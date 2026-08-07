local Startup = {}
DRP.Startup = Startup
DRP.Services.Register("startup", Startup)

local required = {
	{ name = "supporter", methods = { "Tier", "RewardMultiplier", "EntityBonus", "PropertyLimit", "ApplyReward", "ApplyRollCount" } },
	{ name = "arc9", methods = { "Start", "IsLoaded", "IsWeaponPackLoaded", "WeaponCount", "RegisterClientContent" } },
	{ name = "players", methods = { "Start" } },
	{ name = "calendar", methods = { "Start", "Stop", "Now", "Send", "Format", "SyncDayNight" } },
	{ name = "storage", methods = { "LoadPlayer", "SavePlayer", "LoadWorldState", "SaveWorldState", "LoadCrafting", "SaveCrafting" } },
	{ name = "network", methods = { "Receive", "Allow", "SendProfile", "Record" } },
	{ name = "props", methods = { "TrustEntityLimit", "OwnedEntityCount", "CanCreateOwnedEntity", "TrackOwnedEntity", "SpawnPurchased" } },
	{ name = "arcade", methods = { "LoadConfig", "Catalog", "SendOpen", "StartSession", "EndSession", "RelayFrame", "ApplyCommand", "ApplyMove", "Status" } },
	{ name = "roster", methods = { "Build", "Update", "SendSnapshot", "Remove" } },
	{ name = "trust", methods = { "ScoreSignals", "Evaluate", "LoadPlayer", "Apply", "SendSelf", "BeginDiscordLink", "VerifyDiscordLink", "CheckExistingDiscordRole", "StartDiscordRoleDeadline", "ClearDiscordRoleDeadline", "UnlinkDiscord" } },
	{ name = "loading", methods = { "RegisterCurrentMap", "ConfigureURL", "Publish", "SendProfile" } },
	{ name = "voice", methods = { "Distance", "EffectivePosition", "CanHear", "Start", "Stop" } },
	{ name = "phone", methods = { "HasHandset", "RecordFor", "StartCall", "Answer", "EndCall", "CanHearRemote", "Message", "BuildPhotoMetadata", "SendPhotoMetadata" } },
	{ name = "hitman_evidence", methods = { "CaptureDeath", "AttachCorpse", "VisibleCorpses", "ApplyPhoto", "IsQualifyingIncident", "Start", "Stop" } },
	{ name = "inventory", methods = { "Load", "SaveNow", "Footprint", "CanPlace", "MoveItem", "AutoPlace", "TakeRawByID", "ExtractAll", "CanInsertBatch", "CanInsertBatchRecords", "InsertRaw", "ReserveResources", "RestoreRecords", "UseItem", "RecoveryItems", "RecoverItem", "BuildSnapshot", "CanUseEquipmentSlot", "EnforceEquipmentAccess", "CreateWeaponRecord", "HasWeaponRecord", "EquippedWeaponRecord", "CaptureEquippedWeaponStates", "CanPossessWeapon", "GrantEquippedWeapons", "ReconcileWeapons" } },
	{ name = "death_loot", methods = { "Create", "Open", "BuildSnapshot", "Take", "TakeAll", "SyncOpen", "Save", "Start", "Stop" } },
	{ name = "salvage", methods = { "RegisterEntity", "Open", "BuildSnapshot", "TransferToHands", "ReturnToBin", "RefreshIfDue", "Save", "Status" } },
	{ name = "crafting", methods = { "BuildCatalog", "Recipe", "CanCraft", "StartCraft", "CancelCraft", "CompleteCraft", "ClaimOutput", "LearnSchematic", "Dismantle", "Mastery", "AddMastery", "RegisterTable", "BuildSnapshot", "SavePlayer", "SaveWorld", "Status", "ValidateCoverage" } },
	{ name = "hints", methods = { "Send", "CivicGuidance", "Start", "Stop" } },
	{ name = "objectives", methods = { "RefreshOffers", "RefreshAll", "PruneInvalid", "Accept", "Dismiss", "Emit", "Complete", "Sync", "BuildRoleGoal", "SetRoleGoal", "CheckRoleGoal", "EnsureBeginnerGuide", "SaveGuideProgress", "Popup" } },
	{ name = "contracts", methods = { "BuildSnapshot", "Sync", "AddAimedEntity", "AddPocketItem", "BeginNegotiation", "TryAccept", "Fulfill", "Timeout", "HandleDisconnect" } },
	{ name = "drugs", methods = { "Ingest", "ApplyPoliceWitness", "ForceFeedThink", "SavePlayer", "RestorePlayer" } },
	{ name = "cocaine", methods = { "Use", "HarvestWild", "UsePot", "UseBucket", "UseHotplate", "TableAction", "BuyerAction" } },
	{ name = "experience", methods = { "Add", "SetTotalXP", "XPNeededForNext", "BuildSnapshot", "SendSnapshot", "NormalizePersistentState", "NormalizeUnlockedItems", "IsPrestigeWeapon", "GrantLoadoutWeapons", "CanPrestige", "Prestige", "IsMaxPrestige" } },
	{ name = "civic", methods = { "Get", "Set", "Adjust", "InitializePlayer", "ApplyIncidentOutcome" } },
	{ name = "medical", methods = { "CreateCorpse", "IsCorpse", "RequestMedic", "BeginDefibrillation", "CancelDefibrillation", "Revive", "RemovePlayer", "InstallHLMedkitTracking" } },
	{ name = "civic_permissions", methods = { "CanSpawn", "RoleCanSpawnCrate", "EffectiveThreshold", "IsAssignableWeapon", "DynamicCrateKey", "BuildDynamicCrate", "RegisterDynamicCrate", "UnregisterDynamicCrate", "DynamicCrateForWeapon", "SetWeaponCrate", "MobBossCanSpawnCrate", "BuildSnapshot", "SetThreshold", "SetMobBossCrate", "ResetThreshold" } },
	{ name = "roles", methods = { "InitializePlayer", "Resolve", "DerivedJob", "InitialJob", "Record", "RecordHitEvidence", "Evaluate", "BuildSnapshot", "Serialize", "CanAccessRoleTools" } },
	{ name = "incidents", methods = { "Create", "Resolve", "BuildOutcome", "OutcomeRewards", "AwardOutcomeXP", "FindPair", "FindReasonKey", "QueueDelta", "HoldOpen" } },
	{ name = "kidnapping", methods = { "Start", "CanStart", "BatonAimed", "ApplyEffect", "RemoveEffect", "Release", "Rescue", "Resolve", "Escalate", "PrepareShutdown", "ApplyCommand", "ApplyMove", "IsKnockedOut", "IsGagged", "IsBlindfolded" } },
	{ name = "pvp", methods = { "CanDamage", "HasStandingDirectionalPermission", "JobHasUniversalOffense", "BeginMobBossAssault", "RefreshMobBossAssaultMembership", "QueueWitnessedOffence", "ScanWitnessEvents", "RefreshPlayer", "RebuildSpatialIndex", "ScanDiscovery", "ScanActive", "CellCoordinates" } },
	{ name = "armory", methods = { "BuildCatalog", "Open", "StartOrJoinRaid", "SpawnRewards" } },
	{ name = "treasury", methods = { "RegisterEntity", "Use", "StartOrJoinRaid", "GrantRaidCombat", "ResolveRaid", "Status", "LootForBalance", "BuildLootShares" } },
	{ name = "world_entities", methods = { "PersistAimed", "UnpersistAimed", "Restore", "Save" } },
	{ name = "massie", methods = { "CanUse", "Request", "Begin", "EnrollHunter", "HasGrant" } },
	{ name = "economy", methods = { "SavePlayer", "QueueSave", "WriteOutbox", "RecoverPlayerRow", "Reward" } },
	{ name = "economy_director", methods = { "BeginTransaction", "Commit", "RecordMoney", "RecordItem", "Quote", "LootFactor", "FairValue", "MoneySummary", "Snapshot", "Warnings", "QueueJournal", "FlushJournal", "Reconcile", "SetPolicy", "RegisterVendor", "RegisterLootSource", "Save", "Status" } },
	{ name = "zero_addons", methods = { "ApplyCompatibility", "Status" } },
	{ name = "doors", methods = { "RemovePlayer" } },
	{ name = "properties", methods = {
		"Purchase", "PayLease", "SetMemberRent", "VaultDeposit", "VaultWithdraw",
		"BuildManagementSnapshot", "SendManagement", "SetPrice", "SetLeasePrice", "SetBuyable",
		"AddDoor",
		"SelectZoneEditor", "AddBuildZone", "RemoveBuildZoneAt", "ClearBuildZones",
		"BuildPermissionAt", "ValidateEntityPlacement", "LocationAt"
	} },
	{ name = "jobs", methods = { "Set", "RemovePlayer", "BuildLoadoutCache", "GetCachedLoadout", "EnsureSandboxWeapons", "IsUtilityWeapon", "CanUseUtilityWeapon", "GiveUtilityWeapon", "GiveUtilityWeapons", "QueueAppearanceUpdate", "SelectBotTestWeapon" } },
	{ name = "movement", methods = { "Start", "Stop" } },
	{ name = "loadtest", methods = { "Spawn", "QueueIncidents", "RunTicks", "Report", "Clear" } },
	{ name = "tests", methods = { "Run" } }
}

local lifecycleHooks = {
	PlayerDisconnected = { "DRP.Incidents.ParticipantDisconnect", "DRP.Audit.Leave", "DRP.Roster.Disconnect", "DRP.Medical.Disconnect", "DRP.Objectives.Disconnect", "DRP.Arcade.Disconnect" },
	PlayerInitialSpawn = { "DRP.Players.Index", "DRP.Audit.Join" },
	PlayerDeath = { "DRP.Legal.CustodyDeath", "DRP.Audit.Death", "DRP.Contracts.ParticipantDeath", "DRP.Medical.Death", "DRP.Arcade.Death" },
	ShutDown = {}
}

local lifecycleEvents = { "PlayerInitialSpawn", "PlayerDisconnected", "PlayerSpawn", "PlayerDeath", "ShutDown", "DRPPlayerReady", "DRPJobChanged" }

function Startup:Validate()
	local issues = {}
	local ok, missing = DRP.Services.Validate(required)
	for _, requirement in ipairs(missing or {}) do issues[#issues + 1] = "missing " .. requirement end
	if not DRP.Properties or not istable(DRP.Properties.Geometry) then issues[#issues + 1] = "property geometry module unavailable" end
	if not DRP.Properties or not istable(DRP.Properties.Persistence) then issues[#issues + 1] = "property persistence module unavailable" end
	if not DRP.Properties or not istable(DRP.Properties.Raids) then issues[#issues + 1] = "property raid module unavailable" end
	if not DRP.Props or DRP.Props.CatalogModuleLoaded ~= true then issues[#issues + 1] = "prop catalogue module unavailable" end
	if not DRP.Props or DRP.Props.PersistenceModuleLoaded ~= true then issues[#issues + 1] = "prop persistence module unavailable" end
	for name, status in pairs(DRP.Services.Health or {}) do
		if status.started == false then issues[#issues + 1] = "service '" .. name .. "' failed: " .. tostring(status.error) end
	end
	for incidentType, definition in pairs(DRP.Incidents.Definitions or {}) do
		if not istable(definition.outcomes) or not istable(definition.outcomes.default) then
			issues[#issues + 1] = "incident '" .. incidentType .. "' has no default outcome"
		end
	end
	for event, expected in pairs(lifecycleHooks) do
		local registered = hook.GetTable()[event] or {}
		for _, identifier in ipairs(expected) do
			if not isfunction(registered[identifier]) then issues[#issues + 1] = "missing hook " .. event .. "/" .. identifier end
		end
	end
	local lifecycleCount = 0
	for _, event in ipairs(lifecycleEvents) do
		for identifier, callback in pairs(hook.GetTable()[event] or {}) do
			lifecycleCount = lifecycleCount + 1
			if not isfunction(callback) then issues[#issues + 1] = "invalid hook " .. event .. "/" .. tostring(identifier) end
		end
	end
	for _, method in ipairs({ "PlayerInitialSpawn", "PlayerDisconnected", "ShutDown" }) do
		if not isfunction(GAMEMODE[method]) then issues[#issues + 1] = "missing lifecycle method GM:" .. method end
	end
	local receiverCount = table.Count(DRP.Net.ReceiverAudit or {})
	if receiverCount == 0 then issues[#issues + 1] = "no audited network receivers registered" end
	for _, duplicate in ipairs(DRP.Net.ReceiverDuplicates or {}) do issues[#issues + 1] = "duplicate receiver " .. duplicate end
	local storageError = string.lower(tostring(DRP.Storage.LastError or ""))
	if string.find(storageError, "missing", 1, true) or string.find(storageError, "module not found", 1, true) or string.find(storageError, "invalid data/", 1, true) then
		issues[#issues + 1] = "storage module unavailable: " .. tostring(DRP.Storage.LastError)
	end
	local toolgun = weapons.GetStored("gmod_tool")
	if not toolgun then
		issues[#issues + 1] = "Sandbox Tool Gun (gmod_tool) is not registered; verify darkrp.txt base=sandbox and validate the server's Sandbox files"
	else
		for _, mode in ipairs({ "nocollide", "precision", "stacker_improved", "advdupe2", "drp_property_zone" }) do
			local stored = istable(toolgun.Tool) and istable(toolgun.Tool[mode])
			if not stored and not GetConVar("toolmode_allow_" .. mode) then
				issues[#issues + 1] = "required tool mode '" .. mode .. "' is not registered"
			end
		end
	end
	if not DRP.JobService.CacheReady then
		issues[#issues + 1] = "job model/loadout cache was not prepared"
	end
	for _, issue in ipairs(DRP.JobService.ValidationIssues or {}) do issues[#issues + 1] = "job cache: " .. issue end
	if DRP.Crafting then local covered,missing=DRP.Crafting:ValidateCoverage() if not covered then issues[#issues+1]="crafting catalogue missing "..#missing.." ARC9 definition(s): "..table.concat(missing,", ") end end
	if #issues > 0 then
		for _, issue in ipairs(issues) do ErrorNoHalt("[DRP STARTUP] " .. issue .. "\n") end
		ok = false
	end
	print(string.format("[DRP STARTUP] receiver audit=%d lifecycle hooks=%d status=%s", receiverCount, lifecycleCount, ok and "OK" or "FAILED"))
	return ok, issues
end

function Startup:Start()
	self:Validate()
end

function Startup:Stop() end

concommand.Add("drp_validate_startup", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local ok, issues = Startup:Validate()
	if IsValid(ply) then DRP.Net.Notify(ply, ok and "Startup validation passed." or ("Startup validation failed with " .. #issues .. " issue(s)."), ok and 1 or 3) end
end)
