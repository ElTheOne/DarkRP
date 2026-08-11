-- Sandbox only scans its own gmod_tool/stools directory when it creates the
-- Tool Gun. These stools belong to this gamemode, so register their actual
-- source files explicitly into Sandbox's canonical gmod_tool table.
DRP.Toolgun = DRP.Toolgun or {}
DRP.Toolgun.Build = "20260810.4-synchronous-source-capture"

local bundledModes = {
	drp_property_zone = {
		path = "core/toolgun/stools/drp_property_zone.lua"
	},
	drp_police_route = {
		path = "core/toolgun/stools/drp_police_route.lua"
	},
	precision = {
		path = "core/toolgun/stools/precision.lua",
		version = "workshop-104482086-native2"
	},
	stacker_improved = {
		path = "core/toolgun/stools/stacker_improved.lua",
		version = "workshop-264467687-native2"
	}
}

local pendingSource
local deferredSources = {}

local function storedDefinition()
	return weapons.GetStored("gmod_tool")
end

local function storedTools()
	local definition = storedDefinition()
	return istable(definition) and istable(definition.Tool) and definition.Tool or nil
end

local function modeReady(tool, details)
	if not istable(tool) or not isfunction(tool.LeftClick) then return false end
	if details.version and tool.DRPBundledVersion ~= details.version then return false end
	return SERVER or isfunction(tool.BuildCPanel)
end

local function toolPrototype(tools)
	for _, candidate in pairs(tools or {}) do
		local meta = istable(candidate) and getmetatable(candidate) or nil
		local prototype = meta and meta.__index or nil
		if istable(prototype) and isfunction(prototype.Create) then return prototype end
	end
	return nil
end

-- Source files must be included directly by gamemode/shared.lua. GMod resolves
-- those core/... paths correctly there, but not from this nested module and it
-- rejects ../ traversal. Begin/Finish only provide the canonical TOOL context.
function DRP.Toolgun.BeginBundledSource(mode)
	assert(pendingSource == nil, "another bundled Tool source is already loading")
	mode = string.lower(tostring(mode or ""))
	local details = assert(bundledModes[mode], "unknown bundled Tool mode: " .. mode)
	local definition = storedDefinition()
	local tools = storedTools()
	local prototype = toolPrototype(tools)
	-- A clean client evaluates gamemode/shared.lua before scripted weapons have
	-- registered. Capture the stool into a plain definition table in that phase;
	-- RegisterBundledTools promotes it into Sandbox's real Tool prototype later.
	local deferred = not definition or not tools or not prototype
	local instance = deferred and {} or prototype:Create()
	instance.Mode = mode
	instance.SWEP = definition
	pendingSource = {
		mode = mode,
		details = details,
		definition = definition,
		tools = tools,
		instance = instance,
		deferred = deferred,
		previous = TOOL
	}
	TOOL = instance
	return instance
end

-- A failed source include must never leave the global TOOL context poisoned.
-- The root loader uses this when a third-party stool raises during hot reload.
function DRP.Toolgun.AbortBundledSource(mode)
	local pending = pendingSource
	if not pending then return false end
	if mode and pending.mode ~= string.lower(tostring(mode)) then return false end
	pendingSource = nil
	TOOL = pending.previous
	return true
end

function DRP.Toolgun.CanLoadBundledSources()
	return storedDefinition() ~= nil
		and storedTools() ~= nil
		and toolPrototype(storedTools()) ~= nil
end

function DRP.Toolgun.HasBundledSource(mode)
	mode = string.lower(tostring(mode or ""))
	return deferredSources[mode] ~= nil or DRP.Toolgun.IsModeReady(mode)
end

function DRP.Toolgun.FinishBundledSource(mode)
	local pending = assert(pendingSource, "no bundled Tool source is loading")
	assert(pending.mode == string.lower(tostring(mode or "")), "bundled Tool source mode mismatch")
	pendingSource = nil
	TOOL = pending.previous
	local instance, details = pending.instance, pending.details
	assert(not details.version or instance.DRPBundledVersion == details.version,
		"wrong bundled source version for " .. pending.mode)
	assert(isfunction(instance.LeftClick), "bundled source has no LeftClick for " .. pending.mode)
	if pending.deferred then
		deferredSources[pending.mode] = {
			definition = instance,
			details = details
		}
		return true
	end
	instance:CreateConVars()
	assert(hook.Run("PreRegisterTOOL", instance, pending.mode) ~= false,
		"registration rejected by PreRegisterTOOL: " .. pending.mode)
	pending.tools[pending.mode] = instance
	return true
end

local function promoteDeferredSources()
	local definition = storedDefinition()
	local tools = storedTools()
	local prototype = toolPrototype(tools)
	if not definition or not tools or not prototype then return false end

	for mode, queued in pairs(deferredSources) do
		if modeReady(tools[mode], queued.details) then
			deferredSources[mode] = nil
		else
			local instance = prototype:Create()
			for key, value in pairs(queued.definition) do instance[key] = value end
			instance.Mode = mode
			instance.SWEP = definition
			instance:CreateConVars()
			if hook.Run("PreRegisterTOOL", instance, mode) ~= false then
				tools[mode] = instance
				deferredSources[mode] = nil
			end
		end
	end

	return next(deferredSources) == nil
end

function DRP.Toolgun.IsModeReady(mode)
	mode = string.lower(tostring(mode or ""))
	local details = bundledModes[mode]
	local tools = storedTools()
	return details ~= nil and tools ~= nil and modeReady(tools[mode], details)
end

function DRP.Toolgun.IsReady()
	for mode in pairs(bundledModes) do
		if not DRP.Toolgun.IsModeReady(mode) then return false end
	end
	return true
end

function DRP.Toolgun.SyncWeapon(weapon)
	if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" then return false end
	local tools = storedTools()
	if not tools then return false end

	weapon.Tool = weapon.Tool or {}
	weapon.Tool.stacker = nil
	for mode, details in pairs(bundledModes) do
		local canonical = tools[mode]
		if modeReady(canonical, details) and not modeReady(weapon.Tool[mode], details) then
			local instance = table.Copy(canonical)
			setmetatable(instance, getmetatable(canonical))
			instance.SWEP = weapon
			instance.Weapon = weapon
			instance.Owner = weapon:GetOwner()
			if isfunction(instance.Init) then instance:Init() end
			weapon.Tool[mode] = instance
		end
	end
	return true
end

function DRP.Toolgun.SyncLiveWeapons()
	for _, weapon in ipairs(ents.FindByClass("gmod_tool")) do
		DRP.Toolgun.SyncWeapon(weapon)
	end
end

function DRP.Toolgun.RegisterBundledTools()
	promoteDeferredSources()
	DRP.Toolgun.SyncLiveWeapons()
	return DRP.Toolgun.IsReady()
end

local function registerAndSync()
	if not DRP or not DRP.Toolgun then return end
	DRP.Toolgun.RegisterBundledTools()
end

hook.Add("Initialize", "DRPRegisterBundledToolgunModes", registerAndSync)
hook.Add("OnReloaded", "DRPRegisterBundledToolgunModes", function()
	timer.Simple(0, registerAndSync)
end)

hook.Add("OnEntityCreated", "DRPSyncBundledToolgunInstance", function(entity)
	if not IsValid(entity) or entity:GetClass() ~= "gmod_tool" then return end
	timer.Simple(0, function()
		if IsValid(entity) and DRP and DRP.Toolgun then
			DRP.Toolgun.RegisterBundledTools()
			DRP.Toolgun.SyncWeapon(entity)
		end
	end)
end)

if SERVER then
	hook.Add("WeaponEquip", "DRPSyncBundledToolgunOnEquip", function(weapon)
		if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" then return end
		timer.Simple(0, function()
			if IsValid(weapon) and DRP and DRP.Toolgun then
				DRP.Toolgun.RegisterBundledTools()
				DRP.Toolgun.SyncWeapon(weapon)
			end
		end)
	end)
else
	concommand.Add("drp_toolgun_client_status", function()
		local tools = storedTools()
		local active = IsValid(LocalPlayer()) and LocalPlayer():GetActiveWeapon() or nil
		local live = IsValid(active) and active:GetClass() == "gmod_tool" and active.Tool or nil
		print(string.format(
			"[DRP TOOLGUN CLIENT] build=%s registered=%s tools=%d route=%s/%s precision=%s/%s stacker=%s/%s active=%s mode=%s",
			tostring(DRP.Toolgun.Build),
			tostring(istable(tools)),
			istable(tools) and table.Count(tools) or 0,
			tostring(istable(tools) and modeReady(tools.drp_police_route, bundledModes.drp_police_route)),
			tostring(istable(live) and modeReady(live.drp_police_route, bundledModes.drp_police_route)),
			tostring(istable(tools) and modeReady(tools.precision, bundledModes.precision)),
			tostring(istable(live) and modeReady(live.precision, bundledModes.precision)),
			tostring(istable(tools) and modeReady(tools.stacker_improved, bundledModes.stacker_improved)),
			tostring(istable(live) and modeReady(live.stacker_improved, bundledModes.stacker_improved)),
			IsValid(active) and active:GetClass() or "none",
			GetConVarString("gmod_toolmode")
		))
	end)
end

-- gamemode/shared.lua now loads and registers each source from the gamemode
-- root after this service has been included.
