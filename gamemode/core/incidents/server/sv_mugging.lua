local requestMessage = "drp_mug_request_v1"
local noticeMessage = "drp_mug_notice_v1"
local moneyMessage = "drp_money_drop_v1"
local actionMessage = "drp_mug_action_v1"

util.AddNetworkString(requestMessage)
util.AddNetworkString(noticeMessage)
util.AddNetworkString(moneyMessage)
util.AddNetworkString(actionMessage)

local Mugging = {
	Active = {},
	ByMugger = setmetatable({}, { __mode = "k" }),
	ByVictim = setmetatable({}, { __mode = "k" }),
	MoneyDrops = setmetatable({}, { __mode = "k" }),
	NextID = 1,
	DemandTime = 10,
	CombatTime = 30,
	Cooldown = 45,
	MaxAmount = 5000,
	MaxDistance = 180,
	MoveTolerance = 24,
	StandingStillSpeed = 8
}

DRP.Mugging = Mugging
DRP.Money = DRP.Money or {}
DRP.Services.Register("mugging", Mugging)

DRP.Incidents.RegisterType("mugging", {
	initial = "demand_pending",
	transitions = {
		demand_pending = { combat_active = true }
	},
	outcomes = {
		payment_received = { winner = "instigator", loser = "victim" },
		victim_killed = { winner = "instigator", loser = "victim" },
		mugger_killed = { winner = "victim", loser = "instigator" },
		default = { winner = "instigator", loser = "victim" }
	},
	onParticipantUnavailable = function(incident, ply, resolution)
		if resolution ~= "participant_died" then return false end
		if ply == incident.victim then
			DRP.Incidents.Resolve(incident, "victim_killed", "Mugging victim died")
		else
			DRP.Incidents.Resolve(incident, "mugger_killed", "Mugging instigator died")
		end
		return true
	end
})

local function moneyText(amount)
	return "$" .. string.Comma(math.max(0, math.floor(amount or 0)))
end

local function sendNotice(ply, state, isVictim, other, amount, duration, reason)
	if not IsValid(ply) then return end
	net.Start(noticeMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.Clamp(state or 0, 0, 3), 2)
	net.WriteBool(isVictim == true)
	net.WriteString(IsValid(other) and string.sub(other:Nick(), 1, 64) or "Unknown player")
	net.WriteUInt(math.Clamp(math.floor(amount or 0), 0, 65535), 16)
	net.WriteUInt(math.Clamp(math.ceil(duration or 0), 0, 255), 8)
	net.WriteString(string.sub(tostring(reason or ""), 1, 96))
	net.Send(ply)
end

local function clearRecord(record)
	if not record or not Mugging.Active[record.id] then return end
	Mugging.Active[record.id] = nil
	if Mugging.ByMugger[record.mugger] == record then Mugging.ByMugger[record.mugger] = nil end
	if Mugging.ByVictim[record.victim] == record then Mugging.ByVictim[record.victim] = nil end
end

local function cancel(record, reason)
	if not record or not Mugging.Active[record.id] then return end
	local incident = DRP.Incidents.Get(record.incidentID)
	if incident then DRP.Incidents.Resolve(incident, "cancelled", reason or "Mugging cancelled") end
	if IsValid(record.mugger) then sendNotice(record.mugger, 0, false, record.victim, record.amount, 0, reason) end
	if IsValid(record.victim) then sendNotice(record.victim, 0, true, record.mugger, record.amount, 0, reason) end
	clearRecord(record)
end

local function escalate(record, reason)
	if not record or not Mugging.Active[record.id] then return end
	if record.combat then return true end
	reason = tostring(reason or "demand resisted")
	local incident = DRP.Incidents.Get(record.incidentID)
	if not incident or not IsValid(record.mugger) or not IsValid(record.victim) then
		cancel(record, "Mugging incident became unavailable")
		return false
	end

	local deadline = CurTime() + Mugging.CombatTime
	local label = "Mugging escalated: " .. reason
	local transitioned = DRP.Incidents.Transition(incident, "combat_active", label)
	local muggerGranted = transitioned and DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, record.mugger, record.victim, label, deadline)
	local victimGranted = transitioned and DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, record.victim, record.mugger, label, deadline)
	if not transitioned or not muggerGranted or not victimGranted then
		ErrorNoHalt("[DRP] Mugging #" .. tostring(record.id) .. " failed to establish mutual PvP permissions\n")
		cancel(record, "Mugging escalation could not establish PvP")
		return false
	end

	DRP.Incidents.SetDeadline(incident, deadline, true)
	DRP.Incidents.AddEvidence(incident, "demand_resisted", record.victim, record.mugger, reason)
	record.combat = true
	record.expires = deadline
	if IsValid(record.mugger) then
		DRP.Net.Notify(record.mugger, "Mugging escalated: " .. reason .. ". PvP is now two-way.", 2)
		sendNotice(record.mugger, 3, false, record.victim, record.amount, Mugging.CombatTime, reason)
	end
	if IsValid(record.victim) then
		DRP.Net.Notify(record.victim, "Mugging escalated: " .. reason .. ". PvP is now two-way.", 2)
		sendNotice(record.victim, 3, true, record.mugger, record.amount, Mugging.CombatTime, reason)
	end
	if DRP.Audit then DRP.Audit.Log(record.mugger, "mugging_escalated", record.victim, reason) end
	-- Keep the record indexed while combat is active so a death can resolve
	-- the originating mugging incident with a deterministic outcome.
	return true
end

local function paid(record)
	if not record or not Mugging.Active[record.id] then return end
	local incident = DRP.Incidents.Get(record.incidentID)
	if incident then
		DRP.Incidents.AddEvidence(incident, "demand_paid", record.victim, record.mugger, moneyText(record.amount), true)
		DRP.Incidents.Resolve(incident, "payment_received", "Mugging demand paid")
	end
	if IsValid(record.mugger) then
		DRP.Net.Notify(record.mugger, record.victim:Nick() .. " paid the " .. moneyText(record.amount) .. " demand.", 1)
		sendNotice(record.mugger, 2, false, record.victim, record.amount, 0, "Demand paid")
	end
	if IsValid(record.victim) then
		DRP.Net.Notify(record.victim, "You paid " .. record.mugger:Nick() .. " the demanded " .. moneyText(record.amount) .. ".", 1)
		sendNotice(record.victim, 2, true, record.mugger, record.amount, 0, "Demand paid")
	end
	if DRP.Audit then DRP.Audit.Log(record.mugger, "mugging_paid", record.victim, record.amount) end
	clearRecord(record)
end

local function involved(ply)
	return Mugging.ByMugger[ply] or Mugging.ByVictim[ply]
end

local function aimedPlayer(ply)
	local trace = util.TraceLine({
		start = ply:EyePos(),
		endpos = ply:EyePos() + ply:EyeAngles():Forward() * Mugging.MaxDistance,
		filter = ply,
		mask = MASK_SHOT
	})
	return IsValid(trace.Entity) and trace.Entity:IsPlayer() and trace.Entity or nil
end

local function isStandingStill(ply)
	return IsValid(ply) and ply:GetAbsVelocity():Length2DSqr() <= (Mugging.StandingStillSpeed * Mugging.StandingStillSpeed)
end

function Mugging.Begin(mugger, victim, amount)
	if not IsValid(mugger) or not mugger:IsPlayer() or not mugger:DRPReady() or not mugger:Alive() then return false end
	if not mugger:DRPHasRoleCapability("canMug") then
		DRP.Net.Notify(mugger, "Government roles cannot initiate muggings.", 3)
		return false
	end
	if not IsValid(victim) or victim == mugger or not victim:DRPReady() or not victim:Alive() then
		DRP.Net.Notify(mugger, "Aim directly at a living player within " .. Mugging.MaxDistance .. " units.", 3)
		return false
	end
	if mugger:InVehicle() or victim:InVehicle() then
		DRP.Net.Notify(mugger, "Muggings cannot begin while either player is in a vehicle.", 3)
		return false
	end
	if not isStandingStill(victim) then
		DRP.Net.Notify(mugger, "That player must be standing still to be mugged.", 3)
		return false
	end
	if involved(mugger) or involved(victim) then
		DRP.Net.Notify(mugger, "One of you is already involved in a mugging.", 3)
		return false
	end
	if (mugger.DRPMugCooldownUntil or 0) > CurTime() then
		DRP.Net.Notify(mugger, "Wait " .. math.ceil(mugger.DRPMugCooldownUntil - CurTime()) .. " seconds before mugging again.", 3)
		return false
	end
	amount = math.Clamp(math.floor(tonumber(amount) or 0), 1, Mugging.MaxAmount)
	if victim:DRPMoney() < amount then
		DRP.Net.Notify(mugger, "That player cannot afford a " .. moneyText(amount) .. " demand.", 3)
		return false
	end

	local id = Mugging.NextID
	Mugging.NextID = Mugging.NextID + 1
	local deadline = CurTime() + Mugging.DemandTime
	local incident = DRP.Incidents.Create("mugging", {
		reason = mugger:Nick() .. " demanded " .. moneyText(amount) .. " from " .. victim:Nick(),
		instigator = mugger,
		victim = victim,
		participants = { suspect = mugger, victim = victim },
		deadline = deadline,
		cooldowns = { mugger = CurTime() + Mugging.Cooldown },
		metadata = { amount = amount }
	})
	if not incident then
		DRP.Net.Notify(mugger, "The incident service could not start this mugging.", 3)
		return false
	end
	local record = {
		id = id,
		mugger = mugger,
		victim = victim,
		amount = amount,
		paid = 0,
		startedAt = CurTime(),
		expires = deadline,
		startPosition = victim:GetPos(),
		incidentID = incident.id
	}
	Mugging.Active[id] = record
	Mugging.ByMugger[mugger] = record
	Mugging.ByVictim[victim] = record
	mugger.DRPMugCooldownUntil = CurTime() + Mugging.Cooldown

	-- Initially only the victim may harm the mugger. The incident itself owns
	-- this permission and deterministically unlocks mutual combat on resistance.
	DRP.Incidents.Grant(incident, "damage", victim, mugger, "Victim may resist the mugging", deadline + 2)
	DRP.Incidents.Grant(incident, "take_money", mugger, victim, "Mugging demand", deadline)
	DRP.Incidents.AddEvidence(incident, "demand_issued", mugger, victim, "Initiated at close range for " .. moneyText(amount))
	DRP.Net.Notify(mugger, "Mugging " .. victim:Nick() .. " for " .. moneyText(amount) .. ". They have 10 seconds.", 1)
	DRP.Net.Notify(victim, mugger:Nick() .. " is mugging you for " .. moneyText(amount) .. ". Use the demand panel to drop the cash within 10 seconds.", 2)
	sendNotice(mugger, 1, false, victim, amount, Mugging.DemandTime, "Awaiting payment")
	sendNotice(victim, 1, true, mugger, amount, Mugging.DemandTime, "Moving, switching weapons or attacking escalates PvP")
	if DRP.Hints and DRP.Hints.Send then
		DRP.Hints:Send(victim, "mugging_payment", "A mugging demand is active",
			"Use the demand panel to drop the exact remaining cash. You may decide later and reopen it from the HUD; press Z or F3 to enable the free cursor.", 2, 7, true)
	end
	if DRP.Audit then DRP.Audit.Log(mugger, "mugging_started", victim, amount) end
	return true
end

function Mugging:Scan()
	local now = CurTime()
	for _, record in pairs(self.Active) do
		local mugger, victim = record.mugger, record.victim
		if not IsValid(mugger) or not IsValid(victim) or not mugger:Alive() or not victim:Alive() then
			cancel(record, "A participant became unavailable")
		elseif not mugger:DRPReady() or not victim:DRPReady() or not mugger:DRPHasRoleCapability("canMug") then
			cancel(record, "Mugging conditions are no longer valid")
		elseif not record.combat and now >= record.expires then
			escalate(record, "cash was not dropped within 10 seconds")
		elseif not record.combat and victim:GetPos():DistToSqr(record.startPosition) > self.MoveTolerance * self.MoveTolerance then
			escalate(record, "victim moved")
		end
	end
end

hook.Add("PlayerDeath", "DRP.Mugging.ResolveDeath", function(victim, _, attacker)
	local record = Mugging.ByVictim[victim] or Mugging.ByMugger[victim]
	if not record or not record.combat then return end
	local incident = DRP.Incidents.Get(record.incidentID)
	if incident then
		local resolution, detail
		if victim == record.victim then
			resolution = "victim_killed"
			detail = record.mugger:DRPName() .. " killed the mugging victim"
		else
			resolution = "mugger_killed"
			detail = record.victim:DRPName() .. " killed the mugger"
		end
		DRP.Incidents.AddEvidence(incident, "combat_death", attacker, victim, detail)
		DRP.Incidents.Resolve(incident, resolution, detail)
	end
	clearRecord(record)
end)

function Mugging:Start()
end

DRP.Incidents.Definitions.mugging.onDeadline = function(incident)
	if incident.state == "combat_active" then
		for _, record in pairs(Mugging.Active) do
			if record.incidentID == incident.id then clearRecord(record) break end
		end
		return false
	end
	if incident.state ~= "demand_pending" then return false end
	for _, record in pairs(Mugging.Active) do
		if record.incidentID == incident.id then
			escalate(record, "cash was not dropped within 10 seconds")
			return true
		end
	end
	return false
end

function Mugging:Stop()
	local active = {}
	for _, record in pairs(self.Active) do active[#active + 1] = record end
	for _, record in ipairs(active) do cancel(record, "Server shutting down") end
end

function Mugging.ApplyVictimMove(ply)
	local record = Mugging.ByVictim[ply]
	if record and not record.combat and ply:GetPos():DistToSqr(record.startPosition) > Mugging.MoveTolerance * Mugging.MoveTolerance then
		escalate(record, "victim moved")
	end
end

local function dropPosition(ply)
	local startPosition = ply:EyePos()
	local trace = util.TraceLine({
		start = startPosition,
		endpos = startPosition + ply:EyeAngles():Forward() * 72,
		filter = ply,
		mask = MASK_SOLID
	})
	if trace.Hit then return trace.HitPos + trace.HitNormal * 8 end
	return ply:GetPos() + ply:GetForward() * 42 + Vector(0, 0, 24)
end

local function createCashEntity(amount, position, angles)
	local entity = ents.Create("prop_physics")
	if not IsValid(entity) then return nil end
	entity:SetModel("models/props_c17/BriefCase001a.mdl")
	entity:SetPos(position)
	entity:SetAngles(angles or angle_zero)
	entity:SetColor(Color(105, 205, 125))
	entity:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	entity:Spawn()
	entity:Activate()
	entity.DRPMoneyDrop = true
	entity:SetNW2Bool("DRPMoneyDrop", true)
	entity:SetNW2Int("DRPMoneyAmount", amount)
	local physics = entity:GetPhysicsObject()
	if IsValid(physics) then physics:EnableMotion(false) physics:Sleep() end
	return entity
end

function DRP.Money.Drop(ply, amount)
	amount = math.floor(tonumber(amount) or 0)
	if not IsValid(ply) or not ply:DRPReady() or not ply:Alive() then return false end
	if amount < 1 or amount > 100000 then
		DRP.Net.Notify(ply, "Cash drop must be between $1 and $100,000.", 3)
		return false
	end
	if ply:DRPMoney() < amount then
		DRP.Net.Notify(ply, "You cannot afford to drop " .. moneyText(amount) .. ".", 3)
		return false
	end

	local entity = createCashEntity(amount, dropPosition(ply), Angle(0, ply:EyeAngles().y, 0))
	if not IsValid(entity) then
		DRP.Net.Notify(ply, "The cash could not be created.", 3)
		return false
	end

	if not DRP.Economy.Take(ply, amount, "cash dropped", { kind = "custody", source = "cash dropped" }) then
		entity:Remove()
		DRP.Net.Notify(ply, "Your wallet changed before the cash could be dropped.", 3)
		return false
	end

	local record = Mugging.ByVictim[ply]
	local reservedFor
	if record then
		reservedFor = record.mugger
		record.paid = record.paid + amount
	end
	Mugging.MoneyDrops[entity] = {
		amount = amount,
		dropper = ply,
		reservedFor = reservedFor,
		pickupAt = CurTime() + 0.6
	}

	net.Start(moneyMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteEntity(entity)
	net.WriteUInt(amount, 32)
	net.Broadcast()
	if DRP.Audit then DRP.Audit.Log(ply, "money_dropped", reservedFor, amount) end
	DRP.Deadlines.Schedule("moneydrop:" .. entity:EntIndex(), CurTime() + 180, function()
		if IsValid(entity) and Mugging.MoneyDrops[entity] then
			Mugging.MoneyDrops[entity] = nil
			entity:Remove()
		end
	end)

	if record and Mugging.Active[record.id] and record.paid >= record.amount then paid(record) end
	return true
end

function Mugging:PayDemand(victim)
	local record = self.ByVictim[victim]
	if not record or not self.Active[record.id] or record.combat then
		DRP.Net.Notify(victim, "There is no pending mugging demand to pay.", 3)
		return false
	end
	if CurTime() >= record.expires then
		escalate(record, "cash was not dropped within 10 seconds")
		return false
	end
	local remaining = math.max(0, record.amount - (record.paid or 0))
	if remaining <= 0 then
		paid(record)
		return true
	end
	return DRP.Money.Drop(victim, remaining)
end

function DRP.Money.SpawnSystemDrop(amount, position, allowedIDs, options)
	amount = math.Clamp(math.floor(tonumber(amount) or 0), 0, 4294967295)
	options = istable(options) and options or {}
	if amount <= 0 or not isvector(position) or not util.IsInWorld(position) then return nil end
	local entity = createCashEntity(amount, position, Angle(0, math.random(0, 359), 0))
	if not IsValid(entity) then return nil end
	local allowed = {}
	for steamID64, enabled in pairs(allowedIDs or {}) do
		steamID64 = tostring(steamID64 or "")
		if enabled == true and steamID64 ~= "" then allowed[steamID64] = true end
	end
	local expires = math.Clamp(math.floor(tonumber(options.expires) or 180), 10, 1800)
	entity.DRPSystemMoneyDrop = true
	Mugging.MoneyDrops[entity] = {
		amount = amount,
		allowedIDs = allowed,
		system = true,
		source = string.sub(tostring(options.source or "system cash"), 1, 96),
		onRefund = isfunction(options.onRefund) and options.onRefund or nil,
		pickupAt = CurTime() + 0.6
	}
	net.Start(moneyMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteEntity(entity)
		net.WriteUInt(amount, 32)
	net.Broadcast()
	DRP.Deadlines.Schedule("moneydrop:" .. entity:EntIndex(), CurTime() + expires, function()
		if IsValid(entity) and Mugging.MoneyDrops[entity] then
			DRP.Money.RefundSystemDrop(entity, "unclaimed system cash expired")
		end
	end)
	if DRP.Audit then DRP.Audit.Log(nil, "system_money_spawned", entity, amount .. " " .. Mugging.MoneyDrops[entity].source) end
	return entity
end

function DRP.Money.RefundSystemDrop(entity, reason)
	local drop = Mugging.MoneyDrops[entity]
	if not drop or drop.system ~= true then return false end
	Mugging.MoneyDrops[entity] = nil
	if IsValid(entity) then DRP.Deadlines.Cancel("moneydrop:" .. entity:EntIndex()) end
	if drop.onRefund then drop.onRefund(entity, drop.amount, tostring(reason or "system cash refunded")) end
	if IsValid(entity) then entity:Remove() end
	return true
end

DRP.Net.Receive(requestMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local amount = net.ReadUInt(13)
	if not DRP.Net.Allow(ply, "mug_request", 1, 2) then return end
	Mugging.Begin(ply, aimedPlayer(ply), amount)
end)

DRP.Net.Receive(actionMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local action = net.ReadUInt(2)
	if not DRP.Net.Allow(ply, "mug_action", 2, 2) then return end
	if action == 1 then Mugging:PayDemand(ply) end
end)

hook.Add("PlayerUse", "DRP.Money.Pickup", function(ply, entity)
	local drop = Mugging.MoneyDrops[entity]
	if not drop then return end
	if not ply:DRPReady() or not ply:Alive() or CurTime() < drop.pickupAt then return false end
	if IsValid(drop.reservedFor) and ply ~= drop.reservedFor then
		DRP.Net.Notify(ply, "That cash is reserved for " .. drop.reservedFor:Nick() .. ".", 3)
		return false
	end
	if drop.allowedIDs and not drop.allowedIDs[ply:SteamID64()] then
		DRP.Net.Notify(ply, "That cash is reserved for another raid participant.", 3)
		return false
	end
	Mugging.MoneyDrops[entity] = nil
	DRP.Deadlines.Cancel("moneydrop:" .. entity:EntIndex())
	DRP.Economy.Add(ply, drop.amount, "cash picked up", { kind = "custody", source = drop.source or "cash pickup" })
	if DRP.Audit then DRP.Audit.Log(ply, drop.system and "system_money_picked_up" or "money_picked_up", drop.dropper, drop.amount .. (drop.source and (" " .. drop.source) or "")) end
	entity:Remove()
	return false
end)

hook.Add("EntityRemoved", "DRP.Money.RefundRemovedSystemDrop", function(entity)
	local drop = Mugging.MoneyDrops[entity]
	if not drop then return end
	Mugging.MoneyDrops[entity] = nil
	if drop.system and drop.onRefund then drop.onRefund(entity, drop.amount, "system cash entity was removed") end
end)

hook.Add("PlayerSwitchWeapon", "DRP.Mugging.WeaponChanged", function(ply, oldWeapon, newWeapon)
	if oldWeapon == newWeapon then return end
	local record = Mugging.ByVictim[ply]
	if record then timer.Simple(0, function() escalate(record, "victim changed weapons") end) end
end)

hook.Add("KeyPress", "DRP.Mugging.Attack", function(ply, key)
	if key ~= IN_ATTACK and key ~= IN_ATTACK2 then return end
	local record = Mugging.ByVictim[ply]
	if record then escalate(record, "victim attacked") end
end)

-- KeyPress covers normal attacks; this also catches automatic weapons whose
-- attack key was already held when the mugging began.
hook.Add("EntityFireBullets", "DRP.Mugging.Fired", function(entity)
	local ply = IsValid(entity) and entity:IsPlayer() and entity or (IsValid(entity) and entity:GetOwner() or nil)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	local record = Mugging.ByVictim[ply]
	if record then escalate(record, "victim fired a weapon") end
end)

hook.Add("PlayerDeath", "DRP.Mugging.Death", function(ply)
	local record = involved(ply)
	-- Combat deaths are resolved by DRP.Mugging.ResolveDeath so the original
	-- incident keeps its winner/loser outcome and XP receipt.
	if record and not record.combat then cancel(record, "A participant died") end
end)

hook.Add("PlayerDisconnected", "DRP.Mugging.Disconnect", function(ply)
	local record = involved(ply)
	if record then cancel(record, "A participant disconnected") end
end)

hook.Add("DRPJobChanged", "DRP.Mugging.JobChanged", function(ply)
	local record = involved(ply)
	if record then cancel(record, "A participant changed jobs") end
end)
