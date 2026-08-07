# DarkRP N64 arcade setup

The game server owns the catalogue and cabinet sessions. EmulatorJS and each
ROM are fetched over HTTPS by the player who starts a cabinet. ROM bytes are
never sent through Garry's Mod net messages.

## Server files

1. Start the gamemode once. It creates:
   `garrysmod/data/darkrp/arcade.json`
2. Upload legally distributable `.z64`, `.n64` or `.v64` files to an HTTPS
   object/static web host controlled by the server owner.
   Upload `deploy/arcade-web/index.html` as `/arcade/player/index.html` on the
   same host. A stable page origin makes EmulatorJS browser saves persist
   across cabinet sessions.
3. The ROM host must:
   - allow `GET` and `HEAD`;
   - return `Access-Control-Allow-Origin: *` (or an origin compatible with
     GMod's embedded browser);
   - return a stable `ETag` or `Last-Modified` header;
   - use a long `Cache-Control` lifetime for immutable ROM files.
4. Edit `data/darkrp/arcade.json`. Use `rom_base_url` plus `rom_file`, or put
   a complete HTTPS URL in a game's `rom_url`. Set `player_page_url` to the
   public URL of the uploaded player page.
5. Run `drp_arcade_reload` from the server console.
6. Run `drp_arcade_status` to confirm the game count and cabinet model.

`deploy/arcade.example.json` contains the complete schema.

The example pins EmulatorJS 4.2.0 instead of following the changing `stable`
alias. Version 4.2.3 uses JavaScript class-field syntax that GMod's macOS CEF
cannot parse. Test newer releases in GMod's embedded browser before changing
that URL.

The production player also maps the legacy Mupen64Plus core to
`/arcade/compat/`. Its official WebAssembly binary is unchanged; only the
Emscripten JavaScript wrapper is transpiled to ES5 because the upstream
wrapper uses ECMAScript 2022 class fields that macOS GMod CEF cannot parse.
The custom core report has a distinct build identifier so clients replace any
previously cached incompatible wrapper without disabling persistent saves.

## Cabinet content

Workshop item `1788979547` supplies the arcade cabinet model. The gamemode
automatically requests it for connecting clients. The server does not depend
on or invoke the addon's legacy Lua framework: when its model is unavailable
server-side, the secured cabinet uses an HL2 collision shell and clients draw
the Workshop cabinet over it.

## Gameplay

- The owner spawns **N64 Arcade Cabinet** from Job Entities and may persist it
  with the persistent-entity tool.
- A player presses E on an idle cabinet and selects a ROM.
- EmulatorJS runs only on that player's client. Browser storage/IndexedDB
  keeps ROM cache and saves clientside.
- Another nearby player presses E on the occupied cabinet to subscribe to its
  low-rate screen broadcast; pressing E again unsubscribes.
- Frame capture remains off when there are no spectators.

## Performance defaults

The default spectator stream is one 256×192 JPEG frame per second, capped at
24 KiB. A cabinet supports eight viewers and the server permits four
simultaneously broadcasting cabinets. A separate 256 KiB/s global relay
budget drops spectator frames before arcade traffic can crowd out gameplay
packets. Keep these limits for a 64-player server until measured profiling
justifies changing them.

The server never trusts emulator scores and does not award money or XP for
client-reported game results.
