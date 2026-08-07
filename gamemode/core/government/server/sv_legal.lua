local Legal = {
	ArrestDuration = 120,
	WarrantDuration = 300,
	Lockdown = nil,
	LockdownStarted = 0,
	LockdownCursor = 0,
	LockdownBudget = 4,
	Arrested = setmetatable({}, { __mode = "k" }),
	Cuffed = setmetatable({}, { __mode = "k" }),
	TasedUntil = setmetatable({}, { __mode = "k" }),
	TasedCustody = setmetatable({}, { __mode = "k" }),
	Homeless = setmetatable({}, { __mode = "k" }),
	LastResistance = setmetatable({}, { __mode = "k" }),
	EscortDistance = 48,
	EscortSnapDistance = 150,
	CuffWindow = 12
}

local lockdownStateMessage = "drp_lockdown_state_v1"
util.AddNetworkString(lockdownStateMessage)

DRP.Legal = Legal
DRP.Services.Register("legal", Legal)

DRP.Incidents.RegisterType("legal_warrant", {
	initial = "approval_pending",
	transitions = { approval_pending = { active = true } },
	outcomes = {
		suspect_arrested = { winner = "instigator", loser = "victim" },
		default = { winner = "victim", loser = "instigator" }
	},
	onParticipantUnavailable = function(incident, ply)
		if DRP.Incidents.Role(incident, ply) == "suspect" then return false end
		DRP.Incidents.RemoveParticipant(incident, ply, "Officer unavailable")
		return true
	end
})

DRP.Incidents.RegisterType("lockdown", {
	initial = "warning",
	outcomes = { default = { winner = "instigator", loser = "victim" } },
	onParticipantUnavailable = function(incident, ply)
		if DRP.Legal.Lockdown == incident and DRP.Legal.AbortLockdown then DRP.Legal.AbortLockdown("Mayor unavailable")
		else DRP.Incidents.RemoveParticipant(incident, ply, "Left lockdown") end
		return true
	end
})

DRP.Incidents.RegisterType("lockdown_homelessness", {
	initial = "arrestable",
	outcomes = {
		sheltered = { winner = "victim", loser = "instigator" },
		default = { winner = "instigator", loser = "victim" }
	},
	onParticipantUnavailable = function(incident, ply)
		if DRP.Incidents.Role(incident, ply) == "suspect" then return false end
		DRP.Incidents.RemoveParticipant(incident, ply, "Officer unavailable")
		return true
	end
})

local function policePlayers()
	return DRP.PVP and DRP.PVP.OfficerList or {}
end

local function grantPolice(incident, suspect, reason, expires)
	suspect:SetNW2String("DRPWantedReason", string.sub(reason, 1, 120))
	for _, officer in ipairs(policePlayers()) do
		if not DRP.Incidents.Role(incident, officer) then DRP.Incidents.AddParticipant(incident, "officer", officer) end
		local alreadyGranted = false
		for _, grant in ipairs(incident.permissions[DRP.IncidentAction.ARREST] or {}) do if grant.actor == officer and grant.target == suspect then alreadyGranted = true break end end
		if not alreadyGranted then
			DRP.Incidents.Grant(incident, DRP.IncidentAction.TASE, officer, suspect, reason, expires)
			DRP.Incidents.Grant(incident, DRP.IncidentAction.CUFF, officer, suspect, reason, expires)
			DRP.Incidents.Grant(incident, DRP.IncidentAction.ARREST, officer, suspect, reason, expires)
			DRP.Incidents.Grant(incident, DRP.IncidentAction.SEARCH, officer, suspect, reason, expires)
			DRP.Incidents.Grant(incident, DRP.IncidentAction.ENTER_PROPERTY, officer, suspect, reason, expires)
		end
	end
end

function Legal.RequestWarrant(officer, suspect, reason)
	if not officer:DRPJob().isPolice or not IsValid(suspect) or suspect == officer then return false end
	reason = string.sub(string.Trim(tostring(reason or "")), 1, 120)
	if #reason < 5 then DRP.Net.Notify(officer, "A warrant needs a specific reason.", 3) return false end
	local mayor = DRP.Government and DRP.Government.CurrentMayor()
	local incident = DRP.Incidents.Create("legal_warrant", {
		state = IsValid(mayor) and "approval_pending" or "active",
		reason = "Warrant request: " .. reason,
		instigator = officer,
		victim = suspect,
		deadline = CurTime() + (IsValid(mayor) and 60 or Legal.WarrantDuration),
		participants = { officer = officer, suspect = suspect },
		metadata = { requested_reason = reason }
	})
	if not incident then return false end
	if IsValid(mayor) then
		DRP.Incidents.AddParticipant(incident, "mayor", mayor)
		DRP.Net.Notify(mayor, officer:DRPName() .. " requested warrant #" .. incident.id .. " for " .. suspect:DRPName() .. ". Use /approvewarrant " .. incident.id .. ".", 2)
	else
		grantPolice(incident, suspect, reason, incident.deadline)
	end
	return true
end

function Legal.ApproveWarrant(mayor, id)
	if mayor ~= DRP.Government.CurrentMayor() then return false end
	local incident = DRP.Incidents.Get(id)
	if not incident or incident.type ~= "legal_warrant" or incident.state ~= "approval_pending" then return false end
	local suspect
	for _, participant in ipairs(incident.participants) do if participant.role == "suspect" then suspect = participant.player end end
	if not IsValid(suspect) then return false end
	DRP.Incidents.Transition(incident, "active", "Warrant approved: " .. incident.metadata.requested_reason)
	DRP.Incidents.SetDeadline(incident, CurTime() + Legal.WarrantDuration, true)
	grantPolice(incident, suspect, incident.metadata.requested_reason, incident.deadline)
	return true
end

local preservedWeapons = {
	weapon_drp_keys = true,
	weapon_drp_pocket = true,
	weapon_physgun = true,
	gmod_tool = true,
	weapon_drp_mayor_tablet = true
}

local function custodyKey(ply)
	return "legal:custody:" .. ply:SteamID64()
end

local function aimedPlayer(officer, distance)
	if not IsValid(officer) or not officer:Alive() then return nil end
	local trace = officer:GetEyeTrace()
	local suspect = trace.Entity
	if not IsValid(suspect) or not suspect:IsPlayer() or suspect == officer or officer:EyePos():DistToSqr(trace.HitPos) > distance * distance then return nil end
	return suspect
end

function Legal.IsCuffed(ply) return Legal.Cuffed[ply] ~= nil end
function Legal.IsTased(ply) return (Legal.TasedUntil[ply] or 0) > CurTime() end

local function taserCustodyAuthority(officer, suspect)
	local custody = Legal.TasedCustody[suspect]
	if not custody or custody.expires <= CurTime() then
		Legal.TasedCustody[suspect] = nil
		return nil
	end
	local source = custody.source
	if not source or DRP.Incidents.Get(source.id) ~= source then return nil end
	if custody.officer == officer then return source end
	-- Nearby officers added to the same police side inherit the cuff window.
	if source.participantSides and source.participantSides[officer] == "instigator" then return source end
	if source.instigator == officer then return source end
end

local function cuffCandidate(officer)
	if not IsValid(officer) or not officer:Alive() then return nil end
	local traced = aimedPlayer(officer, 160)
	if IsValid(traced) and (Legal.Cuffed[traced] or taserCustodyAuthority(officer, traced)) then return traced end

	-- Tased players can be difficult to hit with GetEyeTrace when their weapon,
	-- animation or another entity overlaps the player hull. Resolve only from
	-- server-issued custody records, within range and in front of the officer.
	local eyePosition, aim = officer:EyePos(), officer:GetAimVector()
	local best, bestScore
	for suspect in pairs(Legal.TasedCustody) do
		if IsValid(suspect) and suspect:Alive() and not Legal.Cuffed[suspect]
			and taserCustodyAuthority(officer, suspect) then
			local targetPosition = suspect:WorldSpaceCenter()
			local offset = targetPosition - eyePosition
			local distanceSquared = offset:LengthSqr()
			if distanceSquared <= 160 * 160 and distanceSquared > 0 then
				local facing = aim:Dot(offset:GetNormalized())
				if facing >= 0.35 then
					local visibility = util.TraceLine({
						start = eyePosition,
						endpos = targetPosition,
						filter = { officer, suspect },
						mask = MASK_SOLID_BRUSHONLY
					})
					if not visibility.Hit or visibility.Fraction > 0.97 then
						local score = facing * 100000 - distanceSquared
						if not bestScore or score > bestScore then best, bestScore = suspect, score end
					end
				end
			end
		end
	end
	return best
end

function Legal.Tase(officer, suspect)
	if not IsValid(officer) or not officer:DRPJob().isPolice or not IsValid(suspect) or Legal.Arrested[suspect] or Legal.Cuffed[suspect] then return false end
	local allowed, source = DRP.Incidents.Can(officer, suspect, DRP.IncidentAction.TASE)
	if not allowed then DRP.Incidents.Deny(officer, suspect, DRP.IncidentAction.TASE) return false end
	if DRP.PVP and DRP.PVP.TaserAttempt then DRP.PVP.TaserAttempt(officer, suspect) end
	local cuffDeadline = CurTime() + Legal.CuffWindow
	Legal.TasedUntil[suspect] = cuffDeadline
	Legal.TasedCustody[suspect] = { officer = officer, source = source, expires = cuffDeadline }
	suspect:SetNW2Float("DRPTasedUntil", cuffDeadline)
	-- PvP state transitions only affect damage. Refresh an explicit custody grant
	-- from the successful taser so retaliation can never erase cuff authority.
	DRP.Incidents.Grant(source, DRP.IncidentAction.CUFF, officer, suspect,
		"Successful taser authorized handcuffing", cuffDeadline + 0.5)
	DRP.Incidents.Grant(source, DRP.IncidentAction.ARREST, officer, suspect,
		"Successful taser authorized police custody", cuffDeadline + 0.5)
	suspect:ScreenFade(SCREENFADE.IN, Color(90, 175, 255, 115), 0.25, 0.15)
	suspect:EmitSound("ambient/energy/zap1.wav", 75, 110, 0.8)
	DRP.Incidents.AddEvidence(source, "suspect_tased", officer, suspect, "Non-lethal force used")
	DRP.Net.Notify(suspect, officer:DRPName() .. " tased you. You are stunned for " .. Legal.CuffWindow .. " seconds.", 2)
	DRP.Net.Notify(officer, "Taser connected. Cuff " .. suspect:DRPName() .. " while they are stunned.", 1)
	if DRP.Audit then DRP.Audit.Log(officer, "suspect_tased", suspect, "incident #" .. source.id) end
	return true
end

function Legal.TaseAimed(officer)
	local suspect = aimedPlayer(officer, 600)
	if not suspect then DRP.Net.Notify(officer, "Aim at a suspect within taser range.", 3) return false end
	return Legal.Tase(officer, suspect)
end

function Legal.ClearCuffs(suspect, silent)
	local record = Legal.Cuffed[suspect]
	if not record then return false end
	Legal.Cuffed[suspect] = nil
	if IsValid(suspect) then
		suspect:SetNW2Bool("DRPCuffed", false)
		suspect:SetNW2Entity("DRPCuffedBy", NULL)
		if not silent and record.weaponClass and suspect:HasWeapon(record.weaponClass) then
			suspect:SelectWeapon(record.weaponClass)
		end
		if not silent then DRP.Net.Notify(suspect, "Your handcuffs were removed.", 1) end
	end
	return true
end

function Legal.Cuff(officer, suspect)
	if not IsValid(officer) or not officer:DRPJob().isPolice or not IsValid(suspect) or Legal.Arrested[suspect] then return false end
	local existing = Legal.Cuffed[suspect]
	if existing then
		local allowed, source = DRP.Incidents.Can(officer, suspect, DRP.IncidentAction.CUFF)
		if not allowed then source = taserCustodyAuthority(officer, suspect) allowed = source ~= nil end
		if not allowed then DRP.Incidents.Deny(officer, suspect, DRP.IncidentAction.CUFF) return false end
		existing.officer = officer
		existing.source = source
		existing.escorting = true
		suspect:SetNW2Entity("DRPCuffedBy", officer)
		if DRP.PVP and DRP.PVP.CustodySecured then DRP.PVP.CustodySecured(source, officer, suspect) end
		hook.Run("DRPPoliceCustodyStarted", officer, suspect)
		if suspect:HasWeapon("weapon_drp_keys") then suspect:SelectWeapon("weapon_drp_keys") end
		DRP.Net.Notify(officer, "You took custody of " .. suspect:DRPName() .. ".", 1)
		return true
	end
	local allowed, source = DRP.Incidents.Can(officer, suspect, DRP.IncidentAction.CUFF)
	if not allowed then source = taserCustodyAuthority(officer, suspect) allowed = source ~= nil end
	if not allowed then DRP.Incidents.Deny(officer, suspect, DRP.IncidentAction.CUFF) return false end
	if not Legal.IsTased(suspect) then DRP.Net.Notify(officer, "Use the taser before applying handcuffs.", 3) return false end
	local activeWeapon = suspect:GetActiveWeapon()
	Legal.Cuffed[suspect] = {
		officer = officer,
		source = source,
		escorting = true,
		cuffedAt = CurTime(),
		weaponClass = IsValid(activeWeapon) and activeWeapon:GetClass() or nil
	}
	local custodyDeadline = CurTime() + 120
	DRP.Incidents.SetDeadline(source, custodyDeadline, true)
	for _, grants in pairs(source.permissions or {}) do
		for _, grant in ipairs(grants) do if grant.target == suspect then grant.expires = custodyDeadline end end
	end
	suspect:SetNW2Bool("DRPCuffed", true)
	suspect:SetNW2Entity("DRPCuffedBy", officer)
	if DRP.PVP and DRP.PVP.CustodySecured then DRP.PVP.CustodySecured(source, officer, suspect) end
	hook.Run("DRPPoliceCustodyStarted", officer, suspect)
	if suspect:HasWeapon("weapon_drp_keys") then
		suspect:SelectWeapon("weapon_drp_keys")
	else
		suspect:SetActiveWeapon(NULL)
	end
	Legal.TasedCustody[suspect] = nil
	DRP.Incidents.AddEvidence(source, "suspect_handcuffed", officer, suspect, "Suspect placed in police custody")
	DRP.Net.Notify(suspect, "You were handcuffed by " .. officer:DRPName() .. ". Follow the officer to the jailer.", 2)
	DRP.Net.Notify(officer, suspect:DRPName() .. " is cuffed and being escorted. Bring them to the jailer.", 1)
	if DRP.Audit then DRP.Audit.Log(officer, "suspect_handcuffed", suspect, "incident #" .. source.id) end
	return true
end

function Legal.CuffAimed(officer)
	local suspect = cuffCandidate(officer)
	if not suspect then
		DRP.Net.Notify(officer, "No taser-authorized suspect is close enough and in front of you.", 3)
		return false
	end
	return Legal.Cuff(officer, suspect)
end

function Legal.ToggleEscortAimed(officer)
	local suspect = aimedPlayer(officer, 140)
	local record = suspect and Legal.Cuffed[suspect]
	if not record then DRP.Net.Notify(officer, "Aim at a handcuffed player.", 3) return false end
	if not officer:DRPJob().isPolice then return false end
	if record.officer ~= officer then
		local allowed, source = DRP.Incidents.Can(officer, suspect, DRP.IncidentAction.CUFF)
		if not allowed then DRP.Incidents.Deny(officer, suspect, DRP.IncidentAction.CUFF) return false end
		record.source = source
	end
	record.officer = officer
	record.escorting = not record.escorting
	suspect:SetNW2Entity("DRPCuffedBy", record.escorting and officer or NULL)
	DRP.Net.Notify(officer, record.escorting and ("Escorting " .. suspect:DRPName() .. ".") or ("Released escort of " .. suspect:DRPName() .. "; cuffs remain on."), 0)
	return true
end

function Legal.UncuffAimed(officer)
	local suspect = aimedPlayer(officer, 120)
	local record = suspect and Legal.Cuffed[suspect]
	if not record or not officer:DRPJob().isPolice then return false end
	Legal.ClearCuffs(suspect)
	DRP.Net.Notify(officer, "Removed " .. suspect:DRPName() .. "'s handcuffs.", 1)
	if record.source and DRP.Incidents.Get(record.source.id) then DRP.Incidents.AddEvidence(record.source, "suspect_uncuffed", officer, suspect, "Released from physical custody") end
	return true
end

function Legal.Arrest(officer, suspect, jailer)
	if not IsValid(officer) or not officer:DRPJob().isPolice or not IsValid(suspect) or Legal.Arrested[suspect] then return false end
	if not IsValid(jailer) or not jailer:GetNW2Bool("DRPJailer", false) or jailer:GetPos():DistToSqr(suspect:GetPos()) > 32400 then DRP.Net.Notify(officer, "Bring the handcuffed suspect within range of the jailer.", 3) return false end
	local cuffRecord = Legal.Cuffed[suspect]
	if not cuffRecord then DRP.Net.Notify(officer, "The suspect must be handcuffed before booking.", 3) return false end
	-- A valid cuff record is the server-owned custody receipt. Once this officer
	-- has successfully tased and cuffed the suspect, an earlier PvP transition or
	-- expiring damage grant cannot invalidate booking at the jailer.
	local source = cuffRecord.source
	local custodyAuthorized = cuffRecord.officer == officer and source and DRP.Incidents.Get(source.id) == source
	if not custodyAuthorized then
		local allowed
		allowed, source = DRP.Incidents.Can(officer, suspect, DRP.IncidentAction.ARREST)
		if not allowed then DRP.Incidents.Deny(officer, suspect, DRP.IncidentAction.ARREST) return false end
	end
	for _, weapon in ipairs(suspect:GetWeapons()) do
		local class = weapon:GetClass()
		if not preservedWeapons[class] and class ~= "weapon_crowbar" then DRP.JobEntityService.StoreEvidence(officer, suspect, class, source) end
	end
	-- Detention is an outcome/state of the originating incident. Do not create
	-- a second "arrest" incident, otherwise the HUD shows duplicate records and
	-- XP cannot be attributed cleanly to the original suspect/victim pair.
	local custodyDeadline = CurTime() + Legal.ArrestDuration
	Legal.Arrested[suspect] = { sourceID = source.id, officer = officer, startedAt = CurTime(), deadline = custodyDeadline }
	DRP.Incidents.AddEvidence(source, "suspect_detained", officer, suspect, "Transferred to evidence storage")
	-- Booking is the terminal outcome of the originating incident. Custody is
	-- tracked separately, so it cannot produce a duplicate incident or XP award.
	DRP.Incidents.Resolve(source, "suspect_arrested", "Suspect booked by " .. officer:DRPName())
	-- Booking is a global legal reset for this life. Resolve every other
	-- primary incident involving the suspect after the source arrest receipt
	-- has been committed.
	DRP.Incidents.ClearPlayer(suspect, "suspect_arrested", "Active incidents cleared by arrest", {
		officer = officer,
		source = source
	})
	DRP.Deadlines.Schedule(custodyKey(suspect), custodyDeadline, function()
		if IsValid(suspect) and Legal.Arrested[suspect] then Legal.Release(suspect, "sentence served") end
	end)
	Legal.ClearCuffs(suspect, true)
	Legal.TasedUntil[suspect] = nil
	Legal.TasedCustody[suspect] = nil
	suspect:SetNW2Float("DRPTasedUntil", 0)
	suspect:StripWeapons()
	suspect:Lock()
	suspect:SetNW2Bool("DRPArrested", true)
	local saved = util.JSONToTable(file.Read("darkrp/jail_" .. game.GetMap() .. ".json", "DATA") or "")
	if saved and saved.x then suspect:SetPos(Vector(saved.x, saved.y, saved.z)) end
	DRP.Net.Notify(suspect, "You are arrested for " .. Legal.ArrestDuration .. " seconds.", 2)
	return true
end

function Legal.ArrestAimed(officer)
	DRP.Net.Notify(officer, "Arrests are processed by bringing a handcuffed suspect to the jailer and pressing E on the jailer.", 0)
	return false
end

function Legal.BookAtJailer(officer, jailer)
	if not IsValid(officer) or not officer:DRPJob().isPolice or not IsValid(jailer) then return false end
	local closest, closestDistance
	for suspect, record in pairs(Legal.Cuffed) do
		if IsValid(suspect) and IsValid(record.officer) and record.officer == officer then
			local distance = jailer:GetPos():DistToSqr(suspect:GetPos())
			if distance <= 32400 and (not closestDistance or distance < closestDistance) then closest, closestDistance = suspect, distance end
		end
	end
	if not closest then DRP.Net.Notify(officer, "Bring the suspect you are escorting closer to the jailer.", 3) return false end
	return Legal.Arrest(officer, closest, jailer)
end

function Legal.Release(suspect, reason)
	local record = Legal.Arrested[suspect]
	if not record then return false end
	Legal.Arrested[suspect] = nil
	DRP.Deadlines.Cancel(custodyKey(suspect))
	if IsValid(suspect) then
		suspect:UnLock()
		suspect:SetNW2Bool("DRPArrested", false)
		GAMEMODE:PlayerLoadout(suspect)
		DRP.Net.Notify(suspect, "Released: " .. tostring(reason or "sentence complete") .. ".", 1)
	end
	return true
end

function Legal.Search(officer, suspect)
	if not DRP.Incidents.Authorize(officer, suspect, DRP.IncidentAction.SEARCH) then return false end
	local weapons = {}
	for _, weapon in ipairs(suspect:GetWeapons()) do weapons[#weapons + 1] = weapon:GetClass() end
	DRP.Net.Notify(officer, suspect:DRPName() .. " — Hands: " .. DRP.Inventory.Describe(suspect) .. " — weapons: " .. (#weapons > 0 and table.concat(weapons, ", ") or "none"), 0)
	return true
end

function Legal.GrantLicense(mayor, target, enabled)
	if mayor ~= DRP.Government.CurrentMayor() or not IsValid(target) then return false end
	target:SetNW2Bool("DRPGunLicense", enabled == true)
	hook.Run("DRPGunLicenseChanged", target, enabled == true)
	DRP.Net.Notify(target, enabled and "The Mayor granted you a weapon licence." or "The Mayor revoked your weapon licence.", enabled and 1 or 2)
	if DRP.Audit then DRP.Audit.Log(mayor, enabled and "weapon_license_granted" or "weapon_license_revoked", target) end
	return true
end

function Legal.Bail(ply)
	local record = Legal.Arrested[ply]
	if not record then return false end
	local elapsed = CurTime() - record.startedAt
	if elapsed < 30 then DRP.Net.Notify(ply, "Bail becomes available after 30 seconds.", 3) return false end
	local cost = 500
	if not DRP.Economy.Take(ply, cost, "bail") then return false end
	if DRP.Government then DRP.Government.DepositTreasury(cost, "bail payment", true) end
	return Legal.Release(ply, "bail paid")
end

function Legal.SetJail(ply)
	if not DRP.Admin or not DRP.Admin.Has(ply, "doors") then return false end
	file.CreateDir("darkrp")
	local pos = ply:GetPos()
	file.Write("darkrp/jail_" .. game.GetMap() .. ".json", util.TableToJSON({ x = pos.x, y = pos.y, z = pos.z }))
	return true
end

local function hasRoof(ply)
	local trace = util.TraceLine({ start = ply:GetPos() + Vector(0, 0, 16), endpos = ply:GetPos() + Vector(0, 0, 4096), filter = ply, mask = MASK_SOLID })
	return trace.Hit and not trace.HitSky
end

local function sendLockdownState(recipient)
	local active = Legal.Lockdown ~= nil and DRP.Incidents.Get(Legal.Lockdown.id) ~= nil
	net.Start(lockdownStateMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(active)
	net.WriteString(active and string.sub(Legal.LockdownReason or "Public emergency", 1, 120) or "")
	net.WriteUInt(active and math.Clamp(math.floor(CurTime() - Legal.LockdownStarted), 0, 65535) or 0, 16)
	if IsValid(recipient) then net.Send(recipient) else net.Broadcast() end
	if DRP.Net.Record then DRP.Net.Record(5 + #(active and Legal.LockdownReason or ""), IsValid(recipient) and 1 or player.GetCount()) end
end

function Legal.StartLockdown(mayor, reason)
	if mayor ~= DRP.Government.CurrentMayor() or Legal.Lockdown then return false end
	reason = string.sub(string.Trim(tostring(reason or "Public emergency")), 1, 120)
	local incident = DRP.Incidents.Create("lockdown", { reason = "LOCKDOWN: " .. reason, instigator = mayor, victim = mayor, participants = { mayor = mayor } })
	if not incident then return false end
	Legal.Lockdown, Legal.LockdownStarted = incident, CurTime()
	Legal.LockdownReason = reason
	sendLockdownState()
	timer.Create("DRP.Legal.LockdownScan", 60, 1, function()
		if not Legal.Lockdown then return end
		Legal:ScanLockdown()
		if Legal.Lockdown then timer.Create("DRP.Legal.LockdownScan", 0.5, 0, function() Legal:ScanLockdown() end) end
	end)
	return true
end

function Legal.EndLockdown(mayor, reason)
	if mayor ~= DRP.Government.CurrentMayor() and (not DRP.Admin or not DRP.Admin.Has(mayor, "server_interactions")) then return false end
	if not Legal.Lockdown then return false end
	return Legal.AbortLockdown(reason or "Mayor ended lockdown")
end

function Legal.AbortLockdown(reason)
	if not Legal.Lockdown then return false end
	for suspect, incident in pairs(Legal.Homeless) do if DRP.Incidents.Get(incident.id) then DRP.Incidents.Resolve(incident, "lockdown_ended", "Lockdown ended") end Legal.Homeless[suspect] = nil end
	if DRP.Incidents.Get(Legal.Lockdown.id) then DRP.Incidents.Resolve(Legal.Lockdown, "ended", reason or "Lockdown ended") end
	Legal.Lockdown = nil
	Legal.LockdownReason = nil
	sendLockdownState()
	timer.Remove("DRP.Legal.LockdownScan")
	return true
end

function Legal:ScanLockdown()
	if not self.Lockdown then return end
	if not DRP.Incidents.Get(self.Lockdown.id) then self.AbortLockdown("Lockdown record ended") return end
	if CurTime() - self.LockdownStarted < 60 then return end
	local players = DRP.Players.List
	for _ = 1, math.min(self.LockdownBudget, #players) do
		self.LockdownCursor = (self.LockdownCursor % #players) + 1
		local suspect = players[self.LockdownCursor]
		if suspect:DRPReady() and suspect:DRPJobID() == DRP.Job.CITIZEN then
			local roof = hasRoof(suspect)
			local incident = self.Homeless[suspect]
			if not roof and not incident then
				incident = DRP.Incidents.Create("lockdown_homelessness", { reason = "Citizen remained outdoors more than one minute into lockdown", instigator = suspect, victim = suspect, participants = { suspect = suspect } })
				self.Homeless[suspect] = incident
				grantPolice(incident, suspect, "Lockdown shelter offence", nil)
			elseif not roof and incident then
				grantPolice(incident, suspect, "Lockdown shelter offence", nil)
			elseif roof and incident then
				if DRP.Incidents.Get(incident.id) then DRP.Incidents.Resolve(incident, "sheltered", "Citizen moved under a roof") end
				self.Homeless[suspect] = nil
			end
		elseif self.Homeless[suspect] then
			local incident = self.Homeless[suspect]
			if DRP.Incidents.Get(incident.id) then DRP.Incidents.Resolve(incident, "role_changed", "Citizen role requirement ended") end
			self.Homeless[suspect] = nil
		end
	end
end

function Legal.PlayerReady(ply)
	sendLockdownState(ply)
end

function Legal:Start() end
function Legal:Stop() timer.Remove("DRP.Legal.LockdownScan") end

function Legal.ApplyCommand(ply, command)
	if Legal.Arrested[ply] then command:ClearMovement() command:ClearButtons() return end
	if Legal.IsTased(ply) then command:ClearMovement() command:ClearButtons() return end
	if Legal.Cuffed[ply] then
		command:RemoveKey(IN_ATTACK)
		command:RemoveKey(IN_ATTACK2)
		command:RemoveKey(IN_RELOAD)
		command:RemoveKey(IN_USE)
		command:RemoveKey(IN_JUMP)
		command:RemoveKey(IN_SPEED)
		local safeWeapon = ply:GetWeapon("weapon_drp_keys")
		if IsValid(safeWeapon) then command:SelectWeapon(safeWeapon) end
	end
end

function Legal.ApplyMove(ply, move)
	local record = Legal.Cuffed[ply]
	if not record then return end
	local officer = record.escorting and record.officer or nil
	if not IsValid(officer) or not officer:Alive() or not officer:DRPJob().isPolice then
		record.escorting = false
		ply:SetNW2Entity("DRPCuffedBy", NULL)
		move:SetMaxSpeed(move:GetMaxSpeed() * 0.35)
		move:SetMaxClientSpeed(move:GetMaxClientSpeed() * 0.35)
		return
	end

	local targetPosition = officer:GetPos() - officer:GetForward() * Legal.EscortDistance
	local offset = targetPosition - ply:GetPos()
	local distance = offset:Length()

	if distance > Legal.EscortSnapDistance then
		local placement = util.TraceHull({
			start = targetPosition + Vector(0, 0, 8),
			endpos = targetPosition,
			mins = ply:OBBMins(),
			maxs = ply:OBBMaxs(),
			filter = { ply, officer },
			mask = MASK_PLAYERSOLID
		})
		if not placement.StartSolid then
			move:SetOrigin(placement.Hit and placement.HitPos or targetPosition)
			offset = vector_origin
			distance = 0
		end
	end

	if distance > 12 then
		local officerVelocity = officer:GetVelocity()
		local correction = offset:GetNormalized() * math.Clamp(distance * 7, 100, 520)
		local tetherVelocity = officerVelocity + correction
		local tetherSpeed = math.max(420, tetherVelocity:Length2D() + 40)
		move:SetMaxSpeed(tetherSpeed)
		move:SetMaxClientSpeed(tetherSpeed)
		move:SetVelocity(tetherVelocity)
	else
		move:SetMaxSpeed(420)
		move:SetMaxClientSpeed(420)
		move:SetVelocity(officer:GetVelocity())
	end
end

hook.Add("ShouldCollide", "DRP.Legal.EscortCollision", function(first, second)
	if not IsValid(first) or not IsValid(second) or not first:IsPlayer() or not second:IsPlayer() then return end
	local firstRecord, secondRecord = Legal.Cuffed[first], Legal.Cuffed[second]
	if (firstRecord and firstRecord.escorting and firstRecord.officer == second) or (secondRecord and secondRecord.escorting and secondRecord.officer == first) then return false end
end)

hook.Add("PlayerDisconnected", "DRP.Legal.Disconnect", function(ply)
	DRP.Deadlines.Cancel(custodyKey(ply))
	Legal.Arrested[ply] = nil
	Legal.Homeless[ply] = nil
	Legal.TasedUntil[ply] = nil
	Legal.TasedCustody[ply] = nil
	Legal.ClearCuffs(ply, true)
	for suspect, record in pairs(Legal.Cuffed) do if record.officer == ply then Legal.ClearCuffs(suspect) end end
end)
hook.Add("PlayerDeath", "DRP.Legal.CustodyDeath", function(ply)
	Legal.TasedUntil[ply] = nil
	Legal.TasedCustody[ply] = nil
	ply:SetNW2Float("DRPTasedUntil", 0)
	Legal.ClearCuffs(ply, true)
	for suspect, record in pairs(Legal.Cuffed) do if record.officer == ply then Legal.ClearCuffs(suspect) end end
end)
hook.Add("DRPJobChanged", "DRP.Legal.CustodyJob", function(ply)
	if Legal.Arrested[ply] then Legal.Release(ply, "role changed") end
	Legal.TasedUntil[ply] = nil
	Legal.TasedCustody[ply] = nil
	ply:SetNW2Float("DRPTasedUntil", 0)
	Legal.ClearCuffs(ply, true)
	for suspect, record in pairs(Legal.Cuffed) do if record.officer == ply then Legal.ClearCuffs(suspect) end end
end)
hook.Add("DRPIncidentResolved", "DRP.Legal.WantedRefresh", function(incident)
	if incident.type ~= "legal_warrant" and incident.type ~= "lockdown_homelessness" and incident.type ~= "police_weapon_sighting" then return end
	timer.Simple(0, function()
		for _, participant in ipairs(incident.participants) do
			if participant.role == "suspect" and IsValid(participant.player) then
				local stillWanted = false
					for _, active in pairs(DRP.Incidents.ByPlayer[participant.player] or {}) do
					for _, grant in ipairs(active.permissions[DRP.IncidentAction.ARREST] or {}) do if grant.target == participant.player then stillWanted = true break end end
					if stillWanted then break end
				end
				if not stillWanted then participant.player:SetNW2String("DRPWantedReason", "") end
			end
		end
	end)
end)
local function escalateLockdownResistance(suspect, trigger)
	local offence = Legal.Homeless[suspect]
	if not offence then return end
	if (Legal.LastResistance[suspect] or 0) > CurTime() then return end
	Legal.LastResistance[suspect] = CurTime() + 0.5
	DRP.Incidents.AddEvidence(offence, "armed_resistance", suspect, nil, trigger)
	for _, officer in ipairs(policePlayers()) do DRP.PVP.Enable(suspect, officer, "lockdown_resistance_" .. offence.id, 30, "Armed resistance during lockdown") end
end
hook.Add("EntityFireBullets", "DRP.Legal.LockdownFire", function(entity) if entity:IsPlayer() then escalateLockdownResistance(entity, "weapon fired") end end)
hook.Add("KeyPress", "DRP.Legal.LockdownAttack", function(ply, key) if key == IN_ATTACK then escalateLockdownResistance(ply, "attack attempted") end end)
hook.Add("PlayerSpawn", "DRP.Legal.ArrestRespawn", function(ply)
	local incident = Legal.Arrested[ply]
	if not incident then return end
	timer.Simple(0, function()
		if not IsValid(ply) or not Legal.Arrested[ply] then return end
		ply:StripWeapons()
		ply:Lock()
		local saved = util.JSONToTable(file.Read("darkrp/jail_" .. game.GetMap() .. ".json", "DATA") or "")
		if saved and saved.x then ply:SetPos(Vector(saved.x, saved.y, saved.z)) end
	end)
end)
