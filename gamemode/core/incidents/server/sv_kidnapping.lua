local stateMessage = "drp_kidnap_state_v1"
local interactionMessage = "drp_kidnap_interaction_v1"

util.AddNetworkString(stateMessage)
util.AddNetworkString(interactionMessage)

local Kidnapping = {
	Active = {},
	ByKidnapper = setmetatable({}, { __mode = "k" }),
	ByVictim = setmetatable({}, { __mode = "k" }),
	EffectAttempts = setmetatable({}, { __mode = "k" }),
	RescueAttempts = setmetatable({}, { __mode = "k" }),
	Duration = 600,
	Cooldown = 900,
	VictimImmunity = 600,
	KnockoutDuration = 5,
	EffectApplyTime = 2,
	RescueTime = 5,
	InteractionDistance = 110,
	BatonDistance = 105,
	OverdueDamage = 2,
	OverdueInterval = 5
}

DRP.Kidnapping = Kidnapping
DRP.Services.Register("kidnapping", Kidnapping)

local EFFECT_BITS = { knockout = 1, blindfold = 2, gag = 4 }
local function notify(ply, text, kind)
	if IsValid(ply) and DRP.Net then DRP.Net.Notify(ply, text, kind or 0) end
end

local function activeAdmin(ply)
	return IsValid(ply) and DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(ply)
end

local function activeIncident(record)
	return record and record.active and DRP.Incidents.Get(record.incidentID)
end

local function effectMask(record)
	local mask = 0
	if not record then return mask end
	for effect, value in pairs(record.effects or {}) do
		if value and EFFECT_BITS[effect] then mask = bit.bor(mask, EFFECT_BITS[effect]) end
	end
	return mask
end

local function sendState(ply, record)
	if not IsValid(ply) then return end
	local incident = activeIncident(record)
	net.Start(stateMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(incident ~= nil)
	if incident then
		net.WriteUInt(incident.id, 32)
		net.WriteBool(ply == record.victim)
		net.WriteEntity(ply == record.victim and record.kidnapper or record.victim)
		net.WriteUInt(effectMask(record), 3)
		net.WriteBool(record.overdue == true)
		net.WriteUInt(math.Clamp(math.ceil(math.max(0, record.deadline - CurTime())), 0, 65535), 16)
	end
	net.Send(ply)
end

local function syncRecord(record)
	if not record then return end
	sendState(record.kidnapper, record)
	sendState(record.victim, record)
end

local function sendInteraction(ply, active, label, duration)
	if not IsValid(ply) then return end
	net.Start(interactionMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(active == true)
	if active then
		net.WriteString(string.sub(tostring(label or "Working"), 1, 80))
		net.WriteFloat(math.max(0.1, tonumber(duration) or 1))
	end
	net.Send(ply)
end

local function setPersistentTime(ply, key, unix)
	if not IsValid(ply) then return end
	unix = math.max(0, math.floor(tonumber(unix) or 0))
	ply[key] = unix
	ply.DRPRoleBehavior = ply.DRPRoleBehavior or {}
	if key == "DRPKidnapCooldownUnix" then
		ply.DRPRoleBehavior.kidnapCooldownUntil = unix
	else
		ply.DRPRoleBehavior.kidnapImmunityUntil = unix
	end
	if DRP.Economy then DRP.Economy.QueueSave(ply) end
end

local function clearInteraction(actor)
	if not IsValid(actor) then return end
	Kidnapping.EffectAttempts[actor] = nil
	Kidnapping.RescueAttempts[actor] = nil
	sendInteraction(actor, false)
end

local function clearRecord(record)
	if not record then return end
	record.active = false
	Kidnapping.Active[record.incidentID] = nil
	if Kidnapping.ByKidnapper[record.kidnapper] == record then Kidnapping.ByKidnapper[record.kidnapper] = nil end
	if Kidnapping.ByVictim[record.victim] == record then Kidnapping.ByVictim[record.victim] = nil end
	DRP.Deadlines.Cancel("kidnapping:" .. record.incidentID .. ":knockout")
	for actor, attempt in pairs(Kidnapping.EffectAttempts) do
		if attempt.record == record then clearInteraction(actor) end
	end
	for actor, attempt in pairs(Kidnapping.RescueAttempts) do
		if attempt.record == record then clearInteraction(actor) end
	end
	record.effects = {}
	sendState(record.kidnapper)
	sendState(record.victim)
end

DRP.Incidents.RegisterType("kidnapping", {
	initial = "captive",
	transitions = { captive = { overdue = true } },
	outcomes = {
		victim_rescued = { winner = "victim", loser = "instigator" },
		victim_released = { winner = "victim", loser = "instigator" },
		victim_killed = { winner = "instigator", loser = "victim" },
		kidnapper_killed = { winner = "victim", loser = "instigator" },
		cancelled = {},
		server_shutdown = {},
		default = { winner = "victim", loser = "instigator" }
	},
	onDeadline = function(incident)
		return Kidnapping:Escalate(incident)
	end,
	onParticipantUnavailable = function(incident, ply, resolution)
		if resolution == "participant_died" then
			return Kidnapping.Resolve(incident, ply == incident.victim and "victim_killed" or "kidnapper_killed",
				ply == incident.victim and "Kidnapping victim died" or "Kidnapper died")
		end
		if ply == incident.instigator then
			return Kidnapping.Resolve(incident, "victim_released", "Kidnapper became unavailable; victim released")
		end
		return Kidnapping.Resolve(incident, "cancelled", "Kidnapping cancelled because a participant became unavailable")
	end
})

function Kidnapping:IsKnockedOut(ply)
	local record = self.ByVictim[ply]
	return record ~= nil and record.effects.knockout == true and (record.knockoutUntil or 0) > CurTime()
end

function Kidnapping:IsGagged(ply)
	local record = self.ByVictim[ply]
	return record ~= nil and record.effects.gag == true
end

function Kidnapping:IsBlindfolded(ply)
	local record = self.ByVictim[ply]
	return record ~= nil and record.effects.blindfold == true
end

function Kidnapping:CanStart(kidnapper, victim, explain)
	local function reject(reason)
		if explain then notify(kidnapper, reason, 3) end
		return false, reason
	end
	if not IsValid(kidnapper) or not kidnapper:IsPlayer() or not kidnapper:Alive() or not kidnapper:DRPReady() then return false end
	if not kidnapper:DRPHasRoleCapability("canKidnap") then return reject("Your current role does not permit kidnapping.") end
	if not IsValid(victim) or not victim:IsPlayer() or victim == kidnapper or not victim:Alive() or not victim:DRPReady() then return reject("Strike a living player at close range.") end
	if activeAdmin(kidnapper) or activeAdmin(victim) then return reject("Admin Mode participants cannot enter kidnapping incidents.") end
	if self.ByKidnapper[kidnapper] or self.ByVictim[kidnapper] or self.ByKidnapper[victim] or self.ByVictim[victim] then return reject("One of you is already involved in a kidnapping.") end
	if DRP.Legal and (DRP.Legal.Arrested[victim] or DRP.Legal.Cuffed[victim] or (DRP.Legal.IsTased and DRP.Legal.IsTased(victim))) then return reject("A player in police custody cannot be kidnapped.") end
	local now = os.time()
	if (kidnapper.DRPKidnapCooldownUnix or 0) > now then return reject("Your kidnapping baton is on cooldown for " .. (kidnapper.DRPKidnapCooldownUnix - now) .. " seconds.") end
	if (victim.DRPKidnapImmunityUnix or 0) > now then return reject(victim:DRPName() .. " has kidnapping immunity for " .. (victim.DRPKidnapImmunityUnix - now) .. " seconds.") end
	return true
end

function Kidnapping.Start(kidnapper, victim)
	-- DRP.Services invokes lifecycle methods with colon syntax. The same public
	-- Start function owns incident creation, so accept that no-op lifecycle call
	-- without replacing the API implementation.
	if kidnapper == Kidnapping and victim == nil then return true end
	local allowed = Kidnapping:CanStart(kidnapper, victim, true)
	if not allowed then return false end
	local deadline = CurTime() + Kidnapping.Duration
	local incident = DRP.Incidents.Create("kidnapping", {
		reason = kidnapper:DRPName() .. " knocked out and kidnapped " .. victim:DRPName(),
		instigator = kidnapper,
		victim = victim,
		participants = { suspect = kidnapper, victim = victim },
		deadline = deadline,
		teamShare = false,
		cooldowns = { kidnapper = CurTime() + Kidnapping.Cooldown },
		metadata = { effects = "knockout" }
	})
	if not incident then return false end
	local record = {
		active = true,
		incidentID = incident.id,
		kidnapper = kidnapper,
		victim = victim,
		deadline = deadline,
		startedAt = CurTime(),
		effects = { knockout = true },
		knockoutUntil = CurTime() + Kidnapping.KnockoutDuration
	}
	Kidnapping.Active[incident.id] = record
	Kidnapping.ByKidnapper[kidnapper] = record
	Kidnapping.ByVictim[victim] = record
	setPersistentTime(kidnapper, "DRPKidnapCooldownUnix", os.time() + Kidnapping.Cooldown)
	DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, victim, kidnapper,
		"Victim may retaliate throughout the kidnapping", nil)
	DRP.Incidents.AddEvidence(incident, "victim_knocked_out", kidnapper, victim, "Five-second non-lethal knockout")
	DRP.Deadlines.Schedule("kidnapping:" .. incident.id .. ":knockout", record.knockoutUntil, function()
		if activeIncident(record) and record.effects.knockout then
			record.effects.knockout = nil
			record.knockoutUntil = nil
			DRP.Incidents.AddEvidence(incident, "victim_awoke", victim, kidnapper, "Knockout ended")
			syncRecord(record)
		end
	end)
	victim:ScreenFade(SCREENFADE.IN, Color(0, 0, 0, 245), 0.2, Kidnapping.KnockoutDuration - 0.2)
	victim:EmitSound("physics/body/body_medium_impact_hard1.wav", 75, 85, 0.8)
	notify(kidnapper, "Kidnapping started. The victim may retaliate; your damage unlocks after 10 minutes.", 1)
	notify(victim, kidnapper:DRPName() .. " kidnapped you. You may retaliate immediately.", 2)
	syncRecord(record)
	if DRP.Audit then DRP.Audit.Log(kidnapper, "kidnapping_started", victim, "incident #" .. incident.id) end
	return true, incident
end

function Kidnapping:BatonAimed(kidnapper)
	if not IsValid(kidnapper) then return false end
	local trace = util.TraceHull({
		start = kidnapper:EyePos(),
		endpos = kidnapper:EyePos() + kidnapper:GetAimVector() * self.BatonDistance,
		mins = Vector(-8, -8, -8), maxs = Vector(8, 8, 8), filter = kidnapper, mask = MASK_SHOT
	})
	return self.Start(kidnapper, IsValid(trace.Entity) and trace.Entity:IsPlayer() and trace.Entity or nil)
end

local function validCloseInteraction(actor, victim, distance)
	if not IsValid(actor) or not actor:Alive() or not actor:DRPReady() or not IsValid(victim) or not victim:Alive() then return false end
	if actor:GetPos():DistToSqr(victim:GetPos()) > distance * distance then return false end
	local trace = util.TraceLine({ start = actor:EyePos(), endpos = victim:WorldSpaceCenter(), filter = actor, mask = MASK_SHOT })
	return trace.Entity == victim
end

function Kidnapping.BeginEffect(kidnapper, effect, remove)
	effect = tostring(effect or "")
	if not EFFECT_BITS[effect] or not IsValid(kidnapper) then return false end
	local record = Kidnapping.ByKidnapper[kidnapper]
	local incident = activeIncident(record)
	if not incident then notify(kidnapper, "You do not have an active kidnapping.", 3) return false end
	local victim = record.victim
	if not validCloseInteraction(kidnapper, victim, Kidnapping.InteractionDistance) then notify(kidnapper, "Stay close and aim directly at your victim.", 3) return false end
	if (record.effects[effect] == true) == (remove ~= true) then
		notify(kidnapper, effect == "gag" and "That gag state is already set." or "That blindfold state is already set.", 3)
		return false
	end
	local existing = Kidnapping.EffectAttempts[kidnapper]
	if existing and existing.record == record and existing.effect == effect and existing.remove == (remove == true) then return true end
	Kidnapping.EffectAttempts[kidnapper] = {
		record = record, effect = effect, remove = remove == true,
		ends = CurTime() + Kidnapping.EffectApplyTime,
		weapon = "weapon_drp_" .. (effect == "gag" and "gag" or "blindfold"),
		key = remove and IN_ATTACK2 or IN_ATTACK
	}
	sendInteraction(kidnapper, true, (remove and "Removing " or "Applying ") .. effect, Kidnapping.EffectApplyTime)
	Kidnapping:EnsureInteractionTimer()
	return true
end

function Kidnapping.ApplyEffect(kidnapper, victim, effect)
	local record = Kidnapping.ByKidnapper[kidnapper]
	if not record or record.victim ~= victim or not activeIncident(record) or not EFFECT_BITS[effect] then return false end
	record.effects[effect] = true
	DRP.Incidents.AddEvidence(DRP.Incidents.Get(record.incidentID), effect .. "_applied", kidnapper, victim, effect .. " applied")
	syncRecord(record)
	return true
end

function Kidnapping.RemoveEffect(actor, victim, effect)
	local record = Kidnapping.ByVictim[victim]
	if not record or not activeIncident(record) or not EFFECT_BITS[effect] then return false end
	record.effects[effect] = nil
	DRP.Incidents.AddEvidence(DRP.Incidents.Get(record.incidentID), effect .. "_removed", actor, victim, effect .. " removed")
	syncRecord(record)
	return true
end

function Kidnapping:Escalate(incident)
	local record = incident and self.Active[incident.id]
	if not record or not activeIncident(record) then return false end
	if record.overdue then return true end
	if not DRP.Incidents.Transition(incident, "overdue", "Kidnapping deadline exceeded — mutual PvP authorized") then return false end
	record.overdue = true
	DRP.Incidents.HoldOpen(incident, "Kidnapping overdue; active inflictions now endanger the victim")
	DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, record.kidnapper, record.victim,
		"Kidnapping deadline exceeded", nil)
	DRP.Incidents.AddEvidence(incident, "deadline_exceeded", record.kidnapper, record.victim,
		"Mutual PvP and infliction damage activated")
	notify(record.kidnapper, "Kidnapping deadline exceeded. PvP is now mutual.", 2)
	notify(record.victim, "Kidnapping deadline exceeded. PvP is now mutual; active inflictions are harming you.", 2)
	syncRecord(record)
	self:EnsureOverdueTimer()
	return true
end

function Kidnapping:EnsureOverdueTimer()
	if timer.Exists("DRP.Kidnapping.Overdue") then return end
	timer.Create("DRP.Kidnapping.Overdue", self.OverdueInterval, 0, function()
		local hasOverdue = false
		for _, record in pairs(Kidnapping.Active) do
			if record.overdue and activeIncident(record) then
				hasOverdue = true
				if effectMask(record) ~= 0 and IsValid(record.victim) and record.victim:Alive() then
					local damage = DamageInfo()
					damage:SetDamage(Kidnapping.OverdueDamage)
					damage:SetDamageType(DMG_POISON)
					damage:SetAttacker(game.GetWorld())
					damage:SetInflictor(game.GetWorld())
					record.victim:TakeDamageInfo(damage)
				end
			end
		end
		if not hasOverdue then timer.Remove("DRP.Kidnapping.Overdue") end
	end)
end

function Kidnapping:PrepareShutdown()
	for _, record in pairs(self.Active) do
		if activeIncident(record) and IsValid(record.victim) then
			setPersistentTime(record.victim, "DRPKidnapImmunityUnix", os.time() + self.VictimImmunity)
		end
	end
end

function Kidnapping.Release(kidnapper, victim)
	local record = Kidnapping.ByKidnapper[kidnapper]
	if not record or (IsValid(victim) and record.victim ~= victim) then return false end
	return Kidnapping.Resolve(DRP.Incidents.Get(record.incidentID), "victim_released", "Victim released by the kidnapper")
end

function Kidnapping.Rescue(rescuer, victim)
	local record = Kidnapping.ByVictim[victim]
	if not record or rescuer == victim or rescuer == record.kidnapper then return false end
	local incident = activeIncident(record)
	if not incident then return false end
	DRP.Incidents.AddEvidence(incident, "victim_rescued", rescuer, victim, "All kidnapping effects removed")
	return Kidnapping.Resolve(incident, "victim_rescued", "Victim rescued by " .. rescuer:DRPName())
end

function Kidnapping.Resolve(incident, outcome, evidence)
	if isnumber(incident) then incident = DRP.Incidents.Get(incident) end
	if not incident or incident.type ~= "kidnapping" then return false end
	local record = Kidnapping.Active[incident.id]
	if not record then return false end
	outcome = tostring(outcome or "cancelled")
	if outcome ~= "cancelled" and IsValid(record.victim) then
		setPersistentTime(record.victim, "DRPKidnapImmunityUnix", os.time() + Kidnapping.VictimImmunity)
	end
	clearRecord(record)
	local resolved, receipt = DRP.Incidents.Resolve(incident, outcome, evidence or outcome)
	if resolved and DRP.Audit then DRP.Audit.Log(record.kidnapper, "kidnapping_" .. outcome, record.victim, "incident #" .. incident.id) end
	return resolved, receipt
end

function Kidnapping:EnsureInteractionTimer()
	if timer.Exists("DRP.Kidnapping.Interactions") then return end
	timer.Create("DRP.Kidnapping.Interactions", 0.05, 0, function()
		local any = false
		for actor, attempt in pairs(Kidnapping.EffectAttempts) do
			any = true
			local record, weapon = attempt.record, IsValid(actor) and actor:GetActiveWeapon()
			if not activeIncident(record) or not IsValid(weapon) or weapon:GetClass() ~= attempt.weapon
				or not actor:KeyDown(attempt.key) or not validCloseInteraction(actor, record.victim, Kidnapping.InteractionDistance) then
				clearInteraction(actor)
			elseif CurTime() >= attempt.ends then
				if attempt.remove then Kidnapping.RemoveEffect(actor, record.victim, attempt.effect)
				else Kidnapping.ApplyEffect(actor, record.victim, attempt.effect) end
				clearInteraction(actor)
			end
		end
		for rescuer, attempt in pairs(Kidnapping.RescueAttempts) do
			any = true
			local record = attempt.record
			if not activeIncident(record) or not IsValid(rescuer) or not rescuer:KeyDown(IN_USE)
				or not validCloseInteraction(rescuer, record.victim, Kidnapping.InteractionDistance) then
				clearInteraction(rescuer)
			elseif CurTime() >= attempt.ends then
				local victim = record.victim
				clearInteraction(rescuer)
				Kidnapping.Rescue(rescuer, victim)
			end
		end
		if not any or (next(Kidnapping.EffectAttempts) == nil and next(Kidnapping.RescueAttempts) == nil) then
			timer.Remove("DRP.Kidnapping.Interactions")
		end
	end)
end

function Kidnapping.ApplyCommand(ply, command)
	if not Kidnapping:IsKnockedOut(ply) then return end
	command:ClearMovement()
	command:RemoveKey(IN_ATTACK)
	command:RemoveKey(IN_ATTACK2)
	command:RemoveKey(IN_RELOAD)
	command:RemoveKey(IN_USE)
	command:RemoveKey(IN_JUMP)
	command:RemoveKey(IN_SPEED)
end

function Kidnapping.ApplyMove(ply, move)
	if not Kidnapping:IsKnockedOut(ply) then return end
	move:SetForwardSpeed(0)
	move:SetSideSpeed(0)
	move:SetUpSpeed(0)
	move:SetMaxSpeed(0)
	move:SetMaxClientSpeed(0)
	move:SetVelocity(vector_origin)
end

hook.Add("KeyPress", "DRP.Kidnapping.RescueStart", function(rescuer, key)
	if key ~= IN_USE or Kidnapping.RescueAttempts[rescuer] or Kidnapping.EffectAttempts[rescuer] then return end
	local victim = rescuer:GetEyeTrace().Entity
	local record = IsValid(victim) and victim:IsPlayer() and Kidnapping.ByVictim[victim] or nil
	if not record or rescuer == victim or rescuer == record.kidnapper or activeAdmin(rescuer) then return end
	if not validCloseInteraction(rescuer, victim, Kidnapping.InteractionDistance) then return end
	Kidnapping.RescueAttempts[rescuer] = { record = record, ends = CurTime() + Kidnapping.RescueTime }
	sendInteraction(rescuer, true, "Rescuing " .. victim:DRPName(), Kidnapping.RescueTime)
	notify(rescuer, "Keep holding E and looking at the victim to rescue them.", 0)
	Kidnapping:EnsureInteractionTimer()
end)

hook.Add("KeyRelease", "DRP.Kidnapping.InteractionStop", function(ply, key)
	if key == IN_USE and Kidnapping.RescueAttempts[ply] then clearInteraction(ply) end
end)

hook.Add("PlayerSwitchWeapon", "DRP.Kidnapping.KnockoutSwitch", function(ply)
	if Kidnapping:IsKnockedOut(ply) then return true end
end)

hook.Add("DRPPoliceCustodyStarted", "DRP.Kidnapping.PoliceCustody", function(_, suspect)
	local record = Kidnapping.ByVictim[suspect]
	if record then Kidnapping.Resolve(record.incidentID, "victim_rescued", "Police custody ended the kidnapping") end
end)

hook.Add("DRPAdminModeChanged", "DRP.Kidnapping.AdminMode", function(ply, active)
	if not active then return end
	local record = Kidnapping.ByVictim[ply] or Kidnapping.ByKidnapper[ply]
	if record then Kidnapping.Resolve(record.incidentID, "cancelled", "Admin Mode cancelled the kidnapping") end
end)

hook.Add("DRPPlayerReady", "DRP.Kidnapping.LoadCooldowns", function(ply)
	local behavior = ply.DRPRoleBehavior or {}
	ply.DRPKidnapCooldownUnix = math.max(0, math.floor(tonumber(behavior.kidnapCooldownUntil) or 0))
	ply.DRPKidnapImmunityUnix = math.max(0, math.floor(tonumber(behavior.kidnapImmunityUntil) or 0))
end)

hook.Add("DRPIncidentResolved", "DRP.Kidnapping.ExternalCleanup", function(incident)
	if incident.type ~= "kidnapping" then return end
	local record = Kidnapping.Active[incident.id]
	if record then clearRecord(record) end
end)

function Kidnapping:Stop()
	timer.Remove("DRP.Kidnapping.Overdue")
	timer.Remove("DRP.Kidnapping.Interactions")
end
