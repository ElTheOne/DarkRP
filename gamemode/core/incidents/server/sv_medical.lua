local Medical = {
	UseRange = 120,
	HealRange = 120,
	HealAmount = 20,
	DefibrillatorRange = 110,
	DefibrillatorDuration = 4,
	ReviveHealth = 50,
	DistanceInterval = 1,
	NextID = 1,
	ByPlayer = setmetatable({}, { __mode = "k" }),
	ByCorpse = setmetatable({}, { __mode = "k" }),
	Records = {},
	Revives = setmetatable({}, { __mode = "k" }),
	UseThrottle = setmetatable({}, { __mode = "k" }),
	FeedbackThrottle = setmetatable({}, { __mode = "k" })
}

DRP.Medical = Medical
DRP.Services.Register("medical", Medical)

local PROMPT = "drp_medical_prompt_v1"
local REQUEST = "drp_medical_request_v1"
local CALL = "drp_medical_call_v1"
local DISTANCES = "drp_medical_distances_v1"
local DEFIB = "drp_medical_defib_v1"
local DISTANCE_TIMER = "DRP.Medical.Distances"
local DEFIB_TIMER = "DRP.Medical.Defibrillation"

local function validMedic(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:Alive()
		and ply.DRPHasRoleCapability and ply:DRPHasRoleCapability("canHeal") == true
end

function Medical:InstallHLMedkitTracking()
	local stored = weapons.GetStored("weapon_medkit")
	if not istable(stored) or not isfunction(stored.DoHeal) then
		ErrorNoHalt("[DRP MEDICAL] weapon_medkit is unavailable; Medic behavior pathway was not installed.\n")
		return false
	end
	if stored.DRPHLHealingTrackingInstalled then return true end

	local originalDoHeal = stored.DoHeal
	stored.DoHeal = function(weapon, target)
		local owner = IsValid(weapon) and weapon:GetOwner() or nil
		local previous = IsValid(target) and math.max(0, target:Health()) or 0
		local result = originalDoHeal(weapon, target)

		if result == true
			and IsValid(owner) and owner:IsPlayer()
			and IsValid(target) and target:IsPlayer() and target ~= owner then
			local amount = math.max(0, target:Health() - previous)
			if amount > 0 then
				hook.Run("DRPPlayerHealed", owner, target, amount, "weapon_medkit")
			end
		end
		return result
	end
	stored.DRPHLHealingTrackingInstalled = true
	stored.DRPOriginalDoHeal = originalDoHeal
	print("[DRP MEDICAL] HL medkit behavior pathway installed")
	return true
end

local function feedback(ply, text, kind)
	if not IsValid(ply) then return end
	local now = CurTime()
	if (Medical.FeedbackThrottle[ply] or 0) > now then return end
	Medical.FeedbackThrottle[ply] = now + 0.75
	DRP.Net.Notify(ply, text, kind or 3)
end

local function visibleThroughWorld(ply, position)
	local trace = util.TraceLine({
		start = ply:EyePos(),
		endpos = position,
		filter = ply,
		mask = MASK_SOLID_BRUSHONLY
	})
	return not trace.Hit or trace.Fraction > 0.97
end

local function aimedCandidate(ply, candidates, range, center)
	local start = ply:EyePos()
	local direction = ply:GetAimVector()
	local best, bestOffset, bestDistance
	for _, candidate in ipairs(candidates) do
		if IsValid(candidate) and candidate ~= ply then
			local position = center(candidate)
			local delta = position - start
			local distance = delta:Dot(direction)
			if distance >= 0 and distance <= range then
				local closest = start + direction * distance
				local offset = position:DistToSqr(closest)
				if offset <= 48 * 48 and visibleThroughWorld(ply, position)
					and (not bestOffset or offset < bestOffset or (offset == bestOffset and distance < bestDistance)) then
					best, bestOffset, bestDistance = candidate, offset, distance
				end
			end
		end
	end
	return best
end

local function addRecipient(output, seen, ply)
	if not IsValid(ply) or seen[ply] then return end
	seen[ply] = true
	output[#output + 1] = ply
end

function Medical:Recipients(record, includeUncalled)
	local recipients, seen = {}, {}
	addRecipient(recipients, seen, record.owner)
	if record.called or includeUncalled then
		for _, ply in ipairs(DRP.Players.List) do
			if validMedic(ply) then addRecipient(recipients, seen, ply) end
		end
	end
	return recipients
end

function Medical:SendRecord(record, recipient)
	if not record then return end
	local recipients = recipient and { recipient } or self:Recipients(record, false)
	if #recipients == 0 then return end
	net.Start(CALL)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(true)
	net.WriteUInt(record.id, 24)
	net.WriteEntity(IsValid(record.corpse) and record.corpse or NULL)
	net.WriteString(IsValid(record.owner) and record.owner:SteamID64() or record.ownerSteamID)
	net.WriteString(record.ownerName)
	net.WriteVector(IsValid(record.corpse) and record.corpse:GetPos() or record.position)
	net.WriteBool(record.called == true)
	net.WriteString(record.callerName or "")
	net.Send(recipients)
	DRP.Net.Record(48 + #record.ownerName + #(record.callerName or ""), #recipients)
end

function Medical:SendRemoval(record, recipient)
	local recipients = recipient and { recipient } or self:Recipients(record, true)
	if #recipients == 0 then return end
	net.Start(CALL)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(false)
	net.WriteUInt(record.id, 24)
	net.Send(recipients)
	DRP.Net.Record(5, #recipients)
end

function Medical:IsCorpse(entity)
	return IsValid(entity) and self.ByCorpse[entity] ~= nil
end

function Medical:GetRecord(entityOrPlayer)
	if not IsValid(entityOrPlayer) then return nil end
	return entityOrPlayer:IsPlayer() and self.ByPlayer[entityOrPlayer] or self.ByCorpse[entityOrPlayer]
end

function Medical:TraceLivingPlayer(ply)
	if not IsValid(ply) then return nil end
	ply:LagCompensation(true)
	local trace = util.TraceHull({
		start = ply:EyePos(),
		endpos = ply:EyePos() + ply:GetAimVector() * self.HealRange,
		mins = Vector(-10, -10, -10),
		maxs = Vector(10, 10, 10),
		filter = ply,
		mask = MASK_SHOT
	})
	ply:LagCompensation(false)
	if IsValid(trace.Entity) and trace.Entity:IsPlayer() and trace.Entity ~= ply and trace.Entity:Alive() then
		return trace.Entity
	end
	return aimedCandidate(ply, (DRP.Players and DRP.Players.List) or player.GetAll(), self.HealRange, function(candidate)
		return candidate:WorldSpaceCenter()
	end)
end

function Medical:HealAimed(medic)
	if not validMedic(medic) then
		feedback(medic, "Only players with Medic permissions can use this equipment.")
		return false
	end
	local target = self:TraceLivingPlayer(medic)
	if not IsValid(target) then
		feedback(medic, "Aim the medical kit at a living player within range.")
		return false
	end
	local previous = math.max(0, target:Health())
	local maximum = math.max(1, target:GetMaxHealth())
	local updated = math.min(maximum, previous + self.HealAmount)
	if updated <= previous then
		feedback(medic, target:DRPName() .. " is already at full health.", 2)
		return false
	end
	target:SetHealth(updated)
	target:EmitSound("items/smallmedkit1.wav", 65, 100, 0.75)
	DRP.Net.Notify(medic, "Treated " .. target:DRPName() .. " for " .. (updated - previous) .. " health.", 1)
	DRP.Net.Notify(target, medic:DRPName() .. " restored " .. (updated - previous) .. " health.", 1)
	hook.Run("DRPPlayerHealed", medic, target, updated - previous, "weapon_drp_medkit")
	return true
end

local function copyAppearance(ply, ragdoll)
	ragdoll:SetModel(ply:GetModel())
	ragdoll:SetSkin(ply:GetSkin())
	for index = 0, math.max(0, ply:GetNumBodyGroups() - 1) do
		ragdoll:SetBodygroup(index, ply:GetBodygroup(index))
	end
	ragdoll:SetColor(ply:GetColor())
	ragdoll:SetMaterial(ply:GetMaterial())
end

function Medical:CreateCorpse(ply)
	if not IsValid(ply) or ply:Alive() then return nil end
	self:RemovePlayer(ply, "replaced")

	-- Prefer the engine-created death ragdoll because it already contains the
	-- player's final animated bone pose and physics impulse. Rebuilding it from
	-- the standing player entity produces a rigid T/Y pose on some models.
	local engineRagdoll = ply:GetRagdollEntity()
	local corpse = engineRagdoll
	if not IsValid(corpse) then
		corpse = ents.Create("prop_ragdoll")
		if not IsValid(corpse) then return nil end
		copyAppearance(ply, corpse)
		corpse:SetPos(ply:GetPos())
		corpse:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		corpse:Spawn()
		corpse:Activate()
		local velocity = ply:GetVelocity()
		for index = 0, math.max(0, corpse:GetPhysicsObjectCount() - 1) do
			local physics = corpse:GetPhysicsObjectNum(index)
			if IsValid(physics) then physics:SetVelocity(velocity) end
		end
	end
	corpse:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
	corpse:SetUseType(SIMPLE_USE)
	corpse.DRPMedicalCorpse = true

	local record = {
		id = self.NextID,
		owner = ply,
		ownerSteamID = ply:SteamID64(),
		ownerName = string.sub(ply:DRPName(), 1, 48),
		corpse = corpse,
		position = corpse:GetPos(),
		called = false,
		createdAt = CurTime()
	}
	self.NextID = self.NextID % 16777214 + 1
	self.ByPlayer[ply] = record
	self.ByCorpse[corpse] = record
	self.Records[record.id] = record
	hook.Run("DRPMedicalBodyCreated", record, ply, corpse)
	self:SendRecord(record, ply)
	self:EnsureDistanceTimer()
	if DRP.Audit then DRP.Audit.Log(ply, "medical_body_created", corpse) end
	return record
end

function Medical:RemoveRecord(record, reason, keepEntity)
	if not record or self.Records[record.id] ~= record then return false end
	self:SendRemoval(record)
	self.Records[record.id] = nil
	if self.ByPlayer[record.owner] == record then self.ByPlayer[record.owner] = nil end
	if IsValid(record.corpse) and self.ByCorpse[record.corpse] == record then self.ByCorpse[record.corpse] = nil end
	for medic, channel in pairs(self.Revives) do
		if channel.record == record then self:CancelDefibrillation(medic, "The patient is no longer available") end
	end
	if not keepEntity and IsValid(record.corpse) then
		record.corpse.DRPMedicalRemoving = true
		SafeRemoveEntity(record.corpse)
	end
	if table.IsEmpty(self.Records) then timer.Remove(DISTANCE_TIMER) end
	hook.Run("DRPMedicalBodyRemoved", record.owner, reason or "removed")
	return true
end

function Medical:RemovePlayer(ply, reason, keepEntity)
	local record = self.ByPlayer[ply]
	if not record then return false end
	return self:RemoveRecord(record, reason, keepEntity)
end

function Medical:Prompt(ply, corpse)
	local record = self.ByCorpse[corpse]
	if not record or not IsValid(ply) or not ply:Alive() then return false end
	if ply:GetPos():DistToSqr(corpse:GetPos()) > self.UseRange * self.UseRange then return false end
	net.Start(PROMPT)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteEntity(corpse)
	net.WriteString(record.ownerName)
	net.WriteBool(record.called)
	net.Send(ply)
	return true
end

function Medical:RequestMedic(ply, corpse)
	local record = self.ByCorpse[corpse]
	if not record or not IsValid(ply) or not ply:Alive() or not IsValid(record.owner) or record.owner:Alive() then return false end
	if ply:GetPos():DistToSqr(corpse:GetPos()) > self.UseRange * self.UseRange then return false end
	if record.called then
		DRP.Net.Notify(ply, "A Medic has already been called for " .. record.ownerName .. ".", 2)
		return false
	end
	record.called = true
	record.caller = ply
	record.callerName = string.sub(ply:DRPName(), 1, 48)
	record.calledAt = CurTime()
	self:SendRecord(record)
	DRP.Net.Notify(ply, "Medic requested for " .. record.ownerName .. ".", 1)
	DRP.Net.Notify(record.owner, record.callerName .. " called a Medic for you.", 1)
	for _, medic in ipairs(DRP.Players.List) do
		if validMedic(medic) then
			DRP.Net.Notify(medic, "Medical call: " .. record.ownerName .. " needs revival.", 2)
		end
	end
	if DRP.Audit then DRP.Audit.Log(ply, "medic_called", record.owner, "body #" .. record.id) end
	hook.Run("DRPMedicCalled", record.owner, ply, corpse)
	return true
end

function Medical:SendDistances(record)
	if not IsValid(record.owner) or record.owner:Alive() then return end
	if IsValid(record.corpse) then record.position = record.corpse:GetPos() end
	local medics = {}
	for _, ply in ipairs(DRP.Players.List) do
		if validMedic(ply) and ply ~= record.owner then
			medics[#medics + 1] = {
				player = ply,
				distance = math.Clamp(math.floor(ply:GetPos():Distance(record.position) / 52.49 + 0.5), 0, 65535)
			}
		end
	end
	table.sort(medics, function(a, b) return a.distance < b.distance end)
	net.Start(DISTANCES)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(record.id, 24)
	net.WriteUInt(math.min(#medics, 8), 4)
	for index = 1, math.min(#medics, 8) do
		local entry = medics[index]
		net.WriteEntity(entry.player)
		net.WriteString(string.sub(entry.player:DRPName(), 1, 48))
		net.WriteUInt(entry.distance, 16)
	end
	net.Send(record.owner)
	DRP.Net.Record(6 + math.min(#medics, 8) * 12)
end

function Medical:EnsureDistanceTimer()
	if timer.Exists(DISTANCE_TIMER) then return end
	timer.Create(DISTANCE_TIMER, self.DistanceInterval, 0, function()
		if table.IsEmpty(Medical.Records) then timer.Remove(DISTANCE_TIMER) return end
		for _, record in pairs(Medical.Records) do Medical:SendDistances(record) end
	end)
end

function Medical:SendDefibrillation(ply, active, record, reason)
	if not IsValid(ply) then return end
	net.Start(DEFIB)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(active == true)
	if active then
		net.WriteUInt(record.id, 24)
		net.WriteFloat(self.DefibrillatorDuration)
		net.WriteString(record.ownerName)
	else
		net.WriteString(string.sub(tostring(reason or ""), 1, 96))
	end
	net.Send(ply)
end

function Medical:TraceCorpse(ply)
	if not IsValid(ply) then return nil, nil end
	local trace = util.TraceHull({
		start = ply:EyePos(),
		endpos = ply:EyePos() + ply:GetAimVector() * self.DefibrillatorRange,
		mins = Vector(-12, -12, -12),
		maxs = Vector(12, 12, 12),
		filter = ply,
		mask = MASK_SHOT
	})
	if self.ByCorpse[trace.Entity] then return trace.Entity, self.ByCorpse[trace.Entity] end

	local corpses = {}
	for _, record in pairs(self.Records) do
		if IsValid(record.corpse) then corpses[#corpses + 1] = record.corpse end
	end
	local corpse = aimedCandidate(ply, corpses, self.DefibrillatorRange, function(candidate)
		return candidate:WorldSpaceCenter()
	end)
	return corpse, self.ByCorpse[corpse]
end

function Medical:BeginDefibrillation(medic)
	if not validMedic(medic) then
		feedback(medic, "Only players with Medic permissions can use this equipment.")
		return false
	end
	local corpse, record = self:TraceCorpse(medic)
	if not record or not IsValid(corpse) or not IsValid(record.owner) or record.owner:Alive() then
		if not self.Revives[medic] then feedback(medic, "Aim the defibrillator at a player's body within range.") end
		return false
	end
	local existing = self.Revives[medic]
	if existing then return existing.record == record end
	self.Revives[medic] = {
		record = record,
		startedAt = CurTime(),
		endsAt = CurTime() + self.DefibrillatorDuration
	}
	self:SendDefibrillation(medic, true, record)
	if not timer.Exists(DEFIB_TIMER) then
		timer.Create(DEFIB_TIMER, 0.1, 0, function() Medical:ProcessDefibrillations() end)
	end
	return true
end

function Medical:CancelDefibrillation(medic, reason)
	if not IsValid(medic) or not self.Revives[medic] then return false end
	self.Revives[medic] = nil
	self:SendDefibrillation(medic, false, nil, reason)
	if table.IsEmpty(self.Revives) then timer.Remove(DEFIB_TIMER) end
	return true
end

function Medical:ProcessDefibrillations()
	for medic, channel in pairs(self.Revives) do
		local record = channel.record
		local active = medic:KeyDown(IN_ATTACK)
			and validMedic(medic)
			and IsValid(medic:GetActiveWeapon())
			and medic:GetActiveWeapon():GetClass() == "weapon_drp_defibrillator"
			and record and self.Records[record.id] == record
			and IsValid(record.owner) and not record.owner:Alive()
		local corpse, aimedRecord
		if active then corpse, aimedRecord = self:TraceCorpse(medic) active = aimedRecord == record and corpse == record.corpse end
		if not active then
			self:CancelDefibrillation(medic, "Keep holding primary on the body")
		elseif CurTime() >= channel.endsAt then
			self.Revives[medic] = nil
			self:Revive(medic, record)
		end
	end
	if table.IsEmpty(self.Revives) then timer.Remove(DEFIB_TIMER) end
end

function Medical:Revive(medic, record)
	if not validMedic(medic) or not record or self.Records[record.id] ~= record then return false end
	local patient = record.owner
	if not IsValid(patient) or patient:Alive() or not IsValid(record.corpse) then return false end
	local context = {
		position = record.corpse:GetPos() + Vector(0, 0, 12),
		angles = Angle(0, record.corpse:GetAngles().y, 0),
		medic = medic,
		record = record
	}
	patient.DRPMedicalReviveContext = context
	patient:Spawn()
	return patient:Alive()
end

function Medical:HandleSpawn(ply)
	local context = ply.DRPMedicalReviveContext
	ply.DRPMedicalReviveContext = nil
	if not context then
		self:RemovePlayer(ply, "respawned")
		return
	end
	local medic, record = context.medic, context.record
	self:RemoveRecord(record, "revived")
	ply:SetPos(context.position)
	ply:SetEyeAngles(context.angles)
	ply:SetHealth(math.min(math.max(1, self.ReviveHealth), ply:GetMaxHealth()))
	ply:SetVelocity(-ply:GetVelocity())
	DRP.Net.Notify(ply, "You were revived by " .. (IsValid(medic) and medic:DRPName() or "a Medic") .. ".", 1)
	if IsValid(medic) then
		self:SendDefibrillation(medic, false, nil, "Revival complete")
		DRP.Net.Notify(medic, "Revived " .. ply:DRPName() .. ".", 1)
		if DRP.Civic then DRP.Civic:Adjust(medic, 10, "revived a player") end
		if DRP.Roles then DRP.Roles:Record(medic, "healing", 2, "revived a player") end
		if DRP.Experience then DRP.Experience:Add(medic, 40, "medical:revive", "Revived " .. ply:DRPName()) end
		if DRP.Audit then DRP.Audit.Log(medic, "player_revived", ply, "body #" .. record.id) end
	end
	hook.Run("DRPPlayerRevived", ply, medic)
end

function Medical:Start()
	util.AddNetworkString(PROMPT)
	util.AddNetworkString(REQUEST)
	util.AddNetworkString(CALL)
	util.AddNetworkString(DISTANCES)
	util.AddNetworkString(DEFIB)
	self:InstallHLMedkitTracking()
end

function Medical:Stop()
	timer.Remove(DISTANCE_TIMER)
	timer.Remove(DEFIB_TIMER)
	for _, record in pairs(self.Records) do
		if IsValid(record.corpse) then record.corpse:Remove() end
	end
	self.Records = {}
end

DRP.Net.Receive(REQUEST, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "medical_request", 0.5, 3) then return end
	Medical:RequestMedic(ply, net.ReadEntity())
end)

hook.Add("PlayerDeath", "DRP.Medical.Death", function(ply)
	timer.Simple(0, function()
		if IsValid(ply) and not ply:Alive() then Medical:CreateCorpse(ply) end
	end)
end)

hook.Add("PlayerSpawn", "DRP.Medical.Spawn", function(ply) Medical:HandleSpawn(ply) end)
hook.Add("PlayerDisconnected", "DRP.Medical.Disconnect", function(ply) Medical:RemovePlayer(ply, "disconnected") end)

hook.Add("EntityRemoved", "DRP.Medical.CorpseRemoved", function(entity)
	local record = Medical.ByCorpse[entity]
	if record and not entity.DRPMedicalRemoving then Medical:RemoveRecord(record, "body removed", true) end
end)

hook.Add("PlayerUse", "DRP.Medical.CorpseUse", function(ply, entity)
	if not Medical:IsCorpse(entity) then return end
	local now = CurTime()
	if (Medical.UseThrottle[ply] or 0) <= now then
		Medical.UseThrottle[ply] = now + 0.75
		Medical:Prompt(ply, entity)
	end
	return false
end)

hook.Add("PhysgunPickup", "DRP.Medical.ProtectCorpse", function(_, entity)
	if Medical:IsCorpse(entity) then return false end
end)
hook.Add("CanTool", "DRP.Medical.ProtectCorpseTools", function(_, trace)
	if trace and Medical:IsCorpse(trace.Entity) then return false end
end)
hook.Add("CanProperty", "DRP.Medical.ProtectCorpseProperties", function(_, _, entity)
	if Medical:IsCorpse(entity) then return false end
end)

hook.Add("DRPJobChanged", "DRP.Medical.MedicRole", function(ply)
	if not validMedic(ply) then
		Medical:CancelDefibrillation(ply, "Medic role lost")
		for _, record in pairs(Medical.Records) do Medical:SendRemoval(record, ply) end
		return
	end
	for _, record in pairs(Medical.Records) do
		if record.called then Medical:SendRecord(record, ply) end
	end
end)

hook.Add("DRPPlayerReady", "DRP.Medical.Ready", function(ply)
	if not validMedic(ply) then return end
	for _, record in pairs(Medical.Records) do
		if record.called then Medical:SendRecord(record, ply) end
	end
end)
