local Admin = DRP.Admin
local Props = DRP.Services.Get("props") or DRP.Props

local requestMessage = "drp_admin_entities_request_v1"
local snapshotMessage = "drp_admin_entities_snapshot_v1"
local actionMessage = "drp_admin_entities_action_v1"

util.AddNetworkString(requestMessage)
util.AddNetworkString(snapshotMessage)
util.AddNetworkString(actionMessage)

local ACTION_REMOVE = 1
local ACTION_FREEZE = 2
local ACTION_UNFREEZE = 3
local ACTION_REMOVE_ALL = 4

local function validSteamID64(value)
	return isstring(value) and #value == 17 and string.match(value, "^%d+$") ~= nil
end

local function onlinePlayer(steamID64)
	return player.GetBySteamID64(steamID64)
end

local function canManageTarget(actor, steamID64)
	if not IsValid(actor) or not Admin.Has(actor, "props") then return false, "You do not have entity-management permission." end
	local target = onlinePlayer(steamID64)
	if target == actor then return true end
	local actorLevel = DRP.AdminRankLevel(Admin.BaseRankKey(actor))
	local targetLevel = DRP.AdminRankLevel(Admin.BaseRankKey(IsValid(target) and target or steamID64))
	if Admin.IsOwner(actor) then return true end
	if targetLevel >= actorLevel then return false, "That player is protected by the staff hierarchy." end
	return true
end

local function entityLabel(entity)
	local class = entity:GetClass()
	local stored = scripted_ents.GetStored(class)
	local definition = stored and stored.t or nil
	local label = definition and (definition.PrintName or definition.Name) or entity.PrintName
	label = string.Trim(tostring(label or ""))
	if label == "" or label == "Scripted Entity" then label = class end
	return string.sub(label, 1, 64)
end

local function entityKind(entity)
	if entity:IsWeapon() then return "Weapon" end
	if entity:IsVehicle() then return "Vehicle" end
	if entity.DRPJobEntityKey or entity.DRPJobEntityOwnerID then return "Job entity" end
	if entity.DRPTrackedCountsAsProp then return "Prop" end
	return "Entity"
end

local function isFrozen(entity)
	local count = entity:GetPhysicsObjectCount()
	if count < 1 then return false end
	for index = 0, count - 1 do
		local physics = entity:GetPhysicsObjectNum(index)
		if IsValid(physics) and physics:IsMotionEnabled() then return false end
	end
	return true
end

local function ownedEntities(steamID64)
	local result = {}
	for entity in pairs((Props and Props.ByOwnerID and Props.ByOwnerID[steamID64]) or {}) do
		if IsValid(entity) and not entity:IsPlayer() and not entity:IsWorld() then result[#result + 1] = entity end
	end
	table.sort(result, function(first, second) return first:EntIndex() < second:EntIndex() end)
	return result
end

local function sendSnapshot(actor, steamID64)
	if not IsValid(actor) then return end
	local allowed, reason = canManageTarget(actor, steamID64)
	if not allowed then DRP.Net.Notify(actor, reason, 3) return end
	local entities = ownedEntities(steamID64)
	local target = onlinePlayer(steamID64)
	local count = math.min(#entities, 255)
	net.Start(snapshotMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(steamID64)
	net.WriteString(string.sub(IsValid(target) and target:Nick()
		or (Admin.Records[steamID64] and Admin.Records[steamID64].name) or steamID64, 1, 64))
	net.WriteUInt(count, 8)
	for index = 1, count do
		local entity = entities[index]
		local position = entity:GetPos()
		net.WriteUInt(entity:EntIndex(), 13)
		net.WriteString(string.sub(entity:GetClass(), 1, 64))
		net.WriteString(entityLabel(entity))
		net.WriteString(string.sub(tostring(entity:GetModel() or ""), 1, 260))
		net.WriteString(entityKind(entity))
		net.WriteVector(position)
		net.WriteBool(isFrozen(entity))
		net.WriteBool(entity.DRPPersistentWorldID ~= nil)
	end
	net.Send(actor)
end

local function ownedBy(entity, steamID64)
	return IsValid(entity) and Props and Props.OwnerID and Props.OwnerID(entity) == steamID64
end

local function traceFor(entity)
	return {
		Entity = entity,
		Hit = true,
		HitPos = entity:WorldSpaceCenter(),
		PhysicsBone = 0
	}
end

local function protectedBySystems(actor, entity, tool)
	if entity.DRPPersistentWorldID then return true, "Persistent world infrastructure must be managed with the persistence tool." end
	actor.DRPAdminEntityManagement = true
	local allowed = hook.Run("CanTool", actor, traceFor(entity), tool)
	actor.DRPAdminEntityManagement = nil
	if allowed == false then
		return true, "That entity is currently protected by a property, raid, or gameplay system."
	end
	return false
end

local function setFrozen(entity, frozen)
	local changed = false
	for index = 0, entity:GetPhysicsObjectCount() - 1 do
		local physics = entity:GetPhysicsObjectNum(index)
		if IsValid(physics) then
			physics:EnableMotion(not frozen)
			if not frozen then physics:Wake() end
			changed = true
		end
	end
	return changed
end

local function removeEntity(actor, steamID64, entity)
	local protected, reason = protectedBySystems(actor, entity, "remover")
	if protected then return false, reason end
	if DRP.Audit then DRP.Audit.Log(actor, "admin_entity_removed", entity, steamID64 .. " " .. entity:GetClass()) end
	entity:Remove()
	return true
end

DRP.Net.Receive(requestMessage, function(_, actor)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local steamID64 = string.sub(net.ReadString(), 1, 17)
	if not validSteamID64(steamID64) or not DRP.Net.Allow(actor, "admin_entities_request", 0.5, 3) then return end
	sendSnapshot(actor, steamID64)
end)

DRP.Net.Receive(actionMessage, function(_, actor)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local steamID64 = string.sub(net.ReadString(), 1, 17)
	local action = net.ReadUInt(3)
	local entityIndex = net.ReadUInt(13)
	if not validSteamID64(steamID64) or not DRP.Net.Allow(actor, "admin_entities_action", 0.2, 6) then return end
	local allowed, reason = canManageTarget(actor, steamID64)
	if not allowed then DRP.Net.Notify(actor, reason, 3) return end

	if action == ACTION_REMOVE_ALL then
		local removed, protected = 0, 0
		for _, entity in ipairs(ownedEntities(steamID64)) do
			local success = removeEntity(actor, steamID64, entity)
			if success then removed = removed + 1 else protected = protected + 1 end
		end
		DRP.Net.Notify(actor, string.format("Removed %d entities%s.", removed, protected > 0 and ("; " .. protected .. " protected") or ""), protected > 0 and 0 or 1)
		timer.Simple(0, function() if IsValid(actor) then sendSnapshot(actor, steamID64) end end)
		return
	end

	local entity = Entity(entityIndex)
	if not ownedBy(entity, steamID64) then DRP.Net.Notify(actor, "That entity is no longer owned by the selected player.", 3) return end
	if action == ACTION_REMOVE then
		local success, removeReason = removeEntity(actor, steamID64, entity)
		if not success then DRP.Net.Notify(actor, removeReason, 3) return end
	elseif action == ACTION_FREEZE or action == ACTION_UNFREEZE then
		local protected, protectReason = protectedBySystems(actor, entity, "physprop")
		if protected then DRP.Net.Notify(actor, protectReason, 3) return end
		if not setFrozen(entity, action == ACTION_FREEZE) then DRP.Net.Notify(actor, "That entity has no manageable physics object.", 3) return end
		if DRP.Audit then DRP.Audit.Log(actor, action == ACTION_FREEZE and "admin_entity_frozen" or "admin_entity_unfrozen", entity, steamID64) end
	else
		return
	end
	timer.Simple(0, function() if IsValid(actor) then sendSnapshot(actor, steamID64) end end)
end)
