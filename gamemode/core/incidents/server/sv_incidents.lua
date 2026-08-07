local syncMessage = "drp_incident_sync_v1"
local deniedMessage = "drp_incident_denied_v1"
local deltaMessage = "drp_incident_delta_v1"
local requestMessage = "drp_incident_request_v1"
local batchMessage = "drp_incident_batch_v1"
local recordToggleMessage = "drp_incident_record_toggle_v1"

util.AddNetworkString(syncMessage)
util.AddNetworkString(deniedMessage)
util.AddNetworkString(deltaMessage)
util.AddNetworkString(requestMessage)
util.AddNetworkString(batchMessage)
util.AddNetworkString(recordToggleMessage)

local Incidents = {
	Active = {},
	ByPlayer = setmetatable({}, { __mode = "k" }),
	ByPair = {},
	ByPairType = {},
	ByType = {},
	ByReasonKey = {},
	Archive = {},
	Definitions = {},
	NextID = 1,
	ArchiveCapacity = 256,
	EvidenceCapacity = 16,
	-- Deadlines may advance a scenario phase, but an established incident and
	-- its permissions remain valid until an explicit outcome, death, arrest or
	-- participant invalidation resolves it.
	PersistentUntilReset = true,
	DeniedThrottle = setmetatable({}, { __mode = "k" }),
	RecoveryThrottle = setmetatable({}, { __mode = "k" }),
	IDBlockSize = 1024,
	ReservedUntil = 0,
	TeamShareRadius = 900,
	TeamShareCapPerSide = 8,
	TeamShareTypes = {
		pvp = true,
		police_weapon_sighting = true,
		mugging = true,
		forced_drugging = true,
		armory_raid = true,
		property_raid = true,
		treasury_raid = true
	},
	TeamSharedActions = {
		damage = true,
		tase = true,
		cuff = true,
		arrest = true,
		search = true
	}
}

local savedNextID = tonumber(file.Read("darkrp/incidents_next_id.txt", "DATA") or "")
if savedNextID then Incidents.NextID = math.Clamp(math.floor(savedNextID), 1, 4294967294) end

DRP.Incidents = Incidents
DRP.Services.Register("incidents", Incidents)

local function clean(value, maximum)
	return string.sub(tostring(value or ""), 1, maximum or 128)
end

local DELTA_STATE, DELTA_PARTICIPANTS, DELTA_PERMISSIONS, DELTA_EVIDENCE = 1, 2, 4, 8

local function identity(ply)
	if not IsValid(ply) or not ply:IsPlayer() then return "", "Unavailable" end
	return ply:SteamID64(), clean(ply:Nick(), 64)
end

local function combatTeamKey(ply)
	if not IsValid(ply) or not ply:IsPlayer() or not ply.DRPJob then return nil end
	local job = ply:DRPJob()
	if not istable(job) then return nil end
	return tostring(job.agendaGroup or ("job:" .. tostring(job.key or ply:Team())))
end

local function activeAdmin(ply)
	return DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(ply)
end

local function canShareTeamIncident(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:Alive()
		and ply.DRPReady and ply:DRPReady() and not activeAdmin(ply)
end

local function passesTeamShareFilter(incident, ply, side)
	return not isfunction(incident and incident.teamShareFilter)
		or incident.teamShareFilter(ply, side, incident) == true
end

local function hasParticipant(incident, ply)
	local role = incident.participantRoles and incident.participantRoles[ply]
	if role then return true, role end
	for _, participant in ipairs(incident.participants) do
		if participant.player == ply then
			incident.participantRoles = incident.participantRoles or setmetatable({}, { __mode = "k" })
			incident.participantRoles[ply] = participant.role
			return true, participant.role
		end
	end
	return false
end

local function pairKey(first, second)
	if not IsValid(first) or not IsValid(second) or first == second then return nil end
	local firstIndex, secondIndex = first:EntIndex(), second:EntIndex()
	if firstIndex > secondIndex then firstIndex, secondIndex = secondIndex, firstIndex end
	return firstIndex .. ":" .. secondIndex
end

local function addSet(index, key, incident)
	local set = index[key]
	if not set then set = {} index[key] = set end
	set[incident.id] = incident
end

local function removeSet(index, key, incident)
	local set = index[key]
	if not set then return end
	set[incident.id] = nil
	if next(set) == nil then index[key] = nil end
end

local function indexParticipant(incident, ply, role)
	incident.participantRoles[ply] = role
	addSet(Incidents.ByPlayer, ply, incident)
	for other in pairs(incident.participantRoles) do
		local key = pairKey(ply, other)
		if key then
			addSet(Incidents.ByPair, key, incident)
			addSet(Incidents.ByPairType, key .. "|" .. incident.type, incident)
		end
	end
end

local function unindexParticipant(incident, ply)
	for other in pairs(incident.participantRoles or {}) do
		local key = pairKey(ply, other)
		if key then
			removeSet(Incidents.ByPair, key, incident)
			removeSet(Incidents.ByPairType, key .. "|" .. incident.type, incident)
		end
	end
	removeSet(Incidents.ByPlayer, ply, incident)
	if incident.participantRoles then incident.participantRoles[ply] = nil end
end

local function indexIncident(incident)
	addSet(Incidents.ByType, incident.type, incident)
	local reasonKey = incident.metadata and incident.metadata.reason_key
	if reasonKey and reasonKey ~= "" then Incidents.ByReasonKey[reasonKey] = incident end
	for _, participant in ipairs(incident.participants) do indexParticipant(incident, participant.player, participant.role) end
end

local function unindexIncident(incident)
	for _, participant in ipairs(incident.participants) do unindexParticipant(incident, participant.player) end
	removeSet(Incidents.ByType, incident.type, incident)
	local reasonKey = incident.metadata and incident.metadata.reason_key
	if reasonKey and Incidents.ByReasonKey[reasonKey] == incident then Incidents.ByReasonKey[reasonKey] = nil end
end

local function reserveIDs()
	if Incidents.NextID <= Incidents.ReservedUntil then return true end
	local reservedUntil = math.min(4294967294, Incidents.NextID + Incidents.IDBlockSize - 1)
	file.CreateDir("darkrp")
	file.Write("darkrp/incidents_next_id.txt", tostring(math.min(4294967294, reservedUntil + 1)))
	Incidents.ReservedUntil = reservedUntil
	return true
end

local function participantNames(incident, viewer)
	local names = {}
	local viewerRole = select(2, hasParticipant(incident, viewer))
	for _, participant in ipairs(incident.participants) do
		local ply = participant.player
		if ply ~= viewer then
			local concealed = incident.metadata.conceal_from_role == viewerRole and incident.metadata.conceal_role == participant.role
			names[#names + 1] = clean(participant.role, 24) .. ": " .. (concealed and "Identity concealed" or (IsValid(ply) and clean(ply:DRPName(), 48) or "Unavailable"))
		end
	end
	return table.concat(names, "  •  ")
end

local function grantMatches(grant, actor, target)
	return grant.actor == actor and (grant.target == nil or grant.target == target)
		and (not grant.expires or grant.expires > CurTime())
end

local function indexGrant(incident, action, grant)
	local byActor = incident.permissionIndex[grant.actor]
	if not byActor then byActor = {} incident.permissionIndex[grant.actor] = byActor end
	local byAction = byActor[action]
	if not byAction then byAction = {} byActor[action] = byAction end
	byAction[grant.target or false] = grant
end

local function unindexGrant(incident, action, grant)
	if grant.deadlineKey then DRP.Deadlines.Cancel(grant.deadlineKey) grant.deadlineKey = nil end
	local byActor = incident.permissionIndex and incident.permissionIndex[grant.actor]
	local byAction = byActor and byActor[action]
	if not byAction then return end
	if byAction[grant.target or false] == grant then byAction[grant.target or false] = nil end
	if next(byAction) == nil then byActor[action] = nil end
	if next(byActor) == nil then incident.permissionIndex[grant.actor] = nil end
end

local function scheduleGrantExpiry(incident, action, grant)
	if Incidents.PersistentUntilReset then
		grant.expires = nil
		if grant.deadlineKey then DRP.Deadlines.Cancel(grant.deadlineKey) grant.deadlineKey = nil end
		return
	end
	if not grant.expires then
		if grant.deadlineKey then DRP.Deadlines.Cancel(grant.deadlineKey) grant.deadlineKey = nil end
		return
	end
	grant.deadlineKey = grant.deadlineKey or ("incident:" .. incident.id .. ":grant:" .. action .. ":" .. grant.actor:EntIndex() .. ":" .. (IsValid(grant.target) and grant.target:EntIndex() or 0))
	DRP.Deadlines.Schedule(grant.deadlineKey, grant.expires, function()
		if not Incidents.Active[incident.id] then return end
		if grant.expires and grant.expires > CurTime() then scheduleGrantExpiry(incident, action, grant) return end
		local grants = incident.permissions[action]
		if not grants then return end
		for index = #grants, 1, -1 do
			if grants[index] == grant then
				unindexGrant(incident, action, grant)
				table.remove(grants, index)
				break
			end
		end
		if #grants == 0 then incident.permissions[action] = nil end
		Incidents.Sync(incident)
	end)
end

local function scheduleIncidentDeadline(incident)
	local key = "incident:" .. incident.id .. ":deadline"
	if not incident.deadline then DRP.Deadlines.Cancel(key) return end
	DRP.Deadlines.Schedule(key, incident.deadline, function()
		if not Incidents.Active[incident.id] then return end
		if incident.deadline and incident.deadline > CurTime() then scheduleIncidentDeadline(incident) return end
		local definition = Incidents.Definitions[incident.type] or {}
		local handled = definition.onDeadline and definition.onDeadline(incident)
		if not handled and Incidents.Active[incident.id] then
			if Incidents.PersistentUntilReset then
				incident.deadline = nil
				incident.updatedAt = CurTime()
				Incidents.AddEvidence(incident, "phase_deadline_elapsed", nil, nil,
					"Incident retained until an explicit outcome, death or arrest", true)
				Incidents.QueueDelta(incident, bit.bor(DELTA_STATE, DELTA_EVIDENCE), incident.evidence[#incident.evidence])
			else
				Incidents.Resolve(incident, "deadline_expired", "Incident deadline expired")
			end
		end
	end)
end

local function permissionLines(incident, viewer)
	local lines = {}
	local viewerRole = select(2, hasParticipant(incident, viewer))
	for action, grants in pairs(incident.permissions) do
		for _, grant in ipairs(grants) do
			if grant.expires == nil or grant.expires > CurTime() then
				if grant.actor == viewer then
					local targetName = IsValid(grant.target) and grant.target:Nick() or "the incident target"
					lines[#lines + 1] = "You may " .. action:gsub("_", " ") .. " " .. clean(targetName, 48)
				elseif grant.target == viewer and IsValid(grant.actor) then
					local actorRole = select(2, hasParticipant(incident, grant.actor))
					local actorName = incident.metadata.conceal_from_role == viewerRole and incident.metadata.conceal_role == actorRole and "A concealed participant" or clean(grant.actor:DRPName(), 48)
					lines[#lines + 1] = actorName .. " may " .. action:gsub("_", " ") .. " you"
				end
			end
		end
	end
	table.sort(lines)
	return lines
end

function Incidents.RegisterType(name, definition)
	name = clean(name, 40)
	if name == "" or not istable(definition) then return false end
	if not istable(definition.outcomes) or not istable(definition.outcomes.default) then
		ErrorNoHalt("[DRP STARTUP] incident type '" .. name .. "' requires an explicit default outcome\n")
		return false
	end
	Incidents.Definitions[name] = definition
	return true
end

function Incidents.Get(id)
	return Incidents.Active[tonumber(id)]
end

function Incidents.ForPlayer(ply, incidentType)
	local found = {}
	for _, incident in pairs(Incidents.ByPlayer[ply] or {}) do
		if not incidentType or incident.type == incidentType then
			found[#found + 1] = incident
		end
	end
	table.sort(found, function(a, b) return a.id < b.id end)
	return found
end

function Incidents.FindPair(first, second, incidentType)
	local key = pairKey(first, second)
	if not key then return nil end
	local set = incidentType and Incidents.ByPairType[key .. "|" .. clean(incidentType, 40)] or Incidents.ByPair[key]
	for _, incident in pairs(set or {}) do return incident end
end

function Incidents.FindReasonKey(key)
	return Incidents.ByReasonKey[tostring(key or "")]
end

function Incidents.QueueDelta(incident, mask, evidence)
	if not incident or not Incidents.Active[incident.id] then return end
	incident.deltaMask = bit.bor(incident.deltaMask or 0, mask or 0)
	if evidence then
		incident.deltaEvidence = incident.deltaEvidence or {}
		incident.deltaEvidence[#incident.deltaEvidence + 1] = evidence
		if #incident.deltaEvidence > 4 then table.remove(incident.deltaEvidence, 1) end
	end
	if incident.deltaQueued then return end
	incident.deltaQueued = true
	timer.Simple(0, function()
		if not Incidents.Active[incident.id] then return end
		incident.deltaQueued = false
		local currentMask = incident.deltaMask or 0
		local evidenceBatch = incident.deltaEvidence or {}
		incident.deltaMask, incident.deltaEvidence = 0, nil
		if currentMask == 0 then return end
		for _, participant in ipairs(incident.participants) do
			local ply = participant.player
			if IsValid(ply) then
				net.Start(deltaMessage)
				net.WriteUInt(DRP.ProtocolVersion, 8)
				net.WriteUInt(incident.id, 32)
				net.WriteUInt(currentMask, 4)
				if bit.band(currentMask, DELTA_STATE) ~= 0 then
					net.WriteString(incident.state)
					net.WriteString(incident.reason)
					net.WriteUInt(math.Clamp(math.ceil((incident.deadline or CurTime()) - CurTime()), 0, 65535), 16)
				end
				if bit.band(currentMask, DELTA_PARTICIPANTS) ~= 0 then
					local _, role = hasParticipant(incident, ply)
					net.WriteString(clean(role or "participant", 24))
					net.WriteString(clean(participantNames(incident, ply), 160))
				end
				if bit.band(currentMask, DELTA_PERMISSIONS) ~= 0 then
					local lines = permissionLines(incident, ply)
					net.WriteUInt(math.min(#lines, 8), 4)
					for index = 1, math.min(#lines, 8) do net.WriteString(clean(lines[index], 120)) end
				end
				if bit.band(currentMask, DELTA_EVIDENCE) ~= 0 then
					net.WriteUInt(math.min(#evidenceBatch, 4), 3)
					for index = math.max(1, #evidenceBatch - 3), #evidenceBatch do
						local item = evidenceBatch[index]
						net.WriteString(clean(item.event, 40))
						net.WriteString(clean(item.detail, 120))
					end
				end
				net.Send(ply)
			end
		end
	end)
end

function Incidents.Role(incident, ply)
	local involved, role = incident and hasParticipant(incident, ply)
	return involved and role or nil
end

function Incidents.AddParticipant(incident, role, ply, side)
	if not incident or not Incidents.Active[incident.id] or not IsValid(ply) or not ply:IsPlayer() then return false end
	if hasParticipant(incident, ply) then return false end
	role = clean(role or "participant", 24)
	incident.participants[#incident.participants + 1] = { role = role, player = ply }
	if side then
		incident.participantSides = incident.participantSides or setmetatable({}, { __mode = "k" })
		incident.participantSides[ply] = side
	end
	indexParticipant(incident, ply, role)
	local participantID, participantName = identity(ply)
	incident.participantHistory[#incident.participantHistory + 1] = { role = role, steam_id = participantID, name = participantName }
	table.sort(incident.participants, function(a, b) return a.role < b.role end)
	Incidents.AddEvidence(incident, "participant_joined", ply, nil, role, true)
	Incidents.Sync(incident, ply)
	Incidents.QueueDelta(incident, bit.bor(DELTA_PARTICIPANTS, DELTA_EVIDENCE), incident.evidence[#incident.evidence])
	return true
end

function Incidents.RefreshNearbyTeams(incident)
	if not incident or not Incidents.Active[incident.id] or incident.teamShareEnabled == false
		or not Incidents.TeamShareTypes[incident.type] then return 0 end

	local instigator, victim = incident.instigator, incident.victim
	if instigator == victim or not canShareTeamIncident(instigator) or not canShareTeamIncident(victim) then return 0 end

	local instigatorTeam, victimTeam = combatTeamKey(instigator), combatTeamKey(victim)
	if not instigatorTeam or not victimTeam or instigatorTeam == victimTeam then return 0 end

	incident.participantSides = incident.participantSides or setmetatable({}, { __mode = "k" })
	incident.participantSides[instigator] = "instigator"
	incident.participantSides[victim] = "victim"

	local present = {}
	local counts = { instigator = 0, victim = 0 }
	for _, participant in ipairs(incident.participants) do
		local member = participant.player
		present[member] = true
		local side = incident.participantSides[member]
		if member ~= instigator and member ~= victim and counts[side] then counts[side] = counts[side] + 1 end
	end

	local radiusSquared = Incidents.TeamShareRadius * Incidents.TeamShareRadius
	local nearby = { instigator = {}, victim = {} }
	for _, candidate in ipairs((DRP.Players and DRP.Players.List) or {}) do
		if not present[candidate] and canShareTeamIncident(candidate) then
			local candidateTeam = combatTeamKey(candidate)
			local side, anchor
			if candidateTeam == instigatorTeam then
				side, anchor = "instigator", instigator
			elseif candidateTeam == victimTeam then
				side, anchor = "victim", victim
			end
			if side and passesTeamShareFilter(incident, candidate, side)
				and counts[side] < Incidents.TeamShareCapPerSide then
				local distance = candidate:GetPos():DistToSqr(anchor:GetPos())
				if distance <= radiusSquared then
					nearby[side][#nearby[side] + 1] = { player = candidate, distance = distance }
				end
			end
		end
	end

	local added = 0
	for _, side in ipairs({ "instigator", "victim" }) do
		table.sort(nearby[side], function(first, second) return first.distance < second.distance end)
		local available = math.max(0, Incidents.TeamShareCapPerSide - counts[side])
		for index = 1, math.min(#nearby[side], available) do
			counts[side] = counts[side] + 1
			if Incidents.AddParticipant(incident, side .. "_ally_" .. counts[side], nearby[side][index].player, side) then
				added = added + 1
			end
		end
	end

	incident.metadata = incident.metadata or {}
	incident.metadata.team_shared = incident.metadata.team_shared or added > 0
	incident.metadata.team_share_radius = Incidents.TeamShareRadius
	return added
end

function Incidents.RemoveParticipant(incident, ply, reason)
	if not incident or not Incidents.Active[incident.id] then return false end
	if IsValid(ply) then
		net.Start(syncMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteBool(false)
		net.WriteUInt(incident.id, 32)
		net.WriteString(clean(reason or "You left the incident", 120))
		net.Send(ply)
	end
	local removed = false
	unindexParticipant(incident, ply)
	if incident.participantSides then incident.participantSides[ply] = nil end
	for index = #incident.participants, 1, -1 do
		if incident.participants[index].player == ply then
			table.remove(incident.participants, index)
			removed = true
		end
	end
	if not removed then return false end
	for action, grants in pairs(incident.permissions) do
		for index = #grants, 1, -1 do
			if grants[index].actor == ply or grants[index].target == ply then
				local grant = grants[index]
				unindexGrant(incident, action, grant)
				table.remove(grants, index)
			end
		end
		if #grants == 0 then incident.permissions[action] = nil end
	end
	Incidents.AddEvidence(incident, "participant_left", ply, nil, reason or "Participant unavailable", true)
	Incidents.QueueDelta(incident, bit.bor(DELTA_PARTICIPANTS, DELTA_PERMISSIONS, DELTA_EVIDENCE), incident.evidence[#incident.evidence])
	return true
end

local function writeFullIncident(incident, ply)
	local _, role = hasParticipant(incident, ply)
	local lines = permissionLines(incident, ply)
	local evidenceStart = math.max(1, #incident.evidence - 2)
	net.WriteUInt(incident.id, 32)
	net.WriteString(incident.type)
	net.WriteString(incident.state)
	net.WriteString(incident.reason)
	net.WriteString(clean(role or "participant", 24))
	net.WriteString(clean(participantNames(incident, ply), 160))
	net.WriteUInt(math.Clamp(math.ceil((incident.deadline or CurTime()) - CurTime()), 0, 65535), 16)
	net.WriteUInt(math.min(#lines, 8), 4)
	for index = 1, math.min(#lines, 8) do net.WriteString(clean(lines[index], 120)) end
	net.WriteUInt(math.min(#incident.evidence, 3), 2)
	for index = evidenceStart, #incident.evidence do
		local evidence = incident.evidence[index]
		net.WriteString(clean(evidence.event, 40))
		net.WriteString(clean(evidence.detail, 120))
	end
end

local function sendSync(incident, recipient)
	if not incident or not Incidents.Active[incident.id] then return end
	local recipients = {}
	if IsValid(recipient) then recipients[1] = recipient
	else
		for _, participant in ipairs(incident.participants) do
			if IsValid(participant.player) then recipients[#recipients + 1] = participant.player end
		end
	end
	for _, ply in ipairs(recipients) do
		net.Start(syncMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteBool(true)
		writeFullIncident(incident, ply)
		net.Send(ply)
	end
end

function Incidents.Sync(incident, recipient, full)
	if not incident or not Incidents.Active[incident.id] then return end
	if IsValid(recipient) then sendSync(incident, recipient) return end
	if full then sendSync(incident) return end
	Incidents.QueueDelta(incident, bit.bor(DELTA_STATE, DELTA_PARTICIPANTS, DELTA_PERMISSIONS, DELTA_EVIDENCE))
end

-- Multiple independently-authoritative incidents can share one packet. This
-- keeps pair-specific permissions/outcomes while avoiding one full network
-- message per sighting when an officer discovers a nearby group.
function Incidents.SyncBatch(batch)
	if not istable(batch) or #batch == 0 then return false end
	local byRecipient = setmetatable({}, { __mode = "k" })
	for _, incident in ipairs(batch) do
		if incident and Incidents.Active[incident.id] then
			for _, participant in ipairs(incident.participants) do
				local ply = participant.player
				if IsValid(ply) then
					local list = byRecipient[ply]
					if not list then list = {} byRecipient[ply] = list end
					list[#list + 1] = incident
				end
			end
		end
	end
	for ply, incidents in pairs(byRecipient) do
		local count = math.min(#incidents, 255)
		if count > 0 then
			net.Start(batchMessage)
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.WriteUInt(count, 8)
			for index = 1, count do writeFullIncident(incidents[index], ply) end
			net.Send(ply)
		end
	end
	for _, incident in ipairs(batch) do
		if incident and incident.deferredInitialSync then
			incident.deferredInitialSync = nil
			incident.deltaMask, incident.deltaEvidence = 0, nil
		end
	end
	return true
end

local function removeFromClients(incident, resolution)
	for _, participant in ipairs(incident.participants) do
		local ply = participant.player
		if IsValid(ply) then
			net.Start(syncMessage)
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.WriteBool(false)
			net.WriteUInt(incident.id, 32)
			net.WriteString(clean(resolution, 120))
			net.Send(ply)
		end
	end
end

function Incidents.Create(incidentType, options)
	options = options or {}
	incidentType = clean(incidentType, 40)
	local definition = Incidents.Definitions[incidentType]
	if not definition then
		ErrorNoHalt("[DRP] rejected unregistered incident type '" .. incidentType .. "'\n")
		return nil
	end
	if not IsValid(options.instigator) or not options.instigator:IsPlayer() or not IsValid(options.victim) or not options.victim:IsPlayer() then
		ErrorNoHalt("[DRP] rejected incident '" .. incidentType .. "': explicit instigator and victim are required\n")
		return nil
	end
	reserveIDs()
	local incident = {
		id = Incidents.NextID,
		type = incidentType,
		state = clean(options.state or definition.initial or "active", 40),
		reason = clean(options.reason or "Incident conditions met", 160),
		startedAt = CurTime(),
		startedUnix = os.time(),
		updatedAt = CurTime(),
		deadline = tonumber(options.deadline),
		persistentUntilReset = Incidents.PersistentUntilReset,
		cooldowns = table.Copy(options.cooldowns or {}),
		metadata = table.Copy(options.metadata or {}),
		deferredInitialSync = options.deferInitialSync == true,
		instigator = options.instigator,
		victim = options.victim,
		participants = {},
		participantRoles = setmetatable({}, { __mode = "k" }),
			participantHistory = {},
			participantSides = setmetatable({}, { __mode = "k" }),
			teamShareEnabled = options.teamShare ~= false,
			teamShareFilter = isfunction(options.teamShareFilter) and options.teamShareFilter or nil,
			permissions = {},
		permissionIndex = setmetatable({}, { __mode = "k" }),
		evidence = {}
	}
	Incidents.NextID = Incidents.NextID + 1

	for role, ply in pairs(options.participants or {}) do
		if IsValid(ply) and ply:IsPlayer() then
			incident.participants[#incident.participants + 1] = { role = clean(role, 24), player = ply }
		end
	end
	if Incidents.TeamShareTypes[incidentType] and options.teamShare ~= false
		and options.instigator ~= options.victim and canShareTeamIncident(options.instigator)
		and canShareTeamIncident(options.victim) then
		local instigatorTeam, victimTeam = combatTeamKey(options.instigator), combatTeamKey(options.victim)
		if instigatorTeam and victimTeam and instigatorTeam ~= victimTeam then
			local present = {}
			for _, participant in ipairs(incident.participants) do present[participant.player] = true end
			incident.participantSides[options.instigator] = "instigator"
			incident.participantSides[options.victim] = "victim"
			local radiusSquared = Incidents.TeamShareRadius * Incidents.TeamShareRadius
			local counts = { instigator = 0, victim = 0 }
			local nearby = { instigator = {}, victim = {} }
			for _, candidate in ipairs(DRP.Players.List or {}) do
				if not present[candidate] and canShareTeamIncident(candidate) then
					local candidateTeam = combatTeamKey(candidate)
					local side, anchor
					if candidateTeam == instigatorTeam then
						side, anchor = "instigator", options.instigator
					elseif candidateTeam == victimTeam then
						side, anchor = "victim", options.victim
					end
					if side and passesTeamShareFilter(incident, candidate, side) then
						local distance = candidate:GetPos():DistToSqr(anchor:GetPos())
						if distance <= radiusSquared then
							nearby[side][#nearby[side] + 1] = { player = candidate, distance = distance }
						end
					end
				end
			end
			for _, side in ipairs({ "instigator", "victim" }) do
				table.sort(nearby[side], function(first, second) return first.distance < second.distance end)
				for index = 1, math.min(#nearby[side], Incidents.TeamShareCapPerSide) do
					local candidate = nearby[side][index].player
					counts[side] = counts[side] + 1
					present[candidate] = true
					incident.participantSides[candidate] = side
					incident.participants[#incident.participants + 1] = {
						role = side .. "_ally_" .. counts[side],
						player = candidate
					}
				end
			end
			incident.metadata.team_shared = counts.instigator + counts.victim > 0
			incident.metadata.team_share_radius = Incidents.TeamShareRadius
		end
	end
	table.sort(incident.participants, function(a, b) return a.role < b.role end)
	if #incident.participants == 0 then return nil end
	for _, participant in ipairs(incident.participants) do
		local participantID, participantName = identity(participant.player)
		incident.participantHistory[#incident.participantHistory + 1] = { role = participant.role, steam_id = participantID, name = participantName }
	end

	Incidents.Active[incident.id] = incident
	indexIncident(incident)
	scheduleIncidentDeadline(incident)
	Incidents.AddEvidence(incident, "incident_created", nil, nil, incident.reason, true)
	if options.deferInitialSync ~= true then Incidents.Sync(incident, nil, true) end
	if DRP.Audit then
		local suspect = options.participants and options.participants.suspect
		local victim = options.participants and (options.participants.victim or options.participants.officer)
		DRP.Audit.Log(suspect, "incident_started", victim, "#" .. incident.id .. " " .. incidentType .. ": " .. incident.reason)
	end
	return incident
end

function Incidents.AddEvidence(incident, event, actor, target, detail, deferSync)
	if not incident or not Incidents.Active[incident.id] then return false end
	local actorID, actorName = identity(actor)
	local targetID, targetName = identity(target)
	incident.evidence[#incident.evidence + 1] = {
		time = CurTime(),
		unix = os.time(),
		event = clean(event, 40),
		actor_id = actorID,
		actor = actorName,
		target_id = targetID,
		target = targetName,
		detail = clean(detail, 160)
	}
	if #incident.evidence > Incidents.EvidenceCapacity then table.remove(incident.evidence, 1) end
	incident.updatedAt = CurTime()
	if not deferSync then Incidents.QueueDelta(incident, DELTA_EVIDENCE, incident.evidence[#incident.evidence]) end
	return true
end

function Incidents.Grant(incident, action, actor, target, reason, expires)
	if not incident or not Incidents.Active[incident.id] or not IsValid(actor) then return false end
	if not hasParticipant(incident, actor) or (IsValid(target) and not hasParticipant(incident, target)) then return false end
	action = clean(action, 32)
	if Incidents.TeamSharedActions[action] and not incident.expandingTeamGrant and IsValid(target) then
		Incidents.RefreshNearbyTeams(incident)
		local actorSide = incident.participantSides and incident.participantSides[actor]
		local targetSide = incident.participantSides and incident.participantSides[target]
		if actorSide and targetSide and actorSide ~= targetSide then
			local actors, targets = {}, {}
			for _, participant in ipairs(incident.participants) do
				local side = incident.participantSides[participant.player]
				if side == actorSide then actors[#actors + 1] = participant.player
				elseif side == targetSide then targets[#targets + 1] = participant.player end
			end
			incident.expandingTeamGrant = true
			local granted = false
			for _, sharedActor in ipairs(actors) do
				if canShareTeamIncident(sharedActor) then
					for _, sharedTarget in ipairs(targets) do
						if canShareTeamIncident(sharedTarget) and sharedActor ~= sharedTarget then
							granted = Incidents.Grant(incident, action, sharedActor, sharedTarget, reason, expires) or granted
						end
					end
				end
			end
			incident.expandingTeamGrant = nil
			return granted
		end
	end
	local grants = incident.permissions[action] or {}
	incident.permissions[action] = grants
	for _, grant in ipairs(grants) do
		if grant.actor == actor and grant.target == target then
			grant.reason = clean(reason or incident.reason, 120)
			grant.expires = Incidents.PersistentUntilReset and nil or tonumber(expires)
			indexGrant(incident, action, grant)
			scheduleGrantExpiry(incident, action, grant)
			Incidents.QueueDelta(incident, DELTA_PERMISSIONS)
			return true
		end
	end
	grants[#grants + 1] = {
		actor = actor,
		target = IsValid(target) and target or nil,
		reason = clean(reason or incident.reason, 120),
		expires = Incidents.PersistentUntilReset and nil or tonumber(expires)
	}
	indexGrant(incident, action, grants[#grants])
	scheduleGrantExpiry(incident, action, grants[#grants])
	Incidents.QueueDelta(incident, DELTA_PERMISSIONS)
	return true
end

function Incidents.Revoke(incident, action, actor, target)
	local grants = incident and incident.permissions[clean(action, 32)]
	if not grants then return false end
	for index = #grants, 1, -1 do
		local grant = grants[index]
		if (not actor or grant.actor == actor) and (not target or grant.target == target) then
			unindexGrant(incident, clean(action, 32), grant)
			table.remove(grants, index)
		end
	end
	Incidents.QueueDelta(incident, DELTA_PERMISSIONS)
	return true
end

function Incidents.CanInIncident(incident, actor, target, action)
	if not incident or not Incidents.Active[incident.id] or not IsValid(actor) then return false end
	if not hasParticipant(incident, actor) or (IsValid(target) and not hasParticipant(incident, target)) then return false end
	action = clean(action, 32)

	-- The index is the normal fast path. The canonical grant list remains the
	-- authority and repairs the index if an entity-keyed entry was ever lost.
	local byAction = incident.permissionIndex[actor] and incident.permissionIndex[actor][action]
	local grant = byAction and (IsValid(target) and (byAction[target] or byAction[false]) or byAction[false])
	if grant and grantMatches(grant, actor, target) then return true, grant end
	for _, candidate in ipairs(incident.permissions[action] or {}) do
		if grantMatches(candidate, actor, target) then
			indexGrant(incident, action, candidate)
			return true, candidate
		end
	end
	return false
end

function Incidents.Can(actor, target, action)
	if not IsValid(actor) then return false end
	action = clean(action, 32)
	for _, incident in pairs(Incidents.ByPlayer[actor] or {}) do
		local allowed, grant = Incidents.CanInIncident(incident, actor, target, action)
		if allowed then return true, incident, grant end
	end
	return false
end

-- Use Authorize at enforcement boundaries. It performs the same lookup as
-- Can, but also gives the actor a rate-limited explanation when denied.
function Incidents.Authorize(actor, target, action)
	local allowed, incident, grant = Incidents.Can(actor, target, action)
	if allowed then return true, incident, grant end
	Incidents.Deny(actor, target, action)
	return false
end

function Incidents.SetDeadline(incident, deadline, forceSync)
	if not incident or not Incidents.Active[incident.id] then return false end
	incident.deadline = tonumber(deadline)
	incident.updatedAt = CurTime()
	scheduleIncidentDeadline(incident)
	if forceSync or (incident.nextDeadlineSync or 0) <= CurTime() then
		incident.nextDeadlineSync = CurTime() + 1
		Incidents.QueueDelta(incident, DELTA_STATE)
	end
	return true
end

function Incidents.HoldOpen(incident, reason)
	if not incident or not Incidents.Active[incident.id] then return false end
	incident.deadline = nil
	incident.updatedAt = CurTime()
	if reason and reason ~= "" then incident.reason = clean(reason, 160) end
	DRP.Deadlines.Cancel("incident:" .. incident.id .. ":deadline")
	Incidents.QueueDelta(incident, DELTA_STATE)
	return true
end

function Incidents.SetCooldown(incident, key, deadline)
	if not incident or not Incidents.Active[incident.id] then return false end
	incident.cooldowns[clean(key, 40)] = tonumber(deadline) or CurTime()
	incident.updatedAt = CurTime()
	return true
end

function Incidents.Transition(incident, nextState, reason)
	if not incident or not Incidents.Active[incident.id] then return false end
	nextState = clean(nextState, 40)
	local definition = Incidents.Definitions[incident.type] or {}
	local allowed = definition.transitions and definition.transitions[incident.state]
	if definition.transitions and (not allowed or allowed[nextState] ~= true) then return false, "invalid transition" end
	local previous = incident.state
	incident.state = nextState
	incident.updatedAt = CurTime()
	if reason and reason ~= "" then incident.reason = clean(reason, 160) end
	Incidents.AddEvidence(incident, "state_transition", nil, nil, previous .. " -> " .. nextState, true)
	Incidents.QueueDelta(incident, bit.bor(DELTA_STATE, DELTA_EVIDENCE), incident.evidence[#incident.evidence])
	return true
end

function Incidents.Resolve(incident, resolution, detail)
	if not incident or not Incidents.Active[incident.id] then return false end
	resolution = clean(resolution or "resolved", 48)
	local outcome = Incidents.BuildOutcome(incident, resolution, detail)
	if not outcome then return false, "outcome policy missing" end
	local instigator, victim = outcome.instigator, outcome.victim
	incident.outcomeInstigator = instigator
	incident.outcomeVictim = victim
	Incidents.AddEvidence(incident, "incident_resolved", nil, nil, detail or resolution, true)
	incident.resolution = resolution
	incident.resolvedAt = CurTime()
	incident.resolvedUnix = os.time()
	DRP.Deadlines.Cancel("incident:" .. incident.id .. ":deadline")
	for action, grants in pairs(incident.permissions) do
		for _, grant in ipairs(grants) do unindexGrant(incident, action, grant) end
	end
	unindexIncident(incident)
	Incidents.Active[incident.id] = nil
	removeFromClients(incident, detail or resolution)
	local instigatorID, instigatorName = identity(instigator)
	local victimID, victimName = identity(victim)
	local winnerID, winnerName = identity(outcome.winner)
	local loserID, loserName = identity(outcome.loser)

	local receipt = {
		id = incident.id,
		type = incident.type,
		state = incident.state,
		reason = incident.reason,
		resolution = resolution,
		instigator_id = instigatorID,
		instigator = instigatorName,
		victim_id = victimID,
		victim = victimName,
		winner_id = winnerID,
		winner = winnerName,
		winner_side = outcome.winner_side,
		loser_id = loserID,
		loser = loserName,
		loser_side = outcome.loser_side,
		started_at = incident.startedUnix,
		resolved_at = incident.resolvedUnix,
		participants = {},
		permissions = {},
		cooldowns = table.Copy(incident.cooldowns),
		evidence = table.Copy(incident.evidence)
	}
	receipt.outcome = {
		resolution = resolution,
		detail = outcome.detail,
		instigator_id = instigatorID,
		instigator = instigatorName,
		victim_id = victimID,
		victim = victimName,
		winner_id = winnerID,
		winner = winnerName,
		winner_side = outcome.winner_side,
		loser_id = loserID,
		loser = loserName,
		loser_side = outcome.loser_side
	}
	receipt.participants = table.Copy(incident.participantHistory or {})
	for action, grants in pairs(incident.permissions) do
		for _, grant in ipairs(grants) do
			local actorID, actorName = identity(grant.actor)
			local targetID, targetName = identity(grant.target)
			receipt.permissions[#receipt.permissions + 1] = {
				action = action,
				actor_id = actorID,
				actor = actorName,
				target_id = targetID,
				target = targetName,
				reason = grant.reason
			}
		end
	end
	Incidents.Archive[#Incidents.Archive + 1] = receipt
	if #Incidents.Archive > Incidents.ArchiveCapacity then table.remove(Incidents.Archive, 1) end

	if DRP.Audit then
		DRP.Audit.Log(instigator, "incident_resolved", victim, "#" .. incident.id .. " " .. resolution .. ": " .. clean(detail, 100))
		if DRP.Audit.Receipt then DRP.Audit.Receipt(receipt) end
	end
	-- XP is part of the resolution transaction and is awarded by the incident
	-- engine before any optional service hook runs.
	Incidents.AwardOutcomeXP(incident, outcome)
	hook.Run("DRPIncidentResolved", incident, receipt)
	return true, receipt
end

function Incidents.ExplainDenied(actor, target, action)
	local actionText = clean(action, 32):gsub("_", " ")
	local targetName = IsValid(target) and clean(target:Nick(), 48) or "that target"
	if action == DRP.IncidentAction.DAMAGE then
		local key = pairKey(actor, target)
		for _, active in pairs(key and Incidents.ByPair[key] or {}) do
			if active.type == "police_weapon_sighting"
				and (active.state == "nonlethal_required" or active.state == "suspect_retaliation_authorized") then
				local actorRole = select(2, hasParticipant(active, actor))
				local targetRole = select(2, hasParticipant(active, target))
				local actorSide = active.participantSides and active.participantSides[actor]
				local targetSide = active.participantSides and active.participantSides[target]
				if (actorRole == "officer" and targetRole == "suspect")
					or (actorSide == "instigator" and targetSide == "victim") then
					return active, "Incident #" .. active.id .. " requires non-lethal force. You may not damage "
						.. targetName .. " until both a taser attempt and suspect gunfire have occurred."
				end
			end
		end
		if DRP.PVP and DRP.PVP.JobHasUniversalOffense and IsValid(target)
			and DRP.PVP.JobHasUniversalOffense(target:DRPJob()) then
			return nil, "Mob Boss PvP is currently one-way. You may not damage " .. targetName .. " until an incident or mutual PvP permission authorizes retaliation."
		end
	end
	local incident = Incidents.FindPair(actor, target)
	if incident then
		return incident, "Incident #" .. incident.id .. " is " .. incident.state .. "; it does not permit you to " .. actionText .. " " .. targetName .. "."
	end
	return nil, "Safe mode: no active incident permits you to " .. actionText .. " " .. targetName .. "."
end

function Incidents.Deny(actor, target, action)
	if not IsValid(actor) or not actor:IsPlayer() then return end
	local now = CurTime()
	if (Incidents.DeniedThrottle[actor] or 0) > now then return end
	Incidents.DeniedThrottle[actor] = now + 1
	local incident, explanation = Incidents.ExplainDenied(actor, target, action)
	net.Start(deniedMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(incident and incident.id or 0, 32)
	net.WriteString(clean(action, 32))
	net.WriteString(clean(explanation, 200))
	net.Send(actor)
	-- Keep denial visible even if the compact WHY panel is hidden or another
	-- HUD addon suppresses it. This uses the same one-second throttle above.
	if DRP.Net and DRP.Net.Notify then DRP.Net.Notify(actor, explanation, 3) end
end

function Incidents.ClearPlayer(ply, resolution, detail, context)
	local affected = {}
	for _, incident in pairs(Incidents.ByPlayer[ply] or {}) do affected[#affected + 1] = incident end
	for _, incident in ipairs(affected) do
		if Incidents.Active[incident.id] then
			local sharedAlly = incident.participantSides and incident.participantSides[ply]
				and incident.instigator ~= ply and incident.victim ~= ply
			if sharedAlly then
				Incidents.RemoveParticipant(incident, ply, detail or "Team participant became unavailable")
			else
				local definition = Incidents.Definitions[incident.type] or {}
				local handled = definition.onParticipantUnavailable and definition.onParticipantUnavailable(incident, ply, resolution, detail, context)
				if not handled and Incidents.Active[incident.id] then
					Incidents.Resolve(incident, resolution or "participant_unavailable", detail or "A participant became unavailable")
				end
			end
		end
	end
end

function Incidents:Start()
	reserveIDs()
end

function Incidents:Stop()
	local active = {}
	for _, incident in pairs(self.Active) do active[#active + 1] = incident end
	for _, incident in ipairs(active) do self.Resolve(incident, "server_shutdown", "Server shutting down") end
end

hook.Add("DRPPlayerReady", "DRP.Incidents.InitialSync", function(ply)
	for _, incident in ipairs(Incidents.ForPlayer(ply)) do Incidents.Sync(incident, ply) end
end)

DRP.Net.Receive(requestMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not ply:DRPReady() then return end
	local now = CurTime()
	if (Incidents.RecoveryThrottle[ply] or 0) > now then return end
	Incidents.RecoveryThrottle[ply] = now + 5
	for _, incident in ipairs(Incidents.ForPlayer(ply)) do Incidents.Sync(incident, ply) end
end)

hook.Add("PlayerDeath", "DRP.Incidents.ParticipantDeath", function(ply, inflictor, attacker)
	-- Capture the live damage grant before ClearPlayer resolves and unindexes
	-- the incident. The later phone proof can therefore never authenticate RDM.
	if DRP.HitmanEvidence and DRP.HitmanEvidence.CaptureDeath then
		DRP.HitmanEvidence:CaptureDeath(ply, attacker)
	end
	Incidents.ClearPlayer(ply, "participant_died", "A participant died", { attacker = attacker, inflictor = inflictor })
end)

hook.Add("PlayerDisconnected", "DRP.Incidents.ParticipantDisconnect", function(ply)
	Incidents.ClearPlayer(ply, "participant_disconnected", "A participant disconnected")
end)

hook.Add("DRPJobChanged", "DRP.Incidents.ParticipantJobChanged", function(ply)
	Incidents.ClearPlayer(ply, "participant_changed_role", "A participant changed role")
end)
