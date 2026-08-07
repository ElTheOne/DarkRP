local MESSAGE = "drp_hint_v1"
local queue, current, serial = {}, nil, 0

local function showNext()
	if IsValid(current) or #queue == 0 then return end
	local data = table.remove(queue, 1)
	local colors = DRP.UI.Colors
	local accents = { colors.accent, colors.green, colors.purple, colors.red }
	local accent = accents[(data.kind or 0) + 1] or colors.accent
	local panel = vgui.Create("DPanel")
	current = panel
	panel.DRPHintKey = data.key
	panel:SetSize(math.min(500, ScrW() - 40), 142)
	panel:SetPos(math.floor((ScrW() - panel:GetWide()) * 0.5), 72)
	panel:SetMouseInputEnabled(false)
	panel:SetKeyboardInputEnabled(false)
	panel:SetAlpha(0)
	panel:AlphaTo(255, 0.16)
	panel.Think = function(self)
		local hidden = DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus()
		if self:IsVisible() == hidden then self:SetVisible(not hidden) end
		self:SetPos(math.floor((ScrW() - self:GetWide()) * 0.5), 72)
	end
	panel.Paint = function(_, width, height)
		draw.RoundedBox(9, 0, 0, width, height, Color(colors.background.r, colors.background.g, colors.background.b, 244))
		draw.RoundedBoxEx(9, 0, 0, 5, height, accent, true, false, true, false)
		draw.SimpleText("HINT", "DRP.Admin.Small", 18, 18, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(string.upper(data.title or "Gameplay hint"), "DRP.Admin.Header", 18, 39, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		surface.SetDrawColor(colors.line)
		surface.DrawRect(18, 55, width - 36, 1)
	end

	local description = vgui.Create("DLabel", panel)
	description:SetPos(18, 64)
	description:SetSize(panel:GetWide() - 36, 52)
	description:SetFont("DRP.Admin.Body")
	description:SetTextColor(colors.muted)
	description:SetWrap(true)
	description:SetContentAlignment(7)
	description:SetText(data.description or "")

	local controls = vgui.Create("DLabel", panel)
	controls:SetPos(18, 119)
	controls:SetSize(panel:GetWide() - 36, 16)
	controls:SetFont("DRP.Admin.Small")
	controls:SetTextColor(accent)
	controls:SetContentAlignment(5)
	controls:SetText("F3 / Z  —  TOGGLE FREE CURSOR     •     F4  —  GUIDE & OBJECTIVES")

	serial = serial + 1
	local timerName = "DRP.Hints.Popup." .. serial
	timer.Create(timerName, data.duration or 7, 1, function()
		if not IsValid(panel) then return end
		panel:AlphaTo(0, 0.4, 0, function() if IsValid(panel) then panel:Remove() end end)
	end)
	panel.OnRemove = function()
		timer.Remove(timerName)
		if current == panel then current = nil end
		timer.Simple(0.12, showNext)
	end
end

net.Receive(MESSAGE, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local data = {
		key = net.ReadString(),
		kind = net.ReadUInt(2),
		duration = net.ReadUInt(4),
		title = net.ReadString(),
		description = net.ReadString()
	}
	for _, pending in ipairs(queue) do if pending.key == data.key then return end end
	if IsValid(current) and current.DRPHintKey == data.key then return end
	queue[#queue + 1] = data
	if #queue > 8 then table.remove(queue, 1) end
	showNext()
end)
