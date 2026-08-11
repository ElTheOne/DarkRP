TOOL.Category = "DarkRP Server"
TOOL.Name = "Police Patrol Routes"
TOOL.Command = nil
TOOL.ConfigName = ""
TOOL.ClientConVar = {
	route_name = "downtown_patrol_1",
	action = "walk",
	wait = "3"
}

TOOL.Information = {
	{ name = "left" },
	{ name = "right" },
	{ name = "reload" }
}

local ROUTE_REQUEST = "drp_police_routes_request_v1"
local ROUTE_MANAGE = "drp_police_routes_manage_v1"
local clientRouteLists
local refreshClientRouteLists

-- BuildCPanel is declared outside the CLIENT block because Sandbox loads stool
-- definitions in both realms. Keep this helper in the file scope so callbacks
-- created by BuildCPanel close over it instead of looking for a global.
local function manageRoute(action, name, value)
	if not CLIENT then return end
	name = string.sub(string.Trim(tostring(name or "")), 1, 40)
	if name == "" then return end
	net.Start(ROUTE_MANAGE)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.Clamp(math.floor(tonumber(action) or 0), 0, 7), 3)
	net.WriteString(name)
	net.WriteString(string.sub(tostring(value or ""), 1, 40))
	net.SendToServer()
end

if CLIENT then
	language.Add("tool.drp_police_route.name", "Police Patrol Routes")
	language.Add("tool.drp_police_route.desc", "Record persistent movement and interaction routes for population-scaled police NPCs.")
	language.Add("tool.drp_police_route.left", "Start recording, or add the selected action at your current position")
	language.Add("tool.drp_police_route.right", "Finish and save the current route")
	language.Add("tool.drp_police_route.reload", "Cancel the current recording")

	DRPPoliceRoutePreview = DRPPoliceRoutePreview or { nodes = {} }
	local previewNodes = {}
	local nodeOffset = Vector(0, 0, 4)
	local routeLineColor = Color(80, 210, 255)
	local routeBeam = Material("cable/redlaser")
	local actionColors = {
		scan = Color(255, 170, 40),
		use = Color(90, 220, 255),
		walk = Color(80, 255, 140)
	}
	clientRouteLists = setmetatable({}, { __mode = "k" })
	refreshClientRouteLists = function()
		for list in pairs(clientRouteLists) do
			if IsValid(list) then
				list:Clear()
				for _, route in ipairs(DRPPoliceRoutePreview.routes or {}) do
					local line = list:AddLine(route.name or "unnamed", tonumber(route.nodes) or 0,
						tostring(tonumber(route.active) or 0) .. "/" .. tostring(tonumber(route.npc_count) or 0),
						tonumber(route.updated) and os.date("%d %b %H:%M", route.updated) or "unknown")
					line.DRPRouteName = route.name
					line.DRPNPCCount = tonumber(route.npc_count) or 0
				end
			else
				clientRouteLists[list] = nil
			end
		end
	end

	local function rebuildPreviewNodes()
		previewNodes = {}
		for index, node in ipairs(DRPPoliceRoutePreview.nodes or {}) do
			local position = Vector(
				tonumber(node.pos and node.pos.x) or 0,
				tonumber(node.pos and node.pos.y) or 0,
				tonumber(node.pos and node.pos.z) or 0
			) + nodeOffset
			previewNodes[index] = {
				position = position,
				color = actionColors[node.action] or actionColors.walk,
				action = tostring(node.action or "walk")
			}
		end
	end
	net.Receive("drp_police_routes_sync_v1", function()
		local length = net.ReadUInt(16)
		local decoded = util.JSONToTable(util.Decompress(net.ReadData(length)) or "")
		DRPPoliceRoutePreview = istable(decoded) and decoded or { nodes = {} }
		rebuildPreviewNodes()
		refreshClientRouteLists()
	end)

	hook.Add("PostDrawTranslucentRenderables", "DRP.PoliceRoute.Preview", function()
		local ply = LocalPlayer()
		local weapon = IsValid(ply) and ply:GetActiveWeapon() or nil
		if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" or weapon:GetMode() ~= "drp_police_route" then return end
		for index = 1, #previewNodes do
			local node = previewNodes[index]
			render.SetColorMaterial()
			render.DrawSphere(node.position, 5, 8, 8, node.color)
			render.DrawWireframeBox(node.position, angle_zero, Vector(-7, -7, -7), Vector(7, 7, 7), node.color, true)
			local nextNode = previewNodes[index + 1]
			if nextNode then
				render.SetMaterial(routeBeam)
				render.DrawBeam(node.position, nextNode.position, 3, 0, 1, routeLineColor)
			end
			local facing = Angle(0, ply:EyeAngles().y - 90, 90)
			cam.Start3D2D(node.position + Vector(0, 0, 13), facing, 0.08)
				draw.SimpleTextOutlined(index .. "  " .. string.upper(node.action), "DermaDefaultBold", 0, 0, node.color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
			cam.End3D2D()
		end
	end)

	local function routeToolActive()
		local ply = LocalPlayer()
		local weapon = IsValid(ply) and ply:GetActiveWeapon() or nil
		return IsValid(weapon) and weapon:GetClass() == "gmod_tool" and weapon:GetMode() == "drp_police_route"
	end

	hook.Add("HUDPaint", "DRP.PoliceRoute.Status", function()
		if not routeToolActive() then return end
		local preview = DRPPoliceRoutePreview or {}
		local state = tostring(preview.state or "ready")
		local recording = state == "recording"
		local saved = state == "saved"
		local accent = recording and Color(255, 184, 65) or saved and Color(86, 235, 140) or Color(77, 198, 255)
		local width, height = math.min(620, ScrW() - 40), 102
		local x, y = math.floor((ScrW() - width) * 0.5), 72
		draw.RoundedBox(8, x, y, width, height, Color(7, 14, 26, 235))
		draw.RoundedBoxEx(8, x, y, 6, height, accent, true, false, true, false)
		draw.SimpleText("POLICE PATROL ROUTE  •  " .. string.upper(state), "DermaDefaultBold", x + 20, y + 18, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		local configuredName = GetConVar("drp_police_route_route_name")
		local previewName = tostring(preview.name or "")
		local name = previewName ~= "" and previewName or (configuredName and configuredName:GetString() or "unnamed")
		draw.SimpleText(name .. "  •  " .. #(preview.nodes or {}) .. " NODES", "DermaDefaultBold", x + width - 18, y + 18, color_white, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		local status = tostring(preview.status or "")
		if status == "" then status = "LEFT starts/adds an action. Walk to record movement. RIGHT saves. RELOAD cancels." end
		draw.SimpleText(status, "DermaDefault", x + 20, y + 49, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("LEFT: START / ADD ACTION     RIGHT: SAVE ROUTE     RELOAD: CANCEL", "DermaDefaultBold", x + 20, y + 78, Color(170, 188, 210), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end)
end

local function returnResult(ply, ok, reason)
	if not ok and IsValid(ply) and DRP.Net and DRP.Net.Notify then
		DRP.Net.Notify(ply, tostring(reason or "Police route action failed."), 2)
	end
	return ok == true
end

function TOOL:LeftClick(trace)
	if CLIENT then return true end
	local ply = self:GetOwner()
	if not DRP.PoliceNPCs then return returnResult(ply, false, "Police NPC service is unavailable.") end
	local ok, reason = DRP.PoliceNPCs:RecordAction(ply, self:GetClientInfo("action"), trace,
		self:GetClientInfo("route_name"), self:GetClientNumber("wait", 3))
	return returnResult(ply, ok, reason)
end

function TOOL:RightClick()
	if CLIENT then return true end
	local ply = self:GetOwner()
	if not DRP.PoliceNPCs then return returnResult(ply, false, "Police NPC service is unavailable.") end
	local ok, reason = DRP.PoliceNPCs:FinishRecording(ply)
	return returnResult(ply, ok, reason)
end

function TOOL:Reload()
	if CLIENT then return true end
	local ply = self:GetOwner()
	if not DRP.PoliceNPCs then return returnResult(ply, false, "Police NPC service is unavailable.") end
	local ok, reason = DRP.PoliceNPCs:CancelRecording(ply)
	return returnResult(ply, ok, reason)
end

function TOOL.BuildCPanel(panel)
	panel:Help("HeadAdmin+ only. The route is saved per map and police NPC population changes gradually as human police join or leave.")
	panel:TextEntry("Route name", "drp_police_route_route_name")
	local action = panel:ComboBox("Action recorded by left click", "drp_police_route_action")
	action:AddChoice("Walk marker", "walk")
	action:AddChoice("Wait", "wait")
	action:AddChoice("Scan nearby property illegals", "scan")
	action:AddChoice("Use aimed map entity", "use")
	panel:NumSlider("Wait seconds", "drp_police_route_wait", 1, 30, 0)
	panel:Help("SAVED ROUTES — select one to reuse or overwrite its name")
	local routes = vgui.Create("DListView")
	routes:SetTall(190)
	routes:SetMultiSelect(false)
	routes:AddColumn("Route")
	routes:AddColumn("Nodes"):SetFixedWidth(55)
	routes:AddColumn("NPCs"):SetFixedWidth(55)
	routes:AddColumn("Updated"):SetFixedWidth(105)
	routes.OnRowSelected = function(_, _, line)
		local name = tostring(line.DRPRouteName or line:GetColumnText(1) or "")
		if name ~= "" then RunConsoleCommand("drp_police_route_route_name", name) end
	end
	routes.OnRowRightClick = function(_, _, line)
		if not IsValid(line) then return end
		local name = tostring(line.DRPRouteName or line:GetColumnText(1) or "")
		if name == "" then return end
		local menu = DermaMenu()
		menu:AddOption("Preview route in the world", function()
			RunConsoleCommand("drp_police_route_route_name", name)
			manageRoute(1, name)
		end):SetIcon("icon16/eye.png")
		local allocation = menu:AddSubMenu("Police NPCs assigned")
		for amount = 0, 3 do
			local count = amount
			local label = count == 0 and "Disabled (0)" or tostring(count) .. " NPC" .. (count == 1 and "" or "s")
			allocation:AddOption(label, function() manageRoute(2, name, count) end)
		end
		menu:AddSpacer()
		menu:AddOption("Rename route", function()
			Derma_StringRequest("Rename police route", "Enter the new persistent route name.", name, function(value)
				value = string.Trim(tostring(value or ""))
				if value == "" then return end
				RunConsoleCommand("drp_police_route_route_name", value)
				manageRoute(3, name, value)
			end, nil, "RENAME", "CANCEL")
		end):SetIcon("icon16/textfield_rename.png")
		menu:AddOption("Delete route", function()
			Derma_Query("Delete patrol route '" .. name .. "'?\n\nAssigned NPCs will be removed or redistributed.",
				"Delete police route", "DELETE", function() manageRoute(4, name) end, "CANCEL")
		end):SetIcon("icon16/delete.png")
		menu:Open()
	end
	panel:AddItem(routes)
	clientRouteLists[routes] = true
	refreshClientRouteLists()
	timer.Simple(0, function()
		if not IsValid(routes) then return end
		net.Start(ROUTE_REQUEST)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.SendToServer()
	end)
	panel:Help("LEFT: begin recording or place an action. Movement nodes are captured automatically while you walk.")
	panel:Help("RIGHT-CLICK A SAVED ROUTE: preview, set NPC allocation, rename or delete it.")
	panel:Help("RIGHT: save, clear the preview and prepare the next route name. RELOAD: cancel recording.")
end
