DRP.WeaponCaseWorkshopID = "542866829"
DRP.WeaponCaseModel = "models/ptejack/props/crates/weapons_crate.mdl"
DRP.WeaponCaseFallbackModel = "models/props_c17/briefcase001a.mdl"

DRP.JobEntities = {
	{ key = "pistol_crate", name = "Glock Case", class = "drp_weapon_crate", model = DRP.WeaponCaseModel, job = "gun_dealer", price = 900, weapon = "arc9_go_glock", count = 10, category = "Gun Dealer" },
	{ key = "smg_crate", name = "MP5 Case", class = "drp_weapon_crate", model = DRP.WeaponCaseModel, job = "gun_dealer", price = 1800, weapon = "arc9_go_mp5", count = 8, category = "Gun Dealer" },
	{ key = "shotgun_crate", name = "Nova Case", class = "drp_weapon_crate", model = DRP.WeaponCaseModel, job = "gun_dealer", price = 2400, weapon = "arc9_go_nova", count = 6, category = "Gun Dealer" },
	{ key = "rifle_crate", name = "AK-47 Case", class = "drp_weapon_crate", model = DRP.WeaponCaseModel, job = "gun_dealer", price = 3500, weapon = "arc9_go_ak47", count = 5, category = "Gun Dealer" },
	{ key = "marksman_crate", name = "Scout Case", class = "drp_weapon_crate", model = DRP.WeaponCaseModel, job = "gun_dealer", price = 4000, weapon = "arc9_go_scout", count = 4, category = "Gun Dealer" },
	{ key = "tip_jar", name = "Tip Jar", class = "drp_tip_jar", model = "models/props_lab/jar01b.mdl", job = "hobo", price = 0, countLimit = 1, category = "Hobo" },
	{ key = "evidence_locker", name = "Evidence Locker", class = "drp_evidence_locker", model = "models/props_c17/Lockers001a.mdl", police = true, ownerOnly = true, price = 0, countLimit = 1, category = "Police Infrastructure" },
	{ key = "jailer", name = "Jailer", class = "drp_jailer", model = "models/Humans/Group03m/male_09.mdl", police = true, ownerOnly = true, price = 0, countLimit = 1, category = "Police Infrastructure" },
	{ key = "police_armory", name = "Police Armory", class = "drp_police_armory", model = "models/props_c17/Lockers001a.mdl", police = true, ownerOnly = true, price = 0, countLimit = 1, category = "Police Infrastructure" },
	{ key = "treasury_vault", name = "Treasury Vault", class = "drp_treasury_vault", model = "models/props_c17/Lockers001a.mdl", ownerOnly = true, price = 0, countLimit = 1, category = "Government Infrastructure" },
	{ key = "salvage_dumpster", name = "Salvage Dumpster", class = "drp_salvage_dumpster", model = "models/props_junk/TrashDumpster01a.mdl", ownerOnly = true, price = 0, countLimit = 16, category = "Server Infrastructure" },
	{ key = "salvage_trashcan", name = "Salvage Trashcan", class = "drp_salvage_trashcan", model = "models/props_junk/TrashBin01a.mdl", ownerOnly = true, price = 0, countLimit = 32, category = "Server Infrastructure" },
	{ key = "crafting_table", name = "Gunsmithing Workbench", class = "drp_crafting_table", model = "models/props_c17/FurnitureTable001a.mdl", price = 1500, countLimit = 3, limitedKind = "production", crafting = true, category = "Production" },
	{ key = "drug_heroin", name = "Heroin", class = "drp_drug", model = "models/props_junk/garbage_bag001a.mdl", job = "drug_dealer", price = 450, drug = "heroin", category = "Drug Dealer" },
	{ key = "drug_speed", name = "Speed", class = "drp_drug", model = "models/props_lab/jar01a.mdl", job = "drug_dealer", price = 300, drug = "speed", category = "Drug Dealer" },
	{ key = "drug_weed", name = "Weed", class = "drp_drug", model = "models/props_lab/box01a.mdl", job = "drug_dealer", price = 100, drug = "weed", category = "Drug Dealer" },
	{ key = "drug_pcp", name = "PCP", class = "drp_drug", model = "models/props_junk/garbage_metalcan001a.mdl", job = "drug_dealer", price = 350, drug = "pcp", category = "Drug Dealer" },
	{ key = "drug_crack", name = "Crack", class = "drp_drug", model = "models/props_lab/jar01b.mdl", job = "drug_dealer", price = 500, drug = "crack", category = "Drug Dealer" },
	{ key = "drug_fentanyl", name = "Fentanyl", class = "drp_drug", model = "models/props_junk/garbage_plasticbottle003a.mdl", job = "drug_dealer", price = 600, drug = "fentanyl", category = "Drug Dealer" },
	{ key = "zeros_meth_tent", name = "Meth Tent Kit", class = "zmlab2_tent", model = "models/zerochain/props_methlab/zmlab2_tentkit.mdl", job = "drug_dealer", price = 1000, countLimit = 1, limitedKind = "production", category = "Meth Production" },
	{ key = "zeros_meth_equipment", name = "Meth Equipment Crate", class = "zmlab2_equipment", model = "models/zerochain/props_methlab/zmlab2_chest.mdl", job = "drug_dealer", price = 1000, countLimit = 1, limitedKind = "production", category = "Meth Production" },
	{ key = "coca_wild", name = "Wild Coca Plant", class = "drp_coca_wild", model = DRP.CocaineModel("wild"), ownerOnly = true, price = 0, countLimit = 24, category = "Cocaine Infrastructure" },
	{ key = "cocaine_buyer", name = "Narcotics Buyer", class = "drp_cocaine_buyer", model = DRP.CocaineModel("buyer"), ownerOnly = true, price = 0, countLimit = 4, category = "Cocaine Infrastructure" },
	{ key = "coca_pot", name = "Coca Growing Pot", class = "drp_coca_pot", model = DRP.CocaineModel("pot"), job = "drug_dealer", price = 220, countLimit = 8, category = "Cocaine Production" },
	{ key = "cocaine_bucket", name = "Mixing Bucket", class = "drp_cocaine_bucket", model = DRP.CocaineModel("bucket"), job = "drug_dealer", price = 260, countLimit = 4, category = "Cocaine Production" },
	{ key = "cocaine_petroleum", name = "Petroleum Can", class = "drp_cocaine_petroleum", model = DRP.CocaineModel("petroleum"), job = "drug_dealer", price = 175, countLimit = 4, limitedKind = "drug", category = "Cocaine Production" },
	{ key = "cocaine_hotplate", name = "Portable Hotplate", class = "drp_cocaine_hotplate", model = DRP.CocaineModel("hotplate"), job = "drug_dealer", price = 540, countLimit = 2, category = "Cocaine Production" },
	{ key = "narcotics_table", name = "Narcotics Table", class = "drp_narcotics_table", model = DRP.CocaineModel("table"), job = "drug_dealer", price = 1350, countLimit = 1, category = "Cocaine Production" }
}

if DRP.DropPolicy then
	for _, definition in ipairs(DRP.JobEntities) do
		DRP.DropPolicy.nonDroppableJobEntities[definition.class] = true
	end
end

local function registerEntity(class, model, title)
	local ENT = {
		Type = "anim",
		Base = "base_anim",
		PrintName = title,
		Spawnable = false,
		Model = model
	}
	function ENT:Initialize()
		if SERVER then
			local currentModel = self:GetModel()
			if not currentModel or currentModel == "" or currentModel == "models/error.mdl" then
				local wantedModel = self.Model
				if class == "drp_weapon_crate" and not util.IsValidModel(wantedModel) then wantedModel = DRP.WeaponCaseFallbackModel end
				self:SetModel(wantedModel)
			end
			self:PhysicsInit(SOLID_VPHYSICS)
			self:SetMoveType(MOVETYPE_VPHYSICS)
			self:SetSolid(SOLID_VPHYSICS)
			self:SetUseType(SIMPLE_USE)
			local physics = self:GetPhysicsObject()
			if IsValid(physics) then physics:EnableMotion(false) physics:EnableGravity(false) physics:Sleep() end
		end
	end
	function ENT:Use(activator)
		if SERVER and DRP.JobEntityService then DRP.JobEntityService.Use(self, activator) end
	end
	if CLIENT then
		local function removePreview(entity)
			if IsValid(entity.DRPWeaponCasePreview) then entity.DRPWeaponCasePreview:Remove() end
			entity.DRPWeaponCasePreview = nil
			entity.DRPWeaponCasePreviewClass = nil
			entity.DRPWeaponCasePreviewModel = nil
			entity.DRPWeaponCasePreviewCenter = nil
		end

		local function removeCaseBody(entity)
			if IsValid(entity.DRPWeaponCaseBody) then entity.DRPWeaponCaseBody:Remove() end
			entity.DRPWeaponCaseBody = nil
			entity.DRPWeaponCaseVisualMins = nil
			entity.DRPWeaponCaseVisualMaxs = nil
			entity.DRPWeaponCaseVisualOffset = nil
		end

		local function drawCaseBody(entity)
			local wantedModel = DRP.WeaponCaseModel
			local currentModel = string.lower(tostring(entity:GetModel() or ""))
			local hasWantedModel = wantedModel ~= "" and util.IsValidModel(wantedModel)

			-- The server has the proper model mounted, so its normal entity is both
			-- the collision body and the visible body.
			if hasWantedModel and currentModel == string.lower(wantedModel) then
				removeCaseBody(entity)
				entity.DRPWeaponCaseVisualMins = entity:OBBMins()
				entity.DRPWeaponCaseVisualMaxs = entity:OBBMaxs()
				entity.DRPWeaponCaseVisualOffset = Vector()
				entity:DrawModel()
				return
			end

			-- A client cannot render content it has not mounted yet. Keep the
			-- collision fallback visible until Workshop content becomes available.
			if not hasWantedModel then
				removeCaseBody(entity)
				entity.DRPWeaponCaseVisualMins = entity:OBBMins()
				entity.DRPWeaponCaseVisualMaxs = entity:OBBMaxs()
				entity.DRPWeaponCaseVisualOffset = Vector()
				entity:DrawModel()
				return
			end

			-- The dedicated server is using its invisible fallback collision shell,
			-- while the client renders the requested Workshop case over it.
			local body = entity.DRPWeaponCaseBody
			if not IsValid(body) then
				body = ClientsideModel(wantedModel, RENDERGROUP_OPAQUE)
				if not IsValid(body) then
					entity:DrawModel()
					return
				end
				body:SetNoDraw(true)
				body:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
				body:DrawShadow(false)
				entity.DRPWeaponCaseBody = body
				local mins, maxs = body:GetRenderBounds()
				entity.DRPWeaponCaseVisualMins = mins
				entity.DRPWeaponCaseVisualMaxs = maxs
			end

			local visualMins = entity.DRPWeaponCaseVisualMins or Vector()
			local visualOffset = Vector(0, 0, entity:OBBMins().z - visualMins.z)
			entity.DRPWeaponCaseVisualOffset = visualOffset
			body:SetPos(entity:LocalToWorld(visualOffset))
			body:SetAngles(entity:GetAngles())
			body:SetSkin(math.Clamp(entity:GetSkin(), 0, math.max(body:SkinCount() - 1, 0)))
			body:SetupBones()
			body:DrawModel()
		end

		local function weaponWorldModel(weaponClass)
			local stored = weapons.GetStored(weaponClass)
			local listed = (list.Get("Weapon") or {})[weaponClass]
			local worldModel = tostring((stored and stored.WorldModel) or (listed and listed.WorldModel) or "")
			return worldModel ~= "" and util.IsValidModel(worldModel) and worldModel or nil
		end

		local function drawWeaponCase(entity)
			local weaponClass = string.lower(entity:GetNW2String("DRPWeapon", ""))
			if weaponClass == "" then removePreview(entity) return end
			local worldModel = weaponWorldModel(weaponClass)
			if not worldModel then
				if entity.DRPWeaponCasePreviewClass ~= weaponClass then removePreview(entity) entity.DRPWeaponCasePreviewClass = weaponClass end
			else
				local preview = entity.DRPWeaponCasePreview
				if not IsValid(preview) or entity.DRPWeaponCasePreviewModel ~= worldModel then
					removePreview(entity)
					preview = ClientsideModel(worldModel, RENDERGROUP_OPAQUE)
					if IsValid(preview) then
						preview:SetNoDraw(true)
						preview:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
						entity.DRPWeaponCasePreview = preview
						entity.DRPWeaponCasePreviewClass = weaponClass
						entity.DRPWeaponCasePreviewModel = worldModel
						local mins, maxs = preview:GetRenderBounds()
						local weaponLength = math.max(maxs.x - mins.x, maxs.y - mins.y, 1)
						local visualMins = entity.DRPWeaponCaseVisualMins or entity:OBBMins()
						local visualMaxs = entity.DRPWeaponCaseVisualMaxs or entity:OBBMaxs()
						local caseSize = visualMaxs - visualMins
						entity.DRPWeaponCasePreviewScale = math.Clamp(math.max(caseSize.x, caseSize.y) * 0.78 / weaponLength, 0.28, 0.82)
						entity.DRPWeaponCasePreviewCenter = (mins + maxs) * 0.5
					end
				end
				if IsValid(preview) then
					local scale = entity.DRPWeaponCasePreviewScale or 0.6
					preview:SetModelScale(scale, 0)
					local angle = entity:LocalToWorldAngles(Angle(0, 0, 0))
					local center = (entity.DRPWeaponCasePreviewCenter or Vector()) * scale
					local visualMaxs = entity.DRPWeaponCaseVisualMaxs or entity:OBBMaxs()
					local visualOffset = entity.DRPWeaponCaseVisualOffset or Vector()
					local top = entity:LocalToWorld(visualOffset + Vector(0, 0, visualMaxs.z + 1.6))
					local offset = angle:Forward() * center.x + angle:Right() * center.y + angle:Up() * center.z
					preview:SetPos(top - offset)
					preview:SetAngles(angle)
					preview:SetupBones()
					preview:DrawModel()
				end
			end

			local quantity = math.max(0, entity:GetNW2Int("DRPCount", 0))
			local visualMaxs = entity.DRPWeaponCaseVisualMaxs or entity:OBBMaxs()
			local visualOffset = entity.DRPWeaponCaseVisualOffset or Vector()
			local badgePosition = entity:LocalToWorld(visualOffset + Vector(visualMaxs.x * 0.52, visualMaxs.y * 0.5, visualMaxs.z + 2.2))
			local badgeAngle = entity:LocalToWorldAngles(Angle(-90, 0, 0))
			cam.Start3D2D(badgePosition, badgeAngle, 0.045)
				draw.RoundedBox(9, -42, -22, 84, 44, Color(8, 13, 25, 245))
				draw.RoundedBox(9, -42, -22, 5, 44, DRP.UI and DRP.UI.Colors.accent or Color(74, 205, 255))
				draw.SimpleText("×" .. quantity, "DRP.Admin.Header", 4, 0, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			cam.End3D2D()
		end

		function ENT:Draw()
			if class == "drp_treasury_vault" then
				self:DrawModel()
				if EyePos():DistToSqr(self:GetPos()) > 1048576 then return end
				local government = DRP.ClientGovernment or {}
				local balance = math.max(0, math.floor(tonumber(government.treasury) or 0))
				local active = self:GetNW2Bool("DRPTreasuryRaidActive", false)
				local remaining = active and math.max(0, math.ceil(self:GetNW2Float("DRPTreasuryDeadline", 0) - CurTime())) or 0
				local cooldown = math.max(0, self:GetNW2Int("DRPTreasuryCooldownUnix", 0) - os.time())
				local accent = active and Color(255, 92, 112) or Color(80, 218, 159)
				local status = active and ("RAID #" .. self:GetNW2Int("DRPTreasuryIncident", 0) .. "  •  " .. remaining .. "s")
					or (cooldown > 0 and ("SECURED  •  " .. cooldown .. "s") or "SECURE")
				local angle = Angle(0, EyeAngles().y - 90, 90)
				cam.Start3D2D(self:WorldSpaceCenter() + Vector(0, 0, 48), angle, 0.075)
					draw.RoundedBox(10, -165, -52, 330, 104, Color(8, 13, 25, 242))
					draw.RoundedBoxEx(10, -165, -52, 7, 104, accent, true, false, true, false)
					draw.SimpleText("GOVERNMENT TREASURY", "DRP.Admin.Small", -142, -31, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
					draw.SimpleText("$" .. string.Comma(balance), "DRP.Admin.Header", -142, 2, Color(94, 225, 177), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
					draw.SimpleText(status, "DRP.Admin.Small", -142, 33, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				cam.End3D2D()
				return
			end
			if class ~= "drp_weapon_crate" then
				self:DrawModel()
				return
			end
			drawCaseBody(self)
			if EyePos():DistToSqr(self:GetPos()) <= 1048576 then drawWeaponCase(self) end
		end

		function ENT:OnRemove()
			if class == "drp_weapon_crate" then
				removePreview(self)
				removeCaseBody(self)
			end
		end
	end
	scripted_ents.Register(ENT, class)
end

registerEntity("drp_weapon_crate", DRP.WeaponCaseModel, "Weapon Case")
registerEntity("drp_tip_jar", "models/props_lab/jar01b.mdl", "Tip Jar")
registerEntity("drp_evidence_locker", "models/props_c17/Lockers001a.mdl", "Evidence Locker")
registerEntity("drp_police_armory", "models/props_c17/Lockers001a.mdl", "Police Armory")
registerEntity("drp_treasury_vault", "models/props_c17/Lockers001a.mdl", "Treasury Vault")
registerEntity("drp_salvage_dumpster", "models/props_junk/TrashDumpster01a.mdl", "Salvage Dumpster")
registerEntity("drp_salvage_trashcan", "models/props_junk/TrashBin01a.mdl", "Salvage Trashcan")
registerEntity("drp_crafting_table", "models/props_c17/FurnitureTable001a.mdl", "Gunsmithing Workbench")
registerEntity("drp_crafting_item", "models/props_lab/box01a.mdl", "Crafting Item")
registerEntity("drp_drug", "models/props_lab/jar01b.mdl", "Drug Package")

local ammoStack = {
	Type = "anim", Base = "base_anim", PrintName = "Ammunition Stack", Spawnable = false,
	Model = "models/items/boxsrounds.mdl"
}
function ammoStack:Initialize()
	if not SERVER then return end
	if not util.IsValidModel(self:GetModel() or "") then self:SetModel(self.Model) end
	self:PhysicsInit(SOLID_VPHYSICS) self:SetMoveType(MOVETYPE_VPHYSICS) self:SetSolid(SOLID_VPHYSICS) self:SetUseType(SIMPLE_USE)
	local physics = self:GetPhysicsObject()
	if IsValid(physics) then physics:Wake() end
end
if CLIENT then function ammoStack:Draw() self:DrawModel() end end
scripted_ents.Register(ammoStack, "drp_ammo_stack")

local jailer = {
	Type = "anim",
	Base = "base_anim",
	PrintName = "Jailer",
	Spawnable = true,
	AutomaticFrameAdvance = true,
	Model = "models/Humans/Group03m/male_09.mdl"
}
function jailer:Initialize()
	if SERVER then
		self:SetModel(self.Model)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		self:SetSequence(self:LookupSequence("idle_all_01"))
		self:SetNW2Bool("DRPJailer", true)
		local physics = self:GetPhysicsObject()
		if IsValid(physics) then physics:EnableMotion(false) physics:EnableGravity(false) physics:Sleep() end
	end
end
function jailer:Use(activator)
	if SERVER and DRP.JobEntityService then DRP.JobEntityService.Use(self, activator) end
end
if CLIENT then function jailer:Draw() self:DrawModel() end end
scripted_ents.Register(jailer, "drp_jailer")

local keyModelCandidates = {
	view = {
		"models/craphead_scripts/adv_keys/weapons/c_key.mdl",
		"models/weapons/c_keys.mdl",
		"models/weapons/c_key.mdl",
		"models/weapons/v_keys.mdl",
		"models/weapons/v_key.mdl",
		"models/weapons/v_adv_keys.mdl",
		"models/craphead_scripts/adv_keys/c_keys.mdl",
		"models/craphead_scripts/adv_keys/v_keys.mdl",
		"models/craphead_scripts/advanced_keys/c_keys.mdl",
		"models/craphead_scripts/advanced_keys/v_keys.mdl",
		"models/craphead_scripts/keys/c_keys.mdl",
		"models/craphead_scripts/keys/v_keys.mdl"
	},
	world = {
		"models/craphead_scripts/adv_keys/weapons/w_key.mdl",
		"models/weapons/w_keys.mdl",
		"models/weapons/w_key.mdl",
		"models/weapons/w_adv_keys.mdl",
		"models/craphead_scripts/adv_keys/w_keys.mdl",
		"models/craphead_scripts/advanced_keys/w_keys.mdl",
		"models/craphead_scripts/keys/w_keys.mdl"
	}
}

local function findKeyModel(kind)
	for _, path in ipairs(keyModelCandidates[kind]) do
		if util.IsValidModel(path) then return path end
	end

	-- The content pack has changed its internal namespace between releases.
	-- Discover the mounted model without coupling the gamemode to one revision.
	local roots = {
		"models/craphead_scripts",
		"models/advanced_keys",
		"models/advancedkeys",
		"models/weapons"
	}
	local wantedWorld = kind == "world"
	local visited, found = {}, nil
	local function scan(directory, depth)
		if found or depth > 5 or visited[directory] then return end
		visited[directory] = true
		local files, directories = file.Find(directory .. "/*", "GAME")
		for _, filename in ipairs(files or {}) do
			local lower = string.lower(filename)
			if string.EndsWith(lower, ".mdl") and string.find(lower, "key", 1, true) then
				local isWorld = string.StartWith(lower, "w_") or string.find(lower, "world", 1, true) ~= nil
				local isView = string.StartWith(lower, "c_") or string.StartWith(lower, "v_") or string.find(lower, "view", 1, true) ~= nil
				if (wantedWorld and isWorld) or (not wantedWorld and isView) then
					local candidate = directory .. "/" .. filename
					if util.IsValidModel(candidate) then found = candidate return end
				end
			end
		end
		for _, child in ipairs(directories or {}) do scan(directory .. "/" .. child, depth + 1) end
	end
	for _, root in ipairs(roots) do scan(root, 0) end
	return found
end

local keysViewModel = findKeyModel("view") or "models/weapons/c_arms.mdl"
local keysWorldModel = findKeyModel("world") or ""

local keys = {
	Base = "weapon_base",
	PrintName = "Keys",
	Author = "UltraRP",
	Instructions = "Primary: lock door. Secondary: unlock door.",
	Spawnable = false,
	UseHands = true,
	ViewModel = keysViewModel,
	WorldModel = keysWorldModel,
	DrawAmmo = false,
	DrawCrosshair = false,
	HoldType = "normal",
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
}
function keys:Initialize() self:SetHoldType("normal") end
function keys:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 0.5)
	if SERVER and DRP.Doors then DRP.Doors.SetLocked(self:GetOwner(), true) end
end
function keys:SecondaryAttack()
	self:SetNextSecondaryFire(CurTime() + 0.5)
	if SERVER and DRP.Doors then DRP.Doors.SetLocked(self:GetOwner(), false) end
end
weapons.Register(keys, "weapon_drp_keys")

if CLIENT then
	local function refreshMountedKeyModels()
		local view = findKeyModel("view")
		local world = findKeyModel("world")
		if view then keysViewModel = view end
		if world then keysWorldModel = world end
		local stored = weapons.GetStored("weapon_drp_keys")
		if not stored then return end
		stored.ViewModel = keysViewModel
		stored.WorldModel = keysWorldModel
	end

	hook.Add("InitPostEntity", "DRP.Keys.ResolveWorkshopModels", refreshMountedKeyModels)
	hook.Add("OnReloaded", "DRP.Keys.ResolveWorkshopModels", refreshMountedKeyModels)
	timer.Simple(1, refreshMountedKeyModels)

	concommand.Add("drp_keys_model_status", function()
		local stored = weapons.GetStored("weapon_drp_keys") or {}
		local activeView = tostring(stored.ViewModel or keysViewModel)
		local activeWorld = tostring(stored.WorldModel or keysWorldModel)
		print(string.format("[DRP KEYS] view=%s valid=%s world=%s valid=%s",
			activeView, tostring(util.IsValidModel(activeView)),
			activeWorld ~= "" and activeWorld or "none",
			tostring(activeWorld ~= "" and util.IsValidModel(activeWorld))))
	end)
end

local pocket = {
	Base = "weapon_base",
	PrintName = "Hands",
	Author = "UltraRP",
	Instructions = "Primary: pick up aimed item. Secondary: open Hands. Reload: use selected drug.",
	Spawnable = false,
	UseHands = true,
	ViewModel = "models/weapons/c_arms.mdl",
	WorldModel = "",
	HoldType = "normal",
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
}
function pocket:Initialize() self:SetHoldType("normal") end
function pocket:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 0.5)
	if SERVER and DRP.Inventory then DRP.Inventory.PocketAimed(self:GetOwner()) end
end
function pocket:SecondaryAttack()
	self:SetNextSecondaryFire(CurTime() + 0.5)
	if SERVER and DRP.Inventory then DRP.Inventory.Open(self:GetOwner()) end
end
function pocket:Reload()
	if self.DRPNextReload and self.DRPNextReload > CurTime() then return end
	self.DRPNextReload = CurTime() + 0.5
	if SERVER and DRP.Inventory then DRP.Inventory.ConsumeSelected(self:GetOwner()) end
end
weapons.Register(pocket, "weapon_drp_pocket")

local taser = {
	Base = "weapon_base",
	PrintName = "Police Taser",
	Author = "UltraRP",
	Instructions = "Primary: stun an incident-authorized suspect.",
	Spawnable = false,
	UseHands = true,
	ViewModel = "models/weapons/c_pistol.mdl",
	WorldModel = "models/weapons/w_pistol.mdl",
	HoldType = "pistol",
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
}
function taser:Initialize() self:SetHoldType("pistol") end
function taser:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 1.5)
	self:SendWeaponAnim(ACT_VM_PRIMARYATTACK)
	local owner = self:GetOwner()
	if IsValid(owner) then owner:SetAnimation(PLAYER_ATTACK1) end
	if SERVER and DRP.Legal then DRP.Legal.TaseAimed(owner) end
end
weapons.Register(taser, "weapon_drp_taser")

local cuffs = {
	Base = "weapon_base",
	PrintName = "Handcuffs",
	Author = "UltraRP",
	Instructions = "Primary: cuff or take custody. Secondary: toggle escort. Reload: release cuffs.",
	Spawnable = false,
	UseHands = true,
	ViewModel = "models/weapons/c_arms.mdl",
	WorldModel = "",
	HoldType = "normal",
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
}
function cuffs:Initialize() self:SetHoldType("normal") end
function cuffs:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 0.8)
	if SERVER and DRP.Legal then DRP.Legal.CuffAimed(self:GetOwner()) end
end
function cuffs:SecondaryAttack()
	self:SetNextSecondaryFire(CurTime() + 0.5)
	if SERVER and DRP.Legal then DRP.Legal.ToggleEscortAimed(self:GetOwner()) end
end
function cuffs:Reload()
	if self.DRPNextRelease and self.DRPNextRelease > CurTime() then return end
	self.DRPNextRelease = CurTime() + 0.8
	if SERVER and DRP.Legal then DRP.Legal.UncuffAimed(self:GetOwner()) end
end
weapons.Register(cuffs, "weapon_drp_cuffs")

local arrest = {
	Base = "weapon_base",
	PrintName = "Arrest Baton",
	Author = "UltraRP",
	Instructions = "Primary: arrest an incident-authorized suspect.",
	Spawnable = false,
	UseHands = true,
	ViewModel = "models/weapons/c_stunstick.mdl",
	WorldModel = "models/weapons/w_stunbaton.mdl",
	HoldType = "melee",
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
}
function arrest:Initialize() self:SetHoldType("melee") end
function arrest:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 1)
	self:SendWeaponAnim(ACT_VM_HITCENTER)
	if SERVER and DRP.Legal then DRP.Legal.ArrestAimed(self:GetOwner()) end
end
weapons.Register(arrest, "weapon_drp_arrest")

local medkit = {
	Base = "weapon_base",
	PrintName = "Medical Kit",
	Author = "UltraRP",
	Instructions = "Primary: heal the player in front of you.",
	Spawnable = true,
	UseHands = true,
	ViewModel = "models/weapons/c_slam.mdl",
	WorldModel = "models/items/healthkit.mdl",
	HoldType = "slam",
	DrawAmmo = false,
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
}
function medkit:Initialize() self:SetHoldType("slam") end
function medkit:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 1.25)
	self:SendWeaponAnim(ACT_VM_PRIMARYATTACK)
	local owner = self:GetOwner()
	if IsValid(owner) then owner:SetAnimation(PLAYER_ATTACK1) end
	if CLIENT then return end
	if IsValid(owner) and DRP.Medical then DRP.Medical:HealAimed(owner) end
end
weapons.Register(medkit, "weapon_drp_medkit")

local defibrillator = {
	Base = "weapon_base",
	PrintName = "Defibrillator",
	Author = "UltraRP",
	Instructions = "Hold primary while aiming at a body to revive its player.",
	Spawnable = true,
	UseHands = true,
	ViewModel = "models/weapons/c_slam.mdl",
	WorldModel = "models/weapons/w_slam.mdl",
	HoldType = "slam",
	DrawAmmo = false,
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
}
function defibrillator:Initialize() self:SetHoldType("slam") end
function defibrillator:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 0.15)
	self:SendWeaponAnim(ACT_VM_PRIMARYATTACK)
	local owner = self:GetOwner()
	if IsValid(owner) then owner:SetAnimation(PLAYER_ATTACK1) end
	if CLIENT then return end
	if IsValid(owner) and DRP.Medical then DRP.Medical:BeginDefibrillation(owner) end
end
function defibrillator:Holster()
	if SERVER and DRP.Medical then DRP.Medical:CancelDefibrillation(self:GetOwner(), "Defibrillation cancelled") end
	return true
end
function defibrillator:OnRemove()
	if SERVER and DRP.Medical then DRP.Medical:CancelDefibrillation(self:GetOwner(), "Defibrillation cancelled") end
end
weapons.Register(defibrillator, "weapon_drp_defibrillator")

local kidnapBaton = {
	Base = "weapon_base",
	PrintName = "Kidnap Baton",
	Category = "Kidnapping",
	Author = "UltraRP",
	Instructions = "Primary: knock out and kidnap a nearby target. Reload: release your victim.",
	Spawnable = false,
	UseHands = true,
	ViewModel = "models/weapons/c_stunstick.mdl",
	WorldModel = "models/weapons/w_stunbaton.mdl",
	HoldType = "melee",
	DrawAmmo = false,
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
}
function kidnapBaton:Initialize() self:SetHoldType("melee") end
function kidnapBaton:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 1)
	self:SendWeaponAnim(ACT_VM_HITCENTER)
	local owner = self:GetOwner()
	if IsValid(owner) then owner:SetAnimation(PLAYER_ATTACK1) end
	if SERVER and DRP.Kidnapping then DRP.Kidnapping:BatonAimed(owner) end
end
function kidnapBaton:Reload()
	if self.DRPNextRelease and self.DRPNextRelease > CurTime() then return end
	self.DRPNextRelease = CurTime() + 0.75
	if SERVER and DRP.Kidnapping then DRP.Kidnapping.Release(self:GetOwner()) end
end
weapons.Register(kidnapBaton, "weapon_drp_kidnap_baton")

local blindfold = {
	Base = "weapon_base",
	PrintName = "Blindfold",
	Category = "Kidnapping",
	Author = "UltraRP",
	Instructions = "Hold primary for 2 seconds to apply. Hold secondary to remove. Reload releases the victim.",
	Spawnable = false,
	UseHands = true,
	ViewModel = "models/weapons/c_arms.mdl",
	WorldModel = "",
	HoldType = "normal",
	DrawAmmo = false,
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }
}
function blindfold:Initialize() self:SetHoldType("normal") end
function blindfold:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 0.15)
	if SERVER and DRP.Kidnapping then DRP.Kidnapping.BeginEffect(self:GetOwner(), "blindfold", false) end
end
function blindfold:SecondaryAttack()
	self:SetNextSecondaryFire(CurTime() + 0.15)
	if SERVER and DRP.Kidnapping then DRP.Kidnapping.BeginEffect(self:GetOwner(), "blindfold", true) end
end
function blindfold:Reload()
	if self.DRPNextRelease and self.DRPNextRelease > CurTime() then return end
	self.DRPNextRelease = CurTime() + 0.75
	if SERVER and DRP.Kidnapping then DRP.Kidnapping.Release(self:GetOwner()) end
end
weapons.Register(blindfold, "weapon_drp_blindfold")

local gag = {
	Base = "weapon_base",
	PrintName = "Gag",
	Category = "Kidnapping",
	Author = "UltraRP",
	Instructions = "Hold primary for 2 seconds to apply. Hold secondary to remove. Reload releases the victim.",
	Spawnable = false,
	UseHands = true,
	ViewModel = "models/weapons/c_arms.mdl",
	WorldModel = "",
	HoldType = "normal",
	DrawAmmo = false,
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }
}
function gag:Initialize() self:SetHoldType("normal") end
function gag:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 0.15)
	if SERVER and DRP.Kidnapping then DRP.Kidnapping.BeginEffect(self:GetOwner(), "gag", false) end
end
function gag:SecondaryAttack()
	self:SetNextSecondaryFire(CurTime() + 0.15)
	if SERVER and DRP.Kidnapping then DRP.Kidnapping.BeginEffect(self:GetOwner(), "gag", true) end
end
function gag:Reload()
	if self.DRPNextRelease and self.DRPNextRelease > CurTime() then return end
	self.DRPNextRelease = CurTime() + 0.75
	if SERVER and DRP.Kidnapping then DRP.Kidnapping.Release(self:GetOwner()) end
end
weapons.Register(gag, "weapon_drp_gag")
