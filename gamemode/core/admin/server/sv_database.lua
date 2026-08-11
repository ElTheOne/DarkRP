local REQUEST = "drp_admin_database_request_v1"
local RESPONSE = "drp_admin_database_response_v1"
local MUTATE = "drp_admin_database_mutate_v1"
local PAGE_SIZE = 15
local MAX_REQUEST = 65535
local MAX_CELL = 8192

util.AddNetworkString(REQUEST)
util.AddNetworkString(RESPONSE)
util.AddNetworkString(MUTATE)

local DatabaseAdmin = { Tables = {}, Schemas = {}, CacheUntil = 0 }
DRP.DatabaseAdmin = DatabaseAdmin
DRP.Services.Register("database_admin", DatabaseAdmin)

local function authorized(ply)
	return IsValid(ply) and DRP.Admin and DRP.Admin.CanSetRanks and DRP.Admin.CanSetRanks(ply)
end

local function send(ply, payload)
	if not IsValid(ply) or not authorized(ply) then return end
	local json = util.TableToJSON(payload or {}, false) or "{}"
	local compressed = util.Compress(json) or ""
	if #compressed > 1048575 then
		json = util.TableToJSON({ kind = "error", message = "Database response exceeded the safe network limit." }) or "{}"
		compressed = util.Compress(json) or ""
	end
	net.Start(RESPONSE)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(#compressed, 20)
		if #compressed > 0 then net.WriteData(compressed, #compressed) end
	net.Send(ply)
end

local function readPayload()
	local length = net.ReadUInt(16)
	if length <= 0 or length > MAX_REQUEST then return nil end
	local raw = util.Decompress(net.ReadData(length) or "")
	local decoded = raw and util.JSONToTable(raw) or nil
	return istable(decoded) and decoded or nil
end

local function identifier(value)
	value = tostring(value or "")
	return string.match(value, "^[%w_]+$") and value or nil
end

local function onlinePlayer(steamID64)
	if DRP.Players and DRP.Players.Online then return DRP.Players.Online(steamID64) end
	for _, ply in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do
		if IsValid(ply) and ply:SteamID64() == tostring(steamID64) then return ply end
	end
end

local function cleanCell(value)
	if value == nil then return { null = true, value = "" } end
	local text = tostring(value)
	return { value = string.sub(text, 1, MAX_CELL), truncated = #text > MAX_CELL, bytes = #text }
end

local function schemaForClient(schema)
	local output = {}
	for _, column in ipairs(schema or {}) do
		output[#output + 1] = {
			name = column.name, type = column.type, nullable = column.nullable,
			primary = column.primary, generated = column.generated
		}
	end
	return output
end

local function discover(callback)
	if DRP.Storage.Mode == "local" then
		DatabaseAdmin.Tables = {
			"drp_players", "drp_player_pockets", "drp_player_crafting",
			"drp_world_state", "drp_government_state", "drp_job_funding"
		}
		callback(true, DatabaseAdmin.Tables)
		return
	end
	if not DRP.Storage.Available or not DRP.Storage.Database then callback(false, DRP.Storage.LastError) return end
	if DatabaseAdmin.CacheUntil > CurTime() and #DatabaseAdmin.Tables > 0 then callback(true, DatabaseAdmin.Tables) return end
	local query = DRP.Storage.Database:query("SHOW TABLES")
	function query:onSuccess(rows)
		local tables = {}
		for _, row in ipairs(rows or {}) do
			for _, value in pairs(row) do
				value = identifier(value)
				if value then tables[#tables + 1] = value end
				break
			end
		end
		table.sort(tables)
		DatabaseAdmin.Tables, DatabaseAdmin.CacheUntil = tables, CurTime() + 60
		callback(true, tables)
	end
	function query:onError(reason) callback(false, tostring(reason)) end
	query:start()
end

local localSchemas = {
	drp_players = {
		{ name = "steam_id", type = "bigint unsigned", primary = true }, { name = "first_seen", type = "bigint" },
		{ name = "last_seen", type = "bigint" }, { name = "last_name", type = "varchar(64)" }, { name = "rp_name", type = "varchar(48)" },
		{ name = "money", type = "bigint unsigned" }, { name = "job_key", type = "varchar(24)" }, { name = "job_name", type = "varchar(48)" },
		{ name = "total_playtime_seconds", type = "bigint unsigned" }, { name = "xp_points", type = "bigint unsigned" },
		{ name = "xp_level", type = "tinyint unsigned" }, { name = "xp_prestige", type = "tinyint unsigned" },
		{ name = "xp_prestige_tokens", type = "tinyint unsigned" }, { name = "xp_prestige_items", type = "mediumtext" },
		{ name = "civic_standing", type = "smallint" }, { name = "role_behavior", type = "mediumtext" },
		{ name = "role_goal", type = "tinyint unsigned" }, { name = "schema_version", type = "smallint unsigned" }
	},
	drp_player_pockets = { { name = "steam_id", type = "bigint unsigned", primary = true }, { name = "payload_json", type = "mediumtext" } },
	drp_player_crafting = { { name = "steam_id", type = "bigint unsigned", primary = true }, { name = "payload_json", type = "mediumtext" } },
	drp_world_state = { { name = "state_key", type = "varchar(64)", primary = true }, { name = "payload_json", type = "mediumtext" } },
	drp_government_state = { { name = "singleton_id", type = "tinyint unsigned", primary = true }, { name = "treasury", type = "bigint unsigned" }, { name = "tax_rate", type = "tinyint unsigned" } },
	drp_job_funding = { { name = "job_key", type = "varchar(24)", primary = true }, { name = "bonus_percent", type = "tinyint unsigned" } }
}

local function loadSchema(tableName, callback)
	if DRP.Storage.Mode == "local" then callback(localSchemas[tableName]) return end
	if DatabaseAdmin.Schemas[tableName] then callback(DatabaseAdmin.Schemas[tableName]) return end
	local query = DRP.Storage.Database:query("SHOW COLUMNS FROM `" .. tableName .. "`")
	function query:onSuccess(rows)
		local schema = {}
		for _, row in ipairs(rows or {}) do
			schema[#schema + 1] = {
				name = identifier(row.Field), type = tostring(row.Type or "text"), nullable = row.Null == "YES",
				primary = row.Key == "PRI", generated = string.find(string.lower(tostring(row.Extra or "")), "generated", 1, true) ~= nil
			}
		end
		DatabaseAdmin.Schemas[tableName] = schema
		callback(schema)
	end
	function query:onError(reason) callback(nil, tostring(reason)) end
	query:start()
end

local function localRows(tableName)
	local data, rows = DRP.Storage.LocalData or {}, {}
	if tableName == "drp_players" then
		for key, row in pairs(data.players or {}) do local copy = table.Copy(row) copy.steam_id = key rows[#rows + 1] = copy end
	elseif tableName == "drp_player_pockets" then
		for key, payload in pairs(data.pockets or {}) do rows[#rows + 1] = { steam_id = key, payload_json = payload } end
	elseif tableName == "drp_player_crafting" then
		for key, payload in pairs(data.crafting or {}) do rows[#rows + 1] = { steam_id = key, payload_json = payload } end
	elseif tableName == "drp_world_state" then
		for key, payload in pairs(data.world or {}) do rows[#rows + 1] = { state_key = key, payload_json = payload } end
	elseif tableName == "drp_government_state" then
		rows[1] = { singleton_id = 1, treasury = data.government and data.government.treasury or 0, tax_rate = data.government and data.government.tax_rate or 0 }
	elseif tableName == "drp_job_funding" then
		for key, value in pairs(data.government and data.government.allocations or {}) do rows[#rows + 1] = { job_key = key, bonus_percent = value } end
	end
	return rows
end

local function primaryIdentity(schema, row)
	local output = {}
	for _, column in ipairs(schema or {}) do if column.primary then output[column.name] = tostring(row[column.name] or "") end end
	return output
end

local function primarySortValue(schema, row)
	local parts = {}
	for _, column in ipairs(schema or {}) do if column.primary then parts[#parts + 1] = tostring(row[column.name] or "") end end
	return table.concat(parts, "\0")
end

function DatabaseAdmin:SendTables(ply)
	discover(function(success, result)
		if not IsValid(ply) then return end
		if not success then send(ply, { kind = "error", message = result }) return end
		send(ply, { kind = "tables", tables = result, backend = DRP.Storage.Mode, available = DRP.Storage.Available == true })
	end)
end

function DatabaseAdmin:SendRows(ply, tableName, page)
	tableName, page = identifier(tableName), math.max(1, math.floor(tonumber(page) or 1))
	discover(function(success, tables)
		if not success or not table.HasValue(tables or {}, tableName) then send(ply, { kind = "error", message = success and "Unknown database table." or tables }) return end
		loadSchema(tableName, function(schema, reason)
			if not schema then send(ply, { kind = "error", message = reason or "Could not read table schema." }) return end
			local function deliver(rows, total)
				local output = {}
				for _, row in ipairs(rows or {}) do
					local values = {}
					for _, column in ipairs(schema) do values[column.name] = cleanCell(row[column.name]) end
					output[#output + 1] = { values = values, identity = primaryIdentity(schema, row) }
				end
				send(ply, { kind = "rows", table = tableName, page = page, pageSize = PAGE_SIZE, total = total or #output, columns = schemaForClient(schema), rows = output })
			end
			if DRP.Storage.Mode == "local" then
				local all = localRows(tableName)
				table.sort(all, function(a, b) return primarySortValue(schema, a) < primarySortValue(schema, b) end)
				local pageRows = {}
				for index = (page - 1) * PAGE_SIZE + 1, math.min(#all, page * PAGE_SIZE) do pageRows[#pageRows + 1] = all[index] end
				deliver(pageRows, #all)
				return
			end
			local countQuery = DRP.Storage.Database:query("SELECT COUNT(*) AS total FROM `" .. tableName .. "`")
			function countQuery:onSuccess(countRows)
				local total = tonumber(countRows and countRows[1] and countRows[1].total) or 0
				local offset = (page - 1) * PAGE_SIZE
				local order = {}
				for _, column in ipairs(schema) do if column.primary then order[#order + 1] = "`" .. column.name .. "`" end end
				local orderSQL = #order > 0 and (" ORDER BY " .. table.concat(order, ", ")) or ""
				local rowQuery = DRP.Storage.Database:query("SELECT * FROM `" .. tableName .. "`" .. orderSQL .. " LIMIT " .. PAGE_SIZE .. " OFFSET " .. offset)
				function rowQuery:onSuccess(rows) deliver(rows, total) end
				function rowQuery:onError(errorText) send(ply, { kind = "error", message = tostring(errorText) }) end
				rowQuery:start()
			end
			function countQuery:onError(errorText) send(ply, { kind = "error", message = tostring(errorText) }) end
			countQuery:start()
		end)
	end)
end

local function findColumn(schema, name)
	for _, column in ipairs(schema or {}) do if column.name == name then return column end end
end

local function livePlayerUpdate(actor, steamID64, column, value)
	local ply = onlinePlayer(steamID64)
	if not IsValid(ply) then return false end
	if column == "money" and DRP.Economy then DRP.Economy.Set(ply, value, false, "database admin edit")
	elseif column == "total_playtime_seconds" then ply.DRPTotalPlaytimeBase = math.max(0, math.floor(tonumber(value) or 0)) ply.DRPSessionStartedAt = CurTime()
	elseif column == "civic_standing" and DRP.Civic then DRP.Civic:Set(ply, value, "database admin edit", false)
	elseif column == "rp_name" then
		ply.DRPRPNameValue = string.sub(tostring(value), 1, 48)
		if DRP.Identity and DRP.Identity.States and DRP.Identity.States[ply] then DRP.Identity:UpdateName(ply, ply.DRPRPNameValue) end
	elseif column == "job_name" then ply.DRPJobNameValue = string.sub(tostring(value), 1, 48)
	elseif (column == "xp_points" or column == "xp_level" or column == "xp_prestige" or column == "xp_prestige_tokens") and DRP.Experience then
		if not DRP.Experience:SetPersistentField(ply, column, value) then return false end
	else return false end
	if DRP.Roster then DRP.Roster:Update(ply) end
	if DRP.Network then DRP.Network.SendProfile(ply) end
	if DRP.Economy and DRP.Economy.QueueSave then DRP.Economy.QueueSave(ply, "database admin edit") end
	if DRP.Audit then DRP.Audit.Log(actor, "database_live_update", ply, column) end
	return true
end

function DatabaseAdmin:Mutate(ply, payload)
	local action, tableName = tostring(payload.action or ""), identifier(payload.table)
	if action == "inventory" then
		if not DRP.Inventory or not DRP.Inventory.AdminEdit then send(ply, { kind = "error", message = "Hands editor is unavailable." }) return end
		DRP.Inventory.AdminEdit(ply, tostring(payload.steamID64 or ""), payload.operation, payload.data, function(ok, result)
			if not IsValid(ply) then return end
			if ok then send(ply, { kind = "inventory", steamID64 = tostring(payload.steamID64), snapshot = result })
			else send(ply, { kind = "error", message = tostring(result or "Hands edit failed.") }) end
		end)
		return
	end
	if action == "inventory_open" then
		DRP.Inventory.AdminEdit(ply, tostring(payload.steamID64 or ""), "snapshot", {}, function(ok, result)
			if ok then send(ply, { kind = "inventory", steamID64 = tostring(payload.steamID64), snapshot = result }) else send(ply, { kind = "error", message = tostring(result) }) end
		end)
		return
	end
	if not tableName or not istable(payload.identity) then send(ply, { kind = "error", message = "Invalid database mutation." }) return end
	discover(function(discovered, tables)
		if not discovered or not table.HasValue(tables or {}, tableName) then send(ply, { kind = "error", message = "Unknown database table." }) return end
	loadSchema(tableName, function(schema, reason)
		if not schema then send(ply, { kind = "error", message = reason }) return end
		local primary, where, values = {}, {}, {}
		for _, column in ipairs(schema) do
			if column.primary then
				local value = payload.identity[column.name]
				if value == nil then send(ply, { kind = "error", message = "Missing primary key " .. column.name }) return end
				primary[column.name], where[#where + 1], values[#values + 1] = tostring(value), "`" .. column.name .. "` = ?", tostring(value)
			end
		end
		if #where == 0 then send(ply, { kind = "error", message = "Rows without primary keys are read-only." }) return end
		if action == "update" then
			local column = findColumn(schema, identifier(payload.column))
			if not column or column.primary or column.generated then send(ply, { kind = "error", message = "That column cannot be edited." }) return end
			if tableName == "drp_player_pockets" and column.name == "payload_json" then send(ply, { kind = "error", message = "Use the Hands inventory editor for this payload." }) return end
			local value = string.sub(tostring(payload.value or ""), 1, 65535)
			if tableName == "drp_players" and IsValid(onlinePlayer(primary.steam_id)) then
				if livePlayerUpdate(ply, primary.steam_id, column.name, value) then send(ply, { kind = "mutated", table = tableName, message = "Live player value updated." })
				else send(ply, { kind = "error", message = "That live field has no safe authoritative editor. Disconnect the player before changing it." }) end
				return
			end
			if DRP.Storage.Mode == "local" then
				local rows = localRows(tableName)
				for _, row in ipairs(rows) do
					local match = true for key, expected in pairs(primary) do if tostring(row[key]) ~= expected then match = false break end end
					if match then row[column.name] = value break end
				end
				send(ply, { kind = "error", message = "Use the live service editors for local listen-server values." })
				return
			end
			local query = DRP.Storage.Database:prepare("UPDATE `" .. tableName .. "` SET `" .. column.name .. "` = ? WHERE " .. table.concat(where, " AND ") .. " LIMIT 1")
			query:setString(1, value) for index, keyValue in ipairs(values) do query:setString(index + 1, keyValue) end
			function query:onSuccess() if DRP.Audit then DRP.Audit.Log(ply, "database_update", tableName, column.name) end send(ply, { kind = "mutated", table = tableName, message = "Value updated." }) end
			function query:onError(errorText) send(ply, { kind = "error", message = tostring(errorText) }) end
			query:start()
		elseif action == "delete" then
			if tableName == "drp_schema_migrations" then send(ply, { kind = "error", message = "Schema migration history cannot be deleted from the live panel." }) return end
			if primary.steam_id and IsValid(onlinePlayer(primary.steam_id)) then send(ply, { kind = "error", message = "Disconnect the player before deleting their durable data." }) return end
			if DRP.Storage.Mode == "local" then send(ply, { kind = "error", message = "Local listen-server row deletion is disabled to protect the recovery database." }) return end
			local query = DRP.Storage.Database:prepare("DELETE FROM `" .. tableName .. "` WHERE " .. table.concat(where, " AND ") .. " LIMIT 1")
			for index, keyValue in ipairs(values) do query:setString(index, keyValue) end
			function query:onSuccess() if DRP.Audit then DRP.Audit.Log(ply, "database_delete", tableName, util.TableToJSON(primary) or "") end send(ply, { kind = "mutated", table = tableName, message = "Row deleted." }) end
			function query:onError(errorText) send(ply, { kind = "error", message = tostring(errorText) }) end
			query:start()
		end
	end)
	end)
end

DRP.Net.Receive(REQUEST, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not authorized(ply) or not DRP.Net.Allow(ply, "database_request", 0.3, 4) then return end
	local payload = readPayload()
	if not payload then return end
	if payload.action == "tables" then DatabaseAdmin:SendTables(ply)
	elseif payload.action == "rows" then DatabaseAdmin:SendRows(ply, payload.table, payload.page) end
end)

DRP.Net.Receive(MUTATE, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not authorized(ply) or not DRP.Net.Allow(ply, "database_mutate", 0.4, 3) then return end
	local payload = readPayload()
	if payload then DatabaseAdmin:Mutate(ply, payload) end
end)

function DatabaseAdmin:Start() end
function DatabaseAdmin:Stop() self.Tables, self.Schemas, self.CacheUntil = {}, {}, 0 end
