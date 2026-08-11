local Phone = {
	NetworkName = "iPhone",
	PhotoRequestName = "drp_phone_photo_request_v1",
	PhotoMetadataName = "drp_phone_photo_metadata_v1",
	PhotoUploadName = "drp_phone_photo_upload_v1",
	PhotoReceiveName = "drp_phone_photo_receive_v1",
	RingTimeout = 30,
	Calls = setmetatable({}, { __mode = "k" }),
	Sequence = 0,
	PhotoSequence = 0,
	MaxPhotoSubjects = 16,
	MaxPhotoIncidents = 12,
	PhotoRange = 2500,
	PhotoChunkSize = 24000,
	MaxPhotoBytes = 524288,
	MaxPhotoMetadataBytes = 32768,
	PhotoUploads = setmetatable({}, { __mode = "k" })
}

DRP.Phone = Phone
DRP.Services.Register("phone", Phone)

util.AddNetworkString(Phone.NetworkName)
util.AddNetworkString(Phone.PhotoRequestName)
util.AddNetworkString(Phone.PhotoMetadataName)
util.AddNetworkString(Phone.PhotoUploadName)
util.AddNetworkString(Phone.PhotoReceiveName)

local function isReadyPlayer(ply)
	return IsValid(ply)
		and ply:IsPlayer()
		and ply:DRPReady()
		and ply:Alive()
end

local function hasHandset(ply)
	if not isReadyPlayer(ply) then return false end
	if ply:HasWeapon("ephone") then return true end
	if ply:HasWeapon("weapon_drp_police_tablet") and ply.DRPJob and ply:DRPJob().isPolice == true then return true end
	return ply:HasWeapon("weapon_drp_mayor_tablet")
		and ply.DRPJob and ply:DRPJob().key == "mayor"
end

local function sendCommand(ply, command, entity, text)
	if not IsValid(ply) then return end
	net.Start(Phone.NetworkName)
	net.WriteString(command)
	if IsValid(entity) then net.WriteEntity(entity) end
	if text ~= nil then net.WriteString(text) end
	net.Send(ply)
	if DRP.Net and DRP.Net.Record then
		DRP.Net.Record(#command + (text and #text or 0) + (IsValid(entity) and 2 or 0) + 2)
	end
end

function Phone:HasHandset(ply)
	return hasHandset(ply)
end

function Phone:HasPoliceTerminal(ply)
	if not isReadyPlayer(ply) then return false end
	local job = ply:DRPJob()
	if job.isPolice == true then return ply:HasWeapon("weapon_drp_police_tablet") end
	if job.key == "mayor" then return ply:HasWeapon("weapon_drp_mayor_tablet") end
	return false
end

function Phone:RecordFor(ply)
	return self.Calls[ply]
end

function Phone:EndCall(ply, reason)
	local record = self.Calls[ply]
	if not record or record.ended then return false end
	record.ended = true
	self.Calls[record.caller] = nil
	self.Calls[record.recipient] = nil

	sendCommand(record.caller, "endcall")
	sendCommand(record.recipient, "endcall")
	if reason and reason ~= "" then
		if IsValid(record.caller) then DRP.Net.Notify(record.caller, reason, 0) end
		if IsValid(record.recipient) then DRP.Net.Notify(record.recipient, reason, 0) end
	end
	if DRP.Audit then
		DRP.Audit.Log(record.caller, "phone_call_end", record.recipient, record.answered and "answered" or "unanswered")
	end
	return true
end

function Phone:StartCall(caller, recipient)
	if not hasHandset(caller) then
		DRP.Net.Notify(caller, "Equip your ePhone or authorised tablet before placing a call.", 2)
		sendCommand(caller, "endcall")
		return false
	end
	if not hasHandset(recipient) or caller == recipient then
		DRP.Net.Notify(caller, "That player is unavailable.", 2)
		sendCommand(caller, "endcall")
		return false
	end
	if self.Calls[caller] then self:EndCall(caller) end
	if self.Calls[recipient] then
		DRP.Net.Notify(caller, "That player is already on a call.", 2)
		sendCommand(caller, "endcall")
		return false
	end

	self.Sequence = self.Sequence + 1
	local record = {
		id = self.Sequence,
		caller = caller,
		recipient = recipient,
		answered = false,
		createdAt = CurTime()
	}
	self.Calls[caller] = record
	self.Calls[recipient] = record
	sendCommand(recipient, "call", caller)
	if DRP.Audit then DRP.Audit.Log(caller, "phone_call", recipient, "ringing") end

	timer.Simple(self.RingTimeout, function()
		if Phone.Calls[caller] == record and not record.answered then
			Phone:EndCall(caller, "The call was not answered.")
		end
	end)
	return true
end

function Phone:Answer(ply)
	local record = self.Calls[ply]
	if not record or record.ended or record.recipient ~= ply or record.answered then return false end
	if not hasHandset(record.caller) or not hasHandset(record.recipient) then
		self:EndCall(ply, "The call ended because a phone became unavailable.")
		return false
	end
	record.answered = true
	record.answeredAt = CurTime()
	sendCommand(record.caller, "anscall")
	if DRP.Audit then DRP.Audit.Log(record.recipient, "phone_answer", record.caller) end
	return true
end

function Phone:CanHearRemote(listener, talker)
	local record = self.Calls[listener]
	return record ~= nil
		and record == self.Calls[talker]
		and record.answered == true
		and not record.ended
		and ((record.caller == listener and record.recipient == talker)
			or (record.caller == talker and record.recipient == listener))
end

function Phone:Message(sender, recipient, text)
	if not hasHandset(sender) then
		DRP.Net.Notify(sender, "Equip your ePhone or authorised tablet before sending a message.", 2)
		return false
	end
	if not hasHandset(recipient) or sender == recipient then
		DRP.Net.Notify(sender, "That player is unavailable.", 2)
		return false
	end
	text = string.Trim(string.sub(tostring(text or ""), 1, 128))
	if text == "" then return false end
	sendCommand(recipient, "msg", sender, text)
	if DRP.Audit then DRP.Audit.Log(sender, "phone_message", recipient, "length=" .. #text) end
	return true
end

local function photoView(ply, mode)
	local eyePosition, eyeAngles = ply:EyePos(), ply:EyeAngles()
	if mode ~= "selfie" then return eyePosition, eyeAngles end
	local origin = eyePosition + eyeAngles:Forward() * 88 + eyeAngles:Up() * 8
	return origin, (eyePosition - origin):Angle()
end

local function photoSubjectList(ply, mode)
	local origin, angles = photoView(ply, mode)
	local forward = angles:Forward()
	local candidates = {}
	for _, candidate in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do
		if isReadyPlayer(candidate) then
			local offset = candidate:WorldSpaceCenter() - origin
			local distanceSquared = offset:LengthSqr()
			local visible = candidate == ply or (distanceSquared <= Phone.PhotoRange * Phone.PhotoRange
				and offset:GetNormalized():Dot(forward) >= 0.55
				and (not ply.TestPVS or ply:TestPVS(candidate)))
			if visible then
				candidates[#candidates + 1] = { player = candidate, distance = distanceSquared }
			end
		end
	end
	table.sort(candidates, function(first, second) return first.distance < second.distance end)
	local subjects = {}
	for index = 1, math.min(#candidates, Phone.MaxPhotoSubjects) do
		local subject = candidates[index].player
		subjects[#subjects + 1] = {
			steam_id = subject:SteamID64(),
			rp_name = string.sub(subject:DRPName(), 1, 64),
			job = string.sub(tostring(subject:DRPJob().name or "Citizen"), 1, 48)
		}
	end
	return subjects
end

function Phone:BuildPhotoMetadata(ply, mode)
	mode = mode == "selfie" and "selfie" or "rear"
	self.PhotoSequence = (self.PhotoSequence + 1) % 4294967295
	local position = ply:GetPos()
	local propertyName, propertyID = "Open world", 0
	if DRP.Properties and DRP.Properties.LocationAt then
		local definition, id = DRP.Properties:LocationAt(position)
		if definition then propertyName, propertyID = definition.name or ("Property " .. id), id end
	end
	local subjects = photoSubjectList(ply, mode)
	local photoOrigin, photoAngles = photoView(ply, mode)
	local visibleCorpses = DRP.HitmanEvidence and DRP.HitmanEvidence.VisibleCorpses
		and DRP.HitmanEvidence:VisibleCorpses(ply, photoOrigin, photoAngles) or {}
	local corpses = {}
	for _, entry in ipairs(visibleCorpses) do
		corpses[#corpses + 1] = {
			death_id = entry.death_id,
			incident_id = entry.incident_id,
			incident_type = entry.incident_type,
			victim_id = entry.victim_id,
			victim_name = entry.victim_name,
			distance = math.Round(entry.distance or 0, 1)
		}
	end
	local subjectIDs = {}
	for _, subject in ipairs(subjects) do subjectIDs[subject.steam_id] = true end
	subjectIDs[ply:SteamID64()] = true

	local incidents, seen = {}, {}
	for participant, set in pairs(DRP.Incidents.ByPlayer or {}) do
		if IsValid(participant) and subjectIDs[participant:SteamID64()] then
			for _, incident in pairs(set) do
				if not seen[incident.id] and #incidents < self.MaxPhotoIncidents then
					seen[incident.id] = true
					incidents[#incidents + 1] = {
						id = incident.id,
						type = string.sub(tostring(incident.type or "incident"), 1, 40),
						state = string.sub(tostring(incident.state or "active"), 1, 40),
						reason = string.sub(tostring(incident.reason or ""), 1, 160),
						instigator = IsValid(incident.instigator) and string.sub(incident.instigator:DRPName(), 1, 64) or "Unavailable",
						instigator_id = IsValid(incident.instigator) and incident.instigator:SteamID64() or "",
						victim = IsValid(incident.victim) and string.sub(incident.victim:DRPName(), 1, 64) or "Unavailable",
						victim_id = IsValid(incident.victim) and incident.victim:SteamID64() or ""
					}
				end
			end
		end
	end
	table.sort(incidents, function(first, second) return first.id < second.id end)

	return {
		version = 1,
		photo_id = self.PhotoSequence,
		captured_at = os.time(),
		mode = mode,
		photographer = {
			steam_id = ply:SteamID64(),
			rp_name = string.sub(ply:DRPName(), 1, 64)
		},
		location = {
			map = game.GetMap(),
			label = string.sub(tostring(propertyName), 1, 64),
			property_id = tonumber(propertyID) or 0,
			x = math.Round(position.x, 1),
			y = math.Round(position.y, 1),
			z = math.Round(position.z, 1)
		},
		subjects = subjects,
		incidents = incidents,
		corpses = corpses,
		_hitmanEvidence = visibleCorpses
	}
end

function Phone:SendPhotoMetadata(ply, requestID, mode)
	if not hasHandset(ply) then
		DRP.Net.Notify(ply, "Equip your ePhone or authorised tablet before taking a photo.", 2)
		return false
	end
	local metadata = self:BuildPhotoMetadata(ply, mode)
	local evidenceCorpses = metadata._hitmanEvidence or {}
	metadata._hitmanEvidence = nil
	local encoded = util.TableToJSON(metadata)
	if not encoded or #encoded > 32768 then return false end
	net.Start(self.PhotoMetadataName)
	net.WriteUInt(math.Clamp(tonumber(requestID) or 0, 0, 65535), 16)
	net.WriteUInt(#encoded, 16)
	net.WriteData(encoded, #encoded)
	net.Send(ply)
	DRP.Net.Record(#encoded + 5)
	if DRP.Audit then
		DRP.Audit.Log(ply, "phone_photo", nil,
			metadata.mode .. " at " .. metadata.location.label .. " subjects=" .. #metadata.subjects .. " incidents=" .. #metadata.incidents)
	end
	hook.Run("DRPPhonePhotoCaptured", ply, metadata, evidenceCorpses)
	return true
end

function Phone:Start()
	hook.Add("PlayerDeath", "DRP.Phone.Death", function(ply)
		Phone:EndCall(ply, "The call ended.")
	end)
	hook.Add("PlayerDisconnected", "DRP.Phone.Disconnect", function(ply)
		Phone:EndCall(ply, "The other caller disconnected.")
	end)
end

function Phone:Stop()
	hook.Remove("PlayerDeath", "DRP.Phone.Death")
	hook.Remove("PlayerDisconnected", "DRP.Phone.Disconnect")
	local active = {}
	for _, record in pairs(self.Calls) do active[record] = true end
	for record in pairs(active) do self:EndCall(record.caller) end
end

DRP.Net.Receive(Phone.NetworkName, function(_, ply)
	local command = string.lower(string.sub(net.ReadString(), 1, 16))
	if command == "msg" then
		if not DRP.Net.Allow(ply, "phone:message", 0.5, 4) then return end
		Phone:Message(ply, net.ReadEntity(), net.ReadString())
	elseif command == "call" then
		if not DRP.Net.Allow(ply, "phone:call", 1, 2) then return end
		Phone:StartCall(ply, net.ReadEntity())
	elseif command == "anscall" then
		if not DRP.Net.Allow(ply, "phone:answer", 0.5, 2) then return end
		Phone:Answer(ply)
	elseif command == "endcall" then
		if not DRP.Net.Allow(ply, "phone:end", 0.25, 3) then return end
		Phone:EndCall(ply)
	elseif command == "code" then
		-- Short-code execution was an unrestricted extension point upstream.
		-- It remains unavailable until a server-owned service claims a code.
		net.ReadString()
		sendCommand(ply, "endcall")
	end
end)

DRP.Net.Receive(Phone.PhotoRequestName, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not DRP.Net.Allow(ply, "phone:photo", 2, 2) then return end
	local requestID = net.ReadUInt(16)
	local mode = net.ReadBool() and "selfie" or "rear"
	Phone:SendPhotoMetadata(ply, requestID, mode)
end)

local function cancelPhotoUpload(ply, message)
	Phone.PhotoUploads[ply] = nil
	if message and IsValid(ply) then DRP.Net.Notify(ply, message, 2) end
end

local function relayPhotoStart(sender, upload)
	net.Start(Phone.PhotoReceiveName)
	net.WriteUInt(0, 2)
	net.WriteEntity(sender)
	net.WriteUInt(upload.id, 16)
	net.WriteUInt(upload.total, 20)
	net.WriteUInt(upload.chunks, 6)
	net.WriteUInt(#upload.metadata, 16)
	net.WriteData(upload.metadata, #upload.metadata)
	net.Send(upload.recipient)
	if DRP.Net and DRP.Net.Record then DRP.Net.Record(#upload.metadata + 16) end
end

local function acknowledgePhotoUpload(sender, upload)
	net.Start(Phone.PhotoReceiveName)
	net.WriteUInt(2, 2)
	net.WriteUInt(upload.id, 16)
	net.WriteEntity(upload.recipient)
	net.Send(sender)
end

local function relayPhotoChunk(sender, upload, index, data)
	net.Start(Phone.PhotoReceiveName)
	net.WriteUInt(1, 2)
	net.WriteEntity(sender)
	net.WriteUInt(upload.id, 16)
	net.WriteUInt(index, 6)
	net.WriteUInt(#data, 15)
	net.WriteData(data, #data)
	net.Send(upload.recipient)
	if DRP.Net and DRP.Net.Record then DRP.Net.Record(#data + 12) end
end

DRP.Net.Receive(Phone.PhotoUploadName, function(_, ply)
	local operation = net.ReadUInt(2)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end

	if operation == 0 then
		if not DRP.Net.Allow(ply, "phone:photo_upload", 8, 1) then return end
		if not hasHandset(ply) then return end

		local transferID = net.ReadUInt(16)
		local recipient = net.ReadEntity()
		local total = net.ReadUInt(20)
		local chunks = net.ReadUInt(6)
		local metadataLength = net.ReadUInt(16)
		if not hasHandset(recipient) or recipient == ply then
			DRP.Net.Notify(ply, "That player cannot receive the photo.", 2)
			return
		end
		if total < 64 or total > Phone.MaxPhotoBytes
			or chunks < 1 or chunks ~= math.ceil(total / Phone.PhotoChunkSize)
			or metadataLength < 2 or metadataLength > Phone.MaxPhotoMetadataBytes then
			DRP.Net.Notify(ply, "That photo upload was invalid or too large.", 2)
			return
		end

		local metadata = net.ReadData(metadataLength)
		if not metadata or #metadata ~= metadataLength or not istable(util.JSONToTable(metadata)) then
			DRP.Net.Notify(ply, "That photo has invalid metadata.", 2)
			return
		end

		local upload = {
			id = transferID,
			recipient = recipient,
			total = total,
			chunks = chunks,
			metadata = metadata,
			nextChunk = 1,
			received = 0,
			expires = CurTime() + 30
		}
		Phone.PhotoUploads[ply] = upload
		relayPhotoStart(ply, upload)
		acknowledgePhotoUpload(ply, upload)
		return
	end

	if operation ~= 1 then return end
	local transferID = net.ReadUInt(16)
	local index = net.ReadUInt(6)
	local length = net.ReadUInt(15)
	local upload = Phone.PhotoUploads[ply]
	if not upload or upload.id ~= transferID or CurTime() > upload.expires then
		cancelPhotoUpload(ply)
		return
	end
	if not hasHandset(ply) or not hasHandset(upload.recipient) then
		cancelPhotoUpload(ply, "The photo transfer was interrupted.")
		return
	end

	local expectedLength = math.min(Phone.PhotoChunkSize, upload.total - upload.received)
	if index ~= upload.nextChunk or length ~= expectedLength or length > Phone.PhotoChunkSize then
		cancelPhotoUpload(ply, "The photo transfer failed validation.")
		return
	end
	local data = net.ReadData(length)
	if not data or #data ~= length then
		cancelPhotoUpload(ply, "The photo transfer was incomplete.")
		return
	end

	relayPhotoChunk(ply, upload, index, data)
	upload.received = upload.received + length
	upload.nextChunk = upload.nextChunk + 1
	upload.expires = CurTime() + 30
	if upload.received >= upload.total and index == upload.chunks then
		Phone.PhotoUploads[ply] = nil
		if DRP.Audit then
			DRP.Audit.Log(ply, "phone_photo_message", upload.recipient,
				"bytes=" .. upload.total .. " chunks=" .. upload.chunks)
		end
	end
end)

concommand.Add("drp_phone_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local calls, answered = 0, 0
	local seen = {}
	for _, record in pairs(Phone.Calls) do
		if not seen[record] then
			seen[record] = true
			calls = calls + 1
			if record.answered then answered = answered + 1 end
		end
	end
	local message = string.format("[DRP PHONE] active=%d answered=%d timeout=%ds", calls, answered, Phone.RingTimeout)
	if IsValid(ply) then ply:ChatPrint(message) else print(message) end
end)
