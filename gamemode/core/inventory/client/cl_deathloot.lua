DRP.DeathLootUI = DRP.DeathLootUI or { State = nil }

local UI = DRP.DeathLootUI
local sourceFrame
local handsFrame

local function sendAction(action, itemID)
	local state = UI.State
	local entity = state and Entity(state.entity or -1) or nil
	if not IsValid(entity) then return end
	local payload = util.Compress(util.TableToJSON({
		action = action,
		id = tostring(itemID or ""),
		revision = math.max(0, tonumber(state.revision) or 0)
	}, false) or "{}") or ""
	if #payload <= 0 or #payload > 32768 then return end
	net.Start(DRP.DeathLootMessages.ACTION)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(#payload, 16)
		net.WriteData(payload, #payload)
		net.WriteEntity(entity)
	net.SendToServer()
end

local function removeFrames()
	if IsValid(sourceFrame) then sourceFrame:Remove() end
	if IsValid(handsFrame) then handsFrame:Remove() end
	sourceFrame, handsFrame = nil, nil
end

local function openLoot(animate)
	local state = UI.State
	if not state or not DRP.InventoryUI or not DRP.InventoryUI.CreateHandsFrame then return end
	hook.Run("DRPInventoryContextOpening", "death_loot")
	removeFrames()
	if DRP.InventoryUI.CloseStandalone then DRP.InventoryUI.CloseStandalone(true) end

	local margin, gap = 20, 18
	local available = ScrW() - margin * 2
	local leftWidth = math.floor((available - gap) * 0.5)
	local rightWidth = available - gap - leftWidth
	local height = math.max(650, ScrH() - margin * 2)
	local source = state.source or { items = {}, equipped = {}, width = 6, height = 10 }
	local hands = state.hands or { items = {}, equipped = {}, width = 6, height = 10 }
	local sourceAccent = istable(source.accent)
		and Color(tonumber(source.accent.r) or 74, tonumber(source.accent.g) or 205, tonumber(source.accent.b) or 255)
		or DRP.UI.Colors.accent

	handsFrame = DRP.InventoryUI.CreateHandsFrame(hands, {
		x = margin + leftWidth + gap,
		y = margin,
		width = rightWidth,
		height = height,
		animate = animate == true,
		footer = "TAKE LOOT FROM THE SUITCASE  •  ARRANGE OR EQUIP IT IN HANDS"
	})

	local function take(item)
		if item and item.id then sendAction("take", item.id) end
	end

	sourceFrame = DRP.InventoryUI.CreateHandsFrame(source, {
		x = margin,
		y = margin,
		width = leftWidth,
		height = height,
		animate = animate == true,
		bindLocalState = false,
		readOnly = true,
		title = string.upper(string.sub(tostring(state.ownerName or "DECEASED"), 1, 24)) .. "'S SUITCASE",
		kicker = "DEATH INVENTORY",
		kickerX = 250,
		subtitle = "Any player may retrieve these items • Click or drag an item into your Hands",
		inventoryTitle = "SUITCASE CONTENTS",
		identity = source.identity,
		appearance = source.appearance,
		accent = sourceAccent,
		footer = "ITEMS REMAIN SECURED UNTIL ANOTHER PLAYER RETRIEVES THEM",
		onEquipmentItem = take,
		onItemMenu = function(item)
			local menu = DermaMenu()
			menu:AddOption("Take into Hands", function() take(item) end):SetIcon("icon16/arrow_right.png")
			menu:AddOption("Inspect", function()
				Derma_Message(tostring(item.label or "Item") .. "\n" .. string.upper(tostring(item.kind or "item")) .. "\nFootprint " .. tostring(item.w or 1) .. " × " .. tostring(item.h or 1), "SUITCASE ITEM", "CLOSE")
			end):SetIcon("icon16/magnifier.png")
			menu:Open()
		end,
		onDropOutside = function(item, cursorX, cursorY)
			if not IsValid(handsFrame) or not IsValid(handsFrame.DRPInventoryGrid) then return end
			local x, y = handsFrame.DRPInventoryGrid:LocalToScreen(0, 0)
			if cursorX >= x and cursorY >= y
				and cursorX <= x + handsFrame.DRPInventoryGrid:GetWide()
				and cursorY <= y + handsFrame.DRPInventoryGrid:GetTall() then take(item) end
		end
	})

	local lootAll = DRP.UI.Button(sourceFrame, "LOOT EVERYTHING THAT FITS", DRP.UI.Colors.green, function()
		sendAction("take_all", "")
	end)
	lootAll:SetPos(sourceFrame:GetWide() - 246, sourceFrame:GetTall() - 46)
	lootAll:SetSize(220, 34)

	local closingPair = false
	local closeSource, closeHands = sourceFrame.Close, handsFrame.Close
	local function closeBoth()
		if closingPair then return end
		closingPair = true
		sendAction("close")
		if IsValid(sourceFrame) then closeSource(sourceFrame) end
		if IsValid(handsFrame) then closeHands(handsFrame) end
	end
	sourceFrame.Close = closeBoth
	handsFrame.Close = closeBoth

	sourceFrame.Think = function(self)
		local entity = Entity(state.entity or -1)
		local ply = LocalPlayer()
		if not IsValid(entity) or not IsValid(ply) or not ply:Alive() or ply:GetPos():DistToSqr(entity:GetPos()) > 180 * 180 then closeBoth() return end
		self.DRPNextLootSight = self.DRPNextLootSight or 0
		if self.DRPNextLootSight <= CurTime() then
			self.DRPNextLootSight = CurTime() + 0.2
			local trace = util.TraceLine({ start = ply:EyePos(), endpos = entity:WorldSpaceCenter(), filter = ply, mask = MASK_SOLID })
			if trace.Hit and trace.Entity ~= entity then closeBoth() end
		end
	end
end

net.Receive(DRP.DeathLootMessages.OPEN, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length = net.ReadUInt(20)
	if length <= 0 or length > 1048575 then return end
	local decoded = util.Decompress(net.ReadData(length))
	decoded = decoded and util.JSONToTable(decoded) or nil
	if not istable(decoded) then return end
	local firstOpen = not IsValid(sourceFrame) and not IsValid(handsFrame)
	UI.State = decoded
	openLoot(firstOpen)
end)

hook.Add("DRPInventoryUpdated", "DRP.DeathLoot.RefreshHands", function(snapshot)
	if not UI.State or (not IsValid(sourceFrame) and not IsValid(handsFrame)) then return end
	UI.State.hands = {
		items = snapshot.items or {}, equipped = snapshot.equipped or {}, selected = snapshot.selected or "",
		width = snapshot.width or 6, height = snapshot.height or 10
	}
	timer.Simple(0, function()
		if UI.State and (IsValid(sourceFrame) or IsValid(handsFrame)) then openLoot(false) end
	end)
end)

hook.Add("DRPInventoryContextOpening", "DRP.DeathLoot.CloseForOtherInventory", function(kind)
	if kind == "death_loot" then return end
	if IsValid(sourceFrame) or IsValid(handsFrame) then sendAction("close") end
	removeFrames()
	UI.State = nil
end)

hook.Add("ShutDown", "DRP.DeathLoot.CloseUI", removeFrames)
