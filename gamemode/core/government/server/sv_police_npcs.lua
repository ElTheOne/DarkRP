local SYNC = "drp_police_routes_sync_v1"
local REQUEST = "drp_police_routes_request_v1"
local MANAGE = "drp_police_routes_manage_v1"
util.AddNetworkString(SYNC)
util.AddNetworkString(REQUEST)
util.AddNetworkString(MANAGE)

local PoliceNPCs = {
	Routes = {},
	Recordings = setmetatable({}, { __mode = "k" }),
	Active = {},
	ByEntity = setmetatable({}, { __mode = "k" }),
	Enforcement = setmetatable({}, { __mode = "k" }),
	PendingArrest = setmetatable({}, { __mode = "k" }),
	MinimumCoverage = 3,
	MaximumNPCs = 3,
	PatrolInterval = 0.5,
	PerceptionRange = 1100,
	TaseRange = 96,
	Started = false,
	LastSpawnError = nil,
	LastReconcileAt = 0,
	RoutePath = "darkrp/police_routes_" .. game.GetMap() .. ".json"
}

DRP.PoliceNPCs = PoliceNPCs
DRP.Services.Register("police_npcs", PoliceNPCs)
DRP.Services.DependsOn("police_npcs", { "legal", "evidence_scanner", "properties", "inventory" })

local function headAdmin(ply)
	return IsValid(ply) and DRP.Admin and DRP.Admin.CanSetRanks and DRP.Admin.CanSetRanks(ply)
end

local function clean(value, maximum)
	return string.sub(string.Trim(tostring(value or "")), 1, maximum or 64)
end

local function cleanRouteName(value)
	value = string.gsub(clean(value, 40), "[^%w_%- ]", "")
	value = string.gsub(string.Trim(value), "%s+", "_")
	return string.sub(value, 1, 40)
end

local function vectorTable(value)
	return { x = math.Round(value.x, 2), y = math.Round(value.y, 2), z = math.Round(value.z, 2) }
end

local function angleTable(value)
	return { p = math.Round(value.p, 2), y = math.Round(value.y, 2), r = math.Round(value.r, 2) }
end

local function toVector(value)
	return Vector(tonumber(value and value.x) or 0, tonumber(value and value.y) or 0, tonumber(value and value.z) or 0)
end

local function toAngle(value)
	return Angle(tonumber(value and value.p) or 0, tonumber(value and value.y) or 0, tonumber(value and value.r) or 0)
end

local function validPlayer(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:Alive() and ply.DRPReady and ply:DRPReady()
		and not (DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(ply))
end

function PoliceNPCs:Load()
	local decoded = util.JSONToTable(file.Read(self.RoutePath, "DATA") or "")
	self.Routes = istable(decoded) and istable(decoded.routes) and decoded.routes or {}
	for name, route in pairs(table.Copy(self.Routes)) do
		if not istable(route) or not istable(route.nodes) or #route.nodes < 2 then
			self.Routes[name] = nil
		else
			route.npc_count = math.Clamp(math.floor(tonumber(route.npc_count) or self.MaximumNPCs), 0, self.MaximumNPCs)
		end
	end
end

function PoliceNPCs:Save(expectedRoute)
	file.CreateDir("darkrp")
	local encoded = util.TableToJSON({ version = 2, routes = self.Routes }, true)
	if not encoded then return false, "Route data could not be encoded." end
	file.Write(self.RoutePath, encoded)
	local verified = util.JSONToTable(file.Read(self.RoutePath, "DATA") or "")
	if not istable(verified) or not istable(verified.routes) then
		return false, "Route file could not be verified after writing."
	end
	if expectedRoute and not istable(verified.routes[expectedRoute]) then
		return false, "The saved route was missing from the verified route file."
	end
	return true
end

local function routeSummaries(routes)
	local activeCounts = {}
	for _, record in ipairs(PoliceNPCs.Active) do
		if IsValid(record.entity) and isstring(record.routeName) then
			activeCounts[record.routeName] = (activeCounts[record.routeName] or 0) + 1
		end
	end
	local names = {}
	for name in pairs(routes) do names[#names + 1] = name end
	table.sort(names)
	local summaries = {}
	for index = 1, math.min(#names, 128) do
		local route = routes[names[index]]
		summaries[index] = {
			name = names[index],
			nodes = #(route.nodes or {}),
			npc_count = math.Clamp(math.floor(tonumber(route.npc_count) or PoliceNPCs.MaximumNPCs), 0, PoliceNPCs.MaximumNPCs),
			active = activeCounts[names[index]] or 0,
			updated = math.max(0, math.floor(tonumber(route.updated) or 0))
		}
	end
	return summaries
end

function PoliceNPCs:SendRoute(ply, route, state, status)
	if not IsValid(ply) then return end
	route = istable(route) and route or { nodes = {} }
	local payload = {
		name = clean(route.name, 40),
		nodes = istable(route.nodes) and route.nodes or {},
		state = clean(state or "preview", 16),
		status = clean(status, 160),
		routes = routeSummaries(self.Routes)
	}
	local encoded = util.TableToJSON(payload, false) or "{}"
	local compressed = util.Compress(encoded)
	if not compressed or #compressed > 60000 then return end
	net.Start(SYNC)
	net.WriteUInt(#compressed, 16)
	net.WriteData(compressed, #compressed)
	net.Send(ply)
end

function PoliceNPCs:BeginRecording(ply, name)
	if not headAdmin(ply) then return false, "HeadAdmin+ is required." end
	name = cleanRouteName(name)
	if name == "" then return false, "Enter a route name in the tool settings." end
	local record = { name = name, nodes = {}, lastPosition = ply:GetPos(), started = CurTime() }
	record.nodes[1] = { pos = vectorTable(ply:GetPos()), ang = angleTable(ply:EyeAngles()), action = "walk", wait = 0 }
	self.Recordings[ply] = record
	self:SendRoute(ply, record, "recording", "Recording started. Walk the route; movement points are captured automatically.")
	DRP.Net.Notify(ply, "Recording police route '" .. name .. "'. Walk normally; left-click records actions, right-click saves.", 1)
	return true
end

function PoliceNPCs:NextRouteName(savedName)
	local base = string.gsub(cleanRouteName(savedName), "_%d+$", "")
	if base == "" then base = "downtown_patrol" end
	local suffix = 1
	while self.Routes[base .. "_" .. suffix] do suffix = suffix + 1 end
	return string.sub(base .. "_" .. suffix, 1, 40)
end

function PoliceNPCs:CaptureStep(ply, forced)
	local record = self.Recordings[ply]
	if not record or not headAdmin(ply) then return false end
	local position = ply:GetPos()
	if not forced and position:DistToSqr(record.lastPosition) < 64 * 64 then return false end
	record.nodes[#record.nodes + 1] = { pos = vectorTable(position), ang = angleTable(ply:EyeAngles()), action = "walk", wait = 0 }
	record.lastPosition = position
	if forced or #record.nodes % 4 == 0 then
		self:SendRoute(ply, record, "recording", "Captured movement node " .. #record.nodes .. ".")
	end
	return true
end

function PoliceNPCs:RecordAction(ply, action, trace, routeName, waitSeconds)
	local record = self.Recordings[ply]
	if not record then return self:BeginRecording(ply, routeName) end
	action = clean(action, 16):lower()
	if action ~= "wait" and action ~= "scan" and action ~= "use" then action = "walk" end
	self:CaptureStep(ply, true)
	local node = record.nodes[#record.nodes]
	node.action = action
	if action == "wait" then node.wait = math.Clamp(tonumber(waitSeconds) or 3, 1, 30) end
	if action == "use" and trace and IsValid(trace.Entity) then
		node.map_id = math.max(0, trace.Entity:MapCreationID())
		node.class = clean(trace.Entity:GetClass(), 64)
	end
	self:SendRoute(ply, record, "recording", "Recorded " .. action .. " action at node " .. #record.nodes .. ".")
	DRP.Net.Notify(ply, "Recorded " .. action .. " action at node " .. #record.nodes .. ".", 0)
	return true
end

function PoliceNPCs:FinishRecording(ply)
	local record = self.Recordings[ply]
	if not record or not headAdmin(ply) then return false, "No route is being recorded." end
	self:CaptureStep(ply, true)
	if #record.nodes < 2 then return false, "A route needs at least two nodes." end
	local previous = self.Routes[record.name]
	local completed = {
		name = record.name,
		nodes = record.nodes,
		npc_count = previous and previous.npc_count or self.MaximumNPCs,
		updated = os.time(),
		author = ply:SteamID64()
	}
	self.Routes[record.name] = completed
	local saved, failure = self:Save(record.name)
	if not saved then
		self.Routes[record.name] = previous
		return false, failure or "The route could not be saved."
	end
	self.Recordings[ply] = nil
	local nextName = self:NextRouteName(record.name)
	ply:ConCommand("drp_police_route_route_name " .. nextName)
	self:SendRoute(ply, { name = nextName, nodes = {} }, "ready",
		"Saved '" .. record.name .. "'. Ready to record a new route as '" .. nextName .. "'.")
	-- A newly-created route must become usable immediately. Previously this was
	-- delegated entirely to a deadline and any spawn failure was silent, which
	-- made a successfully saved route appear to do nothing.
	self:Reconcile("route_saved")
	if DRP.Audit then DRP.Audit.Log(ply, "police_route_saved", nil, record.name .. " nodes=" .. #record.nodes) end
	local desired = self:DesiredCount()
	local suffix = desired > 0
		and (" Patrol coverage is now " .. #self.Active .. "/" .. desired .. ".")
		or " No NPC coverage is required while enough human police are active."
	if self.LastSpawnError then suffix = " NPC spawn failed: " .. self.LastSpawnError end
	DRP.Net.Notify(ply, "Saved police route '" .. record.name .. "' with " .. #record.nodes .. " nodes." .. suffix,
		self.LastSpawnError and 2 or 1)
	return true
end

function PoliceNPCs:CancelRecording(ply)
	if not self.Recordings[ply] then return false, "No route is currently being recorded." end
	self.Recordings[ply] = nil
	self:SendRoute(ply, { nodes = {} }, "cancelled", "Route recording cancelled.")
	DRP.Net.Notify(ply, "Police route recording cancelled.", 2)
	return true
end

function PoliceNPCs:DeleteRoute(ply, name)
	if not headAdmin(ply) then return false, "HeadAdmin+ is required." end
	name = cleanRouteName(name)
	if not self.Routes[name] then return false, "That route no longer exists." end
	for _, recording in pairs(self.Recordings) do
		if recording.name == name then return false, "That route is currently being recorded." end
	end
	local removedRoute = self.Routes[name]
	self.Routes[name] = nil
	local saved, failure = self:Save()
	if not saved then
		self.Routes[name] = removedRoute
		return false, failure
	end
	for _, record in ipairs(self.Active) do
		if record.routeName == name then
			record.routeName, record.route, record.commandedNode = nil, nil, nil
			self:AssignNearestRoute(record)
		end
	end
	self:Reconcile("route_deleted")
	if DRP.Audit then DRP.Audit.Log(ply, "police_route_deleted", nil, name) end
	return true, "Deleted route '" .. name .. "'."
end

function PoliceNPCs:SetRouteNPCCount(ply, name, amount)
	if not headAdmin(ply) then return false, "HeadAdmin+ is required." end
	name = cleanRouteName(name)
	local route = self.Routes[name]
	if not route then return false, "That route no longer exists." end
	amount = tonumber(amount)
	if not amount or amount < 0 or amount > self.MaximumNPCs then
		return false, "NPC allocation must be between 0 and " .. self.MaximumNPCs .. "."
	end
	amount = math.floor(amount)
	local previous = route.npc_count
	route.npc_count = amount
	route.updated = os.time()
	local saved, failure = self:Save(name)
	if not saved then
		route.npc_count = previous
		return false, failure
	end
	self:Reconcile("route_allocation_changed")
	if DRP.Audit then DRP.Audit.Log(ply, "police_route_allocation", nil, name .. " npcs=" .. amount) end
	return true, "Route '" .. name .. "' now allows " .. amount .. " police NPC" .. (amount == 1 and "" or "s") .. "."
end

function PoliceNPCs:RenameRoute(ply, oldName, newName)
	if not headAdmin(ply) then return false, "HeadAdmin+ is required." end
	oldName, newName = cleanRouteName(oldName), cleanRouteName(newName)
	if newName == "" then return false, "Enter a valid route name." end
	if not self.Routes[oldName] then return false, "That route no longer exists." end
	if oldName ~= newName and self.Routes[newName] then return false, "A route with that name already exists." end
	for _, recording in pairs(self.Recordings) do
		if recording.name == oldName then return false, "That route is currently being recorded." end
	end
	if oldName == newName then return true, "The route name is unchanged." end
	local route = self.Routes[oldName]
	self.Routes[oldName] = nil
	self.Routes[newName] = route
	route.name, route.updated = newName, os.time()
	local saved, failure = self:Save(newName)
	if not saved then
		self.Routes[newName], self.Routes[oldName], route.name = nil, route, oldName
		return false, failure
	end
	for _, record in ipairs(self.Active) do
		if record.routeName == oldName then record.routeName, record.route = newName, route end
	end
	if DRP.Audit then DRP.Audit.Log(ply, "police_route_renamed", nil, oldName .. " -> " .. newName) end
	return true, "Renamed route '" .. oldName .. "' to '" .. newName .. "'."
end

function PoliceNPCs:PreviewRoute(ply, name)
	if not headAdmin(ply) then return false, "HeadAdmin+ is required." end
	name = cleanRouteName(name)
	local route = self.Routes[name]
	if not route then return false, "That route no longer exists." end
	self:SendRoute(ply, route, "preview", "Previewing saved route '" .. name .. "'.")
	return true
end

DRP.Net.Receive(REQUEST, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not headAdmin(ply)
		or not DRP.Net.Allow(ply, "police_route_list", 0.5, 3) then return end
	local record = PoliceNPCs.Recordings[ply]
	PoliceNPCs:SendRoute(ply, record or { name = ply:GetInfo("drp_police_route_route_name"), nodes = {} },
		record and "recording" or "ready", record and "Route recording is active." or "Ready to record a police patrol route.")
end)

DRP.Net.Receive(MANAGE, function(length, ply)
	if length > 4096 or net.ReadUInt(8) ~= DRP.ProtocolVersion or not headAdmin(ply)
		or not DRP.Net.Allow(ply, "police_route_manage", 0.2, 5) then return end
	local action = net.ReadUInt(3)
	local name = cleanRouteName(net.ReadString())
	local value = clean(net.ReadString(), 40)
	local ok, reason
	if action == 1 then
		ok, reason = PoliceNPCs:PreviewRoute(ply, name)
	elseif action == 2 then
		ok, reason = PoliceNPCs:SetRouteNPCCount(ply, name, tonumber(value))
	elseif action == 3 then
		ok, reason = PoliceNPCs:RenameRoute(ply, name, value)
	elseif action == 4 then
		ok, reason = PoliceNPCs:DeleteRoute(ply, name)
	else
		return
	end
	if reason then DRP.Net.Notify(ply, reason, ok and 1 or 2) end
	if ok and action ~= 1 then
		PoliceNPCs:SendRoute(ply, { name = name, nodes = {} }, "ready", reason or "Route updated.")
	end
end)

local function humanPoliceCount()
	local count = 0
	for _, ply in ipairs((DRP.Players and DRP.Players.List) or {}) do
		if IsValid(ply) and ply:IsPlayer() and not ply:IsBot() and ply.DRPReady and ply:DRPReady()
			and not (DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(ply))
			and ply.DRPJob and ply:DRPJob().isPolice then count = count + 1 end
	end
	return count
end

function PoliceNPCs:DesiredCount()
	if next(self.Routes) == nil then return 0 end
	local allocated = 0
	for _, route in pairs(self.Routes) do
		allocated = allocated + math.Clamp(math.floor(tonumber(route.npc_count) or self.MaximumNPCs), 0, self.MaximumNPCs)
	end
	return math.min(math.Clamp(self.MinimumCoverage - humanPoliceCount(), 0, self.MaximumNPCs), allocated)
end

local function activeRouteCounts()
	local counts = {}
	for _, record in ipairs(PoliceNPCs.Active) do
		if IsValid(record.entity) and isstring(record.routeName) then
			counts[record.routeName] = (counts[record.routeName] or 0) + 1
		end
	end
	return counts
end

local function orderedRoutes(onlyAvailable)
	local activeCounts = onlyAvailable and activeRouteCounts() or nil
	local output = {}
	for name, route in pairs(PoliceNPCs.Routes) do
		local allocation = math.Clamp(math.floor(tonumber(route.npc_count) or PoliceNPCs.MaximumNPCs), 0, PoliceNPCs.MaximumNPCs)
		if not onlyAvailable or (activeCounts[name] or 0) < allocation then
			output[#output + 1] = {
				name = name,
				route = route,
				allocation = allocation,
				active = activeCounts and (activeCounts[name] or 0) or 0
			}
		end
	end
	table.sort(output, function(a, b) return a.name < b.name end)
	return output
end

function PoliceNPCs:NearestRoute(position)
	if not isvector(position) then return nil end
	local nearestName, nearestRoute, nearestNode, nearestDistance
	for name, route in pairs(self.Routes) do
		if math.Clamp(math.floor(tonumber(route.npc_count) or self.MaximumNPCs), 0, self.MaximumNPCs) > 0 then
			for nodeIndex, node in ipairs(route.nodes or {}) do
				if istable(node) and istable(node.pos) then
					local distance = position:DistToSqr(toVector(node.pos))
					if not nearestDistance or distance < nearestDistance then
						nearestName, nearestRoute, nearestNode, nearestDistance = name, route, nodeIndex, distance
					end
				end
			end
		end
	end
	return nearestName, nearestRoute, nearestNode, nearestDistance
end

function PoliceNPCs:AssignNearestRoute(record)
	if not istable(record) or not IsValid(record.entity) then return false end
	local name, route, node = self:NearestRoute(record.entity:GetPos())
	if not name then return false end
	record.routeName, record.route, record.node = name, route, node
	record.commandedNode, record.nextRouteCommand = nil, 0
	record.entity.DRPPoliceRoute = name
	return true
end

function PoliceNPCs:SpawnOne()
	local routes = orderedRoutes(true)
	if #routes == 0 then return false, "no saved patrol routes" end
	table.sort(routes, function(a, b)
		local aRatio = a.allocation > 0 and a.active / a.allocation or 1
		local bRatio = b.allocation > 0 and b.active / b.allocation or 1
		if aRatio == bRatio then return a.name < b.name end
		return aRatio < bRatio
	end)
	local selected = routes[1]
	if not istable(selected.route) or not istable(selected.route.nodes) or #selected.route.nodes < 2 then
		return false, "route '" .. tostring(selected.name) .. "' has fewer than two valid nodes"
	end
	-- Spread multiple assigned patrols over the route instead of stacking every
	-- NPC at node one. Their starting node remains deterministic after restart.
	local startNode = math.Clamp(math.floor(selected.active * #selected.route.nodes / math.max(1, selected.allocation)) + 1,
		1, #selected.route.nodes)
	local first = selected.route.nodes[startNode]
	if not istable(first) or not istable(first.pos) then
		return false, "route '" .. tostring(selected.name) .. "' has an invalid spawn node"
	end
	local spawnPosition = toVector(first.pos)
	if util.IsInWorld and not util.IsInWorld(spawnPosition) then
		return false, "route '" .. tostring(selected.name) .. "' starts outside the map"
	end
	local npc = ents.Create("npc_metropolice")
	if not IsValid(npc) then return false, "npc_metropolice could not be created" end
	npc:SetPos(spawnPosition)
	npc:SetAngles(Angle(0, toAngle(first.ang).y, 0))
	-- Keep the ordinary police AI while preventing an NPC weapon drop from
	-- becoming a free, repeatable loot source when patrol coverage respawns.
	npc:SetKeyValue("spawnflags", "8192")
	npc:SetKeyValue("additionalequipment", "weapon_pistol")
	npc:Spawn()
	npc:Activate()
	if not IsValid(npc) then return false, "npc_metropolice became invalid during spawn" end
	local weapon = npc.GetActiveWeapon and npc:GetActiveWeapon() or nil
	if not IsValid(weapon) or weapon:GetClass() ~= "weapon_pistol" then
		npc:Fire("GiveWeapon", "weapon_pistol", 0)
		if npc.Give then npc:Give("weapon_pistol") end
	end
	if npc.CapabilitiesAdd then
		local capabilities = bit.bor(tonumber(CAP_MOVE_GROUND) or 0, tonumber(CAP_OPEN_DOORS) or 0,
			tonumber(CAP_AUTO_DOORS) or 0, tonumber(CAP_USE_WEAPONS) or 0)
		if capabilities ~= 0 then npc:CapabilitiesAdd(capabilities) end
	end
	if npc.SetNPCState then npc:SetNPCState(NPC_STATE_ALERT) end
	npc:SetHealth(100)
	npc.DRPPoliceNPC = true
	npc.DRPPoliceRoute = selected.name
	npc:AddRelationship("player D_NU 50")
	local record = {
		entity = npc,
		routeName = selected.name,
		route = selected.route,
		node = startNode,
		waitUntil = 0,
		lastProgressAt = CurTime(),
		lastPosition = npc:GetPos(),
		nextRouteCommand = 0,
		nextPerception = CurTime() + math.Rand(0.1, 0.5)
	}
	self.Active[#self.Active + 1] = record
	self.ByEntity[npc] = record
	return true, nil, npc
end

function PoliceNPCs:RemoveOne()
	local record = table.remove(self.Active)
	if not record then return false end
	if IsValid(record.entity) then record.entity:Remove() end
	return true
end

function PoliceNPCs:Reconcile(reason)
	self.LastReconcileAt = CurTime()
	for index = #self.Active, 1, -1 do
		if not IsValid(self.Active[index].entity) then table.remove(self.Active, index) end
	end
	-- Enforce route-specific allocations before filling global coverage. This
	-- makes setting a route to zero authoritative instead of leaving its old
	-- patrols alive merely because the global total still matches.
	local routeCounts = activeRouteCounts()
	for index = #self.Active, 1, -1 do
		local record = self.Active[index]
		local routeName = record.routeName
		local route = routeName and self.Routes[routeName] or nil
		local allocation = route and math.Clamp(math.floor(tonumber(route.npc_count) or self.MaximumNPCs), 0, self.MaximumNPCs) or 0
		local currentCount = routeName and (routeCounts[routeName] or 0) or 1
		if not route or currentCount > allocation then
			if routeName then routeCounts[routeName] = math.max(0, currentCount - 1) end
			table.remove(self.Active, index)
			if IsValid(record.entity) then record.entity:Remove() end
		end
	end
	local desired = self:DesiredCount()
	if #self.Active < desired then
		local spawned, failure = self:SpawnOne()
		self.LastSpawnError = spawned and nil or tostring(failure or "unknown spawn failure")
		if not spawned then
			ErrorNoHalt("[DRP POLICE NPC] spawn failed during " .. tostring(reason or "reconcile") .. ": "
				.. self.LastSpawnError .. "\n")
		end
	elseif #self.Active > desired then self:RemoveOne() end
	if #self.Active ~= desired and not self.LastSpawnError then self:ScheduleReconcile(1) end
	self:ArmPatrol()
	return #self.Active, desired, self.LastSpawnError
end

function PoliceNPCs:ScheduleReconcile(delay)
	DRP.Deadlines.Schedule("police_npcs:reconcile", CurTime() + math.max(0.1, tonumber(delay) or 2), function() self:Reconcile() end)
end

local function lineVisible(npc, target)
	local trace = util.TraceLine({ start = npc:EyePos(), endpos = target:WorldSpaceCenter(), filter = { npc, target }, mask = MASK_VISIBLE_AND_NPCS })
	return not trace.Hit or trace.Fraction >= 0.98
end

local function heldIllegalWeapon(ply)
	local weapon = ply:GetActiveWeapon()
	if not IsValid(weapon) then return false end
	local class = string.lower(weapon:GetClass())
	return not ply:GetNW2Bool("DRPGunLicense", false) and not (DRP.PVP and DRP.PVP.IgnoredWeapons[class])
end

local function inventoryIllegal(ply)
	local licensed = ply:GetNW2Bool("DRPGunLicense", false)
	for _, item in ipairs(DRP.Inventory and DRP.Inventory.Items(ply) or {}) do
		local class = string.lower(tostring(item.class or item.entityClass or ""))
		local kind = string.lower(tostring(item.kind or ""))
		if (kind == "weapon" and not licensed and not (DRP.PVP and DRP.PVP.IgnoredWeapons[class]))
			or kind == "drug" or string.find(class, "drug", 1, true) or string.find(class, "cocaine", 1, true)
			or string.StartWith(class, "zmlab2_") or string.StartWith(class, "zwf_") then return true end
	end
	return false
end

function PoliceNPCs:MarkForEnforcement(record, suspect, reason)
	if not validPlayer(suspect) or suspect:DRPJob().isPolice or DRP.Legal.Arrested[suspect] or self.PendingArrest[suspect] then return false end
	local current = self.Enforcement[suspect]
	if current then
		if current.npc ~= record.entity then return false end
		current.seen = CurTime()
		if not current.hostile then current.reason = clean(reason, 120) end
		return true
	end
	self.Enforcement[suspect] = { npc = record.entity, reason = clean(reason, 120), seen = CurTime(), hostile = false }
	record.commandedNode, record.nextRouteCommand = nil, 0
	suspect:SetNW2String("DRPWantedReason", clean(reason, 120))
	DRP.Net.Notify(suspect, "Police patrol detected " .. reason .. ". Comply with the approaching officer.", 2)
	return true
end

function PoliceNPCs:ScanBase(record)
	local npc = record.entity
	for _, entity in ipairs(ents.FindInSphere(npc:GetPos(), 700)) do
		local kind = DRP.Legal and DRP.Legal.EvidenceScanner and DRP.Legal.EvidenceScanner:IllegalKind(entity)
		if kind and lineVisible(npc, entity) then
			local owner = DRP.Props and DRP.Props.Owner and DRP.Props.Owner(entity)
			if validPlayer(owner) then self:MarkForEnforcement(record, owner, kind .. " in a visible property area") end
		end
	end
end

function PoliceNPCs:ArrestOnSpot(npc, suspect, reason)
	if not validPlayer(suspect) or DRP.Legal.Arrested[suspect] then return false end
	self.PendingArrest[suspect] = nil
	local deadline = CurTime() + DRP.Legal.ArrestDuration
	DRP.Legal.TasedUntil[suspect] = nil
	DRP.Legal.TasedCustody[suspect] = nil
	suspect:SetNW2Float("DRPTasedUntil", 0)
	DRP.Legal.Arrested[suspect] = { sourceID = 0, officer = npc, startedAt = CurTime(), deadline = deadline, npc = true }
	if DRP.Legal.ClearCuffs then DRP.Legal.ClearCuffs(suspect, true) end
	if DRP.Incidents and DRP.Incidents.ClearPlayer then
		DRP.Incidents.ClearPlayer(suspect, "suspect_arrested", "Active incidents cleared by an NPC arrest", { officer = npc, npc = true })
	end
	suspect:StripWeapons()
	suspect:Lock()
	suspect:SetNW2Bool("DRPArrested", true)
	local saved = util.JSONToTable(file.Read("darkrp/jail_" .. game.GetMap() .. ".json", "DATA") or "")
	if istable(saved) and saved.x then suspect:SetPos(Vector(saved.x, saved.y, saved.z)) end
	DRP.Deadlines.Schedule("legal:custody:" .. suspect:SteamID64(), deadline, function()
		if IsValid(suspect) and DRP.Legal.Arrested[suspect] then DRP.Legal.Release(suspect, "NPC sentence served") end
	end)
	self.Enforcement[suspect] = nil
	DRP.Net.Notify(suspect, "A police patrol arrested you on the spot for " .. clean(reason, 100) .. ".", 2)
	if DRP.Audit then DRP.Audit.Log(nil, "police_npc_arrest", suspect, clean(reason, 120)) end
	return true
end

function PoliceNPCs:Enforce(record, suspect, state)
	local npc = record.entity
	if not validPlayer(suspect) or not IsValid(npc) or DRP.Legal.Arrested[suspect] then
		self.Enforcement[suspect] = nil
		self.PendingArrest[suspect] = nil
		return
	end
	local distance = npc:GetPos():Distance(suspect:GetPos())
	if state.hostile then
		npc:AddEntityRelationship(suspect, D_HT, 99)
		npc:SetEnemy(suspect)
		npc:UpdateEnemyMemory(suspect, suspect:GetPos())
		if npc.SetNPCState then npc:SetNPCState(NPC_STATE_COMBAT) end
		if not state.combatScheduled then
			state.combatScheduled = true
			npc:ClearSchedule()
			npc:SetSchedule(SCHED_CHASE_ENEMY)
		end
		return
	end
	if distance > self.PerceptionRange * 1.5 then return end
	npc:SetLastPosition(suspect:GetPos())
	if not state.nextApproachCommand or state.nextApproachCommand <= CurTime() then
		npc:SetSchedule(SCHED_FORCED_GO_RUN)
		state.nextApproachCommand = CurTime() + 1
	end
	-- This is a simulated close-contact taser, not a long-range hitscan. The
	-- officer must reach the suspect and retain line of sight before restraint.
	if distance <= self.TaseRange and lineVisible(npc, suspect) then
		local untilTime = CurTime() + 3
		DRP.Legal.TasedUntil[suspect] = untilTime
		suspect:SetNW2Float("DRPTasedUntil", untilTime)
		suspect:ScreenFade(SCREENFADE.IN, Color(90, 175, 255, 115), 0.25, 0.15)
		suspect:EmitSound("ambient/energy/zap1.wav", 75, 110, 0.8)
		DRP.Net.Notify(suspect, "A police patrol tased you and is processing an immediate arrest.", 2)
		self.Enforcement[suspect] = nil
		self.PendingArrest[suspect] = true
		DRP.Deadlines.Schedule("police_npcs:arrest:" .. suspect:SteamID64(), CurTime() + 2, function()
			if IsValid(npc) and validPlayer(suspect) then
				self:ArrestOnSpot(npc, suspect, state.reason)
			else
				self.PendingArrest[suspect] = nil
			end
		end)
	end
end

function PoliceNPCs:Perceive(record)
	local npc = record.entity
	local closest, closestDistance
	for _, entity in ipairs(ents.FindInSphere(npc:GetPos(), self.PerceptionRange)) do
		if validPlayer(entity) and not entity:DRPJob().isPolice and (heldIllegalWeapon(entity) or inventoryIllegal(entity)) then
			local distance = npc:GetPos():DistToSqr(entity:GetPos())
			if (not closestDistance or distance < closestDistance) and lineVisible(npc, entity) then closest, closestDistance = entity, distance end
		end
	end
	if closest then self:MarkForEnforcement(record, closest, heldIllegalWeapon(closest) and "an unlicensed drawn weapon" or "illegal items") end
end

function PoliceNPCs:AdvanceRoute(record, now)
	local npc, route = record.entity, self.Routes[record.routeName] or record.route
	if not IsValid(npc) then return end
	if not route or #(route.nodes or {}) == 0 then
		if not self:AssignNearestRoute(record) then return end
		route = record.route
	end
	record.route = route
	if record.waitUntil > now then return end
	local node = route.nodes[record.node] or route.nodes[1]
	local position = toVector(node.pos)
	if npc:GetPos():DistToSqr(position) <= 80 * 80 then
		if node.action == "use" and tonumber(node.map_id) and tonumber(node.map_id) > 0 then
			local target = ents.GetMapCreatedEntity(tonumber(node.map_id))
			if IsValid(target) then target:Use(npc, npc, USE_ON, 1) end
		elseif node.action == "scan" then self:ScanBase(record)
		elseif node.action == "wait" then record.waitUntil = now + math.Clamp(tonumber(node.wait) or 3, 1, 30) end
		record.node = record.node % #route.nodes + 1
		node = route.nodes[record.node]
		position = toVector(node.pos)
	end
	local currentPosition = npc:GetPos()
	if not record.lastPosition or currentPosition:DistToSqr(record.lastPosition) >= 18 * 18 then
		record.lastPosition, record.lastProgressAt = currentPosition, now
	end
	local stalled = now - (record.lastProgressAt or now) >= 2
	if record.commandedNode ~= record.node or stalled then
		record.commandedNode = record.node
		npc:SetLastPosition(position)
		npc:SetSchedule(SCHED_FORCED_GO_RUN)
		record.nextRouteCommand = now + 2
		if stalled then record.lastProgressAt = now end
	end
end

function PoliceNPCs:PatrolTick()
	local now = CurTime()
	local enforcingNPCs = setmetatable({}, { __mode = "k" })
	for suspect, state in pairs(self.Enforcement) do
		local record = IsValid(state.npc) and self.ByEntity[state.npc]
		if record then
			enforcingNPCs[state.npc] = true
			self:Enforce(record, suspect, state)
		else
			self.Enforcement[suspect] = nil
		end
	end
	for index = #self.Active, 1, -1 do
		local record = self.Active[index]
		if not IsValid(record.entity) then table.remove(self.Active, index)
		else
			if record.nextPerception <= now then record.nextPerception = now + 1 self:Perceive(record) end
			if not enforcingNPCs[record.entity] then self:AdvanceRoute(record, now) end
		end
	end
	if #self.Active > 0 then DRP.Deadlines.Schedule("police_npcs:patrol", now + self.PatrolInterval, function() self:PatrolTick() end) end
end

function PoliceNPCs:ArmPatrol()
	if #self.Active > 0 and not DRP.Deadlines.ByKey["police_npcs:patrol"] then
		DRP.Deadlines.Schedule("police_npcs:patrol", CurTime() + self.PatrolInterval, function() self:PatrolTick() end)
	end
end

function PoliceNPCs:Start()
	self.Started = true
	self.LastSpawnError = nil
	self:Load()
	hook.Add("SetupMove", "DRP.PoliceNPCs.RecordMovement", function(ply)
		if PoliceNPCs.Recordings[ply] then PoliceNPCs:CaptureStep(ply, false) end
	end)
	hook.Add("EntityTakeDamage", "DRP.PoliceNPCs.Threat", function(entity, damage)
		local record = PoliceNPCs.ByEntity[entity]
		local attacker = damage:GetAttacker()
		if record and validPlayer(attacker) then
			PoliceNPCs.Enforcement[attacker] = { npc = entity, reason = "assaulting a police officer", seen = CurTime(), hostile = true }
			return
		end
		local state = validPlayer(attacker) and PoliceNPCs.Enforcement[attacker]
		if state and IsValid(state.npc) and entity ~= attacker and damage:GetDamage() > 0 then
			state.reason = "using lethal force while being detained"
			state.hostile = true
			state.seen = CurTime()
		end
	end)
	hook.Add("OnNPCKilled", "DRP.PoliceNPCs.Repopulate", function(npc)
		if PoliceNPCs.ByEntity[npc] then PoliceNPCs:ScheduleReconcile(2) end
	end)
	hook.Add("EntityRemoved", "DRP.PoliceNPCs.EntityRemoved", function(entity)
		if PoliceNPCs.ByEntity[entity] then PoliceNPCs:ScheduleReconcile(2) end
	end)
	for _, event in ipairs({ "DRPPlayerReady", "DRPJobChanged", "PlayerDisconnected", "PlayerDeath" }) do
		local eventName = event
		hook.Add(eventName, "DRP.PoliceNPCs." .. eventName, function(ply)
			if eventName == "PlayerDisconnected" or eventName == "PlayerDeath" then
				PoliceNPCs.Enforcement[ply] = nil
				PoliceNPCs.PendingArrest[ply] = nil
			end
			PoliceNPCs:ScheduleReconcile(2)
		end)
	end
	hook.Add("PlayerDisconnected", "DRP.PoliceNPCs.RecordingDisconnect", function(ply)
		PoliceNPCs.Recordings[ply] = nil
		PoliceNPCs.Enforcement[ply] = nil
		PoliceNPCs.PendingArrest[ply] = nil
	end)
	hook.Add("PostCleanupMap", "DRP.PoliceNPCs.Cleanup", function() PoliceNPCs.Active = {} PoliceNPCs.ByEntity = setmetatable({}, { __mode = "k" }) PoliceNPCs:ScheduleReconcile(2) end)
	self:ScheduleReconcile(2)
	concommand.Add("drp_police_npc_status", function(ply)
		if IsValid(ply) and not headAdmin(ply) then return end
		print(string.format("[DRP POLICE NPC] started=%s routes=%d active=%d desired=%d human_police=%d recordings=%d last_error=%s", tostring(PoliceNPCs.Started), table.Count(PoliceNPCs.Routes), #PoliceNPCs.Active, PoliceNPCs:DesiredCount(), humanPoliceCount(), table.Count(PoliceNPCs.Recordings), tostring(PoliceNPCs.LastSpawnError or "none")))
		local names = {}
		for name in pairs(PoliceNPCs.Routes) do names[#names + 1] = name end
		table.sort(names)
		local routeActivity = activeRouteCounts()
		for index = 1, #names do
			local route = PoliceNPCs.Routes[names[index]]
			local active = routeActivity[names[index]] or 0
			print(string.format("  route=%s nodes=%d npcs=%d/%d updated=%s", names[index], #(route.nodes or {}), active,
				math.Clamp(math.floor(tonumber(route.npc_count) or PoliceNPCs.MaximumNPCs), 0, PoliceNPCs.MaximumNPCs),
				tostring(route.updated or "unknown")))
		end
	end)
	concommand.Add("drp_police_npc_reconcile", function(ply)
		if IsValid(ply) and not headAdmin(ply) then return end
		local active, desired, failure = PoliceNPCs:Reconcile("manual_command")
		local message = string.format("Police NPC reconciliation: active=%d desired=%d error=%s",
			active, desired, tostring(failure or "none"))
		print("[DRP POLICE NPC] " .. message)
		if IsValid(ply) then DRP.Net.Notify(ply, message, failure and 2 or 1) end
	end)
end

function PoliceNPCs:Stop()
	self.Started = false
	DRP.Deadlines.Cancel("police_npcs:patrol")
	DRP.Deadlines.Cancel("police_npcs:reconcile")
	for index = #self.Active, 1, -1 do self:RemoveOne() end
	for _, event in ipairs({ "SetupMove", "EntityTakeDamage", "OnNPCKilled", "EntityRemoved", "DRPPlayerReady", "DRPJobChanged", "PlayerDisconnected", "PlayerDeath", "PostCleanupMap" }) do
		hook.Remove(event, "DRP.PoliceNPCs." .. (event == "SetupMove" and "RecordMovement"
			or event == "EntityTakeDamage" and "Threat"
			or event == "OnNPCKilled" and "Repopulate"
			or event == "EntityRemoved" and "EntityRemoved"
			or event == "PostCleanupMap" and "Cleanup" or event))
	end
	hook.Remove("PlayerDisconnected", "DRP.PoliceNPCs.RecordingDisconnect")
end
