local OPEN = "drp_bed_open_v1"
local ACTION = "drp_bed_action_v1"

util.AddNetworkString(OPEN)
util.AddNetworkString(ACTION)

local Beds = {
	Records = {},
	ByID = {},
	ByOwnerProperty = {},
	HomeByOwner = {},
	NextID = 1,
	Revision = 0,
	Dirty = false,
	MapReady = false,
	Restored = false,
	SuppressRemoval = false,
	StateKey = "beds:" .. game.GetMap():gsub("[^%w_%-]", "_") ,
	DataPath = "darkrp/beds_" .. game.GetMap():gsub("[^%w_%-]", "_") .. ".json",
	InteractionDistance = 160,
	TravelCooldown = 2
}

DRP.Beds = Beds
DRP.Services.Register("beds", Beds)
DRP.Services.DependsOn("beds", { "storage", "incidents", "properties" })

local function vectorData(value)
	return { x = value.x, y = value.y, z = value.z }
end

local function angleData(value)
	return { p = value.p, y = value.y, r = value.r }
end

local function toVector(value)
	return Vector(tonumber(value and value.x) or 0, tonumber(value and value.y) or 0, tonumber(value and value.z) or 0)
end

local function toAngle(value)
	return Angle(tonumber(value and value.p) or 0, tonumber(value and value.y) or 0, tonumber(value and value.r) or 0)
end

local function clean(value, maximum)
	return string.sub(tostring(value or ""), 1, maximum or 64)
end

local function validOwnerAccess(ownerID, propertyID)
	local definition, lease = DRP.Properties.Get(propertyID)
	if not definition or not lease or not ownerID or ownerID == "" then return false end
	if tostring(lease.owner_id or "") == ownerID then return true end
	local member = lease.members and lease.members[ownerID]
	if not member then return false end
	local eviction = math.max(0, tonumber(member.eviction_unix) or 0)
	if eviction > 0 and eviction <= os.time() then return false end
	local permissions = lease.roles and lease.roles[member.role]
	return permissions and permissions.build == true or false
end

local function ownedPropertyIndex(ownerID)
	local index = Beds.ByOwnerProperty[ownerID]
	if not index then
		index = {}
		Beds.ByOwnerProperty[ownerID] = index
	end
	return index
end

function Beds:RebuildIndexes()
	self.ByOwnerProperty = {}
	for id, record in pairs(self.Records) do
		if record.owner_id ~= "" and record.property_id > 0 then
			ownedPropertyIndex(record.owner_id)[record.property_id] = id
		end
	end
end

function Beds:Payload()
	local records = {}
	for _, record in pairs(self.Records) do
		records[#records + 1] = {
			id = record.id,
			owner_id = record.owner_id,
			owner_name = record.owner_name,
			property_id = record.property_id,
			position = record.position,
			angles = record.angles,
			created_unix = record.created_unix
		}
	end
	table.sort(records, function(first, second) return first.id < second.id end)
	return {
		version = 1,
		revision = self.Revision,
		next_id = self.NextID,
		records = records,
		homes = table.Copy(self.HomeByOwner)
	}
end

function Beds:ApplyPayload(payload)
	if not istable(payload) then return false end
	local records = {}
	local highestID = 0
	for _, raw in ipairs(payload.records or {}) do
		local id = math.max(1, math.floor(tonumber(raw.id) or 0))
		local ownerID = clean(raw.owner_id, 32)
		local propertyID = math.max(0, math.floor(tonumber(raw.property_id) or 0))
		if ownerID ~= "" and propertyID > 0 and not records[id] then
			records[id] = {
				id = id,
				owner_id = ownerID,
				owner_name = clean(raw.owner_name, 64),
				property_id = propertyID,
				position = vectorData(toVector(raw.position)),
				angles = angleData(toAngle(raw.angles)),
				created_unix = math.max(0, math.floor(tonumber(raw.created_unix) or 0))
			}
			highestID = math.max(highestID, id)
		end
	end
	self.Records = records
	self.HomeByOwner = {}
	for ownerID, bedID in pairs(payload.homes or {}) do
		ownerID = clean(ownerID, 32)
		bedID = math.floor(tonumber(bedID) or 0)
		if ownerID ~= "" and records[bedID] and records[bedID].owner_id == ownerID then
			self.HomeByOwner[ownerID] = bedID
		end
	end
	self.NextID = math.max(highestID + 1, math.floor(tonumber(payload.next_id) or 1))
	self.Revision = math.max(0, math.floor(tonumber(payload.revision) or 0))
	self:RebuildIndexes()
	return true
end

function Beds:Save(force)
	if not force and not self.Dirty then return true end
	for id, entity in pairs(self.ByID) do
		local record = self.Records[id]
		if record and IsValid(entity) then
			record.position = vectorData(entity:GetPos())
			record.angles = angleData(entity:GetAngles())
		end
	end
	local revision = self.Revision
	local payload = util.TableToJSON(self:Payload(), false)
	if not payload then return false end
	file.CreateDir("darkrp")
	file.Write(self.DataPath, payload)
	local queued = DRP.Storage and DRP.Storage.SaveWorldState
		and DRP.Storage.SaveWorldState(self.StateKey, payload, function(success)
			if success and Beds.Revision == revision then Beds.Dirty = false end
		end)
	if not queued then self.Dirty = true end
	return true
end

function Beds:MarkDirty()
	self.Revision = self.Revision + 1
	self.Dirty = true
	self:Save()
end

function Beds:RemoveRecord(id, removeEntity, deferSave)
	id = math.floor(tonumber(id) or 0)
	local record = self.Records[id]
	if not record then return false end
	local entity = self.ByID[id]
	self.Records[id] = nil
	self.ByID[id] = nil
	local ownerIndex = self.ByOwnerProperty[record.owner_id]
	if ownerIndex and ownerIndex[record.property_id] == id then
		ownerIndex[record.property_id] = nil
		if next(ownerIndex) == nil then self.ByOwnerProperty[record.owner_id] = nil end
	end
	if self.HomeByOwner[record.owner_id] == id then
		self.HomeByOwner[record.owner_id] = nil
		for candidateID, candidate in pairs(self.Records) do
			if candidate.owner_id == record.owner_id and validOwnerAccess(candidate.owner_id, candidate.property_id) then
				self.HomeByOwner[record.owner_id] = candidateID
				break
			end
		end
	end
	if removeEntity and IsValid(entity) then
		self.SuppressRemoval = true
		entity:Remove()
		self.SuppressRemoval = false
	end
	if deferSave then
		self.Revision = self.Revision + 1
		self.Dirty = true
	else
		self:MarkDirty()
	end
	return true
end

function Beds:Restore()
	if self.Restored or not self.MapReady then return end
	self.Restored = true
	self.SuppressRemoval = true
	local rejected = {}
	for id, record in pairs(self.Records) do
		if not validOwnerAccess(record.owner_id, record.property_id) then
			rejected[#rejected + 1] = id
		else
			local entity = ents.Create("drp_spawn_bed")
			if IsValid(entity) then
				entity.DRPBedID = id
				entity.DRPPropertyID = record.property_id
				entity.DRPJobEntityKey = "base_bed"
				entity.DRPJobEntityOwnerID = record.owner_id
				entity.DRPOwnerSteamID = record.owner_id
				entity:SetModel("models/props_c17/FurnitureBed001a.mdl")
				entity:SetPos(toVector(record.position))
				entity:SetAngles(toAngle(record.angles))
				entity:Spawn()
				entity:Activate()
				local inside = DRP.Properties:EntityInsideAssignedBuildZones(entity, record.property_id)
				if inside then
					self.ByID[id] = entity
					DRP.Properties:IndexEntity(entity, record.property_id)
				else
					entity:Remove()
					rejected[#rejected + 1] = id
				end
			else
				rejected[#rejected + 1] = id
			end
		end
	end
	self.SuppressRemoval = false
	if #rejected > 0 then
		for _, id in ipairs(rejected) do
			local record = self.Records[id]
			if record then
				self.Records[id] = nil
				if self.HomeByOwner[record.owner_id] == id then self.HomeByOwner[record.owner_id] = nil end
			end
		end
		self:RebuildIndexes()
		self:MarkDirty()
	end
	for _, ply in player.Iterator() do
		if ply.DRPReady and ply:DRPReady() then
			self:TrackPlayerBeds(ply)
			self:TeleportHome(ply, "restore")
		end
	end
	print(string.format("[DRP BEDS] restored=%d rejected=%d", table.Count(self.ByID), #rejected))
end

function Beds:RegisterEntity(entity, ply, propertyID)
	if not IsValid(entity) or not IsValid(ply) or not ply:IsPlayer() then return false, "Invalid bed or owner." end
	propertyID = math.floor(tonumber(propertyID) or 0)
	local permitted, resolvedPropertyID, placementReason = DRP.Properties:ValidateSpawnedEntityPlacement(ply, entity, "build")
	if not permitted or propertyID <= 0 or resolvedPropertyID ~= propertyID then
		return false, placementReason or "The bed is not inside the authorised property selected at spawn time."
	end
	local ownerID = ply:SteamID64()
	local existingID = (self.ByOwnerProperty[ownerID] or {})[propertyID]
	if existingID and self.Records[existingID] then return false, "You already have one bed in this base." end
	local id = self.NextID
	self.NextID = id + 1
	local record = {
		id = id,
		owner_id = ownerID,
		owner_name = clean(ply:DRPName(), 64),
		property_id = propertyID,
		position = vectorData(entity:GetPos()),
		angles = angleData(entity:GetAngles()),
		created_unix = os.time()
	}
	self.Records[id] = record
	self.ByID[id] = entity
	ownedPropertyIndex(ownerID)[propertyID] = id
	entity.DRPBedID = id
	entity.DRPPropertyID = propertyID
	entity.DRPJobEntityKey = "base_bed"
	entity.DRPJobEntityOwnerID = ownerID
	entity.DRPOwnerSteamID = ownerID
	DRP.Properties:IndexEntity(entity, propertyID)
	if not self.HomeByOwner[ownerID] then self.HomeByOwner[ownerID] = id end
	self:MarkDirty()
	if DRP.Audit then DRP.Audit.Log(ply, "base_bed_registered", entity, "bed #" .. id .. " property #" .. propertyID) end
	return true, id
end

function Beds:TrackPlayerBeds(ply)
	if not IsValid(ply) then return end
	local ownerID = ply:SteamID64()
	for id, record in pairs(self.Records) do
		local entity = self.ByID[id]
		if record.owner_id == ownerID and IsValid(entity) and DRP.Props and DRP.Props.TrackOwnedEntity then
			DRP.Props.TrackOwnedEntity(ply, entity, "sents", false)
		end
	end
end

function Beds:EligibleBeds(ply)
	local beds = {}
	if not IsValid(ply) then return beds end
	local ownerID = ply:SteamID64()
	for id, record in pairs(self.Records) do
		local entity = self.ByID[id]
		if record.owner_id == ownerID and IsValid(entity)
			and DRP.Properties.Can(ply, record.property_id, "build") then
			beds[#beds + 1] = { id = id, record = record, entity = entity }
		end
	end
	table.sort(beds, function(first, second)
		if first.record.property_id == second.record.property_id then return first.id < second.id end
		return first.record.property_id < second.record.property_id
	end)
	return beds
end

function Beds:BuildSnapshot(ply, source)
	local snapshot = { source = IsValid(source) and source.DRPBedID or 0, beds = {} }
	local ownerID = IsValid(ply) and ply:SteamID64() or ""
	for _, item in ipairs(self:EligibleBeds(ply)) do
		local definition = DRP.Properties.Get(item.record.property_id)
		snapshot.beds[#snapshot.beds + 1] = {
			id = item.id,
			property_id = item.record.property_id,
			name = definition and clean(definition.name, 64) or ("Property #" .. item.record.property_id),
			home = self.HomeByOwner[ownerID] == item.id
		}
	end
	return snapshot
end

local function canReachBed(ply, entity)
	if not IsValid(ply) or not ply:Alive() or not IsValid(entity) or entity:GetClass() ~= "drp_spawn_bed" then return false end
	if ply:GetPos():DistToSqr(entity:GetPos()) > Beds.InteractionDistance * Beds.InteractionDistance then return false end
	local trace = util.TraceLine({ start = ply:EyePos(), endpos = entity:WorldSpaceCenter(), filter = ply, mask = MASK_SOLID })
	return trace.Entity == entity or trace.Fraction > 0.98
end

function Beds:Use(ply, entity)
	if not canReachBed(ply, entity) then return false end
	local record = self.Records[entity.DRPBedID or 0]
	if not record or record.owner_id ~= ply:SteamID64() then
		DRP.Net.Notify(ply, "Only this bed's owner can use its travel controls.", 3)
		return false
	end
	if not DRP.Properties.Can(ply, record.property_id, "build") then
		DRP.Net.Notify(ply, "You no longer have build access to this bed's property.", 3)
		return false
	end
	local snapshot = self:BuildSnapshot(ply, entity)
	net.Start(OPEN)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteEntity(entity)
		net.WriteUInt(snapshot.source, 32)
		net.WriteUInt(math.min(#snapshot.beds, 32), 6)
		for index = 1, math.min(#snapshot.beds, 32) do
			local bed = snapshot.beds[index]
			net.WriteUInt(bed.id, 32)
			net.WriteUInt(math.Clamp(bed.property_id, 0, 65535), 16)
			net.WriteString(bed.name)
			net.WriteBool(bed.home)
		end
	net.Send(ply)
	return true
end

function Beds:SetHome(ply, bedID)
	bedID = math.floor(tonumber(bedID) or 0)
	local record = self.Records[bedID]
	if not record or record.owner_id ~= ply:SteamID64() or not IsValid(self.ByID[bedID]) then return false, "That bed is unavailable." end
	if not DRP.Properties.Can(ply, record.property_id, "build") then return false, "You no longer have access to that base." end
	if self.HomeByOwner[record.owner_id] == bedID then return true end
	self.HomeByOwner[record.owner_id] = bedID
	self:MarkDirty()
	if DRP.Audit then DRP.Audit.Log(ply, "home_bed_selected", self.ByID[bedID], "bed #" .. bedID) end
	local definition = DRP.Properties.Get(record.property_id)
	DRP.Net.Notify(ply, "Home bed set to " .. (definition and definition.name or ("property #" .. record.property_id)) .. ".", 1)
	return true
end

function Beds:SafePosition(ply, entity)
	if not IsValid(ply) or not IsValid(entity) then return nil end
	local hullMins, hullMaxs = ply:GetHull()
	local bedMins, bedMaxs = entity:OBBMins(), entity:OBBMaxs()
	local topZ = bedMaxs.z - hullMins.z + 3
	local floorZ = bedMins.z - hullMins.z + 3
	local candidates = {
		Vector(0, 0, topZ),
		Vector(0, bedMaxs.y + 26, floorZ),
		Vector(0, bedMins.y - 26, floorZ),
		Vector(bedMaxs.x + 26, 0, floorZ),
		Vector(bedMins.x - 26, 0, floorZ)
	}
	for _, localPosition in ipairs(candidates) do
		local position = entity:LocalToWorld(localPosition)
		if util.IsInWorld(position) then
			local trace = util.TraceHull({
				start = position,
				endpos = position,
				mins = hullMins,
				maxs = hullMaxs,
				filter = { ply, entity },
				mask = MASK_PLAYERSOLID
			})
			if not trace.StartSolid and not trace.AllSolid and not trace.Hit then return position end
		end
	end
	return nil
end

function Beds:MovePlayer(ply, entity)
	local position = self:SafePosition(ply, entity)
	if not position then return false, "There is no safe space around that bed." end
	ply:SetPos(position)
	ply:SetLocalVelocity(vector_origin)
	local angles = ply:EyeAngles()
	angles.y = entity:GetAngles().y
	angles.p, angles.r = 0, 0
	ply:SetEyeAngles(angles)
	return true
end

function Beds:CanFastTravel(ply, source, target)
	if not canReachBed(ply, source) then return false, "Move closer and look directly at your bed." end
	if not IsValid(target) then return false, "The destination bed is unavailable." end
	local sourceRecord, targetRecord = self.Records[source.DRPBedID or 0], self.Records[target.DRPBedID or 0]
	local ownerID = ply:SteamID64()
	if not sourceRecord or not targetRecord or sourceRecord.owner_id ~= ownerID or targetRecord.owner_id ~= ownerID then
		return false, "You can only travel between your own beds."
	end
	if source == target then return false, "You are already at that bed." end
	if not DRP.Properties.Can(ply, sourceRecord.property_id, "build")
		or not DRP.Properties.Can(ply, targetRecord.property_id, "build") then
		return false, "You need build access to both bases."
	end
	if DRP.Incidents and #DRP.Incidents.ForPlayer(ply) > 0 then return false, "Fast travel is blocked while an incident is active." end
	if DRP.Properties.ActiveRaids[sourceRecord.property_id] or DRP.Properties.ActiveRaids[targetRecord.property_id] then
		return false, "Fast travel is blocked while either property is being raided."
	end
	if DRP.Legal and (DRP.Legal.IsCuffed(ply) or DRP.Legal.IsTased(ply)
		or (DRP.Legal.Arrested and DRP.Legal.Arrested[ply])) then
		return false, "You cannot fast travel while in police custody."
	end
	if DRP.Kidnapping and DRP.Kidnapping:IsKnockedOut(ply) then return false, "You cannot fast travel while incapacitated." end
	if (ply.DRPNextBedTravel or 0) > CurTime() then return false, "Wait a moment before travelling again." end
	return true
end

function Beds:FastTravel(ply, source, bedID)
	bedID = math.floor(tonumber(bedID) or 0)
	local target = self.ByID[bedID]
	local permitted, reason = self:CanFastTravel(ply, source, target)
	if not permitted then return false, reason end
	local moved, moveReason = self:MovePlayer(ply, target)
	if not moved then return false, moveReason end
	ply.DRPNextBedTravel = CurTime() + self.TravelCooldown
	if DRP.Audit then DRP.Audit.Log(ply, "bed_fast_travel", target, "bed #" .. bedID) end
	return true
end

function Beds:HomeEntity(ply)
	if not IsValid(ply) then return nil end
	local ownerID = ply:SteamID64()
	local homeID = self.HomeByOwner[ownerID]
	local record, entity = self.Records[homeID or 0], self.ByID[homeID or 0]
	if record and IsValid(entity) and record.owner_id == ownerID
		and DRP.Properties.Can(ply, record.property_id, "build") then return entity end
	for _, item in ipairs(self:EligibleBeds(ply)) do
		self.HomeByOwner[ownerID] = item.id
		self:MarkDirty()
		return item.entity
	end
	return nil
end

function Beds:TeleportHome(ply, reason)
	if not self.Restored or not IsValid(ply) or not ply:Alive() or not ply.DRPReady or not ply:DRPReady() then return false end
	if DRP.Legal and DRP.Legal.Arrested and DRP.Legal.Arrested[ply] then return false end
	if (ply.DRPLastBedSpawnTeleport or 0) + 0.5 > CurTime() then return false end
	local entity = self:HomeEntity(ply)
	if not IsValid(entity) then return false end
	local moved = self:MovePlayer(ply, entity)
	if moved then
		ply.DRPLastBedSpawnTeleport = CurTime()
		if reason == "ready" then DRP.Net.Notify(ply, "You spawned at your home bed.", 1) end
	end
	return moved
end

function Beds:Status()
	return {
		records = table.Count(self.Records),
		entities = table.Count(self.ByID),
		homes = table.Count(self.HomeByOwner),
		revision = self.Revision,
		dirty = self.Dirty
	}
end

function Beds:Start()
	local localPayload = util.JSONToTable(file.Read(self.DataPath, "DATA") or "")
	if istable(localPayload) then self:ApplyPayload(localPayload) end

	hook.Add("InitPostEntity", "DRP.Beds.Restore", function()
		Beds.MapReady = true
		Beds:Restore()
	end)
	hook.Add("EntityRemoved", "DRP.Beds.EntityRemoved", function(entity)
		if Beds.SuppressRemoval or not entity.DRPBedID then return end
		Beds:RemoveRecord(entity.DRPBedID, false)
	end)
	hook.Add("DRPPlayerReady", "DRP.Beds.PlayerReady", function(ply)
		Beds:TrackPlayerBeds(ply)
		timer.Simple(0, function() if IsValid(ply) then Beds:TeleportHome(ply, "ready") end end)
	end)
	hook.Add("PlayerSpawn", "DRP.Beds.Respawn", function(ply)
		timer.Simple(0, function() if IsValid(ply) then Beds:TeleportHome(ply, "respawn") end end)
	end)
	hook.Add("PlayerDisconnected", "DRP.Beds.DisconnectSave", function() Beds:Save() end)
	hook.Add("PhysgunDrop", "DRP.Beds.CaptureMovement", function(_, entity)
		local record = IsValid(entity) and Beds.Records[entity.DRPBedID or 0]
		if not record then return end
		record.position = vectorData(entity:GetPos())
		record.angles = angleData(entity:GetAngles())
		Beds:MarkDirty()
	end)
	hook.Add("DRPPropertyReleasing", "DRP.Beds.PropertyReleased", function(propertyID)
		local remove = {}
		for id, record in pairs(Beds.Records) do if record.property_id == propertyID then remove[#remove + 1] = id end end
		for _, id in ipairs(remove) do Beds:RemoveRecord(id, true, true) end
		if #remove > 0 then Beds:Save() end
	end)

	if DRP.Storage and DRP.Storage.LoadWorldState then
		DRP.Storage.LoadWorldState(self.StateKey, function(success, raw)
			local databasePayload = success and util.JSONToTable(raw or "") or nil
			if istable(databasePayload) and (tonumber(databasePayload.revision) or 0) > Beds.Revision then
				Beds.SuppressRemoval = true
				for _, entity in pairs(Beds.ByID) do if IsValid(entity) then entity:Remove() end end
				Beds.SuppressRemoval = false
				Beds.ByID = {}
				Beds.Restored = false
				Beds:ApplyPayload(databasePayload)
			end
			Beds:Restore()
		end)
	end
end

function Beds:Stop()
	hook.Remove("InitPostEntity", "DRP.Beds.Restore")
	hook.Remove("EntityRemoved", "DRP.Beds.EntityRemoved")
	hook.Remove("DRPPlayerReady", "DRP.Beds.PlayerReady")
	hook.Remove("PlayerSpawn", "DRP.Beds.Respawn")
	hook.Remove("PlayerDisconnected", "DRP.Beds.DisconnectSave")
	hook.Remove("PhysgunDrop", "DRP.Beds.CaptureMovement")
	hook.Remove("DRPPropertyReleasing", "DRP.Beds.PropertyReleased")
	self:Save(true)
end

DRP.Net.Receive(ACTION, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "bed_action", 0.25, 4) then return end
	if not ply.DRPReady or not ply:DRPReady() then return end
	local source = net.ReadEntity()
	local action = net.ReadUInt(2)
	local bedID = net.ReadUInt(32)
	if not canReachBed(ply, source) then return end
	local success, reason
	if action == 1 then
		success, reason = Beds:SetHome(ply, bedID)
	elseif action == 2 then
		success, reason = Beds:FastTravel(ply, source, bedID)
	else
		return
	end
	if not success then DRP.Net.Notify(ply, reason or "The bed action was denied.", 3) end
end)

concommand.Add("drp_bed_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsAdmin(ply)) then return end
	local status = Beds:Status()
	local message = string.format("beds records=%d entities=%d homes=%d revision=%d dirty=%s",
		status.records, status.entities, status.homes, status.revision, tostring(status.dirty))
	print("[DRP] " .. message)
	if IsValid(ply) then DRP.Net.Notify(ply, message, 0) end
end)
