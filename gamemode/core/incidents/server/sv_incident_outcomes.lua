local Incidents = DRP.Incidents

local function clean(value, maximum)
	return string.sub(tostring(value or ""), 1, maximum or 160)
end

function Incidents.OutcomePolicy(incidentType, resolution)
	local definition = Incidents.Definitions[tostring(incidentType or "")] or {}
	local policies = definition.outcomes or {}
	return policies[tostring(resolution or "")] or policies.default
end

function Incidents.BuildOutcome(incident, resolution, detail)
	if not istable(incident) or incident.instigator == nil or incident.victim == nil then return nil end
	local policy = Incidents.OutcomePolicy(incident.type, resolution)
	if not istable(policy) then return nil end
	local function side(name)
		if name == "instigator" then return incident.instigator end
		if name == "victim" then return incident.victim end
	end
	return {
		resolution = clean(resolution, 48),
		detail = clean(detail or resolution, 160),
		instigator = incident.instigator,
		victim = incident.victim,
		winner = side(policy.winner),
		loser = side(policy.loser),
		winner_side = policy.winner,
		loser_side = policy.loser
	}
end

function Incidents.OutcomeRewards(outcome)
	if not istable(outcome) then return {} end
	local rewards, seen = {}, {}
	local function add(ply, amount, role)
		if ply == nil or seen[ply] then return end
		seen[ply] = true
		rewards[#rewards + 1] = { player = ply, amount = amount, role = role }
	end
	add(outcome.winner, 38, "winning")
	add(outcome.loser, 26, "participation")
	return rewards
end

function Incidents.AwardOutcomeXP(incident, outcome)
	if not istable(incident) or not istable(outcome) or incident.xpOutcomeAwarded then return false end
	if not DRP.Experience or not isfunction(DRP.Experience.Add) then return false end
	local awarded = false
	local function grant(ply, amount, role)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		if DRP.Experience:Add(ply, amount, "incident:" .. incident.type, "Outcome: " .. outcome.resolution, true) then
			DRP.Net.Notify(ply, "+" .. amount .. " XP — " .. role .. " outcome for incident #" .. incident.id .. ".", 1)
			awarded = true
		end
	end
	for _, reward in ipairs(Incidents.OutcomeRewards(outcome)) do grant(reward.player, reward.amount, reward.role) end
	if awarded then
		incident.xpOutcomeAwarded = true
		incident.xpAwarded = true
	end
	return awarded
end
