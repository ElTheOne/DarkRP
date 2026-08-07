local WorldEntities = {
	Records = {},
	ByID = {},
	NextID = 1,
	DataPath = "darkrp/world_entities_" .. game.GetMap():gsub("[^%w_%-]", "_") .. ".json"
}

DRP.WorldEntities = WorldEntities
DRP.Services.Register("world_entities", WorldEntities)

local SELECT = "drp_tool_select_v1"
util.AddNetworkString(SELECT)

local function owner(ply)
	return IsValid(ply) and DRP.Admin and DRP.Admin.IsOwner(ply)
end

local function vectorData(value) return { x = value.x, y = value.y, z = value.z } end
local function angleData(value) return { p = value.p, y = value.y, r = value.r } end
local function toVector(value) return Vector(tonumber(value.x) or 0, tonumber(value.y) or 0, tonumber(value.z) or 0) end
local function toAngle(value) return Angle(tonumber(value.p) or 0, tonumber(value.y) or 0, tonumber(value.r) or 0) end

function WorldEntities:Save()
	file.CreateDir("darkrp")
	file.Write(self.DataPath, util.TableToJSON({ next_id = self.NextID, records = self.Records }, true))
end

function WorldEntities:Capture(entity, id)
	local color = entity:GetColor()
	local record = {
		id = id,
		class = entity:GetClass(),
		model = entity:GetModel() or "",
		position = vectorData(entity:GetPos()),
		angles = angleData(entity:GetAngles()),
		map_id = entity:MapCreationID() >= 0 and entity:MapCreationID() or nil,
		skin = entity:GetSkin() or 0,
		material = entity:GetMaterial() or "",
		color = { r = color.r, g = color.g, b = color.b, a = color.a },
		job_entity_key = entity.DRPJobEntityKey,
		job_entity_name = entity:GetNW2String("DRPJobEntityName", ""),
		weapon = entity:GetNW2String("DRPWeapon", ""),
		count = entity:GetNW2Int("DRPCount", 0),
		drug = entity:GetNW2String("DRPDrug", ""),
		armory = entity:GetNW2Bool("DRPPoliceArmory", false),
		evidence = entity:GetNW2Bool("DRPEvidenceLocker", false),
		treasury = entity:GetNW2Bool("DRPTreasuryVault", false) or entity.DRPTreasuryVault == true,
		salvage_id = entity.DRPSalvageID
	}
	return record
end

function WorldEntities:Apply(entity, record)
	entity:SetPos(toVector(record.position or {}))
	entity:SetAngles(toAngle(record.angles or {}))
	if record.skin then entity:SetSkin(record.skin) end
	if record.material and record.material ~= "" then entity:SetMaterial(record.material) end
	if record.color then entity:SetColor(Color(record.color.r or 255, record.color.g or 255, record.color.b or 255, record.color.a or 255)) end
	entity.DRPPersistentWorldID = record.id
	entity.DRPJobEntityKey = record.job_entity_key
	if record.job_entity_name then entity:SetNW2String("DRPJobEntityName", record.job_entity_name) end
	if record.weapon then entity:SetNW2String("DRPWeapon", record.weapon) end
	if record.count then entity:SetNW2Int("DRPCount", record.count) end
	if record.drug then entity:SetNW2String("DRPDrug", record.drug) end
	if record.armory and DRP.Armory then DRP.Armory:RegisterEntity(entity) end
	if record.evidence and DRP.JobEntityService then DRP.JobEntityService.EvidenceLocker = entity entity:SetNW2Bool("DRPEvidenceLocker", true) end
	if record.treasury and DRP.Treasury then
		local registered, reason = DRP.Treasury:RegisterEntity(entity)
		if not registered then
			ErrorNoHalt("[DRP] failed to register persistent Treasury Vault: " .. tostring(reason) .. "\n")
			return false
		end
	end
	if DRP.Salvage and (record.salvage_id or entity:GetClass() == "drp_salvage_dumpster" or entity:GetClass() == "drp_salvage_trashcan") then
		local registered, reason = DRP.Salvage:RegisterEntity(entity, record.salvage_id and tostring(record.salvage_id) or nil)
		if not registered then
			ErrorNoHalt("[DRP] failed to register persistent salvage container: " .. tostring(reason) .. "\n")
			return false
		end
	end
	local physics = entity:GetPhysicsObject()
	if IsValid(physics) then physics:EnableMotion(false) physics:Sleep() end
	self.ByID[record.id] = entity
	return true
end

function WorldEntities:Restore()
	for _, record in ipairs(self.Records) do
		local entity
		if record.map_id then
			for _, candidate in ents.Iterator() do if candidate:MapCreationID() == record.map_id then entity = candidate break end end
		else
			entity = ents.Create(tostring(record.class or ""))
			if IsValid(entity) then
				if record.model and record.model ~= "" then entity:SetModel(record.model) end
				entity:SetPos(toVector(record.position or {}))
				entity:SetAngles(toAngle(record.angles or {}))
				entity:Spawn()
				entity:Activate()
			end
		end
		if IsValid(entity) then
			if self:Apply(entity, record) == false then entity:Remove() end
		else
			ErrorNoHalt("[DRP] failed to restore persistent entity #" .. tostring(record.id) .. " (" .. tostring(record.class) .. ")\n")
		end
	end
end

function WorldEntities:Target(ply)
	if not owner(ply) or not ply:Alive() then return nil end
	local trace = ply:GetEyeTrace()
	local entity = trace.Entity
	if not IsValid(entity) or entity:IsPlayer() or entity:IsWorld() or entity:GetPos():DistToSqr(ply:GetPos()) > 262144 then return nil end
	return entity
end

function WorldEntities:PersistAimed(ply, updating)
	local entity = self:Target(ply)
	if not IsValid(entity) then DRP.Net.Notify(ply, "Aim at a valid nearby entity.", 3) return false end
	local id = tonumber(entity.DRPPersistentWorldID)
	if not id then id = self.NextID self.NextID = self.NextID + 1 end
	local record = self:Capture(entity, id)
	local replaced = false
	for index, existing in ipairs(self.Records) do if existing.id == id then self.Records[index] = record replaced = true break end end
	if not replaced then self.Records[#self.Records + 1] = record end
	entity.DRPPersistentWorldID = id
	self.ByID[id] = entity
	if DRP.Services.Get("props") and DRP.Services.Get("props").MakeWorldEntity then DRP.Services.Get("props").MakeWorldEntity(entity) end
	self:Save()
	DRP.Net.Notify(ply, (updating or replaced) and "Persistent entity position updated." or "Entity will now persist across restarts.", 1)
	if DRP.Audit then DRP.Audit.Log(ply, replaced and "world_entity_updated" or "world_entity_persisted", entity, "#" .. id .. " " .. entity:GetClass()) end
	return true
end

function WorldEntities:UnpersistAimed(ply)
	local entity = self:Target(ply)
	local id = IsValid(entity) and tonumber(entity.DRPPersistentWorldID)
	if not id then DRP.Net.Notify(ply, "That entity is not persistent.", 3) return false end
	for index = #self.Records, 1, -1 do if self.Records[index].id == id then table.remove(self.Records, index) end end
	self.ByID[id] = nil
	entity.DRPPersistentWorldID = nil
	self:Save()
	DRP.Net.Notify(ply, "Entity will no longer return after a restart. It was not deleted.", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "world_entity_unpersisted", entity, "#" .. id) end
	return true
end

function WorldEntities:Start()
	local decoded = util.JSONToTable(file.Read(self.DataPath, "DATA") or "")
	if istable(decoded) then self.Records = istable(decoded.records) and decoded.records or {} self.NextID = math.max(1, math.floor(tonumber(decoded.next_id) or 1)) end
	hook.Add("InitPostEntity", "DRP.WorldEntities.Restore", function() timer.Simple(0, function() self:Restore() end) end)
end

function WorldEntities:Stop()
	hook.Remove("InitPostEntity", "DRP.WorldEntities.Restore")
	self:Save()
end

DRP.Net.Receive(SELECT, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "tool_select", 0.25, 4) then return end
	local mode = string.lower(string.sub(net.ReadString(), 1, 64))
	if mode == "drp_persistence" then
		if not owner(ply) then return end
		if not ply:HasWeapon("weapon_drp_persistence_tool") then ply:Give("weapon_drp_persistence_tool") end
		ply:SelectWeapon("weapon_drp_persistence_tool")
		return
	end
	if mode == "drp_property_zone" and (not DRP.Properties or not DRP.Properties.CanConfigure(ply)) then return end
	if DRP.JobService and DRP.JobService.EnsureSandboxWeapons then DRP.JobService:EnsureSandboxWeapons() end
	local stored = weapons.GetStored("gmod_tool")
	local liveToolgun = ply:GetWeapon("gmod_tool")
	local registered = (stored and istable(stored.Tool) and istable(stored.Tool[mode]))
		or (IsValid(liveToolgun) and istable(liveToolgun.Tool) and istable(liveToolgun.Tool[mode]))
		or GetConVar("toolmode_allow_" .. mode) ~= nil
	if not registered then
		DRP.Net.Notify(ply, "That Tool Gun mode is not registered on the server: " .. mode, 3)
		return
	end
	if not DRP.JobService or not DRP.JobService.GiveUtilityWeapon(ply, "gmod_tool", false) then
		DRP.Net.Notify(ply, "The Tool Gun could not be equipped. Check the server console for [DRP JOBS].", 3)
		return
	end
	ply:ConCommand("gmod_toolmode " .. mode)
	ply:SelectWeapon("gmod_tool")
end)
