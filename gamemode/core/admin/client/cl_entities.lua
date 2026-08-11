local UI = DRP.UI
local colors = UI.Colors
local requestMessage = "drp_admin_entities_request_v1"
local snapshotMessage = "drp_admin_entities_snapshot_v1"
local actionMessage = "drp_admin_entities_action_v1"

local ACTION_REMOVE = 1
local ACTION_FREEZE = 2
local ACTION_UNFREEZE = 3
local ACTION_REMOVE_ALL = 4

DRP.AdminEntities = DRP.AdminEntities or {}
local Manager = DRP.AdminEntities
local frame
local root
local selectedID
local selectedName
local rows = {}

local function sendRequest()
	if not selectedID then return end
	net.Start(requestMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(selectedID)
	net.SendToServer()
end

local function sendAction(action, entityIndex)
	if not selectedID then return end
	net.Start(actionMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(selectedID)
	net.WriteUInt(action, 3)
	net.WriteUInt(entityIndex or 0, 13)
	net.SendToServer()
end

local function contains(row, query)
	if query == "" then return true end
	local searchable = string.lower(table.concat({ row.label, row.class, row.model, row.kind, tostring(row.index) }, " "))
	return string.find(searchable, query, 1, true) ~= nil
end

local function populate(scroll, query)
	if not IsValid(scroll) then return end
	local canvas = scroll:GetCanvas()
	canvas:Clear()
	local visible = 0
	for _, row in ipairs(rows) do
		if contains(row, query) then
			visible = visible + 1
			local data = row
			local panel = vgui.Create("DPanel", canvas)
			panel:Dock(TOP)
			panel:DockMargin(0, 0, 0, 8)
			panel:SetTall(82)
			panel.Paint = function(_, width, height)
				draw.RoundedBox(8, 0, 0, width, height, colors.background)
				draw.RoundedBoxEx(8, 0, 0, 5, height, data.persistent and colors.red or colors.accent, true, false, true, false)
				draw.SimpleText(data.label, "DRP.Admin.Body", 18, 19, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(string.format("#%d  •  %s  •  %s", data.index, data.kind, data.class), "DRP.Admin.Small", 18, 42, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				local position = data.position
				local location = string.format("  •  %.0f, %.0f, %.0f", position.x, position.y, position.z)
				draw.SimpleText((data.model ~= "" and data.model or "No model") .. location, "DRP.Admin.Small", 18, 63, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end

			local status = vgui.Create("DLabel", panel)
			status:SetFont("DRP.Admin.Small")
			status:SetTextColor(data.persistent and colors.red or (data.frozen and colors.accent or colors.green))
			status:SetText(data.persistent and "PERSISTENT / PROTECTED" or (data.frozen and "FROZEN" or "MOBILE"))
			status:SetContentAlignment(6)

			local remove = UI.Button(panel, "Remove", colors.red, function()
				Derma_Query("Remove " .. data.label .. " (#" .. data.index .. ")?", "Remove player entity", "Remove", function()
					sendAction(ACTION_REMOVE, data.index)
				end, "Cancel")
			end)
			remove:SetEnabled(not data.persistent)

			local freeze = UI.Button(panel, data.frozen and "Unfreeze" or "Freeze", colors.accent, function()
				sendAction(data.frozen and ACTION_UNFREEZE or ACTION_FREEZE, data.index)
			end)
			freeze:SetEnabled(not data.persistent)

			panel.PerformLayout = function(self, width)
				status:SetPos(width - 420, 8)
				status:SetSize(160, 24)
				freeze:SetPos(width - 246, 24)
				freeze:SetSize(104, 36)
				remove:SetPos(width - 132, 24)
				remove:SetSize(112, 36)
			end
		end
	end
	if visible == 0 then
		local empty = vgui.Create("DLabel", canvas)
		empty:Dock(TOP)
		empty:SetTall(120)
		empty:SetFont("DRP.Admin.Body")
		empty:SetTextColor(colors.muted)
		empty:SetContentAlignment(5)
		empty:SetText(#rows == 0 and "This player has no tracked spawned entities." or "No entities match this search.")
	end
end

local function build()
	if not IsValid(frame) or not IsValid(root) then return end
	root:Clear()

	local title = vgui.Create("DLabel", root)
	title:SetPos(24, 14)
	title:SetSize(root:GetWide() - 48, 34)
	title:SetFont("DRP.Admin.Header")
	title:SetTextColor(color_white)
	title:SetText((selectedName or selectedID or "Player") .. "'s spawned entities")

	local summary = vgui.Create("DLabel", root)
	summary:SetPos(24, 48)
	summary:SetSize(root:GetWide() - 48, 24)
	summary:SetFont("DRP.Admin.Small")
	summary:SetTextColor(colors.muted)
	summary:SetText(string.format("%d tracked entities  •  live ownership index  •  protected gameplay infrastructure cannot be removed here", #rows))

	local search = vgui.Create("DTextEntry", root)
	search:SetPos(24, 84)
	search:SetSize(root:GetWide() - 382, 42)
	search:SetFont("DRP.Admin.Body")
	search:SetTextColor(color_white)
	search:SetCursorColor(color_white)
	search:SetPlaceholderText("Search class, model, type, or entity index…")
	search.Paint = function(self, width, height)
		draw.RoundedBox(7, 0, 0, width, height, colors.panel)
		self:DrawTextEntryText(color_white, colors.accent, color_white)
	end

	local refresh = UI.Button(root, "Refresh", colors.accent, sendRequest)
	refresh:SetPos(root:GetWide() - 344, 84)
	refresh:SetSize(140, 42)

	local removeAll = UI.Button(root, "Remove all", colors.red, function()
		Derma_Query("Remove every removable entity spawned by " .. (selectedName or selectedID) .. "?\n\nProtected infrastructure will be retained.", "Remove all player entities", "Remove all", function()
			sendAction(ACTION_REMOVE_ALL, 0)
		end, "Cancel")
	end)
	removeAll:SetPos(root:GetWide() - 194, 84)
	removeAll:SetSize(170, 42)
	removeAll:SetEnabled(#rows > 0)

	local scroll = vgui.Create("DScrollPanel", root)
	scroll:SetPos(24, 140)
	scroll:SetSize(root:GetWide() - 48, root:GetTall() - 164)
	search.OnChange = function(self) populate(scroll, string.lower(string.Trim(self:GetValue()))) end
	populate(scroll, "")

end

function Manager.Open(steamID64, name)
	selectedID = string.sub(tostring(steamID64 or ""), 1, 17)
	selectedName = string.sub(tostring(name or selectedID), 1, 64)
	rows = {}
	if IsValid(frame) then frame:Remove() end
	frame = UI.Frame("Entity Management", ScrW(), ScrH())
	frame:SetSize(ScrW(), ScrH())
	frame:SetPos(0, 0)
	frame:SetDraggable(false)
	if IsValid(frame.DRPCloseButton) then frame.DRPCloseButton:SetPos(frame:GetWide() - 50, 13) end
	root = vgui.Create("DPanel", frame)
	root:SetPos(0, 58)
	root:SetSize(frame:GetWide(), frame:GetTall() - 58)
	root.Paint = nil
	frame.OnRemove = function() frame = nil root = nil end
	build()
	sendRequest()
end

net.Receive(snapshotMessage, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local steamID64 = string.sub(net.ReadString(), 1, 17)
	local name = string.sub(net.ReadString(), 1, 64)
	local incoming = {}
	for index = 1, net.ReadUInt(8) do
		incoming[index] = {
			index = net.ReadUInt(13),
			class = string.sub(net.ReadString(), 1, 64),
			label = string.sub(net.ReadString(), 1, 64),
			model = string.sub(net.ReadString(), 1, 260),
			kind = string.sub(net.ReadString(), 1, 32),
			position = net.ReadVector(),
			frozen = net.ReadBool(),
			persistent = net.ReadBool()
		}
	end
	if selectedID ~= steamID64 or not IsValid(frame) then return end
	selectedName = name ~= "" and name or selectedName
	rows = incoming
	build()
end)
