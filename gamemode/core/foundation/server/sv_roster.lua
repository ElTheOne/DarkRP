local Roster = {
	Last = setmetatable({}, { __mode = "k" })
}

DRP.Roster = Roster
DRP.Services.Register("roster", Roster)

local message = "drp_roster_v1"
local requestMessage = "drp_roster_request_v1"
util.AddNetworkString(message)
util.AddNetworkString(requestMessage)

Roster.Field = {
	RP_NAME = 1,
	JOB = 2,
	LEVEL = 4,
	CIVIC = 8,
	RANK = 16,
	AFK = 32,
	ADMIN_MODE = 64,
	TRUST = 128
}
Roster.ALL = 255

local rankID = {}
for index, definition in ipairs(DRP.AdminRanks) do rankID[definition.key] = index - 1 end

local function ready(ply)
	return IsValid(ply) and ply:IsPlayer() and (ply:IsBot() or ply:DRPReady())
end

function Roster:Build(ply)
	return {
		entity = ply:EntIndex(),
		rpName = string.sub(tostring(ply.DRPRPNameValue or ply:Nick()), 1, 48),
		job = math.Clamp(math.floor(tonumber(ply.DRPJobValue) or DRP.Job.CITIZEN), 1, 255),
		jobTitle = string.sub(tostring(ply.DRPJobNameValue or ""), 1, 48),
		level = math.Clamp(math.floor(tonumber(ply.DRPXPLevelValue) or 1), 1, 100),
		prestige = math.Clamp(math.floor(tonumber(ply.DRPXPPrestigeValue) or 0), 0, 10),
		civic = math.Clamp(math.floor(tonumber(ply.DRPCivicStandingValue) or 0), -1000, 1000),
		rank = DRP.Admin and DRP.Admin.RankKey(ply) or "user",
		supporterTier = DRP.Supporter and DRP.Supporter.Tier(ply) or 0,
		afk = ply.DRPAFKState == true,
		adminMode = ply.DRPAdminMode == true,
		trust = math.Clamp(math.floor(tonumber(ply.DRPTrustScore) or 50), 0, 100),
		trustKnown = math.Clamp(math.floor(tonumber(ply.DRPTrustKnown) or 0), 0, 15),
		discordLinked = ply.DRPDiscordLinked == true
	}
end

local function writeFields(record, mask)
	if bit.band(mask, Roster.Field.RP_NAME) ~= 0 then net.WriteString(record.rpName) end
	if bit.band(mask, Roster.Field.JOB) ~= 0 then
		net.WriteUInt(record.job, 8)
		net.WriteString(record.jobTitle)
	end
	if bit.band(mask, Roster.Field.LEVEL) ~= 0 then
		net.WriteUInt(record.level, 7)
		net.WriteUInt(record.prestige, 4)
	end
	if bit.band(mask, Roster.Field.CIVIC) ~= 0 then net.WriteInt(record.civic, 12) end
	if bit.band(mask, Roster.Field.RANK) ~= 0 then
		net.WriteUInt(rankID[record.rank] or rankID.user, 4)
		net.WriteUInt(record.supporterTier or 0, 2)
	end
	if bit.band(mask, Roster.Field.AFK) ~= 0 then net.WriteBool(record.afk) end
	if bit.band(mask, Roster.Field.ADMIN_MODE) ~= 0 then net.WriteBool(record.adminMode) end
	if bit.band(mask, Roster.Field.TRUST) ~= 0 then
		net.WriteUInt(record.trust, 7)
		net.WriteUInt(record.trustKnown, 4)
		net.WriteBool(record.discordLinked)
	end
end

local function fieldBytes(record, mask)
	local bytes = 0
	if bit.band(mask, Roster.Field.RP_NAME) ~= 0 then bytes = bytes + #record.rpName + 1 end
	if bit.band(mask, Roster.Field.JOB) ~= 0 then bytes = bytes + #record.jobTitle + 2 end
	if bit.band(mask, Roster.Field.LEVEL) ~= 0 then bytes = bytes + 2 end
	if bit.band(mask, Roster.Field.CIVIC) ~= 0 then bytes = bytes + 2 end
	if bit.band(mask, Roster.Field.RANK) ~= 0 then bytes = bytes + 1 end
	if bit.band(mask, Roster.Field.AFK) ~= 0 then bytes = bytes + 1 end
	if bit.band(mask, Roster.Field.ADMIN_MODE) ~= 0 then bytes = bytes + 1 end
	if bit.band(mask, Roster.Field.TRUST) ~= 0 then bytes = bytes + 2 end
	return bytes
end

local function changed(previous, current, mask)
	if not previous then return mask end
	local result = 0
	if bit.band(mask, Roster.Field.RP_NAME) ~= 0 and previous.rpName ~= current.rpName then result = bit.bor(result, Roster.Field.RP_NAME) end
	if bit.band(mask, Roster.Field.JOB) ~= 0 and (previous.job ~= current.job or previous.jobTitle ~= current.jobTitle) then result = bit.bor(result, Roster.Field.JOB) end
	if bit.band(mask, Roster.Field.LEVEL) ~= 0
		and (previous.level ~= current.level or previous.prestige ~= current.prestige) then
		result = bit.bor(result, Roster.Field.LEVEL)
	end
	if bit.band(mask, Roster.Field.CIVIC) ~= 0 and previous.civic ~= current.civic then result = bit.bor(result, Roster.Field.CIVIC) end
	if bit.band(mask, Roster.Field.RANK) ~= 0 and (previous.rank ~= current.rank or previous.supporterTier ~= current.supporterTier) then result = bit.bor(result, Roster.Field.RANK) end
	if bit.band(mask, Roster.Field.AFK) ~= 0 and previous.afk ~= current.afk then result = bit.bor(result, Roster.Field.AFK) end
	if bit.band(mask, Roster.Field.ADMIN_MODE) ~= 0 and previous.adminMode ~= current.adminMode then result = bit.bor(result, Roster.Field.ADMIN_MODE) end
	if bit.band(mask, Roster.Field.TRUST) ~= 0 and (previous.trust ~= current.trust or previous.trustKnown ~= current.trustKnown or previous.discordLinked ~= current.discordLinked) then result = bit.bor(result, Roster.Field.TRUST) end
	return result
end

local function remember(previous, current, mask)
	previous = previous or {}
	previous.entity = current.entity
	if bit.band(mask, Roster.Field.RP_NAME) ~= 0 then previous.rpName = current.rpName end
	if bit.band(mask, Roster.Field.JOB) ~= 0 then previous.job, previous.jobTitle = current.job, current.jobTitle end
	if bit.band(mask, Roster.Field.LEVEL) ~= 0 then
		previous.level = current.level
		previous.prestige = current.prestige
	end
	if bit.band(mask, Roster.Field.CIVIC) ~= 0 then previous.civic = current.civic end
	if bit.band(mask, Roster.Field.RANK) ~= 0 then previous.rank, previous.supporterTier = current.rank, current.supporterTier end
	if bit.band(mask, Roster.Field.AFK) ~= 0 then previous.afk = current.afk end
	if bit.band(mask, Roster.Field.ADMIN_MODE) ~= 0 then previous.adminMode = current.adminMode end
	if bit.band(mask, Roster.Field.TRUST) ~= 0 then
		previous.trust, previous.trustKnown, previous.discordLinked = current.trust, current.trustKnown, current.discordLinked
	end
	return previous
end

function Roster:Update(ply, requestedMask, recipient, force, omit)
	if not ready(ply) then return false end
	local record = self:Build(ply)
	local mask = force and requestedMask or changed(self.Last[ply], record, requestedMask)
	self.Last[ply] = remember(self.Last[ply], record, requestedMask)
	if mask == 0 then return false end

	net.Start(message)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(1, 2)
	net.WriteUInt(ply:EntIndex(), 13)
	net.WriteUInt(mask, 8)
	writeFields(record, mask)
	if IsValid(recipient) then net.Send(recipient)
	elseif IsValid(omit) then net.SendOmit(omit)
	else net.Broadcast() end
	if DRP.Net.Record then
		local recipients = IsValid(recipient) and 1 or math.max(0, player.GetCount() - (IsValid(omit) and 1 or 0))
		DRP.Net.Record(5 + fieldBytes(record, mask), recipients)
	end
	return true
end

function Roster:SendSnapshot(recipient)
	if not IsValid(recipient) then return end
	local entries = {}
	for _, ply in player.Iterator() do
		if ready(ply) then entries[#entries + 1] = ply end
	end
	net.Start(message)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(0, 2)
	net.WriteUInt(math.min(#entries, 255), 8)
	local bytes = 3
	for index = 1, math.min(#entries, 255) do
		local ply = entries[index]
		local record = self:Build(ply)
		self.Last[ply] = record
		net.WriteUInt(ply:EntIndex(), 13)
		writeFields(record, self.ALL)
		bytes = bytes + 2 + fieldBytes(record, self.ALL)
	end
	net.Send(recipient)
	if DRP.Net.Record then DRP.Net.Record(bytes, 1) end
end

function Roster:Remove(ply)
	local previous = self.Last[ply]
	local index = IsValid(ply) and ply:EntIndex() or (previous and previous.entity or 0)
	self.Last[ply] = nil
	if index <= 0 then return end
	net.Start(message)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(2, 2)
	net.WriteUInt(index, 13)
	net.Broadcast()
	if DRP.Net.Record then DRP.Net.Record(4, player.GetCount()) end
end

function Roster:Start()
	self.Last = setmetatable({}, { __mode = "k" })
end

function Roster:Stop()
	self.Last = setmetatable({}, { __mode = "k" })
end

hook.Add("DRPPlayerReady", "DRP.Roster.Join", function(ply)
	-- Existing players receive one join record; the joining player receives one
	-- complete authoritative roster. No periodic recovery snapshots are sent.
	Roster:Update(ply, Roster.ALL, nil, true, ply)
	Roster:SendSnapshot(ply)
end)

hook.Add("PlayerDisconnected", "DRP.Roster.Disconnect", function(ply) Roster:Remove(ply) end)

DRP.Net.Receive(requestMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not ply:DRPReady() then return end
	if not DRP.Net.Allow(ply, "roster_recovery", 10, 1) then return end
	Roster:SendSnapshot(ply)
end)
