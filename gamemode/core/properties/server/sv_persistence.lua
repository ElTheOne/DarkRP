local Properties = assert(DRP and DRP.Properties, "properties service must exist before persistence loads")
local Geometry = assert(Properties.Geometry, "property geometry must load before persistence")
local clean = assert(Properties.Internal and Properties.Internal.Clean)
local roleKey = assert(Properties.Internal and Properties.Internal.RoleKey)
local sanitizeBuildZones = Geometry.SanitizeBuildZones
local defaultRoles = Properties.DefaultRoles
local permissionKeys = Properties.PermissionKeys
local Persistence = {}

local function dataPath()
	return "darkrp/properties/" .. game.GetMap():gsub("[^%w_%-]", "_") .. ".json"
end

local function backupDataPath()
	return "darkrp/properties/" .. game.GetMap():gsub("[^%w_%-]", "_") .. ".backup.json"
end

local function worldStateKey()
	return string.sub("properties:" .. game.GetMap():gsub("[^%w_%-]", "_"), 1, 64)
end

local function userDefinitionCount(definitions)
	local count = 0
	for _, definition in pairs(istable(definitions) and definitions or {}) do
		if not (istable(definition) and definition.kind == "world") then count = count + 1 end
	end
	return count
end

local function steamID(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:SteamID64() or nil
end

local function onlinePlayer(id)
	return DRP.Players.Online(id)
end

local function addPropertyIndex(index, steamID64, propertyID)
	steamID64 = tostring(steamID64 or "")
	if steamID64 == "" then return end
	local set = index[steamID64]
	if not set then set = {} index[steamID64] = set end
	set[tonumber(propertyID)] = true
end

local function removePropertyIndex(index, steamID64, propertyID)
	local set = index[tostring(steamID64 or "")]
	if not set then return end
	set[tonumber(propertyID)] = nil
	if next(set) == nil then index[tostring(steamID64 or "")] = nil end
end

function Properties:RebuildMembershipIndexes()
	self.OwnedProperties, self.MemberProperties = {}, {}
	for propertyID, lease in pairs(self.Leases) do
		addPropertyIndex(self.OwnedProperties, lease.owner_id, propertyID)
		for memberID in pairs(lease.members or {}) do addPropertyIndex(self.MemberProperties, memberID, propertyID) end
	end
end

function Properties:IndexEntity(entity, propertyID)
	if not IsValid(entity) then return end
	local previous = tonumber(entity.DRPIndexedPropertyID)
	if previous and self.EntitiesByProperty[previous] then self.EntitiesByProperty[previous][entity] = nil end
	propertyID = tonumber(propertyID)
	entity.DRPIndexedPropertyID = propertyID
	if not propertyID then return end
	local entities = self.EntitiesByProperty[propertyID]
	if not entities then entities = setmetatable({}, { __mode = "k" }) self.EntitiesByProperty[propertyID] = entities end
	entities[entity] = true
end

local function ownerDeadlineKey(propertyID)
	return "property:owner:" .. tonumber(propertyID)
end

local function memberDeadlineKey(propertyID, memberID)
	return "property:member:" .. tonumber(propertyID) .. ":" .. tostring(memberID)
end

function Properties:ScheduleOwnerDeadline(propertyID, forceOffline)
	propertyID = tonumber(propertyID)
	local lease = self.Leases[propertyID]
	if not lease then DRP.Deadlines.Cancel(ownerDeadlineKey(propertyID)) return end
	lease.lease_paid_until_unix = math.max(tonumber(lease.lease_paid_until_unix) or 0, os.time())
	local deadline = CurTime() + math.max(0, lease.lease_paid_until_unix - os.time())
	DRP.Deadlines.Schedule(ownerDeadlineKey(propertyID), deadline, function()
		local current = self.Leases[propertyID]
		if not current then return end
		if self.ActiveRaids[propertyID] then DRP.Deadlines.Schedule(ownerDeadlineKey(propertyID), CurTime() + 5, function() self:ScheduleOwnerDeadline(propertyID) end) return end
		if (current.lease_paid_until_unix or 0) <= os.time() then
			local currentOwner = onlinePlayer(current.owner_id)
			if IsValid(currentOwner) then DRP.Net.Notify(currentOwner, "Your base lease expired because its scheduled payment was not funded.", 3) end
			self:Release(propertyID, "unpaid scheduled base lease", 0)
		else
			self:ScheduleOwnerDeadline(propertyID)
		end
	end)
end

function Properties:ScheduleMemberDeadline(propertyID, memberID)
	propertyID, memberID = tonumber(propertyID), tostring(memberID)
	local lease = self.Leases[propertyID]
	local member = lease and lease.members[memberID]
	local key = memberDeadlineKey(propertyID, memberID)
	if not member then DRP.Deadlines.Cancel(key) return end
	local now = os.time()
	local dueUnix
	if (member.eviction_unix or 0) > 0 then dueUnix = member.eviction_unix
	elseif (member.rent or 0) > 0 then dueUnix = member.next_rent_unix or (now + self.RentInterval) end
	if not dueUnix then DRP.Deadlines.Cancel(key) return end
	DRP.Deadlines.Schedule(key, CurTime() + math.max(0, dueUnix - now), function()
		local currentLease = self.Leases[propertyID]
		local current = currentLease and currentLease.members[memberID]
		if not current then return end
		local currentUnix = os.time()
		if (current.eviction_unix or 0) > 0 and current.eviction_unix <= currentUnix then
			self:RemoveMember(propertyID, memberID, current.eviction_reason or "evicted after notice")
			return
		end
		if (current.rent or 0) > 0 and (current.next_rent_unix or 0) <= currentUnix then
			local tenant = onlinePlayer(memberID)
			if not IsValid(tenant) or not tenant:DRPPersistent() then return end
			if DRP.Economy.Take(tenant, current.rent, "rent for " .. self.Definitions[propertyID].name) then
				self:Credit(currentLease.owner_id, current.rent, "property rent")
				current.next_rent_unix = currentUnix + self.RentInterval
				if DRP.Audit then DRP.Audit.Log(tenant, "property_rent_paid", onlinePlayer(currentLease.owner_id), "#" .. propertyID .. " $" .. current.rent) end
			else
				current.eviction_unix = currentUnix + self.EvictionNotice
				current.eviction_reason = "unpaid rent"
				DRP.Net.Notify(tenant, "Rent failed. You have " .. self.EvictionNotice .. " seconds before eviction.", 3)
				local owner = onlinePlayer(currentLease.owner_id)
				if IsValid(owner) then DRP.Net.Notify(owner, tenant:Nick() .. " failed rent and received an eviction notice.", 2) end
				if DRP.Audit then DRP.Audit.Log(tenant, "property_rent_failed", owner, "#" .. propertyID .. " $" .. current.rent) end
			end
			self:Save()
			self:SyncAll(propertyID)
		end
		self:ScheduleMemberDeadline(propertyID, memberID)
	end)
end

function Properties:ScheduleAllDeadlines()
	for propertyID, lease in pairs(self.Leases) do
		self:ScheduleOwnerDeadline(propertyID)
		for memberID in pairs(lease.members) do self:ScheduleMemberDeadline(propertyID, memberID) end
	end
end

local function definitionPrice(definition)
	if Properties.IsWorldDefinition(definition) then return 0 end
	local override = math.floor(tonumber(definition.price) or 0)
	return math.max(Properties.BaseDoorPrice, override > 0 and override or (#definition.doors * Properties.BaseDoorPrice))
end

local function definitionLeaseRate(definition)
	if Properties.IsWorldDefinition(definition) then return 0 end
	local override = math.floor(tonumber(definition.lease_price) or 0)
	return math.max(1, override > 0 and override or math.ceil(definitionPrice(definition) * 0.1))
end

function Properties.CanConfigure(ply)
	return IsValid(ply) and DRP.Admin
		and DRP.AdminRankLevel(DRP.Admin.RankKey(ply)) >= DRP.AdminRankLevel("headadmin")
end

local function cloneRoles(roles)
	local result = table.Copy(defaultRoles)
	for name, permissions in pairs(roles or {}) do
		local key = roleKey(name)
		if key and key ~= "owner" and istable(permissions) then
			result[key] = result[key] or {}
			for permission in pairs(permissionKeys) do
				-- New permissions retain their role default when loading an older lease.
				if permissions[permission] ~= nil then result[key][permission] = permissions[permission] == true end
			end
		end
	end
	return result
end

function Properties.IsWorldDefinition(definition)
	return istable(definition) and definition.kind == "world"
end

-- The World is a permanent, doorless property used only as a container for
-- administrator-marked street build zones.
function Properties:EnsureWorldDefinition()
	local worldID, changed
	for id, definition in pairs(self.Definitions) do
		if self.IsWorldDefinition(definition)
		or (string.lower(clean(definition.name, 48)) == "world"
			and #(definition.doors or {}) == 0
			and self.Leases[id] == nil) then
			worldID = id
			break
		end
	end

	if not worldID then
		worldID = self.NextID
		self.NextID = math.min(65534, self.NextID + 1)
		self.Definitions[worldID] = {
			id = worldID,
			kind = "world",
			name = "World",
			doors = {},
			build_zones = {},
			price = 0,
			lease_price = 0,
			buyable = false
		}
		changed = true
	else
		local definition = self.Definitions[worldID]
		if definition.kind ~= "world"
		or definition.name ~= "World"
		or #(definition.doors or {}) > 0
		or definition.buyable ~= false
		or tonumber(definition.price) ~= 0
		or tonumber(definition.lease_price) ~= 0 then
			changed = true
		end
		definition.kind = "world"
		definition.name = "World"
		definition.doors = {}
		definition.build_zones = sanitizeBuildZones(definition.build_zones)
		definition.price = 0
		definition.lease_price = 0
		definition.buyable = false
	end

	if self.Leases[worldID] then
		self.Leases[worldID] = nil
		changed = true
	end
	self.WorldDefinitionID = worldID
	if changed then self:Save() end
	return self.Definitions[worldID], changed == true
end

function Properties:Save()
	self.Dirty = true
end

function Properties:Payload()
	return {
		version = 4,
		revision = self.Revision,
		saved_at = self.LastSavedAt,
		next_id = self.NextID,
		definitions = self.Definitions,
		leases = self.Leases,
		pending_credits = self.PendingCredits,
		pending_vault_items = self.PendingVaultItems,
		player_raid_cooldowns = self.PlayerRaidCooldowns
	}
end

function Properties:Flush()
	if not self.Dirty then return end
	local started = DRP.Profile.Begin()
	file.CreateDir("darkrp")
	file.CreateDir("darkrp/properties")
	local existingRaw = file.Read(dataPath(), "DATA") or ""
	local existing = util.JSONToTable(existingRaw)
	local backupRaw = file.Read(backupDataPath(), "DATA") or ""
	local backup = util.JSONToTable(backupRaw)
	local existingGroups = math.max(
		userDefinitionCount(istable(existing) and existing.definitions or {}),
		userDefinitionCount(istable(backup) and backup.definitions or {})
	)
	local liveGroups = userDefinitionCount(self.Definitions)
	-- A partially started/stopped service previously replaced a valid property
	-- file with an empty payload. Empty runtime state is never authoritative over
	-- a populated, parseable disk snapshot. Keep Dirty set so a later successful
	-- load can reconcile and save normally.
	if liveGroups == 0 and existingGroups > 0 then
		ErrorNoHalt(string.format(
			"[DRP PROPERTIES] refusing destructive empty save: disk_groups=%d disk_bytes=%d live_groups=0\n",
			existingGroups, #existingRaw))
		DRP.Profile.Finish("properties.flush", started)
		return false
	end
	self.Revision = math.max(0, math.floor(tonumber(self.Revision) or 0)) + 1
	self.LastSavedAt = os.time()
	local payload = util.TableToJSON(self:Payload(), false)
	if payload then
		file.Write(dataPath(), payload)
		local verified = util.JSONToTable(file.Read(dataPath(), "DATA") or "")
		if istable(verified) and tonumber(verified.revision) == self.Revision and istable(verified.definitions) then
			file.Write(backupDataPath(), payload)
			self.Dirty = false
			if DRP.Storage and DRP.Storage.SaveWorldState then
				DRP.Storage.SaveWorldState(worldStateKey(), payload, function(success, reason)
					if not success and reason then ErrorNoHalt("[DRP] property database backup failed: " .. tostring(reason) .. "\n") end
				end)
			end
		else
			ErrorNoHalt("[DRP] property save verification failed for data/" .. dataPath() .. "\n")
		end
	end
	DRP.Profile.Finish("properties.flush", started)
end

function Properties:SaveConfiguration()
	self:Save()
	self:Flush()
	return not self.Dirty
end

function Properties:Load()
	local primaryRaw = file.Read(dataPath(), "DATA") or ""
	local backupRaw = file.Read(backupDataPath(), "DATA") or ""
	local primary = util.JSONToTable(primaryRaw)
	local backup = util.JSONToTable(backupRaw)
	local primaryGroups = userDefinitionCount(istable(primary) and primary.definitions or {})
	local backupGroups = userDefinitionCount(istable(backup) and backup.definitions or {})
	-- Prefer a populated snapshot over a valid-but-empty one. A failed modular
	-- startup historically wrote an empty primary and then treated it as valid,
	-- preventing recovery from the populated backup forever.
	local useBackup = istable(backup) and (not istable(primary) or backupGroups > primaryGroups)
	local raw = useBackup and backupRaw or primaryRaw
	local decoded = useBackup and backup or primary
	if useBackup then
		file.Write(dataPath(), backupRaw)
		print(string.format("[DRP PROPERTIES] recovered primary from backup groups=%d bytes=%d", backupGroups, #backupRaw))
	end
	if not istable(decoded) then
		ErrorNoHalt("[DRP PROPERTIES] no valid disk snapshot at data/" .. dataPath() .. " or its backup\n")
		self:EnsureWorldDefinition()
		return
	end
	-- Loading is replacement, not merge. This matters for an explicit recovery
	-- after a failed modular startup and for database reconciliation.
	self.Definitions = {}
	self.Leases = {}
	self.PendingCredits = {}
	self.PendingVaultItems = {}
	self.PlayerRaidCooldowns = {}
	self.OwnedProperties = {}
	self.MemberProperties = {}
	self.Revision = math.max(0, math.floor(tonumber(decoded.revision) or 0))
	self.LastSavedAt = math.max(0, math.floor(tonumber(decoded.saved_at) or 0))
	self.NextID = math.Clamp(math.floor(tonumber(decoded.next_id) or 1), 1, 65534)
	for rawID, raw in pairs(decoded.definitions or {}) do
		local id = math.floor(tonumber(rawID) or tonumber(raw.id) or 0)
		if id > 0 and id < 65535 and istable(raw) then
			local doors, seen = {}, {}
			for _, doorID in ipairs(raw.doors or {}) do
				doorID = tostring(doorID)
				if not seen[doorID] then doors[#doors + 1], seen[doorID] = doorID, true end
			end
			self.Definitions[id] = {
				id = id,
				kind = raw.kind == "world" and "world" or nil,
				name = clean(raw.name ~= "" and raw.name or ("Property " .. id), 48),
				doors = doors,
				build_zones = sanitizeBuildZones(raw.build_zones),
				price = math.max(0, math.floor(tonumber(raw.price) or 0)),
				lease_price = math.max(0, math.floor(tonumber(raw.lease_price) or 0)),
				buyable = raw.buyable ~= false
			}
			self.NextID = math.max(self.NextID, id + 1)
		end
	end
	for rawID, raw in pairs(decoded.leases or {}) do
		local id = math.floor(tonumber(rawID) or 0)
		if self.Definitions[id] and istable(raw) and clean(raw.owner_id, 24) ~= "" then
			self.Leases[id] = {
				owner_id = clean(raw.owner_id, 24),
				owner_name = clean(raw.owner_name, 64),
				acquired_unix = math.floor(tonumber(raw.acquired_unix) or os.time()),
				last_owner_seen_unix = math.floor(tonumber(raw.last_owner_seen_unix) or os.time()),
				owner_offline_unix = math.floor(tonumber(raw.owner_offline_unix) or os.time()),
				price_paid = math.max(0, math.floor(tonumber(raw.price_paid) or 0)),
				roles = cloneRoles(raw.roles),
				members = istable(raw.members) and raw.members or {},
				raid_cooldown_unix = math.floor(tonumber(raw.raid_cooldown_unix) or 0),
					-- Preserve a real expiry across restarts. Only legacy leases which
					-- predate scheduled funding receive an initial day.
					lease_paid_until_unix = math.floor(tonumber(raw.lease_paid_until_unix) or (os.time() + self.LeaseInterval)),
				vault = istable(raw.vault) and raw.vault or {}
			}
			while #self.Leases[id].vault > self.VaultCapacity do table.remove(self.Leases[id].vault) end
		end
	end
	self.PendingCredits = istable(decoded.pending_credits) and decoded.pending_credits or {}
	self.PendingVaultItems = istable(decoded.pending_vault_items) and decoded.pending_vault_items or {}
	self.PlayerRaidCooldowns = istable(decoded.player_raid_cooldowns) and decoded.player_raid_cooldowns or {}
	self:EnsureWorldDefinition()
	self:RebuildMembershipIndexes()
	print(string.format("[DRP PROPERTIES] disk loaded map=%s groups=%d leases=%d revision=%d bytes=%d",
		game.GetMap(), userDefinitionCount(self.Definitions), table.Count(self.Leases), self.Revision, #raw))
end

function Properties:LoadDatabase()
	if self.DatabaseLoaded or not DRP.Storage or not DRP.Storage.LoadWorldState then return end
	self.DatabaseLoaded = true
	DRP.Storage.LoadWorldState(worldStateKey(), function(success, raw, reason)
		if not success then
			self.DatabaseLoaded = false
			if reason then ErrorNoHalt("[DRP] property database restore failed: " .. tostring(reason) .. "\n") end
			return
		end
		local decoded = util.JSONToTable(raw or "")
		local validDatabaseSnapshot = istable(decoded) and istable(decoded.definitions)
		local databaseRevision = validDatabaseSnapshot and math.floor(tonumber(decoded.revision) or 0) or 0
		local localUserGroups = userDefinitionCount(self.Definitions)
		local databaseUserGroups = userDefinitionCount(validDatabaseSnapshot and decoded.definitions or {})
		-- An empty database row must never replace a populated and verified disk
		-- snapshot, regardless of revision. Empty world-state rows have existed on
		-- older deployments and revision alone does not make them authoritative.
		local restoreDatabase = validDatabaseSnapshot and databaseUserGroups > 0 and (
			localUserGroups == 0 or databaseRevision > self.Revision
		)
		print(string.format("[DRP PROPERTIES] reconcile disk_groups=%d disk_revision=%d db_groups=%d db_revision=%d restore_db=%s",
			localUserGroups, self.Revision, databaseUserGroups, databaseRevision, tostring(restoreDatabase)))
		if restoreDatabase then
			-- A local snapshot may already have scheduled lease expiry callbacks while
			-- MySQL was connecting. Cancel those before replacing it with the newer
			-- database snapshot so stale callbacks cannot release restored leases.
			for propertyID, lease in pairs(self.Leases) do
				DRP.Deadlines.Cancel(ownerDeadlineKey(propertyID))
				for memberID in pairs(lease.members or {}) do
					DRP.Deadlines.Cancel(memberDeadlineKey(propertyID, memberID))
				end
			end
			self.Definitions, self.Leases, self.PendingCredits, self.PendingVaultItems, self.PlayerRaidCooldowns = {}, {}, {}, {}, {}
			self.OwnedProperties, self.MemberProperties = {}, {}
			file.CreateDir("darkrp/properties")
			file.Write(dataPath(), raw)
			file.Write(backupDataPath(), raw)
			self:Load()
			self:RebuildDoorIndex()
			self:ScheduleAllDeadlines()
			self:RefreshAllDoors()
			self:Flush()
			self:SyncFullAll()
			print(string.format("[DRP] restored %d property groups from MySQL revision %d", table.Count(self.Definitions), self.Revision))
			return
		end
		local localPayload = util.TableToJSON(self:Payload(), false)
		if localPayload then DRP.Storage.SaveWorldState(worldStateKey(), localPayload) end
	end)
end

function Properties:RebuildDoorIndex()
	self.DoorToProperty = {}
	if DRP.Doors and DRP.Doors.RebuildIndex and next(DRP.Doors.ByMapID) == nil then DRP.Doors:RebuildIndex() end
	for id, definition in pairs(self.Definitions) do
		for _, doorID in ipairs(definition.doors) do self.DoorToProperty[tostring(doorID)] = id end
	end
end

function Properties:Start()
	if self.Started then return end
	self.Started = true
	file.CreateDir("darkrp")
	file.CreateDir("darkrp/properties")
	self:Load()
	print(string.format("[DRP PROPERTIES] service start map=%s live_groups=%d live_leases=%d revision=%d",
		game.GetMap(), userDefinitionCount(self.Definitions), table.Count(self.Leases), self.Revision))
	self:RebuildDoorIndex()
	self:ScheduleAllDeadlines()
	hook.Add("DRPStorageReady", "DRP.Properties.DatabaseRestore", function() self:LoadDatabase() end)
	if DRP.Storage and DRP.Storage.IsAvailable() then timer.Simple(0, function() self:LoadDatabase() end) end
	timer.Simple(1, function() self:FinishInitialSync() end)
end

function Properties:Stop()
	if not self.Started then return end
	self.Started = false
	hook.Remove("DRPStorageReady", "DRP.Properties.DatabaseRestore")
	self:Save()
	self:Flush()
end


Persistence.SteamID = steamID
Persistence.OnlinePlayer = onlinePlayer
Persistence.AddPropertyIndex = addPropertyIndex
Persistence.RemovePropertyIndex = removePropertyIndex
Persistence.OwnerDeadlineKey = ownerDeadlineKey
Persistence.MemberDeadlineKey = memberDeadlineKey
Persistence.DefinitionPrice = definitionPrice
Persistence.DefinitionLeaseRate = definitionLeaseRate
Persistence.CloneRoles = cloneRoles
Properties.Persistence = Persistence
Properties.PersistenceModuleLoaded = true
return Persistence
