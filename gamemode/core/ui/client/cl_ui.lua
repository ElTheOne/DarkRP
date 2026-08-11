DRP.UI = DRP.UI or {}

local UI = DRP.UI
UI.Colors = {
	background = Color(8, 13, 25, 252),
	panel = Color(15, 24, 43, 252),
	panelHover = Color(28, 43, 72, 255),
	accent = Color(74, 205, 255),
	green = Color(104, 235, 150),
	red = Color(244, 105, 128),
	muted = Color(158, 174, 201),
	line = Color(48, 72, 108),
	accentSoft = Color(35, 101, 139, 180),
	purple = Color(157, 120, 255)
}

surface.CreateFont("DRP.Admin.Title", { font = "Roboto", size = 27, weight = 700 })
surface.CreateFont("DRP.Admin.Header", { font = "Roboto", size = 19, weight = 700 })
surface.CreateFont("DRP.Admin.Body", { font = "Roboto", size = 16, weight = 500 })
surface.CreateFont("DRP.Admin.Small", { font = "Roboto", size = 14, weight = 500 })

-- Tool Gun focus mode is shared by every custom HUD module. World-space tool
-- previews remain available, while normal screen overlays can cheaply opt out.
function UI.ToolgunFocus()
	local frame = FrameNumber()
	if UI.ToolgunFocusFrame == frame then return UI.ToolgunFocusValue == true end
	local ply = LocalPlayer()
	local focused = false
	if IsValid(ply) then
		local weapon = ply:GetActiveWeapon()
		focused = IsValid(weapon) and weapon:GetClass() == "gmod_tool"
	end
	UI.ToolgunFocusFrame = frame
	UI.ToolgunFocusValue = focused
	return focused
end

UI.CursorMode = UI.CursorMode == true
UI.CursorKeyState = UI.CursorKeyState or {}

local function enforceCursorMode()
	if UI.CursorMode and not vgui.CursorVisible() and not gui.IsGameUIVisible() then
		gui.EnableScreenClicker(true)
	end
end

function UI.SetCursorMode(enabled)
	enabled = enabled == true
	if UI.CursorMode == enabled then return end
	UI.CursorMode = enabled
	gui.EnableScreenClicker(enabled)
	if enabled then
		hook.Add("Think", "DRP.UI.CursorMode", enforceCursorMode)
	else
		hook.Remove("Think", "DRP.UI.CursorMode")
	end
	hook.Run("DRPCursorModeChanged", enabled)
end

function UI.ToggleCursorMode()
	UI.SetCursorMode(not UI.CursorMode)
end

local function cursorShortcutAvailable()
	if gui.IsGameUIVisible() or gui.IsConsoleVisible() then return false end
	local focus = vgui.GetKeyboardFocus()
	return not IsValid(focus)
end

hook.Add("PlayerButtonDown", "DRP.UI.CursorMode", function(ply, button)
	if ply ~= LocalPlayer() or not IsFirstTimePredicted() then return end
	if button ~= KEY_F3 and button ~= KEY_Z then return end
	if UI.CursorKeyState[button] or not cursorShortcutAvailable() then return end
	UI.CursorKeyState[button] = true
	UI.ToggleCursorMode()
end)

hook.Add("PlayerButtonUp", "DRP.UI.CursorMode", function(ply, button)
	if ply ~= LocalPlayer() then return end
	if button == KEY_F3 or button == KEY_Z then UI.CursorKeyState[button] = nil end
end)

hook.Add("PlayerBindPress", "DRP.UI.CursorMode", function(_, bind, pressed)
	if not pressed then return end
	bind = string.lower(tostring(bind or ""))
	if input.IsKeyDown(KEY_F3) and string.find(bind, "gm_showspare1", 1, true) then return true end
	if input.IsKeyDown(KEY_Z) and (string.find(bind, "gmod_undo", 1, true) or string.find(bind, "undo", 1, true)) then return true end
end)

-- Other panels may disable the screen clicker when they close. Install this
-- guard only while cursor mode is active instead of paying for an idle Think
-- hook during ordinary gameplay.
hook.Remove("Think", "DRP.UI.CursorMode")
if UI.CursorMode then hook.Add("Think", "DRP.UI.CursorMode", enforceCursorMode) end

local cursorModeText = "CURSOR MODE  •  F3 / Z TO RETURN"
surface.SetFont("DRP.Admin.Small")
local cursorModeWidth, cursorModeHeight = surface.GetTextSize(cursorModeText)
local cursorModeBackground = Color(8, 13, 25, 232)

hook.Add("HUDPaint", "DRP.UI.CursorMode", function()
	if not UI.CursorMode then return end
	local x, y = ScrW() * 0.5 - cursorModeWidth * 0.5 - 14, 24
	draw.RoundedBox(7, x, y, cursorModeWidth + 28, cursorModeHeight + 14, cursorModeBackground)
	draw.RoundedBoxEx(7, x, y, 4, cursorModeHeight + 14, UI.Colors.accent, true, false, true, false)
	draw.SimpleText(cursorModeText, "DRP.Admin.Small", ScrW() * 0.5, y + (cursorModeHeight + 14) * 0.5,
		color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

function UI.Button(parent, text, accent, callback)
	accent = accent or UI.Colors.accent
	local hoverAccent = Color(math.min(accent.r + 15, 255), math.min(accent.g + 15, 255), math.min(accent.b + 15, 255))
	local button = vgui.Create("DButton", parent)
	button:SetText(text)
	button:SetFont("DRP.Admin.Body")
	button:SetTextColor(color_white)
	button.Paint = function(self, width, height)
		local fill = self:IsHovered() and hoverAccent or accent
		draw.RoundedBox(7, 0, 0, width, height, fill)
		draw.RoundedBox(7, 1, 1, width - 2, 2, Color(255, 255, 255, 38))
	end
	button.DoClick = callback
	return button
end

function UI.Frame(title, width, height)
	local frame = vgui.Create("DFrame")
	frame:SetSize(math.min(width, ScrW() - 40), math.min(height, ScrH() - 40))
	frame:Center()
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:SetDraggable(true)
	frame:MakePopup()
	frame.Paint = function(_, frameWidth, frameHeight)
		draw.RoundedBox(10, 0, 0, frameWidth, frameHeight, UI.Colors.background)
		draw.RoundedBoxEx(10, 0, 0, frameWidth, 58, UI.Colors.panel, true, true, false, false)
		draw.RoundedBox(10, 0, 0, 4, frameHeight, UI.Colors.accent)
		draw.SimpleText(title, "DRP.Admin.Title", 20, 29, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		surface.SetDrawColor(UI.Colors.accent)
		surface.DrawRect(0, 57, frameWidth, 3)
	end

	local close = UI.Button(frame, "×", UI.Colors.red, function() frame:Close() end)
	close:SetSize(38, 32)
	close:SetPos(frame:GetWide() - 50, 13)
	close:SetFont("DRP.Admin.Title")
	-- Complex full-screen surfaces resize the shared frame after creation. Keep
	-- the close control addressable so those callers can anchor it to the final
	-- bounds instead of leaving it at the helper's initial clamped width.
	frame.DRPCloseButton = close
	return frame
end

function UI.SectionLabel(parent, text)
	local label = vgui.Create("DLabel", parent)
	label:SetText(text)
	label:SetFont("DRP.Admin.Header")
	label:SetTextColor(color_white)
	label:SetTall(30)
	return label
end

function UI.Card(parent)
	local panel = vgui.Create("DPanel", parent)
	panel.Paint = function(_, width, height)
		draw.RoundedBox(8, 0, 0, width, height, UI.Colors.panel)
		draw.RoundedBox(8, 0, 0, width, 2, UI.Colors.accentSoft)
	end
	return panel
end

function UI.Confirm(title, message, confirmText, callback, accent)
	local frame = UI.Frame(title or "Confirm", 560, 270)
	local body = vgui.Create("DLabel", frame)
	body:SetPos(28, 82)
	body:SetSize(frame:GetWide() - 56, 100)
	body:SetFont("DRP.Admin.Body")
	body:SetTextColor(UI.Colors.muted)
	body:SetWrap(true)
	body:SetContentAlignment(7)
	body:SetText(tostring(message or "Are you sure?"))

	local cancel = UI.Button(frame, "CANCEL", UI.Colors.panelHover, function() frame:Close() end)
	cancel:SetSize(174, 42)
	cancel:SetPos(28, frame:GetTall() - 64)

	local confirm = UI.Button(frame, confirmText or "CONFIRM", accent or UI.Colors.accent, function()
		frame:Close()
		if callback then callback() end
	end)
	confirm:SetSize(302, 42)
	confirm:SetPos(frame:GetWide() - 330, frame:GetTall() - 64)
	return frame
end
