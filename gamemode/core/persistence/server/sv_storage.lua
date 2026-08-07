local Storage = {
	Available = false,
	Database = nil,
	LastError = "not started",
	ErrorCount = 0,
	MaxQueueDepth = 0,
	PendingLoads = {},
	NextPendingLoad = 0,
	PlayerLoadQueue = {},
	PlayerLoadHead = 1,
	ActivePlayerLoads = 0,
	MaxConcurrentPlayerLoads = 4,
	PocketLoadQueue = {},
	PocketLoadHead = 1,
	ActivePocketLoads = 0,
	MaxConcurrentPocketLoads = 2,
	Stopping = false,
	Mode = "mysql",
	LocalData = nil,
	LocalPath = "darkrp/singleplayer/database.json",
	LocalBackupPath = "darkrp/singleplayer/database.backup.json"
}

DRP.Storage = Storage
DRP.Services.Register("storage", Storage)

local configPath = "darkrp/mysql.json"
local pumpPlayerLoads, pumpPocketLoads

local function emptyLocalDatabase()
	return {
		schema_version = 1,
		players = {},
		pockets = {},
		crafting = {},
		world = {},
		government = {
			treasury = 0,
			tax_rate = 0,
			allocations = {}
		}
	}
end

local function normalizeLocalDatabase(decoded)
	local database = istable(decoded) and decoded or emptyLocalDatabase()
	database.schema_version = math.max(1, math.floor(tonumber(database.schema_version) or 1))
	database.players = istable(database.players) and database.players or {}
	database.pockets = istable(database.pockets) and database.pockets or {}
	database.crafting = istable(database.crafting) and database.crafting or {}
	database.world = istable(database.world) and database.world or {}
	database.local_host_key = string.sub(tostring(database.local_host_key or ""), 1, 64)
	database.government = istable(database.government) and database.government or {}
	database.government.treasury = math.max(0, math.floor(tonumber(database.government.treasury) or 0))
	database.government.tax_rate = math.Clamp(math.floor(tonumber(database.government.tax_rate) or 0), 0, 50)
	database.government.allocations = istable(database.government.allocations) and database.government.allocations or {}
	return database
end

local function readLocalDatabase(path)
	local raw = file.Read(path, "DATA")
	if not raw or raw == "" then return nil end
	local decoded = util.JSONToTable(raw, false, true)
	if not istable(decoded) then return nil end
	return normalizeLocalDatabase(decoded)
end

local function flushLocalDatabase()
	if Storage.Mode ~= "local" or not istable(Storage.LocalData) then return false, "local database is not active" end
	file.CreateDir("darkrp")
	file.CreateDir("darkrp/singleplayer")

	local encoded = util.TableToJSON(Storage.LocalData, true)
	if not encoded or encoded == "" then return false, "local database encoding failed" end

	local previous = file.Read(Storage.LocalPath, "DATA")
	if previous and previous ~= "" and istable(util.JSONToTable(previous, false, true)) then
		file.Write(Storage.LocalBackupPath, previous)
	end
	file.Write(Storage.LocalPath, encoded)

	if not istable(util.JSONToTable(file.Read(Storage.LocalPath, "DATA") or "", false, true)) then
		Storage.ErrorCount = Storage.ErrorCount + 1
		Storage.LastError = "local database verification failed"
		return false, Storage.LastError
	end
	Storage.LastError = ""
	return true
end

local function isRealSteamID64(value)
	value = tostring(value or "")
	return value ~= "" and value ~= "0" and string.match(value, "^7656119%d%d%d%d%d%d%d%d%d%d$") ~= nil
end

-- A listen server may report the host as SteamID64 "0" while Steam is
-- unavailable and as the real SteamID64 on another launch. Pin the local
-- profile to one persisted key so loading and saving can never target two
-- different records.
local function resolveLocalHostKey(steamID64, name)
	local database = Storage.LocalData
	if not istable(database) then return tostring(steamID64 or "") end

	local configured = tostring(database.local_host_key or "")
	if configured ~= "" and istable(database.players[configured]) then return configured end

	local requested = tostring(steamID64 or "")
	local key
	if isRealSteamID64(requested) then
		key = requested
	else
		local wantedName = string.lower(string.Trim(tostring(name or "")))
		for candidate, row in pairs(database.players) do
			if isRealSteamID64(candidate) and istable(row) then
				local rowName = string.lower(string.Trim(tostring(row.last_name or "")))
				if wantedName ~= "" and rowName == wantedName then
					key = candidate
					break
				end
			end
		end
	end

	if not key and istable(database.players.singleplayer_host) then key = "singleplayer_host" end
	if not key then key = "singleplayer_host" end

	-- Migrate an older SteamID64=0 profile when it is the only local record.
	if not istable(database.players[key]) and istable(database.players["0"]) then
		database.players[key] = table.Copy(database.players["0"])
		database.players[key].steam_id = key
		if database.pockets[key] == nil and database.pockets["0"] ~= nil then
			database.pockets[key] = database.pockets["0"]
		end
	end

	if database.local_host_key ~= key then
		database.local_host_key = key
		local saved, reason = flushLocalDatabase()
		if not saved then ErrorNoHalt("[DRP] failed to pin local host profile: " .. tostring(reason) .. "\n") end
		print("[DRP] single-player host profile pinned to " .. key)
	end
	return key
end

function Storage.LocalPlayerKey()
	return Storage.Mode == "local" and tostring(Storage.LocalData and Storage.LocalData.local_host_key or "") or ""
end

local function fail(reason)
	Storage.Available = false
	Storage.LastError = tostring(reason or "unknown error")
	Storage.ErrorCount = Storage.ErrorCount + 1
	ErrorNoHalt("[DRP] MySQL unavailable: " .. Storage.LastError .. "\n")
end

local function recordQueue()
	if not Storage.Database then return end
	Storage.MaxQueueDepth = math.max(Storage.MaxQueueDepth, Storage.Database:queueSize())
end

local function finishPending(request, persistent, row, reason)
	if not request.active then return end
	request.active = false
	Storage.PendingLoads[request.id] = nil
	timer.Remove(request.timerName)
	request.callback(persistent, row, reason)
end

local function failPending(reason)
	local pending = {}
	for _, request in pairs(Storage.PendingLoads) do pending[#pending + 1] = request end
	for _, request in ipairs(pending) do finishPending(request, false, nil, reason) end
end

local function queuePendingLoad(steamID64, name, callback)
	Storage.NextPendingLoad = Storage.NextPendingLoad + 1
	local id = Storage.NextPendingLoad
	local request = {
		id = id,
		steamID64 = steamID64,
		name = name,
		callback = callback,
		active = true,
		timerName = "DRP.Storage.LoadTimeout." .. id
	}
	Storage.PendingLoads[id] = request
	timer.Create(request.timerName, 15, 1, function()
		finishPending(request, false, nil, "MySQL connection timed out")
	end)
end

local function resumePendingLoads()
	local pending = {}
	for _, request in pairs(Storage.PendingLoads) do pending[#pending + 1] = request end
	for _, request in ipairs(pending) do
		if request.active then
			request.active = false
			Storage.PendingLoads[request.id] = nil
			timer.Remove(request.timerName)
			Storage.LoadPlayer(request.steamID64, request.name, request.callback)
		end
	end
end

local function prepareSchema(db, callback)
	local statements = {
		[[CREATE TABLE IF NOT EXISTS drp_schema_migrations (
			version INT UNSIGNED NOT NULL PRIMARY KEY,
			applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		[[CREATE TABLE IF NOT EXISTS drp_government_state (
			singleton_id TINYINT UNSIGNED NOT NULL PRIMARY KEY,
			treasury BIGINT UNSIGNED NOT NULL DEFAULT 0,
			tax_rate TINYINT UNSIGNED NOT NULL DEFAULT 0,
			updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		[[CREATE TABLE IF NOT EXISTS drp_job_funding (
			job_key VARCHAR(24) NOT NULL PRIMARY KEY,
			bonus_percent TINYINT UNSIGNED NOT NULL DEFAULT 0
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		[[CREATE TABLE IF NOT EXISTS drp_player_pockets (
			steam_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
			payload_json MEDIUMTEXT NOT NULL,
			updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		[[CREATE TABLE IF NOT EXISTS drp_player_crafting (
			steam_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
			payload_json MEDIUMTEXT NOT NULL,
			updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		[[CREATE TABLE IF NOT EXISTS drp_world_state (
			state_key VARCHAR(64) NOT NULL PRIMARY KEY,
			payload_json MEDIUMTEXT NOT NULL,
			updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		[[CREATE TABLE IF NOT EXISTS drp_economy_events (
			event_id VARCHAR(96) NOT NULL PRIMARY KEY,
			revision BIGINT UNSIGNED NOT NULL,
			kind VARCHAR(16) NOT NULL,
			payload_json MEDIUMTEXT NOT NULL,
			occurred_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			INDEX economy_events_revision (revision),
			INDEX economy_events_time (occurred_at)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		[[CREATE TABLE IF NOT EXISTS drp_economy_holdings (
			commodity_key VARCHAR(128) NOT NULL PRIMARY KEY,
			exact_quantity DECIMAL(20, 4) NOT NULL DEFAULT 0,
			effective_quantity DECIMAL(20, 4) NOT NULL DEFAULT 0,
			payload_json MEDIUMTEXT NOT NULL,
			updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		[[CREATE TABLE IF NOT EXISTS drp_economy_state (
			state_key VARCHAR(64) NOT NULL PRIMARY KEY,
			payload_json MEDIUMTEXT NOT NULL,
			updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		[[CREATE TABLE IF NOT EXISTS drp_economy_prices (
			commodity_key VARCHAR(128) NOT NULL PRIMARY KEY,
			multiplier DECIMAL(10, 4) NOT NULL DEFAULT 1,
			confidence DECIMAL(10, 4) NOT NULL DEFAULT 0,
			payload_json MEDIUMTEXT NOT NULL,
			updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		[[CREATE TABLE IF NOT EXISTS drp_economy_daily (
			day_key DATE NOT NULL,
			metric_key VARCHAR(64) NOT NULL,
			value_json MEDIUMTEXT NOT NULL,
			PRIMARY KEY (day_key, metric_key)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
		"INSERT IGNORE INTO drp_government_state (singleton_id, treasury, tax_rate) VALUES (1, 0, 0)",
		"INSERT IGNORE INTO drp_schema_migrations (version) VALUES (3), (4), (5), (6), (7), (8), (9), (10), (11), (12), (13), (14)"
	}

	local function run(index)
		if index > #statements then callback(true) return end
		local query = db:query(statements[index])
		function query:onSuccess() run(index + 1) end
		function query:onError(reason) callback(false, reason) end
		query:start()
		recordQueue()
	end

	local columns = db:query("SHOW COLUMNS FROM drp_players LIKE 'rp_name'")
	function columns:onSuccess(data)
		local function ensureRoleGoal()
			local goalColumns = db:query("SHOW COLUMNS FROM drp_players LIKE 'role_goal'")
			function goalColumns:onSuccess(hasData)
				if hasData and hasData[1] then run(1) return end
				local alter = db:query("ALTER TABLE drp_players ADD COLUMN role_goal TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER role_behavior")
				function alter:onSuccess() run(1) end
				function alter:onError(reason) callback(false, reason) end
				alter:start()
				recordQueue()
			end
			function goalColumns:onError(reason) callback(false, reason) end
			goalColumns:start()
			recordQueue()
		end

		local function ensureRoleBehavior()
			local roleColumns = db:query("SHOW COLUMNS FROM drp_players LIKE 'role_behavior'")
			function roleColumns:onSuccess(hasData)
				if hasData and hasData[1] then ensureRoleGoal() return end
				local alter = db:query("ALTER TABLE drp_players ADD COLUMN role_behavior MEDIUMTEXT NOT NULL DEFAULT '{}' AFTER civic_standing")
				function alter:onSuccess() ensureRoleGoal() end
				function alter:onError(reason) callback(false, reason) end
				alter:start()
				recordQueue()
			end
			function roleColumns:onError(reason) callback(false, reason) end
			roleColumns:start()
			recordQueue()
		end

		local function ensureCivicStanding()
			local civicColumns = db:query("SHOW COLUMNS FROM drp_players LIKE 'civic_standing'")
			function civicColumns:onSuccess(hasData)
				if hasData and hasData[1] then ensureRoleBehavior() return end
				local alter = db:query("ALTER TABLE drp_players ADD COLUMN civic_standing SMALLINT NOT NULL DEFAULT 0 AFTER xp_prestige_items")
				function alter:onSuccess() ensureRoleBehavior() end
				function alter:onError(reason) callback(false, reason) end
				alter:start()
				recordQueue()
			end
			function civicColumns:onError(reason) callback(false, reason) end
			civicColumns:start()
			recordQueue()
		end

		local function ensurePrestigeItems()
			local columns = db:query("SHOW COLUMNS FROM drp_players LIKE 'xp_prestige_items'")
			function columns:onSuccess(hasData)
				if hasData and hasData[1] then ensureCivicStanding() return end
				local alter = db:query("ALTER TABLE drp_players ADD COLUMN xp_prestige_items MEDIUMTEXT NOT NULL DEFAULT '[]' AFTER xp_prestige_tokens")
				function alter:onSuccess() ensureCivicStanding() end
				function alter:onError(reason) callback(false, reason) end
				alter:start()
				recordQueue()
			end
			function columns:onError(reason) callback(false, reason) end
			columns:start()
			recordQueue()
		end

		local function ensurePrestigeTokens()
			local columns = db:query("SHOW COLUMNS FROM drp_players LIKE 'xp_prestige_tokens'")
			function columns:onSuccess(hasData)
				if hasData and hasData[1] then ensurePrestigeItems() return end
				local alter = db:query("ALTER TABLE drp_players ADD COLUMN xp_prestige_tokens TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER xp_prestige")
				function alter:onSuccess() ensurePrestigeItems() end
				function alter:onError(reason) callback(false, reason) end
				alter:start()
				recordQueue()
			end
			function columns:onError(reason) callback(false, reason) end
			columns:start()
			recordQueue()
		end

		local function ensurePrestige()
			local columns = db:query("SHOW COLUMNS FROM drp_players LIKE 'xp_prestige'")
			function columns:onSuccess(hasData)
				if hasData and hasData[1] then ensurePrestigeTokens() return end
				local alter = db:query("ALTER TABLE drp_players ADD COLUMN xp_prestige TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER xp_level")
				function alter:onSuccess() ensurePrestigeTokens() end
				function alter:onError(reason) callback(false, reason) end
				alter:start()
				recordQueue()
			end
			function columns:onError(reason) callback(false, reason) end
			columns:start()
			recordQueue()
		end

		local function ensureLevel()
			local columns = db:query("SHOW COLUMNS FROM drp_players LIKE 'xp_level'")
			function columns:onSuccess(hasData)
				if hasData and hasData[1] then ensurePrestige() return end
				local alter = db:query("ALTER TABLE drp_players ADD COLUMN xp_level TINYINT UNSIGNED NOT NULL DEFAULT 1 AFTER xp_points")
				function alter:onSuccess() ensurePrestige() end
				function alter:onError(reason) callback(false, reason) end
				alter:start()
				recordQueue()
			end
			function columns:onError(reason) callback(false, reason) end
			columns:start()
			recordQueue()
		end

		local function ensureXP()
			local xpColumns = db:query("SHOW COLUMNS FROM drp_players LIKE 'xp_points'")
			function xpColumns:onSuccess(xpData)
				local existing = xpData and xpData[1]
				local columnType = existing and string.lower(tostring(existing.Type or existing.type or "")) or ""
				if existing and string.StartWith(columnType, "decimal(30,0)") then ensureLevel() return end
				local statement = existing
					and "ALTER TABLE drp_players MODIFY COLUMN xp_points DECIMAL(30,0) UNSIGNED NOT NULL DEFAULT 0"
					or "ALTER TABLE drp_players ADD COLUMN xp_points DECIMAL(30,0) UNSIGNED NOT NULL DEFAULT 0 AFTER total_playtime_seconds"
				local alterXP = db:query(statement)
				function alterXP:onSuccess() ensureLevel() end
				function alterXP:onError(reason) callback(false, reason) end
				alterXP:start()
				recordQueue()
			end
			function xpColumns:onError(reason) callback(false, reason) end
			xpColumns:start()
			recordQueue()
		end

		local function ensurePlaytime()
			local playtimeColumns = db:query("SHOW COLUMNS FROM drp_players LIKE 'total_playtime_seconds'")
			function playtimeColumns:onSuccess(playtimeData)
				if playtimeData and playtimeData[1] then ensureXP() return end
				local alterPlaytime = db:query("ALTER TABLE drp_players ADD COLUMN total_playtime_seconds BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER job_name")
				function alterPlaytime:onSuccess() ensureXP() end
				function alterPlaytime:onError(reason) callback(false, reason) end
				alterPlaytime:start()
				recordQueue()
			end
			function playtimeColumns:onError(reason) callback(false, reason) end
			playtimeColumns:start()
			recordQueue()
		end

		local function ensureJobName()
			local jobColumns = db:query("SHOW COLUMNS FROM drp_players LIKE 'job_name'")
			function jobColumns:onSuccess(jobData)
				if jobData and jobData[1] then ensurePlaytime() return end
				local alterJob = db:query("ALTER TABLE drp_players ADD COLUMN job_name VARCHAR(48) NULL AFTER job_key")
				function alterJob:onSuccess() ensurePlaytime() end
				function alterJob:onError(reason) callback(false, reason) end
				alterJob:start()
			end
			function jobColumns:onError(reason) callback(false, reason) end
			jobColumns:start()
		end
		if data and data[1] then ensureJobName() return end
		local alter = db:query("ALTER TABLE drp_players ADD COLUMN rp_name VARCHAR(48) NULL AFTER last_name")
		function alter:onSuccess() ensureJobName() end
		function alter:onError(reason) callback(false, reason) end
		alter:start()
		recordQueue()
	end
	function columns:onError(reason) callback(false, reason) end
	columns:start()
	recordQueue()
end

function Storage.IsAvailable()
	return Storage.Available
end

function Storage.QueueSize()
	if Storage.Mode == "local" then return 0 end
	if not Storage.Database then return 0 end
	return Storage.Database:queueSize()
end

function Storage.ShouldUseLocal()
	-- Source only reports game.SinglePlayer() for a strict one-slot session.
	-- Local stress tests with bots are listen servers, so select by process
	-- type: listen/local servers use JSON; dedicated servers use MySQL.
	return game.SinglePlayer() or not game.IsDedicated()
end

function Storage:Start()
	self.Stopping = false
	if self.ShouldUseLocal() then
		self.Mode = "local"
		self.Database = nil
		local database = readLocalDatabase(self.LocalPath)
		if not database then
			database = readLocalDatabase(self.LocalBackupPath)
			if database then
				print("[DRP] restored local listen-server database from backup")
			else
				database = emptyLocalDatabase()
			end
		end
		self.LocalData = normalizeLocalDatabase(database)
		self.Available = true
		self.LastError = ""
		local saved, reason = flushLocalDatabase()
		if not saved then
			self.Available = false
			fail(reason)
			return
		end
		print("[DRP] local listen-server database ready: data/" .. self.LocalPath)
		hook.Run("DRPStorageReady")
		return
	end

	self.Mode = "mysql"
	self.LocalData = nil
	local raw = file.Read(configPath, "DATA")
	if not raw then
		fail("missing data/" .. configPath)
		return
	end

	local config = util.JSONToTable(raw)
	if not config or not config.host or not config.username or not config.database then
		fail("invalid data/" .. configPath)
		return
	end

	local loaded, loadError = pcall(require, "mysqloo")
	if not loaded then
		fail(loadError)
		return
	end

	local module = mysqloo
	if not module then
		fail("mysqloo did not register its global module")
		return
	end

	local db = module.connect(config.host, config.username, config.password or "", config.database, tonumber(config.port) or 3306)
	Storage.Database = db
	Storage.LastError = "connecting"
	db:setAutoReconnect(true)
	if db.setConnectTimeout then db:setConnectTimeout(3) end
	if db.setReadTimeout then db:setReadTimeout(3) end
	if db.setWriteTimeout then db:setWriteTimeout(3) end

	function db:onConnected()
		Storage.LastError = "preparing schema"
		print("[DRP] MySQL connected: " .. self:serverInfo())
		prepareSchema(self, function(success, reason)
			if not success then fail("schema preparation failed: " .. tostring(reason)) failPending(reason) return end
			Storage.Available = true
			Storage.LastError = ""
			print("[DRP] MySQL schema ready")
			resumePendingLoads()
			if pumpPlayerLoads then pumpPlayerLoads() end
			if pumpPocketLoads then pumpPocketLoads() end
			hook.Run("DRPStorageReady")
		end)
	end

	function db:onConnectionFailed(reason)
		fail(reason)
		failPending(reason)
	end

	function db:onDisconnected()
		Storage.Available = false
		if not Storage.Stopping then fail("disconnected") end
	end

	db:connect()
end

function Storage:Stop()
	self.Stopping = true
	if self.Mode == "local" then
		flushLocalDatabase()
		self.Available = false
		return
	end
	failPending("server shutting down")
	for index = self.PlayerLoadHead, #self.PlayerLoadQueue do
		local request = self.PlayerLoadQueue[index]
		if request and request.callback then request.callback(false, nil, "server shutting down") end
	end
	self.PlayerLoadQueue, self.PlayerLoadHead = {}, 1
	for index = self.PocketLoadHead, #self.PocketLoadQueue do
		local request = self.PocketLoadQueue[index]
		if request and request.callback then request.callback(false, nil, "server shutting down") end
	end
	self.PocketLoadQueue, self.PocketLoadHead = {}, 1
	-- MySQLOO's wait flag drains queued writes before closing the connection.
	if self.Database then self.Database:disconnect(true) end
	self.Available = false
end

local function bindIdentity(query, steamID64, name)
	query:setString(1, steamID64)
	query:setString(2, string.sub(name or "", 1, 64))
end

local function finishPlayerLoad(request, persistent, row, reason)
	Storage.ActivePlayerLoads = math.max(0, Storage.ActivePlayerLoads - 1)
	request.callback(persistent, row, reason)
	pumpPlayerLoads()
end

local function beginPlayerLoad(request)
	Storage.ActivePlayerLoads = Storage.ActivePlayerLoads + 1
	local started = DRP.Profile.Begin()
	local selectQuery = Storage.Database:prepare("SELECT steam_id, first_seen, last_seen, last_name, rp_name, money, job_key, job_name, total_playtime_seconds, xp_points, xp_level, xp_prestige, xp_prestige_tokens, xp_prestige_items, civic_standing, role_behavior, role_goal, schema_version FROM drp_players WHERE steam_id = ? LIMIT 1")
	selectQuery:setString(1, request.steamID64)

	function selectQuery:onSuccess(data)
		local row = data and data[1]
		if row then
			DRP.Profile.Finish("storage.load", started)
			finishPlayerLoad(request, true, row)
			return
		end
		local insert = Storage.Database:prepare([[INSERT IGNORE INTO drp_players (steam_id, first_seen, last_seen, last_name, money, job_key, xp_points, xp_level, xp_prestige, xp_prestige_tokens, xp_prestige_items, civic_standing, role_behavior, role_goal, schema_version)
			VALUES (?, UTC_TIMESTAMP(), UTC_TIMESTAMP(), ?, 500, 'citizen', 0, 1, 0, 0, '[]', 0, '{}', 0, 13)]])
		bindIdentity(insert, request.steamID64, request.name)
		function insert:onSuccess()
			DRP.Profile.Finish("storage.load", started)
			finishPlayerLoad(request, true, {
				steam_id = request.steamID64, last_name = request.name, money = 500,
				job_key = "citizen", total_playtime_seconds = 0, xp_points = 0,
				xp_level = 1, xp_prestige = 0, xp_prestige_tokens = 0,
				xp_prestige_items = "[]", civic_standing = 0, role_behavior = "{}", role_goal = 0, schema_version = 13
			})
		end
		function insert:onError(reason)
			Storage.ErrorCount = Storage.ErrorCount + 1
			Storage.LastError = tostring(reason)
			DRP.Profile.Finish("storage.load", started)
			finishPlayerLoad(request, false, nil, reason)
		end
		insert:start()
		recordQueue()
	end

	function selectQuery:onError(reason)
		Storage.ErrorCount = Storage.ErrorCount + 1
		Storage.LastError = tostring(reason)
		DRP.Profile.Finish("storage.load", started)
		finishPlayerLoad(request, false, nil, reason)
	end
	selectQuery:start()
	recordQueue()
end

pumpPlayerLoads = function()
	if not Storage.Available or Storage.Stopping then return end
	while Storage.ActivePlayerLoads < Storage.MaxConcurrentPlayerLoads and Storage.PlayerLoadHead <= #Storage.PlayerLoadQueue do
		local request = Storage.PlayerLoadQueue[Storage.PlayerLoadHead]
		Storage.PlayerLoadHead = Storage.PlayerLoadHead + 1
		beginPlayerLoad(request)
	end
	if Storage.PlayerLoadHead > #Storage.PlayerLoadQueue then Storage.PlayerLoadQueue, Storage.PlayerLoadHead = {}, 1 end
end

function Storage.LoadPlayer(steamID64, name, callback)
	if Storage.Mode == "local" then
		if not Storage.Available or not Storage.LocalData then
			callback(false, nil, Storage.LastError)
			return
		end
		steamID64 = resolveLocalHostKey(steamID64, name)
		local row = Storage.LocalData.players[steamID64]
		if not istable(row) then
			local now = os.time()
			row = {
				steam_id = steamID64,
				first_seen = now,
				last_seen = now,
				last_name = string.sub(name or "", 1, 64),
				rp_name = "",
				job_name = "",
				money = 500,
				job_key = "citizen",
				total_playtime_seconds = 0,
				xp_points = 0,
				xp_level = 1,
				xp_prestige = 0,
				xp_prestige_tokens = 0,
				xp_prestige_items = "[]",
				civic_standing = 0,
				role_behavior = "{}",
				role_goal = 0,
				schema_version = 13
			}
			Storage.LocalData.players[steamID64] = row
			local saved, reason = flushLocalDatabase()
			if not saved then callback(false, nil, reason) return end
		end
		callback(true, table.Copy(row))
		return
	end
	if not Storage.Available or not Storage.Database then
		-- The database connection is asynchronous. Players commonly reconnect
		-- faster than MySQL after a host restart, so wait for onConnected rather
		-- than incorrectly creating an ephemeral $500 session.
		if Storage.Database and not Storage.Stopping then
			queuePendingLoad(steamID64, name, callback)
			return
		end
		callback(false, nil, Storage.LastError)
		return
	end
	Storage.PlayerLoadQueue[#Storage.PlayerLoadQueue + 1] = { steamID64 = steamID64, name = name, callback = callback }
	pumpPlayerLoads()
end

function Storage.SavePlayer(steamID64, name, rpName, jobName, money, jobKey, totalPlaytime, xpPoints, xpLevel, xpPrestige, xpPrestigeTokens, xpPrestigeItems, civicStanding, roleBehavior, roleGoal, callback)
		if Storage.Mode == "local" then
			if not Storage.Available or not Storage.LocalData then
				if callback then callback(false, Storage.LastError) end
				return false
			end
			steamID64 = resolveLocalHostKey(steamID64, name)
			local previous = Storage.LocalData.players[steamID64]
			Storage.LocalData.players[steamID64] = {
				steam_id = steamID64,
				first_seen = istable(previous) and previous.first_seen or os.time(),
				last_seen = os.time(),
				last_name = string.sub(name or "", 1, 64),
				rp_name = string.sub(rpName or name or "", 1, 48),
				job_name = string.sub(jobName or "", 1, 48),
				money = math.Clamp(math.floor(tonumber(money) or 0), 0, 4294967295),
				job_key = string.sub(jobKey or "citizen", 1, 24),
				total_playtime_seconds = math.max(0, math.floor(tonumber(totalPlaytime) or 0)),
				xp_points = math.max(0, math.floor(tonumber(xpPoints) or 0)),
				xp_level = math.max(1, math.floor(tonumber(xpLevel) or 1)),
				xp_prestige = math.max(0, math.floor(tonumber(xpPrestige) or 0)),
				xp_prestige_tokens = math.max(0, math.floor(tonumber(xpPrestigeTokens) or 0)),
				xp_prestige_items = isstring(xpPrestigeItems) and xpPrestigeItems or (xpPrestigeItems == nil and "[]" or util.TableToJSON(xpPrestigeItems or {}, false)),
				civic_standing = math.Clamp(math.floor(tonumber(civicStanding) or 0), -1000, 1000),
				role_behavior = isstring(roleBehavior) and roleBehavior or (roleBehavior == nil and "{}" or util.TableToJSON(roleBehavior or {}, false)),
				role_goal = math.Clamp(math.floor(tonumber(roleGoal) or 0), 0, 255),
				schema_version = 13
			}
			local saved, reason = flushLocalDatabase()
			if callback then callback(saved, reason) end
			return saved
		end
		if not Storage.Available or not Storage.Database then
			if callback then callback(false, Storage.LastError) end
			return
		end

		local query = Storage.Database:prepare([[
			INSERT INTO drp_players (steam_id, first_seen, last_seen, last_name, rp_name, job_name, money, job_key, total_playtime_seconds, xp_points, xp_level, xp_prestige, xp_prestige_tokens, xp_prestige_items, civic_standing, role_behavior, role_goal, schema_version)
			VALUES (?, UTC_TIMESTAMP(), UTC_TIMESTAMP(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 13)
			ON DUPLICATE KEY UPDATE last_seen = VALUES(last_seen), last_name = VALUES(last_name), rp_name = VALUES(rp_name), job_name = VALUES(job_name), money = VALUES(money), job_key = VALUES(job_key), total_playtime_seconds = VALUES(total_playtime_seconds), xp_points = VALUES(xp_points), xp_level = VALUES(xp_level), xp_prestige = VALUES(xp_prestige), xp_prestige_tokens = VALUES(xp_prestige_tokens), xp_prestige_items = VALUES(xp_prestige_items), civic_standing = VALUES(civic_standing), role_behavior = VALUES(role_behavior), role_goal = VALUES(role_goal), schema_version = VALUES(schema_version)
		]])
		query:setString(1, steamID64)
		query:setString(2, string.sub(name or "", 1, 64))
		query:setString(3, string.sub(rpName or name or "", 1, 48))
		query:setString(4, string.sub(jobName or "", 1, 48))
		query:setNumber(5, math.Clamp(math.floor(tonumber(money) or 0), 0, 4294967295))
		query:setString(6, string.sub(jobKey or "citizen", 1, 24))
		query:setNumber(7, math.max(0, math.floor(tonumber(totalPlaytime) or 0)))
		query:setNumber(8, math.max(0, math.floor(tonumber(xpPoints) or 0)))
		query:setNumber(9, math.max(1, math.floor(tonumber(xpLevel) or 1)))
		query:setNumber(10, math.max(0, math.floor(tonumber(xpPrestige) or 0)))
		query:setNumber(11, math.max(0, math.floor(tonumber(xpPrestigeTokens) or 0)))
		query:setString(12, isstring(xpPrestigeItems) and xpPrestigeItems or (xpPrestigeItems == nil and "[]" or util.TableToJSON(xpPrestigeItems or {}, false)))
		query:setNumber(13, math.Clamp(math.floor(tonumber(civicStanding) or 0), -1000, 1000))
		query:setString(14, isstring(roleBehavior) and roleBehavior or (roleBehavior == nil and "{}" or util.TableToJSON(roleBehavior or {}, false)))
		query:setNumber(15, math.Clamp(math.floor(tonumber(roleGoal) or 0), 0, 255))

		function query:onSuccess()
			if callback then callback(true) end
		end

	function query:onError(reason)
		Storage.ErrorCount = Storage.ErrorCount + 1
		Storage.LastError = tostring(reason)
		if callback then callback(false, reason) end
	end

	query:start()
	recordQueue()
end

local function finishPocketLoad(request, success, payload, reason)
	Storage.ActivePocketLoads = math.max(0, Storage.ActivePocketLoads - 1)
	request.callback(success, payload, reason)
	pumpPocketLoads()
end

local function beginPocketLoad(request)
	Storage.ActivePocketLoads = Storage.ActivePocketLoads + 1
	local query = Storage.Database:prepare("SELECT payload_json FROM drp_player_pockets WHERE steam_id = ? LIMIT 1")
	query:setString(1, request.steamID64)
	function query:onSuccess(data) finishPocketLoad(request, true, data and data[1] and data[1].payload_json or nil) end
	function query:onError(reason)
		Storage.ErrorCount = Storage.ErrorCount + 1
		Storage.LastError = tostring(reason)
		finishPocketLoad(request, false, nil, reason)
	end
	query:start()
	recordQueue()
end

pumpPocketLoads = function()
	if not Storage.Available or Storage.Stopping then return end
	while Storage.ActivePocketLoads < Storage.MaxConcurrentPocketLoads and Storage.PocketLoadHead <= #Storage.PocketLoadQueue do
		local request = Storage.PocketLoadQueue[Storage.PocketLoadHead]
		Storage.PocketLoadHead = Storage.PocketLoadHead + 1
		beginPocketLoad(request)
	end
	if Storage.PocketLoadHead > #Storage.PocketLoadQueue then Storage.PocketLoadQueue, Storage.PocketLoadHead = {}, 1 end
end

function Storage.LoadPocket(steamID64, callback)
	if Storage.Mode == "local" then
		if not Storage.Available or not Storage.LocalData then callback(false, nil, Storage.LastError) return end
		callback(true, Storage.LocalData.pockets[resolveLocalHostKey(steamID64)])
		return
	end
	if not Storage.Available or not Storage.Database then
		callback(false, nil, Storage.LastError)
		return
	end
	Storage.PocketLoadQueue[#Storage.PocketLoadQueue + 1] = { steamID64 = steamID64, callback = callback }
	pumpPocketLoads()
end

function Storage.SavePocket(steamID64, payload, callback)
	if Storage.Mode == "local" then
		if not Storage.Available or not Storage.LocalData then
			if callback then callback(false, Storage.LastError) end
			return false
		end
		Storage.LocalData.pockets[resolveLocalHostKey(steamID64)] = tostring(payload or "")
		local saved, reason = flushLocalDatabase()
		if callback then callback(saved, reason) end
		return saved
	end
	if not Storage.Available or not Storage.Database then
		if callback then callback(false, Storage.LastError) end
		return false
	end
	local query = Storage.Database:prepare([[INSERT INTO drp_player_pockets (steam_id, payload_json, updated_at)
		VALUES (?, ?, UTC_TIMESTAMP())
		ON DUPLICATE KEY UPDATE payload_json = VALUES(payload_json), updated_at = UTC_TIMESTAMP()]])
	query:setString(1, steamID64)
	query:setString(2, payload)
	function query:onSuccess() if callback then callback(true) end end
	function query:onError(reason)
		Storage.ErrorCount = Storage.ErrorCount + 1
		Storage.LastError = tostring(reason)
		if callback then callback(false, reason) end
	end
	query:start()
	recordQueue()
	return true
end

function Storage.LoadCrafting(steamID64, callback)
	if Storage.Mode == "local" then
		if not Storage.Available or not Storage.LocalData then callback(false, nil, Storage.LastError) return false end
		callback(true, Storage.LocalData.crafting[resolveLocalHostKey(steamID64)])
		return true
	end
	if not Storage.Available or not Storage.Database then callback(false, nil, Storage.LastError) return false end
	local query = Storage.Database:prepare("SELECT payload_json FROM drp_player_crafting WHERE steam_id = ? LIMIT 1")
	query:setString(1, tostring(steamID64))
	function query:onSuccess(data) callback(true, data and data[1] and data[1].payload_json or nil) end
	function query:onError(reason) Storage.ErrorCount=Storage.ErrorCount+1 Storage.LastError=tostring(reason) callback(false,nil,reason) end
	query:start() recordQueue() return true
end

function Storage.SaveCrafting(steamID64, payload, callback)
	if Storage.Mode == "local" then
		if not Storage.Available or not Storage.LocalData then if callback then callback(false,Storage.LastError) end return false end
		Storage.LocalData.crafting[resolveLocalHostKey(steamID64)] = tostring(payload or "")
		local saved,reason=flushLocalDatabase() if callback then callback(saved,reason) end return saved
	end
	if not Storage.Available or not Storage.Database then if callback then callback(false,Storage.LastError) end return false end
	local query=Storage.Database:prepare([[INSERT INTO drp_player_crafting (steam_id, payload_json, updated_at) VALUES (?, ?, UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE payload_json=VALUES(payload_json), updated_at=UTC_TIMESTAMP()]])
	query:setString(1,tostring(steamID64)) query:setString(2,tostring(payload or ""))
	function query:onSuccess() if callback then callback(true) end end
	function query:onError(reason) Storage.ErrorCount=Storage.ErrorCount+1 Storage.LastError=tostring(reason) if callback then callback(false,reason) end end
	query:start() recordQueue() return true
end

function Storage.LoadWorldState(stateKey, callback)
	if Storage.Mode == "local" then
		if not Storage.Available or not Storage.LocalData then
			if callback then callback(false, nil, Storage.LastError) end
			return false
		end
		stateKey = string.sub(tostring(stateKey or ""), 1, 64)
		if stateKey == "" then return false end
		if callback then callback(true, Storage.LocalData.world[stateKey]) end
		return true
	end
	if not Storage.Available or not Storage.Database then
		if callback then callback(false, nil, Storage.LastError) end
		return false
	end
	stateKey = string.sub(tostring(stateKey or ""), 1, 64)
	if stateKey == "" then return false end
	local query = Storage.Database:prepare("SELECT payload_json FROM drp_world_state WHERE state_key = ? LIMIT 1")
	query:setString(1, stateKey)
	function query:onSuccess(data)
		if callback then callback(true, data and data[1] and data[1].payload_json or nil) end
	end
	function query:onError(reason)
		Storage.ErrorCount = Storage.ErrorCount + 1
		Storage.LastError = tostring(reason)
		if callback then callback(false, nil, reason) end
	end
	query:start()
	recordQueue()
	return true
end

function Storage.SaveWorldState(stateKey, payload, callback)
	if Storage.Mode == "local" then
		if not Storage.Available or not Storage.LocalData then
			if callback then callback(false, Storage.LastError) end
			return false
		end
		stateKey = string.sub(tostring(stateKey or ""), 1, 64)
		if stateKey == "" or not isstring(payload) or payload == "" then return false end
		Storage.LocalData.world[stateKey] = payload
		local saved, reason = flushLocalDatabase()
		if callback then callback(saved, reason) end
		return saved
	end
	if not Storage.Available or not Storage.Database then
		if callback then callback(false, Storage.LastError) end
		return false
	end
	stateKey = string.sub(tostring(stateKey or ""), 1, 64)
	if stateKey == "" or not isstring(payload) or payload == "" then return false end
	local query = Storage.Database:prepare([[INSERT INTO drp_world_state (state_key, payload_json, updated_at)
		VALUES (?, ?, UTC_TIMESTAMP())
		ON DUPLICATE KEY UPDATE payload_json = VALUES(payload_json), updated_at = UTC_TIMESTAMP()]])
	query:setString(1, stateKey)
	query:setString(2, payload)
	function query:onSuccess() if callback then callback(true) end end
	function query:onError(reason)
		Storage.ErrorCount = Storage.ErrorCount + 1
		Storage.LastError = tostring(reason)
		if callback then callback(false, reason) end
	end
	query:start()
	recordQueue()
	return true
end

function Storage.IsLocal()
	return Storage.Mode == "local"
end

function Storage.LoadLocalGovernment(callback)
	if Storage.Mode ~= "local" or not Storage.Available or not Storage.LocalData then
		if callback then callback(false, nil, Storage.LastError) end
		return false
	end
	if callback then callback(true, table.Copy(Storage.LocalData.government)) end
	return true
end

function Storage.SaveLocalGovernment(treasury, taxRate, allocations, callback)
	if Storage.Mode ~= "local" or not Storage.Available or not Storage.LocalData then
		if callback then callback(false, Storage.LastError) end
		return false
	end
	local cleanAllocations = {}
	for jobKey, percent in pairs(allocations or {}) do
		cleanAllocations[string.sub(tostring(jobKey), 1, 24)] = math.Clamp(math.floor(tonumber(percent) or 0), 0, 50)
	end
	Storage.LocalData.government = {
		treasury = math.Clamp(math.floor(tonumber(treasury) or 0), 0, 4294967295),
		tax_rate = math.Clamp(math.floor(tonumber(taxRate) or 0), 0, 50),
		allocations = cleanAllocations
	}
	local saved, reason = flushLocalDatabase()
	if callback then callback(saved, reason) end
	return saved
end
