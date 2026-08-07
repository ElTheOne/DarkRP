-- WorkshopDL normally mounts this before the client enters. Verify the actual
-- mounted GMA and recover a failed transfer without requiring a subscription.
DRP.ContentDelivery = DRP.ContentDelivery or {}
local Delivery = DRP.ContentDelivery

local portalViewModel = "models/weapons/c_portalgun.mdl"
local portalWorldModel = "models/weapons/w_portalgun.mdl"
local fallbackViewModel = "models/weapons/c_physcannon.mdl"
local fallbackWorldModel = "models/weapons/w_physics.mdl"
local keysViewModel = "models/craphead_scripts/adv_keys/weapons/c_key.mdl"
local keysWorldModel = "models/craphead_scripts/adv_keys/weapons/w_key.mdl"
local phoneViewModel = "models/elysion/c_phone_model.mdl"
local phoneWorldModel = "models/elysion/w_phone_model.mdl"

local function modelAvailable(path)
	if util.IsValidModel(path) then return true end
	if not file.Exists(path, "GAME") then return false end
	-- A model first queried before its Workshop archive was mounted can remain
	-- in Source's negative lookup cache. Precache it again after the file appears.
	util.PrecacheModel(path)
	return util.IsValidModel(path) or file.Exists(path, "GAME")
end

local function applyPortalModelCompatibility()
	local available = modelAvailable(portalViewModel) and modelAvailable(portalWorldModel)
	local viewModel = available and portalViewModel or fallbackViewModel
	local worldModel = available and portalWorldModel or fallbackWorldModel
	local stored = weapons.GetStored("weapon_portalgun")
	if istable(stored) then
		stored.ViewModel = viewModel
		stored.WorldModel = worldModel
	end

	if istable(portal_manager) and istable(portal_manager._list) and istable(portal_manager._list.Portal) then
		portal_manager._list.Portal.model = viewModel
	end

	for _, weapon in ipairs(ents.FindByClass("weapon_portalgun")) do
		weapon.ViewModel = viewModel
		weapon.WorldModel = worldModel
		if not IsValid(weapon:GetOwner()) then weapon:SetModel(worldModel) end
	end

	local ply = LocalPlayer()
	if IsValid(ply) and IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon():GetClass() == "weapon_portalgun" then
		local vm = ply:GetViewModel()
		if IsValid(vm) and vm:GetModel() ~= viewModel then vm:SetModel(viewModel) end
	end

	return available
end

local function applyWeaponModels(class, viewPath, worldPath, fallbackView, fallbackWorld)
	local available = modelAvailable(viewPath) and modelAvailable(worldPath)
	local viewModel = available and viewPath or fallbackView
	local worldModel = available and worldPath or fallbackWorld
	local stored = weapons.GetStored(class)
	if istable(stored) then
		stored.ViewModel = viewModel
		stored.WorldModel = worldModel
	end
	for _, weapon in ipairs(ents.FindByClass(class)) do
		weapon.ViewModel = viewModel
		weapon.WorldModel = worldModel
		-- A server can legitimately know the model while a first-join client is
		-- still mounting it. Hide that networked world entity instead of allowing
		-- Source to cache and draw error.mdl; reveal it once the model is usable.
		weapon:SetNoDraw(not available)
		if available and worldModel ~= "" then weapon:SetModel(worldModel) end
	end
	local ply = LocalPlayer()
	if IsValid(ply) then
		local weapon = ply:GetActiveWeapon()
		if IsValid(weapon) and weapon:GetClass() == class then
			local vm = ply:GetViewModel()
			if IsValid(vm) and vm:GetModel() ~= viewModel then
				if isfunction(vm.SetWeaponModel) then vm:SetWeaponModel(viewModel, weapon) else vm:SetModel(viewModel) end
			end
		end
	end
	return available
end

local function applyKeysModelCompatibility()
	return applyWeaponModels("weapon_drp_keys", keysViewModel, keysWorldModel, "models/weapons/c_arms.mdl", "")
end

local function applyPhoneModelCompatibility()
	local available = applyWeaponModels("ephone", phoneViewModel, phoneWorldModel, "models/weapons/c_arms.mdl", "")
	-- The Mayor tablet inherits the phone base and uses the same physical model.
	applyWeaponModels("weapon_drp_mayor_tablet", phoneViewModel, phoneWorldModel, "models/weapons/c_arms.mdl", "")
	return available
end

timer.Simple(0, function()
	applyKeysModelCompatibility()
	applyPhoneModelCompatibility()
end)

Delivery.Required = {
	{
		id = "1800764828",
		title = "Portal Gun",
		probes = {
			"models/weapons/c_portalgun.mdl",
			"models/weapons/w_portalgun.mdl"
		}
	},
	{
		id = "1443497352",
		title = "Keys",
		probes = {
			keysViewModel,
			keysWorldModel
		}
	}
}

Delivery.Queue = Delivery.Queue or {}
Delivery.Downloading = false
Delivery.Mounted = Delivery.Mounted or {}

local function pathExists(path)
	if string.GetExtensionFromFilename(path) == "mdl" then
		return modelAvailable(path)
	end
	return file.Exists(path, "GAME")
end

local function itemAvailable(item)
	for i = 1, #item.probes do
		if not pathExists(item.probes[i]) then return false end
	end
	return true
end

local function workshopState(item)
	for _, addon in ipairs(engine.GetAddons() or {}) do
		if tostring(addon.wsid or "") == item.id then
			return tostring(addon.downloaded == true), tostring(addon.mounted == true), tostring(addon.file or "")
		end
	end
	return "false", "false", "not registered"
end

local function notify(message, failure)
	local colour = failure and Color(255, 105, 115) or Color(90, 220, 255)
	chat.AddText(colour, "[CONTENT] ", color_white, message)
	print("[DRP CONTENT] " .. message)
end

local function realWorkshopArchive(path)
	path = string.gsub(tostring(path or ""), "\\", "/")
	local filename = string.GetFileFromFilename(path)
	if string.StartWith(filename, "._") then
		-- macOS writes AppleDouble metadata beside files on removable drives.
		-- Steamworks can return that 4 KB sidecar instead of the real GMA.
		local realPath = string.GetPathFromFilename(path) .. string.sub(filename, 3)
		print("[DRP CONTENT] Ignoring AppleDouble archive and mounting " .. realPath)
		return realPath
	end
	return path
end

local function downloadNext()
	if Delivery.Downloading then return end
	local item = table.remove(Delivery.Queue, 1)
	if not item then
		if Delivery.RecoveredAny then
			notify("Content recovery finished. Reconnect once so every repaired material and sound reloads.")
		end
		return
	end

	if itemAvailable(item) then
		Delivery.Mounted[item.id] = true
		return downloadNext()
	end

	Delivery.Downloading = true
	notify("Downloading missing " .. item.title .. " content from Workshop. Keep Garry's Mod open...")
	steamworks.DownloadUGC(item.id, function(path)
		Delivery.Downloading = false
		if not isstring(path) or path == "" then
			notify("Steam failed to download " .. item.title .. " (" .. item.id .. "). Check Steam Downloads and free disk space.", true)
			return downloadNext()
		end
		path = realWorkshopArchive(path)

		local mounted = game.MountGMA(path)
		if not mounted then
			if itemAvailable(item) then
				Delivery.Mounted[item.id] = true
				notify(item.title .. " content is already mounted.")
			else
				notify("Downloaded but could not mount " .. item.title .. ". Fully restart Garry's Mod.", true)
			end
		else
			applyPortalModelCompatibility()
			applyKeysModelCompatibility()
			if itemAvailable(item) then
				Delivery.Mounted[item.id] = true
				Delivery.RecoveredAny = true
				notify("Mounted " .. item.title .. ".")
			else
				notify("Mounted " .. item.title .. " archive, but its required model is still unavailable. Fully restart Garry's Mod.", true)
			end
		end
		downloadNext()
	end)
end

function Delivery.Verify(recover)
	Delivery.Queue = {}
	local missing = {}
	for i = 1, #Delivery.Required do
		local item = Delivery.Required[i]
		local available = itemAvailable(item)
		local downloaded, mounted, addonFile = workshopState(item)
		Delivery.Mounted[item.id] = available
		print(string.format(
			"[DRP CONTENT] %-22s id=%s usable=%s workshop_downloaded=%s workshop_mounted=%s file=%s",
			item.title,
			item.id,
			tostring(available),
			downloaded,
			mounted,
			addonFile
		))
		if not available then
			missing[#missing + 1] = item
			if recover then Delivery.Queue[#Delivery.Queue + 1] = item end
		end
	end
	applyPortalModelCompatibility()
	applyKeysModelCompatibility()
	applyPhoneModelCompatibility()

	if #missing == 0 then
		notify("All required Workshop content is mounted.")
	elseif recover then
		notify(string.format("%d content pack(s) failed pre-join mounting; starting recovery.", #missing), true)
		downloadNext()
	else
		notify(string.format("%d content pack(s) missing. Run drp_content_repair.", #missing), true)
	end
	return #missing == 0
end

concommand.Add("drp_content_status", function()
	Delivery.Verify(false)
	print(string.format(
		"[DRP CONTENT] %-22s usable=%s view=%s world=%s",
		"ePhone FastDL",
		tostring(util.IsValidModel(phoneViewModel) and util.IsValidModel(phoneWorldModel)),
		phoneViewModel,
		phoneWorldModel
	))
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local ent = ply:GetEyeTrace().Entity
	if not IsValid(ent) then return end
	local model = ent:GetModel() or ""
	print(string.format("[DRP CONTENT] aimed class=%s model=%s valid_model=%s", ent:GetClass(), model, tostring(model ~= "" and util.IsValidModel(model))))
	for _, materialPath in ipairs(ent:GetMaterials() or {}) do
		local material = Material(materialPath)
		print(string.format("[DRP CONTENT] material=%s valid=%s", materialPath, tostring(material and not material:IsError())))
	end
end)

concommand.Add("drp_content_repair", function()
	if Delivery.Downloading or #Delivery.Queue > 0 then
		return notify("Content recovery is already running.")
	end
	Delivery.Verify(true)
end)

hook.Add("InitPostEntity", "DRP.ContentDelivery.Verify", function()
	-- Workshop metadata can claim an addon is mounted while its files are absent.
	-- Probe the actual model and immediately remount the downloaded GMA if needed.
	timer.Simple(2, function()
		if not IsValid(LocalPlayer()) then return end
		Delivery.Verify(true)
		if not applyPhoneModelCompatibility() then
			notify("Phone model content is still downloading from FastDL; its error model has been suppressed. Reconnect after the download completes.", true)
		end
	end)
end)

hook.Add("OnReloaded", "DRP.PortalGun.ModelCompatibility", function()
	timer.Simple(0, function()
		applyPortalModelCompatibility()
		applyKeysModelCompatibility()
		applyPhoneModelCompatibility()
	end)
end)

hook.Add("PlayerSwitchWeapon", "DRP.PortalGun.ModelCompatibility", function(_, _, weapon)
	if not IsValid(weapon) then return end
	local class = weapon:GetClass()
	if class == "weapon_portalgun" then timer.Simple(0, applyPortalModelCompatibility)
	elseif class == "weapon_drp_keys" then timer.Simple(0, applyKeysModelCompatibility)
	elseif class == "ephone" or class == "weapon_drp_mayor_tablet" then timer.Simple(0, applyPhoneModelCompatibility) end
end)

-- Give loose FastDL assets a short bounded window to become visible on a true
-- first join. There is no permanent Think hook and no server cost.
timer.Create("DRP.Phone.ContentMountWait", 2, 30, function()
	if applyPhoneModelCompatibility() then timer.Remove("DRP.Phone.ContentMountWait") end
end)
