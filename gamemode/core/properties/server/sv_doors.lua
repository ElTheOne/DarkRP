local Doors = {
	Price = 100,
	Owners = {},
	ByPlayer = {},
	Policies = {},
	ByMapID = {},
	UseBurst = 2,
	UseRapidWindow = 1.25,
	UseCooldown = 2,
	BreachDuration = 120,
	Breached = setmetatable({}, { __mode = "k" }),
	BreachControllers = setmetatable({}, { __mode = "k" }),
	UseStates = setmetatable({}, { __mode = "k" }),
	UseDecisions = setmetatable({}, { __mode = "k" })
}

DRP.Doors = Doors
DRP.Services.Register("doors", Doors)

local function eyeTrace(ply)
	return util.TraceLine({
		start = ply:EyePos(),
		endpos = ply:EyePos() + ply:GetAimVector() * 128,
		filter = ply,
		mask = MASK_SOLID
	})
end

local validClasses = {
	prop_door_rotating = true,
	func_door = true,
	func_door_rotating = true
}

local adminRequestMessage = "drp_door_admin_request_v1"
local adminSnapshotMessage = "drp_door_admin_snapshot_v1"
local adminUpdateMessage = "drp_door_admin_update_v1"
local breachEffectMessage = "drp_door_breach_fx_v1"

util.AddNetworkString(adminRequestMessage)
util.AddNetworkString(adminSnapshotMessage)
util.AddNetworkString(adminUpdateMessage)
util.AddNetworkString(breachEffectMessage)

local function policyPath()
	return "darkrp/doors/" .. string.gsub(game.GetMap(), "[^%w_%-]", "_") .. ".json"
end

local function mapID(door)
	if not Doors.IsDoor(door) then return nil end
	local id = door:MapCreationID()
	if not id or id < 0 then return nil end
	return tostring(id)
end

Doors.MapID = mapID

local function breachDeadlineKey(door)
	return "door_breach:" .. tostring(mapID(door) or door:EntIndex())
end

local buttonClasses = {
	func_button = true,
	func_rot_button = true,
	momentary_rot_button = true
}

local function captureAssemblyPart(entity)
	return {
		entity = entity,
		noDraw = entity:GetNoDraw(),
		notSolid = isfunction(entity.GetNotSolid) and entity:GetNotSolid() or false,
		collisionGroup = entity:GetCollisionGroup()
	}
end

local function collectDoorAssembly(door)
	local parts, seen = {}, {}
	local function collect(entity)
		if not IsValid(entity) or seen[entity] then return end
		seen[entity] = true
		parts[#parts + 1] = captureAssemblyPart(entity)
		for _, child in ipairs(entity:GetChildren() or {}) do collect(child) end
	end
	collect(door)
	return parts
end

local function outputTargetsDoor(value, targetName)
	if isstring(value) then
		local target = string.Trim(string.match(value, "^([^,]+)") or value)
		return target == targetName
	end
	if not istable(value) then return false end
	for _, nested in pairs(value) do
		if outputTargetsDoor(nested, targetName) then return true end
	end
	return false
end

local function collectDoorControllers(door)
	local targetName = isfunction(door.GetName) and door:GetName() or ""
	if targetName == "" then return {} end
	local controllers = {}
	for _, entity in ents.Iterator() do
		if buttonClasses[entity:GetClass()] then
			local directTarget = entity:GetInternalVariable("m_target")
			local linked = directTarget == targetName
			if not linked then
				for key, value in pairs(entity:GetKeyValues() or {}) do
					if string.StartWith(string.lower(tostring(key)), "on") and outputTargetsDoor(value, targetName) then
						linked = true
						break
					end
				end
			end
			if linked then controllers[#controllers + 1] = entity end
		end
	end
	return controllers
end

local function setAssemblyBreached(state)
	for _, part in ipairs(state.parts or {}) do
		local entity = part.entity
		if IsValid(entity) then
			entity:SetNoDraw(true)
			entity:SetNotSolid(true)
		end
	end
end

local function setControllersBlocked(state, blocked)
	for _, controller in ipairs(state.controllers or {}) do
		if IsValid(controller) then
			local count = Doors.BreachControllers[controller] or 0
			Doors.BreachControllers[controller] = blocked and (count + 1) or math.max(0, count - 1)
			if Doors.BreachControllers[controller] == 0 then Doors.BreachControllers[controller] = nil end
		end
	end
end

function Doors:RestoreBreached(door, reason)
	local state = self.Breached[door]
	if not state then return false end
	DRP.Deadlines.Cancel(breachDeadlineKey(door))
	self.Breached[door] = nil
	setControllersBlocked(state, false)
	if IsValid(state.debris) then state.debris:Remove() end
	if not IsValid(door) then return false end

	-- This is the original map entity, not a replacement. Its MapCreationID,
	-- ownership table key, door policy, and property group link never change.
	door:SetPos(state.position)
	door:SetAngles(state.angles)
	for _, part in ipairs(state.parts or {}) do
		local entity = part.entity
		if IsValid(entity) then
			entity:SetNoDraw(part.noDraw)
			entity:SetNotSolid(part.notSolid)
			entity:SetCollisionGroup(part.collisionGroup)
		end
	end
	door.GSR_DoorBusted = false
	door.DRPTemporarilyBreached = nil
	door:Fire("Enable", "", 0)
	door:Fire("Close", "", 0)
	door:Fire(state.locked and "Lock" or "Unlock", "", 0.1)
	local owner = self.Owner(door)
	DRP.Net.SendDoor(door, owner)
	if DRP.Audit then DRP.Audit.Log(nil, "door_breach_restored", owner, (mapID(door) or "unmapped") .. ": " .. tostring(reason or "timer elapsed")) end
	return true
end

function Doors:BreachDoor(door, attacker, velocity, duration)
	if not self.IsDoor(door) or self.Breached[door] then return false end
	duration = math.Clamp(tonumber(duration) or self.BreachDuration, 1, 600)
	local state = {
		position = door:GetPos(),
		angles = door:GetAngles(),
		noDraw = door:GetNoDraw(),
		notSolid = isfunction(door.GetNotSolid) and door:GetNotSolid() or false,
		collisionGroup = door:GetCollisionGroup(),
		locked = door:GetInternalVariable("m_bLocked") == true or door:GetInternalVariable("m_bLocked") == 1,
		doorID = mapID(door),
		propertyID = DRP.Properties and DRP.Properties.DoorToProperty[mapID(door) or ""] or nil,
		deadline = CurTime() + duration,
		parts = collectDoorAssembly(door),
		controllers = collectDoorControllers(door)
	}
	self.Breached[door] = state
	setControllersBlocked(state, true)
	door.GSR_DoorBusted = true
	door.DRPTemporarilyBreached = true
	-- Do not open the map door: its movement and map outputs can restore brush
	-- collision. Disable it in place and block every subsequent input until the
	-- original entity is restored.
	state.allowInput = true
	door:Fire("Unlock", "", 0)
	door:Fire("Disable", "", 0)
	state.allowInput = false
	setAssemblyBreached(state)
	-- Source may finish a queued door input on the next frame. Reassert the
	-- breached state after those inputs have drained without running a timer.
	timer.Simple(0, function()
		if IsValid(door) and Doors.Breached[door] == state then setAssemblyBreached(state) end
	end)
	timer.Simple(0.1, function()
		if IsValid(door) and Doors.Breached[door] == state then setAssemblyBreached(state) end
	end)

	-- The detached-door visual has no gameplay authority. Clients simulate it
	-- locally so it never becomes a server physics object or snapshot entity.
	net.Start(breachEffectMessage)
	net.WriteString(door:GetModel() or "")
	net.WriteVector(state.position)
	net.WriteAngle(state.angles)
	net.WriteUInt(math.Clamp(door:GetSkin() or 0, 0, 255), 8)
	net.WriteVector(isvector(velocity) and velocity or vector_origin)
	net.WriteUInt(math.ceil(duration), 10)
	net.Broadcast()

	DRP.Deadlines.Schedule(breachDeadlineKey(door), state.deadline, function()
		Doors:RestoreBreached(door, "breach duration elapsed")
	end)
	if DRP.Audit then
		DRP.Audit.Log(attacker, "door_temporarily_breached", self.Owner(door), (state.doorID or "unmapped") .. " property #" .. tostring(state.propertyID or 0) .. " for " .. duration .. "s")
	end
	return true
end

function Doors:Start()
	file.CreateDir("darkrp")
	file.CreateDir("darkrp/doors")
	local decoded = util.JSONToTable(file.Read(policyPath(), "DATA") or "")
	if not istable(decoded) then return end
	for id, policy in pairs(decoded) do
		if istable(policy) then
			self.Policies[tostring(id)] = {
				ownable = policy.ownable ~= false,
					jobs = bit.band(math.floor(tonumber(policy.jobs) or 0), 65535)
			}
		end
	end
end

function Doors:SavePolicies()
	file.Write(policyPath(), util.TableToJSON(self.Policies, true))
end

function Doors:RebuildIndex()
	self.ByMapID = {}
	for _, entity in ents.Iterator() do
		local id = mapID(entity)
		if id then self.ByMapID[id] = entity end
	end
end

function Doors:Stop()
	local breached = {}
	for door in pairs(self.Breached) do breached[#breached + 1] = door end
	for _, door in ipairs(breached) do self:RestoreBreached(door, "door service stopping") end
	self:SavePolicies()
end

function Doors.IsDoor(entity)
	return IsValid(entity) and validClasses[entity:GetClass()] == true
end

function Doors.Owner(door)
	return Doors.Owners[door]
end

function Doors.Policy(door)
	local id = mapID(door)
	local policy = id and Doors.Policies[id]
	return policy or { ownable = true, jobs = 0 }, id
end

local function jobAllowed(ply, policy)
	if policy.jobs == 0 then return true end
	local jobBit = 2 ^ math.max(0, ply:DRPJobID() - 1)
	return bit.band(policy.jobs, jobBit) ~= 0
end

-- Expose the persistent door-policy job mask to property groups. A zero mask
-- means "not job-controlled" when requireConfigured is true; this prevents an
-- ordinary unrestricted door from granting every job access to an unbuyable
-- government property.
function Doors.JobAllowed(ply, door, requireConfigured)
	if not IsValid(ply) or not Doors.IsDoor(door) then return false end
	local policy = Doors.Policy(door)
	if requireConfigured and policy.jobs == 0 then return false end
	return jobAllowed(ply, policy)
end

function Doors.JobMask(door)
	if not Doors.IsDoor(door) then return 0 end
	local policy = Doors.Policy(door)
	return bit.band(math.floor(tonumber(policy.jobs) or 0), 65535)
end

function Doors.PlayerCanOwn(ply, door)
	if not IsValid(ply) or not Doors.IsDoor(door) then return false end
	local policy = Doors.Policy(door)
	return policy.ownable ~= false and jobAllowed(ply, policy)
end

local function canAccessDoor(ply, door)
	if DRP.Properties and DRP.Properties.CanAccessDoor then
		local allowed, controlled = DRP.Properties.CanAccessDoor(ply, door)
		if controlled then
			if allowed or (DRP.Admin and DRP.Admin.Has(ply, "doors")) then return true end
			local _, lease = DRP.Properties.ForDoor(door)
			if lease and DRP.Incidents then
				local owner = DRP.Players.Online(lease.owner_id)
				if IsValid(owner) and DRP.Incidents.Can(ply, owner, DRP.IncidentAction.ENTER_PROPERTY) then return true end
			end
			return false
		end
	end
	local policy = Doors.Policy(door)
	local owner = Doors.Owner(door)
	if IsValid(owner) and DRP.Incidents and DRP.Incidents.Can(ply, owner, DRP.IncidentAction.ENTER_PROPERTY) then return true end
	return policy.jobs == 0 or jobAllowed(ply, policy) or (DRP.Admin and DRP.Admin.Has(ply, "doors"))
end

Doors.CanAccess = canAccessDoor

function Doors.SetLocked(ply, locked)
	if not IsValid(ply) or not ply:DRPReady() then return false end
	local door = eyeTrace(ply).Entity
	if not Doors.IsDoor(door) or ply:GetPos():DistToSqr(door:GetPos()) > 16384 then return false end
	if Doors.Breached[door] then
		DRP.Net.Notify(ply, "That door is temporarily breached.", 2)
		return false
	end
	local owner = Doors.Owner(door)
	local policy = Doors.Policy(door)
	local propertyAllowed, propertyControlled = false, false
	if DRP.Properties and DRP.Properties.CanAccessDoor then propertyAllowed, propertyControlled = DRP.Properties.CanAccessDoor(ply, door) end
	local warrantAccess = (propertyControlled and canAccessDoor(ply, door)) or (IsValid(owner) and DRP.Incidents and DRP.Incidents.Can(ply, owner, DRP.IncidentAction.ENTER_PROPERTY))
	local permitted = owner == ply or (propertyControlled and propertyAllowed) or warrantAccess or (policy.jobs ~= 0 and jobAllowed(ply, policy)) or (DRP.Admin and DRP.Admin.Has(ply, "doors"))
	if not permitted then DRP.Net.Notify(ply, "Your keys do not control that door.", 3) return false end
	door:Fire(locked and "Lock" or "Unlock", "", 0)
	if locked then door:Fire("Close", "", 0) end
	DRP.Net.Notify(ply, locked and "Door locked." or "Door unlocked.", 0)
	return true
end

local function doorUseState(ply, door)
	local states = Doors.UseStates[ply]
	if not states then
		states = setmetatable({}, { __mode = "k" })
		Doors.UseStates[ply] = states
	end
	local state = states[door]
	if not state then
		state = { uses = 0, lastUse = 0, blockedUntil = 0 }
		states[door] = state
	end
	return state
end

local function evaluateDoorUse(ply, door)
	local state = doorUseState(ply, door)
	local now = CurTime()
	if state.blockedUntil > now then return false, state.blockedUntil - now end
	if now - state.lastUse > Doors.UseRapidWindow then state.uses = 0 end
	state.uses = state.uses + 1
	state.lastUse = now
	if state.uses >= Doors.UseBurst then state.blockedUntil = now + Doors.UseCooldown end
	return true
end

local function rememberUseDecision(ply, door)
	-- Ownership and job policy govern keys, not the use key. Any player may
	-- operate an unlocked door; Source itself rejects use while it is locked.
	if not Doors.IsDoor(door) then return end
	local allowed, remaining = evaluateDoorUse(ply, door)
	Doors.UseDecisions[ply] = { door = door, blocked = not allowed, used = false, createdAt = CurTime() }
	if not allowed and DRP.Net.Allow(ply, "door_use_cooldown", 1, 1) then
		DRP.Net.Notify(ply, string.format("Door use cooldown — wait %.1f seconds.", math.max(remaining or 0, 0)), 2)
	end
end

local function track(ply, door)
	local owned = Doors.ByPlayer[ply]
	if not owned then
		owned = {}
		Doors.ByPlayer[ply] = owned
	end
	owned[door] = true
end

function Doors.Assign(door, ply)
	if not Doors.IsDoor(door) or not IsValid(ply) then return false end
	Doors.Owners[door] = ply
	track(ply, door)
	DRP.Net.SendDoor(door, ply)
	if DRP.Audit then DRP.Audit.Log(ply, "door_owned", nil, mapID(door) or door:EntIndex()) end
	return true
end

function Doors.Clear(door)
	local owner = Doors.Owners[door]
	if not owner then return end
	Doors.Owners[door] = nil
	if Doors.ByPlayer[owner] then Doors.ByPlayer[owner][door] = nil end
	if IsValid(door) then DRP.Net.SendDoor(door) end
end

function Doors.Toggle(ply, door)
	if not IsValid(ply) or not ply:DRPReady() or not Doors.IsDoor(door) then return end
	if ply:GetPos():DistToSqr(door:GetPos()) > 16384 then return end
	if Doors.Breached[door] then
		DRP.Net.Notify(ply, "That door is temporarily breached.", 2)
		return
	end
	if DRP.Properties and DRP.Properties.ToggleDoor and DRP.Properties.ToggleDoor(ply, door) then return end
	local started = DRP.Profile.Begin()

	local owner = Doors.Owner(door)
	if owner == ply then
		Doors.Clear(door)
		DRP.Economy.Add(ply, math.floor(Doors.Price * 0.8), "door sold")
		if DRP.Audit then DRP.Audit.Log(ply, "door_sold", nil, mapID(door) or door:EntIndex()) end
		DRP.Profile.Finish("doors.toggle", started)
		return
	end
	if IsValid(owner) then
		DRP.Net.Notify(ply, "That door is already owned.", 3)
		DRP.Profile.Finish("doors.toggle", started)
		return
	end
	local policy = Doors.Policy(door)
	local doorAdmin = DRP.Admin and DRP.Admin.Has(ply, "doors")
	if not policy.ownable and not doorAdmin then
		DRP.Net.Notify(ply, "That door cannot be owned.", 3)
		DRP.Profile.Finish("doors.toggle", started)
		return
	end
	if not jobAllowed(ply, policy) and not doorAdmin then
		DRP.Net.Notify(ply, "Your job cannot own that door.", 3)
		DRP.Profile.Finish("doors.toggle", started)
		return
	end
	if not DRP.Economy.Take(ply, Doors.Price, "door purchased") then
		DRP.Net.Notify(ply, "You need $" .. Doors.Price .. " to buy this door.", 3)
		DRP.Profile.Finish("doors.toggle", started)
		return
	end
	Doors.Assign(door, ply)
	DRP.Profile.Finish("doors.toggle", started)
end

local function sendAdminSnapshot(ply, door)
	local policy, id = Doors.Policy(door)
	if not id then DRP.Net.Notify(ply, "That door is not a persistent map door.", 3) return end
	local owner = Doors.Owner(door)
	net.Start(adminSnapshotMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(door:EntIndex(), 13)
	net.WriteUInt(tonumber(id), 16)
	net.WriteString(door:GetClass())
	net.WriteBool(policy.ownable)
	net.WriteUInt(policy.jobs, 16)
	net.WriteString(IsValid(owner) and owner:Nick() or "Unowned")
	net.Send(ply)
end

DRP.Net.Receive(adminRequestMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "door_admin_panel", 0.75, 2) then return end
	if not DRP.Admin or not DRP.Admin.Has(ply, "doors") then return end
	local trace = eyeTrace(ply)
	if not Doors.IsDoor(trace.Entity) then DRP.Net.Notify(ply, "Look at a door first.", 2) return end
	if DRP.Audit then DRP.Audit.Log(ply, "door_panel_open", nil, mapID(trace.Entity) or trace.Entity:EntIndex()) end
	sendAdminSnapshot(ply, trace.Entity)
end)

DRP.Net.Receive(adminUpdateMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "door_admin_update", 0.5, 3) then return end
	if not DRP.Admin or not DRP.Admin.Has(ply, "doors") then return end
	local door = Entity(net.ReadUInt(13))
	local ownable = net.ReadBool()
	local jobs = bit.band(net.ReadUInt(16), (2 ^ #DRP.Jobs) - 1)
	if not Doors.IsDoor(door) or ply:GetPos():DistToSqr(door:GetPos()) > 65536 then return end
	local _, id = Doors.Policy(door)
	if not id then return end

	Doors.Policies[id] = { ownable = ownable, jobs = jobs }
	Doors:SavePolicies()
	if not ownable and Doors.Owner(door) then Doors.Clear(door) end
	DRP.Net.SendDoorPolicy(door, Doors.Policies[id])
	if DRP.Audit then DRP.Audit.Log(ply, "door_policy", nil, "door=" .. id .. " ownable=" .. tostring(ownable) .. " jobs=" .. jobs) end
	DRP.Net.Notify(ply, "Door policy saved.", 1)
	sendAdminSnapshot(ply, door)
end)

hook.Add("KeyPress", "DRP.Doors.UsePress", function(ply, key)
	if key ~= IN_USE or not IsValid(ply) then return end
	local now = CurTime()
	if now - (ply.DRPLastDoorUsePress or 0) < 0.05 then return end
	ply.DRPLastDoorUsePress = now
	local door = ply:GetUseEntity()
	if not Doors.IsDoor(door) then door = eyeTrace(ply).Entity end
	local decision = Doors.UseDecisions[ply]
	if decision and decision.door == door and now - (decision.createdAt or 0) < 0.05 then return end
	rememberUseDecision(ply, door)
end)

hook.Add("KeyRelease", "DRP.Doors.UseRelease", function(ply, key)
	if key == IN_USE then Doors.UseDecisions[ply] = nil end
end)

hook.Add("PlayerUse", "DRP.Doors.AccessAndCooldown", function(ply, entity)
	if Doors.BreachControllers[entity] then
		if DRP.Net.Allow(ply, "breached_door_controller", 1, 1) then
			DRP.Net.Notify(ply, "That control is disabled while its door is breached.", 2)
		end
		return false
	end
	if not Doors.IsDoor(entity) then return end
	if Doors.Breached[entity] then return false end
	local decision = Doors.UseDecisions[ply]
	if not decision or decision.door ~= entity then
		rememberUseDecision(ply, entity)
		decision = Doors.UseDecisions[ply]
	end
	if decision and decision.door == entity then
		if decision.blocked or decision.used then return false end
		decision.used = true
	end
end)

-- Map buttons and relays ultimately operate doors through entity inputs. While
-- breached, consume those inputs so an Open/Toggle/Enable output cannot make a
-- hidden brush door solid again. The breach service's own Disable input is the
-- only deliberate exception.
hook.Add("AcceptInput", "DRP.Doors.BlockBreachedInputs", function(entity)
	local state = Doors.Breached[entity]
	if state and not state.allowInput then return true end
end)

function Doors.SyncPlayer(ply)
	for door, owner in pairs(Doors.Owners) do
		if IsValid(door) and IsValid(owner) then DRP.Net.SendDoor(door, owner, ply) end
	end
	for id, policy in pairs(Doors.Policies) do
		local door = Doors.ByMapID[id]
		if IsValid(door) then DRP.Net.SendDoorPolicy(door, policy, ply) end
	end
end

function Doors.RemovePlayer(ply)
	Doors.UseStates[ply] = nil
	Doors.UseDecisions[ply] = nil
	local owned = Doors.ByPlayer[ply]
	if not owned then return end
	for door in pairs(owned) do Doors.Clear(door) end
	Doors.ByPlayer[ply] = nil
end

DRP.Net.Receive(DRP.Net.DoorRequestName(), function(_, ply)
	if not DRP.Net.Allow(ply, "door", 0.35, 3) then return end
	local trace = eyeTrace(ply)
	Doors.Toggle(ply, trace.Entity)
end)

hook.Add("EntityRemoved", "DRP.Doors.EntityRemoved", function(entity)
	if Doors.Breached[entity] then
		local state = Doors.Breached[entity]
		DRP.Deadlines.Cancel("door_breach:" .. tostring(state.doorID or entity:EntIndex()))
		setControllersBlocked(state, false)
		if IsValid(state.debris) then state.debris:Remove() end
		Doors.Breached[entity] = nil
	end
	if Doors.Owners[entity] then Doors.Clear(entity) end
end)

hook.Add("InitPostEntity", "DRP.Doors.BuildMapIndex", function()
	Doors:RebuildIndex()
end)
