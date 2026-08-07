local Drugs = {
	States = setmetatable({}, { __mode = "k" }),
	ForceFeeds = setmetatable({}, { __mode = "k" }),
	Saved = {},
	ForceFeedTime = 3,
	ForceFeedDistance = 105,
	ForceFeedMoveTolerance = 18,
	ForceFeedAimDot = 0.7,
	Dirty = false
}

DRP.Drugs = Drugs
DRP.Services.Register("drugs", Drugs)

Drugs.Definitions = {
	heroin = { name = "Heroin", duration = 180, description = "90% damage resistance for 3 minutes; withdrawal removes 5 health each minute." },
	speed = { name = "Speed", duration = 120, description = "50% faster sprinting for 2 minutes; withdrawal halves movement for 4 minutes." },
	weed = { name = "Weed", duration = 180, description = "Visual effects for 3 minutes." },
	pcp = { name = "PCP", duration = 60, description = "50% higher jumps for 1 minute." },
	crack = { name = "Crack", duration = 300, description = "45% more damage for 5 minutes; withdrawal reduces accuracy for 10 minutes." },
	fentanyl = { name = "Fentanyl", duration = 120, description = "Complete incapacitation for 2 minutes." },
	cocaine = { name = "Cocaine", duration = 120, description = "15% faster movement and heightened visual focus for 2 minutes." }
}

DRP.Incidents.RegisterType("forced_drugging", {
	initial = "retaliation_allowed",
	outcomes = { default = { winner = "victim", loser = "instigator" } },
	onParticipantUnavailable = function(incident, ply)
		local role = DRP.Incidents.Role(incident, ply) or ""
		if string.StartWith(role, "officer_") then
			DRP.Incidents.RemoveParticipant(incident, ply, "Officer unavailable")
			return true
		end
		return false
	end
})

local function state(ply)
	Drugs.States[ply] = Drugs.States[ply] or {}
	return Drugs.States[ply]
end

local function setEnd(ply, key, value)
	ply:SetNW2Float("DRPDrug_" .. key, value or 0)
end

local function active(record, key)
	return (record[key .. "Until"] or 0) > CurTime()
end

local function planarSpeedSquared(ply)
	local velocity = ply:GetVelocity()
	return velocity.x * velocity.x + velocity.y * velocity.y
end

local persistedDeadlines = { "heroinUntil", "speedUntil", "speedWithdrawalUntil", "weedUntil", "pcpUntil", "crackUntil", "crackWithdrawalUntil", "fentanylUntil", "cocaineUntil" }

local function drugDeadlineKey(ply, suffix)
	return "drug:" .. tostring(IsValid(ply) and ply:SteamID64() or "invalid") .. ":" .. suffix
end

local scheduleHeroinDamage

local function scheduleHeroin(ply)
	local record = IsValid(ply) and Drugs.States[ply]
	local key = drugDeadlineKey(ply, "heroin")
	if not record or not record.heroinDependency then DRP.Deadlines.Cancel(key) return end
	DRP.Deadlines.Schedule(key, math.max(CurTime(), record.heroinUntil or CurTime()), function()
		local current = IsValid(ply) and Drugs.States[ply]
		if not current or not current.heroinDependency then return end
		if active(current, "heroin") then scheduleHeroin(ply) return end
		current.heroinWithdrawal = true
		ply:SetNW2Bool("DRPHeroinWithdrawal", true)
		DRP.Net.Notify(ply, "Heroin withdrawal has begun. You will lose 5 health every minute until another dose.", 3)
		Drugs.SavePlayer(ply)
		scheduleHeroinDamage(ply)
	end)
end

scheduleHeroinDamage = function(ply)
	local key = drugDeadlineKey(ply, "heroin_damage")
	local record = IsValid(ply) and Drugs.States[ply]
	if not record or not record.heroinWithdrawal then DRP.Deadlines.Cancel(key) return end
	DRP.Deadlines.Schedule(key, CurTime() + 60, function()
		local current = IsValid(ply) and Drugs.States[ply]
		if not current or not current.heroinWithdrawal then return end
		if ply:Alive() then
			local health = ply:Health() - 5
			if health <= 0 then ply:Kill() else ply:SetHealth(health) end
			DRP.Net.Notify(ply, "Heroin withdrawal: -5 health.", 3)
		end
		scheduleHeroinDamage(ply)
	end)
end

local function schedulePCPRestore(ply)
	local record = IsValid(ply) and Drugs.States[ply]
	local key = drugDeadlineKey(ply, "pcp")
	if not record or not record.jumpPowerBeforePCP then DRP.Deadlines.Cancel(key) return end
	DRP.Deadlines.Schedule(key, math.max(CurTime(), record.pcpUntil or CurTime()), function()
		local current = IsValid(ply) and Drugs.States[ply]
		if not current or not current.jumpPowerBeforePCP then return end
		if active(current, "pcp") then schedulePCPRestore(ply) return end
		ply:SetJumpPower(current.jumpPowerBeforePCP)
		current.jumpPowerBeforePCP = nil
	end)
end

function Drugs.WriteSaved()
	if not Drugs.Dirty then return end
	file.CreateDir("darkrp")
	file.Write("darkrp/drug_states.json", util.TableToJSON(Drugs.Saved, true))
	Drugs.Dirty = false
end

function Drugs.SavePlayer(ply, flush)
	if not IsValid(ply) or ply:IsBot() then return end
	local record = Drugs.States[ply]
	if not record then return end
	local output, now = {
		heroinWithdrawal = record.heroinWithdrawal == true,
		heroinDependency = record.heroinDependency == true
	}, os.time()
	for _, field in ipairs(persistedDeadlines) do
		if record[field] then output[field] = now + math.max(0, math.ceil(record[field] - CurTime())) end
	end
	Drugs.Saved[ply:SteamID64()] = output
	Drugs.Dirty = true
	if flush then Drugs.WriteSaved() end
end

function Drugs.RestorePlayer(ply)
	if ply.DRPDrugStateLoaded or ply:IsBot() then return end
	ply.DRPDrugStateLoaded = true
	local saved = Drugs.Saved[ply:SteamID64()]
	if not istable(saved) then return end
	local record, now = state(ply), os.time()
	record.heroinDependency = saved.heroinDependency == true
		or (saved.heroinDependency == nil and (saved.heroinWithdrawal == true or saved.heroinUntil ~= nil))
	for _, field in ipairs(persistedDeadlines) do
		local remaining = math.max(0, math.floor(tonumber(saved[field]) or 0) - now)
		if remaining > 0 then record[field] = CurTime() + remaining end
	end
	if record.heroinDependency and (saved.heroinWithdrawal == true or (saved.heroinUntil and tonumber(saved.heroinUntil) <= now)) then
		record.heroinWithdrawal = true
		record.heroinNextDamage = CurTime() + 60
		ply:SetNW2Bool("DRPHeroinWithdrawal", true)
	end
	for _, key in ipairs({ "heroin", "speed", "weed", "pcp", "crack", "fentanyl", "cocaine" }) do setEnd(ply, key, record[key .. "Until"] or 0) end
	setEnd(ply, "speed_withdrawal", record.speedWithdrawalUntil or 0)
	setEnd(ply, "crack_withdrawal", record.crackWithdrawalUntil or 0)
	if active(record, "pcp") then
		record.jumpPowerBeforePCP = ply:GetJumpPower()
		ply:SetJumpPower(record.jumpPowerBeforePCP * 1.5)
	end
	if record.heroinDependency then
		if record.heroinWithdrawal then scheduleHeroinDamage(ply) else scheduleHeroin(ply) end
	end
	if record.jumpPowerBeforePCP then schedulePCPRestore(ply) end
end

function Drugs.Ingest(ply, key, feeder, forced)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return false end
	key = string.lower(tostring(key or ""))
	local definition = Drugs.Definitions[key]
	if not definition then return false end

	local now, record = CurTime(), state(ply)
	local deadline = math.max(record[key .. "Until"] or 0, now + definition.duration)
	record[key .. "Until"] = deadline
	setEnd(ply, key, deadline)

	if key == "heroin" then
		record.heroinDependency = true
		record.heroinWithdrawal = false
		record.heroinNextDamage = nil
		ply:SetNW2Bool("DRPHeroinWithdrawal", false)
		DRP.Deadlines.Cancel(drugDeadlineKey(ply, "heroin_damage"))
		scheduleHeroin(ply)
	elseif key == "speed" then
		record.speedWithdrawalUntil = deadline + 240
		setEnd(ply, "speed_withdrawal", record.speedWithdrawalUntil)
	elseif key == "pcp" then
		if not record.jumpPowerBeforePCP then record.jumpPowerBeforePCP = ply:GetJumpPower() end
		ply:SetJumpPower(record.jumpPowerBeforePCP * 1.5)
		schedulePCPRestore(ply)
	elseif key == "crack" then
		record.crackWithdrawalUntil = deadline + 600
		setEnd(ply, "crack_withdrawal", record.crackWithdrawalUntil)
	end

	local source = IsValid(feeder) and feeder or ply
	local forcedText = forced and (source:DRPName() .. " force-fed you " .. definition.name .. ".") or ("You consumed " .. definition.name .. ".")
	DRP.Net.Notify(ply, forcedText .. " " .. definition.description, forced and 3 or 1)
	if source ~= ply then DRP.Net.Notify(source, "You force-fed " .. ply:DRPName() .. " " .. definition.name .. ".", 1) end

	if forced and source ~= ply then
		if DRP.Roles then DRP.Roles:Record(source, "forceDrugging", 1, "force-drugging behavior") end
		local responseDuration = math.max(180, definition.duration + 60)
		local incident = DRP.Incidents.Create("forced_drugging", {
			reason = source:DRPName() .. " force-fed " .. definition.name .. " to " .. ply:DRPName(),
			instigator = source,
			victim = ply,
			participants = { suspect = source, victim = ply },
			deadline = now + responseDuration,
			metadata = { drug = key }
		})
		if incident then
			DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, ply, source, "Defending against forced drugging", incident.deadline)
			DRP.Incidents.AddEvidence(incident, "drug_force_fed", source, ply, definition.name)
			if DRP.PVP then
				DRP.PVP:QueueWitnessedOffence("forced_drugging", source, ply, incident, {
					drug = key,
					drugName = definition.name
				})
			end
		end
	end
	if DRP.Audit then DRP.Audit.Log(source, forced and "drug_force_fed" or "drug_consumed", ply, key) end
	Drugs.SavePlayer(ply)
	return true
end

local function validForceFeedPlayers(feeder, target)
	if not IsValid(feeder) or not feeder:Alive() or not IsValid(target) or not target:IsPlayer() or target == feeder or not target:Alive() then return false end
	if feeder:InVehicle() or target:InVehicle() then return false end
	if feeder:EyePos():DistToSqr(target:WorldSpaceCenter()) > Drugs.ForceFeedDistance * Drugs.ForceFeedDistance then return false end
	return true
end

local function canStartForceFeed(feeder, target, traceAlreadyMatched)
	if not validForceFeedPlayers(feeder, target) then return false end
	if not feeder:OnGround() or not target:OnGround() then return false end
	if planarSpeedSquared(feeder) > 100 or planarSpeedSquared(target) > 100 then return false end
	return traceAlreadyMatched == true or feeder:GetEyeTrace().Entity == target
end

local function canContinueForceFeed(feeder, attempt)
	local target = attempt.target
	if not validForceFeedPlayers(feeder, target) then return false end
	local toleranceSquared = Drugs.ForceFeedMoveTolerance * Drugs.ForceFeedMoveTolerance
	if feeder:GetPos():DistToSqr(attempt.feederStart) > toleranceSquared or target:GetPos():DistToSqr(attempt.targetStart) > toleranceSquared then return false end

	local offset = target:WorldSpaceCenter() - feeder:EyePos()
	if offset:LengthSqr() <= 0 or feeder:EyeAngles():Forward():Dot(offset:GetNormalized()) < Drugs.ForceFeedAimDot then return false end
	local trace = util.TraceLine({
		start = feeder:EyePos(),
		endpos = target:WorldSpaceCenter(),
		filter = feeder,
		mask = MASK_SHOT
	})
	return trace.Entity == target
end

local function cancelForceFeed(ply)
	if not Drugs.ForceFeeds[ply] then return end
	Drugs.ForceFeeds[ply] = nil
	ply:SetNW2Float("DRPForceFeedEnd", 0)
	ply:SetNW2Entity("DRPForceFeedTarget", NULL)
end

function Drugs:ForceFeedThink()
	for ply, attempt in pairs(self.ForceFeeds) do
		local record, index
		if IsValid(ply) then record, index = DRP.Inventory.Selected(ply) end
		if not IsValid(ply) or not ply:KeyDown(IN_USE) or not canContinueForceFeed(ply, attempt) or not record or record.kind ~= "drug" or record.drug ~= attempt.drug or index ~= attempt.index then
			if IsValid(ply) then cancelForceFeed(ply) else self.ForceFeeds[ply] = nil end
		elseif CurTime() >= attempt.ends then
			local consumed = DRP.Inventory.Remove(ply, index)
			if consumed then Drugs.Ingest(attempt.target, consumed.drug, ply, true) end
			cancelForceFeed(ply)
		end
	end
	if next(self.ForceFeeds) == nil then timer.Remove("DRP.Drugs.ForceFeed") end
end

function Drugs:Start()
	local saved = util.JSONToTable(file.Read("darkrp/drug_states.json", "DATA") or "")
	if istable(saved) then self.Saved = saved end
end

function Drugs:Stop()
	timer.Remove("DRP.Drugs.ForceFeed")
	for _, ply in ipairs(DRP.Players.List) do Drugs.SavePlayer(ply) end
	self.WriteSaved()
end

hook.Add("KeyPress", "DRP.Drugs.ForceFeedStart", function(ply, key)
	if key ~= IN_USE or Drugs.ForceFeeds[ply] then return end
	local weapon = ply:GetActiveWeapon()
	local record, index = DRP.Inventory.Selected(ply)
	if not IsValid(weapon) or weapon:GetClass() ~= "weapon_drp_pocket" or not record or record.kind ~= "drug" then return end
	local target = ply:GetEyeTrace().Entity
	if not canStartForceFeed(ply, target, true) then return end
	Drugs.ForceFeeds[ply] = {
		target = target,
		drug = record.drug,
		index = index,
		ends = CurTime() + Drugs.ForceFeedTime,
		feederStart = ply:GetPos(),
		targetStart = target:GetPos()
	}
	ply:SetNW2Float("DRPForceFeedEnd", CurTime() + Drugs.ForceFeedTime)
	ply:SetNW2Entity("DRPForceFeedTarget", target)
	DRP.Net.Notify(ply, "Keep holding E and remain still to force-feed " .. target:DRPName() .. ".", 0)
	if not timer.Exists("DRP.Drugs.ForceFeed") then timer.Create("DRP.Drugs.ForceFeed", 0.1, 0, function() Drugs:ForceFeedThink() end) end
end)

hook.Add("KeyRelease", "DRP.Drugs.ForceFeedStop", function(ply, key)
	if key == IN_USE then cancelForceFeed(ply) end
end)

function Drugs.ApplyMove(ply, move)
	local record = Drugs.States[ply]
	if not record then return end
	local now = CurTime()
	if (record.fentanylUntil or 0) > now then
		move:SetForwardSpeed(0) move:SetSideSpeed(0) move:SetUpSpeed(0) move:SetMaxSpeed(0) move:SetMaxClientSpeed(0)
		move:SetVelocity(vector_origin)
		return
	end
	local multiplier = 1
	if (record.speedUntil or 0) > now and move:KeyDown(IN_SPEED) then multiplier = 1.5
	elseif (record.speedWithdrawalUntil or 0) > now then multiplier = 0.5
	elseif (record.cocaineUntil or 0) > now then multiplier = 1.15 end
	move:SetMaxSpeed(move:GetMaxSpeed() * multiplier)
	move:SetMaxClientSpeed(move:GetMaxClientSpeed() * multiplier)
end

function Drugs.ApplyCommand(ply, command)
	local record = Drugs.States[ply]
	if not record or not active(record, "fentanyl") then return end
	command:ClearMovement()
	command:RemoveKey(IN_ATTACK) command:RemoveKey(IN_ATTACK2) command:RemoveKey(IN_JUMP) command:RemoveKey(IN_USE)
	local down = tonumber(string.sub(ply:SteamID64() or "0", -1)) % 2 == 0
	command:SetViewAngles(Angle(down and 89 or -89, command:GetViewAngles().y, 0))
end

hook.Add("EntityTakeDamage", "DRP.Drugs.DamageModifiers", function(victim, damage)
	if IsValid(victim) and victim:IsPlayer() then
		local victimState = Drugs.States[victim]
		if victimState and active(victimState, "heroin") then damage:ScaleDamage(0.1) end
	end
	local attacker = damage:GetAttacker()
	if IsValid(attacker) and attacker:IsPlayer() then
		local attackerState = Drugs.States[attacker]
		if attackerState and active(attackerState, "crack") then damage:ScaleDamage(1.45) end
	end
end)

hook.Add("EntityFireBullets", "DRP.Drugs.CrackWithdrawal", function(entity, bullet)
	if not IsValid(entity) or not entity:IsPlayer() then return end
	local record = Drugs.States[entity]
	if not record or active(record, "crack") or (record.crackWithdrawalUntil or 0) <= CurTime() then return end
	local spread = bullet.Spread or vector_origin
	bullet.Spread = Vector(math.max(spread.x * 2.5, 0.045), math.max(spread.y * 2.5, 0.045), spread.z)
	return true
end)

hook.Add("PlayerDisconnected", "DRP.Drugs.Clear", function(ply)
	Drugs.SavePlayer(ply, true)
	cancelForceFeed(ply)
	for _, suffix in ipairs({ "heroin", "heroin_damage", "pcp" }) do DRP.Deadlines.Cancel(drugDeadlineKey(ply, suffix)) end
	Drugs.States[ply] = nil
	for feeder, attempt in pairs(Drugs.ForceFeeds) do if attempt.target == ply then cancelForceFeed(feeder) end end
end)

function Drugs.ClearPlayerEffects(ply)
	if not IsValid(ply) then return false end
	local record = Drugs.States[ply]

	-- PCP changes a real player movement property rather than consulting the
	-- effect record each frame, so restore it before discarding the state.
	if record and record.jumpPowerBeforePCP then
		ply:SetJumpPower(record.jumpPowerBeforePCP)
	end

	for _, suffix in ipairs({ "heroin", "heroin_damage", "pcp" }) do
		DRP.Deadlines.Cancel(drugDeadlineKey(ply, suffix))
	end
	for _, key in ipairs({ "heroin", "speed", "weed", "pcp", "crack", "fentanyl", "cocaine" }) do
		setEnd(ply, key, 0)
	end
	setEnd(ply, "speed_withdrawal", 0)
	setEnd(ply, "crack_withdrawal", 0)
	ply:SetNW2Bool("DRPHeroinWithdrawal", false)

	cancelForceFeed(ply)
	for feeder, attempt in pairs(Drugs.ForceFeeds) do
		if attempt.target == ply then cancelForceFeed(feeder) end
	end

	-- A death starts a clean drug life. Remove both the live state and its
	-- persisted snapshot so a later spawn/reconnect cannot resurrect an effect.
	Drugs.States[ply] = {}
	if not ply:IsBot() then
		Drugs.Saved[ply:SteamID64()] = nil
		Drugs.Dirty = true
	end
	return true
end

hook.Add("PlayerDeath", "DRP.Drugs.ClearEffects", function(ply)
	Drugs.ClearPlayerEffects(ply)
end)

function Drugs:ApplyPoliceWitness(kind, officer, suspect, victim, incident, context)
	if kind ~= "forced_drugging" or not incident or incident.type ~= "forced_drugging"
		or not IsValid(officer) or not officer:DRPJob().isPolice
		or not IsValid(suspect) or incident.instigator ~= suspect or not IsValid(victim) or incident.victim ~= victim then return false end
	local officerRole = "officer_" .. officer:EntIndex()
	if not DRP.Incidents.Role(incident, officer) then DRP.Incidents.AddParticipant(incident, officerRole, officer) end
	local reason, deadline = "Witnessed forced drugging", incident.deadline
	DRP.Incidents.Grant(incident, DRP.IncidentAction.TASE, officer, suspect, reason, deadline)
	DRP.Incidents.Grant(incident, DRP.IncidentAction.CUFF, officer, suspect, reason, deadline)
	DRP.Incidents.Grant(incident, DRP.IncidentAction.ARREST, officer, suspect, reason, deadline)
	DRP.Incidents.Grant(incident, DRP.IncidentAction.SEARCH, officer, suspect, reason, deadline)
	local firstWitness = incident.metadata.police_witnessed ~= true
	incident.metadata.police_witnessed = true
	incident.metadata.witness_count = math.max(0, math.floor(tonumber(incident.metadata.witness_count) or 0)) + 1
	suspect:SetNW2String("DRPWantedReason", "Forced drugging")
	local drugName = tostring(context and context.drugName or "a drug")
	DRP.Incidents.AddEvidence(incident, "forced_drugging_witnessed", officer, suspect, officer:DRPName() .. " witnessed " .. drugName)
	DRP.Net.Notify(officer, "You witnessed " .. suspect:DRPName() .. " force-drug " .. victim:DRPName() .. ". Non-lethal detention is authorized.", 2)
	if firstWitness then
		DRP.Net.Notify(suspect, officer:DRPName() .. " witnessed the forced drugging. You are now wanted.", 3)
		DRP.Net.Notify(victim, officer:DRPName() .. " witnessed the offence and can detain " .. suspect:DRPName() .. ".", 1)
	end
	return true
end

hook.Add("DRPPoliceWitnessedOffence", "DRP.Drugs.PoliceWitness", function(...)
	Drugs:ApplyPoliceWitness(...)
end)

local function hasWitnessedForcedDrugging(ply)
	for _, activeIncident in ipairs(DRP.Incidents.ForPlayer(ply, "forced_drugging")) do
		if activeIncident.metadata and activeIncident.metadata.police_witnessed == true then return true end
	end
	return false
end

hook.Add("DRPIncidentResolved", "DRP.Drugs.ClearWanted", function(incident)
	if incident.type ~= "forced_drugging" then return end
	for _, participant in ipairs(incident.participants or {}) do
		local ply = participant.role == "suspect" and participant.player or nil
		if IsValid(ply) and ply:GetNW2String("DRPWantedReason", "") == "Forced drugging" and not hasWitnessedForcedDrugging(ply) then
			ply:SetNW2String("DRPWantedReason", "")
		end
	end
end)

hook.Add("PlayerSpawn", "DRP.Drugs.RestorePCPJump", function(ply)
	timer.Simple(0, function()
		if not IsValid(ply) then return end
		Drugs.RestorePlayer(ply)
		local record = Drugs.States[ply]
		if record and active(record, "pcp") then
			ply:SetJumpPower(record.jumpPowerBeforePCP * 1.5)
		end
	end)
end)
