local Inventory = {
	SchemaVersion = 3,
	GridWidth = 6,
	GridHeight = 10,
	MaxItems = 60, -- Legacy compatibility: capacity is now determined by cells.
	MaxRecords = 128,
	MaxPayloadBytes = 2097152,
	StackLimit = 99,
	AmmoStackLimit = 2147483647, -- One practical stack per engine/ARC9 ammunition type.
	WeaponFootprintOverrides = {}
}

DRP.Inventory = Inventory
DRP.Services.Register("inventory", Inventory)
DRP.Services.DependsOn("inventory", { "storage", "network" })

local inventoryMessage = "drp_inventory_v1"
local inventoryActionMessage = "drp_inventory_action_v1"
local pocketDataDirectory = "darkrp/pockets"
local nonPocketableProduction = {
	drp_coca_wild = true, drp_coca_pot = true, drp_cocaine_bucket = true,
	drp_cocaine_petroleum = true, drp_cocaine_hotplate = true,
	drp_narcotics_table = true, drp_cocaine_buyer = true,
	drp_crafting_table = true
}

local portableValuableClasses = {
	drp_drug = true, drp_cocaine_item = true, drp_weapon_crate = true,
	drp_tip_jar = true, zwf_weedblock = true, zwf_weedstick = true,
	zwf_jar = true, zwf_joint_ent = true, zwf_edibles = true,
	zwf_palette = true, zwf_seed = true, zwf_bong_ent = true,
	zwf_fuel = true, zwf_nutrition = true, zwf_soil = true,
	zwf_mixer_bowl = true, zmlab2_item_meth = true,
	zmlab2_item_crate = true, zmlab2_item_palette = true,
	zmlab2_equipment = true, drp_crafting_item = true
}
Inventory.PortableValuableClasses = portableValuableClasses

util.AddNetworkString(inventoryMessage)
util.AddNetworkString(inventoryActionMessage)

local function notify(ply, text, kind)
	if IsValid(ply) and DRP.Net then DRP.Net.Notify(ply, text, kind or 0) end
end

local function items(ply)
	ply.DRPPocketItems = ply.DRPPocketItems or {}
	return ply.DRPPocketItems
end

local function recovery(ply)
	ply.DRPHandsRecovery = ply.DRPHandsRecovery or {}
	return ply.DRPHandsRecovery
end

local equipmentSlotNames = {
	primary = true,
	secondary = true,
	alt1 = true,
	alt2 = true,
	alt3 = true,
	alt4 = true,
	alt5 = true,
	alt6 = true
}

local function equipment(ply)
	ply.DRPHandsEquipment = ply.DRPHandsEquipment or {}
	return ply.DRPHandsEquipment
end

local vipEquipmentSlots = { alt4 = true, alt5 = true, alt6 = true }
Inventory.EquipmentSlots = table.Copy(equipmentSlotNames)
Inventory.VIPEquipmentSlots = table.Copy(vipEquipmentSlots)

function Inventory.CanUseEquipmentSlot(ply, slot)
	slot = string.lower(tostring(slot or ""))
	if not IsValid(ply) or not equipmentSlotNames[slot] then return false end
	if not vipEquipmentSlots[slot] then return true end
	return DRP.Admin and DRP.Admin.HasVIP and DRP.Admin.HasVIP(ply) or false
end

function Inventory.EnforceEquipmentAccess(ply, synchronize)
	if not IsValid(ply) then return false end
	local changed = false
	for slot in pairs(equipment(ply)) do
		if not Inventory.CanUseEquipmentSlot(ply, slot) then equipment(ply)[slot], changed = nil, true end
	end
	if changed then
		Inventory.QueueSave(ply)
		if synchronize ~= false then Inventory.Sync(ply, false) end
	end
	return changed
end

local function copyRecord(record)
	local copied = table.Copy(record)
	copied.x, copied.y, copied.w, copied.h, copied.rotated = nil, nil, nil, nil, nil
	return copied
end

local function nextItemID(ply)
	ply.DRPHandsNextID = math.max(0, math.floor(tonumber(ply.DRPHandsNextID) or 0)) + 1
	return string.format("h%s_%d_%d", tostring(IsValid(ply) and ply:SteamID64() or "0"), os.time(), ply.DRPHandsNextID)
end

local function validID(value)
	value = string.sub(tostring(value or ""), 1, 64)
	return value ~= "" and value or nil
end

local function stackLimit(record)
	return record.kind == "ammo" and Inventory.AmmoStackLimit or Inventory.StackLimit
end

local function stackKey(record)
	if record.kind == "resource" then return "resource:" .. tostring(record.resource or "") end
	if record.kind == "drug" then return "drug:" .. tostring(record.drug or "") end
	if record.kind == "ammo" then return "ammo:" .. tostring(record.ammo_type or "") end
	if record.kind == "attachment" then return "attachment:" .. tostring(record.attachment or "") end
	return nil
end

local function weaponMetadata(class)
	local stored = weapons.GetStored(class)
	local listed = (list.Get("Weapon") or {})[class]
	return stored or listed or {}
end

function Inventory.Footprint(record)
	if not istable(record) then return 1, 1 end
	if record.kind == "attachment" or record.kind == "schematic" then return 1, 1 end
	if record.kind == "resource" and DRP.CraftingShared then
		local definition = DRP.CraftingShared.Item(record.resource)
		if definition and definition.w then return definition.w, definition.h or definition.w end
	end
	if record.kind == "ammo" or record.kind == "resource" or record.kind == "drug" then return 1, 1 end
	if record.kind == "weapon" then
		local class = string.lower(tostring(record.class or ""))
		local override = Inventory.WeaponFootprintOverrides[class]
		if istable(override) then return math.Clamp(tonumber(override[1]) or 2, 1, 6), math.Clamp(tonumber(override[2]) or 2, 1, 10) end
		local metadata = weaponMetadata(class)
		local hold = string.lower(tostring(record.hold_type or metadata.HoldType or metadata.Holdtype or ""))
		if hold == "rpg" or hold == "slam" or hold == "physgun" or hold == "camera" then return 6, 3 end
		if hold == "ar2" or hold == "shotgun" or hold == "crossbow" then return 5, 2 end
		if hold == "smg" then return 3, 2 end
		return 2, 2
	end

	local model = tostring(record.model or "")
	if model ~= "" and util.GetModelBounds then
		local mins, maxs = util.GetModelBounds(model)
		if isvector(mins) and isvector(maxs) then
			local size = maxs - mins
			local longest = math.max(math.abs(size.x), math.abs(size.y), math.abs(size.z))
			if longest <= 18 then return 1, 1 end
			if longest <= 42 then return 2, 2 end
			if longest <= 80 then return 3, 3 end
			if longest <= 128 then return 5, 4 end
			return 8, 6
		end
	end
	return 2, 2
end

local function dimensions(record, rotated)
	local width, height = Inventory.Footprint(record)
	if rotated and width ~= height then return height, width end
	return width, height
end

local function occupies(record, x, y)
	local width = math.max(1, math.floor(tonumber(record.w) or 1))
	local height = math.max(1, math.floor(tonumber(record.h) or 1))
	local left = math.floor(tonumber(record.x) or 0)
	local top = math.floor(tonumber(record.y) or 0)
	return x >= left and x < left + width and y >= top and y < top + height
end

function Inventory.CanPlaceRecords(records, record, x, y, rotated, ignoreID)
	x, y = math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0)
	local width, height = dimensions(record, rotated == true)
	if x < 1 or y < 1 or x + width - 1 > Inventory.GridWidth or y + height - 1 > Inventory.GridHeight then return false end
	for _, existing in ipairs(records or {}) do
		if existing ~= record and tostring(existing.id or "") ~= tostring(ignoreID or "") then
			for cellY = y, y + height - 1 do
				for cellX = x, x + width - 1 do
					if occupies(existing, cellX, cellY) then return false end
				end
			end
		end
	end
	return true, width, height
end

function Inventory.CanPlace(ply, record, x, y, rotated)
	if not IsValid(ply) or not istable(record) then return false end
	return Inventory.CanPlaceRecords(items(ply), record, x, y, rotated, record.id)
end

local function findSpace(records, record, preferredRotated)
	for pass = 1, 2 do
		local rotated = pass == 1 and preferredRotated == true or preferredRotated ~= true
		local width, height = dimensions(record, rotated)
		for y = 1, Inventory.GridHeight - height + 1 do
			for x = 1, Inventory.GridWidth - width + 1 do
				if Inventory.CanPlaceRecords(records, record, x, y, rotated, record.id) then return x, y, rotated, width, height end
			end
		end
		if width == height then break end
	end
	return nil
end

local function sanitizeRecord(record, ply, usedIDs)
	if not istable(record) then return nil end
	local kind = tostring(record.kind or "")
	if kind ~= "weapon" and kind ~= "entity" and kind ~= "drug" and kind ~= "resource" and kind ~= "dupe" and kind ~= "ammo" and kind ~= "attachment" and kind ~= "schematic" then return nil end
	if kind == "ammo" then
		record.class = "drp_ammo_stack"
		record.ammo_type = string.sub(tostring(record.ammo_type or record.ammo or ""), 1, 64)
		if record.ammo_type == "" then return nil end
	elseif not isstring(record.class) or #record.class < 1 or #record.class > 128 then
		return nil
	end
	record.label = string.sub(tostring(record.label or record.class), 1, 64)
	record.amount = math.Clamp(math.floor(tonumber(record.amount) or 1), 1, stackLimit(record))
	if kind == "resource" then
		record.resource = string.sub(string.lower(tostring(record.resource or "")), 1, 32)
		if record.resource == "" then return nil end
	elseif kind == "drug" then
		record.drug = string.sub(string.lower(tostring(record.drug or "")), 1, 32)
		if record.drug == "" then return nil end
	elseif kind == "attachment" then
		record.attachment = string.sub(tostring(record.attachment or ""), 1, 128)
		if record.attachment == "" then return nil end
	elseif kind == "schematic" then
		record.schematic = string.sub(tostring(record.schematic or ""), 1, 160)
		record.grade = math.Clamp(math.floor(tonumber(record.grade) or 1), 1, 6)
		if record.schematic == "" then return nil end
	end
	local id = validID(record.id)
	if not id or usedIDs[id] then id = nextItemID(ply) end
	record.id = id
	usedIDs[id] = true
	return record
end

local function layoutRecords(ply, source, keepPlacement)
	local placed, overflow, usedIDs = {}, {}, {}
	for _, original in ipairs(source or {}) do
		local record = sanitizeRecord(table.Copy(original), ply, usedIDs)
		if record then
			local accepted = false
			if keepPlacement and record.x and record.y then
				local rotated = record.rotated == true
				local ok, width, height = Inventory.CanPlaceRecords(placed, record, record.x, record.y, rotated, record.id)
				if ok then
					record.x, record.y, record.w, record.h, record.rotated = math.floor(record.x), math.floor(record.y), width, height, rotated
					placed[#placed + 1] = record
					accepted = true
				end
			end
			if not accepted then
				local x, y, rotated, width, height = findSpace(placed, record, false)
				if x then
					record.x, record.y, record.w, record.h, record.rotated = x, y, width, height, rotated
					placed[#placed + 1] = record
				else
					local clean = copyRecord(record)
					clean.id = record.id
					overflow[#overflow + 1] = clean
				end
			end
		end
	end
	return placed, overflow, usedIDs
end

function Inventory.LayoutRecordsForTest(source, keepPlacement)
	return layoutRecords({}, table.Copy(source or {}), keepPlacement == true)
end

function Inventory.RegisterPortableValuable(class)
	class = string.lower(string.Trim(tostring(class or "")))
	if class == "" or not string.match(class, "^[%w_]+$") then return false end
	portableValuableClasses[class] = true
	return true
end

function Inventory.Items(ply) return IsValid(ply) and items(ply) or {} end
function Inventory.RecoveryItems(ply) return IsValid(ply) and recovery(ply) or {} end
function Inventory.Equipment(ply) return IsValid(ply) and table.Copy(equipment(ply)) or {} end

local function localPath(steamID64) return pocketDataDirectory .. "/" .. tostring(steamID64 or "0") .. ".json" end

local function writeLocalPayload(steamID64, payload)
	file.CreateDir("darkrp")
	file.CreateDir(pocketDataDirectory)
	local path = localPath(steamID64)
	local previous = file.Read(path, "DATA")
	if previous and previous ~= "" then file.Write(path .. ".bak", previous) end
	file.Write(path, payload)
end

local function decodeSnapshot(payload, ply)
	if not isstring(payload) or payload == "" or #payload > Inventory.MaxPayloadBytes then return nil end
	local success, decoded = pcall(util.JSONToTable, payload)
	if not success or not istable(decoded) or not istable(decoded.items) or #decoded.items > Inventory.MaxRecords then return nil end
	local schema = math.floor(tonumber(decoded.schema) or 1)
	local placed, overflow, usedIDs = layoutRecords(ply, decoded.items, schema >= Inventory.SchemaVersion)
	for _, rawRecord in ipairs(decoded.recovery or {}) do
		local record = sanitizeRecord(table.Copy(rawRecord), ply, usedIDs)
		if not record then return nil end
		overflow[#overflow + 1] = copyRecord(record)
		overflow[#overflow].id = record.id
	end
	if #overflow > Inventory.MaxRecords then return nil end
	local selectedID = validID(decoded.selected_id)
	if not selectedID and tonumber(decoded.selected) and placed[tonumber(decoded.selected)] then selectedID = placed[tonumber(decoded.selected)].id end
	local placedIDs, equipped = {}, {}
	for _, record in ipairs(placed) do placedIDs[record.id] = true end
	for slot, itemID in pairs(istable(decoded.equipped) and decoded.equipped or {}) do
		itemID = validID(itemID)
		if Inventory.CanUseEquipmentSlot(ply, slot) and itemID and placedIDs[itemID] then equipped[slot] = itemID end
	end
	return {
		schema = Inventory.SchemaVersion,
		items = placed,
		recovery = overflow,
		selected_id = selectedID,
		equipped = equipped,
		next_id = math.max(math.floor(tonumber(ply.DRPHandsNextID) or 0), math.floor(tonumber(decoded.next_id) or 0)),
		updated_at_ms = math.max(0, math.floor(tonumber(decoded.updated_at_ms) or 0)),
		migrated = schema < Inventory.SchemaVersion or #overflow > #(decoded.recovery or {})
	}
end

local function applySnapshot(ply, snapshot)
	ply.DRPPocketItems = snapshot and snapshot.items or {}
	ply.DRPHandsRecovery = snapshot and snapshot.recovery or {}
	ply.DRPSelectedPocketID = snapshot and snapshot.selected_id or nil
	ply.DRPHandsEquipment = snapshot and snapshot.equipped or {}
	ply.DRPHandsNextID = snapshot and snapshot.next_id or 0
	ply.DRPPocketRevision = snapshot and snapshot.updated_at_ms or 0
	if ply.DRPSelectedPocketID then
		local found = false
		for _, record in ipairs(items(ply)) do if record.id == ply.DRPSelectedPocketID then found = true break end end
		if not found then ply.DRPSelectedPocketID = nil end
	end
	if not ply.DRPSelectedPocketID and items(ply)[1] then ply.DRPSelectedPocketID = items(ply)[1].id end
end

local function encodeSnapshot(ply)
	local now = os.time() * 1000 + math.floor((RealTime() % 1) * 1000)
	local revision = math.max(now, math.floor(tonumber(ply.DRPPocketRevision) or 0) + 1)
	local success, payload = pcall(util.TableToJSON, {
		schema = Inventory.SchemaVersion,
		grid = { width = Inventory.GridWidth, height = Inventory.GridHeight },
		items = items(ply), recovery = recovery(ply), selected_id = ply.DRPSelectedPocketID or "", equipped = equipment(ply),
		next_id = ply.DRPHandsNextID or 0, updated_at_ms = revision
	}, false)
	if not success or not isstring(payload) or payload == "" or #payload > Inventory.MaxPayloadBytes then return nil end
	ply.DRPPocketRevision = revision
	return payload
end

function Inventory.SaveLocal(ply)
	if not IsValid(ply) or ply:IsBot() then return nil end
	local payload = encodeSnapshot(ply)
	if not payload then ErrorNoHalt("[DRP] Failed to serialize Hands for " .. ply:SteamID64() .. "\n") return nil end
	writeLocalPayload(ply:SteamID64(), payload)
	return payload
end

function Inventory.SaveNow(ply)
	if not IsValid(ply) or ply:IsBot() then return false end
	local payload = Inventory.SaveLocal(ply)
	if payload and DRP.Storage and DRP.Storage.Available then DRP.Storage.SavePocket(ply:SteamID64(), payload) end
	ply.DRPPocketDatabaseDirty = false
	return payload ~= nil
end

function Inventory.QueueSave(ply)
	if IsValid(ply) and not ply:IsBot() then ply.DRPPocketDatabaseDirty = true end
end

function Inventory.Load(ply, persistent, callback)
	if not IsValid(ply) then if callback then callback() end return end
	local localPayload = not ply:IsBot() and file.Read(localPath(ply:SteamID64()), "DATA") or nil
	local localSnapshot = decodeSnapshot(localPayload, ply)
	if not localSnapshot and not ply:IsBot() then
		localPayload = file.Read(localPath(ply:SteamID64()) .. ".bak", "DATA")
		localSnapshot = decodeSnapshot(localPayload, ply)
	end
	applySnapshot(ply, localSnapshot)
	if not persistent or ply:IsBot() then
		if ply:Alive() then Inventory.ReconcileWeapons(ply, true) end
		hook.Run("DRPInventoryLoaded", ply)
		if callback then callback() end
		return
	end
	DRP.Storage.LoadPocket(ply:SteamID64(), function(success, databasePayload)
		if not IsValid(ply) then return end
		local databaseSnapshot = success and decodeSnapshot(databasePayload, ply) or nil
		if databaseSnapshot and (not localSnapshot or databaseSnapshot.updated_at_ms > localSnapshot.updated_at_ms) then
			applySnapshot(ply, databaseSnapshot)
			local normalized = encodeSnapshot(ply)
			if normalized then writeLocalPayload(ply:SteamID64(), normalized) end
		elseif localSnapshot and success then
			local normalized = encodeSnapshot(ply)
			if normalized then DRP.Storage.SavePocket(ply:SteamID64(), normalized) end
		elseif success and not databaseSnapshot then
			Inventory.SaveNow(ply)
		end
		if (localSnapshot and localSnapshot.migrated) or (databaseSnapshot and databaseSnapshot.migrated) then notify(ply, "Your inventory was upgraded to Hands. Overflow is protected and will return automatically when space is available.", 1) end
		if ply:Alive() then Inventory.ReconcileWeapons(ply, true) end
		hook.Run("DRPInventoryLoaded", ply)
		if callback then callback() end
	end)
end

local function serialize(entity)
	local class = entity:GetClass()
	if entity:IsWeapon() then
		return Inventory.CreateWeaponRecord(class, entity)
	end
	if class == "drp_weapon_crate" then return { kind = "entity", class = class, model = entity:GetModel(), weapon = entity:GetNW2String("DRPWeapon", "weapon_pistol"), count = entity:GetNW2Int("DRPCount", 1), label = "Weapon Crate" } end
	if class == "drp_tip_jar" then return { kind = "entity", class = class, model = entity:GetModel(), label = "Tip Jar" } end
	if class == "drp_drug" then
		local key = entity:GetNW2String("DRPDrug", "")
		local definition = DRP.Drugs and DRP.Drugs.Definitions[key]
		if not definition then return nil end
		return { kind = "drug", class = class, model = entity:GetModel(), drug = key, amount = math.Clamp(entity:GetNW2Int("DRPItemAmount", 1), 1, 99), label = definition.name }
	end
	if class == "drp_cocaine_item" then
		local key = string.sub(string.lower(entity:GetNW2String("DRPResource", "")), 1, 32)
		if key == "" then return nil end
		return { kind = "resource", class = class, model = entity:GetModel(), resource = key, amount = math.Clamp(entity:GetNW2Int("DRPItemAmount", 1), 1, 99), label = entity:GetNW2String("DRPResourceLabel", key) }
	end
	if class == "drp_ammo_stack" then
		local ammoType = string.sub(entity:GetNW2String("DRPAmmoType", ""), 1, 64)
		if ammoType == "" then return nil end
		return { kind = "ammo", class = class, model = entity:GetModel(), ammo_type = ammoType, amount = math.Clamp(entity:GetNW2Int("DRPItemAmount", 1), 1, Inventory.AmmoStackLimit), label = entity:GetNW2String("DRPAmmoLabel", ammoType .. " ammunition") }
	end
	if class == "drp_crafting_item" then
		local kind=entity:GetNW2String("DRPCraftingKind","")
		if kind=="resource" then
			local key=string.sub(string.lower(entity:GetNW2String("DRPResource","")),1,32)
			if key=="" then return nil end
			return {kind=kind,class=class,model=entity:GetModel(),resource=key,grade=entity:GetNW2Int("DRPCraftingGrade",0)>0 and entity:GetNW2Int("DRPCraftingGrade",1) or nil,amount=math.Clamp(entity:GetNW2Int("DRPItemAmount",1),1,99),label=entity:GetNW2String("DRPCraftingLabel",key)}
		end
		if kind=="attachment" then return {kind=kind,class=class,model=entity:GetModel(),attachment=entity:GetNW2String("DRPAttachment",""),amount=math.Clamp(entity:GetNW2Int("DRPItemAmount",1),1,99),label=entity:GetNW2String("DRPCraftingLabel","Attachment")} end
		if kind=="schematic" then return {kind=kind,class=class,model=entity:GetModel(),schematic=entity:GetNW2String("DRPSchematic",""),grade=entity:GetNW2Int("DRPCraftingGrade",1),label=entity:GetNW2String("DRPCraftingLabel","Schematic")} end
		return nil
	end
	if nonPocketableProduction[class] then return nil end
	if class == "prop_physics" or class == "prop_physics_multiplayer" then
		return { kind = "entity", class = "prop_physics", model = entity:GetModel(), skin = entity:GetSkin(), material = entity:GetMaterial(), color = entity:GetColor(), label = string.GetFileFromFilename(entity:GetModel() or "Prop") }
	end
	if entity:MapCreationID() < 0 and entity:GetMoveType() == MOVETYPE_VPHYSICS and not entity:GetNW2Bool("DRPEvidenceLocker", false) then
		local copied = duplicator.CopyEntTable(entity)
		if copied then return { kind = "dupe", class = class, model = entity:GetModel(), dupe = copied, label = entity.PrintName or class } end
	end
	return nil
end
Inventory.SerializeEntity = serialize

function Inventory.IsPortableValuableRecord(record)
	if not istable(record) then return false end
	if record.kind == "weapon" or record.kind == "drug" or record.kind == "resource" or record.kind == "ammo" or record.kind == "attachment" or record.kind == "schematic" then return true end
	local class = string.lower(tostring(record.class or ""))
	return portableValuableClasses[class] == true or string.StartWith(class, "zmlab2_item_")
end

local function insertPrepared(ply, record, quiet)
	local inventory = items(ply)
	record = copyRecord(record)
	record.id = validID(record.id) or nextItemID(ply)
	for _, existing in ipairs(inventory) do if existing.id == record.id then record.id = nextItemID(ply) break end end
	local x, y, rotated, width, height = findSpace(inventory, record, false)
	if not x then if not quiet then notify(ply, "Your Hands do not have enough free space.", 3) end return false end
	record.x, record.y, record.w, record.h, record.rotated = x, y, width, height, rotated
	inventory[#inventory + 1] = record
	if not ply.DRPSelectedPocketID then ply.DRPSelectedPocketID = record.id end
	return true, record
end

function Inventory.RecoverAvailable(ply, quiet)
	if not IsValid(ply) then return 0 end
	local protected = recovery(ply)
	local recovered, index = 0, 1
	while index <= #protected do
		local record = protected[index]
		local inserted = insertPrepared(ply, record, true)
		if inserted then
			table.remove(protected, index)
			recovered = recovered + 1
		else
			index = index + 1
		end
	end
	if recovered > 0 then
		Inventory.QueueSave(ply)
		if not quiet then notify(ply, recovered .. " protected item" .. (recovered == 1 and " was" or "s were") .. " automatically returned to Hands.", 1) end
	end
	return recovered
end

function Inventory.PocketAimed(ply)
	if not IsValid(ply) or not ply:Alive() then return false end
	local entity = ply:GetEyeTrace().Entity
	if not IsValid(entity) or entity:IsPlayer() or ply:GetPos():DistToSqr(entity:GetPos()) > 14400 then notify(ply, "Aim at a nearby dropped item.", 3) return false end
	if DRP.Doors and DRP.Doors.IsDoor(entity) then return false end
	if entity:GetClass() == "drp_salvage_dumpster" or entity:GetClass() == "drp_salvage_trashcan" then notify(ply, "Salvage containers are fixed infrastructure.", 3) return false end
	if entity:GetClass() == "drp_death_suitcase" then notify(ply, "Open the suitcase to transfer its contents into Hands.", 3) return false end
	if DRP.Medical and DRP.Medical:IsCorpse(entity) then notify(ply, "A player's body cannot be held.", 3) return false end
	if entity:GetNW2Bool("DRPJailer", false) then notify(ply, "The jailer cannot be held.", 3) return false end
	if entity.DRPContractLocked then notify(ply, "That item is reserved by marketplace escrow.", 3) return false end
	local owner = DRP.Props and DRP.Props.Owner(entity)
	if entity:GetClass() ~= "drp_drug" and IsValid(owner) and owner ~= ply then notify(ply, "You cannot take another player's item.", 3) return false end
	local record = serialize(entity)
	if not record then notify(ply, "That item cannot be carried in Hands.", 3) return false end
	if not Inventory.CanInsertRaw(ply, record) then notify(ply, "Your Hands do not have enough free space.", 3) return false end
	local ok, inserted = insertPrepared(ply, record)
	if not ok then return false end
	entity:Remove()
	notify(ply, "Picked up " .. inserted.label .. ".", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "item_pocketed", nil, inserted.class) end
	Inventory.Sync(ply, false)
	Inventory.QueueSave(ply)
	hook.Run("DRPHandsItemAdded", ply, inserted, "world")
	return true
end

local function recordBudgetKind(record)
	return record.kind == "weapon" and "weapon" or (record.class == "drp_drug" and "drug") or (record.class == "drp_cocaine_item" and "drug") or (record.class == "drp_weapon_crate" and "crate")
end

function Inventory.SpawnRecordAt(ply, record, position, normal, quiet, worldLoot)
	if not IsValid(ply) or not istable(record) or not isvector(position) then return nil end
	normal = isvector(normal) and normal or Vector(0, 0, 1)
	local budget, budgetKind = DRP.Services.Get("props"), recordBudgetKind(record)
	if not worldLoot and budget and budget.CanCreateOwnedEntity
		and not budget.CanCreateOwnedEntity(ply, quiet) then return nil end
	if budgetKind and (not budget or not budget.CanCreateLimitedEntity(budgetKind)) then if not quiet then notify(ply, "The server " .. budgetKind .. " entity budget is full.", 3) end return nil end
	local entity = record.kind == "dupe" and duplicator.CreateEntityFromTable(ply, record.dupe) or ents.Create(record.class)
	if not IsValid(entity) then if not quiet then notify(ply, "That item could not be dropped.", 3) end return nil end
	local portable = Inventory.IsPortableValuableRecord(record)
	entity.DRPPocketDropped, entity.DRPPortableValuable = true, portable
	entity.DRPPortableValuableOwnerID = not worldLoot and ply:SteamID64() or nil
	if portable then entity.DRPPropertyID, entity.DRPPropertyStorage, entity.DRPPropertyDefence = nil, false, false end
	if record.kind ~= "dupe" and isstring(record.model) and record.model ~= "" then entity:SetModel(record.model) end
	if record.kind == "ammo" and (not record.model or record.model == "") then entity:SetModel("models/items/boxsrounds.mdl") end
	local mins = entity:OBBMins()
	entity:SetPos(position + normal * math.max(4, 6 - (isvector(mins) and mins.z or -10)))
	if record.kind ~= "dupe" then entity:Spawn() entity:Activate() end
	if record.skin then entity:SetSkin(record.skin) end
	if record.material then entity:SetMaterial(record.material) end
	if record.color then entity:SetColor(record.color) end
	if record.kind == "weapon" then
		if record.clip1 and record.clip1 >= 0 then entity:SetClip1(record.clip1) end
		if record.clip2 and record.clip2 >= 0 then entity:SetClip2(record.clip2) end
	elseif record.class == "drp_weapon_crate" then
		entity:SetNW2String("DRPWeapon", record.weapon or "") entity:SetNW2Int("DRPCount", record.count or 1)
	elseif record.class == "drp_drug" then
		entity:SetNW2String("DRPDrug", record.drug or "") entity:SetNW2Int("DRPItemAmount", record.amount or 1) entity:SetNW2String("DRPJobEntityName", record.label or "Drug Package")
	elseif record.class == "drp_cocaine_item" then
		entity:SetNW2String("DRPResource", record.resource or "") entity:SetNW2Int("DRPItemAmount", record.amount or 1) entity:SetNW2String("DRPResourceLabel", record.label or "Material")
	elseif record.class == "drp_ammo_stack" then
		entity:SetNW2String("DRPAmmoType", record.ammo_type or "") entity:SetNW2Int("DRPItemAmount", record.amount or 1) entity:SetNW2String("DRPAmmoLabel", record.label or "Ammunition")
	elseif record.class == "drp_crafting_item" then
		entity:SetNW2String("DRPCraftingKind", record.kind or "") entity:SetNW2String("DRPResource", record.resource or "") entity:SetNW2String("DRPAttachment", record.attachment or "") entity:SetNW2String("DRPSchematic", record.schematic or "") entity:SetNW2Int("DRPCraftingGrade", record.grade or 1) entity:SetNW2Int("DRPItemAmount", record.amount or 1) entity:SetNW2String("DRPCraftingLabel", record.label or "Crafting Item")
	end
	if worldLoot then
		entity.DRPDeathPocketDrop = true
		if DRP.Props and DRP.Props.MakeWorldEntity then DRP.Props.MakeWorldEntity(entity) end
	elseif budget and budget.TrackOwnedEntity then budget.TrackOwnedEntity(ply, entity, "sents", false) end
	if budgetKind and not budget.RegisterLimitedEntity(entity, budgetKind) then entity:Remove() return nil end
	return entity
end

local function findByID(ply, itemID)
	for index, record in ipairs(items(ply)) do if record.id == itemID then return record, index end end
	return nil
end

local function normalizedWeaponClass(class)
	class = string.lower(string.Trim(tostring(class or "")))
	return class ~= "" and class or nil
end

function Inventory.CreateWeaponRecord(class, weapon)
	class = normalizedWeaponClass(class)
	if not class then return nil end
	local metadata = weaponMetadata(class)
	local model = IsValid(weapon) and weapon:GetModel() or metadata.WorldModel or metadata.WM
	local label = IsValid(weapon) and weapon:GetPrintName() or metadata.PrintName
	local installed = {}
	if IsValid(weapon) and isfunction(weapon.GetSubSlotList) then
		for _, slot in ipairs(weapon:GetSubSlotList() or {}) do if slot.Installed and slot.Address then installed[#installed + 1] = { address = tostring(slot.Address), attachment = tostring(slot.Installed) } end end
	end
	return {
		kind = "weapon",
		class = class,
		model = string.Trim(tostring(model or "")) ~= "" and tostring(model) or nil,
		hold_type = metadata.HoldType or metadata.Holdtype,
		clip1 = IsValid(weapon) and weapon:Clip1() or -1,
		clip2 = IsValid(weapon) and weapon:Clip2() or -1,
		label = string.Trim(tostring(label or "")) ~= "" and tostring(label) or class,
		installed_attachments = installed
	}
end

function Inventory.IsAlwaysAvailableWeapon(ply, class)
	class = normalizedWeaponClass(class)
	if not IsValid(ply) or not class then return false end
	if DRP.JobService and DRP.JobService.CanUseUtilityWeapon and DRP.JobService.CanUseUtilityWeapon(ply, class) then return true end
	local cached = DRP.JobService and DRP.JobService.GetCachedLoadout and DRP.JobService.GetCachedLoadout(ply:DRPJobID())
	if cached and cached.weaponSet and cached.weaponSet[class] then return true end
	if DRP.Experience and DRP.Experience.IsUnlockedKey and DRP.Experience:IsUnlockedKey(ply, "weapon:" .. class) then return true end
	if DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(ply) then return true end
	return istable(ply.DRPAdminGrantedWeapons) and ply.DRPAdminGrantedWeapons[class] == true
end

function Inventory.EquippedWeaponRecord(ply, class)
	class = normalizedWeaponClass(class)
	if not IsValid(ply) or not class then return nil end
	for slot, itemID in pairs(equipment(ply)) do
		if Inventory.CanUseEquipmentSlot(ply, slot) then
			local record = findByID(ply, itemID)
			if record and record.kind == "weapon" and normalizedWeaponClass(record.class) == class then return record, slot end
		end
	end
	return nil
end

function Inventory.CanPossessWeapon(ply, class)
	if DRP.WeaponAccess and DRP.WeaponAccess.CanUse and not DRP.WeaponAccess.CanUse(ply, class) then return false end
	return Inventory.IsAlwaysAvailableWeapon(ply, class) or Inventory.EquippedWeaponRecord(ply, class) ~= nil
end

function Inventory.HasWeaponRecord(ply, class)
	class = normalizedWeaponClass(class)
	if not IsValid(ply) or not class then return false end
	for _, record in ipairs(items(ply)) do
		if record.kind == "weapon" and normalizedWeaponClass(record.class) == class then return true end
	end
	return false
end

function Inventory.CaptureEquippedWeaponStates(ply)
	if not IsValid(ply) then return end
	for _, record in ipairs(items(ply)) do
		if record.kind == "weapon" then
			local class = normalizedWeaponClass(record.class)
			local weapon = class and ply:GetWeapon(class)
			if IsValid(weapon) and Inventory.EquippedWeaponRecord(ply, class) then
				record.clip1, record.clip2 = weapon:Clip1(), weapon:Clip2()
				if isfunction(weapon.GetSubSlotList) then
					record.installed_attachments = {}
					for _, slot in ipairs(weapon:GetSubSlotList() or {}) do if slot.Installed and slot.Address then record.installed_attachments[#record.installed_attachments + 1] = { address = tostring(slot.Address), attachment = tostring(slot.Installed) } end end
				end
			end
		end
	end
end

function Inventory.GrantEquippedWeapons(ply)
	if not IsValid(ply) or not ply:Alive() then return false end
	Inventory.EnforceEquipmentAccess(ply, false)
	for slot, itemID in pairs(equipment(ply)) do
		if Inventory.CanUseEquipmentSlot(ply, slot) then
			local record = findByID(ply, itemID)
			if record and record.kind == "weapon" then
				local class = normalizedWeaponClass(record.class)
				if class and Inventory.CanPossessWeapon(ply, class) and not ply:HasWeapon(class) then
					local weapon = ply:Give(class, true)
					if IsValid(weapon) then
						if tonumber(record.clip1) and record.clip1 >= 0 then weapon:SetClip1(record.clip1) end
						if tonumber(record.clip2) and record.clip2 >= 0 then weapon:SetClip2(record.clip2) end
						if isfunction(weapon.LocateSlotFromAddress) then
							local changed=false
							for _,installed in ipairs(record.installed_attachments or {}) do local slot=weapon:LocateSlotFromAddress(installed.address) if slot then slot.Installed=installed.attachment slot.ToggleNum=1 changed=true end end
							if changed then if isfunction(weapon.PruneAttachments) then weapon:PruneAttachments() end if isfunction(weapon.PostModify) then weapon:PostModify() end end
						end
					end
				end
			end
		end
	end
	return true
end

function Inventory.ReconcileWeapons(ply, grantEquipped)
	if not IsValid(ply) or not ply:Alive() then return false end
	Inventory.EnforceEquipmentAccess(ply, false)
	for _, weapon in ipairs(ply:GetWeapons()) do
		local class = IsValid(weapon) and normalizedWeaponClass(weapon:GetClass())
		if class and not Inventory.CanPossessWeapon(ply, class) then ply:StripWeapon(class) end
	end
	if grantEquipped ~= false then Inventory.GrantEquippedWeapons(ply) end
	return true
end

function Inventory.Selected(ply)
	if not IsValid(ply) then return nil end
	local record, index = findByID(ply, tostring(ply.DRPSelectedPocketID or ""))
	if record then return record, index end
	if items(ply)[1] then ply.DRPSelectedPocketID = items(ply)[1].id return items(ply)[1], 1 end
	return nil
end

function Inventory.SelectByID(ply, itemID)
	local record = findByID(ply, tostring(itemID or ""))
	if not record then return false end
	ply.DRPSelectedPocketID = record.id
	notify(ply, "Selected " .. record.label .. ".", 1)
	Inventory.Sync(ply, false) Inventory.QueueSave(ply)
	return true
end

function Inventory.Select(ply, index)
	local record = items(ply)[math.floor(tonumber(index) or 0)]
	return record and Inventory.SelectByID(ply, record.id) or false
end

function Inventory.AssignEquipment(ply, itemID, slot)
	if not IsValid(ply) then return false end
	slot, itemID = string.lower(tostring(slot or "")), tostring(itemID or "")
	if not equipmentSlotNames[slot] then return false end
	if not Inventory.CanUseEquipmentSlot(ply, slot) then
		notify(ply, "ALT 4, ALT 5 and ALT 6 require VIP entitlement or HeadAdmin+.", 3)
		return false
	end
	local record = findByID(ply, itemID)
	local mainSlot = slot == "primary" or slot == "secondary"
	if not record or (mainSlot and record.kind ~= "weapon") or (not mainSlot and record.kind ~= "weapon" and record.kind ~= "drug") then
		notify(ply, "Only weapons, medical items, grenades and consumables can use equipment slots.", 3)
		return false
	end
	if record.kind == "weapon" and DRP.WeaponAccess and DRP.WeaponAccess.CanUse and not DRP.WeaponAccess.CanUse(ply, record.class) then
		notify(ply, "Your rank cannot equip that weapon.", 3)
		return false
	end
	Inventory.CaptureEquippedWeaponStates(ply)
	for existingSlot, equippedID in pairs(equipment(ply)) do
		local existingRecord = findByID(ply, equippedID)
		local duplicateClass = record.kind == "weapon" and existingRecord and existingRecord.kind == "weapon"
			and normalizedWeaponClass(existingRecord.class) == normalizedWeaponClass(record.class)
		if equippedID == itemID or duplicateClass then equipment(ply)[existingSlot] = nil end
	end
	equipment(ply)[slot] = itemID
	ply.DRPSelectedPocketID = itemID
	Inventory.Sync(ply, false)
	Inventory.QueueSave(ply)
	Inventory.ReconcileWeapons(ply, true)
	if record.kind == "weapon" and ply:HasWeapon(record.class) then ply:SelectWeapon(record.class) end
	return true
end

function Inventory.ClearEquipment(ply, slot)
	slot = string.lower(tostring(slot or ""))
	if not IsValid(ply) or not equipmentSlotNames[slot] or not equipment(ply)[slot] then return false end
	Inventory.CaptureEquippedWeaponStates(ply)
	equipment(ply)[slot] = nil
	Inventory.Sync(ply, false)
	Inventory.QueueSave(ply)
	Inventory.ReconcileWeapons(ply, true)
	return true
end

function Inventory.MoveItem(ply, itemID, x, y, rotated)
	local record = findByID(ply, tostring(itemID or ""))
	if not record then return false end
	local ok, width, height = Inventory.CanPlaceRecords(items(ply), record, x, y, rotated == true, record.id)
	if not ok then return false end
	record.x, record.y, record.w, record.h, record.rotated = math.floor(x), math.floor(y), width, height, rotated == true
	Inventory.Sync(ply, false) Inventory.QueueSave(ply)
	return true
end

function Inventory.AutoPlace(ply, itemID, rotated)
	local record = findByID(ply, tostring(itemID or ""))
	if not record then return false end
	local x, y, chosenRotation, width, height = findSpace(items(ply), record, rotated == true)
	if not x then return false end
	record.x, record.y, record.w, record.h, record.rotated = x, y, width, height, chosenRotation
	Inventory.Sync(ply, false) Inventory.QueueSave(ply)
	return true
end

function Inventory.TakeRawByID(ply, itemID)
	if not IsValid(ply) then return nil end
	local record, index = findByID(ply, tostring(itemID or ""))
	if not record then return nil end
	Inventory.CaptureEquippedWeaponStates(ply)
	table.remove(items(ply), index)
	for slot, equippedID in pairs(equipment(ply)) do if equippedID == record.id then equipment(ply)[slot] = nil end end
	if ply.DRPSelectedPocketID == record.id then ply.DRPSelectedPocketID = items(ply)[1] and items(ply)[1].id or nil end
	local removed = copyRecord(record)
	removed.id = record.id
	Inventory.Sync(ply, false) Inventory.QueueSave(ply)
	hook.Run("DRPHandsItemRemoved", ply, removed)
	Inventory.ReconcileWeapons(ply, true)
	return removed
end

function Inventory.TakeRaw(ply, index)
	local record = items(ply)[math.floor(tonumber(index) or 0)]
	return record and Inventory.TakeRawByID(ply, record.id) or nil
end

function Inventory.Remove(ply, index) return Inventory.TakeRaw(ply, index) end

function Inventory.DropByID(ply, itemID)
	local record = findByID(ply, tostring(itemID or ""))
	if not record then notify(ply, "That Hands item no longer exists.", 3) return false end
	local trace = ply:GetEyeTrace()
	if not trace.Hit or trace.HitSky or trace.HitPos:DistToSqr(ply:EyePos()) > 262144 then return false end
	if not Inventory.SpawnRecordAt(ply, record, trace.HitPos, trace.HitNormal, false) then return false end
	Inventory.TakeRawByID(ply, record.id)
	notify(ply, "Dropped " .. record.label .. ".", 1)
	return true
end

function Inventory.Drop(ply, index)
	local record = items(ply)[math.floor(tonumber(index) or #items(ply))]
	return record and Inventory.DropByID(ply, record.id) or false
end
function Inventory.DropLast(ply) return Inventory.Drop(ply, #items(ply)) end

function Inventory.DropAllAt(ply, deathPosition)
	if not IsValid(ply) then return 0, 0 end
	local inventory = items(ply)
	if #inventory == 0 then return 0, 0 end
	-- Death loot is secured in one server-owned suitcase. Keep this compatibility
	-- entry point because contracts already call it after returning escrow items.
	if DRP.DeathLoot and DRP.DeathLoot.Create then
		return DRP.DeathLoot:Create(ply, deathPosition)
	end
	notify(ply, "Death loot storage is unavailable; your Hands inventory was retained.", 3)
	return 0, #inventory
end

function Inventory.ExtractAll(ply)
	if not IsValid(ply) then return {}, {}, "" end
	Inventory.CaptureEquippedWeaponStates(ply)
	local extracted = table.Copy(items(ply))
	local equippedSnapshot = table.Copy(equipment(ply))
	local selectedSnapshot = tostring(ply.DRPSelectedPocketID or "")
	ply.DRPPocketItems = {}
	ply.DRPHandsEquipment = {}
	ply.DRPSelectedPocketID = nil
	Inventory.Sync(ply, false)
	Inventory.QueueSave(ply)
	hook.Run("DRPHandsInventoryExtracted", ply, extracted, "death_suitcase")
	Inventory.ReconcileWeapons(ply, false)
	return extracted, equippedSnapshot, selectedSnapshot
end

function Inventory.Describe(ply)
	local output = {}
	for _, record in ipairs(items(ply)) do output[#output + 1] = record.label .. ((record.amount or 1) > 1 and (" ×" .. record.amount) or "") end
	return #output > 0 and table.concat(output, "  •  ") or "empty"
end

local function simulateInsert(records, rawRecord)
	local record = copyRecord(rawRecord)
	local key, amount = stackKey(record), math.max(1, math.floor(tonumber(record.amount) or 1))
	if key then
		for _, existing in ipairs(records) do
			if stackKey(existing) == key and amount > 0 then
				local moved = math.min(amount, stackLimit(record) - (existing.amount or 1))
				existing.amount = (existing.amount or 1) + moved amount = amount - moved
			end
		end
		while amount > 0 do
			local chunk = table.Copy(record) chunk.amount = math.min(amount, stackLimit(record)) chunk.id = "sim_" .. (#records + 1)
			local x, y, rotated, width, height = findSpace(records, chunk, false)
			if not x then return false end
			chunk.x, chunk.y, chunk.w, chunk.h, chunk.rotated = x, y, width, height, rotated
			records[#records + 1] = chunk amount = amount - chunk.amount
		end
		return true
	end
	record.id = "sim_new_" .. (#records + 1)
	local x, y, rotated, width, height = findSpace(records, record, false)
	if not x then return false end
	record.id = "sim_" .. (#records + 1) record.x, record.y, record.w, record.h, record.rotated = x, y, width, height, rotated
	records[#records + 1] = record
	return true
end

function Inventory.CanInsertBatchRecords(existing, records)
	if not istable(existing) or not istable(records) then return false end
	local simulated = table.Copy(existing)
	for _, record in ipairs(records) do if not istable(record) or not simulateInsert(simulated, record) then return false end end
	return true
end

function Inventory.CanInsertBatch(ply, records)
	return IsValid(ply) and Inventory.CanInsertBatchRecords(items(ply), records) or false
end

function Inventory.CanInsertRaw(ply, record) return istable(record) and Inventory.CanInsertBatch(ply, { record }) or false end

local function insertStacked(ply, rawRecord)
	local record = copyRecord(rawRecord)
	local key, remaining = stackKey(record), math.max(1, math.floor(tonumber(record.amount) or 1))
	for _, existing in ipairs(items(ply)) do
		if stackKey(existing) == key and remaining > 0 then
			local moved = math.min(remaining, stackLimit(record) - (existing.amount or 1))
			existing.amount = (existing.amount or 1) + moved remaining = remaining - moved
		end
	end
	while remaining > 0 do
		local chunk = table.Copy(record) chunk.amount = math.min(remaining, stackLimit(record)) chunk.id = nil
		if not insertPrepared(ply, chunk, true) then return false end
		remaining = remaining - chunk.amount
	end
	return true
end

function Inventory.InsertRaw(ply, record, deferSync)
	if not Inventory.CanInsertRaw(ply, record) then return false end
	local ok = stackKey(record) and insertStacked(ply, record) or insertPrepared(ply, record, true)
	if ok then
		if deferSync ~= true then Inventory.Sync(ply, false) Inventory.QueueSave(ply) end
		hook.Run("DRPHandsItemAdded", ply, record, "service")
	end
	return ok == true
end

function Inventory.InsertRawWithReceipt(ply, record)
	if not IsValid(ply) or not istable(record) then return false, {} end
	local before, key = {}, stackKey(record)
	for _, existing in ipairs(items(ply)) do before[existing.id] = existing.amount or 1 end
	if not Inventory.InsertRaw(ply, record) then return false, {} end
	local receipts = {}
	for _, existing in ipairs(items(ply)) do
		local previous = before[existing.id]
		local changed = previous == nil or (key and stackKey(existing) == key and (existing.amount or 1) > previous)
		if changed then
			local amount = previous and ((existing.amount or 1) - previous) or (existing.amount or 1)
			receipts[#receipts + 1] = { id = existing.id, amount = amount }
		end
	end
	return true, receipts
end

function Inventory.TakeAmountByID(ply, itemID, amount)
	local record = findByID(ply, tostring(itemID or ""))
	if not record then return nil end
	amount = math.max(1, math.floor(tonumber(amount) or 1))
	if stackKey(record) and (record.amount or 1) > amount then
		record.amount = record.amount - amount
		local taken = copyRecord(record) taken.id, taken.amount = record.id, amount
		Inventory.Sync(ply, false) Inventory.QueueSave(ply)
		return taken
	end
	return Inventory.TakeRawByID(ply, record.id)
end

function Inventory.Add(ply, record, amount)
	if not IsValid(ply) or not istable(record) then return false end
	record = table.Copy(record) record.amount = math.max(1, math.floor(tonumber(amount) or record.amount or 1))
	return Inventory.InsertRaw(ply, record)
end

function Inventory.CanAdd(ply, kind, key, amount)
	local record = { kind = kind, amount = amount or 1, class = kind == "resource" and "drp_cocaine_item" or (kind == "drug" and "drp_drug" or "drp_ammo_stack") }
	if kind == "resource" then record.resource = key elseif kind == "drug" then record.drug = key elseif kind == "ammo" then record.ammo_type = key end
	return Inventory.CanInsertRaw(ply, record)
end

function Inventory.AddResource(ply, key, amount, label, model) return Inventory.Add(ply, { kind = "resource", class = "drp_cocaine_item", resource = key, label = label or key, model = model or "models/props_lab/box01a.mdl" }, amount) end
function Inventory.AddDrug(ply, key, amount, label, model) return Inventory.Add(ply, { kind = "drug", class = "drp_drug", drug = key, label = label or key, model = model or "models/props_lab/jar01b.mdl" }, amount) end
function Inventory.AddAmmo(ply, ammoType, amount, label) return Inventory.Add(ply, { kind = "ammo", class = "drp_ammo_stack", ammo_type = ammoType, label = label or (ammoType .. " ammunition") }, amount) end

function Inventory.CountKind(ply, kind, key)
	local wanted = kind .. ":" .. tostring(key or "")
	local count = 0
	for _, record in ipairs(items(ply)) do if stackKey(record) == wanted then count = count + math.max(1, tonumber(record.amount) or 1) end end
	return count
end
function Inventory.CountResource(ply, key) return Inventory.CountKind(ply, "resource", key) end
function Inventory.CountDrug(ply, key) return Inventory.CountKind(ply, "drug", key) end

function Inventory.TakeKind(ply, kind, key, amount)
	amount = math.max(1, math.floor(tonumber(amount) or 1))
	if Inventory.CountKind(ply, kind, key) < amount then return false end
	local wanted, remaining = kind .. ":" .. tostring(key or ""), amount
	for index = #items(ply), 1, -1 do
		local record = items(ply)[index]
		if stackKey(record) == wanted then
			local removed = math.min(record.amount or 1, remaining)
			record.amount = (record.amount or 1) - removed remaining = remaining - removed
			if record.amount <= 0 then table.remove(items(ply), index) end
			if remaining <= 0 then break end
		end
	end
	local selected = findByID(ply, tostring(ply.DRPSelectedPocketID or ""))
	if not selected then ply.DRPSelectedPocketID = items(ply)[1] and items(ply)[1].id or nil end
	local existingIDs = {}
	for _, record in ipairs(items(ply)) do existingIDs[record.id] = true end
	for slot, equippedID in pairs(equipment(ply)) do if not existingIDs[equippedID] then equipment(ply)[slot] = nil end end
	Inventory.Sync(ply, false) Inventory.QueueSave(ply)
	return true
end
function Inventory.ReserveResources(ply, requirements, multiplier)
	multiplier=math.max(1,math.floor(tonumber(multiplier) or 1))
	for key,count in pairs(requirements or {}) do if Inventory.CountResource(ply,key)<count*multiplier then return false,key end end
	local reserved={}
	for key,count in pairs(requirements or {}) do
		local amount=count*multiplier
		if not Inventory.TakeKind(ply,"resource",key,amount) then
			for _,record in ipairs(reserved) do Inventory.InsertRaw(ply,record,true) end Inventory.Sync(ply,false) Inventory.QueueSave(ply)
			return false,key
		end
		local definition=DRP.CraftingShared and DRP.CraftingShared.Item(key)
		reserved[#reserved+1]={kind="resource",class=definition and "drp_crafting_item" or "drp_cocaine_item",resource=key,label=definition and definition.name or key,model=definition and definition.model or "models/props_lab/box01a.mdl",amount=amount}
	end
	return true,reserved
end
function Inventory.RestoreRecords(ply,records)
	if not Inventory.CanInsertBatch(ply,records or {}) then return false end
	for _,record in ipairs(records or {}) do Inventory.InsertRaw(ply,record,true) end Inventory.Sync(ply,false) Inventory.QueueSave(ply) return true
end
function Inventory.TakeResource(ply, key, amount) return Inventory.TakeKind(ply, "resource", key, amount) end
function Inventory.TakeDrug(ply, key, amount) return Inventory.TakeKind(ply, "drug", key, amount) end

function Inventory.UseItem(ply, itemID)
	local record = findByID(ply, tostring(itemID or ""))
	if not record then return false end
	if record.kind == "drug" then
		if not DRP.Drugs or not DRP.Drugs.Ingest(ply, record.drug, ply, false) then return false end
		record.amount = (record.amount or 1) - 1
	elseif record.kind == "ammo" then
		local ammoID = game.GetAmmoID(record.ammo_type or "")
		if not isnumber(ammoID) or ammoID < 0 then notify(ply, "That ammunition type is not mounted.", 3) return false end
		local maximum = game.GetAmmoMax and game.GetAmmoMax(ammoID) or -1
		if not isnumber(maximum) or maximum <= 0 then maximum = Inventory.AmmoStackLimit end
		local moved = math.min(record.amount or 1, math.max(0, maximum - ply:GetAmmoCount(ammoID)))
		if moved <= 0 then notify(ply, "Your reserve for " .. record.label .. " is full.", 3) return false end
		ply:GiveAmmo(moved, ammoID, true) record.amount = (record.amount or 1) - moved
		notify(ply, "Loaded " .. moved .. " rounds of " .. record.label .. ".", 1)
	else
		notify(ply, "That item has no direct Hands action. Drop it to use it in the world.", 2)
		return false
	end
	if record.amount <= 0 then Inventory.TakeRawByID(ply, record.id) else Inventory.Sync(ply, false) Inventory.QueueSave(ply) end
	return true
end

function Inventory.ConsumeSelected(ply)
	local record = Inventory.Selected(ply)
	if not record or record.kind ~= "drug" then notify(ply, "Select a drug in Hands first.", 3) return false end
	return Inventory.UseItem(ply, record.id)
end

function Inventory.RecoverItem(ply, itemID)
	for index, record in ipairs(recovery(ply)) do
		if record.id == tostring(itemID or "") then
			if not Inventory.CanInsertRaw(ply, record) then notify(ply, "Make more room in Hands before recovering that item.", 3) return false end
			table.remove(recovery(ply), index)
			if not Inventory.InsertRaw(ply, record) then table.insert(recovery(ply), index, record) return false end
			notify(ply, record.label .. " was recovered into Hands.", 1)
			return true
		end
	end
	return false
end

local function clientRecord(record)
	local baseWidth, baseHeight = Inventory.Footprint(record)
	local width, height = record.w or baseWidth, record.h or baseHeight
	return { id = record.id, label = record.label, kind = record.kind, class = record.class, key = record.drug or record.resource or record.ammo_type or "", amount = record.amount or 1, x = record.x, y = record.y, w = width, h = height, rotated = record.rotated == true, model = record.model or "" }
end
Inventory.ClientRecord = clientRecord

function Inventory.BuildSnapshot(ply)
	local snapshot = { schema = Inventory.SchemaVersion, width = Inventory.GridWidth, height = Inventory.GridHeight, selected = ply.DRPSelectedPocketID or "", revision = ply.DRPPocketRevision or 0, items = {}, equipped = table.Copy(equipment(ply)) }
	for _, record in ipairs(items(ply)) do snapshot.items[#snapshot.items + 1] = clientRecord(record) end
	return snapshot
end

local function sendCompressed(name, ply, payload)
	local json = util.TableToJSON(payload, false) or "{}"
	local compressed = util.Compress(json) or ""
	if #compressed > 1048575 then return false end
	net.Start(name) net.WriteUInt(DRP.ProtocolVersion, 8) net.WriteUInt(#compressed, 20) if #compressed > 0 then net.WriteData(compressed, #compressed) end net.Send(ply)
	return true
end

function Inventory.Sync(ply, open)
	if not IsValid(ply) then return end
	local snapshot = Inventory.BuildSnapshot(ply) snapshot.open = open == true
	sendCompressed(inventoryMessage, ply, snapshot)
end
function Inventory.Open(ply)
	Inventory.RecoverAvailable(ply, false)
	Inventory.Sync(ply, true)
end

local function readAction()
	local length = net.ReadUInt(16)
	if length <= 0 or length > 32768 then return {} end
	local decoded = util.Decompress(net.ReadData(length))
	local data = decoded and util.JSONToTable(decoded) or nil
	return istable(data) and data or {}
end

DRP.Net.Receive(inventoryActionMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "inventory_action", 0.08, 12) then return end
	local data = readAction()
	local action, itemID = tostring(data.action or ""), tostring(data.id or "")
	if action == "select" then Inventory.SelectByID(ply, itemID)
	elseif action == "drop" then Inventory.DropByID(ply, itemID)
	elseif action == "use" then Inventory.UseItem(ply, itemID)
	elseif action == "move" then Inventory.MoveItem(ply, itemID, data.x, data.y, data.rotated == true)
	elseif action == "equip" then Inventory.AssignEquipment(ply, itemID, data.slot)
	elseif action == "unequip" then Inventory.ClearEquipment(ply, data.slot)
	elseif action == "learn_schematic" then
		if DRP.Crafting and DRP.Crafting.LearnSchematic then DRP.Crafting:LearnSchematic(ply, itemID) end
	elseif action == "recover" then Inventory.RecoverItem(ply, itemID) end
	if DRP.Salvage and DRP.Salvage.SyncOpen then DRP.Salvage:SyncOpen(ply) end
	if DRP.DeathLoot and DRP.DeathLoot.SyncOpen then DRP.DeathLoot:SyncOpen(ply) end
end)

function Inventory.SaveAll()
	for _, ply in ipairs(DRP.Players.List) do if IsValid(ply) and not ply:IsBot() then Inventory.SaveNow(ply) end end
end

local function possessionNotice(ply, class)
	if not IsValid(ply) or (ply.DRPHandsWeaponNoticeAt or 0) > CurTime() then return end
	ply.DRPHandsWeaponNoticeAt = CurTime() + 2
	notify(ply, "Equip Hands and left-click " .. tostring(class or "that weapon") .. ", then assign it to Primary, Secondary or an ALT slot.", 3)
end

hook.Add("PlayerCanPickupWeapon", "DRP.Inventory.RequireEquippedWeapon", function(ply, weapon)
	local class = IsValid(weapon) and weapon:GetClass() or ""
	if class ~= "" and not Inventory.CanPossessWeapon(ply, class) then
		possessionNotice(ply, IsValid(weapon) and weapon:GetPrintName() or class)
		return false
	end
end)

hook.Add("PlayerSwitchWeapon", "DRP.Inventory.RequireEquippedWeapon", function(ply, _, weapon)
	local class = IsValid(weapon) and weapon:GetClass() or ""
	if class == "" or Inventory.CanPossessWeapon(ply, class) then return end
	possessionNotice(ply, weapon:GetPrintName())
	timer.Simple(0, function()
		if IsValid(ply) and ply:HasWeapon(class) and not Inventory.CanPossessWeapon(ply, class) then ply:StripWeapon(class) end
	end)
	return true
end)

hook.Add("WeaponEquip", "DRP.Inventory.RequireEquippedWeapon", function(weapon, ply)
	local class = IsValid(weapon) and weapon:GetClass() or ""
	if class == "" or Inventory.CanPossessWeapon(ply, class) then return end
	timer.Simple(0, function()
		if not IsValid(ply) or Inventory.CanPossessWeapon(ply, class) then return end
		if ply:HasWeapon(class) then ply:StripWeapon(class) end
		possessionNotice(ply, IsValid(weapon) and weapon:GetPrintName() or class)
	end)
end)

hook.Add("DRPAdminModeChanged", "DRP.Inventory.AdminModeReconcile", function(ply, enabled)
	if enabled ~= true and IsValid(ply) and ply:Alive() then Inventory.ReconcileWeapons(ply, true) end
end)
