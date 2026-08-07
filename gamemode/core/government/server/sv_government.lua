local Government = {
	TaxRate = 0,
	Treasury = 0,
	Allocations = {},
	Phase = 0,
	Deadline = 0,
	Candidates = {},
	Votes = {},
	Confidence = { keep = 0, remove = 0, voters = {} },
	Lottery = nil,
	Mayor = nil,
	AssigningMayor = false
}

DRP.Government = Government
DRP.Services.Register("government", Government)

local syncMessage = "drp_government_v1"
local PHASE_IDLE, PHASE_APPLY, PHASE_VOTE, PHASE_CONFIDENCE = 0, 1, 2, 3
local APPLICATION_TIME, VOTING_TIME, CONFIDENCE_TIME = 60, 60, 60
local CONFIDENCE_INTERVAL = 20 * 60
local queueElectionCheck

util.AddNetworkString(syncMessage)

local function cleanMoney(value)
	return math.Clamp(math.floor(tonumber(value) or 0), 0, 4294967295)
end

function Government.GetTreasury()
	return cleanMoney(Government.Treasury)
end

function Government.SetTreasury(value, reason, immediateSync)
	local previous = Government.GetTreasury()
	local updated = cleanMoney(value)
	if previous == updated then return false, updated end
	Government.Treasury = updated
	Government.QueueSave()
	if immediateSync then Government.Sync() else Government.QueueSync() end
	hook.Run("DRPGovernmentTreasuryChanged", previous, updated, tostring(reason or "treasury updated"))
	return true, updated
end

function Government.DepositTreasury(amount, reason, immediateSync)
	amount = cleanMoney(amount)
	if amount <= 0 then return false, Government.GetTreasury() end
	return Government.SetTreasury(Government.GetTreasury() + amount, reason or "treasury deposit", immediateSync)
end

function Government.WithdrawTreasury(amount, reason, immediateSync)
	amount = cleanMoney(amount)
	local balance = Government.GetTreasury()
	if amount <= 0 or balance < amount then return false, balance end
	return Government.SetTreasury(balance - amount, reason or "treasury withdrawal", immediateSync)
end

local function notifyAll(text, kind)
	for _, ply in ipairs(DRP.Players.List) do
		if ply:DRPReady() then DRP.Net.Notify(ply, text, kind or 0) end
	end
end

local function onlineByID(steamID64)
	return DRP.Players.Online(steamID64)
end

local function candidateVotes(steamID64)
	local count = 0
	for _, choice in pairs(Government.Votes) do if choice == steamID64 then count = count + 1 end end
	return count
end

function Government.CurrentMayor()
	if IsValid(Government.Mayor) and Government.Mayor:DRPJobID() == DRP.Job.MAYOR then return Government.Mayor end
	Government.Mayor = nil
end

function Government.Sync(recipient)
	local mayor = Government.CurrentMayor()
	net.Start(syncMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(Government.TaxRate, 6)
	net.WriteUInt(cleanMoney(Government.Treasury), 32)
	net.WriteEntity(IsValid(mayor) and mayor or NULL)
	local fundedJobs = {}
	for id, job in ipairs(DRP.Jobs) do if (Government.Allocations[job.key] or 0) > 0 then fundedJobs[#fundedJobs + 1] = { id = id, percent = Government.Allocations[job.key] } end end
	net.WriteUInt(math.min(#fundedJobs, 15), 4)
	for index = 1, math.min(#fundedJobs, 15) do
		net.WriteUInt(fundedJobs[index].id, 8)
		net.WriteUInt(fundedJobs[index].percent, 6)
	end
	net.WriteUInt(Government.Phase, 2)
	net.WriteUInt(math.Clamp(math.ceil(Government.Deadline - CurTime()), 0, 65535), 16)
	net.WriteUInt(math.min(#Government.Candidates, 32), 6)
	for index = 1, math.min(#Government.Candidates, 32) do
		local candidate = Government.Candidates[index]
		net.WriteString(candidate.id)
		net.WriteString(candidate.name)
		net.WriteUInt(math.min(candidateVotes(candidate.id), 255), 8)
	end
	net.WriteUInt(math.min(Government.Confidence.keep or 0, 255), 8)
	net.WriteUInt(math.min(Government.Confidence.remove or 0, 255), 8)
	net.WriteBool(Government.Lottery ~= nil)
	if Government.Lottery then
		net.WriteUInt(cleanMoney(Government.Lottery.prize), 32)
		net.WriteUInt(math.Clamp(math.ceil(Government.Lottery.deadline - CurTime()), 0, 65535), 16)
		net.WriteUInt(math.min(table.Count(Government.Lottery.entrants), 255), 8)
	end
	if IsValid(recipient) then net.Send(recipient) else net.Broadcast() end
end

function Government.QueueSync()
	timer.Create("DRP.Government.Sync", 0.5, 1, function() Government.Sync() end)
end

function Government.Save()
	if DRP.Storage.IsLocal and DRP.Storage.IsLocal() then
		if not DRP.Storage.IsAvailable() then return end
		Government.DatabaseDirty = false
		DRP.Storage.SaveLocalGovernment(Government.Treasury, Government.TaxRate, Government.Allocations, function(success, reason)
			if success then return end
			Government.DatabaseDirty = true
			ErrorNoHalt("[DRP] local government save failed: " .. tostring(reason) .. "\n")
		end)
		return
	end
	if not DRP.Storage.IsAvailable() or not DRP.Storage.Database then return end
	Government.DatabaseDirty = false
	local state = DRP.Storage.Database:prepare("UPDATE drp_government_state SET treasury = ?, tax_rate = ? WHERE singleton_id = 1")
	state:setNumber(1, cleanMoney(Government.Treasury))
	state:setNumber(2, Government.TaxRate)
	function state:onError(reason) Government.DatabaseDirty = true ErrorNoHalt("[DRP] government state save failed: " .. tostring(reason) .. "\n") end
	state:start()
	local values = {}
	for jobKey, percent in pairs(Government.Allocations) do
		values[#values + 1] = "('" .. DRP.Storage.Database:escape(jobKey) .. "'," .. math.Clamp(math.floor(percent), 0, 50) .. ")"
	end
	if #values > 0 then
		local query = DRP.Storage.Database:query("INSERT INTO drp_job_funding (job_key, bonus_percent) VALUES " .. table.concat(values, ",") .. " ON DUPLICATE KEY UPDATE bonus_percent = VALUES(bonus_percent)")
		function query:onError(reason) Government.DatabaseDirty = true ErrorNoHalt("[DRP] government funding save failed: " .. tostring(reason) .. "\n") end
		query:start()
	end
end

function Government.QueueSave()
	-- Treasury mutations can be frequent (salary processing), so persist them
	-- only from lifecycle events rather than scheduling database writes.
	Government.DatabaseDirty = true
end

function Government.Load()
	if DRP.Storage.IsLocal and DRP.Storage.IsLocal() then
		DRP.Storage.LoadLocalGovernment(function(success, data, reason)
			if not success then
				ErrorNoHalt("[DRP] local government load failed: " .. tostring(reason) .. "\n")
				return
			end
			data = istable(data) and data or {}
			Government.Treasury = cleanMoney(data.treasury)
			Government.TaxRate = math.Clamp(math.floor(tonumber(data.tax_rate) or 0), 0, 50)
			Government.Allocations = {}
			for jobKey, percent in pairs(data.allocations or {}) do
				if DRP.JobService.Resolve(jobKey) then
					Government.Allocations[jobKey] = math.Clamp(math.floor(tonumber(percent) or 0), 0, 50)
				end
			end
			Government.Sync()
		end)
		return
	end
	if not DRP.Storage.IsAvailable() or not DRP.Storage.Database then return end
	local state = DRP.Storage.Database:query("SELECT treasury, tax_rate FROM drp_government_state WHERE singleton_id = 1 LIMIT 1")
	function state:onSuccess(data)
		local row = data and data[1]
		Government.Treasury = cleanMoney(row and row.treasury)
		Government.TaxRate = math.Clamp(math.floor(tonumber(row and row.tax_rate) or 0), 0, 50)
		Government.Sync()
	end
	function state:onError(reason) ErrorNoHalt("[DRP] government state load failed: " .. tostring(reason) .. "\n") end
	state:start()

	local funding = DRP.Storage.Database:query("SELECT job_key, bonus_percent FROM drp_job_funding")
	function funding:onSuccess(data)
		Government.Allocations = {}
		for _, row in ipairs(data or {}) do
			if DRP.JobService.Resolve(row.job_key) then Government.Allocations[row.job_key] = math.Clamp(math.floor(tonumber(row.bonus_percent) or 0), 0, 50) end
		end
		Government.Sync()
	end
	function funding:onError(reason) ErrorNoHalt("[DRP] job funding load failed: " .. tostring(reason) .. "\n") end
	funding:start()
end

function Government.ProcessSalary(ply, job)
	local base = cleanMoney(job.salary)
	local percent = math.Clamp(math.floor(Government.Allocations[job.key] or 0), 0, 50)
	local requestedBonus = math.floor(base * percent / 100)
	local bonus = math.min(requestedBonus, Government.Treasury)
	local ordinaryGross = base + bonus
	local gross = DRP.Supporter and DRP.Supporter.ApplyReward(ply, ordinaryGross) or ordinaryGross
	local tax = math.min(gross, math.floor(gross * Government.TaxRate / 100))
	if bonus > 0 or tax > 0 then Government.SetTreasury(Government.Treasury - bonus + tax, "salary funding and tax", false) end
	return gross - tax, tax, bonus
end

function Government.SetTax(ply, value)
	if ply ~= Government.CurrentMayor() then DRP.Net.Notify(ply, "Only the sitting Mayor can set tax.", 3) return false end
	local rate = math.floor(tonumber(value) or -1)
	if rate < 0 or rate > 50 then DRP.Net.Notify(ply, "Tax must be between 0% and 50%.", 3) return false end
	Government.TaxRate = rate
	Government.QueueSave()
	Government.Sync()
	notifyAll(ply:DRPName() .. " set salary tax to " .. rate .. "%.", 0)
	if DRP.Audit then DRP.Audit.Log(ply, "government_tax", nil, rate .. "%") end
	return true
end

function Government.SetAllocation(ply, jobValue, value)
	if ply ~= Government.CurrentMayor() then DRP.Net.Notify(ply, "Only the sitting Mayor can allocate treasury funding.", 3) return false end
	local jobID = DRP.JobService.Resolve(jobValue)
	local percent = math.floor(tonumber(value) or -1)
	if not jobID or percent < 0 or percent > 50 then DRP.Net.Notify(ply, "Usage: /allocate <job> <0-50 percent>.", 3) return false end
	local job = DRP.Jobs[jobID]
	Government.Allocations[job.key] = percent
	Government.QueueSave()
	Government.Sync()
	notifyAll(job.name .. " treasury funding is now a maximum " .. percent .. "% salary bonus.", 0)
	if DRP.Audit then DRP.Audit.Log(ply, "government_allocation", nil, job.key .. " " .. percent .. "%") end
	return true
end

function Government.StartElection()
	if IsValid(Government.CurrentMayor()) or Government.Phase ~= PHASE_IDLE then return false end
	Government.Phase = PHASE_APPLY
	Government.Deadline = CurTime() + APPLICATION_TIME
	Government.Candidates = {}
	Government.Votes = {}
	notifyAll("Mayor applications are open for 60 seconds. Use /mayor to apply.", 0)
	Government.Sync()
	timer.Create("DRP.Government.Phase", APPLICATION_TIME, 1, function() Government.BeginVoting() end)
	return true
end

function Government.Apply(ply)
	if IsValid(Government.CurrentMayor()) then DRP.Net.Notify(ply, "There is already a sitting Mayor.", 3) return false end
	local mayorJob = DRP.Jobs[DRP.Job.MAYOR]
	if DRP.Civic and DRP.Civic:Get(ply) < (mayorJob.civicMinimum or 0) then
		DRP.Net.Notify(ply, "Mayor candidates require at least +" .. (mayorJob.civicMinimum or 0) .. " civic standing.", 3)
		return false
	end
	if Government.Phase == PHASE_IDLE then Government.StartElection() end
	if Government.Phase ~= PHASE_APPLY then DRP.Net.Notify(ply, "Mayor applications are closed.", 3) return false end
	for _, candidate in ipairs(Government.Candidates) do if candidate.id == ply:SteamID64() then DRP.Net.Notify(ply, "You have already applied.", 3) return false end end
	Government.Candidates[#Government.Candidates + 1] = { id = ply:SteamID64(), name = ply:DRPName() }
	notifyAll(ply:DRPName() .. " entered the mayor election.", 0)
	Government.Sync()
	return true
end

function Government.BeginVoting()
	if Government.Phase ~= PHASE_APPLY then return end
	local active = {}
	for _, candidate in ipairs(Government.Candidates) do if IsValid(onlineByID(candidate.id)) then active[#active + 1] = candidate end end
	Government.Candidates = active
	if #active == 0 then
		Government.Phase, Government.Deadline = PHASE_IDLE, 0
		notifyAll("The mayor election closed without a candidate.", 2)
		Government.Sync()
		timer.Create("DRP.Government.RetryElection", 60, 1, function() Government.StartElection() end)
		return
	end
	Government.Phase = PHASE_VOTE
	Government.Deadline = CurTime() + VOTING_TIME
	Government.Votes = {}
	notifyAll("Mayor voting is open for 60 seconds. Use /vote <candidate name>.", 0)
	Government.Sync()
	timer.Create("DRP.Government.Phase", VOTING_TIME, 1, function() Government.FinishElection() end)
end

function Government.AssignMayor(ply)
	if not IsValid(ply) or not ply:DRPReady() then return false end
	local current = Government.CurrentMayor()
	Government.AssigningMayor = true
	if IsValid(current) and current ~= ply then DRP.JobService.Set(current, DRP.Job.CITIZEN) end
	if ply:DRPJobID() ~= DRP.Job.MAYOR then DRP.JobService.Set(ply, DRP.Job.MAYOR) end
	Government.AssigningMayor = false
	Government.Mayor = ply
	Government.Phase, Government.Deadline = PHASE_IDLE, 0
	Government.Candidates, Government.Votes = {}, {}
	timer.Remove("DRP.Government.Phase")
	timer.Create("DRP.Government.ConfidenceDue", CONFIDENCE_INTERVAL, 1, function() Government.BeginConfidence() end)
	notifyAll(ply:DRPName() .. " is now Mayor.", 1)
	Government.Sync()
	return true
end

function Government.FinishElection()
	if Government.Phase ~= PHASE_VOTE then return end
	local winner, best = nil, -1
	-- Strictly greater preserves application order when vote totals are tied.
	for _, candidate in ipairs(Government.Candidates) do
		if IsValid(onlineByID(candidate.id)) then
			local votes = candidateVotes(candidate.id)
			if votes > best then winner, best = onlineByID(candidate.id), votes end
		end
	end
	if IsValid(winner) then Government.AssignMayor(winner) return end
	Government.Phase, Government.Deadline = PHASE_IDLE, 0
	Government.Sync()
	timer.Create("DRP.Government.RetryElection", 30, 1, function() Government.StartElection() end)
end

function Government.BeginConfidence()
	local mayor = Government.CurrentMayor()
	if not IsValid(mayor) then Government.StartElection() return end
	Government.Phase = PHASE_CONFIDENCE
	Government.Deadline = CurTime() + CONFIDENCE_TIME
	Government.Confidence = { keep = 0, remove = 0, voters = {} }
	notifyAll("Confidence poll: keep or remove Mayor " .. mayor:DRPName() .. "? Use /vote keep or /vote remove. The Mayor may observe but cannot vote.", 0)
	Government.Sync()
	timer.Create("DRP.Government.Phase", CONFIDENCE_TIME, 1, function() Government.FinishConfidence() end)
end

function Government.FinishConfidence()
	if Government.Phase ~= PHASE_CONFIDENCE then return end
	local mayor = Government.CurrentMayor()
	local remove = Government.Confidence.remove > Government.Confidence.keep
	Government.Phase, Government.Deadline = PHASE_IDLE, 0
	if remove and IsValid(mayor) then
		notifyAll("The confidence poll removed Mayor " .. mayor:DRPName() .. " (" .. Government.Confidence.remove .. " remove / " .. Government.Confidence.keep .. " keep).", 2)
		Government.AssigningMayor = true
		DRP.JobService.Set(mayor, DRP.Job.CITIZEN)
		Government.AssigningMayor = false
		Government.Mayor = nil
		Government.Sync()
		queueElectionCheck(5)
	else
		notifyAll("The Mayor remains in office (" .. Government.Confidence.keep .. " keep / " .. Government.Confidence.remove .. " remove).", 1)
		if IsValid(mayor) then
			hook.Run("DRPMayorConfidenceKept", mayor, Government.Confidence.keep, Government.Confidence.remove)
		end
		Government.Sync()
		timer.Create("DRP.Government.ConfidenceDue", CONFIDENCE_INTERVAL, 1, function() Government.BeginConfidence() end)
	end
end

function Government.Vote(ply, choice)
	local voter = ply:SteamID64()
	if Government.Phase == PHASE_CONFIDENCE then
		if ply == Government.CurrentMayor() then DRP.Net.Notify(ply, "The sitting Mayor cannot vote in their confidence poll.", 3) return false end
		choice = string.lower(tostring(choice or ""))
		if choice ~= "keep" and choice ~= "remove" then DRP.Net.Notify(ply, "Use /vote keep or /vote remove.", 3) return false end
		if Government.Confidence.voters[voter] then DRP.Net.Notify(ply, "Your confidence vote is already recorded.", 3) return false end
		Government.Confidence.voters[voter] = true
		Government.Confidence[choice] = Government.Confidence[choice] + 1
		DRP.Net.Notify(ply, "Your vote to " .. choice .. " the Mayor was recorded.", 1)
		Government.Sync()
		return true
	end
	if Government.Phase ~= PHASE_VOTE then DRP.Net.Notify(ply, "There is no active vote.", 3) return false end
	if Government.Votes[voter] then DRP.Net.Notify(ply, "Your mayor vote is already recorded.", 3) return false end
	choice = string.lower(string.Trim(tostring(choice or "")))
	if choice == "" then DRP.Net.Notify(ply, "Use /vote <candidate name>.", 3) return false end
	local selected
	for _, candidate in ipairs(Government.Candidates) do
		if candidate.id == choice or string.find(string.lower(candidate.name), choice, 1, true) then
			if selected then selected = nil break end
			selected = candidate
		end
	end
	if not selected then DRP.Net.Notify(ply, "Candidate name must match uniquely.", 3) return false end
	Government.Votes[voter] = selected.id
	DRP.Net.Notify(ply, "Your vote for " .. selected.name .. " was recorded.", 1)
	Government.Sync()
	return true
end

function Government.StartLottery(ply, value)
	if ply ~= Government.CurrentMayor() then DRP.Net.Notify(ply, "Only the sitting Mayor can fund a lottery.", 3) return false end
	if Government.Lottery then DRP.Net.Notify(ply, "A treasury lottery is already active.", 3) return false end
	local prize = math.floor(tonumber(value) or 0)
	if prize < 100 or prize > Government.Treasury then DRP.Net.Notify(ply, "Lottery prize must be at least $100 and no more than the treasury balance.", 3) return false end
	if not Government.WithdrawTreasury(prize, "treasury lottery reserved", true) then
		DRP.Net.Notify(ply, "The treasury balance changed before the lottery could be funded.", 3)
		return false
	end
	Government.Lottery = { prize = prize, deadline = CurTime() + 60, entrants = {} }
	notifyAll("A treasury-funded $" .. string.Comma(prize) .. " lottery is open for 60 seconds. Use /lotteryenter.", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "government_lottery", nil, "$" .. prize) end
	timer.Create("DRP.Government.Lottery", 60, 1, function() Government.FinishLottery() end)
	return true
end

function Government.EnterLottery(ply)
	local lottery = Government.Lottery
	if not lottery then DRP.Net.Notify(ply, "There is no active lottery.", 3) return false end
	if ply == Government.CurrentMayor() then DRP.Net.Notify(ply, "The Mayor cannot enter a treasury lottery they funded.", 3) return false end
	local id = ply:SteamID64()
	if lottery.entrants[id] then DRP.Net.Notify(ply, "You are already entered.", 3) return false end
	lottery.entrants[id] = true
	DRP.Net.Notify(ply, "You entered the $" .. string.Comma(lottery.prize) .. " lottery.", 1)
	Government.Sync()
	return true
end

function Government.FinishLottery()
	local lottery = Government.Lottery
	if not lottery then return end
	local entrants = {}
	for steamID64 in pairs(lottery.entrants) do
		local ply = onlineByID(steamID64)
		if IsValid(ply) and ply:DRPReady() then entrants[#entrants + 1] = ply end
	end
	Government.Lottery = nil
	if #entrants == 0 then
		Government.DepositTreasury(lottery.prize, "unclaimed treasury lottery refund", false)
		notifyAll("The lottery had no eligible entrants; its prize returned to the treasury.", 2)
	else
		local winner = entrants[math.random(1, #entrants)]
		DRP.Economy.Reward(winner, lottery.prize, "treasury lottery winner")
		notifyAll(winner:DRPName() .. " won the $" .. string.Comma(lottery.prize) .. " treasury lottery.", 1)
	end
	Government.QueueSave()
	Government.Sync()
end

function Government:Start()
	hook.Add("DRPStorageReady", "DRP.Government.Load", function() Government.Load() end)
	if DRP.Storage.IsAvailable() then Government.Load() end
end

function Government:Stop()
	Government.Save()
	hook.Remove("DRPStorageReady", "DRP.Government.Load")
	for _, name in ipairs({ "Sync", "Save", "Phase", "RetryElection", "ConfidenceDue", "Lottery", "ElectionReady" }) do timer.Remove("DRP.Government." .. name) end
end

queueElectionCheck = function(delay)
	if IsValid(Government.CurrentMayor()) or Government.Phase ~= PHASE_IDLE then return end
	timer.Create("DRP.Government.ElectionReady", delay or 5, 1, function()
		if not IsValid(Government.CurrentMayor()) and Government.Phase == PHASE_IDLE and next(DRP.Players.BySteamID) ~= nil then Government.StartElection() end
	end)
end

hook.Add("DRPPlayerReady", "DRP.Government.Vacancy", function() queueElectionCheck(5) end)

hook.Add("DRPJobChanged", "DRP.Government.MayorJob", function(ply, previous, current)
	if Government.AssigningMayor then return end
	if current == DRP.Job.MAYOR then Government.AssignMayor(ply) return end
	if previous == DRP.Job.MAYOR and ply == Government.Mayor then
		Government.Mayor = nil
		Government.Phase, Government.Deadline = PHASE_IDLE, 0
		timer.Remove("DRP.Government.Phase")
		timer.Remove("DRP.Government.ConfidenceDue")
		Government.Sync()
		queueElectionCheck(5)
	end
end)

hook.Add("PlayerDisconnected", "DRP.Government.Disconnect", function(ply)
	if Government.DatabaseDirty then Government.Save() end
	if ply == Government.Mayor then
		Government.Mayor = nil
		Government.Phase, Government.Deadline = PHASE_IDLE, 0
		timer.Remove("DRP.Government.Phase")
		timer.Remove("DRP.Government.ConfidenceDue")
		Government.Sync()
		queueElectionCheck(5)
	end
end)
