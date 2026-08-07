DRP.ClientRoleOverview = DRP.ClientRoleOverview or nil

net.Receive("drp_roles_snapshot_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length = net.ReadUInt(16)
	local compressed = length > 0 and net.ReadData(length) or ""
	local decoded = util.JSONToTable(util.Decompress(compressed) or "")
	if not istable(decoded) then return end
	DRP.ClientRoleOverview = decoded
	hook.Run("DRPRoleOverviewChanged", decoded)
end)

DRP.Roles = DRP.Roles or {}
local nextRequest = 0

function DRP.Roles.Request()
	if RealTime() < nextRequest then return false end
	nextRequest = RealTime() + 1
	net.Start("drp_roles_request_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.SendToServer()
	return true
end
