local Permissions = {
	DataPath = "darkrp/civic_item_permissions.json",
	ThresholdOverrides = {},
	DynamicCrates = {},
	DynamicCrateWeapons = {},
	MobBossCrates = {},
	DefaultMobBossCrates = {
		pistol_crate = true,
		smg_crate = true
	}
}

DRP.CivicPermissions = Permissions
DRP.Services.Register("civic_permissions", Permissions)

local SNAPSHOT = "drp_civic_item_permissions_v1"
local REQUEST = "drp_civic_item_permissions_request_v1"
local UPDATE = "drp_civic_item_permissions_update_v1"
util.AddNetworkString(SNAPSHOT)
util.AddNetworkString(REQUEST)
util.AddNetworkString(UPDATE)

local function cleanKey(value)
	value = string.lower(string.Trim(string.sub(tostring(value or ""), 1, 64)))
	if value == "" or not string.match(value, "^[%w_%-]+$") then return nil end
	return value
end

local function isHeadAdmin(ply)
	return IsValid(ply)
		and DRP.Admin
		and DRP.AdminRankLevel(DRP.Admin.RankKey(ply)) >= DRP.AdminRankLevel("headadmin")
end

function Permissions:Definition(value)
	local key = cleanKey(istable(value) and value.key or value)
	return key and DRP.JobEntityService and DRP.JobEntityService.ByKey[key] or nil
end

function Permissions:IsWeaponCrate(definition)
	return istable(definition) and definition.class == "drp_weapon_crate" and isstring(definition.weapon)
end

function Permissions:IsAssignableWeapon(class)
	class = string.lower(string.Trim(string.sub(tostring(class or ""), 1, 96)))
	if class == "" then return false, nil end
	-- The armory catalog already excludes bases, tools, police equipment and
	-- other system SWEPs. Reuse it as the crate allowlist instead of trusting a
	-- class supplied by the client.
	local entry = DRP.Armory and DRP.Armory.ByClass and DRP.Armory.ByClass[class]
	return entry ~= nil, entry and class or nil
end

function Permissions:DynamicCrateKey(class)
	class = string.lower(string.Trim(tostring(class or "")))
	if class == "" then return nil end
	return "weapon_crate_" .. util.CRC(class)
end

function Permissions:BuildDynamicCrate(class)
	local valid, normalized = self:IsAssignableWeapon(class)
	if not valid then return nil end
	local entry = DRP.Armory.ByClass[normalized]
	local key = self:DynamicCrateKey(normalized)
	if not key then return nil end
	return {
		key = key,
		name = entry.name .. " Case",
		class = "drp_weapon_crate",
		model = DRP.WeaponCaseModel,
		job = "gun_dealer",
		price = math.Clamp(math.floor((entry.price or 750) * 5), 1250, 50000),
		weapon = normalized,
		count = 5,
		category = "Gun Dealer",
		dynamicCrate = true
	}
end

function Permissions:RegisterDynamicCrate(class)
	local definition = self:BuildDynamicCrate(class)
	if not definition then return nil end
	local existing = DRP.JobEntityService.ByKey[definition.key]
	if existing and existing.weapon ~= definition.weapon then
		ErrorNoHalt("[DRP] dynamic weapon-crate key collision: " .. definition.key .. "\n")
		return nil
	end
	self.DynamicCrates[definition.key] = definition
	self.DynamicCrateWeapons[definition.weapon] = definition
	DRP.JobEntityService.ByKey[definition.key] = definition
	return definition
end

function Permissions:UnregisterDynamicCrate(class)
	class = string.lower(string.Trim(tostring(class or "")))
	local definition = self.DynamicCrateWeapons[class]
	if not definition then return false end
	self.DynamicCrateWeapons[class] = nil
	self.DynamicCrates[definition.key] = nil
	if DRP.JobEntityService.ByKey[definition.key] == definition then DRP.JobEntityService.ByKey[definition.key] = nil end
	self.MobBossCrates[definition.key] = nil
	return true
end

function Permissions:DynamicCrateForWeapon(class)
	return self.DynamicCrateWeapons[string.lower(string.Trim(tostring(class or "")))]
end

function Permissions:IsProtected(definition)
	return istable(definition) and (definition.ownerOnly == true or definition.police == true)
end

function Permissions:DefaultThreshold(definition)
	if not istable(definition) or self:IsProtected(definition) or self:IsWeaponCrate(definition) then return nil end
	if definition.job == "drug_dealer" then return DRP.CivicCapabilityThresholds.canSpawnDrugs end
	if definition.job == "kidnapper" then return DRP.CivicCapabilityThresholds.canKidnap end
	return nil
end

function Permissions:EffectiveThreshold(definition)
	if not istable(definition) then return nil, false end
	local override = self.ThresholdOverrides[definition.key]
	if override == false then return nil, true end
	if isnumber(override) then return math.Clamp(math.floor(override), -1000, 1000), true end
	return self:DefaultThreshold(definition), false
end

function Permissions:MobBossCanSpawnCrate(definition)
	if not self:IsWeaponCrate(definition) then return false end
	return self.MobBossCrates[definition.key] == true
end

function Permissions:RoleCanSpawnCrate(jobKey, definition)
	if not self:IsWeaponCrate(definition) then return false end
	jobKey = string.lower(tostring(jobKey or ""))
	if jobKey == "gun_dealer" then return true end
	return jobKey == "mob_boss" and self:MobBossCanSpawnCrate(definition)
end

function Permissions:CanSpawn(ply, definition)
	if not IsValid(ply) or not ply:IsPlayer() or not istable(definition) then return false end
	local job = ply:DRPJob()
	local derived = DRP.Roles and DRP.Roles.DerivedJob and DRP.Roles:DerivedJob(ply) or nil
	local derivedJob = derived and DRP.Jobs and DRP.Jobs[derived] or nil
	local effectiveJobKey = (derivedJob and derivedJob.key) or job.key

	-- World infrastructure remains owner-controlled and cannot be opened by a
	-- civic threshold or the criminal hierarchy.
	if definition.ownerOnly then return DRP.Admin and DRP.Admin.IsOwner(ply) end
	if definition.police then return job.isPolice == true end
	-- The client exposes the complete job-entity catalogue to Admin+. Mirror
	-- that rank check here instead of depending on the configurable panel bit;
	-- otherwise an Admin can see and click a crate/drug while the server silently
	-- rejects the same request because their panel permission was customised.
	if DRP.Admin
		and DRP.AdminRankLevel(DRP.Admin.RankKey(ply)) >= DRP.AdminRankLevel("admin") then
		return true
	end
	-- Explicitly public utility entities are independent of civic/job identity.
	if definition.public == true then return true end

	if self:IsWeaponCrate(definition) then
		return self:RoleCanSpawnCrate(effectiveJobKey, definition)
	end

	-- Mob Boss inherits every non-government criminal item permission.
	if effectiveJobKey == "mob_boss" then return true end
	if definition.job and effectiveJobKey == definition.job then return true end

	local threshold = self:EffectiveThreshold(definition)
	return isnumber(threshold) and not job.isGovernment and DRP.Civic and DRP.Civic:Get(ply) <= threshold
end

function Permissions:BuildSnapshot()
	local items = {}
	for _, definition in ipairs(DRP.JobEntities or {}) do
		local threshold, overridden = self:EffectiveThreshold(definition)
		items[definition.key] = {
			threshold = threshold,
			thresholdEnabled = isnumber(threshold),
			overridden = overridden,
			protected = self:IsProtected(definition),
			crate = self:IsWeaponCrate(definition),
			mobBossAllowed = self:MobBossCanSpawnCrate(definition),
			weapon = self:IsWeaponCrate(definition) and string.lower(definition.weapon) or nil,
			weaponName = self:IsWeaponCrate(definition) and ((DRP.Armory.ByClass[string.lower(definition.weapon)] or {}).name or definition.weapon) or nil
		}
	end
	local dynamicCrates = {}
	for _, definition in pairs(self.DynamicCrates) do
		local threshold, overridden = self:EffectiveThreshold(definition)
		items[definition.key] = {
			threshold = threshold,
			thresholdEnabled = isnumber(threshold),
			overridden = overridden,
			protected = false,
			crate = true,
			mobBossAllowed = self:MobBossCanSpawnCrate(definition),
			weapon = definition.weapon,
			weaponName = (DRP.Armory.ByClass[definition.weapon] or {}).name or definition.weapon,
			dynamic = true
		}
		dynamicCrates[#dynamicCrates + 1] = table.Copy(definition)
	end
	table.sort(dynamicCrates, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
	return { items = items, dynamicCrates = dynamicCrates }
end

function Permissions:SendSnapshot(ply)
	local payload = util.Compress(util.TableToJSON(self:BuildSnapshot(), false) or "{}") or ""
	net.Start(SNAPSHOT)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.min(#payload, 65535), 16)
	net.WriteData(payload, math.min(#payload, 65535))
	if IsValid(ply) then net.Send(ply) else net.Broadcast() end
	if DRP.Net then DRP.Net.Record(#payload + 3) end
end

function Permissions:Save()
	file.CreateDir("darkrp")
	local weaponCrates = {}
	for class in pairs(self.DynamicCrateWeapons) do weaponCrates[class] = true end
	file.Write(self.DataPath, util.TableToJSON({
		thresholds = self.ThresholdOverrides,
		weaponCrates = weaponCrates,
		mobBossCrates = self.MobBossCrates
	}, true) or "{}")
end

function Permissions:Load()
	self.ThresholdOverrides = {}
	local previous = {}
	for class in pairs(self.DynamicCrateWeapons) do previous[#previous + 1] = class end
	for _, class in ipairs(previous) do self:UnregisterDynamicCrate(class) end
	self.DynamicCrates = {}
	self.DynamicCrateWeapons = {}
	self.MobBossCrates = table.Copy(self.DefaultMobBossCrates)
	local decoded = util.JSONToTable(file.Read(self.DataPath, "DATA") or "")
	if not istable(decoded) then return end
	for rawKey, rawValue in pairs(istable(decoded.thresholds) and decoded.thresholds or {}) do
		local key, definition = cleanKey(rawKey)
		definition = key and self:Definition(key)
		if definition and not self:IsProtected(definition) and not self:IsWeaponCrate(definition) then
			if rawValue == false then
				self.ThresholdOverrides[key] = false
			elseif tonumber(rawValue) then
				self.ThresholdOverrides[key] = math.Clamp(math.floor(tonumber(rawValue)), -1000, 1000)
			end
		end
	end
	for rawClass, enabled in pairs(istable(decoded.weaponCrates) and decoded.weaponCrates or {}) do
		if enabled == true then self:RegisterDynamicCrate(rawClass) end
	end
	for rawKey, rawValue in pairs(istable(decoded.mobBossCrates) and decoded.mobBossCrates or {}) do
		local key, definition = cleanKey(rawKey)
		definition = key and self:Definition(key)
		if self:IsWeaponCrate(definition) then self.MobBossCrates[key] = rawValue == true end
	end
end

function Permissions:SetWeaponCrate(ply, class, enabled)
	if not isHeadAdmin(ply) then return false end
	local valid, normalized = self:IsAssignableWeapon(class)
	if not valid then return false end
	local definition
	if enabled then
		if self.DynamicCrateWeapons[normalized] then return false end
		definition = self:RegisterDynamicCrate(normalized)
		if not definition then return false end
	else
		definition = self.DynamicCrateWeapons[normalized]
		if not definition or not self:UnregisterDynamicCrate(normalized) then return false end
	end
	self:Save()
	self:SendSnapshot()
	if DRP.Audit then DRP.Audit.Log(ply, enabled and "weapon_crate_created" or "weapon_crate_removed", nil, normalized) end
	return true, definition
end

function Permissions:SetThreshold(ply, key, enabled, value)
	local definition = self:Definition(key)
	if not isHeadAdmin(ply) or not definition or self:IsProtected(definition) or self:IsWeaponCrate(definition) then return false end
	self.ThresholdOverrides[definition.key] = enabled and math.Clamp(math.floor(tonumber(value) or 0), -1000, 1000) or false
	self:Save()
	self:SendSnapshot()
	if DRP.Audit then
		local detail = enabled and ("civic <= " .. self.ThresholdOverrides[definition.key]) or "role identity only"
		DRP.Audit.Log(ply, "civic_item_permission_set", nil, definition.key .. " " .. detail)
	end
	return true
end

function Permissions:SetMobBossCrate(ply, key, allowed)
	local definition = self:Definition(key)
	if not isHeadAdmin(ply) or not self:IsWeaponCrate(definition) then return false end
	self.MobBossCrates[definition.key] = allowed == true
	self:Save()
	self:SendSnapshot()
	if DRP.Audit then DRP.Audit.Log(ply, "mob_boss_crate_permission_set", nil, definition.key .. " " .. tostring(allowed == true)) end
	return true
end

function Permissions:ResetThreshold(ply, key)
	local definition = self:Definition(key)
	if not isHeadAdmin(ply) or not definition or self:IsProtected(definition) or self:IsWeaponCrate(definition) then return false end
	self.ThresholdOverrides[definition.key] = nil
	self:Save()
	self:SendSnapshot()
	if DRP.Audit then DRP.Audit.Log(ply, "civic_item_permission_reset", nil, definition.key) end
	return true
end

function Permissions:Start()
	self:Load()
end

function Permissions:Stop()
	self:Save()
end

DRP.Net.Receive(REQUEST, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "civic_item_permissions_request", 1, 2) then return end
	Permissions:SendSnapshot(ply)
end)

DRP.Net.Receive(UPDATE, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "civic_item_permissions_update", 0.3, 4) then return end
	local action = net.ReadUInt(2)
	local key = cleanKey(net.ReadString())
	if not key then return end
	if action == 0 then
		local class, enabled = net.ReadString(), net.ReadBool()
		local changed, definition = Permissions:SetWeaponCrate(ply, class, enabled)
		if changed then
			DRP.Net.Notify(ply, definition.name .. (enabled and " created." or " removed."), 1)
		end
	elseif action == 1 then
		local enabled = net.ReadBool()
		local value = enabled and net.ReadInt(12) or 0
		if Permissions:SetThreshold(ply, key, enabled, value) then
			local definition = Permissions:Definition(key)
			DRP.Net.Notify(ply, definition.name .. " civic access updated.", 1)
		end
	elseif action == 2 then
		local allowed = net.ReadBool()
		if Permissions:SetMobBossCrate(ply, key, allowed) then
			local definition = Permissions:Definition(key)
			DRP.Net.Notify(ply, "Mob Boss crate access " .. (allowed and "enabled for " or "disabled for ") .. definition.name .. ".", 1)
		end
	elseif action == 3 and Permissions:ResetThreshold(ply, key) then
		local definition = Permissions:Definition(key)
		DRP.Net.Notify(ply, definition.name .. " restored to its default civic policy.", 1)
	end
end)

hook.Add("DRPPlayerReady", "DRP.CivicPermissions.Sync", function(ply)
	Permissions:SendSnapshot(ply)
end)
