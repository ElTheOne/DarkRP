# DarkRP Core Layout

`bootstrap/sh_manifest.lua` is the only authoritative load list. Its ordering is
intentional and must be preserved when modules move between domains.

Each gameplay domain owns its shared, server and client code:

| Folder | Authority |
| --- | --- |
| `foundation/` | services, player lifecycle, networking, roster, diagnostics and tests |
| `persistence/` | MySQL, local database and durable state access |
| `platform/` | Workshop delivery, ARC9 and third-party compatibility |
| `calendar/` | roleplay clock and day/night synchronization |
| `ui/` | theme primitives, HUD, F4, scoreboard and client input surfaces |
| `jobs/` | jobs, derived roles, civic standing and entity capabilities |
| `economy/` | balances, dynamic economy, supporter benefits and contracts |
| `inventory/` | Hands, death loot, salvage and crafting |
| `government/` | Mayor, police, law, treasury and armory |
| `incidents/` | incidents, PvP, medical, drugs, kidnapping, mugging and hits |
| `communication/` | chat, voice and phone server routing |
| `progression/` | XP, activity rewards, objectives and contextual hints |
| `trust/` | trust scoring and loading-screen publication |
| `media/` | arcade, media player and MP3 player |
| `properties/` | doors, property geometry, persistence and raids |
| `props/` | prop catalogue, spawning, limits and prop persistence |
| `world/` | persistent world entities |
| `commands/` | chat/console commands and movement dispatcher |
| `admin/` | staff authority, audit and management UI |
| `toolgun/` | Tool Gun bootstrap, bundled stools and Stacker support files |

Realm naming remains conventional:

- `sh_*.lua`: loaded on server and client.
- `sv_*.lua`: server-only authority.
- `cl_*.lua`: client-only presentation and input.

Do not add new scripts directly under `core/`. Put them in the owning domain,
register them in the correct manifest realm, and communicate with other domains
through `DRP` service APIs or authoritative hooks.

`incidents/client/cl_pvp.lua` and `ui/client/cl_toolcontext.lua` are retained
legacy sources. They are intentionally not in the manifest because their active
behavior is owned by `cl_incidents.lua`/`cl_pvpconsent.lua` and `cl_context.lua`.
