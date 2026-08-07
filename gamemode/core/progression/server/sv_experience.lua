local Experience = {
	MaxLevel = 100,
	MaxPrestige = 10,
	HistoryLimit = 24,
	XPVersion = 2,
	XPMultiplier = 1,
	BaseXP = 110,
	GrowthFactor = 1.07,
	LevelUpNoticeCooldown = 6,
	PreviewUnlockCount = 5,
	UnlockTemplates = {
		{ level = 15, key = "weapon:weapon_crowbar", item = "weapon_crowbar", name = "Crowbar" },
		{ level = 25, key = "weapon:weapon_smg1", item = "weapon_smg1", name = "SMG" },
		{ level = 35, key = "job_entity:tip_jar", item = "job_entity:tip_jar", name = "Tip Jar" },
		{ level = 45, key = "job_entity:pistol_crate", item = "job_entity:pistol_crate", name = "Pistol Crate" },
		{ level = 55, key = "weapon:weapon_shotgun", item = "weapon_shotgun", name = "Shotgun" },
		{ level = 65, key = "job_entity:evidence_locker", item = "job_entity:evidence_locker", name = "Evidence Locker" },
		{ level = 75, key = "prop:models/props_c17/oildrum001a.mdl", item = "models/props_c17/oildrum001a.mdl", name = "Metal Drum" },
		{ level = 85, key = "job_entity:drug_heroin", item = "job_entity:drug_heroin", name = "Heroin Supply" },
		{ level = 95, key = "job_entity:drug_crack", item = "job_entity:drug_crack", name = "Crack Supply" },
		{ level = 100, key = "prop:models/props_c17/signpole001a.mdl", item = "models/props_c17/signpole001a.mdl", name = "Sign Pole" }
	}
}

DRP.Experience = Experience
DRP.Services.Register("experience", Experience)

for prestige = 1, Experience.MaxPrestige do
	resource.AddFile(string.format("materials/darkrp/prestige/prestige_%02d.png", prestige))
end

local REQUEST = "drp_xp_overview_request_v1"
local OVERVIEW = "drp_xp_overview_v1"
local ACTION = "drp_xp_action_v1"

util.AddNetworkString(REQUEST)
util.AddNetworkString(OVERVIEW)
util.AddNetworkString(ACTION)

local function clampUInt(value, minValue, maxValue)
	value = math.floor(tonumber(value) or 0)
	if minValue and value < minValue then return minValue end
	if maxValue and value > maxValue then return maxValue end
	return value
end

local function normalizeUnlockedValue(raw)
	if istable(raw) then
		local normalized = {}
		for index, value in pairs(raw) do
			local key = isnumber(index) and value or (value == true and index or nil)
			if isstring(key) then normalized[key] = true end
		end
		return normalized
	end
	if isstring(raw) then
		local decoded = util.JSONToTable(raw)
		if istable(decoded) then return normalizeUnlockedValue(decoded) end
	end
	return {}
end

local function buildExperienceFallbackSnapshot(ply)
	if not IsValid(ply) then
		return {
			level = 1,
			xp = 0,
			xp_to_next = 110,
			progress = 0,
			next_rank = 2,
			remaining = 110,
			prestige = 0,
			tokens = 0,
			history = {},
			next_unlocks = {},
			unlocked = {},
			can_prestige = false,
			maxed = false,
			max_level = Experience.MaxLevel,
			max_prestige = Experience.MaxPrestige,
			version = Experience.XPVersion,
			sync = os.time()
		}
	end
	local level = 1
	local xp = 0
	if isfunction(ply.DRPXPLevel) then level = math.Clamp(tonumber(ply:DRPXPLevel()) or 1, 1, Experience.MaxLevel) else level = clampUInt((ply.DRPXPLevelValue or 1), 1, Experience.MaxLevel) end
	if isfunction(ply.DRPXP) then xp = math.max(0, math.floor(tonumber(ply:DRPXP()) or 0)) else xp = math.max(0, math.floor(tonumber(ply.DRPXPValue) or 0)) end
	local nextLevel = math.min(Experience.MaxLevel, level + 1)
	local progress = 0
	if nextLevel > level then
		progress = clampUInt(xp, 0, Experience:XPNeededForNext(level) or 0) / math.max(1, Experience:XPNeededForNext(level))
	end
	local prestige = isfunction(ply.DRPXPPrestige)
		and clampUInt(ply:DRPXPPrestige(), 0, Experience.MaxPrestige)
		or clampUInt(ply.DRPXPPrestigeValue or 0, 0, Experience.MaxPrestige)
	return {
		level = level,
		xp = xp,
		xp_to_next = Experience:XPNeededForNext(level),
		progress = math.Clamp(progress, 0, 1),
		next_rank = nextLevel,
		remaining = math.max(0, (Experience:XPNeededForNext(level) or 0) - xp),
		prestige = prestige,
		tokens = isfunction(ply.DRPXPPrestigeTokens) and ply:DRPXPPrestigeTokens() or clampUInt(ply.DRPXPPrestigeTokensValue or 0, 0, Experience.MaxPrestige),
		history = {},
		next_unlocks = {},
		unlocked = {},
		can_prestige = false,
		maxed = prestige >= Experience.MaxPrestige and level >= Experience.MaxLevel,
		max_level = Experience.MaxLevel,
		max_prestige = Experience.MaxPrestige,
		version = Experience.XPVersion,
		sync = os.time()
	}
end

local function serializeUnlocked(unlockedItems)
	local payload = {}
	for key in pairs(unlockedItems or {}) do payload[#payload + 1] = key end
	table.sort(payload)
	return util.TableToJSON(payload, false)
end

local function sanitizeItem(raw)
	local key = string.Trim(tostring(raw or ""))
	if key == "" then return nil end
	key = string.lower(key)

	if string.StartWith(key, "prop:") then
		local model = DRP.Props and DRP.Props.NormalizeModel(string.Trim(string.sub(key, 6)))
		if model then return "prop:" .. model end
		return nil
	end

	if string.StartWith(key, "job_entity:") then
		local entityKey = string.Trim(string.sub(key, 12))
		if entityKey == "" then return nil end
		for _, definition in ipairs(DRP.JobEntities or {}) do
			if definition.key == entityKey then return "job_entity:" .. entityKey end
		end
		return nil
	end

	if string.StartWith(key, "weapon:") then
		local weapon = string.Trim(string.sub(key, 8))
		if weapon == "" then return nil end
		if list.Get("Weapon")[weapon] or weapons.GetStored(weapon) then return "weapon:" .. weapon end
		return nil
	end

	if list.Get("Weapon")[key] or weapons.GetStored(key) then return "weapon:" .. key end
	for _, definition in ipairs(DRP.JobEntities or {}) do
		if definition.key == key then return "job_entity:" .. key end
	end
	local model = DRP.Props and DRP.Props.NormalizeModel(key)
	if model then return "prop:" .. model end

	return nil
end

local function sanitizeItems(raw)
	if isstring(raw) then raw = util.JSONToTable(raw) end
	if not istable(raw) then return {} end
	local normalized = {}
	-- MySQL JSON decodes as an array, while NormalizePersistentState exposes a
	-- keyed set. Accept both representations so reconnecting cannot erase it.
	for index, value in pairs(raw) do
		local entry = isnumber(index) and value or (value == true and index or nil)
		local key = entry and sanitizeItem(entry)
		if key then normalized[key] = true end
	end
	return normalized
end

function Experience:NormalizeUnlockedItems(raw)
	return sanitizeItems(raw)
end

local blockedPrestigeWeapons = {
	arc9_base = true,
	arc9_base_nade = true,
	arc9_go_base = true,
	weapon_base = true,
	weapon_physgun = true,
	gmod_tool = true,
	gmod_camera = true,
	weapon_drp_keys = true,
	weapon_drp_pocket = true,
	weapon_drp_taser = true,
	weapon_drp_cuffs = true,
	weapon_drp_arrest = true,
	weapon_drp_medkit = true,
	weapon_drp_defibrillator = true,
	weapon_drp_kidnap_baton = true,
	weapon_drp_blindfold = true,
	weapon_drp_gag = true,
	weapon_portalgun = true,
	ephone = true,
	weapon_drp_mayor_tablet = true,
	weapon_drp_persistence_tool = true
}

function Experience:IsPrestigeWeapon(key)
	key = sanitizeItem(key)
	if not key or not string.StartWith(key, "weapon:") then return false, nil end
	local class = string.sub(key, 8)
	-- Engine weapons (for example weapon_crowbar) may live in the Weapon list
	-- without having a scripted-weapon entry. Both registries represent real,
	-- individually spawnable weapons and must use the same prestige policy.
	local stored = weapons.GetStored(class)
	local listed = list.Get("Weapon")[class]
	local definition = stored or listed
	if class == "" or blockedPrestigeWeapons[class]
		or (DRP.WeaponAccess and DRP.WeaponAccess.IsRestricted(class))
		or not definition or definition.AdminOnly == true then return false, nil end
	return true, "weapon:" .. class
end

local function unlockCatalog(ply)
	local catalog, seen = {}, {}
	for _, entry in ipairs(Experience.UnlockTemplates) do
		-- Weapon progression is administered by the armory policy. Keep the
		-- static templates only as a fallback before that service is available.
		if not (DRP.Armory and string.StartWith(entry.key or "", "weapon:")) then
			catalog[#catalog + 1] = {
				level = entry.level,
				key = entry.key,
				item = entry.item,
				name = string.sub(entry.name or entry.key, 1, 128),
				unlocked = ply and ply.DRPXPUnlockedItemsValue and ply.DRPXPUnlockedItemsValue[entry.key] == true
			}
			seen[entry.key] = true
		end
	end
	if DRP.Armory then
		for class, level in pairs(DRP.Armory.UnlockLevels or {}) do
			local key = "weapon:" .. class
			local definition = DRP.Armory.ByClass and DRP.Armory.ByClass[class]
			if not seen[key] and level > 1 then
				catalog[#catalog + 1] = {
					level = level, key = key, item = class,
					name = definition and definition.name or class,
					unlocked = ply and ply.DRPXPUnlockedItemsValue and ply.DRPXPUnlockedItemsValue[key] == true
				}
			end
		end
	end
	table.sort(catalog, function(a, b) return a.level == b.level and a.name < b.name or a.level < b.level end)
	return catalog
end

function Experience:XPForLevel(level)
	level = clampUInt(level, 1, self.MaxLevel)
	local total = 0
	for current = 1, level - 1 do total = total + self:XPNeededForNext(current) end
	return total
end

function Experience:XPNeededForNext(level)
	level = clampUInt(level, 1, self.MaxLevel)
	if level >= self.MaxLevel then return 0 end
	return math.max(1, math.ceil(self.BaseXP * (self.GrowthFactor ^ (level - 1))))
end

function Experience:EnsurePlayer(ply)
	if not IsValid(ply) then return false end
	if ply.DRPXPHistory == nil then ply.DRPXPHistory = {} end
	if ply.DRPXPUnlockedItemsValue == nil then ply.DRPXPUnlockedItemsValue = {} end
	if ply.DRPXPLevelValue == nil then ply.DRPXPLevelValue = 1 end
	if ply.DRPXPPrestigeValue == nil then ply.DRPXPPrestigeValue = 0 end
	if ply.DRPXPPrestigeTokensValue == nil then ply.DRPXPPrestigeTokensValue = 0 end
	if ply.DRPXPValue == nil then ply.DRPXPValue = 0 end
	return true
end

function Experience:InitializePlayer(ply, xp, level, prestige, tokens, unlockedItems)
	if not IsValid(ply) then return end
	ply.DRPXPValue = math.max(0, math.floor(tonumber(xp) or 0))
	ply.DRPXPLevelValue = clampUInt(level, 1, self.MaxLevel)
	ply.DRPXPPrestigeValue = clampUInt(prestige, 0, self.MaxPrestige)
	ply.DRPXPPrestigeTokensValue = clampUInt(tokens, 0, self.MaxPrestige)
	ply.DRPXPUnlockedItemsValue = self:NormalizeUnlockedItems(unlockedItems)
	ply.DRPXPHistory = {}
	ply.DRPXPLastPrestigeWarn = 0
end

function Experience:NormalizePersistentState(row, persistent)
	row = istable(row) and row or {}
	if not persistent then return { xp = 0, level = 1, prestige = 0, tokens = 0, unlocked = {} } end
	return {
		xp = math.max(0, math.floor(tonumber(row.xp_points) or 0)),
		level = clampUInt(row.xp_level, 1, self.MaxLevel),
		prestige = clampUInt(row.xp_prestige, 0, self.MaxPrestige),
		tokens = clampUInt(row.xp_prestige_tokens, 0, self.MaxPrestige),
		unlocked = normalizeUnlockedValue(row.xp_prestige_items)
	}
end

function Experience:TotalToState(totalXP)
	totalXP = math.max(0, math.floor(tonumber(totalXP) or 0))
	local level = 1
	while level < self.MaxLevel and totalXP >= self:XPNeededForNext(level) do
		totalXP = totalXP - self:XPNeededForNext(level)
		level = level + 1
	end
	return level, totalXP
end

function Experience:TotalXPForPlayer(ply)
	if not self:EnsurePlayer(ply) then return 0 end
	return self:XPForLevel(ply:DRPXPLevel()) + ply:DRPXP()
end

function Experience:SetTotalXP(ply, totalXP, source, detail)
	if not self:EnsurePlayer(ply) or not ply:DRPReady() then return false, "Player not ready" end

	local currentLevel = ply:DRPXPLevel()
	local currentXP = ply:DRPXP()
	local nextLevel, nextXP = self:TotalToState(totalXP)
	ply.DRPXPLevelValue = nextLevel
	ply.DRPXPValue = nextXP
	self:QueueSave(ply)
	DRP.Net.SendProfile(ply)

	if nextLevel ~= currentLevel then
		DRP.Net.Notify(ply, "Your level changed to " .. nextLevel .. ".", 1)
	elseif nextXP ~= currentXP then
		DRP.Net.Notify(ply, "Your XP was updated to " .. nextXP .. ".", 1)
	end

	if detail then
		local previousTotal = self:XPForLevel(currentLevel) + currentXP
		local nextTotal = self:XPForLevel(nextLevel) + nextXP
		local reward = math.abs(math.floor(nextTotal - previousTotal))
		if reward > 0 then self:AddHistory(ply, reward, source or "admin", detail) end
	end

	return true
end

function Experience:AdjustTotalXP(ply, delta, source, detail)
	if not self:EnsurePlayer(ply) or not ply:DRPReady() then return false, "Player not ready" end

	local currentLevel = ply:DRPXPLevel()
	local currentXP = ply:DRPXP()
	local currentTotal = self:XPForLevel(currentLevel) + currentXP
	local nextTotal = currentTotal + math.floor(tonumber(delta) or 0)
	if nextTotal < 0 then nextTotal = 0 end

	local nextLevel, nextXP = self:TotalToState(nextTotal)
	ply.DRPXPLevelValue = nextLevel
	ply.DRPXPValue = nextXP
	self:QueueSave(ply)
	DRP.Net.SendProfile(ply)

	if nextLevel ~= currentLevel then
		DRP.Net.Notify(ply, "Your level changed to " .. nextLevel .. ".", 1)
	elseif nextXP ~= currentXP then
		DRP.Net.Notify(ply, "Your XP was updated to " .. nextXP .. ".", 1)
	end

	local reward = math.abs(math.floor(delta or 0))
	if detail and reward > 0 then self:AddHistory(ply, reward, source or "admin", detail) end
	return true
end

function Experience:LevelProgress(ply)
	if not self:EnsurePlayer(ply) then return 0, 0, 0, 0 end
	local level = ply:DRPXPLevel()
	local xp = ply:DRPXP()
	local needed = self:XPNeededForNext(level)
	if level >= self.MaxLevel then
		return level, xp, 0, 1
	end
	return level, xp, needed, math.Clamp(xp / math.max(1, needed), 0, 1)
end

function Experience:AddHistory(ply, amount, source, detail)
	if not self:EnsurePlayer(ply) then return end
	amount = math.max(0, math.floor(tonumber(amount) or 0))
	if amount <= 0 then return end
	if type(source) ~= "string" then source = "system" end
	if type(detail) ~= "string" then detail = "" end

	table.insert(ply.DRPXPHistory, 1, {
		amount = amount,
		source = string.sub(source, 1, 36),
		detail = string.sub(detail, 1, 140),
		time = os.time(),
		level = ply:DRPXPLevel(),
		prestige = ply:DRPXPPrestige()
	})
	while #ply.DRPXPHistory > self.HistoryLimit do table.remove(ply.DRPXPHistory) end
end

function Experience:QueueSave(ply)
	if not IsValid(ply) then return false end
	ply.DRPXPNeedsSave = true
	return true
end

function Experience:CanPrestige(ply)
	if not self:EnsurePlayer(ply) then return false end
	if ply:DRPXPLevel() < self.MaxLevel then return false end
	if ply:DRPXPPrestige() >= self.MaxPrestige then return false end
	return true
end

function Experience:IsMaxPrestige(ply)
	if not self:EnsurePlayer(ply) then return false end
	return ply:DRPXPPrestige() >= self.MaxPrestige and ply:DRPXPLevel() >= self.MaxLevel
end

function Experience:Prestige(ply)
	if not self:EnsurePlayer(ply) then return false, "Player not ready" end
	if self:IsMaxPrestige(ply) then return false, "You have already reached maximum prestige." end
	if not self:CanPrestige(ply) then return false, "Reach level 100 before entering the next prestige." end

	local previousPrestige = ply:DRPXPPrestige()
	ply.DRPXPLevelValue = 1
	ply.DRPXPValue = 0
	ply.DRPXPPrestigeValue = math.min(self.MaxPrestige, previousPrestige + 1)
	ply.DRPXPPrestigeTokensValue = ply:DRPXPPrestigeTokens() + 1
	self:QueueSave(ply)
	if DRP.Economy then DRP.Economy.SavePlayer(ply) end
	DRP.Net.SendProfile(ply)
	DRP.Net.Notify(ply, "Prestige " .. ply:DRPXPPrestige() .. " reached. You earned a Prestige Token.", 1)
	self:AddHistory(ply, 0, "prestige", "Prestige " .. ply:DRPXPPrestige())
	return true, "Prestige completed"
end

-- Existing callers can continue to use this as a boolean check for unlocked status.
function Experience:CanPayForItem(ply, kind, rawKey)
	if not self:EnsurePlayer(ply) then return false, nil end

	local key = sanitizeItem(rawKey)
	if not key and isstring(kind) and rawKey ~= nil then
		if kind == "prop" then
			key = sanitizeItem("prop:" .. string.Trim(tostring(rawKey)))
		elseif kind == "weapon" then
			key = sanitizeItem("weapon:" .. string.Trim(tostring(rawKey)))
		elseif kind == "job_entity" then
			key = sanitizeItem("job_entity:" .. string.Trim(tostring(rawKey)))
		end
	end
	if not key then return false, nil end
	return self:IsUnlockedKey(ply, key), key
end

function Experience:IsUnlockedKey(ply, key)
	if not self:EnsurePlayer(ply) then return false end
	return key ~= nil and ply.DRPXPUnlockedItemsValue[key] == true
end

function Experience:GrantLoadoutWeapons(ply)
	if not self:EnsurePlayer(ply) then return end
	for key in pairs(ply.DRPXPUnlockedItemsValue or {}) do
		local eligible, prepared = self:IsPrestigeWeapon(key)
		if eligible then
			local class = string.sub(prepared, 8)
			if not ply:HasWeapon(class) then ply:Give(class) end
		end
	end
end

function Experience:CanUnlockWithToken(ply, key)
	if not self:EnsurePlayer(ply) then return false, "not_ready", nil end
	if ply:DRPXPPrestigeTokens() <= 0 then return false, "No prestige tokens available", nil end
	local weaponOK
	weaponOK, key = self:IsPrestigeWeapon(key)
	if not weaponOK then return false, "Only individual player weapons can be permanently unlocked", nil end
	if ply.DRPXPUnlockedItemsValue[key] then return false, "Item already unlocked", nil end
	return true, "ok", key
end

function Experience:GrantUnlockedItem(ply, key)
	if not IsValid(ply) then return false, "Player missing" end
	local ok, reason, prepared = self:CanUnlockWithToken(ply, key)
	if not ok then return false, reason end
	ply.DRPXPPrestigeTokensValue = math.max(0, ply:DRPXPPrestigeTokens() - 1)
	ply.DRPXPUnlockedItemsValue = ply.DRPXPUnlockedItemsValue or {}
	ply.DRPXPUnlockedItemsValue[prepared] = true
	self:QueueSave(ply)
	-- A prestige token is a scarce permanent entitlement. Persist it as part
	-- of this event instead of waiting for a later disconnect or shutdown.
	if DRP.Economy then
		DRP.Economy.SavePlayer(ply, function(saved, reason)
			if IsValid(ply) and not saved then
				self:QueueSave(ply)
				DRP.Net.Notify(ply, "Permanent unlock is active, but its database save failed: " .. tostring(reason or "unknown error"), 3)
			end
		end)
	end
	self:AddHistory(ply, 0, "unlock", "Unlocked item " .. prepared)
	if DRP.Audit then DRP.Audit.Log(ply, "prestige_weapon_unlocked", nil, prepared) end
	DRP.Net.SendProfile(ply)
	DRP.Net.Notify(ply, "Permanently unlocked " .. string.sub(prepared, 8) .. " for free spawning.", 1)
	return true, "Weapon permanently unlocked"
end

function Experience:Add(ply, amount, source, detail, incidentAward)
	if not self:EnsurePlayer(ply) or (not incidentAward and not ply:DRPReady()) then return false end
	amount = clampUInt(amount, 0)
	if amount <= 0 then return false end
	amount = math.floor(amount * self.XPMultiplier)
	local ordinaryAmount = amount
	amount = DRP.Supporter and DRP.Supporter.ApplyReward(ply, amount) or amount
	if amount <= 0 then return false end
	if amount > ordinaryAmount and DRP.Audit then
		DRP.Audit.Log(ply, "supporter_xp_bonus", nil, tostring(source or "xp") .. " " .. ordinaryAmount .. " -> " .. amount)
	end

	local xp = ply:DRPXP() + amount
	local level = ply:DRPXPLevel()
	local originalLevel = level
	local needed = self:XPNeededForNext(level)

	while level < self.MaxLevel and xp >= needed do
		xp = xp - needed
		level = level + 1
		needed = self:XPNeededForNext(level)
	end

	ply.DRPXPValue = xp
	ply.DRPXPLevelValue = level
	self:QueueSave(ply)
	DRP.Net.SendProfile(ply)
	self:AddHistory(ply, amount, source, detail)

	if originalLevel ~= level then
		DRP.Net.Notify(ply, "Level up! You are now level " .. level .. ".", 1)
		if level >= self.MaxLevel and ply.DRPXPLastPrestigeWarn < CurTime() then
			if self:IsMaxPrestige(ply) then
				DRP.Net.Notify(ply, "Maximum Prestige reached.", 1)
			else
				DRP.Net.Notify(ply, "Level 100 reached. Enter the next Prestige to gain a token.", 0)
			end
			ply.DRPXPLastPrestigeWarn = CurTime() + self.LevelUpNoticeCooldown
		end
	end
	return true
end

function Experience:NextLevelUnlocks(level)
	level = clampUInt(level, 1, self.MaxLevel)
	local output = {}
	for _, entry in ipairs(self.UnlockTemplates) do
		if entry.level > level then
			output[#output + 1] = {
				level = entry.level,
				key = entry.key,
				name = string.sub(entry.name or entry.key, 1, 128)
			}
		end
	end
	table.sort(output, function(a, b)
		if a.level == b.level then return a.key < b.key end
		return a.level < b.level
	end)
	if #output > self.PreviewUnlockCount then
		for i = #output, self.PreviewUnlockCount + 1, -1 do
			table.remove(output, i)
		end
	end
	return output
end

function Experience:BuildSnapshot(ply)
	if not self:EnsurePlayer(ply) then return {} end
	local level, xp, needed, ratio = self:LevelProgress(ply)
	return {
		level = level,
		xp = xp,
		xp_to_next = needed,
		progress = ratio,
		next_rank = math.min(self.MaxLevel, level + 1),
		remaining = math.max(0, needed > 0 and needed - xp or 0),
		prestige = ply:DRPXPPrestige(),
		tokens = ply:DRPXPPrestigeTokens(),
		history = table.Copy(ply.DRPXPHistory or {}),
		next_unlocks = self:NextLevelUnlocks(level),
		unlockables = unlockCatalog(ply),
		unlocked = (function()
			local unlocked = {}
			for key in pairs(ply.DRPXPUnlockedItemsValue or {}) do unlocked[#unlocked + 1] = key end
			table.sort(unlocked)
			return unlocked
		end)(),
		can_prestige = self:CanPrestige(ply),
		maxed = self:IsMaxPrestige(ply),
		max_level = self.MaxLevel,
		max_prestige = self.MaxPrestige,
		version = self.XPVersion,
		sync = os.time()
	}
end

function Experience:SerializeUnlockedItems(ply)
	if not self:EnsurePlayer(ply) then return "[]" end
	return serializeUnlocked(ply.DRPXPUnlockedItemsValue or {})
end

function Experience:SendSnapshot(ply)
	if not IsValid(ply) then return end
	local snapshot = self:BuildSnapshot(ply)
	if not istable(snapshot) then snapshot = buildExperienceFallbackSnapshot(ply) end
	local payload = util.TableToJSON(snapshot or {}, false)
	net.Start(OVERVIEW)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(payload or "{}")
	net.Send(ply)
end

DRP.Net.Receive(REQUEST, function(_, ply)
		if not IsValid(ply) or net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
		if not DRP.Net.Allow(ply, "experience_overview", 0.5, 3) then return end
		DRP.Experience:SendSnapshot(ply)
	end)

DRP.Net.Receive(ACTION, function(_, ply)
	if not IsValid(ply) or net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not ply:DRPReady() then return end
	if not DRP.Net.Allow(ply, "experience_action", 0.6, 4) then return end
	if not DRP.Experience then return end

	local action = math.floor(net.ReadUInt(4))
	if action == 0 then
		local ok, message = DRP.Experience:Prestige(ply)
		if not ok then DRP.Net.Notify(ply, tostring(message), 3) end
		DRP.Experience:SendSnapshot(ply)
		return
	end
	if action == 1 then
		local key = string.sub(net.ReadString() or "", 1, 512)
		local ok, message = DRP.Experience:GrantUnlockedItem(ply, key)
		if not ok then DRP.Net.Notify(ply, tostring(message), 3) end
		DRP.Experience:SendSnapshot(ply)
		return
	end

	DRP.Net.Notify(ply, "Unknown experience action.", 3)
end)
