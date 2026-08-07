local Armory = {
	Catalog = {},
	ByClass = {},
	UnlockLevels = {},
	Entities = setmetatable({}, { __mode = "k" }),
	ActiveRaids = setmetatable({}, { __mode = "k" }),
	RaidCooldowns = setmetatable({}, { __mode = "k" }),
	RaidDuration = 90,
	RaidCooldown = 600,
	MaxRewardCrates = 8
}

DRP.Armory = Armory
DRP.Services.Register("armory", Armory)

local OPEN = "drp_armory_open_v1"
local BUY = "drp_armory_buy_v1"
local UNLOCK_SYNC = "drp_weapon_unlock_sync_v1"
local UNLOCK_SET = "drp_weapon_unlock_set_v1"
util.AddNetworkString(OPEN)
util.AddNetworkString(BUY)
util.AddNetworkString(UNLOCK_SYNC)
util.AddNetworkString(UNLOCK_SET)

local excluded = {
	weapon_base = true, arc9_base = true, arc9_base_nade = true, arc9_go_base = true,
	gmod_tool = true, gmod_camera = true, weapon_physgun = true, weapon_physcannon = true,
	weapon_drp_keys = true, weapon_drp_pocket = true, weapon_drp_taser = true,
	weapon_drp_cuffs = true, weapon_drp_arrest = true, weapon_drp_medkit = true,
	weapon_drp_defibrillator = true, weapon_drp_kidnap_baton = true,
	weapon_drp_blindfold = true, weapon_drp_gag = true, weapon_portalgun = true
}

local function clean(value, maximum)
	return string.sub(string.Trim(tostring(value or "")), 1, maximum or 96)
end

local function validWeapon(class, stored)
	return class ~= "" and not excluded[class]
		and not (DRP.WeaponAccess and DRP.WeaponAccess.IsRestricted(class))
		and stored and stored.AdminOnly ~= true
		and not string.StartWith(class, "base_") and not string.EndsWith(class, "_base")
end

function Armory:BuildCatalog()
	local found = {}
	local function add(class, listed)
		class = string.lower(clean(class, 96))
		local stored = weapons.GetStored(class)
		if found[class] or not validWeapon(class, stored) then return end
		listed = listed or {}
		local name = clean(listed.PrintName or stored.PrintName or class, 96)
		if name == "" or string.StartWith(name, "#") then name = class end
		local slot = math.Clamp(math.floor(tonumber(stored.Slot) or 1), 0, 5)
		found[class] = {
			class = class,
			name = name,
			category = clean(listed.Category or stored.Category or "Weapons", 64),
			price = math.Clamp(750 + slot * 350, 250, 10000),
			level = math.Clamp(math.floor(tonumber(self.UnlockLevels[class]) or 1), 1, 100)
		}
	end
	for class, definition in pairs(list.Get("Weapon") or {}) do add(class, definition) end
	for _, definition in ipairs(weapons.GetList() or {}) do add(definition.ClassName or definition.Class or definition.Folder, definition) end
	self.Catalog, self.ByClass = {}, found
	for _, entry in pairs(found) do self.Catalog[#self.Catalog + 1] = entry end
	table.sort(self.Catalog, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
end

function Armory:SaveUnlocks()
	file.CreateDir("darkrp")
	file.Write("darkrp/weapon_unlock_levels.json", util.TableToJSON(self.UnlockLevels, false))
end

function Armory:SendUnlocks(ply)
	local entries = {}
	for class, level in pairs(self.UnlockLevels) do entries[#entries + 1] = { class = class, level = level } end
	net.Start(UNLOCK_SYNC)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.min(#entries, 4095), 12)
	for index = 1, math.min(#entries, 4095) do
		net.WriteString(entries[index].class)
		net.WriteUInt(entries[index].level, 7)
	end
	if IsValid(ply) then net.Send(ply) else net.Broadcast() end
end

function Armory:RegisterEntity(entity)
	if not IsValid(entity) then return false end
	self.Entities[entity] = true
	entity:SetNW2Bool("DRPPoliceArmory", true)
	return true
end

function Armory:RandomWeaponClass()
	if #self.Catalog == 0 then self:BuildCatalog() end
	local entry = self.Catalog[math.random(1, math.max(1, #self.Catalog))]
	return entry and entry.class or nil
end

function Armory:Open(ply, entity)
	if not IsValid(ply) or not IsValid(entity) or not ply:DRPJob().isPolice then return false end
	if ply:GetPos():DistToSqr(entity:GetPos()) > 65536 then return false end
	net.Start(OPEN)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteEntity(entity)
	net.WriteUInt(math.min(#self.Catalog, 1023), 10)
	for index = 1, math.min(#self.Catalog, 1023) do
		local entry = self.Catalog[index]
		net.WriteString(entry.class)
		net.WriteString(entry.name)
		net.WriteString(entry.category)
		net.WriteUInt(entry.price, 16)
		net.WriteUInt(entry.level, 7)
	end
	net.Send(ply)
	return true
end

local function raidRole(incident, ply)
	return DRP.Incidents.Role(incident, ply)
end

function Armory:GrantRaidCombat(incident, newcomer)
	local attackers, defenders = {}, {}
	for _, participant in ipairs(incident.participants) do
		if participant.role == "raider" then attackers[#attackers + 1] = participant.player end
		if participant.role == "defender" then defenders[#defenders + 1] = participant.player end
	end
	for _, attacker in ipairs(attackers) do
		for _, defender in ipairs(defenders) do
			if IsValid(attacker) and IsValid(defender) then
				DRP.Incidents.Grant(incident, "damage", attacker, defender, "Active armory raid", incident.deadline)
				DRP.Incidents.Grant(incident, "damage", defender, attacker, "Defending the police armory", incident.deadline)
			end
		end
	end
end

function Armory:StartOrJoinRaid(ply, entity)
	if not ply:DRPHasRoleCapability("canRaid") then DRP.Net.Notify(ply, "Your role identity cannot raid the armory.", 3) return false end
	local incident = self.ActiveRaids[entity] and DRP.Incidents.Get(self.ActiveRaids[entity])
	if incident then
		if raidRole(incident, ply) then return false end
		DRP.Incidents.AddParticipant(incident, "raider", ply)
		self:GrantRaidCombat(incident, ply)
		DRP.Net.Notify(ply, "Joined armory raid #" .. incident.id .. ". The original countdown was not reset.", 1)
		return true
	end
	if #DRP.Incidents.ForPlayer(ply, "armory_raid") > 0 then DRP.Net.Notify(ply, "You are already participating in another armory raid.", 3) return false end
	local cooldown = self.RaidCooldowns[entity] or 0
	if cooldown > CurTime() then DRP.Net.Notify(ply, "The armory is secured for another " .. math.ceil(cooldown - CurTime()) .. " seconds.", 3) return false end
	local defender
	for _, candidate in player.Iterator() do if candidate ~= ply and candidate:DRPReady() and candidate:Alive() and candidate:DRPJob().isPolice then defender = candidate break end end
	if not IsValid(defender) then DRP.Net.Notify(ply, "At least one police defender must be active.", 3) return false end
	incident = DRP.Incidents.Create("armory_raid", {
		state = "active",
		reason = ply:DRPName() .. " began raiding the police armory",
		instigator = ply,
		victim = defender,
		participants = { raider = ply, defender = defender },
		deadline = CurTime() + self.RaidDuration,
		metadata = { armory_index = entity:EntIndex() }
	})
	if not incident then return false end
	incident.armory = entity
	self.ActiveRaids[entity] = incident.id
	self.RaidCooldowns[entity] = CurTime() + self.RaidCooldown
	for _, candidate in player.Iterator() do
		if candidate ~= defender and candidate:DRPReady() and candidate:Alive() and candidate:DRPJob().isPolice then DRP.Incidents.AddParticipant(incident, "defender", candidate) end
	end
	self:GrantRaidCombat(incident)
	DRP.Incidents.AddEvidence(incident, "armory_raid_started", ply, defender, self.RaidDuration .. " second fixed crate countdown")
	for _, candidate in player.Iterator() do DRP.Net.Notify(candidate, "Armory raid #" .. incident.id .. " started. Crates release in " .. self.RaidDuration .. " seconds if raiders hold it.", 2) end
	return true
end

function Armory:SpawnRewards(incident)
	local entity = incident.armory
	if not IsValid(entity) then return 0 end
	local budget = DRP.Services.Get("props")
	local raiders = 0
	for _, participant in ipairs(incident.participants) do if participant.role == "raider" and IsValid(participant.player) then raiders = raiders + 1 end end
	local count = math.Clamp(raiders, 1, self.MaxRewardCrates)
	local spawned = 0
	for index = 1, count do
		if not budget or not budget.CanCreateLimitedEntity("crate") then break end
		local crate = ents.Create("drp_weapon_crate")
		if IsValid(crate) then
			crate:SetModel("models/items/item_item_crate.mdl")
			local angle = (index - 1) * (360 / count)
			crate:SetPos(entity:GetPos() + Vector(math.cos(math.rad(angle)) * 55, math.sin(math.rad(angle)) * 55, 24))
			crate:Spawn()
			crate:SetNW2String("DRPJobEntityName", "Raided Weapon Crate")
			crate:SetNW2Bool("DRPRandomWeaponCrate", true)
			crate:SetNW2Int("DRPCount", 3)
			if budget.RegisterLimitedEntity(crate, "crate") then spawned = spawned + 1 else crate:Remove() break end
		end
	end
	return spawned
end

function Armory:Use(ply, entity)
	if not IsValid(entity) or not entity:GetNW2Bool("DRPPoliceArmory", false) then return end
	if ply:DRPJob().isPolice then return self:Open(ply, entity) end
	if ply:DRPHasRoleCapability("canRaid") then return self:StartOrJoinRaid(ply, entity) end
	DRP.Net.Notify(ply, "Only police may use this armory. Raiders may attempt to breach it.", 3)
end

function Armory:Start()
	local loaded = util.JSONToTable(file.Read("darkrp/weapon_unlock_levels.json", "DATA") or "")
	if istable(loaded) then
		for class, level in pairs(loaded) do self.UnlockLevels[string.lower(clean(class, 96))] = math.Clamp(math.floor(tonumber(level) or 1), 1, 100) end
	end
	self:BuildCatalog()
end

function Armory:Stop() self:SaveUnlocks() end

DRP.Incidents.RegisterType("armory_raid", {
	initial = "active",
	outcomes = {
		raiders_victory = { winner = "instigator", loser = "victim" },
		default = { winner = "victim", loser = "instigator" }
	}
})

DRP.Incidents.Definitions.armory_raid.onDeadline = function(incident)
	local crates = Armory:SpawnRewards(incident)
	DRP.Incidents.Resolve(incident, "raiders_victory", "Raiders held the armory and released " .. crates .. " weapon crates")
	return true
end

DRP.Incidents.Definitions.armory_raid.onParticipantUnavailable = function(incident, ply, resolution, detail)
	local role = raidRole(incident, ply)
	if role == "defender" and resolution == "participant_died" then
		DRP.Incidents.AddEvidence(incident, "defender_downed", ply, nil, "Defender may rejoin after respawning")
		return true
	end
	DRP.Incidents.RemoveParticipant(incident, ply, detail or "Participant unavailable")
	if role == "raider" then
		for _, participant in ipairs(incident.participants) do
			if participant.role == "raider" and IsValid(participant.player) then
				if incident.instigator == ply then incident.instigator = participant.player end
				return true
			end
		end
		DRP.Incidents.Resolve(incident, "defenders_victory", "All raiders were eliminated")
	elseif role == "defender" then
		for _, participant in ipairs(incident.participants) do
			if participant.role == "defender" and IsValid(participant.player) then
				if incident.victim == ply then incident.victim = participant.player end
				return true
			end
		end
		DRP.Incidents.Resolve(incident, "defenders_victory", "Raid cancelled because no police defenders remained online")
	end
	return true
end

hook.Add("DRPIncidentResolved", "DRP.Armory.RaidResolved", function(incident)
	if incident.type == "armory_raid" and IsValid(incident.armory) then Armory.ActiveRaids[incident.armory] = nil end
end)

hook.Add("EntityRemoved", "DRP.Armory.EntityRemoved", function(entity)
	local incident = Armory.ActiveRaids[entity] and DRP.Incidents.Get(Armory.ActiveRaids[entity])
	if incident then DRP.Incidents.Resolve(incident, "defenders_victory", "The armory became unavailable") end
	Armory.Entities[entity] = nil
	Armory.ActiveRaids[entity] = nil
end)

hook.Add("DRPPlayerReady", "DRP.Armory.UnlockSync", function(ply) Armory:SendUnlocks(ply) end)

DRP.Net.Receive(BUY, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "armory_buy", 0.3, 4) then return end
	local entity, class = net.ReadEntity(), string.lower(clean(net.ReadString(), 96))
	local entry = Armory.ByClass[class]
	if not IsValid(entity) or not Armory.Entities[entity] or ply:GetPos():DistToSqr(entity:GetPos()) > 65536 or not ply:DRPJob().isPolice or not entry then return end
	if ply:DRPXPLevel() < entry.level then DRP.Net.Notify(ply, "This weapon unlocks at level " .. entry.level .. ".", 3) return end
	if not DRP.Inventory or not DRP.Inventory.CreateWeaponRecord then DRP.Net.Notify(ply, "Hands inventory is not ready.", 3) return end
	if ply:HasWeapon(class) or DRP.Inventory.HasWeaponRecord(ply, class) then DRP.Net.Notify(ply, "You already own that weapon.", 3) return end
	local item = DRP.Inventory.CreateWeaponRecord(class)
	if not item or not DRP.Inventory.CanInsertRaw(ply, item) then DRP.Net.Notify(ply, "Make room in Hands before purchasing that weapon.", 3) return end
	local purchasePrice = entry.price
	if DRP.EconomyDirector then purchasePrice = DRP.EconomyDirector:Quote("weapon:" .. class, "sell", purchasePrice) end
	if not DRP.Economy.Take(ply, purchasePrice, "armory purchase") then DRP.Net.Notify(ply, "You need $" .. purchasePrice .. ".", 3) return end
	if not DRP.Inventory.InsertRaw(ply, item) then DRP.Economy.Add(ply, purchasePrice, "failed armory purchase refund") return end
	DRP.Net.Notify(ply, item.label .. " was placed in Hands. Equip it before use.", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "armory_weapon_purchased", entity, class .. " ($" .. purchasePrice .. ")") end
end)

DRP.Net.Receive(UNLOCK_SET, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "weapon_unlock_set", 0.5, 3) then return end
	local class = string.lower(clean(net.ReadString(), 96))
	local level = math.Clamp(net.ReadUInt(7), 1, 100)
	if not DRP.Admin or DRP.AdminRankLevel(DRP.Admin.RankKey(ply)) < DRP.AdminRankLevel("headadmin") or not Armory.ByClass[class] then return end
	Armory.UnlockLevels[class] = level == 1 and nil or level
	Armory.ByClass[class].level = level
	Armory:SaveUnlocks()
	Armory:SendUnlocks()
	DRP.Net.Notify(ply, Armory.ByClass[class].name .. " now unlocks at level " .. level .. ".", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "weapon_unlock_level_set", nil, class .. " level " .. level) end
end)
