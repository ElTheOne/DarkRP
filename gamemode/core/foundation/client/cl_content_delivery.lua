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
	applyWeaponModels("weapon_drp_police_tablet", phoneViewModel, phoneWorldModel, "models/weapons/c_arms.mdl", "")
	return available
end

timer.Simple(0, function()
	applyKeysModelCompatibility()
	applyPhoneModelCompatibility()
end)

Delivery.Required = {
	{
		id = "2910505837",
		title = "ARC9 Weapon Base",
		probes = {
			"materials/arc9/tracer.vmt",
			"materials/arc9/ui/gear.png",
			"models/items/arc9/ammo_pistol_box.mdl"
		}
	},
	{
		id = "2910537020",
		title = "ARC9 Gunsmith Reloaded",
		probes = {
			"models/weapons/csgo/c_rif_ak47.mdl",
			"models/weapons/csgo/atts/scopes/acog_1.mdl",
			"materials/models/csgo/ak47/ak47.vmt"
		}
	},
	{
		id = "1741741175",
		title = "Zero's Grow OP Content",
		probes = {
			"models/zerochain/props_weedfarm/zwf_generator.mdl",
			"materials/zerochain/props_weedfarm/generator/zwf_generator_diff.vmt"
		}
	},
	{
		id = "2486834214",
		title = "Zero's MethLab 2 Content",
		probes = {
			"models/zerochain/props_methlab/zmlab2_tentkit.mdl",
			"models/zerochain/props_methlab/zmlab2_mixer.mdl",
			"materials/zerochain/props_methlab/mixer/zmlab2_mixer_mat01_diff.vmt"
		}
	},
	{
		id = "2532060111",
		title = "zcLib Content",
		probes = {
			"materials/zerochain/zerolib/cable/zlib_beam.vmt",
			"materials/zerochain/zerolib/particle/zlib_glow01.vmt"
		}
	},
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
Delivery.Reported = Delivery.Reported or {}
Delivery.ReportCount = Delivery.ReportCount or 0
Delivery.Issues = Delivery.Issues or {}
Delivery.IssueCount = Delivery.IssueCount or 0
Delivery.WelcomeIssueWindowShown = Delivery.WelcomeIssueWindowShown == true
Delivery.WelcomeClosed = Delivery.WelcomeClosed == true

local requiredByID = {}
for index = 1, #Delivery.Required do
	requiredByID[Delivery.Required[index].id] = Delivery.Required[index]
end

-- More-specific owners must precede their shared framework. This lets a
-- generic error.mdl still be attributed from its scripted entity class while
-- material-only failures can be attributed from their mounted asset path.
local contentOwners = {
	{
		id = "2910537020",
		classPrefixes = { "arc9_go_", "arc9_gsr_" },
		assetPrefixes = { "models/weapons/csgo/", "models/csgo/", "materials/models/csgo/", "sound/weapons/csgo/" }
	},
	{
		id = "2910505837",
		classPrefixes = { "arc9_" },
		assetPrefixes = { "arc9/", "materials/arc9/", "models/items/arc9/", "effects/arc9", "sound/arc9/" }
	},
	{
		id = "1741741175",
		classPrefixes = { "zwf_" },
		assetPrefixes = { "models/zerochain/props_weedfarm/", "materials/zerochain/props_weedfarm/", "zerochain/props_weedfarm/", "zerochain/zwf/" }
	},
	{
		id = "2486834214",
		classPrefixes = { "zmlab2_" },
		assetPrefixes = { "models/zerochain/props_methlab/", "materials/zerochain/props_methlab/", "zerochain/props_methlab/", "zerochain/zmlab2/" }
	},
	{
		id = "2532060111",
		classPrefixes = { "zclib_", "zlib_" },
		assetPrefixes = { "materials/zerochain/zerolib/", "zerochain/zerolib/" }
	}
}

local function startsWithAny(value, prefixes)
	for index = 1, #prefixes do
		if string.StartWith(value, prefixes[index]) then return true end
	end
	return false
end

function Delivery.ContentIDFor(entityClass, asset)
	entityClass = string.lower(tostring(entityClass or ""))
	asset = string.lower(tostring(asset or ""))
	for index = 1, #contentOwners do
		local owner = contentOwners[index]
		if startsWithAny(entityClass, owner.classPrefixes)
			or startsWithAny(asset, owner.assetPrefixes) then return owner.id end
	end
	return ""
end

local contentReportMessage = "drp_content_report_v1"
local reportKinds = {
	required_pack = 1,
	invalid_model = 2,
	missing_material = 3
}

local issueLabels = {
	required_pack = "Required addon content is unavailable",
	invalid_model = "Entity model is missing",
	missing_material = "Entity material or texture is missing"
}

local function issueSignature(kind, contentID, asset, entityClass)
	return table.concat({ kind, contentID, asset, entityClass }, ":")
end

function Delivery.RememberIssue(kind, contentID, asset, entityClass)
	if not reportKinds[kind] then return nil end
	contentID = string.sub(tostring(contentID or ""), 1, 20)
	asset = string.lower(string.sub(tostring(asset or ""), 1, 192))
	entityClass = string.lower(string.sub(tostring(entityClass or ""), 1, 64))
	if contentID == "" then contentID = Delivery.ContentIDFor(entityClass, asset) end
	local signature = issueSignature(kind, contentID, asset, entityClass)
	local issue = Delivery.Issues[signature]
	if not issue and Delivery.IssueCount < 48 then
		issue = {
			kind = kind,
			contentID = contentID,
			asset = asset,
			entityClass = entityClass,
			detectedAt = RealTime()
		}
		Delivery.Issues[signature] = issue
		Delivery.IssueCount = Delivery.IssueCount + 1
		if Delivery.WelcomeClosed and Delivery.QueueIssueWindow then Delivery.QueueIssueWindow(0.5) end
	end
	return issue, signature
end

local function platformID()
	if system.IsWindows() then return 1 end
	if system.IsOSX() then return 2 end
	if system.IsLinux() then return 3 end
	return 0
end

function Delivery.ReportIssue(kind, contentID, asset, entityClass)
	local kindID = reportKinds[kind]
	if not kindID then return false end
	contentID = string.sub(tostring(contentID or ""), 1, 20)
	asset = string.lower(string.sub(tostring(asset or ""), 1, 192))
	entityClass = string.lower(string.sub(tostring(entityClass or ""), 1, 64))
	if contentID == "" then contentID = Delivery.ContentIDFor(entityClass, asset) end
	local _, signature = Delivery.RememberIssue(kind, contentID, asset, entityClass)
	if Delivery.Reported[signature] or Delivery.ReportCount >= 12 then return false end
	Delivery.Reported[signature] = true
	Delivery.ReportCount = Delivery.ReportCount + 1
	local delay = math.max(0, (Delivery.ReportCount - 1) * 1.5)
	timer.Simple(delay, function()
		if not IsValid(LocalPlayer()) then return end
		net.Start(contentReportMessage)
			net.WriteUInt(kindID, 2)
			net.WriteString(contentID)
			net.WriteString(asset)
			net.WriteString(entityClass)
			net.WriteUInt(platformID(), 2)
			net.WriteString(string.sub(tostring(BRANCH or "unknown"), 1, 24))
		net.SendToServer()
	end)
	return true
end

local itemAvailable
local notify

local function activeIssues()
	-- Re-probe required packs at presentation time. A pack recovered while the
	-- welcome panel was open should not be presented as still broken.
	for index = 1, #Delivery.Required do
		local item = Delivery.Required[index]
		if not itemAvailable(item) then
			Delivery.RememberIssue("required_pack", item.id, item.probes[1], "")
		end
	end

	local issues = {}
	for _, issue in pairs(Delivery.Issues) do
		local required = issue.kind == "required_pack" and requiredByID[issue.contentID]
		if not required or not itemAvailable(required) then issues[#issues + 1] = issue end
	end
	table.sort(issues, function(left, right)
		if left.contentID ~= right.contentID then return left.contentID < right.contentID end
		if left.kind ~= right.kind then return left.kind < right.kind end
		return left.asset < right.asset
	end)
	return issues
end

local function addonTitle(contentID)
	local item = requiredByID[tostring(contentID or "")]
	return item and item.title or "Unattributed addon content"
end

local function repairInstructions(issue)
	local contentID = tostring(issue.contentID or "")
	local addon = addonTitle(contentID)
	if contentID == "" then
		return "Fully restart Garry's Mod. If the error remains, copy the asset path below and send it to staff so its providing addon can be identified."
	end
	if system.IsOSX() then
		return "Fully exit Garry's Mod. Confirm Workshop item " .. contentID .. " is subscribed, then remove only files beginning with ._ from steamapps/workshop/content/4000/" .. contentID .. "/. Relaunch and reconnect."
	end
	return "Fully exit Garry's Mod. Confirm " .. addon .. " (Workshop " .. contentID .. ") is subscribed and downloaded. If it remains broken, unsubscribe, delete only steamapps/workshop/content/4000/" .. contentID .. "/, resubscribe, then relaunch."
end

function Delivery.ShowIssueWindow()
	if Delivery.WelcomeIssueWindowShown or IsValid(Delivery.IssueFrame) then return false end
	local issues = activeIssues()
	if #issues == 0 then return false end
	Delivery.WelcomeIssueWindowShown = true

	local colors = DRP.UI.Colors
	local frame = DRP.UI.Frame("CONTENT REPAIR REQUIRED", 920, 680)
	Delivery.IssueFrame = frame
	frame:SetDeleteOnClose(true)

	local summary = vgui.Create("DLabel", frame)
	summary:SetPos(24, 70)
	summary:SetSize(frame:GetWide() - 48, 52)
	summary:SetFont("DRP.Admin.Body")
	summary:SetTextColor(colors.muted)
	summary:SetWrap(true)
	summary:SetText(string.format("We detected %d addon content error%s on this client. The server is working, but the affected models or textures will remain broken until the client content is repaired.", #issues, #issues == 1 and "" or "s"))

	local scroll = vgui.Create("DScrollPanel", frame)
	scroll:SetPos(24, 126)
	scroll:SetSize(frame:GetWide() - 48, frame:GetTall() - 204)

	for index = 1, #issues do
		local issue = issues[index]
		local card = vgui.Create("DPanel", scroll)
		card:Dock(TOP)
		card:DockMargin(0, 0, 0, 10)
		card:SetTall(142)
		card.Paint = function(_, width, height)
			draw.RoundedBox(8, 0, 0, width, height, colors.panel)
			draw.RoundedBoxEx(8, 0, 0, 5, height, colors.red, true, false, true, false)
			surface.SetDrawColor(colors.line)
			surface.DrawOutlinedRect(0, 0, width, height, 1)
		end

		local title = vgui.Create("DLabel", card)
		title:SetPos(18, 10)
		title:SetSize(scroll:GetWide() - 54, 22)
		title:SetFont("DRP.Admin.Header")
		title:SetTextColor(colors.red)
		title:SetText(addonTitle(issue.contentID))

		local detail = vgui.Create("DLabel", card)
		detail:SetPos(18, 36)
		detail:SetSize(scroll:GetWide() - 54, 38)
		detail:SetFont("DRP.Admin.Small")
		detail:SetTextColor(color_white)
		detail:SetWrap(true)
		local entityText = issue.entityClass ~= "" and ("  •  Entity: " .. issue.entityClass) or ""
		detail:SetText((issueLabels[issue.kind] or "Content error") .. entityText .. "\nAsset: " .. (issue.asset ~= "" and issue.asset or "unknown"))

		local repair = vgui.Create("DLabel", card)
		repair:SetPos(18, 78)
		repair:SetSize(scroll:GetWide() - 54, 56)
		repair:SetFont("DRP.Admin.Small")
		repair:SetTextColor(colors.muted)
		repair:SetWrap(true)
		repair:SetText(repairInstructions(issue))
	end

	local copyIDs = DRP.UI.Button(frame, "COPY WORKSHOP IDS", colors.panelHover, function()
		local ids, seen = {}, {}
		for index = 1, #issues do
			local contentID = issues[index].contentID
			if contentID ~= "" and not seen[contentID] then
				seen[contentID] = true
				ids[#ids + 1] = contentID
			end
		end
		SetClipboardText(table.concat(ids, "\n"))
		notify("Copied affected Workshop IDs to the clipboard.")
	end)
	copyIDs:SetPos(24, frame:GetTall() - 62)
	copyIDs:SetSize(220, 40)

	local repair = DRP.UI.Button(frame, "ATTEMPT AUTOMATIC REPAIR", colors.accent, function()
		RunConsoleCommand("drp_content_repair")
	end)
	repair:SetPos(252, frame:GetTall() - 62)
	repair:SetSize(280, 40)

	local close = DRP.UI.Button(frame, "CLOSE", colors.green, function() frame:Close() end)
	close:SetPos(540, frame:GetTall() - 62)
	close:SetSize(frame:GetWide() - 564, 40)
	return true
end

function Delivery.QueueIssueWindow(delay)
	if Delivery.WelcomeIssueWindowShown or not Delivery.WelcomeClosed then return end
	timer.Remove("DRP.ContentDelivery.PostWelcomeIssues")
	timer.Create("DRP.ContentDelivery.PostWelcomeIssues", math.max(0.1, tonumber(delay) or 1.5), 1, function()
		Delivery.ShowIssueWindow()
	end)
end

hook.Add("DRPWelcomePanelClosed", "DRP.ContentDelivery.ShowAfterWelcome", function()
	Delivery.WelcomeClosed = true
	Delivery.QueueIssueWindow(1.5)
end)

concommand.Add("drp_content_issues", function()
	if IsValid(Delivery.IssueFrame) then Delivery.IssueFrame:MakePopup() return end
	Delivery.WelcomeIssueWindowShown = false
	if not Delivery.ShowIssueWindow() then notify("No addon content errors are currently detected.") end
end)

local function pathExists(path)
	if string.GetExtensionFromFilename(path) == "mdl" then
		return modelAvailable(path)
	end
	return file.Exists(path, "GAME")
end

itemAvailable = function(item)
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

notify = function(message, failure)
	local colour = failure and Color(255, 105, 115) or Color(90, 220, 255)
	chat.AddText(colour, "[CONTENT] ", color_white, message)
	print("[DRP CONTENT] " .. message)
end

local function realWorkshopArchive(path)
	path = string.gsub(tostring(path or ""), "\\", "/")
	local filename = string.GetFileFromFilename(path)
	if string.StartWith(filename, "._") then
		-- macOS writes AppleDouble metadata beside files on removable drives.
		-- Steamworks can return that 4 KB sidecar instead of the real GMA. Do
		-- not pass either path to MountGMA here: GMod can resolve the containing
		-- Workshop item back to the invalid sidecar even when given the sibling.
		local realPath = string.GetPathFromFilename(path) .. string.sub(filename, 3)
		print("[DRP CONTENT] Rejected AppleDouble archive " .. path .. "; expected " .. realPath)
		return realPath, true
	end
	return path, false
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
			Delivery.ReportIssue("required_pack", item.id, item.probes[1], "")
			return downloadNext()
		end
		local appleDouble
		path, appleDouble = realWorkshopArchive(path)
		if appleDouble then
			notify(
				"Steam selected a macOS metadata file for " .. item.title .. ". Fully exit Garry's Mod, remove only ._*.gma files from Workshop item " .. item.id .. ", then relaunch.",
				true
			)
			Delivery.ReportIssue("required_pack", item.id, item.probes[1], "")
			return downloadNext()
		end

		local mounted = game.MountGMA(path)
		if not mounted then
			if itemAvailable(item) then
				Delivery.Mounted[item.id] = true
				notify(item.title .. " content is already mounted.")
			else
				notify("Downloaded but could not mount " .. item.title .. ". Fully restart Garry's Mod.", true)
				Delivery.ReportIssue("required_pack", item.id, item.probes[1], "")
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
				Delivery.ReportIssue("required_pack", item.id, item.probes[1], "")
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
		for index = 1, #missing do
			local item = missing[index]
			Delivery.ReportIssue("required_pack", item.id, item.probes[1], "")
		end
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
	local ownerID = Delivery.ContentIDFor(ent:GetClass(), model)
	print(string.format("[DRP CONTENT] aimed class=%s model=%s valid_model=%s workshop=%s", ent:GetClass(), model, tostring(model ~= "" and util.IsValidModel(model)), ownerID ~= "" and ownerID or "unattributed"))
	for _, materialPath in ipairs(ent:GetMaterials() or {}) do
		local material = Material(materialPath)
		print(string.format("[DRP CONTENT] material=%s valid=%s", materialPath, tostring(material and not material:IsError())))
	end
end)

local function inspectEntityContent(ent)
	if not IsValid(ent) or ent:IsWorld() then return end
	local entityClass = ent:GetClass() or ""
	local model = string.lower(ent:GetModel() or "")
	if model == "models/error.mdl" or (string.StartWith(model, "models/") and not modelAvailable(model)) then
		Delivery.ReportIssue("invalid_model", "", model, entityClass)
		return
	end
	local materials = ent:GetMaterials() or {}
	for index = 1, math.min(#materials, 32) do
		local materialPath = string.lower(tostring(materials[index] or ""))
		if materialPath ~= "" and not string.StartWith(materialPath, "___") then
			local material = Material(materialPath)
			if not material or material:IsError() then
				Delivery.ReportIssue("missing_material", "", materialPath, entityClass)
				return
			end
		end
	end
end

hook.Add("OnEntityCreated", "DRP.ContentDelivery.InspectCreatedEntity", function(ent)
	timer.Simple(6, function() inspectEntityContent(ent) end)
end)

hook.Add("InitPostEntity", "DRP.ContentDelivery.InitialEntityAudit", function()
	timer.Simple(10, function()
		local entities = ents.GetAll()
		local cursor = 1
		timer.Create("DRP.ContentDelivery.InitialEntityAudit", 0.1, 0, function()
			for _ = 1, 16 do
				local ent = entities[cursor]
				cursor = cursor + 1
				if not ent then
					timer.Remove("DRP.ContentDelivery.InitialEntityAudit")
					return
				end
				inspectEntityContent(ent)
			end
		end)
	end)
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
	elseif class == "ephone" or class == "weapon_drp_mayor_tablet" or class == "weapon_drp_police_tablet" then timer.Simple(0, applyPhoneModelCompatibility) end
	timer.Simple(2, function()
		inspectEntityContent(weapon)
		local ply = LocalPlayer()
		if IsValid(ply) then inspectEntityContent(ply:GetViewModel()) end
	end)
end)

-- Give loose FastDL assets a short bounded window to become visible on a true
-- first join. There is no permanent Think hook and no server cost.
timer.Create("DRP.Phone.ContentMountWait", 2, 30, function()
	if applyPhoneModelCompatibility() then timer.Remove("DRP.Phone.ContentMountWait") end
end)
