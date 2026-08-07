local colors = DRP.UI.Colors
local serverAnnouncement

net.Receive("drp_punishment_announce_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local isBlacklist = net.ReadBool()
	local targetName = string.sub(net.ReadString(), 1, 64)
	local offense = string.sub(net.ReadString(), 1, 160)
	local issuedAt = net.ReadUInt(32)
	local includeIssuer = net.ReadBool()
	local issuer = includeIssuer and string.sub(net.ReadString(), 1, 64) or ""
	local kind = isBlacklist and "BLACKLIST" or "WARNING"
	local text = kind .. " — " .. targetName .. " — Offense: " .. offense .. " — " .. os.date("%d %b %Y %H:%M", issuedAt)
	if includeIssuer then text = text .. " — Issued by " .. issuer end
	if DRP.Chat and DRP.Chat.System then
		DRP.Chat.System(text, isBlacklist and 3 or 2)
	else
		chat.AddText(isBlacklist and colors.red or Color(235, 170, 65), "[" .. kind .. "] ", color_white, text)
	end
end)

local function wrapAnnouncement(text, font, maximumWidth)
	surface.SetFont(font)
	local lines = {}
	for paragraph in string.gmatch(tostring(text or "") .. "\n", "([^\n]*)\n") do
		local line = ""
		for word in string.gmatch(paragraph, "%S+") do
			local candidate = line == "" and word or (line .. " " .. word)
			local width = surface.GetTextSize(candidate)
			if width > maximumWidth and line ~= "" then
				lines[#lines + 1] = line
				line = word
			else
				line = candidate
			end
		end
		if line ~= "" then lines[#lines + 1] = line end
	end
	return lines
end

net.Receive("drp_server_announcement_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local title = string.sub(net.ReadString(), 1, 48)
	local message = string.sub(net.ReadString(), 1, 300)
	serverAnnouncement = { title = title, message = message, expires = RealTime() + 12 }
	if DRP.Chat and DRP.Chat.System then
		DRP.Chat.System("ANNOUNCEMENT — " .. title .. " — " .. string.Replace(message, "\n", " "), 0)
	else
		chat.AddText(colors.accent, "[ANNOUNCEMENT] ", color_white, title .. ": " .. message)
	end
	surface.PlaySound("buttons/button15.wav")
end)

hook.Add("HUDPaint", "DRP.ServerAnnouncement", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	if not serverAnnouncement or serverAnnouncement.expires <= RealTime() then serverAnnouncement = nil return end
	local width = math.min(820, ScrW() - 40)
	local lines = wrapAnnouncement(serverAnnouncement.message, "DRP.Admin.Body", width - 48)
	local height = 70 + math.max(#lines, 1) * 20
	local x, y = (ScrW() - width) * 0.5, 52
	local alpha = math.Clamp((serverAnnouncement.expires - RealTime()) * 255, 0, 255)
	local background = Color(colors.background.r, colors.background.g, colors.background.b, math.min(alpha, colors.background.a))
	local accent = Color(colors.accent.r, colors.accent.g, colors.accent.b, alpha)
	local white = Color(255, 255, 255, alpha)
	local muted = Color(colors.muted.r, colors.muted.g, colors.muted.b, alpha)
	draw.RoundedBox(9, x, y, width, height, background)
	draw.RoundedBoxEx(9, x, y, 7, height, accent, true, false, true, false)
	draw.SimpleText(string.upper(serverAnnouncement.title), "DRP.Admin.Header", x + 24, y + 24, white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText("GLOBAL SERVER ANNOUNCEMENT", "DRP.Admin.Small", x + width - 20, y + 24, accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	if #lines == 0 then lines[1] = serverAnnouncement.message end
	for index, line in ipairs(lines) do
		draw.SimpleText(line, "DRP.Admin.Body", x + 24, y + 53 + (index - 1) * 20, muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
end)

