-- Import Sandbox's player extensions, limits, duplicator support and native
-- Tool Gun behaviour as the actual gamemode base.
DeriveGamemode("sandbox")

GM.Name = "DarkRP"
GM.Author = "UltraRP"
GM.TeamBased = false
GM.Base = "sandbox"
-- darkrp.txt also declares Sandbox as the engine-level base. Keep this flag
-- explicit for addons which gate their Sandbox tools behind it.
GM.IsSandboxDerived = true

DRP = DRP or {}
DRP.Version = "0.25.0"
DRP.ProtocolVersion = 42

DRP.Bootstrap = DRP.Bootstrap or {}

DRP.DropPolicy = {
	enable = true,
	nonDroppableWeapons = {
		weapon_physgun = true,
		weapon_physcannon = true,
		weapon_drp_keys = true,
		weapon_drp_pocket = true,
		weapon_drp_taser = true,
		weapon_drp_cuffs = true,
		weapon_drp_arrest = true,
		weapon_drp_defibrillator = true,
		weapon_drp_kidnap_baton = true,
		weapon_drp_blindfold = true,
		weapon_drp_gag = true,
		ephone = true,
		weapon_drp_mayor_tablet = true,
		weapon_drp_police_tablet = true,
		gmod_tool = true,
		weapon_drp_persistence_tool = true
	},
	blockJobEntitiesByDefault = true,
	nonDroppableJobEntities = {},
	-- Optional override tables if an operation needs custom handling later.
	jobWeaponPrefixes = {
		weapon_drp_ = true
	}
}

-- Stable action names used by the server-owned incident permission service.
DRP.IncidentAction = {
	DAMAGE = "damage",
	TASE = "tase",
	CUFF = "cuff",
	ARREST = "arrest",
	SEARCH = "search",
	ENTER_PROPERTY = "enter_property",
	TAKE_MONEY = "take_money"
}

local manifest = DRP.Bootstrap and DRP.Bootstrap.Manifest
if not manifest then manifest = include("core/bootstrap/sh_manifest.lua") end
for index = 1, #manifest.Shared do include(manifest.Shared[index]) end

-- These sources intentionally load here, at the gamemode root. GMod can load
-- core/... from this file but not from nested Tool modules. Dependencies are
-- initialized before Stacker, then each stool executes with the canonical
-- Sandbox TOOL instance prepared by DRP.Toolgun.
include("core/toolgun/stacker/localify.lua")
include("core/toolgun/stacker/localization.lua")
include("core/toolgun/stacker/improvedstacker.lua")
if CLIENT then
	include("core/toolgun/stacker/vgui/stackercontrolpresets.lua")
	include("core/toolgun/stacker/vgui/stackerdnumslider.lua")
	include("core/toolgun/stacker/vgui/stackerpreseteditor.lua")
end

-- Capture stool source while the root gamemode file still owns a valid
-- gamemode-relative include context. Sandbox's gmod_tool may not exist yet;
-- DRP.Toolgun holds plain definitions until it can promote them later.
local bundledToolSources = {
	{ "drp_property_zone", "core/toolgun/stools/drp_property_zone.lua" },
	{ "drp_police_route", "core/toolgun/stools/drp_police_route.lua" },
	{ "precision", "core/toolgun/stools/precision.lua" },
	{ "stacker_improved", "core/toolgun/stools/stacker_improved.lua" }
}

-- Publish the exact sources from the same bootstrap which includes them. This
-- deliberately duplicates the manifest's AddCSLuaFile declaration so an older
-- init.lua or a partially uploaded manifest cannot leave joining clients with
-- shared.lua but without one of its bundled stools.
if SERVER then
	for index = 1, #bundledToolSources do
		AddCSLuaFile(bundledToolSources[index][2])
	end
end

local failedBundledTools = {}

local function loadBundledToolSources()
	for index = 1, #bundledToolSources do
		local mode, path = unpack(bundledToolSources[index])
		if not failedBundledTools[mode] and not DRP.Toolgun.HasBundledSource(mode) then
			-- include() resolves this path relative to the active gamemode. Do not
			-- preflight it through file.Exists(..., "LUA"): that realm is rooted at
			-- lua/ and can falsely report valid gamemode-relative files as absent.
			local ok, failure = xpcall(function()
				DRP.Toolgun.BeginBundledSource(mode)
				include(path)
				DRP.Toolgun.FinishBundledSource(mode)
			end, debug.traceback)

			if not ok then
				DRP.Toolgun.AbortBundledSource(mode)
				failedBundledTools[mode] = true
				ErrorNoHalt("[DRP TOOLGUN] Failed to register " .. mode .. ":\n" .. tostring(failure) .. "\n")
			end
		end
	end

	return DRP.Toolgun.RegisterBundledTools()
end

DRP.Toolgun.LoadBundledSources = loadBundledToolSources

function DRP.Toolgun.RetryBundledSources()
	-- Includes are intentionally never attempted here: delayed callbacks have no
	-- reliable gamemode-relative path context. This is only a promotion/sync
	-- recovery point for definitions captured during shared.lua execution.
	return DRP.Toolgun.RegisterBundledTools()
end

local function scheduleBundledToolSources()
	if DRP.Toolgun.RegisterBundledTools() then return end
	timer.Create("DRP.WaitForSandboxToolgun", 0.1, 50, function()
		if DRP.Toolgun.RegisterBundledTools() then
			timer.Remove("DRP.WaitForSandboxToolgun")
		end
	end)
end

hook.Add("Initialize", "DRPLoadBundledToolSources", function()
	-- Run after the current Initialize dispatch so other scripted-weapon setup
	-- in the same phase has completed on both server and client.
	timer.Simple(0, scheduleBundledToolSources)
end)

hook.Add("OnReloaded", "DRPReloadBundledToolSources", function()
	timer.Simple(0, scheduleBundledToolSources)
end)

-- This call must remain synchronous at the gamemode root. It captures every
-- stool now and only defers promotion into Sandbox's Tool table.
loadBundledToolSources()
