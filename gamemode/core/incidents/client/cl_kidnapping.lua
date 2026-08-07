local state
local interaction

surface.CreateFont("DRP.Kidnap.Title", { font = "Roboto", size = 17, weight = 850 })
surface.CreateFont("DRP.Kidnap.Body", { font = "Roboto", size = 14, weight = 600 })

net.Receive("drp_kidnap_state_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not net.ReadBool() then state = nil return end
	state = {
		incidentID = net.ReadUInt(32),
		victim = net.ReadBool(),
		other = net.ReadEntity(),
		effects = net.ReadUInt(3),
		overdue = net.ReadBool(),
		deadline = CurTime() + net.ReadUInt(16)
	}
end)

net.Receive("drp_kidnap_interaction_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not net.ReadBool() then interaction = nil return end
	local label = net.ReadString()
	local duration = net.ReadFloat()
	interaction = { label = label, started = CurTime(), duration = math.max(0.1, duration) }
end)

local function effect(bitValue)
	return state and bit.band(state.effects or 0, bitValue) ~= 0
end

hook.Add("HUDPaintBackground", "DRP.Kidnapping.Blindfold", function()
	if state and state.victim and effect(2) then
		surface.SetDrawColor(0, 0, 0, 246)
		surface.DrawRect(0, 0, ScrW(), ScrH())
	end
end)

hook.Add("HUDPaint", "DRP.Kidnapping.Status", function()
	local colors = DRP.UI and DRP.UI.Colors
	if not colors then return end
	if state then
		local width, height = 360, 72
		local x, y = (ScrW() - width) * 0.5, ScrH() - 170
		draw.RoundedBox(8, x, y, width, height, Color(10, 14, 23, 238))
		draw.RoundedBoxEx(8, x, y, 5, height, state.overdue and colors.red or colors.purple or colors.accent, true, false, true, false)
		draw.SimpleText(state.victim and "KIDNAPPED" or "KIDNAPPING ACTIVE", "DRP.Kidnap.Title", x + 17, y + 17, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		local remaining = math.max(0, math.ceil(state.deadline - CurTime()))
		draw.SimpleText(state.overdue and "OVERDUE • MUTUAL PVP" or (string.FormattedTime(remaining, "%02i:%02i") .. " • VICTIM RETALIATION"),
			"DRP.Kidnap.Body", x + width - 15, y + 17, state.overdue and colors.red or colors.accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		local names = {}
		if effect(1) then names[#names + 1] = "KNOCKED OUT" end
		if effect(2) then names[#names + 1] = "BLINDFOLDED" end
		if effect(4) then names[#names + 1] = "GAGGED" end
		if #names == 0 then names[1] = "NO ACTIVE INFLICTIONS" end
		draw.SimpleText(table.concat(names, "  •  "), "DRP.Kidnap.Body", x + 17, y + 47, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	if interaction then
		local progress = math.Clamp((CurTime() - interaction.started) / interaction.duration, 0, 1)
		local width, height = 330, 54
		local x, y = (ScrW() - width) * 0.5, ScrH() * 0.68
		draw.RoundedBox(8, x, y, width, height, Color(10, 14, 23, 242))
		draw.SimpleText(interaction.label, "DRP.Kidnap.Body", x + 14, y + 17, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.RoundedBox(4, x + 14, y + 34, width - 28, 8, Color(36, 47, 65, 235))
		draw.RoundedBox(4, x + 14, y + 34, (width - 28) * progress, 8, colors.accent)
		if progress >= 1 then interaction = nil end
	end
end)

hook.Add("CalcView", "DRP.Kidnapping.KnockoutView", function(ply, origin, angles, fov)
	if not state or not state.victim or not effect(1) then return end
	return { origin = origin, angles = Angle(math.Clamp(angles.p + 16, -89, 89), angles.y, angles.r + 10), fov = fov * 0.9, drawviewer = false }
end)
