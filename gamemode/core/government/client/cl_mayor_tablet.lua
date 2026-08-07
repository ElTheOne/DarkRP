DRP.MayorTablet = DRP.MayorTablet or {}

local Tablet = DRP.MayorTablet
Tablet.Width = 970
Tablet.Height = 725
Tablet.Page = Tablet.Page or "overview"

surface.CreateFont("DRP.Tablet.Brand", { font = "Roboto", size = 34, weight = 900, extended = true })
surface.CreateFont("DRP.Tablet.Title", { font = "Roboto", size = 28, weight = 800, extended = true })
surface.CreateFont("DRP.Tablet.Header", { font = "Roboto", size = 21, weight = 800, extended = true })
surface.CreateFont("DRP.Tablet.Body", { font = "Roboto", size = 18, weight = 550, extended = true })
surface.CreateFont("DRP.Tablet.Small", { font = "Roboto", size = 15, weight = 550, extended = true })

local colorBackground = Color(5, 13, 27, 255)
local colorSidebar = Color(8, 21, 40, 255)
local colorPanel = Color(13, 31, 55, 252)
local colorPanelHover = Color(22, 49, 80, 255)
local colorAccent = Color(67, 216, 255)
local colorGreen = Color(91, 225, 160)
local colorAmber = Color(246, 183, 79)
local colorRed = Color(247, 101, 126)
local colorText = Color(235, 244, 255)
local colorMuted = Color(143, 166, 193)
local colorLine = Color(41, 72, 106)

local function updateCursor(panel)
	if iPhone and isfunction(iPhone.cursorUpdate) then iPhone.cursorUpdate(panel) end
end

local function issue(command)
	command = string.Trim(tostring(command or ""))
	if command == "" then return end
	RunConsoleCommand("say", "/" .. command)
	surface.PlaySound("ui/buttonclickrelease.wav")
end

local function text(parent, value, font, color, x, y, width, height, wrap)
	local label = vgui.Create("DLabel", parent)
	label:SetPos(x, y)
	label:SetSize(width, height)
	label:SetText(tostring(value or ""))
	label:SetFont(font or "DRP.Tablet.Body")
	label:SetTextColor(color or colorText)
	label:SetWrap(wrap == true)
	label:SetAutoStretchVertical(wrap == true)
	return label
end

local function button(parent, label, x, y, width, height, callback, accent)
	local control = vgui.Create("DButton", parent)
	control:SetPos(x, y)
	control:SetSize(width, height)
	control:SetText("")
	function control:Paint(w, h)
		updateCursor(self)
		local active = self.Depressed or self.Hovered
		draw.RoundedBox(9, 0, 0, w, h, active and (accent or colorAccent) or colorPanelHover)
		draw.SimpleText(label, "DRP.Tablet.Small", w * 0.5, h * 0.5,
			active and colorBackground or colorText, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		return true
	end
	control.DoClick = callback
	return control
end

local function entry(parent, placeholder, x, y, width, height)
	local control = vgui.Create("DTextEntry", parent)
	control:SetPos(x, y)
	control:SetSize(width, height)
	control:SetFont("DRP.Tablet.Body")
	control:SetPlaceholderText(placeholder or "")
	control:SetTextColor(colorText)
	control:SetCursorColor(colorAccent)
	control:SetHighlightColor(ColorAlpha(colorAccent, 100))
	control:SetDrawBackground(false)
	control:SetPaintBackground(false)
	function control:Paint(w, h)
		updateCursor(self)
		draw.RoundedBox(9, 0, 0, w, h, Color(4, 14, 29, 245))
		surface.SetDrawColor(self:HasFocus() and colorAccent or colorLine)
		surface.DrawOutlinedRect(0, 0, w, h, self:HasFocus() and 2 or 1)
		self:DrawTextEntryText(colorText, colorAccent, colorText)
	end
	function control:OnMousePressed()
		self:RequestFocus()
		self:SetKeyboardInputEnabled(true)
		self:SetCaretPos(#self:GetValue())
	end
	return control
end

local function pageHeading(parent, titleValue, description)
	text(parent, titleValue, "DRP.Tablet.Title", colorText, 22, 15, 740, 34)
	text(parent, description, "DRP.Tablet.Small", colorMuted, 22, 50, 760, 25)
	surface.SetDrawColor(colorAccent)
end

local function scrollFor(parent, top)
	local scroll = vgui.Create("DScrollPanel", parent)
	scroll:SetPos(20, top or 84)
	scroll:SetSize(parent:GetWide() - 40, parent:GetTall() - (top or 84) - 18)
	return scroll
end

local function card(parent, height, paint)
	local panel = vgui.Create("DPanel", parent)
	panel:SetWide(math.max(100, parent:GetWide() - 16))
	panel:Dock(TOP)
	panel:DockMargin(0, 0, 0, 10)
	panel:SetTall(height)
	function panel:Paint(w, h)
		draw.RoundedBox(12, 0, 0, w, h, colorPanel)
		surface.SetDrawColor(colorLine)
		surface.DrawOutlinedRect(0, 0, w, h, 1)
		if paint then paint(self, w, h) end
	end
	return panel
end

local function government()
	return DRP.ClientGovernment or {
		taxRate = 0, treasury = 0, allocations = {}, phase = 0,
		deadline = 0, candidates = {}, keep = 0, remove = 0
	}
end

local function mayorName()
	local state = government()
	return IsValid(state.mayor) and state.mayor:DRPName() or "Office vacant"
end

local function addActionCard(scroll, titleValue, description, placeholder, actions)
	local panel = card(scroll, 112)
	text(panel, titleValue, "DRP.Tablet.Header", colorText, 18, 13, 350, 27)
	text(panel, description, "DRP.Tablet.Small", colorMuted, 18, 42, 720, 22)
	local input = entry(panel, placeholder, 18, 70, 450, 32)
	local right = panel:GetWide() - 16
	for index = #actions, 1, -1 do
		local action = actions[index]
		right = right - action.width
		button(panel, action.label, right, 70, action.width - 8, 32, function()
			action.callback(input:GetValue())
		end, action.color)
	end
	return panel, input
end

function Tablet:BuildOverview(parent)
	pageHeading(parent, "Government Overview", "Live municipal state, polls and urgent city operations.")
	local scroll = scrollFor(parent)
	local state = government()

	local summary = card(scroll, 118, function(_, w)
		draw.SimpleText("TREASURY", "DRP.Tablet.Small", 20, 18, colorMuted)
		draw.SimpleText("$" .. string.Comma(state.treasury or 0), "DRP.Tablet.Title", 20, 43, colorGreen)
		draw.SimpleText("SALARY TAX", "DRP.Tablet.Small", 285, 18, colorMuted)
		draw.SimpleText(tostring(state.taxRate or 0) .. "%", "DRP.Tablet.Title", 285, 43, colorAccent)
		draw.SimpleText("SITTING MAYOR", "DRP.Tablet.Small", 470, 18, colorMuted)
		draw.SimpleText(mayorName(), "DRP.Tablet.Header", 470, 48, colorText)
		local lockdown = DRP.ClientLockdown or {}
		draw.SimpleText(lockdown.active and "LOCKDOWN ACTIVE" or "CITY OPERATING NORMALLY",
			"DRP.Tablet.Small", w - 20, 23, lockdown.active and colorRed or colorGreen, TEXT_ALIGN_RIGHT)
		draw.SimpleText(lockdown.active and tostring(lockdown.reason or "") or "No emergency declaration",
			"DRP.Tablet.Small", w - 20, 51, colorMuted, TEXT_ALIGN_RIGHT)
	end)
	text(summary, "Government state updates are server-authoritative.", "DRP.Tablet.Small",
		colorMuted, 20, 88, 700, 20)

	local phaseNames = {
		[0] = "No poll currently active",
		[1] = "Mayor applications open",
		[2] = "Mayoral election vote",
		[3] = "Confidence vote"
	}
	local poll = card(scroll, 94, function(_, w)
		local remaining = math.max(0, math.ceil((state.deadline or 0) - CurTime()))
		draw.SimpleText("DEMOCRATIC PROCESS", "DRP.Tablet.Small", 18, 14, colorAccent)
		draw.SimpleText(phaseNames[state.phase or 0] or "No poll", "DRP.Tablet.Header", 18, 39, colorText)
		local detail = state.phase == 3
			and ((state.keep or 0) .. " keep  •  " .. (state.remove or 0) .. " remove")
			or ((state.phase or 0) > 0 and (remaining .. " seconds remaining")
				or "Confidence review scheduled every 20 minutes")
		draw.SimpleText(detail, "DRP.Tablet.Small", w - 18, 48, colorMuted, TEXT_ALIGN_RIGHT)
	end)
	if state.phase == 2 then
		for _, candidate in ipairs(state.candidates or {}) do
			local data = candidate
			local row = card(scroll, 62)
			text(row, data.name, "DRP.Tablet.Header", colorText, 18, 10, 420, 25)
			text(row, data.votes .. " vote" .. (data.votes == 1 and "" or "s"),
				"DRP.Tablet.Small", colorMuted, 18, 36, 250, 20)
			button(row, "VOTE", row:GetWide() - 108, 14, 90, 34,
				function() issue("vote " .. data.id) end)
		end
	end

	if state.lottery then
		local lottery = state.lottery
		card(scroll, 76, function(_, w)
			draw.SimpleText("ACTIVE PUBLIC LOTTERY", "DRP.Tablet.Small", 18, 13, colorGreen)
			draw.SimpleText("$" .. string.Comma(lottery.prize or 0), "DRP.Tablet.Header", 18, 39, colorText)
			draw.SimpleText((lottery.entrants or 0) .. " entrants  •  "
				.. math.max(0, math.ceil((lottery.deadline or 0) - CurTime())) .. "s remaining",
				"DRP.Tablet.Small", w - 18, 42, colorMuted, TEXT_ALIGN_RIGHT)
		end)
	end

	local agenda = GetGlobalString("DRPAgenda.government", "")
	card(scroll, 88, function(_, w)
		draw.SimpleText("GOVERNMENT AGENDA", "DRP.Tablet.Small", 18, 14, colorAccent)
		draw.SimpleText(agenda ~= "" and agenda or "No agenda has been published.",
			"DRP.Tablet.Body", 18, 44, agenda ~= "" and colorText or colorMuted)
		draw.SimpleText("Edit from Authority", "DRP.Tablet.Small", w - 18, 45, colorMuted, TEXT_ALIGN_RIGHT)
	end)
end

function Tablet:BuildTreasury(parent)
	pageHeading(parent, "Treasury & Funding", "Set taxation, fund public roles and create treasury-backed lotteries.")
	local scroll = scrollFor(parent)

	addActionCard(scroll, "Salary tax", "Applied to every salary and deposited into the public treasury.",
		"Tax percentage from 0 to 50", {
			{ label = "SET TAX", width = 112, callback = function(value) issue("tax " .. value) end }
		})

	addActionCard(scroll, "Public lottery", "Prize is reserved from treasury immediately and returned if nobody enters.",
		"Prize amount", {
			{ label = "START", width = 104, color = colorGreen,
				callback = function(value) issue("lottery " .. value) end }
		})

	local heading = card(scroll, 54)
	text(heading, "JOB FUNDING ALLOCATIONS", "DRP.Tablet.Small", colorAccent, 18, 17, 360, 22)
	text(heading, "Maximum bonus: 50% of base salary", "DRP.Tablet.Small",
		colorMuted, heading:GetWide() - 330, 17, 310, 22)

	local state = government()
	for id, job in ipairs(DRP.Jobs or {}) do
		if job.salary and job.salary > 0 then
			local row = card(scroll, 72)
			local current = tonumber(state.allocations and state.allocations[id]) or 0
			text(row, job.name, "DRP.Tablet.Header", colorText, 18, 11, 360, 25)
			text(row, "$" .. string.Comma(job.salary) .. " base  •  currently +" .. current .. "%",
				"DRP.Tablet.Small", current > 0 and colorGreen or colorMuted, 18, 40, 420, 20)
			local value = entry(row, "0-50", row:GetWide() - 212, 18, 92, 36)
			value:SetText(tostring(current))
			button(row, "APPLY", row:GetWide() - 108, 18, 90, 36, function()
				issue("allocate " .. tostring(job.key) .. " " .. value:GetValue())
			end)
		end
	end
end

function Tablet:BuildAuthority(parent)
	pageHeading(parent, "Executive Authority", "Incident-backed city controls and public-service administration.")
	local scroll = scrollFor(parent)

	addActionCard(scroll, "City lockdown",
		"Declares a global city state. Unsheltered Citizens become arrestable after one minute.",
		"Specific public emergency reason", {
			{ label = "BEGIN", width = 104, color = colorRed,
				callback = function(value) issue("lockdown " .. value) end },
			{ label = "END", width = 92, color = colorGreen,
				callback = function() issue("unlockdown") end }
		})

	addActionCard(scroll, "Government agenda", "Publishes direction to government personnel.",
		"Agenda message", {
			{ label = "PUBLISH", width = 118,
				callback = function(value) issue("agenda " .. value) end }
		})

	addActionCard(scroll, "Weapon licensing", "Grant or revoke the right to carry weapons openly.",
		"Exact or uniquely matching RP name", {
			{ label = "GRANT", width = 106, color = colorGreen,
				callback = function(value) issue("grantlicense " .. value) end },
			{ label = "REVOKE", width = 106, color = colorRed,
				callback = function(value) issue("revokelicense " .. value) end }
		})

	addActionCard(scroll, "Warrant approval", "Approve an incident-backed request submitted by police.",
		"Incident / warrant ID", {
			{ label = "APPROVE", width = 124,
				callback = function(value) issue("approvewarrant " .. value) end }
		})

	addActionCard(scroll, "Custody review", "Release a prisoner using executive authority.",
		"Exact or uniquely matching RP name", {
			{ label = "RELEASE", width = 118, color = colorAmber,
				callback = function(value) issue("unarrest " .. value) end }
		})
end

local function pretty(value)
	return string.upper(tostring(value or ""):gsub("_", " "))
end

function Tablet:BuildPolice(parent)
	pageHeading(parent, "Police Database", "Server-authorised infractions, active matters and warrant approvals.")
	local body = vgui.Create("EditablePanel", parent)
	body:SetPos(20, 84)
	body:SetSize(parent:GetWide() - 40, parent:GetTall() - 102)

	local service = iPhone and iPhone.PoliceRecordsService
	if not service or not isfunction(service.Request) or not isfunction(service.Listen) then
		text(body, "Police record service unavailable.", "DRP.Tablet.Header",
			colorRed, 20, 100, 700, 35)
		text(body, "Ensure the ePhone police database client file is mounted.",
			"DRP.Tablet.Body", colorMuted, 20, 142, 700, 30)
		return
	end

	local showIndex
	local function loading(message)
		body:Clear()
		text(body, message or "Retrieving authorised records…", "DRP.Tablet.Header",
			colorText, 22, 90, 720, 35)
		text(body, "SECURE SERVER QUERY", "DRP.Tablet.Small", colorAccent, 22, 130, 300, 24)
	end

	local function showDetails(data)
		body:Clear()
		local steamID = tostring(data.steam_id or "")
		button(body, "‹ BACK", 0, 0, 100, 38, function()
			loading("Refreshing subject index…")
			service.Request(0)
		end)
		button(body, "REFRESH", body:GetWide() - 104, 0, 104, 38, function()
			loading("Refreshing subject record…")
			service.Request(1, steamID)
		end)
		text(body, data.name or "Unknown subject", "DRP.Tablet.Title", colorText, 120, 0, 430, 32)
		text(body, steamID, "DRP.Tablet.Small", colorMuted, 120, 33, 380, 20)
		button(body, "COPY STEAMID", 510, 10, 130, 32, function() SetClipboardText(steamID) end)

		local scroll = vgui.Create("DScrollPanel", body)
		scroll:SetPos(0, 66)
		scroll:SetSize(body:GetWide(), body:GetTall() - 66)

		local status = card(scroll, 76, function(_, w)
			local count = #(data.active or {})
			draw.SimpleText(data.online and "ONLINE SUBJECT" or "OFFLINE RECORD",
				"DRP.Tablet.Small", 18, 16, data.online and colorGreen or colorMuted)
			draw.SimpleText(count > 0 and (count .. " ACTIVE POLICE MATTER" .. (count == 1 and "" or "S"))
				or "NO ACTIVE POLICE MATTER", "DRP.Tablet.Header", 18, 43,
				count > 0 and colorAmber or colorText)
			draw.SimpleText(data.wanted_reason ~= "" and data.wanted_reason or "No independent wanted flag",
				"DRP.Tablet.Small", w - 18, 45, colorMuted, TEXT_ALIGN_RIGHT)
		end)

		for _, active in ipairs(data.active or {}) do
			local matter = active
			local panel = card(scroll, 112)
			local label = matter.warrant and "ACTIVE WARRANT"
				or (matter.pending_warrant and "AWAITING MAYORAL APPROVAL" or "ACTIVE MATTER")
			text(panel, label, "DRP.Tablet.Small",
				matter.warrant and colorRed or colorAmber, 18, 13, 340, 22)
			text(panel, "#" .. tostring(matter.id) .. "  " .. pretty(matter.type),
				"DRP.Tablet.Header", colorText, 18, 38, 500, 28)
			text(panel, pretty(matter.state) .. "  •  " .. tostring(matter.reason or ""),
				"DRP.Tablet.Small", colorMuted, 18, 72, panel:GetWide() - 180, 25, true)
			if matter.pending_warrant then
				button(panel, "APPROVE", panel:GetWide() - 132, 37, 112, 38, function()
					issue("approvewarrant " .. tostring(matter.id))
					timer.Simple(0.35, function()
						if IsValid(body) then service.Request(1, steamID) end
					end)
				end, colorGreen)
			end
		end

		local history = card(scroll, 48)
		text(history, "POLICE-KNOWN HISTORY  •  " .. #(data.records or {}),
			"DRP.Tablet.Small", colorAccent, 18, 14, 400, 22)
		for _, record in ipairs(data.records or {}) do
			local item = record
			local panel = card(scroll, 132)
			text(panel, "#" .. tostring(item.id) .. "  " .. pretty(item.type),
				"DRP.Tablet.Header", colorText, 18, 13, 420, 27)
			text(panel, "OUTCOME  " .. pretty(item.resolution), "DRP.Tablet.Small",
				colorAccent, 18, 43, 400, 22)
			text(panel, "Instigator: " .. tostring(item.instigator or "Unknown")
				.. "    Victim: " .. tostring(item.victim or "Unknown"),
				"DRP.Tablet.Small", colorText, 18, 69, panel:GetWide() - 36, 22)
			text(panel, tostring(item.reason or "No additional report detail."),
				"DRP.Tablet.Small", colorMuted, 18, 94, panel:GetWide() - 36, 28, true)
			text(panel, os.date("%d %b %Y  %H:%M", tonumber(item.resolved_at) or os.time()),
				"DRP.Tablet.Small", colorMuted, panel:GetWide() - 210, 15, 190, 22)
		end
	end

	showIndex = function(subjects)
		body:Clear()
		local search = entry(body, "Search RP name or SteamID", 0, 0, body:GetWide() - 118, 40)
		button(body, "REFRESH", body:GetWide() - 108, 0, 108, 40, function()
			loading("Refreshing subject index…")
			service.Request(0)
		end)
		local scroll = vgui.Create("DScrollPanel", body)
		scroll:SetPos(0, 52)
		scroll:SetSize(body:GetWide(), body:GetTall() - 52)

		local function rebuild(filter)
			scroll:Clear()
			filter = string.lower(string.Trim(tostring(filter or "")))
			local shown = 0
			for _, subject in ipairs(subjects or {}) do
				local data = subject
				local haystack = string.lower(tostring(data.name or "") .. " " .. tostring(data.steam_id or ""))
				if filter == "" or haystack:find(filter, 1, true) then
					shown = shown + 1
					local row = vgui.Create("DButton", scroll)
					row:Dock(TOP)
					row:DockMargin(0, 0, 0, 8)
					row:SetTall(72)
					row:SetText("")
					function row:Paint(w, h)
						updateCursor(self)
						draw.RoundedBox(11, 0, 0, w, h, self.Hovered and colorPanelHover or colorPanel)
						draw.RoundedBox(3, 0, 0, 5, h,
							data.warrants > 0 and colorRed
								or (data.matters > 0 and colorAmber or (data.online and colorGreen or colorMuted)))
						draw.SimpleText(data.name or "Unknown", "DRP.Tablet.Header", 18, 13, colorText)
						draw.SimpleText(data.steam_id or "", "DRP.Tablet.Small", 18, 43, colorMuted)
						local statusText = data.warrants > 0 and (data.warrants .. " WARRANTS")
							or (data.matters > 0 and (data.matters .. " ACTIVE")
								or (data.online and "ONLINE" or "OFFLINE"))
						draw.SimpleText(statusText, "DRP.Tablet.Small", w - 18, 17,
							data.warrants > 0 and colorRed or (data.matters > 0 and colorAmber or colorMuted),
							TEXT_ALIGN_RIGHT)
						draw.SimpleText((data.infractions or 0) .. " infractions  •  "
							.. (data.records or 0) .. " known records",
							"DRP.Tablet.Small", w - 18, 44, colorMuted, TEXT_ALIGN_RIGHT)
						return true
					end
					row.DoClick = function()
						loading("Retrieving authorised subject record…")
						service.Request(1, data.steam_id)
					end
				end
			end
			if shown == 0 then
				text(scroll, "No matching police records.", "DRP.Tablet.Header",
					colorMuted, 20, 80, 600, 35)
			end
		end
		search.OnValueChange = function(_, value) rebuild(value) end
		rebuild("")
	end

	service.Listen(body, function(payload)
		if not IsValid(body) then return end
		if tonumber(payload.mode) == 1 then showDetails(payload.data or {})
		else showIndex(payload.data or {}) end
	end)
	loading("Connecting to police records…")
	if not service.Request(0) then loading("Police database server module is unavailable.") end
end

function Tablet:ShowPage(key)
	if not IsValid(self.Content) then return end
	key = tostring(key or "overview")
	self.Page = key
	self.Content:Clear()
	local builders = {
		overview = self.BuildOverview,
		treasury = self.BuildTreasury,
		authority = self.BuildAuthority,
		police = self.BuildPolice
	}
	local builder = builders[key] or builders.overview
	builder(self, self.Content)
end

function Tablet:Create()
	if IsValid(self.Panel) then return self.Panel end
	local root = vgui.Create("EditablePanel")
	root:SetSize(self.Width, self.Height)
	root:SetPaintedManually(true)
	root:SetVisible(true)
	function root:Paint(w, h)
		draw.RoundedBox(18, 0, 0, w, h, colorBackground)
		draw.RoundedBoxEx(18, 0, 0, 222, h, colorSidebar, true, false, true, false)
		surface.SetDrawColor(colorAccent)
		surface.DrawRect(0, 0, w, 5)
		surface.SetDrawColor(colorLine)
		surface.DrawRect(221, 0, 1, h)
	end
	self.Panel = root

	text(root, "MAYOR OS", "DRP.Tablet.Brand", colorText, 22, 21, 190, 40)
	text(root, "SECURE MUNICIPAL TERMINAL", "DRP.Tablet.Small", colorAccent, 24, 59, 190, 22)

	local nav = {
		{ key = "overview", label = "OVERVIEW", sub = "Live city state" },
		{ key = "treasury", label = "TREASURY", sub = "Tax and allocations" },
		{ key = "authority", label = "AUTHORITY", sub = "Executive actions" },
		{ key = "police", label = "POLICE DB", sub = "Records and warrants" }
	}
	for index, item in ipairs(nav) do
		local data = item
		local control = vgui.Create("DButton", root)
		control:SetPos(14, 105 + (index - 1) * 76)
		control:SetSize(194, 64)
		control:SetText("")
		function control:Paint(w, h)
			updateCursor(self)
			local selected = Tablet.Page == data.key
			draw.RoundedBox(10, 0, 0, w, h,
				selected and Color(26, 66, 99) or (self.Hovered and colorPanelHover or Color(0, 0, 0, 0)))
			if selected then
				draw.RoundedBox(3, 0, 8, 5, h - 16, colorAccent)
			end
			draw.SimpleText(data.label, "DRP.Tablet.Header", 17, 13,
				selected and colorText or colorMuted)
			draw.SimpleText(data.sub, "DRP.Tablet.Small", 17, 39,
				selected and colorAccent or colorMuted)
			return true
		end
		control.DoClick = function() Tablet:ShowPage(data.key) end
	end

	local status = vgui.Create("DPanel", root)
	status:SetPos(14, self.Height - 112)
	status:SetSize(194, 94)
	function status:Paint(w, h)
		draw.RoundedBox(10, 0, 0, w, h, Color(4, 15, 29, 230))
		draw.SimpleText("AUTHENTICATED AS", "DRP.Tablet.Small", 13, 13, colorMuted)
		draw.SimpleText(IsValid(LocalPlayer()) and LocalPlayer():DRPName() or "Mayor",
			"DRP.Tablet.Header", 13, 37, colorText)
		draw.SimpleText(os.date("%d %b %Y  •  %H:%M"), "DRP.Tablet.Small", 13, 67, colorAccent)
	end

	local header = vgui.Create("DPanel", root)
	header:SetPos(222, 0)
	header:SetSize(self.Width - 222, 70)
	function header:Paint(w, h)
		surface.SetDrawColor(Color(8, 22, 40, 250))
		surface.DrawRect(0, 0, w, h)
		surface.SetDrawColor(colorLine)
		surface.DrawRect(0, h - 1, w, 1)
		local state = government()
		draw.SimpleText("OFFICE OF THE MAYOR", "DRP.Tablet.Small", 22, 15, colorAccent)
		draw.SimpleText(mayorName(), "DRP.Tablet.Header", 22, 39, colorText)
		draw.SimpleText("TREASURY  $" .. string.Comma(state.treasury or 0)
			.. "   •   TAX  " .. tostring(state.taxRate or 0) .. "%",
			"DRP.Tablet.Small", w - 22, 38, colorMuted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end

	local content = vgui.Create("EditablePanel", root)
	content:SetPos(222, 70)
	content:SetSize(self.Width - 222, self.Height - 70)
	self.Content = content
	self:ShowPage(self.Page)
	return root
end

function Tablet:Ensure()
	return self:Create()
end

function Tablet:Close(remove)
	if not IsValid(self.Panel) then return end
	if remove then
		self.Panel:Remove()
		self.Panel = nil
		self.Content = nil
	else
		self.Panel:SetVisible(false)
	end
end

function Tablet:Reset()
	self:Close(true)
	self.Page = "overview"
end

local function refreshCurrentPage()
	if not IsValid(Tablet.Panel) or not Tablet.Panel:IsVisible() then return end
	local focus = vgui.GetKeyboardFocus()
	if IsValid(focus) then return end
	timer.Create("DRP.MayorTablet.Refresh", 0.1, 1, function()
		if IsValid(Tablet.Panel) and Tablet.Panel:IsVisible() then Tablet:ShowPage(Tablet.Page) end
	end)
end

hook.Add("DRPGovernmentChanged", "DRP.MayorTablet.Government", refreshCurrentPage)
hook.Add("DRPLockdownChanged", "DRP.MayorTablet.Lockdown", refreshCurrentPage)
