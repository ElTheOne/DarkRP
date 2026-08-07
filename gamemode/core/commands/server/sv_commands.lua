local Commands = {}
DRP.Commands = Commands
local panelCommandMessage = "drp_admin_player_adjust_v1"
util.AddNetworkString(panelCommandMessage)

local function args(text)
	local values = {}
	for value in string.gmatch(string.Trim(text or ""), "%S+") do values[#values + 1] = value end
	return values
end

local function findPlayer(fragment)
	fragment = string.lower(fragment or "")
	if fragment == "" then return nil end
	local match
	for _, target in ipairs(DRP.Players.List) do
		if string.find(string.lower(target:Nick()), fragment, 1, true) or string.find(string.lower(target:DRPName()), fragment, 1, true) then
			if match then return nil end
			match = target
		end
	end
	return match
end

function Commands.rpname(ply, values)
	local name = string.Trim(table.concat(values, " "))
	name = string.gsub(string.gsub(name, "%c", ""), "%s+", " ")
	if #name < 3 or #name > 48 then DRP.Net.Notify(ply, "Usage: /rpname <name> (3-48 characters).", 3) return end
	local lowered = string.lower(name)
	for _, target in ipairs(DRP.Players.List) do
		if target ~= ply and string.lower(target:DRPName()) == lowered then DRP.Net.Notify(ply, "That RP name is already in use.", 3) return end
	end
	local previous = ply:DRPName()
	ply.DRPRPNameValue = name
	if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.RP_NAME) end
	DRP.Economy.QueueSave(ply)
	DRP.Net.Notify(ply, "Your RP name is now " .. name .. ".", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "rp_name_changed", nil, previous .. " -> " .. name) end
	if DRP.Government then DRP.Government.Sync() end
end

Commands.name = Commands.rpname

function Commands.jobname(ply, values)
	local title = string.gsub(string.gsub(string.Trim(table.concat(values, " ")), "%c", ""), "%s+", " ")
	if #title < 3 or #title > 48 then DRP.Net.Notify(ply, "Usage: /jobname <title> (3-48 characters).", 3) return end
	ply.DRPJobNameValue = title
	if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.JOB) end
	DRP.Economy.QueueSave(ply)
	DRP.Net.Notify(ply, "Your job title is now " .. title .. ".", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "job_title_changed", nil, title) end
end

local function canManageTarget(actor, target, permission)
	if not DRP.Admin or not DRP.Admin.Has(actor, permission) then
		DRP.Net.Notify(actor, "You do not have permission to use that command.", 3)
		return false
	end
	if not IsValid(target) or not target:DRPReady() then return false end
	if target == actor or DRP.Admin.IsOwner(actor) then return true end
	local actorLevel = DRP.AdminRankLevel(DRP.Admin.RankKey(actor))
	local targetLevel = DRP.AdminRankLevel(DRP.Admin.RankKey(target))
	if DRP.Admin.IsOwner(target) or targetLevel >= actorLevel then
		DRP.Net.Notify(actor, "You cannot modify an equal or higher-ranked player.", 3)
		return false
	end
	return true
end

local function commandTarget(actor, value, usage)
	local target = findPlayer(value)
	if IsValid(target) and target:DRPReady() then return target end
	DRP.Net.Notify(actor, usage .. " (player name must match uniquely)", 3)
end

local function commandAmount(actor, value, minimum, usage)
	local amount = tonumber(value)
	if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then
		DRP.Net.Notify(actor, usage, 3)
		return
	end
	amount = math.floor(amount)
	if amount < minimum or amount > 4294967295 then
		DRP.Net.Notify(actor, "Amount must be between " .. minimum .. " and 4294967295.", 3)
		return
	end
	return amount
end

local function commandXPAmount(actor, value, minimum, usage)
	local amount = tonumber(value)
	if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then
		DRP.Net.Notify(actor, usage, 3)
		return
	end
	amount = math.floor(amount)
	if amount < minimum then
		DRP.Net.Notify(actor, "Amount must be at least " .. minimum .. ".", 3)
		return
	end
	return amount
end

local function canDropWeapon(ply, class)
	if DRP.Inventory and DRP.Inventory.IsAlwaysAvailableWeapon and DRP.Inventory.IsAlwaysAvailableWeapon(ply, class) then return false end
	if not DRP.DropPolicy or DRP.DropPolicy.enable == false then return true end
	if DRP.DropPolicy.nonDroppableWeapons[class] then return false end
	for prefix in pairs(DRP.DropPolicy.jobWeaponPrefixes or {}) do
		if string.StartWith(class, prefix) then return false end
	end
	return true
end

function Commands.job(ply, values)
	local id = DRP.JobService.Resolve(values[1])
	local allowed, reason = DRP.JobService.CanJoin(ply, id)
	if not allowed then DRP.Net.Notify(ply, reason, 3) return end
	if id == DRP.Job.CITIZEN and ply:DRPJob().isGovernment and DRP.Roles then id = DRP.Roles:DerivedJob(ply) end
	ply.DRPRoleAdminOverride = nil
	DRP.JobService.Set(ply, id)
	DRP.Net.Notify(ply, "You are now a " .. DRP.Jobs[id].name .. ".", 1)
	if DRP.Roles then DRP.Roles:SendSnapshot(ply) end
end

function Commands.give(ply, values)
	local target = findPlayer(values[1])
	local amount = math.floor(tonumber(values[2]) or 0)
	if not IsValid(target) or target == ply then DRP.Net.Notify(ply, "Usage: /give <unique name> <amount>", 3) return end
	if amount < 1 or amount > 100000 then DRP.Net.Notify(ply, "Amount must be between 1 and 100000.", 3) return end
	if not DRP.Economy.Take(ply, amount) then DRP.Net.Notify(ply, "You cannot afford that.", 3) return end
	DRP.Economy.Add(target, amount)
	if DRP.Audit then DRP.Audit.Log(ply, "money_given", target, amount) end
	DRP.Net.Notify(ply, "Gave $" .. amount .. " to " .. target:Nick() .. ".", 1)
	DRP.Net.Notify(target, ply:Nick() .. " gave you $" .. amount .. ".", 1)
end

function Commands.dropmoney(ply, values)
	local amount = math.floor(tonumber(values[1]) or 0)
	if amount < 1 or amount > 100000 then
		DRP.Net.Notify(ply, "Usage: /dropmoney <amount> (1-100000)", 3)
		return
	end
	if not DRP.Money or not DRP.Money.Drop then
		DRP.Net.Notify(ply, "Cash drops are temporarily unavailable.", 3)
		return
	end
	DRP.Money.Drop(ply, amount)
end

function Commands.drop(ply)
	if not IsValid(ply) or not ply:Alive() or not ply:DRPReady() then return end
	local active = ply:GetActiveWeapon()
	if not IsValid(active) then DRP.Net.Notify(ply, "You are not holding anything to drop.", 3) return end
	local class = active:GetClass()
	if not canDropWeapon(ply, class) then
		DRP.Net.Notify(ply, "You cannot drop that item.", 3)
		return
	end
	local equippedRecord = DRP.Inventory and DRP.Inventory.EquippedWeaponRecord and DRP.Inventory.EquippedWeaponRecord(ply, class)
	if equippedRecord then
		DRP.Inventory.CaptureEquippedWeaponStates(ply)
		DRP.Inventory.DropByID(ply, equippedRecord.id)
		return
	end
	local budget = DRP.Services.Get("props")
	if not budget or not budget.CanCreateLimitedEntity("weapon") then
		DRP.Net.Notify(ply, "The server dropped-weapon budget is full.", 3)
		return
	end
	local dropped = ply:DropWeapon(active)
	if not IsValid(dropped) then
		DRP.Net.Notify(ply, "That item could not be dropped right now.", 3)
		return
	end
	if not budget.RegisterLimitedEntity(dropped, "weapon") then
		dropped:Remove()
		DRP.Net.Notify(ply, "The server dropped-weapon budget filled before the drop completed.", 3)
		return
	end
	DRP.Net.Notify(ply, "Dropped " .. (string.Trim(active:GetPrintName()) ~= "" and active:GetPrintName() or class) .. ".", 1)
end

function Commands.mayor(ply)
	DRP.Government.Apply(ply)
end

function Commands.vote(ply, values)
	DRP.Government.Vote(ply, table.concat(values, " "))
end

function Commands.tax(ply, values)
	DRP.Government.SetTax(ply, values[1])
end

function Commands.allocate(ply, values)
	DRP.Government.SetAllocation(ply, values[1], values[2])
end

function Commands.treasury(ply)
	local government = DRP.Government
	local allocations = {}
	for id, job in ipairs(DRP.Jobs) do
		local percent = government.Allocations[job.key] or 0
		if percent > 0 then allocations[#allocations + 1] = job.name .. " " .. percent .. "%" end
	end
	DRP.Net.Notify(ply, "Treasury $" .. string.Comma(government.Treasury) .. " — tax " .. government.TaxRate .. "%" .. (#allocations > 0 and (" — funding: " .. table.concat(allocations, ", ")) or " — no job funding"), 0)
end

function Commands.lottery(ply, values)
	DRP.Government.StartLottery(ply, values[1])
end

function Commands.lotteryenter(ply)
	DRP.Government.EnterLottery(ply)
end

function Commands.hands(ply) DRP.Inventory.Open(ply) end
function Commands.handdrop(ply, values) DRP.Inventory.Drop(ply, values[1]) end
Commands.pockets = Commands.hands
function Commands.pocketdrop(ply, values) DRP.Inventory.Drop(ply, values[1]) end
function Commands.marketplacelist(ply) DRP.Contracts.AddAimedEntity(ply) end
function Commands.marketplace(ply) DRP.Contracts.Sync(ply, true) end
function Commands.contracttestbuyer(ply) DRP.Contracts.CreateAutomatedBuyerListing(ply) end
function Commands.contracttestseller(ply) DRP.Contracts.CreateAutomatedSellerTrade(ply) end
function Commands.settradecenter(ply)
	if not DRP.Contracts:SetTradeCenter(ply) then DRP.Net.Notify(ply, "Only the server owner can set the trade center.", 3) end
end

function Commands.tip(ply, values)
	local amount = math.Clamp(math.floor(tonumber(values[1]) or 0), 0, 100000)
	local jar = ply:GetEyeTrace().Entity
	if amount < 1 or not IsValid(jar) or jar:GetClass() ~= "drp_tip_jar" then DRP.Net.Notify(ply, "Look at a tip jar and use /tip <amount>.", 3) return end
	local owner = DRP.Props.Owner(jar)
	if not IsValid(owner) or owner == ply or not DRP.Economy.Take(ply, amount, "tip") then return end
	DRP.Economy.Add(owner, amount, ply:DRPName() .. " tipped your jar")
end

function Commands.setevidence(ply)
	if not DRP.JobEntityService.AssignEvidence(ply, ply:GetEyeTrace().Entity, false) then DRP.Net.Notify(ply, "Look at an entity; door-management permission is required.", 3) end
end

function Commands.evidence(ply)
	local locker = DRP.JobEntityService.EvidenceLocker
	if IsValid(locker) then DRP.JobEntityService.Use(locker, ply) else DRP.Net.Notify(ply, "No evidence storage is assigned.", 3) end
end

function Commands.setjail(ply)
	if DRP.Legal.SetJail(ply) then DRP.Net.Notify(ply, "Jail position saved for this map.", 1) else DRP.Net.Notify(ply, "Door-management permission is required.", 3) end
end

function Commands.warrant(ply, values)
	local target = findPlayer(values[1])
	if not IsValid(target) or not DRP.Legal.RequestWarrant(ply, target, table.concat(values, " ", 2)) then DRP.Net.Notify(ply, "Usage: /warrant <player> <specific reason>.", 3) end
end

function Commands.approvewarrant(ply, values)
	if not DRP.Legal.ApproveWarrant(ply, values[1]) then DRP.Net.Notify(ply, "That pending warrant cannot be approved.", 3) end
end

function Commands.search(ply, values)
	local target = findPlayer(values[1])
	if not IsValid(target) or not DRP.Legal.Search(ply, target) then return end
end

function Commands.grantlicense(ply, values)
	if not DRP.Legal.GrantLicense(ply, findPlayer(values[1]), true) then DRP.Net.Notify(ply, "Usage: /grantlicense <player> (Mayor only).", 3) end
end
function Commands.revokelicense(ply, values)
	if not DRP.Legal.GrantLicense(ply, findPlayer(values[1]), false) then DRP.Net.Notify(ply, "Usage: /revokelicense <player> (Mayor only).", 3) end
end
function Commands.bail(ply) if not DRP.Legal.Bail(ply) then DRP.Net.Notify(ply, "You cannot pay bail right now.", 3) end end

function Commands.unarrest(ply, values)
	local target = findPlayer(values[1])
	if not IsValid(target) or (ply ~= DRP.Government.CurrentMayor() and (not DRP.Admin or not DRP.Admin.Has(ply, "adminmode"))) or not DRP.Legal.Release(target, "released by authority") then DRP.Net.Notify(ply, "Usage: /unarrest <player> (Mayor or authorized staff).", 3) end
end

function Commands.lockdown(ply, values)
	if not DRP.Legal.StartLockdown(ply, table.concat(values, " ")) then DRP.Net.Notify(ply, "Only the Mayor can begin a lockdown, and only one may be active.", 3) end
end

function Commands.unlockdown(ply)
	if not DRP.Legal.EndLockdown(ply, "Lockdown ended by authority") then DRP.Net.Notify(ply, "There is no lockdown you can end.", 3) end
end

function Commands.hit(ply, values)
	local target = findPlayer(values[1])
	DRP.Hits.Create(ply, target, values[2])
end

function Commands.hits(ply) DRP.Hits.List(ply) end
function Commands.accepthit(ply, values)
	if not DRP.Hits.Accept(ply, values[1]) then DRP.Net.Notify(ply, "That hit cannot be accepted.", 3) end
end

function Commands.agenda(ply, values)
	if #values == 0 then DRP.Net.Notify(ply, DRP.Agendas:Get(ply), 0) else DRP.Agendas:Set(ply, table.concat(values, " ")) end
end

local function lookedDoor(ply)
	local trace = util.TraceLine({ start = ply:EyePos(), endpos = ply:EyePos() + ply:GetAimVector() * 180, filter = ply, mask = MASK_SOLID })
	return DRP.Doors and DRP.Doors.IsDoor(trace.Entity) and trace.Entity or nil
end

local function propertyIDFor(ply, value)
	local requested = math.floor(tonumber(value) or 0)
	if requested > 0 and DRP.Properties.Get(requested) then return requested end
	local definition = DRP.Properties.PlayerProperty(ply, "access")
	return definition and definition.id or nil
end

function Commands.property(ply, values)
	local door = lookedDoor(ply)
	local definition, lease
	if door then definition, lease = DRP.Properties.ForDoor(door) end
	if not definition then
		local propertyID = propertyIDFor(ply, values[1])
		if propertyID then definition, lease = DRP.Properties.Get(propertyID) end
	end
	if not definition then DRP.Net.Notify(ply, "Look at a grouped door or provide a property ID.", 3) return end
	local _, role = DRP.Properties.Member(definition.id, ply)
	DRP.Net.Notify(ply, "Property #" .. definition.id .. " " .. definition.name .. " — owner: " .. (lease and lease.owner_name or "unowned") .. ", your role: " .. (role or "none") .. ", doors: " .. #definition.doors .. ".", 0)
end

function Commands.propertymanage(ply, values)
	local door = lookedDoor(ply)
	local definition = door and DRP.Properties.ForDoor(door)
	local propertyID = definition and definition.id or propertyIDFor(ply, values[1])
	if not propertyID then DRP.Net.Notify(ply, "Look at a grouped door or provide a property ID.", 3) return end
	DRP.Properties:SendManagement(ply, propertyID, true)
end

function Commands.propertypay(ply, values)
	local days = math.floor(tonumber(values[1]) or 0)
	local propertyID = propertyIDFor(ply, values[2])
	if days < 1 or days > DRP.Properties.MaxPrepaidDays or not propertyID or not DRP.Properties:PayLease(ply, propertyID, days) then
		DRP.Net.Notify(ply, "Usage: /propertypay <1-3 days> [property ID].", 3)
	end
end

function Commands.propertyaccept(ply)
	DRP.Properties:AcceptInvite(ply)
end

function Commands.propertyinvite(ply, values)
	local target = findPlayer(values[1])
	local propertyID = propertyIDFor(ply, values[5])
	if not IsValid(target) or not propertyID then DRP.Net.Notify(ply, "Usage: /propertyinvite <player> <role> <rent> <deposit> [property ID]", 3) return end
	if not DRP.Properties:Invite(ply, target, propertyID, values[2], values[3], values[4]) then DRP.Net.Notify(ply, "The property invitation could not be created.", 3) end
end

function Commands.propertyevict(ply, values)
	local target = findPlayer(values[1])
	local propertyID = propertyIDFor(ply, values[2])
	if not propertyID then DRP.Net.Notify(ply, "Usage: /propertyevict <player or SteamID64> [property ID]", 3) return end
	if not IsValid(target) then
		local memberID = DRP.Properties.FindMember(propertyID, values[1])
		target = memberID
	end
	if not target then DRP.Net.Notify(ply, "Tenant name must match uniquely, including offline tenants.", 3) return end
	if not DRP.Properties:BeginEviction(ply, target, propertyID, "owner eviction") then DRP.Net.Notify(ply, "That tenancy cannot be evicted.", 3) end
end

function Commands.propertysetrole(ply, values)
	local target = findPlayer(values[1])
	local propertyID = propertyIDFor(ply, values[3])
	if not IsValid(target) or not propertyID or not DRP.Properties:SetMemberRole(ply, target, propertyID, values[2]) then
		DRP.Net.Notify(ply, "Usage: /propertysetrole <player> <role> [property ID]", 3)
	end
end

function Commands.propertyrole(ply, values)
	local propertyID = propertyIDFor(ply, values[4])
	local enabled = tostring(values[3]) == "1" or string.lower(tostring(values[3])) == "true"
	if not propertyID or not DRP.Properties:SetRolePermission(ply, propertyID, values[1], values[2], enabled) then
		DRP.Net.Notify(ply, "Usage: /propertyrole <role> <access|storage|build|crafting|manage_members|manage_roles|finances> <0|1> [property ID]", 3)
	end
end

function Commands.propertyleave(ply, values)
	local propertyID = propertyIDFor(ply, values[1])
	local lease
	if propertyID then
		local ignored
		ignored, lease = DRP.Properties.Get(propertyID)
	end
	local id = ply:SteamID64()
	if not lease or lease.owner_id == id or not lease.members[id] then DRP.Net.Notify(ply, "You are not a tenant of that property.", 3) return end
	if not DRP.Properties:RemoveMember(propertyID, id, "tenant left voluntarily") then DRP.Net.Notify(ply, "Tenancy cannot change during a declared or active raid.", 3) end
end

function Commands.propertyrelease(ply, values)
	local propertyID = propertyIDFor(ply, values[1])
	local role
	if propertyID then local member; member, role = DRP.Properties.Member(propertyID, ply) end
	if role ~= "owner" then DRP.Net.Notify(ply, "Only the property owner can release it.", 3) return end
	local released, reason = DRP.Properties:Release(propertyID, "owner sale", 0.8)
	if not released then DRP.Net.Notify(ply, reason or "The property cannot be released.", 3) end
end

function Commands.propertystorage(ply, values)
	local entity = ply:GetEyeTrace().Entity
	local propertyID = propertyIDFor(ply, values[1])
	if DRP.Properties:SetEntityPurpose(ply, entity, propertyID, true) then DRP.Net.Notify(ply, "Entity registered as protected property storage.", 1) else DRP.Net.Notify(ply, "Look at a nearby owned entity within your property.", 3) end
end

function Commands.propertydefence(ply, values)
	local entity = ply:GetEyeTrace().Entity
	local propertyID = propertyIDFor(ply, values[1])
	if DRP.Properties:SetEntityPurpose(ply, entity, propertyID, false) then DRP.Net.Notify(ply, "Entity registered as a raid defence.", 1) else DRP.Net.Notify(ply, "That entity cannot become a property defence.", 3) end
end

function Commands.raid(ply, values)
	local propertyID = math.floor(tonumber(values[1]) or 0)
	if propertyID <= 0 then
		local door = lookedDoor(ply)
		local definition = door and DRP.Properties.ForDoor(door)
		propertyID = definition and definition.id or 0
	end
	if propertyID <= 0 then DRP.Net.Notify(ply, "Usage: /raid <property ID>, or look at a grouped property door.", 3) return end
	DRP.Properties:DeclareRaid(ply, propertyID)
end

function Commands.raidjoin(ply, values)
	if not DRP.Properties:JoinRaid(ply, values[1]) then DRP.Net.Notify(ply, "Usage: /raidjoin <declared incident ID>.", 3) end
end

function Commands.raidarmory(ply)
	local entity = ply:GetEyeTrace().Entity
	if not IsValid(entity) or entity:GetClass() ~= "drp_police_armory" or ply:GetPos():DistToSqr(entity:GetPos()) > 65536 then
		DRP.Net.Notify(ply, "Look at a nearby police armory and use /raidarmory, or press E on it.", 3)
		return
	end
	if DRP.Armory then DRP.Armory:StartOrJoinRaid(ply, entity) end
end

function Commands.raidtreasury(ply)
	local entity = ply:GetEyeTrace().Entity
	if not IsValid(entity) or entity:GetClass() ~= "drp_treasury_vault" or ply:GetPos():DistToSqr(entity:GetPos()) > 65536 then
		DRP.Net.Notify(ply, "Look at the nearby Treasury Vault and use /raidtreasury, or press E on it.", 3)
		return
	end
	if DRP.Treasury then DRP.Treasury:StartOrJoinRaid(ply, entity) end
end

function Commands.propertycreate(ply, values)
	local name = table.concat(values, " ")
	local created, id, count = DRP.Properties:CreateDefinition(ply, name, lookedDoor(ply))
	if created then DRP.Net.Notify(ply, "Created property group #" .. id .. " from " .. count .. " selected doors.", 1) else DRP.Net.Notify(ply, "Buy every ungrouped door in the building, look at its main door, then use /propertycreate <name>.", 3) end
end

function Commands.propertyadddoor(ply, values)
	local mainDoor = lookedDoor(ply)
	local propertyID = tonumber(values[1])
	if propertyID and IsValid(mainDoor) and not DRP.Properties.ForDoor(mainDoor) then
		local added, reason, resolvedID, doorID = DRP.Properties:AddDoor(ply, propertyID, mainDoor)
		if added then
			DRP.Net.Notify(ply, "Added door " .. tostring(doorID) .. " to property group #" .. resolvedID .. ".", 1)
		else
			DRP.Net.Notify(ply, reason or "HeadAdmin+ usage: aim at an ungrouped door and use /propertyadddoor <property ID>.", 3)
		end
		return
	end
	if not propertyID and mainDoor then
		local definition = DRP.Properties.ForDoor(mainDoor)
		propertyID = definition and definition.id
	end
	local added, count = DRP.Properties:AddOwnedDoors(ply, propertyID, mainDoor)
	if added then DRP.Net.Notify(ply, "Added " .. count .. " selected doors to property group #" .. propertyID .. ".", 1) else DRP.Net.Notify(ply, "Buy the additional ungrouped doors, look at the group's main door, then use /propertyadddoor [ID].", 3) end
end

function Commands.propertyaddsingledoor(ply, values)
	local propertyID = math.floor(tonumber(values[1]) or 0)
	local added, reason, resolvedID, doorID = DRP.Properties:AddDoor(ply, propertyID, lookedDoor(ply))
	if added then
		DRP.Net.Notify(ply, "Added door " .. tostring(doorID) .. " to property group #" .. resolvedID .. ".", 1)
	else
		DRP.Net.Notify(ply, reason or "HeadAdmin+ usage: aim at an ungrouped door and use /propertyaddsingledoor <property ID>.", 3)
	end
end

Commands.propertydooradd = Commands.propertyaddsingledoor
Commands.adddoortoproperty = Commands.propertyaddsingledoor

function Commands.propertyremovedoor(ply)
	if DRP.Properties:RemoveDoor(ply, lookedDoor(ply)) then DRP.Net.Notify(ply, "Door removed from its property group.", 1) else DRP.Net.Notify(ply, "The door cannot be removed while its property is owned or when it is the final group door.", 3) end
end

function Commands.propertyprice(ply, values)
	if DRP.Properties:SetPrice(ply, values[1], values[2]) then DRP.Net.Notify(ply, "Property price updated; use 0 for automatic per-door pricing.", 1) else DRP.Net.Notify(ply, "HeadAdmin+ usage: /propertyprice <property ID> <0-10000000>.", 3) end
end

function Commands.propertyleaseprice(ply, values)
	if DRP.Properties:SetLeasePrice(ply, values[1], values[2]) then DRP.Net.Notify(ply, "Daily property lease updated; use 0 for the automatic 10% rate.", 1) else DRP.Net.Notify(ply, "HeadAdmin+ usage: /propertyleaseprice <property ID> <0-10000000>.", 3) end
end

function Commands.propertybuyable(ply, values)
	local raw = string.lower(tostring(values[2] or ""))
	local enabled = raw == "1" or raw == "true" or raw == "yes"
	if (raw == "0" or raw == "false" or raw == "no" or enabled) and DRP.Properties:SetBuyable(ply, values[1], enabled) then
		DRP.Net.Notify(ply, "Property purchases are now " .. (enabled and "enabled." or "disabled."), 1)
	else
		DRP.Net.Notify(ply, "HeadAdmin+ usage: /propertybuyable <property ID> <0|1>.", 3)
	end
end

function Commands.propertydelete(ply, values)
	if DRP.Properties:DeleteDefinition(ply, values[1]) then DRP.Net.Notify(ply, "Property group deleted.", 1) else DRP.Net.Notify(ply, "Only unowned property groups can be deleted.", 3) end
end

local function setJobForTarget(ply, target, jobValue)
	if not target or not canManageTarget(ply, target, "jobs") then return end
	local jobID = DRP.JobService.Resolve(jobValue)
	local usage = "Usage: /setjob <unique name> <job>"
	if not jobID then DRP.Net.Notify(ply, usage, 3) return end
	local previous = target:DRPJob().name
	if target:DRPJobID() == jobID then
		DRP.Net.Notify(ply, target:Nick() .. " already has that job.", 3)
		return
	end
	target.DRPRoleAdminOverride = true
	if not DRP.JobService.Set(target, jobID) then
		target.DRPRoleAdminOverride = nil
		if jobID == DRP.Job.MOB_BOSS then
			DRP.Net.Notify(ply, "Mob Boss requires exactly " .. DRP.Civic.Minimum .. " civic standing and its single server slot must be vacant.", 3)
		else
			DRP.Net.Notify(ply, "That job could not be assigned.", 3)
		end
		return
	end
	if DRP.Roles then DRP.Roles:SendSnapshot(target) end
	local current = DRP.Jobs[jobID].name
	if DRP.Audit then DRP.Audit.Log(ply, "admin_setjob", target, previous .. " -> " .. current) end
	DRP.Net.Notify(ply, "Set " .. target:Nick() .. "'s job to " .. current .. ".", 1)
	if target ~= ply then DRP.Net.Notify(target, ply:Nick() .. " set your job to " .. current .. ".", 0) end
end

function Commands.setjob(ply, values)
	local usage = "Usage: /setjob <unique name> <job>"
	local target = commandTarget(ply, values[1], usage)
	setJobForTarget(ply, target, values[2])
end

local function changeMoney(ply, values, mode, directTarget)
	local command = mode == "set" and "setmoney" or (mode == "add" and "addmoney" or "deductmoney")
	local usage = "Usage: /" .. command .. " <unique name> <amount>"
	local target = directTarget or commandTarget(ply, values[1], usage)
	if not target or not canManageTarget(ply, target, "money") then return end
	local amount = commandAmount(ply, values[2], mode == "set" and 0 or 1, usage)
	if amount == nil then return end

	local previous = target:DRPMoney()
	local updated
	if mode == "set" then
		updated = amount
	elseif mode == "add" then
		if previous + amount > 4294967295 then
			DRP.Net.Notify(ply, "That would exceed the maximum wallet value.", 3)
			return
		end
		updated = previous + amount
	else
		if amount > previous then
			DRP.Net.Notify(ply, target:Nick() .. " only has $" .. string.Comma(previous) .. ".", 3)
			return
		end
		updated = previous - amount
	end

	DRP.Economy.Set(target, updated)
	if DRP.Audit then DRP.Audit.Log(ply, "admin_" .. command, target, "$" .. previous .. " -> $" .. updated) end
	DRP.Net.Notify(ply, target:Nick() .. " now has $" .. string.Comma(updated) .. ".", 1)
	if target ~= ply then DRP.Net.Notify(target, ply:Nick() .. " updated your wallet to $" .. string.Comma(updated) .. ".", 0) end
end

local function changeExperience(ply, values, mode, directTarget)
	local experience = DRP.Experience or (DRP.Services and DRP.Services.Get and DRP.Services.Get("experience"))
	if not experience then DRP.Net.Notify(ply, "Experience service failed startup validation; check server console.", 3) return end

	local command = mode == "set" and "setxp" or (mode == "add" and "addxp" or "deductxp")
	local usage = "Usage: /" .. command .. " <unique name> <amount>"
	local target = directTarget or commandTarget(ply, values[1], usage)
	if not target or not canManageTarget(ply, target, "experience") then return end

	local amount = commandXPAmount(ply, values[2], mode == "set" and 0 or 1, usage)
	if amount == nil then return end

	local previousXP = experience:TotalXPForPlayer(target)
	local ok
	if mode == "set" then
		ok = experience:SetTotalXP(target, amount, "admin", string.format("Admin %s set XP to %d", ply:DRPName(), amount))
	elseif mode == "add" then
		ok = experience:AdjustTotalXP(target, amount, "admin", string.format("Admin %s added %d XP", ply:DRPName(), amount))
	else
		ok = experience:AdjustTotalXP(target, -amount, "admin", string.format("Admin %s deducted %d XP", ply:DRPName(), amount))
	end

	if not ok then
		DRP.Net.Notify(ply, "Could not update XP for " .. target:Nick() .. ".", 3)
		return
	end

	local updatedXP = experience:TotalXPForPlayer(target)
	if DRP.Audit then DRP.Audit.Log(ply, "admin_" .. command, target, "XP " .. previousXP .. " -> " .. updatedXP) end
	DRP.Net.Notify(ply, target:Nick() .. " XP is now " .. string.Comma(updatedXP) .. ".", 1)
	if target ~= ply then DRP.Net.Notify(target, ply:Nick() .. " adjusted your XP to " .. string.Comma(updatedXP) .. ".", 0) end
end

local function changeCivic(ply, values, mode, directTarget)
	local civic = DRP.Civic or (DRP.Services and DRP.Services.Get and DRP.Services.Get("civic"))
	if not civic then DRP.Net.Notify(ply, "Civic service failed startup validation; check server console.", 3) return end
	local command = mode == "set" and "setcivic" or (mode == "add" and "addcivic" or "deductcivic")
	local usage = "Usage: /" .. command .. " <unique name> <amount>"
	local target = directTarget or commandTarget(ply, values[1], usage)
	if not target or not canManageTarget(ply, target, "civic") then return end
	local amount = tonumber(values[2])
	if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then DRP.Net.Notify(ply, usage, 3) return end
	amount = math.floor(amount)
	if mode == "set" then
		if amount < civic.Minimum or amount > civic.Maximum then
			DRP.Net.Notify(ply, "Civic standing must be between " .. civic.Minimum .. " and " .. civic.Maximum .. ".", 3)
			return
		end
	elseif amount < 1 or amount > civic.Maximum - civic.Minimum then
		DRP.Net.Notify(ply, "Adjustment must be between 1 and " .. (civic.Maximum - civic.Minimum) .. ".", 3)
		return
	end
	local previous = civic:Get(target)
	local requested = mode == "set" and amount or previous + (mode == "add" and amount or -amount)
	civic:Set(target, requested, "administrative adjustment by " .. ply:DRPName(), true)
	local updated = civic:Get(target)
	if updated == previous and requested ~= previous then DRP.Net.Notify(ply, target:Nick() .. " is already at the civic standing limit.", 3) return end
	if DRP.Audit then DRP.Audit.Log(ply, "admin_" .. command, target, "civic " .. previous .. " -> " .. updated) end
	DRP.Net.Notify(ply, target:Nick() .. " civic standing is now " .. updated .. ".", 1)
	if target ~= ply then DRP.Net.Notify(target, ply:Nick() .. " adjusted your civic standing to " .. updated .. ".", 0) end
end

function Commands.setxp(ply, values) changeExperience(ply, values, "set") end
function Commands.addxp(ply, values) changeExperience(ply, values, "add") end
function Commands.deductxp(ply, values) changeExperience(ply, values, "deduct") end
function Commands.setcivic(ply, values) changeCivic(ply, values, "set") end
function Commands.addcivic(ply, values) changeCivic(ply, values, "add") end
function Commands.deductcivic(ply, values) changeCivic(ply, values, "deduct") end

function Commands.setmoney(ply, values) changeMoney(ply, values, "set") end
function Commands.addmoney(ply, values) changeMoney(ply, values, "add") end
function Commands.deductmoney(ply, values) changeMoney(ply, values, "deduct") end

local panelActions = {
	[1] = function(actor, target, value) setJobForTarget(actor, target, value) end,
	[2] = function(actor, target, value) changeMoney(actor, { "", value }, "set", target) end,
	[3] = function(actor, target, value) changeMoney(actor, { "", value }, "add", target) end,
	[4] = function(actor, target, value) changeMoney(actor, { "", value }, "deduct", target) end,
	[5] = function(actor, target, value) changeExperience(actor, { "", value }, "set", target) end,
	[6] = function(actor, target, value) changeExperience(actor, { "", value }, "add", target) end,
	[7] = function(actor, target, value) changeExperience(actor, { "", value }, "deduct", target) end,
	[8] = function(actor, target, value) changeCivic(actor, { "", value }, "set", target) end,
	[9] = function(actor, target, value) changeCivic(actor, { "", value }, "add", target) end,
	[10] = function(actor, target, value) changeCivic(actor, { "", value }, "deduct", target) end
}

DRP.Net.Receive(panelCommandMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local action = net.ReadUInt(4)
	local target = Entity(net.ReadUInt(13))
	local value = string.sub(net.ReadString(), 1, 64)
	if not DRP.Net.Allow(ply, "admin_player_adjust", 0.25, 5) then return end
	if not IsValid(target) or not target:IsPlayer() or not target:DRPReady() or not panelActions[action] then return end
	panelActions[action](ply, target, value)
end)

function Commands.admin(ply)
	if not DRP.AdminMode then DRP.Net.Notify(ply, "Admin Mode is unavailable.", 3) return end
	DRP.AdminMode.Toggle(ply)
end

Commands.adminmode = Commands.admin

function Commands.massie(ply)
	if DRP.Massie then DRP.Massie:Request(ply) end
end

function Commands.trust(ply, values)
	local target = ply
	if values[1] and DRP.Admin and DRP.Admin.IsAdmin(ply) then target = findPlayer(values[1]) or ply end
	local state = DRP.Trust and DRP.Trust:Get(target)
	if not state then DRP.Net.Notify(ply, (target == ply and "Your" or (target:DRPName() .. "'s")) .. " trust signals are still being evaluated.", 2) return end
	DRP.Net.Notify(ply, string.format("%s: Trust %d/100 — %s — %d/8 signals verified.", target:DRPName(), state.score or 50, state.label or "UNVERIFIED", state.known or 0), (state.score or 50) >= 65 and 1 or 2)
	if target ~= ply and (not DRP.Admin or not DRP.Admin.IsAdmin(ply)) then return end
	local reasons = table.concat(state.reasons or {}, "  •  ")
	if reasons ~= "" then
		for index = 1, #reasons, 150 do DRP.Net.Notify(ply, string.sub(reasons, index, index + 149), 0) end
	end
end

function Commands.discordlink(ply)
	if not DRP.Trust then
		DRP.Net.Notify(ply, "Discord linking service is not loaded. The server needs the current init.lua and sv_trust.lua.", 3)
		return
	end
	local success, reason = DRP.Trust:JoinDiscord(ply)
	if not success then DRP.Net.Notify(ply, reason or "Discord linking is unavailable.", 3) end
end

function Commands.discordverify(ply)
	if not DRP.Trust then
		DRP.Net.Notify(ply, "Discord linking service is not loaded. The server needs the current init.lua and sv_trust.lua.", 3)
		return
	end
	local success, reason = DRP.Trust:BeginOrCheckDiscordVerification(ply)
	if not success then DRP.Net.Notify(ply, reason or "Discord verification could not start.", 3) end
end

function Commands.discordunlink(ply)
	if not DRP.Trust or not DRP.Trust:UnlinkDiscord(ply) then DRP.Net.Notify(ply, "No Discord account is currently linked.", 3) else DRP.Net.Notify(ply, "Discord account unlinked.", 1) end
end

function Commands.civichint(ply)
	if not DRP.Hints then
		DRP.Net.Notify(ply, "The hint service is not ready.", 3)
		return
	end
	DRP.Hints:CivicGuidance(ply, true)
end

function Commands.releasekidnap(ply)
	if not DRP.Kidnapping or not DRP.Kidnapping.Release(ply) then
		DRP.Net.Notify(ply, "You do not have an active kidnapping to release.", 3)
	end
end

function Commands.recordincident(ply)
	net.Start("drp_incident_record_toggle_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
	net.Send(ply)
end

local function adminTargetAction(ply, values, action, command, amountIndex, minimum)
	local usage = "Usage: /" .. command .. " <unique name>" .. (amountIndex and " <amount>" or "")
	local target = commandTarget(ply, values[1], usage)
	if not target then return end
	local amount = 0
	if amountIndex then
		amount = commandAmount(ply, values[amountIndex], minimum or 0, usage)
		if amount == nil then return end
		if amount > 1000000 then DRP.Net.Notify(ply, "Health and armor are limited to 1000000.", 3) return end
	end
	DRP.AdminMode.Perform(ply, action, target, amount)
end

function Commands.noclip(ply) DRP.AdminMode.Perform(ply, DRP.AdminModeAction.NOCLIP) end
function Commands.cloak(ply) DRP.AdminMode.Perform(ply, DRP.AdminModeAction.CLOAK) end
function Commands.unspectate(ply) DRP.AdminMode.Perform(ply, DRP.AdminModeAction.STOP_SPECTATE) end
function Commands.spectate(ply, values) adminTargetAction(ply, values, DRP.AdminModeAction.SPECTATE, "spectate") end
function Commands.freeze(ply, values) adminTargetAction(ply, values, DRP.AdminModeAction.FREEZE, "freeze") end
function Commands.unfreeze(ply, values) adminTargetAction(ply, values, DRP.AdminModeAction.UNFREEZE, "unfreeze") end
function Commands.respawn(ply, values) adminTargetAction(ply, values, DRP.AdminModeAction.RESPAWN, "respawn") end
function Commands.strip(ply, values) adminTargetAction(ply, values, DRP.AdminModeAction.STRIP_WEAPONS, "strip") end
function Commands.jail(ply, values) adminTargetAction(ply, values, DRP.AdminModeAction.JAIL, "jail") end
function Commands.unjail(ply, values) adminTargetAction(ply, values, DRP.AdminModeAction.UNJAIL, "unjail") end
function Commands.sethealth(ply, values) adminTargetAction(ply, values, DRP.AdminModeAction.SET_HEALTH, "sethealth", 2, 1) end
function Commands.setarmor(ply, values) adminTargetAction(ply, values, DRP.AdminModeAction.SET_ARMOR, "setarmor", 2, 0) end

function Commands.help(ply)
	DRP.Net.Notify(ply, "/rpname, /hands, /handdrop, /drop, /give, /marketplace, /marketplacelist, /mayor, /vote, /property, /raid. Roles are earned through civic standing and behavior; /job is reserved for government service. F4/I opens the menu.", 0)
	DRP.Net.Notify(ply, "Marketplace: /marketplacelist aims a new sale; /listing<number>add adds another aimed entity. Solo tests: /contracttestbuyer and /contracttestseller.", 0)
	DRP.Net.Notify(ply, "/setxp, /addxp, /deductxp let staff manage player XP (Experience permission).", 0)
	DRP.Net.Notify(ply, "/setcivic, /addcivic, /deductcivic manage civic standing (Civic permission).", 0)
	DRP.Net.Notify(ply, "/trust shows your trust calculation. /discordlink, /discordverify and /discordunlink manage Discord verification.", 0)
	DRP.Net.Notify(ply, "/civichint explains which lawful and criminal outcomes change civic standing. Kidnappers may use /releasekidnap.", 0)
	DRP.Net.Notify(ply, "/recordincident starts or stops a clientside demo. Automatic incident recording is available in F4 > Settings.", 0)
end

function GM:PlayerSay(ply, text, teamChat)
	local prefix = string.sub(text, 1, 1)
	local normalized = string.lower(string.Trim(text))
	local bangCommand = prefix == "!" and string.lower(string.Trim(string.sub(text, 2))) or ""
	local bangAdmin = bangCommand == "admin" or bangCommand == "adminmode"
	local bareAdminMode = normalized == "adminmode"
	if prefix ~= "/" and not bangAdmin and not bareAdminMode then
		if DRP.ChatServer then DRP.ChatServer.Send(ply, teamChat and 2 or 1, text) end
		return ""
	end
	if not ply:DRPReady() or not DRP.Net.Allow(ply, "chat_command", 0.5, 4) then return "" end
	local started = DRP.Profile.Begin()

	local command, remainder
	if bareAdminMode then
		command, remainder = "adminmode", ""
	else
		command, remainder = string.match(text, "^[!/]([^%s]+)%s*(.*)$")
	end
	local normalizedCommand = command and string.lower(command)
	local handler = normalizedCommand and Commands[normalizedCommand]
	if handler then
		handler(ply, args(remainder))
	else
		local listingID = normalizedCommand and string.match(normalizedCommand, "^listing(%d+)add$")
		if listingID then
			DRP.Contracts.AddAimedEntity(ply, tonumber(listingID))
		else
			DRP.Net.Notify(ply, "Unknown command. Use /help.", 3)
		end
	end
	DRP.Profile.Finish("commands.execute", started)
	return ""
end

concommand.Add("drp_setmoney", function(ply, _, values)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.Has(ply, "money")) then return end
	local target = findPlayer(values[1])
	local amount = tonumber(values[2])
	if not IsValid(target) or not amount then return end
	DRP.Economy.Set(target, amount)
	DRP.Net.Notify(target, "Your wallet was set to $" .. target:DRPMoney() .. ".", 0)
end)
