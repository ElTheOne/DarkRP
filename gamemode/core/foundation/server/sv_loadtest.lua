local LoadTest = {
	Actors = {},
	ByID = {},
	Officers = {},
	Armed = {},
	Grid = {},
	IncidentSchedule = {},
	ActivePairs = {},
	AuditBatch = {},
	Metrics = {},
	TickCount = 0,
	ActivityCursor = 0,
	OfficerCursor = 0,
	NextIncidentID = 1,
	PendingIncidents = 0,
	ResolvedIncidents = 0,
	GeneratedSightings = 0,
	RosterDeltas = 0,
	RosterBytes = 0,
	ProfileDeltas = 0,
	ProfileBytes = 0,
	AuditBytes = 0,
	PersistenceBytes = 0,
	TotalXPAwarded = 0,
	Running = false,
	RemainingTicks = 0,
	Seed = 1337,
	InitialMemoryKB = 0,
	StartedAt = 0,
	MaxActors = 1024,
	MaxQueuedIncidents = 100000,
	MaxActiveIncidents = 4096,
	-- One virtual 20 Hz simulation step per real server frame keeps the
	-- reported frame_batch cost representative instead of accelerating it.
	TicksPerFrame = 1,
	IncidentHorizonTicks = 100,
	IncidentAuditBatchSize = 256,
	MetricSampleLimit = 1024,
	TimerName = "DRP.LoadTest.Run"
}

DRP.LoadTest = LoadTest
DRP.Services.Register("loadtest", LoadTest)

local scenarios = {
	{ type = "mugging", resolutions = { "payment_received", "victim_killed", "mugger_killed" } },
	{ type = "legal_warrant", resolutions = { "suspect_arrested" } },
	{ type = "police_weapon_sighting", resolutions = { "suspect_arrested" } },
	{ type = "property_raid", resolutions = { "attackers_victory", "defenders_victory" } },
	{ type = "hit_contract", resolutions = { "target_eliminated", "contract_failed" } },
	{ type = "armory_raid", resolutions = { "raiders_victory", "defenders_victory" } },
	{ type = "treasury_raid", resolutions = { "raiders_victory", "defenders_victory" } }
}

local civicAdjustments = {
	mugging = {
		payment_received = { instigator = -25 },
		victim_killed = { instigator = -70 },
		mugger_killed = { instigator = -20, victim = 5 }
	},
	legal_warrant = { suspect_arrested = { instigator = 30, victim = -30 } },
	police_weapon_sighting = { suspect_arrested = { instigator = 25, victim = -25 } },
	property_raid = {
		attackers_victory = { instigator = -40 },
		defenders_victory = { instigator = -20, victim = 10 }
	},
	hit_contract = {
		target_eliminated = { instigator = -80 },
		contract_failed = { instigator = -20, victim = 5 }
	},
	armory_raid = {
		raiders_victory = { instigator = -55 },
		defenders_victory = { instigator = -30, victim = 10 }
	},
	treasury_raid = {
		raiders_victory = { instigator = -65 },
		defenders_victory = { instigator = -35, victim = 10 }
	}
}

local function commandAllowed(ply)
	local toggle=GetConVar("drp_enable_test_commands")
	if not toggle or not toggle:GetBool() then return false end
	return not IsValid(ply)
		or (not game.IsDedicated() and isfunction(ply.IsListenServerHost) and ply:IsListenServerHost())
		or (DRP.Admin and DRP.Admin.IsOwner(ply))
end

local function respond(ply, message, kind)
	print("[DRP LOADTEST] " .. message)
	if IsValid(ply) then DRP.Net.Notify(ply, message, kind or 1) end
end

local function percentile(samples, fraction)
	if #samples == 0 then return 0 end
	local copy = table.Copy(samples)
	table.sort(copy)
	return copy[math.max(1, math.ceil(#copy * fraction))]
end

function LoadTest:Record(name, elapsed)
	elapsed = math.max(0, tonumber(elapsed) or 0)
	local metric = self.Metrics[name]
	if not metric then
		metric = { count = 0, total = 0, max = 0, samples = {}, cursor = 0 }
		self.Metrics[name] = metric
	end
	metric.count = metric.count + 1
	metric.total = metric.total + elapsed
	metric.max = math.max(metric.max, elapsed)
	metric.cursor = (metric.cursor % self.MetricSampleLimit) + 1
	metric.samples[metric.cursor] = elapsed
	if DRP.Profile then DRP.Profile.Record("loadtest." .. name, elapsed) end
end

function LoadTest:Random(maximum)
	self.Seed = (self.Seed * 1103515245 + 12345) % 2147483648
	if not maximum then return self.Seed / 2147483648 end
	return (self.Seed % math.max(1, maximum)) + 1
end

local function actorCell(actor, cellSize)
	return math.floor(actor.x / cellSize), math.floor(actor.y / cellSize)
end

local function cellKey(x, y)
	return x .. ":" .. y
end

local function markRoster(actor, mask)
	actor.rosterMask = bit.bor(actor.rosterMask or 0, mask or 1)
end

function LoadTest:Clear()
	timer.Remove(self.TimerName)
	self.Actors = {}
	self.ByID = {}
	self.Officers = {}
	self.Armed = {}
	self.Grid = {}
	self.IncidentSchedule = {}
	self.ActivePairs = {}
	self.AuditBatch = {}
	self.Metrics = {}
	self.TickCount = 0
	self.ActivityCursor = 0
	self.OfficerCursor = 0
	self.NextIncidentID = 1
	self.PendingIncidents = 0
	self.ResolvedIncidents = 0
	self.GeneratedSightings = 0
	self.RosterDeltas = 0
	self.RosterBytes = 0
	self.ProfileDeltas = 0
	self.ProfileBytes = 0
	self.AuditBytes = 0
	self.PersistenceBytes = 0
	self.TotalXPAwarded = 0
	self.Running = false
	self.RemainingTicks = 0
	self.Seed = 1337
	self.InitialMemoryKB = collectgarbage("count")
	self.StartedAt = 0
end

function LoadTest:BuildRosterSnapshot()
	local started = SysTime()
	local rows = {}
	for index = 1, #self.Actors do
		local actor = self.Actors[index]
		rows[index] = {
			id = actor.id,
			name = actor.name,
			job = actor.job,
			level = actor.level,
				civic = actor.civic,
				rank = actor.rank,
				afk = actor.afk,
				admin = actor.admin,
				trust = actor.trust,
				discordLinked = actor.discordLinked
		}
	end
	local payload = util.TableToJSON(rows, false) or "[]"
	self.RosterBytes = self.RosterBytes + #payload
	for index = 1, #self.Actors do self.Actors[index].rosterMask = 0 end
	self:Record("roster_snapshot", (SysTime() - started) * 1000)
	return #payload
end

function LoadTest:Spawn(count)
	self:Clear()
	count = math.Clamp(math.floor(tonumber(count) or 64), 1, self.MaxActors)
	local started = SysTime()
	local width = math.max(1, math.ceil(math.sqrt(count)))
	for id = 1, count do
		local officer = id % 8 == 0
		local armed = not officer and id % 3 == 0
		local angle = (id * 37 % 360) * math.pi / 180
		local actor = {
			id = id,
			steamID64 = "900000000000" .. string.format("%05d", id),
			name = "Virtual Player " .. id,
			job = officer and "police" or (id % 7 == 0 and "thief" or "citizen"),
			rank = id % 32 == 0 and "vip" or "user",
			level = (id - 1) % 100 + 1,
			xp = 0,
			totalXP = 0,
			prestige = 0,
				civic = 0,
				trust = 35 + (id * 17 % 66),
				discordLinked = id % 3 == 0,
			money = 500 + id * 25,
			afk = false,
			admin = false,
			officer = officer,
			armed = armed,
			alive = true,
			x = ((id - 1) % width) * 320 + (id % 5) * 19,
			y = math.floor((id - 1) / width) * 320 + (id % 7) * 13,
			z = 0,
			fx = math.cos(angle),
			fy = math.sin(angle),
				rosterMask = 255,
			profileDirty = false
		}
		self.Actors[id] = actor
		self.ByID[id] = actor
		if officer then self.Officers[#self.Officers + 1] = actor end
		if armed then self.Armed[#self.Armed + 1] = actor end
	end
	self:Record("spawn", (SysTime() - started) * 1000)
	self:BuildRosterSnapshot()
	return count
end

function LoadTest:RebuildSpatialIndex()
	local started = SysTime()
	local grid, cellSize = {}, (DRP.PVP and DRP.PVP.CellSize) or 768
	for index = 1, #self.Armed do
		local actor = self.Armed[index]
		if actor.alive and actor.armed then
			local x, y = actorCell(actor, cellSize)
			local key = cellKey(x, y)
			local list = grid[key]
			if not list then list = {} grid[key] = list end
			list[#list + 1] = actor
		end
	end
	self.Grid = grid
	self:Record("spatial_rebuild", (SysTime() - started) * 1000)
end

function LoadTest:ScheduleIncident(instigator, victim, scenario, resolution, delay)
	if not instigator or not victim or instigator == victim or self.PendingIncidents >= self.MaxActiveIncidents then return false end
	local dueTick = self.TickCount + math.max(1, math.floor(tonumber(delay) or 1))
	local bucket = self.IncidentSchedule[dueTick]
	if not bucket then bucket = {} self.IncidentSchedule[dueTick] = bucket end
	local definition = DRP.Incidents.Definitions[scenario.type] or {}
	local incident = {
		id = self.NextIncidentID,
		type = scenario.type,
		state = definition.initial or "active",
		reason = "Synthetic load-test scenario",
		instigator = instigator,
		victim = victim,
		resolution = resolution,
		evidence = {
			{ tick = self.TickCount, event = "incident_created", detail = "Synthetic incident created" }
		}
	}
	self.NextIncidentID = self.NextIncidentID + 1
	bucket[#bucket + 1] = incident
	self.PendingIncidents = self.PendingIncidents + 1
	return true
end

function LoadTest:QueueIncidents(count)
	if #self.Actors < 2 then return false, "spawn virtual actors first" end
	count = math.Clamp(math.floor(tonumber(count) or 1000), 1, self.MaxQueuedIncidents)
	local started, queued = SysTime(), 0
	for index = 1, count do
		local scenario = scenarios[(index - 1) % #scenarios + 1]
		if DRP.Incidents.Definitions[scenario.type] then
			local instigator = self.Actors[self:Random(#self.Actors)]
			local victim = self.Actors[self:Random(#self.Actors)]
			if victim == instigator then victim = self.Actors[(victim.id % #self.Actors) + 1] end
			local resolution = scenario.resolutions[(index - 1) % #scenario.resolutions + 1]
			if self:ScheduleIncident(instigator, victim, scenario, resolution, (index - 1) % self.IncidentHorizonTicks + 1) then
				queued = queued + 1
			end
		end
	end
	self:Record("incident_queue", (SysTime() - started) * 1000)
	return true, queued
end

local function applyVirtualXP(service, actor, amount)
	local previousLevel = actor.level
	actor.totalXP = math.max(0, actor.totalXP + amount)
	local level, remainder = DRP.Experience:TotalToState(actor.totalXP)
	actor.level, actor.xp = level, remainder
	actor.profileDirty = true
	service.TotalXPAwarded = service.TotalXPAwarded + amount
	if level ~= previousLevel then markRoster(actor, 4) end
end

local function applyVirtualCivic(actor, amount)
	if not amount then return end
	actor.civic = math.Clamp(actor.civic + amount, -1000, 1000)
	markRoster(actor, 8)
end

function LoadTest:FlushAuditBatch(force)
	if #self.AuditBatch == 0 or (not force and #self.AuditBatch < self.IncidentAuditBatchSize) then return end
	local started = SysTime()
	local payload = table.concat(self.AuditBatch)
	self.AuditBytes = self.AuditBytes + #payload
	self.AuditBatch = {}
	self:Record("audit_batch", (SysTime() - started) * 1000)
end

function LoadTest:ResolveIncident(incident)
	local outcome = DRP.Incidents.BuildOutcome(incident, incident.resolution, "Synthetic outcome")
	if not outcome then return false end
	incident.state = "resolved"
	incident.evidence[#incident.evidence + 1] = {
		tick = self.TickCount,
		event = "incident_resolved",
		detail = incident.resolution
	}
	if #incident.evidence > (DRP.Incidents.EvidenceCapacity or 16) then table.remove(incident.evidence, 1) end
	for _, reward in ipairs(DRP.Incidents.OutcomeRewards(outcome)) do
		applyVirtualXP(self, reward.player, reward.amount)
	end
	local policy = civicAdjustments[incident.type]
	policy = policy and policy[incident.resolution]
	if policy then
		applyVirtualCivic(incident.instigator, policy.instigator)
		applyVirtualCivic(incident.victim, policy.victim)
	end
	self.AuditBatch[#self.AuditBatch + 1] = (util.TableToJSON({
		id = incident.id,
		type = incident.type,
		resolution = incident.resolution,
		instigator = incident.instigator.id,
		victim = incident.victim.id
	}, false) or "{}") .. "\n"
	self.ResolvedIncidents = self.ResolvedIncidents + 1
	self.PendingIncidents = math.max(0, self.PendingIncidents - 1)
	self:FlushAuditBatch(false)
	return true
end

function LoadTest:ProcessIncidentDeadlines()
	local started = SysTime()
	local bucket = self.IncidentSchedule[self.TickCount]
	self.IncidentSchedule[self.TickCount] = nil
	if bucket then
		for index = 1, #bucket do self:ResolveIncident(bucket[index]) end
	end
	self:Record("incident_deadlines", (SysTime() - started) * 1000)
end

function LoadTest:ScanOfficer()
	if #self.Officers == 0 then return end
	local started = SysTime()
	self.OfficerCursor = self.OfficerCursor % #self.Officers + 1
	local officer = self.Officers[self.OfficerCursor]
	local cellSize = (DRP.PVP and DRP.PVP.CellSize) or 768
	local range = (DRP.PVP and DRP.PVP.ScanDistance) or 1600
	local rangeSqr = range * range
	local cellX, cellY = actorCell(officer, cellSize)
	local confirmed, comparisons = 0, 0
	for x = cellX - 2, cellX + 2 do
		for y = cellY - 2, cellY + 2 do
			for _, suspect in ipairs(self.Grid[cellKey(x, y)] or {}) do
				comparisons = comparisons + 1
				local dx, dy = suspect.x - officer.x, suspect.y - officer.y
				local distanceSqr = dx * dx + dy * dy
				if distanceSqr > 0 and distanceSqr <= rangeSqr then
					local inverseDistance = 1 / math.sqrt(distanceSqr)
					local dot = (dx * inverseDistance) * officer.fx + (dy * inverseDistance) * officer.fy
					if dot >= -0.15 then
						local pair = officer.id .. ":" .. suspect.id
						if (self.ActivePairs[pair] or 0) <= self.TickCount and confirmed < 8 then
							local scenario = scenarios[3]
							if self:ScheduleIncident(officer, suspect, scenario, "suspect_arrested", 30) then
								self.ActivePairs[pair] = self.TickCount + 100
								self.GeneratedSightings = self.GeneratedSightings + 1
								confirmed = confirmed + 1
							end
						end
					end
				end
			end
		end
	end
	self:Record("police_scan", (SysTime() - started) * 1000)
	return comparisons, confirmed
end

function LoadTest:ProcessActivity()
	if #self.Actors == 0 then return end
	local started = SysTime()
	local budget = math.max(1, math.ceil(#self.Actors / 20))
	for _ = 1, budget do
		self.ActivityCursor = self.ActivityCursor % #self.Actors + 1
		local actor = self.Actors[self.ActivityCursor]
		actor.money = math.max(0, actor.money + (self:Random(21) - 11))
		actor.profileDirty = true
		if self.TickCount % 100 == actor.id % 100 then
			actor.afk = not actor.afk
			markRoster(actor, 32)
		end
	end
	self:Record("activity", (SysTime() - started) * 1000)
end

function LoadTest:FlushRosterDeltas()
	local started = SysTime()
	local rows = {}
	for index = 1, #self.Actors do
		local actor = self.Actors[index]
		if (actor.rosterMask or 0) ~= 0 then
			rows[#rows + 1] = {
				id = actor.id,
				mask = actor.rosterMask,
				level = actor.level,
				civic = actor.civic,
				money = actor.money,
				afk = actor.afk
			}
			actor.rosterMask = 0
		end
	end
	if #rows > 0 then
		local payload = util.TableToJSON(rows, false) or "[]"
		self.RosterDeltas = self.RosterDeltas + #rows
		self.RosterBytes = self.RosterBytes + #payload
	end
	self:Record("roster_deltas", (SysTime() - started) * 1000)
end

function LoadTest:FlushProfileDeltas()
	local started = SysTime()
	local rows = {}
	for index = 1, #self.Actors do
		local actor = self.Actors[index]
		if actor.profileDirty then
			rows[#rows + 1] = {
				id = actor.id,
				money = actor.money,
				xp = actor.xp,
				level = actor.level,
				prestige = actor.prestige
			}
			actor.profileDirty = false
		end
	end
	if #rows > 0 then
		local payload = util.TableToJSON(rows, false) or "[]"
		self.ProfileDeltas = self.ProfileDeltas + #rows
		self.ProfileBytes = self.ProfileBytes + #payload
	end
	self:Record("profile_deltas", (SysTime() - started) * 1000)
end

function LoadTest:ProcessTick()
	self.TickCount = self.TickCount + 1
	local started = SysTime()
	self:ProcessActivity()
	if self.TickCount == 1 or self.TickCount % 10 == 0 then self:RebuildSpatialIndex() end
	self:ScanOfficer()
	self:ProcessIncidentDeadlines()
	self:FlushRosterDeltas()
	self:FlushProfileDeltas()
	self:Record("tick", (SysTime() - started) * 1000)
end

function LoadTest:BuildPersistenceBatches()
	local started, bytes = SysTime(), 0
	for first = 1, #self.Actors, 64 do
		local batch = {}
		for index = first, math.min(#self.Actors, first + 63) do
			local actor = self.Actors[index]
			batch[#batch + 1] = {
				steam_id = actor.steamID64,
				last_name = actor.name,
				money = actor.money,
				job_key = actor.job,
				xp_points = actor.xp,
				xp_level = actor.level,
				civic_standing = actor.civic,
				total_playtime_seconds = self.TickCount / 20
			}
		end
		bytes = bytes + #(util.TableToJSON(batch, false) or "[]")
	end
	self.PersistenceBytes = self.PersistenceBytes + bytes
	self:Record("persistence_batch", (SysTime() - started) * 1000)
	return bytes
end

function LoadTest:FinishRun()
	timer.Remove(self.TimerName)
	self.Running = false
	self.RemainingTicks = 0
	self:FlushAuditBatch(true)
	self:BuildPersistenceBatches()
	local elapsed = math.max(0, SysTime() - self.StartedAt)
	print(string.format("[DRP LOADTEST] completed actors=%d ticks=%d resolved=%d pending=%d wall=%.2fs",
		#self.Actors, self.TickCount, self.ResolvedIncidents, self.PendingIncidents, elapsed))
end

function LoadTest:RunTicks(count)
	if self.Running then return false, "a load test is already running" end
	if #self.Actors == 0 then return false, "spawn virtual actors first" end
	count = math.Clamp(math.floor(tonumber(count) or 300), 1, 100000)
	self.Running = true
	self.RemainingTicks = count
	self.StartedAt = SysTime()
	timer.Create(self.TimerName, 0, 0, function()
		if not DRP.LoadTest or not LoadTest.Running then timer.Remove(LoadTest.TimerName) return end
		local frameStarted = SysTime()
		local iterations = math.min(LoadTest.TicksPerFrame, LoadTest.RemainingTicks)
		for _ = 1, iterations do LoadTest:ProcessTick() end
		LoadTest.RemainingTicks = LoadTest.RemainingTicks - iterations
		LoadTest:Record("frame_batch", (SysTime() - frameStarted) * 1000)
		if LoadTest.RemainingTicks <= 0 then LoadTest:FinishRun() end
	end)
	return true, count
end

function LoadTest:Report()
	local memory = collectgarbage("count")
	print("[DRP LOADTEST] report")
	print(string.format("  actors=%d officers=%d armed=%d ticks=%d running=%s remaining=%d",
		#self.Actors, #self.Officers, #self.Armed, self.TickCount, tostring(self.Running), self.RemainingTicks))
	print(string.format("  incidents resolved=%d pending=%d scanner_generated=%d xp_awarded=%d",
		self.ResolvedIncidents, self.PendingIncidents, self.GeneratedSightings, self.TotalXPAwarded))
	print(string.format("  roster_deltas=%d roster_bytes=%d audit_bytes=%d persistence_bytes=%d",
		self.RosterDeltas, self.RosterBytes, self.AuditBytes, self.PersistenceBytes))
	print(string.format("  profile_deltas=%d profile_bytes=%d", self.ProfileDeltas, self.ProfileBytes))
	for name, metric in SortedPairs(self.Metrics) do
		print(string.format("  %s count=%d avg=%.4fms p95=%.4fms p99=%.4fms max=%.4fms",
			name, metric.count, metric.total / math.max(1, metric.count),
			percentile(metric.samples, 0.95), percentile(metric.samples, 0.99), metric.max))
	end
	print(string.format("  lua_memory=%.1fKB delta=%.1fKB", memory, memory - self.InitialMemoryKB))
	return {
		actors = #self.Actors,
		ticks = self.TickCount,
		resolved = self.ResolvedIncidents,
		pending = self.PendingIncidents,
		memoryKB = memory
	}
end

function LoadTest:Start()
	self:Clear()
end

function LoadTest:Stop()
	self:Clear()
end

concommand.Add("drp_loadtest_spawn", function(ply, _, arguments)
	if not commandAllowed(ply) then return end
	local count = LoadTest:Spawn(arguments[1])
	respond(ply, "Spawned " .. count .. " virtual actors. No Player entities were created.")
end)

concommand.Add("drp_loadtest_incidents", function(ply, _, arguments)
	if not commandAllowed(ply) then return end
	local ok, result = LoadTest:QueueIncidents(arguments[1])
	respond(ply, ok and ("Queued " .. result .. " synthetic incidents.") or result, ok and 1 or 3)
end)

concommand.Add("drp_loadtest_tick", function(ply, _, arguments)
	if not commandAllowed(ply) then return end
	local ok, result = LoadTest:RunTicks(arguments[1])
	respond(ply, ok and ("Running " .. result .. " virtual ticks across server frames.") or result, ok and 1 or 3)
end)

concommand.Add("drp_loadtest_report", function(ply)
	if not commandAllowed(ply) then return end
	local report = LoadTest:Report()
	if IsValid(ply) then DRP.Net.Notify(ply, string.format("Load test: %d actors, %d ticks, %d incidents.", report.actors, report.ticks, report.resolved), 1) end
end)

concommand.Add("drp_loadtest_clear", function(ply)
	if not commandAllowed(ply) then return end
	LoadTest:Clear()
	respond(ply, "Virtual load-test state cleared.")
end)
