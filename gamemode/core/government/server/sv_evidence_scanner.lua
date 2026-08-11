local Legal = assert(DRP and DRP.Legal, "legal service must load before evidence scanner")

local Scanner = {
	Cooldown = 20,
	Range = 1400,
	MinimumFacing = 0.35,
	MaximumCandidates = 96,
	MaximumTraces = 40,
	MaximumFindings = 16,
	NextCapture = setmetatable({}, { __mode = "k" }),
	RequestMessage = "drp_legal_tablet_request_v1",
	ResponseMessage = "drp_legal_tablet_response_v1"
}

Legal.EvidenceScanner = Scanner
DRP.Services.Register("evidence_scanner", Scanner)
util.AddNetworkString(Scanner.RequestMessage)
util.AddNetworkString(Scanner.ResponseMessage)

local illegalClasses = {
	drp_drug = "Controlled drug",
	drp_weapon_crate = "Weapon crate",
	drp_coca_pot = "Cocaine growing equipment",
	drp_cocaine_bucket = "Cocaine processing equipment",
	drp_cocaine_petroleum = "Cocaine production chemical",
	drp_cocaine_hotplate = "Cocaine processing equipment",
	drp_narcotics_table = "Narcotics production table"
}

local illegalPrefixes = {
	zwf_ = "Illegal cannabis equipment",
	zmlab2_ = "Illegal methamphetamine equipment"
}

local excludedClasses = {
	zwf_npc = true,
	zwf_buyer = true,
	zmlab2_npc = true,
	zmlab2_dropoff = true,
	zmlab2_dropoffpoint = true
}

Scanner.IllegalClasses = illegalClasses
Scanner.IllegalPrefixes = illegalPrefixes
Scanner.ExcludedClasses = excludedClasses

local function clean(value, maximum)
	return string.sub(string.Trim(tostring(value or "")), 1, maximum or 160)
end

local function roleAllowsTablet(ply)
	if not IsValid(ply) or not ply:DRPReady() or not ply.DRPJob then return false end
	local job = ply:DRPJob()
	return istable(job) and (job.isPolice == true or job.key == "mayor")
end

local function scannerOfficer(ply)
	if not roleAllowsTablet(ply) or not ply:Alive() then return false end
	local job = ply:DRPJob()
	if job.isPolice ~= true then return false end
	if DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(ply) then return false end
	if not (DRP.Phone and DRP.Phone.HasPoliceTerminal and DRP.Phone:HasPoliceTerminal(ply)) then return false end
	local weapon = ply:GetActiveWeapon()
	return IsValid(weapon) and weapon:GetClass() == "weapon_drp_police_tablet"
end

local function illegalKind(entity)
	if not IsValid(entity) then return nil end
	local class = string.lower(entity:GetClass())
	if excludedClasses[class] then return nil end
	if illegalClasses[class] then return illegalClasses[class] end
	for prefix, description in pairs(illegalPrefixes) do
		if string.StartWith(class, prefix) then return description end
	end
end

function Scanner:IllegalKind(entity)
	return illegalKind(entity)
end

local function onlineOwner(entity, lease)
	local owner = DRP.Props and DRP.Props.Owner and DRP.Props.Owner(entity)
	if IsValid(owner) and owner:IsPlayer() then
		if DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(owner) then return nil end
		return owner
	end
	local ownerID = DRP.Props and DRP.Props.OwnerID and DRP.Props.OwnerID(entity)
	if (not ownerID or ownerID == "") and istable(lease) then ownerID = lease.owner_id end
	if not ownerID or ownerID == "" then return nil end
	owner = DRP.Players and DRP.Players.Online and DRP.Players.Online(ownerID) or nil
	if IsValid(owner) and DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(owner) then return nil end
	return owner
end

local function targetProperty(officer)
	local trace = officer:GetEyeTrace()
	if not trace or officer:EyePos():DistToSqr(trace.HitPos) > Scanner.Range * Scanner.Range then return nil end
	local definition, lease, propertyID
	if IsValid(trace.Entity) then
		propertyID = tonumber(trace.Entity.DRPPropertyID or trace.Entity.DRPIndexedPropertyID)
		if propertyID then definition, lease = DRP.Properties.Get(propertyID) end
	end
	if IsValid(trace.Entity) and DRP.Doors and DRP.Doors.IsDoor(trace.Entity) then
		definition, lease = DRP.Properties.ForDoor(trace.Entity)
		propertyID = definition and definition.id
	end
	if not definition then
		definition, propertyID = DRP.Properties:LocationAt(trace.HitPos)
		lease = propertyID and DRP.Properties.Leases[propertyID] or nil
	end
	return definition, lease, tonumber(propertyID), trace
end

local function visible(officer, entity)
	if officer.TestPVS and not officer:TestPVS(entity) then return false end
	local eye, center = officer:EyePos(), entity:WorldSpaceCenter()
	local offset = center - eye
	if offset:LengthSqr() > Scanner.Range * Scanner.Range or offset:LengthSqr() <= 1 then return false end
	if officer:GetAimVector():Dot(offset:GetNormalized()) < Scanner.MinimumFacing then return false end
	local trace = util.TraceLine({
		start = eye,
		endpos = center,
		filter = officer,
		mask = MASK_VISIBLE_AND_NPCS
	})
	return not trace.Hit or trace.Entity == entity or trace.Fraction >= 0.985
end

local function propertyContains(entity, propertyID)
	if tonumber(entity.DRPPropertyID or entity.DRPIndexedPropertyID) == propertyID then return true end
	local _, locatedID = DRP.Properties:LocationAt(entity:WorldSpaceCenter())
	return tonumber(locatedID) == propertyID
end

local function summaryFor(findings)
	local counts, ordered = {}, {}
	for _, finding in ipairs(findings) do counts[finding.kind] = (counts[finding.kind] or 0) + 1 end
	for name, count in pairs(counts) do ordered[#ordered + 1] = count .. "× " .. name end
	table.sort(ordered)
	return clean(table.concat(ordered, ", "), 150)
end

function Scanner:BuildWarrants()
	local result = {}
	for _, incident in pairs((DRP.Incidents.ByType and DRP.Incidents.ByType.legal_warrant) or {}) do
		if incident.state == "approval_pending" or incident.state == "active" then
			local suspect, officer
			for _, participant in ipairs(incident.participants or {}) do
				if participant.role == "suspect" then suspect = participant.player
				elseif participant.role == "officer" then officer = participant.player end
			end
			result[#result + 1] = {
				id = incident.id,
				state = clean(incident.state, 32),
				reason = clean(incident.metadata and incident.metadata.requested_reason or incident.reason, 160),
				suspect = IsValid(suspect) and clean(suspect:DRPName(), 64) or "Unavailable suspect",
				suspect_id = IsValid(suspect) and suspect:SteamID64() or "",
				officer = IsValid(officer) and clean(officer:DRPName(), 64) or "Unavailable officer",
				property_id = math.max(0, math.floor(tonumber(incident.metadata and incident.metadata.property_id) or 0)),
				property = clean(incident.metadata and incident.metadata.property_name, 64),
				scanner = incident.metadata and incident.metadata.scanner_evidence == true,
				created = math.floor(tonumber(incident.startedUnix) or os.time()),
				remaining = math.max(0, math.ceil((tonumber(incident.deadline) or CurTime()) - CurTime()))
			}
		end
	end
	table.sort(result, function(first, second) return first.id > second.id end)
	while #result > 48 do table.remove(result) end
	return result
end

function Scanner:Send(ply, mode, payload)
	local encoded = util.TableToJSON({ mode = mode, data = payload or {} })
	local compressed = encoded and util.Compress(encoded)
	if not compressed or #compressed > 60000 then return false end
	net.Start(self.ResponseMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(#compressed, 16)
	net.WriteData(compressed, #compressed)
	net.Send(ply)
	if DRP.Net and DRP.Net.Record then DRP.Net.Record(#compressed + 3) end
	return true
end

function Scanner:SendWarrants(ply)
	if not roleAllowsTablet(ply) then return false end
	return self:Send(ply, 0, { warrants = self:BuildWarrants() })
end

function Scanner:BroadcastWarrants()
	local recipients = {}
	for _, ply in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do
		if roleAllowsTablet(ply) then recipients[#recipients + 1] = ply end
	end
	if #recipients == 0 then return end
	local warrants = self:BuildWarrants()
	for _, ply in ipairs(recipients) do self:Send(ply, 0, { warrants = warrants }) end
end

function Scanner:Capture(officer)
	if not scannerOfficer(officer) then
		return self:Send(officer, 1, { ok = false, message = "Evidence scanner access denied." })
	end
	local now = CurTime()
	local remaining = math.max(0, (self.NextCapture[officer] or 0) - now)
	if remaining > 0 then
		return self:Send(officer, 1, { ok = false, remaining = math.ceil(remaining), message = "Scanner camera is recharging." })
	end
	if not DRP.Properties or not DRP.Properties.LocationAt then
		return self:Send(officer, 1, { ok = false, message = "Property authority is not ready." })
	end
	local definition, lease, propertyID = targetProperty(officer)
	if not definition or not propertyID or not istable(definition.build_zones) or #definition.build_zones == 0 then
		return self:Send(officer, 1, { ok = false, message = "Aim at a configured property boundary or grouped door." })
	end

	-- Consume the camera cooldown only after a valid property has been acquired.
	self.NextCapture[officer] = now + self.Cooldown
	local findings, traces, candidates = {}, 0, 0
	local seen = {}
	for _, entity in ipairs(ents.FindInSphere(officer:EyePos(), self.Range)) do
		if candidates >= self.MaximumCandidates or #findings >= self.MaximumFindings or traces >= self.MaximumTraces then break end
		if IsValid(entity) and not seen[entity] then
			seen[entity] = true
			local kind = illegalKind(entity)
			if kind and propertyContains(entity, propertyID) then
				candidates = candidates + 1
				traces = traces + 1
				if visible(officer, entity) then
					findings[#findings + 1] = {
						entity = entity,
						class = clean(entity:GetClass(), 64),
						kind = kind,
						owner = onlineOwner(entity, lease)
					}
				end
			end
		end
	end

	local byOwner, display = {}, {}
	for _, finding in ipairs(findings) do
		display[#display + 1] = { class = finding.class, kind = finding.kind,
			owner = IsValid(finding.owner) and finding.owner:DRPName() or "Owner unavailable" }
		if IsValid(finding.owner) and finding.owner ~= officer then
			byOwner[finding.owner] = byOwner[finding.owner] or {}
			byOwner[finding.owner][#byOwner[finding.owner] + 1] = finding
		end
	end

	local warrants = {}
	for suspect, ownedFindings in pairs(byOwner) do
		local evidenceSummary = summaryFor(ownedFindings)
		local reason = "Evidence scan at " .. clean(definition.name or ("Property #" .. propertyID), 48) .. ": " .. evidenceSummary
		local accepted, incident, status = Legal.RequestWarrant(officer, suspect, reason, {
			scanner_evidence = true,
			property_id = propertyID,
			property_name = clean(definition.name, 64),
			evidence_summary = evidenceSummary,
			finding_count = #ownedFindings
		})
		if accepted and incident then
			warrants[#warrants + 1] = { id = incident.id, suspect = suspect:DRPName(), status = status }
			DRP.Incidents.AddEvidence(incident, "evidence_scanned", officer, suspect,
				"Property #" .. propertyID .. ": " .. evidenceSummary)
		end
	end

	if DRP.Audit then
		DRP.Audit.Log(officer, "property_evidence_scan", nil,
			"property #" .. propertyID .. " visible_illegals=" .. #findings .. " warrants=" .. #warrants)
	end
	self:Send(officer, 1, {
		ok = true,
		remaining = self.Cooldown,
		property_id = propertyID,
		property = clean(definition.name or ("Property #" .. propertyID), 64),
		message = #findings > 0 and ("Captured " .. #findings .. " visible illegal item(s).") or "No visible illegal items were captured.",
		findings = display,
		warrants = warrants
	})
	self:BroadcastWarrants()
	return true
end

DRP.Net.Receive(Scanner.RequestMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not DRP.Net.Allow(ply, "legal_tablet", 0.25, 4) then return end
	local mode = net.ReadUInt(2)
	if mode == 1 then Scanner:Capture(ply) else Scanner:SendWarrants(ply) end
end)

hook.Add("DRPWarrantChanged", "DRP.EvidenceScanner.Warrants", function()
	timer.Create("DRP.EvidenceScanner.WarrantBroadcast", 0.05, 1, function() Scanner:BroadcastWarrants() end)
end)

hook.Add("DRPIncidentResolved", "DRP.EvidenceScanner.WarrantResolved", function(incident)
	if incident.type == "legal_warrant" then hook.Run("DRPWarrantChanged", incident, "resolved") end
end)

hook.Add("PlayerDisconnected", "DRP.EvidenceScanner.Cooldown", function(ply)
	Scanner.NextCapture[ply] = nil
end)
