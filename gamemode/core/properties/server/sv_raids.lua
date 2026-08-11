local Properties = assert(DRP and DRP.Properties, "properties service must exist before raids load")
local function onlinePlayer(id) return DRP.Players.Online(id) end

local function raidRole(incident, ply)
	return DRP.Incidents.Role(incident, ply)
end

local function isAttacker(incident, ply)
	local role = raidRole(incident, ply)
	return role == "suspect" or (role and string.StartWith(role, "attacker"))
end

local function raidParticipants(propertyID, attacker)
	local participants = { suspect = attacker }
	local lease = Properties.Leases[propertyID]
	local owner = lease and onlinePlayer(lease.owner_id)
	if IsValid(owner) then participants.victim = owner end
	local index = 1
	for memberID in pairs(lease and lease.members or {}) do
		local member = onlinePlayer(memberID)
		if IsValid(member) and member ~= owner and Properties.Can(member, propertyID, "access") then participants["defender_" .. index] = member index = index + 1 end
	end
	return participants
end

function Properties:DeclareRaid(attacker, propertyID)
	propertyID = math.floor(tonumber(propertyID) or 0)
	local definition, lease = self.Get(propertyID)
	if not definition or not lease then DRP.Net.Notify(attacker, "That property is not currently owned.", 3) return false end
	if not attacker:DRPHasRoleCapability("canRaid") then DRP.Net.Notify(attacker, "Your role identity cannot declare raids.", 3) return false end
	if self.Member(propertyID, attacker) then DRP.Net.Notify(attacker, "You cannot raid your own property.", 3) return false end
	if self.ActiveRaids[propertyID] then DRP.Net.Notify(attacker, "That property already has a raid incident.", 3) return false end
	local now = os.time()
	if (lease.raid_cooldown_unix or 0) > now then DRP.Net.Notify(attacker, "That property is protected from raids for " .. (lease.raid_cooldown_unix - now) .. " seconds.", 3) return false end
	if (tonumber(self.PlayerRaidCooldowns[attacker:SteamID64()]) or 0) > now then DRP.Net.Notify(attacker, "You must wait before declaring another raid.", 3) return false end
	local near = false
	for _, doorID in ipairs(definition.doors) do
		local door = DRP.Doors.ByMapID[tostring(doorID)]
		if IsValid(door) and attacker:GetPos():DistToSqr(door:GetPos()) <= self.RaidDistance * self.RaidDistance then near = true break end
	end
	if not near then DRP.Net.Notify(attacker, "Move within " .. self.RaidDistance .. " units of the target property.", 3) return false end

	local defences = {}
	for entity in pairs(self.EntitiesByProperty[propertyID] or {}) do
		if entity.DRPPropertyID == propertyID and entity.DRPPropertyDefence and not entity.DRPPropertyStorage then defences[entity] = true end
	end
	local defenceCount = table.Count(defences)
	if defenceCount < 1 then DRP.Net.Notify(attacker, "That property has no registered defences to raid.", 3) return false end

	local incident = DRP.Incidents.Create("property_raid", {
		reason = attacker:Nick() .. " declared a raid on " .. definition.name,
		instigator = attacker,
		victim = onlinePlayer(lease.owner_id) or attacker,
		participants = raidParticipants(propertyID, attacker),
		deadline = CurTime() + self.RaidWarmup,
		metadata = { property_id = propertyID, property_name = definition.name, defence_count = defenceCount, defence_goal = math.max(1, math.ceil(defenceCount * 0.35)), destroyed = 0 }
	})
	if not incident then return false end
	incident.raidDefences = defences
	self.ActiveRaids[propertyID] = incident.id
	if self.ClearTrespassProperty then
		self:ClearTrespassProperty(propertyID, "raid_declared", "Declared raid rules now control property combat")
	end
	lease.raid_cooldown_unix = now + self.RaidCooldown
	self.PlayerRaidCooldowns[attacker:SteamID64()] = now + self.RaidCooldown
	self:Save()
	self:SyncAll(propertyID)
	DRP.Incidents.AddEvidence(incident, "raid_declared", attacker, onlinePlayer(lease.owner_id), defenceCount .. " defences; objective " .. incident.metadata.defence_goal)
	for _, participant in ipairs(incident.participants) do
		if IsValid(participant.player) then DRP.Net.Notify(participant.player, "Raid declared on " .. definition.name .. ". Combat begins in " .. self.RaidWarmup .. " seconds.", 2) end
	end
	return true
end

function Properties:JoinRaid(ply, incidentID)
	local incident = DRP.Incidents.Get(tonumber(incidentID))
	if not incident or incident.type ~= "property_raid" or incident.state ~= "declared" then DRP.Net.Notify(ply, "That raid is not accepting attackers.", 3) return false end
	local propertyID = tonumber(incident.metadata.property_id)
	local definition, lease = self.Get(propertyID)
	if not definition or not lease or self.Member(propertyID, ply) or not ply:DRPHasRoleCapability("canRaid") then DRP.Net.Notify(ply, "You cannot join that raid.", 3) return false end
	if #DRP.Incidents.ForPlayer(ply, "property_raid") > 0 then DRP.Net.Notify(ply, "You are already in a property raid.", 3) return false end
	local now = os.time()
	if (tonumber(self.PlayerRaidCooldowns[ply:SteamID64()]) or 0) > now then DRP.Net.Notify(ply, "Your raid cooldown is still active.", 3) return false end
	local near = false
	for _, doorID in ipairs(definition.doors) do
		local door = DRP.Doors.ByMapID[tostring(doorID)]
		if IsValid(door) and ply:GetPos():DistToSqr(door:GetPos()) <= self.RaidDistance * self.RaidDistance then near = true break end
	end
	if not near then DRP.Net.Notify(ply, "Move closer to the target property before joining.", 3) return false end
	local attackerIndex = 1
	for _, participant in ipairs(incident.participants) do if isAttacker(incident, participant.player) then attackerIndex = attackerIndex + 1 end end
	if not DRP.Incidents.AddParticipant(incident, "attacker_" .. attackerIndex, ply) then return false end
	self.PlayerRaidCooldowns[ply:SteamID64()] = now + self.RaidCooldown
	self:Save()
	DRP.Incidents.AddEvidence(incident, "attacker_joined", ply, nil, definition.name)
	DRP.Net.Notify(ply, "Joined raid incident #" .. incident.id .. ".", 1)
	return true
end

function Properties:ActivateRaid(incident)
	if not incident or incident.state ~= "declared" then return false end
	local remaining = 0
	for entity in pairs(incident.raidDefences or {}) do
		if IsValid(entity) then remaining = remaining + 1 else incident.raidDefences[entity] = nil end
	end
	if remaining < 1 then
		self:FinishRaid(incident, "defenders_victory", "No valid raid defences remained when the warning period ended")
		return true
	end
	incident.metadata.defence_count = remaining
	incident.metadata.defence_goal = math.max(1, math.min(incident.metadata.defence_goal, remaining))
	local deadline = CurTime() + self.RaidDuration
	DRP.Incidents.Transition(incident, "active", "Raid active: destroy " .. incident.metadata.defence_goal .. " registered defences")
	local attackers, defenders = {}, {}
	for _, participant in ipairs(incident.participants) do
		if isAttacker(incident, participant.player) then attackers[#attackers + 1] = participant.player else defenders[#defenders + 1] = participant.player end
	end
	for _, attacker in ipairs(attackers) do
		for _, defender in ipairs(defenders) do
			DRP.Incidents.Grant(incident, "damage", attacker, defender, "Active property raid", deadline)
			DRP.Incidents.Grant(incident, "damage", defender, attacker, "Defending property from raid", deadline)
		end
	end
	DRP.Incidents.SetDeadline(incident, deadline, true)
	DRP.Incidents.AddEvidence(incident, "raid_started", nil, nil, self.RaidDuration .. " second objective window")
	return true
end

function Properties:AddDefenderToRaid(ply, propertyID)
	local incident = DRP.Incidents.Get(self.ActiveRaids[tonumber(propertyID)])
	if not incident or not self.Can(ply, propertyID, "access") or DRP.Incidents.Role(incident, ply) then return false end
	local defenderIndex = 1
	for _, participant in ipairs(incident.participants) do if not isAttacker(incident, participant.player) then defenderIndex = defenderIndex + 1 end end
	if not DRP.Incidents.AddParticipant(incident, "defender_" .. defenderIndex, ply) then return false end
	if incident.state == "active" then
		for _, participant in ipairs(incident.participants) do
			if isAttacker(incident, participant.player) then
				DRP.Incidents.Grant(incident, "damage", participant.player, ply, "Active property raid", incident.deadline)
				DRP.Incidents.Grant(incident, "damage", ply, participant.player, "Defending property from raid", incident.deadline)
			end
		end
	end
	DRP.Incidents.AddEvidence(incident, "defender_joined", ply, nil, self.Definitions[propertyID].name)
	return true
end

function Properties:FinishRaid(incident, resolution, detail)
	if not incident or not DRP.Incidents.Get(incident.id) then return false end
	for _, participant in ipairs(incident.participants) do
		if IsValid(participant.player) then DRP.Net.Notify(participant.player, "Raid resolved: " .. detail, resolution == "attackers_victory" and 2 or 1) end
	end
	return DRP.Incidents.Resolve(incident, resolution, detail)
end

function Properties:CanRaidDamage(ply, entity)
	local propertyID = IsValid(entity) and entity.DRPPropertyID
	local active, incident
	if propertyID then active, incident = self:IsRaidActive(propertyID) end
	return active and incident.raidDefences and incident.raidDefences[entity] == true and isAttacker(incident, ply), incident
end

local function damagePlayer(entity)
	if not IsValid(entity) then return nil end
	if entity:IsPlayer() then return entity end
	local owner = entity.GetOwner and entity:GetOwner() or nil
	if IsValid(owner) and owner:IsPlayer() then return owner end
	if DRP.Props and DRP.Props.Owner then return DRP.Props.Owner(entity) end
end


DRP.Incidents.Definitions.property_raid.onDeadline = function(incident)
	if incident.state == "declared" then return Properties:ActivateRaid(incident) end
	if incident.state == "active" then Properties:FinishRaid(incident, "defenders_victory", "Defenders held the property until the raid timer expired") return true end
	return false
end

DRP.Incidents.Definitions.property_raid.onParticipantUnavailable = function(incident, ply, _, detail)
	if isAttacker(incident, ply) then
		DRP.Incidents.RemoveParticipant(incident, ply, detail or "Attacker unavailable")
		for _, participant in ipairs(incident.participants) do if isAttacker(incident, participant.player) then return true end end
		Properties:FinishRaid(incident, "defenders_victory", "All attacking capability was lost")
		return true
	end
	DRP.Incidents.RemoveParticipant(incident, ply, detail or "Defender unavailable")
	return true
end

hook.Add("DRPIncidentResolved", "DRP.Properties.RaidResolved", function(incident)
	if incident.type ~= "property_raid" then return end
	local propertyID = tonumber(incident.metadata.property_id)
	if Properties.ActiveRaids[propertyID] == incident.id then Properties.ActiveRaids[propertyID] = nil end
	Properties:ScheduleOwnerDeadline(propertyID)
	Properties:Save()
	Properties:SyncAll(propertyID)
end)

hook.Add("EntityTakeDamage", "DRP.Properties.ProtectDefences", function(entity, damage)
	if not IsValid(entity) or not entity.DRPPropertyID then return end
	local attacker = damagePlayer(damage:GetAttacker()) or damagePlayer(damage:GetInflictor())
	local allowed, incident
	if IsValid(attacker) then allowed, incident = Properties:CanRaidDamage(attacker, entity) end
	if allowed then
		if (incident.nextDefenceEvidence or 0) <= CurTime() then
			incident.nextDefenceEvidence = CurTime() + 1
			DRP.Incidents.AddEvidence(incident, "defence_damaged", attacker, nil, entity:GetClass() .. "#" .. entity:EntIndex(), true)
		end
		return
	end
	if IsValid(attacker) then DRP.Incidents.Deny(attacker, onlinePlayer(Properties.Leases[entity.DRPPropertyID] and Properties.Leases[entity.DRPPropertyID].owner_id), "damage_property") end
	damage:SetDamage(0)
	damage:SetDamageForce(vector_origin)
	return true
end)

hook.Add("EntityRemoved", "DRP.Properties.RaidObjective", function(entity)
	local propertyID = entity.DRPPropertyID
	Properties:IndexEntity(entity, nil)
	local active, incident
	if propertyID then active, incident = Properties:IsRaidActive(propertyID) end
	if not active or not incident.raidDefences or not incident.raidDefences[entity] then return end
	incident.raidDefences[entity] = nil
	incident.metadata.destroyed = (incident.metadata.destroyed or 0) + 1
	DRP.Incidents.AddEvidence(incident, "defence_destroyed", nil, nil, incident.metadata.destroyed .. "/" .. incident.metadata.defence_goal, true)
	if incident.metadata.destroyed >= incident.metadata.defence_goal then Properties:FinishRaid(incident, "attackers_victory", "Attackers destroyed the declared defence objective") end
end)

Properties.Raids = {
	IsAttacker = isAttacker
}
Properties.RaidModuleLoaded = true
return Properties.Raids
