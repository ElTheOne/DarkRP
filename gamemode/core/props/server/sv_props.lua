local Props = {
	-- Absolute ceiling includes the maximum paid capacity bonus. Global and
	-- complexity budgets remain unchanged.
	MaxPerPlayer = 120,
	BaseMaxPerPlayer = 80,
	MaxPropWeightPerPlayer = 80,
	MaxGlobalProps = 350,
	MaxGlobalPropWeight = 500,
	ComplexWeightThreshold = 8,
	MaxComplexPropsPerPlayer = 4,
	MaxAdminEntitiesPerPlayer = 120,
	BaseMaxAdminEntitiesPerPlayer = 80,
	TrustEntityLimits = {
		{ maximum = 50, limit = 20 },
		{ maximum = 60, limit = 30 },
		{ maximum = 75, limit = 45 },
		{ maximum = 89, limit = 60 },
		{ maximum = 100, limit = 80 }
	},
	OrphanGrace = 120,
	DisconnectCleanupGrace = 30,
	CleanupBatchSize = 8,
	-- Ground weapons are temporary transport/loot objects. One slot per intended
	-- player avoids rejecting ordinary drops while the shorter lifetime prevents
	-- abandoned ARC9 weapons from accumulating expensive Think work.
	DroppedEntityLifetime = 180,
	LimitedEntityCaps = { weapon = 64, drug = 32, crate = 20, production = 40 },
	LimitedEntityCounts = { weapon = 0, drug = 0, crate = 0, production = 0 },
	CleanupQueue = {},
	CleanupHead = 1,
	CleanupTail = 0,
	TotalPropCount = 0,
	TotalPropWeight = 0,
	ByPlayer = setmetatable({}, {__mode = "k"}),
	ByEntity = setmetatable({}, {__mode = "k"}),
	ActiveZonePhysgun = setmetatable({}, {__mode = "k"}),
	ZonePhysgunInterval = 0.1,
	NextZonePhysgunCheck = 0,
	ByOwnerID = {},
	CountByOwnerID = {},
	WeightByOwnerID = {},
	ComplexCountByOwnerID = {},
	PersistentDataPath = "darkrp/player_props_" .. game.GetMap():gsub("[^%w_%-]", "_") .. ".json",
	PersistentRecords = {},
	PersistentEntities = {},
	NextPersistentID = 1,
	PersistenceDirty = false,
	PersistenceSaveScheduled = false,
	RestoringPersistence = false,
	Stopping = false,
	Blacklist = {},
	DataPath = "darkrp/props_blacklist.json",
	PriceDataPath = "darkrp/prop_prices.json",
	CatalogCachePath = "darkrp/prop_catalog_cache.json",
	CatalogCacheVersion = 1,
	PriceOverrides = {},
	AutomaticPrices = {},
	WeightByModel = {},
	Catalog = {},
	CatalogByModel = {},
	CatalogReady = false,
	CatalogGeneration = 0,
	CatalogFingerprint = "",
	CatalogCompressedChunks = {},
	CatalogTransferQueue = {},
	CatalogTransferHead = 1,
	CatalogTransferIndex = setmetatable({}, {__mode = "k"}),
	CatalogChunksPerPump = 1,
	CatalogWaiting = setmetatable({}, {__mode = "k"})
}

-- Keep the authoritative server object available to compatibility callers
-- that predate the service registry (job entities, inventory and addons).
-- This assignment is intentionally available while the module is loading because
-- the catalogue and persistence submodules extend this exact table.  Do not put
-- the table in the service registry until the complete module has validated: a
-- failed include used to leave a convincing but unusable half-service behind.
DRP.Props = Props
-- sh_props.lua owns the canonical model sanitizer.  The server service table
-- is constructed separately, so preserve that shared helper explicitly.
if not isfunction(Props.NormalizeModel) then
	function Props.NormalizeModel(value)
		local model = string.lower(string.Trim(tostring(value or "")))
		model = string.gsub(model, "\\+", "/")
		model = string.gsub(model, "/+", "/")
		if #model < 12 or #model > 260 or string.find(model, "..", 1, true) then return nil end
		if string.sub(model, 1, 7) ~= "models/" or string.sub(model, -4) ~= ".mdl" then return nil end
		return model
	end
end

local spawnMessage = "drp_prop_spawn_v2"
local blacklistRequestMessage = "drp_prop_blacklist_request_v1"
local blacklistSnapshotMessage = "drp_prop_blacklist_snapshot_v1"
local blacklistUpdateMessage = "drp_prop_blacklist_update_v1"
local catalogRequestMessage = "drp_prop_catalog_request_v1"
local catalogBeginMessage = "drp_prop_catalog_begin_v1"
local catalogChunkMessage = "drp_prop_catalog_chunk_v1"
local catalogEndMessage = "drp_prop_catalog_end_v1"
local priceSetMessage = "drp_prop_price_set_v1"
local priceUpdateMessage = "drp_prop_price_update_v1"
local creatorSelectMessage = "drp_prop_creator_select_v1"
local adminSpawnMessage = "drp_admin_spawn_v1"
local prestigeWeaponMessage = "drp_prestige_weapon_spawn_v1"
local utilityWeaponMessage = "drp_utility_weapon_select_v1"

util.AddNetworkString(spawnMessage)
util.AddNetworkString(blacklistRequestMessage)
util.AddNetworkString(blacklistSnapshotMessage)
util.AddNetworkString(blacklistUpdateMessage)
util.AddNetworkString(catalogRequestMessage)
util.AddNetworkString(catalogBeginMessage)
util.AddNetworkString(catalogChunkMessage)
util.AddNetworkString(catalogEndMessage)
util.AddNetworkString(priceSetMessage)
util.AddNetworkString(priceUpdateMessage)
util.AddNetworkString(creatorSelectMessage)
util.AddNetworkString(adminSpawnMessage)
util.AddNetworkString(prestigeWeaponMessage)
util.AddNetworkString(utilityWeaponMessage)

local function notify(ply, text, kind)
	if DRP.Net and DRP.Net.Notify then DRP.Net.Notify(ply, text, kind or 1) end
end


include("sv_catalog.lua")
assert(Props.CatalogModuleLoaded == true,
	"missing core/props/server/sv_catalog.lua; upload the complete modular props folder")

function Props.Count(ply)
	return IsValid(ply) and (Props.CountByOwnerID[ply:SteamID64()] or 0) or 0
end

function Props.TrustEntityLimit(value)
	-- util.IsValid expects an engine object and errors when a deterministic test
	-- or caller supplies a numeric trust score directly.
	local playerValue = isentity(value) and IsValid(value) and value:IsPlayer() and value or nil
	local score = playerValue and tonumber(playerValue.DRPTrustScore) or tonumber(value)
	local supporterBonus = playerValue and DRP.Supporter and DRP.Supporter.EntityBonus(playerValue) or 0
	score = math.Clamp(math.floor(score or 0), 0, 100)
	for _, tier in ipairs(Props.TrustEntityLimits) do
		if score <= tier.maximum then return tier.limit + supporterBonus end
	end
	return 80 + supporterBonus
end

function Props.EffectivePropLimit(ply)
	return Props.BaseMaxPerPlayer + (DRP.Supporter and DRP.Supporter.EntityBonus(ply) or 0)
end

function Props.EffectiveAdminEntityLimit(ply)
	return Props.BaseMaxAdminEntitiesPerPlayer + (DRP.Supporter and DRP.Supporter.EntityBonus(ply) or 0)
end

function Props.OwnedEntityCount(ply)
	if not IsValid(ply) then return 0 end
	local owned = Props.ByOwnerID[ply:SteamID64()]
	if not owned then return 0 end
	local count = 0
	for entity in pairs(owned) do
		if IsValid(entity) then count = count + 1 else owned[entity] = nil end
	end
	return count
end

function Props.CanCreateOwnedEntity(ply, quiet)
	if not IsValid(ply) then return false, 0, 0 end
	local count, limit = Props.OwnedEntityCount(ply), Props.TrustEntityLimit(ply)
	if count < limit then return true, count, limit end
	if not quiet and (ply.DRPTrustEntityLimitNotice or 0) <= CurTime() then
		ply.DRPTrustEntityLimitNotice = CurTime() + 2
		notify(ply, "Trust entity limit reached (" .. count .. "/" .. limit
			.. "). Improve your trust factor or supporter tier to unlock more prop and entity capacity.", 3)
	end
	return false, count, limit
end

DRP.Props.TrustEntityLimit = Props.TrustEntityLimit
DRP.Props.OwnedEntityCount = Props.OwnedEntityCount
DRP.Props.CanCreateOwnedEntity = Props.CanCreateOwnedEntity

local function modelWeight(model)
	local cached = Props.WeightByModel[model]
	if cached then return cached end
	local automatic = Props.AutomaticPrices[model]
	if not automatic then automatic = automaticPrice(model) Props.AutomaticPrices[model] = automatic end
	-- Large hulls and high-detail model files consume the weighted budget more
	-- aggressively. File size is cached and never queried on a per-frame path.
	local bytes = math.max(0, tonumber(file.Size(model, "GAME")) or 0)
	local hullWeight = math.ceil(automatic / 50)
	local detailWeight = math.ceil(bytes / 262144)
	cached = math.Clamp(math.max(hullWeight, detailWeight), 1, 24)
	Props.WeightByModel[model] = cached
	return cached
end

function Props.Usage(ply)
	if not IsValid(ply) then return 0, 0 end
	local id = ply:SteamID64()
	return Props.CountByOwnerID[id] or 0, Props.WeightByOwnerID[id] or 0
end

local function playerOwner(value)
	return IsValid(value) and value:IsPlayer() and value or nil
end

-- Native Sandbox construction entities use GetPlayer for their creator.
local externalOwnerMethods = { "Getowning_ent", "GetCreator", "GetOwner", "GetPlayer" }

local function resolvedExternalOwner(ent)
	-- Job addons do not all use the same ownership API. Resolve their
	-- server-authored owner fields only when our O(1) ownership index misses;
	-- this path runs on interactions, never as a polling scan.
	local success, owner
	if isfunction(ent.CPPIGetOwner) then
		success, owner = pcall(ent.CPPIGetOwner, ent)
		owner = success and playerOwner(owner) or nil
		if owner then return owner end
	end
	if zwf and zwf.f and isfunction(zwf.f.GetOwner) then
		success, owner = pcall(zwf.f.GetOwner, ent)
		owner = success and playerOwner(owner) or nil
		if owner then return owner end
	end
	if zclib and zclib.Player and isfunction(zclib.Player.GetOwner) then
		success, owner = pcall(zclib.Player.GetOwner, ent)
		owner = success and playerOwner(owner) or nil
		if owner then return owner end
	end
	for _, method in ipairs(externalOwnerMethods) do
		if isfunction(ent[method]) then
			success, owner = pcall(ent[method], ent)
			owner = success and playerOwner(owner) or nil
			if owner then return owner end
		end
	end
	-- A few stock and legacy stools store the creator as a public field after
	-- spawning instead of exposing a getter.
	owner = playerOwner(ent.Player) or playerOwner(ent.pl)
	if owner then return owner end
end

local function normalizeExternalOwnerID(value)
	value = string.Trim(tostring(value or ""))
	if value == "" or value == "nil" or value == "world" or value == "0" then return end
	if string.match(value, "^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then return value end
	if string.match(value, "^STEAM_[0-5]:[01]:%d+$") and util.SteamIDTo64 then
		local converted = tostring(util.SteamIDTo64(value) or "")
		if converted ~= "" and converted ~= "0" then return converted end
	end
end

function Props.Owner(ent)
	if not IsValid(ent) then return nil end
	local owner = playerOwner(Props.ByEntity[ent])
	return owner or resolvedExternalOwner(ent)
end

function Props.OwnerID(ent)
	if not IsValid(ent) then return nil end
	-- DRP-authored identity is authoritative.  In particular, job entities may
	-- expose a vendor GetOwner method which reports world/nil even though the
	-- player that bought the entity is still its valid DRP owner.
	local ownerID = normalizeExternalOwnerID(ent.DRPJobEntityOwnerID)
		or normalizeExternalOwnerID(ent.DRPOwnerSteamID)
		or normalizeExternalOwnerID(ent.DRPTrackedOwnerID)
	if ownerID then return ownerID end
	local owner = Props.Owner(ent)
	if owner then return owner:SteamID64() end
	if zwf and zwf.f and isfunction(zwf.f.GetOwnerID) then
		local success, externalID = pcall(zwf.f.GetOwnerID, ent)
		if success then return normalizeExternalOwnerID(externalID) end
	end
end

function Props.IsOwnedBy(ply, ent)
	return IsValid(ply) and Props.OwnerID(ent) == ply:SteamID64()
end

function Props.IsPortableValuable(ent)
	return IsValid(ent) and ent.DRPPocketDropped == true and ent.DRPPortableValuable == true
end

local function activeToolMode(ply)
	if not IsValid(ply) then return "" end
	local weapon = ply:GetActiveWeapon()
	if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" or not isfunction(weapon.GetMode) then return "" end
	return string.lower(tostring(weapon:GetMode() or ""))
end

local function isPasteToolActive(ply)
	return DRP.ToolPasteModes and DRP.ToolPasteModes[activeToolMode(ply)] == true
end

local function isToolPropSpawnActive(ply)
	return DRP.ToolPropSpawnModes and DRP.ToolPropSpawnModes[activeToolMode(ply)] == true
end

local function propPriceFor(ply, model)
	local free = DRP.Experience and DRP.Experience:CanPayForItem(ply, "prop", model)
	return free == true and 0 or Props.Price(model)
end

local function validatePropSpawn(ply, rawModel)
	local model = DRP.Props.NormalizeModel(rawModel)
	if not IsValid(ply) or not ply:DRPReady() or not ply:Alive() or not model then return nil end
	if not Props.CanCreateOwnedEntity(ply) then return nil end
	if Props.IsBlacklisted(model) then notify(ply, "That prop is blacklisted.", 3) return nil end
	if not util.IsValidModel(model) or not util.IsValidProp(model) then return nil end

	local propCount, propWeight = Props.Usage(ply)
	local requestedWeight = modelWeight(model)
	local complexCount = Props.ComplexCountByOwnerID[ply:SteamID64()] or 0
	local personalPropLimit = Props.EffectivePropLimit(ply)
	if propCount >= personalPropLimit then
		notify(ply, "Prop limit reached (" .. propCount .. "/" .. personalPropLimit .. ").", 3)
		return nil
	end
	if propWeight + requestedWeight > Props.MaxPropWeightPerPlayer then
		notify(ply, "Prop budget reached (" .. propWeight .. "/" .. Props.MaxPropWeightPerPlayer .. " complexity).", 3)
		return nil
	end
	if requestedWeight >= Props.ComplexWeightThreshold and complexCount >= Props.MaxComplexPropsPerPlayer then
		notify(ply, "Complex prop limit reached (" .. complexCount .. "/" .. Props.MaxComplexPropsPerPlayer .. ").", 3)
		return nil
	end
	if Props.TotalPropCount >= Props.MaxGlobalProps or Props.TotalPropWeight + requestedWeight > Props.MaxGlobalPropWeight then
		notify(ply, "The server prop budget is full. Remove unused props before spawning more.", 3)
		return nil
	end
	return model, requestedWeight
end

DRP.Props.Owner = Props.Owner
DRP.Props.OwnerID = Props.OwnerID
DRP.Props.IsOwnedBy = Props.IsOwnedBy
DRP.Props.IsBlacklisted = Props.IsBlacklisted
DRP.Props.Price = Props.Price

-- Normal sandbox spawning remains closed. The duplicator tools receive a
-- narrow prop-only path which preserves blacklist, ownership, economy and
-- weighted-budget enforcement for every entity they paste.
function GM:PlayerSpawnProp(ply, model)
	if not IsValid(ply) then return false end
	if ply.DRPAuthorizedPropSpawn == true then return true end
	if not isToolPropSpawnActive(ply) then return false end
	local normalized, weight = validatePropSpawn(ply, model)
	if not normalized then return false end
	local price = propPriceFor(ply, normalized)
	if price > 0 and ply:DRPMoney() < price then
			notify(ply, "You need $" .. price .. " to spawn that prop.", 3)
		return false
	end
	ply.DRPToolPropApproval = {
		model = normalized,
		weight = weight,
		price = price,
		expires = CurTime() + 2
	}
	return true
end
function GM:PlayerSpawnSENT(ply, class)
	if not IsValid(ply) then return false end
	if string.lower(string.Trim(tostring(class or ""))) == "gmod_tardis" then
		notify(ply, "The TARDIS addon has been removed from this server.", 3)
		return false
	end
	if DRP.EntityAccess and DRP.EntityAccess.IsRestricted(class) then
		local allowed = DRP.EntityAccess.CanSpawn(ply, class)
		if not allowed and (ply.DRPRestrictedEntityNotice or 0) <= CurTime() then
			ply.DRPRestrictedEntityNotice = CurTime() + 2
			notify(ply, "You do not have permission to spawn that entity.", 3)
		end
		return allowed and Props.CanCreateOwnedEntity(ply)
	end
	return ply.DRPAuthorizedEntitySpawn == true and Props.CanCreateOwnedEntity(ply)
end
function GM:PlayerSpawnSWEP(ply, class)
	return IsValid(ply) and ply.DRPAuthorizedWeaponSpawn == true
		and Props.CanCreateOwnedEntity(ply)
		and (not DRP.WeaponAccess or DRP.WeaponAccess.CanUse(ply, class))
end
function GM:PlayerGiveSWEP(ply, class)
	return IsValid(ply) and ply.DRPAuthorizedWeaponSpawn == true
		and (not DRP.WeaponAccess or DRP.WeaponAccess.CanUse(ply, class))
end
function GM:PlayerSpawnNPC() return false end
function GM:PlayerSpawnVehicle() return false end
function GM:PlayerSpawnRagdoll() return false end
function GM:PlayerSpawnEffect() return false end

local function hasPropertyLease(ent)
	if not IsValid(ent) or not ent.DRPPropertyID or not DRP.Properties or not DRP.Properties.Get then return false end
	local _, lease = DRP.Properties.Get(ent.DRPPropertyID)
	return lease ~= nil
end

function Props:EnsureCleanupTimer()
	if timer.Exists("DRP.Props.EntityCleanup") then return end
	timer.Create("DRP.Props.EntityCleanup", 0.25, 0, function()
		if DRP.Props == self then self:ProcessCleanupQueue() else timer.Remove("DRP.Props.EntityCleanup") end
	end)
end

function Props:QueueCleanup(ent, delay, reason)
	if not IsValid(ent) or ent.DRPPersistentWorldID or ent.DRPPersistentPropID then return false end
	if ent.DRPCleanupRecord then
		ent.DRPCleanupRecord.remove_at = math.min(ent.DRPCleanupRecord.remove_at, CurTime() + math.max(0, tonumber(delay) or 0))
		ent.DRPCleanupRecord.owner_id = ent.DRPTrackedOwnerID or ent.DRPCleanupRecord.owner_id
		ent.DRPCleanupRecord.reason = tostring(reason or ent.DRPCleanupRecord.reason)
		return true
	end
	local record = {
		entity = ent,
		owner_id = ent.DRPTrackedOwnerID,
		remove_at = CurTime() + math.max(0, tonumber(delay) or 0),
		reason = tostring(reason or "entity budget"),
		ignore_owner = false,
		ignore_property = false
	}
	ent.DRPCleanupRecord = record
	self.CleanupTail = self.CleanupTail + 1
	self.CleanupQueue[self.CleanupTail] = record
	self:EnsureCleanupTimer()
	return true
end

function Props:ProcessCleanupQueue()
	local started = DRP.Profile and DRP.Profile.Begin and DRP.Profile.Begin() or nil
	local processed, now = 0, CurTime()
	local stopAt = self.CleanupTail
	while processed < self.CleanupBatchSize and self.CleanupHead <= stopAt do
		local record = self.CleanupQueue[self.CleanupHead]
		self.CleanupQueue[self.CleanupHead] = nil
		self.CleanupHead = self.CleanupHead + 1
		processed = processed + 1
		local ent = record and record.entity
		if IsValid(ent) and ent.DRPCleanupRecord == record then
			local owner = record.owner_id and DRP.Players and DRP.Players.Online(record.owner_id) or nil
			if (IsValid(owner) and not record.ignore_owner)
				or (hasPropertyLease(ent) and not record.ignore_property)
				or ent.DRPPersistentWorldID
				or ent.DRPPersistentPropID then
				ent.DRPCleanupRecord = nil
			elseif record.remove_at <= now then
				ent.DRPCleanupRecord = nil
				ent:Remove()
			else
				self.CleanupTail = self.CleanupTail + 1
				self.CleanupQueue[self.CleanupTail] = record
			end
		end
	end
	if self.CleanupHead > 256 and self.CleanupHead > (self.CleanupTail * 0.5) then
		local compact = {}
		for index = self.CleanupHead, self.CleanupTail do
			if self.CleanupQueue[index] then compact[#compact + 1] = self.CleanupQueue[index] end
		end
		self.CleanupQueue, self.CleanupHead, self.CleanupTail = compact, 1, #compact
	elseif self.CleanupHead > self.CleanupTail then
		self.CleanupQueue, self.CleanupHead, self.CleanupTail = {}, 1, 0
		timer.Remove("DRP.Props.EntityCleanup")
	end
	if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("props.cleanup", started) end
end

function Props.ReconcileLimitedEntityCount(kind)
	kind = tostring(kind or "")
	if Props.LimitedEntityCaps[kind] == nil then return 0 end
	local count = 0
	for _, entity in ents.Iterator() do
		if entity.DRPLimitedEntityKind == kind then count = count + 1 end
	end
	Props.LimitedEntityCounts[kind] = count
	return count
end

function Props.CanCreateLimitedEntity(kind)
	kind = tostring(kind or "")
	local cap = Props.LimitedEntityCaps[kind]
	if cap == nil then return false end
	local count = Props.LimitedEntityCounts[kind] or 0
	-- EntityRemoved and WeaponEquip normally release slots. Recount only on the
	-- rejection path so a stale field, addon removal or Lua reload cannot leave
	-- the server permanently claiming that a budget is full.
	if count >= cap then count = Props.ReconcileLimitedEntityCount(kind) end
	return count < cap
end

function Props.UnregisterLimitedEntity(ent)
	if not ent then return false end
	local kind = ent.DRPLimitedEntityKind
	if not kind then return false end
	Props.LimitedEntityCounts[kind] = math.max(0, (Props.LimitedEntityCounts[kind] or 1) - 1)
	ent.DRPLimitedEntityKind = nil
	ent.DRPCleanupRecord = nil
	return true
end

function Props.RegisterLimitedEntity(ent, kind)
	if not IsValid(ent) then return false end
	kind = tostring(kind or "")
	if ent.DRPLimitedEntityKind == kind then return true end
	if not Props.CanCreateLimitedEntity(kind) then return false end
	ent.DRPLimitedEntityKind = kind
	Props.LimitedEntityCounts[kind] = (Props.LimitedEntityCounts[kind] or 0) + 1
	Props:QueueCleanup(ent, Props.DroppedEntityLifetime, "dropped " .. kind .. " lifetime")
	if ent.DRPCleanupRecord then
		ent.DRPCleanupRecord.ignore_owner = true
		ent.DRPCleanupRecord.ignore_property = true
	end
	return true
end

local function removeOwned(ply)
	local owned = Props.ByPlayer[ply]
	if not owned then return end
	for ent in pairs(owned) do
		if IsValid(ent) then
			Props.ByEntity[ent] = nil
			if not hasPropertyLease(ent) then
				Props:QueueCleanup(ent, Props.DisconnectCleanupGrace, "owner disconnected")
			end
		end
	end
	Props.ByPlayer[ply] = nil
end

local function trackOwnedEntity(ply, ent, cleanupType, countsAsProp)
	if not IsValid(ply) or not IsValid(ent) then return end
	local ownerID = ply:SteamID64()
	if not ent.DRPTrackedOwnerID then
		local byID = Props.ByOwnerID[ownerID]
		if not byID then byID = setmetatable({}, { __mode = "k" }) Props.ByOwnerID[ownerID] = byID end
		byID[ent] = true
		ent.DRPTrackedOwnerID = ownerID
		ent.DRPTrackedCountsAsProp = countsAsProp == true
		if ent.DRPTrackedCountsAsProp then
			ent.DRPPropWeight = ent.DRPPropWeight or modelWeight(DRP.Props.NormalizeModel(ent:GetModel()) or "")
			Props.CountByOwnerID[ownerID] = (Props.CountByOwnerID[ownerID] or 0) + 1
			Props.WeightByOwnerID[ownerID] = (Props.WeightByOwnerID[ownerID] or 0) + ent.DRPPropWeight
			if ent.DRPPropWeight >= Props.ComplexWeightThreshold then
				Props.ComplexCountByOwnerID[ownerID] = (Props.ComplexCountByOwnerID[ownerID] or 0) + 1
			end
			Props.TotalPropCount = Props.TotalPropCount + 1
			Props.TotalPropWeight = Props.TotalPropWeight + ent.DRPPropWeight
		end
	end
	local owned = Props.ByPlayer[ply] or {}
	Props.ByPlayer[ply] = owned
	owned[ent] = true
	Props.ByEntity[ent] = ply
	ent.DRPOwnerSteamID = ply:SteamID64()
	ent.DRPCountsAsProp = countsAsProp == true
	if not ent.DRPLimitedEntityKind then ent.DRPCleanupRecord = nil end
	ent:SetCreator(ply)
	cleanup.Add(ply, cleanupType or "sents", ent)
	if DRP.Properties and DRP.Properties.AssignEntity then DRP.Properties:AssignEntity(ent, ply, false) end
	if countsAsProp == true and not Props.RestoringPersistence then Props:PersistEntity(ent) end
end

Props.TrackOwnedEntity = trackOwnedEntity
DRP.Props.TrackOwnedEntity = trackOwnedEntity


Props.Internal = Props.Internal or {}
Props.Internal.ModelWeight = modelWeight
Props.Internal.TrackOwnedEntity = trackOwnedEntity
include("sv_persistence.lua")
assert(Props.PersistenceModuleLoaded == true,
	"missing core/props/server/sv_persistence.lua; upload the complete modular props folder")

local function adminEntityCount(ply)
	local count = 0
	for ent in pairs(Props.ByPlayer[ply] or {}) do
		if IsValid(ent) and ent.DRPAdminSpawned then count = count + 1 end
	end
	return count
end

function Props.SpawnPurchased(ply, model, trace)
	local requestedWeight
	model, requestedWeight = validatePropSpawn(ply, model)
	if not model then return false end
	ply.DRPAuthorizedPropSpawn = true
	local spawnAllowed = hook.Run("PlayerSpawnProp", ply, model) ~= false
	ply.DRPAuthorizedPropSpawn = nil
	if not spawnAllowed then return false end

	trace = trace or ply:GetEyeTrace()
	if not trace.Hit or trace.HitSky or trace.HitPos:DistToSqr(ply:EyePos()) > (512 * 512) then return false end
	if DRP.Properties and DRP.Properties.IsBuildLockedAt and DRP.Properties:IsBuildLockedAt(trace.HitPos) then
		notify(ply, "Building is locked inside a declared raid area.", 3)
		return false
	end
	local price = propPriceFor(ply, model)
	if price > 0 and DRP.EconomyDirector then
		price = DRP.EconomyDirector:Quote("prop:" .. string.lower(model), "sell", price)
	end
	if price > 0 and not DRP.Economy.Take(ply, price) then
		notify(ply, "You need $" .. price .. " to spawn that prop.", 3)
		return false
	end
	local ent = ents.Create("prop_physics")
	if not IsValid(ent) then DRP.Economy.Add(ply, price) return false end
	ent:SetModel(model)
	ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
	ent:SetPos(trace.HitPos + trace.HitNormal * math.abs(ent:OBBMins().z))
	ent:Spawn()
	ent:Activate()
	if DRP.Properties and DRP.Properties.ValidateEntityPlacement then
		local validPlacement, propertyID, reason = DRP.Properties:ValidateEntityPlacement(ply, ent)
		if not validPlacement then
			ent:Remove()
			if price > 0 then DRP.Economy.Add(ply, price, "invalid prop placement refund") end
			notify(ply, reason or "The complete prop must remain inside the combined authorised build zones.", 3)
			return false
		end
		ent.DRPPropertyID = propertyID
	end
	ent.DRPPropWeight = requestedWeight
	if DRP.Props.SuppressImpactDamage then DRP.Props.SuppressImpactDamage(ent) end
	trackOwnedEntity(ply, ent, "props", true)
	hook.Run("PlayerSpawnedProp", ply, model, ent)
	if DRP.Audit then
		local purchasedAs = price == 0 and "free_experience" or tostring(price)
		DRP.Audit.Log(ply, "prop_purchased", ent, model .. " ($" .. purchasedAs .. ")")
	end
	return true, ent
end

DRP.Props.SpawnPurchased = Props.SpawnPurchased

DRP.Net.Receive(spawnMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local model = DRP.Props.NormalizeModel(net.ReadString())
	if not IsValid(ply) or not ply:DRPReady() or not model then return end
	if not DRP.Net.Allow(ply, "prop_spawn", 0.18, 4) then return end
	Props.SpawnPurchased(ply, model)
end)

DRP.Net.Receive(creatorSelectMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local model = DRP.Props.NormalizeModel(net.ReadString())
	if not IsValid(ply) or not ply:DRPReady() or not ply:Alive() or not model then return end
	if not DRP.Net.Allow(ply, "prop_creator_select", 0.4, 3) then return end
	if Props.IsBlacklisted(model) or not util.IsValidModel(model) or not util.IsValidProp(model) then
		notify(ply, "That prop cannot be selected.", 3)
		return
	end
	ply.DRPCreatorModel = model
	ply:SetNWString("DRPCreatorModel", model)
	ply:SetNWInt("DRPCreatorPrice", Props.Price(model))
	if not ply:HasWeapon("weapon_drp_creator") then ply:Give("weapon_drp_creator") end
	ply:SelectWeapon("weapon_drp_creator")
	notify(ply, "Tool Gun selected: " .. string.GetFileFromFilename(model) .. ". Left-click to purchase and place it.", 0)
end)

local function adminPlus(ply)
	return IsValid(ply) and DRP.Admin and DRP.AdminRankLevel(DRP.Admin.RankKey(ply)) >= DRP.AdminRankLevel("admin")
end

local function adminSpawnTrace(ply, offset)
	local trace = ply:GetEyeTrace()
	if not trace.Hit or trace.HitSky or trace.HitPos:DistToSqr(ply:EyePos()) > (512 * 512) then return end
	return trace, trace.HitPos + trace.HitNormal * (offset or 16)
end

local function spawnableEntityDefinition(class)
	local definition = list.GetEntry("SpawnableEntities", class)
	if definition then return class, definition end
	-- Preserve mixed-case registration keys while network input remains normalized.
	for registeredClass, candidate in pairs(list.Get("SpawnableEntities") or {}) do
		if string.lower(tostring(registeredClass)) == class then return registeredClass, candidate end
	end
	return class, nil
end

local function spawnAdminEntity(ply, class)
	if not Props.CanCreateOwnedEntity(ply) then return end
	if adminEntityCount(ply) >= Props.EffectiveAdminEntityLimit(ply) then notify(ply, "Admin entity limit reached.", 3) return end
	if string.StartWith(class, "zmlab2_") and (not zclib or not zmlab2 or not zmlab2.Tent) then
		notify(ply, "MethLab is unavailable: zcLib or the MethLab runtime failed to initialize. Run drp_zero_status in server console.", 3)
		return
	end
	local registeredClass, definition = spawnableEntityDefinition(class)
	local isTARDIS = definition and string.lower(tostring(definition.ScriptedEntityType or "")) == "tardis"
	if isTARDIS then
		notify(ply, "The TARDIS addon has been removed from this server.", 3)
		return
	end

	local stored = scripted_ents.GetStored(class)
	local sent = stored and stored.t or nil
	local spawnFunction = scripted_ents.GetMember(class, "SpawnFunction")
	if not definition and not (sent and isfunction(spawnFunction) and sent.Spawnable) then return end
	ply.DRPAuthorizedEntitySpawn = true
	local spawnAllowed = hook.Run("PlayerSpawnSENT", ply, class) ~= false
	ply.DRPAuthorizedEntitySpawn = nil
	if not spawnAllowed then return end
	local trace, position = adminSpawnTrace(ply, 16)
	if not trace then return end

	local entity
	if sent and isfunction(spawnFunction) then
		local ok, result = pcall(spawnFunction, sent, ply, trace, class)
		if ok then entity = result end
	else
		local entityClass = tostring(definition.ClassName or class)
		entity = ents.Create(entityClass)
		if IsValid(entity) then
			entity:SetPos(position + trace.HitNormal * math.max(tonumber(definition.NormalOffset) or 0, 0))
			if definition.Model then entity:SetModel(definition.Model) end
			if definition.Material then entity:SetMaterial(definition.Material) end
			for key, value in pairs(definition.KeyValues or {}) do entity:SetKeyValue(key, value) end
			entity:Spawn()
			entity:Activate()
			if definition.DropToFloor then entity:DropToFloor() end
		end
	end
	if not IsValid(entity) then notify(ply, "That entity could not be spawned.", 3) return end
	entity.DRPAdminSpawned = true
	trackOwnedEntity(ply, entity, "sents", false)
	hook.Run("PlayerSpawnedSENT", ply, entity)
	if DRP.Audit then DRP.Audit.Log(ply, "admin_spawn_entity", entity, class) end
end

local function weaponDefinition(class)
	local listed = list.GetEntry("Weapon", class)
	local stored = weapons.GetStored(class)
	local legacy = DRP.WeaponAccess and DRP.WeaponAccess.LegacyOwnerWeapons
		and DRP.WeaponAccess.LegacyOwnerWeapons[class]
	if not stored and not listed and not legacy then return end
	listed = listed or stored or legacy
	local spawnable = listed.Spawnable == true or (stored and stored.Spawnable == true)
		or listed.AdminSpawnable == true or (stored and stored.AdminSpawnable == true)
		or legacy ~= nil
	if not spawnable then return end
	return listed, stored or legacy
end

local function giveAdminWeapon(ply, class)
	local listed = weaponDefinition(class)
	if not listed then notify(ply, "That weapon is not registered as spawnable or admin-spawnable.", 3) return end
	if DRP.WeaponAccess and not DRP.WeaponAccess.CanUse(ply, class) then
		notify(ply, "That Half-Life weapon is reserved for the server Owner.", 3)
		return
	end
	ply.DRPAuthorizedWeaponSpawn = true
	local spawnAllowed = hook.Run("PlayerGiveSWEP", ply, class, listed) ~= false
	ply.DRPAuthorizedWeaponSpawn = nil
	if not spawnAllowed then return end
	ply.DRPAdminGrantedWeapons = ply.DRPAdminGrantedWeapons or {}
	ply.DRPAdminGrantedWeapons[class] = true
	if not ply:HasWeapon(class) then ply:Give(class) end
	if not ply:HasWeapon(class) then
		notify(ply, "That Half-Life weapon is not mounted on this server.", 3)
		return
	end
	if class == "weapon_portalgun" and DRP.WeaponAccess and DRP.WeaponAccess.ArmPortalGun then
		DRP.WeaponAccess.ArmPortalGun(ply, ply:GetWeapon(class))
	end
	ply:SelectWeapon(class)
	if DRP.Audit then DRP.Audit.Log(ply, "admin_give_weapon", nil, class) end
end

local function spawnAdminWeapon(ply, class)
	if not Props.CanCreateOwnedEntity(ply) then return end
	if adminEntityCount(ply) >= Props.EffectiveAdminEntityLimit(ply) then notify(ply, "Admin entity limit reached.", 3) return end
	if not Props.CanCreateLimitedEntity("weapon") then notify(ply, "The server dropped-weapon budget is full.", 3) return end
	local listed, stored = weaponDefinition(class)
	if not listed or not stored then notify(ply, "That weapon is not registered as spawnable or admin-spawnable.", 3) return end
	if DRP.WeaponAccess and not DRP.WeaponAccess.CanUse(ply, class) then
		notify(ply, "That Half-Life weapon is reserved for the server Owner.", 3)
		return
	end
	ply.DRPAuthorizedWeaponSpawn = true
	local spawnAllowed = hook.Run("PlayerSpawnSWEP", ply, class, listed) ~= false
	ply.DRPAuthorizedWeaponSpawn = nil
	if not spawnAllowed then return end
	local _, position = adminSpawnTrace(ply, 32)
	if not position then return end
	local entity = ents.Create(class)
	if not IsValid(entity) then notify(ply, "That weapon cannot be spawned on the ground.", 3) return end
	if class == "weapon_portalgun" then
		entity:SetKeyValue("PortalLinkageGroupID", "1")
		entity:SetKeyValue("CanFirePortal1", "1")
		entity:SetKeyValue("CanFirePortal2", "1")
	end
	entity:SetPos(position)
	entity:Spawn()
	if class == "weapon_portalgun" then
		entity:SetNWInt("FirePortal", 0)
		entity:SetNWInt("UpgradePortal", 1)
	end
	entity.DRPAdminSpawned = true
	trackOwnedEntity(ply, entity, "sents", false)
	if not Props.RegisterLimitedEntity(entity, "weapon") then entity:Remove() notify(ply, "The server dropped-weapon budget is full.", 3) return end
	hook.Run("PlayerSpawnedSWEP", ply, entity)
	if DRP.Audit then DRP.Audit.Log(ply, "admin_spawn_weapon", entity, class) end
end

local function givePrestigeWeapon(ply, class)
	if not DRP.Experience then return end
	local eligible, key = DRP.Experience:IsPrestigeWeapon("weapon:" .. class)
	if not eligible or not DRP.Experience:IsUnlockedKey(ply, key) then
		notify(ply, "That weapon is not permanently unlocked.", 3)
		return
	end
	if not ply:HasWeapon(class) then ply:Give(class) end
	ply:SelectWeapon(class)
	if DRP.Audit then DRP.Audit.Log(ply, "prestige_weapon_spawn", nil, class) end
end

DRP.Net.Receive(adminSpawnMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local action = net.ReadUInt(2)
	local class = string.lower(string.Trim(string.sub(net.ReadString(), 1, 96)))
	if not adminPlus(ply) or not ply:DRPReady() or not ply:Alive() or class == "" then return end
	if not DRP.Net.Allow(ply, "admin_spawn", 0.2, 5) then return end
	if action == 1 then
		spawnAdminEntity(ply, class)
	elseif action == 2 then
		giveAdminWeapon(ply, class)
	elseif action == 3 then
		spawnAdminWeapon(ply, class)
	end
end)

DRP.Net.Receive(prestigeWeaponMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local class = string.lower(string.Trim(string.sub(net.ReadString(), 1, 96)))
	if not ply:DRPReady() or not ply:Alive() or class == "" then return end
	if not DRP.Net.Allow(ply, "prestige_weapon_spawn", 0.5, 3) then return end
	givePrestigeWeapon(ply, class)
end)

DRP.Net.Receive(utilityWeaponMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local class = string.lower(string.Trim(string.sub(net.ReadString(), 1, 32)))
	if not ply:DRPReady() or not ply:Alive() or not DRP.Net.Allow(ply, "utility_weapon_select", 0.25, 4) then return end
	if not DRP.JobService or not DRP.JobService.IsUtilityWeapon(class) then return end
	if not DRP.JobService.GiveUtilityWeapon(ply, class, true) then
		notify(ply, "The " .. class .. " weapon is not registered on this server. Check [DRP JOBS] in the console.", 3)
	end
end)

DRP.Net.Receive(blacklistRequestMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "prop_blacklist_request", 1, 2) then return end
	Props.SendBlacklist(ply)
end)

DRP.Net.Receive(blacklistUpdateMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "prop_blacklist_update", 0.4, 3) then return end
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local model = DRP.Props.NormalizeModel(net.ReadString())
	local blocked = net.ReadBool()
	if not model or not Props.CanManageBlacklist(ply) then
		notify(ply, "You do not have permission to manage props.", 3)
		return
	end
	if blocked and (not util.IsValidModel(model) or not util.IsValidProp(model)) then return end
	if not blocked and not Props.Blacklist[model] then return end

	Props.Blacklist[model] = blocked and true or nil
	Props:SaveBlacklist()
	Props.BroadcastBlacklist()
	if DRP.Audit then DRP.Audit.Log(ply, blocked and "prop_blacklisted" or "prop_whitelisted", model) end
	notify(ply, blocked and "Prop blacklisted." or "Prop whitelisted.", 1)
end)

DRP.Net.Receive(catalogRequestMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local clientFingerprint = string.sub(net.ReadString(), 1, 32)
	if not DRP.Net.Allow(ply, "prop_catalog_request", 2, 2) then return end
	Props:StartCatalogTransfer(ply, clientFingerprint)
end)

local function broadcastPrice(model)
	local price, overridden = Props.Price(model)
	net.Start(priceUpdateMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(model)
	net.WriteUInt(price, 16)
	net.WriteBool(overridden == true)
	net.WriteString(Props.CatalogFingerprint)
	net.Broadcast()
end

DRP.Net.Receive(priceSetMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local model = DRP.Props.NormalizeModel(net.ReadString())
	local requestedPrice = net.ReadUInt(16)
	if not model or not Props.CatalogByModel[model] or not Props.CanManagePrices(ply) then
		notify(ply, "You do not have permission to manage prop prices.", 3)
		return
	end
	if not DRP.Net.Allow(ply, "prop_price_update", 0.4, 4) then return end
	local oldPrice = Props.Price(model)
	Props.PriceOverrides[model] = requestedPrice > 0 and requestedPrice or nil
	Props:SavePrices()
	Props:PrepareCatalogPayload()
	broadcastPrice(model)
	local newPrice = Props.Price(model)
	if DRP.Audit then DRP.Audit.Log(ply, "prop_price_set", model, "$" .. oldPrice .. " -> $" .. newPrice) end
	notify(ply, requestedPrice > 0 and ("Prop price set to $" .. newPrice .. ".") or ("Automatic prop price restored ($" .. newPrice .. ")."), 1)
end)

hook.Add("DRPPlayerReady", "DRP.Props.BlacklistSync", Props.SendBlacklist)

hook.Add("EntityRemoved", "DRP.Props.Untrack", function(ent)
	if not Props.Stopping and not Props.RestoringPersistence and ent.DRPPersistentPropID then
		Props:ForgetPersistentEntity(ent)
	end
	Props.UnregisterLimitedEntity(ent)
	ent.DRPCleanupRecord = nil
	local ply = Props.ByEntity[ent]
	if ply and Props.ByPlayer[ply] then Props.ByPlayer[ply][ent] = nil end
	Props.ByEntity[ent] = nil
	local ownerID = ent.DRPTrackedOwnerID
	if not ownerID then return end
	local byID = Props.ByOwnerID[ownerID]
	if byID then
		byID[ent] = nil
		if next(byID) == nil then Props.ByOwnerID[ownerID] = nil end
	end
	if ent.DRPTrackedCountsAsProp then
		local count = math.max(0, (Props.CountByOwnerID[ownerID] or 1) - 1)
		local weight = math.max(0, (Props.WeightByOwnerID[ownerID] or ent.DRPPropWeight or 1) - (ent.DRPPropWeight or 1))
		Props.CountByOwnerID[ownerID] = count > 0 and count or nil
		Props.WeightByOwnerID[ownerID] = weight > 0 and weight or nil
		if (ent.DRPPropWeight or 0) >= Props.ComplexWeightThreshold then
			local complex = math.max(0, (Props.ComplexCountByOwnerID[ownerID] or 1) - 1)
			Props.ComplexCountByOwnerID[ownerID] = complex > 0 and complex or nil
		end
		Props.TotalPropCount = math.max(0, Props.TotalPropCount - 1)
		Props.TotalPropWeight = math.max(0, Props.TotalPropWeight - (ent.DRPPropWeight or 1))
	end
end)

hook.Add("OnEntityCreated", "DRP.Props.OrphanGrace", function(ent)
	if not IsValid(ent) then return end
	local class = ent:GetClass()
	if class ~= "prop_physics" and class ~= "prop_physics_multiplayer" and class ~= "prop_physics_override" then return end
	timer.Simple(0, function()
		if not IsValid(ent) or ent:MapCreationID() >= 0 or ent.DRPMoneyDrop or ent.DRPBreachDebris then return end
		if ent.DRPPersistentWorldID or ent.DRPPersistentPropID or ent.DRPTrackedOwnerID or hasPropertyLease(ent) then return end
		Props:QueueCleanup(ent, Props.OrphanGrace, "unowned prop")
	end)
end)

-- Remove stale exteriors if the old addon remains mounted until the next clean
-- server restart. Internal addon entities disappear once its collection entries
-- are removed and the server is restarted.
hook.Add("OnEntityCreated", "DRP.Props.RemovedTARDISCreation", function(entity)
	if not IsValid(entity) or string.lower(entity:GetClass()) ~= "gmod_tardis" then return end
	timer.Simple(0, function()
		if not IsValid(entity) then return end
		local creator = entity:GetCreator()
		if IsValid(creator) then notify(creator, "The TARDIS addon has been removed from this server.", 3) end
		if DRP.Audit then
			DRP.Audit.Log(IsValid(creator) and creator or nil, "removed_addon_entity", entity, entity:GetClass())
		end
		entity:Remove()
	end)
end)

local function setPhysgunMotion(entity, moving, remember)
	if not IsValid(entity) then return end
	local states = remember and {} or entity.DRPPhysgunMotionStates
	local count = entity:GetPhysicsObjectCount()
	if count > 0 then
		for index = 0, count - 1 do
			local physics = entity:GetPhysicsObjectNum(index)
			if IsValid(physics) then
				if remember then states[index] = physics:IsMotionEnabled() end
				physics:EnableMotion(moving == true)
				physics:EnableGravity(false)
				if moving then physics:Wake() else physics:Sleep() end
			end
		end
	else
		local physics = entity:GetPhysicsObject()
		if IsValid(physics) then
			if remember then states[0] = physics:IsMotionEnabled() end
			physics:EnableMotion(moving == true)
			physics:EnableGravity(false)
			if moving then physics:Wake() else physics:Sleep() end
		end
	end
	if remember then entity.DRPPhysgunMotionStates = states end
end

local function restorePhysgunMotion(entity)
	local states = IsValid(entity) and entity.DRPPhysgunMotionStates
	if not states then return end
	for index, enabled in pairs(states) do
		local physics = entity:GetPhysicsObjectCount() > 0 and entity:GetPhysicsObjectNum(index) or entity:GetPhysicsObject()
		if IsValid(physics) then physics:EnableMotion(enabled == true) if enabled then physics:Wake() else physics:Sleep() end end
	end
	entity.DRPPhysgunMotionStates = nil
end

local function ownerHasBuildOverride(ply)
	return IsValid(ply)
		and DRP.Admin
		and DRP.Admin.IsOwner(ply)
		and DRP.AdminMode
		and isfunction(DRP.AdminMode.IsActive)
		and DRP.AdminMode.IsActive(ply)
end

local function validatePhysgunPlacement(ply, entity)
	if Props.IsPortableValuable(entity) then return true, nil, "portable valuable" end
	if not DRP.Properties then return true, entity.DRPPropertyID end
	if entity.DRPPropertyID and DRP.Properties.EntityInsideAssignedBuildZones then
		return DRP.Properties:EntityInsideAssignedBuildZones(entity, entity.DRPPropertyID)
	end
	if DRP.Properties.ValidateEntityPlacement then
		return DRP.Properties:ValidateEntityPlacement(ply, entity)
	end
	return true, entity.DRPPropertyID
end

local function zeroEntityVelocity(entity)
	if not IsValid(entity) then return end
	local count = entity:GetPhysicsObjectCount()
	if count > 0 then
		for index = 0, count - 1 do
			local physics = entity:GetPhysicsObjectNum(index)
			if IsValid(physics) then
				physics:SetVelocityInstantaneous(vector_origin)
				physics:AddAngleVelocity(-physics:GetAngleVelocity())
			end
		end
	else
		local physics = entity:GetPhysicsObject()
		if IsValid(physics) then
			physics:SetVelocityInstantaneous(vector_origin)
			physics:AddAngleVelocity(-physics:GetAngleVelocity())
		end
	end
end

local function restoreLastValidBuildTransform(entity)
	if not IsValid(entity) or not entity.DRPLastValidBuildPosition then return false end
	entity:SetPos(entity.DRPLastValidBuildPosition)
	entity:SetAngles(entity.DRPLastValidBuildAngles or angle_zero)
	zeroEntityVelocity(entity)
	return true
end

Props.RestoreLastValidBuildTransform = restoreLastValidBuildTransform

function Props:ValidateActiveZonePhysgun(now)
	if next(self.ActiveZonePhysgun) == nil then self:DisarmZonePhysgunValidation() return 0 end
	now = tonumber(now) or CurTime()
	if self.NextZonePhysgunCheck > now then return 0 end
	self.NextZonePhysgunCheck = now + self.ZonePhysgunInterval
	local profileStarted = DRP.Profile and DRP.Profile.Begin and DRP.Profile.Begin() or nil
	local checked = 0
	for entity, ply in pairs(self.ActiveZonePhysgun) do
		if not IsValid(entity) or not IsValid(ply) or entity.DRPPhysgunZoneEnforced ~= true then
			self.ActiveZonePhysgun[entity] = nil
		elseif Props.IsPortableValuable(entity) or ownerHasBuildOverride(ply) then
			self.ActiveZonePhysgun[entity] = nil
			entity.DRPPhysgunZoneEnforced = nil
		else
			checked = checked + 1
			local validPlacement, propertyID, reason = validatePhysgunPlacement(ply, entity)
			if validPlacement then
				entity.DRPLastValidBuildPosition = entity:GetPos()
				entity.DRPLastValidBuildAngles = entity:GetAngles()
				if propertyID then entity.DRPPropertyID = propertyID end
			else
				if not restoreLastValidBuildTransform(entity) then
					self.ActiveZonePhysgun[entity] = nil
					entity:Remove()
				end
				if (ply.DRPNextZoneCorrectionNotice or 0) <= now then
					ply.DRPNextZoneCorrectionNotice = now + 1
					notify(ply, reason or "The complete prop must remain inside its property build zones.", 3)
				end
			end
		end
	end
	if next(self.ActiveZonePhysgun) == nil then self:DisarmZonePhysgunValidation() end
	if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("props.zone_physgun", profileStarted) end
	return checked
end

function Props:ArmZonePhysgunValidation()
	if isfunction((hook.GetTable().Think or {})["DRP.Props.ActiveZonePhysgun"]) then return end
	hook.Add("Think", "DRP.Props.ActiveZonePhysgun", function() Props:ValidateActiveZonePhysgun(CurTime()) end)
end

function Props:DisarmZonePhysgunValidation()
	hook.Remove("Think", "DRP.Props.ActiveZonePhysgun")
end

hook.Add("PhysgunPickup", "DRP.Props.OwnedPhysgunOnly", function(ply, ent)
	if not IsValid(ply) or not IsValid(ent) then return false end
	if ent.DRPContractLocked then return false end
	local isOwner = DRP.Admin and DRP.Admin.IsOwner(ply)
	local buildOverride = ownerHasBuildOverride(ply)
	if isOwner then
		ent.DRPPhysgunZoneEnforced = not Props.IsPortableValuable(ent) and not buildOverride
			and (ent.DRPPropertyID ~= nil or Props.IsOwnedBy(ply, ent))
		if ent.DRPPhysgunZoneEnforced then
			local validPlacement = validatePhysgunPlacement(ply, ent)
			if validPlacement then
				ent.DRPLastValidBuildPosition = ent:GetPos()
				ent.DRPLastValidBuildAngles = ent:GetAngles()
			end
		end
		if not ent:IsPlayer() then setPhysgunMotion(ent, true, true) end
		if ent.DRPPhysgunZoneEnforced and not ent:IsPlayer() then
			Props.ActiveZonePhysgun[ent] = ply
			Props:ArmZonePhysgunValidation()
		end
		return true
	end
	if ent:IsPlayer() and DRP.AdminMode and DRP.AdminMode.CanPhysgun(ply, ent) then return true end
	if ent.DRPPropertyID and ent.DRPPropertyDefence and DRP.Properties and DRP.Properties.ActiveRaids[ent.DRPPropertyID] then return false end
	local propertyAccess = DRP.Properties and DRP.Properties.CanManageEntity and DRP.Properties.CanManageEntity(ply, ent, "build")
	if not Props.IsOwnedBy(ply, ent) and not propertyAccess then return false end
	ent.DRPPhysgunZoneEnforced = not Props.IsPortableValuable(ent)
	if DRP.Properties then
		local validPlacement = validatePhysgunPlacement(ply, ent)
		if validPlacement then
			ent.DRPLastValidBuildPosition = ent:GetPos()
			ent.DRPLastValidBuildAngles = ent:GetAngles()
		end
	end
	if DRP.Props.SuppressImpactDamage then DRP.Props.SuppressImpactDamage(ent) end
	if not ent:IsPlayer() then setPhysgunMotion(ent, true, true) end
	if ent.DRPPhysgunZoneEnforced and not ent:IsPlayer() then
		Props.ActiveZonePhysgun[ent] = ply
		Props:ArmZonePhysgunValidation()
	end
	return true
end)

hook.Add("CanTool", "DRP.Props.OwnedToolsOnly", function(ply, trace, mode)
	if not IsValid(ply) or not ply:DRPReady() then return false end
	local isOwner = DRP.Admin and DRP.Admin.IsOwner(ply)
	mode = tostring(mode or "")
	if mode == "drp_property_zone" then
		return DRP.Properties and DRP.Properties.CanConfigure(ply) or false
	end
	if not isOwner and mode == "precision" and ply:GetInfoNum("precision_entirecontrap", 0) ~= 0 then
		ply:ConCommand("precision_entirecontrap 0")
		ply:ChatPrint("[Tools] Entire Contraption was disabled because it could affect props you do not own. Try the action again.")
		return false
	end
	local entity = trace and trace.Entity
	if not IsValid(entity) or entity:IsWorld() then return end
	if isOwner and ownerHasBuildOverride(ply) then return end
	local propertyAccess = DRP.Properties and DRP.Properties.CanManageEntity
		and DRP.Properties.CanManageEntity(ply, entity, "build")
	if not isOwner and not Props.IsOwnedBy(ply, entity) and not propertyAccess then return false end
	if not Props.IsPortableValuable(entity) and DRP.Properties then
		local previousPosition, previousAngles = entity:GetPos(), entity:GetAngles()
		timer.Simple(0.05, function()
			if not IsValid(ply) or not IsValid(entity) then return end
			local validPlacement, propertyID, reason = validatePhysgunPlacement(ply, entity)
			if validPlacement then
				if propertyID then
					entity.DRPPropertyID = propertyID
					DRP.Properties:IndexEntity(entity, propertyID)
				end
				if entity.DRPTrackedCountsAsProp then Props:PersistEntity(entity) end
				return
			end
			entity:SetPos(previousPosition)
			entity:SetAngles(previousAngles)
			zeroEntityVelocity(entity)
			if entity.DRPTrackedCountsAsProp then Props:PersistEntity(entity) end
			notify(ply, reason or "Tool action reverted because the prop left its property build zone.", 3)
		end)
	end
end)

hook.Add("PhysgunDrop", "DRP.Props.RefreezeAfterPhysgun", function(ply, ent)
	if not IsValid(ent) or ent:IsPlayer() then return end
	Props.ActiveZonePhysgun[ent] = nil
	if next(Props.ActiveZonePhysgun) == nil then Props:DisarmZonePhysgunValidation() end
	local isOwner = DRP.Admin and DRP.Admin.IsOwner(ply)
	local propertyAccess = DRP.Properties and DRP.Properties.CanManageEntity and DRP.Properties.CanManageEntity(ply, ent, "build")
	local playerOwned = Props.IsOwnedBy(ply, ent)
	if not isOwner and not playerOwned and not propertyAccess then return end
	local enforceZone = ent.DRPPhysgunZoneEnforced == true and not ownerHasBuildOverride(ply)
	timer.Simple(0, function()
		if not IsValid(ent) then return end
		if enforceZone and DRP.Properties then
			local validPlacement, propertyID, reason = validatePhysgunPlacement(ply, ent)
			if not validPlacement then
				if ent.DRPLastValidBuildPosition then
					restoreLastValidBuildTransform(ent)
					notify(ply, reason or "That prop cannot leave its property build zone.", 3)
				else
					ent:Remove()
					notify(ply, "Invalid prop placement removed.", 3)
					return
				end
			elseif propertyID then
				ent.DRPPropertyID = propertyID
				DRP.Properties:IndexEntity(ent, propertyID)
			end
		end
		ent.DRPLastValidBuildPosition = nil
		ent.DRPLastValidBuildAngles = nil
		ent.DRPPhysgunZoneEnforced = nil
		if playerOwned or propertyAccess or ent.DRPJobEntityKey then
			setPhysgunMotion(ent, false, false)
			ent.DRPPhysgunMotionStates = nil
		elseif DRP.Props.Freeze then
			DRP.Props.Freeze(ent)
			if ent.DRPPhysicsFrozen ~= true then restorePhysgunMotion(ent) end
		else
			restorePhysgunMotion(ent)
		end
		if IsValid(ent) and ent.DRPTrackedCountsAsProp then Props:PersistEntity(ent) end
	end)
end)

local function claimSpawnedEntity(ply, entity, cleanupType, countsAsProp)
	if not IsValid(ply) or not IsValid(entity) or Props.OwnerID(entity) then return end
	trackOwnedEntity(ply, entity, cleanupType, countsAsProp == true)
end

hook.Add("PlayerSpawnedProp", "DRP.Props.TrackEverySpawnedProp", function(ply, model, entity)
	local approval = ply.DRPToolPropApproval
	ply.DRPToolPropApproval = nil
	if DRP.Properties and DRP.Properties.ValidateEntityPlacement then
		local validPlacement, propertyID, reason = DRP.Properties:ValidateEntityPlacement(ply, entity)
		if not validPlacement then
			entity:Remove()
			notify(ply, reason or "The complete prop must remain inside the combined authorised build zones.", 3)
			return
		end
		entity.DRPPropertyID = propertyID
	end
	if istable(approval) and approval.expires >= CurTime()
		and approval.model == DRP.Props.NormalizeModel(model)
		and not Props.OwnerID(entity) then
		local price = math.max(0, math.floor(tonumber(approval.price) or 0))
		if price > 0 and not DRP.Economy.Take(ply, price, "Duplicated prop") then
			entity:Remove()
			return
		end
		entity.DRPPropWeight = math.max(1, math.floor(tonumber(approval.weight) or modelWeight(approval.model)))
		if DRP.Props.SuppressImpactDamage then DRP.Props.SuppressImpactDamage(entity) end
		if DRP.Audit then
			local event = isPasteToolActive(ply) and "prop_pasted" or "prop_tool_spawned"
			DRP.Audit.Log(ply, event, entity, approval.model .. " ($" .. price .. ")")
		end
	end
	claimSpawnedEntity(ply, entity, "props", true)
end)

hook.Add("AdvDupe2_CanCreateEntity", "DRP.Props.AdvDupePropsOnly", function(ply, class)
	if not IsValid(ply) then return end
	if tostring(class or "") ~= "prop_physics" then return false, "DarkRP permits prop-only duplications." end
end)

hook.Add("StackerMaxPerPlayer", "DRP.Props.SupporterStackerLimit", function(ply)
	if not IsValid(ply) then return Props.BaseMaxPerPlayer end
	return Props.EffectivePropLimit(ply)
end)

hook.Add("Initialize", "DRP.Props.ConfigureAdvDupe2", function()
	local values = {
		AdvDupe2_Strict = "1",
		AdvDupe2_MaxEntities = tostring(Props.MaxPerPlayer),
		AdvDupe2_MaxConstraints = "100",
		sbox_maxgmod_contr_spawners = "0"
	}
	for name, value in pairs(values) do
		if GetConVar(name) then RunConsoleCommand(name, value) end
	end
end)

hook.Add("PlayerSpawnedSENT", "DRP.Props.TrackEverySpawnedEntity", function(ply, entity)
	claimSpawnedEntity(ply, entity, "sents", false)
end)

hook.Add("PlayerSpawnedSWEP", "DRP.Props.TrackEverySpawnedWeapon", function(ply, entity)
	claimSpawnedEntity(ply, entity, "sents", false)
end)

hook.Add("PlayerDroppedWeapon", "DRP.Props.DroppedWeaponBudget", function(_, weapon)
	timer.Simple(0, function()
		if not IsValid(weapon) or Props.RegisterLimitedEntity(weapon, "weapon") then return end
		weapon:Remove()
	end)
end)

local function restrictedWeaponNotice(ply, class)
	if not IsValid(ply) or (ply.DRPRestrictedWeaponNotice or 0) > CurTime() then return end
	ply.DRPRestrictedWeaponNotice = CurTime() + 2
	local required = DRP.WeaponAccess and DRP.WeaponAccess.RequiredRank(class) or "admin"
	local label = DRP.AdminRankLabel and DRP.AdminRankLabel(required) or tostring(required)
	notify(ply, tostring(class or "That weapon") .. " requires the " .. label .. " rank.", 3)
end

function DRP.WeaponAccess.Enforce(ply)
	if not IsValid(ply) then return end
	for _, weapon in ipairs(ply:GetWeapons()) do
		local class = IsValid(weapon) and weapon:GetClass() or ""
		if class ~= "" and not DRP.WeaponAccess.CanUse(ply, class) then
			ply:StripWeapon(class)
			restrictedWeaponNotice(ply, class)
		end
	end
end

hook.Add("PlayerCanPickupWeapon", "DRP.Props.RestrictedWeaponPickup", function(ply, weapon)
	local class = IsValid(weapon) and weapon:GetClass() or ""
	if class ~= "" and not DRP.WeaponAccess.CanUse(ply, class) then
		restrictedWeaponNotice(ply, class)
		return false
	end
end)

hook.Add("PlayerSwitchWeapon", "DRP.Props.RestrictedWeaponSwitch", function(ply, _, weapon)
	local class = IsValid(weapon) and weapon:GetClass() or ""
	if class ~= "" and not DRP.WeaponAccess.CanUse(ply, class) then
		restrictedWeaponNotice(ply, class)
		timer.Simple(0, function()
			if IsValid(ply) and ply:HasWeapon(class) then ply:StripWeapon(class) end
		end)
		return true
	end
end)

hook.Add("WeaponEquip", "DRP.Props.RestrictedWeaponEquip", function(weapon, ply)
	local class = IsValid(weapon) and weapon:GetClass() or ""
	if class == "" or DRP.WeaponAccess.CanUse(ply, class) then return end
	timer.Simple(0, function()
		if not IsValid(ply) then return end
		if ply:HasWeapon(class) then ply:StripWeapon(class) end
		restrictedWeaponNotice(ply, class)
	end)
end)

hook.Add("WeaponEquip", "DRP.Props.ReleaseDroppedWeaponBudget", function(weapon, ply)
	if IsValid(ply) and ply:IsPlayer() then Props.UnregisterLimitedEntity(weapon) end
end)

hook.Add("PlayerDisconnected", "DRP.Props.Cleanup", removeOwned)

hook.Add("DRPPlayerReady", "DRP.Props.RestorePropertyOwnership", function(ply)
	if DRP.WeaponAccess then DRP.WeaponAccess.Enforce(ply) end
	local owned = Props.ByPlayer[ply] or {}
	Props.ByPlayer[ply] = owned
	for entity in pairs(Props.ByOwnerID[ply:SteamID64()] or {}) do
		if IsValid(entity) then
			if not entity.DRPLimitedEntityKind then entity.DRPCleanupRecord = nil end
			owned[entity] = true
			Props.ByEntity[entity] = ply
		end
	end
end)
hook.Add("PlayerDisconnected", "DRP.Props.CatalogCleanup", function(ply)
	local transfer = Props.CatalogTransferIndex[ply]
	if transfer then transfer.player = nil Props.CatalogTransferIndex[ply] = nil end
	Props.CatalogWaiting[ply] = nil
end)

concommand.Add("drp_prop_persistence_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local message = string.format(
		"[DRP PROPS] persistent=%d live=%d owners=%d cap=%d global=%d/%d file=%dB dirty=%s",
		table.Count(Props.PersistentRecords),
		table.Count(Props.PersistentEntities),
		table.Count(Props.CountByOwnerID),
		Props.MaxPerPlayer,
		Props.TotalPropCount,
		Props.MaxGlobalProps,
		file.Size(Props.PersistentDataPath, "DATA") or 0,
		tostring(Props.PersistenceDirty))
	if IsValid(ply) then ply:ChatPrint(message) else print(message) end
end)

concommand.Add("drp_weapon_access_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local function output(line)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) else print(line) end
	end
	local restricted = {}
	for _, definition in ipairs(weapons.GetList() or {}) do
		local class = string.lower(string.Trim(tostring(definition.ClassName or definition.Class or definition.Folder or "")))
		local required = class ~= "" and DRP.WeaponAccess.RequiredRank(class) or nil
		if required then
			restricted[#restricted + 1] = {
				class = class,
				name = tostring(definition.PrintName or class),
				rank = required
			}
		end
	end
	table.sort(restricted, function(left, right) return left.class < right.class end)
	output(string.format("[DRP WEAPON ACCESS] detected=%d policy=Admin+", #restricted))
	for _, entry in ipairs(restricted) do
		output(string.format("[DRP WEAPON ACCESS] %s (%s) requires %s", entry.class, entry.name, entry.rank))
	end
	if #restricted == 0 then
		output("[DRP WEAPON ACCESS] No mounted Portal Gun SWEP was detected. Confirm Workshop item 1800764828 mounted during startup.")
	end
end)

concommand.Add("drp_entity_access_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local function output(line)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) else print(line) end
	end
	for class, required in SortedPairs(DRP.EntityAccess.MinimumRanks or {}) do
		local registered = scripted_ents.GetStored(class) ~= nil
		output(string.format("[DRP ENTITY ACCESS] %s requires %s registered=%s", class, required, tostring(registered)))
	end
end)

concommand.Add("drp_prop_catalog_rebuild", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsAdmin(ply)) then return end
	Props.CatalogTransferQueue, Props.CatalogTransferHead = {}, 1
	Props.CatalogTransferIndex = setmetatable({}, { __mode = "k" })
	Props.CatalogWaiting = setmetatable({}, { __mode = "k" })
	timer.Remove("DRP.Props.CatalogTransfer")
	Props:StartCatalogScan()
	if IsValid(ply) then notify(ply, "Server prop catalogue rebuild started.", 1)
	else print("[DRP] server prop catalogue rebuild started") end
end)

concommand.Add("drp_prop_catalog_status", function(ply, _, arguments)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsAdmin(ply)) then return end
	local function output(line)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) else print(line) end
	end
	local needle = string.lower(string.Trim(table.concat(arguments or {}, " ")))
	output(string.format("[DRP] prop catalog ready=%s entries=%d directories_remaining=%d", tostring(Props.CatalogReady), #Props.Catalog, #(Props.CatalogDirectories or {})))
	if needle == "" then return end
	local matches = 0
	for _, model in ipairs(Props.Catalog) do
		if string.find(model, needle, 1, true) then
			matches = matches + 1
			if matches <= 100 then output("[DRP] " .. model) end
		end
	end
	output(string.format("[DRP] matches for %q: %d%s", needle, matches, matches > 100 and " (first 100 shown)" or ""))
end)

local requiredPropsAPI = {
	"TrustEntityLimit",
	"OwnedEntityCount",
	"CanCreateOwnedEntity",
	"TrackOwnedEntity",
	"SpawnPurchased"
}

assert(Props.CatalogModuleLoaded == true,
	"props module incomplete: catalogue submodule did not finish loading")
assert(Props.PersistenceModuleLoaded == true,
	"props module incomplete: persistence submodule did not finish loading")
for _, method in ipairs(requiredPropsAPI) do
	assert(isfunction(Props[method]),
		"props module incomplete: missing required method Props." .. method)
end

Props.ModuleBuild = "20260807-atomic-service-1"
DRP.Services.Register("props", Props)
print(string.format("[DRP PROPS] module complete build=%s catalogue=%s persistence=%s",
	Props.ModuleBuild,
	tostring(Props.CatalogModuleLoaded == true),
	tostring(Props.PersistenceModuleLoaded == true)))
