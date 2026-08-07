net.Receive("drp_massie_confirm_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	DRP.UI.Confirm(
		"Commit a Massie?",
		"Are you sure you want to commit a massie? Your civic status will be dropped significantly.\n\nFor 30 seconds, every active player will be allowed to damage you. This does not give you permission to damage them.",
		"COMMIT MASSIE",
		function()
			net.Start("drp_massie_accept_v1")
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.SendToServer()
		end,
		DRP.UI.Colors.red
	)
end)
