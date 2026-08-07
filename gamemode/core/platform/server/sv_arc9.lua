local Integration = {
	WorkshopID = "2910505837",
	SourceDirectory = "addons/arc9_base_source",
	WeaponPackWorkshopID = "2910537020",
	WeaponPackSourceDirectory = "addons/arc9_gunsmith_reloaded_source",
	WeaponPackClassPrefix = "arc9_go_",
	UseWorkshopContent = true,
	-- ARC9 ships thousands of individual assets. Deliver those as packed Workshop
	-- addons while keeping this server's loose Lua editable.
	UseFastDLContent = false,
	FastDLFileCount = 0,
	MaxExplosives = 24,
	MaxAreaEffects = 8,
	MaxExplosiveLifetime = 30,
	ActiveExplosives = 0,
	ActiveAreaEffects = 0,
	TrackedEntities = setmetatable({}, { __mode = "k" }),
	RestrictedAmmoCrateWeaponClasses = {},
	RestrictedAmmoCrateWeaponPrefixes = {
		"arc9_go_nade_"
	},
	RestrictedAmmoCrateTypes = {
		ar2altfire = true,
		c4 = true,
		grenade = true,
		hopwire = true,
		molotov = true,
		rpg_round = true,
		slam = true,
		smg1_grenade = true
	}
}

DRP.ARC9Integration = Integration
DRP.Services.Register("arc9", Integration)

local fastDLRoots = { "materials", "models", "particles", "resource", "shaders", "sound" }
local fastDLExtensions = {
	ani = true,
	mdl = true,
	ogg = true,
	pcf = true,
	phy = true,
	mp3 = true,
	png = true,
	properties = true,
	ttf = true,
	vcs = true,
	vmt = true,
	vtf = true,
	vtx = true,
	vvd = true,
	wav = true
}

local function registerDirectory(physicalDirectory, virtualDirectory, registered)
	local files, directories = file.Find(physicalDirectory .. "/*", "GAME")
	for _, filename in ipairs(files or {}) do
		local extension = string.lower(string.GetExtensionFromFilename(filename) or "")
		local virtualPath = virtualDirectory .. "/" .. filename
		if fastDLExtensions[extension] and not registered[virtualPath] then
			resource.AddSingleFile(virtualPath)
			registered[virtualPath] = true
		end
	end
	for _, directory in ipairs(directories or {}) do
		registerDirectory(physicalDirectory .. "/" .. directory, virtualDirectory .. "/" .. directory, registered)
	end
end

function Integration:RegisterClientContent()
	if self.UseWorkshopContent then
		resource.AddWorkshop(self.WorkshopID)
		resource.AddWorkshop(self.WeaponPackWorkshopID)
	end

	local registered = {}
	if self.UseFastDLContent then
		for _, addonDirectory in ipairs({ "arc9_base_source", "arc9_gunsmith_reloaded_source" }) do
			for _, root in ipairs(fastDLRoots) do
				registerDirectory("addons/" .. addonDirectory .. "/" .. root, root, registered)
			end
		end
	end
	self.FastDLFileCount = table.Count(registered)
	if self.FastDLFileCount > 8192 then
		error("ARC9 FastDL content exceeds Garry's Mod's 8192 downloadable-file limit")
	end
	return self.FastDLFileCount
end

Integration:RegisterClientContent()

function Integration:IsLoaded()
	return istable(ARC9) and isfunction(ARC9.GetAttTable)
end

function Integration:WeaponCount()
	local count = 0
	for _, definition in ipairs(weapons.GetList() or {}) do
		local class = string.lower(tostring(definition.ClassName or definition.Class or definition.Folder or ""))
		if string.StartWith(class, self.WeaponPackClassPrefix) and definition.Spawnable == true then count = count + 1 end
	end
	return count
end

function Integration:IsWeaponPackLoaded()
	return self:WeaponCount() > 0
end

local explosiveAmmoFragments = {
	"c4",
	"claymore",
	"explosive",
	"grenade",
	"landmine",
	"missile",
	"molotov",
	"rocket"
}

local function processedValue(weapon, key)
	if not IsValid(weapon) or not weapon.ARC9 or not isfunction(weapon.GetProcessedValue) then return nil end
	local ok, value = pcall(weapon.GetProcessedValue, weapon, key)
	if ok then return value end
end

local function ammoName(ammo)
	if isnumber(ammo) then ammo = game.GetAmmoName(ammo) end
	return string.lower(string.Trim(tostring(ammo or "")))
end

function Integration:IsAmmoCrateAmmoRestricted(ammo)
	local name = ammoName(ammo)
	if name == "" or name == "-1" then return false, "invalid ammunition" end
	if self.RestrictedAmmoCrateTypes[name] then return true, name end
	for _, fragment in ipairs(explosiveAmmoFragments) do
		if string.find(name, fragment, 1, true) then return true, name end
	end
	return false, name
end

function Integration:IsAmmoCrateWeaponRestricted(weapon)
	if not IsValid(weapon) then return true, "no active weapon" end
	local class = string.lower(weapon:GetClass())
	if self.RestrictedAmmoCrateWeaponClasses[class] then return true, class end
	for _, prefix in ipairs(self.RestrictedAmmoCrateWeaponPrefixes) do
		if string.StartWith(class, prefix) then return true, class end
	end
	for _, key in ipairs({ "Throwable", "Throwing", "IsGrenade", "Explosive" }) do
		if weapon[key] == true or processedValue(weapon, key) == true then return true, key end
	end
	return false
end

local function clampedGiveAllowedAmmo(integration, ply, ammo, amount, maximum)
	local restricted = integration:IsAmmoCrateAmmoRestricted(ammo)
	if restricted then return false, true end
	amount = math.max(0, math.floor(tonumber(amount) or 0))
	maximum = math.max(0, math.floor(tonumber(maximum) or 0))
	if amount <= 0 or maximum <= 0 then return false, false end
	local count = ply:GetAmmoCount(ammo)
	if count >= maximum then return false, false end
	amount = math.min(amount, maximum - count)
	if amount <= 0 then return false, false end
	ply:GiveAmmo(amount, ammo)
	return true, false
end

function Integration:NotifyAmmoCrateDenied(ply)
	if not IsValid(ply) or (ply.DRPNextARC9AmmoDenied or 0) > CurTime() then return end
	ply.DRPNextARC9AmmoDenied = CurTime() + 1.5
	if DRP.Net and DRP.Net.Notify then
		DRP.Net.Notify(ply, "Ammo crates cannot resupply explosives or throwable weapons.", 3)
	else
		ply:ChatPrint("Ammo crates cannot resupply explosives or throwable weapons.")
	end
end

function Integration:ApplyFilteredAmmo(crate, ply)
	if not IsValid(crate) or not IsValid(ply) or not ply:IsPlayer() then return end
	if (crate.NextUse or 0) > CurTime() then return end
	local weapon = ply:GetActiveWeapon()
	local weaponRestricted = self:IsAmmoCrateWeaponRestricted(weapon)
	if weaponRestricted then self:NotifyAmmoCrateDenied(ply) return end

	local supply = math.max(1, tonumber(crate.Supply) or 1)
	local primaryAmmo = weapon:GetPrimaryAmmoType()
	local primaryClip = weapon:GetMaxClip1()
	local primaryLimit = primaryClip * 6
	local secondaryGiven = false
	local restrictedAttempt = false

	if weapon.ARC9 then
		primaryAmmo = processedValue(weapon, "Ammo") or primaryAmmo
		primaryClip = tonumber(processedValue(weapon, "ClipSize")) or primaryClip
		primaryLimit = (tonumber(processedValue(weapon, "SupplyLimit")) or 6) * primaryClip
		if processedValue(weapon, "UBGL") then
			local secondaryAmmo = processedValue(weapon, "UBGLAmmo")
			local secondaryClip = tonumber(processedValue(weapon, "UBGLClipSize")) or 0
			local secondaryLimit = secondaryClip * (tonumber(processedValue(weapon, "SecondarySupplyLimit")) or 0)
			local denied
			secondaryGiven, denied = clampedGiveAllowedAmmo(self, ply, secondaryAmmo, secondaryClip, secondaryLimit)
			restrictedAttempt = restrictedAttempt or denied
		end
	end

	primaryClip = math.max(0, tonumber(primaryClip) or 0)
	primaryLimit = math.max(1, tonumber(primaryLimit) or 0)
	local primaryGiven, primaryDenied = clampedGiveAllowedAmmo(
		self,
		ply,
		primaryAmmo,
		primaryClip * supply,
		primaryLimit
	)
	restrictedAttempt = restrictedAttempt or primaryDenied

	if not primaryGiven and not secondaryGiven then
		if restrictedAttempt then self:NotifyAmmoCrateDenied(ply) end
		return
	end

	if crate.OpeningAnim and not crate.Open then
		crate:ResetSequence(crate:LookupSequence("open"))
		crate:EmitSound("items/ammocrate_open.wav")
		crate.Open = true
	end
	crate.NextUse = CurTime() + 1
	if not crate.InfiniteUse then crate:Remove() end
end

function Integration:InstallAmmoCratePolicy()
	local stored = scripted_ents.GetStored("arc9_ammo")
	local definition = stored and stored.t
	if not definition or not isfunction(definition.ApplyAmmo) then
		ErrorNoHalt("[DRP ARC9] arc9_ammo is unavailable; explosive refill policy was not installed\n")
		return false
	end
	if definition.DRPFilteredAmmoPolicy then return true end
	definition.DRPOriginalApplyAmmo = definition.ApplyAmmo
	definition.ApplyAmmo = function(crate, ply)
		local integration = DRP.ARC9Integration
		if integration then return integration:ApplyFilteredAmmo(crate, ply) end
	end
	definition.DRPFilteredAmmoPolicy = true
	return true
end

local populationConVars = {
	arc9_cheapscopes = "1",
	arc9_hud_force_disable = "1",
	arc9_bullet_physics = "0",
	arc9_bullet_physics_shotguns = "0",
	arc9_bullet_lifetime = "3",
	arc9_thirdperson_force = "0",
	arc9_npc_atts = "0",
	arc9_ground_atts = "0"
}

local function arc9EntityKind(class)
	class = string.lower(tostring(class or ""))
	if class == "arc9_smoke_cloud" or string.find(class, "_fire_", 1, true) then return "area" end
	if string.StartWith(class, "arc9_gsr_thrown") or string.StartWith(class, "arc9_gsr_proj")
		or class == "arc9_gsr_c4_ent" or class == "arc9_gsr_breach" then return "explosive" end
end

function Integration:TrackEntity(entity)
	if not IsValid(entity) or self.TrackedEntities[entity] then return end
	local kind = arc9EntityKind(entity:GetClass())
	if not kind then return end
	local countKey = kind == "area" and "ActiveAreaEffects" or "ActiveExplosives"
	local limit = kind == "area" and self.MaxAreaEffects or self.MaxExplosives
	if self[countKey] >= limit then entity:Remove() return end
	self[countKey] = self[countKey] + 1
	self.TrackedEntities[entity] = kind
	timer.Simple(self.MaxExplosiveLifetime, function() if IsValid(entity) then entity:Remove() end end)
end

hook.Add("OnEntityCreated", "DRP.ARC9.PopulationCap", function(entity)
	if not IsValid(entity) or not string.StartWith(string.lower(entity:GetClass()), "arc9_") then return end
	timer.Simple(0, function() if DRP.ARC9Integration then DRP.ARC9Integration:TrackEntity(entity) end end)
end)

hook.Add("EntityRemoved", "DRP.ARC9.PopulationRelease", function(entity)
	local integration = DRP.ARC9Integration
	local kind = integration and integration.TrackedEntities[entity]
	if not kind then return end
	integration.TrackedEntities[entity] = nil
	local countKey = kind == "area" and "ActiveAreaEffects" or "ActiveExplosives"
	integration[countKey] = math.max(0, integration[countKey] - 1)
end)

function Integration:Start()
	if not self:IsLoaded() then
		error(
			"ARC9 did not load. Install its source at garrysmod/" .. self.SourceDirectory ..
			" and remove any duplicate server-mounted ARC9 Workshop copy."
		)
	end
	if not self:IsWeaponPackLoaded() then
		error(
			"ARC9 Gunsmith Reloaded did not load. Install its source at garrysmod/" ..
			self.WeaponPackSourceDirectory .. " and remove duplicate server-mounted copies."
		)
	end
	for name, value in pairs(populationConVars) do
		local convar = GetConVar(name)
		if convar then RunConsoleCommand(name, value) else ErrorNoHalt("[DRP ARC9] missing expected convar " .. name .. "\n") end
	end
	local ammoPolicy = self:InstallAmmoCratePolicy()

	local attachmentCount = istable(ARC9.Attachments) and table.Count(ARC9.Attachments) or 0
	print(string.format(
		"[DRP ARC9] editable source ready; weapons=%d attachments=%d fastdl_files=%d delivery=%s caps=%d/%d ammo_policy=%s",
		self:WeaponCount(),
		attachmentCount,
		self.FastDLFileCount,
		self.UseWorkshopContent and (self.UseFastDLContent and "workshop+fastdl" or "workshop") or "fastdl",
		self.MaxExplosives,
		self.MaxAreaEffects,
		ammoPolicy and "filtered" or "missing"
	))
end

function Integration:Stop() end
