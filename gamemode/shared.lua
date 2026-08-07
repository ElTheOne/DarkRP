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

DRP.Toolgun.BeginBundledSource("drp_property_zone")
include("core/toolgun/stools/drp_property_zone.lua")
DRP.Toolgun.FinishBundledSource("drp_property_zone")

DRP.Toolgun.BeginBundledSource("precision")
include("core/toolgun/stools/precision.lua")
DRP.Toolgun.FinishBundledSource("precision")

DRP.Toolgun.BeginBundledSource("stacker_improved")
include("core/toolgun/stools/stacker_improved.lua")
DRP.Toolgun.FinishBundledSource("stacker_improved")

DRP.Toolgun.RegisterBundledTools()
