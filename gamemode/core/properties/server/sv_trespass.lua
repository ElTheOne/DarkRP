local Properties = assert(DRP and DRP.Properties, "properties service must exist before trespass protection loads")

Properties.TrespassByPlayer = Properties.TrespassByPlayer or setmetatable({}, { __mode = "k" })
Properties.TrespassByProperty = Properties.TrespassByProperty or {}
Properties.NextTrespassCheck = Properties.NextTrespassCheck or setmetatable({}, { __mode = "k" })
Properties.TrespassCheckInterval = 1

local function adminMode(ply)
	return IsValid(ply) and DRP.AdminMode and DRP.AdminMode.IsActive
		and DRP.AdminMode.IsActive(ply)
end

local function eligiblePlayer(ply)
	return IsValid(ply) and ply:IsPlayer() and not ply:IsBot() and ply:Alive()
		and ply.DRPReady and ply:DRPReady() and not adminMode(ply)
end

local function activeIncident(id)
	local incident = DRP.Incidents.Get(tonumber(id))
	return incident and incident.type == "property_trespass" and incident or nil
end

local function propertySet(propertyID)
	local set = Properties.TrespassByProperty[propertyID]
	if not set then set = {} Properties.TrespassByProperty[propertyID] = set end
	return set
end

local function unindexIncident(incident)
	if not incident then return end
	local intruder = incident.instigator
	if IsValid(intruder) and Properties.TrespassByPlayer[intruder] == incident.id then
		Properties.TrespassByPlayer[intruder] = nil
	end
	local propertyID = tonumber(incident.metadata and incident.metadata.property_id)
	local set = propertyID and Properties.TrespassByProperty[propertyID]
	if set then
		set[incident.id] = nil
		if next(set) == nil then Properties.TrespassByProperty[propertyID] = nil end
	end
end

function Properties:BelongsToProperty(ply, propertyID)
	propertyID = math.floor(tonumber(propertyID) or 0)
	local definition, lease = self.Get(propertyID)
	if not definition or not IsValid(ply) then return false end
	if lease then return self.Can(ply, propertyID, "access") end
	if definition.buyable == false and not self.IsWorldDefinition(definition) then
		return self.JobCanBuild(ply, propertyID)
	end
	return false
end

function Properties:TrespassPropertyAt(position, ply)
	if not isvector(position) then return nil end
	local accessible
	for propertyID, definition in pairs(self.Definitions) do
		local lease = self.Leases[propertyID]
		if not self.IsWorldDefinition(definition) and not self.ActiveRaids[propertyID]
			and (lease or definition.buyable == false) then
			for _, zone in ipairs(definition.build_zones or {}) do
				if self.Geometry.PointInsideZone(position, zone, self.BuildZoneTolerance) then
					local match = { definition, propertyID, lease }
					if not IsValid(ply) or not self:BelongsToProperty(ply, propertyID) then
						return unpack(match)
					end
					accessible = accessible or match
					break
				end
			end
		end
	end
	if accessible then return unpack(accessible) end
	return nil
end

function Properties:TrespassDefenders(propertyID, intruder)
	local definition, lease = self.Get(propertyID)
	if not definition then return {} end
	local defenders, seen = {}, {}
	local function add(ply)
		if ply ~= intruder and eligiblePlayer(ply) and self:BelongsToProperty(ply, propertyID)
			and not seen[ply] then
			seen[ply] = true
			defenders[#defenders + 1] = ply
		end
	end
	if lease then
		add(DRP.Players.Online(lease.owner_id))
		for memberID in pairs(lease.members or {}) do add(DRP.Players.Online(memberID)) end
	else
		for _, candidate in ipairs((DRP.Players and DRP.Players.List) or {}) do add(candidate) end
	end
	table.sort(defenders, function(first, second) return first:SteamID64() < second:SteamID64() end)
	return defenders
end

function Properties:ClearTrespass(ply, resolution, detail)
	local incident = activeIncident(self.TrespassByPlayer[ply])
	self.TrespassByPlayer[ply] = nil
	if not incident then return false end
	unindexIncident(incident)
	return DRP.Incidents.Resolve(incident, resolution or "intruder_left",
		detail or "The intruder left the property boundary")
end

function Properties:RefreshTrespassIncident(incident)
	if not incident or not DRP.Incidents.Get(incident.id) then return false end
	local intruder = incident.instigator
	local propertyID = tonumber(incident.metadata and incident.metadata.property_id)
	local definition, currentID
	if eligiblePlayer(intruder) then
		definition, currentID = self:TrespassPropertyAt(intruder:GetPos(), intruder)
	end
	if not definition or currentID ~= propertyID or self:BelongsToProperty(intruder, propertyID) then
		return self:ClearTrespass(intruder, "intruder_left", "The intruder left or gained access to the property")
	end

	local defenders = self:TrespassDefenders(propertyID, intruder)
	if #defenders == 0 then
		return self:ClearTrespass(intruder, "no_defender", "No eligible property defender remains online")
	end
	local wanted = {}
	for _, defender in ipairs(defenders) do wanted[defender] = true end

	-- Promote a valid representative before removing an unavailable original
	-- victim so the incident keeps its explicit victim field.
	incident.victim = defenders[1]
	incident.participantSides[intruder] = "instigator"
	local previousParticipants = {}
	for _, participant in ipairs(incident.participants or {}) do
		previousParticipants[#previousParticipants + 1] = participant.player
	end
	for _, candidate in ipairs(previousParticipants) do
		if candidate ~= intruder and not wanted[candidate] then
			DRP.Incidents.RemoveParticipant(incident, candidate, "Property defence access ended")
		end
	end

	local defenderNumber = 0
	for _, defender in ipairs(defenders) do
		defenderNumber = defenderNumber + 1
		if not DRP.Incidents.Role(incident, defender) then
			DRP.Incidents.AddParticipant(incident, "defender_" .. defenderNumber, defender, "victim")
			DRP.Net.Notify(defender, intruder:DRPName() .. " entered " .. definition.name
				.. ". One-way property defence PvP is active.", 2)
		end
		incident.participantSides[defender] = "victim"
		DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, defender, intruder,
			"Defending " .. definition.name .. " from a trespasser")
		DRP.Incidents.Revoke(incident, DRP.IncidentAction.DAMAGE, intruder, defender)
	end
	return true
end

function Properties:BeginTrespass(intruder, definition, propertyID)
	local defenders = self:TrespassDefenders(propertyID, intruder)
	if #defenders == 0 then return false end
	local representative = defenders[1]
	local reason = intruder:DRPName() .. " entered " .. definition.name .. " without access"
	local incident = DRP.Incidents.Create("property_trespass", {
		reason = reason,
		instigator = intruder,
		victim = representative,
		participants = { intruder = intruder, defender = representative },
		teamShare = false,
		metadata = { property_id = propertyID, property_name = definition.name }
	})
	if not incident then return false end
	self.TrespassByPlayer[intruder] = incident.id
	propertySet(propertyID)[incident.id] = incident
	incident.participantSides[intruder] = "instigator"
	incident.participantSides[representative] = "victim"
	self:RefreshTrespassIncident(incident)
	DRP.Incidents.AddEvidence(incident, "property_boundary_entered", intruder, representative,
		definition.name)
	DRP.Net.Notify(representative, intruder:DRPName() .. " entered " .. definition.name
		.. ". One-way property defence PvP is active.", 2)
	DRP.Net.Notify(intruder, "You entered " .. definition.name
		.. " without access. Its members may damage you while you remain inside.", 3)
	return true, incident
end

function Properties:UpdateTrespass(ply, now, force)
	if not IsValid(ply) then return false end
	now = tonumber(now) or CurTime()
	if not force and (self.NextTrespassCheck[ply] or 0) > now then return false end
	self.NextTrespassCheck[ply] = now + self.TrespassCheckInterval

	local existing = activeIncident(self.TrespassByPlayer[ply])
	if not eligiblePlayer(ply) then
		if existing then self:ClearTrespass(ply, "intruder_unavailable", "Trespass protection ended") end
		return false
	end
	local definition, propertyID = self:TrespassPropertyAt(ply:GetPos(), ply)
	if not definition or self:BelongsToProperty(ply, propertyID) then
		if existing then self:ClearTrespass(ply, "intruder_left", "The intruder left or gained property access") end
		if propertyID then self:RefreshTrespassProperty(propertyID) end
		return false
	end
	if existing and tonumber(existing.metadata.property_id) ~= propertyID then
		self:ClearTrespass(ply, "intruder_left", "The intruder moved to another property")
		existing = nil
	end
	if existing then return self:RefreshTrespassIncident(existing) end
	return self:BeginTrespass(ply, definition, propertyID)
end

function Properties:RefreshTrespassProperty(propertyID)
	local set = self.TrespassByProperty[tonumber(propertyID)]
	if not set then return 0 end
	local incidents = {}
	for _, incident in pairs(set) do incidents[#incidents + 1] = incident end
	for _, incident in ipairs(incidents) do self:RefreshTrespassIncident(incident) end
	return #incidents
end

function Properties:ClearTrespassProperty(propertyID, resolution, detail)
	local set = self.TrespassByProperty[tonumber(propertyID)]
	if not set then return 0 end
	local incidents = {}
	for _, incident in pairs(set) do incidents[#incidents + 1] = incident end
	for _, incident in ipairs(incidents) do
		if DRP.Incidents.Get(incident.id) then
			unindexIncident(incident)
			DRP.Incidents.Resolve(incident, resolution or "property_unavailable",
				detail or "Property defence became unavailable")
		end
	end
	return #incidents
end

function Properties:HandleTrespassParticipantUnavailable(incident, ply, resolution, detail)
	if not incident or incident.type ~= "property_trespass" then return false end
	if ply == incident.instigator then
		self:ClearTrespass(ply, resolution or "intruder_unavailable", detail or "Intruder unavailable")
		return true
	end
	self:RefreshTrespassIncident(incident)
	return true
end

hook.Add("DRPPlayerActivity", "DRP.Properties.Trespass", function(ply, now)
	Properties:UpdateTrespass(ply, now)
end)

hook.Add("DRPPlayerReady", "DRP.Properties.TrespassReady", function(ply)
	timer.Simple(0, function()
		if IsValid(ply) and DRP.Properties then DRP.Properties:UpdateTrespass(ply, CurTime(), true) end
	end)
end)

hook.Add("DRPAdminModeChanged", "DRP.Properties.TrespassAdminMode", function(ply, active)
	if active then Properties:ClearTrespass(ply, "admin_mode", "Admin Mode exempts property boundaries")
	else Properties:UpdateTrespass(ply, CurTime(), true) end
	local affected = {}
	for _, incident in pairs((DRP.Incidents.ByPlayer and DRP.Incidents.ByPlayer[ply]) or {}) do
		if incident.type == "property_trespass" then affected[#affected + 1] = incident end
	end
	for _, incident in ipairs(affected) do Properties:RefreshTrespassIncident(incident) end
end)

hook.Add("DRPJobChanged", "DRP.Properties.TrespassJob", function(ply)
	Properties:UpdateTrespass(ply, CurTime(), true)
end)

hook.Add("DRPPropertyReleasing", "DRP.Properties.TrespassRelease", function(propertyID)
	Properties:ClearTrespassProperty(propertyID, "property_released", "The property was released")
end)

hook.Add("DRPIncidentResolved", "DRP.Properties.TrespassResolved", function(incident)
	if incident and incident.type == "property_trespass" then unindexIncident(incident) end
end)

Properties.TrespassModuleLoaded = true
return Properties
