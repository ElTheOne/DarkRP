DRP.AdminDatabaseUI = DRP.AdminDatabaseUI or {}

local DatabaseUI = DRP.AdminDatabaseUI
local UI = DRP.UI
local colors = UI.Colors
local REQUEST = "drp_admin_database_request_v1"
local RESPONSE = "drp_admin_database_response_v1"
local MUTATE = "drp_admin_database_mutate_v1"

local state = { tables = {}, table = nil, page = 1, total = 0, columns = {}, rows = {} }
local sidebarPanel, contentPanel, inventoryFrame

local function notify(message, failed)
	if notification then notification.AddLegacy(tostring(message or "Database request completed."), failed and NOTIFY_ERROR or NOTIFY_GENERIC, 5) end
	surface.PlaySound(failed and "buttons/button10.wav" or "buttons/button15.wav")
end

local function transmit(name, payload)
	local compressed = util.Compress(util.TableToJSON(payload or {}, false) or "{}") or ""
	if #compressed <= 0 or #compressed > 65535 then notify("Database request was too large.", true) return end
	net.Start(name)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(#compressed, 16)
		net.WriteData(compressed, #compressed)
	net.SendToServer()
end

local function requestTables() transmit(REQUEST, { action = "tables" }) end
local function requestRows(tableName, page) transmit(REQUEST, { action = "rows", table = tableName, page = page or 1 }) end
local function mutate(payload) transmit(MUTATE, payload) end

local function primaryText(identity)
	local parts = {}
	for key, value in SortedPairs(identity or {}) do parts[#parts + 1] = key .. "=" .. tostring(value) end
	return table.concat(parts, "  •  ")
end

local function entry(parent, value, enabled)
	local control = vgui.Create("DTextEntry", parent)
	control:SetFont("DRP.Admin.Small")
	control:SetTextColor(enabled and color_white or colors.muted)
	control:SetCursorColor(color_white)
	control:SetValue(tostring(value or ""))
	control:SetEnabled(enabled)
	control.Paint = function(self, width, height)
		draw.RoundedBox(5, 0, 0, width, height, colors.background)
		self:DrawTextEntryText(self:IsEnabled() and color_white or colors.muted, colors.accent, color_white)
	end
	return control
end

local function openAddItem(steamID64)
	local frame = UI.Frame("ADD HANDS ITEM", 560, 390)
	local kinds = { "resource", "weapon", "ammo", "drug", "attachment", "schematic" }
	local kind = vgui.Create("DComboBox", frame)
	kind:SetPos(24, 78) kind:SetSize(512, 38) kind:SetValue("resource")
	for _, value in ipairs(kinds) do kind:AddChoice(value) end
	local key = entry(frame, "", true) key:SetPos(24, 130) key:SetSize(512, 38) key:SetPlaceholderText("Item identifier, resource key, or weapon class")
	local label = entry(frame, "", true) label:SetPos(24, 182) label:SetSize(512, 38) label:SetPlaceholderText("Display name (optional)")
	local amount = entry(frame, "1", true) amount:SetPos(24, 234) amount:SetSize(250, 38) amount:SetPlaceholderText("Quantity")
	local grade = entry(frame, "1", true) grade:SetPos(286, 234) grade:SetSize(250, 38) grade:SetPlaceholderText("Schematic grade")
	local add = UI.Button(frame, "ADD TO HANDS", colors.green, function()
		mutate({ action = "inventory", steamID64 = steamID64, operation = "add", data = {
			kind = kind:GetValue(), key = key:GetValue(), label = label:GetValue(), amount = amount:GetValue(), grade = grade:GetValue()
		} })
		frame:Close()
	end)
	add:SetPos(24, 302) add:SetSize(512, 44)
end

local function openInventory(steamID64, snapshot)
	local frame = inventoryFrame
	if not IsValid(frame) or frame.DRPDatabaseSteamID ~= steamID64 then
		if IsValid(frame) then frame:Remove() end
		frame = UI.Frame("HANDS DATABASE EDITOR", 700, 680)
		inventoryFrame, frame.DRPDatabaseSteamID = frame, steamID64
		local caption = vgui.Create("DLabel", frame)
		caption:SetPos(24, 70) caption:SetSize(480, 38) caption:SetFont("DRP.Admin.Body") caption:SetTextColor(colors.muted)
		caption:SetText(steamID64 .. "  •  drag items to rearrange; right-click to edit")
		local add = UI.Button(frame, "ADD ITEM", colors.green, function() openAddItem(steamID64) end)
		add:SetPos(frame:GetWide() - 154, 72) add:SetSize(126, 36)
	elseif IsValid(frame.DRPDatabaseGrid) then
		frame.DRPDatabaseGrid:Remove()
	end
	local cell = math.floor(math.min((frame:GetWide() - 48) / (snapshot.width or 6), (frame:GetTall() - 150) / (snapshot.height or 10)))
	local grid = DRP.InventoryUI.BuildGrid(frame, snapshot.items or {}, {
		width = snapshot.width or 6, height = snapshot.height or 10, cell = cell,
		onMove = function(item, x, y) mutate({ action = "inventory", steamID64 = steamID64, operation = "move", data = { id = item.id, x = x, y = y, rotated = item.rotated == true } }) end,
		onItemMenu = function(item)
			local menu = DermaMenu()
			if item.w ~= item.h then menu:AddOption("Rotate", function() mutate({ action = "inventory", steamID64 = steamID64, operation = "move", data = { id = item.id, x = item.x, y = item.y, rotated = item.rotated ~= true } }) end):SetIcon("icon16/arrow_rotate_clockwise.png") end
			menu:AddOption("Set quantity", function()
				Derma_StringRequest("Set quantity", "Enter the authoritative stack quantity.", tostring(item.amount or 1), function(value)
					mutate({ action = "inventory", steamID64 = steamID64, operation = "amount", data = { id = item.id, amount = value } })
				end)
			end):SetIcon("icon16/pencil.png")
			menu:AddOption("Remove item", function()
				UI.Confirm("REMOVE HANDS ITEM", "Permanently remove " .. tostring(item.label or item.id) .. "?", "REMOVE", function()
					mutate({ action = "inventory", steamID64 = steamID64, operation = "remove", data = { id = item.id } })
				end, colors.red)
			end):SetIcon("icon16/delete.png")
			menu:Open()
		end
	})
	grid:SetPos(math.floor((frame:GetWide() - grid:GetWide()) * .5), 122)
	frame.DRPDatabaseGrid = grid
end

local renderTables, renderRows

renderTables = function()
	if not IsValid(sidebarPanel) or not IsValid(contentPanel) or contentPanel.DRPDatabaseActive ~= true then return end
	sidebarPanel:Clear()
	local title = UI.SectionLabel(sidebarPanel, "DATABASE TABLES")
	title:Dock(TOP) title:DockMargin(14, 10, 12, 4)
	local search = entry(sidebarPanel, "", true)
	search:Dock(TOP) search:DockMargin(10, 0, 10, 8) search:SetTall(36) search:SetPlaceholderText("Filter tables…")
	local scroll = vgui.Create("DScrollPanel", sidebarPanel)
	scroll:Dock(FILL) scroll:DockMargin(8, 0, 8, 8)
	local function populate()
		scroll:GetCanvas():Clear()
		local needle = string.lower(string.Trim(search:GetValue() or ""))
		for _, tableName in ipairs(state.tables) do
			if needle == "" or string.find(string.lower(tableName), needle, 1, true) then
				local name = tableName
				local button = UI.Button(scroll, name, colors.accent, function() state.table, state.page, state.scrollOffset = name, 1, 0 requestRows(name, 1) end)
				button:Dock(TOP) button:DockMargin(0, 0, 0, 5) button:SetTall(38)
				button.Paint = function(self, width, height)
					draw.RoundedBox(5, 0, 0, width, height, state.table == name and colors.accent or (self:IsHovered() and colors.panelHover or colors.background))
				end
			end
		end
	end
	search.OnChange = populate
	populate()
end

renderRows = function()
	if not IsValid(contentPanel) or contentPanel.DRPDatabaseActive ~= true then return end
	contentPanel:Clear()
	local title = UI.SectionLabel(contentPanel, string.upper(state.table or "DATABASE"))
	title:SetPos(16, 12) title:SetSize(contentPanel:GetWide() - 300, 30)
	local pages = math.max(1, math.ceil((state.total or 0) / 15))
	local hasPrimary = false
	for _, column in ipairs(state.columns) do if column.primary then hasPrimary = true break end end
	local pageLabel = vgui.Create("DLabel", contentPanel)
	pageLabel:SetPos(contentPanel:GetWide() - 282, 14) pageLabel:SetSize(120, 28) pageLabel:SetFont("DRP.Admin.Small") pageLabel:SetTextColor(colors.muted)
	pageLabel:SetContentAlignment(6) pageLabel:SetText("PAGE " .. state.page .. " / " .. pages)
	local previous = UI.Button(contentPanel, "‹", colors.accent, function() if state.page > 1 then requestRows(state.table, state.page - 1) end end)
	previous:SetPos(contentPanel:GetWide() - 152, 10) previous:SetSize(54, 34)
	local nextPage = UI.Button(contentPanel, "›", colors.accent, function() if state.page < pages then requestRows(state.table, state.page + 1) end end)
	nextPage:SetPos(contentPanel:GetWide() - 88, 10) nextPage:SetSize(54, 34)
	local scroll = vgui.Create("DScrollPanel", contentPanel)
	scroll:SetPos(12, 54) scroll:SetSize(contentPanel:GetWide() - 24, contentPanel:GetTall() - 66)
	local bar = scroll:GetVBar()
	bar.OnScroll = function(_, offset) state.scrollOffset = offset end
	timer.Simple(0, function() if IsValid(bar) then bar:SetScroll(tonumber(state.scrollOffset) or 0) end end)
	if #state.rows == 0 then
		local empty = vgui.Create("DLabel", scroll) empty:Dock(TOP) empty:SetTall(90) empty:SetFont("DRP.Admin.Body") empty:SetTextColor(colors.muted) empty:SetContentAlignment(5) empty:SetText("This table has no rows.")
		return
	end
	for _, rowData in ipairs(state.rows) do
		local row = rowData
		local cardWidth = math.max(520, contentPanel:GetWide() - 48)
		local editableColumns = math.max(1, #state.columns)
		local card = vgui.Create("DPanel", scroll)
		card:Dock(TOP) card:DockMargin(0, 0, 0, 10) card:SetTall(58 + editableColumns * 42 + ((state.table == "drp_player_pockets") and 48 or 0))
		card.Paint = function(_, width, height)
			draw.RoundedBox(7, 0, 0, width, height, colors.background)
			draw.RoundedBoxEx(7, 0, 0, 5, height, colors.accent, true, false, true, false)
			draw.SimpleText(primaryText(row.identity), "DRP.Admin.Small", 16, 18, colors.accent)
		end
		local y = 36
		for _, columnData in ipairs(state.columns) do
			local column = columnData
			local cell = row.values[column.name] or { value = "" }
			local label = vgui.Create("DLabel", card)
			label:SetPos(16, y) label:SetSize(155, 32) label:SetFont("DRP.Admin.Small") label:SetTextColor(column.primary and colors.accent or colors.muted)
			label:SetText(column.name .. (cell.null and "  [NULL]" or "") .. (cell.truncated and "  [TRUNCATED]" or ""))
			local canEdit = not column.primary and not column.generated and not (state.table == "drp_player_pockets" and column.name == "payload_json")
			local field = entry(card, cell.value, canEdit)
			field:SetPos(174, y) field:SetSize(cardWidth - 286, 32)
			local save = UI.Button(card, "SAVE", colors.accent, function()
				mutate({ action = "update", table = state.table, identity = row.identity, column = column.name, value = field:GetValue() })
			end)
			save:SetPos(cardWidth - 102, y) save:SetSize(86, 32) save:SetVisible(canEdit)
			y = y + 42
		end
		if state.table == "drp_player_pockets" and row.identity.steam_id then
			local hands = UI.Button(card, "EDIT HANDS INVENTORY", colors.green, function() mutate({ action = "inventory_open", steamID64 = row.identity.steam_id }) end)
			hands:SetPos(16, y) hands:SetSize(220, 36)
		end
		local remove = UI.Button(card, "DELETE ROW", colors.red, function()
			UI.Confirm("DELETE DATABASE ROW", "This permanently deletes " .. primaryText(row.identity) .. " from " .. state.table .. ". This cannot be undone.", "DELETE ROW", function()
				mutate({ action = "delete", table = state.table, identity = row.identity })
			end, colors.red)
		end)
		remove:SetPos(cardWidth - 142, 4) remove:SetSize(126, 28)
		remove:SetVisible(hasPrimary and state.table ~= "drp_schema_migrations")
	end
end

function DatabaseUI.Show(sidebar, content)
	sidebarPanel, contentPanel = sidebar, content
	content.DRPDatabaseActive = true
	state.table, state.page = nil, 1
	sidebar:Clear() content:Clear()
	local waiting = vgui.Create("DLabel", content)
	waiting:Dock(FILL) waiting:SetFont("DRP.Admin.Body") waiting:SetTextColor(colors.muted) waiting:SetContentAlignment(5)
	waiting:SetText("Reading database schema…")
	requestTables()
end

net.Receive(RESPONSE, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length = math.min(net.ReadUInt(20), 1048575)
	local decoded = util.JSONToTable(util.Decompress(net.ReadData(length) or "") or "")
	if not istable(decoded) then return end
	if decoded.kind == "error" then notify(decoded.message, true) return end
	if decoded.kind == "tables" then
		state.tables = istable(decoded.tables) and decoded.tables or {}
		renderTables()
		if state.tables[1] then state.table, state.page = state.tables[1], 1 requestRows(state.table, 1) end
	elseif decoded.kind == "rows" then
		state.table, state.page, state.total = decoded.table, tonumber(decoded.page) or 1, tonumber(decoded.total) or 0
		state.columns, state.rows = decoded.columns or {}, decoded.rows or {}
		renderRows()
	elseif decoded.kind == "mutated" then
		notify(decoded.message or "Database row updated.")
		if state.table then requestRows(state.table, state.page) end
	elseif decoded.kind == "inventory" then
		openInventory(tostring(decoded.steamID64 or ""), decoded.snapshot or {})
	end
end)
