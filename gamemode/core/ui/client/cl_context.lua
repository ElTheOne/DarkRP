DRP.ContextMenu = DRP.ContextMenu or {}

local Context = DRP.ContextMenu
local frame
local activeMode
local modeSelector
local settingsHost
local activeControls

local function activeToolgun()
	local ply = LocalPlayer()
	if not IsValid(ply) then return nil end
	local weapon = ply:GetActiveWeapon()
	return IsValid(weapon) and weapon:GetClass() == "gmod_tool" and weapon or nil
end

local function translated(value, fallback)
	value = tostring(value or "")
	if value == "" then return fallback end
	if string.StartWith(value, "#") then
		local phrase = language.GetPhrase(string.sub(value, 2))
		if phrase ~= "" and phrase ~= string.sub(value, 2) then return phrase end
	end
	return value
end

local function friendlyMode(mode)
	local text = string.gsub(tostring(mode or ""), "_", " ")
	return string.gsub(text, "(%a)([%w']*)", function(first, rest)
		return string.upper(first) .. string.lower(rest)
	end)
end

local function availableModes(weapon)
	if DRP.Toolgun and isfunction(DRP.Toolgun.SyncWeapon) then DRP.Toolgun.SyncWeapon(weapon) end
	local modes = {}
	for mode, tool in pairs(weapon.Tool or {}) do
		mode = string.lower(tostring(mode or ""))
		if mode ~= "" then
			modes[#modes + 1] = {
				mode = mode,
				name = translated(tool.Name, friendlyMode(mode))
			}
		end
	end
	table.sort(modes, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
	return modes
end

local function clearSettings()
	activeControls = nil
	if IsValid(settingsHost) then settingsHost:Clear() end
end

local function addGenericSettings(scroll, mode, tool)
	local values = tool.ClientConVar or {}
	local found = false

	for key, default in SortedPairs(values) do
		found = true
		local convarName = mode .. "_" .. tostring(key)
		local defaultText = tostring(default or "")
		local title = friendlyMode(key)

		if defaultText == "0" or defaultText == "1" then
			local checkbox = vgui.Create("DCheckBoxLabel")
			checkbox:Dock(TOP)
			checkbox:DockMargin(8, 7, 8, 0)
			checkbox:SetTall(24)
			checkbox:SetFont("DRP.Admin.Body")
			checkbox:SetTextColor(DRP.UI.Colors.text)
			checkbox:SetText(title)
			checkbox:SetConVar(convarName)
			checkbox:SizeToContents()
			scroll:AddItem(checkbox)
		else
			local row = vgui.Create("DPanel")
			row:SetTall(56)
			row.Paint = nil

			local label = vgui.Create("DLabel", row)
			label:Dock(TOP)
			label:SetTall(21)
			label:SetFont("DRP.Admin.Small")
			label:SetTextColor(DRP.UI.Colors.muted)
			label:SetText(string.upper(title))

			local input = vgui.Create("DTextEntry", row)
			input:Dock(TOP)
			input:SetTall(30)
			input:SetFont("DRP.Admin.Body")
			input:SetConVar(convarName)
			input:SetUpdateOnType(true)
			row:DockMargin(8, 7, 8, 0)
			scroll:AddItem(row)
		end
	end

	if found then return end

	local empty = vgui.Create("DLabel")
	empty:SetTall(90)
	empty:SetFont("DRP.Admin.Body")
	empty:SetTextColor(DRP.UI.Colors.muted)
	empty:SetWrap(true)
	empty:SetContentAlignment(5)
	empty:SetText("This tool has no adjustable settings.\nRelease C to use its mouse controls.")
	scroll:AddItem(empty)
end

local function showBuildFailure(message)
	clearSettings()
	local label = vgui.Create("DLabel", settingsHost)
	label:Dock(TOP)
	label:DockMargin(18, 20, 18, 0)
	label:SetTall(80)
	label:SetFont("DRP.Admin.Body")
	label:SetTextColor(DRP.UI.Colors.red)
	label:SetWrap(true)
	label:SetContentAlignment(7)
	label:SetText(message)
end

local function buildSettings(mode)
	if not IsValid(frame) or not IsValid(settingsHost) then return end
	local weapon = activeToolgun()
	if not IsValid(weapon) then Context.Close() return end
	if DRP.Toolgun and isfunction(DRP.Toolgun.SyncWeapon) then DRP.Toolgun.SyncWeapon(weapon) end

	mode = string.lower(tostring(mode or GetConVarString("gmod_toolmode")))
	local tool = isfunction(weapon.GetToolObject) and weapon:GetToolObject(mode) or (weapon.Tool and weapon.Tool[mode])
	if not istable(tool) then
		local stored = weapons.GetStored("gmod_tool")
		tool = istable(stored) and istable(stored.Tool) and stored.Tool[mode] or nil
	end
	activeMode = mode
	frame.ModeTitle = translated(tool and tool.Name, friendlyMode(mode))

	clearSettings()
	if not istable(tool) then
		showBuildFailure("This Tool Gun mode is not registered on the client.")
		return
	end

	local scroll = vgui.Create("DScrollPanel", settingsHost)
	scroll:Dock(FILL)
	scroll:DockMargin(10, 10, 6, 10)

	if not isfunction(tool.BuildCPanel) then
		addGenericSettings(scroll, mode, tool)
		return
	end

	local controls = vgui.Create("ControlPanel", scroll)
	if not IsValid(controls) then
		showBuildFailure("The Garry's Mod Tool Gun control panel could not be created.")
		return
	end
	scroll:AddItem(controls)
	activeControls = controls
	controls:Dock(TOP)
	-- Legacy Workshop stools resolve their live panel through
	-- controlpanel.Get(mode). Registering the real mode name is required for
	-- Precision rebuilds and Improved Stacker's expandable settings.
	controls:SetName(mode)
	controls:SetExpanded(true)
	controls:SetVisible(true)
	controls:SetPaintBackground(true)
	if isfunction(controls.SetAutoSize) then controls:SetAutoSize(true) end

	local ok, failure = xpcall(function()
		-- Sandbox passes the tool object to modes such as Advanced Duplicator.
		-- Modes which do not need it simply ignore the additional argument.
		tool.BuildCPanel(controls, tool)
	end, debug.traceback)
	if not ok then
		controls:Remove()
		activeControls = nil
		addGenericSettings(scroll, mode, tool)
		ErrorNoHalt("[DRP CONTEXT] Tool settings failed for " .. mode .. ":\n" .. tostring(failure) .. "\n")
		return
	end

	local function refreshHeight()
		if not IsValid(controls) then return end
		controls:InvalidateLayout(true)
		controls:SizeToChildren(false, true)
		controls:SetTall(math.max(controls:GetTall(), 80))
	end
	-- The imported panels create nested controls and presets over several VGUI
	-- layout passes. Reflow after each pass instead of clamping them to one row.
	refreshHeight()
	timer.Simple(0, refreshHeight)
	timer.Simple(0.05, refreshHeight)
	timer.Simple(0.2, refreshHeight)
end

function Context.Close()
	if IsValid(frame) then frame:Remove() end
	frame = nil
	activeMode = nil
	modeSelector = nil
	settingsHost = nil
	activeControls = nil
end

function Context.Open()
	local weapon = activeToolgun()
	if not IsValid(weapon) then return false end
	if DRP.Toolgun and isfunction(DRP.Toolgun.RegisterBundledTools) then
		DRP.Toolgun.RegisterBundledTools()
		DRP.Toolgun.SyncWeapon(weapon)
	end
	Context.Close()
	if MediaPlayer and isfunction(MediaPlayer.HideSidebar) then
		MediaPlayer.HideSidebar()
	end

	local colors = DRP.UI.Colors
	local width = math.min(470, ScrW() - 40)
	local height = math.min(760, ScrH() - 48)

	frame = vgui.Create("DFrame")
	frame:SetSize(width, height)
	frame:SetPos(ScrW() - width - 24, math.floor((ScrH() - height) * 0.5))
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:SetDraggable(false)
	frame:SetSizable(false)
	frame:MakePopup()
	-- MakePopup enables keyboard capture. Turn it back off so holding C does
	-- not prevent the player from walking while adjusting Tool Gun settings.
	frame:SetKeyboardInputEnabled(false)
	frame:SetMouseInputEnabled(true)
	frame.OpenedAt = RealTime()
	frame.Paint = function(self, panelWidth, panelHeight)
		draw.RoundedBox(11, 0, 0, panelWidth, panelHeight, colors.background)
		draw.RoundedBoxEx(11, 0, 0, panelWidth, 72, colors.panel, true, true, false, false)
		draw.RoundedBoxEx(11, 0, 0, 5, panelHeight, colors.accent, true, false, true, false)
		draw.SimpleText("TOOL GUN CONTEXT", "DRP.Admin.Small", 22, 20, colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(self.ModeTitle or "Tool Settings", "DRP.Admin.Title", 22, 47, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("RELEASE C TO CLOSE", "DRP.Admin.Small", panelWidth - 20, 21, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end
	frame.Think = function(self)
		if RealTime() > (self.OpenedAt or 0) + 0.12 and not input.IsKeyDown(KEY_C) then
			Context.Close()
			return
		end
		local current = activeToolgun()
		if not IsValid(current) then Context.Close() return end
		local mode = string.lower(GetConVarString("gmod_toolmode"))
		if mode ~= activeMode then
			if IsValid(modeSelector) then
				for index, choice in ipairs(modeSelector.Data or {}) do
					if choice == mode then modeSelector:ChooseOptionID(index) break end
				end
			end
			buildSettings(mode)
		end
	end
	frame.OnRemove = function()
		frame = nil
		activeMode = nil
		modeSelector = nil
		settingsHost = nil
		activeControls = nil
	end

	local selectorLabel = vgui.Create("DLabel", frame)
	selectorLabel:SetPos(20, 84)
	selectorLabel:SetSize(width - 40, 20)
	selectorLabel:SetFont("DRP.Admin.Small")
	selectorLabel:SetTextColor(colors.muted)
	selectorLabel:SetText("ACTIVE TOOL")

	modeSelector = vgui.Create("DComboBox", frame)
	modeSelector:SetPos(20, 107)
	modeSelector:SetSize(width - 40, 38)
	modeSelector:SetFont("DRP.Admin.Body")
	modeSelector:SetTextColor(color_white)
	modeSelector:SetSortItems(false)
	modeSelector.Paint = function(self, panelWidth, panelHeight)
		draw.RoundedBox(7, 0, 0, panelWidth, panelHeight, self:IsHovered() and colors.panelHover or Color(17, 29, 51, 255))
		surface.SetDrawColor(self:IsMenuOpen() and colors.accent or colors.line)
		surface.DrawOutlinedRect(0, 0, panelWidth, panelHeight, 1)
	end

	local currentMode = string.lower(GetConVarString("gmod_toolmode"))
	for _, entry in ipairs(availableModes(weapon)) do
		modeSelector:AddChoice(entry.name, entry.mode, entry.mode == currentMode)
	end
	modeSelector.OnSelect = function(_, _, _, mode)
		mode = string.lower(tostring(mode or ""))
		if mode == "" or mode == activeMode then return end
		RunConsoleCommand("gmod_toolmode", mode)
		timer.Simple(0, function() buildSettings(mode) end)
	end

	settingsHost = vgui.Create("DPanel", frame)
	settingsHost:SetPos(14, 158)
	settingsHost:SetSize(width - 28, height - 172)
	settingsHost.Paint = function(_, panelWidth, panelHeight)
		draw.RoundedBox(8, 0, 0, panelWidth, panelHeight, Color(224, 230, 240, 252))
	end

	buildSettings(currentMode)
	return true
end

hook.Add("PlayerBindPress", "DRP.ContextMenu.Toolgun", function(_, bind, pressed)
	local command = string.match(string.Trim(string.lower(bind or "")), "^(%S+)") or ""
	if command ~= "+menu_context" and command ~= "menu_context" then return end

	if pressed then
		if not activeToolgun() then return end
		Context.Open()
		return true
	end

	if IsValid(frame) then
		Context.Close()
		return true
	end
end)

hook.Add("ShutDown", "DRP.ContextMenu.Cleanup", function()
	Context.Close()
end)
