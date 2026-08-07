local UI = DRP.UI
local colors = UI.Colors

local CHAT_LOCAL = 1
local CHAT_TEAM = 2
local CHAT_GLOBAL = 3
local MAX_MESSAGES = 200
local MAX_HISTORY = 64
local PLAYER_CARD_CLEARANCE = 216
local chatSounds = CreateClientConVar("drp_chat_sounds", "1", true, false, "Play a sound when a chat message arrives")
local recentMessages = CreateClientConVar("drp_chat_recent", "1", true, false, "Show recent messages while chat is closed")

local categories = {
	[CHAT_LOCAL] = { name = "LOCAL", color = Color(80, 200, 150) },
	[CHAT_TEAM] = { name = "TEAM", color = Color(90, 150, 235) },
	[CHAT_GLOBAL] = { name = "GLOBAL", color = Color(190, 115, 235) }
}

local function wrapText(text, font, maximumWidth)
	surface.SetFont(font)
	local lines = {}
	maximumWidth = math.max(1, tonumber(maximumWidth) or 1)
	for paragraph in string.gmatch(tostring(text or "") .. "\n", "([^\n]*)\n") do
		local line = ""
		for word in string.gmatch(paragraph, "%S+") do
			local wordWidth = surface.GetTextSize(word)
			if wordWidth > maximumWidth then
				if line ~= "" then lines[#lines + 1] = line; line = "" end
				local chunk = ""
				for index = 1, #word do
					local candidate = chunk .. word:sub(index, index)
					if surface.GetTextSize(candidate) > maximumWidth and chunk ~= "" then
						lines[#lines + 1] = chunk
						chunk = word:sub(index, index)
					else
						chunk = candidate
					end
				end
				if chunk ~= "" then lines[#lines + 1] = chunk end
			else
				local candidate = line == "" and word or (line .. " " .. word)
				if surface.GetTextSize(candidate) > maximumWidth and line ~= "" then
					lines[#lines + 1] = line
					line = word
				else
					line = candidate
				end
			end
		end
		if line == "" then
			lines[#lines + 1] = ""
		else
			lines[#lines + 1] = line
		end
	end
	return lines
end

local Chat = {
	messages = {},
	unread = { 0, 0, 0 },
	hidden = { false, false, false },
	solo = nil,
	sendCategory = CHAT_LOCAL,
	open = false,
	history = {},
	historyIndex = 1,
	historyDraft = "",
	interactingUntil = 0
}
DRP.Chat = Chat

surface.CreateFont("DRP.Chat.Title", { font = "Roboto", size = 18, weight = 800 })
surface.CreateFont("DRP.Chat.Button", { font = "Roboto", size = 14, weight = 700 })
surface.CreateFont("DRP.Chat.Name", { font = "Roboto", size = 16, weight = 700 })
surface.CreateFont("DRP.Chat.Body", { font = "Roboto", size = 16, weight = 500 })
surface.CreateFont("DRP.Chat.Small", { font = "Roboto", size = 13, weight = 500 })

local function categoryVisible(category)
	if Chat.hidden[category] then return false end
	return Chat.solo == nil or Chat.solo == category
end

local function scrollToBottom()
	if not IsValid(Chat.scroll) then return end
	timer.Simple(0, function()
		if not IsValid(Chat.scroll) then return end
		local bar = Chat.scroll:GetVBar()
		bar:SetScroll(bar.CanvasSize)
	end)
end

local function isNearBottom()
	if not IsValid(Chat.scroll) then return true end
	local bar = Chat.scroll:GetVBar()
	if not IsValid(bar) then return true end
	local maximum = math.max(0, (tonumber(bar.CanvasSize) or 0) - (tonumber(bar.BarSize) or 0))
	return bar:GetScroll() >= maximum - 12
end

local function markInteraction(duration)
	Chat.interactingUntil = math.max(Chat.interactingUntil or 0, RealTime() + (tonumber(duration) or 2))
end

local function rememberMessage(text)
	text = string.Trim(tostring(text or ""))
	if text == "" then return end
	if Chat.history[#Chat.history] ~= text then
		Chat.history[#Chat.history + 1] = text
		if #Chat.history > MAX_HISTORY then table.remove(Chat.history, 1) end
	end
	Chat.historyIndex = #Chat.history + 1
	Chat.historyDraft = ""
end

local function navigateHistory(entry, direction)
	if not IsValid(entry) or #Chat.history == 0 then return end
	local endIndex = #Chat.history + 1
	if Chat.historyIndex < 1 or Chat.historyIndex > endIndex then Chat.historyIndex = endIndex end
	if direction < 0 then
		if Chat.historyIndex == endIndex then Chat.historyDraft = entry:GetValue() end
		Chat.historyIndex = math.max(1, Chat.historyIndex - 1)
	else
		Chat.historyIndex = math.min(endIndex, Chat.historyIndex + 1)
	end
	local value = Chat.historyIndex == endIndex and Chat.historyDraft or Chat.history[Chat.historyIndex]
	entry:SetText(value or "")
	entry:SetCaretPos(#(value or ""))
end

local function copyMenu(message)
	markInteraction(8)
	local menu = DermaMenu()
	menu:AddOption("Copy message", function() SetClipboardText(tostring(message.text or "")) end):SetIcon("icon16/page_copy.png")
	menu:AddOption("Copy full line", function()
		SetClipboardText("[" .. categories[message.category].name .. "] " .. tostring(message.name or "Unknown") .. ": " .. tostring(message.text or ""))
	end):SetIcon("icon16/comments.png")
	menu:AddOption("Copy sender name", function() SetClipboardText(tostring(message.name or "Unknown")) end):SetIcon("icon16/user.png")
	menu:Open()
end

local function addRow(message)
	if not IsValid(Chat.scroll) or not categoryVisible(message.category) then return end
	local category = categories[message.category]
	local row = vgui.Create("DPanel", Chat.scroll)
	row:Dock(TOP)
	row:DockMargin(0, 0, 0, 5)
	row:SetTall(42)
	row:SetMouseInputEnabled(true)
	row:SetCursor("hand")
	row.Paint = function(_, width, height)
		draw.RoundedBox(6, 0, 0, width, height, Color(17, 23, 33, 235))
		draw.RoundedBoxEx(6, 0, 0, 3, height, category.color, true, false, true, false)
		draw.SimpleText(category.name, "DRP.Chat.Small", 12, 10, category.color, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(message.name, "DRP.Chat.Name", 76, 10, message.nameColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	local body = vgui.Create("DLabel", row)
	body:SetFont("DRP.Chat.Body")
	body:SetTextColor(color_white)
	body:SetText(message.text)
	body:SetWrap(true)
	body:SetAutoStretchVertical(true)
	body:SetMouseInputEnabled(true)
	body:SetCursor("hand")
	row.PerformLayout = function(self, width)
		local textLines = wrapText(message.text, "DRP.Chat.Body", math.max(width - 24, 24))
		body:SetText(table.concat(textLines, "\n"))
		body:SetPos(12, 20)
		body:SetWide(math.max(width - 24, 32))
		body:SizeToContentsY()
		local wanted = math.max(42, body:GetTall() + 27)
		if self:GetTall() ~= wanted then self:SetTall(wanted) end
	end
	local function messagePressed(_, code)
		markInteraction(code == MOUSE_RIGHT and 8 or 4)
		if code == MOUSE_RIGHT then copyMenu(message) end
	end
	row.OnMousePressed = messagePressed
	body.OnMousePressed = messagePressed
	row:SetTooltip(message.text .. "\nRight-click to copy")
	body:SetTooltip(message.text .. "\nRight-click to copy")
	return row
end

local function rebuildMessages()
	if not IsValid(Chat.scroll) then return end
	Chat.scroll:Clear()
	for _, message in ipairs(Chat.messages) do addRow(message) end
	scrollToBottom()
end

local function clearUnread(category)
	Chat.unread[category] = 0
	if IsValid(Chat.buttons and Chat.buttons[category]) then Chat.buttons[category]:InvalidateLayout() end
end

local function markVisibleRead()
	for category = CHAT_LOCAL, CHAT_GLOBAL do
		if categoryVisible(category) then clearUnread(category) end
	end
end

local function refocusEntry()
	if Chat.open and IsValid(Chat.entry) then Chat.entry:RequestFocus() end
end

local function setSolo(category)
	if Chat.solo == category then
		Chat.solo = nil
	else
		Chat.solo = category
		Chat.sendCategory = category
		Chat.hidden[category] = false
	end
	markVisibleRead()
	rebuildMessages()
	refocusEntry()
end

local function toggleFilter(category)
	Chat.hidden[category] = not Chat.hidden[category]
	if not Chat.hidden[category] then clearUnread(category) end
	rebuildMessages()
	refocusEntry()
end

local function buildChatbox()
	if IsValid(Chat.frame) then return end

	local frame = vgui.Create("DFrame")
	Chat.frame = frame
	frame:SetSize(math.min(680, ScrW() - 56), 378)
	frame:SetPos(28, math.max(24, ScrH() - frame:GetTall() - PLAYER_CARD_CLEARANCE))
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:SetDraggable(false)
	frame:SetDeleteOnClose(false)
	frame.Paint = function(_, width, height)
		draw.RoundedBox(10, 0, 0, width, height, colors.background)
		draw.RoundedBoxEx(10, 0, 0, width, 58, colors.panel, true, true, false, false)
		draw.SimpleText("CHAT", "DRP.Chat.Title", 18, 17, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("↑/↓ history  •  Right-click a message to copy", "DRP.Chat.Small", 18, 39, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		surface.SetDrawColor(colors.accent)
		surface.DrawRect(0, 57, width, 2)
	end
	frame.OnKeyCodePressed = function(_, key)
		if key == KEY_ESCAPE then Chat.Close() end
	end

	Chat.buttons = {}
	for category = CHAT_LOCAL, CHAT_GLOBAL do
		local data = categories[category]
		local button = vgui.Create("DButton", frame)
		Chat.buttons[category] = button
		button:SetPos(frame:GetWide() - 300 + ((category - 1) * 94), 13)
		button:SetSize(88, 32)
		button:SetText("")
		button:SetTooltip("Left click to show only " .. string.lower(data.name) .. "; right click to hide/show it")
		button.Paint = function(self, width, height)
			local selected = Chat.solo == category
			local filtered = Chat.hidden[category]
			local fill = selected and data.color or (self:IsHovered() and colors.panelHover or Color(28, 37, 50))
			draw.RoundedBox(6, 0, 0, width, height, fill)
			if filtered then
				surface.SetDrawColor(110, 120, 135, 210)
				surface.DrawRect(7, height * 0.5, width - 14, 1)
			end
			draw.SimpleText(data.name, "DRP.Chat.Button", width * 0.5, height * 0.5, selected and Color(10, 18, 25) or (filtered and colors.muted or color_white), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			local unread = Chat.unread[category] or 0
			if unread > 0 then
				local label = unread > 99 and "99+" or tostring(unread)
				draw.RoundedBox(8, width - 25, 2, 22, 16, colors.red)
				draw.SimpleText(label, "DRP.Chat.Small", width - 14, 10, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		end
		button.DoClick = function() setSolo(category) end
		button.DoRightClick = function() toggleFilter(category) end
	end

	local scroll = vgui.Create("DScrollPanel", frame)
	Chat.scroll = scroll
	scroll:SetPos(12, 70)
	scroll:SetSize(frame:GetWide() - 24, frame:GetTall() - 124)
	local bar = scroll:GetVBar()
	bar:SetWide(5)
	bar.Paint = function() end
	bar.btnUp.Paint = function() end
	bar.btnDown.Paint = function() end
	bar.btnGrip.Paint = function(_, width, height) draw.RoundedBox(3, 0, 0, width, height, colors.line) end
	local inheritedMouseWheel = scroll.OnMouseWheeled
	scroll.OnMouseWheeled = function(self, delta)
		markInteraction(3)
		if inheritedMouseWheel then return inheritedMouseWheel(self, delta) end
	end

	local entryBack = vgui.Create("DPanel", frame)
	entryBack:SetPos(12, frame:GetTall() - 46)
	entryBack:SetSize(frame:GetWide() - 24, 36)
	entryBack.Paint = function(_, width, height)
		draw.RoundedBox(6, 0, 0, width, height, Color(15, 21, 30, 255))
		draw.RoundedBoxEx(6, 0, 0, 86, height, categories[Chat.sendCategory].color, true, false, true, false)
		draw.SimpleText(categories[Chat.sendCategory].name, "DRP.Chat.Button", 43, height * 0.5, Color(10, 18, 25), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	local entry = vgui.Create("DTextEntry", entryBack)
	Chat.entry = entry
	entry:SetPos(96, 4)
	entry:SetSize(entryBack:GetWide() - 104, 28)
	entry:SetFont("DRP.Chat.Body")
	entry:SetTextColor(color_white)
	entry:SetPlaceholderText("Send a message…")
	entry:SetPlaceholderColor(colors.muted)
	entry:SetDrawBackground(false)
	entry:SetUpdateOnType(true)
	local function submitEntry(self)
		if self.DRPMessageSubmitted then return end
		local text = string.Trim(self:GetValue())
		if text == "" then Chat.Close() return end
		self.DRPMessageSubmitted = true
		rememberMessage(text)
		local normalized = string.lower(text)
		if string.StartWith(text, "/") or normalized == "!admin" or normalized == "!adminmode" or normalized == "adminmode" then
			RunConsoleCommand("say", text)
		else
			net.Start("drp_chat_send_v1")
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.WriteUInt(Chat.sendCategory, 2)
			net.WriteString(text)
			net.SendToServer()
		end
		self:SetText("")
		Chat.Close()
	end
	entry.OnEnter = submitEntry
	local inheritedKeyCodeTyped = entry.OnKeyCodeTyped
	entry.OnKeyCodeTyped = function(self, key)
		if key == KEY_UP then
			navigateHistory(self, -1)
			return
		end
		if key == KEY_DOWN then
			navigateHistory(self, 1)
			return
		end
		if key == KEY_ENTER or key == KEY_PAD_ENTER then
			submitEntry(self)
			return
		end
		if key == KEY_ESCAPE then
			Chat.Close()
			gui.HideGameUI()
			return
		end
		return inheritedKeyCodeTyped(self, key)
	end

	rebuildMessages()
	frame:SetVisible(false)
end

function Chat.Open(teamChat)
	buildChatbox()
	if teamChat then
		Chat.sendCategory = CHAT_TEAM
		Chat.solo = CHAT_TEAM
		Chat.hidden[CHAT_TEAM] = false
		clearUnread(CHAT_TEAM)
	end
	Chat.open = true
	Chat.historyIndex = #Chat.history + 1
	Chat.historyDraft = ""
	Chat.interactingUntil = 0
	Chat.entry.DRPMessageSubmitted = false
	Chat.frame:SetVisible(true)
	Chat.frame:MakePopup()
	Chat.entry:RequestFocus()
	markVisibleRead()
	rebuildMessages()
end

function Chat.Close()
	if not IsValid(Chat.frame) then return end
	Chat.open = false
	Chat.entry:SetText("")
	Chat.frame:SetVisible(false)
	gui.EnableScreenClicker(false)
	hook.Run("FinishChat")
end

function Chat.Add(category, sender, name, text, nameColor)
	local job = IsValid(sender) and sender:DRPJob() or nil
	local message = {
		category = category,
		name = name,
		text = text,
		nameColor = nameColor or (job and job.color or colors.muted),
		received = CurTime()
	}
	Chat.messages[#Chat.messages + 1] = message
	if #Chat.messages > MAX_MESSAGES then table.remove(Chat.messages, 1) end

	if not categoryVisible(category) then
		Chat.unread[category] = math.min((Chat.unread[category] or 0) + 1, 999)
	elseif Chat.open then
		local shouldFollow = isNearBottom() and RealTime() >= (Chat.interactingUntil or 0)
		addRow(message)
		if shouldFollow then scrollToBottom() end
	end

	if chatSounds:GetBool() then chat.PlaySound() end
end

function Chat.System(text, kind)
	local noticeColors = { colors.accent, colors.green, Color(255, 190, 75), colors.red }
	Chat.Add(CHAT_GLOBAL, nil, "SYSTEM", tostring(text or ""), noticeColors[(tonumber(kind) or 0) + 1])
end

net.Receive("drp_chat_receive_v1", function()
	local version = net.ReadUInt(8)
	local category = net.ReadUInt(2)
	local sender = net.ReadEntity()
	local name = string.sub(net.ReadString(), 1, 64)
	local text = string.sub(net.ReadString(), 1, 240)
	if version ~= DRP.ProtocolVersion or not categories[category] then return end
	Chat.Add(category, sender, name, text)
end)

hook.Add("StartChat", "DRP.Chat.Open", function(teamChat)
	Chat.Open(teamChat)
	return true
end)

hook.Add("OnPlayerChat", "DRP.Chat.SuppressStock", function()
	return true
end)

hook.Add("ChatText", "DRP.Chat.SystemText", function(_, name, text, messageType)
	name = tostring(name or "")
	text = tostring(text or "")
	if text == "" or messageType == "chat" then return true end
	Chat.System(name ~= "" and (name .. " " .. text) or text, 0)
	return true
end)

hook.Add("HUDShouldDraw", "DRP.Chat.HideStock", function(name)
	if name == "CHudChat" then return false end
end)

hook.Add("HUDPaint", "DRP.Chat.Recent", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	if Chat.open or not recentMessages:GetBool() then return end
	local shown = {}
	for index = #Chat.messages, 1, -1 do
		local message = Chat.messages[index]
		if CurTime() - message.received <= 9 and categoryVisible(message.category) then
			table.insert(shown, 1, message)
			if #shown >= 5 then break end
		end
	end

	local x, width = 28, math.min(620, ScrW() - 56)
	local rows = {}
	local totalHeight = 0
	for _, message in ipairs(shown) do
		surface.SetFont("DRP.Chat.Name")
		local textX = x + 79 + surface.GetTextSize(message.name .. ":")
		local bodyWidth = math.max(width - (textX - x) - 12, 24)
		local lines = wrapText(message.text, "DRP.Chat.Body", bodyWidth)
		if #lines == 0 then lines[1] = message.text end
		local height = math.max(29, 12 + (#lines * 16))
		rows[#rows + 1] = { message = message, lines = lines, textX = textX, height = height }
		totalHeight = totalHeight + height + 8
	end
	local y = ScrH() - PLAYER_CARD_CLEARANCE - totalHeight
	for _, row in ipairs(rows) do
		local message, lines, textX, height = row.message, row.lines, row.textX, row.height
		local category = categories[message.category]
		surface.SetFont("DRP.Chat.Name")
		local nameWidth = surface.GetTextSize(message.name .. ":")
		draw.RoundedBox(5, x, y, width, height, Color(12, 16, 24, 210))
		draw.RoundedBoxEx(5, x, y, 3, height, category.color, true, false, true, false)
		draw.SimpleText(category.name, "DRP.Chat.Small", x + 11, math.Clamp(y + (height * 0.5), y + 8, y + 21), category.color, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(message.name .. ":", "DRP.Chat.Name", x + 72, y + 15, message.nameColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		for index, line in ipairs(lines) do
			draw.SimpleText(line, "DRP.Chat.Body", textX, y + 12 + ((index - 1) * 16), color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		end
		y = y + height + 8
	end
end)
