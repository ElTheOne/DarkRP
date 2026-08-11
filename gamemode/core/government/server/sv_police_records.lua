local PoliceRecords = {
	Protocol = 1,
	RequestMessage = "drp_phone_police_records_request_v1",
	ResponseMessage = "drp_phone_police_records_response_v1",
	Path = "darkrp/police_records.jsonl.txt",
	Capacity = 1000,
	DetailLimit = 40,
	Records = {},
	ByIncident = {},
	BySubject = {}
}

DRP.PoliceRecords = PoliceRecords
DRP.Services.Register("police_records", PoliceRecords)

util.AddNetworkString(PoliceRecords.RequestMessage)
util.AddNetworkString(PoliceRecords.ResponseMessage)

local inherentlyKnown = {
	legal_warrant = true,
	police_weapon_sighting = true,
	lockdown_homelessness = true
}

local policeEvidence = {
	weapon_sighted = true,
	forced_drugging_witnessed = true,
	suspect_tased = true,
	suspect_handcuffed = true,
	suspect_detained = true,
	suspect_arrested = true,
	warrant_requested = true,
	warrant_approved = true,
	reported_to_police = true,
	evidence_stored = true
}

local function clean(value, limit)
	return string.sub(string.Trim(tostring(value or "")), 1, limit or 160)
end

local function validSteamID(value)
	value = tostring(value or "")
	return value:match("^7656119%d+$") ~= nil and value or ""
end

local function isPoliceRole(role)
	role = string.lower(tostring(role or ""))
	return role:find("officer", 1, true) ~= nil
		or role:find("police", 1, true) ~= nil
end

local function isSuspectRole(role)
	role = string.lower(tostring(role or ""))
	return role:find("suspect", 1, true) ~= nil
		or role:find("offender", 1, true) ~= nil
		or role:find("instigator", 1, true) ~= nil
		or role:find("attacker", 1, true) ~= nil
		or role:find("mugger", 1, true) ~= nil
		or role:find("raider", 1, true) ~= nil
end

local function rolePriority(role)
	if role == "suspect" then return 4 end
	if role == "instigator" then return 3 end
	if role == "victim" then return 2 end
	return 1
end

local function addSubject(subjects, steamID, name, role)
	steamID = validSteamID(steamID)
	if steamID == "" then return end
	role = clean(role or "involved", 24)
	local existing = subjects[steamID]
	if existing and rolePriority(existing.role) >= rolePriority(role) then return end
	subjects[steamID] = {
		steam_id = steamID,
		name = clean(name ~= "" and name or steamID, 64),
		role = role
	}
end

function PoliceRecords:IsKnown(incident, receipt)
	local incidentType = tostring((receipt and receipt.type) or (incident and incident.type) or "")
	if inherentlyKnown[incidentType] then return true end
	if incident and incident.metadata and incident.metadata.police_witnessed == true then return true end

	for _, participant in ipairs((receipt and receipt.participants) or (incident and incident.participantHistory) or {}) do
		if isPoliceRole(participant.role) then return true end
	end
	for _, evidence in ipairs((receipt and receipt.evidence) or (incident and incident.evidence) or {}) do
		local event = string.lower(tostring(evidence.event or ""))
		if policeEvidence[event]
			or event:find("police_", 1, true)
			or event:find("_witnessed", 1, true)
			or event:find("warrant", 1, true)
			or event:find("arrest", 1, true) then
			return true
		end
	end
	return false
end

function PoliceRecords:CompactReceipt(receipt)
	if not istable(receipt) then return nil end
	local subjects = {}
	local incidentType = tostring(receipt.type or "")

	for _, participant in ipairs(receipt.participants or {}) do
		if not isPoliceRole(participant.role) then
			local role = isSuspectRole(participant.role) and "suspect" or clean(participant.role, 24)
			addSubject(subjects, participant.steam_id, participant.name, role)
		end
	end

	local primarySuspect = inherentlyKnown[incidentType] and "victim" or "instigator"
	if primarySuspect == "victim" then
		addSubject(subjects, receipt.victim_id, receipt.victim, "suspect")
	else
		addSubject(subjects, receipt.instigator_id, receipt.instigator, "instigator")
	end
	-- Victims remain searchable, but are explicitly labelled so a victim is
	-- never presented as having committed the infraction.
	addSubject(subjects, receipt.victim_id, receipt.victim,
		primarySuspect == "victim" and "suspect" or "victim")

	local subjectList = {}
	for _, subject in pairs(subjects) do subjectList[#subjectList + 1] = subject end
	table.sort(subjectList, function(first, second) return first.steam_id < second.steam_id end)
	if #subjectList == 0 then return nil end

	local evidence = {}
	local startAt = math.max(1, #(receipt.evidence or {}) - 7)
	for index = startAt, #(receipt.evidence or {}) do
		local item = receipt.evidence[index]
		evidence[#evidence + 1] = {
			time = math.floor(tonumber(item.unix) or tonumber(receipt.resolved_at) or os.time()),
			event = clean(item.event, 40),
			actor = clean(item.actor, 64),
			target = clean(item.target, 64),
			detail = clean(item.detail, 160)
		}
	end

	return {
		id = math.max(0, math.floor(tonumber(receipt.id) or 0)),
		type = clean(receipt.type or "incident", 40),
		reason = clean(receipt.reason, 160),
		resolution = clean(receipt.resolution or "resolved", 48),
		started_at = math.floor(tonumber(receipt.started_at) or os.time()),
		resolved_at = math.floor(tonumber(receipt.resolved_at) or os.time()),
		instigator_id = validSteamID(receipt.instigator_id),
		instigator = clean(receipt.instigator, 64),
		victim_id = validSteamID(receipt.victim_id),
		victim = clean(receipt.victim, 64),
		winner_id = validSteamID(receipt.winner_id),
		winner = clean(receipt.winner, 64),
		subjects = subjectList,
		evidence = evidence
	}
end

function PoliceRecords:Index(record)
	if not istable(record) or (tonumber(record.id) or 0) <= 0 or self.ByIncident[record.id] then return false end
	self.Records[#self.Records + 1] = record
	self.ByIncident[record.id] = record
	for _, subject in ipairs(record.subjects or {}) do
		local steamID = validSteamID(subject.steam_id)
		if steamID ~= "" then
			self.BySubject[steamID] = self.BySubject[steamID] or {}
			self.BySubject[steamID][#self.BySubject[steamID] + 1] = record
		end
	end
	if #self.Records > self.Capacity then
		local removed = table.remove(self.Records, 1)
		self.ByIncident[removed.id] = nil
		for _, subject in ipairs(removed.subjects or {}) do
			local list = self.BySubject[subject.steam_id]
			if list then
				table.RemoveByValue(list, removed)
				if #list == 0 then self.BySubject[subject.steam_id] = nil end
			end
		end
	end
	return true
end

function PoliceRecords:Record(incident, receipt)
	if not self:IsKnown(incident, receipt) then return false end
	local record = self:CompactReceipt(receipt)
	if not record or not self:Index(record) then return false end
	file.CreateDir("darkrp")
	local encoded = util.TableToJSON(record)
	if encoded then
		if file.Exists(self.Path, "DATA") then file.Append(self.Path, encoded .. "\n")
		else file.Write(self.Path, encoded .. "\n") end
	end
	return true
end

function PoliceRecords:Load()
	local raw = file.Read(self.Path, "DATA")
	if not raw or raw == "" then return end
	local decoded = {}
	for line in string.gmatch(raw, "[^\r\n]+") do
		local record = util.JSONToTable(line)
		if istable(record) then decoded[#decoded + 1] = record end
	end
	local startAt = math.max(1, #decoded - self.Capacity + 1)
	for index = startAt, #decoded do self:Index(decoded[index]) end
	if startAt > 1 then
		local compact = {}
		for _, record in ipairs(self.Records) do compact[#compact + 1] = util.TableToJSON(record) end
		file.Write(self.Path, table.concat(compact, "\n") .. "\n")
	end
	print(string.format("[DRP POLICE DB] loaded %d police-known incident records", #self.Records))
end

local function activeSubject(incident)
	if IsValid(incident.victim) then return incident.victim end
	for _, participant in ipairs(incident.participants or {}) do
		if IsValid(participant.player) and isSuspectRole(participant.role) then return participant.player end
	end
end

function PoliceRecords:ActiveFor(steamID)
	local active = {}
	for _, incident in pairs((DRP.Incidents and DRP.Incidents.Active) or {}) do
		if self:IsKnown(incident) then
			local suspect = activeSubject(incident)
			if IsValid(suspect) and suspect:SteamID64() == steamID then
				local warrant = incident.type == "legal_warrant" and incident.state == "active"
				local pendingWarrant = incident.type == "legal_warrant" and incident.state == "approval_pending"
			active[#active + 1] = {
				id = incident.id,
				type = clean(incident.type, 40),
				state = clean(incident.state, 40),
				reason = clean(incident.reason, 160),
				warrant = warrant,
				pending_warrant = pendingWarrant,
				seconds = math.max(0, math.ceil((tonumber(incident.deadline) or CurTime()) - CurTime()))
			}
			end
		end
	end
	table.sort(active, function(first, second) return first.id > second.id end)
	return active
end

local function onlinePlayer(steamID)
	for _, ply in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do
		if IsValid(ply) and ply:SteamID64() == steamID then return ply end
	end
end

function PoliceRecords:BuildIndex()
	local summaries = {}
	local function ensure(steamID, name)
		steamID = validSteamID(steamID)
		if steamID == "" then return nil end
		summaries[steamID] = summaries[steamID] or {
			steam_id = steamID,
			name = clean(name ~= "" and name or steamID, 64),
			online = false,
			records = 0,
			infractions = 0,
			warrants = 0,
			matters = 0
		}
		return summaries[steamID]
	end

	for steamID, records in pairs(self.BySubject) do
		local name = steamID
		if records[#records] then
			for _, subject in ipairs(records[#records].subjects or {}) do
				if subject.steam_id == steamID then name = subject.name break end
			end
		end
		local summary = ensure(steamID, name)
		if summary then
			summary.records = #records
			for _, record in ipairs(records) do
				for _, subject in ipairs(record.subjects or {}) do
					if subject.steam_id == steamID and (subject.role == "suspect" or subject.role == "instigator") then
						summary.infractions = summary.infractions + 1
						break
					end
				end
			end
		end
	end
	for _, ply in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do
		if IsValid(ply) and ply:DRPReady() then
			local summary = ensure(ply:SteamID64(), ply:DRPName())
			if summary then summary.name, summary.online = clean(ply:DRPName(), 64), true end
		end
	end
	for steamID, summary in pairs(summaries) do
		local active = self:ActiveFor(steamID)
		summary.matters = #active
		for _, item in ipairs(active) do
			if item.warrant or item.pending_warrant then summary.warrants = summary.warrants + 1 end
		end
	end

	local result = {}
	for _, summary in pairs(summaries) do result[#result + 1] = summary end
	table.sort(result, function(first, second)
		if first.warrants ~= second.warrants then return first.warrants > second.warrants end
		if first.matters ~= second.matters then return first.matters > second.matters end
		if first.online ~= second.online then return first.online end
		return string.lower(first.name) < string.lower(second.name)
	end)
	while #result > 256 do table.remove(result) end
	return result
end

function PoliceRecords:BuildDetails(steamID)
	steamID = validSteamID(steamID)
	if steamID == "" then return nil end
	local ply = onlinePlayer(steamID)
	local records = self.BySubject[steamID] or {}
	local result = {
		steam_id = steamID,
		name = IsValid(ply) and clean(ply:DRPName(), 64) or steamID,
		online = IsValid(ply),
		wanted_reason = IsValid(ply) and clean(ply:GetNW2String("DRPWantedReason", ""), 120) or "",
		active = self:ActiveFor(steamID),
		records = {}
	}
	if not IsValid(ply) and records[#records] then
		for _, subject in ipairs(records[#records].subjects or {}) do
			if subject.steam_id == steamID then result.name = subject.name break end
		end
	end
	for index = #records, math.max(1, #records - self.DetailLimit + 1), -1 do
		local record = table.Copy(records[index])
		for _, subject in ipairs(record.subjects or {}) do
			if subject.steam_id == steamID then record.subject_role = subject.role break end
		end
		result.records[#result.records + 1] = record
	end
	return result
end

function PoliceRecords:Send(ply, mode, payload)
	local body = util.TableToJSON({ version = self.Protocol, mode = mode, data = payload })
	local compressed = body and util.Compress(body)
	if not compressed or #compressed > 60000 then
		DRP.Net.Notify(ply, "Police database response was too large.", 3)
		return false
	end
	net.Start(self.ResponseMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(#compressed, 16)
	net.WriteData(compressed, #compressed)
	net.Send(ply)
	if DRP.Net and DRP.Net.Record then DRP.Net.Record(#compressed + 3) end
	return true
end

PoliceRecords:Load()

hook.Add("DRPIncidentResolved", "DRP.PoliceRecords.Resolve", function(incident, receipt)
	PoliceRecords:Record(incident, receipt)
end)

DRP.Net.Receive(PoliceRecords.RequestMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not DRP.Net.Allow(ply, "phone_police_records", 0.35, 4) then return end
	local job = IsValid(ply) and ply:DRPReady() and ply:DRPJob() or nil
	if not job or (job.isPolice ~= true and job.key ~= "mayor") then
		DRP.Net.Notify(ply, "Police database access denied.", 3)
		return
	end
	if not DRP.Phone or not DRP.Phone:HasPoliceTerminal(ply) then
		DRP.Net.Notify(ply, job.key == "mayor"
			and "Equip the mayoral tablet to use the police database."
			or "Equip the Police Operations Tablet to use the police database.", 2)
		return
	end
	local mode = net.ReadUInt(2)
	if mode == 1 then
		local steamID = validSteamID(net.ReadString())
		PoliceRecords:Send(ply, 1, PoliceRecords:BuildDetails(steamID) or {})
	else
		PoliceRecords:Send(ply, 0, PoliceRecords:BuildIndex())
	end
end)
