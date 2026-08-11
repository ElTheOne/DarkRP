local motdSyncMessage = "drp_motd_sync_v1"
local motdUpdateMessage = "drp_motd_update_v1"
local motdUpdateResultMessage = "drp_motd_update_result_v1"
local xpOverviewRequestMessage = "drp_xp_overview_request_v1"
local xpOverviewMessage = "drp_xp_overview_v1"
local xpActionMessage = "drp_xp_action_v1"

DRP.MOTD = DRP.MOTD or { enabled = false, title = "Server MOTD", html = "", updated = -1 }
local motdShownVersion = -1
local motdNeedsAutoShow = true
local motdAutoShowQueued = false
local motdPendingBackup
local nextF4Toggle = 0
local xpOverview = nil
local xpHUDSnapshot = nil
local xpRequestQueued = false
local xpOverviewRequestedAt = 0
local xpHUDFallbackStartedAt = 0
local xpMenuPageState = { open = false, frame = nil, page = nil }
local f4PressedState = {
	[KEY_F4] = false,
	[KEY_I] = false
}

local function clampXP(value, minValue, maxValue)
	value = math.floor(tonumber(value) or 0)
	if minValue and value < minValue then return minValue end
	if maxValue and value > maxValue then return maxValue end
	return value
end

local function xpForLevel(level)
	level = clampXP(level, 1, 100)
	local total = 0
	for current = 1, level - 1 do
		total = total + math.max(1, math.ceil(110 * (1.07 ^ (current - 1))))
	end
	return total
end

local function xpNeededForNext(level)
	level = clampXP(level, 1, 100)
	if level >= 100 then return 0 end
	return math.max(1, math.ceil(110 * (1.07 ^ (level - 1))))
end

local function buildXPFallbackSnapshot()
	local profile = DRP.ClientProfile or {}
	local level = clampXP(profile.level or 1, 1, 100)
	local xp = clampXP(profile.xp or 0, 0)
	local needed = xpNeededForNext(level)
	return {
		level = level,
		xp = xp,
		xp_to_next = needed,
		remaining = needed > 0 and math.max(0, needed - xp) or 0,
		progress = needed > 0 and math.Clamp(math.max(0, xp) / needed, 0, 1) or 1,
		next_rank = math.min(100, level + 1),
		prestige = profile.prestige or 0,
		tokens = profile.prestigeTokens or 0,
		history = {},
		next_unlocks = {},
		unlocked = {},
		can_prestige = false,
		max_level = 100,
		max_prestige = 10,
		maxed = (profile.prestige or 0) >= 10 and level >= 100,
		version = 2,
		sync = os.time(),
		_syncReason = "local_profile_fallback"
	}
end

local nextDoorRequest = 0

local function requestDoor()
	local now = RealTime()
	if now < nextDoorRequest then return end
	nextDoorRequest = now + 0.2
	net.Start("drp_door_request_v2")
	net.SendToServer()
end

local function controlDown()
	return input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL)
end

local f4Menu
local f4MenuSerial = 0

local function boundKey(command, fallback)
	local key = input.LookupBinding(command, true)
	if not key or key == "" then return fallback end
	return string.upper(key)
end

local function addPageHeading(parent, titleText, description)
	local title = vgui.Create("DLabel", parent)
	title:Dock(TOP)
	title:DockMargin(18, 15, 18, 0)
	title:SetTall(30)
	title:SetFont("DRP.Admin.Header")
	title:SetTextColor(color_white)
	title:SetText(titleText)
	title.PaintOver = function(_, width, height)
		draw.RoundedBox(3, 0, 5, 4, height - 10, DRP.UI.Colors.accent)
	end

	local hint = vgui.Create("DLabel", parent)
	hint:Dock(TOP)
	hint:DockMargin(18, 0, 18, 14)
	hint:SetTall(22)
	hint:SetFont("DRP.Admin.Small")
	hint:SetTextColor(DRP.UI.Colors.muted)
	hint:SetText(description)
end

local function stylePageScroll(scroll)
	local bar = scroll:GetVBar()
	bar:SetWide(7)
	bar.Paint = function() end
	bar.btnUp.Paint = function() end
	bar.btnDown.Paint = function() end
	bar.btnGrip.Paint = function(_, width, height)
		draw.RoundedBox(4, 1, 0, width - 2, height, DRP.UI.Colors.line)
	end
end

local function addReferenceRow(parent, titleText, detail, accentColor, actionText, action, detail2, detail3)
	local colors = DRP.UI.Colors
	local row = vgui.Create(action and "DButton" or "DPanel", parent)
	row:Dock(TOP)
	row:DockMargin(0, 0, 0, 8)
	row:SetTall(detail3 and 108 or (detail2 and 90 or 72))
	if action then row:SetText("") end
	row.Paint = function(self, width, height)
		local hovered = action and self:IsHovered()
		draw.RoundedBox(7, 0, 0, width, height, hovered and colors.panelHover or colors.background)
		draw.RoundedBoxEx(7, 0, 0, 5, height, accentColor or colors.accent, true, false, true, false)
		draw.RoundedBox(7, 5, 0, width - 5, 2, Color(255, 255, 255, hovered and 24 or 10))
		draw.SimpleText(titleText, "DRP.Admin.Body", 18, 22, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(detail, "DRP.Admin.Small", 18, 48, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		if detail2 then draw.SimpleText(detail2, "DRP.Admin.Small", 18, 68, colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
		if detail3 then draw.SimpleText(detail3, "DRP.Admin.Small", 18, 89, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
		if actionText then draw.SimpleText(actionText, "DRP.Admin.Small", width - 18, height * 0.5, colors.accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER) end
	end
	if action then row.DoClick = action end
	return row
end

local function escapeMOTDHTML(text)
	text = tostring(text or "")
	text = string.gsub(text, "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	text = string.gsub(text, ">", "&gt;")
	text = string.gsub(text, "\"", "&quot;")
	return text
end

local function normalizeMOTDBody(raw)
	raw = tostring(raw or "")
	if string.Trim(raw) == "" then return "<p>This server has not set a custom MOTD yet. Use the F4 menu MOTD page to set a welcome message.</p>" end
	if not string.match(raw, "<[^>]+>") then
		return "<p>" .. string.Replace(escapeMOTDHTML(raw), "\n", "<br/>") .. "</p>"
	end
	return raw
end

local function buildMOTDHTML(title, html)
	title = string.Trim(tostring(title or "Server MOTD"))
	if title == "" then title = "Server MOTD" end
	html = normalizeMOTDBody(html)
	return "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'>"
		.. "<style>html,body{margin:0;padding:0;background:#0d1220;color:#eaf2ff;font-family:Inter,Arial,Helvetica,sans-serif;line-height:1.5;font-size:15px;}"
		.. "body{padding:14px;} .container{max-width:900px;margin:0 auto;} h1{font-size:30px;letter-spacing:0.4px;color:#7dd3ff;margin:0 0 14px 0;font-weight:700;text-shadow:0 2px 22px rgba(62,175,255,0.25);}"
		.. "h2,h3{margin:0;color:#9dd9ff;} h2{font-size:23px;} h3{font-size:18px;} a{color:#8de2ff;} p,li{color:#d9e7ff;}"
		.. ".hero{background:linear-gradient(135deg,#13213a,#0b1730);padding:16px 18px;border:1px solid #2e4968;border-radius:12px;box-shadow:0 8px 24px rgba(5,14,28,.45);margin-bottom:14px;}"
		.. ".hero p{margin-top:8px;margin-bottom:10px;} .chipline{display:flex;flex-wrap:wrap;gap:8px;} .chipline span{display:inline-block;background:rgba(98,207,255,.13);color:#cceaff;border:1px solid rgba(98,207,255,.35);padding:4px 10px;border-radius:999px;font-size:12px;}"
		.. ".panel{background:#101c31;border:1px solid #2a3e5d;border-radius:12px;padding:14px 16px;margin-bottom:14px;} .panel.callout{border-color:#2c5f7f;background:linear-gradient(90deg,rgba(41,93,124,.3),rgba(17,29,49,.8));}"
		.. "ul{padding:0 0 0 19px;margin:10px 0 0 0;} li{margin:7px 0;} li:before{content:'•';color:#89d6ff;margin-right:8px;}"
		.. "code{padding:2px 7px;border-radius:6px;background:#0b172d;color:#9de5ff;} p{margin:8px 0;}</style></head><body><div class='container'><h1>"
		.. escapeMOTDHTML(title) .. "</h1>" .. (html == "" and "<p>No message content.</p>" or html) .. "</div></body></html>"
end

local function buildGuideHTML()
	return [[<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#08101d;--panel:#101c31;--panel2:#14243d;--line:#29415f;--cyan:#4acdff;--cyan2:#8cf0ff;--green:#6cee97;--amber:#ffbe61;--red:#ff647d;--text:#edf6ff;--muted:#a8b9cf}
*{box-sizing:border-box}html,body{margin:0;min-height:100%;background:radial-gradient(circle at 78% -15%,#173a5d 0,transparent 35%),linear-gradient(145deg,#0b1424,#070d18 70%);color:var(--text);font-family:Arial,Helvetica,sans-serif;line-height:1.55}
body{padding:18px}.shell{max-width:980px;margin:auto}.hero{position:relative;overflow:hidden;padding:24px;border:1px solid #315272;border-radius:16px;background:linear-gradient(125deg,rgba(25,55,88,.96),rgba(10,22,40,.96));box-shadow:0 16px 45px rgba(0,0,0,.35)}
.hero:after{content:"";position:absolute;width:260px;height:260px;right:-95px;top:-145px;border-radius:50%;background:rgba(74,205,255,.15);box-shadow:0 0 80px rgba(74,205,255,.25)}
.eyebrow{color:var(--cyan2);font-size:11px;font-weight:800;letter-spacing:2.4px;text-transform:uppercase}.hero h1{margin:5px 0 5px;font-size:29px;line-height:1.15}.hero p{max-width:720px;margin:0;color:#c4d5e8}.chips{display:flex;gap:7px;flex-wrap:wrap;margin-top:14px}.chip{padding:4px 10px;border:1px solid rgba(74,205,255,.32);border-radius:999px;background:rgba(74,205,255,.09);color:#c9f4ff;font-size:11px;font-weight:700}
.nav{position:sticky;top:0;z-index:5;display:flex;gap:7px;flex-wrap:wrap;margin:13px 0;padding:10px;border:1px solid var(--line);border-radius:13px;background:rgba(8,16,29,.94);box-shadow:0 8px 22px rgba(0,0,0,.28)}
.nav button,.pager button{border:1px solid #2b4969;border-radius:8px;background:#111f34;color:var(--muted);padding:8px 11px;font-weight:700;font-size:12px;cursor:pointer;transition:.15s}.nav button:hover,.nav button.active,.pager button:hover{color:#07111f;background:var(--cyan);border-color:var(--cyan);box-shadow:0 0 18px rgba(74,205,255,.25)}
.section{display:none;animation:rise .18s ease}.section.active{display:block}@keyframes rise{from{opacity:.35;transform:translateY(4px)}to{opacity:1;transform:none}}
.sectionHead{display:flex;align-items:flex-end;justify-content:space-between;padding:15px 2px 10px;border-bottom:1px solid var(--line)}.sectionHead h2{margin:0;font-size:22px}.sectionHead span{color:var(--cyan);font-size:11px;font-weight:800;letter-spacing:1.5px}
.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:11px;margin-top:11px}.card{padding:15px;border:1px solid var(--line);border-radius:12px;background:linear-gradient(145deg,rgba(17,31,52,.98),rgba(11,21,37,.98));box-shadow:0 8px 24px rgba(0,0,0,.2)}.card.wide{grid-column:1/-1}.card h3{margin:0 0 7px;color:var(--cyan2);font-size:16px}.card p{margin:0;color:#c8d6e7;font-size:13px}.card ul{margin:8px 0 0;padding-left:18px;color:#c8d6e7;font-size:13px}.card li{margin:5px 0}.tag{display:inline-block;margin-bottom:8px;padding:2px 7px;border-radius:5px;background:rgba(108,238,151,.12);color:var(--green);font-size:10px;font-weight:800;letter-spacing:1px}.tag.warn{background:rgba(255,190,97,.12);color:var(--amber)}.tag.danger{background:rgba(255,100,125,.12);color:var(--red)}
.flow{display:flex;align-items:stretch;gap:7px;margin-top:10px}.step{flex:1;padding:10px;border-radius:9px;background:#0b1729;border:1px solid #263d59;color:#c9d8e9;font-size:12px}.arrow{align-self:center;color:var(--cyan);font-weight:bold}.why{border-left:4px solid var(--cyan);background:linear-gradient(90deg,rgba(74,205,255,.14),rgba(16,28,49,.85))}.key{display:inline-block;min-width:29px;padding:2px 7px;border:1px solid #3a5877;border-bottom-width:3px;border-radius:6px;background:#17263c;color:white;text-align:center;font-size:11px;font-weight:800}.pager{display:flex;justify-content:space-between;margin:14px 0 4px}.footer{padding:13px 4px 2px;color:#8193ab;text-align:center;font-size:11px}
@media(max-width:560px){body{padding:10px}.grid{grid-template-columns:1fr}.card.wide{grid-column:auto}.flow{display:block}.arrow{text-align:center;padding:3px}.hero{padding:18px}.hero h1{font-size:24px}}
</style>
</head>
<body>
<div class="shell">
 <div class="hero"><div class="eyebrow">DarkRP Foundation · Player Field Guide</div><h1>Roleplay through systems, not arguments.</h1><p>This server uses incidents, permissions and visible evidence to decide what players may do. Learn the signals below and the gamemode will explain every confrontation as it unfolds.</p><div class="chips"><span class="chip">SAFE BY DEFAULT</span><span class="chip">SERVER-OWNED INCIDENTS</span><span class="chip">PERSISTENT PROGRESSION</span><span class="chip">MINIMAL ADMIN INTERVENTION</span></div></div>
 <div class="nav" id="nav">
  <button data-page="overview">Start Here</button><button data-page="objectives">Objectives</button><button data-page="incidents">Incidents & PvP</button><button data-page="police">Police</button><button data-page="crime">Crime</button><button data-page="property">Property & Raids</button><button data-page="economy">Jobs & Economy</button><button data-page="items">Items & Drugs</button><button data-page="progression">Progression</button><button data-page="controls">Controls</button>
 </div>

 <section class="section" id="overview"><div class="sectionHead"><h2>Start here</h2><span>01 · FOUNDATION</span></div><div class="grid">
  <div class="card wide why"><span class="tag">THE WHY INTERFACE</span><h3>If an action is allowed or denied, the server tells you why.</h3><p>The panel on your HUD shows the active incident, participants, evidence, allowed actions and remaining time. Read it before fighting, arresting, raiding or taking property. A denied action is blocked by the server—it is not an invitation to keep trying.</p></div>
  <div class="card"><h3>Safe by default</h3><p>Players cannot normally damage one another. PvP exists only when an incident grants a specific direction of damage, or when both players accept permanent mutual PvP in Settings.</p></div>
  <div class="card"><h3>No arbitrary roleplay rules</h3><p>Roleplay conflicts are resolved by mechanics: ownership, witnessed offences, declared incidents, evidence and deterministic outcomes. Staff handle abuse and technical misconduct, not ordinary RP outcomes.</p></div>
  <div class="card wide"><h3>The basic loop</h3><div class="flow"><div class="step"><b>1. Establish an identity</b><br>Your civic standing and actions determine your role.</div><div class="arrow">→</div><div class="step"><b>2. Build a life</b><br>Earn, own, trade and cooperate.</div><div class="arrow">→</div><div class="step"><b>3. Enter incidents</b><br>Respond using granted actions.</div><div class="arrow">→</div><div class="step"><b>4. Progress</b><br>Gain XP and civic reputation.</div></div></div>
 </div></section>

 <section class="section" id="objectives"><div class="sectionHead"><h2>Contextual objectives</h2><span>OPTIONAL · SERVER GENERATED</span></div><div class="grid">
  <div class="card wide why"><span class="tag">YOUR NEXT MOVE</span><h3>The server teaches new players through automatic, outcome-driven objectives.</h3><p>Beginner steps are pinned automatically and cover property, identity, Hands, mugging, healing and role pathways. Afterwards, open F4 → Objectives to accept optional activities generated for your role and the current population.</p></div>
  <div class="card wide">{{BEGINNER_PROGRESS}}</div>
  <div class="card"><h3>Learn by playing</h3><p>Your first objective teaches you to purchase a property. Once established and no longer a Hobo, the next objective sends you to the police-station Councilman to register a name and appearance.</p></div>
  <div class="card"><h3>Role-specific direction</h3><p>Police investigate and book suspects, medics answer calls, criminals resolve structured incidents, merchants deliver orders, owners maintain property and Mayors fund public service.</p></div>
  <div class="card"><h3>Authoritative completion</h3><p>Progress comes from completed server events and incident outcomes—not client claims. Rewards are issued immediately and appear in your XP history.</p></div>
  <div class="card"><h3>Hints never take control</h3><p>Timed hints explain mechanics without buttons or forced responses. Press F3 or Z whenever a HUD interface needs a cursor, then press it again to return to movement.</p></div>
  <div class="card"><h3>Population aware</h3><p>Objectives that require another player are withheld when the city is too quiet. Solo-compatible activities remain available to create direction at low population.</p></div>
 </div></section>

 <section class="section" id="incidents"><div class="sectionHead"><h2>Incidents and PvP</h2><span>02 · PERMISSION ENGINE</span></div><div class="grid">
  <div class="card wide"><span class="tag">SERVER AUTHORITY</span><h3>Every confrontation is a record</h3><p>An incident stores the instigator, victim, other participants, reason, evidence, deadline, current state and final outcome. Damage, arrest, search, property entry and money-taking permissions come from this record.</p></div>
  <div class="card"><h3>One-way means one-way</h3><p>Some situations initially let only one side attack. Nearby members of the same job or agenda team join the same incident and inherit that direction; they do not create duplicate incidents. The HUD states the exact permission.</p></div>
  <div class="card"><h3>Escalation</h3><p>Movement, weapon changes, gunfire, missed deadlines or other witnessed events can deterministically change an incident. Once escalated, previous evidence remains valid.</p></div>
  <div class="card"><h3>Resolution</h3><p>Payment, arrest, death, raid victory, surrender, expiry or invalid participants can end an incident. The outcome creates an audit receipt and drives XP and civic standing.</p></div>
  <div class="card"><h3>Permanent mutual PvP</h3><p>F4 → Settings lets you request always-on PvP with a named player. It activates only after acceptance and either player may disable it later.</p></div>
 </div></section>

 <section class="section" id="police"><div class="sectionHead"><h2>Police and justice</h2><span>03 · NON-LETHAL FIRST</span></div><div class="grid">
  <div class="card wide"><span class="tag warn">WITNESSED FIREARM</span><h3>Seeing an unlicensed civilian weapon starts a police incident.</h3><div class="flow"><div class="step">Officer directly sees firearm</div><div class="arrow">→</div><div class="step">Taser, cuffs, search and arrest become available</div><div class="arrow">→</div><div class="step">Taser attempt gives suspect one-way retaliation</div><div class="arrow">→</div><div class="step">Suspect fires: PvP becomes mutual</div></div></div>
  <div class="card"><h3>Taser</h3><p>Use non-lethal force against an incident-authorized suspect. A sighting alone does not authorize police gunfire.</p></div>
  <div class="card"><h3>Handcuffs and escort</h3><p>Cuff an authorized suspect, toggle escort with secondary fire, then physically bring them to the Jailer. The Jailer completes the arrest.</p></div>
  <div class="card"><h3>Evidence</h3><p>Dropped or seized items can be stored in the evidence locker. Police actions and incident evidence create an auditable chain rather than relying on conflicting stories.</p></div>
  <div class="card"><h3>Lockdowns</h3><p>Lockdowns are public incidents. Citizens without shelter receive a grace period before police gain arrest authority. Resistance can escalate permissions.</p></div>
 </div></section>

 <section class="section" id="crime"><div class="sectionHead"><h2>Crime systems</h2><span>04 · RISK AND RESPONSE</span></div><div class="grid">
  <div class="card wide"><span class="tag danger">MUGGING</span><h3>A victim must be standing still when the demand begins.</h3><ul><li>As a mugging-capable role, aim at a player and tap <span class="key">M</span>.</li><li>Hold <span class="key">M</span> for three seconds to choose and issue a demand up to $5,000.</li><li>The victim has ten seconds to pay through the demand panel. They may decide later and reopen it from the HUD with free cursor mode.</li><li>The victim may initially damage the mugger. Movement, weapon changes, firing or missing the deadline enables mutual PvP.</li></ul></div>
  <div class="card"><h3>Becoming a Hitman</h3><p>Reach −325 civic directly, or reach −200 civic and take authenticated ePhone photographs of three different people you personally killed during legitimate incidents. Once qualified, private hit contracts become available.</p></div>
  <div class="card"><h3>Armory and treasury raids</h3><p>Raiders may declare an armory raid for weapon crates or hold the Treasury Vault for reserved public cash. Both use server-owned participants, countdowns, PvP permissions and outcomes.</p></div>
  <div class="card"><h3>Civic consequences</h3><p>Mugging, murder, forced drugging, criminal raids and hits reduce civic standing. The result is visible in your HUD and scoreboard reputation.</p></div>
  <div class="card"><h3>Criminal organizations</h3><p>Gangsters and the Mob Boss coordinate criminal roleplay, while thieves specialize in mugging and raiding permissions. A role never bypasses incident requirements.</p></div>
 </div></section>

 <section class="section" id="property"><div class="sectionHead"><h2>Property and raids</h2><span>05 · OWNERSHIP</span></div><div class="grid">
  <div class="card"><h3>Buying property</h3><p>Look at a grouped door and press <span class="key">F</span> to purchase the complete property. Buildings marked not buyable cannot be purchased and show no purchase prompt.</p></div>
  <div class="card"><h3>Scheduled lease</h3><p>Ownership persists across reconnects and restarts while the daily base lease remains funded. Open F4 → Properties to deposit up to three days in advance. Funding never blocks a declared raid.</p></div>
  <div class="card"><h3>Access and tenancy</h3><p>Owners manage co-owners, tenants, roles, scheduled rent, refundable deposits and eviction notices from the property panel. Anyone may open an unlocked door; ownership controls locking and management.</p></div>
  <div class="card"><h3>Persistent shared vault</h3><p>Authorized members can move Hands items into the base vault. Vault contents persist independently of player death, reconnects and clean restarts, and vault access is locked while the property is under raid.</p></div>
  <div class="card"><h3>Keys</h3><p>Use the Keys weapon to lock or unlock doors you control, including supported job doors. Every linked door retains the complete property’s ownership and access rules.</p></div>
  <div class="card wide"><span class="tag danger">DECLARED RAIDS ONLY</span><h3>Base destruction is scoped to the raid.</h3><p>A raid has declared attackers, defenders, target property, duration, cooldown and victory conditions. Only participants can damage relevant defences. Breached doors temporarily disappear, then the original map door returns with its ID and property group intact.</p></div>
 </div></section>

 <section class="section" id="economy"><div class="sectionHead"><h2>Jobs and economy</h2><span>06 · PLAYER-DRIVEN CITY</span></div><div class="grid">
  <div class="card"><h3>Roles are earned identities</h3><p>Civic standing establishes the criminal ladder while healing, weapon commerce, drug production, raids and force-drugging create specialist identities. Only eligible government service is selected directly.</p></div>
  <div class="card"><h3>Persistent wallet</h3><p>Money, progression and Hands are stored across reconnects and clean restarts. Prop spawning costs money based on size and configured model pricing.</p></div>
  <div class="card"><h3>Mayor</h3><p>Players apply and vote for Mayor. Confidence polls occur during the term. Ties favor the earliest valid candidate; the Mayor can see confidence results but cannot vote in them.</p></div>
  <div class="card"><h3>Tax and treasury</h3><p>Salary tax enters the treasury. The Mayor reallocates funds to job salaries—never directly to an individual—and may fund lotteries. A job bonus is capped at 50%.</p></div>
  <div class="card wide"><h3>Specialized roles</h3><p><b>Medic</b> earns civic credit for genuine aid. <b>Gun and drug dealers</b> supply job entities. <b>Hobos</b> use tip jars. <b>Police</b> enforce incident-backed law. <b>Thieves, gangsters, mob bosses and hitmen</b> create structured criminal conflict.</p></div>
 </div></section>

 <section class="section" id="items"><div class="sectionHead"><h2>Items, Hands and drugs</h2><span>07 · INVENTORY</span></div><div class="grid">
  <div class="card"><h3>Hands</h3><p>Use the Hands weapon to carry supported dropped items. Secondary fire opens the 6 × 10 grid; arrange, rotate, equip, drop or consume items there. Protected tools, keys and required job equipment cannot be dropped.</p></div>
  <div class="card"><h3>Force-feeding</h3><p>Select a drug in Hands, then hold <span class="key">E</span> on a stationary player for three seconds while both players remain still and in sight. The victim receives self-defence authority immediately. The offender becomes wanted only when a police officer witnesses the act through the visibility system.</p></div>
  <div class="card"><h3>Enhancers</h3><ul><li><b>Heroin:</b> extreme damage resistance, followed by damaging withdrawal.</li><li><b>Speed:</b> faster sprinting, then severe movement withdrawal.</li><li><b>PCP:</b> temporary increased jump height.</li><li><b>Crack:</b> greater outgoing damage, followed by poor accuracy.</li></ul></div>
  <div class="card"><h3>Disruptors</h3><ul><li><b>Weed:</b> visual effects without a mechanical boost.</li><li><b>Fentanyl:</b> incapacitation, heavy blur and forced folded posture.</li><li>Withdrawal effects are removed on death.</li></ul></div>
 </div></section>

 <section class="section" id="progression"><div class="sectionHead"><h2>Progression and reputation</h2><span>08 · LONG-TERM PLAY</span></div><div class="grid">
  <div class="card"><h3>Incident XP</h3><p>Resolved incidents reward both sides according to the explicit outcome. Victim victories generally pay more than suspect victories, while participation still receives recognition.</p></div>
  <div class="card"><h3>Active play</h3><p>Active players receive 50 XP for each ten minutes of genuine activity. AFK time does not count.</p></div>
  <div class="card"><h3>Levels</h3><p>XP requirements grow by 7% each level. The Experience page shows progress, recent sources and upcoming unlocks through level 100.</p></div>
  <div class="card"><h3>Prestige</h3><p>At level 100, prestige resets level unlocks and grants one token. A token permanently unlocks one eligible individual weapon for free. There are ten prestige ranks; reaching level 100 during Prestige 10 completes Maximum Prestige.</p></div>
  <div class="card wide"><h3>Civic standing</h3><p>Civic standing is separate from XP. Arrests and healing can improve it; mugging, murder, criminal victories and forced drugging reduce it. It describes your public relationship with the city, not your staff rank.</p></div>
  <div class="card wide"><h3>Trust score</h3><p>The public scoreboard combines server history with available Steam, network and optional Discord identity signals. Unknown or private information is neutral. Trust is an investigative indicator—not proof, punishment or permission to harass another player. Use <b>/trust</b> to inspect your own calculation.</p></div>
 </div></section>

 <section class="section" id="controls"><div class="sectionHead"><h2>Essential controls</h2><span>09 · QUICK REFERENCE</span></div><div class="grid">
  <div class="card"><h3>Menus</h3><ul><li><span class="key">F4</span> or <span class="key">I</span> DarkRP menu</li><li><span class="key">Q</span> themed spawn and prop browser</li><li><span class="key">Y</span> local chat</li><li><span class="key">U</span> team chat</li></ul></div>
  <div class="card"><h3>Identity and items</h3><ul><li><b>Councilman</b> register your first RP name and appearance</li><li><b>/rpname name</b> update a registered RP name</li><li><b>/jobname title</b> customize job title</li><li><b>/drop</b> drop eligible held weapon</li><li><b>/dropmoney amount</b> drop cash</li></ul></div>
  <div class="card"><h3>Doors and crime</h3><ul><li><span class="key">F</span> buy or sell aimed door</li><li>Keys weapon locks/unlocks controlled doors</li><li><span class="key">M</span> mug; hold to configure amount</li></ul></div>
  <div class="card"><h3>Chat categories</h3><p>The chatbox separates Local, Team and Global. Left-click a category to view only it; right-click toggles it as a filter. Use Up/Down to recall sent messages and right-click any message to copy its text, sender or complete line. New messages follow the bottom unless you are reading earlier chat.</p></div>
  <div class="card"><h3>Local voice</h3><p>Voice chat is proximity-based and uses positional attenuation. Move closer for a clearer conversation; players beyond the configured local range cannot hear you. Dead and living voice are isolated.</p></div>
  <div class="card wide why"><h3>Still unsure?</h3><p>Open the Commands and Keybinds pages beside this Guide. During a confrontation, trust the live <b>WHY?</b> panel over memory: it reflects the current server-owned incident and permissions.</p></div>
 </div></section>

 <div class="pager"><button id="previous">← Previous section</button><button id="next">Next section →</button></div><div class="footer">This guide describes enforced mechanics. Live incident state always takes priority.</div>
</div>
<script>
(function(){var pages=['overview','objectives','incidents','police','crime','property','economy','items','progression','controls'],current=0;
function show(id){var found=pages.indexOf(id);if(found<0)return;current=found;document.querySelectorAll('.section').forEach(function(el){el.classList.toggle('active',el.id===id)});document.querySelectorAll('.nav button').forEach(function(el){el.classList.toggle('active',el.getAttribute('data-page')===id)});window.scrollTo(0,0)}
document.querySelectorAll('.nav button').forEach(function(el){el.addEventListener('click',function(){show(el.getAttribute('data-page'))})});
document.getElementById('previous').addEventListener('click',function(){show(pages[(current+pages.length-1)%pages.length])});document.getElementById('next').addEventListener('click',function(){show(pages[(current+1)%pages.length])});show('overview');})();
</script>
</body>
</html>]]
end

local function openMOTDPanel(joinWelcome)
	if not DRP.MOTD.enabled or DRP.MOTD.html == "" then
		if DRP.MOTD.enabled and DRP.MOTD.html == "" then
			DRP.MOTD.html = "<p>This server has no Message of the Day content yet.</p>"
		else
			return
		end
	end

	if IsValid(DRP.MOTD.Frame) then DRP.MOTD.Frame:Close() end
	local frame = DRP.UI.Frame(DRP.MOTD.title or "Server MOTD", math.min(ScrW() - 60, 980), math.min(ScrH() - 60, 760))
	DRP.MOTD.Frame = frame
	frame:SetDeleteOnClose(true)
	if joinWelcome then
		local previousRemove = frame.OnRemove
		frame.OnRemove = function(...)
			if previousRemove then previousRemove(...) end
			hook.Run("DRPWelcomePanelClosed", "motd")
		end
	end

	local html = vgui.Create("DHTML", frame)
	html:SetPos(12, 62)
	html:SetSize(frame:GetWide() - 24, frame:GetTall() - 112)
	html:SetHTML(buildMOTDHTML(DRP.MOTD.title, DRP.MOTD.html))

	local close = DRP.UI.Button(frame, "START PLAYING", DRP.UI.Colors.green, function()
		if IsValid(frame) then frame:Close() end
	end)
	close:SetPos(22, frame:GetTall() - 40)
	close:SetSize(frame:GetWide() - 44, 34)
	motdShownVersion = DRP.MOTD.updated or os.time()
end

local function requestXPOverview()
	if (util.NetworkStringToID(xpOverviewRequestMessage) or 0) <= 0 then
		xpRequestQueued = true
		if not timer.Exists("DRP.XPRequestRetry") then
			timer.Create("DRP.XPRequestRetry", 1.0, 1, function()
				xpRequestQueued = false
				requestXPOverview()
			end)
		end
		return
	end

	if (RealTime() - xpOverviewRequestedAt) < 0.75 then return end
	if timer.Exists("DRP.XPRequestRetry") then
		timer.Remove("DRP.XPRequestRetry")
		xpRequestQueued = false
	end
	xpOverviewRequestedAt = RealTime()
	if xpOverviewRequestedAt > 0 then xpHUDFallbackStartedAt = xpOverviewRequestedAt end

	net.Start(xpOverviewRequestMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.SendToServer()
end

local function sendXPAction(action, key)
	net.Start(xpActionMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.Clamp(action, 0, 15), 4)
	if action == 1 then net.WriteString(string.sub(key or "", 1, 512)) end
	net.SendToServer()
end

local function queueMOTDOpen()
	if not DRP.MOTD or not DRP.MOTD.enabled then return end
	if motdAutoShowQueued then return end
	motdAutoShowQueued = true

	local attemptsLeft = 12
	local function attemptOpen()
		attemptsLeft = attemptsLeft - 1
		if not IsValid(LocalPlayer()) then
			if attemptsLeft > 0 then
				timer.Simple(0.2, attemptOpen)
			else
				motdAutoShowQueued = false
			end
			return
		end

		motdAutoShowQueued = false
		openMOTDPanel(true)
	end
	attemptOpen()
end

net.Receive(xpOverviewMessage, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local raw = net.ReadString()
	local data = util.JSONToTable(raw or "")
	if not istable(data) then data = {} end
	xpOverview = data
	DRP.ClientXPOverview = data
	hook.Run("DRPXPOverviewUpdated", data)
	xpHUDSnapshot = data
	xpHUDFallbackStartedAt = 0
	xpOverviewRequestedAt = RealTime()
	if IsValid(xpMenuPageState.frame) and xpMenuPageState.open and xpMenuPageState.page == "experience" and xpMenuPageState.refresh then
		xpMenuPageState.refresh()
	end
end)

hook.Add("DRPRoleOverviewChanged", "DRP.Gameplay.RefreshRolePage", function()
	if IsValid(xpMenuPageState.frame) and xpMenuPageState.open and xpMenuPageState.page == "jobs" and xpMenuPageState.refresh then
		xpMenuPageState.refresh()
	end
end)

hook.Add("InitPostEntity", "DRP.MOTD.ResetAutoOpen", function()
	motdNeedsAutoShow = true
	motdShownVersion = -1
end)

hook.Add("OnEntityCreated", "DRP.MOTD.ResetAutoOpenOnLocalPlayer", function(ent)
	if not IsValid(ent) or not ent:IsPlayer() then return end
	timer.Simple(0.15, function()
		if IsValid(LocalPlayer()) and ent == LocalPlayer() then
			motdNeedsAutoShow = true
			motdShownVersion = -1
		end
	end)
end)

local function openF4Menu()
	if IsValid(f4Menu) then
		f4Menu:Close()
		return
	end

	local UI = DRP.UI
	local colors = UI.Colors
	local frame = UI.Frame("DarkRP Menu", 920, 620)
	f4Menu = frame
	xpMenuPageState.open = true
	xpMenuPageState.frame = frame
		frame.OnRemove = function()
			xpMenuPageState.open = false
			xpMenuPageState.refresh = nil
			if f4Menu == frame then f4Menu = nil end
		end

	local sidebar = UI.Card(frame)
	sidebar:SetPos(16, 74)
	sidebar:SetSize(184, frame:GetTall() - 90)

	local content = UI.Card(frame)
	content:SetPos(212, 74)
	content:SetSize(frame:GetWide() - 228, frame:GetTall() - 90)

	local activePage = xpMenuPageState.page or "jobs"
	local navigation = {}
	local pageDefinitions = {
		{ key = "guide", label = "Guide", description = "Learn the server's core mechanics" },
		{ key = "objectives", label = "Objectives", description = "Optional role-aware activities" },
		{ key = "jobs", label = "Jobs", description = "Roles, salaries and loadouts" },
		{ key = "experience", label = "Experience", description = "Level progress, prestige and unlock rewards" },
		{ key = "government", label = "Government", description = "Elections, tax and treasury" },
		{ key = "properties", label = "Properties", description = "Leases, tenants, vaults and raids" },
		{ key = "commands", label = "Commands", description = "Available chat commands" },
		{ key = "keybinds", label = "Keybinds", description = "Gamemode shortcuts" },
		{ key = "motd", label = "MOTD", description = "Server message of the day" },
		{ key = "settings", label = "Settings", description = "Client preferences" }
	}

	local function pageScroll()
		local scroll = vgui.Create("DScrollPanel", content)
		scroll:Dock(FILL)
		scroll:DockMargin(12, 0, 12, 12)
		stylePageScroll(scroll)
		return scroll
	end

	local showPage

	local function showJobs()
		addPageHeading(content, "Role Identity", "Your civic standing and demonstrated behavior now determine your role. Government service remains selectable.")
		local scroll = pageScroll()
		if DRP.Roles and DRP.Roles.Request then DRP.Roles.Request() end
		local overview = DRP.ClientRoleOverview or {}
		local behavior = istable(overview.behavior) and overview.behavior or {}
		local civic = math.floor(tonumber(overview.civic) or (DRP.Roster and DRP.Roster.Value(LocalPlayer(), "civic", 0)) or 0)
		local currentID = DRP.ClientProfile.job or DRP.Job.CITIZEN
		local derivedID = math.floor(tonumber(overview.derived) or currentID)
		local pursuedRoleID = DRP.ObjectivesClient and DRP.ObjectivesClient.RoleGoal and tonumber(DRP.ObjectivesClient.RoleGoal.job) or 0
		local metricLabels = {
			narcotics = "narcotics activity",
			forceDrugging = "force-drugging incidents",
			healing = "credited medical aid",
			weaponTrades = "completed weapon trades",
			homelessness = "homelessness events"
		}

		local currentJob = DRP.Jobs[currentID] or DRP.Jobs[DRP.Job.CITIZEN]
		addReferenceRow(
			scroll,
			"Current identity: " .. currentJob.name,
			"Civic " .. (civic > 0 and "+" or "") .. civic .. "  •  " .. tostring(overview.reason or "Behavior profile is synchronising."),
			currentJob.color
		)
		addReferenceRow(
			scroll,
			"Specialist behavior evidence",
			string.format("Narcotics %d  •  Force-drugging %d  •  Medical aid %d  •  Weapon trades %d",
				tonumber(behavior.narcotics) or 0, tonumber(behavior.forceDrugging) or 0,
				tonumber(behavior.healing) or 0, tonumber(behavior.weaponTrades) or 0),
			colors.accent
		)
		addReferenceRow(
			scroll,
			"Criminal behavior evidence",
			string.format("Muggings %d  •  Hits %d  •  Raids %d  •  Homelessness %d",
				tonumber(behavior.muggings) or 0, tonumber(behavior.hits) or 0,
				tonumber(behavior.raids) or 0, tonumber(behavior.homelessness) or 0),
			Color(224, 116, 132)
		)
		addReferenceRow(
			scroll,
			"Criminal permission hierarchy",
			"All non-government players: mugging  •  −150: raids  •  −325: hit contracts",
			Color(224, 116, 132),
			nil,
			nil,
			"−425: kidnapping  •  −525: criminal agenda  •  −650: drug equipment",
			"−1000 Mob Boss: one-way PvP against everyone, all criminal access, and approved weapon crates"
		)

		for id, job in ipairs(DRP.Jobs) do
			local jobID, jobData = id, job
			local path = jobData.rolePath or {}
			local percent = (DRP.ClientGovernment and DRP.ClientGovernment.allocations[jobID]) or 0
			local fundedSalary = jobData.salary + math.floor(jobData.salary * percent / 100)
			fundedSalary = DRP.Supporter and DRP.Supporter.ApplyReward(LocalPlayer(), fundedSalary) or fundedSalary
			local status = path.description or "Assigned by gameplay."
			local accent = jobData.color
			local actionText, action
			local permissionProfile = DRP.JobPermissionProfiles[jobID] or {
				requirement = "Assigned by gameplay",
				permissions = "No specialist permissions"
			}

			if jobID == currentID then
				status = "CURRENT ROLE  •  " .. status
				accent = colors.accent
			elseif jobID == pursuedRoleID then
				status = "PINNED ROLE PATHWAY  •  " .. status
				accent = colors.purple
			elseif jobID == derivedID and not jobData.isGovernment then
				status = "EARNED IDENTITY  •  " .. status
				accent = colors.green
			elseif path.kind == "civic" then
				local threshold = tonumber(path.civicMaximum) or -1000
				local remaining = math.max(0, civic - threshold)
				status = "Civic " .. civic .. " / requires " .. threshold .. " or lower. " .. (remaining > 0 and (remaining .. " standing remaining. ") or "Requirement met. ") .. status
				if path.exclusive then
					if overview.mobBossOccupied then
						status = status .. " SERVER SLOT: HELD BY " .. tostring(overview.mobBossHolder or "another player") .. "."
					else
						status = status .. " SERVER SLOT: AVAILABLE."
					end
				end
			elseif path.kind == "behavior" then
				local value = math.floor(tonumber(behavior[path.metric]) or 0)
				local threshold = math.max(1, math.floor(tonumber(path.threshold) or 1))
				status = (metricLabels[path.metric] or path.metric or "evidence") .. " " .. math.min(value, threshold) .. "/" .. threshold .. ". "
				if path.civicMaximum and civic > path.civicMaximum then status = status .. " Civic must reach " .. path.civicMaximum .. "." end
				if path.civicMinimum and civic < path.civicMinimum then status = status .. " Civic must reach +" .. path.civicMinimum .. "." end
				status = status .. " " .. (path.description or "")
			end

			if jobID == DRP.Job.CITIZEN and currentJob.isGovernment then
				actionText = "RESIGN"
				action = function() RunConsoleCommand("say", "/job citizen") end
			elseif jobID ~= currentID and jobID ~= DRP.Job.CITIZEN then
				actionText = jobID == pursuedRoleID and "TRACKING" or "OPTIONS"
				action = function()
					local menu = DermaMenu()
					if jobID == pursuedRoleID then
						menu:AddOption("Stop pursuing " .. jobData.name, function()
							if DRP.ObjectivesClient then DRP.ObjectivesClient.ClearRoleGoal() end
						end):SetIcon("icon16/cancel.png")
					else
						menu:AddOption("Pin pathway to " .. jobData.name, function()
							if DRP.ObjectivesClient then DRP.ObjectivesClient.SetRoleGoal(jobID) end
						end):SetIcon("icon16/flag_blue.png")
					end
					if jobData.electionOnly and civic >= (jobData.civicMinimum or 0) then
						menu:AddOption("Apply for " .. jobData.name, function() RunConsoleCommand("say", "/mayor") end):SetIcon("icon16/group.png")
					elseif jobData.manualSelectable and civic >= (jobData.civicMinimum or 0) then
						menu:AddOption("Join " .. jobData.name, function() RunConsoleCommand("say", "/job " .. jobData.key) end):SetIcon("icon16/user_go.png")
					end
					menu:Open()
				end
			end

			addReferenceRow(
				scroll,
				jobData.name .. "  •  $" .. fundedSalary .. " salary",
				string.sub(status, 1, 112),
				accent,
				actionText,
				action,
				"ACCESS: " .. permissionProfile.requirement,
				"PERMISSIONS: " .. permissionProfile.permissions
			)
		end
	end

	local function showExperience()
		local isFallback = not istable(xpOverview)
		local snapshot = isFallback and buildXPFallbackSnapshot() or xpOverview
		local syncState = isFallback and "Using local profile snapshot." or "Progression, prestige rewards and unlocked content."
		local now = RealTime()
		local waited = now - xpHUDFallbackStartedAt
		if isFallback and xpHUDFallbackStartedAt <= 0 then
			xpHUDFallbackStartedAt = now
		end
		requestXPOverview()

		addPageHeading(content, "Experience", syncState)
		local scroll = pageScroll()
		if isFallback then
			local statusText
			local statusClass = colors.accent
			if waited > 2.5 then
				statusText = "Server response delayed. Showing local snapshot until sync completes."
				statusClass = Color(255, 217, 120)
			else
				statusText = "Waiting for server confirmation. Data will refresh automatically once the server responds."
			end
			addReferenceRow(scroll, "Server sync status", statusText, statusClass)
			timer.Simple(0.25, function()
				if xpMenuPageState.open and IsValid(content) and xpMenuPageState.page == "experience" then
					xpMenuPageState.refresh = function()
						if IsValid(f4Menu) and IsValid(content) and xpMenuPageState.open then
							if xpMenuPageState.page == "experience" then showPage("experience") end
						end
					end
					requestXPOverview()
				end
			end)
			xpMenuPageState.refresh = function()
				if IsValid(f4Menu) and IsValid(content) and xpMenuPageState.open then
					if xpMenuPageState.page == "experience" then showPage("experience") end
				end
			end
			addReferenceRow(scroll, "Local profile sync", "Server-only unlocks, history, and unlock preview may update when live snapshot arrives.", colors.accent)
		end

		local level = snapshot.level or 1
		local xp = snapshot.xp or 0
		local nextXP = snapshot.xp_to_next or 0
		local remaining = snapshot.remaining or 0
		local maxLevel = snapshot.max_level or 100
		local nextLevel = snapshot.next_rank or math.min(maxLevel, level + 1)
		local progress = snapshot.progress or 0
		local prestige = snapshot.prestige or 0
		local tokens = snapshot.tokens or 0
		local canPrestige = snapshot.can_prestige == true
		local maxPrestige = snapshot.max_prestige or 10
		local maxed = snapshot.maxed == true or (prestige >= maxPrestige and level >= maxLevel)

		local statPanel = vgui.Create("DPanel", scroll)
		statPanel:Dock(TOP)
		statPanel:DockMargin(0, 0, 0, 10)
		statPanel:SetTall(112)
		statPanel.Paint = function(_, width, height)
			draw.RoundedBox(6, 0, 0, width, height, colors.background)
			local prestigeLabel = maxed and "MAX PRESTIGE" or ("Prestige " .. prestige .. "/" .. maxPrestige)
			draw.SimpleText("Level " .. level .. "/" .. maxLevel .. "    " .. prestigeLabel .. "    Tokens " .. tokens, "DRP.Admin.Body", 16, 14, maxed and colors.green or color_white)
			local rankLabel = maxed and "Progression complete" or ("Next Rank: " .. nextLevel .. "  •  " .. (nextXP > 0 and (remaining .. " XP remaining") or "READY TO PRESTIGE"))
			draw.SimpleText(rankLabel, "DRP.Admin.Small", 16, 40, maxed and colors.green or colors.muted)
			draw.SimpleText("Current XP: " .. xp .. (xp > 0 and "" or " (no XP yet)"), "DRP.Admin.Small", 16, 56, colors.muted)
			local barY, barHeight = 78, 18
			draw.RoundedBox(6, 16, barY, width - 32, barHeight, colors.line)
			draw.RoundedBox(6, 16, barY, math.max(8, (width - 32) * math.Clamp(progress, 0, 1)), barHeight, colors.accent)
			draw.SimpleText(xp .. " / " .. (nextXP > 0 and nextXP or "MAX") .. " XP", "DRP.Admin.Small", width * 0.5, barY + barHeight * 0.5, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		if canPrestige then
			local prestigeButton = UI.Button(scroll, "PRESTIGE — EARN 1 PERMANENT UNLOCK TOKEN", colors.green, function()
				UI.Confirm(
					"Confirm Prestige",
					"Entering Prestige " .. math.min(maxPrestige, prestige + 1) .. " resets you to Level 1 and removes access to every level-based unlock. Your existing permanent weapon unlocks remain yours. You will receive one Prestige Token that can permanently unlock one individual weapon from the Weapons page in the spawn menu.",
					"PRESTIGE NOW",
					function() sendXPAction(0) end,
					colors.green
				)
			end)
			prestigeButton:SetTall(38)
			prestigeButton:Dock(TOP)
			prestigeButton:DockMargin(0, 0, 0, 12)
		end

		addReferenceRow(scroll, "XP Breakdown", "Latest activity used for progression.", colors.accent)
		for _, entry in ipairs(snapshot.history or {}) do
			local rowLabel = (entry.amount and ("+" .. entry.amount .. " XP") or "No XP")
			local detail = (entry.source or "system") .. " • " .. (entry.detail or "")
			local stamp = entry.time and os.date("%m-%d %H:%M", tonumber(entry.time) or 0) or "?"
			addReferenceRow(scroll, rowLabel .. " (" .. stamp .. ")", detail, colors.accent)
		end

		addReferenceRow(scroll, "Unlock preview", "Items becoming available on future ranks.", colors.accent)
		local unlocks = snapshot.next_unlocks or {}
		for _, unlock in ipairs(unlocks) do
			addReferenceRow(
				scroll,
				("Unlock at level %d: %s"):format(unlock.level or 0, string.sub(unlock.name or unlock.key, 1, 72)),
				"Item key: " .. string.sub(unlock.key or "", 1, 80),
				colors.green
			)
		end
		if #unlocks == 0 then
			addReferenceRow(scroll, "No more unlocks", "You have reached the end of the unlock list.", colors.muted)
		end

		addReferenceRow(scroll, "Permanent weapon unlocks", "Spend Prestige Tokens from a weapon's right-click menu in Q > Weapons.", colors.accent)
		local unlockedItems = snapshot.unlocked or {}
		for _, key in ipairs(unlockedItems) do
			addReferenceRow(scroll, string.sub(key, 1, 92), "Can spawn this item for free.", colors.green)
		end
		if #unlockedItems == 0 then
			addReferenceRow(scroll, "None unlocked yet", "Reach level 100 and prestige to begin unlocking items.", colors.muted)
		end

		addReferenceRow(scroll, tokens > 0 and (tokens .. " token" .. (tokens == 1 and "" or "s") .. " available") or "No Prestige Tokens", tokens > 0 and "Open Q > Weapons and right-click the exact weapon you want to own permanently." or "Reach Level 100 and prestige to earn another token.", tokens > 0 and colors.green or colors.muted)
	end

	local function showCommands()
		addPageHeading(content, "Commands", "Click any command to copy its syntax to your clipboard.")
		local scroll = pageScroll()
		local commands = {
			{ syntax = "/rpname <name>  /name <name>", detail = "Update your persistent roleplay name after first registering with the police-station Councilman." },
			{ syntax = "/job <police|citizen>", detail = "Join eligible government service or resign back to your earned civic/behavior identity. Other roles cannot be selected." },
			{ syntax = "/jobname <title>", detail = "Set a custom title for your current job." },
			{ syntax = "/hands  /handdrop <slot>", detail = "Equip Hands: primary picks up items, secondary opens the grid inventory, reload consumes the selected drug. Legacy pocket commands remain aliases." },
			{ syntax = "/marketplace  /marketplacelist", detail = "Open the player market or create a listing from the owned entity you are aiming at." },
			{ syntax = "/listing<number>add", detail = "Add another aimed owned entity to an existing listing, for example /listing12add." },
			{ syntax = "/contracttestbuyer  /contracttestseller", detail = "Run the automated single-player buyer or seller delivery scenarios." },
			{ syntax = "/hit <player> <amount>  /hits  /accepthit <ID>", detail = "Post an escrowed hit or manage contracts as a Hitman." },
			{ syntax = "/warrant <player> <reason>  /approvewarrant <ID>", detail = "Police request and Mayor approval for incident-backed arrest/search authority." },
			{ syntax = "/search <player>  /evidence", detail = "Police: search an authorized suspect or inspect the assigned evidence store." },
			{ syntax = "Police custody workflow", detail = "Tase an authorized suspect, cuff and escort them, then press E on a Jailer spawned from Q > Job Entities." },
			{ syntax = "/grantlicense <player>  /revokelicense <player>", detail = "Mayor: grant or revoke a weapon licence; licensed Citizens may openly carry." },
			{ syntax = "/bail  /unarrest <player>", detail = "Pay treasury bail after 30 seconds; Mayor or authorized staff may release a prisoner." },
			{ syntax = "/lockdown <reason>  /unlockdown", detail = "Mayor: announce or end a lockdown; unsheltered Citizens become arrestable after one minute." },
			{ syntax = "/agenda [text]", detail = "View your team agenda; Mayor and Mob Boss can update their agenda group." },
			{ syntax = "/tip <amount>", detail = "Tip the Hobo-owned jar you are looking at." },
			{ syntax = "/setevidence  /setjail", detail = "Authorized setup: assign aimed evidence storage or save the current jail position." },
			{ syntax = "/mayor  /vote <candidate|keep|remove>", detail = "Apply for Mayor or vote in an election/confidence poll." },
			{ syntax = "/treasury", detail = "View public treasury, tax and job funding information." },
			{ syntax = "/tax <0-50>  /allocate <job> <0-50>", detail = "Mayor: set salary tax and maximum treasury-funded job bonuses." },
			{ syntax = "/lottery <prize>  /lotteryenter", detail = "Mayor: fund a 60-second public lottery; players use /lotteryenter." },
			{ syntax = "/give <player> <amount>", detail = "Give money to a uniquely matched player." },
			{ syntax = "/drop", detail = "Drop the currently held item (except blocked utility/job items)." },
			{ syntax = "/dropmoney <amount>", detail = "Drop physical cash for another player to collect." },
			{ syntax = "/recordincident", detail = "Start or stop a clientside demo. Automatic incident recording can be enabled in Settings." },
			{ syntax = "/property [ID]  /propertymanage [ID]", detail = "Inspect a property or open its payments, members and persistent shared vault panel." },
			{ syntax = "/propertypay <1-3> [ID]", detail = "Fund a base lease up to three days ahead. Prepaid time never protects the base from raids." },
			{ syntax = "/propertyinvite <player> <role> <rent> <deposit> [ID]", detail = "Owner: invite a co-owner, tenant or custom role with refundable deposit." },
			{ syntax = "/propertyaccept  /propertyleave [ID]", detail = "Accept a tenancy offer or voluntarily leave and recover your deposit." },
			{ syntax = "/propertyevict <player> [ID]", detail = "Owner: issue a 60-second eviction notice; access is not removed instantly." },
			{ syntax = "/propertysetrole <player> <role> [ID]", detail = "Owner/co-owner: change a member's property role." },
			{ syntax = "/propertyrole <role> <permission> <0|1> [ID]", detail = "Owner: define access, storage, build, crafting and management permissions." },
			{ syntax = "/propertyrelease [ID]", detail = "Owner: release the complete property and receive the sale refund." },
			{ syntax = "/propertystorage [ID]  /propertydefence [ID]", detail = "Register a compatible storage entity as protected, or a prop as a declared raid objective." },
			{ syntax = "/raid [property ID]", detail = "Raid-capable job: declare an objective raid while near the property." },
			{ syntax = "/raidjoin <incident ID>", detail = "Raid-capable job: join a declared raid during its warning period." },
			{ syntax = "/raidarmory", detail = "Raid-capable job: look at the police armory and begin or join its fixed-countdown weapon-crate raid. Pressing E also works." },
			{ syntax = "/raidtreasury", detail = "Raid-capable job: look at the Treasury Vault and begin or join its 90-second hold raid for reserved public cash." },
			{ syntax = "/massie", detail = "HeadAdmin+ or individually authorized users: accept a major civic penalty and become a one-way PvP target for everyone for 30 seconds." },
			{ syntax = "/trust  /discordlink  /discordverify  /discordunlink", detail = "Review your transparent trust calculation or manage the Discord identity linked to it." },
			{ syntax = "/propertycreate <name>  /propertyadddoor [ID]", detail = "Door administrators: buy the building's doors as a selection, look at its main door, then create or extend the group." },
			{ syntax = "/propertyaddsingledoor <ID>", detail = "HeadAdmin+: aim at one ungrouped map door within 180 units and add it directly to an unowned property group." },
			{ syntax = "/propertyremovedoor  /propertyprice <ID> <price>  /propertydelete <ID>", detail = "HeadAdmin+: maintain property groups and purchase prices." },
			{ syntax = "/propertyleaseprice <ID> <price>  /propertybuyable <ID> <0|1>", detail = "HeadAdmin+: configure scheduled daily lease cost and whether a property can be purchased." },
			{ syntax = "/setjob <player> <job>", detail = "Staff: force an online player into a job (Jobs permission)." },
			{ syntax = "/setmoney <player> <amount>", detail = "Staff: set an online player's wallet (Money permission)." },
			{ syntax = "/addmoney <player> <amount>", detail = "Staff: add money to an online player's wallet." },
			{ syntax = "/deductmoney <player> <amount>", detail = "Staff: deduct money from an online player's wallet." },
			{ syntax = "/setxp <player> <amount>", detail = "Staff: set an online player's total experience points (Experience permission)." },
			{ syntax = "/addxp <player> <amount>", detail = "Staff: add experience points to an online player." },
			{ syntax = "/deductxp <player> <amount>", detail = "Staff: deduct experience points from an online player." },
			{ syntax = "/setcivic <player> <-1000 to 1000>", detail = "Staff: set civic standing directly (Civic permission)." },
			{ syntax = "/addcivic <player> <amount>", detail = "Staff: increase an online player's civic standing." },
			{ syntax = "/deductcivic <player> <amount>", detail = "Staff: reduce an online player's civic standing." },
			{ syntax = "/admin  /adminmode  !admin  !adminmode", detail = "Staff: enter or leave Admin Mode. Typing adminmode by itself also works." },
			{ syntax = "/spectate <player>  /unspectate", detail = "Admin Mode: remotely watch a player without teleporting." },
			{ syntax = "/freeze <player>  /unfreeze <player>", detail = "Admin Mode: freeze or release an online player." },
			{ syntax = "/respawn <player>", detail = "Admin Mode: respawn while preserving weapons and ammunition." },
			{ syntax = "/sethealth <player> <amount>", detail = "Admin Mode: set player health." },
			{ syntax = "/setarmor <player> <amount>", detail = "Admin Mode: set player armor." },
			{ syntax = "/strip <player>", detail = "Admin Mode: remove every weapon from a player." },
			{ syntax = "/jail <player>  /unjail <player>", detail = "Admin Mode: immobilize or release a player." },
			{ syntax = "/help", detail = "Show a quick command and controls reminder." }
		}
		for _, command in ipairs(commands) do
			local data = command
			addReferenceRow(scroll, data.syntax, data.detail, colors.accent, "COPY", function()
				SetClipboardText(data.syntax)
				surface.PlaySound("ui/buttonclickrelease.wav")
			end)
		end
	end

	local function showGovernment()
		addPageHeading(content, "Government", "Public elections, confidence polling and treasury-backed job funding.")
		local scroll = pageScroll()
		local government = DRP.ClientGovernment or { taxRate = 0, treasury = 0, phase = 0, candidates = {}, allocations = {} }
		local mayor = IsValid(government.mayor) and government.mayor:DRPName() or "Vacant"
		addReferenceRow(scroll, "Mayor: " .. mayor, "Treasury $" .. string.Comma(government.treasury) .. "  •  Salary tax " .. government.taxRate .. "%", IsValid(government.mayor) and colors.green or colors.red)

		local phaseNames = { [0] = "No active poll", [1] = "Applications open", [2] = "Mayor election voting", [3] = "Mayor confidence poll" }
		local remaining = math.max(0, math.ceil((government.deadline or 0) - CurTime()))
		addReferenceRow(scroll, phaseNames[government.phase] or "No active poll", government.phase > 0 and (remaining .. " seconds remaining") or "The next confidence poll occurs 20 minutes after the previous result.", government.phase > 0 and colors.accent or colors.muted, government.phase == 1 and "APPLY" or nil, government.phase == 1 and function()
			RunConsoleCommand("say", "/mayor")
		end or nil)

		if government.phase == 2 then
			for _, candidate in ipairs(government.candidates or {}) do
				local data = candidate
				addReferenceRow(scroll, data.name, data.votes .. " recorded vote" .. (data.votes == 1 and "" or "s"), colors.accent, "VOTE", function()
					RunConsoleCommand("say", "/vote " .. data.id)
				end)
			end
		elseif government.phase == 3 then
			addReferenceRow(scroll, "Confidence poll", government.keep .. " keep  •  " .. government.remove .. " remove", colors.accent, "COPY VOTE", function()
				SetClipboardText("/vote keep    or    /vote remove")
			end)
		end

		if government.lottery then
			local lotteryTime = math.max(0, math.ceil(government.lottery.deadline - CurTime()))
			addReferenceRow(scroll, "$" .. string.Comma(government.lottery.prize) .. " treasury lottery", government.lottery.entrants .. " entrants  •  " .. lotteryTime .. " seconds remaining", colors.green, "ENTER", function()
				RunConsoleCommand("say", "/lotteryenter")
			end)
		end

		for id, job in ipairs(DRP.Jobs) do
			local percent = government.allocations[id] or 0
			if percent > 0 then
				local bonus = math.floor(job.salary * percent / 100)
				local previewSalary = DRP.Supporter and DRP.Supporter.ApplyReward(LocalPlayer(), job.salary + bonus) or (job.salary + bonus)
				addReferenceRow(scroll, job.name .. " funding: up to +" .. percent .. "%", "Treasury pays up to $" .. bonus .. " ordinary funding; your tier previews $" .. previewSalary .. " gross before tax.", colors.green)
			end
		end
	end

	local function showKeybinds()
		addPageHeading(content, "Keybinds", "Current bindings and custom shortcuts provided by this gamemode.")
		local scroll = pageScroll()
		local bindings = {
			{ key = boundKey("gm_showspare2", "F4") .. "  /  CTRL+F4  /  I", action = "Open or close this DarkRP menu" },
			{ key = "F3  /  Z", action = "Toggle gameplay cursor mode for interactive HUD panels and checks" },
			{ key = boundKey("+menu", "Q"), action = "Open the themed prop browser" },
			{ key = boundKey("messagemode", "Y"), action = "Open local chat" },
			{ key = boundKey("messagemode2", "U"), action = "Open team chat" },
			{ key = "M", action = "Mug your aimed-at player; hold 3 seconds to set the demand" },
			{ key = "KEYS", action = "Primary locks your controlled door; secondary unlocks it, including job doors" },
			{ key = "HANDS", action = "Primary carries an item; secondary opens the grid; reload consumes the selected drug; hold E on a still player for 3 seconds to force-feed" },
			{ key = "POLICE TASER", action = "Primary stuns an incident-authorized suspect for six seconds without enabling lethal force" },
			{ key = "HANDCUFFS", action = "Primary cuffs/takes custody; secondary toggles escort; reload removes cuffs; E on the Jailer books the suspect" },
			{ key = "ADMIN PHYSGUN", action = "In Admin Mode: grab a player, then right-click to freeze; reload while aiming to unfreeze" },
			{ key = "F  /  CTRL+F2", action = "Buy or sell the door you are looking at" },
			{ key = "CTRL+F1", action = "Open Garry's Mod help" }
		}
		for _, binding in ipairs(bindings) do
			addReferenceRow(scroll, binding.key, binding.action, colors.accent)
		end
	end

local function showMOTD()
		addPageHeading(content, "Server Message of the Day", "Update the startup Message of the Day that appears when players connect.")
		local scroll = pageScroll()
		local data = DRP.MOTD or {}
		addReferenceRow(scroll, data.title or "Server MOTD", (data.enabled and "Enabled for all players." or "Disabled: this message is hidden on connect.") .. " Last updated: " .. os.date("%Y-%m-%d %H:%M", data.updated or 0), colors.green, "OPEN PREVIEW", function()
			openMOTDPanel()
		end)

		local previewFrame = vgui.Create("DPanel", scroll)
		previewFrame:Dock(TOP)
		previewFrame:DockMargin(0, 0, 0, 10)
		previewFrame:SetTall(300)
		previewFrame.Paint = function() end
		local preview = vgui.Create("DHTML", previewFrame)
		preview:Dock(FILL)
		preview:DockMargin(12, 4, 12, 4)
			preview:SetHTML(buildMOTDHTML(data.title or "Server MOTD", data.html or ""))

		if not DRP.ClientOwner then
			addReferenceRow(scroll, "Owner-only editing", "Only the owner can modify the Message of the Day.", colors.muted)
			return
		end

		addPageHeading(content, "Edit MOTD", "Only the server owner can change title, HTML content and enabled state.")
		local title = vgui.Create("DTextEntry", scroll)
		title:Dock(TOP)
		title:DockMargin(0, 0, 0, 8)
		title:SetTall(34)
		title:SetText(string.sub(data.title or "Server MOTD", 1, 96))
		title:SetFont("DRP.Admin.Body")
		title:SetTooltip("Server MOTD title")
		title.Paint = function(self, width, height)
			draw.RoundedBox(6, 0, 0, width, height, DRP.UI.Colors.background)
			self:DrawTextEntryText(color_white, DRP.UI.Colors.accent, color_white)
			surface.SetDrawColor(DRP.UI.Colors.line)
			surface.DrawOutlinedRect(0, 0, width, height, 1)
		end

		local body = vgui.Create("DTextEntry", scroll)
		body:Dock(TOP)
		body:DockMargin(0, 0, 0, 8)
		body:SetTall(240)
		body:SetMultiline(true)
		body:SetText(data.html or "")
		body:SetFont("DRP.Admin.Body")
		body:SetVerticalScrollbarEnabled(true)
		body:SetTooltip("Paste HTML content here.")

		local enabled = vgui.Create("DCheckBoxLabel", scroll)
		enabled:Dock(TOP)
		enabled:DockMargin(0, 0, 0, 12)
		enabled:SetTall(32)
		enabled:SetText("Display this MOTD to players when they join")
		enabled:SetTextColor(color_white)
		enabled:SetChecked(data.enabled == true)

	local save = UI.Button(scroll, "Save MOTD", DRP.UI.Colors.accent, function()
		local content = body:GetValue() or ""
		local titleValue = title:GetValue() or ""
		if string.Trim(titleValue) == "" then titleValue = "Server MOTD" end
		local safeTitle = string.sub(titleValue, 1, 96)
		local safeContent = string.sub(content, 1, 12000)
		motdPendingBackup = table.Copy(DRP.MOTD or {})
		DRP.MOTD = {
			enabled = enabled:GetChecked(),
			title = safeTitle,
			html = safeContent,
			updated = os.time()
		}
		motdShownVersion = DRP.MOTD.updated

		net.Start(motdUpdateMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteBool(enabled:GetChecked())
		net.WriteString(safeTitle)
		net.WriteString(safeContent)
		net.SendToServer()
		if frame and IsValid(frame) and showPage then showPage("motd") end
		timer.Simple(0.05, function()
			if not IsValid(frame) then return end
			if showPage then showPage("motd") end
		end)
	end)
		save:Dock(TOP)
		save:SetTall(40)
		save:DockMargin(0, 0, 0, 16)
		UI.Button(scroll, "Clear MOTD Body", DRP.UI.Colors.red, function()
			body:SetText("")
		end):Dock(TOP)
	end

	local function showProperties()
		addPageHeading(content, "Property Management", "Persistent leases, scheduled payments, co-owners, tenants, shared vaults and declared raids.")
		local scroll = pageScroll()
		local ids = {}
		for id in pairs(DRP.ClientProperties or {}) do ids[#ids + 1] = id end
		table.sort(ids)
		if #ids == 0 then
			addReferenceRow(scroll, "No property groups configured", "Door administrators can create one while looking at a map door with /propertycreate <name>.", colors.muted)
			return
		end
		for _, id in ipairs(ids) do
			local propertyID = id
			local property = DRP.ClientProperties[propertyID]
			local role = property.role ~= "none" and string.upper(property.role) or "NO ACCESS"
			local detail = property.world
				and ("Hobo street construction  •  " .. (property.buildZoneCount or 0) .. " marked zones")
				or ("Owner: " .. property.owner .. "  •  " .. role .. "  •  " .. #property.doors .. " doors")
			if property.owner ~= "Unowned" then
				local funded = math.max(0, math.ceil((property.leasePaidDeadline or 0) - RealTime()))
				detail = detail .. "  •  Base funded " .. math.floor(funded / 3600) .. "h  •  Vault " .. property.vaultCount .. " items"
			end
			if property.role ~= "none" and property.rent > 0 then
				local rentDue = math.max(0, math.ceil((property.nextRentDeadline or 0) - RealTime()))
				detail = detail .. "  •  Rent $" .. string.Comma(property.rent) .. " due " .. rentDue .. "s"
			end
			if property.deposit > 0 then detail = detail .. "  •  Deposit $" .. string.Comma(property.deposit) end
			local eviction = math.max(0, math.ceil((property.evictionDeadline or 0) - RealTime()))
			if eviction > 0 then detail = detail .. "  •  EVICTION " .. eviction .. "s" end
			if property.raid > 0 then detail = detail .. "  •  RAID INCIDENT #" .. property.raid end
			local availability = property.world and "  —  HOBO BUILD ZONES"
				or property.owner == "Unowned" and (property.buyable and ("  —  $" .. string.Comma(property.price)) or "  —  NOT BUYABLE") or ""
			local title = "#" .. propertyID .. "  " .. property.name .. availability
			local row = addReferenceRow(scroll, title, detail, property.raid > 0 and colors.red or (property.role ~= "none" and colors.green or colors.accent), "MANAGE", function()
				if DRP.PropertyUI then DRP.PropertyUI.Request(propertyID, true) end
			end)
			row.DoRightClick = function()
				if DRP.PropertyUI then DRP.PropertyUI.OpenAdminMenu(property) end
			end
		end
	end

	local function showSettings()
		addPageHeading(content, "Settings", "Client preferences and server-persistent mutual PvP relationships.")
		local scroll = pageScroll()
		local localRoster = DRP.Roster and DRP.Roster.Get(LocalPlayer()) or {}
		local discordLinked = localRoster.discordLinked == true
		addReferenceRow(scroll, discordLinked and "Discord identity linked" or "Discord identity not linked",
			discordLinked and "Your verified Discord identity contributes to the public trust score." or "Linking is optional and adds one verified identity signal to the trust calculation.",
			discordLinked and colors.green or colors.purple, discordLinked and "UNLINK" or "LINK", function()
				RunConsoleCommand("say", discordLinked and "/discordunlink" or "/discordlink")
			end)
		if not discordLinked then
			addReferenceRow(scroll, "Complete Discord verification", "After authorizing in the browser, click verify to ask the configured backend for the result.", colors.accent, "VERIFY", function()
				RunConsoleCommand("say", "/discordverify")
			end)
		end
		local settings = {
			{ cvar = "drp_hud_enabled", default = "1", label = "DarkRP HUD", detail = "Show job, wallet, health and door information." },
			{ cvar = "drp_objectives_hud", default = "1", label = "Objective tracker", detail = "Show accepted objectives and their progress on the HUD." },
			{ cvar = "drp_chat_sounds", default = "1", label = "Chat sounds", detail = "Play a sound when a new chat message arrives." },
			{ cvar = "drp_chat_recent", default = "1", label = "Recent chat overlay", detail = "Show recent messages while the chatbox is closed." },
			{ cvar = "drp_incident_autorecord", default = "0", label = "Automatically record active incidents", detail = "Record your client view with gm_demo from the next incident until 30 seconds after your final incident resolves." }
		}
		for _, setting in ipairs(settings) do
			local data = setting
			local row = addReferenceRow(scroll, data.label, data.detail, colors.accent)
			local check = vgui.Create("DCheckBox", row)
			check:SetSize(24, 24)
			check:SetPos(row:GetWide() - 45, 24)
			check:SetChecked(GetConVar(data.cvar):GetBool())
			check.OnChange = function(_, enabled)
				RunConsoleCommand(data.cvar, enabled and "1" or "0")
			end
			row.PerformLayout = function(self)
				check:SetPos(self:GetWide() - 45, 24)
			end
		end

		local consent = DRP.PVPConsentClient or { Incoming = {}, Outgoing = {}, Enabled = {} }
		local section = UI.SectionLabel(scroll, "Permanent Player PvP")
		section:Dock(TOP)
		section:DockMargin(4, 14, 4, 6)

		local blocked = {}
		for _, list in ipairs({ consent.Incoming, consent.Outgoing, consent.Enabled }) do for _, entry in ipairs(list or {}) do blocked[entry.id] = true end end
		local selector = vgui.Create("DComboBox", scroll)
		selector:Dock(TOP)
		selector:DockMargin(0, 0, 0, 6)
		selector:SetTall(38)
		selector:SetFont("DRP.Admin.Body")
		selector:SetTextColor(color_white)
		selector:SetSortItems(true)
		selector.Paint = function(self, width, height)
			draw.RoundedBox(6, 0, 0, width, height, self:IsHovered() and colors.panelHover or colors.background)
			surface.SetDrawColor(colors.line)
			surface.DrawOutlinedRect(0, 0, width, height, 1)
		end
		selector:SetValue("Select an online player by DarkRP name")
		for _, target in player.Iterator() do
			if target ~= LocalPlayer() and not blocked[target:SteamID64()] then selector:AddChoice(target:DRPName(), target:SteamID64()) end
		end
		selector.OnSelect = function(_, _, _, targetID) selector.SelectedSteamID = targetID end

		local request = UI.Button(scroll, "SEND PERMANENT PVP REQUEST", colors.accent, function()
			local targetID = selector.SelectedSteamID
			if targetID and DRP.PVPConsentClient then DRP.PVPConsentClient.Request(targetID)
			else notification.AddLegacy("Select an online player first.", NOTIFY_ERROR, 3) end
		end)
		request:Dock(TOP)
		request:DockMargin(0, 0, 0, 12)
		request:SetTall(38)

		local function decisionRow(entry)
			local row = vgui.Create("DPanel", scroll)
			row:Dock(TOP)
			row:DockMargin(0, 0, 0, 8)
			row:SetTall(72)
			row.Paint = function(_, width, height)
				draw.RoundedBox(7, 0, 0, width, height, colors.background)
				draw.RoundedBoxEx(7, 0, 0, 5, height, colors.accent, true, false, true, false)
				draw.SimpleText(entry.name, "DRP.Admin.Body", 18, 23, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText("Requests permanent mutual damage permission", "DRP.Admin.Small", 18, 50, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end
			local reject = UI.Button(row, "REJECT", colors.red, function() DRP.PVPConsentClient.Reject(entry.id) end)
			reject:SetSize(76, 32)
			local accept = UI.Button(row, "ACCEPT", colors.green, function() DRP.PVPConsentClient.Accept(entry.id) end)
			accept:SetSize(76, 32)
			row.PerformLayout = function(self)
				reject:SetPos(self:GetWide() - 164, 20)
				accept:SetPos(self:GetWide() - 82, 20)
			end
		end

		if #(consent.Incoming or {}) > 0 then
			local incomingTitle = UI.SectionLabel(scroll, "Incoming Requests")
			incomingTitle:Dock(TOP)
			incomingTitle:DockMargin(4, 4, 4, 4)
			for _, entry in ipairs(consent.Incoming) do decisionRow(entry) end
		end
		if #(consent.Outgoing or {}) > 0 then
			local outgoingTitle = UI.SectionLabel(scroll, "Pending Requests")
			outgoingTitle:Dock(TOP)
			outgoingTitle:DockMargin(4, 4, 4, 4)
			for _, entry in ipairs(consent.Outgoing) do
				local data = entry
				addReferenceRow(scroll, data.name, "Waiting for this player to accept or reject.", colors.muted, "CANCEL", function() DRP.PVPConsentClient.Reject(data.id) end)
			end
		end
		if #(consent.Enabled or {}) > 0 then
			local enabledTitle = UI.SectionLabel(scroll, "PvP Permanently Enabled")
			enabledTitle:Dock(TOP)
			enabledTitle:DockMargin(4, 4, 4, 4)
			for _, entry in ipairs(consent.Enabled) do
				local data = entry
				addReferenceRow(scroll, data.name, "Mutual player damage remains enabled until either player disables it.", colors.green, "DISABLE", function() DRP.PVPConsentClient.Disable(data.id) end)
			end
		end
		local reset = UI.Button(scroll, "Reset client settings", colors.red, function()
			for _, setting in ipairs(settings) do RunConsoleCommand(setting.cvar, setting.default or "1") end
			showPage("settings")
		end)
		reset:Dock(TOP)
		reset:DockMargin(0, 8, 0, 0)
		reset:SetTall(38)
	end

	local function showGuide()
		addPageHeading(content, "Player Field Guide", "Browse the mechanics that govern roleplay, conflict, property and progression.")
		local holder = vgui.Create("DPanel", content)
		holder:Dock(FILL)
		holder:DockMargin(12, 0, 12, 12)
		holder.Paint = function(_, width, height)
			draw.RoundedBox(9, 0, 0, width, height, colors.background)
			surface.SetDrawColor(colors.line)
			surface.DrawOutlinedRect(0, 0, width, height, 1)
		end

		local guide = vgui.Create("DHTML", holder)
		guide:Dock(FILL)
		guide:DockMargin(2, 2, 2, 2)
		local html = buildGuideHTML()
		local state = DRP.ObjectivesClient and DRP.ObjectivesClient.Guide or {}
		local names = {
			"Set an RP name", "Purchase a property", "Use Hands",
			"Complete a mugging", "Heal another player", "Review role pathways"
		}
		local rows = {}
		if (state.total or 0) > 0 then
			rows[#rows + 1] = string.format("<span class='tag'>BEGINNER PROGRESS %d / %d</span><h3>Your automatic field training</h3><ul>", state.completed or 0, state.total or 0)
			for index, name in ipairs(names) do
				local complete = bit.band(state.mask or 0, bit.lshift(1, index - 1)) ~= 0
				rows[#rows + 1] = "<li style='color:" .. (complete and "#6cee97" or "#c8d6e7") .. "'>" .. (complete and "✓ " or "○ ") .. name .. "</li>"
			end
			rows[#rows + 1] = "</ul>"
		else
			rows[#rows + 1] = "<span class='tag'>REFERENCE GUIDE</span><h3>Automatic training is complete or not required.</h3><p>Every mechanic remains documented here, and population-aware activities remain available in F4 → Objectives.</p>"
		end
		html = string.Replace(html, "{{BEGINNER_PROGRESS}}", table.concat(rows))
		guide:SetHTML(html)
	end

	local function showObjectives()
		addPageHeading(content, "Objective Board", "Optional, population-aware activities generated for your role and current situation.")
		if DRP.ObjectivesClient and DRP.ObjectivesClient.BuildPage then
			DRP.ObjectivesClient.BuildPage(content)
		end
	end

	local pageBuilders = {
		guide = showGuide,
		objectives = showObjectives,
		experience = showExperience,
		jobs = showJobs,
		government = showGovernment,
		properties = showProperties,
		commands = showCommands,
		keybinds = showKeybinds,
		motd = showMOTD,
		settings = showSettings
	}

	showPage = function(page)
		activePage = pageBuilders[page] and page or "jobs"
		xpMenuPageState.page = activePage
		xpMenuPageState.refresh = function()
			if IsValid(f4Menu) and xpMenuPageState.open and xpMenuPageState.page == activePage then showPage(activePage) end
		end
		content:Clear()
		for key, button in pairs(navigation) do button.Active = key == activePage end
		pageBuilders[activePage]()
	end

	local navTitle = vgui.Create("DLabel", sidebar)
	navTitle:Dock(TOP)
	navTitle:DockMargin(14, 12, 14, 8)
	navTitle:SetTall(24)
	navTitle:SetFont("DRP.Admin.Small")
	navTitle:SetTextColor(colors.muted)
	navTitle:SetText("NAVIGATION")

	local navScroll = vgui.Create("DScrollPanel", sidebar)
	navScroll:Dock(FILL)
	navScroll:DockMargin(0, 0, 4, 8)
	stylePageScroll(navScroll)

	for _, definition in ipairs(pageDefinitions) do
		local page = definition
		local button = vgui.Create("DButton", navScroll)
		navigation[page.key] = button
		button:Dock(TOP)
		button:DockMargin(8, 0, 8, 6)
		button:SetTall(58)
		button:SetText("")
		button.Paint = function(self, width, height)
			local fill = self.Active and colors.panelHover or (self:IsHovered() and Color(26, 34, 47) or Color(0, 0, 0, 0))
			draw.RoundedBox(6, 0, 0, width, height, fill)
			if self.Active then draw.RoundedBoxEx(6, 0, 0, 4, height, colors.accent, true, false, true, false) end
			draw.SimpleText(page.label, "DRP.Admin.Body", 14, 20, self.Active and color_white or colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(page.description, "DRP.Admin.Small", 14, 41, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
		button.DoClick = function() showPage(page.key) end
	end

		f4MenuSerial = f4MenuSerial + 1
		local consentHook = "DRP.F4.PVPConsent." .. f4MenuSerial
		hook.Add("DRPPVPConsentUpdated", consentHook, function()
			if IsValid(frame) and activePage == "settings" then showPage("settings") end
		end)
		local oldOnRemove = frame.OnRemove
		local propertyHook = "DRP.F4.Properties." .. f4MenuSerial
		hook.Add("DRPPropertiesUpdated", propertyHook, function()
			if IsValid(frame) and activePage == "properties" then showPage("properties") end
		end)
		local rosterHook = "DRP.F4.LocalRoster." .. f4MenuSerial
		hook.Add("DRPRosterChanged", rosterHook, function(index)
			if IsValid(frame) and activePage == "settings" and IsValid(LocalPlayer()) and index == LocalPlayer():EntIndex() then showPage("settings") end
		end)
		local objectivesHook = "DRP.F4.Objectives." .. f4MenuSerial
		hook.Add("DRPObjectivesUpdated", objectivesHook, function()
			if IsValid(frame) and (activePage == "objectives" or activePage == "jobs") then showPage(activePage) end
		end)
		frame.OnRemove = function(...)
			if oldOnRemove then oldOnRemove(...) end
			hook.Remove("DRPPVPConsentUpdated", consentHook)
			hook.Remove("DRPPropertiesUpdated", propertyHook)
			hook.Remove("DRPRosterChanged", rosterHook)
			hook.Remove("DRPObjectivesUpdated", objectivesHook)
		end
	if DRP.PVPConsentClient then DRP.PVPConsentClient.RequestSync() end
	if DRP.ObjectivesClient then DRP.ObjectivesClient.Request() end
	showPage(activePage)
end

function DRP.CloseF4Menu()
	if IsValid(f4Menu) then f4Menu:Close() end
end

local function openF4MenuSafe()
	if RealTime() < nextF4Toggle then return end
	nextF4Toggle = RealTime() + 0.18
	openF4Menu()
end

function DRP.OpenF4Page(page)
	xpMenuPageState.page = tostring(page or "guide")
	if IsValid(f4Menu) then f4Menu:Close() end
	nextF4Toggle = 0
	timer.Simple(0, openF4MenuSafe)
end

function GM:ShowSpare2()
	openF4MenuSafe()
end

net.Receive(motdSyncMessage, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local motd = {
		enabled = net.ReadBool(),
		title = string.sub(net.ReadString(), 1, 96),
		html = net.ReadString(),
		updated = net.ReadUInt(32)
	}
	DRP.MOTD = motd
	if motd.enabled and (motdNeedsAutoShow or (motd.updated or -1) ~= motdShownVersion) then
		motdNeedsAutoShow = false
		motdShownVersion = motd.updated
		queueMOTDOpen()
	end
end)

net.Receive(motdUpdateResultMessage, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local success = net.ReadBool()
	local message = string.sub(net.ReadString(), 1, 256)
	local updated = net.ReadUInt(32)
	local title = string.sub(net.ReadString(), 1, 96)
	local html = net.ReadString()
	local enabled = net.ReadBool()
	if success then
		DRP.MOTD = {
			enabled = enabled,
			title = title,
			html = html,
			updated = updated
		}
		motdPendingBackup = nil
		motdShownVersion = updated
	elseif motdPendingBackup then
		DRP.MOTD = motdPendingBackup
		motdPendingBackup = nil
	end
	if DRP.Chat and DRP.Chat.System then
		DRP.Chat.System(message, success and 1 or 3)
	end
	chat.AddText((success and Color(100, 220, 120) or Color(255, 95, 95)), "[DRP] ", color_white, message)
end)

local modifiedFunctionKeys = {
	[KEY_F1] = function() RunConsoleCommand("gm_showhelp") end,
	[KEY_F2] = requestDoor,
	[KEY_F4] = openF4MenuSafe
}

-- macOS users can use Control+F1 through Control+F4 as an alternative to
-- changing the system-wide media-key setting or holding the hardware Fn key.
hook.Add("PlayerButtonDown", "DRP.MacFunctionKeys", function(ply, button)
	if ply ~= LocalPlayer() then return end

	if button == KEY_F then
		requestDoor()
		return
	end

	-- Secondary Mac-friendly shortcut for the F4 action.
	if button == KEY_I then
		if not f4PressedState[KEY_I] then
			f4PressedState[KEY_I] = true
			openF4MenuSafe()
		end
		return
	end
	if button == KEY_F4 then
		if not f4PressedState[KEY_F4] then
			f4PressedState[KEY_F4] = true
			openF4MenuSafe()
		end
		return
	end

	if not controlDown() then return end

	local action = modifiedFunctionKeys[button]
	if action then action() end
end)

hook.Add("PlayerBindPress", "DRP.FunctionKeyBinds", function(_, bind, pressed)
	if not pressed then return end
	if input.IsKeyDown(KEY_F) and string.find(bind, "impulse 100", 1, true) then
		requestDoor()
		return true
	end

	local isF1 = string.find(bind, "gm_showhelp", 1, true)
	local isF2 = string.find(bind, "gm_showteam", 1, true)
	local isF3 = string.find(bind, "gm_showspare1", 1, true)
	local isF4 = string.find(bind, "gm_showspare2", 1, true)

	-- The PlayerButtonDown bridge dispatches modified keys. Suppress the
	-- original bind so a Control chord cannot run the action twice.
	if controlDown() and (isF1 or isF2 or isF3 or isF4) then return true end

	if isF2 then
		requestDoor()
		return true
	end
	if isF4 then
		if not f4PressedState[KEY_F4] then
			f4PressedState[KEY_F4] = true
			openF4MenuSafe()
		end
		return true
	end
end)

hook.Add("PlayerButtonUp", "DRP.MacFunctionKeysUp", function(ply, button)
	if ply ~= LocalPlayer() then return end
	if button == KEY_I or button == KEY_F4 then
		f4PressedState[button] = false
	end
end)
-- cl_gameplay is part of the core client bootstrap and is known to be active
-- whenever the DarkRP menu is available. Recover the HUD here if a stale or
-- host-modified cl_init did not execute its normal include.
if not GetConVar("drp_hud_enabled") then
	-- This file and cl_hud.lua are siblings inside core/ui/client. include paths
	-- are resolved relative to the calling Lua file.
	local hudLoaded, hudError = pcall(include, "cl_hud.lua")
	if hudLoaded then
		print("[DRP HUD] fallback loader initialized core/ui/client/cl_hud.lua")
	else
		ErrorNoHalt("[DRP HUD] failed to load sibling cl_hud.lua: " .. tostring(hudError) .. "\n")
	end
end
