DRP.PVPConsentClient = DRP.PVPConsentClient or {
	Incoming = {},
	Outgoing = {},
	Enabled = {},
	LastSync = 0
}

local Consent = DRP.PVPConsentClient

local function send(action, targetID)
	net.Start("drp_pvp_consent_action_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(action, 3)
		net.WriteString(tostring(targetID or ""))
	net.SendToServer()
end

function Consent.Request(targetID) send(0, targetID) end
function Consent.Accept(targetID) send(1, targetID) end
function Consent.Reject(targetID) send(2, targetID) end
function Consent.Disable(targetID) send(3, targetID) end
function Consent.RequestSync() send(4, "") end

local function readEntries()
	local entries = {}
	for index = 1, net.ReadUInt(6) do entries[index] = { id = net.ReadString(), name = net.ReadString() } end
	return entries
end

net.Receive("drp_pvp_consent_sync_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	Consent.Incoming = readEntries()
	Consent.Outgoing = readEntries()
	Consent.Enabled = readEntries()
	Consent.LastSync = RealTime()
	hook.Run("DRPPVPConsentUpdated")
end)

net.Receive("drp_pvp_consent_request_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local requesterID, requesterName = net.ReadString(), net.ReadString()
	surface.PlaySound("buttons/button9.wav")
	Derma_Query(
		requesterName .. " wants to permanently enable mutual PvP with you.\n\nEither player can disable it later from DarkRP Menu > Settings.",
		"Permanent PvP Request",
		"Accept", function() Consent.Accept(requesterID) end,
		"Reject", function() Consent.Reject(requesterID) end,
		"View Later", function() end
	)
end)
