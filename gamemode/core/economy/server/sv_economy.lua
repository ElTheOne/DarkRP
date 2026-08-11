local Economy = {
	DefaultMoney = 500,
	SalaryInterval = 120,
	OutboxDirectory = "darkrp/profile_outbox",
	-- Runtime mutations may arrive several times in one server frame (salary,
	-- civic, XP and derived-role updates frequently travel together). Keep the
	-- crash-recovery journal event driven, but serialize it only once per frame.
	PendingOutboxWrites = setmetatable({}, { __mode = "k" })
}

DRP.Economy = Economy
DRP.Services.Register("economy", Economy)
DRP.Services.DependsOn("economy", { "storage", "network" })

local function cleanAmount(amount)
	return math.Clamp(math.floor(tonumber(amount) or 0), 0, 4294967295)
end

local function outboxPath(steamID64)
	return Economy.OutboxDirectory .. "/" .. tostring(steamID64 or "") .. ".json"
end

local function playerSnapshot(ply, totalPlaytime)
	-- A Steam nickname is only a temporary display fallback. Persist an RP name
	-- after the Councilman has issued a civic identity, otherwise a new player
	-- could disconnect once and accidentally bypass registration on the next join.
	local rpName = DRP.Identity and DRP.Identity:IsRegistered(ply) and ply:DRPName() or ""
	return {
		revision = math.max(os.time() * 1000, math.floor(tonumber(ply.DRPProfileOutboxRevision) or 0) + 1),
		last_name = ply:Nick(), rp_name = rpName, job_name = ply.DRPJobNameValue or "",
		money = ply:DRPMoney(), job_key = ply:DRPJob().key,
		total_playtime_seconds = math.max(0, math.floor(tonumber(totalPlaytime) or 0)),
		xp_points = ply:DRPXP(), xp_level = ply:DRPXPLevel(), xp_prestige = ply:DRPXPPrestige(),
		xp_prestige_tokens = ply:DRPXPPrestigeTokens(),
		xp_prestige_items = DRP.Experience and DRP.Experience:SerializeUnlockedItems(ply) or "[]",
		civic_standing = DRP.Civic and DRP.Civic:Get(ply) or 0,
		role_behavior = DRP.Roles and DRP.Roles:Serialize(ply) or "{}",
		role_goal = math.Clamp(math.floor(tonumber(ply.DRPRoleGoalValue) or 0), 0, 255),
		written_at = os.time()
	}
end

function Economy.WriteOutbox(ply, totalPlaytime)
	if not IsValid(ply) or ply:IsBot() or not ply.DRPSessionStartedAt then return nil end
	local started = DRP.Profile and DRP.Profile.Begin and DRP.Profile.Begin() or nil
	local elapsed = math.max(0, CurTime() - ply.DRPSessionStartedAt)
	local snapshot = playerSnapshot(ply, totalPlaytime or ((ply.DRPTotalPlaytimeBase or 0) + elapsed))
	local payload = util.TableToJSON(snapshot, false)
	if not payload then
		if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("economy.outbox", started) end
		return nil
	end
	file.Write(outboxPath(ply:SteamID64()), payload)
	ply.DRPProfileOutboxRevision = snapshot.revision
	if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("economy.outbox", started) end
	return snapshot
end

-- A surviving outbox is a snapshot whose database acknowledgement was never
-- observed. Overlay it after the database read so an outage or crash cannot
-- reset wallet, XP, civic state, identity or playtime on the next join.
function Economy.RecoverPlayerRow(steamID64, row)
	local recovered = util.JSONToTable(file.Read(outboxPath(steamID64), "DATA") or "")
	if not istable(recovered) then return row, false end
	row = istable(row) and table.Copy(row) or {}
	for key, value in pairs(recovered) do
		if key ~= "revision" and key ~= "written_at" then row[key] = value end
	end
	row.steam_id = tostring(steamID64 or row.steam_id or "")
	return row, true, math.floor(tonumber(recovered.revision) or 0)
end

function Economy.SavePlayer(ply, callback)
	if not IsValid(ply) or ply:IsBot() then
		if callback then callback(false, not IsValid(ply) and "player is not valid" or "bots are not persistent") end
		return false
	end
	local sessionTime = math.max(0, CurTime() - (ply.DRPSessionStartedAt or CurTime()))
	local totalPlaytime = math.floor((ply.DRPTotalPlaytimeBase or 0) + sessionTime)
	ply.DRPTotalPlaytimeBase = totalPlaytime
	ply.DRPSessionStartedAt = CurTime()
	ply.DRPPlayerRecordDirty = true
	Economy.PendingOutboxWrites[ply] = nil
	local snapshot = Economy.WriteOutbox(ply, totalPlaytime)
	if not snapshot then
		if callback then callback(false, "profile snapshot could not be serialized") end
		return false
	end
	local steamID64=ply:SteamID64()
	DRP.Storage.SavePlayer(
		steamID64,
		snapshot.last_name, snapshot.rp_name, snapshot.job_name, snapshot.money,
		snapshot.job_key, snapshot.total_playtime_seconds, snapshot.xp_points,
		snapshot.xp_level, snapshot.xp_prestige, snapshot.xp_prestige_tokens,
		snapshot.xp_prestige_items, snapshot.civic_standing, snapshot.role_behavior,
		snapshot.role_goal,
		function(success, reason)
			local current=util.JSONToTable(file.Read(outboxPath(steamID64),"DATA") or "")
			if success == true and istable(current) and math.floor(tonumber(current.revision) or 0)==snapshot.revision then
				file.Delete(outboxPath(steamID64))
				if IsValid(ply) then ply.DRPPlayerRecordDirty = false end
			elseif IsValid(ply) then
				ply.DRPPlayerRecordDirty = true
			end
			if callback then callback(success, reason) end
		end
	)
	return true
end

function Economy.FlushQueuedOutbox(ply)
	if not Economy.PendingOutboxWrites[ply] then return false end
	Economy.PendingOutboxWrites[ply] = nil
	if not IsValid(ply) or ply:IsBot() or not ply.DRPPlayerRecordDirty then return false end
	return Economy.WriteOutbox(ply) ~= nil
end

function Economy.QueueSave(ply)
	if not IsValid(ply) or ply:IsBot() then return false end
	-- MySQL remains lifecycle/event driven. Coalescing only affects the local
	-- recovery journal; SavePlayer still performs an immediate lifecycle write.
	ply.DRPPlayerRecordDirty = true
	if Economy.PendingOutboxWrites[ply] then return true end
	Economy.PendingOutboxWrites[ply] = true
	timer.Simple(0, function()
		if DRP.Economy == Economy then Economy.FlushQueuedOutbox(ply) end
	end)
	return true
end

function Economy.SaveAll()
	for _, ply in ipairs(DRP.Players.List) do
		if IsValid(ply) and not ply:IsBot() then Economy.SavePlayer(ply) end
	end
end

function Economy:Start()
	file.CreateDir("darkrp")
	file.CreateDir(self.OutboxDirectory)
end
function Economy:Stop() end

function Economy.InitializePlayer(ply, amount)
	ply.DRPMoneyValue = cleanAmount(amount or Economy.DefaultMoney)
	ply.DRPNextSalary = CurTime() + Economy.SalaryInterval
	Economy.ScheduleSalary(ply)
end

function Economy.Set(ply, amount, silent, context)
	if not IsValid(ply) then return false end
	local started = DRP.Profile.Begin()
	local previous = cleanAmount(ply.DRPMoneyValue)
	local updated = cleanAmount(amount)
	ply.DRPMoneyValue = updated
	if not silent then DRP.Net.SendProfile(ply) end
	Economy.QueueSave(ply)
	if (previous <= 0) ~= (updated <= 0) then
		hook.Run("DRPMoneyZeroStateChanged", ply, previous, updated)
	end
	if DRP.EconomyDirector and updated ~= previous then
		local kind = istable(context) and context.kind or "reconcile"
		DRP.EconomyDirector:RecordMoney(ply, updated - previous, kind, istable(context) and context.source or "economy.set")
	end
	DRP.Profile.Finish("economy.set", started)
	return true
end

function Economy.Add(ply, amount, reason, context)
	amount = cleanAmount(amount)
	if amount <= 0 or not IsValid(ply) then return false end
	Economy.Set(ply, ply:DRPMoney() + amount, false, context or { kind = "transfer", source = reason or "economy.add" })
	if reason then DRP.Net.Notify(ply, "+$" .. amount .. " — " .. reason, 1) end
	return true
end

-- Releases existing money to a recipient after applying the director's
-- automatic circulation burn. The gross amount has already left a payer or
-- escrow; only the net amount enters the recipient wallet.
function Economy.SettleTransfer(ply, amount, reason)
	amount = cleanAmount(amount)
	if amount <= 0 or not IsValid(ply) then return false, 0, 0 end
	local burned, net = 0, amount
	if DRP.EconomyDirector and DRP.EconomyDirector.CalculateTransactionBurn then
		burned, net = DRP.EconomyDirector:CalculateTransactionBurn(amount)
	end
	if net > 0 then
		Economy.Add(ply, net, nil, { kind = "transfer", source = reason or "transaction settlement" })
	end
	if burned > 0 then
		DRP.EconomyDirector:RecordBurn(burned, reason or "transaction settlement")
		if DRP.Audit then DRP.Audit.Log(ply, "economy_transaction_burn", nil, tostring(reason or "transaction") .. " gross=" .. amount .. " net=" .. net .. " burned=" .. burned) end
	end
	return true, net, burned
end

function Economy.Transfer(from, to, amount, reason)
	amount = cleanAmount(amount)
	if amount <= 0 or not IsValid(from) or not IsValid(to) or from == to or from:DRPMoney() < amount then return false, 0, 0 end
	Economy.Set(from, from:DRPMoney() - amount, false, { kind = "transfer", source = reason or "player transfer" })
	local ok, net, burned = Economy.SettleTransfer(to, amount, reason or "player transfer")
	if not ok then
		Economy.Add(from, amount, nil, { kind = "transfer", source = "failed transfer rollback" })
		return false, 0, 0
	end
	return true, net, burned
end

-- Server-generated income only. Successful ownership-changing payments use
-- Transfer/SettleTransfer; refunds, escrow releases and administrative
-- adjustments use Add so existing value is never duplicated or taxed twice.
function Economy.Reward(ply, amount, reason)
	local ordinary = cleanAmount(amount)
	if ordinary <= 0 or not IsValid(ply) then return false, 0 end
	local rewarded = DRP.Supporter and DRP.Supporter.ApplyReward(ply, ordinary) or ordinary
	if rewarded <= 0 then return false, 0 end
	if rewarded > ordinary and DRP.Audit then DRP.Audit.Log(ply, "supporter_money_bonus", nil, tostring(reason or "server reward") .. " " .. ordinary .. " -> " .. rewarded) end
	local suffix = rewarded > ordinary and (" (supporter bonus +$" .. (rewarded - ordinary) .. ")") or ""
	return Economy.Add(ply, rewarded, tostring(reason or "server reward") .. suffix, { kind = "mint", source = reason or "server reward" }), rewarded
end

function Economy.Take(ply, amount, reason, context)
	amount = cleanAmount(amount)
	if amount <= 0 or not IsValid(ply) or ply:DRPMoney() < amount then return false end
	Economy.Set(ply, ply:DRPMoney() - amount, false, context or { kind = "burn", source = reason or "economy.take" })
	if reason then DRP.Net.Notify(ply, "-$" .. amount .. " — " .. reason, 2) end
	return true
end

function Economy.ScheduleSalary(ply)
	if not IsValid(ply) then return end
	local key = "salary:" .. ply:SteamID64()
	DRP.Deadlines.Schedule(key, ply.DRPNextSalary or (CurTime() + Economy.SalaryInterval), function()
		if not IsValid(ply) or not ply:DRPReady() then return end
		local job = ply:DRPJob()
		ply.DRPNextSalary = CurTime() + Economy.SalaryInterval
		local payment, tax, bonus = job.salary, 0, 0
		if DRP.Government then payment, tax, bonus = DRP.Government.ProcessSalary(ply, job) end
		-- ProcessSalary already applies the supporter multiplier before tax.
		Economy.Add(ply, payment, job.name .. " salary" .. (bonus > 0 and (" (+$" .. bonus .. " funded)") or ""), { kind = "mint", source = "salary" })
		if tax > 0 then DRP.Net.Notify(ply, "$" .. tax .. " salary tax was paid to the treasury.", 0) end
		Economy.ScheduleSalary(ply)
	end)
end

function Economy.RemovePlayer(ply)
	DRP.Deadlines.Cancel("salary:" .. ply:SteamID64())
	Economy.PendingOutboxWrites[ply] = nil
	ply.DRPPlayerRecordDirty = nil
end
