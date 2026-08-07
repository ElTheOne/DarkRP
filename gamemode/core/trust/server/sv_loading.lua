local Loading = {
	DefaultOrigin = "https://darkrp-discord-link.tcv2y2cdj7.workers.dev",
	InFlight = {},
	Pending = {},
	MapPath = "",
	MapBytes = 0,
	MapRegistered = false
}

DRP.Loading = Loading
DRP.Services.Register("loading", Loading)

local pageConVar = CreateConVar(
	"drp_loading_page_url",
	Loading.DefaultOrigin .. "/loading?steamid=%s&map=%m",
	FCVAR_ARCHIVE,
	"External page shown while a player joins. Garry's Mod replaces %s with SteamID64 and %m with the map."
)

local function clean(value, maximum)
	return string.sub(string.Trim(tostring(value or "")), 1, maximum or 64)
end

local function validSteamID64(value)
	value = tostring(value or "")
	return #value == 17 and string.match(value, "^7656119%d+$") ~= nil
end

local function configuredOrigin()
	local trustConfig = DRP.Trust and DRP.Trust.Config
	local discord = trustConfig and trustConfig.discord
	local candidate = discord and (
		discord.bot_chat_url ~= "" and discord.bot_chat_url
		or discord.link_url ~= "" and discord.link_url
		or discord.bot_start_url
	) or ""
	local origin = string.match(tostring(candidate), "^(https://[^/]+)")
	return origin or Loading.DefaultOrigin
end

local function serviceHeaders()
	local trustConfig = DRP.Trust and DRP.Trust.Config
	local configured = trustConfig and trustConfig.discord and trustConfig.discord.headers
	local headers = {}
	for key, value in pairs(istable(configured) and configured or {}) do
		headers[clean(key, 64)] = clean(value, 512)
	end
	return headers
end

local function profileFor(ply)
	return {
		steamid = clean(ply:SteamID64(), 24),
		rp_name = clean(ply:DRPName(), 48),
		job = clean(ply:DRPJobName(), 48),
		wallet = math.max(0, math.floor(tonumber(ply:DRPMoney()) or 0)),
		level = math.Clamp(math.floor(tonumber(ply:DRPXPLevel()) or 1), 1, 100),
		civic = DRP.Civic and DRP.Civic:Get(ply) or 0,
		updated_at = os.time()
	}
end

function Loading:RegisterCurrentMap()
	local mapName = string.lower(string.Trim(tostring(game.GetMap() or "")))
	self.MapPath = mapName ~= "" and ("maps/" .. mapName .. ".bsp") or ""
	self.MapBytes = self.MapPath ~= "" and math.max(0, tonumber(file.Size(self.MapPath, "GAME")) or 0) or 0
	self.MapRegistered = self.MapPath ~= "" and file.Exists(self.MapPath, "GAME")

	if not self.MapRegistered then
		ErrorNoHalt("[DRP CONTENT] current map BSP is missing from the server: " .. tostring(self.MapPath) .. "\n")
		return false
	end

	resource.AddFile(self.MapPath)
	print(string.format(
		"[DRP CONTENT] registered current map for client download: %s (%.1f MB)",
		self.MapPath,
		self.MapBytes / 1048576
	))
	return true
end

function Loading:ConfigureURL()
	if not game.IsDedicated() then return end
	local loadingURL = clean(pageConVar:GetString(), 1024)
	if loadingURL == "" then
		loadingURL = configuredOrigin() .. "/loading?steamid=%s&map=%m"
		RunConsoleCommand("drp_loading_page_url", loadingURL)
	end
	RunConsoleCommand("sv_loadingurl", loadingURL)
	print("[DRP LOADING] dedicated loading URL configured: " .. loadingURL)
end

function Loading:SendProfile(steamID64, payload)
	if not game.IsDedicated() or not validSteamID64(steamID64) then return false end
	if self.InFlight[steamID64] then
		self.Pending[steamID64] = payload
		return true
	end

	self.InFlight[steamID64] = true
	local queued = HTTP({
		url = configuredOrigin() .. "/loading/profile",
		method = "post",
		headers = serviceHeaders(),
		type = "application/json",
		body = util.TableToJSON(payload, false),
		timeout = 8,
		success = function(code)
			self.InFlight[steamID64] = nil
			if code < 200 or code >= 300 then
				ErrorNoHalt("[DRP LOADING] profile publish rejected for " .. steamID64 .. " (HTTP " .. tostring(code) .. ")\n")
			end
			local queued = self.Pending[steamID64]
			self.Pending[steamID64] = nil
			if queued then self:SendProfile(steamID64, queued) end
		end,
		failed = function(reason)
			self.InFlight[steamID64] = nil
			ErrorNoHalt("[DRP LOADING] profile publish failed for " .. steamID64 .. ": " .. clean(reason, 160) .. "\n")
			local queued = self.Pending[steamID64]
			self.Pending[steamID64] = nil
			if queued then self:SendProfile(steamID64, queued) end
		end
	})
	if not queued then
		self.InFlight[steamID64] = nil
		ErrorNoHalt("[DRP LOADING] HTTP request could not be queued; check -disablehttp and server networking\n")
		return false
	end
	return true
end

function Loading:Publish(ply)
	if not IsValid(ply) or not ply:IsPlayer() or ply:IsBot() then return false end
	return self:SendProfile(ply:SteamID64(), profileFor(ply))
end

function Loading:Start()
	self:RegisterCurrentMap()
	self:ConfigureURL()
	local downloadURL = GetConVar("sv_downloadurl") and string.Trim(GetConVar("sv_downloadurl"):GetString()) or ""
	if self.MapRegistered and downloadURL == "" then
		ErrorNoHalt(
			"[DRP CONTENT] sv_downloadurl is empty. New players cannot reliably receive the "
			.. string.format("%.1f MB map; configure FastDL and run its sync job.\n", self.MapBytes / 1048576)
		)
	end
end

function Loading:Stop()
	self.InFlight = {}
	self.Pending = {}
end

hook.Add("DRPPlayerReady", "DRP.Loading.PublishReadyProfile", function(ply)
	Loading:Publish(ply)
end)

concommand.Add("drp_loading_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local headers = serviceHeaders()
	print(string.format(
		"[DRP LOADING] dedicated=%s page=%s publisher=%s authorization=%s inflight=%d pending=%d map=%s map_registered=%s map_mb=%.1f fastdl=%s",
		tostring(game.IsDedicated()),
		GetConVar("sv_loadingurl") and GetConVar("sv_loadingurl"):GetString() or "",
		configuredOrigin() .. "/loading/profile",
		headers.Authorization and headers.Authorization ~= "" and "configured" or "missing",
		table.Count(Loading.InFlight),
		table.Count(Loading.Pending),
		Loading.MapPath,
		tostring(Loading.MapRegistered),
		Loading.MapBytes / 1048576,
		GetConVar("sv_downloadurl") and GetConVar("sv_downloadurl"):GetString() or ""
	))
end)
