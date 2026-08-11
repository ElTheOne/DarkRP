DRP.PoliceTablet = DRP.PoliceTablet or {}

local Tablet = DRP.PoliceTablet
Tablet.Width = 1080
Tablet.Height = 760
Tablet.Page = Tablet.Page or "overview"
Tablet.CanApproveWarrants = false
Tablet.IncidentCount = Tablet.IncidentCount or 0

local background = Color(4, 12, 25)
local sidebar = Color(7, 21, 39)
local panelColor = Color(12, 32, 56, 252)
local panelHover = Color(21, 52, 84)
local accent = Color(65, 191, 255)
local green = Color(86, 226, 157)
local amber = Color(247, 186, 79)
local red = Color(247, 100, 126)
local white = Color(235, 245, 255)
local muted = Color(142, 166, 193)
local line = Color(39, 74, 108)

local function updateCursor(control)
	if iPhone and isfunction(iPhone.cursorUpdate) then iPhone.cursorUpdate(control) end
end

local function issue(command)
	command = string.Trim(tostring(command or ""))
	if command == "" then return end
	RunConsoleCommand("say", "/" .. command)
	surface.PlaySound("ui/buttonclickrelease.wav")
end

local function label(parent, value, font, color, x, y, width, height, wrap)
	local control = vgui.Create("DLabel", parent)
	control:SetPos(x, y)
	control:SetSize(width, height)
	control:SetText(tostring(value or ""))
	control:SetFont(font or "DRP.Tablet.Body")
	control:SetTextColor(color or white)
	control:SetWrap(wrap == true)
	control:SetAutoStretchVertical(wrap == true)
	return control
end

local function button(parent, value, x, y, width, height, callback, buttonColor)
	local control = vgui.Create("DButton", parent)
	control:SetPos(x, y)
	control:SetSize(width, height)
	control:SetText("")
	function control:Paint(w, h)
		updateCursor(self)
		local active = self.Depressed or self.Hovered
		draw.RoundedBox(9, 0, 0, w, h, active and (buttonColor or accent) or panelHover)
		draw.SimpleText(value, "DRP.Tablet.Small", w * 0.5, h * 0.5,
			active and background or white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
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
	control:SetTextColor(white)
	control:SetCursorColor(accent)
	control:SetHighlightColor(ColorAlpha(accent, 100))
	control:SetDrawBackground(false)
	control:SetPaintBackground(false)
	function control:Paint(w, h)
		updateCursor(self)
		local focused = self:HasFocus() or IsValid(self.DRPKeyboardProxy)
		draw.RoundedBox(9, 0, 0, w, h, Color(3, 14, 29, 245))
		surface.SetDrawColor(focused and accent or line)
		surface.DrawOutlinedRect(0, 0, w, h, focused and 2 or 1)
		self:DrawTextEntryText(white, accent, white)
	end
	function control:DRPBeginTextInput()
		if IsValid(self.DRPKeyboardProxy) then
			self.DRPKeyboardProxy:RequestFocus()
			return
		end
		if not (iPhone and IsValid(iPhone.panel2d)) then return end
		local field = self
		local proxy = vgui.Create("DTextEntry", iPhone.panel2d)
		proxy:SetPos(-8, -8)
		proxy:SetSize(1, 1)
		proxy:SetAlpha(0)
		proxy:MakePopup()
		proxy:SetMouseInputEnabled(false)
		proxy:SetKeyboardInputEnabled(true)
		proxy:SetUpdateOnType(true)
		proxy:SetText(tostring(field:GetValue() or ""))
		proxy:SetCaretPos(#proxy:GetValue())
		field.DRPKeyboardProxy = proxy
		function proxy:OnValueChange(value)
			if not IsValid(field) then self:Remove() return end
			field:SetText(tostring(value or ""))
			field:SetCaretPos(#field:GetValue())
		end
		function proxy:OnEnter() self:KillFocus() self:Remove() end
		function proxy:OnLoseFocus() self:Remove() end
		function proxy:Think()
			if not IsValid(field) or not IsValid(iPhone.panel2d) then self:Remove() end
		end
		function proxy:OnRemove()
			if IsValid(field) and field.DRPKeyboardProxy == self then field.DRPKeyboardProxy = nil end
		end
		proxy:RequestFocus()
	end
	function control:OnMousePressed(code)
		if code == MOUSE_LEFT then self:DRPBeginTextInput() end
	end
	return control
end

local function heading(parent, title, description)
	label(parent, title, "DRP.Tablet.Title", white, 22, 15, 760, 34)
	label(parent, description, "DRP.Tablet.Small", muted, 22, 50, 760, 25)
end

local function scrollFor(parent)
	local scroll = vgui.Create("DScrollPanel", parent)
	scroll:SetPos(20, 84)
	scroll:SetSize(parent:GetWide() - 40, parent:GetTall() - 102)
	scroll:SetMouseInputEnabled(true)
	function scroll:Paint() updateCursor(self) end
	return scroll
end

local function card(parent, height, paint)
	local control = vgui.Create("DPanel", parent)
	control:SetWide(math.max(100, parent:GetWide() - 16))
	control:Dock(TOP)
	control:DockMargin(0, 0, 0, 10)
	control:SetTall(height)
	function control:Paint(w, h)
		draw.RoundedBox(12, 0, 0, w, h, panelColor)
		surface.SetDrawColor(line)
		surface.DrawOutlinedRect(0, 0, w, h, 1)
		if paint then paint(self, w, h) end
	end
	return control
end

local function activeIncidents()
	local output = {}
	for _, incident in pairs(DRP.ClientIncidents or {}) do output[#output + 1] = incident end
	table.sort(output, function(first, second) return (first.id or 0) > (second.id or 0) end)
	return output
end

local function pretty(value)
	return string.upper(tostring(value or ""):gsub("_", " "))
end

function Tablet:BuildOverview(parent)
	heading(parent, "Police Operations", "Live officer context, active incidents and field workflow.")
	local scroll = scrollFor(parent)
	local incidents = activeIncidents()
	local wanted = 0
	for _, incident in ipairs(incidents) do
		if incident.type == "police_sighting" or incident.type == "arrest" then wanted = wanted + 1 end
	end
	card(scroll, 120, function(_, w)
		draw.SimpleText("ON-DUTY OFFICER", "DRP.Tablet.Small", 20, 18, muted)
		draw.SimpleText(IsValid(LocalPlayer()) and LocalPlayer():DRPName() or "Officer",
			"DRP.Tablet.Title", 20, 45, white)
		draw.SimpleText("ACTIVE INCIDENTS", "DRP.Tablet.Small", 390, 18, muted)
		draw.SimpleText(tostring(#incidents), "DRP.Tablet.Title", 390, 45,
			#incidents > 0 and amber or green)
		draw.SimpleText("POLICE MATTERS", "DRP.Tablet.Small", 600, 18, muted)
		draw.SimpleText(tostring(wanted), "DRP.Tablet.Title", 600, 45,
			wanted > 0 and red or green)
		draw.SimpleText("All permissions and records are supplied by server-owned incidents.",
			"DRP.Tablet.Small", w - 20, 91, muted, TEXT_ALIGN_RIGHT)
	end)

	local workflow = card(scroll, 160)
	label(workflow, "NON-LETHAL RESPONSE", "DRP.Tablet.Header", accent, 18, 15, 360, 28)
	label(workflow,
		"Observe the offence, issue lawful commands, then use the taser before attempting cuffs. Mutual combat is only established by the incident rules; this terminal cannot invent permission.",
		"DRP.Tablet.Body", white, 18, 48, workflow:GetWide() - 36, 55, true)
	label(workflow, "BOOKING", "DRP.Tablet.Small", green, 18, 111, 140, 22)
	label(workflow, "Drag a cuffed suspect to the Jailer NPC and press E to complete arrest processing.",
		"DRP.Tablet.Small", muted, 118, 111, workflow:GetWide() - 136, 28, true)

	if #incidents == 0 then
		card(scroll, 78, function()
			draw.SimpleText("NO ACTIVE DISPATCH", "DRP.Tablet.Header", 18, 18, green)
			draw.SimpleText("The incident queue will update automatically when the server assigns a matter.",
				"DRP.Tablet.Small", 18, 48, muted)
		end)
	else
		local latest = incidents[1]
		card(scroll, 96, function(_, w)
			draw.SimpleText("LATEST ASSIGNMENT", "DRP.Tablet.Small", 18, 14, accent)
			draw.SimpleText("#" .. tostring(latest.id) .. "  " .. pretty(latest.type),
				"DRP.Tablet.Header", 18, 40, white)
			draw.SimpleText(pretty(latest.state), "DRP.Tablet.Small", w - 18, 22, amber, TEXT_ALIGN_RIGHT)
			draw.SimpleText(tostring(latest.reason or ""), "DRP.Tablet.Small", 18, 69, muted)
		end)
	end
end

function Tablet:BuildIncidents(parent)
	heading(parent, "Active Incidents", "Only matters synchronized to this officer are shown.")
	local scroll = scrollFor(parent)
	local incidents = activeIncidents()
	if #incidents == 0 then
		card(scroll, 92, function()
			draw.SimpleText("DISPATCH CLEAR", "DRP.Tablet.Header", 18, 18, green)
			draw.SimpleText("No active incident currently includes this officer.", "DRP.Tablet.Body", 18, 52, muted)
		end)
		return
	end
	for _, incident in ipairs(incidents) do
		local data = incident
		card(scroll, 152, function(_, w)
			local remaining = math.max(0, math.ceil((data.deadline or 0) - RealTime()))
			draw.SimpleText("INCIDENT #" .. tostring(data.id) .. "  •  " .. pretty(data.type),
				"DRP.Tablet.Header", 18, 16, white)
			draw.SimpleText(pretty(data.state) .. (remaining > 0 and ("  •  " .. remaining .. "s") or ""),
				"DRP.Tablet.Small", w - 18, 21, accent, TEXT_ALIGN_RIGHT)
			draw.SimpleText(tostring(data.others or "Participants unavailable"),
				"DRP.Tablet.Small", 18, 49, muted)
			draw.SimpleText(tostring(data.reason or "No report detail."),
				"DRP.Tablet.Body", 18, 76, white)
			local permissions = table.concat(data.permissions or {}, "  •  ")
			draw.SimpleText(permissions ~= "" and permissions or "No action permission granted",
				"DRP.Tablet.Small", 18, 109, permissions ~= "" and green or amber)
			local evidence = data.evidence and data.evidence[#data.evidence]
			if evidence then
				draw.SimpleText("LATEST EVIDENCE  " .. pretty(evidence.event) .. " — " .. tostring(evidence.detail or ""),
					"DRP.Tablet.Small", 18, 132, accent)
			end
		end)
	end
end

local function actionCard(scroll, title, description, placeholder, action, command, color)
	local control = card(scroll, 118)
	label(control, title, "DRP.Tablet.Header", white, 18, 13, 420, 27)
	label(control, description, "DRP.Tablet.Small", muted, 18, 43, control:GetWide() - 36, 22)
	local input = entry(control, placeholder, 18, 74, control:GetWide() - 152, 34)
	button(control, action, control:GetWide() - 122, 74, 104, 34, function()
		local value = string.Trim(input:GetValue())
		if value == "" then return end
		issue(command .. " " .. value)
	end, color)
end

function Tablet:BuildField(parent)
	heading(parent, "Field Actions", "Validated commands for investigation, warrants and evidence handling.")
	local scroll = scrollFor(parent)
	actionCard(scroll, "Request a warrant",
		"Submit a specific incident-backed reason for Mayoral approval.",
		"RP name followed by a specific reason", "REQUEST", "warrant", amber)
	actionCard(scroll, "Search a suspect",
		"Search requires active incident authority and appropriate custody conditions.",
		"Exact or uniquely matching RP name", "SEARCH", "search", accent)
	local evidence = card(scroll, 112)
	label(evidence, "Evidence storage", "DRP.Tablet.Header", white, 18, 13, 420, 27)
	label(evidence, "Review or deposit confiscated items through the assigned evidence locker.",
		"DRP.Tablet.Small", muted, 18, 43, evidence:GetWide() - 170, 22)
	button(evidence, "OPEN EVIDENCE", evidence:GetWide() - 164, 66, 146, 34,
		function() issue("evidence") end, green)
	local reminder = card(scroll, 106)
	label(reminder, "ARREST PROCESS", "DRP.Tablet.Small", accent, 18, 14, 260, 22)
	label(reminder,
		"Tase → cuff → physically transport the suspect → present them to the Jailer NPC. The tablet does not bypass the non-lethal or transport requirements.",
		"DRP.Tablet.Body", white, 18, 43, reminder:GetWide() - 36, 54, true)
end

function Tablet:BuildRecords(parent)
	local mayorTablet = DRP.MayorTablet
	if mayorTablet and isfunction(mayorTablet.BuildPolice) then
		return mayorTablet.BuildPolice(self, parent)
	end
	heading(parent, "Police Database", "The records interface is unavailable.")
end

function Tablet:BuildScanner(parent)
	heading(parent, "Evidence Scanner", "Photograph visible contraband inside the property currently in your sights.")
	local scroll = scrollFor(parent)
	local service = DRP.LegalTablet
	local scan = service and service.Scan or {}
	local remaining = math.max(0, math.ceil((tonumber(scan.remaining) or 0)
		- (CurTime() - (tonumber(scan.received_at) or CurTime()))))

	local controls = card(scroll, 128)
	label(controls, "PROPERTY EVIDENCE CAMERA", "DRP.Tablet.Header", white, 18, 14, 410, 28)
	label(controls,
		"Aim at a configured property boundary or grouped door. Only contraband that is in frame, in PVS and unobstructed by walls or props is admissible.",
		"DRP.Tablet.Small", muted, 18, 45, controls:GetWide() - 205, 48, true)
	button(controls, remaining > 0 and ("RECHARGING " .. remaining .. "s") or "CAPTURE SCAN",
		controls:GetWide() - 180, 34, 162, 48, function()
			if service and isfunction(service.CaptureEvidence) then service.CaptureEvidence() end
		end, remaining > 0 and muted or accent)
	label(controls, "Capture cooldown is server-controlled; failed property acquisition does not consume it.", "DRP.Tablet.Small",
		remaining > 0 and amber or green, 18, 101, controls:GetWide() - 36, 20)

	local result = card(scroll, 94)
	label(result, scan.ok and "LATEST CAPTURE" or "SCANNER STATUS", "DRP.Tablet.Small",
		scan.ok and green or amber, 18, 14, 260, 22)
	label(result, tostring(scan.message or "No evidence scan captured this session."),
		"DRP.Tablet.Body", white, 18, 42, result:GetWide() - 36, 42, true)
	if scan.property and scan.property ~= "" then
		label(result, "PROPERTY  " .. tostring(scan.property) .. "  •  #" .. tostring(scan.property_id or 0),
			"DRP.Tablet.Small", accent, result:GetWide() - 390, 15, 370, 22)
	end

	for index, finding in ipairs(scan.findings or {}) do
		local data = finding
		card(scroll, 76, function(_, w)
			draw.SimpleText(string.upper(tostring(data.kind or "Illegal item")), "DRP.Tablet.Header", 18, 14, white)
			draw.SimpleText(tostring(data.class or "unknown entity"), "DRP.Tablet.Small", 18, 45, muted)
			draw.SimpleText(tostring(data.owner or "Owner unavailable"), "DRP.Tablet.Small",
				w - 18, 27, index <= 16 and accent or muted, TEXT_ALIGN_RIGHT)
		end)
	end

	for _, warrant in ipairs(scan.warrants or {}) do
		local data = warrant
		card(scroll, 72, function(_, w)
			draw.SimpleText("WARRANT #" .. tostring(data.id), "DRP.Tablet.Header", 18, 13, green)
			draw.SimpleText(tostring(data.suspect or "Suspect"), "DRP.Tablet.Body", 18, 42, white)
			draw.SimpleText(pretty(data.status), "DRP.Tablet.Small", w - 18, 28,
				data.status == "pending" and amber or green, TEXT_ALIGN_RIGHT)
		end)
	end
end

function Tablet.BuildWarrants(_, parent, allowDecision)
	heading(parent, "Warrants", allowDecision
		and "Review evidence-backed requests and approve or reject police authority."
		or "Track pending requests and active search, entry and arrest authority.")
	local scroll = scrollFor(parent)
	local service = DRP.LegalTablet
	if service and isfunction(service.RequestWarrants) then service.RequestWarrants() end
	local warrants = service and service.Warrants or {}
	if #warrants == 0 then
		card(scroll, 92, function()
			draw.SimpleText("NO ACTIVE WARRANTS", "DRP.Tablet.Header", 18, 18, green)
			draw.SimpleText("There are no pending or approved warrants in the legal system.",
				"DRP.Tablet.Body", 18, 52, muted)
		end)
		return
	end

	for _, warrant in ipairs(warrants) do
		local data = warrant
		local pending = data.state == "approval_pending"
		local control = card(scroll, pending and allowDecision and 158 or 130)
		label(control, "WARRANT #" .. tostring(data.id), "DRP.Tablet.Header",
			pending and amber or red, 18, 13, 300, 28)
		label(control, pretty(data.state) .. "  •  " .. tostring(data.remaining or 0) .. "s",
			"DRP.Tablet.Small", pending and amber or green, control:GetWide() - 255, 17, 235, 22)
		label(control, tostring(data.suspect or "Unavailable suspect"), "DRP.Tablet.Header",
			white, 18, 43, 390, 28)
		label(control, "Requested by " .. tostring(data.officer or "Unavailable officer")
			.. (data.property ~= "" and ("  •  " .. data.property) or ""),
			"DRP.Tablet.Small", muted, 18, 72, control:GetWide() - 36, 22)
		label(control, tostring(data.reason or "No reason supplied."), "DRP.Tablet.Small",
			white, 18, 98, control:GetWide() - 36, 34, true)
		if pending and allowDecision then
			button(control, "APPROVE", control:GetWide() - 258, 119, 112, 31, function()
				issue("approvewarrant " .. tostring(data.id))
			end, green)
			button(control, "REJECT", control:GetWide() - 136, 119, 118, 31, function()
				issue("rejectwarrant " .. tostring(data.id) .. " Evidence did not meet Mayoral review")
			end, red)
		end
	end
end

function Tablet:ShowPage(key)
	if not IsValid(self.Content) then return end
	key = tostring(key or "overview")
	self.Page = key
	self.Content:Clear()
	local builders = {
		overview = self.BuildOverview,
		incidents = self.BuildIncidents,
		records = self.BuildRecords,
		scanner = self.BuildScanner,
		warrants = self.BuildWarrants,
		field = self.BuildField
	}
	local builder = builders[key] or builders.overview
	builder(self, self.Content)
end

function Tablet:Create()
	if IsValid(self.Panel) then
		local width, height = self.Panel:GetSize()
		if width == self.Width and height == self.Height then return self.Panel end
		self.Panel:Remove()
	end
	local root = vgui.Create("EditablePanel")
	root:SetSize(self.Width, self.Height)
	root:SetPaintedManually(true)
	root:SetVisible(true)
	function root:Paint(w, h)
		draw.RoundedBox(18, 0, 0, w, h, background)
		draw.RoundedBoxEx(18, 0, 0, 222, h, sidebar, true, false, true, false)
		surface.SetDrawColor(accent)
		surface.DrawRect(0, 0, w, 5)
		surface.SetDrawColor(line)
		surface.DrawRect(221, 0, 1, h)
	end
	self.Panel = root

	label(root, "POLICE OS", "DRP.Tablet.Brand", white, 22, 21, 190, 40)
	label(root, "SECURE OPERATIONS TERMINAL", "DRP.Tablet.Small", accent, 24, 59, 190, 22)
	local nav = {
		{ key = "overview", title = "OVERVIEW", sub = "Officer status" },
		{ key = "incidents", title = "INCIDENTS", sub = "Live assignments" },
		{ key = "records", title = "POLICE DB", sub = "Subject records" },
		{ key = "scanner", title = "EVIDENCE", sub = "Property scanner" },
		{ key = "warrants", title = "WARRANTS", sub = "Legal authority" },
		{ key = "field", title = "FIELD ACTIONS", sub = "Operational tools" }
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
				selected and Color(25, 67, 102) or (self.Hovered and panelHover or Color(0, 0, 0, 0)))
			if selected then draw.RoundedBox(3, 0, 8, 5, h - 16, accent) end
			draw.SimpleText(data.title, "DRP.Tablet.Header", 17, 13, selected and white or muted)
			draw.SimpleText(data.sub, "DRP.Tablet.Small", 17, 39, selected and accent or muted)
			return true
		end
		control.DoClick = function() Tablet:ShowPage(data.key) end
	end

	local status = vgui.Create("DPanel", root)
	status:SetPos(14, self.Height - 112)
	status:SetSize(194, 94)
	function status:Paint(w, h)
		draw.RoundedBox(10, 0, 0, w, h, Color(3, 15, 29, 230))
		draw.SimpleText("AUTHENTICATED OFFICER", "DRP.Tablet.Small", 13, 13, muted)
		draw.SimpleText(IsValid(LocalPlayer()) and LocalPlayer():DRPName() or "Officer",
			"DRP.Tablet.Header", 13, 37, white)
		draw.SimpleText(os.date("%d %b %Y  •  %H:%M"), "DRP.Tablet.Small", 13, 67, accent)
	end

	local header = vgui.Create("DPanel", root)
	header:SetPos(222, 0)
	header:SetSize(self.Width - 222, 70)
	function header:Paint(w, h)
		surface.SetDrawColor(Color(7, 22, 40, 250))
		surface.DrawRect(0, 0, w, h)
		surface.SetDrawColor(line)
		surface.DrawRect(0, h - 1, w, 1)
		draw.SimpleText("METROPOLITAN POLICE OPERATIONS", "DRP.Tablet.Small", 22, 15, accent)
		draw.SimpleText(IsValid(LocalPlayer()) and LocalPlayer():DRPName() or "Officer",
			"DRP.Tablet.Header", 22, 39, white)
		local incidentCount = Tablet.IncidentCount or 0
		draw.SimpleText(incidentCount .. " ACTIVE INCIDENT" .. (incidentCount == 1 and "" or "S"),
			"DRP.Tablet.Small", w - 22, 38, muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end

	local content = vgui.Create("EditablePanel", root)
	content:SetPos(222, 70)
	content:SetSize(self.Width - 222, self.Height - 70)
	self.Content = content
	self:ShowPage(self.Page)
	return root
end

function Tablet:Ensure() return self:Create() end

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

local function refreshIncidents()
	Tablet.IncidentCount = table.Count(DRP.ClientIncidents or {})
	if not IsValid(Tablet.Panel) or not Tablet.Panel:IsVisible() then return end
	if Tablet.Page ~= "overview" and Tablet.Page ~= "incidents" then return end
	timer.Create("DRP.PoliceTablet.Refresh", 0.1, 1, function()
		if IsValid(Tablet.Panel) and Tablet.Panel:IsVisible() then Tablet:ShowPage(Tablet.Page) end
	end)
end

hook.Add("DRPClientIncidentsChanged", "DRP.PoliceTablet.Incidents", refreshIncidents)

local function refreshLegalPage()
	if not IsValid(Tablet.Panel) or not Tablet.Panel:IsVisible() then return end
	if Tablet.Page ~= "scanner" and Tablet.Page ~= "warrants" then return end
	timer.Create("DRP.PoliceTablet.LegalRefresh", 0.05, 1, function()
		if IsValid(Tablet.Panel) and Tablet.Panel:IsVisible() then Tablet:ShowPage(Tablet.Page) end
	end)
end

hook.Add("DRPEvidenceScannerChanged", "DRP.PoliceTablet.Scanner", refreshLegalPage)
hook.Add("DRPWarrantsChanged", "DRP.PoliceTablet.Warrants", refreshLegalPage)

timer.Simple(0, function()
	Tablet.IncidentCount = table.Count(DRP.ClientIncidents or {})
end)
