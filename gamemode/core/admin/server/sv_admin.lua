local Admin = {
	Records = {},
	RankMasks = {},
	DataPath = "darkrp/admins.json",
	RanksPath = "darkrp/ranks.json",
	MOTDPath = "darkrp/motd.json",
	MOTD = { enabled = false, title = "Server MOTD", html = "", updated = 0 },
	Punishments = {},
	PunishmentsPath = "darkrp/punishments.json",
	NextPunishmentID = 1
}

DRP.Admin = Admin
DRP.Services.Register("admin", Admin)

local accessMessage = "drp_admin_access_v1"
local requestMessage = "drp_admin_request_v1"
local snapshotMessage = "drp_admin_snapshot_v1"
local updateMessage = "drp_admin_update_v1"
local entitlementUpdateMessage = "drp_admin_entitlement_update_v1"
local supporterTierUpdateMessage = "drp_admin_supporter_tier_update_v1"
local rankPermissionsMessage = "drp_admin_rank_permissions_v1"
local actionMessage = "drp_admin_action_v1"
local punishmentMessage = "drp_admin_punishment_v1"
local punishmentAnnouncementMessage = "drp_punishment_announce_v1"
local serverInteractionMessage = "drp_admin_server_interaction_v1"
local serverAnnouncementMessage = "drp_server_announcement_v1"
local motdSyncMessage = "drp_motd_sync_v1"
local motdUpdateMessage = "drp_motd_update_v1"
local motdUpdateResultMessage = "drp_motd_update_result_v1"
local healthRequestMessage = "drp_admin_health_request_v1"
local healthSnapshotMessage = "drp_admin_health_snapshot_v1"

util.AddNetworkString(accessMessage)
util.AddNetworkString(requestMessage)
util.AddNetworkString(snapshotMessage)
util.AddNetworkString(updateMessage)
util.AddNetworkString(entitlementUpdateMessage)
util.AddNetworkString(supporterTierUpdateMessage)
util.AddNetworkString(rankPermissionsMessage)
util.AddNetworkString(actionMessage)
util.AddNetworkString(punishmentMessage)
util.AddNetworkString(punishmentAnnouncementMessage)
util.AddNetworkString(serverInteractionMessage)
util.AddNetworkString(serverAnnouncementMessage)
util.AddNetworkString(motdSyncMessage)
util.AddNetworkString(motdUpdateMessage)
util.AddNetworkString(motdUpdateResultMessage)
util.AddNetworkString(healthRequestMessage)
util.AddNetworkString(healthSnapshotMessage)

local function sendMOTDUpdateResult(ply, success, message)
	net.Start(motdUpdateResultMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(success)
	net.WriteString(string.sub(tostring(message or ""), 1, 256))
	if success and Admin.MOTD then
		net.WriteUInt(math.max(0, tonumber(Admin.MOTD.updated or 0) % 4294967296), 32)
		net.WriteString(sanitizeMOTDTitle(Admin.MOTD.title))
		net.WriteString(sanitizeMOTDHTML(Admin.MOTD.html))
		net.WriteBool(Admin.MOTD.enabled == true)
	else
		net.WriteUInt(0, 32)
		net.WriteString("")
		net.WriteString("")
		net.WriteBool(false)
	end
	net.Send(ply)
end

local function validSteamID64(value)
	return isstring(value) and #value == 17 and string.match(value, "^%d+$") ~= nil
end

local function normalizeSteamID(value)
	local raw = string.upper(string.Trim(tostring(value or "")))
	if raw == "" then return nil end

	-- Accept copied Steam Community profile URLs as well as the three formal
	-- identifier representations: SteamID2, SteamID3 and SteamID64.
	raw = raw:match("STEAMCOMMUNITY%.COM/PROFILES/(%d+)") or raw
	raw = string.match(raw, "^%[(.-)%]$") or raw
	if validSteamID64(raw) then return raw end

	local _, authenticationServer, accountNumber = string.match(raw, "^STEAM_([0-5]):([01]):(%d+)$")
	if authenticationServer and accountNumber then
		local converted = util.SteamIDTo64("STEAM_0:" .. authenticationServer .. ":" .. accountNumber)
		if validSteamID64(converted) then return converted end
	end

	local accountType, universe, accountID = string.match(raw, "^([U]):([0-5]):(%d+)$")
	if not accountID then
		accountType, universe, accountID = string.match(raw, "^([U]):([0-5]):(%d+):%d+$")
	end
	accountID = tonumber(accountID)
	if accountType == "U" and universe and accountID and accountID >= 0 and accountID <= 4294967295 then
		local parity = accountID % 2
		local accountNumber3 = math.floor(accountID / 2)
		local converted = util.SteamIDTo64("STEAM_0:" .. parity .. ":" .. accountNumber3)
		if validSteamID64(converted) then return converted end
	end

	return nil
end

Admin.NormalizeSteamID = normalizeSteamID

local function cleanMask(value)
	return bit.band(math.floor(tonumber(value) or 0), DRP.AdminAllPermissions)
end

local function cleanMOTDText(value, maximum)
	value = string.gsub(tostring(value or ""), "\r", "")
	value = string.gsub(value, "[%z\1-\8\11\12\14-\31]", "")
	return string.sub(value, 1, maximum)
end

local function sanitizeMOTDTitle(value)
	return cleanMOTDText(value, 96)
end

local function sanitizeMOTDHTML(value)
	local html = cleanMOTDText(value, 12000)
	html = string.gsub(html, "<%s*[sS][cC][rR][iI][pP][tT].->", "")
	html = string.gsub(html, "</%s*[sS][cC][rR][iI][pP][tT]>", "")
	html = string.gsub(html, "javascript:", "")
	return html
end

local function cleanMOTDFinal(value)
	local text = string.Trim(tostring(value or ""))
	return text ~= "" and text or "Server MOTD"
end

local function motdDefaults()
	return {
		enabled = true,
		title = "Welcome to the Server",
		html = [[
<section class='hero'>
  <h2>Welcome to our community</h2>
  <p>We built this server around stable, low-admin, high-reliability roleplay and strong in-game consequence systems.</p>
  <div class='chipline'><span>Server Vision</span> <span>Reliable Systems</span> <span>Respectful Players</span></div>
</section>

<section class='panel'>
  <h3>Our Purpose</h3>
  <p>Every system in this server is designed around clear behavior, consistent enforcement, and meaningful player agency. We want conflict to be emergent, fair, and defensible through the server’s own rules and mechanics.</p>
</section>

<section class='panel'>
  <h3>Core Rules</h3>
  <ul>
    <li>Respect all players and staff. Harassment, abuse, and threats are not tolerated.</li>
    <li>No exploit abuse, cheating, duplicated items, macro abuse, or unauthorized tools.</li>
    <li>Do not grief, spam, or deliberately overload server systems (props, doors, incidents, economy).</li>
    <li>Use clear communication. Avoid baiting, insults, and intentional chaos.</li>
    <li>Follow all announcements and policy systems in-game, including police and property mechanics.</li>
    <li>Staff decisions on server safety and disruptive behavior are considered final.</li>
  </ul>
</section>

<section class='panel'>
  <h3>Roleplay note</h3>
  <p>Roleplay-specific guidelines are managed separately and can be updated by staff as needed. Keep this message for server conduct and expectation-level rules.</p>
</section>

<section class='panel callout'>
  <h3>Get started</h3>
  <p>Read the quick start in your F4 menu, keep gameplay fair, and report concerns through the built-in systems.</p>
</section>
]],
		updated = 0
	}
end

function Admin:LoadMOTD()
	local decoded = util.JSONToTable(file.Read(self.MOTDPath, "DATA") or "", false, true)
	if not istable(decoded) then
		self.MOTD = motdDefaults()
		return
	end
	self.MOTD = {
		enabled = decoded.enabled == true,
		title = cleanMOTDFinal(sanitizeMOTDTitle(decoded.title)),
		html = sanitizeMOTDHTML(decoded.html),
		updated = math.max(0, math.floor(tonumber(decoded.updated) or 0))
	}
end

function Admin:SaveMOTD()
	file.CreateDir("darkrp")
	file.Write(self.MOTDPath, util.TableToJSON(self.MOTD, true))
	local persisted = file.Read(self.MOTDPath, "DATA")
	local decoded = util.JSONToTable(persisted or "", false, true)
	if not istable(decoded) then return false, "MOTD file could not be written." end
	return true
end

local function sendMOTDTo(ply)
	if not IsValid(ply) then return end
	net.Start(motdSyncMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(Admin.MOTD.enabled == true)
	net.WriteString(sanitizeMOTDTitle(Admin.MOTD.title))
	net.WriteString(sanitizeMOTDHTML(Admin.MOTD.html))
	net.WriteUInt(math.max(0, Admin.MOTD.updated % 4294967296), 32)
	net.Send(ply)
end

local function scheduleMOTDSync(ply)
	if not IsValid(ply) then return end
	if ply.DRPSyncQueued or ply.DRPAdminBootstrapDone then return end
	ply.DRPSyncQueued = true
	timer.Simple(0.15, function()
		if not IsValid(ply) then return end
		if ply.DRPAdminBootstrapDone then
			ply.DRPSyncQueued = nil
			return
		end
		ply.DRPSyncQueued = nil
		ply.DRPAdminBootstrapDone = true
		Admin.SyncAccess(ply)
		sendMOTDTo(ply)
	end)
end

local function broadcastMOTD()
	for _, ply in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do sendMOTDTo(ply) end
end

local function forcedMask(rankKey, mask)
	if rankKey == "owner" then return DRP.AdminAllPermissions end
	if rankKey == "user" then return 0 end
	if rankKey == "headadmin" then
		return bit.bor(mask, DRP.AdminPermissionBits.panel, DRP.AdminPermissionBits.users, DRP.AdminPermissionBits.server_interactions, DRP.AdminPermissionBits.adminmode)
	end
	return mask
end

local function cleanRecord(record)
	if not istable(record) then return nil, false end
	local rankKey = string.lower(tostring(record.rank or ""))
	local migrated = false
	if not DRP.AdminRankByKey[rankKey] then
		migrated = true
		if record.owner == true then
			rankKey = "owner"
		elseif cleanMask(record.mask) ~= 0 then
			rankKey = DRP.AdminMaskHas(record.mask, "users") and "headadmin" or "admin"
		else
			rankKey = "user"
		end
	end
	local trusted = record.trusted == true
	local supporterTier = DRP.Supporter.Normalize(record.supporter_tier)
	if record.supporter_tier == nil then
		if rankKey ~= "owner" and record.vip == true then supporterTier = 1 end
		if rankKey == "vip" then supporterTier = math.max(supporterTier, 1) end
		if rankKey == "vipplus" then supporterTier = math.max(supporterTier, 2) end
		if rankKey == "supporter" then supporterTier = 3 end
		migrated = true
	end
	if record.trusted == nil or record.vip ~= nil then migrated = true end
	if rankKey == "user" and not trusted and supporterTier == 0 then return nil, migrated end
	return {
		name = string.sub(tostring(record.name or "Unknown"), 1, 64),
		rank = rankKey,
		trusted = trusted,
		supporter_tier = supporterTier
	}, migrated
end

function Admin:LoadRankMasks()
	local decoded = util.JSONToTable(file.Read(self.RanksPath, "DATA") or "")
	local changed = not istable(decoded)
	local permissionsVersion = istable(decoded) and math.floor(tonumber(decoded._version) or 1) or 1
	for _, rank in ipairs(DRP.AdminRanks) do
		local default = DRP.AdminDefaultRankMasks[rank.key] or 0
		local value = istable(decoded) and decoded[rank.key] or nil
		if permissionsVersion < 2 and rank.key == "headadmin" and value ~= nil then
			value = bit.bor(cleanMask(value), DRP.AdminPermissionBits.props)
			changed = true
		end
		if permissionsVersion < 3 and (rank.key == "headadmin" or rank.key == "admin") and value ~= nil then
			value = bit.bor(cleanMask(value), DRP.AdminPermissionBits.prop_prices)
			changed = true
		end
		if permissionsVersion < 4 and value ~= nil then
			if rank.key == "headadmin" or rank.key == "admin" then
				value = bit.bor(cleanMask(value), DRP.AdminPermissionBits.warnings, DRP.AdminPermissionBits.blacklists)
				changed = true
			elseif rank.key == "moderator" then
				value = bit.bor(cleanMask(value), DRP.AdminPermissionBits.warnings)
				changed = true
			end
		end
		if permissionsVersion < 5 and rank.key == "headadmin" and value ~= nil then
			value = bit.bor(cleanMask(value), DRP.AdminPermissionBits.server_interactions)
			changed = true
		end
		if permissionsVersion < 6 and (rank.key == "headadmin" or rank.key == "admin" or rank.key == "moderator") and value ~= nil then
			value = bit.bor(cleanMask(value), DRP.AdminPermissionBits.adminmode)
			changed = true
		end
		if permissionsVersion < 7 and (rank.key == "headadmin" or rank.key == "admin") and value ~= nil then
			value = bit.bor(cleanMask(value), DRP.AdminPermissionBits.experience)
			changed = true
		end
		if permissionsVersion < 8 and (rank.key == "headadmin" or rank.key == "admin") and value ~= nil then
			value = bit.bor(cleanMask(value), DRP.AdminPermissionBits.civic)
			changed = true
		end
		if permissionsVersion < 9 and (rank.key == "headadmin" or rank.key == "admin") and value ~= nil then
			value = bit.bor(cleanMask(value), DRP.AdminPermissionBits.trust)
			changed = true
		end
		local clean = forcedMask(rank.key, value == nil and default or cleanMask(value))
		self.RankMasks[rank.key] = clean
		if value == nil or cleanMask(value) ~= clean then changed = true end
	end
	if changed then self:SaveRankMasks() end
end

function Admin:Start()
	file.CreateDir("darkrp")
	self:LoadRankMasks()
	self:LoadMOTD()

	-- Preserve SteamID64 object keys as strings; numeric conversion loses
	-- precision for 17-digit identifiers and would silently drop admins.
	local decoded = util.JSONToTable(file.Read(self.DataPath, "DATA") or "", false, true)
	local migrated = false
	if istable(decoded) then
		for steamID64, record in pairs(decoded) do
			if validSteamID64(steamID64) then
				local clean, wasMigrated = cleanRecord(record)
				if clean then self.Records[steamID64] = clean end
				migrated = migrated or wasMigrated
			end
		end
	end
	if migrated then self:Save() end

	local punishments = util.JSONToTable(file.Read(self.PunishmentsPath, "DATA") or "", false, true)
	if not istable(punishments) then return end
	for _, record in ipairs(punishments) do
		local id = math.floor(tonumber(record.id) or 0)
		local kind = record.kind == "blacklist" and "blacklist" or (record.kind == "warning" and "warning" or nil)
		local targetID = tostring(record.target_id or "")
		if id > 0 and kind and validSteamID64(targetID) then
			self.Punishments[#self.Punishments + 1] = {
				id = id,
				kind = kind,
				target_id = targetID,
				target_name = string.sub(tostring(record.target_name or targetID), 1, 64),
				offense = string.sub(tostring(record.offense or "Unspecified offense"), 1, 160),
				issued_at = math.max(0, math.floor(tonumber(record.issued_at) or 0)),
				issuer_id = tostring(record.issuer_id or "SERVER"),
				issuer_name = string.sub(tostring(record.issuer_name or "Server"), 1, 64),
				active = kind == "blacklist" and record.active ~= false or false,
				lifted_at = math.max(0, math.floor(tonumber(record.lifted_at) or 0)),
				lifted_by = string.sub(tostring(record.lifted_by or ""), 1, 64)
			}
			self.NextPunishmentID = math.max(self.NextPunishmentID, id + 1)
		end
	end
end

function Admin:Save()
	file.Write(self.DataPath, util.TableToJSON(self.Records, true))
end

function Admin:SaveRankMasks()
	local encoded = table.Copy(self.RankMasks)
	encoded._version = 9
	file.Write(self.RanksPath, util.TableToJSON(encoded, true))
end

function Admin:SavePunishments()
	file.Write(self.PunishmentsPath, util.TableToJSON(self.Punishments, true))
end

function Admin.Record(value)
	local steamID64 = IsValid(value) and value:SteamID64() or tostring(value or "")
	return Admin.Records[steamID64]
end

function Admin.BaseRankKey(value)
	local record = Admin.Record(value)
	return record and record.rank or "user"
end

function Admin.HasFlag(value, flag)
	flag = string.lower(tostring(flag or ""))
	if flag ~= "trusted" and flag ~= "vip" then return false end
	local record = Admin.Record(value)
	if flag == "vip" then return DRP.Supporter.Tier(value) > 0 end
	return record ~= nil and record.trusted == true
end

function Admin.HasVIP(value)
	local rankKey = Admin.BaseRankKey(value)
	return DRP.Supporter.Tier(value) > 0 or rankKey == "vip" or rankKey == "vipplus" or rankKey == "supporter"
		or DRP.AdminRankLevel(rankKey) >= DRP.AdminRankLevel("headadmin")
end

function Admin.HasTrusted(value)
	return Admin.HasFlag(value, "trusted") or Admin.HasVIP(value)
		or DRP.AdminRankLevel(Admin.BaseRankKey(value)) >= DRP.AdminRankLevel("trusted")
end

function Admin.DisplayRankKey(value)
	local rankKey = Admin.BaseRankKey(value)
	local tier = DRP.Supporter.Tier(value)
	local tierRank = tier == 3 and "supporter" or (tier == 2 and "vipplus" or (tier == 1 and "vip" or nil))
	if tierRank and DRP.AdminRankLevel(rankKey) < DRP.AdminRankLevel(tierRank) then rankKey = tierRank end
	if Admin.HasFlag(value, "trusted") and DRP.AdminRankLevel(rankKey) < DRP.AdminRankLevel("trusted") then rankKey = "trusted" end
	return rankKey
end

-- Compatibility for existing presentation and addon integrations. Staff
-- authority always reads BaseRankKey directly.
function Admin.RankKey(value)
	return Admin.DisplayRankKey(value)
end

function Admin.MaskForRank(rankKey)
	return Admin.RankMasks[DRP.AdminRank(rankKey).key] or 0
end

function Admin.IsOwner(ply)
	return IsValid(ply) and Admin.BaseRankKey(ply) == "owner"
end

function Admin.IsAdmin(ply)
	if not IsValid(ply) then return false end
	local rankKey = Admin.BaseRankKey(ply)
	return DRP.AdminRankLevel(rankKey) >= DRP.AdminRankLevel("moderator")
		or Admin.MaskForRank(rankKey) ~= 0
end

function Admin.Has(ply, permission)
	if not IsValid(ply) then return false end
	return DRP.AdminMaskHas(Admin.MaskForRank(Admin.BaseRankKey(ply)), permission)
end

function Admin.CanSetRanks(ply)
	return IsValid(ply) and DRP.AdminRankLevel(Admin.BaseRankKey(ply)) >= DRP.AdminRankLevel("headadmin")
end

local playerMeta = FindMetaTable("Player")
function playerMeta:DRPIsAdmin() return Admin.IsAdmin(self) end
function playerMeta:DRPHasPermission(permission) return Admin.Has(self, permission) end
function playerMeta:DRPRank() return Admin.RankKey(self) end

function Admin.SyncAccess(ply)
	if not IsValid(ply) then return end
	local rankKey = Admin.DisplayRankKey(ply)
	local baseRankKey = Admin.BaseRankKey(ply)
	ply:SetUserGroup(rankKey)
	net.Start(accessMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(rankKey)
	net.WriteUInt(Admin.MaskForRank(baseRankKey), 32)
	net.WriteBool(baseRankKey == "owner")
	net.WriteString(baseRankKey)
	net.WriteBool(Admin.HasFlag(ply, "trusted"))
	net.WriteUInt(DRP.Supporter.Tier(ply), 2)
	net.WriteBool(Admin.HasVIP(ply))
	net.Send(ply)
	if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.RANK) end
	if DRP.Trust and DRP.Trust.Get and DRP.Trust.Apply then
		local trustState = DRP.Trust:Get(ply)
		if trustState then DRP.Trust:Apply(ply, trustState, false) end
	end
	if DRP.AdminMode and DRP.AdminMode.ValidateAccess then DRP.AdminMode.ValidateAccess(ply) end
	if DRP.WeaponAccess and DRP.WeaponAccess.Enforce then DRP.WeaponAccess.Enforce(ply) end
	if DRP.Inventory and DRP.Inventory.EnforceEquipmentAccess then
		if DRP.Inventory.CaptureEquippedWeaponStates then DRP.Inventory.CaptureEquippedWeaponStates(ply) end
		local changed = DRP.Inventory.EnforceEquipmentAccess(ply, true)
		if not changed and DRP.Inventory.Sync then DRP.Inventory.Sync(ply, false) end
		if DRP.Inventory.ReconcileWeapons and ply:Alive() then DRP.Inventory.ReconcileWeapons(ply, true) end
	end
end

local function onlineBySteamID64(steamID64)
	return DRP.Players.Online(steamID64)
end

local function snapshotEntries()
	local entries, seen = {}, {}
	for _, ply in ipairs(DRP.Players.List) do
		local steamID64 = ply:SteamID64()
		entries[#entries + 1] = {
			entity = ply:EntIndex(), steamID64 = steamID64, name = ply:Nick(),
			rank = Admin.DisplayRankKey(ply), baseRank = Admin.BaseRankKey(ply),
			trusted = Admin.HasFlag(ply, "trusted"), supporterTier = DRP.Supporter.Tier(ply)
		}
		seen[steamID64] = true
	end
	for steamID64, record in pairs(Admin.Records) do
		if not seen[steamID64] then
			entries[#entries + 1] = {
				entity = 0, steamID64 = steamID64, name = record.name,
				rank = Admin.DisplayRankKey(steamID64), baseRank = record.rank,
				trusted = record.trusted == true, supporterTier = DRP.Supporter.Tier(steamID64)
			}
			seen[steamID64] = true
		end
	end
	for steamID64, grant in pairs((DRP.Massie and DRP.Massie.Grants) or {}) do
		if not seen[steamID64] then
			entries[#entries + 1] = {
				entity = 0, steamID64 = steamID64, name = grant.name or steamID64,
				rank = Admin.DisplayRankKey(steamID64), baseRank = Admin.BaseRankKey(steamID64),
				trusted = Admin.HasFlag(steamID64, "trusted"), supporterTier = DRP.Supporter.Tier(steamID64)
			}
			seen[steamID64] = true
		end
	end
	-- Keep punished non-staff selectable after they disconnect, even though
	-- ordinary users are not stored in the staff rank file.
	for index = #Admin.Punishments, 1, -1 do
		local punishment = Admin.Punishments[index]
		if not seen[punishment.target_id] then
			entries[#entries + 1] = {
				entity = 0,
				steamID64 = punishment.target_id,
				name = punishment.target_name,
				rank = Admin.DisplayRankKey(punishment.target_id),
				baseRank = Admin.BaseRankKey(punishment.target_id),
				trusted = Admin.HasFlag(punishment.target_id, "trusted"),
				supporterTier = DRP.Supporter.Tier(punishment.target_id)
			}
			seen[punishment.target_id] = true
		end
	end
	for _, entry in ipairs(entries) do
		local target = onlineBySteamID64(entry.steamID64)
		local trustState = DRP.Trust and DRP.Trust.Cache and DRP.Trust.Cache[entry.steamID64]
		entry.discordLinked = istable(trustState) and trustState.discord_linked == true
		entry.discordVerified = IsValid(target) and target.DRPDiscordRoleVerifiedSession == true
	end
	table.sort(entries, function(a, b)
		if (a.entity > 0) ~= (b.entity > 0) then return a.entity > 0 end
		local rankDifference = DRP.AdminRankLevel(a.rank) - DRP.AdminRankLevel(b.rank)
		if rankDifference ~= 0 then return rankDifference > 0 end
		return string.lower(a.name) < string.lower(b.name)
	end)
	return entries
end

function Admin.SendSnapshot(ply)
	local canViewManagement = Admin.Has(ply, "panel")
	if not canViewManagement and not Admin.Has(ply, "server_interactions") then return end
	local entries = canViewManagement and snapshotEntries() or {}
	local count = math.min(#entries, 255)
	net.Start(snapshotMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(count, 8)
	for index = 1, count do
		local entry = entries[index]
		net.WriteUInt(entry.entity, 13)
		net.WriteString(entry.steamID64)
		net.WriteString(string.sub(entry.name, 1, 64))
		net.WriteString(entry.rank)
		net.WriteString(entry.baseRank or entry.rank)
		net.WriteBool(entry.trusted == true)
		net.WriteUInt(DRP.Supporter.Normalize(entry.supporterTier), 2)
		net.WriteBool(entry.discordLinked == true)
		net.WriteBool(entry.discordVerified == true)
		net.WriteUInt(Admin.MaskForRank(entry.baseRank or entry.rank), 32)
		net.WriteBool(DRP.Massie and DRP.Massie:HasGrant(entry.steamID64) or false)
	end
	local canConfigure = canViewManagement and Admin.IsOwner(ply)
	net.WriteBool(canConfigure)
	if canConfigure then
		net.WriteUInt(#DRP.AdminRanks, 4)
		for _, rank in ipairs(DRP.AdminRanks) do
			net.WriteString(rank.key)
			net.WriteUInt(Admin.MaskForRank(rank.key), 32)
		end
	end
	local punishmentCount = canViewManagement and math.min(#Admin.Punishments, 100) or 0
	net.WriteUInt(punishmentCount, 7)
	for offset = 0, punishmentCount - 1 do
		local punishment = Admin.Punishments[#Admin.Punishments - offset]
		net.WriteUInt(punishment.id % 4294967296, 32)
		net.WriteBool(punishment.kind == "blacklist")
		net.WriteString(punishment.target_id)
		net.WriteString(punishment.target_name)
		net.WriteString(punishment.offense)
		net.WriteUInt(punishment.issued_at % 4294967296, 32)
		net.WriteString(punishment.issuer_name)
		net.WriteBool(punishment.active == true)
		net.WriteUInt((punishment.lifted_at or 0) % 4294967296, 32)
		net.WriteString(punishment.lifted_by or "")
	end
	net.Send(ply)
end

local function deny(ply, permission)
	if DRP.Audit then DRP.Audit.Log(ply, "admin_denied", nil, permission) end
	DRP.Net.Notify(ply, "You do not have permission for that.", 3)
end

DRP.Net.Receive(requestMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "admin_panel", 0.75, 2) then return end
	if not Admin.Has(ply, "panel") and not Admin.Has(ply, "server_interactions") then deny(ply, "panel") return end
	if DRP.Audit then DRP.Audit.Log(ply, "admin_panel_open") end
	Admin.SendSnapshot(ply)
end)

local function sendHealthSnapshot(ply)
	if not IsValid(ply) or not Admin.Has(ply, "server_interactions") then return end
	local services = {}
	for name, status in pairs(DRP.Services.Health or {}) do
		services[#services + 1] = { name = name, started = status.started == true, error = tostring(status.error or "") }
	end
	table.sort(services, function(first, second) return first.name < second.name end)
	local props, propWeight = 0, 0
	local propService = DRP.Services.Get("props")
	if propService then
		for _, count in pairs(propService.CountByOwnerID or {}) do props = props + count end
		for _, weight in pairs(propService.WeightByOwnerID or {}) do propWeight = propWeight + weight end
	end
	net.Start(healthSnapshotMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.min(math.floor(CurTime()), 4294967295), 32)
	net.WriteUInt(math.min(#player.GetAll(), 255), 8)
	net.WriteUInt(math.min(game.MaxPlayers(), 255), 8)
	net.WriteUInt(math.Clamp(math.Round(1 / engine.TickInterval()), 1, 1023), 10)
	net.WriteUInt(math.min(#ents.GetAll(), 65535), 16)
	net.WriteUInt(math.min(table.Count(DRP.Incidents and DRP.Incidents.Active or {}), 65535), 16)
	net.WriteUInt(math.min(DRP.Deadlines and #DRP.Deadlines.Heap or 0, 65535), 16)
	net.WriteUInt(math.min(math.floor(collectgarbage("count")), 4294967295), 32)
	net.WriteBool(DRP.Storage.IsAvailable())
	net.WriteUInt(math.min(DRP.Storage.QueueSize(), 65535), 16)
	net.WriteUInt(math.min(DRP.Storage.ErrorCount or 0, 65535), 16)
	net.WriteString(string.sub(tostring(DRP.Storage.LastError or ""), 1, 160))
	net.WriteUInt(math.min(DRP.Audit and (#DRP.Audit.WriteQueue + #DRP.Audit.ReceiptQueue) or 0, 65535), 16)
	net.WriteUInt(math.min(DRP.Net.SentMessages or 0, 4294967295), 32)
	net.WriteUInt(math.min(DRP.Net.SentBytes or 0, 4294967295), 32)
	net.WriteUInt(math.min(props, 65535), 16)
	net.WriteUInt(math.min(math.floor(propWeight), 4294967295), 32)
	net.WriteUInt(math.min(DRP.Storage.ActivePlayerLoads or 0, 255), 8)
	net.WriteUInt(math.min(DRP.Storage.ActivePocketLoads or 0, 255), 8)
	net.WriteUInt(math.min(propService and table.Count(propService.CatalogTransferIndex or {}) or 0, 255), 8)
	net.WriteUInt(math.min(DRP.ARC9Integration and DRP.ARC9Integration.ActiveExplosives or 0, 255), 8)
	net.WriteUInt(math.min(DRP.ARC9Integration and DRP.ARC9Integration.ActiveAreaEffects or 0, 255), 8)
	net.WriteUInt(math.min(ARC9 and ARC9.PhysBullets and #ARC9.PhysBullets or 0, 65535), 16)
	net.WriteUInt(math.min(#services, 63), 6)
	for index = 1, math.min(#services, 63) do
		local status = services[index]
		net.WriteString(status.name)
		net.WriteBool(status.started)
		net.WriteString(string.sub(status.error, 1, 180))
	end
	net.Send(ply)
end

DRP.Net.Receive(healthRequestMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not DRP.Net.Allow(ply, "admin_health", 0.75, 2) then return end
	if not Admin.Has(ply, "server_interactions") then deny(ply, "server_interactions") return end
	sendHealthSnapshot(ply)
end)

local function cleanAnnouncement(value, maximum)
	value = string.gsub(tostring(value or ""), "\r", "")
	value = string.gsub(value, "[%z\1-\8\11\12\14-\31]", "")
	value = string.Trim(value)
	return string.sub(value, 1, maximum)
end

DRP.Net.Receive(serverInteractionMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local action = net.ReadUInt(2)
	if not DRP.Net.Allow(ply, "server_interaction", 5, 2) then
		DRP.Net.Notify(ply, "Please wait before using another server interaction.", 3)
		return
	end
	if not Admin.Has(ply, "server_interactions") then deny(ply, "server_interactions") return end
	if action ~= 1 then return end

	local title = cleanAnnouncement(net.ReadString(), 48)
	local message = cleanAnnouncement(net.ReadString(), 300)
	if title == "" then title = "SERVER ANNOUNCEMENT" end
	if message == "" then
		DRP.Net.Notify(ply, "Enter an announcement message first.", 3)
		return
	end

	net.Start(serverAnnouncementMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(title)
	net.WriteString(message)
	net.Broadcast()
	if DRP.Audit then DRP.Audit.Log(ply, "global_announcement", nil, title .. ": " .. message) end
end)

DRP.Net.Receive(motdUpdateMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not Admin.IsOwner(ply) then
		DRP.Net.Notify(ply, "Only the server owner can edit MOTD.", 3)
		sendMOTDUpdateResult(ply, false, "Only the server owner can edit MOTD.")
		return
	end
	if not DRP.Net.Allow(ply, "admin_update", 0.5, 3) then
		local waitText = "Please wait briefly before saving again."
		DRP.Net.Notify(ply, waitText, 3)
		sendMOTDUpdateResult(ply, false, waitText)
		return
	end

	Admin.MOTD.enabled = net.ReadBool()
	Admin.MOTD.title = cleanMOTDFinal(sanitizeMOTDTitle(net.ReadString()))
	Admin.MOTD.html = sanitizeMOTDHTML(net.ReadString())
	Admin.MOTD.updated = os.time()

	local saved, reason = Admin:SaveMOTD()
	if not saved then
		DRP.Net.Notify(ply, "MOTD save failed: " .. reason, 3)
		sendMOTDUpdateResult(ply, false, "MOTD save failed: " .. reason)
		return
	end

	broadcastMOTD()
	if DRP.Audit then DRP.Audit.Log(ply, "motd_updated", nil, (Admin.MOTD.title .. " (" .. (Admin.MOTD.enabled and "enabled" or "disabled") .. ")")) end
	sendMOTDUpdateResult(ply, true, "MOTD saved and pushed.")
end)

local function setRankRecord(steamID64, newRank)
	if not validSteamID64(steamID64) or not DRP.AdminRankByKey[newRank] then return false end
	local oldRank = Admin.BaseRankKey(steamID64)
	local existing = Admin.Records[steamID64]
	local target = onlineBySteamID64(steamID64)
	local trusted = existing and existing.trusted == true or false
	local supporterTier = DRP.Supporter.Tier(steamID64)
	if newRank == "vip" then supporterTier = math.max(supporterTier, 1) end
	if newRank == "vipplus" then supporterTier = math.max(supporterTier, 2) end
	if newRank == "supporter" then supporterTier = 3 end
	if newRank == "user" and not trusted and supporterTier == 0 then
		Admin.Records[steamID64] = nil
	else
		Admin.Records[steamID64] = {
			name = IsValid(target) and target:Nick() or (existing and existing.name or steamID64),
			rank = newRank,
			trusted = trusted,
			supporter_tier = supporterTier
		}
	end
	Admin:Save()
	if IsValid(target) then Admin.SyncAccess(target) end
	return true, oldRank, target
end

local canManageEntitlement
function Admin.SetFlag(actor, value, flag, enabled)
	local steamID64 = IsValid(value) and value:SteamID64() or tostring(value or "")
	flag = string.lower(tostring(flag or ""))
	if not validSteamID64(steamID64) or (flag ~= "trusted" and flag ~= "vip") then return false, "Invalid entitlement." end
	if IsValid(actor) and canManageEntitlement then
		local allowed, reason = canManageEntitlement(actor, steamID64, flag)
		if not allowed then return false, reason end
	end
	if flag == "vip" then return Admin.SetSupporterTier(actor, steamID64, enabled and 1 or 0) end
	local existing = Admin.Records[steamID64]
	local target = onlineBySteamID64(steamID64)
	local record = existing or {
		name = IsValid(target) and target:Nick() or steamID64,
		rank = "user",
		trusted = false,
		supporter_tier = 0
	}
	record.name = IsValid(target) and target:Nick() or string.sub(tostring(record.name or steamID64), 1, 64)
	record.rank = DRP.AdminRank(record.rank).key
	record.trusted = record.trusted == true
	record.supporter_tier = DRP.Supporter.Normalize(record.supporter_tier)
	record[flag] = enabled == true
	if record.rank == "user" and not record.trusted and record.supporter_tier == 0 then
		Admin.Records[steamID64] = nil
	else
		Admin.Records[steamID64] = record
	end
	Admin:Save()
	if IsValid(target) then Admin.SyncAccess(target) end
	if DRP.Audit then DRP.Audit.Log(actor, flag .. "_flag_" .. (enabled and "granted" or "revoked"), target or steamID64) end
	return true, nil, target
end

function Admin.SetSupporterTier(actor, value, tier)
	local steamID64 = IsValid(value) and value:SteamID64() or tostring(value or "")
	tier = DRP.Supporter.Normalize(tier)
	if not validSteamID64(steamID64) then return false, "Invalid SteamID." end
	if IsValid(actor) and canManageEntitlement then
		local allowed, reason = canManageEntitlement(actor, steamID64, "vip")
		if not allowed then return false, reason end
	end
	local existing = Admin.Records[steamID64]
	local target = onlineBySteamID64(steamID64)
	local record = existing or { name = IsValid(target) and target:Nick() or steamID64, rank = "user", trusted = false }
	local previous = DRP.Supporter.Normalize(record.supporter_tier)
	record.name = IsValid(target) and target:Nick() or string.sub(tostring(record.name or steamID64), 1, 64)
	record.rank = DRP.AdminRank(record.rank).key
	record.trusted = record.trusted == true
	record.supporter_tier = tier
	record.vip = nil
	if record.rank == "user" and not record.trusted and tier == 0 then Admin.Records[steamID64] = nil else Admin.Records[steamID64] = record end
	Admin:Save()
	if IsValid(target) then Admin.SyncAccess(target) end
	if DRP.Audit then DRP.Audit.Log(actor, "supporter_tier_set", target or steamID64, previous .. " -> " .. tier) end
	return true, nil, target
end

DRP.Net.Receive(updateMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "admin_update", 0.5, 3) then return end
	local steamID64 = string.sub(net.ReadString(), 1, 17)
	local newRank = DRP.AdminRank(net.ReadString()).key
	if not validSteamID64(steamID64) then return end
	if not Admin.CanSetRanks(ply) then deny(ply, "setrank") return end
	if steamID64 == ply:SteamID64() then
		DRP.Net.Notify(ply, "You cannot change your own rank.", 3)
		return
	end

	local oldRank = Admin.BaseRankKey(steamID64)
	if not DRP.AdminCanSetRank(Admin.BaseRankKey(ply), oldRank, newRank) then
		DRP.Net.Notify(ply, "You cannot assign or modify that rank.", 3)
		return
	end

	local function finishRankUpdate()
		if not IsValid(ply) then return end
		local _, _, target = setRankRecord(steamID64, newRank)
		if DRP.Audit then DRP.Audit.Log(ply, "rank_set", target or steamID64, oldRank .. " -> " .. newRank) end
		DRP.Net.Notify(ply, "Rank updated to " .. DRP.AdminRankLabel(newRank) .. ".", 1)
		Admin.SendSnapshot(ply)
	end
	if newRank == "trusted" and oldRank ~= "trusted" then
		if not DRP.Trust or not DRP.Trust.CheckDiscordRole then
			if DRP.Audit then DRP.Audit.Log(ply, "trusted_rank_denied", steamID64, "Discord role service unavailable") end
			DRP.Net.Notify(ply, "Trusted requires a live Discord verification, but the service is unavailable.", 3)
			return
		end
		DRP.Net.Notify(ply, "Checking the user's Discord role...", 0)
		DRP.Trust:CheckDiscordRole(steamID64, function(verified, detail)
			if not IsValid(ply) then return end
			if verified ~= true then
				if DRP.Audit then DRP.Audit.Log(ply, "trusted_rank_denied", steamID64, tostring(detail or "Discord role not verified")) end
				DRP.Net.Notify(ply, "Trusted denied: " .. string.sub(tostring(detail or "Discord role not verified."), 1, 120), 3)
				return
			end
			local stillAllowed = DRP.AdminCanSetRank(Admin.BaseRankKey(ply), Admin.BaseRankKey(steamID64), newRank)
			if stillAllowed then finishRankUpdate() else DRP.Net.Notify(ply, "The rank hierarchy changed during verification.", 3) end
		end)
		return
	end
	finishRankUpdate()
end)

canManageEntitlement = function(actor, steamID64, flag)
	if not IsValid(actor) or steamID64 == actor:SteamID64() then return false, "You cannot change your own entitlements." end
	local actorRank = Admin.BaseRankKey(actor)
	local targetRank = Admin.BaseRankKey(steamID64)
	local minimum = flag == "vip" and "headadmin" or "admin"
	if DRP.AdminRankLevel(actorRank) < DRP.AdminRankLevel(minimum) then
		return false, flag == "vip" and "VIP flags require HeadAdmin+." or "Trusted flags require Admin+."
	end
	if targetRank == "owner" or (not Admin.IsOwner(actor) and DRP.AdminRankLevel(targetRank) >= DRP.AdminRankLevel(actorRank)) then
		return false, "That user's base rank is protected by the staff hierarchy."
	end
	return true
end

local function finishEntitlementUpdate(actor, steamID64, flag, enabled)
	local allowed, reason = canManageEntitlement(actor, steamID64, flag)
	if not allowed then
		if IsValid(actor) then DRP.Net.Notify(actor, reason, 3) end
		return false
	end
	local changed, setReason, target = Admin.SetFlag(actor, steamID64, flag, enabled)
	if not changed then DRP.Net.Notify(actor, setReason or "Entitlement could not be changed.", 3) return false end
	DRP.Net.Notify(actor, (flag == "vip" and "VIP" or "Trusted") .. " entitlement " .. (enabled and "granted." or "revoked."), 1)
	Admin.SendSnapshot(actor)
	return true
end

DRP.Net.Receive(entitlementUpdateMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "admin_entitlement_update", 1, 2) then return end
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local steamID64 = normalizeSteamID(string.sub(net.ReadString(), 1, 96))
	local flag = net.ReadBool() and "vip" or "trusted"
	local enabled = net.ReadBool()
	if not validSteamID64(steamID64) then return end
	local allowed, reason = canManageEntitlement(ply, steamID64, flag)
	if not allowed then DRP.Net.Notify(ply, reason, 3) return end

	if flag ~= "trusted" or not enabled then
		finishEntitlementUpdate(ply, steamID64, flag, enabled)
		return
	end
	if not DRP.Trust or not DRP.Trust.CheckDiscordRole then
		if DRP.Audit then DRP.Audit.Log(ply, "trusted_flag_denied", steamID64, "Discord role service unavailable") end
		DRP.Net.Notify(ply, "Trusted requires a live Discord verification, but the service is unavailable.", 3)
		return
	end
	DRP.Net.Notify(ply, "Checking the user's Discord role...", 0)
	DRP.Trust:CheckDiscordRole(steamID64, function(verified, detail)
		if not IsValid(ply) then return end
		if verified ~= true then
			if DRP.Audit then DRP.Audit.Log(ply, "trusted_flag_denied", steamID64, tostring(detail or "Discord role not verified")) end
			DRP.Net.Notify(ply, "Trusted denied: " .. string.sub(tostring(detail or "Discord role not verified."), 1, 120), 3)
			return
		end
		finishEntitlementUpdate(ply, steamID64, flag, true)
	end)
end)

DRP.Net.Receive(supporterTierUpdateMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "admin_supporter_tier_update", 1, 2) then return end
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local steamID64 = normalizeSteamID(string.sub(net.ReadString(), 1, 96))
	local tier = net.ReadUInt(2)
	if not validSteamID64(steamID64) then return end
	local changed, reason = Admin.SetSupporterTier(ply, steamID64, tier)
	if not changed then DRP.Net.Notify(ply, reason or "Supporter tier could not be changed.", 3) return end
	local definition = DRP.Supporter.Definition(tier)
	DRP.Net.Notify(ply, "Supporter tier updated to " .. definition.label .. ".", 1)
	Admin.SendSnapshot(ply)
end)

DRP.Net.Receive(rankPermissionsMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "admin_rank_permissions", 0.5, 3) then return end
	local rankKey = DRP.AdminRank(net.ReadString()).key
	local mask = cleanMask(net.ReadUInt(32))
	if not Admin.IsOwner(ply) then deny(ply, "rank_permissions") return end
	if rankKey == "owner" or rankKey == "user" then
		DRP.Net.Notify(ply, "That rank has fixed permissions.", 3)
		return
	end

	Admin.RankMasks[rankKey] = forcedMask(rankKey, mask)
	Admin:SaveRankMasks()
	for _, target in ipairs(DRP.Players.List) do
		if Admin.BaseRankKey(target) == rankKey then Admin.SyncAccess(target) end
	end
	if DRP.Audit then DRP.Audit.Log(ply, "rank_permissions_set", nil, rankKey .. " mask=" .. Admin.RankMasks[rankKey]) end
	DRP.Net.Notify(ply, DRP.AdminRankLabel(rankKey) .. " permissions updated.", 1)
	Admin.SendSnapshot(ply)
end)

local function cleanOffense(value)
	local offense = string.Trim(string.gsub(tostring(value or ""), "%s+", " "))
	return string.sub(offense, 1, 160)
end

local function punishmentByID(id)
	id = math.floor(tonumber(id) or 0)
	for _, punishment in ipairs(Admin.Punishments) do
		if punishment.id == id then return punishment end
	end
end

local function activeBlacklist(steamID64)
	for index = #Admin.Punishments, 1, -1 do
		local punishment = Admin.Punishments[index]
		if punishment.kind == "blacklist" and punishment.active and punishment.target_id == steamID64 then return punishment end
	end
end

Admin.ActiveBlacklist = activeBlacklist

local function targetName(steamID64)
	local target = onlineBySteamID64(steamID64)
	if IsValid(target) then return string.sub(target:Nick(), 1, 64), target end
	local record = Admin.Records[steamID64]
	if record then return record.name end
	for index = #Admin.Punishments, 1, -1 do
		local punishment = Admin.Punishments[index]
		if punishment.target_id == steamID64 then return punishment.target_name end
	end
	return steamID64
end

local function canPunish(actor, targetID)
	if targetID == actor:SteamID64() then return false, "You cannot punish yourself." end
	local actorRank = Admin.BaseRankKey(actor)
	local targetRank = Admin.BaseRankKey(targetID)
	if targetRank == "owner" then return false, "The server owner is protected." end
	if actorRank ~= "owner" and DRP.AdminRankLevel(targetRank) >= DRP.AdminRankLevel(actorRank) then
		return false, "You cannot punish an equal or higher rank."
	end
	return true
end

local function announcePunishment(punishment)
	for _, recipient in ipairs(DRP.Players.List) do
		net.Start(punishmentAnnouncementMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteBool(punishment.kind == "blacklist")
		net.WriteString(punishment.target_name)
		net.WriteString(punishment.offense)
		net.WriteUInt(punishment.issued_at % 4294967296, 32)
		local includeIssuer = Admin.IsAdmin(recipient)
		net.WriteBool(includeIssuer)
		if includeIssuer then net.WriteString(punishment.issuer_name) end
		net.Send(recipient)
	end
end

DRP.Net.Receive(punishmentMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local action = net.ReadUInt(2)
	if not DRP.Net.Allow(ply, "admin_punishment", 0.75, 3) then return end

	if action == 3 then
		local punishment = punishmentByID(net.ReadUInt(32))
		local permission = punishment and punishment.kind == "blacklist" and "blacklists" or "warnings"
		if not Admin.Has(ply, permission) then deny(ply, permission) return end
		if not DRP.AdminMode or not DRP.AdminMode.IsActive(ply) then
			DRP.Net.Notify(ply, "Enable Admin Mode before revoking punishments.", 3)
			return
		end
		local revocable = punishment and ((punishment.kind == "blacklist" and punishment.active) or (punishment.kind == "warning" and (punishment.lifted_at or 0) == 0))
		if not revocable then
			DRP.Net.Notify(ply, "That punishment has already been revoked.", 3)
			return
		end
		local allowed, reason = canPunish(ply, punishment.target_id)
		if not allowed then DRP.Net.Notify(ply, reason, 3) return end
		punishment.active = false
		punishment.lifted_at = os.time()
		punishment.lifted_by = string.sub(ply:Nick(), 1, 64)
		Admin:SavePunishments()
		if DRP.Audit then DRP.Audit.Log(ply, punishment.kind == "blacklist" and "blacklist_revoked" or "warning_revoked", punishment.target_id, punishment.offense) end
		DRP.Net.Notify(ply, DRP.AdminRankLabel(Admin.RankKey(ply)) .. " revoked the " .. punishment.kind .. " for " .. punishment.target_name .. ".", 1)
		Admin.SendSnapshot(ply)
		return
	end

	local targetInput = string.sub(net.ReadString(), 1, 96)
	local targetID = normalizeSteamID(targetInput)
	local offense = cleanOffense(net.ReadString())
	local permission = action == 1 and "warnings" or (action == 2 and "blacklists" or nil)
	if not permission or not targetID or offense == "" then
		DRP.Net.Notify(ply, "Enter a valid SteamID/SteamID3/SteamID64 and offense.", 3)
		return
	end
	if not Admin.Has(ply, permission) then deny(ply, permission) return end
	local allowed, reason = canPunish(ply, targetID)
	if not allowed then DRP.Net.Notify(ply, reason, 3) return end
	if action == 2 and activeBlacklist(targetID) then
		DRP.Net.Notify(ply, "That player already has an active blacklist.", 3)
		return
	end

	local name, target = targetName(targetID)
	local punishment = {
		id = Admin.NextPunishmentID,
		kind = action == 2 and "blacklist" or "warning",
		target_id = targetID,
		target_name = name,
		offense = offense,
		issued_at = os.time(),
		issuer_id = ply:SteamID64(),
		issuer_name = string.sub(ply:Nick(), 1, 64),
		active = action == 2,
		lifted_at = 0,
		lifted_by = ""
	}
	Admin.NextPunishmentID = Admin.NextPunishmentID + 1
	Admin.Punishments[#Admin.Punishments + 1] = punishment
	Admin:SavePunishments()
	announcePunishment(punishment)
	if DRP.Audit then DRP.Audit.Log(ply, punishment.kind .. "_issued", target or targetID, offense) end
	DRP.Net.Notify(ply, punishment.kind == "warning" and ("Warning issued to " .. name .. ".") or (name .. " was blacklisted."), 1)
	Admin.SendSnapshot(ply)
	if IsValid(target) and punishment.kind == "blacklist" then
		timer.Simple(0.75, function()
			if IsValid(target) then target:Kick("Blacklisted: " .. offense) end
		end)
	end
end)

local function safePosition(target, direction)
	local origin = target:GetPos() + direction * 72 + Vector(0, 0, 8)
	local trace = util.TraceHull({
		start = origin, endpos = origin, mins = Vector(-16, -16, 0),
		maxs = Vector(16, 16, 72), mask = MASK_PLAYERSOLID
	})
	return trace.Hit and target:GetPos() + Vector(0, 0, 16) or origin
end

DRP.Net.Receive(actionMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "admin_action", 0.35, 3) then return end
	local action = DRP.AdminActionByID[net.ReadUInt(3)]
	local target = Entity(net.ReadUInt(13))
	if not action or not IsValid(target) or not target:IsPlayer() then return end
	if not Admin.Has(ply, action.permission) then deny(ply, action.permission) return end
	if target ~= ply and Admin.IsOwner(target) then
		DRP.Net.Notify(ply, "The server owner is protected.", 3)
		return
	end

	local actorLevel = DRP.AdminRankLevel(Admin.BaseRankKey(ply))
	local targetLevel = DRP.AdminRankLevel(Admin.BaseRankKey(target))
	if target ~= ply and action.key ~= "goto" and not Admin.IsOwner(ply) and targetLevel >= actorLevel then
		DRP.Net.Notify(ply, "You cannot use that action on an equal or higher rank.", 3)
		return
	end

	if DRP.Audit then DRP.Audit.Log(ply, "admin_" .. action.key, target) end
	if action.key == "kick" then
		target:Kick("Removed by an administrator")
	elseif action.key == "slay" then
		if target:Alive() then target:Kill() end
	elseif action.key == "bring" then
		target:SetPos(safePosition(ply, ply:GetForward()))
	elseif action.key == "goto" then
		ply:SetPos(safePosition(target, target:GetForward()))
	end
end)

hook.Add("PlayerInitialSpawn", "DRP.Admin.InitialSync", function(ply)
	scheduleMOTDSync(ply)
end)

hook.Add("PlayerAuthed", "DRP.Admin.AuthenticatedSync", function(ply)
	local blacklist = activeBlacklist(ply:SteamID64())
	if blacklist then
		ply:Kick("Blacklisted: " .. blacklist.offense)
		return
	end
	scheduleMOTDSync(ply)
end)

hook.Add("PlayerDisconnected", "DRP.Admin.RememberName", function(ply)
	local record = Admin.Record(ply)
	if not record then return end
	record.name = string.sub(ply:Nick(), 1, 64)
	Admin:Save()
end)

local function isServerRankOperator(ply)
	if not IsValid(ply) then return true end
	if game.IsDedicated() then return false end
	if game.SinglePlayer() or ply:IsListenServerHost() then return true end

	-- Some client branches do not flag the host correctly while starting a
	-- multiplayer listen server. The host is the first connected human there.
	return ply == player.GetHumans()[1]
end

concommand.Add("drp_admin_owner", function(ply, _, values)
	if not isServerRankOperator(ply) then return end
	local steamID64 = tostring(values[1] or "")
	if not validSteamID64(steamID64) then print("Usage: drp_admin_owner <SteamID64>") return end
	local _, _, target = setRankRecord(steamID64, "owner")
	if DRP.Audit then DRP.Audit.Log(nil, "owner_granted", target or steamID64) end
	print("[DRP] owner granted to " .. steamID64)
end)

concommand.Add("drp_setrank", function(ply, _, values)
	-- Dedicated servers restrict this to their console. A listen-server host is
	-- the local server operator and has no separate server console window.
	if not isServerRankOperator(ply) then
		DRP.Net.Notify(ply, "drp_setrank can only be run from the server console.", 3)
		return
	end
	local steamID64 = tostring(values[1] or "")
	local newRank = string.lower(string.Trim(tostring(values[2] or "")))
	if not validSteamID64(steamID64) or not DRP.AdminRankByKey[newRank] then
		print("Usage: drp_setrank <SteamID64> <owner|headadmin|admin|moderator|supporter|vipplus|vip|trusted|user>")
		return
	end
	local oldRank = Admin.BaseRankKey(steamID64)
	local function applyConsoleRank()
		local changed, previousRank, target = setRankRecord(steamID64, newRank)
		if not changed then print("[DRP] rank update failed for " .. steamID64) return end
		if DRP.Audit then DRP.Audit.Log(nil, "rank_set_console", target or steamID64, previousRank .. " -> " .. newRank) end
		print("[DRP] rank updated: " .. steamID64 .. " " .. previousRank .. " -> " .. newRank)
	end
	if newRank == "trusted" and oldRank ~= "trusted" then
		if not DRP.Trust or not DRP.Trust.CheckDiscordRole then
			print("[DRP] Trusted rank denied: Discord role service unavailable")
			return
		end
		print("[DRP] checking Discord verification for " .. steamID64 .. "...")
		DRP.Trust:CheckDiscordRole(steamID64, function(verified, detail)
			if verified == true then applyConsoleRank() else print("[DRP] Trusted rank denied: " .. tostring(detail or "Discord role not verified")) end
		end)
		return
	end
	applyConsoleRank()
end)
