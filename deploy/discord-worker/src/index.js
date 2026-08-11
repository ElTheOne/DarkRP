import {
  canIdentify,
  gatewayClosePolicy,
  reconnectDelay,
  sessionStartState
} from "./gateway-policy.js";

const DISCORD_API = "https://discord.com/api/v10";
const BOT_OBJECT_NAME = "darkrp-primary";
const SERVER_TTL_MS = 150000;
const GUILD_MEMBERS_INTENT = 1 << 1;
const GUILD_MESSAGES_INTENT = 1 << 9;
const MESSAGE_CONTENT_INTENT = 1 << 15;
const ARCADE_PREFIX = "/arcade/";
const GATEWAY_CONTROL_KEY = "gatewayControlV2";
const GATEWAY_SESSION_KEY = "gatewaySessionV2";

const randomUnit = () => {
  const value = new Uint32Array(1);
  crypto.getRandomValues(value);
  return value[0] / 0xffffffff;
};

const tokenFingerprint = async token => {
  if (!token) return "";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest).slice(0, 12), byte => byte.toString(16).padStart(2, "0")).join("");
};

const gatewayControlDefaults = fingerprint => ({
  tokenFingerprint: fingerprint,
  attempts: 0,
  nextAttemptAt: 0,
  fatalCode: 0,
  fatalReason: "",
  identifyRemaining: -1,
  identifyResetAt: 0,
  lastCloseCode: 0,
  lastCloseReason: "",
  lastIdentifyAt: 0,
  lastReadyAt: 0
});

const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
});

const page = (title, message, ok) => new Response(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>${title}</title><style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#080d19;color:#f7fbff;
font:16px system-ui}.card{width:min(560px,calc(100% - 40px));padding:34px;border-radius:18px;
background:#0f182b;border:1px solid #30486c;box-shadow:0 24px 80px #0009}.bar{height:5px;
border-radius:5px;background:${ok ? "#68eb96" : "#f46980"};margin-bottom:24px}h1{margin:0 0 12px;
font-size:28px}p{color:#9eaec9;line-height:1.6;margin:0}.brand{color:#4acdff;font-weight:800;
letter-spacing:.12em;font-size:12px;margin-bottom:10px}</style></head><body><main class="card">
<div class="bar"></div><div class="brand">DARKRP FOUNDATION</div><h1>${title}</h1><p>${message}</p>
</main></body></html>`, { status: ok ? 200 : 400, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });

const validSteamID = value => /^7656119\d{10}$/.test(value || "");
const validToken = value => /^[a-f0-9]{40}$/.test(value || "");
const validSignature = value => /^[a-f0-9]{64}$/.test(value || "");
const validLinkCode = value => /^[A-F0-9]{8}$/.test(value || "");
const validDiscordID = value => /^\d{16,22}$/.test(value || "");
const validServerAddress = value => /^(?:[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?|\[[0-9a-f:]+\]):(?:[1-9]\d{0,4})$/i.test(value || "")
  && Number.parseInt(String(value).split(":").at(-1), 10) <= 65535;
const safeText = (value, maximum) => String(value || "").replace(/[\u0000-\u001f\u007f]/g, "").slice(0, maximum);
const escapeHTML = value => String(value ?? "").replace(/[&<>"']/g, character => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;"
})[character]);
const escapeDiscord = value => String(value || "").replace(/([\\`*_{}[\]()#+\-.!|>~])/g, "\\$1");
const normalizeChannelName = value => safeText(value, 100).toLowerCase().replace(/[^a-z0-9]/g, "");
const boundedInteger = (value, minimum, maximum, fallback) => {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? Math.min(maximum, Math.max(minimum, parsed)) : fallback;
};

function arcadeObjectKey(url) {
  if (!url.pathname.startsWith(ARCADE_PREFIX)) return null;
  let key;
  try {
    key = decodeURIComponent(url.pathname.slice(ARCADE_PREFIX.length));
  } catch {
    return null;
  }
  if (!key || key.length > 256 || key.includes("..") || key.includes("//")
    || !/^[a-z0-9][a-z0-9._/-]*$/i.test(key)) return null;
  return key;
}

function arcadeContentType(key) {
  const extension = key.slice(key.lastIndexOf(".") + 1).toLowerCase();
  if (extension === "html") return "text/html; charset=utf-8";
  if (extension === "json") return "application/json; charset=utf-8";
  if (extension === "js") return "text/javascript; charset=utf-8";
  if (extension === "css") return "text/css; charset=utf-8";
  if (extension === "wasm") return "application/wasm";
  return "application/octet-stream";
}

function arcadeHeaders(object, key) {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  if (!headers.has("content-type")) headers.set("content-type", arcadeContentType(key));
  headers.set("etag", object.httpEtag);
  headers.set("accept-ranges", "bytes");
  headers.set("access-control-allow-origin", "*");
  headers.set("access-control-expose-headers", "content-length, content-range, etag, last-modified");
  headers.set("cross-origin-resource-policy", "cross-origin");
  headers.set("x-content-type-options", "nosniff");
  if (key.endsWith(".html")) {
    headers.set("cache-control", "no-store");
  } else if (!headers.has("cache-control")) {
    headers.set("cache-control", "public, max-age=31536000, immutable");
  }
  return headers;
}

function arcadeByteRange(value, size) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(value || "");
  if (!match || (!match[1] && !match[2]) || size < 1) return null;
  if (!match[1]) {
    const suffix = Number.parseInt(match[2], 10);
    if (!Number.isSafeInteger(suffix) || suffix < 1) return null;
    const length = Math.min(size, suffix);
    return { offset: size - length, length };
  }
  const offset = Number.parseInt(match[1], 10);
  const requestedEnd = match[2] ? Number.parseInt(match[2], 10) : size - 1;
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(requestedEnd)
    || offset < 0 || offset >= size || requestedEnd < offset) return null;
  const end = Math.min(size - 1, requestedEnd);
  return { offset, length: end - offset + 1 };
}

async function serveArcade(request, url, env) {
  if (!env.DRP_ARCADE) return json({ error: "arcade_storage_unavailable" }, 503);
  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, HEAD, OPTIONS",
        "access-control-allow-headers": "range, if-none-match, if-modified-since",
        "access-control-max-age": "86400"
      }
    });
  }
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method Not Allowed", { status: 405, headers: { allow: "GET, HEAD, OPTIONS" } });
  }

  const key = arcadeObjectKey(url);
  if (!key) return new Response("Not Found", { status: 404 });

  if (request.method === "HEAD") {
    const object = await env.DRP_ARCADE.head(key);
    if (!object) return new Response("Not Found", { status: 404 });
    const headers = arcadeHeaders(object, key);
    headers.set("content-length", String(object.size));
    return new Response(null, { status: 200, headers });
  }

  const rangeValue = request.headers.get("range");
  let object;
  if (rangeValue) {
    const metadata = await env.DRP_ARCADE.head(key);
    if (!metadata) return new Response("Not Found", { status: 404 });
    const range = arcadeByteRange(rangeValue, metadata.size);
    if (!range) {
      return new Response("Range Not Satisfiable", {
        status: 416,
        headers: {
          "content-range": `bytes */${metadata.size}`,
          "access-control-allow-origin": "*",
          "accept-ranges": "bytes"
        }
      });
    }
    object = await env.DRP_ARCADE.get(key, { range });
  } else {
    object = await env.DRP_ARCADE.get(key);
  }
  if (!object) return new Response("Not Found", { status: 404 });
  const headers = arcadeHeaders(object, key);
  let status = 200;
  if (object.range) {
    const offset = object.range.offset || 0;
    const length = object.range.length || object.size;
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("content-length", String(length));
    status = 206;
  } else {
    headers.set("content-length", String(object.size));
  }
  return new Response(object.body, { status, headers });
}

function normalizeLoadingProfile(value, steamid) {
  const profile = value && typeof value === "object" ? value : {};
  return {
    found: true,
    steamid,
    rp_name: safeText(profile.rp_name, 48) || "Returning citizen",
    job: safeText(profile.job, 48) || "Citizen",
    wallet: boundedInteger(profile.wallet, 0, 4294967295, 0),
    level: boundedInteger(profile.level, 1, 100, 1),
    civic: boundedInteger(profile.civic, -1000, 1000, 0),
    updated_at: boundedInteger(profile.updated_at, 0, 4294967295, 0)
  };
}

async function loadingProfile(request, url, env) {
  if (request.method === "POST") {
    if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
    const declaredLength = boundedInteger(request.headers.get("content-length"), 0, 1000000, 0);
    if (declaredLength > 4096) return json({ error: "payload_too_large" }, 413);
    const raw = await request.text();
    if (raw.length > 4096) return json({ error: "payload_too_large" }, 413);
    let submitted;
    try {
      submitted = JSON.parse(raw);
    } catch {
      return json({ error: "invalid_json" }, 400);
    }
    const steamid = safeText(submitted?.steamid, 24);
    if (!validSteamID(steamid)) return json({ error: "invalid_steamid" }, 400);
    const profile = normalizeLoadingProfile(submitted, steamid);
    await env.DRP_LINKS.put(`loading:${steamid}`, JSON.stringify(profile), { expirationTtl: 31536000 });
    return json({ stored: true });
  }

  const steamid = safeText(url.searchParams.get("steamid"), 24);
  if (!validSteamID(steamid)) return json({ found: false, error: "invalid_steamid" }, 400);
  const stored = await env.DRP_LINKS.get(`loading:${steamid}`, { type: "json" });
  if (!stored) {
    return json({
      found: false,
      steamid,
      rp_name: "New arrival",
      job: "Citizen",
      wallet: 0,
      level: 1,
      civic: 0,
      updated_at: 0
    });
  }
  return json(normalizeLoadingProfile(stored, steamid));
}

async function loadingPage(url, env) {
  const steamid = safeText(url.searchParams.get("steamid"), 24);
  const map = safeText(url.searchParams.get("map"), 64) || "Connecting";
  const validID = validSteamID(steamid);
  const stored = validID ? await env.DRP_LINKS.get(`loading:${steamid}`, { type: "json" }) : null;
  const profile = stored
    ? normalizeLoadingProfile(stored, steamid)
    : { found: false, steamid: validID ? steamid : "", rp_name: "New arrival", job: "Citizen", wallet: 0, level: 1, civic: 0 };
  const civicValue = boundedInteger(profile.civic, -1000, 1000, 0);
  const civicLabel = civicValue <= -750 ? "Notorious" : civicValue <= -400 ? "Criminal" : civicValue <= -150 ? "Fringe"
    : civicValue < 150 ? "Neutral" : civicValue < 400 ? "Upstanding" : civicValue < 750 ? "Exemplary" : "Civic Pillar";
  const initial = JSON.stringify({ steamid: validID ? steamid : "", map, profile }).replace(/</g, "\\u003c");
  const visibleName = escapeHTML(profile.rp_name);
  const visibleJob = escapeHTML(profile.job);
  const visibleSteamID = escapeHTML(profile.steamid || "Unavailable");
  const visibleWallet = boundedInteger(profile.wallet, 0, 4294967295, 0).toLocaleString("en-US");
  const visibleLevel = boundedInteger(profile.level, 1, 100, 1);
  const visibleCivic = `${escapeHTML(civicLabel)} · ${civicValue > 0 ? "+" : ""}${civicValue}`;
  return new Response(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Joining DarkRP Foundation</title><style>
:root{color-scheme:dark;--cyan:#55d9ff;--blue:#4387ff;--green:#6ef3a5;--muted:#91a4c3;--panel:#0a1222e8}
*{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;overflow:hidden}
body{font-family:Arial,Helvetica,sans-serif;color:#f7fbff;background:#050a14}
.backdrop{position:fixed;inset:0;background:
radial-gradient(circle at 78% 18%,#19507299 0,transparent 34%),
radial-gradient(circle at 15% 90%,#19385d99 0,transparent 40%),
linear-gradient(128deg,#050914 0%,#0b1930 52%,#07101e 100%)}
.grid{position:fixed;inset:0;opacity:.13;background-image:linear-gradient(#63dfff22 1px,transparent 1px),linear-gradient(90deg,#63dfff22 1px,transparent 1px);background-size:46px 46px;transform:perspective(600px) rotateX(54deg) scale(1.7);transform-origin:center bottom}
.shell{position:relative;height:100%;display:flex;align-items:center;padding:6vw}
.card{width:min(760px,68vw);padding:38px 42px 34px;border:1px solid #55d9ff55;border-radius:18px;background:var(--panel);box-shadow:0 30px 100px #000b,inset 0 1px #fff1;backdrop-filter:blur(14px)}
.accent{height:4px;width:112px;border-radius:8px;background:linear-gradient(90deg,var(--cyan),var(--blue));box-shadow:0 0 26px #55d9ffaa}
.kicker{margin:22px 0 8px;color:var(--cyan);font-size:12px;font-weight:800;letter-spacing:.22em}
h1{margin:0;font-size:clamp(30px,4vw,58px);line-height:1.04;letter-spacing:-.04em}
.role{margin:12px 0 28px;color:var(--muted);font-size:19px}.role span{color:#fff;font-weight:700}
.fields{display:grid;grid-template-columns:1.3fr .7fr;gap:12px}
.field{min-height:74px;padding:15px 17px;border:1px solid #8bb9e326;border-radius:10px;background:#111d31cc}
.label{color:var(--muted);font-size:11px;font-weight:800;letter-spacing:.14em}.value{margin-top:8px;font-size:18px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.good{color:var(--green)}.footer{margin-top:28px}.statusrow{display:flex;justify-content:space-between;gap:20px;color:var(--muted);font-size:12px;font-weight:700;letter-spacing:.08em}
.track{height:7px;margin-top:11px;border-radius:8px;background:#1e314c;overflow:hidden}.progress{height:100%;width:24%;border-radius:8px;background:linear-gradient(90deg,var(--cyan),var(--blue));box-shadow:0 0 18px #55d9ff;transition:width .35s ease}
.corner{position:fixed;right:5vw;top:6vh;text-align:right}.brand{font-weight:900;letter-spacing:.16em}.map{margin-top:8px;color:var(--muted);font-size:13px}
@media(max-width:760px){.shell{padding:24px}.card{width:100%;padding:28px}.fields{grid-template-columns:1fr}.corner{display:none}}
</style></head><body><div class="backdrop"></div><div class="grid"></div>
<aside class="corner"><div class="brand">DARKRP FOUNDATION</div><div class="map" id="map"></div></aside>
<main class="shell"><section class="card"><div class="accent"></div><div class="kicker">PLAYER PROFILE</div>
<h1 id="name">${visibleName}</h1><div class="role">Entering as <span id="job">${visibleJob}</span></div>
<div class="fields">
<div class="field"><div class="label">STEAM ID</div><div class="value" id="steamid">${visibleSteamID}</div></div>
<div class="field"><div class="label">LEVEL</div><div class="value" id="level">${visibleLevel}</div></div>
<div class="field"><div class="label">WALLET</div><div class="value good" id="wallet">$${visibleWallet}</div></div>
<div class="field"><div class="label">CIVIC STANDING</div><div class="value" id="civic">${visibleCivic}</div></div>
</div><div class="footer"><div class="statusrow"><span id="status">CONTACTING SERVER</span><span id="files">PREPARING CONTENT</span></div>
<div class="track"><div class="progress" id="progress"></div></div></div></section></main>
<script>
(function(){
  "use strict";
  var initial=${initial}, activeSteamID="", filesNeeded=0, filesTotal=0, refreshes=0;
  var byId=function(id){return document.getElementById(id)};
  var setText=function(id,value){byId(id).textContent=String(value)};
  var money=function(value){return "$"+Math.max(0,Number(value)||0).toLocaleString("en-US")};
  var civic=function(value){value=Number(value)||0;var label=value<=-750?"Notorious":value<=-400?"Criminal":value<=-150?"Fringe":value<150?"Neutral":value<400?"Upstanding":value<750?"Exemplary":"Civic Pillar";return label+" · "+(value>0?"+":"")+value};
  var applyProfile=function(profile){
    setText("name",profile.rp_name||"New arrival");setText("job",profile.job||"Citizen");
    setText("wallet",money(profile.wallet));setText("level",profile.level||1);setText("civic",civic(profile.civic));
    setText("status",profile.found?"PROFILE READY":"NEW PROFILE");
  };
  var loadProfile=function(sid,refresh){
    if(!/^7656119\\d{10}$/.test(sid)||(!refresh&&sid===activeSteamID))return;
    activeSteamID=sid;setText("steamid",sid);
    fetch("/loading/profile?steamid="+encodeURIComponent(sid),{cache:"no-store"}).then(function(response){
      if(!response.ok)throw new Error("profile unavailable");return response.json();
    }).then(function(profile){
      applyProfile(profile);byId("progress").style.width="62%";
      if(!profile.found&&refreshes<4){refreshes++;setTimeout(function(){loadProfile(sid,true)},2000)}
    }).catch(function(){setText("name","Welcome, citizen");setText("status","PROFILE WILL INITIALISE IN GAME");});
  };
  setText("map",initial.map);applyProfile(initial.profile);
  if(initial.steamid&&!initial.profile.found)loadProfile(initial.steamid);
  window.GameDetails=function(servername,serverurl,mapname,maxplayers,sid,gamemode){
    if(mapname)setText("map",mapname);if(sid)loadProfile(String(sid));
  };
  window.SetFilesTotal=function(total){filesTotal=Math.max(0,Number(total)||0)};
  window.DownloadingFile=function(fileName){if(fileName)setText("files",String(fileName).split("/").pop())};
  window.SetStatusChanged=function(status){
    setText("status",status||"CONNECTING");
    if(/sending client info|fully connected/i.test(status||""))byId("progress").style.width="100%";
  };
  window.SetFilesNeeded=function(needed){
    filesNeeded=Math.max(0,Number(needed)||0);
    setText("files",filesNeeded?filesNeeded+" FILES REMAINING":"CONTENT READY");
    if(filesTotal>0)byId("progress").style.width=(15+85*(1-Math.min(1,filesNeeded/filesTotal)))+"%";
    else if(!filesNeeded)byId("progress").style.width="88%";
  };
})();
</script></body></html>`, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; connect-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline';"
    }
  });
}

async function sha256(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

async function equalSecret(actual, expected) {
  if (typeof actual !== "string" || typeof expected !== "string") return false;
  const encoder = new TextEncoder();
  const left = encoder.encode(actual);
  const right = encoder.encode(expected);
  return left.byteLength === right.byteLength && crypto.subtle.timingSafeEqual(left, right);
}

async function authorized(request, env) {
  return equalSecret(request.headers.get("authorization") || "", `Bearer ${env.SERVICE_BEARER || ""}`);
}

async function discordChannel(env, requestedID) {
  const channelID = safeText(requestedID || env.DISCORD_DARKRP_CHANNEL_ID, 22);
  if (!env.DISCORD_BOT_TOKEN || !validDiscordID(channelID)) return { error: "darkrp_channel_not_configured" };
  const response = await fetch(`${DISCORD_API}/channels/${channelID}`, {
    headers: { authorization: `Bot ${env.DISCORD_BOT_TOKEN}` }
  });
  if (!response.ok) return { error: `channel_lookup_http_${response.status}` };
  const channel = await response.json();
  const guildID = safeText(channel.guild_id || env.DISCORD_GUILD_ID, 22);
  if (!validDiscordID(guildID)) return { error: "channel_guild_unavailable" };
  return { id: channelID, guildID, name: safeText(channel.name, 100) };
}

async function darkRPRole(env, guildID) {
  if (!env.DISCORD_BOT_TOKEN || !validDiscordID(guildID)) return { error: "role_service_not_configured" };
  const configuredID = safeText(env.DISCORD_DARKRP_ROLE_ID, 22);
  if (validDiscordID(configuredID)) return { id: configuredID };
  const response = await fetch(`${DISCORD_API}/guilds/${guildID}/roles`, {
    headers: { authorization: `Bot ${env.DISCORD_BOT_TOKEN}` }
  });
  if (!response.ok) return { error: `role_lookup_http_${response.status}` };
  const roles = await response.json();
  const role = (Array.isArray(roles) ? roles : []).find(entry => normalizeChannelName(entry.name) === "darkrp");
  return role && validDiscordID(role.id) ? { id: role.id } : { error: "darkrp_role_not_found" };
}

async function grantDarkRPRole(env, guildID, discordID) {
  if (!env.DISCORD_BOT_TOKEN || !validDiscordID(guildID) || !validDiscordID(discordID)) {
    return { ok: false, message: "The DarkRP role service is not configured." };
  }
  const headers = { authorization: `Bot ${env.DISCORD_BOT_TOKEN}` };
  const role = await darkRPRole(env, guildID);
  if (!validDiscordID(role.id)) return { ok: false, message: "Create a Discord role named DarkRP, then try again." };
  const assignResponse = await fetch(`${DISCORD_API}/guilds/${guildID}/members/${discordID}/roles/${role.id}`, {
    method: "PUT",
    headers: {
      ...headers,
      "x-audit-log-reason": "DarkRP Foundation account verification"
    }
  });
  if (!assignResponse.ok) {
    return { ok: false, message: "The bot could not grant DarkRP. Give it Manage Roles and place its role above DarkRP." };
  }
  return { ok: true, roleID: role.id };
}

async function memberStatus(request, url, env) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  const steamid = safeText(url.searchParams.get("steamid"), 24);
  if (!validSteamID(steamid)) return json({ checked: false, error: "invalid_steamid" }, 400);

  const [storedDiscordID, storedMeta] = await Promise.all([
    env.DRP_LINKS.get(`steam:${steamid}`),
    env.DRP_LINKS.get(`linkmeta:${steamid}`, { type: "json" })
  ]);
  const discordID = safeText(storedDiscordID, 22);
  if (!validDiscordID(discordID)) {
    return json({ checked: true, linked: false, guild_member: false, role_granted: false });
  }

  let guildID = safeText(env.DISCORD_GUILD_ID || storedMeta?.guild_id, 22);
  if (!validDiscordID(guildID)) {
    const channel = await discordChannel(env, url.searchParams.get("channel_id"));
    if (channel.error) return json({ checked: false, error: channel.error }, 503);
    guildID = channel.guildID;
  }
  let role = { id: safeText(env.DISCORD_DARKRP_ROLE_ID || storedMeta?.role_id, 22) };
  if (!validDiscordID(role.id)) role = await darkRPRole(env, guildID);
  if (!validDiscordID(role.id)) return json({ checked: false, error: role.error || "darkrp_role_unavailable" }, 503);
  if (!validDiscordID(storedMeta?.guild_id) || !validDiscordID(storedMeta?.role_id)) {
    await env.DRP_LINKS.put(`linkmeta:${steamid}`, JSON.stringify({ guild_id: guildID, role_id: role.id }));
  }

  const response = await fetch(`${DISCORD_API}/guilds/${guildID}/members/${discordID}`, {
    headers: { authorization: `Bot ${env.DISCORD_BOT_TOKEN}` }
  });
  if (response.status === 404) {
    return json({ checked: true, linked: true, discord_id: discordID, guild_member: false, role_granted: false });
  }
  if (!response.ok) return json({ checked: false, error: `member_lookup_http_${response.status}` }, 502);
  const member = await response.json();
  const memberRoles = Array.isArray(member.roles) ? member.roles.map(String) : [];
  return json({
    checked: true,
    linked: true,
    discord_id: discordID,
    discord_name: safeText(member.nick || member.user?.global_name || member.user?.username, 64),
    guild_member: true,
    role_granted: memberRoles.includes(role.id)
  });
}

async function saveVerifiedLink(env, pending, discordUser, roleGranted = false, guildID = "", roleID = "") {
  const discordID = String(discordUser.id || "");
  if (!validSteamID(pending.steamid) || !validToken(pending.token) || !validDiscordID(discordID)) {
    return { ok: false, message: "That link request is invalid or expired." };
  }
  if (!roleGranted) {
    return { ok: false, message: "Join the DarkRP Discord and use the /link command so the bot can grant your role." };
  }
  const [existingOwner, existingDiscord] = await Promise.all([
    env.DRP_LINKS.get(`discord:${discordID}`),
    env.DRP_LINKS.get(`steam:${pending.steamid}`)
  ]);
  if (existingOwner && existingOwner !== pending.steamid) {
    return { ok: false, message: "Your Discord identity is already linked to a different Steam account." };
  }
  if (existingDiscord && existingDiscord !== discordID) {
    return { ok: false, message: "That Steam account is already linked to a different Discord identity." };
  }
  const discordName = safeText(discordUser.global_name || discordUser.username || discordUser.name, 64);
  await Promise.all([
    env.DRP_LINKS.put(`discord:${discordID}`, pending.steamid),
    env.DRP_LINKS.put(`steam:${pending.steamid}`, discordID),
    env.DRP_LINKS.put(`linkmeta:${pending.steamid}`, JSON.stringify({
      guild_id: safeText(guildID, 22),
      role_id: safeText(roleID, 22)
    })),
    env.DRP_LINKS.put(`verified:${pending.steamid}:${pending.token}`, JSON.stringify({
      linked: true,
      role_granted: true,
      discord_id: discordID,
      discord_name: discordName
    }), { expirationTtl: 600 })
  ]);
  return { ok: true, message: "DarkRP role granted and Discord linked. Return to Garry's Mod; your trust score will refresh automatically." };
}

async function start(url, env) {
  const steamid = url.searchParams.get("steamid") || "";
  const token = url.searchParams.get("token") || "";
  const signature = url.searchParams.get("signature") || "";
  if (!validSteamID(steamid) || !validToken(token) || !validSignature(signature)) {
    return page("Invalid link", "Return to the game and begin Discord linking again.", false);
  }
  const expected = await sha256(`${steamid}:${token}:${env.LINK_SECRET}`);
  if (!await equalSecret(signature, expected)) return page("Invalid signature", "This link was not issued by the game server.", false);

  const state = crypto.randomUUID().replaceAll("-", "");
  await env.DRP_LINKS.put(`state:${state}`, JSON.stringify({ steamid, token }), { expirationTtl: 600 });
  const authorize = new URL("https://discord.com/oauth2/authorize");
  authorize.searchParams.set("response_type", "code");
  authorize.searchParams.set("client_id", env.DISCORD_CLIENT_ID);
  authorize.searchParams.set("scope", "identify");
  authorize.searchParams.set("state", state);
  authorize.searchParams.set("redirect_uri", env.DISCORD_REDIRECT_URI);
  authorize.searchParams.set("prompt", "consent");
  return Response.redirect(authorize.toString(), 302);
}

async function callback(url, env) {
  const code = url.searchParams.get("code") || "";
  const state = url.searchParams.get("state") || "";
  const pendingRaw = state && await env.DRP_LINKS.get(`state:${state}`);
  if (!code || !pendingRaw) return page("Verification expired", "Return to the game and use /discordlink again.", false);
  await env.DRP_LINKS.delete(`state:${state}`);
  const pending = JSON.parse(pendingRaw);

  const form = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: env.DISCORD_REDIRECT_URI,
    client_id: env.DISCORD_CLIENT_ID,
    client_secret: env.DISCORD_CLIENT_SECRET
  });
  const tokenResponse = await fetch(`${DISCORD_API}/oauth2/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: form
  });
  if (!tokenResponse.ok) return page("Discord rejected the link", "The authorization code could not be verified.", false);
  const oauth = await tokenResponse.json();
  const userResponse = await fetch(`${DISCORD_API}/users/@me`, {
    headers: { authorization: `Bearer ${oauth.access_token}` }
  });
  if (!userResponse.ok) return page("Identity unavailable", "Discord did not return an identity for this authorization.", false);
  const result = await saveVerifiedLink(env, pending, await userResponse.json(), false);
  return page(result.ok ? "Identity verified" : "Identity unavailable", result.message, result.ok);
}

async function status(request, url, env) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  const steamid = url.searchParams.get("steamid") || "";
  const token = url.searchParams.get("token") || "";
  if (!validSteamID(steamid) || !validToken(token)) return json({ linked: false }, 400);
  const result = await env.DRP_LINKS.get(`verified:${steamid}:${token}`);
  if (!result) return json({ linked: false });
  return json(JSON.parse(result));
}

async function unlink(request, url, env) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  const steamid = url.searchParams.get("steamid") || "";
  const discordID = url.searchParams.get("discord_id") || "";
  if (!validSteamID(steamid) || !validDiscordID(discordID)) return json({ unlinked: false }, 400);
  const [owner, identity] = await Promise.all([
    env.DRP_LINKS.get(`discord:${discordID}`),
    env.DRP_LINKS.get(`steam:${steamid}`)
  ]);
  if (owner !== steamid || identity !== discordID) return json({ unlinked: false }, 409);
  await Promise.all([
    env.DRP_LINKS.delete(`discord:${discordID}`),
    env.DRP_LINKS.delete(`steam:${steamid}`),
    env.DRP_LINKS.delete(`linkmeta:${steamid}`)
  ]);
  return json({ unlinked: true });
}

async function botStart(request, url, env) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  const steamid = url.searchParams.get("steamid") || "";
  const token = url.searchParams.get("token") || "";
  const code = (url.searchParams.get("code") || "").toUpperCase();
  if (!validSteamID(steamid) || !validToken(token) || !validLinkCode(code)) {
    return json({ started: false, error: "invalid_request" }, 400);
  }
  const channel = await discordChannel(env, url.searchParams.get("channel_id"));
  if (channel.error) return json({ started: false, error: channel.error }, 503);
  await env.DRP_LINKS.put(`botcode:${code}`, JSON.stringify({ steamid, token }), { expirationTtl: 600 });
  return json({
    started: true,
    code,
    command: `/link code:${code}`,
    channel_url: `https://discord.com/channels/${channel.guildID}/${channel.id}`
  });
}

async function botInvite(request, url, env) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  const channel = await discordChannel(env, url.searchParams.get("channel_id"));
  if (channel.error) return json({ error: channel.error }, 503);
  const response = await fetch(`${DISCORD_API}/channels/${channel.id}/invites`, {
    method: "POST",
    headers: {
      authorization: `Bot ${env.DISCORD_BOT_TOKEN}`,
      "content-type": "application/json",
      "x-audit-log-reason": "DarkRP Foundation in-game Discord join request"
    },
    body: JSON.stringify({ max_age: 0, max_uses: 0, temporary: false, unique: false })
  });
  const invite = await response.json().catch(() => ({}));
  const code = safeText(invite.code, 64);
  if (!response.ok || !code) return json({ error: `invite_create_http_${response.status}` }, 502);
  return json({
    invite_url: `https://discord.gg/${code}`,
    channel_url: `https://discord.com/channels/${channel.guildID}/${channel.id}`,
    channel_name: channel.name
  });
}

async function botControl(request, url, env, action) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  if (!env.BOT_PRESENCE) return json({ active: false, error: "bot_presence_not_bound" }, 503);
  const target = new URL(`https://bot.internal/${action}`);
  for (const key of ["name", "map", "players", "max", "channel_id"]) {
    const value = url.searchParams.get(key);
    if (value !== null) target.searchParams.set(key, value);
  }
  const id = env.BOT_PRESENCE.idFromName(BOT_OBJECT_NAME);
  return env.BOT_PRESENCE.get(id).fetch(target.toString(), {
    method: action === "reset" ? "POST" : "GET"
  });
}

async function botInbox(request, url, env) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  const channelID = safeText(url.searchParams.get("channel_id"), 22);
  if (!validDiscordID(channelID) || !env.BOT_PRESENCE) {
    return json({ messages: [], error: "invalid_channel" }, 400);
  }
  const id = env.BOT_PRESENCE.idFromName(BOT_OBJECT_NAME);
  return env.BOT_PRESENCE.get(id).fetch(`https://bot.internal/inbox?channel_id=${channelID}`);
}

function joinPage(url) {
  const serverAddress = safeText(url.searchParams.get("server"), 280);
  if (!validServerAddress(serverAddress)) return page("Invalid server", "This join link is not configured correctly.", false);
  const steamURL = `steam://connect/${serverAddress}`;
  return new Response(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Join DarkRP Foundation</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;
background:radial-gradient(circle at 20% 0%,#12345f 0,#080d19 42%,#050811 100%);color:#f7fbff;
font:16px system-ui,-apple-system,sans-serif}.card{width:min(600px,calc(100% - 36px));padding:38px;border-radius:22px;
background:linear-gradient(145deg,#121e34f2,#0b1222f2);border:1px solid #31547c;box-shadow:0 30px 100px #000b;
position:relative;overflow:hidden}.card:before{content:"";position:absolute;inset:0 0 auto;height:5px;
background:linear-gradient(90deg,#40d8ff,#6978ff,#42edac)}.brand{color:#56dcff;font-size:12px;font-weight:900;
letter-spacing:.18em}h1{font-size:34px;margin:10px 0 10px}p{color:#a9b9d2;line-height:1.65;margin:0 0 24px}
.server{padding:13px 16px;border-radius:12px;background:#07101f;border:1px solid #263c5b;color:#d7e8ff;
font:600 14px ui-monospace,monospace;margin-bottom:20px}.join{display:inline-flex;align-items:center;gap:9px;
padding:13px 19px;border-radius:11px;background:linear-gradient(90deg,#35cfff,#6574ff);color:white;text-decoration:none;
font-weight:850;box-shadow:0 10px 30px #247fd855}.note{font-size:12px;color:#7789a5;margin-top:18px}
</style></head><body><main class="card"><div class="brand">DARKRP FOUNDATION</div>
<h1>Launching Garry's Mod</h1><p>Steam should open and connect you automatically. If your browser asks for permission,
allow it to open Steam.</p><div class="server">${serverAddress}</div>
<a class="join" href="${steamURL}">🎮 Open Garry's Mod</a>
<div class="note">If nothing happens, click the button above once more.</div></main>
<script>window.location.href=${JSON.stringify(steamURL)};</script></body></html>`, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=300",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; navigate-to steam:"
    }
  });
}

async function findDiscordChannel(env, requestedName) {
  if (!env.DISCORD_BOT_TOKEN) return { error: "bot_not_configured" };
  const authorization = { authorization: `Bot ${env.DISCORD_BOT_TOKEN}` };
  const guildResponse = await fetch(`${DISCORD_API}/users/@me/guilds?limit=200`, { headers: authorization });
  if (!guildResponse.ok) return { error: `guild_lookup_http_${guildResponse.status}` };
  const guilds = await guildResponse.json();
  const target = normalizeChannelName(requestedName);
  const matches = [];
  for (const guild of Array.isArray(guilds) ? guilds : []) {
    const channelResponse = await fetch(`${DISCORD_API}/guilds/${guild.id}/channels`, { headers: authorization });
    if (!channelResponse.ok) continue;
    const channels = await channelResponse.json();
    for (const channel of Array.isArray(channels) ? channels : []) {
      if ((channel.type === 0 || channel.type === 5) && normalizeChannelName(channel.name) === target) {
        matches.push({ id: channel.id, name: channel.name, guild_id: guild.id, guild_name: guild.name });
      }
    }
  }
  if (matches.length !== 1) return {
    error: matches.length === 0 ? "channel_not_found" : "channel_name_ambiguous",
    matches
  };
  return { channel: matches[0] };
}

async function publishJoinCard(request, url, env) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  if (!env.BOT_PRESENCE) return json({ error: "bot_presence_not_bound" }, 503);
  const declaredLength = Number.parseInt(request.headers.get("content-length") || "0", 10);
  if (declaredLength > 2048) return json({ error: "payload_too_large" }, 413);
  const raw = await request.text();
  if (raw.length > 2048) return json({ error: "payload_too_large" }, 413);
  const data = JSON.parse(raw || "{}");
  const serverAddress = safeText(data.server_address, 280);
  if (!validServerAddress(serverAddress)) return json({ error: "invalid_server_address" }, 400);

  let channel = null;
  const requestedChannelID = safeText(data.channel_id, 22);
  if (validDiscordID(requestedChannelID)) {
    channel = { id: requestedChannelID, name: safeText(data.channel_name, 100) || requestedChannelID };
  } else {
    const discovered = await findDiscordChannel(env, safeText(data.channel_name, 100) || "join darkrp");
    if (!discovered.channel) return json(discovered, discovered.error === "channel_not_found" ? 404 : 409);
    channel = discovered.channel;
  }

  const joinURL = new URL("/join", url.origin);
  joinURL.searchParams.set("server", serverAddress);
  const id = env.BOT_PRESENCE.idFromName(BOT_OBJECT_NAME);
  const response = await env.BOT_PRESENCE.get(id).fetch("https://bot.internal/join-card", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      channelID: channel.id,
      channelName: channel.name,
      serverAddress,
      joinURL: joinURL.toString()
    })
  });
  const result = await response.json().catch(() => ({ error: "invalid_bot_response" }));
  return json({ ...result, channel }, response.status);
}

async function registerCommand(request, env) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  if (!env.DISCORD_BOT_TOKEN || !env.DISCORD_CLIENT_ID) return json({ error: "bot_not_configured" }, 503);
  const response = await fetch(`${DISCORD_API}/applications/${env.DISCORD_CLIENT_ID}/commands`, {
    method: "POST",
    headers: {
      authorization: `Bot ${env.DISCORD_BOT_TOKEN}`,
      "content-type": "application/json"
    },
    body: JSON.stringify({
      name: "link",
      description: "Link your Discord account to your DarkRP Foundation profile",
      options: [{
        type: 3,
        name: "code",
        description: "The eight-character code shown in Garry's Mod",
        required: true,
        min_length: 8,
        max_length: 8
      }]
    })
  });
  const body = await response.json().catch(() => ({}));
  return json({ registered: response.ok, discord_status: response.status, command: body }, response.ok ? 200 : 502);
}

async function botChat(request, env) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  const declaredLength = Number.parseInt(request.headers.get("content-length") || "0", 10);
  if (declaredLength > 4096) return json({ accepted: false, error: "payload_too_large" }, 413);
  const raw = await request.text();
  if (raw.length > 4096) return json({ accepted: false, error: "payload_too_large" }, 413);
  const data = JSON.parse(raw);
  const payload = {
    queue_kind: safeText(data.queue_kind, 24),
    channel_id: safeText(data.channel_id, 22),
    rp_name: safeText(data.rp_name, 64),
    steam_name: safeText(data.steam_name, 64),
    steam_id: safeText(data.steam_id, 32),
    steam_id64: safeText(data.steam_id64, 20),
    discord_id: safeText(data.discord_id, 22),
    discord_name: safeText(data.discord_name, 64),
    message: safeText(data.message, 240),
    job: safeText(data.job, 48),
    rank: safeText(data.rank, 24),
    level: Math.max(1, Math.min(100, Number.parseInt(data.level, 10) || 1)),
    civic: Math.max(-32768, Math.min(32767, Number.parseInt(data.civic, 10) || 0)),
    trust_score: Math.max(0, Math.min(100, Number.parseInt(data.trust_score, 10) || 0)),
    trust_label: safeText(data.trust_label, 32),
    players: Math.max(0, Math.min(128, Number.parseInt(data.players, 10) || 0)),
    max_players: Math.max(1, Math.min(128, Number.parseInt(data.max_players, 10) || 64))
  };
  const playerJoin = payload.queue_kind === "player_join";
  if (payload.queue_kind && !playerJoin) return json({ accepted: false, error: "invalid_message_kind" }, 400);
  if (!validDiscordID(payload.channel_id) || !validSteamID(payload.steam_id64) || !payload.rp_name
    || (!playerJoin && !payload.message)) {
    return json({ accepted: false, error: "invalid_message" }, 400);
  }
  if (payload.discord_id && !validDiscordID(payload.discord_id)) payload.discord_id = "";
  if (!env.BOT_PRESENCE) return json({ accepted: false, error: "bot_presence_not_bound" }, 503);
  const id = env.BOT_PRESENCE.idFromName(BOT_OBJECT_NAME);
  return env.BOT_PRESENCE.get(id).fetch("https://bot.internal/chat", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  });
}

async function botContentReport(request, env) {
  if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
  const declaredLength = Number.parseInt(request.headers.get("content-length") || "0", 10);
  if (declaredLength > 4096) return json({ accepted: false, error: "payload_too_large" }, 413);
  const raw = await request.text();
  if (raw.length > 4096) return json({ accepted: false, error: "payload_too_large" }, 413);
  const data = JSON.parse(raw);
  const payload = {
    queue_kind: "content_report",
    channel_id: safeText(data.channel_id, 22),
    player_name: safeText(data.player_name, 64),
    steam_id: safeText(data.steam_id, 32),
    steam_id64: safeText(data.steam_id64, 20),
    discord_id: safeText(data.discord_id, 22),
    issue_kind: safeText(data.issue_kind, 32),
    content_id: safeText(data.content_id, 20),
    asset: safeText(data.asset, 192),
    entity_class: safeText(data.entity_class, 64),
    platform: safeText(data.platform, 16),
    branch: safeText(data.branch, 24)
  };
  const validKinds = new Set(["required_pack", "invalid_model", "missing_material"]);
  if (!validDiscordID(payload.channel_id) || !validSteamID(payload.steam_id64)
    || !payload.player_name || !validKinds.has(payload.issue_kind) || !payload.asset) {
    return json({ accepted: false, error: "invalid_content_report" }, 400);
  }
  if (payload.discord_id && !validDiscordID(payload.discord_id)) payload.discord_id = "";
  if (!env.BOT_PRESENCE) return json({ accepted: false, error: "bot_presence_not_bound" }, 503);
  const id = env.BOT_PRESENCE.idFromName(BOT_OBJECT_NAME);
  return env.BOT_PRESENCE.get(id).fetch("https://bot.internal/content-report", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  });
}

export class BotPresence {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.socket = null;
    this.connecting = false;
    this.ready = false;
    this.sequence = null;
    this.sessionID = null;
    this.resumeURL = null;
    this.server = null;
    this.heartbeatTimer = null;
    this.reconnectTimer = null;
    this.heartbeatAcknowledged = true;
    this.claimedCodes = new Set();
    this.chatQueue = [];
    this.chatDraining = false;
    this.inboundQueue = [];
    this.watchedChannelID = "";
    this.joinCard = null;
    this.joinCardSyncing = false;
    this.connectionMode = "identify";
    this.sessionStart = null;
    this.gatewayControl = null;
    this.gatewayStateLoaded = false;
    this.gatewayStateLoading = null;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/heartbeat") {
      this.server = {
        name: safeText(url.searchParams.get("name"), 80) || "DarkRP Foundation",
        map: safeText(url.searchParams.get("map"), 64) || "unknown map",
        players: Math.max(0, Math.min(128, Number.parseInt(url.searchParams.get("players") || "0", 10) || 0)),
        max: Math.max(1, Math.min(128, Number.parseInt(url.searchParams.get("max") || "64", 10) || 64)),
        channelID: safeText(url.searchParams.get("channel_id"), 22),
        lastSeen: Date.now()
      };
      if (validDiscordID(this.server.channelID)) this.watchedChannelID = this.server.channelID;
      await this.state.storage.put("server", this.server);
      await this.state.storage.setAlarm(this.server.lastSeen + SERVER_TTL_MS);
      await this.ensureConnected();
      this.updatePresence();
      this.state.waitUntil(this.syncJoinCard());
      return json({
        active: true,
        configured: Boolean(this.env.DISCORD_BOT_TOKEN),
        ready: this.ready,
        locked: Boolean(this.gatewayControl?.fatalCode),
        next_attempt_at: this.gatewayControl?.nextAttemptAt || 0
      });
    }
    if (url.pathname === "/offline") {
      await this.state.storage.delete("server");
      this.server = null;
      await this.syncJoinCard(true);
      await this.disconnect(1000, "Game server stopped");
      return json({ active: false });
    }
    if (url.pathname === "/chat" && request.method === "POST") {
      const payload = await request.json();
      if (this.chatQueue.length >= 200) this.chatQueue.shift();
      this.chatQueue.push(payload);
      this.state.waitUntil(this.drainChat());
      return json({ accepted: true, queued: this.chatQueue.length });
    }
    if (url.pathname === "/content-report" && request.method === "POST") {
      const payload = await request.json();
      if (this.chatQueue.length >= 200) this.chatQueue.shift();
      this.chatQueue.push(payload);
      this.state.waitUntil(this.drainChat());
      return json({ accepted: true, queued: this.chatQueue.length });
    }
    if (url.pathname === "/inbox") {
      const channelID = safeText(url.searchParams.get("channel_id"), 22);
      if (!validDiscordID(channelID)) return json({ messages: [] }, 400);
      this.watchedChannelID = channelID;
      const messages = [];
      const retained = [];
      for (const message of this.inboundQueue) {
        if (message.channel_id === channelID && messages.length < 32) messages.push(message);
        else retained.push(message);
      }
      this.inboundQueue = retained.slice(-200);
      return json({ messages });
    }
    if (url.pathname === "/join-card" && request.method === "POST") {
      const payload = await request.json();
      const next = {
        channelID: safeText(payload.channelID, 22),
        channelName: safeText(payload.channelName, 100),
        serverAddress: safeText(payload.serverAddress, 280),
        joinURL: safeText(payload.joinURL, 512),
        messageID: "",
        signature: ""
      };
      if (!validDiscordID(next.channelID) || !validServerAddress(next.serverAddress)
        || !next.joinURL.startsWith("https://")) {
        return json({ posted: false, error: "invalid_join_card" }, 400);
      }
      const existing = this.joinCard || await this.state.storage.get("joinCard");
      if (existing?.channelID === next.channelID) next.messageID = safeText(existing.messageID, 22);
      this.joinCard = next;
      await this.state.storage.put("joinCard", next);
      const result = await this.syncJoinCard(true);
      return json(result, result.posted ? 200 : 502);
    }
    if (url.pathname === "/status") {
      await this.loadGatewayState();
      return json(this.gatewayStatus());
    }
    if (url.pathname === "/reset" && request.method === "POST") {
      await this.disconnect(4000, "Gateway state reset", true);
      await this.resetGatewayState("manual_reset");
      await this.ensureConnected();
      return json(this.gatewayStatus());
    }
    return json({ error: "not_found" }, 404);
  }

  async alarm() {
    this.server = await this.state.storage.get("server");
    if (!this.server || Date.now() - this.server.lastSeen >= SERVER_TTL_MS) {
      await this.state.storage.delete("server");
      this.server = null;
      await this.syncJoinCard(true);
      await this.disconnect(1000, "Game server heartbeat expired");
      return;
    }
    await this.state.storage.setAlarm(this.server.lastSeen + SERVER_TTL_MS);
    await this.ensureConnected();
  }

  isServerLive() {
    return this.server && Date.now() - this.server.lastSeen < SERVER_TTL_MS;
  }

  async loadGatewayState() {
    const fingerprint = await tokenFingerprint(this.env.DISCORD_BOT_TOKEN);
    if (this.gatewayStateLoaded && this.gatewayControl?.tokenFingerprint === fingerprint) return;
    if (this.gatewayStateLoading) return this.gatewayStateLoading;
    this.gatewayStateLoading = (async () => {
      const [storedControl, storedSession] = await Promise.all([
        this.state.storage.get(GATEWAY_CONTROL_KEY),
        this.state.storage.get(GATEWAY_SESSION_KEY)
      ]);
      if (!storedControl || storedControl.tokenFingerprint !== fingerprint) {
        this.gatewayControl = gatewayControlDefaults(fingerprint);
        this.sequence = null;
        this.sessionID = null;
        this.resumeURL = null;
        await this.state.storage.put({
          [GATEWAY_CONTROL_KEY]: this.gatewayControl,
          [GATEWAY_SESSION_KEY]: { sessionID: null, sequence: null, resumeURL: null }
        });
      } else {
        this.gatewayControl = { ...gatewayControlDefaults(fingerprint), ...storedControl };
        this.sequence = Number.isInteger(storedSession?.sequence) ? storedSession.sequence : null;
        this.sessionID = safeText(storedSession?.sessionID, 128) || null;
        this.resumeURL = safeText(storedSession?.resumeURL, 256) || null;
      }
      this.gatewayStateLoaded = true;
    })();
    try {
      await this.gatewayStateLoading;
    } finally {
      this.gatewayStateLoading = null;
    }
  }

  async persistGatewayControl() {
    if (this.gatewayControl) await this.state.storage.put(GATEWAY_CONTROL_KEY, this.gatewayControl);
  }

  async persistGatewaySession() {
    await this.state.storage.put(GATEWAY_SESSION_KEY, {
      sessionID: this.sessionID,
      sequence: this.sequence,
      resumeURL: this.resumeURL
    });
  }

  async clearGatewaySession() {
    this.sequence = null;
    this.sessionID = null;
    this.resumeURL = null;
    await this.persistGatewaySession();
  }

  async resetGatewayState(reason) {
    const fingerprint = await tokenFingerprint(this.env.DISCORD_BOT_TOKEN);
    this.gatewayControl = gatewayControlDefaults(fingerprint);
    this.gatewayControl.lastCloseReason = safeText(reason, 160);
    this.gatewayStateLoaded = true;
    await this.clearGatewaySession();
    await this.persistGatewayControl();
  }

  async lockGateway(code, reason) {
    await this.loadGatewayState();
    this.gatewayControl.fatalCode = Number.parseInt(code, 10) || 4000;
    this.gatewayControl.fatalReason = safeText(reason, 160) || "fatal_gateway_error";
    this.gatewayControl.nextAttemptAt = 0;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    await this.clearGatewaySession();
    await this.persistGatewayControl();
    console.error("Discord gateway locked", JSON.stringify({
      code: this.gatewayControl.fatalCode,
      reason: this.gatewayControl.fatalReason
    }));
  }

  gatewayStatus() {
    const control = this.gatewayControl || gatewayControlDefaults("");
    return {
      configured: Boolean(this.env.DISCORD_BOT_TOKEN),
      server_live: Boolean(this.isServerLive()),
      socket_state: this.socket?.readyState ?? WebSocket.CLOSED,
      connecting: this.connecting,
      ready: this.ready,
      resumable_session: Boolean(this.sessionID && Number.isInteger(this.sequence) && this.resumeURL),
      connection_mode: this.connectionMode,
      attempts: control.attempts,
      next_attempt_at: control.nextAttemptAt,
      fatal_code: control.fatalCode,
      fatal_reason: control.fatalReason,
      identify_remaining: control.identifyRemaining,
      identify_reset_at: control.identifyResetAt,
      last_close_code: control.lastCloseCode,
      last_close_reason: control.lastCloseReason,
      last_identify_at: control.lastIdentifyAt,
      last_ready_at: control.lastReadyAt
    };
  }

  async ensureConnected() {
    if (!this.env.DISCORD_BOT_TOKEN || this.connecting || (this.socket && this.socket.readyState <= WebSocket.OPEN)) return;
    this.connecting = true;
    try {
      await this.loadGatewayState();
      if (!this.server) this.server = await this.state.storage.get("server");
      if (validDiscordID(this.server?.channelID)) this.watchedChannelID = this.server.channelID;
      if (!this.isServerLive()) return;
      if (this.gatewayControl.fatalCode) return;
      const now = Date.now();
      if (this.gatewayControl.nextAttemptAt > now) {
        this.armReconnect(this.gatewayControl.nextAttemptAt - now);
        return;
      }

      const canResumeSession = Boolean(this.sessionID && Number.isInteger(this.sequence) && this.resumeURL);
      let base = canResumeSession ? this.resumeURL : "";
      this.sessionStart = null;
      if (!canResumeSession) {
        const gatewayResponse = await fetch(`${DISCORD_API}/gateway/bot`, {
          headers: { authorization: `Bot ${this.env.DISCORD_BOT_TOKEN}` }
        });
        if (!gatewayResponse.ok) {
          if (gatewayResponse.status === 401 || gatewayResponse.status === 403) {
            await this.lockGateway(4004, `gateway_http_${gatewayResponse.status}`);
          } else {
            const retryAfter = Math.max(0, Number.parseFloat(gatewayResponse.headers.get("retry-after") || "0") * 1000);
            await this.scheduleReconnect(`gateway_http_${gatewayResponse.status}`, retryAfter);
          }
          return;
        }
        const gateway = await gatewayResponse.json();
        base = safeText(gateway.url, 256) || "wss://gateway.discord.gg";
        this.sessionStart = sessionStartState(gateway.session_start_limit, now);
        this.gatewayControl.identifyRemaining = this.sessionStart.remaining;
        this.gatewayControl.identifyResetAt = this.sessionStart.resetAt;
        await this.persistGatewayControl();
        if (!canIdentify(this.gatewayControl, now)) {
          this.gatewayControl.nextAttemptAt = this.gatewayControl.identifyResetAt;
          await this.persistGatewayControl();
          this.armReconnect(this.gatewayControl.nextAttemptAt - now);
          return;
        }
      }

      this.connectionMode = canResumeSession ? "resume" : "identify";
      const socket = new WebSocket(`${base}/?v=10&encoding=json`);
      socket.addEventListener("message", event => this.state.waitUntil(this.onMessage(event.data)));
      socket.addEventListener("close", event => this.state.waitUntil(this.onClosed(socket, event.code, event.reason)));
      socket.addEventListener("error", () => {
        if (socket.readyState < WebSocket.CLOSING) socket.close(1011, "Gateway error");
      });
      this.socket = socket;
    } catch (error) {
      console.error("Discord gateway connection failed", error);
      await this.scheduleReconnect("connection_exception");
    } finally {
      this.connecting = false;
    }
  }

  async onMessage(data) {
    if (typeof data !== "string") return;
    const packet = JSON.parse(data);
    if (Number.isInteger(packet.s)) this.sequence = packet.s;
    if (packet.op === 10) {
      this.startHeartbeat(Math.max(5000, Number(packet.d?.heartbeat_interval) || 41250));
      if (this.connectionMode === "resume" && this.sessionID && Number.isInteger(this.sequence)) {
        this.send({ op: 6, d: { token: this.env.DISCORD_BOT_TOKEN, session_id: this.sessionID, seq: this.sequence } });
      } else {
        await this.loadGatewayState();
        if (!canIdentify(this.gatewayControl)) {
          await this.disconnect(4000, "Identify allowance exhausted", true);
          this.armReconnect(Math.max(1000, this.gatewayControl.identifyResetAt - Date.now()));
          return;
        }
        if (this.gatewayControl.identifyRemaining >= 0) this.gatewayControl.identifyRemaining = Math.max(0, this.gatewayControl.identifyRemaining - 1);
        this.gatewayControl.lastIdentifyAt = Date.now();
        await this.persistGatewayControl();
        this.send({
          op: 2,
          d: {
            token: this.env.DISCORD_BOT_TOKEN,
            intents: GUILD_MEMBERS_INTENT | GUILD_MESSAGES_INTENT | MESSAGE_CONTENT_INTENT,
            properties: { os: "linux", browser: "darkrp-foundation", device: "darkrp-foundation" },
            presence: this.presencePayload()
          }
        });
      }
      return;
    }
    if (packet.op === 11) {
      this.heartbeatAcknowledged = true;
      if (this.sessionID && Number.isInteger(this.sequence)) await this.persistGatewaySession();
      return;
    }
    if (packet.op === 1) {
      this.send({ op: 1, d: this.sequence });
      return;
    }
    if (packet.op === 7) {
      await this.disconnect(4000, "Discord requested reconnect", true);
      await this.scheduleReconnect("gateway_reconnect", 1000);
      return;
    }
    if (packet.op === 9) {
      const resumable = packet.d === true && this.sessionID && Number.isInteger(this.sequence);
      if (!resumable) await this.clearGatewaySession();
      await this.disconnect(4000, "Discord invalid session", true);
      await this.scheduleReconnect("invalid_session", 1000 + Math.floor(randomUnit() * 4000));
      return;
    }
    if (packet.op !== 0) return;
    if (packet.t === "READY") {
      this.ready = true;
      this.sessionID = packet.d?.session_id || null;
      this.resumeURL = packet.d?.resume_gateway_url || null;
      this.gatewayControl.attempts = 0;
      this.gatewayControl.nextAttemptAt = 0;
      this.gatewayControl.lastReadyAt = Date.now();
      await this.persistGatewaySession();
      await this.persistGatewayControl();
      this.updatePresence();
    } else if (packet.t === "RESUMED") {
      this.ready = true;
      this.gatewayControl.attempts = 0;
      this.gatewayControl.nextAttemptAt = 0;
      this.gatewayControl.lastReadyAt = Date.now();
      await this.persistGatewaySession();
      await this.persistGatewayControl();
      this.updatePresence();
    } else if (packet.t === "INTERACTION_CREATE") {
      await this.handleInteraction(packet.d);
    } else if (packet.t === "GUILD_MEMBER_ADD") {
      await this.handleMemberJoin(packet.d);
    } else if (packet.t === "MESSAGE_CREATE") {
      this.handleDiscordMessage(packet.d);
    }
  }

  startHeartbeat(interval) {
    if (this.heartbeatTimer) clearTimeout(this.heartbeatTimer);
    this.heartbeatAcknowledged = true;
    const beat = () => {
      if (!this.isServerLive() || !this.socket || this.socket.readyState !== WebSocket.OPEN) return;
      if (!this.heartbeatAcknowledged) {
        this.socket.close(4000, "Heartbeat acknowledgement missed");
        return;
      }
      this.heartbeatAcknowledged = false;
      this.send({ op: 1, d: this.sequence });
      this.heartbeatTimer = setTimeout(beat, interval);
    };
    this.heartbeatTimer = setTimeout(beat, Math.floor(randomUnit() * interval));
  }

  presencePayload() {
    const server = this.server || { name: "DarkRP Foundation", map: "starting", players: 0, max: 64 };
    return {
      since: null,
      activities: [{
        name: `${server.players}/${server.max} players · ${server.map}`,
        state: server.name,
        type: 0
      }],
      status: "online",
      afk: false
    };
  }

  updatePresence() {
    if (this.ready) this.send({ op: 3, d: this.presencePayload() });
  }

  joinCardPayload(online) {
    const server = this.server || { name: "DarkRP Foundation", map: "Unavailable", players: 0, max: 64 };
    const status = online ? "🟢 ONLINE" : "🔴 OFFLINE";
    const description = online
      ? "A persistent roleplay sandbox built around player-driven systems and minimal admin intervention."
      : "The server is currently offline. This card will update automatically when it returns.";
    return {
      flags: 1 << 15,
      allowed_mentions: { parse: [] },
      components: [{
        type: 17,
        accent_color: online ? 0x43ddbc : 0xef667d,
        components: [
          {
            type: 10,
            content: `# JOIN DARKRP FOUNDATION\n${description}`
          },
          { type: 14, divider: true, spacing: 1 },
          {
            type: 10,
            content: `**Status**  ${status}\n**Players**  ${server.players} / ${server.max}\n**Map**  \`${escapeDiscord(server.map)}\`\n**Server**  ${escapeDiscord(server.name)}`
          },
          {
            type: 1,
            components: [{
              type: 2,
              style: 5,
              label: "Join DarkRP",
              emoji: { name: "🎮" },
              url: this.joinCard.joinURL
            }]
          },
          {
            type: 10,
            content: `-# Direct address: ${escapeDiscord(this.joinCard.serverAddress)} · Stats update automatically`
          }
        ]
      }]
    };
  }

  async syncJoinCard(force = false) {
    if (this.joinCardSyncing || !this.env.DISCORD_BOT_TOKEN) return { posted: false, error: "sync_busy" };
    this.joinCardSyncing = true;
    try {
      if (!this.joinCard) this.joinCard = await this.state.storage.get("joinCard");
      if (!this.joinCard || !validDiscordID(this.joinCard.channelID)) return { posted: false, error: "join_card_not_configured" };
      if (!this.server) this.server = await this.state.storage.get("server");
      const online = this.isServerLive();
      const signature = JSON.stringify({
        online,
        name: this.server?.name || "",
        map: this.server?.map || "",
        players: this.server?.players || 0,
        max: this.server?.max || 64,
        channelID: this.joinCard.channelID,
        joinURL: this.joinCard.joinURL
      });
      if (!force && signature === this.joinCard.signature) {
        return { posted: true, unchanged: true, message_id: this.joinCard.messageID };
      }

      const payload = this.joinCardPayload(online);
      const headers = {
        authorization: `Bot ${this.env.DISCORD_BOT_TOKEN}`,
        "content-type": "application/json"
      };
      let response;
      if (validDiscordID(this.joinCard.messageID)) {
        response = await fetch(`${DISCORD_API}/channels/${this.joinCard.channelID}/messages/${this.joinCard.messageID}`, {
          method: "PATCH",
          headers,
          body: JSON.stringify(payload)
        });
        if (response.status === 404) this.joinCard.messageID = "";
      }
      if (!validDiscordID(this.joinCard.messageID)) {
        response = await fetch(`${DISCORD_API}/channels/${this.joinCard.channelID}/messages`, {
          method: "POST",
          headers,
          body: JSON.stringify(payload)
        });
      }
      if (!response?.ok) {
        const detail = await response?.text().catch(() => "");
        console.error("Discord join card sync failed", response?.status, safeText(detail, 500));
        return { posted: false, error: `discord_http_${response?.status || 0}` };
      }
      const message = await response.json();
      this.joinCard.messageID = safeText(message.id, 22);
      this.joinCard.signature = signature;
      await this.state.storage.put("joinCard", this.joinCard);
      return { posted: true, message_id: this.joinCard.messageID, online };
    } finally {
      this.joinCardSyncing = false;
    }
  }

  async handleInteraction(interaction) {
    if (interaction?.type !== 2 || interaction.data?.name !== "link") return;
    const discordUser = interaction.member?.user || interaction.user || {};
    const rawCode = interaction.data?.options?.find(option => option.name === "code")?.value;
    const code = String(rawCode || "").trim().toUpperCase();
    let message = "That link code is invalid. Use /discordlink in Garry's Mod for a new code.";
    if (validLinkCode(code) && !this.claimedCodes.has(code)) {
      this.claimedCodes.add(code);
      try {
        const pendingRaw = await this.env.DRP_LINKS.get(`botcode:${code}`);
        if (pendingRaw) {
          const guildID = safeText(interaction.guild_id, 22);
          const roleResult = await grantDarkRPRole(this.env, guildID, safeText(discordUser.id, 22));
          const result = roleResult.ok
            ? await saveVerifiedLink(this.env, JSON.parse(pendingRaw), discordUser, true, guildID, roleResult.roleID)
            : roleResult;
          if (result.ok) await this.env.DRP_LINKS.delete(`botcode:${code}`);
          message = result.message;
        } else {
          message = "That link code is invalid or expired. Use /discordlink in Garry's Mod for a new code.";
        }
      } finally {
        this.claimedCodes.delete(code);
      }
    }
    const response = await fetch(`${DISCORD_API}/interactions/${interaction.id}/${interaction.token}/callback`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: 4, data: { content: message, flags: 64 } })
    });
    if (!response.ok) console.error("Discord interaction response failed", response.status);
  }

  async handleMemberJoin(member) {
    const discordID = safeText(member?.user?.id, 22);
    const guildID = safeText(member?.guild_id, 22);
    if (!validDiscordID(discordID) || member?.user?.bot) return;
    if (validDiscordID(this.env.DISCORD_GUILD_ID) && guildID !== this.env.DISCORD_GUILD_ID) return;
    const headers = {
      authorization: `Bot ${this.env.DISCORD_BOT_TOKEN}`,
      "content-type": "application/json"
    };
    const dmResponse = await fetch(`${DISCORD_API}/users/@me/channels`, {
      method: "POST",
      headers,
      body: JSON.stringify({ recipient_id: discordID })
    });
    if (!dmResponse.ok) return;
    const dm = await dmResponse.json();
    if (!validDiscordID(dm.id)) return;
    const response = await fetch(`${DISCORD_API}/channels/${dm.id}/messages`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        content: "Welcome to DarkRP Foundation. Return to Garry's Mod and use `/discordverify`. The game will copy your `/link code:XXXXXXXX` command and open the DarkRP channel for you.",
        allowed_mentions: { parse: [] }
      })
    });
    if (!response.ok) console.error("Discord verification welcome DM failed", response.status);
  }

  async drainChat() {
    if (this.chatDraining || !this.env.DISCORD_BOT_TOKEN) return;
    this.chatDraining = true;
    try {
      while (this.chatQueue.length > 0) {
        const entry = this.chatQueue[0];
        let content;
        if (entry.queue_kind === "player_join") {
          const discordIdentity = entry.discord_id
            ? `<@${entry.discord_id}>${entry.discord_name ? ` (${escapeDiscord(entry.discord_name)})` : ""}`
            : "Not linked";
          const population = `${entry.players}/${entry.max_players}`;
          content = `## Player joined the server\n**${escapeDiscord(entry.rp_name)}** has connected.\n\n**Steam:** ${escapeDiscord(entry.steam_name || entry.rp_name)} · \`${escapeDiscord(entry.steam_id)}\`\n**Discord:** ${discordIdentity}\n**Role:** ${escapeDiscord(entry.job || "Citizen")} · ${escapeDiscord(entry.rank || "user")} · Level ${entry.level}\n**Civic:** ${entry.civic >= 0 ? "+" : ""}${entry.civic} · **Trust:** ${entry.trust_score}/100 (${escapeDiscord(entry.trust_label || "Unknown")})\n**Online:** ${population}`;
        } else if (entry.queue_kind === "content_report") {
          const issueLabels = {
            required_pack: "Required Workshop pack is unavailable",
            invalid_model: "Missing or invalid model",
            missing_material: "Missing material or purple checker texture"
          };
          const contentNames = {
            "2910505837": "ARC9 Weapon Base",
            "2910537020": "ARC9 Gunsmith Reloaded",
            "1741741175": "Zero's Grow OP Content",
            "2486834214": "Zero's MethLab 2 Content",
            "2532060111": "zcLib Content",
            "1800764828": "Portal Gun",
            "1443497352": "Keys Content"
          };
          const macAppleDouble = entry.issue_kind === "required_pack" && entry.platform === "macOS";
          const recovery = macAppleDouble
            ? `1. Fully exit Garry's Mod.\n2. Open Steam's Workshop folder for item \`${escapeDiscord(entry.content_id)}\` and remove only files beginning with \`._\`.\n3. Relaunch, reconnect and run \`drp_content_repair\` if the asset is still unavailable.`
            : entry.issue_kind === "required_pack"
              ? "1. In game, run `drp_content_repair`.\n2. If it remains broken, fully exit Garry's Mod and allow Steam Workshop downloads to finish.\n3. Relaunch and reconnect. If still broken, verify Garry's Mod files and resubscribe to the affected Workshop item."
              : "1. Look at the broken entity and run `drp_content_status` in the client console.\n2. Fully exit Garry's Mod and allow Steam Workshop downloads to finish.\n3. Relaunch and reconnect. If unresolved, verify Garry's Mod files and resubscribe to the server collection.";
          const contentLine = entry.content_id ? `\n**Workshop item:** \`${escapeDiscord(entry.content_id)}\`` : "";
          const addonLine = entry.content_id && contentNames[entry.content_id]
            ? `\n**Addon:** ${escapeDiscord(contentNames[entry.content_id])}`
            : "";
          const classLine = entry.entity_class ? `\n**Entity:** \`${escapeDiscord(entry.entity_class)}\`` : "";
          content = `## Client content failure\n**Player:** ${escapeDiscord(entry.player_name)} · \`${escapeDiscord(entry.steam_id)}\` · \`${escapeDiscord(entry.steam_id64)}\`\n**Issue:** ${issueLabels[entry.issue_kind] || "Content failure"}${addonLine}${contentLine}${classLine}\n**Asset:** \`${escapeDiscord(entry.asset)}\`\n**Client:** ${escapeDiscord(entry.platform || "Unknown")} · ${escapeDiscord(entry.branch || "unknown")}\n\n### How the player can fix it\n${recovery}`;
        } else {
          const identity = entry.discord_id
            ? `<@${entry.discord_id}>${entry.discord_name ? ` (${escapeDiscord(entry.discord_name)})` : ""}`
            : "Not linked";
          content = `**${escapeDiscord(entry.rp_name)}** · \`${escapeDiscord(entry.steam_id)}\` · Discord: ${identity}\n${escapeDiscord(entry.message)}`;
        }
        const response = await fetch(`${DISCORD_API}/channels/${entry.channel_id}/messages`, {
          method: "POST",
          headers: {
            authorization: `Bot ${this.env.DISCORD_BOT_TOKEN}`,
            "content-type": "application/json"
          },
          body: JSON.stringify({
            content,
            allowed_mentions: { parse: [], users: [] }
          })
        });
        if (response.status === 429) {
          const limited = await response.json().catch(() => ({}));
          const waitMilliseconds = Math.max(250, Math.min(10000, Math.ceil(Number(limited.retry_after || 1) * 1000)));
          await new Promise(resolve => setTimeout(resolve, waitMilliseconds));
          continue;
        }
        if (!response.ok) {
          console.error("Discord global chat relay failed", response.status);
        }
        this.chatQueue.shift();
      }
    } finally {
      this.chatDraining = false;
      if (this.chatQueue.length > 0) this.state.waitUntil(this.drainChat());
    }
  }

  handleDiscordMessage(message) {
    if (!message || message.channel_id !== this.watchedChannelID || message.webhook_id || message.author?.bot) return;
    const content = safeText(message.content, 240).replace(/\s+/g, " ").trim();
    if (!content) return;
    this.inboundQueue.push({
      id: safeText(message.id, 22),
      channel_id: safeText(message.channel_id, 22),
      author_id: safeText(message.author?.id, 22),
      author_name: safeText(message.member?.nick || message.author?.global_name || message.author?.username, 64) || "Discord User",
      message: content
    });
    if (this.inboundQueue.length > 200) this.inboundQueue.shift();
  }

  send(packet) {
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify(packet));
  }

  async onClosed(socket, code, reason) {
    if (this.socket !== socket) return;
    this.socket = null;
    this.ready = false;
    if (this.heartbeatTimer) clearTimeout(this.heartbeatTimer);
    this.heartbeatTimer = null;
    await this.loadGatewayState();

    const normalizedCode = Number.parseInt(code, 10) || 1006;
    const normalizedReason = safeText(reason, 160) || "gateway_closed";
    this.gatewayControl.lastCloseCode = normalizedCode;
    this.gatewayControl.lastCloseReason = normalizedReason;
    const policy = gatewayClosePolicy(normalizedCode);
    if (policy.fatal) {
      await this.lockGateway(normalizedCode, normalizedReason);
      return;
    }
    if (policy.resumable) await this.persistGatewaySession();
    else await this.clearGatewaySession();
    await this.persistGatewayControl();
    await this.scheduleReconnect(`gateway_close_${normalizedCode}`);
  }

  armReconnect(delay) {
    if (!this.isServerLive() || this.gatewayControl?.fatalCode) return;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.state.waitUntil(this.ensureConnected());
    }, Math.max(250, Math.min(300000, Number(delay) || 0)));
  }

  async scheduleReconnect(reason, minimumDelay = 0) {
    await this.loadGatewayState();
    if (!this.isServerLive() || this.gatewayControl.fatalCode || this.reconnectTimer) return;
    this.gatewayControl.attempts = Math.min(12, Math.max(0, this.gatewayControl.attempts) + 1);
    const delay = Math.max(Number(minimumDelay) || 0, reconnectDelay(this.gatewayControl.attempts, randomUnit()));
    this.gatewayControl.nextAttemptAt = Date.now() + delay;
    this.gatewayControl.lastCloseReason = safeText(reason, 160) || this.gatewayControl.lastCloseReason;
    await this.persistGatewayControl();
    this.armReconnect(delay);
  }

  async disconnect(code, reason, preserveServer = false) {
    if (this.heartbeatTimer) clearTimeout(this.heartbeatTimer);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.heartbeatTimer = null;
    this.reconnectTimer = null;
    this.ready = false;
    if (!preserveServer) this.server = null;
    const socket = this.socket;
    this.socket = null;
    if (socket && socket.readyState < WebSocket.CLOSING) socket.close(code, reason);
  }
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (url.pathname.startsWith(ARCADE_PREFIX)) return serveArcade(request, url, env);
      if (request.method === "GET" && url.pathname === "/discord/start") return start(url, env);
      if (request.method === "GET" && url.pathname === "/discord/callback") return callback(url, env);
      if (request.method === "GET" && url.pathname === "/join") return joinPage(url);
      if (request.method === "GET" && url.pathname === "/loading") return loadingPage(url, env);
      if ((request.method === "GET" || request.method === "POST") && url.pathname === "/loading/profile") return loadingProfile(request, url, env);
      if (request.method === "GET" && url.pathname === "/discord/status") return status(request, url, env);
      if (request.method === "GET" && url.pathname === "/discord/member-status") return memberStatus(request, url, env);
      if (request.method === "GET" && url.pathname === "/discord/unlink") return unlink(request, url, env);
      if (request.method === "GET" && url.pathname === "/discord/bot/start") return botStart(request, url, env);
      if (request.method === "GET" && url.pathname === "/discord/bot/invite") return botInvite(request, url, env);
      if (request.method === "GET" && url.pathname === "/discord/bot/heartbeat") return botControl(request, url, env, "heartbeat");
      if (request.method === "GET" && url.pathname === "/discord/bot/offline") return botControl(request, url, env, "offline");
      if (request.method === "GET" && url.pathname === "/discord/bot/status") return botControl(request, url, env, "status");
      if (request.method === "POST" && url.pathname === "/discord/bot/reset") return botControl(request, url, env, "reset");
      if (request.method === "GET" && url.pathname === "/discord/bot/inbox") return botInbox(request, url, env);
      if (request.method === "POST" && url.pathname === "/discord/bot/register-command") return registerCommand(request, env);
      if (request.method === "POST" && url.pathname === "/discord/bot/chat") return botChat(request, env);
      if (request.method === "POST" && url.pathname === "/discord/bot/content-report") return botContentReport(request, env);
      if (request.method === "POST" && url.pathname === "/discord/bot/publish-join") return publishJoinCard(request, url, env);
      return json({ error: "not_found" }, 404);
    } catch (error) {
      console.error("Worker request failed", error);
      return json({ error: "internal_error" }, 500);
    }
  }
};
