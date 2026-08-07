local announceMessage = "drp_trust_announce_v1"
local linkMessage = "drp_trust_link_v1"
local inviteMessage = "drp_trust_invite_v1"
local inspectRequestMessage = "drp_trust_inspect_request_v1"
local inspectResponseMessage = "drp_trust_inspect_response_v1"
local selfMessage = "drp_trust_self_v1"
local selfActionMessage = "drp_trust_self_action_v1"
util.AddNetworkString(announceMessage)
util.AddNetworkString(linkMessage)
util.AddNetworkString(inviteMessage)
util.AddNetworkString(inspectRequestMessage)
util.AddNetworkString(inspectResponseMessage)
util.AddNetworkString(selfMessage)
util.AddNetworkString(selfActionMessage)

local Trust = {
	Cache = {},
	Attempts = {},
	Evaluations = setmetatable({}, { __mode = "k" }),
	PendingLinks = {},
	RoleChecks = {},
	Config = nil,
	ConfigPath = "darkrp/trust.json",
	RefreshSeconds = 86400,
	NetworkRefreshSeconds = 21600,
	GModAppID = 4000,
	MaximumSignals = 8
}

DRP.Trust = Trust
DRP.Services.Register("trust", Trust)

local function clean(value, maximum)
	return string.sub(string.Trim(tostring(value or "")), 1, maximum or 96)
end

local function defaultConfig()
	return {
		version = 1,
		steam_web_api_key = "",
		steam_refresh_seconds = 86400,
		network_refresh_seconds = 21600,
		vpn = {
			lookup_url = "",
			headers = {},
			boolean_paths = { "vpn", "proxy", "security.vpn", "security.proxy" }
		},
			discord = {
			link_url = "",
			verify_url = "",
			member_status_url = "",
			unlink_url = "",
			bot_start_url = "",
			bot_invite_url = "",
			bot_heartbeat_url = "",
			bot_offline_url = "",
			bot_chat_url = "",
			bot_inbox_url = "",
			global_chat_channel_id = "",
			role_required = true,
			verification_timeout_seconds = 600,
			headers = {},
			link_secret = util.SHA256(tostring(SysTime()) .. ":" .. tostring(os.time()) .. ":" .. tostring(math.random()))
		}
	}
end

local function normalizeConfig(value)
	local config = istable(value) and value or defaultConfig()
	config.version = 1
	config.steam_web_api_key = clean(config.steam_web_api_key, 128)
	config.steam_refresh_seconds = math.Clamp(math.floor(tonumber(config.steam_refresh_seconds) or 86400), 3600, 604800)
	config.network_refresh_seconds = math.Clamp(math.floor(tonumber(config.network_refresh_seconds) or 21600), 1800, 604800)
	config.vpn = istable(config.vpn) and config.vpn or {}
	config.vpn.lookup_url = clean(config.vpn.lookup_url, 512)
	config.vpn.headers = istable(config.vpn.headers) and config.vpn.headers or {}
	config.vpn.boolean_paths = istable(config.vpn.boolean_paths) and config.vpn.boolean_paths or { "vpn", "proxy" }
	config.discord = istable(config.discord) and config.discord or {}
	config.discord.link_url = clean(config.discord.link_url, 512)
	config.discord.verify_url = clean(config.discord.verify_url, 512)
	config.discord.member_status_url = clean(config.discord.member_status_url, 512)
	if config.discord.member_status_url == "" then
		local memberBase = string.match(config.discord.verify_url, "^(.-)/discord/status")
		if memberBase then config.discord.member_status_url = memberBase .. "/discord/member-status?steamid={steamid}&channel_id={channel_id}" end
	end
	config.discord.unlink_url = clean(config.discord.unlink_url, 512)
	config.discord.bot_start_url = clean(config.discord.bot_start_url, 512)
	config.discord.bot_invite_url = clean(config.discord.bot_invite_url, 512)
	if config.discord.bot_invite_url == "" then
		local botBase = string.match(config.discord.bot_start_url, "^(.-)/discord/bot/start")
		if botBase then config.discord.bot_invite_url = botBase .. "/discord/bot/invite?channel_id={channel_id}" end
	end
	config.discord.bot_heartbeat_url = clean(config.discord.bot_heartbeat_url, 512)
	config.discord.bot_offline_url = clean(config.discord.bot_offline_url, 512)
	config.discord.bot_chat_url = clean(config.discord.bot_chat_url, 512)
	config.discord.bot_inbox_url = clean(config.discord.bot_inbox_url, 512)
	if config.discord.bot_inbox_url == "" and string.sub(config.discord.bot_chat_url, -5) == "/chat" then
		config.discord.bot_inbox_url = string.sub(config.discord.bot_chat_url, 1, -6) .. "/inbox?channel_id={channel_id}"
	end
	config.discord.global_chat_channel_id = clean(config.discord.global_chat_channel_id, 22)
	config.discord.role_required = config.discord.role_required ~= false
	config.discord.verification_timeout_seconds = math.Clamp(
		math.floor(tonumber(config.discord.verification_timeout_seconds) or 600), 60, 3600)
	config.discord.headers = istable(config.discord.headers) and config.discord.headers or {}
	config.discord.link_secret = clean(config.discord.link_secret, 128)
	if config.discord.link_secret == "" then
		config.discord.link_secret = util.SHA256(tostring(SysTime()) .. ":" .. tostring(os.time()) .. ":" .. tostring(math.random()))
	end
	return config
end

local function stateKey(steamID64)
	return "trust:" .. clean(steamID64, 24)
end

local function canAttempt(key, cooldown)
	local now = CurTime()
	if table.Count(Trust.Attempts) > 2048 then
		for attemptKey, expires in pairs(Trust.Attempts) do
			if expires <= now then Trust.Attempts[attemptKey] = nil end
		end
	end
	if (Trust.Attempts[key] or 0) > now then return false end
	Trust.Attempts[key] = now + (cooldown or 300)
	return true
end

local function normalizeState(value)
	local state = istable(value) and value or {}
	state.version = 1
	state.score = math.Clamp(math.floor(tonumber(state.score) or 50), 0, 100)
	state.known = math.Clamp(math.floor(tonumber(state.known) or 0), 0, Trust.MaximumSignals)
	state.updated_at = math.max(0, math.floor(tonumber(state.updated_at) or 0))
	state.steam_owned_checked = math.max(0, math.floor(tonumber(state.steam_owned_checked) or 0))
	state.steam_bans_checked = math.max(0, math.floor(tonumber(state.steam_bans_checked) or 0))
	state.network_checked = math.max(0, math.floor(tonumber(state.network_checked) or 0))
	state.network_hash = clean(state.network_hash, 32)
	state.steam_owned_known = state.steam_owned_known == true
	state.steam_game_count = math.max(0, math.floor(tonumber(state.steam_game_count) or 0))
	state.gmod_minutes = math.max(0, math.floor(tonumber(state.gmod_minutes) or 0))
	state.gmod_visible = state.gmod_visible == true
	state.vac_known = state.vac_known == true
	state.vac_bans = math.max(0, math.floor(tonumber(state.vac_bans) or 0))
	state.game_bans = math.max(0, math.floor(tonumber(state.game_bans) or 0))
	state.days_since_ban = math.max(0, math.floor(tonumber(state.days_since_ban) or 0))
	state.vpn_known = state.vpn_known == true
	state.vpn_detected = state.vpn_detected == true
	local discordID = clean(state.discord_id, 32)
	state.discord_role_granted = state.discord_role_granted == true
	state.discord_linked = state.discord_linked == true and discordID ~= ""
	state.discord_role_checked_at = math.max(0, math.floor(tonumber(state.discord_role_checked_at) or 0))
	-- Keep a formerly verified identity even if an old snapshot predates the
	-- role flag. It lets the server confirm the live Discord role safely.
	state.discord_id = discordID
	state.discord_name = discordID ~= "" and clean(state.discord_name, 64) or ""
	state.reasons = istable(state.reasons) and state.reasons or {}
	return state
end

local function trustLabel(score)
	if score >= 80 then return "ESTABLISHED" end
	if score >= 65 then return "TRUSTED" end
	if score >= 45 then return "UNVERIFIED" end
	if score >= 25 then return "ELEVATED RISK" end
	return "HIGH RISK"
end

function Trust.ScoreSignals(signals)
	signals = istable(signals) and signals or {}
	local score, known, reasons = 60, 0, {}

	if signals.returning ~= nil then
		known = known + 1
		if signals.returning then
			score = score + 8
			reasons[#reasons + 1] = "returning server player +8"
		else
			score = score - 5
			reasons[#reasons + 1] = "first server session -5"
		end
	end

	if signals.serverHours ~= nil then
		known = known + 1
		local hours = math.max(0, tonumber(signals.serverHours) or 0)
		if hours >= 50 then score = score + 15 reasons[#reasons + 1] = "50+ server hours +15"
		elseif hours >= 10 then score = score + 10 reasons[#reasons + 1] = "10+ server hours +10"
		elseif hours >= 2 then score = score + 4 reasons[#reasons + 1] = "2+ server hours +4"
		elseif hours < 1 then score = score - 8 reasons[#reasons + 1] = "under one server hour -8"
		else reasons[#reasons + 1] = "limited server history" end
	end

	if signals.gmodHours ~= nil then
		known = known + 1
		local hours = math.max(0, tonumber(signals.gmodHours) or 0)
		if hours >= 1000 then score = score + 12 reasons[#reasons + 1] = "1000+ Garry's Mod hours +12"
		elseif hours >= 300 then score = score + 9 reasons[#reasons + 1] = "300+ Garry's Mod hours +9"
		elseif hours >= 100 then score = score + 6 reasons[#reasons + 1] = "100+ Garry's Mod hours +6"
		elseif hours >= 20 then score = score + 2 reasons[#reasons + 1] = "20+ Garry's Mod hours +2"
		elseif hours < 10 then score = score - 10 reasons[#reasons + 1] = "under ten Garry's Mod hours -10"
		else reasons[#reasons + 1] = "limited Garry's Mod history" end
	end

	if signals.onlyGMod ~= nil then
		known = known + 1
		if signals.onlyGMod then
			score = score - 12
			reasons[#reasons + 1] = "Garry's Mod is the only visible owned game -12"
		else
			score = score + 3
			reasons[#reasons + 1] = "established visible Steam library +3"
		end
	end

	if signals.vacBans ~= nil then
		known = known + 1
		local bans = math.max(0, math.floor(tonumber(signals.vacBans) or 0))
		if bans > 0 then
			local penalty = math.min(35, 18 + (bans - 1) * 5)
			score = score - penalty
			reasons[#reasons + 1] = bans .. " VAC ban(s) -" .. penalty
			if (tonumber(signals.daysSinceBan) or 99999) < 365 then
				score = score - 7
				reasons[#reasons + 1] = "recent VAC ban -7"
			end
		else
			score = score + 4
			reasons[#reasons + 1] = "no VAC bans +4"
		end
	end

	if signals.vpn ~= nil then
		known = known + 1
		if signals.vpn then
			score = score - 15
			reasons[#reasons + 1] = "VPN or proxy detected -15"
		else
			score = score + 3
			reasons[#reasons + 1] = "ordinary network reputation +3"
		end
	end

	known = known + 1
	if signals.discordLinked then
		score = score + 8
		reasons[#reasons + 1] = "Discord identity linked +8"
	else
		reasons[#reasons + 1] = "Discord identity not linked"
	end

	known = known + 1
	if signals.trustedRank then
		score = score + 10
		reasons[#reasons + 1] = "Trusted or higher server rank +10"
	else
		reasons[#reasons + 1] = "standard server rank"
	end

	score = math.Clamp(math.floor(score), 0, 100)
	return score, known, reasons, trustLabel(score)
end

local function buildSignals(ply, state)
	local serverSeconds = math.max(0, tonumber(ply.DRPTotalPlaytimeBase) or 0)
	local signals = {
		returning = serverSeconds > 0,
		serverHours = serverSeconds / 3600,
		discordLinked = state.discord_linked == true,
		trustedRank = DRP.Admin and DRP.AdminRankLevel(DRP.Admin.BaseRankKey(ply)) >= DRP.AdminRankLevel("trusted") or false
	}
	if state.steam_owned_known then
		if state.gmod_visible then
			signals.gmodHours = state.gmod_minutes / 60
			signals.onlyGMod = state.steam_game_count == 1
		elseif state.steam_game_count > 1 then
			signals.onlyGMod = false
		end
	end
	if state.vac_known then
		signals.vacBans = state.vac_bans
		signals.daysSinceBan = state.days_since_ban
	end
	if state.vpn_known then signals.vpn = state.vpn_detected end
	return signals
end

local function headers(value)
	local output = {}
	for key, headerValue in pairs(istable(value) and value or {}) do
		key = clean(key, 64)
		if key ~= "" then output[key] = clean(headerValue, 256) end
	end
	return output
end

local function requestJSON(url, requestHeaders, callback)
	local finished = false
	local function finish(success, data, reason)
		if finished then return end
		finished = true
		callback(success, data, reason)
	end
	local started = HTTP({
		url = url,
		method = "get",
		headers = headers(requestHeaders),
		success = function(code, body)
			if code < 200 or code >= 300 then finish(false, nil, "HTTP " .. code) return end
			local decoded = util.JSONToTable(body or "")
			if not istable(decoded) then finish(false, nil, "invalid JSON") return end
			finish(true, decoded)
		end,
		failed = function(reason) finish(false, nil, reason) end
	})
	if started == false then finish(false, nil, "request rejected") end
end

local function postJSON(url, requestHeaders, payload, callback)
	local finished = false
	local function finish(success, data, reason)
		if finished then return end
		finished = true
		if callback then callback(success, data, reason) end
	end
	local requestHeadersClean = headers(requestHeaders)
	requestHeadersClean["Content-Type"] = "application/json"
	local body = util.TableToJSON(payload or {}, false)
	if not body then finish(false, nil, "JSON encoding failed") return end
	local started = HTTP({
		url = url,
		method = "post",
		headers = requestHeadersClean,
		type = "application/json",
		body = body,
		success = function(code, responseBody)
			if code < 200 or code >= 300 then finish(false, nil, "HTTP " .. code) return end
			local decoded = util.JSONToTable(responseBody or "")
			finish(true, istable(decoded) and decoded or {})
		end,
		failed = function(reason) finish(false, nil, reason) end
	})
	if started == false then finish(false, nil, "request rejected") end
end

local function encode(value)
	return string.gsub(tostring(value or ""), "([^%w%-_%.~])", function(character)
		return string.format("%%%02X", string.byte(character))
	end)
end

local function endpoint(template, values)
	local output, replaced = tostring(template or ""), false
	for key, value in pairs(values or {}) do
		local token = "{" .. key .. "}"
		if string.find(output, token, 1, true) then
			output = string.gsub(output, token, function() return encode(value) end)
			replaced = true
		end
	end
	if replaced then return output end
	local separator = string.find(output, "?", 1, true) and "&" or "?"
	local parts = {}
	for key, value in pairs(values or {}) do parts[#parts + 1] = encode(key) .. "=" .. encode(value) end
	table.sort(parts)
	return output .. separator .. table.concat(parts, "&")
end

local function valueAtPath(root, path)
	local value = root
	for segment in string.gmatch(tostring(path or ""), "[^%.]+") do
		if not istable(value) then return nil end
		value = value[segment]
	end
	return value
end

local function playerIP(ply)
	local address = clean(IsValid(ply) and ply:IPAddress() or "", 96)
	if address == "" or address == "loopback" then return nil end
	local bracketed = string.match(address, "^%[([^%]]+)%]:%d+$")
	if bracketed then address = bracketed else address = string.gsub(address, ":%d+$", "") end
	local subnet172 = tonumber(string.match(address, "^172%.(%d+)%."))
	if address == "127.0.0.1" or address == "::1" or string.StartWith(address, "10.")
		or string.StartWith(address, "192.168.") or subnet172 and subnet172 >= 16 and subnet172 <= 31 then
		return nil
	end
	return address
end

local function discordDeadlineTimer(steamID64)
	return "DRP.Trust.DiscordRoleDeadline." .. tostring(steamID64 or "")
end

local function discordDeadlineWarningTimer(steamID64)
	return "DRP.Trust.DiscordRoleWarning." .. tostring(steamID64 or "")
end

function Trust:ClearDiscordRoleDeadline(plyOrSteamID64)
	local steamID64 = IsValid(plyOrSteamID64) and plyOrSteamID64:SteamID64() or tostring(plyOrSteamID64 or "")
	timer.Remove(discordDeadlineTimer(steamID64))
	timer.Remove(discordDeadlineWarningTimer(steamID64))
end

function Trust:IsDiscordKickExempt(ply, rawState)
	if not IsValid(ply) then return true end
	return ply.DRPDiscordRoleVerifiedSession == true
end

function Trust:CheckDiscordRole(steamID64, callback, rawState)
	callback = isfunction(callback) and callback or function() end
	steamID64 = tostring(steamID64 or "")
	if #steamID64 ~= 17 or not string.match(steamID64, "^%d+$") then callback(nil, "invalid SteamID64") return false end
	local state = normalizeState(rawState or self.Cache[steamID64])
	local config = self.Config and self.Config.discord
	if not config or config.member_status_url == "" then
		callback(nil, "role service unavailable")
		return false
	end

	local pending = self.RoleChecks[steamID64]
	if pending then
		pending[#pending + 1] = callback
		return true
	end
	self.RoleChecks[steamID64] = { callback }
	requestJSON(endpoint(config.member_status_url, {
		steamid = steamID64,
		channel_id = config.global_chat_channel_id
	}), config.headers, function(success, data, reason)
		local callbacks = self.RoleChecks[steamID64] or {}
		self.RoleChecks[steamID64] = nil
		local result, detail
		if not success then
			result, detail = nil, clean(reason or "role lookup failed", 96)
		elseif data.checked ~= true then
			result, detail = nil, clean(data.error or "role lookup was not authoritative", 96)
		elseif data.role_granted == true then
			result, detail = true, "live role"
			local target = DRP.Players.Online(steamID64)
			if IsValid(target) then
				local current = normalizeState(self.Cache[steamID64])
				current.discord_linked = true
				current.discord_role_granted = true
				current.discord_id = clean(data.discord_id or state.discord_id, 32)
				current.discord_name = clean(data.discord_name or current.discord_name, 64)
				current.discord_role_checked_at = os.time()
				target.DRPDiscordRoleVerifiedSession = true
				self:Apply(target, current, false)
			end
		else
			local target = DRP.Players.Online(steamID64)
			if IsValid(target) then target.DRPDiscordRoleVerifiedSession = false end
			result, detail = false, clean(data.error or "DarkRP role absent", 96)
		end
		for _, done in ipairs(callbacks) do done(result, detail) end
	end)
	return true
end

function Trust:CheckExistingDiscordRole(ply, rawState, callback)
	callback = isfunction(callback) and callback or function() end
	if not IsValid(ply) then callback(nil, "player unavailable") return false end
	return self:CheckDiscordRole(ply:SteamID64(), callback, rawState)
end

local function armDiscordRoleDeadline(self, ply)
	if not IsValid(ply) or self:IsDiscordKickExempt(ply) then return false end
	local config = self.Config.discord
	local steamID64 = ply:SteamID64()
	local timerName = discordDeadlineTimer(steamID64)
	if timer.Exists(timerName) then return true end
	local timeout = config.verification_timeout_seconds
	DRP.Net.Notify(ply, "Discord verification is required. Use /discordlink, join, then /discordverify within "
		.. math.ceil(timeout / 60) .. " minutes or you will be disconnected.", 2)
	timer.Create(timerName, timeout, 1, function()
		local target = DRP.Players.Online(steamID64)
		if not IsValid(target) then return end
		if self:IsDiscordKickExempt(target) then
			self:ClearDiscordRoleDeadline(steamID64)
			return
		end
		self:CheckExistingDiscordRole(target, self.Cache[steamID64], function(confirmed)
			local current = DRP.Players.Online(steamID64)
			if not IsValid(current) or self:IsDiscordKickExempt(current) or confirmed == true then
				self:ClearDiscordRoleDeadline(steamID64)
				return
			end
			if confirmed == nil then
				-- Never punish a possibly verified player because Discord or the
				-- Worker is temporarily unavailable. Retry after a protected grace.
				self:ClearDiscordRoleDeadline(steamID64)
				DRP.Net.Notify(current, "Discord role verification is temporarily unavailable. Your session is protected while the server retries.", 2)
				timer.Simple(120, function()
					local retryTarget = DRP.Players.Online(steamID64)
					if IsValid(retryTarget) then self:StartDiscordRoleDeadline(retryTarget) end
				end)
				return
			end
			if DRP.Audit then DRP.Audit.Log(current, "discord_role_timeout") end
			current:Kick("Discord verification timed out. Join the Discord, obtain the DarkRP role, then reconnect.")
		end)
	end)
	if timeout > 75 then
		timer.Create(discordDeadlineWarningTimer(steamID64), timeout - 60, 1, function()
			local target = DRP.Players.Online(steamID64)
			if not IsValid(target) or self:IsDiscordKickExempt(target) then
				self:ClearDiscordRoleDeadline(steamID64)
				return
			end
			if timer.Exists(timerName) then
				DRP.Net.Notify(target, "Discord verification required: 60 seconds remaining. Use /discordlink and /discordverify now.", 3)
			end
		end)
	end
	return true
end

function Trust:StartDiscordRoleDeadline(ply)
	if not IsValid(ply) or ply:IsBot() or not ply:DRPPersistent() then return false end
	if self:IsDiscordKickExempt(ply) then self:ClearDiscordRoleDeadline(ply) return true end
	local config = self.Config and self.Config.discord
	if not config or not config.role_required or config.member_status_url == "" then return false end
	local steamID64 = ply:SteamID64()
	if timer.Exists(discordDeadlineTimer(steamID64)) or self.RoleChecks[steamID64] then return true end
	local state = normalizeState(self.Cache[steamID64])
	if config.member_status_url ~= "" then
		self:CheckExistingDiscordRole(ply, state, function(confirmed)
			local target = DRP.Players.Online(steamID64)
			if IsValid(target) and confirmed ~= true and not self:IsDiscordKickExempt(target) then
				armDiscordRoleDeadline(self, target)
			end
		end)
		return true
	end
	return armDiscordRoleDeadline(self, ply)
end

function Trust:Apply(ply, state, announce)
	if not IsValid(ply) or not ply:DRPReady() then return false end
	state = normalizeState(state)
	local score, known, reasons, label = self.ScoreSignals(buildSignals(ply, state))
	state.score, state.known, state.reasons, state.label = score, known, reasons, label
	state.updated_at = os.time()
	self.Cache[ply:SteamID64()] = state
	ply.DRPTrustScore = score
	ply.DRPTrustKnown = known
	ply.DRPDiscordLinked = state.discord_linked == true
	if state.discord_linked and state.discord_role_granted and ply.DRPDiscordRoleVerifiedSession then
		self:ClearDiscordRoleDeadline(ply)
	else
		self:StartDiscordRoleDeadline(ply)
	end
	if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.TRUST, nil, true) end
	if DRP.Storage and ply:DRPPersistent() then
		local payload = util.TableToJSON(state, false)
		if payload then DRP.Storage.SaveWorldState(stateKey(ply:SteamID64()), payload) end
	end
	if announce then
		net.Start(announceMessage)
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.WriteString(clean(ply:DRPName(), 64))
			net.WriteUInt(score, 7)
			net.WriteUInt(math.Clamp(known, 0, self.MaximumSignals), 4)
			net.WriteString(label)
		net.Broadcast()
	end
	self:SendSelf(ply, state, announce == true)
	return true
end

function Trust:SendSelf(ply, rawState, show)
	if not IsValid(ply) then return false end
	local state = normalizeState(rawState or self.Cache[ply:SteamID64()])
	local serverSeconds = math.max(0, math.floor(tonumber(ply.DRPTotalPlaytimeBase) or 0))
	net.Start(selfMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteBool(show == true)
		net.WriteUInt(state.score, 7)
		net.WriteUInt(state.known, 4)
		net.WriteString(trustLabel(state.score))
		net.WriteBool(self.Config and self.Config.steam_web_api_key ~= "")
		net.WriteBool(self.Config and self.Config.vpn and self.Config.vpn.lookup_url ~= "")
		net.WriteBool(self.Config and self.Config.discord and self.Config.discord.verify_url ~= ""
			and (self.Config.discord.link_url ~= "" or self.Config.discord.bot_start_url ~= ""))
		net.WriteUInt(math.min(serverSeconds, 4294967295), 32)
		net.WriteBool(serverSeconds > 0)
		net.WriteBool(DRP.Admin and DRP.AdminRankLevel(DRP.Admin.BaseRankKey(ply)) >= DRP.AdminRankLevel("trusted") or false)
		net.WriteBool(state.steam_owned_known)
		net.WriteBool(state.gmod_visible)
		net.WriteUInt(math.min(state.gmod_minutes, 4294967295), 32)
		net.WriteUInt(math.min(state.steam_game_count, 65535), 16)
		net.WriteBool(state.vac_known)
		net.WriteUInt(math.min(state.vac_bans, 255), 8)
		net.WriteUInt(math.min(state.game_bans, 255), 8)
		net.WriteUInt(math.min(state.days_since_ban, 65535), 16)
		net.WriteBool(state.vpn_known)
		net.WriteBool(state.vpn_detected)
		net.WriteBool(state.discord_linked)
		local pending = self.PendingLinks[ply:SteamID64()]
		net.WriteBool(istable(pending) and (pending.expires or 0) > CurTime())
		net.WriteString(state.discord_name)
		net.WriteString(state.discord_id)
	net.Send(ply)
	if DRP.Net then DRP.Net.Record(39 + #state.discord_name + #state.discord_id) end
	return true
end

function Trust:Evaluate(ply, loadedState, announce)
	if not IsValid(ply) or ply:IsBot() then return end
	local state = normalizeState(loadedState)
	local context = { pending = 0, finalized = false, building = true, state = state }
	self.Evaluations[ply] = context

	local function finalize()
		if context.finalized or not IsValid(ply) or self.Evaluations[ply] ~= context then return end
		context.finalized = true
		self:Apply(ply, state, announce)
	end

	local function queue(request)
		context.pending = context.pending + 1
		request(function()
			context.pending = math.max(0, context.pending - 1)
			if context.finalized then
				-- A timed-out join gets one prompt provisional result. Coalesce
				-- every late provider into one final roster/persistence update.
				if context.pending == 0 and IsValid(ply) and self.Evaluations[ply] == context then
					self:Apply(ply, state, false)
				end
			elseif not context.building and context.pending == 0 then
				finalize()
			end
		end)
	end

	local now = os.time()
	local steamKey = self.Config.steam_web_api_key
	if steamKey ~= "" and now - state.steam_owned_checked >= self.RefreshSeconds and canAttempt("owned:" .. ply:SteamID64()) then
		queue(function(done)
			local url = "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?key=" .. encode(steamKey)
				.. "&steamid=" .. encode(ply:SteamID64()) .. "&include_appinfo=false&include_played_free_games=false"
			requestJSON(url, nil, function(success, data)
				local response = success and data.response
				if istable(response) and tonumber(response.game_count) and tonumber(response.game_count) > 0 and istable(response.games) then
					state.steam_owned_known = true
					state.steam_game_count = math.max(0, math.floor(tonumber(response.game_count) or 0))
					state.gmod_minutes = 0
					state.gmod_visible = false
					for _, gameData in ipairs(response.games or {}) do
						if tonumber(gameData.appid) == self.GModAppID then
							state.gmod_minutes = math.max(0, math.floor(tonumber(gameData.playtime_forever) or 0))
							state.gmod_visible = true
							break
						end
					end
					state.steam_owned_checked = os.time()
				end
				done()
			end)
		end)
	end

	if steamKey ~= "" and now - state.steam_bans_checked >= self.RefreshSeconds and canAttempt("bans:" .. ply:SteamID64()) then
		queue(function(done)
			local url = "https://api.steampowered.com/ISteamUser/GetPlayerBans/v1/?key=" .. encode(steamKey) .. "&steamids=" .. encode(ply:SteamID64())
			requestJSON(url, nil, function(success, data)
				local record = success and istable(data.players) and data.players[1]
				if istable(record) then
					state.vac_known = true
					state.vac_bans = math.max(0, math.floor(tonumber(record.NumberOfVACBans) or 0))
					state.game_bans = math.max(0, math.floor(tonumber(record.NumberOfGameBans) or 0))
					state.days_since_ban = math.max(0, math.floor(tonumber(record.DaysSinceLastBan) or 0))
					state.steam_bans_checked = os.time()
				end
				done()
			end)
		end)
	end

	local ip = playerIP(ply)
	local ipHash = ip and string.sub(util.SHA256(ip), 1, 32) or ""
	local vpnConfig = self.Config.vpn
	if ip and vpnConfig.lookup_url ~= "" and (ipHash ~= state.network_hash or now - state.network_checked >= self.NetworkRefreshSeconds)
		and canAttempt("vpn:" .. ply:SteamID64(), 600) then
		queue(function(done)
			requestJSON(endpoint(vpnConfig.lookup_url, { ip = ip }), vpnConfig.headers, function(success, data)
				if success then
					local found, detected = false, false
					for _, path in ipairs(vpnConfig.boolean_paths) do
						local value = valueAtPath(data, path)
						if isbool(value) then found, detected = true, detected or value end
						if tonumber(value) ~= nil then found, detected = true, detected or tonumber(value) ~= 0 end
					end
					if found then
						state.vpn_known = true
						state.vpn_detected = detected
						state.network_hash = ipHash
						state.network_checked = os.time()
					end
				end
				done()
			end)
		end)
	end

	timer.Simple(8, finalize)
	context.building = false
	if context.pending == 0 then finalize() end
end

function Trust:LoadPlayer(ply, announce)
	if not IsValid(ply) or ply:IsBot() then return end
	if not DRP.Storage or not ply:DRPPersistent() then self:Evaluate(ply, nil, announce) return end
	DRP.Storage.LoadWorldState(stateKey(ply:SteamID64()), function(success, payload)
		if not IsValid(ply) then return end
		local decoded = success and util.JSONToTable(payload or "") or nil
		self:Evaluate(ply, decoded, announce)
	end)
end

function Trust:Get(ply)
	if not IsValid(ply) then return nil end
	return self.Cache[ply:SteamID64()]
end

function Trust:RelayGlobalChat(ply, text)
	if not IsValid(ply) or not self.Config or not self.Config.discord then return false end
	local config = self.Config.discord
	local channelID = config.global_chat_channel_id
	if config.bot_chat_url == "" or #channelID < 16 or #channelID > 22 or not string.match(channelID, "^%d+$") then return false end
	local state = normalizeState(self.Cache[ply:SteamID64()])
	postJSON(config.bot_chat_url, config.headers, {
		channel_id = config.global_chat_channel_id,
		rp_name = clean(ply:DRPName(), 64),
		steam_id = clean(ply:SteamID(), 32),
		steam_id64 = clean(ply:SteamID64(), 20),
		discord_id = state.discord_linked and state.discord_id or "",
		discord_name = state.discord_linked and state.discord_name or "",
		message = clean(text, 240)
	}, function(success, _, reason)
		if success then
			self.BotChatErrorReported = false
			return
		end
		if not self.BotChatErrorReported then
			self.BotChatErrorReported = true
			print("[DRP TRUST] Discord global chat relay failed: " .. clean(reason, 96))
		end
	end)
	return true
end

function Trust:PollBotInbox()
	if self.BotInboxPollActive or not self.Config or not self.Config.discord then return false end
	local config = self.Config.discord
	local channelID = config.global_chat_channel_id
	if config.bot_inbox_url == "" or #channelID < 16 or #channelID > 22 or not string.match(channelID, "^%d+$") then return false end

	self.BotInboxPollActive = true
	requestJSON(endpoint(config.bot_inbox_url, { channel_id = channelID }), config.headers, function(success, data, reason)
		self.BotInboxPollActive = false
		if not success then
			if not self.BotInboxErrorReported then
				self.BotInboxErrorReported = true
				print("[DRP TRUST] Discord global chat inbox failed: " .. clean(reason or data and data.error, 96))
			end
			return
		end

		self.BotInboxErrorReported = false
		if not istable(data.messages) or not DRP.ChatServer or not DRP.ChatServer.SendDiscord then return end
		for index = 1, math.min(#data.messages, 32) do
			local message = data.messages[index]
			if istable(message) then
				DRP.ChatServer.SendDiscord(
					clean(message.author_name, 64),
					clean(message.author_id, 22),
					clean(message.message, 240)
				)
			end
		end
	end)
	return true
end

local function sendTrustInspection(requester, steamID64, name, rawState)
	if not IsValid(requester) then return end
	local found = istable(rawState)
	local state = found and normalizeState(rawState) or nil
	net.Start(inspectResponseMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteBool(found)
		net.WriteString(clean(steamID64, 20))
		net.WriteString(clean(name, 64))
		if found then
			net.WriteUInt(state.score, 7)
			net.WriteUInt(state.known, 4)
			net.WriteString(trustLabel(state.score))
			net.WriteUInt(state.updated_at % 4294967296, 32)
			net.WriteBool(state.discord_linked)
			net.WriteString(state.discord_name)
			net.WriteString(state.discord_id)
			local reasonCount = math.min(#state.reasons, 15)
			net.WriteUInt(reasonCount, 4)
			for index = 1, reasonCount do net.WriteString(clean(state.reasons[index], 128)) end
		end
	net.Send(requester)
end

DRP.Net.Receive(inspectRequestMessage, function(_, requester)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local steamID64 = clean(net.ReadString(), 20)
	if not DRP.Net.Allow(requester, "trust_inspect", 0.5, 3) then return end
	if not DRP.Admin or not DRP.Admin.Has(requester, "trust") then
		DRP.Net.Notify(requester, "You do not have permission to inspect trust evidence.", 3)
		return
	end
	if #steamID64 ~= 17 or not string.match(steamID64, "^%d+$") then return end
	local target = DRP.Players.Online(steamID64)
	local record = DRP.Admin.Record(steamID64)
	local name = IsValid(target) and target:Nick() or record and record.name or steamID64
	if IsValid(target) and Trust.Cache[steamID64] then
		sendTrustInspection(requester, steamID64, name, Trust.Cache[steamID64])
	elseif DRP.Storage then
		DRP.Storage.LoadWorldState(stateKey(steamID64), function(success, payload)
			local decoded = success and util.JSONToTable(payload or "") or nil
			sendTrustInspection(requester, steamID64, name, decoded)
		end)
	else
		sendTrustInspection(requester, steamID64, name, nil)
	end
	if DRP.Audit then DRP.Audit.Log(requester, "trust_inspected", target or steamID64) end
end)

DRP.Net.Receive(selfActionMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local action = net.ReadUInt(2)

	if action == 1 then
		local now = CurTime()
		if (ply.DRPTrustManualRefreshAt or 0) > now then
			DRP.Net.Notify(ply, "Trust providers can be rechecked in " .. math.ceil(ply.DRPTrustManualRefreshAt - now) .. " seconds.", 2)
			return
		end
		ply.DRPTrustManualRefreshAt = now + 300
		local steamID64 = ply:SteamID64()
		local state = normalizeState(Trust.Cache[steamID64])
		if not state.steam_owned_known then state.steam_owned_checked = 0 end
		if not state.vac_known then state.steam_bans_checked = 0 end
		if not state.vpn_known or state.vpn_detected then
			state.network_checked = 0
			state.network_hash = ""
		end
		Trust.Attempts["owned:" .. steamID64] = nil
		Trust.Attempts["bans:" .. steamID64] = nil
		Trust.Attempts["vpn:" .. steamID64] = nil
		Trust:Evaluate(ply, state, false)
		DRP.Net.Notify(ply, "Trust providers are being rechecked. This panel will update when they respond.", 1)
	elseif action == 2 then
		if not DRP.Net.Allow(ply, "trust_self_link", 5, 1) then return end
		local success, reason = Trust:JoinDiscord(ply)
		if not success then DRP.Net.Notify(ply, reason or "Discord linking is unavailable.", 3) end
	elseif action == 3 then
		if not DRP.Net.Allow(ply, "trust_self_verify", 2, 1) then return end
		local success, reason = Trust:BeginOrCheckDiscordVerification(ply)
		if not success then DRP.Net.Notify(ply, reason or "Discord verification could not start.", 3) end
	end
end)

function Trust:BeginDiscordLink(ply)
	if not IsValid(ply) or not ply:DRPPersistent() then return false, "Persistent server state is required." end
	local config = self.Config.discord
	if config.verify_url == "" or config.link_url == "" and config.bot_start_url == "" then
		return false, "Discord linking is not configured by the server owner."
	end
	local steamID64 = ply:SteamID64()
	local token = string.sub(util.SHA256(config.link_secret .. ":" .. steamID64 .. ":" .. tostring(SysTime()) .. ":" .. tostring(math.random())), 1, 40)
	self.PendingLinks[steamID64] = { token = token, expires = CurTime() + 600 }
	local signature = util.SHA256(steamID64 .. ":" .. token .. ":" .. config.link_secret)
	local fallbackURL = config.link_url ~= "" and endpoint(config.link_url, {
		steamid = steamID64,
		token = token,
		signature = signature
	}) or ""
	local function sendLink(botMode, value, channelURL)
		if not IsValid(ply) then return end
		net.Start(linkMessage)
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.WriteBool(botMode)
			net.WriteString(value)
			net.WriteString(channelURL or fallbackURL)
		net.Send(ply)
	end
	if config.bot_start_url ~= "" then
		local code = string.upper(string.sub(token, 1, 8))
		local botStartURL = endpoint(config.bot_start_url, {
			steamid = steamID64,
			token = token,
			code = code,
			channel_id = config.global_chat_channel_id
		})
		if not string.find(config.bot_start_url, "{channel_id}", 1, true) then
			botStartURL = botStartURL .. (string.find(botStartURL, "?", 1, true) and "&" or "?")
				.. "channel_id=" .. encode(config.global_chat_channel_id)
		end
		requestJSON(botStartURL, config.headers, function(success, data, reason)
			if not IsValid(ply) then return end
			if success and data.started == true then
				sendLink(true, clean(data.code or code, 8), clean(data.channel_url, 512))
				self:StartDiscordVerificationPoll(ply)
				return
			end
			self.PendingLinks[steamID64] = nil
			DRP.Net.Notify(ply, "Discord verification could not start: " .. clean(reason or data and data.error, 80), 3)
		end)
	else
		sendLink(false, fallbackURL)
	end
	if DRP.Audit then DRP.Audit.Log(ply, "discord_link_started") end
	return true
end

function Trust:JoinDiscord(ply)
	if not IsValid(ply) then return false, "A player is required." end
	local config = self.Config and self.Config.discord
	if not config or config.bot_invite_url == "" then
		return false, "The Discord invite service is not configured."
	end
	requestJSON(endpoint(config.bot_invite_url, { channel_id = config.global_chat_channel_id }), config.headers,
		function(success, data, reason)
			if not IsValid(ply) then return end
			local inviteURL = success and clean(data.invite_url, 512) or ""
			if inviteURL == "" then
				DRP.Net.Notify(ply, "Discord invite could not be created: " .. clean(reason or data and data.error, 80), 3)
				return
			end
			net.Start(inviteMessage)
				net.WriteUInt(DRP.ProtocolVersion, 8)
				net.WriteString(inviteURL)
			net.Send(ply)
		end)
	if DRP.Audit then DRP.Audit.Log(ply, "discord_invite_requested") end
	return true
end

local function discordPollTimer(steamID64)
	return "DRP.Trust.DiscordVerify." .. tostring(steamID64 or "")
end

function Trust:StartDiscordVerificationPoll(ply)
	if not IsValid(ply) then return false end
	local steamID64 = ply:SteamID64()
	local timerName = discordPollTimer(steamID64)
	timer.Remove(timerName)
	timer.Create(timerName, 3, 40, function()
		local target = DRP.Players.Online(steamID64)
		if not IsValid(target) or not self.PendingLinks[steamID64] then
			timer.Remove(timerName)
			return
		end
		self:VerifyDiscordLink(target, true)
	end)
	return true
end

function Trust:BeginOrCheckDiscordVerification(ply)
	if not IsValid(ply) then return false, "A player is required." end
	local pending = self.PendingLinks[ply:SteamID64()]
	if istable(pending) and (pending.expires or 0) > CurTime() then
		return self:VerifyDiscordLink(ply, false)
	end
	return self:BeginDiscordLink(ply)
end

function Trust:SendBotHeartbeat(offline)
	local config = self.Config and self.Config.discord
	if not config then return end
	local template = offline and config.bot_offline_url or config.bot_heartbeat_url
	if template == "" then return end
	local humanCount = 0
	for _, candidate in ipairs(player.GetHumans()) do
		if IsValid(candidate) then humanCount = humanCount + 1 end
	end
	requestJSON(endpoint(template, {
		name = GetHostName(),
		map = game.GetMap(),
		players = humanCount,
		max = game.MaxPlayers(),
		channel_id = config.global_chat_channel_id
	}), config.headers, function(success, data, reason)
		if offline or success then return end
		if not self.BotHeartbeatErrorReported then
			self.BotHeartbeatErrorReported = true
			print("[DRP TRUST] Discord bot heartbeat failed: " .. clean(reason or data and data.error, 96))
		end
	end)
end

function Trust:VerifyDiscordLink(ply, quiet)
	if not IsValid(ply) or not ply:DRPPersistent() then return false, "Persistent server state is required." end
	local steamID64 = ply:SteamID64()
	local pending = self.PendingLinks[steamID64]
	if not pending or pending.expires <= CurTime() then return false, "Use /discordverify again; the verification session expired." end
	local config = self.Config.discord
	local url = endpoint(config.verify_url, { steamid = steamID64, token = pending.token })
	requestJSON(url, config.headers, function(success, data, reason)
		if not IsValid(ply) then return end
		if not success or data.linked ~= true or clean(data.discord_id, 32) == "" then
			if not quiet then DRP.Net.Notify(ply, "Discord verification is not complete" .. (reason and (": " .. clean(reason, 80)) or ".") , 3) end
			return
		end
		local state = normalizeState(self.Cache[steamID64])
		state.discord_linked = true
		state.discord_role_granted = data.role_granted == true
		if not state.discord_role_granted then
			if not quiet then DRP.Net.Notify(ply, "Discord linked, but the DarkRP role has not been granted yet.", 3) end
			return
		end
		state.discord_id = clean(data.discord_id, 32)
		state.discord_name = clean(data.discord_name or data.username, 64)
		state.discord_role_checked_at = os.time()
		ply.DRPDiscordRoleVerifiedSession = true
		self.PendingLinks[steamID64] = nil
		timer.Remove(discordPollTimer(steamID64))
		self:Apply(ply, state, false)
		DRP.Net.Notify(ply, "Discord account linked. Your trust score has been recalculated.", 1)
		if DRP.Audit then DRP.Audit.Log(ply, "discord_link_verified", nil, state.discord_name) end
	end)
	return true
end

function Trust:UnlinkDiscord(ply)
	if not IsValid(ply) then return false end
	local state = normalizeState(self.Cache[ply:SteamID64()])
	if not state.discord_linked then return false end
	local formerDiscordID = state.discord_id
	state.discord_linked, state.discord_role_granted, state.discord_id, state.discord_name = false, false, "", ""
	ply.DRPDiscordRoleVerifiedSession = false
	self.PendingLinks[ply:SteamID64()] = nil
	self:Apply(ply, state, false)
	local config = self.Config.discord
	if config.unlink_url ~= "" then
		requestJSON(endpoint(config.unlink_url, { steamid = ply:SteamID64(), discord_id = formerDiscordID }), config.headers, function(success, _, reason)
			if not success and IsValid(ply) then DRP.Net.Notify(ply, "Discord was unlinked in game, but the identity provider could not be updated: " .. clean(reason, 64), 2) end
		end)
	end
	if DRP.Audit then DRP.Audit.Log(ply, "discord_link_removed") end
	return true
end

function Trust:Start()
	timer.Remove("DRP.Trust.BotHeartbeat")
	timer.Remove("DRP.Trust.BotInbox")
	file.CreateDir("darkrp")
	local decoded = util.JSONToTable(file.Read(self.ConfigPath, "DATA") or "")
	self.Config = normalizeConfig(decoded)
	file.Write(self.ConfigPath, util.TableToJSON(self.Config, true))
	self.RefreshSeconds = self.Config.steam_refresh_seconds
	self.NetworkRefreshSeconds = self.Config.network_refresh_seconds
	self.BotHeartbeatErrorReported = false
	self.BotChatErrorReported = false
	self.BotInboxErrorReported = false
	self.BotInboxPollActive = false
	if self.Config.discord.bot_heartbeat_url ~= "" then
		timer.Create("DRP.Trust.BotHeartbeat", 45, 0, function() self:SendBotHeartbeat(false) end)
		timer.Simple(1, function()
			if DRP.Trust == self then self:SendBotHeartbeat(false) end
		end)
	end
	if self.Config.discord.bot_inbox_url ~= "" and self.Config.discord.global_chat_channel_id ~= "" then
		timer.Create("DRP.Trust.BotInbox", 2, 0, function() self:PollBotInbox() end)
		timer.Simple(2, function()
			if DRP.Trust == self then self:PollBotInbox() end
		end)
	end
	print(string.format("[DRP TRUST] Steam=%s VPN=%s Discord=%s Bot=%s config=data/%s",
		self.Config.steam_web_api_key ~= "" and "enabled" or "disabled",
		self.Config.vpn.lookup_url ~= "" and "enabled" or "disabled",
		self.Config.discord.link_url ~= "" and self.Config.discord.verify_url ~= "" and "enabled" or "disabled",
		self.Config.discord.bot_start_url ~= "" and self.Config.discord.bot_heartbeat_url ~= "" and "enabled" or "disabled",
		self.ConfigPath))
end

function Trust:Stop()
	timer.Remove("DRP.Trust.BotHeartbeat")
	timer.Remove("DRP.Trust.BotInbox")
	self.BotInboxPollActive = false
	self:SendBotHeartbeat(true)
	for _, ply in ipairs(player.GetHumans()) do self:ClearDiscordRoleDeadline(ply) end
	self.Evaluations = setmetatable({}, { __mode = "k" })
	self.PendingLinks = {}
	self.RoleChecks = {}
	self.Attempts = {}
end

hook.Add("DRPPlayerReady", "DRP.Trust.Evaluate", function(ply)
	if ply:IsBot() then
		ply.DRPTrustScore, ply.DRPTrustKnown, ply.DRPDiscordLinked = 100, Trust.MaximumSignals, false
		if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.TRUST, nil, true) end
		return
	end
	ply.DRPDiscordRoleVerifiedSession = false
	Trust:LoadPlayer(ply, true)
end)

hook.Add("PlayerDisconnected", "DRP.Trust.Clear", function(ply)
	local steamID64 = ply:SteamID64()
	Trust:ClearDiscordRoleDeadline(steamID64)
	timer.Remove(discordPollTimer(steamID64))
	Trust.Evaluations[ply] = nil
	Trust.PendingLinks[steamID64] = nil
	Trust.RoleChecks[steamID64] = nil
	Trust.Cache[steamID64] = nil
end)

concommand.Add("drp_trust_reload", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	Trust:Start()
	if IsValid(ply) then DRP.Net.Notify(ply, "Trust provider configuration reloaded.", 1) end
end)

concommand.Add("drp_trust_refresh", function(ply, _, arguments)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local target
	if arguments[1] then target = DRP.Players.Online(arguments[1]) end
	if not IsValid(target) and IsValid(ply) then target = ply end
	if not IsValid(target) then print("Usage: drp_trust_refresh <online SteamID64>") return end
	local id = target:SteamID64()
	Trust.Attempts["owned:" .. id], Trust.Attempts["bans:" .. id], Trust.Attempts["vpn:" .. id] = nil, nil, nil
	local state = normalizeState(Trust.Cache[id])
	state.steam_owned_checked, state.steam_bans_checked, state.network_checked = 0, 0, 0
	Trust:Evaluate(target, state, false)
	if IsValid(ply) then DRP.Net.Notify(ply, "Trust providers are refreshing for " .. target:DRPName() .. ".", 1) end
end)
