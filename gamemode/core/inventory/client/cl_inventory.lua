DRP.InventoryUI = DRP.InventoryUI or { Items = {}, Equipped = {}, Selected = "", Width = 6, Height = 10 }

local UI = DRP.InventoryUI
local frame
local equipmentOrder = { "primary", "secondary", "alt1", "alt2", "alt3", "alt4", "alt5", "alt6" }
local equipmentLabels = {
	primary = "PRIMARY",
	secondary = "SECONDARY",
	alt1 = "ALT 1",
	alt2 = "ALT 2",
	alt3 = "ALT 3",
	alt4 = "ALT 4",
	alt5 = "ALT 5",
	alt6 = "ALT 6"
}

local vipEquipmentSlots = { alt4 = true, alt5 = true, alt6 = true }

local function canUseEquipmentSlot(slot)
	if not vipEquipmentSlots[slot] then return true end
	return DRP.ClientVIPAccess == true
end
UI.CanUseEquipmentSlot = canUseEquipmentSlot

local function roleColor()
	local ply = LocalPlayer()
	local job = IsValid(ply) and ply.DRPJob and ply:DRPJob() or nil
	local colour = job and job.color or (DRP.UI and DRP.UI.Colors.accent) or Color(74, 205, 255)
	return Color(colour.r, colour.g, colour.b)
end
UI.RoleColor = roleColor

local function sendAction(action, data)
	data = data or {}
	data.action = action
	local compressed = util.Compress(util.TableToJSON(data, false) or "{}") or ""
	if #compressed > 32768 then return end
	net.Start("drp_inventory_action_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(#compressed, 16)
		net.WriteData(compressed, #compressed)
	net.SendToServer()
end
UI.SendAction = sendAction

local kindColors = {
	weapon = Color(244, 105, 128), ammo = Color(255, 190, 88),
	drug = Color(157, 120, 255), resource = Color(104, 235, 150),
	entity = Color(74, 205, 255), dupe = Color(74, 205, 255)
}

local function itemSubtitle(item)
	if item.kind == "ammo" then return tostring(item.key or "AMMO") .. " • " .. tostring(item.amount or 1) end
	if item.kind == "drug" then return "DRUG" .. ((item.amount or 1) > 1 and (" ×" .. item.amount) or "") end
	if item.kind == "resource" then return "RESOURCE" .. ((item.amount or 1) > 1 and (" ×" .. item.amount) or "") end
	return string.upper(tostring(item.kind or "item")) .. " • " .. tostring(item.w or 1) .. "×" .. tostring(item.h or 1)
end

local function itemModel(item)
	local model = tostring(item.model or "")
	if model ~= "" then return model end
	if item.kind == "weapon" then
		local stored = weapons.GetStored(tostring(item.class or "")) or (list.Get("Weapon") or {})[tostring(item.class or "")]
		model = istable(stored) and tostring(stored.WorldModel or stored.WM or "") or ""
	end
	if model ~= "" then return model end
	if item.kind == "ammo" then return "models/items/boxsrounds.mdl" end
	if item.kind == "drug" then return "models/props_lab/jar01b.mdl" end
	if item.kind == "resource" then return "models/gibs/metal_gib4.mdl" end
	return "models/props_junk/cardboard_box004a.mdl"
end

local function addModelIcon(parent, item, inset)
	inset = inset or 5
	local icon = vgui.Create("SpawnIcon", parent)
	icon:SetPos(inset, inset)
	icon:SetSize(math.max(16, parent:GetWide() - inset * 2), math.max(16, parent:GetTall() - inset * 2))
	icon:SetModel(itemModel(item))
	icon:SetMouseInputEnabled(false)
	icon:SetKeyboardInputEnabled(false)
	icon:SetAlpha(215)
	return icon
end
UI.AddModelIcon = addModelIcon

local function findItem(itemID)
	for index, item in ipairs(UI.Items or {}) do
		if item.id == itemID then return item, index end
	end
end

local function openMenu(item, legacyIndex)
	local menu = DermaMenu()
	menu:AddOption("Select", function() UI.Selected = item.id sendAction("select", { id = item.id }) end):SetIcon("icon16/accept.png")
	if item.kind == "weapon" or item.kind == "drug" then
		local equipmentMenu = menu:AddSubMenu("Assign equipment slot")
		for _, slot in ipairs(equipmentOrder) do
			local selectedSlot = slot
			if item.kind == "weapon" or string.StartWith(selectedSlot, "alt") then
				local option = equipmentMenu:AddOption(equipmentLabels[selectedSlot] .. (canUseEquipmentSlot(selectedSlot) and "" or "  •  VIP+"), function()
					sendAction("equip", { id = item.id, slot = selectedSlot })
				end):SetIcon((selectedSlot == "primary" or selectedSlot == "secondary") and "icon16/gun.png" or "icon16/bullet_star.png")
				if not canUseEquipmentSlot(selectedSlot) then option:SetEnabled(false) end
			end
		end
	end
	if item.kind == "drug" or item.kind == "ammo" then
		menu:AddOption(item.kind == "ammo" and "Load ammunition" or "Consume", function() sendAction("use", { id = item.id }) end):SetIcon("icon16/lightning.png")
	end
	if item.kind == "schematic" then
		menu:AddOption("Learn schematic permanently", function() sendAction("learn_schematic", { id = item.id }) end):SetIcon("icon16/book_open.png")
	end
	if item.w ~= item.h then menu:AddOption("Rotate", function() sendAction("move", { id = item.id, x = item.x, y = item.y, rotated = not item.rotated }) end):SetIcon("icon16/arrow_rotate_clockwise.png") end
	if DRP.ContractsUI and DRP.ContractsUI.AddPocketMenu then DRP.ContractsUI.AddPocketMenu(menu, item.id, legacyIndex) end
	menu:AddSpacer()
	menu:AddOption("Drop into world", function() sendAction("drop", { id = item.id }) end):SetIcon("icon16/arrow_down.png")
	menu:Open()
end
UI.OpenItemMenu = openMenu

function UI.BuildGrid(parent, inventory, options)
	options = options or {}
	local columns, rows = options.width or UI.Width, options.height or UI.Height
	local cell = options.cell or 48
	local selectedID = tostring(options.selected ~= nil and options.selected or UI.Selected or "")
	local grid = vgui.Create("DPanel", parent)
	grid:SetSize(columns * cell, rows * cell)
	grid.Paint = function(_, width, height)
		local accent = options.accent or roleColor()
		draw.RoundedBox(10, 0, 0, width, height, Color(5, 10, 20, 248))
		draw.RoundedBox(10, 1, 1, width - 2, height - 2, Color(accent.r, accent.g, accent.b, 12))
		surface.SetDrawColor(Color(accent.r, accent.g, accent.b, 48))
		for x = 0, columns do surface.DrawLine(x * cell, 0, x * cell, height) end
		for y = 0, rows do surface.DrawLine(0, y * cell, width, y * cell) end
	end

	for index, item in ipairs(inventory or {}) do
		local button = vgui.Create("DButton", grid)
		button:SetText("")
		button:SetPos((item.x - 1) * cell + 3, (item.y - 1) * cell + 3)
		button:SetSize(item.w * cell - 6, item.h * cell - 6)
		button:SetTooltip(item.label .. "\n" .. itemSubtitle(item))
		addModelIcon(button, item, 4)
		button.Paint = function(self, width, height)
			local accent = options.accent or roleColor()
			local kindAccent = kindColors[item.kind] or accent
			draw.RoundedBox(7, 0, 0, width, height, self:IsHovered() and Color(22, 35, 54, 252) or Color(10, 18, 31, 248))
			draw.RoundedBoxEx(7, 0, 0, 4, height, selectedID == item.id and accent or kindAccent, true, false, true, false)
			if self:IsHovered() or selectedID == item.id then surface.SetDrawColor(Color(accent.r, accent.g, accent.b, 150)) surface.DrawOutlinedRect(1, 1, width - 2, height - 2, 1) end
		end
		button.PaintOver = function(_, width, height)
			local accent = options.accent or roleColor()
			draw.RoundedBox(0, 4, height - 22, width - 4, 22, Color(3, 7, 14, 220))
			draw.SimpleText(string.upper(string.sub(tostring(item.label or "ITEM"), 1, math.max(5, math.floor(width / 7)))), "DRP.Admin.Small", 9, height - 11, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			if (item.amount or 1) > 1 then draw.SimpleText("×" .. tostring(item.amount), "DRP.Admin.Small", width - 7, 8, accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP) end
			if selectedID == item.id then draw.SimpleText("●", "DRP.Admin.Small", 9, 7, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP) end
		end
		button.OnMousePressed = function(self, mouseCode)
			if mouseCode == MOUSE_RIGHT then
				if options.onItemMenu then options.onItemMenu(item, index) else openMenu(item, index) end
				return
			end
			if mouseCode == MOUSE_LEFT then self:MouseCapture(true) self.Dragging = true self:SetCursor("sizeall") end
		end
		button.OnMouseReleased = function(self, mouseCode)
			if mouseCode ~= MOUSE_LEFT then return end
			self:MouseCapture(false) self:SetCursor("hand")
			local cursorX, cursorY = input.GetCursorPos()
			local localX, localY = grid:ScreenToLocal(cursorX, cursorY)
			local targetX, targetY = math.floor(localX / cell) + 1, math.floor(localY / cell) + 1
			if targetX == item.x and targetY == item.y then
				if options.onItemMenu then options.onItemMenu(item, index) else openMenu(item, index) end
			elseif targetX >= 1 and targetY >= 1 and targetX <= columns and targetY <= rows then
				if options.onMove then options.onMove(item, targetX, targetY) else sendAction("move", { id = item.id, x = targetX, y = targetY, rotated = item.rotated == true }) end
			elseif options.onDropOutside then
				options.onDropOutside(item, cursorX, cursorY)
			end
			self.Dragging = false
		end
	end
	return grid
end

local function configurePlayerModel(panel, appearance)
	appearance = appearance or {}
	local ply = LocalPlayer()
	local modelName = tostring(appearance.model or (IsValid(ply) and ply:GetModel()) or "")
	if modelName == "" or not util.IsValidModel(modelName) then modelName = "models/player/Group01/male_07.mdl" end
	panel:SetModel(modelName)
	if not IsValid(panel.Entity) then return end
	panel.Entity:SetSkin(math.max(0, math.floor(tonumber(appearance.skin) or (IsValid(ply) and ply:GetSkin()) or 0)))
	if istable(appearance.bodygroups) then
		for bodyGroup, value in pairs(appearance.bodygroups) do panel.Entity:SetBodygroup(tonumber(bodyGroup) or 0, tonumber(value) or 0) end
	elseif IsValid(ply) then
		for bodyGroup = 0, ply:GetNumBodyGroups() - 1 do panel.Entity:SetBodygroup(bodyGroup, ply:GetBodygroup(bodyGroup)) end
	end
	if isstring(appearance.material) then panel.Entity:SetMaterial(appearance.material) end

	local function fitModel()
		if not IsValid(panel) or not IsValid(panel.Entity) then return end
		local mins, maxs = panel.Entity:GetRenderBounds()
		local centre = (mins + maxs) * 0.5
		local bounds = maxs - mins
		local verticalFOV = 36
		local aspect = math.max(0.35, panel:GetWide() / math.max(1, panel:GetTall()))
		local verticalTangent = math.tan(math.rad(verticalFOV * 0.5))
		local horizontalTangent = verticalTangent * aspect
		local halfHeight = math.max(24, bounds.z * 0.5)
		local halfWidth = math.max(math.abs(bounds.x), math.abs(bounds.y), 18)
		-- Fit against both axes so unusual or taller Workshop playermodels remain
		-- fully visible instead of being cropped to their torso.
		local distance = math.max(halfHeight / verticalTangent, halfWidth / horizontalTangent) * 1.18
		panel:SetFOV(verticalFOV)
		panel:SetCamPos(centre + Vector(distance, 0, 0))
		panel:SetLookAt(centre + Vector(0, 0, bounds.z * 0.015))
	end

	panel.LayoutEntity = function(_, entity)
		entity:SetAngles(Angle(0, 18, 0))
	end
	panel:SetAmbientLight(Color(72, 78, 92))
	panel:SetDirectionalLight(BOX_FRONT, Color(220, 235, 255))
	panel:SetDirectionalLight(BOX_RIGHT, Color(90, 150, 210))
	fitModel()
	panel.OnSizeChanged = function() fitModel() end
end

local function findItemIn(source, itemID)
	for _, item in ipairs(source or {}) do if item.id == itemID then return item end end
end

local function makeEquipmentSlot(parent, slot, x, y, width, height, targets, sourceItems, equipped, options)
	options = options or {}
	local locked = options.locked == true
	local item = findItemIn(sourceItems or UI.Items, (equipped or UI.Equipped or {})[slot])
	local button = vgui.Create("DButton", parent)
	button:SetPos(x, y) button:SetSize(width, height) button:SetText("")
	if item then addModelIcon(button, item, 5) end
	button.Paint = function(self, panelWidth, panelHeight)
		local accent = options.accent or roleColor()
		draw.RoundedBox(8, 0, 0, panelWidth, panelHeight, locked and Color(12, 15, 23, 245) or (self:IsHovered() and Color(22, 35, 54, 250) or Color(8, 15, 27, 245)))
		draw.RoundedBoxEx(8, 0, 0, 4, panelHeight, item and accent or Color(accent.r, accent.g, accent.b, 80), true, false, true, false)
		surface.SetDrawColor(Color(accent.r, accent.g, accent.b, item and 120 or 42)) surface.DrawOutlinedRect(1, 1, panelWidth - 2, panelHeight - 2, 1)
	end
	button.PaintOver = function(_, panelWidth, panelHeight)
		local accent = options.accent or roleColor()
		draw.RoundedBox(0, 4, 0, panelWidth - 4, 21, Color(3, 7, 14, 225))
		draw.SimpleText(equipmentLabels[slot], "DRP.Admin.Small", 10, 10, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		if locked then
			draw.SimpleText("VIP+ LOCKED", "DRP.Admin.Small", panelWidth * 0.5, panelHeight * 0.57, Color(235, 120, 190), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		elseif item then
			draw.RoundedBox(0, 4, panelHeight - 21, panelWidth - 4, 21, Color(3, 7, 14, 225))
			draw.SimpleText(string.upper(string.sub(tostring(item.label), 1, math.max(6, math.floor(panelWidth / 7)))), "DRP.Admin.Small", 10, panelHeight - 10, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		else
			draw.SimpleText("DROP ITEM HERE", "DRP.Admin.Small", panelWidth * 0.5, panelHeight * 0.57, Color(155, 166, 184), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
	button.DoClick = function()
		if locked or not item then return end
		if options.onItem then options.onItem(item) elseif not options.readOnly then sendAction("select", { id = item.id }) end
	end
	button.DoRightClick = function() if not locked and item and not options.readOnly then sendAction("unequip", { slot = slot }) end end
	button:SetTooltip(locked and "Requires VIP entitlement or HeadAdmin+" or (item and ((options.readOnly and "Stored " or "Select ") .. item.label .. (options.readOnly and "" or "\nRight-click to clear slot")) or (options.readOnly and "Empty equipment slot" or ("Drag a weapon or consumable into " .. equipmentLabels[slot]))))
	if not options.readOnly and not locked then targets[#targets + 1] = { panel = button, slot = slot } end
	return button
end

local function installFade(framePanel, animate)
	framePanel:SetAlpha(animate and 0 or 255)
	if animate then framePanel:AlphaTo(255, 0.24, 0) end
	framePanel.Close = function(self)
		if self.DRPClosing then return end
		self.DRPClosing = true
		self:SetMouseInputEnabled(false)
		self:SetKeyboardInputEnabled(false)
		self:AlphaTo(0, 0.18, 0, function() if IsValid(self) then self:Remove() end end)
	end
end
UI.InstallFade = installFade

function UI.CreateHandsFrame(snapshot, options)
	snapshot = snapshot or {}
	options = options or {}
	local sourceItems = istable(snapshot.items) and snapshot.items or {}
	local sourceEquipped = istable(snapshot.equipped) and snapshot.equipped or {}
	local sourceSelected = tostring(snapshot.selected or "")
	local sourceWidth = tonumber(snapshot.width) or UI.Width or 6
	local sourceHeight = tonumber(snapshot.height) or UI.Height or 10
	local accent = options.accent or roleColor()
	if options.bindLocalState ~= false then
		UI.Items, UI.Equipped, UI.Selected = sourceItems, sourceEquipped, sourceSelected
		UI.Width, UI.Height = sourceWidth, sourceHeight
	end

	local frameWidth = tonumber(options.width) or math.max(700, math.floor(ScrW() * 0.5) - 20)
	local frameHeight = tonumber(options.height) or math.max(650, ScrH() - 40)
	local target = DRP.UI.Frame(options.title or "HANDS", frameWidth, frameHeight)
	target:SetPos(tonumber(options.x) or (ScrW() - target:GetWide() - 20), tonumber(options.y) or 20)
	installFade(target, options.animate == true)

	target.Paint = function(_, width, height)
		draw.RoundedBox(12, 0, 0, width, height, Color(5, 10, 19, 249))
		draw.RoundedBoxEx(12, 0, 0, width, 60, Color(13, 23, 39, 252), true, true, false, false)
		draw.RoundedBox(12, 0, 0, 5, height, accent)
		draw.RoundedBox(8, 18, 57, width - 36, 2, Color(accent.r, accent.g, accent.b, 180))
		draw.SimpleText(options.title or "HANDS", "DRP.Admin.Title", 22, 28, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(options.kicker or "ROLE-SYNCHRONISED LOADOUT", "DRP.Admin.Small", options.kickerX or 112, 29, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local subtitle = vgui.Create("DLabel", target)
	subtitle:SetPos(24, 68) subtitle:SetSize(target:GetWide() - 48, 32)
	subtitle:SetFont("DRP.Admin.Small") subtitle:SetTextColor(DRP.UI.Colors.muted)
	subtitle:SetText(options.subtitle or "Drag to arrange or assign equipment • Right-click for actions • 60 persistent cells")

	local contentTop, footerHeight = 108, 54
	local contentHeight = target:GetTall() - contentTop - footerHeight
	local gridAreaWidth = math.floor(target:GetWide() * 0.57)
	local playerAreaWidth = target:GetWide() - gridAreaWidth - 58
	local cell = math.floor(math.min((gridAreaWidth - 12) / sourceWidth, (contentHeight - 30) / sourceHeight))
	cell = math.Clamp(cell, 30, 96)
	local gridWidth, gridHeight = sourceWidth * cell, sourceHeight * cell
	local gridX = target:GetWide() - 24 - gridWidth
	local gridY = contentTop + math.floor((contentHeight - gridHeight) * 0.5)

	local section = vgui.Create("DLabel", target)
	section:SetPos(gridX, gridY - 28) section:SetSize(gridWidth, 26) section:SetFont("DRP.Admin.Header") section:SetTextColor(accent)
	section:SetText((options.inventoryTitle or "INVENTORY") .. "  •  " .. sourceWidth .. " × " .. sourceHeight)

	local portrait = vgui.Create("DPanel", target)
	portrait:SetPos(24, contentTop) portrait:SetSize(playerAreaWidth, math.floor(contentHeight * 0.52))
	portrait.Paint = function(_, width, height)
		local colour = accent
		draw.RoundedBox(10, 0, 0, width, height, Color(8, 15, 27, 245))
		draw.RoundedBoxEx(10, 0, 0, 4, height, colour, true, false, true, false)
		surface.SetDrawColor(Color(colour.r, colour.g, colour.b, 70)) surface.DrawOutlinedRect(1, 1, width - 2, height - 2, 1)
	end
	local model = vgui.Create("DModelPanel", portrait)
	model:SetPos(5, 5) model:SetSize(portrait:GetWide() - 10, portrait:GetTall() - 10)
	configurePlayerModel(model, options.appearance)

	local ply = LocalPlayer()
	local identity = vgui.Create("DLabel", portrait)
	identity:SetPos(14, portrait:GetTall() - 48) identity:SetSize(portrait:GetWide() - 28, 38)
	identity:SetFont("DRP.Admin.Body") identity:SetTextColor(color_white) identity:SetContentAlignment(5)
	identity:SetText(options.identity or (IsValid(ply) and ((ply.DRPRPName and ply:DRPRPName() or ply:Nick()) .. "  •  " .. (ply.DRPJobName and ply:DRPJobName() or "Citizen")) or "PLAYER"))

	local targets = {}
	local slotsTop = contentTop + portrait:GetTall() + 12
	local remainingHeight = contentTop + contentHeight - slotsTop
	local mainHeight = math.Clamp(math.floor((remainingHeight - 21) * 0.22), 52, 76)
	local equipmentOptions = { readOnly = options.readOnly == true, onItem = options.onEquipmentItem, accent = accent }
	makeEquipmentSlot(target, "primary", 24, slotsTop, playerAreaWidth, mainHeight, targets, sourceItems, sourceEquipped, equipmentOptions)
	makeEquipmentSlot(target, "secondary", 24, slotsTop + mainHeight + 7, playerAreaWidth, mainHeight, targets, sourceItems, sourceEquipped, equipmentOptions)
	local altY = slotsTop + (mainHeight + 7) * 2
	local altGap = 6
	local altWidth = math.floor((playerAreaWidth - altGap * 2) / 3)
	local altHeight = math.max(38, math.floor((contentTop + contentHeight - altY - altGap) * 0.5))
	for index = 1, 6 do
		local row, column = math.floor((index - 1) / 3), (index - 1) % 3
		local slotOptions = table.Copy(equipmentOptions)
		slotOptions.locked = options.readOnly ~= true and not canUseEquipmentSlot("alt" .. index)
		makeEquipmentSlot(target, "alt" .. index, 24 + column * (altWidth + altGap), altY + row * (altHeight + altGap), altWidth, altHeight, targets, sourceItems, sourceEquipped, slotOptions)
	end

	local grid = UI.BuildGrid(target, sourceItems, {
		width = sourceWidth,
		height = sourceHeight,
		cell = cell,
		accent = accent,
		selected = sourceSelected,
		onMove = options.readOnly and function() end or options.onMove,
		onItemMenu = options.onItemMenu,
		onDropOutside = function(item, cursorX, cursorY)
			for _, target in ipairs(targets) do
				local x, y = target.panel:LocalToScreen(0, 0)
				if cursorX >= x and cursorX <= x + target.panel:GetWide() and cursorY >= y and cursorY <= y + target.panel:GetTall() then
					sendAction("equip", { id = item.id, slot = target.slot })
					return
				end
			end
			if options.onDropOutside then options.onDropOutside(item, cursorX, cursorY) end
		end
	})
	grid:SetPos(gridX, gridY)
	target.DRPInventoryGrid = grid
	target.DRPEquipmentTargets = targets

	local footer = vgui.Create("DLabel", target)
	footer:SetPos(24, target:GetTall() - 45) footer:SetSize(target:GetWide() - 48, 28) footer:SetFont("DRP.Admin.Small") footer:SetTextColor(DRP.UI.Colors.muted)
	footer:SetText(options.footer or "PRIMARY: PICK UP  •  SECONDARY: OPEN HANDS  •  RELOAD: USE SELECTED CONSUMABLE")
	return target
end

local function openInventory(animate)
	hook.Run("DRPInventoryContextOpening", "hands")
	if IsValid(frame) then frame:Remove() end
	frame = UI.CreateHandsFrame({
		items = UI.Items,
		equipped = UI.Equipped,
		selected = UI.Selected,
		width = UI.Width,
		height = UI.Height
	}, { animate = animate == true })
end

UI.Open = function() openInventory(true) end
UI.CloseStandalone = function(immediate)
	if not IsValid(frame) then return end
	if immediate == true then frame:Remove() else frame:Close() end
	frame = nil
end

net.Receive("drp_inventory_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length = net.ReadUInt(20)
	if length <= 0 or length > 1048575 then return end
	local json = util.Decompress(net.ReadData(length))
	local decoded = json and util.JSONToTable(json) or nil
	if not istable(decoded) then return end
	UI.Items = istable(decoded.items) and decoded.items or {}
	UI.Equipped = istable(decoded.equipped) and decoded.equipped or {}
	UI.Selected = tostring(decoded.selected or "")
	UI.Width, UI.Height = tonumber(decoded.width) or 6, tonumber(decoded.height) or 10
	hook.Run("DRPInventoryUpdated", decoded)
	if decoded.open then openInventory(true)
	elseif IsValid(frame) and not frame.DRPClosing then timer.Simple(0, function() if IsValid(frame) and not frame.DRPClosing then openInventory(false) end end) end
end)
