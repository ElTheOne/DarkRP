local Roster = {
	Entries = {},
	Field = {
		RP_NAME = 1, JOB = 2, LEVEL = 4, CIVIC = 8,
		RANK = 16, AFK = 32, ADMIN_MODE = 64, TRUST = 128
	}
}

DRP.Roster = Roster
Roster.ALL = 255

local rankKeys = {}
for index, definition in ipairs(DRP.AdminRanks) do rankKeys[index - 1] = definition.key end

local function readFields(record, mask)
	if bit.band(mask, Roster.Field.RP_NAME) ~= 0 then record.rpName = string.sub(net.ReadString(), 1, 48) end
	if bit.band(mask, Roster.Field.JOB) ~= 0 then
		record.job = net.ReadUInt(8)
		record.jobTitle = string.sub(net.ReadString(), 1, 48)
	end
	if bit.band(mask, Roster.Field.LEVEL) ~= 0 then
		record.level = net.ReadUInt(7)
		record.prestige = net.ReadUInt(4)
	end
	if bit.band(mask, Roster.Field.CIVIC) ~= 0 then record.civic = net.ReadInt(12) end
	if bit.band(mask, Roster.Field.RANK) ~= 0 then
		record.rank = rankKeys[net.ReadUInt(4)] or "user"
		record.supporterTier = net.ReadUInt(2)
	end
	if bit.band(mask, Roster.Field.AFK) ~= 0 then record.afk = net.ReadBool() end
	if bit.band(mask, Roster.Field.ADMIN_MODE) ~= 0 then record.adminMode = net.ReadBool() end
	if bit.band(mask, Roster.Field.TRUST) ~= 0 then
		record.trust = net.ReadUInt(7)
		record.trustKnown = net.ReadUInt(4)
		record.discordLinked = net.ReadBool()
	end
end

function Roster.Get(value)
	local index = IsValid(value) and value:EntIndex() or math.floor(tonumber(value) or 0)
	return Roster.Entries[index]
end

function Roster.Value(value, key, fallback)
	local record = Roster.Get(value)
	local result = record and record[key]
	if result == nil then return fallback end
	return result
end

net.Receive("drp_roster_v1", function()
	local version = net.ReadUInt(8)
	local operation = net.ReadUInt(2)
	if version ~= DRP.ProtocolVersion then return end

	if operation == 0 then
		local replacement = {}
		for _ = 1, net.ReadUInt(8) do
			local index = net.ReadUInt(13)
			local record = {}
			readFields(record, Roster.ALL)
			replacement[index] = record
		end
		Roster.Entries = replacement
		hook.Run("DRPRosterSnapshot", replacement)
		return
	end

	local index = net.ReadUInt(13)
	if operation == 2 then
		local previous = Roster.Entries[index]
		Roster.Entries[index] = nil
		hook.Run("DRPRosterRemoved", index, previous)
		return
	end
	if operation ~= 1 then return end
	local mask = net.ReadUInt(8)
	local record = Roster.Entries[index] or {}
	readFields(record, mask)
	Roster.Entries[index] = record
	hook.Run("DRPRosterChanged", index, record, mask)
end)

function Roster.RequestRecovery()
	net.Start("drp_roster_request_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.SendToServer()
end

concommand.Add("drp_roster_refresh", function() Roster.RequestRecovery() end)
