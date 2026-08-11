local Hits = { NextID = 1, Open = {}, ActiveByHitman = setmetatable({}, { __mode = "k" }), ActiveByTarget = setmetatable({}, { __mode = "k" }) }
DRP.Hits = Hits
DRP.Services.Register("hits", Hits)

DRP.Incidents.RegisterType("hit_contract", {
	initial = "accepted",
	outcomes = {
		target_eliminated = { winner = "instigator", loser = "victim" },
		contract_failed = { winner = "victim", loser = "instigator" },
		default = { winner = "victim", loser = "instigator" }
	},
	onDeadline = function(incident)
		for _, record in pairs(Hits.ActiveByHitman) do
			if record.incident == incident then Hits.Finish(record, false, "contract expired") return true end
		end
		return false
	end,
	onParticipantUnavailable = function(incident, ply, resolution, _, context)
		local record = Hits.ActiveByHitman[ply] or Hits.ActiveByTarget[ply]
		if record then
			local completed = resolution == "participant_died" and ply == record.target and context and context.attacker == record.hitman
			Hits.Finish(record, completed, completed and "target eliminated" or "participant unavailable")
		end
		return true
	end
})

local function findOnline(id)
	return DRP.Players.Online(id)
end

local function refund(record, reason)
	local requester = findOnline(record.requesterID)
	if IsValid(requester) then DRP.Economy.Add(requester, record.amount, "hit contract refund: " .. reason) end
end

function Hits.Create(requester, target, amount)
	amount = math.floor(tonumber(amount) or 0)
	if not IsValid(target) or target == requester or amount < 100 or amount > 50000 then DRP.Net.Notify(requester, "Usage: /hit <player> <100-50000>.", 3) return false end
	if Hits.ActiveByTarget[target] then DRP.Net.Notify(requester, "That player already has an active contract.", 3) return false end
	for _, record in pairs(Hits.Open) do if record.target == target then DRP.Net.Notify(requester, "That player already has an open contract.", 3) return false end end
	if not DRP.Economy.Take(requester, amount, "hit contract escrow", { kind = "custody", source = "hit contract escrow" }) then return false end
	local id = Hits.NextID
	Hits.NextID = id + 1
	Hits.Open[id] = { id = id, requesterID = requester:SteamID64(), requesterName = requester:DRPName(), target = target, targetID = target:SteamID64(), amount = amount, expires = CurTime() + 180 }
	DRP.Deadlines.Schedule("hit:open:" .. id, Hits.Open[id].expires, function()
		local record = Hits.Open[id]
		if record then Hits.Finish(record, false, "unaccepted contract expired") end
	end)
	DRP.Net.Notify(requester, "Hit #" .. id .. " posted for $" .. string.Comma(amount) .. ".", 1)
	for _, ply in ipairs(DRP.Players.List) do if ply:DRPHasRoleCapability("canExecuteHits") then DRP.Net.Notify(ply, "Private hit #" .. id .. " available for $" .. string.Comma(amount) .. ". Use /accepthit " .. id .. ".", 0) end end
	return true
end

function Hits.Accept(hitman, id)
	if not hitman:DRPHasRoleCapability("canExecuteHits") or Hits.ActiveByHitman[hitman] then return false end
	local record = Hits.Open[math.floor(tonumber(id) or 0)]
	if not record or not IsValid(record.target) or record.target == hitman then return false end
	Hits.Open[record.id] = nil
	DRP.Deadlines.Cancel("hit:open:" .. record.id)
	record.hitman, record.deadline = hitman, CurTime() + 300
	record.incident = DRP.Incidents.Create("hit_contract", {
		reason = "Accepted private contract #" .. record.id,
		instigator = hitman,
		victim = record.target,
		deadline = record.deadline,
		participants = { hitman = hitman, target = record.target },
		metadata = { contract_id = record.id, escrow = record.amount, conceal_from_role = "target", conceal_role = "hitman" }
	})
	DRP.Incidents.Grant(record.incident, DRP.IncidentAction.DAMAGE, hitman, record.target, "Active hit contract", record.deadline)
	Hits.ActiveByHitman[hitman], Hits.ActiveByTarget[record.target] = record, record
	DRP.Net.Notify(hitman, "Hit #" .. record.id .. " accepted. Target: " .. record.target:DRPName() .. ".", 1)
	if DRP.Audit then DRP.Audit.Log(hitman, "hit_accepted", record.target, "#" .. record.id .. " $" .. record.amount) end
	return true
end

function Hits.StartGenerated(hitman, target, objectiveKey)
	if not IsValid(hitman) or not IsValid(target) or hitman == target then return nil, "Invalid contract participants." end
	if Hits.ActiveByHitman[hitman] or Hits.ActiveByTarget[target] then return nil, "One participant already has an active hit." end
	local id = Hits.NextID
	Hits.NextID = id + 1
	local record = {
		id = id, generated = true, requesterID = "SERVER", requesterName = "Server",
		target = target, targetID = target:SteamID64(), amount = 0,
		hitman = hitman, deadline = CurTime() + 300, objectiveKey = objectiveKey
	}
	record.incident = DRP.Incidents.Create("hit_contract", {
		reason = "An anonymous contract has been accepted against you",
		instigator = hitman, victim = target, deadline = record.deadline,
		participants = { hitman = hitman, target = target }, teamShare = false,
		metadata = { contract_id = id, generated = true, conceal_from_role = "target", conceal_role = "hitman" }
	})
	if not record.incident then return nil, "Incident authority rejected the generated contract." end
	record.incident.suppressProgression = true
	DRP.Incidents.Grant(record.incident, DRP.IncidentAction.DAMAGE, hitman, target, "Server-issued hit contract", record.deadline)
	Hits.ActiveByHitman[hitman], Hits.ActiveByTarget[target] = record, record
	DRP.Net.Notify(target, "An anonymous hit contract is active against you. The contractor will be revealed only if they attack.", 2)
	return record
end

function Hits.Finish(record, success, reason)
	if not record or record.finished then return false end
	record.finished = true
	Hits.Open[record.id] = nil
	DRP.Deadlines.Cancel("hit:open:" .. record.id)
	if IsValid(record.hitman) then Hits.ActiveByHitman[record.hitman] = nil end
	if IsValid(record.target) then Hits.ActiveByTarget[record.target] = nil end
	if record.generated then
		-- Generated objectives are rewarded by DRP.Objectives; no escrow exists.
	elseif success and IsValid(record.hitman) then
		DRP.Economy.SettleTransfer(record.hitman, record.amount, "completed hit contract #" .. record.id)
		DRP.Net.Notify(record.hitman, "Hit completed. Escrow released.", 1)
	else
		refund(record, reason or "contract failed")
	end
	if record.incident and DRP.Incidents.Get(record.incident.id) then DRP.Incidents.Resolve(record.incident, success and "target_eliminated" or "contract_failed", reason or "Contract resolved") end
	if DRP.SocialObjectives and DRP.SocialObjectives.HitFinished then DRP.SocialObjectives:HitFinished(record, success, reason) end
	if DRP.Audit then DRP.Audit.Log(record.hitman, success and "hit_completed" or "hit_failed", record.target, "#" .. record.id .. " " .. tostring(reason)) end
	return true
end

function Hits.List(ply)
	local output = {}
	for id, record in pairs(Hits.Open) do output[#output + 1] = "#" .. id .. " $" .. string.Comma(record.amount) end
	table.sort(output)
	DRP.Net.Notify(ply, #output > 0 and ("Open hits: " .. table.concat(output, "  •  ")) or "There are no open hit contracts.", 0)
end

function Hits:Start()
end
function Hits:Stop()
	local records, seen = {}, {}
	for _, record in pairs(Hits.Open) do if not seen[record] then seen[record] = true records[#records + 1] = record end end
	for _, record in pairs(Hits.ActiveByHitman) do if not seen[record] then seen[record] = true records[#records + 1] = record end end
	for _, record in ipairs(records) do Hits.Finish(record, false, "server shutdown") end
end

hook.Add("EntityTakeDamage", "DRP.Hits.LethalDamage", function(victim, damage)
	if not victim:IsPlayer() then return end
	local record = Hits.ActiveByTarget[victim]
	if not record then return end
	local attacker = damage:GetAttacker()
	if attacker == record.hitman and record.incident and DRP.Incidents.Get(record.incident.id)
		and record.incident.metadata.conceal_from_role then
		record.incident.metadata.conceal_from_role = nil
		record.incident.metadata.conceal_role = nil
		DRP.Incidents.AddEvidence(record.incident, "contractor_revealed", attacker, victim, "The contractor attacked and revealed their identity", true)
		DRP.Incidents.Sync(record.incident, victim)
	end
	if attacker == record.hitman and damage:GetDamage() >= victim:Health() then Hits.Finish(record, true, "target eliminated") end
end)

hook.Add("PlayerDeath", "DRP.Hits.Death", function(victim, _, attacker)
	local asHitman = Hits.ActiveByHitman[victim]
	if asHitman then Hits.Finish(asHitman, false, "hitman died") end
	local asTarget = Hits.ActiveByTarget[victim]
	if asTarget and attacker ~= asTarget.hitman then Hits.Finish(asTarget, false, "target died to another cause") end
end)
