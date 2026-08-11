local Props = assert(DRP and DRP.Props, "props service must exist before persistence loads")
local modelWeight = assert(Props.Internal and Props.Internal.ModelWeight)
local trackOwnedEntity = assert(Props.Internal and Props.Internal.TrackOwnedEntity)

local persistentPropClasses = {
	prop_physics = true,
	prop_physics_multiplayer = true,
	prop_physics_override = true
}

local function vectorRecord(value)
	return { x = value.x, y = value.y, z = value.z }
end

local function angleRecord(value)
	return { p = value.p, y = value.y, r = value.r }
end

local function recordVector(value)
	return Vector(tonumber(value and value.x) or 0, tonumber(value and value.y) or 0, tonumber(value and value.z) or 0)
end

local function recordAngle(value)
	return Angle(tonumber(value and value.p) or 0, tonumber(value and value.y) or 0, tonumber(value and value.r) or 0)
end

function Props:CapturePersistentRecord(entity, id)
	if not IsValid(entity) or not entity.DRPTrackedCountsAsProp or not entity.DRPTrackedOwnerID then return nil end
	local class = string.lower(tostring(entity:GetClass() or ""))
	local model = DRP.Props.NormalizeModel(entity:GetModel())
	if not persistentPropClasses[class] or not model then return nil end
	local color = entity:GetColor()
	local bodygroups = {}
	for index = 0, math.max(0, entity:GetNumBodyGroups() - 1) do
		bodygroups[index + 1] = entity:GetBodygroup(index)
	end
	return {
		id = math.floor(tonumber(id) or 0),
		owner_id = tostring(entity.DRPTrackedOwnerID),
		class = class,
		model = model,
		position = vectorRecord(entity:GetPos()),
		angles = angleRecord(entity:GetAngles()),
		property_id = math.floor(tonumber(entity.DRPPropertyID) or 0),
		weight = math.max(1, math.floor(tonumber(entity.DRPPropWeight) or modelWeight(model))),
		skin = math.max(0, math.floor(tonumber(entity:GetSkin()) or 0)),
		material = string.sub(tostring(entity:GetMaterial() or ""), 1, 256),
		color = { r = color.r, g = color.g, b = color.b, a = color.a },
		bodygroups = bodygroups,
		-- Player props are intentionally restored frozen even if the server
		-- stopped while one happened to be held by a physgun.
		motion = false
	}
end

function Props:PersistencePayload()
	local records = {}
	for _, record in pairs(self.PersistentRecords) do records[#records + 1] = record end
	table.sort(records, function(first, second) return (first.id or 0) < (second.id or 0) end)
	return {
		version = 1,
		map = game.GetMap(),
		next_id = self.NextPersistentID,
		records = records
	}
end

function Props:SavePersistence()
	timer.Remove("DRP.Props.PersistenceSave")
	self.PersistenceSaveScheduled = false
	if not self.PersistenceDirty and file.Exists(self.PersistentDataPath, "DATA") then return true end
	file.CreateDir("darkrp")
	local encoded = util.TableToJSON(self:PersistencePayload(), false)
	if not encoded then return false end
	file.Write(self.PersistentDataPath, encoded)
	self.PersistenceDirty = false
	return true
end

function Props:MarkPersistenceDirty()
	self.PersistenceDirty = true
	if self.PersistenceSaveScheduled or self.Stopping then return end
	self.PersistenceSaveScheduled = true
	-- Coalesce several removals/spawns from the same engine event into one
	-- local-file write. This is event-triggered and never a recurring timer.
	timer.Create("DRP.Props.PersistenceSave", 0, 1, function()
		if DRP.Props == self then self:SavePersistence() end
	end)
end

function Props:LoadPersistence()
	self.PersistentRecords = {}
	self.PersistentEntities = {}
	self.NextPersistentID = 1
	local decoded = util.JSONToTable(file.Read(self.PersistentDataPath, "DATA") or "")
	if not istable(decoded) or not istable(decoded.records) then return false end
	self.NextPersistentID = math.max(1, math.floor(tonumber(decoded.next_id) or 1))
	for _, record in ipairs(decoded.records) do
		local id = math.floor(tonumber(record and record.id) or 0)
		local ownerID = tostring(record and record.owner_id or "")
		if id > 0 and ownerID ~= "" and istable(record.position) and istable(record.angles) then
			self.PersistentRecords[id] = record
			self.NextPersistentID = math.max(self.NextPersistentID, id + 1)
		end
	end
	return true
end

function Props:PersistEntity(entity)
	if self.RestoringPersistence or not IsValid(entity) or not entity.DRPTrackedCountsAsProp then return false end
	local id = math.floor(tonumber(entity.DRPPersistentPropID) or 0)
	if id <= 0 then
		id = self.NextPersistentID
		self.NextPersistentID = self.NextPersistentID + 1
		entity.DRPPersistentPropID = id
	end
	local record = self:CapturePersistentRecord(entity, id)
	if not record then return false end
	self.PersistentRecords[id] = record
	self.PersistentEntities[id] = entity
	self:MarkPersistenceDirty()
	return true
end

function Props:ForgetPersistentEntity(entity)
	local id = entity and math.floor(tonumber(entity.DRPPersistentPropID) or 0) or 0
	if id <= 0 then return false end
	self.PersistentRecords[id] = nil
	self.PersistentEntities[id] = nil
	entity.DRPPersistentPropID = nil
	self:MarkPersistenceDirty()
	return true
end

function Props:CaptureAllPersistent()
	for id, entity in pairs(self.PersistentEntities) do
		local record = self:CapturePersistentRecord(entity, id)
		if record then self.PersistentRecords[id] = record end
	end
	self.PersistenceDirty = true
end

local function indexRestoredOwnership(service, entity, record)
	local ownerID = tostring(record.owner_id)
	local byID = service.ByOwnerID[ownerID]
	if not byID then byID = setmetatable({}, { __mode = "k" }) service.ByOwnerID[ownerID] = byID end
	byID[entity] = true
	entity.DRPTrackedOwnerID = ownerID
	entity.DRPOwnerSteamID = ownerID
	entity.DRPTrackedCountsAsProp = true
	entity.DRPCountsAsProp = true
	entity.DRPPropWeight = math.max(1, math.floor(tonumber(record.weight) or modelWeight(record.model)))
	service.CountByOwnerID[ownerID] = (service.CountByOwnerID[ownerID] or 0) + 1
	service.WeightByOwnerID[ownerID] = (service.WeightByOwnerID[ownerID] or 0) + entity.DRPPropWeight
	if entity.DRPPropWeight >= service.ComplexWeightThreshold then
		service.ComplexCountByOwnerID[ownerID] = (service.ComplexCountByOwnerID[ownerID] or 0) + 1
	end
	service.TotalPropCount = service.TotalPropCount + 1
	service.TotalPropWeight = service.TotalPropWeight + entity.DRPPropWeight
	local online = DRP.Players and DRP.Players.Online(ownerID) or nil
	if IsValid(online) then
		service.ByPlayer[online] = service.ByPlayer[online] or {}
		service.ByPlayer[online][entity] = true
		service.ByEntity[entity] = online
		entity:SetCreator(online)
	end
end

function Props:RestorePersistence()
	if self.RestoringPersistence then return false end
	self.RestoringPersistence = true
	local restored, rejected = 0, {}
	local perOwner, weightPerOwner, complexPerOwner = {}, {}, {}
	local records = {}
	for _, record in pairs(self.PersistentRecords) do records[#records + 1] = record end
	table.sort(records, function(first, second) return (first.id or 0) < (second.id or 0) end)

	for _, record in ipairs(records) do
		local id = math.floor(tonumber(record.id) or 0)
		local ownerID = tostring(record.owner_id or "")
		local class = string.lower(tostring(record.class or ""))
		local model = DRP.Props.NormalizeModel(record.model)
		local propertyID = math.floor(tonumber(record.property_id) or 0)
		local ownerCount = perOwner[ownerID] or 0
		local weight = math.max(1, math.floor(tonumber(record.weight) or (model and modelWeight(model)) or 1))
		local ownerWeight = weightPerOwner[ownerID] or 0
		local ownerComplex = complexPerOwner[ownerID] or 0
		local ownerPropLimit = self.BaseMaxPerPlayer + (DRP.Supporter and DRP.Supporter.EntityBonus(ownerID) or 0)
		local isComplex = weight >= self.ComplexWeightThreshold
		local valid = id > 0 and ownerID ~= "" and persistentPropClasses[class]
			and model and util.IsValidModel(model) and util.IsValidProp(model)
			and propertyID > 0 and DRP.Properties and DRP.Properties.Definitions[propertyID]
			and ownerCount < ownerPropLimit and self.TotalPropCount < self.MaxGlobalProps
			and ownerWeight + weight <= self.MaxPropWeightPerPlayer
			and self.TotalPropWeight + weight <= self.MaxGlobalPropWeight
			and (not isComplex or ownerComplex < self.MaxComplexPropsPerPlayer)
		if valid then
			local entity = ents.Create(class)
			if IsValid(entity) then
				entity:SetModel(model)
				entity:SetPos(recordVector(record.position))
				entity:SetAngles(recordAngle(record.angles))
				entity:Spawn()
				entity:Activate()
				entity.DRPPropertyID = propertyID
				local inside = DRP.Properties:EntityInsideAssignedBuildZones(entity, propertyID)
				if inside then
					entity.DRPPersistentPropID = id
					if record.skin then entity:SetSkin(math.max(0, math.floor(tonumber(record.skin) or 0))) end
					if record.material and record.material ~= "" then entity:SetMaterial(record.material) end
					if record.color then
						entity:SetColor(Color(record.color.r or 255, record.color.g or 255,
							record.color.b or 255, record.color.a or 255))
					end
					for index, value in ipairs(record.bodygroups or {}) do entity:SetBodygroup(index - 1, value) end
					local physics = entity:GetPhysicsObject()
					if IsValid(physics) then
						physics:EnableMotion(record.motion == true)
						physics:EnableGravity(false)
						if record.motion == true then physics:Wake() else physics:Sleep() end
					end
					indexRestoredOwnership(self, entity, record)
					self.PersistentEntities[id] = entity
					DRP.Properties:IndexEntity(entity, propertyID)
					perOwner[ownerID] = ownerCount + 1
					weightPerOwner[ownerID] = ownerWeight + weight
					if isComplex then complexPerOwner[ownerID] = ownerComplex + 1 end
					restored = restored + 1
				else
					entity:Remove()
					rejected[#rejected + 1] = id
				end
			else
				rejected[#rejected + 1] = id
			end
		else
			rejected[#rejected + 1] = id
		end
	end

	for _, id in ipairs(rejected) do self.PersistentRecords[id] = nil self.PersistentEntities[id] = nil end
	self.RestoringPersistence = false
	if #rejected > 0 then self:MarkPersistenceDirty() end
	print(string.format("[DRP PROPS] restored=%d rejected=%d persistent=%d cap=%d",
		restored, #rejected, table.Count(self.PersistentRecords), self.MaxPerPlayer))
	return true
end

function Props.TransferOwnership(ent, newOwner)
	if not IsValid(ent) or not IsValid(newOwner) or not newOwner:IsPlayer() then return false end
	local countsAsProp = ent.DRPTrackedCountsAsProp == true
	local cleanupType = countsAsProp and "props" or "sents"
	Props.MakeWorldEntity(ent)
	trackOwnedEntity(newOwner, ent, cleanupType, countsAsProp)
	return Props.IsOwnedBy(newOwner, ent)
end
DRP.Props.TransferOwnership = Props.TransferOwnership

function Props.MakeWorldEntity(ent)
	if not IsValid(ent) then return false end
	Props:ForgetPersistentEntity(ent)
	local owner = Props.ByEntity[ent]
	local ownerID = ent.DRPTrackedOwnerID
	if IsValid(owner) and Props.ByPlayer[owner] then Props.ByPlayer[owner][ent] = nil end
	if IsValid(owner) and cleanup.GetList then
		local cleanupTypes = cleanup.GetList()[owner:UniqueID()] or {}
		for _, entities in pairs(cleanupTypes) do
			for index = #entities, 1, -1 do if entities[index] == ent then table.remove(entities, index) end end
		end
	end
	if ownerID and Props.ByOwnerID[ownerID] then Props.ByOwnerID[ownerID][ent] = nil end
	if ownerID and ent.DRPTrackedCountsAsProp then
		Props.CountByOwnerID[ownerID] = math.max(0, (Props.CountByOwnerID[ownerID] or 0) - 1)
		Props.WeightByOwnerID[ownerID] = math.max(0, (Props.WeightByOwnerID[ownerID] or 0) - (ent.DRPPropWeight or 0))
		if (ent.DRPPropWeight or 0) >= Props.ComplexWeightThreshold then
			Props.ComplexCountByOwnerID[ownerID] = math.max(0, (Props.ComplexCountByOwnerID[ownerID] or 0) - 1)
		end
		Props.TotalPropCount = math.max(0, Props.TotalPropCount - 1)
		Props.TotalPropWeight = math.max(0, Props.TotalPropWeight - (ent.DRPPropWeight or 0))
	end
	Props.ByEntity[ent] = nil
	Props.UnregisterLimitedEntity(ent)
	ent.DRPTrackedOwnerID = nil
	ent.DRPTrackedCountsAsProp = nil
	ent.DRPOwnerSteamID = nil
	ent:SetCreator(NULL)
	return true
end
DRP.Props.MakeWorldEntity = Props.MakeWorldEntity

function Props.RemovePropertyEntities(propertyID)
	local entities = DRP.Properties and DRP.Properties.EntitiesByProperty[tonumber(propertyID)] or {}
	for entity in pairs(entities) do if IsValid(entity) then entity:Remove() end end
end

function Props.RemovePropertyMemberEntities(propertyID, ownerID)
	local entities = DRP.Properties and DRP.Properties.EntitiesByProperty[tonumber(propertyID)] or {}
	for entity in pairs(entities) do
		if IsValid(entity) and Props.OwnerID(entity) == tostring(ownerID) then entity:Remove() end
	end
end

DRP.Props.RemovePropertyEntities = Props.RemovePropertyEntities
DRP.Props.RemovePropertyMemberEntities = Props.RemovePropertyMemberEntities


Props.PersistenceModuleLoaded = true
