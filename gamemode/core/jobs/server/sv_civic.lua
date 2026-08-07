local Civic = {
	Minimum = -1000,
	Maximum = 1000,
	HealingCredit = setmetatable({}, { __mode = "k" })
}

DRP.Civic = Civic
DRP.Services.Register("civic", Civic)

local incidentAdjustments = {
	mugging = {
		payment_received = { instigator = -25 },
		victim_killed = { instigator = -70 },
		mugger_killed = { instigator = -20, victim = 5 },
		default = { instigator = -15 }
	},
	police_weapon_sighting = {
		suspect_arrested = { instigator = 25, victim = -25 }
	},
	legal_warrant = {
		suspect_arrested = { instigator = 30, victim = -30 }
	},
	lockdown_homelessness = {
		sheltered = { victim = 5 },
		suspect_arrested = { instigator = 15, victim = -10 }
	},
	hit_contract = {
		target_eliminated = { instigator = -80 },
		contract_failed = { instigator = -20 }
	},
	property_raid = {
		attackers_victory = { instigator = -40 },
		default = { instigator = -20 }
	},
	armory_raid = {
		raiders_victory = { instigator = -55 },
		default = { instigator = -30, victim = 10 }
	},
	treasury_raid = {
		raiders_victory = { instigator = -65 },
		default = { instigator = -35, victim = 10 }
	},
	forced_drugging = {
		default = { instigator = -35, victim = 5 }
	},
	kidnapping = {
		victim_rescued = { instigator = -30, victim = 5 },
		victim_released = { instigator = -30, victim = 5 },
		victim_killed = { instigator = -90 },
		kidnapper_killed = { instigator = -40, victim = 10 },
		cancelled = {},
		server_shutdown = {},
		default = { instigator = -30, victim = 5 }
	}
}

function Civic:Get(ply)
	if not IsValid(ply) then return 0 end
	return math.Clamp(math.floor(tonumber(ply.DRPCivicStandingValue) or 0), self.Minimum, self.Maximum)
end

function Civic:InitializePlayer(ply, value)
	if not IsValid(ply) then return end
	ply.DRPCivicStandingValue = math.Clamp(math.floor(tonumber(value) or 0), self.Minimum, self.Maximum)
end

function Civic:Set(ply, value, reason, silent)
	if not IsValid(ply) or not ply:IsPlayer() then return false end
	local old = self:Get(ply)
	local updated = math.Clamp(math.floor(tonumber(value) or old), self.Minimum, self.Maximum)
	if updated == old then return false end
	ply.DRPCivicStandingValue = updated
	if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.CIVIC) end
	if DRP.Economy then DRP.Economy.QueueSave(ply) end
	if not silent then
		local delta = updated - old
		DRP.Net.Notify(ply, (delta > 0 and "+" or "") .. delta .. " civic standing — " .. tostring(reason or "standing updated"), delta > 0 and 1 or 2)
	end
	hook.Run("DRPCivicStandingChanged", ply, old, updated, reason)
	return true
end

function Civic:Adjust(ply, amount, reason, silent)
	amount = math.floor(tonumber(amount) or 0)
	if amount == 0 then return false end
	return self:Set(ply, self:Get(ply) + amount, reason, silent)
end

function Civic:ApplyIncidentOutcome(incident, receipt)
	if not istable(incident) or incident.civicOutcomeApplied then return false end
	local resolution = receipt and receipt.resolution or (receipt and receipt.outcome and receipt.outcome.resolution) or "default"
	local policies = incidentAdjustments[tostring(incident.type or "")]
	if not policies then return false end
	local policy = policies[tostring(resolution or "")] or policies.default
	if not policy then return false end
	local changed = false
	if policy.instigator and IsValid(incident.instigator) then changed = self:Adjust(incident.instigator, policy.instigator, "incident #" .. incident.id .. ": " .. resolution) or changed end
	if policy.victim and IsValid(incident.victim) then changed = self:Adjust(incident.victim, policy.victim, "incident #" .. incident.id .. ": " .. resolution) or changed end
	incident.civicOutcomeApplied = true
	return changed
end

function Civic:RecordHealing(healer, target, amount, source)
	if not IsValid(healer) or not IsValid(target) or healer == target or not healer:IsPlayer() or not target:IsPlayer() then return false end
	-- The stock Half-Life medkit is the entry path into medical work. Do not
	-- award behavior from the Medic-only DRP kit, scripted health changes or
	-- self-healing: the server-side weapon wrapper supplies this source.
	if tostring(source or "") ~= "weapon_medkit" or math.floor(tonumber(amount) or 0) < 10 then return false end
	self.HealingCredit[healer] = self.HealingCredit[healer] or setmetatable({}, { __mode = "k" })
	local now = CurTime()
	if (self.HealingCredit[healer][target] or 0) > now then return false end
	self.HealingCredit[healer][target] = now + 60
	local threshold = tonumber(DRP.Jobs[DRP.Job.MEDIC].rolePath and DRP.Jobs[DRP.Job.MEDIC].rolePath.threshold) or 8
	local progress = math.min(threshold, (DRP.Roles and DRP.Roles:GetMetric(healer, "healing") or 0) + 1)
	-- Eight clean credits from neutral produce +104 standing, so completing
	-- the configured eight-event pathway can actually satisfy Medic's +100
	-- civic requirement without an unrelated government grind.
	local civicChanged = self:Adjust(healer, 13,
		string.format("HL medkit aid • Medic pathway %d/%d", progress, threshold))
	local behaviorChanged = DRP.Roles and DRP.Roles:Record(healer, "healing", 1, "repeated HL medkit aid") or false
	return civicChanged or behaviorChanged
end

hook.Add("DRPIncidentResolved", "DRP.Civic.IncidentOutcome", function(incident, receipt)
	Civic:ApplyIncidentOutcome(incident, receipt)
end)

hook.Add("DRPPlayerHealed", "DRP.Civic.Healing", function(healer, target, amount, source)
	Civic:RecordHealing(healer, target, amount, source)
end)

function Civic:Start() end
function Civic:Stop() end
