# DRP Trust provider setup

The gamemode creates `data/darkrp/trust.json` on first startup. Secrets belong
in that DATA file and must never be shipped inside the Workshop gamemode.

## Steam

Set `steam_web_api_key` to a server-side Steam Web API key. The server queries
owned games and Garry's Mod playtime only when the profile exposes those
details. Private or unavailable data remains unknown and is not treated as a
negative signal. VAC data is fetched independently.

## VPN/proxy provider

Set `vpn.lookup_url` to an HTTPS endpoint. `{ip}` is URL encoded and replaced
server-side. Configure any provider headers under `vpn.headers`. The response
must be JSON. `boolean_paths` lists fields which indicate VPN/proxy status:

```json
{ "vpn": false, "proxy": false }
```

Nested paths such as `security.vpn` are supported. Player IP addresses are
never persisted; only a truncated SHA-256 fingerprint is stored to decide when
the network needs checking again.

## Discord identity provider

Discord linking requires a small HTTPS OAuth2 backend because a Garry's Mod
server cannot receive Discord's OAuth callback directly.

`discord.link_url` receives URL-encoded `steamid`, one-time `token`, and
server-generated `signature` values. It must validate the signature, start
Discord OAuth2 with the `identify` scope, and use the token as server-owned
state. `discord.verify_url` receives the Steam ID and token and returns:

```json
{
  "linked": true,
  "discord_id": "123456789012345678",
  "discord_name": "example"
}
```

The included `discord-worker` Wrangler project implements this contract as a
Cloudflare Worker. Its configuration automatically provisions a KV namespace
bound as `DRP_LINKS`. Deploy it with `npm install` followed by
`npx wrangler deploy`, then configure these secrets:

- `DISCORD_CLIENT_ID`
- `DISCORD_CLIENT_SECRET`
- `DISCORD_REDIRECT_URI` (`https://YOUR-WORKER/discord/callback`)
- `SERVICE_BEARER` (a long random value also used in `trust.json`)
- `LINK_SECRET` (the same long random value as `discord.link_secret`)

Register the identical redirect URI in Discord's Developer Portal. Configure:

```json
{
  "discord": {
    "link_url": "https://YOUR-WORKER/discord/start?steamid={steamid}&token={token}&signature={signature}",
    "verify_url": "https://YOUR-WORKER/discord/status?steamid={steamid}&token={token}",
    "unlink_url": "https://YOUR-WORKER/discord/unlink?steamid={steamid}&discord_id={discord_id}",
    "headers": { "Authorization": "Bearer YOUR_SERVICE_BEARER" }
  }
}
```

The worker validates OAuth state, enforces one Discord account per Steam
account, expires one-time tokens, and discards OAuth access tokens after
reading the identity. Players use `/discordlink`, complete the browser flow,
then use `/discordverify`.

## Reloading and verification

After changing `data/darkrp/trust.json`, run these commands from the server
console:

```text
drp_trust_reload
drp_trust_refresh STEAMID64
```

The first command reloads provider settings. The second clears the provider
cooldowns for one online player and performs a fresh evaluation. Players can
use `/trust` to see their own score and signal breakdown. Staff can use
`/trust player-name` to inspect an online player.

Trust scores are indicators only. They do not ban, kick, restrict, or prove
that a player is cheating.
