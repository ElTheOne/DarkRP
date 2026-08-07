local function setState(ply, state)
	if not IsValid(ply) then return end
	ply.DRPLifecycleState = state
	DRP.Net.SendState(ply, state)
end

function GM:Initialize()
	DRP.Services.StartAll()
	print(string.format("[DRP] foundation %s protocol=%d", DRP.Version, DRP.ProtocolVersion))
end

function GM:ShutDown()
	-- Queue final player snapshots before Storage:Stop drains MySQLOO's queue.
	if DRP.Contracts then DRP.Contracts.PrepareShutdown() end
	if DRP.Kidnapping then DRP.Kidnapping:PrepareShutdown() end
	if DRP.Inventory then DRP.Inventory.SaveAll() end
	if DRP.Economy then DRP.Economy.SaveAll() end
	if DRP.EconomyDirector then DRP.EconomyDirector:Reconcile("all") end
	DRP.Services.StopAll()
end

local function canForceSave(ply)
	return not IsValid(ply) or (DRP.Admin and DRP.Admin.IsOwner(ply))
end

concommand.Add("drp_save_all", function(ply)
	if not canForceSave(ply) then return end
	-- Local world configuration is flushed synchronously first. Player and
	-- government snapshots are then queued through MySQLOO without stopping it.
	if DRP.Properties then DRP.Properties:Save() DRP.Properties:Flush() end
	if DRP.Doors then DRP.Doors:SavePolicies() end
	if DRP.WorldEntities then DRP.WorldEntities:Save() end
	if DRP.Salvage then DRP.Salvage:Save(true) end
	if DRP.Crafting then
		for _, target in player.Iterator() do DRP.Crafting:SavePlayer(target) end
		DRP.Crafting:SaveWorld()
	end
	if DRP.DeathLoot then DRP.DeathLoot:Save() end
	if DRP.Props and DRP.Props.CaptureAllPersistent then
		DRP.Props:CaptureAllPersistent()
		DRP.Props:SavePersistence()
	end
	if DRP.Armory then DRP.Armory:SaveUnlocks() end
	if DRP.Audit then DRP.Audit:Flush() end
	if DRP.Inventory then DRP.Inventory.SaveAll() end
	if DRP.Economy then DRP.Economy.SaveAll() end
	if DRP.EconomyDirector then DRP.EconomyDirector:Reconcile("all") end
	if DRP.Government then DRP.Government.Save() end
	local queue = DRP.Storage and DRP.Storage.QueueSize() or 0
	local backend = DRP.Storage and DRP.Storage.Mode or "unavailable"
	local message = "Forced save complete; local property/crafting files flushed and " .. backend .. " queue=" .. queue .. ". Wait for queue=0 before restarting."
	print("[DRP] " .. message)
	if IsValid(ply) then DRP.Net.Notify(ply, message, 1) end
end)

concommand.Add("drp_save_status", function(ply)
	if not canForceSave(ply) then return end
	local available = DRP.Storage and DRP.Storage.IsAvailable() or false
	local queue = DRP.Storage and DRP.Storage.QueueSize() or 0
	local propertyDirty = DRP.Properties and DRP.Properties.Dirty == true or false
	local propertyRevision = DRP.Properties and DRP.Properties.Revision or 0
	local propertyGroups = DRP.Properties and table.Count(DRP.Properties.Definitions) or 0
	local propertyBytes = file.Size("darkrp/properties/" .. game.GetMap():gsub("[^%w_%-]", "_") .. ".json", "DATA") or -1
	local databaseLoaded = DRP.Properties and DRP.Properties.DatabaseLoaded == true or false
	local craftingDirty = DRP.Crafting and DRP.Crafting.DirtyWorld == true or false
	local craftingTables = DRP.Crafting and table.Count(DRP.Crafting.Tables or {}) or 0
	local backend = DRP.Storage and DRP.Storage.Mode or "unavailable"
	local localKey = DRP.Storage and DRP.Storage.LocalPlayerKey and DRP.Storage.LocalPlayerKey() or ""
	local outboxFiles=file.Find("darkrp/profile_outbox/*.json","DATA") or {}
	local message = string.format("save status: backend=%s local_host=%s available=%s queue=%d profile_outbox=%d property_dirty=%s groups=%d revision=%d local_bytes=%d db_checked=%s crafting_dirty=%s crafting_tables=%d", backend, localKey ~= "" and localKey or "-", tostring(available), queue, #outboxFiles, tostring(propertyDirty), propertyGroups, propertyRevision, propertyBytes, tostring(databaseLoaded), tostring(craftingDirty), craftingTables)
	print("[DRP] " .. message)
	if IsValid(ply) then DRP.Net.Notify(ply, message, available and queue == 0 and not propertyDirty and 1 or 2) end
end)

function GM:PlayerInitialSpawn(ply)
	ply.DRPSessionStartedAt = CurTime()
	ply.DRPTotalPlaytimeBase = 0

	if ply:IsBot() then
		ply.DRPEphemeralReason = "bot session"
		ply.DRPRoleGoalValue = 0
		if DRP.Roles then DRP.Roles:InitializePlayer(ply, {}) end
		DRP.JobService.Set(ply, DRP.Job.CITIZEN, true)
		if DRP.Experience then DRP.Experience:InitializePlayer(ply, 0, 1, 0, 0, {}) end
		if DRP.Civic then DRP.Civic:InitializePlayer(ply, 0) end
		DRP.Economy.InitializePlayer(ply, DRP.Economy.DefaultMoney)
		DRP.Inventory.Load(ply, false)
		ply.DRPRPNameValue = ply:Nick()
		ply.DRPJobNameValue = ""
		setState(ply, DRP.State.EPHEMERAL)
		hook.Run("DRPPlayerReady", ply)
		DRP.Net.SendProfile(ply)
		if DRP.Government then DRP.Government.Sync(ply) end
		if DRP.Legal then DRP.Legal.PlayerReady(ply) end
		return
	end

	setState(ply, DRP.State.LOADING)
	ply:Lock()

	local steamID64 = ply:SteamID64()
	DRP.Storage.LoadPlayer(steamID64, ply:Nick(), function(persistent, row, reason)
		if not IsValid(ply) then return end
		local recovered, recoveryRevision
		if DRP.Economy and DRP.Economy.RecoverPlayerRow then
			row, recovered, recoveryRevision = DRP.Economy.RecoverPlayerRow(steamID64, row)
			if recovered then
				persistent = true
				ply.DRPProfileOutboxRevision = recoveryRevision
				ply.DRPPlayerRecordDirty = true
				print("[DRP] recovered unsaved player profile for " .. steamID64)
			end
		end

		ply.DRPPlayerRecord = row
		ply.DRPEphemeralReason = persistent and nil or reason
		ply.DRPTotalPlaytimeBase = persistent and math.max(0, math.floor(tonumber(row and row.total_playtime_seconds) or 0)) or 0
		if DRP.Experience then
			local xpState = DRP.Experience:NormalizePersistentState(row, persistent)
			DRP.Experience:InitializePlayer(
				ply,
				xpState.xp,
				xpState.level,
				xpState.prestige,
				xpState.tokens,
				xpState.unlocked
			)
		end
		if DRP.Civic then DRP.Civic:InitializePlayer(ply, persistent and row and row.civic_standing or 0) end
		if DRP.Roles then DRP.Roles:InitializePlayer(ply, persistent and row and row.role_behavior or {}) end
		ply.DRPRoleGoalValue = persistent and math.Clamp(math.floor(tonumber(row and row.role_goal) or 0), 0, 255) or 0
		local jobID = persistent and DRP.JobService.Resolve(row and row.job_key) or DRP.Job.CITIZEN
		-- An elected office is never restored merely because it was the last saved job.
		if jobID == DRP.Job.MAYOR then jobID = DRP.Job.CITIZEN end
		if DRP.Roles then jobID = DRP.Roles:InitialJob(ply, jobID) end
		local rpName = persistent and row and string.Trim(tostring(row.rp_name or "")) or ""
		ply.DRPRPNameValue = rpName ~= "" and rpName or ply:Nick()
		ply.DRPJobNameValue = persistent and row and string.sub(string.Trim(tostring(row.job_name or "")), 1, 48) or ""
		DRP.JobService.Set(ply, jobID or DRP.Job.CITIZEN, true)
		DRP.Economy.InitializePlayer(ply, persistent and row and row.money or DRP.Economy.DefaultMoney)
		setState(ply, persistent and DRP.State.PERSISTENT or DRP.State.EPHEMERAL)
		hook.Run("DRPPlayerReady", ply)
		-- Identity/economy are essential. Pocket contents are secondary and load
		-- asynchronously, preventing a restart wave from holding every player.
		DRP.Net.SendProfile(ply)
		if DRP.Government then DRP.Government.Sync(ply) end
		if DRP.Legal then DRP.Legal.PlayerReady(ply) end
		DRP.Doors.SyncPlayer(ply)
		ply:UnLock()
		DRP.Inventory.Load(ply, persistent)
	end)
end

function GM:PlayerDisconnected(ply)
	if ply:IsBot() then return end

	-- Marketplace escrow/listing cleanup must happen before the single final
	-- Hands snapshot. Keeping this order here avoids hook-order races and
	-- duplicate database writes during disconnect.
	if DRP.Contracts and DRP.Contracts.HandleDisconnect then DRP.Contracts.HandleDisconnect(ply) end
	-- Capture wallet and job while all player state is still intact.
	local sessionTime = math.max(0, CurTime() - (ply.DRPSessionStartedAt or CurTime()))
	if DRP.Economy then
		if sessionTime > 0 then
			ply.DRPTotalPlaytimeBase = math.floor((ply.DRPTotalPlaytimeBase or 0) + sessionTime)
			ply.DRPSessionStartedAt = CurTime()
		end
	end
	if DRP.Loading then DRP.Loading:Publish(ply) end
	if DRP.Economy then
		DRP.Economy.SavePlayer(ply)
	end
	if DRP.Inventory then DRP.Inventory.SaveNow(ply) end
	DRP.Economy.RemovePlayer(ply)
	DRP.Doors.RemovePlayer(ply)
	DRP.JobService.RemovePlayer(ply)
end

function GM:PlayerSetModel(ply)
	local cached = DRP.JobService.GetCachedLoadout(ply:DRPJobID())
	ply:SetModel(cached.model)
end

function GM:PlayerLoadout(ply)
	ply:StripWeapons()
	local cached = DRP.JobService.GetCachedLoadout(ply:DRPJobID())
	local loadoutWeapons = cached.weapons
	for i = 1, #loadoutWeapons do ply:Give(loadoutWeapons[i]) end
	-- These are universal building utilities, not job or progression weapons.
	-- Give them again outside the cache so an early cache miss cannot remove
	-- them from every player's spawn loadout.
	DRP.JobService.GiveUtilityWeapons(ply)
	if DRP.Experience then DRP.Experience:GrantLoadoutWeapons(ply) end
	if DRP.Inventory then DRP.Inventory.ReconcileWeapons(ply, true) end
	return true
end

concommand.Add("drp_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsAdmin(ply)) then return end

	local counts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
	for _, target in player.Iterator() do
		local state = target.DRPLifecycleState or DRP.State.LOADING
		counts[state] = counts[state] + 1
	end

	print(string.format("[DRP] version=%s protocol=%d storage=%s available=%s queue=%d error=%s", DRP.Version, DRP.ProtocolVersion, DRP.Storage.Mode or "unknown", tostring(DRP.Storage.IsAvailable()), DRP.Storage.QueueSize(), DRP.Storage.LastError or ""))
	print(string.format("[DRP] players loading=%d persistent=%d ephemeral=%d ready=%d", counts[0], counts[1], counts[2], counts[3]))
	print(string.format("[DRP] net messages=%d estimated_bytes=%d lua_memory=%.1fKB", DRP.Net.SentMessages, DRP.Net.SentBytes, collectgarbage("count")))
	print(string.format("[DRP] db errors=%d max_queue=%d", DRP.Storage.ErrorCount, DRP.Storage.MaxQueueDepth))
	local deadlineCount = DRP.Deadlines and #DRP.Deadlines.Heap or 0
	local incidentCount = DRP.Incidents and table.Count(DRP.Incidents.Active) or 0
	local auditQueue = DRP.Audit and (#DRP.Audit.WriteQueue + #DRP.Audit.ReceiptQueue) or 0
	print(string.format("[DRP] deadlines=%d incidents=%d audit_queue=%d", deadlineCount, incidentCount, auditQueue))
	if DRP.PVP then
		local stats = DRP.PVP.LastScanStats or {}
		print(string.format("[DRP] pvp officers=%d armed_suspects=%d active=%d cells=%d candidates=%d traces=%d/%d scanner=%s", #DRP.PVP.OfficerList, #DRP.PVP.ArmedSuspects, #(DRP.PVP.ActiveSightings or {}), stats.cells or 0, stats.candidates or 0, stats.discovery_traces or 0, stats.active_traces or 0, tostring(timer.Exists("DRP.PVP.Scan"))))
	end
	if DRP.JobService then
		print(string.format("[DRP] job_cache ready=%s jobs=%d weapons=%d models=%d issues=%d stage_delay=%.3fs",
			tostring(DRP.JobService.CacheReady), table.Count(DRP.JobService.LoadoutCache or {}),
			table.Count(DRP.JobService.WeaponDefinitions or {}), table.Count(DRP.JobService.PrecachedModels or {}),
			#(DRP.JobService.ValidationIssues or {}), DRP.JobService.ApplyStageDelay or 0))
	end
	local propService = DRP.Services.Get("props")
	if propService then
		local props, complexity = 0, 0
		for _, count in pairs(propService.CountByOwnerID) do props = props + count end
		for _, weight in pairs(propService.WeightByOwnerID) do complexity = complexity + weight end
		print(string.format("[DRP] tracked_props=%d/%d complexity=%d/%d", props, propService.MaxGlobalProps, complexity, propService.MaxGlobalPropWeight))
		print(string.format("[DRP] dropped_entities weapons=%d/%d drugs=%d/%d crates=%d/%d cleanup_queue=%d",
			propService.LimitedEntityCounts.weapon or 0, propService.LimitedEntityCaps.weapon,
			propService.LimitedEntityCounts.drug or 0, propService.LimitedEntityCaps.drug,
			propService.LimitedEntityCounts.crate or 0, propService.LimitedEntityCaps.crate,
			math.max(0, propService.CleanupTail - propService.CleanupHead + 1)))
	end
	if DRP.Properties then
		print(string.format("[DRP] properties definitions=%d active_leases=%d active_raids=%d pending_credits=%d", table.Count(DRP.Properties.Definitions), table.Count(DRP.Properties.Leases), table.Count(DRP.Properties.ActiveRaids), table.Count(DRP.Properties.PendingCredits)))
	end
end)
