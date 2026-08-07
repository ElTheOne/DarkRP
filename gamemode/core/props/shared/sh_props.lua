DRP = DRP or {}
DRP.Props = DRP.Props or {}

-- Server-mounted portal guns are staff utilities. Keep the policy based on
-- class prefixes because the maintained Workshop addon can register variants
-- while retaining the weapon_portalgun naming convention.
DRP.WeaponAccess = DRP.WeaponAccess or {}
DRP.WeaponAccess.MinimumRanks = DRP.WeaponAccess.MinimumRanks or {
	weapon_portalgun = "admin"
}

-- Native Half-Life weapons do not all appear in weapons.GetList(), so keep a
-- shared manifest for the owner browser and the authoritative server give path.
-- Avoid overlapping ordinary classes such as weapon_pistol/weapon_shotgun;
-- those remain available to jobs and weapon crates under their existing rules.
DRP.WeaponAccess.LegacyOwnerWeapons = DRP.WeaponAccess.LegacyOwnerWeapons or {}
local legacyOwnerWeapons = {
	weapon_9mmar = "HL1 MP5",
	weapon_9mmhandgun = "HL1 Glock",
	weapon_egon = "HL1 Gluon Gun",
	weapon_gauss = "HL1 Tau Cannon",
	weapon_handgrenade = "HL1 Hand Grenade",
	weapon_hornetgun = "HL1 Hornet Gun",
	weapon_satchel = "HL1 Satchel Charge",
	weapon_snark = "HL1 Snark",
	weapon_tripmine = "HL1 Tripmine",
	weapon_alyxgun = "HL2 Alyx Gun",
	weapon_annabelle = "HL2 Annabelle",
	weapon_bugbait = "HL2 Bugbait",
	weapon_citizenpackage = "HL2 Citizen Package",
	weapon_citizensuitcase = "HL2 Citizen Suitcase",
	weapon_flechettegun = "HL2 Flechette Gun",
	weapon_oldmanharpoon = "HL2 Harpoon",
	weapon_slam = "HL2 S.L.A.M.",
	weapon_stunstick = "HL2 Stunstick"
}
for class, name in pairs(legacyOwnerWeapons) do
	DRP.WeaponAccess.LegacyOwnerWeapons[class] = {
		ClassName = class,
		PrintName = name,
		Category = string.StartWith(name, "HL1") and "Half-Life 1 — Owner" or "Half-Life 2 — Owner",
		Spawnable = true,
		AdminOnly = true,
		IconOverride = "entities/" .. class .. ".png"
	}
	DRP.WeaponAccess.MinimumRanks[class] = "owner"
end

function DRP.WeaponAccess.RequiredRank(rawClass)
	local class = string.lower(string.Trim(tostring(rawClass or "")))
	local exact = DRP.WeaponAccess.MinimumRanks[class]
	if exact then return exact end
	if string.StartWith(class, "weapon_portalgun") or string.StartWith(class, "weapon_portal_gun") then
		return "admin"
	end
	if string.StartWith(class, "weapon_hl1_") or string.StartWith(class, "weapon_hl2_")
		or string.StartWith(class, "hl1_weapon_") or string.StartWith(class, "hl2_weapon_") then
		return "owner"
	end
	local stored = weapons.GetStored(class)
	local printName = string.lower(tostring(stored and stored.PrintName or ""))
	if string.find(printName, "portal gun", 1, true) then return "admin" end
end

function DRP.WeaponAccess.IsRestricted(rawClass)
	return DRP.WeaponAccess.RequiredRank(rawClass) ~= nil
end

function DRP.WeaponAccess.CanUse(ply, rawClass)
	local required = DRP.WeaponAccess.RequiredRank(rawClass)
	if not required then return true end
	if not SERVER or not IsValid(ply) or not DRP.Admin or not DRP.Admin.RankKey then return false end
	return DRP.AdminRankLevel(DRP.Admin.RankKey(ply)) >= DRP.AdminRankLevel(required)
end

-- The Workshop Portal Gun is inert when given through weapon:Give because its
-- own give_portalgun command is normally responsible for setting these values.
-- Our admin browser gives registered SWEPs directly, so arm every equipped copy
-- on the server without invoking the addon's unrestricted console command.
if SERVER then
	local function armPortalGun(ply, weapon)
		if not IsValid(ply) or not IsValid(weapon) or weapon:GetClass() ~= "weapon_portalgun" then return end
		timer.Simple(0, function()
			if not IsValid(ply) or not IsValid(weapon) or weapon:GetOwner() ~= ply then return end
			local index = math.Clamp(ply:GetNWInt("Portal:Index", 1), 1, 12)
			if isfunction(weapon.SetPortalIndex) then weapon:SetPortalIndex(index) end
			weapon.StoredPortalIndex = index
			weapon:SetNWInt("Portal:Index", index)
			ply:SetNWInt("Portal:Index", index)
			weapon:SetNWInt("FirePortal", 0)
			weapon:SetNWInt("UpgradePortal", 1)
		end)
	end

	DRP.WeaponAccess.ArmPortalGun = armPortalGun

	local function playerOwnsPortal(ply, portal, tracked)
		if tracked[portal] then return true end
		if portal.Ownr == ply or portal:GetOwner() == ply then return true end
		if isfunction(portal.CPPIGetOwner) then
			local ok, owner = pcall(portal.CPPIGetOwner, portal)
			if ok and owner == ply then return true end
		end
		return false
	end

	local function unlinkPortal(portal)
		local other = portal:GetNWEntity("Potal:Other")
		if IsValid(other) then
			other:SetNWBool("Potal:Linked", false)
			other:SetNWEntity("Potal:Other", NULL)
		end
		portal:SetNWBool("Potal:Linked", false)
		portal:SetNWEntity("Potal:Other", NULL)
	end

	-- The Workshop addon cleans portals on death but does not clean them when
	-- the owning player disconnects. Do not call SWEP:CleanPortals here: that
	-- method removes by linkage index and can delete another player's portal if
	-- an addon or map assigned both weapons the same index.
	function DRP.WeaponAccess.RemovePlayerPortals(ply)
		if not ply then return 0 end

		local tracked = {}
		for _, collection in ipairs({ ply.PortalBlue, ply.PortalOrange }) do
			if istable(collection) then
				for _, portal in pairs(collection) do
					if IsValid(portal) then tracked[portal] = true end
				end
			end
		end

		local removed = 0
		for _, portal in ipairs(ents.FindByClass("prop_portal")) do
			if IsValid(portal) and playerOwnsPortal(ply, portal, tracked) then
				local index = portal:GetNWInt("PortalIndex", -1)
				local portalType = portal:GetNWInt("Potal:PortalType", -1)
				if istable(PORTAL_GLOBAL) then
					local collection = portalType == TYPE_BLUE and PORTAL_GLOBAL.Blue
						or portalType == TYPE_ORANGE and PORTAL_GLOBAL.Orange
					if istable(collection) and collection[index] == portal then collection[index] = nil end
				end
				unlinkPortal(portal)
				portal:Remove()
				removed = removed + 1
			end
		end

		-- Remove shots which were already travelling when the player left so they
		-- cannot create a portal after the disconnect cleanup has completed.
		for _, projectile in ipairs(ents.FindByClass("projectile_portal_ball")) do
			if IsValid(projectile) then
				local gun = isfunction(projectile.GetGun) and projectile:GetGun() or nil
				if projectile:GetOwner() == ply
				or (IsValid(gun) and (gun:GetOwner() == ply or gun.Owner == ply)) then
					projectile:Remove()
				end
			end
		end

		ply.PortalBlue = {}
		ply.PortalOrange = {}
		if IsValid(ply) then
			for index = 1, 12 do
				ply:SetNWBool("Portal:BluePresent_" .. index, false)
				ply:SetNWBool("Portal:OrangePresent_" .. index, false)
			end
		end
		return removed
	end

	hook.Add("PlayerDisconnected", "DRP.PortalGun.CleanupOnDisconnect", function(ply)
		DRP.WeaponAccess.RemovePlayerPortals(ply)
	end)

	hook.Add("WeaponEquip", "DRP.PortalGun.ArmDirectGive", function(weapon, ply)
		armPortalGun(ply, weapon)
	end)
	hook.Add("PlayerSwitchWeapon", "DRP.PortalGun.ArmOnSelect", function(ply, _, weapon)
		if IsValid(weapon) and weapon:GetClass() == "weapon_portalgun" then armPortalGun(ply, weapon) end
	end)
else
	concommand.Add("drp_portalgun_status", function()
		local ply = LocalPlayer()
		local weapon = IsValid(ply) and ply:GetWeapon("weapon_portalgun") or NULL
		if not IsValid(weapon) then return print("[DRP PORTAL] weapon=missing") end
		print(string.format(
			"[DRP PORTAL] upgrade=%d fire=%d index=%d viewmodel=%s model_valid=%s",
			weapon:GetNWInt("UpgradePortal", -1),
			weapon:GetNWInt("FirePortal", -1),
			weapon:GetNWInt("Portal:Index", -1),
			tostring(weapon.ViewModel or ""),
			tostring(util.IsValidModel("models/weapons/c_portalgun.mdl"))
		))
	end)
end

DRP.EntityAccess = DRP.EntityAccess or {}
DRP.EntityAccess.MinimumRanks = DRP.EntityAccess.MinimumRanks or {}

function DRP.EntityAccess.RequiredRank(rawClass)
	local class = string.lower(string.Trim(tostring(rawClass or "")))
	return DRP.EntityAccess.MinimumRanks[class]
end

function DRP.EntityAccess.IsRestricted(rawClass)
	return DRP.EntityAccess.RequiredRank(rawClass) ~= nil
end

function DRP.EntityAccess.CanSpawn(ply, rawClass)
	local required = DRP.EntityAccess.RequiredRank(rawClass)
	if not required then return true end
	if not SERVER or not IsValid(ply) or not DRP.Admin or not DRP.Admin.RankKey then return false end
	return DRP.AdminRankLevel(DRP.Admin.RankKey(ply)) >= DRP.AdminRankLevel(required)
end

DRP.Props.Catalog = {
	{model = "models/props_c17/FurnitureTable001a.mdl", name = "Table", category = "Furniture"},
	{model = "models/props_c17/FurnitureChair001a.mdl", name = "Chair", category = "Furniture"},
	{model = "models/props_c17/FurnitureCouch001a.mdl", name = "Couch", category = "Furniture"},
	{model = "models/props_c17/FurnitureDrawer001a.mdl", name = "Drawer", category = "Furniture"},
	{model = "models/props_c17/FurnitureShelf001a.mdl", name = "Shelf", category = "Furniture"},
	{model = "models/props_c17/Lockers001a.mdl", name = "Locker", category = "Furniture"},
	{model = "models/props_c17/Bench01a.mdl", name = "Bench", category = "Furniture"},
	{model = "models/props_wasteland/kitchen_table001a.mdl", name = "Kitchen Table", category = "Furniture"},
	{model = "models/props_wasteland/kitchen_counter001a.mdl", name = "Kitchen Counter", category = "Furniture"},
	{model = "models/props_wasteland/kitchen_chair001a.mdl", name = "Kitchen Chair", category = "Furniture"},
	{model = "models/props_junk/wood_crate001a.mdl", name = "Wood Crate", category = "Containers"},
	{model = "models/props_junk/wood_crate002a.mdl", name = "Large Crate", category = "Containers"},
	{model = "models/props_junk/TrashDumpster02.mdl", name = "Dumpster", category = "Containers"},
	{model = "models/props_junk/TrashBin01a.mdl", name = "Trash Bin", category = "Containers"},
	{model = "models/props_junk/cardboard_box001a.mdl", name = "Cardboard Box", category = "Containers"},
	{model = "models/props_junk/PlasticCrate01a.mdl", name = "Plastic Crate", category = "Containers"},
	{model = "models/props_c17/oildrum001.mdl", name = "Oil Drum", category = "Industrial"},
	{model = "models/props_c17/canister01a.mdl", name = "Canister", category = "Industrial"},
	{model = "models/props_c17/canister02a.mdl", name = "Canister 2", category = "Industrial"},
	{model = "models/props_junk/metal_paintcan001a.mdl", name = "Paint Can", category = "Industrial"},
	{model = "models/props_junk/TrafficCone001a.mdl", name = "Traffic Cone", category = "Industrial"},
	{model = "models/props_lab/reciever01b.mdl", name = "Receiver", category = "Equipment"},
	{model = "models/props_c17/utilityconnecter006c.mdl", name = "Utility Connector", category = "Equipment"}
}

DRP.PropCatalog = DRP.Props.Catalog

function DRP.Props.NormalizeModel(value)
	local model = string.lower(string.Trim(tostring(value or "")))
	model = string.gsub(model, "\\+", "/")
	model = string.gsub(model, "/+", "/")
	if #model < 12 or #model > 260 or string.find(model, "..", 1, true) then return nil end
	if string.sub(model, 1, 7) ~= "models/" or string.sub(model, -4) ~= ".mdl" then return nil end
	return model
end

local frozenPhysicsClasses = {
	prop_physics = true,
	prop_physics_multiplayer = true,
	prop_physics_override = true,
	prop_ragdoll = true,
	prop_ragdoll_attached = true
}

local function isFrozenPhysicsProp(entity)
	return IsValid(entity) and not entity.DRPBreachDebris and frozenPhysicsClasses[entity:GetClass()] == true
end

local function markPropCollision(entity)
	if not isFrozenPhysicsProp(entity) or entity.DRPNoPropCollision then return end
	entity.DRPNoPropCollision = true
	entity:SetCustomCollisionCheck(true)
	entity:CollisionRulesChanged()
end

hook.Add("ShouldCollide", "DRP.Props.NoPropToPropCollision", function(first, second)
	if first.DRPNoPropCollision and second.DRPNoPropCollision then return false end
end)

if CLIENT then
	hook.Add("InitPostEntity", "DRP.Props.MarkMapCollisions", function()
		for _, entity in ents.Iterator() do markPropCollision(entity) end
	end)

	hook.Add("OnEntityCreated", "DRP.Props.MarkNewCollisions", function(entity)
		if not isFrozenPhysicsProp(entity) then return end
		timer.Simple(0, function()
			if IsValid(entity) then markPropCollision(entity) end
		end)
	end)
end

if SERVER then
	local function suppressImpactDamage(entity)
		if not isFrozenPhysicsProp(entity) then return end
		local count = entity:GetPhysicsObjectCount()
		for index = 0, math.max(count - 1, 0) do
			local physics = count > 0 and entity:GetPhysicsObjectNum(index) or entity:GetPhysicsObject()
			if IsValid(physics) then
				physics:AddGameFlag(FVPHYSICS_NO_IMPACT_DMG)
				physics:AddGameFlag(FVPHYSICS_NO_NPC_IMPACT_DMG)
			end
		end
	end

	local function freezePhysicsObject(physics)
		if not IsValid(physics) then return end
		physics:SetVelocity(vector_origin)
		physics:AddAngleVelocity(-physics:GetAngleVelocity())
		physics:EnableGravity(false)
		physics:EnableMotion(false)
		physics:Sleep()
	end

	local function freezeProp(entity)
		if not isFrozenPhysicsProp(entity) then return end
		markPropCollision(entity)
		entity.DRPPhysicsFrozen = true

		local count = entity:GetPhysicsObjectCount()
		if count > 0 then
			for index = 0, count - 1 do freezePhysicsObject(entity:GetPhysicsObjectNum(index)) end
		else
			freezePhysicsObject(entity:GetPhysicsObject())
		end
	end

	-- Exposed for the authoritative ownership hook in sv_props. Props stay
	-- motionless after their owner finishes repositioning them.
	DRP.Props.Freeze = freezeProp
	DRP.Props.SuppressImpactDamage = suppressImpactDamage

	hook.Add("InitPostEntity", "DRP.Props.FreezeMapPhysics", function()
		for _, entity in ents.Iterator() do freezeProp(entity) end
	end)

	hook.Add("OnEntityCreated", "DRP.Props.FreezeNewPhysics", function(entity)
		if not isFrozenPhysicsProp(entity) then return end
		timer.Simple(0, function()
			if IsValid(entity) then freezeProp(entity) end
		end)
	end)

	hook.Add("CanPlayerUnfreeze", "DRP.Props.BlockUnfreeze", function(_, entity)
		if isFrozenPhysicsProp(entity) then return false end
	end)

	hook.Add("GravGunPickupAllowed", "DRP.Props.BlockFrozenGravgun", function(_, entity)
		if isFrozenPhysicsProp(entity) then return false end
	end)

	hook.Add("AllowPlayerPickup", "DRP.Props.BlockFrozenUsePickup", function(_, entity)
		if isFrozenPhysicsProp(entity) then return false end
	end)

	concommand.Add("drp_props_status", function(ply)
		if IsValid(ply) then return end
		local props, physicsObjects, moving, collisionMarked = 0, 0, 0, 0
		for _, entity in ents.Iterator() do
			if isFrozenPhysicsProp(entity) then
				props = props + 1
				if entity.DRPNoPropCollision then collisionMarked = collisionMarked + 1 end
				for index = 0, entity:GetPhysicsObjectCount() - 1 do
					local physics = entity:GetPhysicsObjectNum(index)
					if IsValid(physics) then
						physicsObjects = physicsObjects + 1
						if physics:IsMotionEnabled() then moving = moving + 1 end
					end
				end
			end
		end
		print(string.format("[DRP] props=%d physics_objects=%d moving=%d no_prop_collision=%d", props, physicsObjects, moving, collisionMarked))
	end)
end
