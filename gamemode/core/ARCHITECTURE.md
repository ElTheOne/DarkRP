# DarkRP Foundation module layout

## Bootstrap

`core/bootstrap/sh_manifest.lua` is the only authoritative realm and load-order
manifest. `init.lua`, `cl_init.lua`, and `shared.lua` consume it. A new client
submodule must be listed in `ClientSubmodules`; `cl_init.lua` loads that list
directly after the primary client modules. Server-only submodules are included
by their owning server entry point and must not be sent to clients.

## Compatibility facades

Existing top-level filenames remain stable because deployed servers, addons,
and diagnostics may include or inspect them directly. A facade owns the public
service and includes cohesive implementation modules beneath its domain:

- `core/properties/server/sv_properties.lua`
  - `core/properties/server/sv_geometry.lua`
  - `core/properties/server/sv_persistence.lua`
  - `core/properties/server/sv_raids.lua`
- `core/props/server/sv_props.lua`
  - `core/props/server/sv_catalog.lua`
  - `core/props/server/sv_persistence.lua`
- `core/admin/client/cl_admin.lua` (compatibility entry point)
  - `core/admin/client/cl_main.lua`
  - `core/admin/client/cl_announcements.lua`
  - `core/admin/client/cl_doors.lua`
  - `core/admin/client/cl_audit.lua`
  - `core/admin/client/cl_shortcuts.lua`

## Module rules

1. The top-level service remains the sole authority and public API.
2. Submodules extend that service; they do not register competing services.
3. Cross-module private dependencies are exported through a named component
   table such as `DRP.Properties.Geometry`, never through duplicate globals.
4. Client modules render state and send bounded intentions only. Server modules
   validate and perform mutations.
5. Preserve event-driven persistence and the existing service startup order.
6. Add a startup validation marker for every required server component.
7. Keep high-frequency hooks indexed and give unaffected players/entities an
   immediate return path.

## Next safe split candidates

Continue incrementally rather than moving the whole tree at once:

- Property membership/finance and property build-zone interaction.
- Prop persistence, spawn authority, and physgun/tool ownership.
- F4 pages from `cl_gameplay.lua`.
- Prop-browser catalogues and context actions from `cl_props.lua`.
- Admin server punishments, rank policy, MOTD, and server interactions.

Each extraction should keep its original facade, retain public method names,
pass Lua syntax validation, and pass `drp_validate_startup` on the server.
