local function hasPermission(permission)
	return DRP.ClientOwner or DRP.AdminMaskHas(DRP.ClientAdminMask, permission)
end

local function canUseShortcut()
	return not gui.IsGameUIVisible() and not IsValid(vgui.GetKeyboardFocus())
end

hook.Add("PlayerButtonDown", "DRP.Admin.Shortcuts", function(ply, button)
	if ply ~= LocalPlayer() or not IsFirstTimePredicted() or not canUseShortcut() then return end
	if button == KEY_BACKSLASH and (hasPermission("panel") or hasPermission("server_interactions")) then
		net.Start("drp_admin_request_v1")
		net.SendToServer()
	elseif button == KEY_RBRACKET and hasPermission("doors") then
		net.Start("drp_door_admin_request_v1")
		net.SendToServer()
	elseif button == KEY_L and hasPermission("logs") then
		net.Start("drp_audit_request_v1")
		net.SendToServer()
	end
end)

hook.Add("DRPAdminModeChanged", "DRP.Admin.RefreshForMode", function()
	if not (DRP.AdminUI and DRP.AdminUI.IsOpen and DRP.AdminUI.IsOpen()) then return end
	timer.Create("DRP.Admin.ModeRefresh", 0.8, 1, function()
		if not (DRP.AdminUI and DRP.AdminUI.IsOpen and DRP.AdminUI.IsOpen()) then return end
		net.Start("drp_admin_request_v1")
		net.SendToServer()
	end)
end)
