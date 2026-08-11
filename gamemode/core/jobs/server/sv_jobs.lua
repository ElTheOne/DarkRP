local Jobs = {
	Counts = {},
	LoadoutCache = {},
	WeaponDefinitions = {},
	PrecachedModels = {},
	ValidationIssues = {},
	ValidationIssueSet = {},
	ApplyStageDelay = math.max(engine.TickInterval(), 0.01),
	CacheReady = false,
	UtilityGrantFailures = {}
}

DRP.JobService = Jobs
DRP.Services.Register("jobs", Jobs)

local commonWeapons = {
	"weapon_drp_keys",
	"weapon_drp_pocket",
	"weapon_physgun",
	"weapon_physcannon",
	"gmod_tool",
	"ephone"
}

-- Native Source weapons are implemented by the engine and therefore are not
-- guaranteed to appear in weapons.GetStored(), which only describes scripted
-- SWEP definitions.  Treating a missing scripted definition as proof that one
-- of these classes was unavailable produced false startup failures and removed
-- the weapon from the cached job loadout.
local nativeWeaponClasses = {
	weapon_physgun = true,
	weapon_physcannon = true,
	weapon_crowbar = true,
	weapon_stunstick = true,
	weapon_bugbait = true
}

local universalUtilityWeapons = {
	"weapon_drp_keys",
	"weapon_drp_pocket",
	"weapon_physgun",
	"weapon_physcannon",
	"gmod_tool",
	"ephone"
}

local universalUtilitySet = {
	weapon_drp_keys = true,
	weapon_drp_pocket = true,
	weapon_physgun = true,
	weapon_physcannon = true,
	gmod_tool = true,
	-- Universally selectable from the Q-menu, but deliberately not part of
	-- universalUtilityWeapons: players opt into the medical pathway instead
	-- of spawning with a medkit every life.
	weapon_medkit = true,
	-- Phones are available to every role and can also be re-equipped from the
	-- Weapons page if another system strips the player's loadout.
	ephone = true,
	weapon_drp_creator = true
}

local ownerUtilitySet = {
	weapon_drp_persistence_tool = true
}

local roleSelectableWeaponSet = {
	weapon_drp_medkit = "canHeal",
	weapon_drp_defibrillator = "canHeal",
	weapon_drp_kidnap_baton = "canKidnap",
	weapon_drp_blindfold = "canKidnap",
	weapon_drp_gag = "canKidnap",
	weapon_drp_police_tablet = "canUsePoliceOperationsTablet",
	weapon_drp_mayor_tablet = "canUsePoliceTablet"
}

local botUtilityWeapons = {
	weapon_drp_keys = true,
	weapon_drp_pocket = true,
	weapon_physgun = true,
	weapon_physcannon = true,
	gmod_tool = true
}

local function validationIssue(message)
	if Jobs.ValidationIssueSet[message] then return end
	Jobs.ValidationIssueSet[message] = true
	Jobs.ValidationIssues[#Jobs.ValidationIssues + 1] = message
end

local function normalizedClass(value)
	local class = string.lower(string.Trim(tostring(value or "")))
	if class == "" or not string.match(class, "^[%w_]+$") then return nil end
	return class
end

local function precacheModel(model)
	model = string.Trim(tostring(model or ""))
	if model == "" or not string.match(string.lower(model), "%.mdl$") or Jobs.PrecachedModels[model] then return false end
	Jobs.PrecachedModels[model] = true
	local ok, failure = pcall(util.PrecacheModel, model)
	if not ok then
		validationIssue("model precache failed " .. model .. ": " .. tostring(failure))
		return false
	end
	return true
end

local function precacheDefinitionModels(definition, visited, depth)
	if not istable(definition) or depth > 4 or visited[definition] then return end
	visited[definition] = true
	for _, value in pairs(definition) do
		if isstring(value) then
			precacheModel(value)
		elseif istable(value) then
			precacheDefinitionModels(value, visited, depth + 1)
		end
	end
	local base = normalizedClass(definition.Base)
	if base then precacheDefinitionModels(weapons.GetStored(base), visited, depth + 1) end
end

local function resolveWeapon(class)
	class = normalizedClass(class)
	if not class then return nil end
	local cached = Jobs.WeaponDefinitions[class]
	if cached ~= nil then return cached ~= false and class or nil end
	local definition = weapons.GetStored(class)
	Jobs.WeaponDefinitions[class] = definition or false
	if not definition then return nil end
	precacheDefinitionModels(definition, {}, 0)
	return class
end

function Jobs:EnsureSandboxWeapons()
	if DRP.Toolgun and isfunction(DRP.Toolgun.RegisterBundledTools) then
		DRP.Toolgun.RegisterBundledTools()
	end
	local storedToolgun = weapons.GetStored("gmod_tool")
	local toolgunReady = storedToolgun ~= nil and istable(storedToolgun.Tool) and table.Count(storedToolgun.Tool) > 0
	if not toolgunReady then
		validationIssue("missing inherited Sandbox gmod_tool or registered stool modes")
	end
	return toolgunReady
end

function Jobs.IsUtilityWeapon(class)
	class = string.lower(string.Trim(tostring(class or "")))
	return universalUtilitySet[class] == true or ownerUtilitySet[class] == true or roleSelectableWeaponSet[class] ~= nil
end

function Jobs.CanUseUtilityWeapon(ply, class)
	if not IsValid(ply) or not ply:IsPlayer() then return false end
	class = string.lower(string.Trim(tostring(class or "")))
	if universalUtilitySet[class] then return true end
	if ownerUtilitySet[class] then return DRP.Admin and DRP.Admin.IsOwner(ply) == true end
	local requiredCapability = roleSelectableWeaponSet[class]
	return requiredCapability ~= nil and ply:DRPHasRoleCapability(requiredCapability) == true
end

function Jobs.GiveUtilityWeapon(ply, class, selectAfter)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return false end
	class = string.lower(string.Trim(tostring(class or "")))
	if not Jobs.CanUseUtilityWeapon(ply, class) then return false end
	local stored = class == "gmod_tool" and weapons.GetStored(class) or nil
	if class == "gmod_tool" and (not stored or not istable(stored.Tool) or table.Count(stored.Tool) == 0) then
		Jobs:EnsureSandboxWeapons()
		stored = weapons.GetStored(class)
	end
	if class == "gmod_tool" and (not stored or not istable(stored.Tool) or table.Count(stored.Tool) == 0) then
		if not Jobs.UtilityGrantFailures[class] then
			Jobs.UtilityGrantFailures[class] = true
			ErrorNoHalt("[DRP JOBS] cannot grant unregistered universal weapon " .. class .. "\n")
		end
		return false
	end
	if not ply:HasWeapon(class) then
		local ok, weapon = pcall(ply.Give, ply, class, true)
		if not ok or not IsValid(weapon) then
			if not ply:HasWeapon(class) and not Jobs.UtilityGrantFailures[class] then
				Jobs.UtilityGrantFailures[class] = true
				ErrorNoHalt("[DRP JOBS] Player:Give failed for universal weapon " .. class .. "\n")
			end
		end
	end
	if not ply:HasWeapon(class) then return false end
	Jobs.UtilityGrantFailures[class] = nil
	if selectAfter then ply:SelectWeapon(class) end
	return true
end

function Jobs:BuildLoadoutCache()
	self.LoadoutCache = {}
	self.WeaponDefinitions = {}
	self.PrecachedModels = {}
	self.ValidationIssues = {}
	self.ValidationIssueSet = {}

	for id, job in ipairs(DRP.Jobs) do
		local model = string.Trim(tostring(job.model or ""))
		if model == "" or not util.IsValidModel(model) then
			validationIssue(string.format("job %s has invalid player model %s", job.key, model))
			model = "models/player/Group01/male_07.mdl"
		end
		precacheModel(model)
		if player_manager and player_manager.TranslatePlayerHands then
			local hands = player_manager.TranslatePlayerHands(model)
			if istable(hands) then precacheModel(hands.model) end
		end

		local giveWeapons, weaponSet = {}, {}
		local function addWeapon(rawClass, source)
			local class = normalizedClass(rawClass)
			if not class or weaponSet[class] then return end
			if not nativeWeaponClasses[class] and not resolveWeapon(class) then
				if source == "common" then
					validationIssue(string.format("missing common weapon %s", tostring(rawClass)))
				else
					validationIssue(string.format("job %s missing loadout weapon %s", job.key, tostring(rawClass)))
				end
				return
			end
			weaponSet[class] = true
			giveWeapons[#giveWeapons + 1] = class
		end
		for index = 1, #(job.weapons or {}) do addWeapon(job.weapons[index], "loadout") end
		for index = 1, #commonWeapons do addWeapon(commonWeapons[index], "common") end

		self.LoadoutCache[id] = {
			id = id,
			key = job.key,
			model = model,
			weapons = giveWeapons,
			weaponSet = weaponSet
		}
	end

	self.CacheReady = true
	print(string.format("[DRP JOBS] cached %d jobs, %d weapon definitions and %d models",
		#DRP.Jobs, table.Count(self.WeaponDefinitions), table.Count(self.PrecachedModels)))
	for _, issue in ipairs(self.ValidationIssues) do ErrorNoHalt("[DRP JOBS] " .. issue .. "\n") end
	return #self.ValidationIssues == 0
end

function Jobs.GetCachedLoadout(id)
	if not Jobs.CacheReady then Jobs:BuildLoadoutCache() end
	return Jobs.LoadoutCache[id] or Jobs.LoadoutCache[DRP.Job.CITIZEN]
end

function Jobs.GiveUtilityWeapons(ply)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return false end
	local complete = true
	for index = 1, #universalUtilityWeapons do
		local class = universalUtilityWeapons[index]
		if not Jobs.GiveUtilityWeapon(ply, class, false) then complete = false end
	end
	return complete
end

function Jobs.SelectBotTestWeapon(ply)
	if not IsValid(ply) or not ply:IsBot() or not ply:Alive() then return false end
	local cached = Jobs.GetCachedLoadout(ply:DRPJobID())
	for index = 1, #cached.weapons do
		local class = cached.weapons[index]
		if not botUtilityWeapons[class] and ply:HasWeapon(class) then
			ply:SelectWeapon(class)
			return true
		end
	end
	return false
end

local function validApplyStage(ply, id, generation)
	return IsValid(ply) and ply:Alive() and ply.DRPJobApplyGeneration == generation and ply:DRPJobID() == id
end

function Jobs.QueueAppearanceUpdate(ply, id)
	if not IsValid(ply) then return end
	ply.DRPJobApplyGeneration = (ply.DRPJobApplyGeneration or 0) + 1
	local generation = ply.DRPJobApplyGeneration

	-- Each delayed stage executes no sooner than the next server frame and
	-- rechecks the generation so a newer job change cancels stale work.
	timer.Simple(Jobs.ApplyStageDelay, function()
		if not validApplyStage(ply, id, generation) then return end
		local phase = DRP.Profile.Begin()
		GAMEMODE:PlayerSetModel(ply)
		DRP.Profile.Finish("jobs.model", phase)

		timer.Simple(Jobs.ApplyStageDelay, function()
			if not validApplyStage(ply, id, generation) then return end
			phase = DRP.Profile.Begin()
			GAMEMODE:PlayerLoadout(ply)
			if ply:IsBot() then Jobs.SelectBotTestWeapon(ply) end
			DRP.Profile.Finish("jobs.loadout", phase)

			timer.Simple(Jobs.ApplyStageDelay, function()
				if not validApplyStage(ply, id, generation) then return end
				phase = DRP.Profile.Begin()
				ply:SetupHands()
				DRP.Profile.Finish("jobs.hands", phase)
			end)
		end)
	end)
end

function Jobs.Resolve(value)
	if isnumber(value) and DRP.Jobs[value] then return value end
	local normalized = string.lower(string.Trim(tostring(value or "")))
	local byKey = DRP.JobByKey[normalized]
	if byKey then return byKey end
	for id, job in ipairs(DRP.Jobs) do
		if string.lower(job.name) == normalized then return id end
	end
end

function Jobs.CanJoin(ply, id)
	local job = DRP.Jobs[id]
	if not job then return false, "Unknown job." end
	if ply:DRPJobID() == id then return false, "You already have that job." end
	if id == DRP.Job.CITIZEN and ply:DRPJob().isGovernment then return true end
	if id == DRP.Job.MAYOR then return false, "Mayor is selected through an election. Use /mayor to apply." end
	if not job.manualSelectable then
		return false, job.name .. " is an earned identity. Civic standing and demonstrated behavior assign it automatically."
	end
	if job.civicMinimum and DRP.Civic and DRP.Civic:Get(ply) < job.civicMinimum then
		return false, job.name .. " requires at least +" .. job.civicMinimum .. " civic standing."
	end
	if job.limit > 0 and (Jobs.Counts[id] or 0) >= job.limit then return false, job.name .. " is full." end
	return true
end

function Jobs.Set(ply, id, initial)
	if not IsValid(ply) or not DRP.Jobs[id] then return false end
	local started = DRP.Profile.Begin()
	local previous = ply.DRPJobValue
	if previous == id then DRP.Profile.Finish("jobs.set", started) return true end
	if id == DRP.Job.MOB_BOSS then
		if not DRP.Civic or DRP.Civic:Get(ply) > DRP.Civic.Minimum then
			DRP.Profile.Finish("jobs.set", started)
			return false
		end
		for _, candidate in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do
			if candidate ~= ply and IsValid(candidate) and candidate:DRPJobID() == DRP.Job.MOB_BOSS then
				DRP.Profile.Finish("jobs.set", started)
				return false
			end
		end
	end

	if previous then Jobs.Counts[previous] = math.max(0, (Jobs.Counts[previous] or 1) - 1) end
	ply.DRPJobValue = id
	Jobs.Counts[id] = (Jobs.Counts[id] or 0) + 1
	ply:SetTeam(id)
	local phase = DRP.Profile.Begin()
	hook.Run("DRPJobChanged", ply, previous, id, initial == true)
	DRP.Profile.Finish("jobs.hooks", phase)
	if not initial then ply.DRPJobNameValue = "" end
	phase = DRP.Profile.Begin()
	if DRP.Roster and ply:DRPReady() then DRP.Roster:Update(ply, DRP.Roster.Field.JOB) end
	DRP.Profile.Finish("jobs.roster", phase)
	if DRP.Audit then DRP.Audit.Log(ply, initial and "job_initialized" or "job_changed", nil, DRP.Jobs[id].key) end

	phase = DRP.Profile.Begin()
	if ply:DRPReady() then DRP.Net.SendProfile(ply) end
	DRP.Profile.Finish("jobs.profile_sync", phase)
	if not initial and ply:Alive() then
		Jobs.QueueAppearanceUpdate(ply, id)
	end
	if not initial and DRP.Economy then DRP.Economy.QueueSave(ply) end
	DRP.Profile.Finish("jobs.set", started)
	return true
end

function Jobs.RemovePlayer(ply)
	local id = ply.DRPJobValue
	if id then Jobs.Counts[id] = math.max(0, (Jobs.Counts[id] or 1) - 1) end
	ply.DRPJobApplyGeneration = (ply.DRPJobApplyGeneration or 0) + 1
end

function Jobs:Start()
	self:EnsureSandboxWeapons()
	self:BuildLoadoutCache()
end

function Jobs:Stop()
	self.CacheReady = false
end

hook.Add("PlayerSpawn", "DRP.Jobs.BotTestLoadout", function(ply)
	-- Apply this after the engine and addon PlayerSpawn chain so a late loadout
	-- hook cannot silently remove the two universal building weapons.
	for _, delay in ipairs({ Jobs.ApplyStageDelay, 0.25, 1 }) do
		timer.Simple(delay, function()
			if not IsValid(ply) or not ply:Alive() then return end
			local hadNoWeapons = #ply:GetWeapons() == 0
			Jobs.GiveUtilityWeapons(ply)
			if ply:IsBot() then
				if hadNoWeapons then GAMEMODE:PlayerLoadout(ply) end
				Jobs.SelectBotTestWeapon(ply)
			end
		end)
	end
end)

-- Government transitions are staged to avoid a job-change hitch. Guarantee
-- the role-specific tablet at the end of that transition even if an older
-- loadout cache existed before the SWEP was registered.
hook.Add("DRPJobChanged", "DRP.Jobs.RoleTablets", function(ply)
	for _, delay in ipairs({ Jobs.ApplyStageDelay * 4, 0.5, 1 }) do
		timer.Simple(delay, function()
			if not IsValid(ply) or not ply:Alive() then return end
			local current = ply:DRPJobID()
			if current == DRP.Job.MAYOR then
				if ply:HasWeapon("weapon_drp_police_tablet") then ply:StripWeapon("weapon_drp_police_tablet") end
				if not ply:HasWeapon("weapon_drp_mayor_tablet") then
					local weapon = ply:Give("weapon_drp_mayor_tablet")
					if not IsValid(weapon) then
						ErrorNoHalt("[DRP JOBS] failed to grant registered Mayor tablet\n")
					end
				end
			elseif current == DRP.Job.POLICE then
				if ply:HasWeapon("weapon_drp_mayor_tablet") then ply:StripWeapon("weapon_drp_mayor_tablet") end
				if not ply:HasWeapon("weapon_drp_police_tablet") then
					local weapon = ply:Give("weapon_drp_police_tablet")
					if not IsValid(weapon) then
						ErrorNoHalt("[DRP JOBS] failed to grant registered Police tablet\n")
					end
				end
			else
				if ply:HasWeapon("weapon_drp_mayor_tablet") then ply:StripWeapon("weapon_drp_mayor_tablet") end
				if ply:HasWeapon("weapon_drp_police_tablet") then ply:StripWeapon("weapon_drp_police_tablet") end
			end
		end)
	end
end)

concommand.Add("drp_toolgun_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	Jobs:EnsureSandboxWeapons()
	local stored = weapons.GetStored("gmod_tool")
	local toolCount = istable(stored and stored.Tool) and table.Count(stored.Tool) or 0
	local precisionReady = istable(stored and stored.Tool) and istable(stored.Tool.precision)
	local stackerReady = istable(stored and stored.Tool) and istable(stored.Tool.stacker_improved)
	local routeReady = istable(stored and stored.Tool) and istable(stored.Tool.drp_police_route)
	local precisionAction = precisionReady and isfunction(stored.Tool.precision.LeftClick)
	local stackerAction = stackerReady and isfunction(stored.Tool.stacker_improved.LeftClick)
	local routeAction = routeReady and isfunction(stored.Tool.drp_police_route.LeftClick)
	local precisionVersion = precisionReady and stored.Tool.precision.DRPBundledVersion or "missing"
	local stackerVersion = stackerReady and stored.Tool.stacker_improved.DRPBundledVersion or "missing"
	local target = IsValid(ply) and ply or nil
	print(string.format(
		"[DRP TOOLGUN] build=%s registered=%s tools=%d police_route=%s/%s precision=%s/%s/%s stacker_improved=%s/%s/%s physgun=%s%s",
		tostring(DRP.Toolgun and DRP.Toolgun.Build or "unknown"),
		tostring(stored ~= nil),
		toolCount,
		tostring(routeReady),
		tostring(routeAction),
		tostring(precisionReady),
		tostring(precisionAction),
		tostring(precisionVersion),
		tostring(stackerReady),
		tostring(stackerAction),
		tostring(stackerVersion),
		"engine",
		IsValid(target) and (" player_has_toolgun=" .. tostring(target:HasWeapon("gmod_tool"))
			.. " player_has_physgun=" .. tostring(target:HasWeapon("weapon_physgun"))) or ""
	))
end)
