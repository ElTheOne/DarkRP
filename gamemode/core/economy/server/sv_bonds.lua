local Bonds = {
	Version = 1,
	StateKey = "government_bonds",
	DataPath = "darkrp/government_bonds.json",
	Records = {},
	ByOwner = {},
	NextID = 1,
	Debt = 0,
	IssuanceEnabled = false,
	IssuanceMayorID = "",
	Revision = 0,
	Dirty = false,
	LocalLoaded = false,
	DatabaseLoadStarted = false,
	Sessions = setmetatable({}, { __mode = "k" }),
	Config = {
		InterestBasisPoints = 500,
		TermSeconds = 3600,
		MinimumInvestment = 500,
		BasePlayerPrincipalCap = 50000,
		MinimumGlobalPrincipalCap = 25000,
		EconomyShareCap = 0.10,
		MaximumActivePerPlayer = 16,
		BurnPauseRate = 0.12,
		MinimumBurnLimitFactor = 0.15,
		InteractionDistance = 180
	}
}

DRP.Bonds = Bonds
DRP.Services.Register("bonds", Bonds)
DRP.Services.DependsOn("bonds", { "storage", "deadlines", "economy", "economy_director", "government" })

local openMessage = "drp_bond_atm_open_v1"
local buyMessage = "drp_bond_atm_buy_v1"
util.AddNetworkString(openMessage)
util.AddNetworkString(buyMessage)

local function integer(value)
	return math.max(0, math.floor(tonumber(value) or 0))
end

local function validSteamID64(value)
	value = tostring(value or "")
	return string.match(value, "^7656119%d%d%d%d%d%d%d%d%d%d$") ~= nil and value or ""
end

local function audit(actor, action, detail)
	if DRP.Audit then DRP.Audit.Log(IsValid(actor) and actor or nil, action, nil, tostring(detail or "")) end
end

function Bonds:PayoutFor(principal)
	principal = integer(principal)
	return principal + math.max(1, math.floor(principal * integer(self.Config.InterestBasisPoints) / 10000))
end

function Bonds:BurnRate()
	return DRP.EconomyDirector and DRP.EconomyDirector.TransactionBurnRate
		and math.max(0, tonumber(DRP.EconomyDirector:TransactionBurnRate()) or 0) or 0
end

function Bonds:BurnLimitFactor(rate)
	rate = math.max(0, tonumber(rate) or self:BurnRate())
	local pause = math.max(0.001, tonumber(self.Config.BurnPauseRate) or 0.12)
	if rate >= pause then return 0 end
	local minimum = math.Clamp(tonumber(self.Config.MinimumBurnLimitFactor) or 0.15, 0, 1)
	return Lerp(math.Clamp(rate / pause, 0, 1), 1, minimum)
end

function Bonds:RebuildIndexes()
	self.ByOwner = {}
	local normalized = {}
	local highest = 0
	for id, record in pairs(self.Records) do
		id = integer(id)
		if id > 0 and istable(record) and validSteamID64(record.owner) ~= "" then
			record.id = id
			record.owner = validSteamID64(record.owner)
			record.principal = integer(record.principal)
			record.payout = math.max(record.principal, integer(record.payout))
			record.purchased = integer(record.purchased)
			record.matures = integer(record.matures)
			record.status = ({ active = true, pending = true })[record.status] and record.status or "pending"
			normalized[id] = record
			self.ByOwner[record.owner] = self.ByOwner[record.owner] or {}
			self.ByOwner[record.owner][id] = true
			highest = math.max(highest, id)
		end
	end
	self.Records = normalized
	self.NextID = math.max(integer(self.NextID), highest + 1, 1)
end

function Bonds:OutstandingPrincipal(ownerID)
	local total = 0
	if ownerID then
		for id in pairs(self.ByOwner[tostring(ownerID)] or {}) do
			local record = self.Records[id]
			if record and record.status == "active" then total = total + integer(record.principal) end
		end
	else
		for _, record in pairs(self.Records) do
			if record.status == "active" then total = total + integer(record.principal) end
		end
	end
	return total
end

function Bonds:OutstandingLiability()
	local total = 0
	for _, record in pairs(self.Records) do
		if record.status == "active" then total = total + integer(record.payout) end
	end
	return total
end

function Bonds:PendingPayout(ownerID)
	local total = 0
	for id in pairs(self.ByOwner[tostring(ownerID or "")] or {}) do
		local record = self.Records[id]
		if record and record.status == "pending" then total = total + integer(record.payout) end
	end
	return total
end

function Bonds:DeficitFor(treasury, activeLiability, maturedDebt)
	return integer(maturedDebt) + math.max(0, integer(activeLiability) - integer(treasury))
end

function Bonds:Deficit()
	local treasury = DRP.Government and DRP.Government.GetTreasury and DRP.Government.GetTreasury() or 0
	return self:DeficitFor(treasury, self:OutstandingLiability(), self.Debt)
end

function Bonds:IsDeficit()
	return self:Deficit() > 0
end

function Bonds:IsIssuanceActive()
	local mayor = DRP.Government and DRP.Government.CurrentMayor and DRP.Government.CurrentMayor()
	return self.IssuanceEnabled == true and IsValid(mayor)
		and self.IssuanceMayorID ~= "" and mayor:SteamID64() == self.IssuanceMayorID
end

function Bonds:Capacity(ownerID)
	local money = DRP.EconomyDirector and DRP.EconomyDirector:MoneySummary(true) or {}
	local factor = self:BurnLimitFactor()
	local playerCap = math.floor(integer(self.Config.BasePlayerPrincipalCap) * factor)
	local globalBase = math.max(integer(self.Config.MinimumGlobalPrincipalCap), math.floor((tonumber(money.effectiveMoney) or 0) * (tonumber(self.Config.EconomyShareCap) or 0.10)))
	local globalCap = math.floor(globalBase * factor)
	local playerUsed = self:OutstandingPrincipal(ownerID)
	local globalUsed = self:OutstandingPrincipal()
	return {
		factor = factor,
		burnRate = self:BurnRate(),
		playerCap = playerCap,
		playerUsed = playerUsed,
		playerAvailable = math.max(0, playerCap - playerUsed),
		globalCap = globalCap,
		globalUsed = globalUsed,
		globalAvailable = math.max(0, globalCap - globalUsed)
	}
end

function Bonds:Payload()
	return {
		version = self.Version,
		revision = self.Revision,
		next_id = self.NextID,
		debt = self.Debt,
		issuance_enabled = self.IssuanceEnabled == true,
		issuance_mayor_id = self.IssuanceMayorID,
		records = self.Records,
		config = self.Config,
		saved_at = os.time()
	}
end

function Bonds:ApplyPayload(payload)
	if not istable(payload) then return false end
	self.Revision = integer(payload.revision)
	self.NextID = math.max(1, integer(payload.next_id))
	self.Debt = integer(payload.debt)
	self.IssuanceEnabled = payload.issuance_enabled == true
	self.IssuanceMayorID = validSteamID64(payload.issuance_mayor_id)
	self.Records = istable(payload.records) and payload.records or {}
	if istable(payload.config) then table.Merge(self.Config, payload.config) end
	self:RebuildIndexes()
	return true
end

function Bonds:WriteLocal()
	local payload = util.TableToJSON(self:Payload(), false)
	if not payload then return false end
	file.CreateDir("darkrp")
	file.Write(self.DataPath, payload)
	return payload
end

function Bonds:Save(force)
	if not force and not self.Dirty then return true end
	local revision = self.Revision
	local payload = self:WriteLocal()
	if not payload then return false end
	if DRP.Storage and DRP.Storage.SaveWorldState then
		local queued = DRP.Storage.SaveWorldState(self.StateKey, payload, function(success, reason)
			if success and self.Revision == revision then
				self.Dirty = false
			elseif success ~= true then
				self.Dirty = true
				ErrorNoHalt("[DRP BONDS] database save deferred: " .. tostring(reason or "storage unavailable") .. "\n")
			end
		end)
		if queued == false then self.Dirty = true end
	end
	return true
end

function Bonds:MarkDirty(reason, saveNow)
	self.Revision = self.Revision + 1
	self.Dirty = true
	hook.Run("DRPBondsChanged", tostring(reason or "bond state changed"))
	if saveNow then self:Save(true) else self:WriteLocal() end
end

function Bonds:Schedule(record)
	if not record or record.status ~= "active" then return end
	local delay = math.max(0.01, integer(record.matures) - os.time())
	DRP.Deadlines.Schedule("bond:" .. record.id, CurTime() + delay, function()
		if DRP.Bonds == Bonds then Bonds:Mature(record.id) end
	end)
end

function Bonds:ScheduleAll()
	for _, record in pairs(self.Records) do self:Schedule(record) end
end

-- Positive government revenue services matured bond debt before it becomes
-- spendable treasury cash. This is invoked by Government.SetTreasury and must
-- never call back into the treasury API.
function Bonds:ApplyTreasuryIncrease(increase, reason)
	increase = integer(increase)
	if increase <= 0 or self.Debt <= 0 then return increase, 0 end
	local absorbed = math.min(increase, self.Debt)
	self.Debt = self.Debt - absorbed
	self:MarkDirty("bond debt serviced by " .. tostring(reason or "government revenue"), false)
	audit(nil, "bond_debt_serviced", "amount=" .. absorbed .. " remaining=" .. self.Debt)
	return increase - absorbed, absorbed
end

function Bonds:SetIssuance(mayor, enabled)
	if not IsValid(mayor) or not DRP.Government or mayor ~= DRP.Government.CurrentMayor() then
		if IsValid(mayor) then DRP.Net.Notify(mayor, "Only the sitting Mayor can control municipal bond sales.", 3) end
		return false
	end
	enabled = enabled == true
	if enabled and self:IsDeficit() then
		DRP.Net.Notify(mayor, "Bond sales cannot open while government bond liabilities exceed available treasury assets.", 3)
		return false
	end
	if enabled and self:BurnLimitFactor() <= 0 then
		DRP.Net.Notify(mayor, "Bond sales are paused while automatic inflation burning is at its safety threshold.", 3)
		return false
	end
	self.IssuanceEnabled = enabled
	self.IssuanceMayorID = enabled and mayor:SteamID64() or ""
	self:MarkDirty(enabled and "bond sales opened" or "bond sales closed", true)
	DRP.Net.Notify(mayor, enabled and "Municipal bond sales are now open." or "Municipal bond sales are now closed.", 1)
	audit(mayor, enabled and "bond_issuance_opened" or "bond_issuance_closed", "deficit=" .. self:Deficit())
	return true
end

function Bonds:CanPurchase(ply, amount)
	amount = integer(amount)
	if not IsValid(ply) or not ply:DRPReady() then return false, "Your profile is not ready." end
	local session = self.Sessions[ply]
	if not session or not IsValid(session.entity) or session.entity:GetClass() ~= "drp_atm"
		or (tonumber(session.expires) or 0) < CurTime()
		or ply:GetPos():DistToSqr(session.entity:GetPos()) > (integer(self.Config.InteractionDistance) ^ 2) then
		self.Sessions[ply] = nil
		return false, "Use a nearby Municipal Bond ATM before purchasing."
	end
	if not self:IsIssuanceActive() then return false, "The sitting Mayor is not currently selling municipal bonds." end
	if self:IsDeficit() then return false, "Bond sales are suspended while the government is in a bond deficit." end
	if amount < integer(self.Config.MinimumInvestment) then return false, "The minimum bond investment is $" .. integer(self.Config.MinimumInvestment) .. "." end
	if ply:DRPMoney() < amount then return false, "You cannot afford that investment." end
	if amount > 4294967295 - DRP.Government.GetTreasury() then
		return false, "The treasury cannot safely accept an investment that large."
	end
	local capacity = self:Capacity(ply:SteamID64())
	if capacity.factor <= 0 then return false, "Bond purchases are paused while automatic inflation burning is active at its safety threshold." end
	if amount > capacity.playerAvailable then return false, "Your remaining bond allowance is $" .. string.Comma(capacity.playerAvailable) .. "." end
	if amount > capacity.globalAvailable then return false, "Only $" .. string.Comma(capacity.globalAvailable) .. " remains in the current municipal issue." end
	local active = 0
	for id in pairs(self.ByOwner[ply:SteamID64()] or {}) do
		local record = self.Records[id]
		if record and record.status == "active" then active = active + 1 end
	end
	if active >= integer(self.Config.MaximumActivePerPlayer) then return false, "You already hold the maximum number of active bonds." end
	local projectedTreasury = DRP.Government.GetTreasury() + amount
	local projectedLiability = self:OutstandingLiability() + self:PayoutFor(amount)
	if self:DeficitFor(projectedTreasury, projectedLiability, self.Debt) > 0 then
		return false, "The treasury lacks enough equity to guarantee this bond's profit."
	end
	return true, nil, capacity
end

function Bonds:Buy(ply, amount)
	amount = integer(amount)
	local allowed, reason = self:CanPurchase(ply, amount)
	if not allowed then DRP.Net.Notify(ply, reason, 3) return false end
	if not DRP.Economy.Take(ply, amount, nil, { kind = "transfer", source = "municipal bond principal" }) then
		DRP.Net.Notify(ply, "The bond purchase could not reserve your funds.", 3)
		return false
	end
	local deposited = DRP.Government.DepositTreasury(amount, "municipal bond principal", true)
	if not deposited then
		DRP.Economy.Add(ply, amount, nil, { kind = "transfer", source = "failed bond purchase refund" })
		DRP.Net.Notify(ply, "The treasury could not accept the bond. Your money was returned.", 3)
		return false
	end
	local id, now = self.NextID, os.time()
	self.NextID = id + 1
	local record = {
		id = id,
		owner = ply:SteamID64(),
		owner_name = string.sub(ply:DRPName(), 1, 64),
		principal = amount,
		payout = self:PayoutFor(amount),
		purchased = now,
		matures = now + integer(self.Config.TermSeconds),
		status = "active"
	}
	self.Records[id] = record
	self.ByOwner[record.owner] = self.ByOwner[record.owner] or {}
	self.ByOwner[record.owner][id] = true
	self:Schedule(record)
	self.Sessions[ply].expires = CurTime() + 30
	self:MarkDirty("bond purchased", true)
	DRP.Government.Save()
	DRP.Net.Notify(ply, "Bond #" .. id .. " purchased for $" .. string.Comma(amount) .. ". Guaranteed maturity value: $" .. string.Comma(record.payout) .. ".", 1)
	audit(ply, "bond_purchased", "id=" .. id .. " principal=" .. amount .. " payout=" .. record.payout)
	self:SendSnapshot(ply)
	return true
end

function Bonds:ClaimPending(ply)
	if not IsValid(ply) then return 0 end
	local ownerID, payout, treasuryFunded, deficitFunded, remove = ply:SteamID64(), 0, 0, 0, {}
	local pending = {}
	for id in pairs(self.ByOwner[ownerID] or {}) do
		local record = self.Records[id]
		if record and record.status == "pending" then pending[#pending + 1] = record end
	end
	table.sort(pending, function(a, b) return a.id < b.id end)
	local walletRoom = math.max(0, 4294967295 - integer(ply:DRPMoney()))
	for _, record in ipairs(pending) do
		local amount = integer(record.payout)
		if amount <= walletRoom - payout then
			payout = payout + amount
			treasuryFunded = treasuryFunded + integer(record.treasury_funded)
			deficitFunded = deficitFunded + integer(record.deficit_funded)
			remove[#remove + 1] = record.id
		end
	end
	if payout <= 0 then
		if #pending > 0 then DRP.Net.Notify(ply, "A matured government bond is waiting. Spend enough wallet funds to receive its full guaranteed payout.", 3) end
		return 0
	end
	for _, id in ipairs(remove) do
		self.Records[id] = nil
		self.ByOwner[ownerID][id] = nil
	end
	if next(self.ByOwner[ownerID]) == nil then self.ByOwner[ownerID] = nil end
	if treasuryFunded > 0 then
		DRP.Economy.Add(ply, treasuryFunded, nil, { kind = "transfer", source = "treasury-funded municipal bond maturity" })
	end
	if deficitFunded > 0 then
		DRP.Economy.Add(ply, deficitFunded, nil, { kind = "mint", source = "guaranteed municipal bond deficit payout" })
	end
	local accounted = treasuryFunded + deficitFunded
	if accounted < payout then
		DRP.Economy.Add(ply, payout - accounted, nil, { kind = "transfer", source = "legacy municipal bond maturity" })
	end
	self:MarkDirty("mature bond payout claimed", true)
	local label = #remove == 1 and " government bond" or " government bonds"
	DRP.Net.Notify(ply, "+$" .. string.Comma(payout) .. " — " .. #remove .. label .. " matured with guaranteed profit.", 1)
	audit(ply, "bond_payout_claimed", "count=" .. #remove .. " payout=" .. payout)
	return payout
end

function Bonds:Mature(id)
	local record = self.Records[integer(id)]
	if not record or record.status ~= "active" then return false end
	local payout = integer(record.payout)
	local treasury = DRP.Government.GetTreasury()
	local funded = math.min(treasury, payout)
	record.status = "pending"
	record.matured = os.time()
	if funded > 0 then DRP.Government.WithdrawTreasury(funded, "municipal bond maturity", true) end
	local shortfall = payout - funded
	if shortfall > 0 then
		self.Debt = self.Debt + shortfall
		self.IssuanceEnabled = false
		self.IssuanceMayorID = ""
		audit(nil, "bond_deficit_created", "bond=" .. record.id .. " shortfall=" .. shortfall .. " debt=" .. self.Debt)
	end
	record.treasury_funded = funded
	record.deficit_funded = shortfall
	self:MarkDirty("bond matured", true)
	DRP.Government.Save()
	local ply = DRP.Players.Online(record.owner)
	if IsValid(ply) then self:ClaimPending(ply) end
	return true
end

function Bonds:BuildSnapshot(ply)
	local ownerID = IsValid(ply) and ply:SteamID64() or ""
	local capacity = self:Capacity(ownerID)
	local records = {}
	for id in pairs(self.ByOwner[ownerID] or {}) do
		local record = self.Records[id]
		if record then
			records[#records + 1] = {
				id = record.id,
				principal = record.principal,
				payout = record.payout,
				purchased = record.purchased,
				matures = record.matures,
				status = record.status
			}
		end
	end
	table.sort(records, function(a, b) return a.id > b.id end)
	return {
		revision = self.Revision,
		issuance = self:IsIssuanceActive() and not self:IsDeficit() and capacity.factor > 0,
		treasury = DRP.Government.GetTreasury(),
		debt = self.Debt,
		deficit = self:Deficit(),
		activePrincipal = self:OutstandingPrincipal(),
		activeLiability = self:OutstandingLiability(),
		interestBasisPoints = integer(self.Config.InterestBasisPoints),
		termSeconds = integer(self.Config.TermSeconds),
		minimum = integer(self.Config.MinimumInvestment),
		capacity = capacity,
		records = records
	}
end

function Bonds:SendSnapshot(ply)
	if not IsValid(ply) then return false end
	local raw = util.TableToJSON(self:BuildSnapshot(ply), false) or "{}"
	local packed = util.Compress(raw) or raw
	net.Start(openMessage)
	net.WriteUInt(#packed, 20)
	net.WriteData(packed, #packed)
	net.Send(ply)
	return true
end

function Bonds:Use(ply, entity)
	if not IsValid(ply) or not IsValid(entity) or entity:GetClass() ~= "drp_atm" then return false end
	if ply:GetPos():DistToSqr(entity:GetPos()) > (integer(self.Config.InteractionDistance) ^ 2) then
		DRP.Net.Notify(ply, "Move closer to the ATM.", 3)
		return false
	end
	self.Sessions[ply] = { entity = entity, expires = CurTime() + 30 }
	self:ClaimPending(ply)
	return self:SendSnapshot(ply)
end

function Bonds:Status()
	local capacity = self:Capacity("")
	return {
		issuance = self:IsIssuanceActive(),
		treasury = DRP.Government and DRP.Government.GetTreasury() or 0,
		principal = self:OutstandingPrincipal(),
		liability = self:OutstandingLiability(),
		debt = self.Debt,
		deficit = self:Deficit(),
		burnRate = capacity.burnRate,
		globalCap = capacity.globalCap,
		globalAvailable = capacity.globalAvailable,
		records = table.Count(self.Records),
		dirty = self.Dirty
	}
end

function Bonds:LoadLocal()
	if self.LocalLoaded then return end
	self.LocalLoaded = true
	local decoded = util.JSONToTable(file.Read(self.DataPath, "DATA") or "")
	if istable(decoded) then self:ApplyPayload(decoded) end
	self:ScheduleAll()
end

function Bonds:LoadDatabase()
	if self.DatabaseLoadStarted or not DRP.Storage or not DRP.Storage.LoadWorldState then return end
	if DRP.Storage.IsAvailable and not DRP.Storage.IsAvailable() then return end
	self.DatabaseLoadStarted = true
	DRP.Storage.LoadWorldState(self.StateKey, function(success, raw)
		local database = success and util.JSONToTable(raw or "") or nil
		if istable(database) and integer(database.revision) >= self.Revision then
			for id in pairs(self.Records) do DRP.Deadlines.Cancel("bond:" .. id) end
			self:ApplyPayload(database)
			self:ScheduleAll()
			self.Dirty = false
		elseif self.LocalLoaded and self.Revision > 0 then
			self.Dirty = true
			self:Save(true)
		end
		if success ~= true then self.DatabaseLoadStarted = false end
	end)
end

function Bonds:Start()
	file.CreateDir("darkrp")
	self:LoadLocal()
	self:LoadDatabase()
	hook.Add("DRPStorageReady", "DRP.Bonds.StorageReady", function() Bonds:LoadDatabase() end)
	hook.Add("DRPPlayerReady", "DRP.Bonds.PlayerReady", function(ply)
		Bonds:ClaimPending(ply)
	end)
	hook.Add("PlayerDisconnected", "DRP.Bonds.MayorDisconnected", function(ply)
		Bonds.Sessions[ply] = nil
		if not Bonds.IssuanceEnabled or ply:SteamID64() ~= Bonds.IssuanceMayorID then return end
		Bonds.IssuanceEnabled = false
		Bonds.IssuanceMayorID = ""
		Bonds:MarkDirty("issuing mayor disconnected", true)
	end)
	hook.Add("DRPJobChanged", "DRP.Bonds.MayorRoleChanged", function(ply, _, newJob)
		if not Bonds.IssuanceEnabled or ply:SteamID64() ~= Bonds.IssuanceMayorID then return end
		if newJob == DRP.Job.MAYOR then return end
		Bonds.IssuanceEnabled = false
		Bonds.IssuanceMayorID = ""
		Bonds:MarkDirty("issuing mayor left office", true)
	end)
	hook.Add("DRPGovernmentTreasuryChanged", "DRP.Bonds.Solvency", function()
		if Bonds.IssuanceEnabled and Bonds:IsDeficit() then
			Bonds.IssuanceEnabled = false
			Bonds.IssuanceMayorID = ""
			Bonds:MarkDirty("automatic deficit lock", true)
			local mayor = DRP.Government.CurrentMayor()
			if IsValid(mayor) then DRP.Net.Notify(mayor, "Municipal bond sales closed automatically because the government entered a bond deficit.", 3) end
		end
	end)
end

function Bonds:Stop()
	hook.Remove("DRPStorageReady", "DRP.Bonds.StorageReady")
	hook.Remove("DRPPlayerReady", "DRP.Bonds.PlayerReady")
	hook.Remove("PlayerDisconnected", "DRP.Bonds.MayorDisconnected")
	hook.Remove("DRPJobChanged", "DRP.Bonds.MayorRoleChanged")
	hook.Remove("DRPGovernmentTreasuryChanged", "DRP.Bonds.Solvency")
	for id in pairs(self.Records) do DRP.Deadlines.Cancel("bond:" .. id) end
	self.Sessions = setmetatable({}, { __mode = "k" })
	self:Save(true)
end

DRP.Net.Receive(buyMessage, function(_, ply)
	local protocol = net.ReadUInt(8)
	if protocol ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "bond_purchase", 0.75, 2) then return end
	local amount = net.ReadUInt(32)
	Bonds:Buy(ply, amount)
end)

concommand.Add("drp_bond_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.Has(ply, "logs")) then return end
	print("[DRP BONDS] " .. (util.TableToJSON(Bonds:Status(), false) or "{}"))
end)
