DRP.SalvageUI = DRP.SalvageUI or { State = nil }

local UI = DRP.SalvageUI
local frame
local handsFrame

local function sendAction(action, itemID, placement)
	local state = UI.State
	if not state or not IsValid(Entity(state.entity or -1)) then return end
	local data = { action = action, id = itemID or "", revision = state.revision, placement = placement }
	local compressed = util.Compress(util.TableToJSON(data, false) or "{}") or ""
	if #compressed > 32768 then return end
	net.Start("drp_salvage_action_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(#compressed, 16)
		net.WriteData(compressed, #compressed)
		net.WriteUInt(state.entity, 16)
	net.SendToServer()
end

local function addLootRows(parent, titleText, loot, accent, grid, cell)
	local title = vgui.Create("DLabel", parent)
	title:Dock(TOP) title:DockMargin(10, 10, 10, 4) title:SetTall(24)
	title:SetFont("DRP.Admin.Header") title:SetTextColor(accent) title:SetText(titleText)
	if #loot == 0 then
		local empty = vgui.Create("DLabel", parent)
		empty:Dock(TOP) empty:DockMargin(10, 0, 10, 7) empty:SetTall(38)
		empty:SetFont("DRP.Admin.Small") empty:SetTextColor(DRP.UI.Colors.muted) empty:SetText("Nothing available. The container will refresh later.")
		return
	end
	for _, item in ipairs(loot) do
		local row = vgui.Create("DButton", parent)
		row:Dock(TOP) row:DockMargin(10, 0, 10, 7) row:SetTall(58) row:SetText("")
		if DRP.InventoryUI and DRP.InventoryUI.AddModelIcon then
			local icon = DRP.InventoryUI.AddModelIcon(row, item, 4)
			icon:SetSize(50, 50)
		end
		row.Paint = function(self, width, height)
			draw.RoundedBox(7, 0, 0, width, height, self:IsHovered() and DRP.UI.Colors.panelHover or DRP.UI.Colors.panel)
			draw.RoundedBoxEx(7, 0, 0, 4, height, accent, true, false, true, false)
			draw.SimpleText(item.label .. ((item.amount or 1) > 1 and (" ×" .. item.amount) or ""), "DRP.Admin.Body", 64, 18, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(string.upper(item.scope) .. " • " .. item.w .. "×" .. item.h, "DRP.Admin.Small", 64, 41, DRP.UI.Colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText("TAKE", "DRP.Admin.Small", width - 14, height * 0.5, accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
		row.DoClick = function() sendAction("take", item.id) end
		row.DoRightClick = function()
			local menu = DermaMenu()
			menu:AddOption("Take into Hands", function() sendAction("take", item.id) end):SetIcon("icon16/arrow_right.png")
			if item.w ~= item.h then
				menu:AddOption("Take rotated", function()
					sendAction("take", item.id, { auto = true, rotated = true })
				end):SetIcon("icon16/arrow_rotate_clockwise.png")
			end
			menu:AddOption("Inspect", function()
				Derma_Message(item.label .. "\n" .. string.upper(item.scope) .. " salvage\nFootprint " .. item.w .. " × " .. item.h .. "\nQuantity " .. tostring(item.amount or 1), "SALVAGE ITEM", "CLOSE")
			end):SetIcon("icon16/magnifier.png")
			menu:Open()
		end
		row.OnMousePressed = function(self, mouseCode)
			if mouseCode ~= MOUSE_LEFT then return end
			self:MouseCapture(true) self.Dragging = true self:SetCursor("sizeall")
		end
		row.OnMouseReleased = function(self, mouseCode)
			if mouseCode ~= MOUSE_LEFT then return end
			self:MouseCapture(false) self:SetCursor("hand")
			local cursorX, cursorY = input.GetCursorPos()
			local localX, localY = grid:ScreenToLocal(cursorX, cursorY)
			if localX >= 0 and localY >= 0 and localX < grid:GetWide() and localY < grid:GetTall() then
				sendAction("take", item.id, { x = math.floor(localX / cell) + 1, y = math.floor(localY / cell) + 1, rotated = false })
			else
				sendAction("take", item.id)
			end
			self.Dragging = false
		end
	end
end

local function openSalvage(animate)
	local state = UI.State
	if not state then return end
	hook.Run("DRPInventoryContextOpening", "salvage")
	if DRP.InventoryUI and DRP.InventoryUI.CloseStandalone then DRP.InventoryUI.CloseStandalone(true) end
	if IsValid(frame) then frame:Remove() end
	if IsValid(handsFrame) then handsFrame:Remove() end
	local titleText = state.kind == "dumpster" and "DUMPSTER SALVAGE" or "TRASHCAN SALVAGE"
	local margin, paneGap = 20, 18
	local availableWidth = ScrW() - margin * 2
	local handsWidth = math.max(600, math.floor(availableWidth * 0.58))
	local sourceWidth = availableWidth - paneGap - handsWidth
	if sourceWidth < 340 then
		sourceWidth = 340
		handsWidth = math.max(520, availableWidth - paneGap - sourceWidth)
	end
	local panelHeight = math.max(650, ScrH() - margin * 2)
	local rightX = margin + sourceWidth + paneGap

	local left
	local hands = state.hands or { items = {}, equipped = {}, width = 6, height = 10 }
	handsFrame = DRP.InventoryUI.CreateHandsFrame(hands, {
		x = rightX,
		y = margin,
		width = handsWidth,
		height = panelHeight,
		animate = animate == true,
		footer = "DRAG ITEMS LEFT TO RETURN THEM  •  RIGHT-CLICK FOR HANDS ACTIONS",
		onMove = function(item, x, y)
			DRP.InventoryUI.SendAction("move", { id = item.id, x = x, y = y, rotated = item.rotated == true })
		end,
		onDropOutside = function(item, cursorX, cursorY)
			if not IsValid(left) then return end
			local x, y = left:LocalToScreen(0, 0)
			if cursorX >= x and cursorY >= y and cursorX <= x + left:GetWide() and cursorY <= y + left:GetTall() then
				sendAction("return", item.id)
			end
		end,
		onItemMenu = function(item, index)
			local menu = DermaMenu()
			menu:AddOption("Return to this container", function() sendAction("return", item.id) end):SetIcon("icon16/arrow_left.png")
			menu:AddOption("Hands item actions", function() DRP.InventoryUI.OpenItemMenu(item, index) end):SetIcon("icon16/application_view_tile.png")
			menu:Open()
		end
	})
	local grid = handsFrame.DRPInventoryGrid

	frame = DRP.UI.Frame(titleText, sourceWidth, panelHeight)
	frame:SetPos(margin, margin)
	if DRP.InventoryUI and DRP.InventoryUI.InstallFade then DRP.InventoryUI.InstallFade(frame, animate == true) end
	frame.Paint = function(_, width, height)
		local accent = DRP.UI.Colors.green
		draw.RoundedBox(12, 0, 0, width, height, Color(5, 10, 19, 249))
		draw.RoundedBoxEx(12, 0, 0, width, 60, Color(13, 23, 39, 252), true, true, false, false)
		draw.RoundedBox(12, 0, 0, 5, height, accent)
		draw.RoundedBox(8, 18, 57, width - 36, 2, Color(accent.r, accent.g, accent.b, 180))
		draw.SimpleText(titleText, "DRP.Admin.Title", 22, 28, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local outerPadding = 24
	local paneWidth = frame:GetWide() - outerPadding * 2
	local leftX = outerPadding
	local contentTop = 150
	local contentBottom = frame:GetTall() - 24
	local contentHeight = contentBottom - contentTop

	local hint = vgui.Create("DLabel", frame)
	hint:SetPos(24, 68) hint:SetSize(frame:GetWide() - 48, 54) hint:SetFont("DRP.Admin.Small") hint:SetTextColor(DRP.UI.Colors.muted)
	hint:SetWrap(true)
	hint:SetText("Common finds are personal • Rare finds are shared and can be claimed by another scavenger • Drag loot into Hands")

	local sourceTitle = vgui.Create("DLabel", frame)
	sourceTitle:SetPos(leftX, 120) sourceTitle:SetSize(paneWidth, 28) sourceTitle:SetFont("DRP.Admin.Header") sourceTitle:SetTextColor(color_white)
	sourceTitle:SetText(state.kind == "dumpster" and "DUMPSTER CONTENTS" or "TRASHCAN CONTENTS")

	left = vgui.Create("DScrollPanel", frame)
	left:SetPos(leftX, contentTop) left:SetSize(paneWidth, contentHeight - 52)

	local refresh = DRP.UI.Button(frame, "REFRESH VIEW", DRP.UI.Colors.accent, function() sendAction("refresh", "") end)
	refresh:SetPos(leftX, contentBottom - 42) refresh:SetSize(paneWidth, 42)

	local gridCell = grid and math.floor(grid:GetWide() / math.max(1, hands.width or 6)) or 48
	addLootRows(left, "PERSONAL FINDS", state.personal or {}, DRP.UI.Colors.green, grid, gridCell)
	addLootRows(left, "SHARED RARE FINDS", state.shared or {}, DRP.UI.Colors.purple, grid, gridCell)

	-- Both windows represent separate inventories, so closing either closes the
	-- interaction as one paired view while preserving independent frame chrome.
	local closingPair = false
	local closeLeft, closeHands = frame.Close, handsFrame.Close
	local function closeBoth()
		if closingPair then return end
		closingPair = true
		if IsValid(frame) then closeLeft(frame) end
		if IsValid(handsFrame) then closeHands(handsFrame) end
	end
	frame.Close = closeBoth
	handsFrame.Close = closeBoth

	frame.Think = function(self)
		local entity = Entity(state.entity or -1)
		local ply = LocalPlayer()
		if not IsValid(entity) or not IsValid(ply) or not ply:Alive() or ply:GetPos():DistToSqr(entity:GetPos()) > 160 * 160 then closeBoth() return end
		self.DRPSalvageNextSight = self.DRPSalvageNextSight or 0
		if self.DRPSalvageNextSight <= CurTime() then
			self.DRPSalvageNextSight = CurTime() + 0.2
			local trace = util.TraceLine({ start = ply:EyePos(), endpos = entity:WorldSpaceCenter(), mask = MASK_SOLID, filter = ply })
			if trace.Hit and trace.Entity ~= entity then closeBoth() end
		end
	end
end

net.Receive("drp_salvage_open_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length = net.ReadUInt(20)
	if length <= 0 or length > 1048575 then return end
	local json = util.Decompress(net.ReadData(length))
	local decoded = json and util.JSONToTable(json) or nil
	if not istable(decoded) then return end
	local firstOpen = not IsValid(frame) and not IsValid(handsFrame)
	UI.State = decoded
	openSalvage(firstOpen)
end)

hook.Add("DRPInventoryUpdated", "DRP.Salvage.RefreshHands", function(snapshot)
	if not UI.State or (not IsValid(frame) and not IsValid(handsFrame)) then return end
	UI.State.hands = {
		items = snapshot.items or {},
		equipped = snapshot.equipped or {},
		selected = snapshot.selected or "",
		width = snapshot.width or 6,
		height = snapshot.height or 10
	}
	timer.Simple(0, function()
		if UI.State and (IsValid(frame) or IsValid(handsFrame)) then openSalvage(false) end
	end)
end)

hook.Add("DRPInventoryContextOpening", "DRP.Salvage.CloseForOtherInventory", function(kind)
	if kind == "salvage" then return end
	if IsValid(frame) then frame:Remove() end
	if IsValid(handsFrame) then handsFrame:Remove() end
	frame, handsFrame = nil, nil
	UI.State = nil
end)
