local Calendar = DRP.Calendar
if not Calendar then return end

net.Receive(Calendar.SyncMessage, function()
	if net.ReadUInt(8) ~= Calendar.ProtocolVersion then return end
	Calendar.ClientRoleplayUnix = net.ReadDouble()
	Calendar.ClientScale = net.ReadFloat()
	Calendar.ClientReceivedAt = RealTime()
	hook.Run("DRPCalendarSynchronized", Calendar.ClientRoleplayUnix)
end)

hook.Add("InitPostEntity", "DRP.Calendar.Request", function()
	net.Start(Calendar.RequestMessage)
	net.SendToServer()
end)

concommand.Add("drp_calendar_client_status", function()
	local timestamp = Calendar.Now()
	print(string.format(
		"[DRP CALENDAR CLIENT] synchronized=%s scale=%.2fx timestamp=%.3f display=%s",
		tostring(Calendar.ClientRoleplayUnix > 0),
		Calendar.ClientScale,
		timestamp,
		Calendar.Format(timestamp, true)
	))
end)
