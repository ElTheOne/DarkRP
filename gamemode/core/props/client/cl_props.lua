DRP = DRP or {}
DRP.Props = DRP.Props or {}
DRP.PropMenu = DRP.PropMenu or {}
DRP.PropBlacklist = DRP.PropBlacklist or {}
DRP.CivicItemPermissions = DRP.CivicItemPermissions or {}
DRP.DynamicWeaponCrates = DRP.DynamicWeaponCrates or {}

local UI = DRP.UI
local colors = UI.Colors
local menu
local catalog
local menuState = DRP.PropMenu.State or {
	activePage = "props",
	activeCategory = "All",
	currentPage = 1,
	searchText = "",
	categoryScroll = 0,
	propScroll = 0
}
DRP.PropMenu.State = menuState
local searchText = tostring(menuState.searchText or "")
local itemsPerPage = 112
local serverCatalogModels
local serverCatalogIncoming
local serverCatalogFingerprint = ""
local serverCatalogExpected = 0
local serverCatalogLoading = false
local serverCatalogChecked = false
local catalogCachePath = "darkrp/prop_catalog_client_v1.json"

do
	local cached = util.JSONToTable(file.Read(catalogCachePath, "DATA") or "")
	if istable(cached) and isstring(cached.fingerprint) and istable(cached.models) then
		serverCatalogFingerprint = cached.fingerprint
		serverCatalogModels = cached.models
		serverCatalogExpected = #cached.models
	end
end

local function saveClientCatalog()
	if not serverCatalogModels or serverCatalogFingerprint == "" then return end
	file.CreateDir("darkrp")
	file.Write(catalogCachePath, util.TableToJSON({ fingerprint = serverCatalogFingerprint, models = serverCatalogModels }, false))
end

surface.CreateFont("DRP.SpawnMenu.Tab", { font = "Roboto", size = 17, weight = 700 })
surface.CreateFont("DRP.SpawnMenu.Category", { font = "Roboto", size = 15, weight = 600 })
surface.CreateFont("DRP.SpawnMenu.Icon", { font = "Roboto", size = 13, weight = 500 })

-- The admin-access packet can arrive before cl_admin has installed its receiver
-- during a busy join. Roster rank and the replicated user group are authoritative
-- fallbacks, so owner-only Q-menu entries must not disappear because one client
-- cache has not populated yet.
local function clientRank()
	local rank = string.lower(tostring(DRP.ClientAdminRank or ""))
	if rank ~= "" and rank ~= "user" then return rank end
	local ply = LocalPlayer()
	if IsValid(ply) then
		local rosterRank = DRP.Roster and DRP.Roster.Value and DRP.Roster.Value(ply, "rank", nil)
		rosterRank = string.lower(tostring(rosterRank or ""))
		if rosterRank ~= "" and rosterRank ~= "user" then return rosterRank end
		local userGroup = string.lower(tostring(ply:GetUserGroup() or ""))
		if userGroup ~= "" then return userGroup end
	end
	return rank ~= "" and rank or "user"
end

local function isClientOwner()
	return DRP.ClientOwner == true or clientRank() == "owner"
end

local function canManageBlacklist()
	return isClientOwner() or DRP.AdminMaskHas(DRP.ClientAdminMask or 0, "props")
end

local function canManagePrices()
	return isClientOwner() or DRP.AdminMaskHas(DRP.ClientAdminMask or 0, "prop_prices")
end

local function canUseAdminSpawn()
	return DRP.AdminRankLevel(clientRank()) >= DRP.AdminRankLevel("admin")
end

local roleSelectableWeapons = {
	weapon_drp_medkit = "canHeal",
	weapon_drp_defibrillator = "canHeal",
	weapon_drp_kidnap_baton = "canKidnap",
	weapon_drp_blindfold = "canKidnap",
	weapon_drp_gag = "canKidnap",
	weapon_drp_mayor_tablet = "canUsePoliceTablet"
}

local universallySelectableWeapons = {
	weapon_medkit = true,
	ephone = true
}

local function canEquipUtilityWeapon(definition)
	local class = string.lower(tostring(definition and definition.class or ""))
	if universallySelectableWeapons[class] then return true end
	local capability = roleSelectableWeapons[class]
	if not capability then return false end
	local ply = LocalPlayer()
	return IsValid(ply) and ply:DRPHasRoleCapability(capability)
end

local function canSetWeaponUnlocks()
	return DRP.AdminRankLevel(clientRank()) >= DRP.AdminRankLevel("headadmin")
end

local function canManageCivicAccess()
	return DRP.AdminRankLevel(clientRank()) >= DRP.AdminRankLevel("headadmin")
end

local function civicItemPolicy(definition)
	return DRP.CivicItemPermissions[tostring(definition and definition.key or "")] or {}
end

local function allJobEntityDefinitions()
	local output = {}
	for _, definition in ipairs(DRP.JobEntities or {}) do output[#output + 1] = definition end
	for _, definition in ipairs(DRP.DynamicWeaponCrates or {}) do output[#output + 1] = definition end
	return output
end

local function clientCanSpawnJobEntity(definition, job, civic)
	local policy = civicItemPolicy(definition)
	local overview = DRP.ClientRoleOverview or {}
	local derivedID = tonumber(overview.derived)
	local derivedJob = derivedID and DRP.Jobs and DRP.Jobs[derivedID] or nil
	local effectiveJobKey = (derivedJob and derivedJob.key) or job.key
	-- Owner is the world builder and can test every registered job entity even
	-- while occupying Mayor/police. Keep this first so the client catalogue
	-- mirrors the server's authoritative override.
	if isClientOwner() then return true end
	if definition.ownerOnly then return isClientOwner() end
	if definition.police then return job.isPolice == true end
	if definition.crafting then return not (job.isPolice or job.isMayor or job.isGovernment) end
	-- Mirror the server's admin spawn override before role-specific crate
	-- filtering so staff can see and test the crates they configure.
	if canUseAdminSpawn() then return true end
	if definition.class == "drp_weapon_crate" then
		if effectiveJobKey == "gun_dealer" then return true end
		return effectiveJobKey == "mob_boss" and policy.mobBossAllowed == true
	end
	if effectiveJobKey == "mob_boss" then return true end
	if definition.job and definition.job == effectiveJobKey then return true end
	return policy.thresholdEnabled == true and not job.isGovernment and civic <= (tonumber(policy.threshold) or -1000)
end

local function jobEntityCatalog()
	local output = {}
	local job = DRP.Jobs[DRP.ClientProfile.job] or {}
	local civic = DRP.ClientRoleOverview and tonumber(DRP.ClientRoleOverview.civic)
		or (DRP.Roster and DRP.Roster.Value(LocalPlayer(), "civic", 0))
		or 0
	for _, definition in ipairs(allJobEntityDefinitions()) do
		if clientCanSpawnJobEntity(definition, job, civic) then
			local copy = table.Copy(definition)
			copy.kind = "job_entity"
			copy.categories = { [definition.category or "Job Entities"] = true }
			output[#output + 1] = copy
		end
	end
	return output
end

local function civicAccessCatalog()
	local output = {}
	for _, definition in ipairs(allJobEntityDefinitions()) do
		local copy = table.Copy(definition)
		local policy = civicItemPolicy(definition)
		copy.kind = "civic_permission"
		copy.accessPolicy = table.Copy(policy)
		copy.categories = { [definition.category or "Job Entities"] = true }
		output[#output + 1] = copy
	end
	return output
end

local function sendJobEntitySpawn(definition)
	net.Start("drp_job_entity_spawn_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(definition.key)
	net.SendToServer()
	surface.PlaySound("ui/buttonclickrelease.wav")
end

local function translatedName(value, fallback)
	value = tostring(value or "")
	if value == "" then return fallback end
	local translated = language.GetPhrase(value)
	return translated ~= "" and translated or fallback
end

local function normalizedCategory(value)
	value = string.Trim(translatedName(value, "Other"))
	return value ~= "" and value or "Other"
end

local adminEntityCatalog
local adminWeaponCatalog
local function friendlyToolName(mode)
	local value = string.gsub(tostring(mode or ""), "_", " ")
	return string.gsub(value, "(%a)([%w']*)", function(first, rest)
		return string.upper(first) .. string.lower(rest)
	end)
end

-- This is intentionally local to the Q menu instead of depending on the
-- Sandbox spawnmenu or a live Tool Gun instance. Those registries may populate
-- after this menu is opened. Keep these beside Persistent Entity as requested.
local stockToolModes = {
	"axis", "balloon", "ballsocket", "button", "camera", "colour",
	"creator", "duplicator", "dynamite", "editentity", "elastic",
	"emitter", "eyeposer", "faceposer", "finger", "hoverball",
	"hydraulic", "inflator", "lamp", "leafblower", "light", "material",
	"motor", "muscle", "nocollide", "paint", "physprop", "pulley",
	"remover", "rope", "slider", "thruster", "trails", "weld", "wheel",
	"winch"
}

local function toolCatalog()
	local output = {}
	local seen = {}
	local function addTool(mode, tool, category)
		mode = string.lower(string.Trim(tostring(mode or "")))
		if mode == "" or seen[mode] then return end
		if mode == "drp_property_zone"
			and not isClientOwner()
			and DRP.AdminRankLevel(clientRank()) < DRP.AdminRankLevel("headadmin") then return end
		tool = istable(tool) and tool or {}
		category = normalizedCategory(category or tool.Category or "Tools")
		seen[mode] = true
		output[#output + 1] = {
			kind = "tool",
			mode = mode,
			class = mode,
			name = translatedName(tool.Name, friendlyToolName(mode)),
			category = category,
			categories = { [category] = true },
			icon = tool.Icon or "gui/tool.png"
		}
	end

	-- Register the guaranteed local suite first. This both prevents an empty
	-- Tools page and ensures every stock tool sits in the same category as the
	-- working Persistent Entity entry.
	DRP.AllowedToolModes = DRP.AllowedToolModes or {}
	for _, mode in ipairs(stockToolModes) do
		DRP.AllowedToolModes[mode] = true
		addTool(mode, { Name = "#tool." .. mode .. ".name" }, "DarkRP Server")
	end
	DRP.AllowedToolModes.drp_property_zone = true
	addTool("drp_property_zone", { Name = "Property Build Zones", Icon = "icon16/shape_handles.png" }, "DarkRP Server")

	-- The live weapon contains initialized tool objects and is the most
	-- dependable registry after the player has received their loadout.
	local player = LocalPlayer()
	local liveToolgun = IsValid(player) and player:GetWeapon("gmod_tool") or nil
	for mode, tool in pairs((IsValid(liveToolgun) and liveToolgun.Tool) or {}) do
		addTool(mode, tool)
	end

	-- The stored SWEP definition remains useful before the live weapon exists.
	local stored = weapons.GetStored("gmod_tool")
	for mode, tool in pairs((stored and stored.Tool) or {}) do
		addTool(mode, tool)
	end

	-- Sandbox also keeps a client registry for populated control panels. This
	-- captures tools registered by addons after the Tool Gun definition loaded.
	for _, tab in ipairs((spawnmenu and spawnmenu.GetTools and spawnmenu.GetTools()) or {}) do
		for _, category in ipairs(tab.Items or {}) do
			local categoryName = translatedName(category.Text, category.ItemName or tab.Label or "Tools")
			for _, item in ipairs(category) do
				if istable(item) and item.ItemName then
					addTool(item.ItemName, nil, categoryName)
				end
			end
		end
	end

	-- Every loaded stool creates this replicated convar. It is a safe final
	-- fallback when one of the Lua registry tables has not populated yet.
	for mode in pairs(DRP.AllowedToolModes or {}) do
		if GetConVar("toolmode_allow_" .. mode) then addTool(mode) end
	end

	-- Add any future built-in manifest entries not covered by the guaranteed
	-- suite above.
	for mode, category in pairs(DRP.BuiltinToolModes or {}) do
		addTool(mode, { Name = "#tool." .. mode .. ".name" }, category)
	end

	if isClientOwner() then
		output[#output + 1] = {
			kind = "tool", mode = "drp_persistence", class = "drp_persistence", name = "Persistent Entity",
			category = "DarkRP Server", categories = { ["DarkRP Server"] = true }, icon = "icon16/database_save.png"
		}
	end
	table.sort(output, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
	return output
end

concommand.Add("drp_tools_debug", function()
	local definitions = toolCatalog()
	local stored = weapons.GetStored("gmod_tool")
	local live = IsValid(LocalPlayer()) and LocalPlayer():GetWeapon("gmod_tool") or nil
	print(string.format(
		"[DRP TOOLS] catalogue=%d stored=%d live=%d rank=%s owner=%s",
		#definitions,
		istable(stored and stored.Tool) and table.Count(stored.Tool) or 0,
		IsValid(live) and istable(live.Tool) and table.Count(live.Tool) or 0,
		clientRank(),
		tostring(isClientOwner())
	))
	for _, definition in ipairs(definitions) do
		print(string.format("[DRP TOOLS] %s | %s", definition.mode, definition.category))
	end
end)

local blockedPrestigeWeapons = {
	arc9_base = true,
	arc9_base_nade = true,
	arc9_go_base = true,
	weapon_base = true,
	weapon_physgun = true,
	weapon_physcannon = true,
	gmod_tool = true,
	gmod_camera = true,
	weapon_drp_keys = true,
	weapon_drp_pocket = true,
	weapon_drp_taser = true,
	weapon_drp_cuffs = true,
	weapon_drp_arrest = true,
	weapon_drp_medkit = true,
	weapon_drp_defibrillator = true,
	weapon_drp_kidnap_baton = true,
	weapon_drp_blindfold = true,
	weapon_drp_gag = true,
	weapon_portalgun = true,
	weapon_medkit = true,
	ephone = true,
	weapon_drp_mayor_tablet = true,
	weapon_drp_persistence_tool = true
}

local function buildAdminCatalogs()
	if adminEntityCatalog and adminWeaponCatalog then return end
	local entityByClass = {}
	local function addEntity(class, definition)
		class = string.lower(string.Trim(tostring(class or "")))
		if class == "" or entityByClass[class] then return end
		definition = definition or {}
		local stored = scripted_ents.GetStored(class)
		local sent = stored and stored.t or nil
		local isTARDIS = string.lower(tostring(definition.ScriptedEntityType or "")) == "tardis"
		-- TARDIS was removed from this gamemode. Do not expose stale metadata if a
		-- client still has the old addon mounted locally.
		if isTARDIS or class == "gmod_tardis" then return end
		if not definition.ClassName and not (sent and sent.Spawnable) then return end
		local category = normalizedCategory(definition.Category or (sent and sent.Category))
		entityByClass[class] = {
			kind = "entity",
			class = class,
			name = translatedName(definition.PrintName or (sent and sent.PrintName), class),
			category = category,
			categories = { [category] = true },
			model = definition.Model or (sent and sent.Model),
			icon = definition.Material or (sent and sent.IconOverride) or ("entities/" .. class .. ".png")
		}
	end
	for class, definition in pairs(list.Get("SpawnableEntities") or {}) do addEntity(class, definition) end
	for class, stored in pairs(scripted_ents.GetList() or {}) do addEntity(class, stored and stored.t or stored) end
	adminEntityCatalog = {}
	for _, definition in pairs(entityByClass) do adminEntityCatalog[#adminEntityCatalog + 1] = definition end

	local weaponByClass = {}
	local function addWeapon(class, definition)
		class = string.lower(string.Trim(tostring(class or "")))
		local stored = weapons.GetStored(class)
		definition = definition or {}
		local weapon = stored or definition
		if class ~= "" and (stored or definition.ClassName or definition.PrintName) then
			local category = normalizedCategory(definition.Category or weapon.Category)
			weaponByClass[class] = {
				kind = "weapon",
				class = class,
				name = translatedName(definition.PrintName or weapon.PrintName, class),
				category = category,
				categories = { [category] = true },
				model = weapon.WorldModel,
				icon = definition.IconOverride or weapon.IconOverride or ("entities/" .. class .. ".png"),
				prestigeEligible = not blockedPrestigeWeapons[class]
					and not (DRP.WeaponAccess and DRP.WeaponAccess.IsRestricted(class))
					and weapon.AdminOnly ~= true
			}
		end
	end
	for class, definition in pairs(list.Get("Weapon") or {}) do addWeapon(class, definition) end
	for _, definition in ipairs(weapons.GetList() or {}) do
		addWeapon(definition.ClassName or definition.Class or definition.Folder, definition)
	end
	-- Several mounted Half-Life weapons are native engine entities rather than
	-- enumerable Lua SWEPs. The shared manifest keeps them visible to the owner.
	for class, definition in pairs((DRP.WeaponAccess and DRP.WeaponAccess.LegacyOwnerWeapons) or {}) do
		addWeapon(class, definition)
	end
	-- Engine utility weapons are not guaranteed to be present in either
	-- enumerable spawn-list registry. They are universal loadout items, so keep
	-- deterministic SYSTEM entries in the Weapons page.
	addWeapon("weapon_physgun", {
		ClassName = "weapon_physgun",
		PrintName = "Physics Gun",
		Category = "Building Utilities",
		IconOverride = "entities/weapon_physgun.png"
	})
	addWeapon("gmod_tool", {
		ClassName = "gmod_tool",
		PrintName = "Tool Gun",
		Category = "Building Utilities",
		IconOverride = "entities/gmod_tool.png"
	})
	addWeapon("weapon_drp_mayor_tablet", {
		ClassName = "weapon_drp_mayor_tablet",
		PrintName = "Mayoral Records Tablet",
		Category = "Government Utilities",
		IconOverride = "entities/ephone.png"
	})
	adminWeaponCatalog = {}
	for _, definition in pairs(weaponByClass) do adminWeaponCatalog[#adminWeaponCatalog + 1] = definition end

	local function sortCatalog(entries)
		table.sort(entries, function(first, second)
			if first.name == second.name then return first.class < second.class end
			return string.lower(first.name) < string.lower(second.name)
		end)
	end
	sortCatalog(adminEntityCatalog)
	sortCatalog(adminWeaponCatalog)
end

local function closeMenu()
	if IsValid(menu) then menu:Close() end
	menu = nil
end

local function friendlyModelName(model)
	local name = string.GetFileFromFilename(model or "")
	name = string.StripExtension(name)
	name = string.gsub(name, "[_%-]+", " ")
	name = string.Trim(name)
	if name == "" then return "Prop" end
	return string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

local function friendlyDirectoryName(value)
	value = string.gsub(tostring(value or ""), "[_%-]+", " ")
	value = string.Trim(value)
	if value == "" then return "Other" end
	return string.upper(string.sub(value, 1, 1)) .. string.sub(value, 2)
end

local function modelCategory(model)
	local directory = string.GetPathFromFilename(string.sub(model, 8))
	local parts = string.Explode("/", string.TrimRight(directory, "/"), false)
	if #parts == 0 or parts[1] == "" then return "Other" end
	local category = friendlyDirectoryName(parts[1])
	if #parts > 1 and parts[2] ~= "" then category = category .. " / " .. friendlyDirectoryName(parts[2]) end
	return category
end

-- Keep catalogue construction safe during client hot reloads. sh_props normally
-- supplies the shared helper first, but cl_props can be reloaded independently.
local function normalizeCatalogModel(value)
	if DRP and DRP.Props and isfunction(DRP.Props.NormalizeModel) then return DRP.Props.NormalizeModel(value) end
	local model = string.lower(string.Trim(tostring(value or "")))
	model = string.gsub(model, "\\+", "/")
	model = string.gsub(model, "/+", "/")
	if #model < 12 or #model > 260 or string.find(model, "..", 1, true) then return nil end
	if string.sub(model, 1, 7) ~= "models/" or string.sub(model, -4) ~= ".mdl" then return nil end
	return model
end

local function sharedPropCatalog()
	if DRP and DRP.Props and istable(DRP.Props.Catalog) then return DRP.Props.Catalog end
	return DRP and istable(DRP.PropCatalog) and DRP.PropCatalog or {}
end

local function addCatalogEntry(byModel, model, category, serverVerified, price, priceOverridden)
	model = normalizeCatalogModel(model)
	if not model then return end
	local definition = byModel[model]
	if not definition and not serverVerified and (not util.IsValidModel(model) or (util.IsValidProp and not util.IsValidProp(model))) then return end
	category = string.Trim(tostring(category or "Other"))
	if category == "" then category = "Other" end
	if not definition then
		definition = {
			model = model,
			name = friendlyModelName(model),
			category = category,
			categories = {}
		}
		byModel[model] = definition
	end
	definition.categories[category] = true
	if price then definition.price = math.max(math.floor(tonumber(price) or 0), 0) end
	if priceOverridden ~= nil then definition.priceOverridden = priceOverridden == true end
	return definition
end

local function addSpawnlistTable(byModel, source)
	if not istable(source) then return end
	for _, info in SortedPairs(source) do
		if istable(info) and (not info.needsapp or info.needsapp == "" or IsMounted(info.needsapp)) then
			for _, object in SortedPairs(info.contents or {}) do
				if istable(object) and object.type == "model" then
					addCatalogEntry(byModel, object.model, info.name)
				end
			end
		end
	end
end

local function addDefaultSpawnlistFiles(byModel)
	local files = file.Find("settings/spawnlist_default/*.txt", "GAME") or {}
	for _, filename in ipairs(files) do
		local raw = file.Read("settings/spawnlist_default/" .. filename, "GAME")
		local info = raw and util.KeyValuesToTable(raw) or nil
		if istable(info) and not info.contents then
			for _, candidate in pairs(info) do
				if istable(candidate) and candidate.contents then info = candidate break end
			end
		end
		if istable(info) and (not info.needsapp or info.needsapp == "" or IsMounted(info.needsapp)) then
			local category = info.name or string.StripExtension(filename)
			for _, object in SortedPairs(info.contents or {}) do
				if istable(object) and object.type == "model" then addCatalogEntry(byModel, object.model, category) end
			end
		end
	end
end

local function buildSandboxCatalog()
	if catalog then return catalog end
	local byModel = {}
	local serverSet
	if serverCatalogModels then
		serverSet = {}
		for _, record in ipairs(serverCatalogModels) do
			local model = istable(record) and record.model or record
			serverSet[model] = true
			addCatalogEntry(byModel, model, modelCategory(model), true, istable(record) and record.price or nil, istable(record) and record.overridden or nil)
		end
	end

	-- Spawnlists now provide friendly category metadata only. Once the server
	-- inventory arrives, it is the authority for which models actually exist.
	addDefaultSpawnlistFiles(byModel)
	if spawnmenu and spawnmenu.PopulateFromEngineTextFiles then
		pcall(spawnmenu.PopulateFromEngineTextFiles)
		if spawnmenu.GetPropTable then addSpawnlistTable(byModel, spawnmenu.GetPropTable()) end
		if spawnmenu.GetCustomPropTable then addSpawnlistTable(byModel, spawnmenu.GetCustomPropTable()) end
	end
	for _, definition in ipairs(sharedPropCatalog()) do
		addCatalogEntry(byModel, definition.model, definition.category)
	end
	if serverSet then
		for model in pairs(byModel) do
			if not serverSet[model] then byModel[model] = nil end
		end
	end

	catalog = {}
	for _, definition in pairs(byModel) do catalog[#catalog + 1] = definition end
	table.sort(catalog, function(first, second)
		if first.name == second.name then return first.model < second.model end
		return string.lower(first.name) < string.lower(second.name)
	end)
	DRP.PropCatalog = catalog
	return catalog
end

local function sendSpawn(definition)
	if DRP.PropBlacklist[definition.model] then
		surface.PlaySound("buttons/button10.wav")
		return
	end
	if not definition.price then
		surface.PlaySound("buttons/button10.wav")
		return
	end
	net.Start("drp_prop_spawn_v2")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(definition.model)
	net.SendToServer()
	surface.PlaySound("ui/buttonclickrelease.wav")
end

local function selectCreatorTool(definition)
	if DRP.PropBlacklist[definition.model] then return end
	net.Start("drp_prop_creator_select_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(definition.model)
	net.SendToServer()
	closeMenu()
end

local function sendAdminSpawn(action, definition)
	if not canUseAdminSpawn() then return end
	net.Start("drp_admin_spawn_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(action, 2)
	net.WriteString(definition.class)
	net.SendToServer()
	surface.PlaySound("ui/buttonclickrelease.wav")
end

local function selectTool(definition)
	local mode = string.lower(tostring(definition.mode or ""))
	if mode == "" then return end
	if DRP.Toolgun and isfunction(DRP.Toolgun.RegisterBundledTools) then
		DRP.Toolgun.RegisterBundledTools()
	end
	if mode ~= "drp_persistence" then RunConsoleCommand("gmod_toolmode", mode) end
	net.Start("drp_tool_select_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(mode)
	net.SendToServer()
	closeMenu()
	if mode == "drp_persistence" then return end
	timer.Simple(0, function()
		if not IsValid(LocalPlayer()) then return end
		local weapon = LocalPlayer():GetWeapon("gmod_tool")
		if IsValid(weapon) and DRP.Toolgun then DRP.Toolgun.SyncWeapon(weapon) end
		RunConsoleCommand("gmod_toolmode", mode)
	end)
end

local function requestXPOverview()
	if (util.NetworkStringToID("drp_xp_overview_request_v1") or 0) <= 0 then return end
	net.Start("drp_xp_overview_request_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.SendToServer()
end

local function weaponKey(definition) return "weapon:" .. string.lower(definition.class or "") end

local function weaponUnlocked(definition)
	local key = weaponKey(definition)
	for _, unlocked in ipairs((DRP.ClientXPOverview and DRP.ClientXPOverview.unlocked) or {}) do
		if unlocked == key then return true end
	end
	return false
end

local function sendPrestigeWeapon(definition)
	net.Start("drp_prestige_weapon_spawn_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(definition.class)
	net.SendToServer()
	surface.PlaySound("ui/buttonclickrelease.wav")
end

local function sendUtilityWeapon(definition)
	net.Start("drp_utility_weapon_select_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(definition.class)
	net.SendToServer()
	surface.PlaySound("ui/buttonclickrelease.wav")
end

local function redeemPrestigeWeapon(definition)
	UI.Confirm(
		"Permanent Weapon Unlock",
		"Spend one Prestige Token to permanently unlock " .. definition.name .. " (" .. definition.class .. ")? This applies only to this exact weapon and cannot be refunded. Future prestiges will not remove it.",
		"SPEND 1 TOKEN",
		function()
			net.Start("drp_xp_action_v1")
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.WriteUInt(1, 4)
			net.WriteString(weaponKey(definition))
			net.SendToServer()
			timer.Simple(0.4, requestXPOverview)
		end,
		colors.green
	)
end

local function sendBlacklistUpdate(definition, blocked)
	if not canManageBlacklist() then return end
	net.Start("drp_prop_blacklist_update_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(definition.model)
	net.WriteBool(blocked)
	net.SendToServer()
end

local function sendPriceUpdate(definition, price)
	if not canManagePrices() then return end
	net.Start("drp_prop_price_set_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(definition.model)
	net.WriteUInt(math.Clamp(math.floor(tonumber(price) or 0), 0, 65535), 16)
	net.SendToServer()
end

local function openPropContext(definition)
	local context = DermaMenu()
	if not DRP.PropBlacklist[definition.model] then
		context:AddOption("Spawn with Tool Gun", function() selectCreatorTool(definition) end):SetIcon("icon16/brick_add.png")
		context:AddSpacer()
	end
	context:AddOption("Copy model path", function() SetClipboardText(definition.model) end):SetIcon("icon16/page_copy.png")
	context:AddOption("Copy prop directory", function()
		SetClipboardText(string.GetPathFromFilename(definition.model))
	end):SetIcon("icon16/folder.png")
	if canManageBlacklist() then
		context:AddSpacer()
		local blocked = DRP.PropBlacklist[definition.model] == true
		local option = context:AddOption(blocked and "Whitelist prop" or "Blacklist prop", function()
			sendBlacklistUpdate(definition, not blocked)
		end)
		option:SetIcon(blocked and "icon16/accept.png" or "icon16/cancel.png")
	end
	if canManagePrices() then
		context:AddSpacer()
		context:AddOption("Set prop price…", function()
			Derma_StringRequest(
				"Set Prop Price",
				definition.name .. "\n" .. definition.model .. "\nEnter 0 to restore automatic pricing.",
				tostring(definition.price or 0),
				function(value)
					local price = math.floor(tonumber(value) or -1)
					if price < 0 or price > 65535 then
						Derma_Message("Price must be between $1 and $65,535, or $0 to restore automatic pricing.", "Invalid Price", "OK")
						return
					end
					sendPriceUpdate(definition, price)
				end,
				nil,
				"Save",
				"Cancel"
			)
		end):SetIcon("icon16/money_dollar.png")
		if definition.priceOverridden then
			context:AddOption("Restore automatic price", function() sendPriceUpdate(definition, 0) end):SetIcon("icon16/arrow_refresh.png")
		end
	end
	context:Open()
end

local function sendCivicItemUpdate(action, definition, enabled, value)
	if not canManageCivicAccess() then return end
	net.Start("drp_civic_item_permissions_update_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(action, 2)
	net.WriteString(definition.key)
	if action == 1 then
		net.WriteBool(enabled == true)
		if enabled then net.WriteInt(math.Clamp(math.floor(tonumber(value) or 0), -1000, 1000), 12) end
	elseif action == 2 then
		net.WriteBool(enabled == true)
	end
	net.SendToServer()
end

local function sendWeaponCrateUpdate(weaponClass, enabled)
	if not canManageCivicAccess() then return end
	net.Start("drp_civic_item_permissions_update_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(0, 2)
	net.WriteString("dynamic_crate")
	net.WriteString(string.lower(tostring(weaponClass or "")))
	net.WriteBool(enabled == true)
	net.SendToServer()
end

local function openCivicAccessContext(definition)
	if not canManageCivicAccess() then return end
	local policy = civicItemPolicy(definition)
	local context = DermaMenu()
	context:AddOption("Copy item key", function() SetClipboardText(definition.key) end):SetIcon("icon16/page_copy.png")
	context:AddSpacer()
	if policy.protected then
		local fixed = context:AddOption("Fixed owner/government infrastructure")
		fixed:SetEnabled(false)
	elseif policy.crate then
		local dealer = context:AddOption("Gun Dealer access: always enabled")
		dealer:SetEnabled(false)
		local contents = context:AddOption("Contents: " .. tostring(policy.weaponName or policy.weapon or definition.weapon))
		contents:SetEnabled(false)
		if definition.dynamicCrate then
			context:AddOption("Remove generated weapon crate", function()
				sendWeaponCrateUpdate(definition.weapon, false)
			end):SetIcon("icon16/delete.png")
		end
		local label = policy.mobBossAllowed and "Disable Mob Boss crate access" or "Enable Mob Boss crate access"
		context:AddOption(label, function()
			sendCivicItemUpdate(2, definition, not policy.mobBossAllowed)
		end):SetIcon(policy.mobBossAllowed and "icon16/delete.png" or "icon16/accept.png")
	else
		local current = policy.thresholdEnabled and tostring(policy.threshold) or "ROLE ONLY"
		context:AddOption("Set civic threshold…", function()
			Derma_StringRequest(
				"Civic Item Access",
				definition.name .. "\nEnter the maximum civic standing allowed (-1000 to 1000).\nCurrent: " .. current,
				policy.thresholdEnabled and tostring(policy.threshold) or "-150",
				function(value)
					local threshold = math.floor(tonumber(value) or 2001)
					if threshold < -1000 or threshold > 1000 then
						Derma_Message("Civic standing must be between -1000 and 1000.", "Invalid Civic Threshold", "OK")
						return
					end
					sendCivicItemUpdate(1, definition, true, threshold)
				end,
				nil,
				"Save",
				"Cancel"
			)
		end):SetIcon("icon16/chart_line.png")
		context:AddOption("Require role identity only", function()
			sendCivicItemUpdate(1, definition, false)
		end):SetIcon("icon16/lock.png")
		if policy.overridden then
			context:AddOption("Restore default policy", function()
				sendCivicItemUpdate(3, definition)
			end):SetIcon("icon16/arrow_refresh.png")
		end
	end
	context:Open()
end

local function crateDefinitionsForWeapon(class)
	local output = {}
	class = string.lower(tostring(class or ""))
	for _, definition in ipairs(allJobEntityDefinitions()) do
		if definition.class == "drp_weapon_crate" and string.lower(tostring(definition.weapon or "")) == class then
			output[#output + 1] = definition
		end
	end
	return output
end

local function openAdminSpawnContext(definition)
	local context = DermaMenu()
	if definition.kind == "civic_permission" then
		context:Remove()
		openCivicAccessContext(definition)
		return
	elseif definition.kind == "tool" then
		context:AddOption("Select tool", function() selectTool(definition) end):SetIcon("icon16/wrench.png")
	elseif definition.kind == "weapon" then
		if definition.class == "gmod_tool" or definition.class == "weapon_physgun" or canEquipUtilityWeapon(definition) then
			local label = definition.class == "weapon_medkit" and "Equip HL medkit"
				or (roleSelectableWeapons[definition.class] and "Equip role weapon" or "Equip building utility")
			context:AddOption(label,
				function() sendUtilityWeapon(definition) end):SetIcon("icon16/wrench.png")
		end
		local unlocked = weaponUnlocked(definition)
		if unlocked then context:AddOption("Spawn permanent weapon", function() sendPrestigeWeapon(definition) end):SetIcon("icon16/gun.png") end
		if definition.prestigeEligible and not unlocked and (DRP.ClientProfile.prestigeTokens or 0) > 0 then
			context:AddOption("Use Prestige Token…", function() redeemPrestigeWeapon(definition) end):SetIcon("icon16/award_star_gold_1.png")
		elseif not unlocked then
			local unavailable = context:AddOption(definition.prestigeEligible and "Requires 1 Prestige Token" or "System weapon — cannot be unlocked")
			unavailable:SetEnabled(false)
		end
		if canUseAdminSpawn() then
			context:AddSpacer()
			context:AddOption("Admin: give weapon", function() sendAdminSpawn(2, definition) end):SetIcon("icon16/gun.png")
			context:AddOption("Admin: spawn on ground", function() sendAdminSpawn(3, definition) end):SetIcon("icon16/brick_add.png")
		end
		if canSetWeaponUnlocks() and definition.prestigeEligible then
			context:AddSpacer()
			context:AddOption("HeadAdmin: set unlock level…", function()
				local current = (DRP.WeaponUnlockLevels or {})[definition.class] or 1
				Derma_StringRequest("Weapon Unlock Level", definition.name .. "\n" .. definition.class .. "\nEnter a level from 1 to 100.", tostring(current), function(value)
					local level = math.floor(tonumber(value) or 0)
					if level < 1 or level > 100 then Derma_Message("Level must be between 1 and 100.", "Invalid Level", "OK") return end
					net.Start("drp_weapon_unlock_set_v1")
					net.WriteUInt(DRP.ProtocolVersion, 8)
					net.WriteString(definition.class)
					net.WriteUInt(level, 7)
					net.SendToServer()
				end, nil, "Save", "Cancel")
			end):SetIcon("icon16/lock_edit.png")
		end
		if canManageCivicAccess() and definition.prestigeEligible then
			local generated
			for _, crate in ipairs(DRP.DynamicWeaponCrates or {}) do
				if string.lower(tostring(crate.weapon or "")) == string.lower(definition.class) then generated = crate break end
			end
			context:AddSpacer()
			context:AddOption(generated and "HeadAdmin: remove generated weapon crate" or "HeadAdmin: create new weapon crate", function()
				sendWeaponCrateUpdate(definition.class, generated == nil)
			end):SetIcon(generated and "icon16/delete.png" or "icon16/package_add.png")
			local crateDefinitions = crateDefinitionsForWeapon(definition.class)
			if #crateDefinitions > 0 then
				context:AddSpacer()
				for _, crateDefinition in ipairs(crateDefinitions) do
					local crate = crateDefinition
					local allowed = civicItemPolicy(crate).mobBossAllowed == true
					context:AddOption(
						"HeadAdmin: " .. (allowed and "deny" or "allow") .. " Mob Boss " .. crate.name,
						function() sendCivicItemUpdate(2, crate, not allowed) end
					):SetIcon(allowed and "icon16/delete.png" or "icon16/accept.png")
				end
			end
		end
	else
		context:AddOption("Spawn entity", function() sendAdminSpawn(1, definition) end):SetIcon("icon16/brick_add.png")
	end
	context:AddSpacer()
	context:AddOption(definition.kind == "tool" and "Copy tool mode" or "Copy class", function() SetClipboardText(definition.class) end):SetIcon("icon16/page_copy.png")
	context:Open()
end

local function styleScrollBar(scroll)
	local bar = scroll:GetVBar()
	bar:SetWide(8)
	bar.Paint = function(_, width, height)
		draw.RoundedBox(4, 1, 0, width - 2, height, Color(8, 11, 17, 170))
	end
	bar.btnUp.Paint = function() end
	bar.btnDown.Paint = function() end
	bar.btnGrip.Paint = function(_, width, height)
		draw.RoundedBox(4, 1, 0, width - 2, height, colors.line)
	end
end

local function createPropTile(parent, definition, blacklistedPage)
	local tile = vgui.Create("DPanel", parent)
	tile:SetSize(116, 154)
	tile.Hovered = false
	tile.Paint = function(self, width, height)
		local background = self.Hovered and colors.panelHover or colors.panel
		draw.RoundedBox(7, 0, 0, width, height, background)
		if self.Hovered or blacklistedPage then
			draw.RoundedBoxEx(7, 0, 0, 3, height, blacklistedPage and colors.red or colors.accent, true, false, true, false)
		end
		local priceColor = definition.priceOverridden and Color(255, 190, 75) or colors.green
		draw.SimpleText(definition.price and ("$" .. string.Comma(definition.price)) or "$…", "DRP.Admin.Small", width * 0.5, height - 11, priceColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	local icon = vgui.Create("SpawnIcon", tile)
	icon:SetPos(8, 7)
	icon:SetSize(100, 100)
	icon:SetModel(definition.model)
	icon:SetTooltip(nil)
	icon.DoClick = function() if not blacklistedPage then sendSpawn(definition) end end
	icon.DoRightClick = function() openPropContext(definition) end
	icon.OnCursorEntered = function() tile.Hovered = true end
	icon.OnCursorExited = function() tile.Hovered = false end

	local label = vgui.Create("DLabel", tile)
	label:SetPos(7, 108)
	label:SetSize(102, 22)
	label:SetFont("DRP.SpawnMenu.Icon")
	label:SetText(definition.name)
	label:SetTextColor(blacklistedPage and colors.red or color_white)
	label:SetContentAlignment(5)
	label:SetWrap(false)
	label:SetMouseInputEnabled(true)
	label:SetCursor("hand")
	label.OnCursorEntered = function() tile.Hovered = true end
	label.OnCursorExited = function() tile.Hovered = false end
	label.OnMousePressed = function(_, code)
		if code == MOUSE_LEFT and not blacklistedPage then sendSpawn(definition) end
		if code == MOUSE_RIGHT then openPropContext(definition) end
	end
	tile.PerformLayout = function(self, width)
		icon:SetPos(math.floor((width - icon:GetWide()) * 0.5), 7)
		label:SetPos(8, 109)
		label:SetWide(width - 16)
	end
	return tile
end

local function createAdminSpawnTile(parent, definition)
	local tile = vgui.Create("DPanel", parent)
	tile:SetSize(116, 142)
	tile.Hovered = false
	tile.Paint = function(self, width, height)
		draw.RoundedBox(7, 0, 0, width, height, self.Hovered and colors.panelHover or colors.panel)
		if self.Hovered then draw.RoundedBoxEx(7, 0, 0, 3, height, colors.accent, true, false, true, false) end
		local footer, footerColor = "SPAWN", colors.accent
		if definition.kind == "weapon" then
			local unlockLevel = (DRP.WeaponUnlockLevels or {})[definition.class] or 1
			if definition.class == "gmod_tool" or definition.class == "weapon_physgun" or canEquipUtilityWeapon(definition) then footer, footerColor = "EQUIP", colors.accent
			elseif (tonumber(DRP.ClientProfile.level) or 1) < unlockLevel then footer, footerColor = "LEVEL " .. unlockLevel, colors.red
			elseif weaponUnlocked(definition) then footer, footerColor = "PERMANENT", colors.green
			elseif not definition.prestigeEligible then footer, footerColor = "SYSTEM", colors.muted
			elseif (DRP.ClientProfile.prestigeTokens or 0) > 0 then footer, footerColor = "1 TOKEN", colors.purple
			else footer, footerColor = "LOCKED", colors.muted end
		elseif definition.kind == "job_entity" then
			footer = "$" .. string.Comma(definition.price or 0)
		elseif definition.kind == "civic_permission" then
			local policy = definition.accessPolicy or {}
			if policy.protected then
				footer, footerColor = "FIXED", colors.muted
			elseif policy.crate then
				footer, footerColor = policy.mobBossAllowed and "BOSS + DEALER" or "DEALER ONLY", policy.mobBossAllowed and colors.purple or colors.accent
			elseif policy.thresholdEnabled then
				footer, footerColor = "CIVIC ≤ " .. tostring(policy.threshold), colors.green
			else
				footer, footerColor = "ROLE ONLY", colors.muted
			end
		elseif definition.kind == "tool" then
			footer, footerColor = definition.mode == "drp_persistence" and "OWNER" or "EQUIP", definition.mode == "drp_persistence" and colors.purple or colors.accent
		end
		draw.SimpleText(footer, "DRP.Admin.Small", width * 0.5, height - 10, footerColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	local click = function()
		if definition.kind == "job_entity" then
			sendJobEntitySpawn(definition)
		elseif definition.kind == "civic_permission" then
			openCivicAccessContext(definition)
		elseif definition.kind == "tool" then
			selectTool(definition)
		elseif definition.kind == "weapon" then
			if definition.class == "gmod_tool" or definition.class == "weapon_physgun" or canEquipUtilityWeapon(definition) then sendUtilityWeapon(definition)
			elseif weaponUnlocked(definition) then sendPrestigeWeapon(definition)
			elseif canUseAdminSpawn() then sendAdminSpawn(2, definition)
			else openAdminSpawnContext(definition) end
		else
			sendAdminSpawn(1, definition)
		end
	end
	local validPreviewModel = isstring(definition.model) and definition.model ~= "" and util.IsValidModel(definition.model)
	local icon
	if validPreviewModel then
		icon = vgui.Create("SpawnIcon", tile)
		icon:SetModel(definition.model)
	else
		icon = vgui.Create("DImageButton", tile)
		icon:SetImage(definition.icon or "icon16/brick.png")
	end
	icon:SetPos(8, 7)
	icon:SetSize(100, 92)
	icon:SetTooltip(nil)
	icon.DoClick = click
	icon.DoRightClick = function() if definition.kind ~= "job_entity" then openAdminSpawnContext(definition) end end
	icon.OnCursorEntered = function() tile.Hovered = true end
	icon.OnCursorExited = function() tile.Hovered = false end

	local label = vgui.Create("DLabel", tile)
	label:SetPos(7, 101)
	label:SetSize(102, 22)
	label:SetFont("DRP.SpawnMenu.Icon")
	label:SetText(definition.name)
	label:SetTextColor(color_white)
	label:SetContentAlignment(5)
	label:SetMouseInputEnabled(true)
	label:SetCursor("hand")
	label.OnCursorEntered = function() tile.Hovered = true end
	label.OnCursorExited = function() tile.Hovered = false end
	label.OnMousePressed = function(_, code)
		if code == MOUSE_LEFT then click() end
		if code == MOUSE_RIGHT and definition.kind ~= "job_entity" then openAdminSpawnContext(definition) end
	end
	tile.PerformLayout = function(self, width)
		icon:SetPos(math.floor((width - icon:GetWide()) * 0.5), 7)
		label:SetPos(8, 101)
		label:SetWide(width - 16)
	end
	return tile
end

local function openMenu(openedFromBind)
	if IsValid(menu) then return end
	if IsValid(g_SpawnMenu) and g_SpawnMenu:IsVisible() then
		if isfunction(g_SpawnMenu.SetHangOpen) then g_SpawnMenu:SetHangOpen(false) end
		if isfunction(g_SpawnMenu.Close) then g_SpawnMenu:Close() end
	end
	buildSandboxCatalog()
	buildAdminCatalogs()
	requestXPOverview()
	if not serverCatalogChecked and not serverCatalogLoading then
		serverCatalogChecked = true
		serverCatalogLoading = true
		net.Start("drp_prop_catalog_request_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteString(serverCatalogFingerprint)
		net.SendToServer()
		-- A matching fingerprint intentionally receives no response.
		if serverCatalogModels then serverCatalogLoading = false end
	end
	net.Start("drp_prop_blacklist_request_v1")
	net.SendToServer()
	net.Start("drp_civic_item_permissions_request_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.SendToServer()

	menu = vgui.Create("DFrame")
	menu:SetSize(math.min(1240, ScrW() - 36), math.min(820, ScrH() - 36))
	menu:Center()
	menu:SetTitle("")
	menu:ShowCloseButton(false)
	menu:SetDraggable(false)
	menu:SetSizable(false)
	menu:MakePopup()
	menu:SetKeyboardInputEnabled(false)
	menu:SetMouseInputEnabled(true)
	menu.OpenedFromBind = openedFromBind == true
	menu.HangOpen = false
	menu.OnClose = function(self)
		if self.SaveState then self:SaveState() end
		if menu == self then menu = nil end
	end
	menu.OnRemove = function(self)
		if self.SaveState then self:SaveState() end
		if menu == self then menu = nil end
	end
	menu.Paint = function(_, width, height)
		draw.RoundedBox(8, 0, 0, width, height, colors.background)
		draw.RoundedBoxEx(8, 0, 0, width, 94, colors.panel, true, true, false, false)
		surface.SetDrawColor(colors.accent)
		surface.DrawRect(0, 93, width, 2)
	end

	local top = vgui.Create("DPanel", menu)
	top:Dock(TOP)
	top:SetTall(94)
	top.Paint = nil

	local brand = vgui.Create("DLabel", top)
	brand:Dock(LEFT)
	brand:SetWide(165)
	brand:DockMargin(18, 0, 0, 0)
	brand:SetFont("DRP.Admin.Title")
	brand:SetText("")
	brand.Paint = function(_, _, height)
		draw.SimpleText("SPAWN MENU", "DRP.Admin.Title", 4, 28, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("BUILD  •  CREATE  •  MANAGE", "DRP.Admin.Small", 4, 49, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local requestedPage = tostring(menuState.activePage or "props")
	local activePage = "props"
	if requestedPage == "blacklisted" and canManageBlacklist() then
		activePage = "blacklisted"
	elseif requestedPage == "civic_access" and canManageCivicAccess() then
		activePage = "civic_access"
	elseif requestedPage == "job_entities" or requestedPage == "weapons" or requestedPage == "tools" or (requestedPage == "entities" and canUseAdminSpawn()) then
		activePage = requestedPage
	end
	local activeCategory = tostring(menuState.activeCategory or "All")
	local currentPage = math.max(1, math.floor(tonumber(menuState.currentPage) or 1))
	local propTab
	local marketplaceTab
	local blacklistTab
	local entityTab
	local weaponTab
	local toolTab
	local jobEntityTab
	local civicAccessTab

	local function paintTab(button, page)
		local text = button:GetText()
		button:SetText("")
		button.Paint = function(self, width, height)
			local active = activePage == page
			if active or self:IsHovered() then
				draw.RoundedBox(6, 5, 42, width - 10, 39, active and colors.panelHover or colors.background)
			end
			draw.SimpleText(text, "DRP.SpawnMenu.Tab", width * 0.5, 61, active and color_white or colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			if active then
				surface.SetDrawColor(page == "blacklisted" and colors.red or colors.accent)
				surface.DrawRect(14, 84, width - 28, 3)
			end
		end
	end

	propTab = vgui.Create("DButton", top)
	propTab:Dock(LEFT)
	propTab:SetWide(104)
	propTab:SetText("Props")
	propTab:SetFont("DRP.SpawnMenu.Tab")
	propTab:SetTextColor(color_white)
	paintTab(propTab, "props")

	marketplaceTab = vgui.Create("DButton", top)
	marketplaceTab:Dock(LEFT)
	marketplaceTab:SetWide(120)
	marketplaceTab:SetText("Marketplace")
	marketplaceTab:SetFont("DRP.SpawnMenu.Tab")
	marketplaceTab:SetTextColor(color_white)
	paintTab(marketplaceTab, "marketplace")

	jobEntityTab = vgui.Create("DButton", top)
	jobEntityTab:Dock(LEFT)
	jobEntityTab:SetWide(132)
	jobEntityTab:SetText("Job Entities")
	jobEntityTab:SetFont("DRP.SpawnMenu.Tab")
	jobEntityTab:SetTextColor(color_white)
	paintTab(jobEntityTab, "job_entities")

	if canUseAdminSpawn() then
		entityTab = vgui.Create("DButton", top)
		entityTab:Dock(LEFT)
		entityTab:SetWide(112)
		entityTab:SetText("Entities")
		entityTab:SetFont("DRP.SpawnMenu.Tab")
		entityTab:SetTextColor(color_white)
		paintTab(entityTab, "entities")

	end

	weaponTab = vgui.Create("DButton", top)
	weaponTab:Dock(LEFT)
	weaponTab:SetWide(112)
	weaponTab:SetText("Weapons")
	weaponTab:SetFont("DRP.SpawnMenu.Tab")
	weaponTab:SetTextColor(color_white)
	paintTab(weaponTab, "weapons")

	toolTab = vgui.Create("DButton", top)
	toolTab:Dock(LEFT)
	toolTab:SetWide(100)
	toolTab:SetText("Tools")
	toolTab:SetFont("DRP.SpawnMenu.Tab")
	toolTab:SetTextColor(color_white)
	paintTab(toolTab, "tools")

	if canManageBlacklist() then
		blacklistTab = vgui.Create("DButton", top)
		blacklistTab:Dock(LEFT)
		blacklistTab:SetWide(120)
		blacklistTab:SetText("Blacklisted")
		blacklistTab:SetFont("DRP.SpawnMenu.Tab")
		blacklistTab:SetTextColor(color_white)
		paintTab(blacklistTab, "blacklisted")
	end

	if canManageCivicAccess() then
		civicAccessTab = vgui.Create("DButton", top)
		civicAccessTab:Dock(LEFT)
		civicAccessTab:SetWide(120)
		civicAccessTab:SetText("Civic Access")
		civicAccessTab:SetFont("DRP.SpawnMenu.Tab")
		civicAccessTab:SetTextColor(color_white)
		paintTab(civicAccessTab, "civic_access")
	end

	local close = vgui.Create("DButton", top)
	close:Dock(RIGHT)
	close:SetWide(52)
	close:SetText("")
	close.Paint = function(self, width, height)
		if self:IsHovered() then draw.RoundedBox(6, 8, 14, width - 16, 32, colors.red) end
		draw.SimpleText("×", "DRP.Admin.Title", width * 0.5, 29, self:IsHovered() and color_white or colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	close.DoClick = closeMenu

	local status = vgui.Create("DPanel", menu)
	status:Dock(BOTTOM)
	status:SetTall(34)
	status.Paint = function(_, width)
		surface.SetDrawColor(colors.line)
		surface.DrawRect(0, 0, width, 1)
	end

	local statusText = vgui.Create("DLabel", status)
	statusText:Dock(LEFT)
	statusText:DockMargin(16, 0, 0, 0)
	statusText:SetWide(760)
	statusText:SetFont("DRP.Admin.Small")
	statusText:SetText("Left-click to spawn  •  Right-click for model options  •  Movement remains enabled")
	statusText:SetTextColor(colors.muted)

	local shortcut = vgui.Create("DLabel", status)
	shortcut:Dock(RIGHT)
	shortcut:DockMargin(0, 0, 16, 0)
	shortcut:SetWide(250)
	shortcut:SetFont("DRP.Admin.Small")
	shortcut:SetText(openedFromBind and "Release Q to close" or "Q opens the spawn menu")
	shortcut:SetTextColor(colors.accent)
	shortcut:SetContentAlignment(6)

	local body = vgui.Create("DPanel", menu)
	body:Dock(FILL)
	body:DockMargin(14, 14, 14, 12)
	body.Paint = nil

	local sidebar = vgui.Create("DPanel", body)
	sidebar:Dock(LEFT)
	sidebar:SetWide(236)
	sidebar.Paint = function(_, width, height)
		draw.RoundedBox(6, 0, 0, width, height, colors.panel)
	end

	local search = vgui.Create("DTextEntry", sidebar)
	search:Dock(TOP)
	search:DockMargin(12, 12, 12, 10)
	search:SetTall(36)
	search:SetFont("DRP.Admin.Body")
	search:SetPlaceholderText("Search props...")
	search:SetText(searchText)
	search:SetUpdateOnType(true)
	search:SetTextColor(color_white)
	search:SetPlaceholderColor(colors.muted)
	search:SetPaintBackground(false)
	search.Paint = function(self, width, height)
		draw.RoundedBox(5, 0, 0, width, height, Color(10, 14, 21, 220))
		surface.SetDrawColor(self:HasFocus() and colors.accent or colors.line)
		surface.DrawOutlinedRect(0, 0, width, height, 1)
		self:DrawTextEntryText(color_white, colors.accent, color_white)
	end
	search.OnGetFocus = function(self)
		if not IsValid(menu) then return end
		menu.HangOpen = true
		menu.KeyFocus = self
		menu:SetKeyboardInputEnabled(true)
		shortcut:SetText("Typing search  •  Menu will remain open")
	end
	search.OnLoseFocus = function(self)
		if not IsValid(menu) or menu.KeyFocus ~= self then return end
		menu.KeyFocus = nil
		menu:SetKeyboardInputEnabled(false)
		shortcut:SetText("Movement enabled  •  Q closes menu")
	end

	local browseHeader = vgui.Create("DLabel", sidebar)
	browseHeader:Dock(TOP)
	browseHeader:DockMargin(15, 5, 10, 5)
	browseHeader:SetTall(26)
	browseHeader:SetFont("DRP.Admin.Small")
	browseHeader:SetText("SPAWNLISTS")
	browseHeader:SetTextColor(colors.muted)

	local categoryScroll = vgui.Create("DScrollPanel", sidebar)
	categoryScroll:Dock(FILL)
	categoryScroll:DockMargin(7, 0, 7, 10)
	styleScrollBar(categoryScroll)

	local content = vgui.Create("DPanel", body)
	content:Dock(FILL)
	content:DockMargin(12, 0, 0, 0)
	content.Paint = function(_, width, height)
		draw.RoundedBox(6, 0, 0, width, height, Color(13, 18, 27, 235))
	end

	local contentHeader = vgui.Create("DPanel", content)
	contentHeader:Dock(TOP)
	contentHeader:SetTall(52)
	contentHeader.Paint = function(_, width, height)
		surface.SetDrawColor(colors.line)
		surface.DrawRect(0, height - 1, width, 1)
	end

	local contentTitle = vgui.Create("DLabel", contentHeader)
	contentTitle:Dock(LEFT)
	contentTitle:DockMargin(18, 0, 0, 0)
	contentTitle:SetWide(330)
	contentTitle:SetFont("DRP.Admin.Header")
	contentTitle:SetTextColor(color_white)
	contentTitle:SetContentAlignment(4)

	local nextPage = vgui.Create("DButton", contentHeader)
	nextPage:Dock(RIGHT)
	nextPage:DockMargin(4, 8, 12, 8)
	nextPage:SetWide(34)
	nextPage:SetText("›")
	nextPage:SetFont("DRP.Admin.Header")
	nextPage:SetTextColor(color_white)
	nextPage.Paint = function(self, width, height)
		draw.RoundedBox(5, 0, 0, width, height, self:IsHovered() and colors.accent or colors.panelHover)
	end

	local previousPage = vgui.Create("DButton", contentHeader)
	previousPage:Dock(RIGHT)
	previousPage:DockMargin(4, 8, 0, 8)
	previousPage:SetWide(34)
	previousPage:SetText("‹")
	previousPage:SetFont("DRP.Admin.Header")
	previousPage:SetTextColor(color_white)
	previousPage.Paint = nextPage.Paint

	local contentCount = vgui.Create("DLabel", contentHeader)
	contentCount:Dock(RIGHT)
	contentCount:DockMargin(0, 0, 6, 0)
	contentCount:SetWide(225)
	contentCount:SetFont("DRP.Admin.Small")
	contentCount:SetTextColor(colors.muted)
	contentCount:SetContentAlignment(6)

	local propScroll = vgui.Create("DScrollPanel", content)
	propScroll:Dock(FILL)
	propScroll:DockMargin(12, 12, 7, 10)
	styleScrollBar(propScroll)

	local grid = vgui.Create("DIconLayout", propScroll)
	grid:Dock(TOP)
	grid:SetTall(1)
	grid:SetSpaceX(10)
	grid:SetSpaceY(10)
	grid:SetStretchHeight(true)
	grid:SetStretchWidth(true)

	local categoryButtons = {}
	local rebuildGrid
	local rebuildCategories

	local function pageDefinitions()
		if activePage == "job_entities" then return jobEntityCatalog() end
		if activePage == "civic_access" then return civicAccessCatalog() end
		if activePage == "entities" then return adminEntityCatalog or {} end
		if activePage == "weapons" then return adminWeaponCatalog or {} end
		if activePage == "tools" then return toolCatalog() end
		local definitions = {}
		local seen = {}
		local blacklistedPage = activePage == "blacklisted"
		for _, definition in ipairs(catalog or {}) do
			local blocked = DRP.PropBlacklist[definition.model] == true
			if blocked == blacklistedPage then
				definitions[#definitions + 1] = definition
				seen[definition.model] = true
			end
		end
		if blacklistedPage then
			for model in pairs(DRP.PropBlacklist) do
				if not seen[model] then
					definitions[#definitions + 1] = {
						model = model, name = friendlyModelName(model), category = "Unavailable",
						categories = { Unavailable = true }
					}
				end
			end
		end
		return definitions
	end

	local function matches(definition)
		if activeCategory ~= "All" and not definition.categories[activeCategory] then return false end
		local needle = string.Trim(string.lower(searchText or ""))
		if needle == "" then return true end
		local haystack = string.lower(definition.name .. " " .. tostring(definition.model or definition.class or "") .. " " .. table.concat(table.GetKeys(definition.categories), " "))
		return string.find(haystack, needle, 1, true) ~= nil
	end

	local function updateCategoryButtons()
		for category, button in pairs(categoryButtons) do button.Active = category == activeCategory end
	end

	rebuildCategories = function()
		categoryScroll:GetCanvas():Clear()
		categoryButtons = {}
		local counts = { All = 0 }
		for _, definition in ipairs(pageDefinitions()) do
			counts.All = counts.All + 1
			for category in pairs(definition.categories) do counts[category] = (counts[category] or 0) + 1 end
		end
		if activeCategory ~= "All" and not counts[activeCategory] then activeCategory = "All" end
		local allLabel = activePage == "blacklisted" and "All Blacklisted"
			or (activePage == "civic_access" and "All Civic Rules")
			or (activePage == "job_entities" and "All Job Entities")
			or (activePage == "entities" and "All Entities")
			or (activePage == "weapons" and "All Weapons")
			or (activePage == "tools" and "All Tools")
			or "All Props"
		local categories = {{ key = "All", label = allLabel, count = counts.All }}
		for category, count in pairs(counts) do
			if category ~= "All" then categories[#categories + 1] = { key = category, label = category, count = count } end
		end
		table.sort(categories, function(first, second)
			if first.key == "All" then return true end
			if second.key == "All" then return false end
			return string.lower(first.label) < string.lower(second.label)
		end)
		for _, category in ipairs(categories) do
			local categoryData = category
			local button = vgui.Create("DButton", categoryScroll)
			button:Dock(TOP)
			button:DockMargin(4, 1, 4, 1)
			button:SetTall(34)
			button:SetText("")
			button.Active = category.key == activeCategory
			button.Paint = function(self, width, height)
				if self.Active then
					draw.RoundedBox(4, 0, 0, width, height, colors.panelHover)
					draw.RoundedBoxEx(4, 0, 0, 4, height, activePage == "blacklisted" and colors.red or colors.accent, true, false, true, false)
				elseif self:IsHovered() then
					draw.RoundedBox(4, 0, 0, width, height, Color(28, 37, 51, 190))
				end
				draw.SimpleText(categoryData.label, "DRP.SpawnMenu.Category", 13, height * 0.5, self.Active and color_white or colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(categoryData.count, "DRP.Admin.Small", width - 12, height * 0.5, self.Active and (activePage == "blacklisted" and colors.red or colors.accent) or colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
			end
			button.DoClick = function()
				activeCategory = categoryData.key
				currentPage = 1
				updateCategoryButtons()
				rebuildGrid()
			end
			categoryButtons[category.key] = button
		end
	end

	rebuildGrid = function()
		grid:Clear()
		local filtered = {}
		for _, definition in ipairs(pageDefinitions()) do
			if matches(definition) then filtered[#filtered + 1] = definition end
		end
		table.sort(filtered, function(first, second) return first.name < second.name end)
		local pageCount = math.max(1, math.ceil(#filtered / itemsPerPage))
		currentPage = math.Clamp(currentPage, 1, pageCount)
		local firstIndex = ((currentPage - 1) * itemsPerPage) + 1
		local lastIndex = math.min(firstIndex + itemsPerPage - 1, #filtered)
		for index = firstIndex, lastIndex do
			local definition = filtered[index]
			if activePage == "entities" or activePage == "weapons" or activePage == "job_entities" or activePage == "tools" or activePage == "civic_access" then
				createAdminSpawnTile(grid, definition)
			else
				createPropTile(grid, definition, activePage == "blacklisted")
			end
		end

		local rootTitle = activePage == "blacklisted" and "Blacklisted Props"
			or (activePage == "civic_access" and "Civic Item Access")
			or (activePage == "job_entities" and "Job Entities")
			or (activePage == "entities" and "Entities")
			or (activePage == "weapons" and "Weapons")
			or (activePage == "tools" and "Tools")
			or "All Props"
		local title = activeCategory == "All" and rootTitle or activeCategory
		contentTitle:SetText(title)
		if serverCatalogLoading and (activePage == "props" or activePage == "blacklisted") then
			contentCount:SetText(serverCatalogExpected > 0 and ("Receiving " .. serverCatalogExpected .. " server props…") or "Indexing server props…")
		else
			contentCount:SetText(#filtered .. (#filtered == 1 and " item" or " items") .. "  •  Page " .. currentPage .. "/" .. pageCount)
		end
		previousPage:SetEnabled(currentPage > 1)
		nextPage:SetEnabled(currentPage < pageCount)
		if #filtered == 0 then
			local empty = vgui.Create("DLabel", grid)
			empty:SetSize(500, 80)
			empty:SetFont("DRP.Admin.Body")
			empty:SetText(activePage == "blacklisted" and "No props are blacklisted."
				or (activePage == "civic_access" and "No configurable job entities are registered.")
				or (activePage == "entities" and "No spawnable entities match your search.")
				or (activePage == "weapons" and "No weapons match your search.")
				or (activePage == "tools" and "No tools match your search.")
				or "No props match your search.")
			empty:SetTextColor(colors.muted)
			empty:SetContentAlignment(5)
		end
		propScroll:GetVBar():SetScroll(0)
		grid:InvalidateLayout(true)
	end

	local function switchPage(page)
		if page == "blacklisted" and not canManageBlacklist() then return end
		if page == "civic_access" and not canManageCivicAccess() then return end
		if page == "entities" and not canUseAdminSpawn() then return end
		activePage = page
		activeCategory = "All"
		currentPage = 1
		search:SetPlaceholderText(page == "entities" and "Search entities..." or (page == "weapons" and "Search weapons..." or (page == "tools" and "Search tools..." or (page == "civic_access" and "Search civic item rules..." or (page == "job_entities" and "Search job entities..." or "Search props...")))))
		statusText:SetText(page == "weapons" and "All server weapons  •  Right-click to spend a Prestige Token  •  Permanent unlocks spawn free"
			or (page == "entities" and "Left-click to spawn  •  Right-click for entity options  •  Admin+ only"
			or (page == "tools" and "Left-click to equip and open the tool options  •  Tools can affect only your entities"
			or (page == "civic_access" and "HeadAdmin  •  Configure civic thresholds and the Mob Boss weapon-crate allowlist"
			or (page == "job_entities" and "Left-click to purchase and spawn an entity available to your current job"
			or "Left-click to spawn  •  Right-click for model options  •  Movement remains enabled")))))
		rebuildCategories()
		rebuildGrid()
	end

	propTab.DoClick = function() switchPage("props") end
	marketplaceTab.DoClick = function()
		if menu and menu.SaveState then menu:SaveState() end
		closeMenu()
		timer.Simple(0, function()
			if DRP.ContractsUI and isfunction(DRP.ContractsUI.Request) then
				DRP.ContractsUI.Request(true)
			end
		end)
	end
	jobEntityTab.DoClick = function() switchPage("job_entities") end
	if IsValid(entityTab) then entityTab.DoClick = function() switchPage("entities") end end
	if IsValid(weaponTab) then weaponTab.DoClick = function() switchPage("weapons") end end
	if IsValid(toolTab) then toolTab.DoClick = function() switchPage("tools") end end
	if IsValid(blacklistTab) then blacklistTab.DoClick = function() switchPage("blacklisted") end end
	if IsValid(civicAccessTab) then civicAccessTab.DoClick = function() switchPage("civic_access") end end
	previousPage.DoClick = function()
		currentPage = math.max(1, currentPage - 1)
		rebuildGrid()
	end
	nextPage.DoClick = function()
		currentPage = currentPage + 1
		rebuildGrid()
	end
	search.OnValueChange = function(_, value)
		searchText = value or ""
		menuState.searchText = searchText
		currentPage = 1
		rebuildGrid()
	end
	local function restoreScrolls(categoryPosition, propPosition)
		local frame = menu
		timer.Simple(0, function()
			if not IsValid(frame) or menu ~= frame or not IsValid(categoryScroll) or not IsValid(propScroll) then return end
			categoryScroll:GetVBar():SetScroll(math.max(0, tonumber(categoryPosition) or 0))
			propScroll:GetVBar():SetScroll(math.max(0, tonumber(propPosition) or 0))
		end)
	end

	menu.RefreshBlacklist = function()
		local categoryPosition = categoryScroll:GetVBar():GetScroll()
		local propPosition = propScroll:GetVBar():GetScroll()
		if activePage == "blacklisted" and not canManageBlacklist() then activePage = "props" end
		if activePage == "civic_access" and not canManageCivicAccess() then activePage = "props" end
		if activePage == "entities" and not canUseAdminSpawn() then activePage = "props" end
		rebuildCategories()
		rebuildGrid()
		restoreScrolls(categoryPosition, propPosition)
	end
	menu.RefreshCatalog = function()
		local categoryPosition = categoryScroll:GetVBar():GetScroll()
		local propPosition = propScroll:GetVBar():GetScroll()
		rebuildCategories()
		rebuildGrid()
		restoreScrolls(categoryPosition, propPosition)
	end
	menu.SaveState = function()
		menuState.activePage = activePage
		menuState.activeCategory = activeCategory
		menuState.currentPage = currentPage
		if IsValid(search) then menuState.searchText = search:GetValue() end
		if IsValid(categoryScroll) then menuState.categoryScroll = categoryScroll:GetVBar():GetScroll() end
		if IsValid(propScroll) then menuState.propScroll = propScroll:GetVBar():GetScroll() end
		searchText = menuState.searchText
	end
	local restoreCategoryScroll = math.max(0, tonumber(menuState.categoryScroll) or 0)
	local restorePropScroll = math.max(0, tonumber(menuState.propScroll) or 0)
	search:SetPlaceholderText(activePage == "entities" and "Search entities..." or (activePage == "weapons" and "Search weapons..." or (activePage == "tools" and "Search tools..." or (activePage == "civic_access" and "Search civic item rules..." or (activePage == "job_entities" and "Search job entities..." or "Search props...")))))
	statusText:SetText(activePage == "weapons" and "All server weapons  •  Right-click to spend a Prestige Token  •  Permanent unlocks spawn free"
		or (activePage == "entities" and "Left-click to spawn  •  Right-click for entity options  •  Admin+ only"
		or (activePage == "tools" and "Left-click to equip and open the tool options  •  Tools can affect only your entities"
		or (activePage == "civic_access" and "HeadAdmin  •  Configure civic thresholds and the Mob Boss weapon-crate allowlist"
		or (activePage == "job_entities" and "Left-click to purchase and spawn an entity available to your current job"
		or "Left-click to spawn  •  Right-click for model options  •  Movement remains enabled")))))
	rebuildCategories()
	rebuildGrid()
	restoreScrolls(restoreCategoryScroll, restorePropScroll)
end

hook.Add("DRPXPOverviewUpdated", "DRP.PropMenu.RefreshWeapons", function()
	if IsValid(menu) and menu.RefreshCatalog then menu.RefreshCatalog() end
end)

hook.Add("DRPWeaponUnlockLevelsUpdated", "DRP.PropMenu.RefreshUnlockLevels", function()
	if IsValid(menu) and menu.RefreshCatalog then menu.RefreshCatalog() end
end)

net.Receive("drp_prop_catalog_begin_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local fingerprint = net.ReadString()
	local expected = net.ReadUInt(32)
	local ready = net.ReadBool()
	serverCatalogLoading = true
	serverCatalogExpected = expected
	if ready then
		local chunks = net.ReadUInt(16)
		serverCatalogFingerprint = fingerprint
		serverCatalogIncoming = { chunks = {}, expected = chunks }
	end
	if IsValid(menu) and menu.RefreshCatalog then menu:RefreshCatalog() end
end)

net.Receive("drp_prop_catalog_chunk_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local fingerprint = net.ReadString()
	local index = net.ReadUInt(16)
	local count = net.ReadUInt(16)
	local length = net.ReadUInt(16)
	local data = net.ReadData(length)
	if fingerprint ~= serverCatalogFingerprint or not serverCatalogIncoming or count ~= serverCatalogIncoming.expected then return end
	serverCatalogIncoming.chunks[index] = data
end)

net.Receive("drp_prop_catalog_end_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local fingerprint = net.ReadString()
	if fingerprint ~= serverCatalogFingerprint or not serverCatalogIncoming then return end
	local compressed = table.concat(serverCatalogIncoming.chunks)
	local decoded = util.JSONToTable(util.Decompress(compressed) or "")
	if not istable(decoded) then serverCatalogLoading = false serverCatalogIncoming = nil return end
	serverCatalogModels = {}
	for _, record in ipairs(decoded) do
		local model = normalizeCatalogModel(record[1])
		if model then serverCatalogModels[#serverCatalogModels + 1] = { model = model, price = tonumber(record[2]) or 10, overridden = record[3] == 1 } end
	end
	serverCatalogIncoming = nil
	serverCatalogLoading = false
	serverCatalogExpected = #serverCatalogModels
	saveClientCatalog()
	catalog = nil
	buildSandboxCatalog()
	if IsValid(menu) and menu.RefreshCatalog then menu:RefreshCatalog() end
end)

net.Receive("drp_prop_price_update_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local model = normalizeCatalogModel(net.ReadString())
	local price = net.ReadUInt(16)
	local overridden = net.ReadBool()
	local fingerprint = net.ReadString()
	if not model then return end
	serverCatalogFingerprint = fingerprint
	serverCatalogIncoming = nil
	serverCatalogLoading = false
	for _, record in ipairs(serverCatalogModels or {}) do
		if istable(record) and record.model == model then
			record.price = price
			record.overridden = overridden
			break
		end
	end
	for _, definition in ipairs(catalog or {}) do
		if definition.model == model then
			definition.price = price
			definition.priceOverridden = overridden
			break
		end
	end
	saveClientCatalog()
	if IsValid(menu) and menu.RefreshBlacklist then menu:RefreshBlacklist() end
end)

net.Receive("drp_civic_item_permissions_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length = net.ReadUInt(16)
	if length <= 0 then return end
	local compressed = net.ReadData(length)
	local decoded = compressed and util.JSONToTable(util.Decompress(compressed) or "") or nil
	if not istable(decoded) or not istable(decoded.items) then return end
	DRP.CivicItemPermissions = decoded.items
	DRP.DynamicWeaponCrates = istable(decoded.dynamicCrates) and decoded.dynamicCrates or {}
	hook.Run("DRPCivicItemPermissionsUpdated")
	if IsValid(menu) and menu.RefreshCatalog then menu:RefreshCatalog() end
end)

net.Receive("drp_prop_blacklist_snapshot_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local blacklist = {}
	for _ = 1, net.ReadUInt(16) do
		local model = normalizeCatalogModel(net.ReadString())
		if model then blacklist[model] = true end
	end
	DRP.PropBlacklist = blacklist
	if IsValid(menu) and menu.RefreshBlacklist then menu:RefreshBlacklist() end
end)

hook.Add("PlayerBindPress", "DRP.PropMenu.Bind", function(_, bind, pressed)
	bind = string.Trim(string.lower(bind or ""))
	-- Q is "+menu"; C is "+menu_context". A substring check captured both and
	-- prevented Media Player Redux from receiving its context-menu input.
	local command = string.match(bind, "^(%S+)") or ""
	if command ~= "+menu" and command ~= "menu" then return end
	if pressed then
		openMenu(true)
	elseif IsValid(menu) then
		if menu.HangOpen then
			menu.HangOpen = false
		else
			closeMenu()
		end
	end
	return true
end)

DRP.PropMenu.Open = function() openMenu(false) end
DRP.PropMenu.Close = closeMenu
