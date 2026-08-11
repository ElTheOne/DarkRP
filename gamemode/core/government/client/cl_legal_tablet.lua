DRP.LegalTablet = DRP.LegalTablet or {
	Warrants = {},
	Scan = { ok = false, message = "No evidence scan captured this session.", findings = {}, warrants = {} },
	RequestMessage = "drp_legal_tablet_request_v1",
	ResponseMessage = "drp_legal_tablet_response_v1"
}

local Client = DRP.LegalTablet

local function request(mode)
	if not util.NetworkStringToID or util.NetworkStringToID(Client.RequestMessage) == 0 then return false end
	net.Start(Client.RequestMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(mode, 2)
	net.SendToServer()
	return true
end

function Client.RequestWarrants(force)
	local now = CurTime()
	if not force and (Client.LastWarrantRequest or 0) + 1 > now then return true end
	Client.LastWarrantRequest = now
	return request(0)
end
function Client.CaptureEvidence() return request(1) end

net.Receive(Client.ResponseMessage, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length = net.ReadUInt(16)
	if length < 1 or length > 60000 then return end
	local raw = net.ReadData(length)
	local decoded = raw and util.Decompress(raw)
	local payload = decoded and util.JSONToTable(decoded)
	if not istable(payload) or not istable(payload.data) then return end
	if tonumber(payload.mode) == 1 then
		Client.Scan = payload.data
		Client.Scan.received_at = CurTime()
		hook.Run("DRPEvidenceScannerChanged", Client.Scan)
	else
		Client.Warrants = istable(payload.data.warrants) and payload.data.warrants or {}
		hook.Run("DRPWarrantsChanged", Client.Warrants)
	end
end)
