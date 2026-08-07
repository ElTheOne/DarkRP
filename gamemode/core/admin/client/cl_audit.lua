local UI = DRP.UI
local colors = UI.Colors
local modernButton = UI.Button
local modernFrame = UI.Frame
local auditFrame
local auditEntries = {}
local function hasPermission(permission)
	return DRP.ClientOwner or DRP.AdminMaskHas(DRP.ClientAdminMask, permission)
end
function DRP.AdminUI.CloseAudit()
	if IsValid(auditFrame) then auditFrame:Close() end
end

local function validAuditSteamID(value)
	return isstring(value) and #value == 17 and string.match(value, "^%d+$") ~= nil
end

local function auditEventLabel(value)
	return string.upper(string.Replace(tostring(value or "unknown"), "_", " "))
end

local function populateAudit(scroll, filter, eventType)
	scroll:GetCanvas():Clear()
	filter = string.lower(string.Trim(filter or ""))
	local visible = 0
	for _, entry in ipairs(auditEntries) do
		local haystack = string.lower(entry.suspect .. " " .. entry.suspect_id .. " " .. entry.event_type .. " " .. entry.victim .. " " .. entry.victim_id .. " " .. entry.details)
		if (not eventType or eventType == entry.event_type) and (filter == "" or string.find(haystack, filter, 1, true)) then
			visible = visible + 1
			local rowData = entry
			local row = vgui.Create("DButton", scroll)
			row:Dock(TOP)
			row:DockMargin(0, 0, 0, 7)
			row:SetTall(94)
			row:SetText("")
			row.Paint = function(self, width, height)
				local fill = self:IsHovered() and colors.panelHover or colors.background
				local eventColor = (string.find(rowData.event_type, "death", 1, true) or string.find(rowData.event_type, "denied", 1, true) or string.find(rowData.event_type, "blacklist", 1, true)) and colors.red or colors.accent
				draw.RoundedBox(7, 0, 0, width, height, fill)
				draw.RoundedBoxEx(7, 0, 0, 6, height, eventColor, true, false, true, false)
				draw.SimpleText(os.date("%H:%M:%S", rowData.time), "DRP.Admin.Small", 18, 21, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(os.date("%d %b", rowData.time), "DRP.Admin.Small", 18, 46, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(auditEventLabel(rowData.event_type), "DRP.Admin.Small", 104, 21, eventColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText("Right click to copy IDs", "DRP.Admin.Small", 104, 46, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

				draw.SimpleText("SUSPECT", "DRP.Admin.Small", 330, 18, eventColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(string.sub(rowData.suspect, 1, 34), "DRP.Admin.Body", 405, 18, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(validAuditSteamID(rowData.suspect_id) and rowData.suspect_id or "No player SteamID", "DRP.Admin.Small", 330, 39, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText("VICTIM", "DRP.Admin.Small", 330, 65, colors.green, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(rowData.victim ~= "" and string.sub(rowData.victim, 1, 34) or "None", "DRP.Admin.Body", 405, 65, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(validAuditSteamID(rowData.victim_id) and rowData.victim_id or "No player SteamID", "DRP.Admin.Small", 330, 84, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

				draw.SimpleText("DETAILS", "DRP.Admin.Small", 710, 18, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(rowData.details ~= "" and string.sub(rowData.details, 1, 54) or "—", "DRP.Admin.Body", 710, 43, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end
			row.DoRightClick = function()
				local context = DermaMenu()
				local hasOption = false
				if validAuditSteamID(rowData.suspect_id) then
					hasOption = true
					context:AddOption("Copy suspect SteamID64", function() SetClipboardText(rowData.suspect_id) end):SetIcon("icon16/page_copy.png")
				end
				if validAuditSteamID(rowData.victim_id) then
					hasOption = true
					context:AddOption("Copy victim SteamID64", function() SetClipboardText(rowData.victim_id) end):SetIcon("icon16/page_copy.png")
				end
				if validAuditSteamID(rowData.suspect_id) and validAuditSteamID(rowData.victim_id) then
					hasOption = true
					context:AddOption("Copy both SteamID64s", function()
						SetClipboardText("Suspect: " .. rowData.suspect_id .. "\nVictim: " .. rowData.victim_id)
					end):SetIcon("icon16/page_white_copy.png")
				end
				if not hasOption then context:AddOption("No player SteamIDs on this event"):SetDisabled(true) end
				context:Open()
			end
		end
	end
	if visible == 0 then
		local empty = vgui.Create("DLabel", scroll)
		empty:Dock(TOP)
		empty:SetTall(80)
		empty:SetContentAlignment(5)
		empty:SetFont("DRP.Admin.Body")
		empty:SetTextColor(colors.muted)
		empty:SetText("No activity matches this filter.")
	end
end

local function openAuditPanel(entries)
	auditEntries = entries
	if IsValid(auditFrame) then auditFrame:Remove() end
	local frame = modernFrame("Activity Log", 1120, 680)
	auditFrame = frame
	frame.OnRemove = function() if auditFrame == frame then auditFrame = nil end end

	local card = UI.Card(frame)
	card:SetPos(16, 74)
	card:SetSize(frame:GetWide() - 32, frame:GetTall() - 90)

	local search = vgui.Create("DTextEntry", card)
	search:SetPos(14, 14)
	search:SetSize(card:GetWide() - 442, 38)
	search:SetFont("DRP.Admin.Body")
	search:SetTextColor(color_white)
	search:SetCursorColor(color_white)
	search:SetPlaceholderText("Search suspect, victim, SteamID, or details…")
	search.Paint = function(self, width, height)
		draw.RoundedBox(6, 0, 0, width, height, colors.background)
		self:DrawTextEntryText(color_white, colors.accent, color_white)
	end

	local eventFilter = vgui.Create("DComboBox", card)
	eventFilter:SetPos(card:GetWide() - 414, 14)
	eventFilter:SetSize(282, 38)
	eventFilter:SetFont("DRP.Admin.Body")
	eventFilter:SetTextColor(color_white)
	eventFilter:SetValue("All event types")
	eventFilter.Paint = function(_, width, height)
		draw.RoundedBox(6, 0, 0, width, height, colors.background)
	end
	eventFilter:AddChoice("All event types", false, true)
	local eventTypes = {}
	for _, entry in ipairs(entries) do eventTypes[entry.event_type] = true end
	for eventType in SortedPairs(eventTypes) do eventFilter:AddChoice(auditEventLabel(eventType), eventType) end

	local refresh = modernButton(card, "Refresh", colors.accent, function()
		net.Start("drp_audit_request_v1")
		net.SendToServer()
	end)
	refresh:SetPos(card:GetWide() - 118, 14)
	refresh:SetSize(104, 36)

	local summary = vgui.Create("DLabel", card)
	summary:SetPos(16, 62)
	summary:SetSize(card:GetWide() - 32, 26)
	summary:SetFont("DRP.Admin.Small")
	summary:SetTextColor(colors.muted)
	summary:SetText("Latest " .. #entries .. " server events  •  Buffered and persisted in batches")

	local scroll = vgui.Create("DScrollPanel", card)
	scroll:SetPos(12, 94)
	scroll:SetSize(card:GetWide() - 24, card:GetTall() - 106)
	local selectedEvent
	local function applyFilters() populateAudit(scroll, search:GetValue(), selectedEvent) end
	search.OnChange = applyFilters
	eventFilter.OnSelect = function(_, _, _, data)
		selectedEvent = data or nil
		applyFilters()
	end
	populateAudit(scroll, "", nil)
end

net.Receive("drp_audit_snapshot_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not hasPermission("logs") then return end
	local entries = {}
	for index = 1, net.ReadUInt(7) do
		entries[index] = {
			id = net.ReadUInt(32), time = net.ReadUInt(32),
			suspect_id = string.sub(net.ReadString(), 1, 32),
			suspect = string.sub(net.ReadString(), 1, 64),
			event_type = string.sub(net.ReadString(), 1, 40),
			victim_id = string.sub(net.ReadString(), 1, 32),
			victim = string.sub(net.ReadString(), 1, 64),
			details = string.sub(net.ReadString(), 1, 192)
		}
	end
	openAuditPanel(entries)
end)
