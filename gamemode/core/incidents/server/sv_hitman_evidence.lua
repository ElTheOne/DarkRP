local Evidence = {
	RequiredProofs = 3,
	PhotoRange = 1800,
	PhotoDot = 0.68,
	DeathLifetime = 300,
	PendingByVictim = setmetatable({}, { __mode = "k" }),
	PendingByIncident = {},
	ByCorpse = setmetatable({}, { __mode = "k" }),
	ExcludedIncidentTypes = {
		pvp_consent = true,
		standing_pvp = true,
		external_pvp = true,
		loadtest = true
	}
}

DRP.HitmanEvidence = Evidence
DRP.Services.Register("hitman_evidence", Evidence)

local function activeAdminMode(ply)
	return IsValid(ply) and DRP.AdminMode and DRP.AdminMode.IsActive
		and DRP.AdminMode.IsActive(ply)
end

function Evidence:IsQualifyingIncident(incident, attacker, victim)
	if not istable(incident) or not IsValid(attacker) or not IsValid(victim) then return false end
	if attacker == victim or not attacker:IsPlayer() or not victim:IsPlayer() then return false end
	if attacker:IsBot() or victim:IsBot() or activeAdminMode(attacker) or activeAdminMode(victim) then return false end
	if self.ExcludedIncidentTypes[tostring(incident.type or "")] then return false end
	if not DRP.Incidents or not DRP.Incidents.CanInIncident then return false end
	return DRP.Incidents.CanInIncident(incident, attacker, victim, DRP.IncidentAction.DAMAGE) == true
end

function Evidence:CaptureDeath(victim, attacker)
	if not IsValid(victim) or not IsValid(attacker) or not attacker:IsPlayer() then return false end
	local allowed, incident = DRP.Incidents.Can(attacker, victim, DRP.IncidentAction.DAMAGE)
	if not allowed or not self:IsQualifyingIncident(incident, attacker, victim) then return false end
	local record = {
		death_id = string.format("%d:%s:%d", tonumber(incident.id) or 0, victim:SteamID64(), math.floor(CurTime() * 1000)),
		incident_id = tonumber(incident.id) or 0,
		incident_type = tostring(incident.type or "incident"),
		killer = attacker,
		killer_id = attacker:SteamID64(),
		killer_name = string.sub(attacker:DRPName(), 1, 64),
		victim = victim,
		victim_id = victim:SteamID64(),
		victim_name = string.sub(victim:DRPName(), 1, 64),
		created_at = CurTime(),
		expires_at = CurTime() + self.DeathLifetime,
		outcome_verified = false
	}
	self.PendingByVictim[victim] = record
	self.PendingByIncident[record.incident_id] = record
	return true, record
end

function Evidence:AttachCorpse(medicalRecord)
	if not istable(medicalRecord) or not IsValid(medicalRecord.corpse) then return false end
	local pending = self.PendingByVictim[medicalRecord.owner]
	if not pending or pending.expires_at < CurTime() then return false end
	pending.corpse = medicalRecord.corpse
	pending.position = medicalRecord.corpse:WorldSpaceCenter()
	medicalRecord.hitmanEvidence = pending
	medicalRecord.corpse.DRPHitmanEvidenceDeathID = pending.death_id
	self.ByCorpse[medicalRecord.corpse] = pending
	self.PendingByVictim[medicalRecord.owner] = nil
	return true
end

local function visibleThroughWorld(ply, corpse, origin, target)
	local trace = util.TraceLine({
		start = origin,
		endpos = target,
		filter = { ply, corpse },
		mask = MASK_SOLID_BRUSHONLY
	})
	return not trace.Hit or trace.Fraction > 0.98
end

function Evidence:VisibleCorpses(ply, origin, angles)
	if not IsValid(ply) or not isvector(origin) or not isangle(angles) then return {} end
	local output, now, forward = {}, CurTime(), angles:Forward()
	for corpse, record in pairs(self.ByCorpse) do
		if IsValid(corpse) and record.expires_at >= now then
			local target = corpse:WorldSpaceCenter()
			local offset = target - origin
			local distanceSquared = offset:LengthSqr()
			if distanceSquared <= self.PhotoRange * self.PhotoRange
				and distanceSquared > 1
				and offset:GetNormalized():Dot(forward) >= self.PhotoDot
				and (not ply.TestPVS or ply:TestPVS(corpse))
				and visibleThroughWorld(ply, corpse, origin, target) then
				output[#output + 1] = {
					death_id = record.death_id,
					incident_id = record.incident_id,
					incident_type = record.incident_type,
					victim_id = record.victim_id,
					victim_name = record.victim_name,
					distance = math.sqrt(distanceSquared),
					_record = record
				}
			end
		elseif not IsValid(corpse) or record.expires_at < now then
			self.ByCorpse[corpse] = nil
		end
	end
	table.sort(output, function(first, second) return first.distance < second.distance end)
	return output
end

function Evidence:ApplyPhoto(ply, metadata, visibleCorpses)
	if not IsValid(ply) or ply:IsBot() or activeAdminMode(ply) then return false end
	for _, entry in ipairs(visibleCorpses or {}) do
		local record = entry._record
		if record and record.outcome_verified == true
			and record.killer == ply and record.killer_id == ply:SteamID64()
			and record.expires_at >= CurTime() and not record.credited then
			local granted, count = DRP.Roles and DRP.Roles.RecordHitEvidence
				and DRP.Roles:RecordHitEvidence(ply, record.victim_id, record.incident_id)
			if granted then
				record.credited = true
				if DRP.Net then
					DRP.Net.Notify(ply, string.format("Hitman evidence %d/%d — authenticated photograph of %s.", count, self.RequiredProofs, record.victim_name), 1)
				end
				if DRP.Audit then
					DRP.Audit.Log(ply, "hitman_photo_evidence", record.victim,
						"incident #" .. record.incident_id .. " proof " .. count .. "/" .. self.RequiredProofs)
				end
				hook.Run("DRPHitmanEvidenceGranted", ply, record, count, metadata)
				return true
			end
		end
	end
	return false
end

function Evidence:Start()
	hook.Add("DRPIncidentResolved", "DRP.HitmanEvidence.Outcome", function(incident, receipt)
		local record = istable(incident) and Evidence.PendingByIncident[tonumber(incident.id) or 0] or nil
		if not record or not istable(receipt) then return end
		record.outcome_verified = receipt.winner_id == record.killer_id
			and receipt.loser_id == record.victim_id
			and receipt.instigator_id ~= "" and receipt.victim_id ~= ""
		Evidence.PendingByIncident[record.incident_id] = nil
	end)
	hook.Add("DRPMedicalBodyCreated", "DRP.HitmanEvidence.Corpse", function(record)
		Evidence:AttachCorpse(record)
	end)
	hook.Add("DRPPhonePhotoCaptured", "DRP.HitmanEvidence.Photo", function(ply, metadata, corpses)
		Evidence:ApplyPhoto(ply, metadata, corpses)
	end)
	hook.Add("EntityRemoved", "DRP.HitmanEvidence.CorpseRemoved", function(entity)
		Evidence.ByCorpse[entity] = nil
	end)
	hook.Add("PlayerDisconnected", "DRP.HitmanEvidence.Disconnect", function(ply)
		Evidence.PendingByVictim[ply] = nil
	end)
end

function Evidence:Stop()
	hook.Remove("DRPIncidentResolved", "DRP.HitmanEvidence.Outcome")
	hook.Remove("DRPMedicalBodyCreated", "DRP.HitmanEvidence.Corpse")
	hook.Remove("DRPPhonePhotoCaptured", "DRP.HitmanEvidence.Photo")
	hook.Remove("EntityRemoved", "DRP.HitmanEvidence.CorpseRemoved")
	hook.Remove("PlayerDisconnected", "DRP.HitmanEvidence.Disconnect")
	self.PendingByVictim = setmetatable({}, { __mode = "k" })
	self.PendingByIncident = {}
	self.ByCorpse = setmetatable({}, { __mode = "k" })
end
