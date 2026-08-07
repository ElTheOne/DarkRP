# DarkRP Foundation

A server-authoritative Garry's Mod roleplay gamemode built around persistent progression, incidents, properties, crafting, civic roles, marketplace trading, administration, and low-intervention roleplay.

## Layout

- `gamemode/` — shared, server, and client gamemode source.
- `entities/` — scripted entities and weapons.
- `content/` — gamemode-owned materials and models.
- `sql/` — database schema and migrations.
- `deploy/` — example configuration and optional web/Discord deployment source.

Runtime configuration belongs under Garry's Mod's `data/darkrp/` directory and is intentionally not committed. Start from the example files under `deploy/`.

## Validation

After deploying and restarting the server, run from the server console:

```text
drp_test_scenarios
drp_profile_reset
drp_profile 1
```

After exercising representative gameplay, use `drp_profile_report` to inspect server-side timings.
