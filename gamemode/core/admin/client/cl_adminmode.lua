DRP.ClientAdminMode = DRP.ClientAdminMode or false
DRP.ClientAdminCloaked = DRP.ClientAdminCloaked or false
DRP.ClientAdminNoclip = DRP.ClientAdminNoclip or false
DRP.ClientAdminSpectateIndex = DRP.ClientAdminSpectateIndex or 0
DRP.AdminModeClient = DRP.AdminModeClient or {}

function DRP.AdminModeClient.Send(action, target, amount)
	net.Start("drp_admin_mode_action_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.Clamp(math.floor(tonumber(action) or 0), 0, 15), 4)
	net.WriteUInt(IsValid(target) and target:EntIndex() or 0, 13)
	net.WriteUInt(math.Clamp(math.floor(tonumber(amount) or 0), 0, 4294967295), 32)
	net.SendToServer()
end

local function spectateTarget()
	local index = DRP.ClientAdminSpectateIndex or 0
	if index <= 0 then return end
	local target = Entity(index)
	return IsValid(target) and target:IsPlayer() and target or nil
end

net.Receive("drp_admin_mode_state_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	DRP.ClientAdminMode = net.ReadBool()
	DRP.ClientAdminCloaked = net.ReadBool()
	DRP.ClientAdminNoclip = net.ReadBool()
	DRP.ClientAdminSpectateIndex = net.ReadUInt(13)
	if not DRP.ClientAdminMode then DRP.ClientAdminSpectateIndex = 0 end
	hook.Run("DRPAdminModeChanged", DRP.ClientAdminMode)
end)

hook.Add("CalcView", "DRP.AdminMode.RemoteSpectate", function(ply, _, _, fov)
	if ply ~= LocalPlayer() or not DRP.ClientAdminMode then return end
	local target = spectateTarget()
	if not target then return end
	return {
		origin = target:EyePos(),
		angles = target:EyeAngles(),
		fov = fov,
		drawviewer = false
	}
end)

hook.Add("PreDrawViewModel", "DRP.AdminMode.HideViewModel", function()
	if DRP.ClientAdminMode and spectateTarget() then return true end
end)

hook.Add("HUDPaint", "DRP.AdminMode.Status", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	if not DRP.ClientAdminMode then return end
	local colors = DRP.UI.Colors
	local target = spectateTarget()
	local states = {}
	if DRP.ClientAdminNoclip then states[#states + 1] = "NOCLIP" end
	if DRP.ClientAdminCloaked then states[#states + 1] = "CLOAKED" end
	if target then states[#states + 1] = "SPECTATING " .. string.upper(target:Nick()) end
	local detail = #states > 0 and table.concat(states, "  •  ") or "PLAYER COLLISION DISABLED"
	local width, height = 360, 56
	local x, y = math.floor((ScrW() - width) * 0.5), ScrH() - height - 24
	draw.RoundedBox(7, x, y, width, height, colors.background)
	draw.RoundedBoxEx(7, x, y, 5, height, colors.accent, true, false, true, false)
	draw.SimpleText("ADMIN MODE", "DRP.Admin.Header", x + 17, y + 18, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText(detail, "DRP.Admin.Small", x + 17, y + 40, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
end)

surface.CreateFont("DRP.AdminMode.Overhead", { font = "Roboto", size = 62, weight = 900, antialias = true })

hook.Add("PostPlayerDraw", "DRP.AdminMode.Overhead", function(ply)
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	if not IsValid(ply) or ply == LocalPlayer() or not (DRP.Roster and DRP.Roster.Value(ply, "adminMode", false)) then return end
	if LocalPlayer():GetPos():DistToSqr(ply:GetPos()) > 4000000 then return end
	local position = ply:GetPos() + Vector(0, 0, 87)
	local angle = Angle(0, EyeAngles().y - 90, 90)
	cam.Start3D2D(position, angle, 0.075)
		draw.RoundedBox(18, -190, -34, 380, 68, Color(8, 14, 27, 225))
		draw.RoundedBoxEx(18, -190, -34, 12, 68, DRP.UI.Colors.accent, true, false, true, false)
		draw.SimpleText("ADMIN MODE", "DRP.AdminMode.Overhead", 8, 0, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	cam.End3D2D()
end)
