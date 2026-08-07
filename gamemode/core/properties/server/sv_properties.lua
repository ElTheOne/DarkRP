local syncMessage = "drp_property_sync_v1"
local deltaMessage = "drp_property_delta_v1"
local manageSyncMessage = "drp_property_manage_sync_v1"
local manageActionMessage = "drp_property_manage_action_v1"
local zoneSyncMessage = "drp_property_zone_sync_v1"
util.AddNetworkString(syncMessage)
util.AddNetworkString(deltaMessage)
util.AddNetworkString(manageSyncMessage)
util.AddNetworkString(manageActionMessage)
util.AddNetworkString(zoneSyncMessage)

local Properties = {
	Definitions = {},
	Leases = {},
	DoorToProperty = {},
	Invites = {},
	PendingCredits = {},
	PendingVaultItems = {},
	PlayerRaidCooldowns = {},
	ActiveRaids = {},
	OwnedProperties = {},
	MemberProperties = {},
	EntitiesByProperty = {},
	Dirty = false,
	SyncDirtyIDs = {},
	SyncQueued = false,
	InitialSyncDone = false,
	Started = false,
	Revision = 0,
	LastSavedAt = 0,
	DatabaseLoaded = false,
	NextID = 1,
	BaseDoorPrice = 100,
	LeaseInterval = 86400,
	MaxPrepaidDays = 3,
	VaultCapacity = 48,
	RentInterval = 300,
	EvictionNotice = 60,
	OfflineOwnerExpiry = 600,
	AFKOwnerExpiry = 1200,
	RaidWarmup = 10,
	RaidDuration = 120,
	RaidCooldown = 600,
	RaidDistance = 600,
	MaxBuildZones = 32,
	MinBuildZoneAxis = 16,
	MaxBuildZoneAxis = 8192,
	-- Only absorb floating-point/map-surface noise. Visible overhang is invalid.
	BuildZoneTolerance = 1,
	BuildZoneUnionResolution = 1,
	BuildZoneUnionMaxChecks = 4096,
	LastActivity = setmetatable({}, { __mode = "k" }),
	NextActivityCheck = setmetatable({}, { __mode = "k" })
}

DRP.Properties = Properties
-- Geometry, persistence and raid modules extend this table while this file is
-- loading.  Registering it here previously exposed a partial service whenever
-- one of those includes failed, allowing startup to continue without property
-- authority.  Registration now happens only after the full API is validated.

DRP.Incidents.RegisterType("property_raid", {
	initial = "declared",
	transitions = { declared = { active = true } },
	outcomes = {
		attackers_victory = { winner = "instigator", loser = "victim" },
		default = { winner = "victim", loser = "instigator" }
	}
})

local defaultRoles = {
	coowner = { access = true, storage = true, build = true, crafting = true, manage_members = true, manage_roles = false, finances = false },
	tenant = { access = true, storage = true, build = true, crafting = false, manage_members = false, manage_roles = false, finances = false },
	guest = { access = true, storage = false, build = false, crafting = false, manage_members = false, manage_roles = false, finances = false }
}

local permissionKeys = {
	access = true,
	storage = true,
	build = true,
	crafting = true,
	manage_members = true,
	manage_roles = true,
	finances = true
}
Properties.DefaultRoles=defaultRoles
Properties.PermissionKeys=permissionKeys

local function clean(value, maximum)
	return string.sub(string.Trim(tostring(value or "")), 1, maximum or 64)
end

local function roleKey(value)
	local key = string.lower(clean(value, 24)):gsub("[^%w_%-]", "_")
	return key ~= "" and key or nil
end


local Geometry = assert(include("sv_geometry.lua"),
	"missing core/properties/server/sv_geometry.lua; upload the complete modular properties folder")
local vectorData = Geometry.VectorData
local normalizeBuildZone = Geometry.NormalizeBuildZone
local normalizeCornerBuildZone = Geometry.NormalizeCornerBuildZone
local sanitizeBuildZones = Geometry.SanitizeBuildZones
local pointInsideZone = Geometry.PointInsideZone
local entityInsideZoneUnion = Geometry.EntityInsideZoneUnion
local zoneVolume = Geometry.ZoneVolume


Properties.Internal = Properties.Internal or {}
Properties.Internal.Clean = clean
Properties.Internal.RoleKey = roleKey
local Persistence = assert(include("sv_persistence.lua"),
	"missing core/properties/server/sv_persistence.lua; upload the complete modular properties folder")
local steamID = Persistence.SteamID
local onlinePlayer = Persistence.OnlinePlayer
local addPropertyIndex = Persistence.AddPropertyIndex
local removePropertyIndex = Persistence.RemovePropertyIndex
local ownerDeadlineKey = Persistence.OwnerDeadlineKey
local memberDeadlineKey = Persistence.MemberDeadlineKey
local definitionPrice = Persistence.DefinitionPrice
local definitionLeaseRate = Persistence.DefinitionLeaseRate
local cloneRoles = Persistence.CloneRoles

function Properties.Get(id)
	return Properties.Definitions[math.floor(tonumber(id) or 0)], Properties.Leases[math.floor(tonumber(id) or 0)]
end

function Properties.ForDoor(door)
	if not DRP.Doors or not DRP.Doors.IsDoor(door) then return nil end
	local doorID = DRP.Doors.MapID and DRP.Doors.MapID(door)
	local propertyID = doorID and Properties.DoorToProperty[tostring(doorID)]
	return propertyID and Properties.Definitions[propertyID] or nil, propertyID and Properties.Leases[propertyID] or nil
end

function Properties.Member(propertyID, ply)
	local lease = Properties.Leases[tonumber(propertyID)]
	local id = steamID(ply)
	if not lease or not id then return nil end
	if lease.owner_id == id then return { role = "owner", name = ply:Nick() }, "owner" end
	local member = lease.members[id]
	return member, member and member.role or nil
end

function Properties.Can(ply, propertyID, permission)
	local definition, lease = Properties.Get(propertyID)
	if not definition or not lease or not IsValid(ply) then return false end
	local member, role = Properties.Member(propertyID, ply)
	if role == "owner" then return true end
	if not member or (member.eviction_unix or 0) <= os.time() and (member.eviction_unix or 0) > 0 then return false end
	local permissions = lease.roles[role]
	return permissions and permissions[permission] == true or false
end

-- Unbuyable job bases (PD, Mayor offices, and future job properties) inherit
-- their build access from the job masks configured on their grouped doors.
-- Door masks are combined across the group, so every job explicitly assigned
-- to at least one grouped door can build inside the property's zones.
function Properties.JobCanBuild(ply, propertyID)
	local definition, lease = Properties.Get(propertyID)
	if not definition or lease or definition.buyable ~= false or not IsValid(ply) then return false end
	if Properties.IsWorldDefinition(definition) then
		local job = ply.DRPJob and ply:DRPJob() or nil
		return istable(job) and job.isHobo == true
	end
	if not DRP.Doors or not DRP.Doors.JobMask then return false end
	local allowedJobs = 0
	for _, doorID in ipairs(definition.doors or {}) do
		local door = DRP.Doors.ByMapID[tostring(doorID)]
		if IsValid(door) then allowedJobs = bit.bor(allowedJobs, DRP.Doors.JobMask(door)) end
	end
	if allowedJobs == 0 then return false end
	local jobBit = 2 ^ math.max(0, ply:DRPJobID() - 1)
	return bit.band(allowedJobs, jobBit) ~= 0
end

function Properties.CanAccessDoor(ply, door)
	local definition, lease = Properties.ForDoor(door)
	if not definition or not lease then return nil, false end
	return Properties.Can(ply, definition.id, "access"), true
end

function Properties.PlayerProperty(ply, permission)
	local steamID64 = steamID(ply)
	local candidates = {}
	for id in pairs(Properties.OwnedProperties[steamID64] or {}) do candidates[id] = true end
	for id in pairs(Properties.MemberProperties[steamID64] or {}) do candidates[id] = true end
	for id in pairs(candidates) do
		if Properties.Can(ply, id, permission or "access") then return Properties.Definitions[id], Properties.Leases[id] end
	end
end

-- Staff rank alone must never bypass a property's build permissions during
-- normal roleplay. The owner override exists only while actively administering
-- the server, so an Owner playing a criminal/citizen role is treated exactly
-- like every other property member.
local function hasAdministrativeBuildOverride(ply)
	return IsValid(ply)
		and DRP.Admin ~= nil
		and DRP.Admin.IsOwner(ply)
		and DRP.AdminMode ~= nil
		and isfunction(DRP.AdminMode.IsActive)
		and DRP.AdminMode.IsActive(ply)
end

function Properties.FindMember(propertyID, fragment)
	local _, lease = Properties.Get(propertyID)
	fragment = string.lower(clean(fragment, 64))
	if not lease or fragment == "" then return nil end
	local matchID, match
	for memberID, member in pairs(lease.members) do
		if string.find(string.lower(tostring(member.name or memberID)), fragment, 1, true) or tostring(memberID) == fragment then
			if matchID then return nil end
			matchID, match = tostring(memberID), member
		end
	end
	return matchID, match, matchID and onlinePlayer(matchID) or nil
end

function Properties:RefreshDoors(propertyID)
	local definition, lease = self.Get(propertyID)
	if not definition or not DRP.Doors then return end
	local owner = lease and onlinePlayer(lease.owner_id) or nil
	for _, doorID in ipairs(definition.doors) do
		local door = DRP.Doors.ByMapID[tostring(doorID)]
		if IsValid(door) then
			local current = DRP.Doors.Owner(door)
			if IsValid(owner) and current ~= owner then
				DRP.Doors.Assign(door, owner)
			elseif not IsValid(owner) and current then
				DRP.Doors.Clear(door)
			end
		end
	end
end

function Properties:RefreshAllDoors()
	for id in pairs(self.Definitions) do self:RefreshDoors(id) end
end

local function writeProperty(service, ply, id)
	local definition, lease = service.Definitions[id], service.Leases[id]
	local member, role = service.Member(id, ply)
		net.WriteUInt(id, 16)
		net.WriteString(definition.name)
		net.WriteString(lease and lease.owner_name or "Unowned")
		net.WriteUInt(math.Clamp(definitionPrice(definition), 0, 4294967295), 32)
		net.WriteString(role or "none")
		net.WriteUInt(math.Clamp(member and tonumber(member.rent) or 0, 0, 4294967295), 32)
		net.WriteUInt(math.Clamp(member and tonumber(member.deposit) or 0, 0, 4294967295), 32)
		net.WriteUInt(math.Clamp(math.ceil(((member and member.next_rent_unix) or os.time()) - os.time()), 0, 65535), 16)
		net.WriteUInt(math.Clamp(math.ceil(((member and member.eviction_unix) or os.time()) - os.time()), 0, 65535), 16)
		net.WriteUInt(service.ActiveRaids[id] or 0, 32)
		net.WriteBool(definition.buyable ~= false)
		net.WriteBool(service.IsWorldDefinition(definition))
		net.WriteUInt(math.min(#(definition.build_zones or {}), 63), 6)
		net.WriteUInt(math.Clamp(definitionLeaseRate(definition), 0, 4294967295), 32)
		net.WriteUInt(math.Clamp(math.max(0, math.ceil(((lease and lease.lease_paid_until_unix) or os.time()) - os.time())), 0, 4294967295), 32)
		net.WriteUInt(math.Clamp(lease and #(lease.vault or {}) or 0, 0, 63), 6)
		net.WriteBool(lease ~= nil and (service.Can(ply, id, "finances") or service.Can(ply, id, "manage_members") or service.Can(ply, id, "storage")))
		net.WriteUInt(math.min(#definition.doors, 31), 5)
		for doorIndex = 1, math.min(#definition.doors, 31) do
			local door = DRP.Doors and DRP.Doors.ByMapID[tostring(definition.doors[doorIndex])]
			net.WriteUInt(IsValid(door) and door:EntIndex() or 0, 13)
		end
	end

function Properties:Sync(ply)
	if not IsValid(ply) then return end
	local ids = {}
	for id in pairs(self.Definitions) do ids[#ids + 1] = id end
	table.sort(ids)
	net.Start(syncMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.min(#ids, 255), 8)
	for index = 1, math.min(#ids, 255) do
		writeProperty(self, ply, ids[index])
	end
	net.Send(ply)
end

function Properties:SyncFullAll()
	for _, ply in ipairs(DRP.Players.List) do self:Sync(ply) end
end

function Properties:FinishInitialSync()
	if self.InitialSyncDone then return end
	if not self.Started then self:Start() end
	self.InitialSyncDone = true
	self:EnsureWorldDefinition()
	self:RebuildDoorIndex()
	self:RefreshAllDoors()
	self:SyncFullAll()
end

function Properties:SyncProperty(id, recipient)
	id = tonumber(id)
	local recipients = IsValid(recipient) and { recipient } or DRP.Players.List
	for _, ply in ipairs(recipients) do
		if IsValid(ply) then
			net.Start(deltaMessage)
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.WriteUInt(math.Clamp(id or 0, 0, 65535), 16)
			net.WriteBool(self.Definitions[id] ~= nil)
			if self.Definitions[id] then writeProperty(self, ply, id) end
			net.Send(ply)
		end
	end
end

function Properties:SyncAll(propertyID)
	if propertyID ~= nil then self.SyncDirtyIDs[tonumber(propertyID)] = true end
	if self.SyncQueued then return end
	self.SyncQueued = true
	timer.Simple(0, function()
		self.SyncQueued = false
		local started = DRP.Profile.Begin()
		local candidates = next(self.SyncDirtyIDs) and self.SyncDirtyIDs or self.Definitions
		self.SyncDirtyIDs = {}
		for id in pairs(candidates) do
			self:SyncProperty(id)
		end
		DRP.Profile.Finish("properties.delta_sync", started)
	end)
end

function Properties:BuildManagementSnapshot(ply, propertyID)
	propertyID = math.floor(tonumber(propertyID) or 0)
	local definition, lease = self.Get(propertyID)
	if not definition then return nil end
	local _, role = self.Member(propertyID, ply)
	local canConfigure = self.CanConfigure(ply)
	local snapshot = {
		id = definition.id,
		name = definition.name,
		price = definitionPrice(definition),
		automaticPrice = math.max(self.BaseDoorPrice, #definition.doors * self.BaseDoorPrice),
		leaseRate = definitionLeaseRate(definition),
		buyable = definition.buyable ~= false,
		world = self.IsWorldDefinition(definition),
		owner = lease and lease.owner_name or "Unowned",
		ownerID = lease and lease.owner_id or "",
		role = role or "none",
		canConfigure = canConfigure,
		canFinances = lease ~= nil and self.Can(ply, propertyID, "finances") or false,
		canMembers = lease ~= nil and self.Can(ply, propertyID, "manage_members") or false,
		canRoles = lease ~= nil and self.Can(ply, propertyID, "manage_roles") or false,
		canStorage = lease ~= nil and self.Can(ply, propertyID, "storage") or false,
		leasePaidUntil = lease and lease.lease_paid_until_unix or 0,
		maxPrepaidDays = self.MaxPrepaidDays,
		vaultCapacity = self.VaultCapacity,
		raid = self.ActiveRaids[propertyID] or 0,
		buildZoneCount = #(definition.build_zones or {}),
		members = {},
		roles = {},
		vault = {},
		pockets = {},
		players = {}
	}
	if lease and snapshot.canRoles then
		for roleName,permissions in pairs(lease.roles or {}) do
			snapshot.roles[roleName]={}
			for permission in pairs(permissionKeys) do snapshot.roles[roleName][permission]=permissions[permission]==true end
		end
	end
	if lease and (snapshot.canMembers or snapshot.canFinances or snapshot.canRoles or role ~= "none") then
		for memberID, member in pairs(lease.members or {}) do
			snapshot.members[#snapshot.members + 1] = {
				id = tostring(memberID),
				name = clean(member.name or memberID, 64),
				role = clean(member.role or "tenant", 24),
				rent = math.max(0, math.floor(tonumber(member.rent) or 0)),
				deposit = math.max(0, math.floor(tonumber(member.deposit) or 0)),
				nextRent = math.max(0, math.floor(tonumber(member.next_rent_unix) or 0)),
				eviction = math.max(0, math.floor(tonumber(member.eviction_unix) or 0))
			}
		end
		table.sort(snapshot.members, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
	end
	if lease and snapshot.canStorage then
		for index, entry in ipairs(lease.vault or {}) do
			local record = entry.record or entry
			snapshot.vault[index] = {
				index = index,
				label = clean(record.label or record.class or "Stored Item", 64),
				kind = clean(record.kind or "entity", 16),
				amount = math.Clamp(math.floor(tonumber(record.amount) or 1), 1, 99),
				depositor = clean(entry.depositor_name or "Unknown", 64),
				deposited = math.max(0, math.floor(tonumber(entry.deposited_unix) or 0))
			}
		end
		for index, record in ipairs(DRP.Inventory.Items(ply)) do
			snapshot.pockets[index] = {
				index = index,
				itemID = record.id,
				label = clean(record.label or record.class or "Hands Item", 64),
				kind = clean(record.kind or "entity", 16),
				amount = math.Clamp(math.floor(tonumber(record.amount) or 1), 1, 99)
			}
		end
	end
	if snapshot.canMembers then
		for _, target in ipairs(DRP.Players.List) do
			if IsValid(target) and target ~= ply and target:DRPReady() and not self.Member(propertyID, target) then
				snapshot.players[#snapshot.players + 1] = { entity = target:EntIndex(), name = clean(target:DRPName(), 64) }
			end
		end
	end
	return snapshot
end

function Properties:SendZoneEditor(ply, propertyID)
	if not IsValid(ply) or not self.CanConfigure(ply) then return false end
	propertyID = math.floor(tonumber(propertyID) or 0)
	local definition = self.Definitions[propertyID]
	if not definition then return false end
	local pending = {}
	for index, point in ipairs(ply.DRPPropertyZonePoints or {}) do
		if index > 4 then break end
		pending[index] = vectorData(point)
	end
	local json = util.TableToJSON({
		id = definition.id,
		name = definition.name,
		zones = definition.build_zones or {},
		pending = #pending > 0 and pending or nil
	}, false) or "{}"
	local payload = util.Compress(json) or ""
	net.Start(zoneSyncMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(#payload, 18)
		net.WriteData(payload, #payload)
	net.Send(ply)
	DRP.Net.Record(#payload + 4)
	return true
end

function Properties:SelectZoneEditor(ply, propertyID)
	if not IsValid(ply) or not self.CanConfigure(ply) then return false end
	propertyID = math.floor(tonumber(propertyID) or 0)
	local definition = self.Definitions[propertyID]
	if not definition then return false end
	ply.DRPPropertyZoneEditID = propertyID
	ply.DRPPropertyZonePoint = nil
	ply.DRPPropertyZonePoints = nil
	if not ply:HasWeapon("gmod_tool") then ply:Give("gmod_tool") end
	ply:ConCommand("gmod_toolmode drp_property_zone")
	ply:SelectWeapon("gmod_tool")
	self:SendZoneEditor(ply, propertyID)
	DRP.Net.Notify(ply, "Editing build zones for " .. definition.name .. ". Left-click four base corners in order, then left-click the height.", 0)
	return true
end

function Properties:SendManagement(ply, propertyID, open)
	if not IsValid(ply) then return end
	local snapshot = self:BuildManagementSnapshot(ply, propertyID)
	if not snapshot then return end
	local json = util.TableToJSON(snapshot, false) or "{}"
	local payload = util.Compress(json) or ""
	net.Start(manageSyncMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteBool(open == true)
		net.WriteUInt(#payload, 20)
		net.WriteData(payload, #payload)
	net.Send(ply)
	DRP.Net.Record(#payload + 4)
end

local function readManageAction()
	local action = clean(net.ReadString(), 32)
	local length = net.ReadUInt(16)
	if length > 32768 then return action, {} end
	local payload = length > 0 and net.ReadData(length) or ""
	local json = length > 0 and util.Decompress(payload) or "{}"
	local data = json and util.JSONToTable(json) or {}
	return action, istable(data) and data or {}
end

DRP.Net.Receive(manageActionMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "property_management", 0.2, 8) then return end
	local action, data = readManageAction()
	local propertyID = math.floor(tonumber(data.id) or 0)
	if action == "request" then Properties:SendManagement(ply, propertyID, data.open == true) return end
	if action == "pay" then
		Properties:PayLease(ply, propertyID, data.days)
	elseif action == "vault_deposit" then
		Properties:VaultDeposit(ply, propertyID, data.itemID or data.index)
	elseif action == "vault_withdraw" then
		Properties:VaultWithdraw(ply, propertyID, data.index)
	elseif action == "invite" then
		local target = Entity(math.floor(tonumber(data.target) or 0))
		if IsValid(target) and target:IsPlayer() then Properties:Invite(ply, target, propertyID, data.role, data.rent, data.deposit) end
	elseif action == "member_rent" then
		Properties:SetMemberRent(ply, propertyID, data.memberID, data.rent)
	elseif action == "member_role" then
		Properties:SetMemberRoleByID(ply, data.memberID, propertyID, data.role)
	elseif action == "member_evict" then
		Properties:BeginEviction(ply, tostring(data.memberID or ""), propertyID, "owner eviction")
	elseif action == "role_permission" then
		Properties:SetRolePermission(ply,propertyID,data.role,data.permission,data.enabled==true)
	elseif action == "set_price" then
		Properties:SetPrice(ply, propertyID, data.price)
	elseif action == "set_lease_price" then
		Properties:SetLeasePrice(ply, propertyID, data.price)
	elseif action == "set_buyable" then
		Properties:SetBuyable(ply, propertyID, data.buyable == true)
	elseif action == "edit_zones" then
		Properties:SelectZoneEditor(ply, propertyID)
	elseif action == "clear_zones" then
		Properties:ClearBuildZones(ply, propertyID)
	end
	Properties:SendManagement(ply, propertyID, false)
end)

function Properties:Credit(id, amount, reason)
	amount = math.max(0, math.floor(tonumber(amount) or 0))
	if amount <= 0 or not id then return end
	local ply = onlinePlayer(id)
	if IsValid(ply) and ply:DRPPersistent() then
		DRP.Economy.Add(ply, amount, reason)
	else
		self.PendingCredits[tostring(id)] = math.max(0, math.floor(tonumber(self.PendingCredits[tostring(id)]) or 0)) + amount
		self:Save()
	end
end

function Properties:ApplyCredit(ply)
	local id = steamID(ply)
	local amount = id and math.floor(tonumber(self.PendingCredits[id]) or 0) or 0
	if amount <= 0 or not ply:DRPPersistent() then return false end
	self.PendingCredits[id] = nil
	self:Save()
	DRP.Economy.Add(ply, amount, "property escrow and rent credit")
	return true
end

function Properties:ApplyPendingVault(ply)
	local id = steamID(ply)
	local pending = id and self.PendingVaultItems[id]
	if not istable(pending) or #pending == 0 then return false end
	local remaining, restored = {}, 0
	for _, record in ipairs(pending) do
		if DRP.Inventory.InsertRaw(ply, record) then restored = restored + 1 else remaining[#remaining + 1] = record end
	end
	self.PendingVaultItems[id] = #remaining > 0 and remaining or nil
	self:Save()
	self:Flush()
	if restored > 0 then DRP.Net.Notify(ply, restored .. " item(s) from a former property vault were restored to Hands.", 1) end
	return restored > 0
end

function Properties:PayLease(ply, propertyID, days)
	local definition, lease = self.Get(propertyID)
	days = math.floor(tonumber(days) or 0)
	local _, role = self.Member(propertyID, ply)
	if not definition or not lease or not role or not ply:DRPPersistent() or days < 1 or days > self.MaxPrepaidDays then return false end
	local now = os.time()
	local paidUntil = math.max(now, math.floor(tonumber(lease.lease_paid_until_unix) or now))
	local maximum = now + (self.MaxPrepaidDays + 1) * self.LeaseInterval
	local extension = days * self.LeaseInterval
	if paidUntil + extension > maximum then
		DRP.Net.Notify(ply, "The base can only be funded three days ahead.", 3)
		return false
	end
	local rate = definitionLeaseRate(definition)
	local amount = rate * days
	if not DRP.Economy.Take(ply, amount, "base lease funded for " .. days .. " day(s)") then
		DRP.Net.Notify(ply, "You need $" .. string.Comma(amount) .. " to fund that lease.", 3)
		return false
	end
	lease.lease_paid_until_unix = paidUntil + extension
	self:ScheduleOwnerDeadline(propertyID)
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	if DRP.Audit then DRP.Audit.Log(ply, "property_lease_funded", onlinePlayer(lease.owner_id), "#" .. propertyID .. " days=" .. days .. " $" .. amount) end
	DRP.Net.Notify(ply, definition.name .. " is funded until " .. os.date("%Y-%m-%d %H:%M", lease.lease_paid_until_unix) .. ".", 1)
	return true
end

function Properties:SetMemberRent(ply, propertyID, memberID, rent)
	local _, lease = self.Get(propertyID)
	memberID = tostring(memberID or "")
	rent = math.Clamp(math.floor(tonumber(rent) or 0), 0, 100000)
	local member = lease and lease.members[memberID]
	if not member or self.ActiveRaids[tonumber(propertyID)] or not self.Can(ply, propertyID, "finances") then return false end
	member.rent = rent
	member.next_rent_unix = rent > 0 and math.max(os.time() + self.RentInterval, tonumber(member.next_rent_unix) or 0) or nil
	member.eviction_unix = 0
	member.eviction_reason = nil
	self:ScheduleMemberDeadline(propertyID, memberID)
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	if DRP.Audit then DRP.Audit.Log(ply, "property_tenant_rent_set", onlinePlayer(memberID) or memberID, "#" .. propertyID .. " $" .. rent) end
	return true
end

function Properties:VaultDeposit(ply, propertyID, pocketReference)
	local _, lease = self.Get(propertyID)
	if not lease or not ply:DRPPersistent() or not self.Can(ply, propertyID, "storage") then return false end
	if self.ActiveRaids[tonumber(propertyID)] then DRP.Net.Notify(ply, "The shared vault is locked while the property is under raid.", 3) return false end
	lease.vault = lease.vault or {}
	if #lease.vault >= self.VaultCapacity then DRP.Net.Notify(ply, "The property vault is full.", 3) return false end
	local record = isstring(pocketReference) and DRP.Inventory.TakeRawByID(ply, pocketReference) or DRP.Inventory.TakeRaw(ply, pocketReference)
	if not record then return false end
	lease.vault[#lease.vault + 1] = { record = record, depositor_id = ply:SteamID64(), depositor_name = clean(ply:DRPName(), 64), deposited_unix = os.time() }
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	if DRP.Audit then DRP.Audit.Log(ply, "property_vault_deposit", nil, "#" .. propertyID .. " " .. tostring(record.label or record.class)) end
	DRP.Net.Notify(ply, tostring(record.label or record.class or "Item") .. " was secured in the property vault.", 1)
	return true
end

function Properties:VaultWithdraw(ply, propertyID, vaultIndex)
	local _, lease = self.Get(propertyID)
	vaultIndex = math.floor(tonumber(vaultIndex) or 0)
	local entry = lease and lease.vault and lease.vault[vaultIndex]
	if not entry or not ply:DRPPersistent() or not self.Can(ply, propertyID, "storage") then return false end
	if self.ActiveRaids[tonumber(propertyID)] then DRP.Net.Notify(ply, "The shared vault is locked while the property is under raid.", 3) return false end
	local record = entry.record or entry
	if not DRP.Inventory.InsertRaw(ply, record) then DRP.Net.Notify(ply, "Your Hands grid cannot hold that vault item.", 3) return false end
	table.remove(lease.vault, vaultIndex)
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	if DRP.Audit then DRP.Audit.Log(ply, "property_vault_withdraw", nil, "#" .. propertyID .. " " .. tostring(record.label or record.class)) end
	DRP.Net.Notify(ply, tostring(record.label or record.class or "Item") .. " was moved into Hands.", 1)
	return true
end

function Properties:Touch(ply)
	if not IsValid(ply) then return end
	if (self.LastActivity[ply] or 0) > CurTime() - 1 then return end
	self.LastActivity[ply] = CurTime()
	local id = steamID(ply)
	for propertyID in pairs(self.OwnedProperties[id] or {}) do
		local lease = self.Leases[propertyID]
		if lease then
			lease.last_owner_seen_unix = os.time()
			lease.owner_offline_unix = nil
		end
	end
end

function Properties:Purchase(ply, propertyID)
	local definition, lease = self.Get(propertyID)
	if not definition or lease or not IsValid(ply) or not ply:DRPPersistent() then
		if IsValid(ply) then DRP.Net.Notify(ply, "Persistent database state is required to purchase property.", 3) end
		return false
	end
	if definition.buyable == false then
		DRP.Net.Notify(ply, definition.name .. " is not available for purchase.", 3)
		return false
	end
	local ownedCount = 0
	for _ in pairs(self.OwnedProperties[ply:SteamID64()] or {}) do ownedCount = ownedCount + 1 end
	local propertyLimit = DRP.Supporter and DRP.Supporter.PropertyLimit(ply) or 1
	if ownedCount >= propertyLimit then
		DRP.Net.Notify(ply, "Property limit reached (" .. ownedCount .. "/" .. propertyLimit .. "). Your supporter tier allows " .. propertyLimit .. " directly owned " .. (propertyLimit == 1 and "property" or "properties") .. ".", 3)
		return false
	end
	for _, doorID in ipairs(definition.doors) do
		local door = DRP.Doors.ByMapID[tostring(doorID)]
		if not IsValid(door) or (DRP.Doors.PlayerCanOwn and not DRP.Doors.PlayerCanOwn(ply, door)) then
			DRP.Net.Notify(ply, "Your job cannot purchase every door in that property.", 3)
			return false
		end
	end
	local price = definitionPrice(definition)
	if not DRP.Economy.Take(ply, price, "property purchased") then
		DRP.Net.Notify(ply, "You need $" .. string.Comma(price) .. " to purchase " .. definition.name .. ".", 3)
		return false
	end
	self.Leases[propertyID] = {
		owner_id = ply:SteamID64(), owner_name = clean(ply:Nick(), 64), acquired_unix = os.time(),
		last_owner_seen_unix = os.time(), price_paid = price, roles = cloneRoles(), members = {}, raid_cooldown_unix = 0,
		lease_paid_until_unix = os.time() + self.LeaseInterval, vault = {}
	}
	addPropertyIndex(self.OwnedProperties, ply:SteamID64(), propertyID)
	self:ScheduleOwnerDeadline(propertyID)
	local ownedEntities = DRP.Services.Get("props") and DRP.Services.Get("props").ByPlayer[ply] or {}
	for entity in pairs(ownedEntities) do if IsValid(entity) then self:AssignEntity(entity, ply, false) end end
	self.LastActivity[ply] = CurTime()
	self:RefreshDoors(propertyID)
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	hook.Run("DRPPropertyOwnershipChanged", ply, propertyID, true)
	if DRP.Audit then DRP.Audit.Log(ply, "property_purchased", nil, "#" .. propertyID .. " " .. definition.name .. " ($" .. price .. ")") end
	DRP.Net.Notify(ply, "Purchased " .. definition.name .. " and all " .. #definition.doors .. " doors.", 1)
	return true
end

function Properties.ToggleDoor(ply, door)
	local definition, lease = Properties.ForDoor(door)
	if not definition then return false end
	if not lease then
		if definition.buyable == false then
			DRP.Net.Notify(ply, definition.name .. " is not available for purchase.", 3)
		else
			Properties:Purchase(ply, definition.id)
		end
		return true
	end
	local _, role = Properties.Member(definition.id, ply)
	if role == "owner" then
		DRP.Net.Notify(ply, definition.name .. " is managed through /property. Use /propertyrelease to sell it.", 0)
	elseif role then
		DRP.Net.Notify(ply, "You access " .. definition.name .. " as " .. role .. ".", 0)
	else
		DRP.Net.Notify(ply, definition.name .. " is owned by " .. lease.owner_name .. ".", 3)
	end
	return true
end

local function selectedSetupDoors(ply)
	local doors, seen = {}, {}
	for selected in pairs(DRP.Doors.ByPlayer[ply] or {}) do
		local doorID = DRP.Doors.MapID(selected)
		if IsValid(selected) and DRP.Doors.Owner(selected) == ply and doorID and not Properties.DoorToProperty[doorID] and not seen[doorID] then
			doors[#doors + 1] = { entity = selected, id = doorID }
			seen[doorID] = true
		end
	end
	table.sort(doors, function(first, second) return tonumber(first.id) < tonumber(second.id) end)
	return doors, seen
end

local function consumeSetupDoors(ply, selected)
	for _, record in ipairs(selected) do DRP.Doors.Clear(record.entity) end
	local refund = #selected * DRP.Doors.Price
	if refund > 0 then DRP.Economy.Add(ply, refund, "building-group setup refund") end
end

function Properties:IsRaidActive(propertyID)
	local incident = DRP.Incidents.Get(self.ActiveRaids[tonumber(propertyID)])
	return incident and incident.state == "active", incident
end

function Properties:RemoveMember(propertyID, memberID, reason)
	local _, lease = self.Get(propertyID)
	if self.ActiveRaids[tonumber(propertyID)] then return false end
	local member = lease and lease.members[tostring(memberID)]
	if not member then return false end
	lease.members[tostring(memberID)] = nil
	removePropertyIndex(self.MemberProperties, memberID, propertyID)
	DRP.Deadlines.Cancel(memberDeadlineKey(propertyID, memberID))
	if DRP.Props and DRP.Props.RemovePropertyMemberEntities then DRP.Props.RemovePropertyMemberEntities(propertyID, memberID) end
	self:Credit(memberID, member.deposit or 0, "refundable property deposit")
	local target = onlinePlayer(memberID)
	if IsValid(target) then DRP.Net.Notify(target, "Your tenancy at " .. self.Definitions[propertyID].name .. " ended: " .. tostring(reason or "ended") .. ".", 2) end
	if DRP.Audit then DRP.Audit.Log(onlinePlayer(lease.owner_id), "property_tenancy_ended", target or tostring(memberID), "#" .. propertyID .. " " .. tostring(reason or "ended")) end
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	return true
end

function Properties:Release(propertyID, reason, refundFraction)
	local definition, lease = self.Get(propertyID)
	if not definition or not lease then return false end
	local _, raid = self:IsRaidActive(propertyID)
	if raid then return false, "Property cannot be released during a declared or active raid" end
	hook.Run("DRPPropertyReleasing", propertyID, lease.owner_id, reason)
	for memberID in pairs(table.Copy(lease.members)) do self:RemoveMember(propertyID, memberID, reason) end
	if refundFraction and refundFraction > 0 then self:Credit(lease.owner_id, math.floor(lease.price_paid * refundFraction), "property sale refund") end
	if istable(lease.vault) and #lease.vault > 0 then
		local pending = self.PendingVaultItems[lease.owner_id] or {}
		for _, entry in ipairs(lease.vault) do
			local record = entry.record or entry
			if istable(record) then pending[#pending + 1] = record end
		end
		self.PendingVaultItems[lease.owner_id] = pending
	end
	self.Leases[propertyID] = nil
	removePropertyIndex(self.OwnedProperties, lease.owner_id, propertyID)
	DRP.Deadlines.Cancel(ownerDeadlineKey(propertyID))
	self.ActiveRaids[propertyID] = nil
	self:RefreshDoors(propertyID)
	if DRP.Props and DRP.Props.RemovePropertyEntities then DRP.Props.RemovePropertyEntities(propertyID) end
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	local formerOwner = onlinePlayer(lease.owner_id)
	if IsValid(formerOwner) then
		self:ApplyPendingVault(formerOwner)
		hook.Run("DRPPropertyOwnershipChanged", formerOwner, propertyID, false)
	end
	if DRP.Audit then DRP.Audit.Log(onlinePlayer(lease.owner_id), "property_released", nil, "#" .. propertyID .. " " .. tostring(reason or "released")) end
	return true
end

function Properties:Invite(owner, target, propertyID, role, rent, deposit)
	local definition, lease = self.Get(propertyID)
	role = roleKey(role)
	rent, deposit = math.max(0, math.floor(tonumber(rent) or 0)), math.max(0, math.floor(tonumber(deposit) or 0))
	if not definition or not lease or self.ActiveRaids[tonumber(propertyID)] or not IsValid(target) or target == owner or not self.Can(owner, propertyID, "manage_members") then return false end
	if not role or not lease.roles[role] then DRP.Net.Notify(owner, "That property role does not exist.", 3) return false end
	if rent > 100000 or deposit > 100000 then DRP.Net.Notify(owner, "Rent and deposits are limited to $100,000.", 3) return false end
	if self.Member(propertyID, target) then DRP.Net.Notify(owner, "That player already belongs to the property.", 3) return false end
	self.Invites[target:SteamID64()] = { property_id = propertyID, role = role, rent = rent, deposit = deposit, inviter_id = owner:SteamID64(), expires = CurTime() + 60 }
	DRP.Net.Notify(owner, "Invited " .. target:Nick() .. " as " .. role .. ".", 1)
	DRP.Net.Notify(target, owner:Nick() .. " invited you to " .. definition.name .. " as " .. role .. ". Rent: $" .. rent .. ", deposit: $" .. deposit .. ". Use /propertyaccept.", 0)
	return true
end

function Properties:AcceptInvite(ply)
	local invite = self.Invites[ply:SteamID64()]
	if not invite or invite.expires <= CurTime() then self.Invites[ply:SteamID64()] = nil DRP.Net.Notify(ply, "You have no active property invitation.", 3) return false end
	local definition, lease = self.Get(invite.property_id)
	if not definition or not lease or self.ActiveRaids[invite.property_id] or not lease.roles[invite.role] then self.Invites[ply:SteamID64()] = nil return false end
	if not ply:DRPPersistent() then DRP.Net.Notify(ply, "Persistent database state is required for deposits and rent.", 3) return false end
	if invite.deposit > 0 and not DRP.Economy.Take(ply, invite.deposit, "refundable property deposit") then
		DRP.Net.Notify(ply, "You cannot afford the $" .. invite.deposit .. " deposit.", 3)
		return false
	end
	lease.members[ply:SteamID64()] = {
		name = clean(ply:Nick(), 64), role = invite.role, rent = invite.rent, deposit = invite.deposit,
		next_rent_unix = os.time() + self.RentInterval, joined_unix = os.time(), eviction_unix = 0
	}
	addPropertyIndex(self.MemberProperties, ply:SteamID64(), definition.id)
	self:ScheduleMemberDeadline(definition.id, ply:SteamID64())
	self.Invites[ply:SteamID64()] = nil
	self:Save()
	self:Flush()
	self:SyncAll(definition.id)
	if DRP.Audit then DRP.Audit.Log(onlinePlayer(lease.owner_id), "property_tenant_joined", ply, "#" .. definition.id .. " role=" .. invite.role) end
	DRP.Net.Notify(ply, "Joined " .. definition.name .. " as " .. invite.role .. ".", 1)
	return true
end

function Properties:BeginEviction(actor, target, propertyID, reason)
	local definition, lease = self.Get(propertyID)
	local targetID = isstring(target) and target or steamID(target)
	local member = targetID and lease and lease.members[targetID]
	if not definition or not member or self.ActiveRaids[tonumber(propertyID)] or not self.Can(actor, propertyID, "manage_members") then return false end
	if member.eviction_unix and member.eviction_unix > os.time() then return false end
	member.eviction_unix = os.time() + self.EvictionNotice
	member.eviction_reason = clean(reason or "owner eviction", 96)
	self:ScheduleMemberDeadline(propertyID, targetID)
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	local onlineTarget = onlinePlayer(targetID)
	local targetName = IsValid(onlineTarget) and onlineTarget:Nick() or member.name or targetID
	DRP.Net.Notify(actor, targetName .. " received " .. self.EvictionNotice .. " seconds' eviction notice.", 1)
	if IsValid(onlineTarget) then DRP.Net.Notify(onlineTarget, "Eviction notice for " .. definition.name .. ": " .. member.eviction_reason .. ". Access remains for " .. self.EvictionNotice .. " seconds.", 2) end
	if DRP.Audit then DRP.Audit.Log(actor, "property_eviction_notice", onlineTarget or targetID, "#" .. propertyID .. " " .. member.eviction_reason) end
	return true
end

function Properties:SetRolePermission(ply, propertyID, role, permission, enabled)
	local _, lease = self.Get(propertyID)
	role, permission = roleKey(role), roleKey(permission)
	if not lease or self.ActiveRaids[tonumber(propertyID)] or not role or role == "owner" or not permissionKeys[permission] or not self.Can(ply, propertyID, "manage_roles") then return false end
	lease.roles[role] = lease.roles[role] or {}
	lease.roles[role][permission] = enabled == true
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	if DRP.Audit then DRP.Audit.Log(ply, "property_role_permission", nil, "#" .. propertyID .. " " .. role .. "." .. permission .. "=" .. tostring(enabled)) end
	return true
end

function Properties:SetMemberRole(ply, target, propertyID, role)
	local _, lease = self.Get(propertyID)
	local targetID = steamID(target)
	role = roleKey(role)
	local member = targetID and lease and lease.members[targetID]
	if not member or self.ActiveRaids[tonumber(propertyID)] or not role or not lease.roles[role] or not self.Can(ply, propertyID, "manage_members") then return false end
	member.role = role
	member.name = clean(target:Nick(), 64)
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	DRP.Net.Notify(target, "Your property role is now " .. role .. ".", 0)
	if DRP.Audit then DRP.Audit.Log(ply, "property_member_role", target, "#" .. propertyID .. " role=" .. role) end
	return true
end

function Properties:SetMemberRoleByID(ply, targetID, propertyID, role)
	local _, lease = self.Get(propertyID)
	targetID = tostring(targetID or "")
	role = roleKey(role)
	local member = lease and lease.members[targetID]
	if not member or self.ActiveRaids[tonumber(propertyID)] or not role or not lease.roles[role] or not self.Can(ply, propertyID, "manage_members") then return false end
	member.role = role
	self:Save()
	self:Flush()
	self:SyncAll(propertyID)
	local target = onlinePlayer(targetID)
	if IsValid(target) then DRP.Net.Notify(target, "Your property role is now " .. role .. ".", 0) end
	if DRP.Audit then DRP.Audit.Log(ply, "property_member_role", target or targetID, "#" .. propertyID .. " role=" .. role) end
	return true
end

function Properties:AddBuildZone(ply, propertyID, points, heightPoint)
	propertyID = math.floor(tonumber(propertyID) or 0)
	local definition = self.Definitions[propertyID]
	if not definition or not self.CanConfigure(ply) then return false end
	definition.build_zones = definition.build_zones or {}
	if #definition.build_zones >= self.MaxBuildZones then
		DRP.Net.Notify(ply, "This property already has the maximum " .. self.MaxBuildZones .. " build zones.", 3)
		return false
	end
	local zone, reason
	if istable(points) then
		zone, reason = normalizeCornerBuildZone(points, heightPoint)
	else
		-- Compatibility for any older internal caller still supplying two
		-- opposite corners.
		zone, reason = normalizeBuildZone(points, heightPoint)
	end
	if not zone then
		DRP.Net.Notify(ply, reason or "That build zone is invalid.", 3)
		return false
	end
	definition.build_zones[#definition.build_zones + 1] = zone
	if not self:SaveConfiguration() then
		table.remove(definition.build_zones)
		DRP.Net.Notify(ply, "Build zone could not be verified in persistent storage.", 3)
		return false
	end
	self:SyncAll(propertyID)
	self:SendZoneEditor(ply, propertyID)
	self:SendManagement(ply, propertyID, false)
	if DRP.Audit then DRP.Audit.Log(ply, "property_build_zone_added", nil, "#" .. propertyID .. " zone=" .. #definition.build_zones) end
	DRP.Net.Notify(ply, "Build zone #" .. #definition.build_zones .. " saved for " .. definition.name .. ".", 1)
	return true
end

function Properties:RemoveBuildZoneAt(ply, propertyID, position)
	propertyID = math.floor(tonumber(propertyID) or 0)
	local definition = self.Definitions[propertyID]
	if not definition or not self.CanConfigure(ply) then return false end
	local selected, selectedVolume
	for index, zone in ipairs(definition.build_zones or {}) do
		if pointInsideZone(position, zone, 24) then
			local volume = zoneVolume(zone)
			if not selectedVolume or volume < selectedVolume then selected, selectedVolume = index, volume end
		end
	end
	if not selected then
		DRP.Net.Notify(ply, "Aim at a surface inside the build zone you want to remove.", 3)
		return false
	end
	local removed = table.remove(definition.build_zones, selected)
	if not self:SaveConfiguration() then
		table.insert(definition.build_zones, selected, removed)
		DRP.Net.Notify(ply, "Build-zone removal could not be verified in persistent storage.", 3)
		return false
	end
	self:SyncAll(propertyID)
	self:SendZoneEditor(ply, propertyID)
	self:SendManagement(ply, propertyID, false)
	if DRP.Audit then DRP.Audit.Log(ply, "property_build_zone_removed", nil, "#" .. propertyID .. " zone=" .. selected) end
	DRP.Net.Notify(ply, "Removed build zone #" .. selected .. " from " .. definition.name .. ".", 1)
	return true
end

function Properties:ClearBuildZones(ply, propertyID)
	propertyID = math.floor(tonumber(propertyID) or 0)
	local definition = self.Definitions[propertyID]
	if not definition or not self.CanConfigure(ply) then return false end
	local count = #(definition.build_zones or {})
	if count == 0 then return false end
	local previous = definition.build_zones
	definition.build_zones = {}
	if not self:SaveConfiguration() then
		definition.build_zones = previous
		DRP.Net.Notify(ply, "Build-zone clearing could not be verified in persistent storage.", 3)
		return false
	end
	if ply.DRPPropertyZoneEditID == propertyID then
		ply.DRPPropertyZonePoint = nil
		ply.DRPPropertyZonePoints = nil
		self:SendZoneEditor(ply, propertyID)
	end
	self:SyncAll(propertyID)
	if DRP.Audit then DRP.Audit.Log(ply, "property_build_zones_cleared", nil, "#" .. propertyID .. " zones=" .. count) end
	DRP.Net.Notify(ply, "Cleared " .. count .. " build zone(s) from " .. definition.name .. ".", 2)
	return true
end

function Properties:ZoneToolLeft(ply, position)
	if not self.CanConfigure(ply) then return false end
	local propertyID = math.floor(tonumber(ply.DRPPropertyZoneEditID) or 0)
	if not self.Definitions[propertyID] then return false end
	ply.DRPPropertyZonePoint = nil
	local points = ply.DRPPropertyZonePoints
	if not istable(points) then
		points = {}
		ply.DRPPropertyZonePoints = points
	end
	if #points < 4 then
		points[#points + 1] = Vector(position.x, position.y, position.z)
		self:SendZoneEditor(ply, propertyID)
		if #points < 4 then
			DRP.Net.Notify(ply, "Base corner " .. #points .. "/4 selected. Select corner " .. (#points + 1) .. " in perimeter order.", 0)
		else
			DRP.Net.Notify(ply, "All four base corners selected. Left-click once more to set the box height.", 0)
		end
		return true
	end
	ply.DRPPropertyZonePoints = nil
	local created = self:AddBuildZone(ply, propertyID, points, position)
	if not created then self:SendZoneEditor(ply, propertyID) end
	return created
end

function Properties:ZoneToolRight(ply, position)
	if not self.CanConfigure(ply) then return false end
	local propertyID = math.floor(tonumber(ply.DRPPropertyZoneEditID) or 0)
	if not self.Definitions[propertyID] then return false end
	ply.DRPPropertyZonePoint = nil
	ply.DRPPropertyZonePoints = nil
	return self:RemoveBuildZoneAt(ply, propertyID, position)
end

function Properties:ZoneToolReload(ply)
	if not self.CanConfigure(ply) then return false end
	local propertyID = math.floor(tonumber(ply.DRPPropertyZoneEditID) or 0)
	if not self.Definitions[propertyID] then return false end
	ply.DRPPropertyZonePoint = nil
	ply.DRPPropertyZonePoints = nil
	self:SendZoneEditor(ply, propertyID)
	DRP.Net.Notify(ply, "Pending build-zone selections cancelled.", 0)
	return true
end

function Properties:BuildPermissionAt(ply, position)
	if not IsValid(ply) or not isvector(position) then return false, nil, "invalid position" end
	if hasAdministrativeBuildOverride(ply) then return true, nil, "admin-mode owner override" end
	local id = steamID(ply)
	local candidates = {}
	for propertyID in pairs(self.OwnedProperties[id] or {}) do candidates[propertyID] = true end
	for propertyID in pairs(self.MemberProperties[id] or {}) do candidates[propertyID] = true end
	for propertyID in pairs(candidates) do
		local definition = self.Definitions[propertyID]
		if definition and self.Leases[propertyID] and self.Can(ply, propertyID, "build") then
			for _, zone in ipairs(definition.build_zones or {}) do
				if pointInsideZone(position, zone, self.BuildZoneTolerance) then return true, propertyID end
			end
		end
	end
	for propertyID, definition in pairs(self.Definitions) do
		if self.JobCanBuild(ply, propertyID) then
			for _, zone in ipairs(definition.build_zones or {}) do
				if pointInsideZone(position, zone, self.BuildZoneTolerance) then return true, propertyID end
			end
		end
	end
	if next(candidates) == nil then return false, nil, "You need property or job-base build access before spawning props." end
	return false, nil, "That position is outside your property's configured build zones."
end

function Properties:ValidateEntityPlacement(ply, entity, permission)
	if not IsValid(ply) or not IsValid(entity) then return false, nil, "invalid entity" end
	if DRP.Props and DRP.Props.IsPortableValuable and DRP.Props.IsPortableValuable(entity) then
		return true, nil, "portable valuable"
	end
	if hasAdministrativeBuildOverride(ply) then return true, entity.DRPPropertyID, "admin-mode owner override" end
	permission = permission == "storage" and "storage" or "build"
	local id = steamID(ply)
	local candidates = {}
	for propertyID in pairs(self.OwnedProperties[id] or {}) do candidates[propertyID] = true end
	for propertyID in pairs(self.MemberProperties[id] or {}) do candidates[propertyID] = true end
	for propertyID in pairs(candidates) do
		local definition = self.Definitions[propertyID]
		if definition and self.Leases[propertyID] and self.Can(ply, propertyID, permission) then
			if entityInsideZoneUnion(entity, definition.build_zones, self.BuildZoneTolerance) then return true, propertyID end
		end
	end
	if permission == "build" then
		for propertyID, definition in pairs(self.Definitions) do
			if self.JobCanBuild(ply, propertyID) then
				if entityInsideZoneUnion(entity, definition.build_zones, self.BuildZoneTolerance) then return true, propertyID end
			end
		end
	end
	if next(candidates) == nil then return false, nil, "You need property or job-base build access before spawning props." end
	return false, nil, "The complete prop must remain inside the combined authorised build zones."
end

-- Movement tools validate an already assigned entity against its original
-- property without re-resolving permissions or silently transferring it to a
-- neighbouring property. This is also used for staff physgun movement while
-- they are not in admin mode.
function Properties:EntityInsideAssignedBuildZones(entity, propertyID)
	propertyID = math.floor(tonumber(propertyID) or (IsValid(entity) and entity.DRPPropertyID) or 0)
	local definition = self.Definitions[propertyID]
	if not IsValid(entity) or not definition then
		return false, "That entity is not assigned to a valid property."
	end
	if entityInsideZoneUnion(entity, definition.build_zones, self.BuildZoneTolerance) then
		return true, propertyID
	end
	return false, "The complete prop must remain inside " .. tostring(definition.name or "its property") .. "'s build zones."
end

function Properties:AssignEntity(entity, ply, storage)
	if not IsValid(entity) or not IsValid(ply) then return nil end
	local valid, propertyID = self:ValidateEntityPlacement(ply, entity)
	if valid and propertyID then
		entity.DRPPropertyID = propertyID
		entity.DRPPropertyStorage = storage == true
		entity.DRPPropertyDefence = storage ~= true
		self:IndexEntity(entity, propertyID)
	end
	return propertyID
end

function Properties.MarkStorage(entity, propertyID)
	if not IsValid(entity) or not Properties.Definitions[tonumber(propertyID)] then return false end
	entity.DRPPropertyID = tonumber(propertyID)
	entity.DRPPropertyStorage = true
	entity.DRPPropertyDefence = false
	Properties:IndexEntity(entity, propertyID)
	return true
end

function Properties:SetEntityPurpose(ply, entity, propertyID, storage)
	propertyID = tonumber(propertyID) or (IsValid(entity) and entity.DRPPropertyID)
	local definition, lease = self.Get(propertyID)
	if not definition or not lease or not IsValid(entity) or entity:IsPlayer() or DRP.Doors.IsDoor(entity) then return false end
	local class = entity:GetClass()
	local ordinaryProp = class == "prop_physics" or class == "prop_physics_multiplayer" or class == "prop_physics_override"
	if storage and ordinaryProp and entity.DRPStorageCapable ~= true then return false end
	if self.ActiveRaids[propertyID] or not self.Can(ply, propertyID, storage and "storage" or "build") then return false end
	if entity.DRPPropertyID and entity.DRPPropertyID ~= propertyID then return false end
	if not entity.DRPPropertyID then
		local creator = entity.GetCreator and entity:GetCreator() or nil
		local knownOwnerID = DRP.Props and DRP.Props.OwnerID and DRP.Props.OwnerID(entity)
		local cppiOwner = entity.CPPIGetOwner and entity:CPPIGetOwner() or nil
		if knownOwnerID ~= ply:SteamID64() and creator ~= ply and cppiOwner ~= ply then return false end
	end
	local validPlacement, matchedPropertyID = self:ValidateEntityPlacement(ply, entity, storage and "storage" or "build")
	if not validPlacement or (matchedPropertyID and matchedPropertyID ~= propertyID) then return false end
	entity.DRPPropertyID = propertyID
	entity.DRPPropertyStorage = storage == true
	entity.DRPPropertyDefence = storage ~= true
	self:IndexEntity(entity, propertyID)
	if DRP.Audit then DRP.Audit.Log(ply, storage and "property_storage_marked" or "property_defence_marked", entity, "#" .. propertyID) end
	return true
end

function Properties.CanManageEntity(ply, entity, permission)
	if not IsValid(entity) or not entity.DRPPropertyID then return false end
	permission = permission or (entity.DRPPropertyStorage and "storage" or "build")
	if Properties.Can(ply, entity.DRPPropertyID, permission) then return true end
	return permission == "build" and Properties.JobCanBuild(ply, entity.DRPPropertyID)
end

function Properties:IsBuildLockedAt(position)
	for propertyID in pairs(self.ActiveRaids) do
		local definition = self.Definitions[propertyID]
		for _, zone in ipairs(definition and definition.build_zones or {}) do
			if pointInsideZone(position, zone, 0) then return true, propertyID end
		end
	end
	return false
end


assert(include("sv_raids.lua"),
	"missing core/properties/server/sv_raids.lua; upload the complete modular properties folder")

function Properties:CreateDefinition(ply, name, door)
	if not DRP.Admin or not DRP.Admin.Has(ply, "doors") or not DRP.Doors.IsDoor(door) then return false end
	local doorID = DRP.Doors.MapID(door)
	local selected, seen = selectedSetupDoors(ply)
	if not doorID or self.DoorToProperty[doorID] or DRP.Doors.Owner(door) ~= ply or not seen[doorID] or #selected == 0 then return false end
	local id = self.NextID
	self.NextID = self.NextID + 1
	local doorIDs = {}
	for index, record in ipairs(selected) do doorIDs[index] = record.id end
	self.Definitions[id] = {
		id = id,
		name = clean(name ~= "" and name or ("Property " .. id), 48),
		doors = doorIDs,
		build_zones = {},
		price = 0,
		lease_price = 0,
		buyable = true
	}
	self:RebuildDoorIndex()
	consumeSetupDoors(ply, selected)
	if not self:SaveConfiguration() then DRP.Net.Notify(ply, "Property group was created in memory, but persistence verification failed. Do not restart yet.", 3) end
	self:SyncAll(id)
	if DRP.Audit then DRP.Audit.Log(ply, "property_group_created", nil, "#" .. id .. " " .. self.Definitions[id].name .. " doors=" .. #doorIDs) end
	return true, id, #doorIDs
end

function Properties:AddOwnedDoors(ply, propertyID, mainDoor)
	local definition = self.Definitions[tonumber(propertyID)]
	if not definition or self.IsWorldDefinition(definition) or self.Leases[definition.id] or not DRP.Admin or not DRP.Admin.Has(ply, "doors") then return false end
	if IsValid(mainDoor) then
		local mainID = DRP.Doors.MapID(mainDoor)
		local groupedID = mainID and self.DoorToProperty[mainID]
		if groupedID and groupedID ~= definition.id then return false end
	end
	local selected = selectedSetupDoors(ply)
	if #selected == 0 then return false end
	for _, record in ipairs(selected) do definition.doors[#definition.doors + 1] = record.id end
	self:RebuildDoorIndex()
	consumeSetupDoors(ply, selected)
	if not self:SaveConfiguration() then DRP.Net.Notify(ply, "Door changes could not be verified on disk. Do not restart yet.", 3) end
	self:SyncAll(definition.id)
	if DRP.Audit then DRP.Audit.Log(ply, "property_group_doors_added", nil, "#" .. definition.id .. " doors=" .. #selected) end
	return true, #selected
end

function Properties:AddDoor(ply, propertyID, door)
	local definition = self.Definitions[tonumber(propertyID)]
	if not self.CanConfigure(ply) then return false, "Only HeadAdmin+ can add individual property doors" end
	if not definition then return false, "That property group does not exist" end
	if self.IsWorldDefinition(definition) then return false, "The World build-zone property cannot contain doors" end
	if self.Leases[definition.id] then return false, "Release the active property lease before changing its doors" end
	if not DRP.Doors.IsDoor(door) then return false, "Aim at a map door within 180 units" end
	local doorID = DRP.Doors.MapID(door)
	if not doorID then return false, "That door has no persistent map ID" end
	local existingPropertyID = self.DoorToProperty[tostring(doorID)]
	if existingPropertyID then return false, "That door already belongs to property group #" .. existingPropertyID end
	definition.doors[#definition.doors + 1] = doorID
	self:RebuildDoorIndex()
	if not self:SaveConfiguration() then DRP.Net.Notify(ply, "Door was added in memory, but persistence verification failed. Do not restart yet.", 3) end
	self:SyncAll(definition.id)
	if DRP.Audit then DRP.Audit.Log(ply, "property_group_single_door_added", door, "#" .. definition.id .. " door=" .. tostring(doorID)) end
	return true, nil, definition.id, doorID
end

function Properties:RemoveDoor(ply, door)
	if not DRP.Admin or not DRP.Admin.Has(ply, "doors") or not DRP.Doors.IsDoor(door) then return false end
	local doorID = DRP.Doors.MapID(door)
	local propertyID = doorID and self.DoorToProperty[doorID]
	local definition = propertyID and self.Definitions[propertyID]
	if not definition or self.Leases[propertyID] or #definition.doors <= 1 then return false end
	for index = #definition.doors, 1, -1 do if definition.doors[index] == doorID then table.remove(definition.doors, index) end end
	self:RebuildDoorIndex()
	if not self:SaveConfiguration() then DRP.Net.Notify(ply, "Door changes could not be verified on disk. Do not restart yet.", 3) end
	self:SyncAll(propertyID)
	return true
end

function Properties:SetPrice(ply, propertyID, price)
	local definition = self.Definitions[tonumber(propertyID)]
	price = math.floor(tonumber(price) or 0)
	if not definition or self.IsWorldDefinition(definition) or price < 0 or price > 10000000 or not self.CanConfigure(ply) then return false end
	definition.price = price
	if not self:SaveConfiguration() then DRP.Net.Notify(ply, "Property price could not be verified on disk. Do not restart yet.", 3) end
	self:SyncAll(definition.id)
	if DRP.Audit then DRP.Audit.Log(ply, "property_purchase_price_set", nil, "#" .. definition.id .. " $" .. definitionPrice(definition)) end
	return true
end

function Properties:SetLeasePrice(ply, propertyID, price)
	local definition = self.Definitions[tonumber(propertyID)]
	price = math.floor(tonumber(price) or 0)
	if not definition or self.IsWorldDefinition(definition) or price < 0 or price > 10000000 or not self.CanConfigure(ply) then return false end
	definition.lease_price = price
	if not self:SaveConfiguration() then DRP.Net.Notify(ply, "Lease price could not be verified on disk. Do not restart yet.", 3) end
	self:SyncAll(definition.id)
	if DRP.Audit then DRP.Audit.Log(ply, "property_lease_price_set", nil, "#" .. definition.id .. " $" .. definitionLeaseRate(definition)) end
	return true
end

function Properties:SetBuyable(ply, propertyID, buyable)
	local definition = self.Definitions[tonumber(propertyID)]
	if not definition or self.IsWorldDefinition(definition) or not self.CanConfigure(ply) then return false end
	definition.buyable = buyable == true
	if not self:SaveConfiguration() then DRP.Net.Notify(ply, "Property buyability could not be verified on disk. Do not restart yet.", 3) end
	self:SyncAll(definition.id)
	if DRP.Audit then DRP.Audit.Log(ply, "property_buyable_set", nil, "#" .. definition.id .. "=" .. tostring(definition.buyable)) end
	return true
end

function Properties:DeleteDefinition(ply, propertyID)
	propertyID = tonumber(propertyID)
	local definition = self.Definitions[propertyID]
	if not definition or self.IsWorldDefinition(definition) or self.Leases[propertyID] or not DRP.Admin or not DRP.Admin.Has(ply, "doors") then return false end
	self.Definitions[propertyID] = nil
	self:RebuildDoorIndex()
	if not self:SaveConfiguration() then DRP.Net.Notify(ply, "Property deletion could not be verified on disk. Do not restart yet.", 3) end
	self:SyncAll(propertyID)
	if DRP.Audit then DRP.Audit.Log(ply, "property_group_deleted", nil, "#" .. propertyID .. " " .. definition.name) end
	return true
end


hook.Add("CanTool", "DRP.Properties.ProtectTools", function(ply, trace, tool)
	if tool == "drp_property_zone" then return Properties.CanConfigure(ply) end
	local entity = trace and trace.Entity
	if not IsValid(entity) or not entity.DRPPropertyID then return end
	if Properties.ActiveRaids[entity.DRPPropertyID] and entity.DRPPropertyDefence and (tool == "remover" or tool == "duplicator") then return false end
	if not Properties.CanManageEntity(ply, entity, entity.DRPPropertyStorage and "storage" or "build") then return false end
end)

hook.Add("CanProperty", "DRP.Properties.ProtectEntityActions", function(ply, property, entity)
	if not IsValid(entity) or not entity.DRPPropertyID then return end
	if Properties.ActiveRaids[entity.DRPPropertyID] and entity.DRPPropertyDefence then return false end
	if not Properties.CanManageEntity(ply, entity) then return false end
end)

hook.Add("PlayerUse", "DRP.Properties.ProtectStorage", function(ply, entity)
	if IsValid(entity) and entity.DRPPropertyStorage and not Properties.CanManageEntity(ply, entity, "storage") then
		DRP.Net.Notify(ply, "Property storage access denied.", 3)
		return false
	end
end)

hook.Add("PlayerSpawnProp", "DRP.Properties.BuildZoneAuthorization", function(ply)
	if not IsValid(ply) then return false end
	if hasAdministrativeBuildOverride(ply) then return end
	local trace = ply:GetEyeTrace()
	if not trace.Hit or trace.HitSky then return false end
	if Properties:IsBuildLockedAt(trace.HitPos) then
		DRP.Net.Notify(ply, "Building is locked inside a declared raid area.", 3)
		return false
	end
	local allowed, _, reason = Properties:BuildPermissionAt(ply, trace.HitPos)
	if not allowed then
		DRP.Net.Notify(ply, reason or "Props can only be spawned inside an authorised property build zone.", 3)
		return false
	end
end)

hook.Add("DRPPlayerActivity", "DRP.Properties.Activity", function(ply, now)
	if next(Properties.OwnedProperties[ply:SteamID64()] or {}) == nil then return end
	now = tonumber(now) or CurTime()
	if (Properties.NextActivityCheck[ply] or 0) > now then return end
	Properties.NextActivityCheck[ply] = now + 1
	Properties:Touch(ply)
end)

hook.Add("DRPPlayerReady", "DRP.Properties.Reconnect", function(ply)
	if not Properties.Started then Properties:Start() end
	Properties.LastActivity[ply] = CurTime()
	Properties:ApplyCredit(ply)
	Properties:ApplyPendingVault(ply)
	Properties:Touch(ply)
	for propertyID in pairs(Properties.MemberProperties[ply:SteamID64()] or {}) do Properties:ScheduleMemberDeadline(propertyID, ply:SteamID64()) end
	for propertyID in pairs(Properties.OwnedProperties[ply:SteamID64()] or {}) do Properties:RefreshDoors(propertyID) end
	for propertyID in pairs(Properties.ActiveRaids) do Properties:AddDefenderToRaid(ply, propertyID) end
	Properties:Sync(ply)
end)

hook.Add("PlayerDisconnected", "DRP.Properties.OwnerOffline", function(ply)
	ply.DRPPropertyZoneEditID = nil
	ply.DRPPropertyZonePoint = nil
	ply.DRPPropertyZonePoints = nil
	local id = ply:SteamID64()
	local refresh = {}
	for propertyID in pairs(Properties.OwnedProperties[id] or {}) do
		refresh[#refresh + 1] = propertyID
		local lease = Properties.Leases[propertyID]
		if lease then lease.owner_offline_unix = os.time() end
		Properties:ScheduleOwnerDeadline(propertyID, true)
	end
	Properties.LastActivity[ply] = nil
	Properties.NextActivityCheck[ply] = nil
	Properties:Save()
	Properties:Flush()
	timer.Simple(0, function() for _, propertyID in ipairs(refresh) do Properties:RefreshDoors(propertyID) end end)
end)

hook.Add("InitPostEntity", "DRP.Properties.MapDoors", function()
	if not Properties.Started then Properties:Start() end
	Properties:FinishInitialSync()
end)

local requiredPropertiesAPI = {
	"Purchase",
	"PayLease",
	"SetMemberRent",
	"VaultDeposit",
	"VaultWithdraw",
	"BuildManagementSnapshot",
	"SendManagement",
	"SetPrice",
	"SetLeasePrice",
	"SetBuyable",
	"AddDoor",
	"SelectZoneEditor",
	"AddBuildZone",
	"RemoveBuildZoneAt",
	"ClearBuildZones",
	"BuildPermissionAt",
	"ValidateEntityPlacement",
	"LocationAt"
}

assert(Properties.GeometryModuleLoaded == true,
	"properties module incomplete: geometry submodule did not finish loading")
assert(Properties.PersistenceModuleLoaded == true,
	"properties module incomplete: persistence submodule did not finish loading")
assert(Properties.RaidModuleLoaded == true,
	"properties module incomplete: raid submodule did not finish loading")
for _, method in ipairs(requiredPropertiesAPI) do
	assert(isfunction(Properties[method]),
		"properties module incomplete: missing required method Properties." .. method)
end

Properties.ModuleBuild = "20260807-atomic-service-1"
DRP.Services.Register("properties", Properties)
print(string.format("[DRP PROPERTIES] module complete build=%s geometry=%s persistence=%s raids=%s",
	Properties.ModuleBuild,
	tostring(Properties.GeometryModuleLoaded == true),
	tostring(Properties.PersistenceModuleLoaded == true),
	tostring(Properties.RaidModuleLoaded == true)))
