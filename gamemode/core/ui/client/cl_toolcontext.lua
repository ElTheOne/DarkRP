DRP.ToolContext = DRP.ToolContext or {}

local Context = DRP.ToolContext
local contextHeld = false
local frame
local activeMode

local function friendly(value)
	value = tostring(value or "")
	if string.StartWith(value, "#") then value = language.GetPhrase(string.sub(value, 2)) end
	if value == "" then return "Tool Gun" end
	return value
end

local function activeTool()
	local ply = LocalPlayer()
	if not IsValid(ply) then return nil end
	local weapon = ply:GetActiveWeapon()
	if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" then return nil end

	local mode = isfunction(weapon.GetMode) and string.lower(tostring(weapon:GetMode() or "")) or ""
	if mode == "" then mode = string.lower(GetConVarString("gmod_toolmode") or "") end
	local tool = isfunction(weapon.GetToolObject) and weapon:GetToolObject() or nil
	if not istable(tool) then
		local stored = weapons.GetStored("gmod_tool")
		tool = stored and istable(stored.Tool) and stored.Tool[mode] or nil
	end
	return weapon, mode, tool
end

local function closeContext()
	if IsValid(frame) then frame:Remove() end
	frame = nil
	activeMode = nil
end

local function buildSettings(mode, tool)
	closeContext()
	if not contextHeld or mode == "" or not istable(tool) then return end

	local colors = DRP.UI.Colors
	local width = math.Clamp(math.floor(ScrW() * 0.25), 390, 500)
	local height = math.min(760, ScrH() - 40)
	local panel = vgui.Create("EditablePanel")
	frame = panel
	activeMode = mode
	panel:SetSize(width, height)
	panel:SetPos(ScrW() - width - 20, math.floor((ScrH() - height) * 0.5))
	panel:SetMouseInputEnabled(true)
	panel:SetKeyboardInputEnabled(false)
	panel:SetZPos(32760)
	panel.Paint = function(_, panelWidth, panelHeight)
		draw.RoundedBox(10, 0, 0, panelWidth, panelHeight, colors.background)
		draw.RoundedBoxEx(10, 0, 0, panelWidth, 82, colors.panel, true, true, false, false)
		draw.RoundedBoxEx(10, 0, 0, 5, panelHeight, colors.accent, true, false, true, false)
		surface.SetDrawColor(colors.accent)
		surface.DrawRect(0, 80, panelWidth, 2)
	end

	local title = vgui.Create("DLabel", panel)
	title:SetPos(20, 12)
	title:SetSize(width - 40, 30)
	title:SetFont("DRP.Admin.Header")
	title:SetTextColor(color_white)
	title:SetText(friendly(tool.Name or mode))

	local subtitle = vgui.Create("DLabel", panel)
	subtitle:SetPos(20, 42)
	subtitle:SetSize(width - 40, 25)
	subtitle:SetFont("DRP.Admin.Small")
	subtitle:SetTextColor(colors.accent)
	subtitle:SetText(string.upper(friendly(tool.Category or "Tool Gun")) .. "  •  HOLD C  •  SETTINGS APPLY IMMEDIATELY")

	local scroll = vgui.Create("DScrollPanel", panel)
	scroll:SetPos(12, 94)
	scroll:SetSize(width - 24, height - 106)

	local controls = vgui.Create("ControlPanel", scroll)
	controls.Name = "drp_tool_context_" .. mode
	controls:SetVisible(true)
	controls:SetPaintBackground(false)
	if isfunction(controls.SetAutoSize) then controls:SetAutoSize(true) end
	controls:Dock(TOP)
	scroll:AddItem(controls)

	local ok, failure = xpcall(function()
		if isfunction(tool.BuildCPanel) then
			if isfunction(controls.FillViaTable) then
				controls:FillViaTable({
					Text = "",
					ControlPanelBuildFunction = function(controlPanel)
						tool.BuildCPanel(controlPanel)
					end
				})
			else
				tool.BuildCPanel(controls)
			end
		else
			controls:Help("This tool has no configurable client settings.")
		end
	end, debug.traceback)

	if not ok then
		controls:Clear()
		controls:Help("The settings panel for this tool failed to build.")
		ErrorNoHalt("[DRP TOOL CONTEXT] " .. mode .. " panel failed:\n" .. tostring(failure) .. "\n")
	end

	panel.Think = function()
		local _, currentMode, currentTool = activeTool()
		if not contextHeld or not currentMode then
			closeContext()
			return
		end
		if currentMode ~= activeMode then
			buildSettings(currentMode, currentTool)
		end
	end
end

function Context.Open()
	local _, mode, tool = activeTool()
	if not mode or not tool then return false end

	if IsValid(g_ContextMenu) then g_ContextMenu:SetVisible(false) end
	if MediaPlayer and isfunction(MediaPlayer.HideSidebar) then MediaPlayer.HideSidebar() end
	buildSettings(mode, tool)
	return IsValid(frame)
end

function Context.Close()
	closeContext()
end

hook.Add("OnContextMenuOpen", "DRP.ToolContext.Open", function()
	contextHeld = true
	timer.Simple(0, function()
		if contextHeld then Context.Open() end
	end)
end)

hook.Add("OnContextMenuClose", "DRP.ToolContext.Close", function()
	contextHeld = false
	Context.Close()
end)

hook.Add("OnReloaded", "DRP.ToolContext.Reload", function()
	contextHeld = false
	Context.Close()
end)
