# DarkRP Discord link Worker

This project must be deployed with Wrangler. The Cloudflare dashboard's
generic project uploader does not support this project format.

## First deployment

From this directory:

```bash
npm install
npx wrangler login
npm run deploy
```

Wrangler will create the `DRP_LINKS` KV namespace automatically and print the
public `https://darkrp-discord-link.<subdomain>.workers.dev` URL.

Register this exact Discord OAuth2 redirect:

```text
https://darkrp-discord-link.<subdomain>.workers.dev/discord/callback
```

## Required secrets

Add each value through Wrangler. Paste the value only after Wrangler prompts:

```bash
npx wrangler secret put DISCORD_CLIENT_ID
npx wrangler secret put DISCORD_CLIENT_SECRET
npx wrangler secret put DISCORD_REDIRECT_URI
npx wrangler secret put SERVICE_BEARER
npx wrangler secret put LINK_SECRET
npx wrangler secret put DISCORD_BOT_TOKEN
```

Generate the final two values with:

```bash
openssl rand -hex 32
openssl rand -hex 32
```

`SERVICE_BEARER` and `LINK_SECRET` must also be placed in the game server's
`data/darkrp/trust.json`. Run `npm run deploy` once more after all secrets are
configured.

Discord membership is required by default. The game gives an unverified player
600 seconds to obtain the bot-confirmed DarkRP role before disconnecting them.
Change `discord.verification_timeout_seconds` in `data/darkrp/trust.json` to a
value from 60 to 3600, or set `discord.role_required` to `false` to disable the
join deadline. Every human player, including staff, is checked against live
guild membership and the DarkRP role through the protected
`/discord/member-status` endpoint. A role-service outage extends the deadline
instead of kicking the player.

You may set `DISCORD_GUILD_ID` and `DISCORD_DARKRP_ROLE_ID` as Worker secrets to
avoid rediscovering the guild and the role named `DarkRP` during checks.

## Bot verification and presence

Create the bot under the same Discord application, copy its token into
`DISCORD_BOT_TOKEN`, and invite it with both the `bot` and
`applications.commands` scopes:

```text
https://discord.com/oauth2/authorize?client_id=1426717557418885271&scope=bot%20applications.commands&permissions=268504065
```

Create a role named **DarkRP**, place the bot's role above it, and enable both
**Server Members Intent** and **Message Content Intent** under Discord Developer
Portal → Bot → Privileged Gateway Intents. The bot needs View Channels, Send
Messages, Read Message History, Create Invite and Manage Roles.

After deploying, register/update the `/link code:` command once:

```bash
curl -X POST \
  -H "Authorization: Bearer YOUR_SERVICE_BEARER" \
  https://darkrp-discord-link.tcv2y2cdj7.workers.dev/discord/bot/register-command
```

The in-game flow is `/discordlink` → accept the bot-created channel invite →
return to the game and use `/discordverify` → paste the automatically copied
`/link code:XXXXXXXX` command in the opened DarkRP channel. The bot grants the
DarkRP role and the game performs a bounded verification poll so trust updates
without requiring a second command.

The Garry's Mod server sends one non-database HTTP heartbeat every 45 seconds.
The Durable Object connects the bot to Discord while those heartbeats arrive,
updates its player/map presence, and disconnects it about 150 seconds after the
game server stops. Browser OAuth remains available as a fallback.

To relay in-game global chat, set these values under `discord` in
`data/darkrp/trust.json`:

```json
"bot_chat_url": "https://darkrp-discord-link.tcv2y2cdj7.workers.dev/discord/bot/chat",
"bot_inbox_url": "https://darkrp-discord-link.tcv2y2cdj7.workers.dev/discord/bot/inbox?channel_id={channel_id}",
"global_chat_channel_id": "YOUR_DISCORD_TEXT_CHANNEL_ID"
```

Only the global category is relayed. The Worker
serializes outgoing messages through the live bot object, suppresses Discord
mentions, ignores bot and webhook messages on the return path, and keeps a
bounded inbox that the game server polls once every two seconds.

## Live join card

Publish or update one persistent server card in a Discord text channel:

```bash
curl -X POST \
  -H "Authorization: Bearer YOUR_SERVICE_BEARER" \
  -H "Content-Type: application/json" \
  --data '{"channel_name":"join darkrp","server_address":"103.212.224.5:27025"}' \
  https://darkrp-discord-link.tcv2y2cdj7.workers.dev/discord/bot/publish-join
```

The channel name is normalized, so `join darkrp` matches `join-darkrp`. The
Worker stores the resulting Discord message ID and edits that same message on
future calls. Existing game-server heartbeats update its online state, player
count, map, and server name. The link button opens the Worker's branded `/join`
page, which hands the browser to `steam://connect/<address>`.
