local PVP = {
	SightGrace = 12,
	SightDistance = 2200,
	-- A witnessed offence does not disappear because the suspect briefly ducks
	-- behind cover. Pursuit uses cheap distance checks and only re-traces at
	-- these bounded deadline intervals.
	PursuitGrace = 8,
	PursuitRadius = 1400,
	PursuitMemory = 45,
	-- One discovery trace at most per 20-tick server frame.
	ScanInterval = 0.05,
	CellSize = 768,
	GridRefreshInterval = 0.5,
	NextGridRefresh = 0,
	DiscoveryTimeBudget = 0.0003,
	DiscoveryTraceLimit = 1,
	DiscoveryCandidateLimit = 128,
	DiscoveryQueues = {},
	DiscoveryQueueByOfficer = setmetatable({}, { __mode = "k" }),
	DiscoveryQueueCursor = 0,
	OfficerCells = {},
	SuspectCells = {},
	SightingBatchWindow = 0.35,
	PendingSightings = setmetatable({}, { __mode = "k" }),
	PendingSightingPairs = {},
	WitnessQueue = {},
	WitnessQueueHead = 1,
	WitnessEventLifetime = 1,
	WitnessQueueCapacity = 512,
	WitnessSkipBudget = 32,
	ActiveSightings = {},
	ActiveSightingIndex = {},
	OfficerList = {},
	OfficerIndex = setmetatable({}, { __mode = "k" }),
	ArmedSuspects = {},
	SuspectIndex = setmetatable({}, { __mode = "k" }),
	DamageEvidenceThrottle = {},
	TraceData = { mask = MASK_VISIBLE_AND_NPCS },
	TraceResult = {},
	LastScanStats = { candidates = 0, discovery_traces = 0, witness_traces = 0, active_traces = 0, cells = 0 },
	IgnoredWeapons = {
		weapon_physgun = true,
		weapon_physcannon = true,
		gmod_tool = true,
		gmod_camera = true,
		weapon_fists = true,
		keys = true,
		pocket = true,
		weapon_drp_keys = true,
		weapon_drp_pocket = true,
		weapon_drp_arrest = true,
		weapon_drp_taser = true,
		weapon_drp_cuffs = true,
		weapon_medkit = true,
		weapon_drp_medkit = true,
		weapon_drp_defibrillator = true,
		ephone = true,
		weapon_drp_mayor_tablet = true
	}
}

DRP.PVP = PVP
DRP.Services.Register("pvp", PVP)

DRP.Incidents.RegisterType("pvp", {
	initial = "active",
	transitions = { active = { escalated = true } },
	outcomes = { default = { winner = "instigator", loser = "victim" } }
})

DRP.Incidents.RegisterType("mob_boss_assault", {
	initial = "active",
	outcomes = {
		instigator_victory = { winner = "instigator", loser = "victim" },
		victim_victory = { winner = "victim", loser = "instigator" },
		default = { winner = "victim", loser = "instigator" }
	},
	onParticipantUnavailable = function(incident, ply, resolution, detail)
		if ply == incident.instigator then
			DRP.Incidents.Resolve(incident, "victim_victory",
				detail or "The Mob Boss became unavailable")
			return true
		end
		if ply ~= incident.victim then return false end

		-- A police assault is team-owned. Keep it active by promoting another
		-- participating officer when the original officer dies or disconnects.
		if incident.metadata and incident.metadata.target_scope == "police" then
			for _, participant in ipairs(incident.participants or {}) do
				local candidate = participant.player
				if candidate ~= ply and IsValid(candidate) and candidate:IsPlayer()
					and candidate:Alive() and candidate:DRPReady()
					and candidate:DRPJob().isPolice == true
					and incident.participantSides[candidate] == "victim" then
					incident.victim = candidate
					DRP.Incidents.RemoveParticipant(incident, ply,
						detail or "Original police representative became unavailable")
					DRP.Incidents.AddEvidence(incident, "police_representative_changed",
						candidate, nil, "Police team incident remains active")
					return true
				end
			end
		end

		DRP.Incidents.Resolve(incident, "instigator_victory",
			detail or "The assault target became unavailable")
		return true
	end
})

DRP.Incidents.RegisterType("police_weapon_sighting", {
	initial = "nonlethal_required",
	transitions = {
		nonlethal_required = { suspect_retaliation_authorized = true, lethal_force_authorized = true },
		suspect_retaliation_authorized = { lethal_force_authorized = true }
	},
	onDeadline = function(incident)
		return PVP:RevalidateSightingDeadline(incident)
	end,
	outcomes = {
		suspect_arrested = { winner = "instigator", loser = "victim" },
		default = { winner = "victim", loser = "instigator" }
	}
})

local function reasonKey(first, second, key)
	local firstID, secondID = first:SteamID64(), second:SteamID64()
	if firstID > secondID then firstID, secondID = secondID, firstID end
	return string.sub(tostring(key or "external"), 1, 48) .. ":" .. firstID .. ":" .. secondID
end

local function rolePlayer(incident, role)
	for _, participant in ipairs(incident.participants) do
		if participant.role == role then return participant.player end
	end
end

local function incidentSide(incident, ply)
	if not incident or not IsValid(ply) then return nil end
	local sharedSide = incident.participantSides and incident.participantSides[ply]
	if sharedSide then return sharedSide end
	if incident.instigator == ply then return "instigator" end
	if incident.victim == ply then return "victim" end
end

local function findReason(first, second, key)
	local wanted = reasonKey(first, second, key)
	return DRP.Incidents.FindReasonKey(wanted)
end

local function incidentAllows(incident, actor, target)
	for _, grant in ipairs(incident.permissions.damage or {}) do
		if grant.actor == actor and grant.target == target and (not grant.expires or grant.expires > CurTime()) then return true end
	end
	return false
end

local function inAdminMode(ply)
	return IsValid(ply) and DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(ply)
end

local function setReason(attacker, target, key, duration, label, oneWay)
	if not IsValid(attacker) or not attacker:IsPlayer() or not IsValid(target) or not target:IsPlayer() or attacker == target then return false end
	duration = math.Clamp(tonumber(duration) or PVP.SightGrace, 0.25, 3600)
	label = string.sub(tostring(label or "PvP condition met"), 1, 160)
	local incident = findReason(attacker, target, key)
	if not incident then
		incident = DRP.Incidents.Create("pvp", {
			reason = label,
			instigator = attacker,
			victim = target,
			participants = { suspect = attacker, victim = target },
			deadline = CurTime() + duration,
			metadata = { reason_key = reasonKey(attacker, target, key), external_key = tostring(key or "external") }
		})
	else
		incident.reason = label
		DRP.Incidents.SetDeadline(incident, CurTime() + duration)
	end
	if not incident then return false end

	DRP.Incidents.Grant(incident, "damage", attacker, target, label, CurTime() + duration)
	if oneWay then
		DRP.Incidents.Revoke(incident, "damage", target, attacker)
	else
		DRP.Incidents.Grant(incident, "damage", target, attacker, label, CurTime() + duration)
	end
	DRP.Incidents.AddEvidence(incident, oneWay and "one_way_pvp_granted" or "mutual_pvp_granted", attacker, target, label)
	return true, incident
end

-- Compatibility API for future modules: all grants now become incidents.
function PVP.Enable(first, second, key, duration, label)
	return setReason(first, second, key, duration, label, false)
end

function PVP.EnableOneWay(attacker, target, key, duration, label)
	return setReason(attacker, target, key, duration, label, true)
end

function PVP.Refresh(first, second, key, duration, label)
	local incident = findReason(first, second, key)
	if not incident then return PVP.Enable(first, second, key, duration, label) end
	local oneWay = not incidentAllows(incident, second, first)
	return setReason(first, second, key, duration, label or incident.reason, oneWay)
end

function PVP.RefreshOneWay(attacker, target, key, duration, label)
	return setReason(attacker, target, key, duration, label, true)
end

function PVP.Disable(first, second, key, endReason)
	if not IsValid(first) or not IsValid(second) then return false end
	local incident = findReason(first, second, key)
	if not incident then return false end
	return DRP.Incidents.Resolve(incident, "permission_revoked", endReason or "PvP permission revoked")
end

function PVP.IsEnabled(first, second)
	if not IsValid(first) or not IsValid(second) then return false end
	if DRP.PVPConsent and DRP.PVPConsent.Allows(first, second) then return true end
	return DRP.Incidents.FindPair(first, second) ~= nil
end

function PVP.JobHasUniversalOffense(job)
	return istable(job) and job.key == "mob_boss"
end

function PVP:HasStandingDirectionalPermission(attacker, victim)
	return IsValid(attacker)
		and attacker:IsPlayer()
		and IsValid(victim)
		and victim:IsPlayer()
		and attacker ~= victim
		and attacker:DRPReady()
		and victim:DRPReady()
		and not inAdminMode(attacker)
		and not inAdminMode(victim)
		and self.JobHasUniversalOffense(attacker:DRPJob())
end

local function mobBossAssaultReasonKey(boss, victim)
	local scope = victim:DRPJob().isPolice and "police" or victim:SteamID64()
	return "mob_boss_assault:" .. boss:SteamID64() .. ":" .. scope, scope
end

local function validAssaultParticipant(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:Alive() and ply:DRPReady() and not inAdminMode(ply)
end

local function addMobBossAssaultTeams(incident, boss, victim, targetScope)
	if not incident or not DRP.Incidents.Get(incident.id) then return false end
	incident.participantSides = incident.participantSides or setmetatable({}, { __mode = "k" })
	incident.participantSides[boss] = "instigator"
	incident.participantSides[victim] = "victim"

	for _, candidate in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do
		if validAssaultParticipant(candidate) and candidate ~= victim then
			local job = candidate:DRPJob()
			if candidate ~= boss and job.key == "gangster" then
				DRP.Incidents.AddParticipant(incident,
					"gangster_" .. candidate:EntIndex(), candidate, "instigator")
			elseif targetScope == "police" and candidate ~= boss and job.isPolice == true then
				DRP.Incidents.AddParticipant(incident,
					"police_" .. candidate:EntIndex(), candidate, "victim")
			end
		end
	end
	return true
end

local function grantMobBossAssaultCombat(incident)
	if not incident or not DRP.Incidents.Get(incident.id)
		or not IsValid(incident.instigator) or not IsValid(incident.victim) then return false end
	local reason = incident.metadata.target_scope == "police"
		and "The Mob Boss attacked police; gang and police team PvP is active"
		or "The Mob Boss attacked this player; the gang and target may fight"
	DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE,
		incident.instigator, incident.victim, reason)
	DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE,
		incident.victim, incident.instigator, reason)
	return true
end

function PVP.BeginMobBossAssault(boss, victim, damage)
	if not self:HasStandingDirectionalPermission(boss, victim) then return nil end
	if damage and damage:GetDamage() <= 0 then return nil end
	local reasonKey, targetScope = mobBossAssaultReasonKey(boss, victim)
	local incident = DRP.Incidents.FindReasonKey(reasonKey)
	if not incident then
		local reason = targetScope == "police"
			and "Mob Boss damaged a police officer"
			or ("Mob Boss damaged " .. victim:DRPName())
		incident = DRP.Incidents.Create("mob_boss_assault", {
			reason = reason,
			instigator = boss,
			victim = victim,
			participants = { suspect = boss, victim = victim },
			teamShare = false,
			metadata = {
				reason_key = reasonKey,
				target_scope = targetScope,
				first_damage = damage and math.max(0, math.floor(damage:GetDamage())) or 0
			}
		})
		if not incident then return nil end
		DRP.Incidents.HoldOpen(incident, reason)
	end

	addMobBossAssaultTeams(incident, boss, victim, targetScope)
	grantMobBossAssaultCombat(incident)
	DRP.Incidents.AddEvidence(incident, "mob_boss_assault_damage", boss, victim,
		(damage and math.max(0, math.floor(damage:GetDamage())) or 0) .. " damage initiated team PvP")
	DRP.Incidents.Sync(incident, nil, true)

	for _, participant in ipairs(incident.participants) do
		local ply = participant.player
		if IsValid(ply) then
			DRP.Net.Notify(ply, targetScope == "police"
				and ("Mob Boss assault #" .. incident.id .. ": gang versus police PvP is active.")
				or ("Mob Boss assault #" .. incident.id .. ": the gang and "
					.. victim:DRPName() .. " may now damage each other."), 2)
		end
	end
	return incident
end

function PVP.RefreshMobBossAssaultMembership(ply)
	if not validAssaultParticipant(ply) then return end
	local job = ply:DRPJob()
	if job.key ~= "gangster" and job.isPolice ~= true then return end
	for _, incident in pairs(DRP.Incidents.ByType.mob_boss_assault or {}) do
		if DRP.Incidents.Get(incident.id)
			and ((job.key == "gangster")
				or (job.isPolice == true and incident.metadata.target_scope == "police")) then
			addMobBossAssaultTeams(incident, incident.instigator, incident.victim,
				incident.metadata.target_scope)
			grantMobBossAssaultCombat(incident)
		end
	end
end

function PVP.CanDamage(attacker, victim)
	-- Physical custody is stronger than an earlier retaliation grant. Stale
	-- incident, consent and standing-role permissions cannot bypass handcuffs.
	if DRP.Legal and (DRP.Legal.IsCuffed(attacker) or DRP.Legal.Arrested[attacker]
		or DRP.Legal.IsCuffed(victim) or DRP.Legal.Arrested[victim]) then
		return false, DRP.Incidents.FindPair(attacker, victim)
	end
	-- A kidnapping's captive phase is deliberately asymmetric and supersedes
	-- consent plus the Mob Boss standing permission. The victim may retaliate,
	-- but the kidnapper must wait for the server-owned ten-minute transition.
	local kidnapping = DRP.Incidents.FindPair(attacker, victim, "kidnapping")
	if kidnapping and kidnapping.state == "captive" and attacker == kidnapping.instigator
		and victim == kidnapping.victim then return false, kidnapping end
	-- Once created, this explicit team incident supersedes the ordinary police
	-- non-lethal sighting restriction for its registered combatants.
	local bossAssault = DRP.Incidents.FindPair(attacker, victim, "mob_boss_assault")
	if bossAssault then
		local assaultAllowed, grant = DRP.Incidents.CanInIncident(
			bossAssault, attacker, victim, DRP.IncidentAction.DAMAGE)
		if assaultAllowed then return true, bossAssault, grant end
	end
	-- The Mob Boss owns the initiating hit. No incident exists before this
	-- directional permission is exercised.
	if PVP:HasStandingDirectionalPermission(attacker, victim) then return true end
	local policeIncident = DRP.Incidents.FindPair(attacker, victim, "police_weapon_sighting")
	if policeIncident and (policeIncident.state == "nonlethal_required"
		or policeIncident.state == "suspect_retaliation_authorized")
		and incidentSide(policeIncident, attacker) == "instigator"
		and incidentSide(policeIncident, victim) == "victim" then
		return false, policeIncident
	end
	if DRP.PVPConsent then
		local allowed, incident = DRP.PVPConsent.Allows(attacker, victim)
		if allowed then return true, incident end
	end
	-- Normal incident grants take precedence so mutual PvP retains its incident,
	-- evidence and resolution. The Mob Boss permission is only the directional
	-- fallback when no ordinary attacker -> victim grant exists.
	local allowed, incident, grant = DRP.Incidents.Can(attacker, victim, "damage")
	if allowed then return true, incident, grant end
	return false
end

function PVP.CustodySecured(incident, officer, suspect)
	if not incident or not DRP.Incidents.Get(incident.id) or not IsValid(suspect) then return false end
	-- Remove both directions involving this detained suspect. Uncuffed teammates
	-- keep their own shared incident permissions.
	DRP.Incidents.Revoke(incident, DRP.IncidentAction.DAMAGE, suspect, nil)
	DRP.Incidents.Revoke(incident, DRP.IncidentAction.DAMAGE, nil, suspect)
	incident.metadata = incident.metadata or {}
	incident.metadata.custody_secured_at = CurTime()
	DRP.Incidents.AddEvidence(incident, "pvp_suspended_for_custody", officer, suspect,
		"Damage permissions involving the handcuffed suspect were revoked")
	return true
end

function PVP.CanAction(actor, target, action)
	return DRP.Incidents.Can(actor, target, action)
end

local function activateMutualPolicePVP(incident, officer, suspect, reason, evidence)
	if not incident or incident.state == "lethal_force_authorized" then return false end
	local deadline = CurTime() + PVP.SightGrace
	if not DRP.Incidents.Transition(incident, "lethal_force_authorized", reason) then return false end
	DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, officer, suspect, reason, deadline + 0.5)
	DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, suspect, officer, reason, deadline + 0.5)
	DRP.Incidents.SetDeadline(incident, deadline, true)
	DRP.Incidents.AddEvidence(incident, evidence, suspect, officer, reason)
	if evidence == "mutual_pvp_after_fire_and_taser" then
		DRP.Net.Notify(officer, suspect:DRPName() .. " had already fired. Your taser attempt activated mutual PvP.", 2)
		DRP.Net.Notify(suspect, officer:DRPName() .. " attempted a taser after you fired. Mutual PvP is now active.", 2)
	else
		DRP.Net.Notify(officer, suspect:DRPName() .. " fired after your taser attempt. Mutual PvP is now active.", 2)
		DRP.Net.Notify(suspect, "You fired after " .. officer:DRPName() .. "'s taser attempt. Mutual PvP is now active.", 2)
	end
	return true
end

function PVP.SuspectFired(suspect, trigger)
	if not IsValid(suspect) or inAdminMode(suspect)
		or (DRP.Legal and (DRP.Legal.IsCuffed(suspect) or DRP.Legal.Arrested[suspect])) then return end
	for _, incident in pairs(DRP.Incidents.ByPlayer[suspect] or {}) do
		if incident.type == "police_weapon_sighting" and incidentSide(incident, suspect) == "victim"
			and (incident.state == "nonlethal_required" or incident.state == "suspect_retaliation_authorized") then
			local officer = rolePlayer(incident, "officer")
			if IsValid(officer) and not inAdminMode(officer) then
				incident.metadata = incident.metadata or {}
				local now = CurTime()
				incident.metadata.suspect_fired_at = incident.metadata.suspect_fired_at or now
				if (tonumber(incident.metadata.last_suspect_fire_evidence) or 0) <= now - 0.75 then
					incident.metadata.last_suspect_fire_evidence = now
					DRP.Incidents.AddEvidence(incident, incident.state == "suspect_retaliation_authorized"
						and "suspect_fired_after_taser" or "suspect_fired_before_taser", suspect, officer,
						trigger or "weapon fired")
				end
				if incident.state == "suspect_retaliation_authorized" then
					activateMutualPolicePVP(incident, officer, suspect,
						"Suspect fired after a police taser attempt; mutual PvP is authorized",
						"mutual_pvp_after_taser_and_fire")
				end
			end
		end
	end
end

-- A taser attempt gives the suspect a one-way right to retaliate. The officer
-- receives lethal permission only after the same suspect has also fired.
function PVP.TaserAttempt(officer, suspect)
	if not IsValid(officer) or not IsValid(suspect) or inAdminMode(officer) or inAdminMode(suspect) then return false end
	local incident = DRP.Incidents.FindPair(officer, suspect, "police_weapon_sighting")
	if not incident or incident.state ~= "nonlethal_required"
		or incidentSide(incident, officer) ~= "instigator" or incidentSide(incident, suspect) ~= "victim" then return false end
	incident.metadata = incident.metadata or {}
	incident.metadata.taser_attempted_at = CurTime()
	DRP.Incidents.AddEvidence(incident, "police_taser_attempt", officer, suspect, "Taser attempted")
	if incident.metadata.suspect_fired_at then
		return activateMutualPolicePVP(incident, officer, suspect,
			"Police attempted a taser after the suspect fired; mutual PvP is authorized",
			"mutual_pvp_after_fire_and_taser")
	end
	local reason = "Police attempted a taser; the suspect may retaliate one-way"
	local deadline = CurTime() + PVP.SightGrace
	if not DRP.Incidents.Transition(incident, "suspect_retaliation_authorized", reason) then return false end
	DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, suspect, officer, reason, deadline + 0.5)
	DRP.Incidents.Revoke(incident, DRP.IncidentAction.DAMAGE, officer, suspect)
	DRP.Incidents.SetDeadline(incident, deadline, true)
	DRP.Net.Notify(officer, "Taser attempted. " .. suspect:DRPName() .. " may retaliate, but you gain lethal permission only if they fire.", 2)
	DRP.Net.Notify(suspect, officer:DRPName() .. " attempted to tase you. You may now retaliate against that officer.", 2)
	return true, incident
end

-- Compatibility name for callers outside the legal service. Cuffs deliberately
-- do not change damage permissions.
function PVP.NonLethalAttempt(officer, suspect, method)
	if method ~= "taser" then return false end
	return PVP.TaserAttempt(officer, suspect)
end

function PVP.ClearPlayer(ply, reason)
	local affected = {}
	for _, incident in pairs(DRP.Incidents.ByPlayer[ply] or {}) do
		if (incident.type == "pvp" or incident.type == "police_weapon_sighting") then
			affected[#affected + 1] = incident
		end
	end
	for _, incident in ipairs(affected) do
		if DRP.Incidents.Get(incident.id) then
			if incident.instigator == ply or incident.victim == ply then
				DRP.Incidents.Resolve(incident, "participant_unavailable", reason or "Participant unavailable")
			else
				DRP.Incidents.RemoveParticipant(incident, ply, reason or "Team participant unavailable")
			end
		end
	end
end

local function isArmed(ply, weapon)
	weapon = IsValid(weapon) and weapon or ply:GetActiveWeapon()
	if not IsValid(weapon) then return false end
	-- A drawn SWEP is armed unless it is explicitly marked as harmless.  Clip and
	-- ammo metadata cannot be used here: melee, scripted and unlimited-ammo
	-- weapons commonly report Clip1() == -1 and omit Primary.Ammo entirely.
	return PVP.IgnoredWeapons[string.lower(weapon:GetClass())] ~= true
end

local function removeIndexed(list, index, ply)
	local position = index[ply]
	if not position then return end
	local last = table.remove(list)
	index[ply] = nil
	if last and last ~= ply then list[position] = last index[last] = position end
end

local function addIndexed(list, index, ply)
	if index[ply] then return end
	list[#list + 1] = ply
	index[ply] = #list
end

function PVP.EnsureScanTimer()
	if timer.Exists("DRP.PVP.Scan") then return end
	timer.Create("DRP.PVP.Scan", PVP.ScanInterval, 0, function() PVP:Scan() end)
end

function PVP.RefreshPlayer(ply, weapon)
	removeIndexed(PVP.OfficerList, PVP.OfficerIndex, ply)
	removeIndexed(PVP.ArmedSuspects, PVP.SuspectIndex, ply)
	PVP.NextGridRefresh = 0
	if not IsValid(ply) or not ply:Alive() or not ply:DRPReady() or inAdminMode(ply) then return end
	if ply:DRPJob().isPolice then
		addIndexed(PVP.OfficerList, PVP.OfficerIndex, ply)
	elseif not ply:GetNW2Bool("DRPGunLicense", false) and isArmed(ply, weapon) then
		addIndexed(PVP.ArmedSuspects, PVP.SuspectIndex, ply)
	end
	if #PVP.OfficerList > 0 and #PVP.ArmedSuspects > 0 then PVP.EnsureScanTimer() end
end

function PVP.RemovePlayer(ply)
	removeIndexed(PVP.OfficerList, PVP.OfficerIndex, ply)
	removeIndexed(PVP.ArmedSuspects, PVP.SuspectIndex, ply)
	PVP.NextGridRefresh = 0
end

local function deferredRefresh(ply)
	timer.Simple(0, function() if IsValid(ply) then PVP.RefreshPlayer(ply) end end)
end

local function deferredMobBossAssaultRefresh(ply)
	timer.Simple(0, function()
		if IsValid(ply) then PVP.RefreshMobBossAssaultMembership(ply) end
	end)
end

local function visibilityGeometry(officer, target)
	local startPosition = officer:EyePos()
	local targetPosition = target:WorldSpaceCenter()
	local offset = targetPosition - startPosition
	if offset:LengthSqr() > PVP.SightDistance * PVP.SightDistance then return nil end
	if officer.TestPVS and not officer:TestPVS(target) then return nil end
	local direction = offset:GetNormalized()
	local halfFOV = math.Clamp(officer:GetFOV() * 0.5, 10, 90)
	if officer:EyeAngles():Forward():Dot(direction) < math.cos(math.rad(halfFOV)) then return nil end
	return startPosition, targetPosition
end

local function traceVisible(officer, target, startPosition, targetPosition)
	local data, result = PVP.TraceData, PVP.TraceResult
	data.start, data.endpos, data.filter = startPosition, targetPosition, officer
	table.Empty(result)
	data.output = result
	util.TraceLine(data)
	return result.Entity == target
end

local function witnessTraceVisible(candidate)
	local data, result = PVP.TraceData, PVP.TraceResult
	data.start, data.endpos, data.filter = candidate.startPosition, candidate.targetPosition, candidate.officer
	table.Empty(result)
	data.output = result
	util.TraceLine(data)
	return result.Fraction >= 0.98 or result.Entity == candidate.suspect or result.Entity == candidate.victim
end

function PVP:QueueWitnessedOffence(kind, suspect, victim, incident, context)
	if not IsValid(suspect) or not suspect:IsPlayer() or not IsValid(victim) or not victim:IsPlayer()
		or inAdminMode(suspect) or inAdminMode(victim)
		or not incident or not DRP.Incidents.Get(incident.id) then return false end
	kind = string.sub(string.lower(string.Trim(tostring(kind or ""))), 1, 48)
	if kind == "" then return false end

	if self.WitnessQueueHead > 128 then
		local compacted = {}
		for index = self.WitnessQueueHead, #self.WitnessQueue do compacted[#compacted + 1] = self.WitnessQueue[index] end
		self.WitnessQueue, self.WitnessQueueHead = compacted, 1
	end
	local queued, now = 0, CurTime()
	for _, officer in ipairs(self.OfficerList) do
		if (#self.WitnessQueue - self.WitnessQueueHead + 1) >= self.WitnessQueueCapacity then break end
		if IsValid(officer) and officer:Alive() and officer:DRPReady() and officer:DRPJob().isPolice and not inAdminMode(officer) then
			local startPosition, targetPosition = visibilityGeometry(officer, suspect)
			if startPosition then
				self.WitnessQueue[#self.WitnessQueue + 1] = {
					kind = kind,
					officer = officer,
					suspect = suspect,
					victim = victim,
					incidentID = incident.id,
					context = istable(context) and table.Copy(context) or {},
					startPosition = Vector(startPosition.x, startPosition.y, startPosition.z),
					targetPosition = Vector(targetPosition.x, targetPosition.y, targetPosition.z),
					expires = now + self.WitnessEventLifetime
				}
				queued = queued + 1
			end
		end
	end
	if queued > 0 then self.EnsureScanTimer() end
	return queued > 0, queued
end

function PVP:ScanWitnessEvents()
	local queue, head, now = self.WitnessQueue, self.WitnessQueueHead, CurTime()
	local skipped = 0
	while head <= #queue and skipped < self.WitnessSkipBudget do
		local candidate = queue[head]
		head = head + 1
		skipped = skipped + 1
		local officer, suspect, victim = candidate.officer, candidate.suspect, candidate.victim
		local incident = DRP.Incidents.Get(candidate.incidentID)
		if candidate.expires > now and incident and IsValid(officer) and officer:Alive() and officer:DRPReady()
			and officer:DRPJob().isPolice and IsValid(suspect) and IsValid(victim)
			and not inAdminMode(officer) and not inAdminMode(suspect) and not inAdminMode(victim) then
			self.WitnessQueueHead = head
			if witnessTraceVisible(candidate) then
				hook.Run("DRPPoliceWitnessedOffence", candidate.kind, officer, suspect, victim, incident, candidate.context)
			end
			if head > #queue then self.WitnessQueue, self.WitnessQueueHead = {}, 1 end
			self.LastScanStats.witness_traces = 1
			return 1
		end
	end
	if head > #queue then self.WitnessQueue, self.WitnessQueueHead = {}, 1 else self.WitnessQueueHead = head end
	self.LastScanStats.witness_traces = 0
	return 0
end

local function validSightPair(officer, suspect)
	return IsValid(officer) and IsValid(suspect) and officer:Alive() and suspect:Alive()
		and officer:DRPReady() and suspect:DRPReady()
		and not inAdminMode(officer) and not inAdminMode(suspect)
		and officer:DRPJob().isPolice == true and suspect:DRPJob().isPolice ~= true and not suspect:GetNW2Bool("DRPGunLicense", false)
end

local function validDiscoveryPair(officer, suspect)
	return validSightPair(officer, suspect)
		and PVP.OfficerIndex[officer] ~= nil and PVP.SuspectIndex[suspect] ~= nil
		and isArmed(suspect)
end

local function createWeaponIncident(officer, suspect, deferInitialSync, deadlineOffset)
	local weapon = suspect:GetActiveWeapon()
	local weaponClass = IsValid(weapon) and weapon:GetClass() or "unknown weapon"
	local reason = "Police witnessed an unlicensed firearm; non-lethal force is required"
	local incident = DRP.Incidents.Create("police_weapon_sighting", {
		reason = reason,
		instigator = officer,
		victim = suspect,
		participants = { officer = officer, suspect = suspect },
		metadata = {
			last_seen_at = CurTime(),
			pursuit = false
		},
		-- Confirmations in one notification batch are staggered by one scanner
		-- interval so their eventual revalidation traces cannot burst together.
		deadline = CurTime() + PVP.SightGrace + math.max(0, tonumber(deadlineOffset) or 0),
		deferInitialSync = deferInitialSync == true
	})
	if not incident then return end
	addIndexed(PVP.ActiveSightings, PVP.ActiveSightingIndex, incident)
	suspect:SetNW2String("DRPWantedReason", "Unlicensed firearm")
	local permissionDeadline = incident.deadline + 0.5
	DRP.Incidents.Grant(incident, DRP.IncidentAction.TASE, officer, suspect, "Non-lethal firearm response", permissionDeadline)
	DRP.Incidents.Grant(incident, DRP.IncidentAction.CUFF, officer, suspect, "Non-lethal firearm response", permissionDeadline)
	DRP.Incidents.Grant(incident, DRP.IncidentAction.ARREST, officer, suspect, "Unlicensed firearm offence", permissionDeadline)
	DRP.Incidents.Grant(incident, DRP.IncidentAction.SEARCH, officer, suspect, "Unlicensed firearm offence", permissionDeadline)
	DRP.Incidents.AddEvidence(incident, "weapon_sighted", suspect, officer, weaponClass)
	DRP.Net.Notify(suspect, officer:DRPName() .. " witnessed your unlicensed gun. Police non-lethal detention is authorized.", 2)
	return incident
end

local function sightingPairKey(officer, suspect)
	return officer:EntIndex() .. ":" .. suspect:EntIndex()
end

function PVP:QueueConfirmedSighting(officer, suspect)
	if not validDiscoveryPair(officer, suspect) or DRP.Incidents.FindPair(officer, suspect, "police_weapon_sighting") then return false end
	local pair = sightingPairKey(officer, suspect)
	if self.PendingSightingPairs[pair] then return false end
	local batch = self.PendingSightings[officer]
	if not batch then
		batch = { suspects = {}, pairs = {}, set = setmetatable({}, { __mode = "k" }), flushAt = CurTime() + self.SightingBatchWindow }
		self.PendingSightings[officer] = batch
	end
	if batch.set[suspect] then return false end
	batch.set[suspect] = true
	batch.suspects[#batch.suspects + 1] = suspect
	batch.pairs[#batch.pairs + 1] = pair
	self.PendingSightingPairs[pair] = true
	return true
end

function PVP:FlushSightingBatches(now)
	local pending = false
	for officer, batch in pairs(self.PendingSightings) do
		if not IsValid(officer) then
			for _, pair in ipairs(batch.pairs) do self.PendingSightingPairs[pair] = nil end
			self.PendingSightings[officer] = nil
		elseif batch.flushAt > now then
			pending = true
		else
			local created, names = {}, {}
			for _, pair in ipairs(batch.pairs) do self.PendingSightingPairs[pair] = nil end
			for _, suspect in ipairs(batch.suspects) do
				if IsValid(suspect) then
					if validSightPair(officer, suspect) and not DRP.Incidents.FindPair(officer, suspect, "police_weapon_sighting") then
						local incident = createWeaponIncident(officer, suspect, true, #created * self.ScanInterval)
						if incident then
							created[#created + 1] = incident
							names[#names + 1] = suspect:DRPName()
						end
					end
				end
			end
			self.PendingSightings[officer] = nil
			if #created > 0 then
				DRP.Incidents.SyncBatch(created)
				local visibleNames = {}
				for index = 1, math.min(#names, 8) do visibleNames[index] = names[index] end
				local overflow = #names > #visibleNames and (" +" .. (#names - #visibleNames) .. " more") or ""
				DRP.Net.Notify(officer, "Armed suspects detected: " .. table.concat(visibleNames, ", ") .. overflow .. ". Non-lethal detention authorized.", 2)
			end
		end
	end
	return pending
end

local function extendSighting(incident, desiredDeadline)
	DRP.Incidents.SetDeadline(incident, desiredDeadline, true)
	for action, grants in pairs(incident.permissions) do
		local snapshot = {}
		for index = 1, #grants do snapshot[index] = grants[index] end
		for _, grant in ipairs(snapshot) do
			if IsValid(grant.actor) then
				DRP.Incidents.Grant(incident, action, grant.actor, grant.target, grant.reason, desiredDeadline + 0.5)
			end
		end
	end
end

local function normalSightingReason(incident)
	if incident.state == "lethal_force_authorized" then
		return "Taser attempted and suspect fired; mutual PvP is authorized"
	elseif incident.state == "suspect_retaliation_authorized" then
		return "Police attempted a taser; suspect retaliation is authorized one-way"
	end
	return "Police witnessed an unlicensed firearm; non-lethal force is required"
end

-- Active sightings sleep for their entire grace countdown. At the deadline we
-- perform at most one revalidation trace. A failed trace can enter a bounded
-- proximity-based pursuit window, so briefly stepping behind cover cannot erase
-- an offence and no continuous eye tracing is required.
function PVP:RevalidateSightingDeadline(incident)
	if not incident or not DRP.Incidents.Get(incident.id) then return true end
	local officer, suspect = rolePlayer(incident, "officer"), rolePlayer(incident, "suspect")
	if not validSightPair(officer, suspect) then
		DRP.Incidents.Resolve(incident, "conditions_invalid", "Police offence conditions no longer valid")
		return true
	end
	if DRP.Incidents.PersistentUntilReset then
		incident.metadata = incident.metadata or {}
		incident.metadata.pursuit = false
		DRP.Incidents.HoldOpen(incident, normalSightingReason(incident))
		DRP.Incidents.AddEvidence(incident, "offence_retained", officer, suspect,
			"Witnessed offence retained until death, arrest or explicit resolution")
		return true
	end
	incident.metadata = incident.metadata or {}
	local now = CurTime()

	-- Custody is already a stronger server-owned condition than vision. Do not
	-- waste traces or drop the offence while the suspect is physically cuffed.
	if suspect:GetNW2Bool("DRPCuffed", false) then
		incident.metadata.pursuit = false
		incident.reason = normalSightingReason(incident)
		extendSighting(incident, now + 120)
		return true
	end

	local startPosition, targetPosition = visibilityGeometry(officer, suspect)
	if startPosition and traceVisible(officer, suspect, startPosition, targetPosition) then
		local regained = incident.metadata.pursuit == true
		incident.metadata.last_seen_at = now
		incident.metadata.pursuit = false
		incident.metadata.pursuit_started_at = nil
		incident.reason = normalSightingReason(incident)
		extendSighting(incident, now + self.SightGrace)
		DRP.Incidents.AddEvidence(incident, regained and "visual_contact_restored" or "sighting_revalidated",
			officer, suspect, regained and "Officer regained visual contact during pursuit" or "Suspect remained visible at grace expiry")
		if regained then
			DRP.Net.Notify(officer, "Visual contact restored with " .. suspect:DRPName() .. ". Offence timer refreshed.", 2)
			DRP.Net.Notify(suspect, officer:DRPName() .. " regained visual contact. The police offence remains active.", 2)
		end
		return true
	end

	local lastSeen = tonumber(incident.metadata.last_seen_at) or tonumber(incident.startedAt) or now
	local memoryDeadline = lastSeen + self.PursuitMemory
	local nearby = officer:GetPos():DistToSqr(suspect:GetPos()) <= self.PursuitRadius * self.PursuitRadius
	if nearby and memoryDeadline > now + 0.25 then
		local enteringPursuit = incident.metadata.pursuit ~= true
		incident.metadata.pursuit = true
		incident.metadata.pursuit_started_at = incident.metadata.pursuit_started_at or now
		incident.reason = "Police pursuit active after recent visual contact"
		extendSighting(incident, math.min(now + self.PursuitGrace, memoryDeadline))
		if enteringPursuit then
			DRP.Incidents.AddEvidence(incident, "pursuit_started", officer, suspect,
				"Visual contact lost nearby; offence retained during bounded pursuit")
			DRP.Net.Notify(officer, suspect:DRPName() .. " moved out of sight nearby. Pursuit authority remains temporarily active.", 2)
			DRP.Net.Notify(suspect, "Breaking line of sight did not clear the witnessed offence. Police pursuit remains active.", 2)
		end
		return true
	end

	local resolution = nearby and "pursuit_memory_expired" or "pursuit_range_lost"
	local detail = nearby and "Police pursuit memory expired without renewed visual contact"
		or "Suspect escaped the officer's pursuit area"
	DRP.Incidents.Resolve(incident, resolution, detail)
	return true
end

function PVP.CellCoordinates(position)
	return math.floor(position.x / PVP.CellSize), math.floor(position.y / PVP.CellSize)
end

local function cellKey(x, y)
	return x .. ":" .. y
end

local function addToCell(cells, ply)
	local x, y = PVP.CellCoordinates(ply:GetPos())
	local key = cellKey(x, y)
	local cell = cells[key]
	if not cell then
		cell = { x = x, y = y, players = {} }
		cells[key] = cell
	end
	cell.players[#cell.players + 1] = ply
end

function PVP:RebuildSpatialIndex()
	local started = DRP.Profile.Begin()
	local officerCells, suspectCells = {}, {}
	for _, officer in ipairs(self.OfficerList) do
		if IsValid(officer) and officer:Alive() and officer:DRPReady() and officer:DRPJob().isPolice then addToCell(officerCells, officer) end
	end
	for _, suspect in ipairs(self.ArmedSuspects) do
		if IsValid(suspect) and suspect:Alive() and suspect:DRPReady() and suspect:DRPJob().isPolice ~= true then addToCell(suspectCells, suspect) end
	end

	local previousQueues = self.DiscoveryQueueByOfficer or {}
	local queues, byOfficer = {}, setmetatable({}, { __mode = "k" })
	local radius = math.ceil(self.SightDistance / self.CellSize)
	local maximumDistance = self.SightDistance * self.SightDistance
	local candidateCount = 0
	for _, officer in ipairs(self.OfficerList) do
		if IsValid(officer) and officer:Alive() and officer:DRPReady() and officer:DRPJob().isPolice then
			local cellX, cellY = self.CellCoordinates(officer:GetPos())
			local queue = { officer = officer, suspects = {}, cursor = 0 }
			local previous = previousQueues[officer]
			local officerPosition = officer:EyePos()
			for offsetX = -radius, radius do
				for offsetY = -radius, radius do
					local suspectCell = suspectCells[cellKey(cellX + offsetX, cellY + offsetY)]
					if suspectCell then
						for _, suspect in ipairs(suspectCell.players) do
							local pair = sightingPairKey(officer, suspect)
							if not self.PendingSightingPairs[pair]
								and not DRP.Incidents.FindPair(officer, suspect, "police_weapon_sighting")
								and officerPosition:DistToSqr(suspect:WorldSpaceCenter()) <= maximumDistance
								and validDiscoveryPair(officer, suspect)
								and visibilityGeometry(officer, suspect) then
								queue.suspects[#queue.suspects + 1] = suspect
								candidateCount = candidateCount + 1
							end
						end
					end
				end
			end
			if #queue.suspects > 0 then
				queue.cursor = previous and (previous.cursor % #queue.suspects) or 0
				queues[#queues + 1] = queue
				byOfficer[officer] = queue
			end
		end
	end

	self.OfficerCells = officerCells
	self.SuspectCells = suspectCells
	self.DiscoveryQueues, self.DiscoveryQueueByOfficer = queues, byOfficer
	if #queues == 0 then self.DiscoveryQueueCursor = 0 else self.DiscoveryQueueCursor = self.DiscoveryQueueCursor % #queues end
	self.NextGridRefresh = CurTime() + self.GridRefreshInterval
	self.LastScanStats.cells = table.Count(officerCells) + table.Count(suspectCells)
	self.LastScanStats.candidates = candidateCount
	DRP.Profile.Finish("pvp.grid", started)
	return candidateCount
end

function PVP:ScanActive()
	local started = DRP.Profile.Begin()
	-- Compatibility/status entry point. Active incidents are revalidated once
	-- by their deadline callback and never participate in the hot scan loop.
	self.LastScanStats.active_traces = 0
	DRP.Profile.Finish("pvp.active", started)
	return 0
end

function PVP:ScanDiscovery(traceLimit)
	local started = DRP.Profile.Begin()
	local queues = self.DiscoveryQueues
	local count = #queues
	traceLimit = math.max(0, math.floor(tonumber(traceLimit) or self.DiscoveryTraceLimit))
	if count == 0 or traceLimit == 0 then
		if count == 0 then self.DiscoveryQueueCursor = 0 end
		self.LastScanStats.discovery_traces = 0
		DRP.Profile.Finish("pvp.discovery", started)
		return 0
	end
	local deadline = SysTime() + self.DiscoveryTimeBudget
	local traces, visited = 0, 0
	local visitLimit = self.DiscoveryCandidateLimit
	while visited < visitLimit and traces < traceLimit and SysTime() < deadline do
		self.DiscoveryQueueCursor = (self.DiscoveryQueueCursor % count) + 1
		local queue = queues[self.DiscoveryQueueCursor]
		local suspectCount = queue and #queue.suspects or 0
		visited = visited + 1
		if suspectCount > 0 then
			queue.cursor = (queue.cursor % suspectCount) + 1
			local officer, suspect = queue.officer, queue.suspects[queue.cursor]
			local pair = IsValid(officer) and IsValid(suspect) and sightingPairKey(officer, suspect) or ""
			if validDiscoveryPair(officer, suspect) and not self.PendingSightingPairs[pair]
				and not DRP.Incidents.FindPair(officer, suspect, "police_weapon_sighting") then
				local startPosition, targetPosition = visibilityGeometry(officer, suspect)
				if startPosition and SysTime() < deadline then
					traces = traces + 1
					if traceVisible(officer, suspect, startPosition, targetPosition) then self:QueueConfirmedSighting(officer, suspect) end
				end
			end
		end
	end
	self.LastScanStats.discovery_traces = traces
	DRP.Profile.Finish("pvp.discovery", started)
	return traces
end

function PVP:Scan()
	local started, now = DRP.Profile.Begin(), CurTime()
	local pending = self:FlushSightingBatches(now)
	if now >= self.NextGridRefresh then self:RebuildSpatialIndex() end
	local witnessTraces = self:ScanWitnessEvents()
	self:ScanDiscovery(math.max(0, self.DiscoveryTraceLimit - witnessTraces))
	if (#self.OfficerList == 0 or #self.ArmedSuspects == 0)
		and self.WitnessQueueHead > #self.WitnessQueue
		and not pending and next(self.PendingSightings) == nil then timer.Remove("DRP.PVP.Scan") end
	DRP.Profile.Finish("pvp.scan", started)
end

function PVP:Start()
	self.LastScanStats = { candidates = 0, discovery_traces = 0, witness_traces = 0, active_traces = 0, cells = 0 }
	self.OfficerCells, self.SuspectCells = {}, {}
	self.DiscoveryQueues, self.DiscoveryQueueByOfficer = {}, setmetatable({}, { __mode = "k" })
	self.DiscoveryQueueCursor, self.NextGridRefresh = 0, 0
	self.PendingSightings = setmetatable({}, { __mode = "k" })
	self.PendingSightingPairs = {}
	self.WitnessQueue, self.WitnessQueueHead = {}, 1
	self.ActiveSightings, self.ActiveSightingIndex = {}, {}
	for _, incident in pairs(DRP.Incidents.ByType.police_weapon_sighting or {}) do
		addIndexed(self.ActiveSightings, self.ActiveSightingIndex, incident)
	end
	for _, ply in ipairs(DRP.Players.List) do self.RefreshPlayer(ply) end
	if #self.OfficerList > 0 and #self.ArmedSuspects > 0 then self.EnsureScanTimer() end
end

function PVP:Stop()
	timer.Remove("DRP.PVP.Scan")
	self.OfficerList, self.ArmedSuspects = {}, {}
	self.OfficerIndex = setmetatable({}, { __mode = "k" })
	self.SuspectIndex = setmetatable({}, { __mode = "k" })
	self.OfficerCells, self.SuspectCells = {}, {}
	self.DiscoveryQueues, self.DiscoveryQueueByOfficer = {}, setmetatable({}, { __mode = "k" })
	self.DiscoveryQueueCursor, self.NextGridRefresh = 0, 0
	self.PendingSightings, self.PendingSightingPairs = setmetatable({}, { __mode = "k" }), {}
	self.WitnessQueue, self.WitnessQueueHead = {}, 1
	self.ActiveSightings, self.ActiveSightingIndex = {}, {}
end

hook.Add("DRPPlayerReady", "DRP.PVP.ReadyIndex", deferredRefresh)
hook.Add("PlayerSpawn", "DRP.PVP.SpawnIndex", deferredRefresh)
hook.Add("DRPPlayerReady", "DRP.PVP.MobBossAssaultReady", deferredMobBossAssaultRefresh)
hook.Add("PlayerSpawn", "DRP.PVP.MobBossAssaultSpawn", deferredMobBossAssaultRefresh)
hook.Add("PlayerSwitchWeapon", "DRP.PVP.WeaponIndex", function(ply, _, newWeapon)
	-- GetActiveWeapon can still be the old weapon inside this hook, so index the
	-- weapon supplied by the engine immediately, then reconcile next tick.
	PVP.RefreshPlayer(ply, newWeapon)
	deferredRefresh(ply)
end)
hook.Add("WeaponEquip", "DRP.PVP.WeaponEquipIndex", function(_, ply) deferredRefresh(ply) end)
hook.Add("PlayerDroppedWeapon", "DRP.PVP.WeaponDropIndex", deferredRefresh)
hook.Add("DRPGunLicenseChanged", "DRP.PVP.LicenseIndex", deferredRefresh)
hook.Add("DRPJobChanged", "DRP.PVP.JobIndex", function(ply)
	deferredRefresh(ply)
	deferredMobBossAssaultRefresh(ply)
end)
hook.Add("DRPAdminModeChanged", "DRP.PVP.AdminModeIndex", function(ply, active)
	if active then
		PVP.RemovePlayer(ply)
		local affected = {}
		for _, incident in pairs(DRP.Incidents.ByPlayer[ply] or {}) do
			if incident.type == "police_weapon_sighting" or incident.type == "mob_boss_assault" then
				affected[#affected + 1] = incident
			end
		end
		for _, incident in ipairs(affected) do
			if DRP.Incidents.Get(incident.id) then
				if incident.type == "mob_boss_assault" then
					local definition = DRP.Incidents.Definitions.mob_boss_assault
					local handled = definition and definition.onParticipantUnavailable
						and definition.onParticipantUnavailable(incident, ply, "admin_mode",
							"Participant entered Admin Mode")
					if not handled and DRP.Incidents.Get(incident.id) then
						DRP.Incidents.RemoveParticipant(incident, ply,
							"Removed from the assault while in Admin Mode")
					end
				elseif incident.instigator == ply or incident.victim == ply then
					DRP.Incidents.Resolve(incident, "admin_mode", "Police sighting cancelled because a primary participant entered Admin Mode")
				else
					DRP.Incidents.RemoveParticipant(incident, ply, "Removed from the incident while in Admin Mode")
				end
			end
		end
	else
		deferredRefresh(ply)
	end
end)
hook.Add("PlayerDeath", "DRP.PVP.DeathIndex", function(ply) PVP.RemovePlayer(ply) end)
hook.Add("PlayerDisconnected", "DRP.PVP.DisconnectIndex", function(ply) PVP.RemovePlayer(ply) end)

local function resolvePlayerAttacker(attacker)
	if not IsValid(attacker) then return nil end
	if attacker:IsPlayer() then return attacker end
	if attacker:IsVehicle() then
		local driver = attacker:GetDriver()
		if IsValid(driver) then return driver end
	end
	if DRP.Props and DRP.Props.Owner then
		local propOwner = DRP.Props.Owner(attacker)
		if IsValid(propOwner) then return propOwner end
	end
	local owner = attacker.GetOwner and attacker:GetOwner() or nil
	if IsValid(owner) and owner:IsPlayer() then return owner end
	local creator = attacker.GetCreator and attacker:GetCreator() or nil
	if IsValid(creator) and creator:IsPlayer() then return creator end
end

local function recordDamageEvidence(incident, event, attacker, victim, damage)
	if not incident then return end
	local throttles = PVP.DamageEvidenceThrottle[incident.id] or {}
	PVP.DamageEvidenceThrottle[incident.id] = throttles
	local key = attacker:SteamID64() .. ":" .. event
	if (throttles[key] or 0) > CurTime() then return end
	throttles[key] = CurTime() + 0.75
	local inflictor = damage and damage:GetInflictor() or attacker:GetActiveWeapon()
	local amount = damage and (math.max(0, math.floor(damage:GetDamage())) .. " damage") or "damage attempt"
	local detail = amount .. " via " .. (IsValid(inflictor) and inflictor:GetClass() or "unknown")
	DRP.Incidents.AddEvidence(incident, event, attacker, victim, detail, true)
end

hook.Add("DRPIncidentResolved", "DRP.PVP.ClearEvidenceThrottle", function(incident)
	PVP.DamageEvidenceThrottle[incident.id] = nil
	if incident.type == "police_weapon_sighting" then removeIndexed(PVP.ActiveSightings, PVP.ActiveSightingIndex, incident) end
end)

hook.Add("PlayerShouldTakeDamage", "DRP.PVP.DefaultSafe", function(victim, attacker)
	local attackingPlayer = resolvePlayerAttacker(attacker)
	if not IsValid(attackingPlayer) or attackingPlayer == victim then return end
	if PVP.CanDamage(attackingPlayer, victim) then
		-- Returning nil delegates to Sandbox's PlayerShouldTakeDamage, allowing
		-- sbox_playershurtplayers to veto a permission the incident engine has
		-- already granted. Return true so DRP remains the PvP authority.
		if cvars.Bool("sbox_godmode", false) then return false end
		return true
	end
	recordDamageEvidence(DRP.Incidents.FindPair(attackingPlayer, victim), "damage_denied", attackingPlayer, victim)
	DRP.Incidents.Deny(attackingPlayer, victim, "damage")
	return false
end)

hook.Add("EntityTakeDamage", "DRP.PVP.IndirectDamage", function(victim, damage)
	if not IsValid(victim) or not victim:IsPlayer() then return end
	local attackingPlayer = resolvePlayerAttacker(damage:GetAttacker())
	if not IsValid(attackingPlayer) then attackingPlayer = resolvePlayerAttacker(damage:GetInflictor()) end
	if not IsValid(attackingPlayer) or attackingPlayer == victim then return end
	local allowed, incident = PVP.CanDamage(attackingPlayer, victim)
	if allowed then
		if not incident and PVP:HasStandingDirectionalPermission(attackingPlayer, victim) then
			incident = PVP.BeginMobBossAssault(attackingPlayer, victim, damage)
		end
		recordDamageEvidence(incident, "damage_allowed", attackingPlayer, victim, damage)
		return
	end
	recordDamageEvidence(DRP.Incidents.FindPair(attackingPlayer, victim), "damage_denied", attackingPlayer, victim, damage)
	DRP.Incidents.Deny(attackingPlayer, victim, "damage")
	damage:SetDamage(0)
	damage:SetDamageForce(vector_origin)
	return true
end)

hook.Add("EntityFireBullets", "DRP.PVP.SuspectFired", function(entity)
	local ply = resolvePlayerAttacker(entity)
	if IsValid(ply) then PVP.SuspectFired(ply, "bullet fired") end
end)

hook.Add("KeyPress", "DRP.PVP.SuspectAttack", function(ply, key)
	if key ~= IN_ATTACK or not isArmed(ply) then return end
	local weapon = ply:GetActiveWeapon()
	if IsValid(weapon) and weapon:Clip1() ~= 0 then PVP.SuspectFired(ply, "trigger pulled") end
end)

hook.Add("PlayerDeath", "DRP.PVP.Death", function(ply) PVP.ClearPlayer(ply, "A participant died") end)
hook.Add("PlayerDisconnected", "DRP.PVP.Disconnect", function(ply) PVP.ClearPlayer(ply, "A participant disconnected") end)
hook.Add("DRPJobChanged", "DRP.PVP.JobChanged", function(ply) PVP.ClearPlayer(ply, "A participant changed role") end)
