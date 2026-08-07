local Loot = {
	DataPath = "darkrp/death_loot_" .. game.GetMap():gsub("[^%w_%-]", "_") .. ".json",
	Model = "models/props_c17/SuitCase_Passenger_Physics.mdl",
	InteractionDistance = 160,
	NextID = 1,
	Records = {},
	ByEntity = setmetatable({}, { __mode = "k" }),
	Entities = {},
	Stopping = false
}

DRP.DeathLoot = Loot
DRP.Services.Register("death_loot", Loot)

local OPEN = DRP.DeathLootMessages.OPEN
local ACTION = DRP.DeathLootMessages.ACTION
util.AddNetworkString(OPEN)
util.AddNetworkString(ACTION)

local function vectorData(value)
	return { x = value.x, y = value.y, z = value.z }
end

local function angleData(value)
	return { p = value.p, y = value.y, r = value.r }
end

local function appearanceFor(ply)
	local bodygroups = {}
	for index = 0, math.max(0, ply:GetNumBodyGroups() - 1) do bodygroups[tostring(index)] = ply:GetBodygroup(index) end
	return { model = ply:GetModel(), skin = ply:GetSkin(), bodygroups = bodygroups, material = ply:GetMaterial() }
end

local function roleColourFor(ply)
	local job = ply:DRPJob()
	local colour = istable(job) and job.color or nil
	return {
		r = math.Clamp(math.floor(tonumber(colour and colour.r) or 74), 0, 255),
		g = math.Clamp(math.floor(tonumber(colour and colour.g) or 205), 0, 255),
		b = math.Clamp(math.floor(tonumber(colour and colour.b) or 255), 0, 255)
	}
end

local function toVector(value)
	return Vector(tonumber(value and value.x) or 0, tonumber(value and value.y) or 0, tonumber(value and value.z) or 0)
end

local function toAngle(value)
	return Angle(tonumber(value and value.p) or 0, tonumber(value and value.y) or 0, tonumber(value and value.r) or 0)
end

local function canInteract(ply, entity)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() or not IsValid(entity) or entity:GetClass() ~= "drp_death_suitcase" then return false end
	if ply:GetPos():DistToSqr(entity:GetPos()) > Loot.InteractionDistance ^ 2 then return false end
	local trace = util.TraceLine({ start = ply:EyePos(), endpos = entity:WorldSpaceCenter(), mask = MASK_SOLID, filter = ply })
	return not trace.Hit or trace.Entity == entity
end

local function publicItem(record)
	local width, height = DRP.Inventory.Footprint(record)
	return {
		id = tostring(record.id or ""),
		label = tostring(record.label or record.class or "Item"),
		kind = tostring(record.kind or "entity"),
		class = tostring(record.class or ""),
		model = tostring(record.model or ""),
		amount = math.max(1, math.floor(tonumber(record.amount) or 1)),
		x = math.max(1, math.floor(tonumber(record.x) or 1)),
		y = math.max(1, math.floor(tonumber(record.y) or 1)),
		w = math.max(1, math.floor(tonumber(record.w) or width)),
		h = math.max(1, math.floor(tonumber(record.h) or height)),
		rotated = record.rotated == true
	}
end

function Loot:Save()
	file.CreateDir("darkrp")
	local encoded = { next_id = self.NextID, records = {} }
	for id, record in pairs(self.Records) do
		local entity = self.Entities[id]
		if IsValid(entity) then
			record.position = vectorData(entity:GetPos())
			record.angle = angleData(entity:GetAngles())
		end
		encoded.records[id] = record
	end
	file.Write(self.DataPath, util.TableToJSON(encoded, false) or "{}")
end

function Loot:SpawnRecord(record)
	if not istable(record) or not istable(record.items) or #record.items == 0 then return nil end
	local entity = ents.Create("drp_death_suitcase")
	if not IsValid(entity) then return nil end
	entity:SetPos(toVector(record.position))
	entity:SetAngles(toAngle(record.angle))
	entity:Spawn()
	entity:Activate()
	if not IsValid(entity) then return nil end
	entity.DRPDeathLootID = tostring(record.id)
	entity:SetNW2String("DRPDeathLootOwner", tostring(record.owner_name or "Unknown"))
	entity:SetNW2Int("DRPDeathLootCount", #record.items)
	self.ByEntity[entity] = record
	self.Entities[tostring(record.id)] = entity
	return entity
end

function Loot:Create(ply, deathPosition)
	if not IsValid(ply) or not DRP.Inventory or #(ply.DRPPocketItems or {}) == 0 then return 0, 0 end
	local count = #(ply.DRPPocketItems or {})
	local base = isvector(deathPosition) and deathPosition or ply:GetPos()
	local side = ply:GetRight() * 28
	local origin = base + side + Vector(0, 0, 48)
	local trace = util.TraceLine({ start = origin, endpos = origin - Vector(0, 0, 192), mask = MASK_SOLID, filter = ply })
	local position = (trace.Hit and trace.HitPos or base) + (trace.Hit and trace.HitNormal or vector_up) * 7
	local id = tostring(self.NextID)
	self.NextID = self.NextID + 1
	local placeholder = {
		id = id,
		owner_id = ply:SteamID64(),
		owner_name = string.sub(ply:DRPName(), 1, 48),
		owner_job = string.sub(ply:DRPJobName(), 1, 48),
		appearance = appearanceFor(ply),
		role_colour = roleColourFor(ply),
		equipped = DRP.Inventory.Equipment(ply),
		selected = tostring(ply.DRPSelectedPocketID or ""),
		created_at = os.time(),
		revision = 1,
		items = table.Copy(ply.DRPPocketItems or {}),
		position = vectorData(position),
		angle = angleData(Angle(0, ply:EyeAngles().y, 0))
	}
	local entity = self:SpawnRecord(placeholder)
	if not IsValid(entity) then return 0, count end
	local extracted = DRP.Inventory.ExtractAll(ply)
	if not istable(extracted) or #extracted == 0 then
		self.ByEntity[entity], self.Entities[id] = nil, nil
		entity.DRPDeathLootRemoving = true
		entity:Remove()
		return 0, count
	end
	placeholder.items = extracted
	self.Records[id] = placeholder
	entity:SetNW2Int("DRPDeathLootCount", #extracted)
	self:Save()
	if DRP.Audit then DRP.Audit.Log(ply, "death_suitcase_created", entity, #extracted .. " Hands items") end
	return #extracted, 0
end

function Loot:BuildSnapshot(ply, entity)
	if not canInteract(ply, entity) then return nil end
	local record = self.ByEntity[entity]
	if not record then return nil end
	local output = {
		entity = entity:EntIndex(),
		id = tostring(record.id),
		ownerName = tostring(record.owner_name or "Unknown"),
		revision = math.max(0, math.floor(tonumber(record.revision) or 0)),
		source = {
			width = DRP.Inventory.GridWidth,
			height = DRP.Inventory.GridHeight,
			selected = tostring(record.selected or ""),
			equipped = table.Copy(record.equipped or {}),
			items = {},
			identity = tostring(record.owner_name or "Unknown") .. "  •  " .. tostring(record.owner_job or "Citizen"),
			appearance = table.Copy(record.appearance or {}),
			accent = table.Copy(record.role_colour or {})
		},
		hands = DRP.Inventory.BuildSnapshot(ply)
	}
	for _, item in ipairs(record.items or {}) do output.source.items[#output.source.items + 1] = publicItem(item) end
	return output
end

function Loot:SendSnapshot(ply, entity)
	local snapshot = self:BuildSnapshot(ply, entity)
	if not snapshot then return false end
	local compressed = util.Compress(util.TableToJSON(snapshot, false) or "{}") or ""
	if #compressed > 1048575 then return false end
	net.Start(OPEN)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(#compressed, 20)
		net.WriteData(compressed, #compressed)
	net.Send(ply)
	return true
end

function Loot:Open(ply, entity)
	if not canInteract(ply, entity) then
		if IsValid(ply) then DRP.Net.Notify(ply, "Move closer and look directly at the suitcase.", 3) end
		return false
	end
	ply.DRPDeathLootOpen = entity
	return self:SendSnapshot(ply, entity)
end

function Loot:SyncOpen(ply)
	local entity = IsValid(ply) and ply.DRPDeathLootOpen or nil
	if not canInteract(ply, entity) then return false end
	return self:SendSnapshot(ply, entity)
end

function Loot:SyncViewers(entity)
	for _, viewer in ipairs(player.GetHumans()) do
		if viewer.DRPDeathLootOpen == entity then
			if canInteract(viewer, entity) then self:SendSnapshot(viewer, entity) else viewer.DRPDeathLootOpen = nil end
		end
	end
end

function Loot:RemoveEmpty(entity, record)
	if not record or #(record.items or {}) > 0 then return false end
	local id = tostring(record.id)
	self.Records[id], self.Entities[id] = nil, nil
	self.ByEntity[entity] = nil
	for _, viewer in ipairs(player.GetHumans()) do if viewer.DRPDeathLootOpen == entity then viewer.DRPDeathLootOpen = nil end end
	if IsValid(entity) then entity.DRPDeathLootRemoving = true entity:Remove() end
	self:Save()
	return true
end

function Loot:Take(ply, entity, itemID, revision)
	if not canInteract(ply, entity) or ply.DRPDeathLootOpen ~= entity then return false end
	local record = self.ByEntity[entity]
	if not record or tonumber(revision) ~= tonumber(record.revision) then
		DRP.Net.Notify(ply, "The suitcase changed; its contents were refreshed.", 2)
		self:SendSnapshot(ply, entity)
		return false
	end
	local found, index
	for position, item in ipairs(record.items or {}) do if tostring(item.id) == tostring(itemID) then found, index = item, position break end end
	if not found then self:SendSnapshot(ply, entity) return false end
	if not DRP.Inventory.CanInsertRaw(ply, found) then DRP.Net.Notify(ply, "Your Hands do not have enough free space.", 3) return false end
	if not DRP.Inventory.InsertRaw(ply, found) then return false end
	table.remove(record.items, index)
	for slot, equippedID in pairs(record.equipped or {}) do if equippedID == found.id then record.equipped[slot] = nil end end
	if record.selected == found.id then record.selected = record.items[1] and record.items[1].id or "" end
	record.revision = (tonumber(record.revision) or 0) + 1
	entity:SetNW2Int("DRPDeathLootCount", #record.items)
	if DRP.Audit then DRP.Audit.Log(ply, "death_suitcase_looted", entity, tostring(found.label or found.class)) end
	if self:RemoveEmpty(entity, record) then return true end
	self:Save()
	self:SyncViewers(entity)
	return true
end

function Loot:TakeAll(ply, entity, revision)
	if not canInteract(ply, entity) or ply.DRPDeathLootOpen ~= entity then return false end
	local record = self.ByEntity[entity]
	if not record or tonumber(revision) ~= tonumber(record.revision) then self:SendSnapshot(ply, entity) return false end
	local moved = 0
	for index = #(record.items or {}), 1, -1 do
		local item = record.items[index]
		if DRP.Inventory.CanInsertRaw(ply, item) and DRP.Inventory.InsertRaw(ply, item, true) then table.remove(record.items, index) moved = moved + 1 end
	end
	local remaining = {}
	for _, item in ipairs(record.items or {}) do remaining[item.id] = true end
	for slot, equippedID in pairs(record.equipped or {}) do if not remaining[equippedID] then record.equipped[slot] = nil end end
	if record.selected ~= "" and not remaining[record.selected] then record.selected = record.items[1] and record.items[1].id or "" end
	if moved == 0 then DRP.Net.Notify(ply, "Your Hands do not have enough free space.", 3) return false end
	DRP.Inventory.Sync(ply, false)
	DRP.Inventory.QueueSave(ply)
	record.revision = (tonumber(record.revision) or 0) + 1
	entity:SetNW2Int("DRPDeathLootCount", #record.items)
	DRP.Net.Notify(ply, "Looted " .. moved .. " suitcase item" .. (moved == 1 and "." or "s."), 1)
	if DRP.Audit then DRP.Audit.Log(ply, "death_suitcase_looted_all", entity, tostring(moved)) end
	if self:RemoveEmpty(entity, record) then return true end
	self:Save()
	self:SyncViewers(entity)
	return true
end

function Loot:Start()
	self.Stopping = false
	local decoded = util.JSONToTable(file.Read(self.DataPath, "DATA") or "")
	self.NextID = math.max(1, math.floor(tonumber(decoded and decoded.next_id) or 1))
	local restored = {}
	for id, record in pairs(istable(decoded and decoded.records) and decoded.records or {}) do
		if istable(record) and istable(record.items) and #record.items > 0 then
			record.id = tostring(record.id or id)
			self.NextID = math.max(self.NextID, (tonumber(record.id) or 0) + 1)
			record.equipped = istable(record.equipped) and record.equipped or {}
			record.selected = tostring(record.selected or "")
			restored[record.id] = record
		end
	end
	self.Records = restored
	timer.Simple(0, function()
		for _, record in pairs(self.Records) do self:SpawnRecord(record) end
		self:Save()
	end)
end

function Loot:Stop()
	self.Stopping = true
	self:Save()
end

DRP.Net.Receive(ACTION, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "death_loot_action", 0.08, 12) then return end
	local length = net.ReadUInt(16)
	if length <= 0 or length > 32768 then return end
	local json = util.Decompress(net.ReadData(length))
	local data = json and util.JSONToTable(json) or nil
	local entity = net.ReadEntity()
	if not istable(data) or not IsValid(entity) then return end
	if data.action == "close" then
		if ply.DRPDeathLootOpen == entity then ply.DRPDeathLootOpen = nil end
	elseif data.action == "take" then Loot:Take(ply, entity, data.id, data.revision)
	elseif data.action == "take_all" then Loot:TakeAll(ply, entity, data.revision)
	elseif data.action == "refresh" then Loot:Open(ply, entity) end
end)

hook.Add("PlayerDisconnected", "DRP.DeathLoot.ClearViewer", function(ply)
	ply.DRPDeathLootOpen = nil
end)

hook.Add("EntityRemoved", "DRP.DeathLoot.EntityRemoved", function(entity)
	local record = Loot.ByEntity[entity]
	if not record then return end
	Loot.ByEntity[entity] = nil
	Loot.Entities[tostring(record.id)] = nil
	if entity.DRPDeathLootRemoving or Loot.Stopping or #(record.items or {}) == 0 then return end
	record.position, record.angle = vectorData(entity:GetPos()), angleData(entity:GetAngles())
	Loot:Save()
	timer.Simple(0, function() if not Loot.Stopping and Loot.Records[tostring(record.id)] == record then Loot:SpawnRecord(record) end end)
end)

hook.Add("PhysgunPickup", "DRP.DeathLoot.Protect", function(_, entity)
	if Loot.ByEntity[entity] then return false end
end)

hook.Add("GravGunPickupAllowed", "DRP.DeathLoot.ProtectGravGun", function(_, entity)
	if Loot.ByEntity[entity] then return false end
end)

hook.Add("GravGunPunt", "DRP.DeathLoot.ProtectPunt", function(_, entity)
	if Loot.ByEntity[entity] then return false end
end)

hook.Add("AllowPlayerPickup", "DRP.DeathLoot.ProtectUsePickup", function(_, entity)
	if Loot.ByEntity[entity] then return false end
end)

hook.Add("CanDrive", "DRP.DeathLoot.ProtectDrive", function(_, entity)
	if Loot.ByEntity[entity] then return false end
end)

hook.Add("CanPlayerUnfreeze", "DRP.DeathLoot.ProtectUnfreeze", function(_, entity)
	if Loot.ByEntity[entity] then return false end
end)

hook.Add("CanTool", "DRP.DeathLoot.ProtectTools", function(_, trace)
	if trace and Loot.ByEntity[trace.Entity] then return false end
end)

hook.Add("CanProperty", "DRP.DeathLoot.ProtectProperties", function(_, _, entity)
	if Loot.ByEntity[entity] then return false end
end)

hook.Add("EntityTakeDamage", "DRP.DeathLoot.Invulnerable", function(entity, damage)
	if Loot.ByEntity[entity] then damage:SetDamage(0) return true end
end)

hook.Add("DRPMedicalBodyCreated", "DRP.DeathLoot.AlignWithBody", function(_, ply, corpse)
	if not IsValid(ply) or not IsValid(corpse) then return end
	local newest
	for _, record in pairs(Loot.Records) do
		if record.owner_id == ply:SteamID64() and IsValid(Loot.Entities[tostring(record.id)])
			and (not newest or (record.created_at or 0) > (newest.created_at or 0)) then newest = record end
	end
	if not newest or os.time() - (newest.created_at or 0) > 5 then return end
	local entity = Loot.Entities[tostring(newest.id)]
	local origin = corpse:GetPos() + corpse:GetRight() * 28 + Vector(0, 0, 48)
	local trace = util.TraceLine({ start = origin, endpos = origin - Vector(0, 0, 192), filter = { ply, corpse, entity }, mask = MASK_SOLID })
	entity:SetPos((trace.Hit and trace.HitPos or corpse:GetPos()) + (trace.Hit and trace.HitNormal or vector_up) * 7)
	entity:SetAngles(Angle(0, corpse:GetAngles().y, 0))
	Loot:Save()
end)
