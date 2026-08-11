local colors = DRP.UI.Colors
local notices = {}
local titlePrefixes = {
	[0] = "PVP ENDED WITH ",
	[1] = "PVP AUTHORIZED AGAINST ",
	[2] = "PVP THREAT: ",
	[3] = "MUTUAL PVP WITH "
}
local threatColor = Color(255, 190, 75)

surface.CreateFont("DRP.PVP.Title", { font = "Roboto", size = 18, weight = 800 })
surface.CreateFont("DRP.PVP.Body", { font = "Roboto", size = 15, weight = 500 })

net.Receive("drp_pvp_state_v1", function()
	local version = net.ReadUInt(8)
	local state = net.ReadUInt(2)
	local otherName = string.sub(net.ReadString(), 1, 64)
	local reason = string.sub(net.ReadString(), 1, 96)
	local grace = net.ReadUInt(8)
	if version ~= DRP.ProtocolVersion then return end

	local detail = reason
	if state == 1 then detail = detail .. "  •  One-way until you escalate" end
	if state == 2 then detail = detail .. "  •  Return fire currently locked" end
	if state ~= 0 and grace > 0 then detail = detail .. "  •  " .. grace .. "s grace" end

	notices[#notices + 1] = {
		state = state,
		title = (titlePrefixes[state] or "PVP WITH ") .. string.upper(otherName),
		detail = detail,
		started = CurTime(),
		expires = CurTime() + 5
	}
	if #notices > 4 then table.remove(notices, 1) end
	surface.PlaySound(state ~= 0 and "buttons/button14.wav" or "buttons/button19.wav")
end)

hook.Add("HUDPaint", "DRP.PVP.Notices", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	local now = CurTime()
	for index = #notices, 1, -1 do
		if notices[index].expires <= now then table.remove(notices, index) end
	end

	local width = math.min(500, ScrW() - 40)
	local x = (ScrW() - width) * 0.5
	for index, notice in ipairs(notices) do
		local age = now - notice.started
		local remaining = notice.expires - now
		local alpha = math.Clamp(math.min(age * 5, remaining * 4), 0, 1) * 255
		local y = 72 + ((index - 1) * 68)
		local accent = notice.state == 0 and colors.green or (notice.state == 2 and threatColor or colors.red)

		draw.RoundedBox(8, x, y, width, 56, Color(12, 16, 24, math.floor(alpha * 0.96)))
		draw.RoundedBoxEx(8, x, y, 5, 56, Color(accent.r, accent.g, accent.b, alpha), true, false, true, false)
		draw.SimpleText(notice.title, "DRP.PVP.Title", x + 18, y + 18, Color(255, 255, 255, alpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(notice.detail, "DRP.PVP.Body", x + 18, y + 39, Color(colors.muted.r, colors.muted.g, colors.muted.b, alpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
end)
