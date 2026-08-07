local Salvage = {
	SchemaVersion = 2,
	InteractionDistance = 160,
	TrashcanLimit = 32,
	DumpsterLimit = 16,
	PersonalExpiry = 30 * 86400,
	State = { schema = 2, revision = 0, next_id = 1, next_item_id = 1, bins = {} },
	ByEntity = setmetatable({}, { __mode = "k" }),
	ByID = {},
	Dirty = false,
	DatabaseDirty = false,
	MapLimits = {},
	DataPath = "darkrp/salvage_" .. game.GetMap():gsub("[^%w_%-]", "_") .. ".json",
	StateKey = "salvage:" .. game.GetMap()
}

DRP.Salvage = Salvage
DRP.Services.Register("salvage", Salvage)

Salvage.Types = {
	trashcan = { class = "drp_salvage_trashcan", personalMin = 1, personalMax = 3, personalCooldown = 600, sharedCooldown = 1800, rareChance = 0.04 },
	dumpster = { class = "drp_salvage_dumpster", personalMin = 3, personalMax = 6, personalCooldown = 1200, sharedCooldown = 2700, rareChance = 0.10 }
}

Salvage.RareWeapons = {
	"arc9_go_glock", "arc9_go_p2000", "arc9_go_usp", "arc9_go_mp5", "arc9_go_nova"
}

Salvage.ARC9AmmoSources = {
	{ class = "arc9_go_glock", label = "ARC9 9mm ammunition", minimum = 12, maximum = 30 },
	{ class = "arc9_go_mp5", label = "ARC9 SMG ammunition", minimum = 18, maximum = 45 },
	{ class = "arc9_go_ak47", label = "ARC9 rifle ammunition", minimum = 12, maximum = 30 },
	{ class = "arc9_go_nova", label = "ARC9 12-gauge shells", minimum = 4, maximum = 12 }
}

local openMessage = "drp_salvage_open_v1"
local actionMessage = "drp_salvage_action_v1"
util.AddNetworkString(openMessage)
util.AddNetworkString(actionMessage)

local function notify(ply, text, kind) if IsValid(ply) then DRP.Net.Notify(ply, text, kind or 0) end end

local function entityType(entity)
	local class = IsValid(entity) and entity:GetClass() or ""
	if class == "drp_salvage_dumpster" then return "dumpster" end
	if class == "drp_salvage_trashcan" then return "trashcan" end
	return nil
end

local function nextItemID(binID)
	local sequence = math.max(1, math.floor(tonumber(Salvage.State.next_item_id) or 1))
	Salvage.State.next_item_id = sequence + 1
	return string.format("s%s_%d", tostring(binID), sequence)
end

local function cleanItem(record, binID)
	record = table.Copy(record or {})
	record.id = string.sub(tostring(record.id or nextItemID(binID)), 1, 64)
	record.label = string.sub(tostring(record.label or record.class or "Salvage"), 1, 64)
	record.amount = math.max(1, math.floor(tonumber(record.amount) or 1))
	record.x, record.y, record.w, record.h, record.rotated = nil, nil, nil, nil, nil
	return record
end

local function validWeapon(class)
	class = string.lower(tostring(class or ""))
	local prefix = DRP.ARC9Integration and DRP.ARC9Integration.WeaponPackClassPrefix or "arc9_go_"
	if class == "" or not string.StartWith(class, prefix) then return false end
	local metadata = weapons.GetStored(class) or (list.Get("Weapon") or {})[class]
	if not istable(metadata) or metadata.AdminOnly == true then return false end
	if DRP.ARC9Integration then
		for _, prefix in ipairs(DRP.ARC9Integration.RestrictedAmmoCrateWeaponPrefixes or {}) do if string.StartWith(class, prefix) then return false end end
	end
	for _, fragment in ipairs({ "grenade", "rpg", "rocket", "c4", "mine", "molotov", "slam", "explosive", "flechette", "snark" }) do
		if string.find(class, fragment, 1, true) then return false end
	end
	return true
end
function Salvage:IsRareWeaponAllowed(class) return validWeapon(class) end

local function arc9AmmoType(class)
	if not validWeapon(class) then return nil end
	local metadata = weapons.GetStored(class) or (list.Get("Weapon") or {})[class] or {}
	local ammo = metadata.Ammo or (istable(metadata.Primary) and metadata.Primary.Ammo)
	ammo = string.Trim(tostring(ammo or ""))
	if ammo == "" or ammo == "none" or game.GetAmmoID(ammo) < 0 then return nil end
	if DRP.ARC9Integration and DRP.ARC9Integration:IsAmmoCrateAmmoRestricted(ammo) then return nil end
	return ammo
end

local function ammoRecord(binID)
	local choices = {}
	for _, source in ipairs(Salvage.ARC9AmmoSources) do
		local ammoType = arc9AmmoType(source.class)
		if ammoType then choices[#choices + 1] = { source = source, ammoType = ammoType } end
	end
	if #choices == 0 then return nil end
	local choice = table.Random(choices)
	return cleanItem({
		kind = "ammo", class = "drp_ammo_stack", ammo_type = choice.ammoType,
		arc9_source = choice.source.class, label = choice.source.label,
		amount = math.random(choice.source.minimum, choice.source.maximum), model = "models/items/boxsrounds.mdl"
	}, binID)
end

local function zeroProductRecord(binID)
	if math.random(1, 2) == 1 and scripted_ents.GetStored("zwf_jar") then
		return cleanItem({ kind = "entity", class = "zwf_jar", label = "GrowOP Weed Jar", model = "models/zerochain/props_weedfarm/zwf_jar.mdl" }, binID)
	end
	if scripted_ents.GetStored("zmlab2_item_meth") then
		return cleanItem({ kind = "entity", class = "zmlab2_item_meth", label = "MethLab Meth Bag", model = "models/zerochain/props_methlab/zmlab2_bag.mdl" }, binID)
	end
	if scripted_ents.GetStored("zwf_jar") then
		return cleanItem({ kind = "entity", class = "zwf_jar", label = "GrowOP Weed Jar", model = "models/zerochain/props_weedfarm/zwf_jar.mdl" }, binID)
	end
end

local function salvageRecordAllowed(record)
	if not istable(record) then return false end
	if record.kind == "weapon" then return validWeapon(record.class) end
	if record.kind == "ammo" then return validWeapon(record.arc9_source) and arc9AmmoType(record.arc9_source) == tostring(record.ammo_type or "") end
	if record.class == "drp_drug" then return false end
	return true
end

function Salvage:IsRecordAllowed(record)
	return salvageRecordAllowed(record)
end

local function purgeDisallowed(records)
	local changed = false
	for index = #(records or {}), 1, -1 do
		if not salvageRecordAllowed(records[index]) then table.remove(records, index) changed = true end
	end
	return changed
end

-- Version 1 bins could contain Sandbox/HL2 weapons and loose Source ammo.
-- Remove those records while decoding, without depending on ARC9 having
-- finished registering every SWEP yet. Full mounted-class validation still
-- occurs when the bin is opened and again when an item is claimed.
local function purgeLegacyHL(records)
	local changed = false
	for index = #(records or {}), 1, -1 do
		local record = records[index]
		local legacyWeapon = istable(record) and record.kind == "weapon" and not string.StartWith(string.lower(tostring(record.class or "")), "arc9_go_")
		local legacyAmmo = istable(record) and record.kind == "ammo" and not string.StartWith(string.lower(tostring(record.arc9_source or "")), "arc9_go_")
		if legacyWeapon or legacyAmmo then
			table.remove(records, index)
			changed = true
		end
	end
	return changed
end

local function boostedRecord(ply, record)
	if not istable(record) then return record end
	local commodity = DRP.Commodities and DRP.Commodities.Key(record) or nil
	if tonumber(record.amount) and record.amount > 0 then
		if commodity and DRP.EconomyDirector then
			record.amount = math.max(1, math.floor(record.amount * DRP.EconomyDirector:LootFactor(commodity) + 0.5))
		end
		record.amount = DRP.Supporter and DRP.Supporter.ApplyRollCount(ply, record.amount) or math.ceil(record.amount)
	end
	if DRP.EconomyDirector then
		if commodity then DRP.EconomyDirector:RecordItem(commodity, record.amount, "world", "mint", "salvage") end
	end
	return record
end

local function commonRecord(binID, ply)
	if DRP.Crafting and DRP.Crafting.GeneratePersonalLoot then
		local generated=DRP.Crafting:GeneratePersonalLoot(ply)
		if generated then return boostedRecord(ply,cleanItem(generated,binID)) end
		local resources = {
			{ "coca_leaf", "Coca Leaves", "models/props_junk/garbage_bag001a.mdl" },
			{ "coca_seed", "Coca Seed", "models/props_lab/jar01a.mdl" },
			{ "petroleum", "Petroleum", "models/props_junk/gascan001a.mdl" }
		}
		local choice=table.Random(resources)
		return boostedRecord(ply, zeroProductRecord(binID) or cleanItem({kind="resource",class="drp_cocaine_item",resource=choice[1],label=choice[2],model=choice[3],amount=1},binID))
	end
	local roll = math.random(1, 100)
	if roll <= 55 then
		return boostedRecord(ply, cleanItem({ kind = "resource", class = "drp_cocaine_item", resource = "salvage_scrap", label = "Salvage Scrap", model = "models/gibs/metal_gib4.mdl", amount = math.random(1, 4) }, binID))
	elseif roll <= 85 then
		return boostedRecord(ply, ammoRecord(binID) or cleanItem({ kind = "resource", class = "drp_cocaine_item", resource = "salvage_scrap", label = "Salvage Scrap", model = "models/gibs/metal_gib4.mdl", amount = math.random(1, 3) }, binID))
	elseif roll <= 95 then
		local resources = {
			{ "coca_leaf", "Coca Leaves", "models/props_junk/garbage_bag001a.mdl" },
			{ "coca_seed", "Coca Seed", "models/props_lab/jar01a.mdl" },
			{ "petroleum", "Petroleum", "models/props_junk/gascan001a.mdl" }
		}
		local choice = table.Random(resources)
		return boostedRecord(ply, cleanItem({ kind = "resource", class = "drp_cocaine_item", resource = choice[1], label = choice[2], model = choice[3], amount = 1 }, binID))
	end
	return boostedRecord(ply, zeroProductRecord(binID) or cleanItem({ kind = "resource", class = "drp_cocaine_item", resource = "salvage_scrap", label = "Salvage Scrap", model = "models/gibs/metal_gib4.mdl", amount = 1 }, binID))
end

local function rareRecord(binID, ply, kind)
	if DRP.Crafting and DRP.Crafting.GenerateRareLoot then
		local generated=DRP.Crafting:GenerateRareLoot(ply,kind)
		if generated then return boostedRecord(ply,cleanItem(generated,binID)) end
	end
	if math.random() <= 0.25 then
		local candidates = {}
		for _, class in ipairs(Salvage.RareWeapons) do if validWeapon(class) then candidates[#candidates + 1] = class end end
		if #candidates > 0 then
			local class = table.Random(candidates)
			local metadata = weapons.GetStored(class) or (list.Get("Weapon") or {})[class] or {}
			return boostedRecord(ply, cleanItem({ kind = "weapon", class = class, model = metadata.WorldModel, hold_type = metadata.HoldType, clip1 = -1, clip2 = -1, label = metadata.PrintName or class }, binID))
		end
	end
	return boostedRecord(ply, cleanItem({ kind = "resource", class = "drp_cocaine_item", resource = "cocaine_product", label = "Valuable Salvage", model = "models/props_lab/box01a.mdl", amount = math.random(1, 2) }, binID))
end

local function binRecord(entity)
	local id = IsValid(entity) and tostring(entity.DRPSalvageID or "") or ""
	return id ~= "" and Salvage.State.bins[id] or nil
end

local function markDirty(bin)
	Salvage.Dirty = true
	Salvage.DatabaseDirty = true
	Salvage.State.revision = math.max(os.time() * 1000, math.floor(tonumber(Salvage.State.revision) or 0) + 1)
	if istable(bin) then bin.revision = math.max(1, math.floor(tonumber(bin.revision) or 0) + 1) end
end

local function canInteract(ply, entity)
	if not IsValid(ply) or not ply:Alive() or not IsValid(entity) or not entityType(entity) then return false end
	if ply:GetPos():DistToSqr(entity:GetPos()) > Salvage.InteractionDistance ^ 2 then return false end
	local trace = util.TraceLine({ start = ply:EyePos(), endpos = entity:WorldSpaceCenter(), mask = MASK_SOLID, filter = ply })
	return not trace.Hit or trace.Entity == entity
end

function Salvage:CanRegisterClass(class, ignore)
	local wantedType = class == "drp_salvage_dumpster" and "dumpster" or (class == "drp_salvage_trashcan" and "trashcan" or nil)
	if not wantedType then return true end
	local count = 0
	for entity in pairs(self.ByEntity) do if IsValid(entity) and entity ~= ignore and entityType(entity) == wantedType then count = count + 1 end end
	local mapLimits = self.MapLimits[game.GetMap()] or {}
	local limit = wantedType == "dumpster" and (mapLimits.dumpsters or self.DumpsterLimit) or (mapLimits.trashcans or self.TrashcanLimit)
	return count < limit, limit
end

function Salvage:RegisterEntity(entity, forcedID)
	local kind = entityType(entity)
	if not kind then return false, "That is not a salvage container." end
	if self.ByEntity[entity] then return true, entity.DRPSalvageID end
	local allowed, limit = self:CanRegisterClass(entity:GetClass(), entity)
	if not allowed then return false, "The map limit of " .. limit .. " " .. kind .. " containers has been reached." end
	local id = tostring(forcedID or entity.DRPSalvageID or "")
	if id == "" then id = tostring(self.State.next_id or 1) self.State.next_id = math.max(tonumber(id) + 1, tonumber(self.State.next_id) or 1) end
	if IsValid(self.ByID[id]) and self.ByID[id] ~= entity then return false, "That salvage identifier is already active." end
	self.State.next_id = math.max(math.floor(tonumber(self.State.next_id) or 1), math.floor(tonumber(id) or 0) + 1)
	entity.DRPSalvageID = id
	self.ByEntity[entity], self.ByID[id] = true, entity
	self.State.bins[id] = self.State.bins[id] or { kind = kind, revision = 0, shared = { items = {}, next_refresh = 0 }, personal = {} }
	self.State.bins[id].kind = kind
	markDirty(self.State.bins[id])
	return true, id
end

function Salvage:RefreshIfDue(ply, entity)
	if not canInteract(ply, entity) then return false end
	local record, definition = binRecord(entity), self.Types[entityType(entity)]
	if not record or not definition then return false end
	local now, steamID = os.time(), ply:SteamID64()
	record.personal = record.personal or {}
	local expiryCutoff, purged = now - self.PersonalExpiry, false
	for ownerID, savedPersonal in pairs(record.personal) do
		if ownerID ~= steamID and math.floor(tonumber(savedPersonal.last_seen) or 0) < expiryCutoff then record.personal[ownerID], purged = nil, true end
	end
	if purged then markDirty(record) end
	local personal = record.personal[steamID]
	if not personal then personal = { items = {}, next_refresh = 0, last_seen = now } record.personal[steamID] = personal end
	personal.items = istable(personal.items) and personal.items or {}
	if purgeDisallowed(personal.items) then markDirty(record) end
	local staleActivity = math.floor(tonumber(personal.last_seen) or 0) < now - 86400
	personal.last_seen = now
	if staleActivity then markDirty(record) end
	if #personal.items == 0 and now >= math.floor(tonumber(personal.next_refresh) or 0) then
		local rolls = math.random(definition.personalMin, definition.personalMax)
		rolls = DRP.Supporter and DRP.Supporter.ApplyRollCount(ply, rolls) or rolls
		for _ = 1, rolls do personal.items[#personal.items + 1] = commonRecord(entity.DRPSalvageID, ply) end
		personal.next_refresh = 0
		markDirty(record)
	end
	record.shared = record.shared or { items = {}, next_refresh = 0 }
	record.shared.items = istable(record.shared.items) and record.shared.items or {}
	if purgeDisallowed(record.shared.items) then markDirty(record) end
	if #record.shared.items == 0 and now >= math.floor(tonumber(record.shared.next_refresh) or 0) then
		local rareChance = definition.rareChance
		if math.random() <= rareChance then
			local rareRolls = DRP.Supporter and DRP.Supporter.ApplyRollCount(ply, 1) or 1
			for _ = 1, rareRolls do record.shared.items[#record.shared.items + 1] = rareRecord(entity.DRPSalvageID, ply, record.kind) end
		end
		record.shared.next_refresh = #record.shared.items == 0 and (now + definition.sharedCooldown) or 0
		markDirty(record)
	end
	return true
end

local function publicItem(record, scope)
	local width, height = DRP.Inventory.Footprint(record)
	return { id = record.id, label = record.label, kind = record.kind, class = record.class, model = record.model or "", key = record.drug or record.resource or record.ammo_type or "", amount = record.amount or 1, w = width, h = height, scope = scope }
end

function Salvage:BuildSnapshot(ply, entity)
	if not canInteract(ply, entity) then return nil end
	local record = binRecord(entity)
	if not record then return nil end
	local personal = record.personal and record.personal[ply:SteamID64()] or { items = {} }
	local output = { entity = entity:EntIndex(), id = entity.DRPSalvageID, kind = entityType(entity), revision = record.revision or 0, personal = {}, shared = {}, hands = DRP.Inventory.BuildSnapshot(ply) }
	for _, item in ipairs(personal.items or {}) do output.personal[#output.personal + 1] = publicItem(item, "personal") end
	for _, item in ipairs((record.shared or {}).items or {}) do output.shared[#output.shared + 1] = publicItem(item, "shared") end
	return output
end

local function sendSnapshot(ply, entity)
	local snapshot = Salvage:BuildSnapshot(ply, entity)
	if not snapshot then return false end
	local compressed = util.Compress(util.TableToJSON(snapshot, false) or "{}") or ""
	if #compressed > 1048575 then return false end
	net.Start(openMessage) net.WriteUInt(DRP.ProtocolVersion, 8) net.WriteUInt(#compressed, 20) net.WriteData(compressed, #compressed) net.Send(ply)
	return true
end

function Salvage:Open(ply, entity)
	if not canInteract(ply, entity) then notify(ply, "Move closer and look directly at the container.", 3) return false end
	if not self.ByEntity[entity] then local ok, reason = self:RegisterEntity(entity) if not ok then notify(ply, reason, 3) return false end end
	self:RefreshIfDue(ply, entity)
	ply.DRPSalvageOpen = entity
	return sendSnapshot(ply, entity)
end

function Salvage:SyncOpen(ply)
	local entity = IsValid(ply) and ply.DRPSalvageOpen or nil
	if not canInteract(ply, entity) then return false end
	return sendSnapshot(ply, entity)
end

local function removeFromPool(pool, itemID)
	for index, item in ipairs(pool or {}) do if item.id == itemID then table.remove(pool, index) return item end end
	return nil
end

function Salvage:TransferToHands(ply, entity, itemID, placement, expectedRevision)
	if not canInteract(ply, entity) or ply.DRPSalvageOpen ~= entity then return false end
	if expectedRevision and tonumber(expectedRevision) ~= tonumber((binRecord(entity) or {}).revision or 0) then notify(ply, "The bin changed. Its contents were refreshed.", 2) sendSnapshot(ply, entity) return false end
	local record, steamID = binRecord(entity), ply:SteamID64()
	if not record then return false end
	local personal = record.personal and record.personal[steamID]
	local source, scope = personal and personal.items or {}, "personal"
	local item = nil
	for _, candidate in ipairs(source) do if candidate.id == itemID then item = candidate break end end
	if not item then source, scope = (record.shared or {}).items or {}, "shared" for _, candidate in ipairs(source) do if candidate.id == itemID then item = candidate break end end end
	if not item then notify(ply, "Another player already claimed that salvage.", 2) sendSnapshot(ply, entity) return false end
	if not salvageRecordAllowed(item) then
		removeFromPool(source, itemID)
		markDirty(record)
		self:SaveLocal()
		notify(ply, "That legacy salvage item was removed because it is no longer permitted.", 2)
		sendSnapshot(ply, entity)
		return false
	end
	if not DRP.Inventory.CanInsertRaw(ply, item) then notify(ply, "Your Hands do not have enough free space.", 3) return false end
	item = removeFromPool(source, itemID)
	if not item then return false end
	local inserted, receipts = DRP.Inventory.InsertRawWithReceipt(ply, item)
	if not inserted then source[#source + 1] = item return false end
	if istable(placement) and receipts[1] then
		if placement.auto == true then
			DRP.Inventory.AutoPlace(ply, receipts[1].id, placement.rotated == true)
		elseif not DRP.Inventory.MoveItem(ply, receipts[1].id, placement.x, placement.y, placement.rotated == true) and placement.rotated == true then
			DRP.Inventory.AutoPlace(ply, receipts[1].id, true)
		end
	end
	ply.DRPSalvageClaims = ply.DRPSalvageClaims or {}
	for _, receipt in ipairs(receipts) do
		ply.DRPSalvageClaims[receipt.id] = ply.DRPSalvageClaims[receipt.id] or {}
		ply.DRPSalvageClaims[receipt.id][#ply.DRPSalvageClaims[receipt.id] + 1] = { bin = entity.DRPSalvageID, scope = scope, amount = receipt.amount, record = cleanItem(item, entity.DRPSalvageID) }
	end
	local definition, now = self.Types[entityType(entity)], os.time()
	if #source == 0 then
		if scope == "personal" then personal.next_refresh = now + definition.personalCooldown else record.shared.next_refresh = now + definition.sharedCooldown end
	end
	markDirty(record) self:SaveLocal()
	if DRP.Audit then DRP.Audit.Log(ply, "salvage_claimed", entity, scope .. " " .. item.label) end
	sendSnapshot(ply, entity)
	return true
end

function Salvage:ReturnToBin(ply, entity, itemID, expectedRevision)
	if not canInteract(ply, entity) or ply.DRPSalvageOpen ~= entity then return false end
	if expectedRevision and tonumber(expectedRevision) ~= tonumber((binRecord(entity) or {}).revision or 0) then notify(ply, "The bin changed. Its contents were refreshed.", 2) sendSnapshot(ply, entity) return false end
	local claims = ply.DRPSalvageClaims and ply.DRPSalvageClaims[itemID]
	local claim, claimIndex
	for index, candidate in ipairs(claims or {}) do if candidate.bin == entity.DRPSalvageID then claim, claimIndex = candidate, index break end end
	if not claim then notify(ply, "Only items taken from this container can be returned.", 3) return false end
	local item = DRP.Inventory.TakeAmountByID(ply, itemID, claim.amount)
	if not item then return false end
	local record, steamID = binRecord(entity), ply:SteamID64()
	local pool = claim.scope == "shared" and record.shared.items or record.personal[steamID].items
	local returned = cleanItem(claim.record or item, entity.DRPSalvageID) returned.amount = item.amount or claim.amount returned.id = nextItemID(entity.DRPSalvageID)
	if not salvageRecordAllowed(returned) then
		DRP.Inventory.InsertRaw(ply, item)
		notify(ply, "That item is not permitted in salvage containers.", 3)
		return false
	end
	pool[#pool + 1] = returned
	if claim.scope == "shared" then record.shared.next_refresh = 0 else record.personal[steamID].next_refresh = 0 end
	table.remove(claims, claimIndex)
	if #claims == 0 then ply.DRPSalvageClaims[itemID] = nil end
	markDirty(record) self:SaveLocal() sendSnapshot(ply, entity)
	return true
end

function Salvage:SaveLocal()
	if not self.Dirty then return false end
	file.CreateDir("darkrp")
	local payload = util.TableToJSON(self.State, false)
	if not payload then return false end
	local previous = file.Read(self.DataPath, "DATA")
	if previous and previous ~= "" then file.Write(self.DataPath .. ".bak", previous) end
	file.Write(self.DataPath, payload)
	self.Dirty = false
	return payload
end

function Salvage:Save(database)
	local payload = self:SaveLocal() or file.Read(self.DataPath, "DATA")
	if database and self.DatabaseDirty and payload and DRP.Storage and DRP.Storage.Available then
		DRP.Storage.SaveWorldState(self.StateKey, payload, function(success) if success then self.DatabaseDirty = false end end)
	end
	return payload ~= nil
end

function Salvage:Status()
	return { containers = table.Count(self.ByID), records = table.Count(self.State.bins or {}), dirty = self.Dirty == true, database_dirty = self.DatabaseDirty == true, revision = self.State.revision or 0 }
end

local function decodeState(payload)
	local decoded = isstring(payload) and util.JSONToTable(payload) or nil
	if not istable(decoded) or not istable(decoded.bins) then return nil end
	local migrated = math.floor(tonumber(decoded.schema) or 1) < Salvage.SchemaVersion
	decoded.schema = Salvage.SchemaVersion
	decoded.next_id = math.max(1, math.floor(tonumber(decoded.next_id) or 1))
	decoded.next_item_id = math.max(1, math.floor(tonumber(decoded.next_item_id) or 1))
	decoded.revision = math.max(0, math.floor(tonumber(decoded.revision) or 0))
	local cutoff = os.time() - Salvage.PersonalExpiry
	for _, record in pairs(decoded.bins) do
		record.revision = math.max(0, math.floor(tonumber(record.revision) or 0))
		record.shared = istable(record.shared) and record.shared or { items = {}, next_refresh = 0 }
		record.shared.items = istable(record.shared.items) and record.shared.items or {}
		if purgeLegacyHL(record.shared.items) then migrated = true end
		record.personal = istable(record.personal) and record.personal or {}
		for steamID, personal in pairs(record.personal) do
			if math.floor(tonumber(personal.last_seen) or 0) < cutoff then
				record.personal[steamID] = nil
				migrated = true
			else
				personal.items = istable(personal.items) and personal.items or {}
				if purgeLegacyHL(personal.items) then migrated = true end
			end
		end
	end
	return decoded, migrated
end

function Salvage:Start()
	local localPayload = file.Read(self.DataPath, "DATA") or file.Read(self.DataPath .. ".bak", "DATA")
	local localState, localMigrated = decodeState(localPayload)
	if localState then
		self.State = localState
		if localMigrated then self.Dirty, self.DatabaseDirty = true, true self:SaveLocal() end
	end
	if DRP.Storage then
		DRP.Storage.LoadWorldState(self.StateKey, function(success, payload)
			local databaseState, databaseMigrated
			if success then databaseState, databaseMigrated = decodeState(payload) end
			if databaseState and databaseState.revision > (self.State.revision or 0) then
				self.State = databaseState
				self.Dirty = true
				if databaseMigrated then self.DatabaseDirty = true end
				self:SaveLocal()
			elseif localState and success then DRP.Storage.SaveWorldState(self.StateKey, util.TableToJSON(self.State, false)) end
		end)
	end
end

function Salvage:Stop() self:Save(true) end

local function readAction()
	local length = net.ReadUInt(16)
	if length <= 0 or length > 32768 then return {} end
	local json = util.Decompress(net.ReadData(length))
	local decoded = json and util.JSONToTable(json) or nil
	return istable(decoded) and decoded or {}
end

DRP.Net.Receive(actionMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "salvage_action", 0.08, 12) then return end
	local data, entity = readAction(), Entity(net.ReadUInt(16))
	if not IsValid(entity) then return end
	if data.action == "take" then Salvage:TransferToHands(ply, entity, tostring(data.id or ""), data.placement, data.revision)
	elseif data.action == "return" then Salvage:ReturnToBin(ply, entity, tostring(data.id or ""), data.revision)
	elseif data.action == "refresh" then Salvage:Open(ply, entity) end
end)

hook.Add("EntityRemoved", "DRP.Salvage.EntityRemoved", function(entity)
	if not Salvage.ByEntity[entity] then return end
	Salvage.ByEntity[entity] = nil
	if entity.DRPSalvageID then Salvage.ByID[entity.DRPSalvageID] = nil end
end)

hook.Add("PlayerDisconnected", "DRP.Salvage.Save", function(ply)
	ply.DRPSalvageOpen, ply.DRPSalvageClaims = nil, nil
	Salvage:Save(true)
end)
