local Consent = {
	Enabled = {},
	Pending = {},
	ActiveIncidents = {},
	DataPath = "darkrp/pvp_consent.json"
}

DRP.PVPConsent = Consent
DRP.Services.Register("pvp_consent", Consent)

local syncMessage = "drp_pvp_consent_sync_v1"
local actionMessage = "drp_pvp_consent_action_v1"
local requestMessage = "drp_pvp_consent_request_v1"
util.AddNetworkString(syncMessage)
util.AddNetworkString(actionMessage)
util.AddNetworkString(requestMessage)

DRP.Incidents.RegisterType("consensual_pvp", {
	initial = "permanent_consent_active",
	outcomes = { default = { winner = "instigator", loser = "victim" } }
})

local function validID(value)
	value = tostring(value or "")
	return string.match(value, "^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") and value or nil
end

local function pairKey(firstID, secondID)
	firstID, secondID = validID(firstID), validID(secondID)
	if not firstID or not secondID or firstID == secondID then return nil end
	if firstID > secondID then firstID, secondID = secondID, firstID end
	return firstID .. ":" .. secondID, firstID, secondID
end

local function online(steamID64)
	return DRP.Players.Online(steamID64)
end

local function currentName(steamID64, fallback)
	local ply = online(steamID64)
	return IsValid(ply) and ply:DRPName() or string.sub(tostring(fallback or steamID64), 1, 48)
end

function Consent:Write()
	file.CreateDir("darkrp")
	local previous = file.Read(self.DataPath, "DATA")
	if previous and previous ~= "" then file.Write(self.DataPath .. ".bak", previous) end
	file.Write(self.DataPath, util.TableToJSON({ enabled = self.Enabled, pending = self.Pending }, true))
end

function Consent:Load()
	local decoded = util.JSONToTable(file.Read(self.DataPath, "DATA") or "")
	if not istable(decoded) then decoded = util.JSONToTable(file.Read(self.DataPath .. ".bak", "DATA") or "") end
	if not istable(decoded) then return end
	for key, record in pairs(decoded.enabled or {}) do
		local wanted, first, second = pairKey(record.first, record.second)
		if wanted == key then
			self.Enabled[key] = { first = first, second = second, first_name = string.sub(tostring(record.first_name or first), 1, 48), second_name = string.sub(tostring(record.second_name or second), 1, 48), accepted_at = math.floor(tonumber(record.accepted_at) or os.time()) }
		end
	end
	for key, record in pairs(decoded.pending or {}) do
		local requester, target = validID(record.requester), validID(record.target)
		local wanted = pairKey(requester, target)
		if wanted == key and requester and target then
			self.Pending[key] = { requester = requester, target = target, requester_name = string.sub(tostring(record.requester_name or requester), 1, 48), target_name = string.sub(tostring(record.target_name or target), 1, 48), created_at = math.floor(tonumber(record.created_at) or os.time()) }
		end
	end
end

function Consent:Activate(key)
	local record = self.Enabled[key]
	if not record then return nil end
	local existing = self.ActiveIncidents[key]
	if existing and DRP.Incidents.Get(existing.id) then return existing end
	local first, second = online(record.first), online(record.second)
	if not IsValid(first) or not IsValid(second) or not first:DRPReady() or not second:DRPReady() or not first:Alive() or not second:Alive() then return nil end
	local incident = DRP.Incidents.Create("consensual_pvp", {
		reason = "Permanent mutual PvP consent",
		instigator = first,
		victim = second,
		participants = { participant_a = first, participant_b = second },
		metadata = { consent_key = key }
	})
	if not incident then return nil end
	DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, first, second, "Permanent mutual PvP consent", nil)
	DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, second, first, "Permanent mutual PvP consent", nil)
	DRP.Incidents.AddEvidence(incident, "mutual_consent_restored", nil, nil, "Both players are online")
	self.ActiveIncidents[key] = incident
	return incident
end

function Consent.Allows(first, second)
	if not IsValid(first) or not IsValid(second) then return false end
	local key = pairKey(first:SteamID64(), second:SteamID64())
	if not key or not Consent.Enabled[key] then return false end
	return true, Consent:Activate(key)
end

local function relationEntry(viewerID, record)
	local otherID = record.first == viewerID and record.second or record.first
	local fallback = record.first == otherID and record.first_name or record.second_name
	return { id = otherID, name = currentName(otherID, fallback) }
end

function Consent:Sync(ply)
	if not IsValid(ply) then return end
	local viewerID = ply:SteamID64()
	local incoming, outgoing, enabled = {}, {}, {}
	for _, record in pairs(self.Pending) do
		if record.target == viewerID then incoming[#incoming + 1] = { id = record.requester, name = currentName(record.requester, record.requester_name) }
		elseif record.requester == viewerID then outgoing[#outgoing + 1] = { id = record.target, name = currentName(record.target, record.target_name) } end
	end
	for _, record in pairs(self.Enabled) do if record.first == viewerID or record.second == viewerID then enabled[#enabled + 1] = relationEntry(viewerID, record) end end
	local function sort(entries) table.sort(entries, function(a, b) return string.lower(a.name) < string.lower(b.name) end) end
	sort(incoming) sort(outgoing) sort(enabled)
	net.Start(syncMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		for _, entries in ipairs({ incoming, outgoing, enabled }) do
			net.WriteUInt(math.min(#entries, 63), 6)
			for index = 1, math.min(#entries, 63) do net.WriteString(entries[index].id) net.WriteString(entries[index].name) end
		end
	net.Send(ply)
end

local function syncPair(firstID, secondID)
	local first, second = online(firstID), online(secondID)
	if IsValid(first) then Consent:Sync(first) end
	if IsValid(second) then Consent:Sync(second) end
end

function Consent:Request(requester, target)
	if not IsValid(requester) or not IsValid(target) or requester == target or not target:DRPReady() then return false end
	local key, first, second = pairKey(requester:SteamID64(), target:SteamID64())
	if not key then return false end
	if self.Enabled[key] then DRP.Net.Notify(requester, "Permanent PvP is already enabled with " .. target:DRPName() .. ".", 3) return false end
	if self.Pending[key] then DRP.Net.Notify(requester, "That PvP request is already pending.", 3) return false end
	self.Pending[key] = { requester = requester:SteamID64(), target = target:SteamID64(), requester_name = requester:DRPName(), target_name = target:DRPName(), created_at = os.time() }
	self:Write()
	DRP.Net.Notify(requester, "Permanent PvP request sent to " .. target:DRPName() .. ".", 1)
	DRP.Net.Notify(target, requester:DRPName() .. " wants to permanently enable mutual PvP with you. Accept or reject the request in Settings.", 2)
	net.Start(requestMessage) net.WriteUInt(DRP.ProtocolVersion, 8) net.WriteString(requester:SteamID64()) net.WriteString(requester:DRPName()) net.Send(target)
	syncPair(first, second)
	return true
end

function Consent:Respond(ply, otherID, accepted)
	local key = pairKey(ply:SteamID64(), otherID)
	local pending = key and self.Pending[key]
	if not pending then return false end
	local actorID = ply:SteamID64()
	if accepted and pending.target ~= actorID then return false end
	if not accepted and pending.target ~= actorID and pending.requester ~= actorID then return false end
	self.Pending[key] = nil
	if accepted then
		local _, first, second = pairKey(pending.requester, pending.target)
		self.Enabled[key] = { first = first, second = second, first_name = first == pending.requester and pending.requester_name or pending.target_name, second_name = second == pending.target and pending.target_name or pending.requester_name, accepted_at = os.time() }
		self:Activate(key)
		local requester = online(pending.requester)
		if IsValid(requester) then DRP.Net.Notify(requester, ply:DRPName() .. " accepted your permanent PvP request.", 1) end
		DRP.Net.Notify(ply, "Permanent mutual PvP enabled with " .. currentName(otherID, otherID) .. ".", 1)
	else
		local other = online(otherID)
		if IsValid(other) then DRP.Net.Notify(other, ply:DRPName() .. (pending.target == actorID and " rejected" or " cancelled") .. " the permanent PvP request.", 3) end
	end
	self:Write()
	syncPair(pending.requester, pending.target)
	return true
end

function Consent:Disable(ply, otherID)
	local key = pairKey(ply:SteamID64(), otherID)
	local record = key and self.Enabled[key]
	if not record or (record.first ~= ply:SteamID64() and record.second ~= ply:SteamID64()) then return false end
	self.Enabled[key] = nil
	local incident = self.ActiveIncidents[key]
	if incident and DRP.Incidents.Get(incident.id) then DRP.Incidents.Resolve(incident, "consent_withdrawn", ply:DRPName() .. " disabled permanent PvP") end
	self.ActiveIncidents[key] = nil
	self:Write()
	local other = online(otherID)
	DRP.Net.Notify(ply, "Permanent PvP disabled with " .. currentName(otherID, otherID) .. ".", 1)
	if IsValid(other) then DRP.Net.Notify(other, ply:DRPName() .. " disabled permanent PvP with you.", 2) end
	syncPair(record.first, record.second)
	return true
end

function Consent:Start()
	self:Load()
end

function Consent:Stop()
	self:Write()
end

local function activateFor(ply)
	if not IsValid(ply) or not ply:DRPReady() or not ply:Alive() then return end
	local id = ply:SteamID64()
	for key, record in pairs(Consent.Enabled) do
		if record.first == id or record.second == id then Consent:Activate(key) end
	end
end

hook.Add("PlayerSpawn", "DRP.PVPConsent.Respawn", function(ply)
	timer.Simple(0, function() activateFor(ply) end)
end)

hook.Add("DRPJobChanged", "DRP.PVPConsent.JobChanged", function(ply)
	timer.Simple(0, function() activateFor(ply) end)
end)

DRP.Net.Receive(actionMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "pvp_consent", 0.5, 5) then return end
	local action, targetID = net.ReadUInt(3), validID(net.ReadString())
	if action == 4 then Consent:Sync(ply) return end
	if not targetID then return end
	if action == 0 then Consent:Request(ply, online(targetID))
	elseif action == 1 then Consent:Respond(ply, targetID, true)
	elseif action == 2 then Consent:Respond(ply, targetID, false)
	elseif action == 3 then Consent:Disable(ply, targetID) end
end)

hook.Add("DRPIncidentResolved", "DRP.PVPConsent.IncidentResolved", function(incident)
	if incident.type == "consensual_pvp" and incident.metadata.consent_key then Consent.ActiveIncidents[incident.metadata.consent_key] = nil end
end)

hook.Add("DRPPlayerReady", "DRP.PVPConsent.Sync", function(ply)
	Consent:Sync(ply)
	activateFor(ply)
end)
