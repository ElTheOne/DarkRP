DRP = DRP or {}
DRP.Bootstrap = DRP.Bootstrap or {}

-- One authoritative realm manifest. Keep ordering intentional: services rely
-- on earlier authorities being registered before their files are included.
local Manifest = {
	Shared = {
		"core/foundation/shared/sh_services.lua", "core/foundation/shared/sh_state.lua", "core/calendar/shared/sh_calendar.lua",
		"core/jobs/shared/sh_jobs.lua", "core/jobs/shared/sh_identity.lua", "core/economy/shared/sh_supporter.lua", "core/admin/shared/sh_admin.lua",
		"core/props/shared/sh_props.lua", "core/incidents/shared/sh_cocaine.lua", "core/inventory/shared/sh_crafting.lua",
		"core/jobs/shared/sh_jobentities.lua", "core/inventory/shared/sh_deathloot.lua", "core/media/shared/sh_arcade.lua",
		"core/media/shared/sh_mediaplayer.lua", "core/media/shared/sh_mp3player.lua", "core/toolgun/shared/sh_toolgun.lua"
	},
	ClientShared = { "core/government/shared/sh_mayor_tablet.lua", "core/government/shared/sh_police_tablet.lua", "core/world/shared/sh_worldentities.lua" },
	ServerPreload = { "core/government/shared/sh_mayor_tablet.lua", "core/government/shared/sh_police_tablet.lua" },
	Server = {
		"core/platform/server/sv_workshop.lua", "core/platform/server/sv_arc9.lua", "core/foundation/server/sv_profile.lua",
		"core/foundation/server/sv_players.lua", "core/foundation/server/sv_deadlines.lua", "core/persistence/server/sv_storage.lua",
		"core/foundation/server/sv_network.lua", "core/calendar/server/sv_calendar.lua", "core/media/server/sv_arcade.lua",
		"core/foundation/server/sv_roster.lua", "core/inventory/server/sv_inventory.lua", "core/inventory/server/sv_deathloot.lua",
		"core/inventory/server/sv_salvage.lua", "core/inventory/server/sv_crafting.lua", "core/jobs/server/sv_identity.lua", "core/jobs/server/sv_jobentities.lua",
		"core/media/server/sv_mediaplayer.lua", "core/world/shared/sh_worldentities.lua", "core/world/server/sv_worldentities.lua",
		"core/government/server/sv_government.lua", "core/government/server/sv_agendas.lua", "core/communication/server/sv_chat.lua",
		"core/communication/server/sv_voice.lua", "core/incidents/server/sv_hitman_evidence.lua", "core/communication/server/sv_phone.lua",
		"core/progression/server/sv_experience.lua", "core/progression/server/sv_experience_activity.lua", "core/incidents/server/sv_incidents.lua",
		"core/incidents/server/sv_incident_outcomes.lua", "core/incidents/server/sv_kidnapping.lua", "core/government/server/sv_treasury.lua",
		"core/government/server/sv_armory.lua", "core/jobs/server/sv_civic.lua", "core/incidents/server/sv_medical.lua",
		"core/jobs/server/sv_civic_permissions.lua", "core/jobs/server/sv_roles.lua", "core/incidents/server/sv_pvp.lua",
		"core/incidents/server/sv_pvpconsent.lua", "core/incidents/server/sv_drugs.lua", "core/incidents/server/sv_cocaine.lua",
		"core/government/server/sv_legal.lua", "core/government/server/sv_evidence_scanner.lua", "core/government/server/sv_police_records.lua", "core/incidents/server/sv_hits.lua",
		"core/government/server/sv_police_npcs.lua", "core/progression/server/sv_social_objectives.lua",
		"core/props/server/sv_props.lua", "core/admin/server/sv_admin.lua", "core/admin/server/sv_entities.lua", "core/admin/server/sv_database.lua", "core/incidents/server/sv_massie.lua",
		"core/admin/server/sv_adminmode.lua", "core/admin/server/sv_audit.lua", "core/progression/server/sv_hints.lua",
		"core/progression/server/sv_objectives.lua", "core/trust/server/sv_trust.lua", "core/trust/server/sv_loading.lua",
		"core/economy/server/sv_economy.lua", "core/economy/server/sv_economy_director.lua", "core/economy/server/sv_bonds.lua", "core/economy/server/sv_contracts.lua",
		"core/platform/server/sv_zero_addons.lua", "core/incidents/server/sv_mugging.lua", "core/jobs/server/sv_jobs.lua",
		"core/properties/server/sv_doors.lua", "core/properties/server/sv_properties.lua", "core/commands/server/sv_commands.lua",
		"core/properties/server/sv_beds.lua", "core/progression/server/sv_mercenaries.lua",
		"core/commands/server/sv_movement.lua", "core/foundation/server/sv_loadtest.lua", "core/foundation/server/sv_tests.lua",
		"core/foundation/server/sv_startup.lua", "core/foundation/server/sv_lifecycle.lua"
	},
	Client = {
		"core/ui/client/cl_ui.lua", "core/foundation/client/cl_performance.lua", "core/foundation/client/cl_content_delivery.lua", "core/calendar/client/cl_calendar.lua",
		"core/ui/client/cl_context.lua", "core/progression/client/cl_objectives.lua", "core/progression/client/cl_mercenaries.lua", "core/jobs/client/cl_identity.lua", "core/incidents/client/cl_medical.lua",
		"core/foundation/client/cl_roster.lua", "core/ui/client/cl_visuals.lua", "core/government/client/cl_government.lua", "core/government/client/cl_legal_tablet.lua",
		"core/government/client/cl_mayor_tablet.lua", "core/government/client/cl_police_tablet.lua", "core/jobs/client/cl_jobentities.lua", "core/government/client/cl_armory.lua",
		"core/economy/client/cl_contracts.lua", "core/economy/client/cl_bonds.lua", "core/media/client/cl_arcade.lua", "core/media/client/cl_mp3player.lua", "core/media/client/cl_mediaplayer.lua",
		"core/inventory/client/cl_inventory.lua", "core/inventory/client/cl_deathloot.lua", "core/inventory/client/cl_salvage.lua",
		"core/inventory/client/cl_crafting.lua", "core/incidents/client/cl_drugs.lua", "core/incidents/client/cl_cocaine.lua",
		"core/incidents/client/cl_pvpconsent.lua", "core/incidents/client/cl_incidents.lua", "core/properties/client/cl_properties.lua",
		"core/properties/client/cl_beds.lua",
		"core/communication/client/cl_chat.lua", "core/trust/client/cl_trust.lua", "core/incidents/client/cl_mugging.lua",
		"core/incidents/client/cl_massie.lua", "core/incidents/client/cl_kidnapping.lua", "core/props/client/cl_props.lua",
		"core/foundation/client/cl_network.lua", "core/ui/client/cl_weaponselect.lua", "core/jobs/client/cl_roles.lua",
		"core/ui/client/cl_hud.lua", "core/jobs/client/cl_civic.lua", "core/ui/client/cl_scoreboard.lua",
		"core/ui/client/cl_gameplay.lua", "core/admin/client/cl_admin.lua", "core/admin/client/cl_adminmode.lua"
	},
	ClientSubmodules = {
		"core/admin/client/cl_database.lua", "core/admin/client/cl_entities.lua", "core/admin/client/cl_main.lua", "core/admin/client/cl_announcements.lua",
		"core/admin/client/cl_doors.lua", "core/admin/client/cl_audit.lua",
		"core/admin/client/cl_shortcuts.lua"
	},
	ClientResources = {
		-- Sent for compatibility with the existing hint loader; it is not a
		-- standalone bootstrap module yet.
		"core/ui/client/cl_hints.lua",
		"core/toolgun/stools/drp_property_zone.lua", "core/toolgun/stools/drp_police_route.lua", "core/toolgun/stools/precision.lua",
		"core/toolgun/stools/stacker_improved.lua", "core/toolgun/stacker/improvedstacker.lua",
		"core/toolgun/stacker/localify.lua",
		"core/toolgun/stacker/vgui/stackercontrolpresets.lua",
		"core/toolgun/stacker/vgui/stackerdnumslider.lua",
		"core/toolgun/stacker/vgui/stackerpreseteditor.lua",
		"core/toolgun/stacker/localization.lua"
	}
}

DRP.Bootstrap.Manifest = Manifest
return Manifest
