local Network = {
	SentMessages = 0,
	SentBytes = 0,
	ReceiverAudit = {},
	ReceiverDuplicates = {}
}

DRP.Net = Network
DRP.Services.Register("network", Network)

local stateMessage = "drp_state_v1"
local profileMessage = "drp_profile_v2"
local noticeMessage = "drp_notice_v2"
local doorMessage = "drp_door_v2"
local doorRequestMessage = "drp_door_request_v2"
local doorPolicyMessage = "drp_door_policy_v1"

function Network:Start()
	util.AddNetworkString(stateMessage)
	util.AddNetworkString(profileMessage)
	util.AddNetworkString(noticeMessage)
	util.AddNetworkString(doorMessage)
	util.AddNetworkString(doorRequestMessage)
	util.AddNetworkString(doorPolicyMessage)
end

local function record(bytes, recipients)
	Network.SentMessages = Network.SentMessages + (recipients or 1)
	Network.SentBytes = Network.SentBytes + bytes * (recipients or 1)
end

function Network.Record(bytes, recipients)
	record(math.max(0, math.floor(tonumber(bytes) or 0)), recipients)
end

function Network.SendProfile(ply)
	if not IsValid(ply) then return end
	if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.LEVEL) end

	net.Start(profileMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.Clamp(ply:DRPMoney(), 0, 4294967295), 32)
	net.WriteUInt(ply:DRPJobID(), 8)
	net.WriteUInt(math.Clamp(math.ceil((ply.DRPNextSalary or CurTime()) - CurTime()), 0, 65535), 16)
	net.WriteDouble(math.max(0, math.floor(tonumber(ply:DRPXP()) or 0)))
	net.WriteUInt(math.max(0, math.floor(tonumber(ply:DRPXPLevel()) or 1)), 8)
	net.WriteUInt(math.max(0, math.floor(tonumber(ply:DRPXPPrestige()) or 0)), 8)
	net.WriteUInt(math.max(0, math.floor(tonumber(ply:DRPXPPrestigeTokens()) or 0)), 8)
	-- Playtime is private HUD state. Carry it in this owner-only event packet
	-- rather than globally replicating two NW2 variables on every player.
	net.WriteUInt(math.Clamp(math.floor(CurTime() - (ply.DRPSessionStartedAt or CurTime())), 0, 4294967295), 32)
	net.WriteUInt(math.Clamp(math.floor(tonumber(ply.DRPTotalPlaytimeBase) or 0), 0, 4294967295), 32)
	local prestigeWeapons = {}
	for key in pairs(ply.DRPXPUnlockedItemsValue or {}) do
		if isstring(key) and string.StartWith(key, "weapon:") then
			local class = string.lower(string.Trim(string.sub(key, 8)))
			if class ~= "" then prestigeWeapons[#prestigeWeapons + 1] = class end
		end
	end
	table.sort(prestigeWeapons)
	if #prestigeWeapons > 63 then
		for index = #prestigeWeapons, 64, -1 do table.remove(prestigeWeapons, index) end
	end
	net.WriteUInt(#prestigeWeapons, 6)
	for index = 1, #prestigeWeapons do net.WriteString(prestigeWeapons[index]) end
	net.Send(ply)
	local prestigeBytes = 1
	for index = 1, #prestigeWeapons do prestigeBytes = prestigeBytes + #prestigeWeapons[index] + 1 end
	record(23 + prestigeBytes)
end

function Network.Notify(ply, text, kind)
	if not IsValid(ply) then return end
	text = string.sub(tostring(text or ""), 1, 160)

	net.Start(noticeMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.Clamp(tonumber(kind) or 0, 0, 3), 2)
	net.WriteString(text)
	net.Send(ply)
	record(#text + 3)
end

function Network.SendDoor(door, owner, recipient)
	if not IsValid(door) then return end

	net.Start(doorMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(door:EntIndex(), 13)
	net.WriteUInt(IsValid(owner) and owner:EntIndex() or 0, 8)
	if IsValid(recipient) then
		net.Send(recipient)
		record(4)
	else
		local count = #DRP.Players.List
		net.Broadcast()
		record(4, count)
	end
end

function Network.DoorRequestName()
	return doorRequestMessage
end

function Network.SendDoorPolicy(door, policy, recipient)
	if not IsValid(door) or not istable(policy) then return end
	net.Start(doorPolicyMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(door:EntIndex(), 13)
	net.WriteBool(policy.ownable ~= false)
	net.WriteUInt(bit.band(math.floor(tonumber(policy.jobs) or 0), 65535), 16)
	if IsValid(recipient) then
		net.Send(recipient)
		record(5)
	else
		local count = #DRP.Players.List
		net.Broadcast()
		record(5, count)
	end
end

function Network.SendState(ply, state)
	if not IsValid(ply) then return end

	net.Start(stateMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(state, 2)
	net.Send(ply)

	Network.SentMessages = Network.SentMessages + 1
	Network.SentBytes = Network.SentBytes + 2
end

function Network.Allow(ply, key, interval, burst)
	if not IsValid(ply) then return false end

	local limits = ply.DRPRateLimits
	if not limits then
		limits = {}
		ply.DRPRateLimits = limits
	end

	local now = CurTime()
	local bucket = limits[key]
	if not bucket then
		limits[key] = { tokens = burst - 1, updated = now }
		return true
	end

	bucket.tokens = math.min(burst, bucket.tokens + (now - bucket.updated) / interval)
	bucket.updated = now
	if bucket.tokens < 1 then return false end
	bucket.tokens = bucket.tokens - 1
	return true
end

-- All client-to-server endpoints pass through this boundary. Individual
-- receivers still enforce their tighter permission and action-specific limits.
function Network.Receive(name, callback)
	assert(isstring(name) and name ~= "", "network receiver name must be a non-empty string")
	assert(isfunction(callback), "network receiver callback must be a function")
	local source = debug.getinfo(2, "S").short_src or "unknown"
	if Network.ReceiverAudit[name] then
		Network.ReceiverDuplicates[#Network.ReceiverDuplicates + 1] = name
		ErrorNoHalt("[DRP STARTUP] duplicate net receiver: " .. name .. "\n")
	end
	Network.ReceiverAudit[name] = { source = source }
	net.Receive(name, function(length, ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		if not Network.Allow(ply, "net:" .. name, 0.05, 20) then return end
		return callback(length, ply)
	end)
end
