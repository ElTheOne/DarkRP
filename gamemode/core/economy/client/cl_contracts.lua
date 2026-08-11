DRP.ContractsUI = DRP.ContractsUI or { State = { listings = {}, myListings = {} } }

local UI = DRP.ContractsUI
local colors = DRP.UI.Colors
local marketplaceFrame
local tradeFrame
local pendingEditor
local pendingTrade

surface.CreateFont("DRP.Contracts.Hero", { font = "Roboto", size = 32, weight = 800 })
surface.CreateFont("DRP.Contracts.Price", { font = "Roboto", size = 23, weight = 800 })

local function sendAction(action, data)
	local json = util.TableToJSON(data or {}, false) or "{}"
	local payload = util.Compress(json) or ""
	net.Start("drp_contracts_action_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteString(action)
		net.WriteUInt(#payload, 16)
		net.WriteData(payload, #payload)
	net.SendToServer()
end

function UI.Request(open)
	-- Never leave the player looking at a closed Q menu while an asynchronous
	-- snapshot is in flight. Render the last known state immediately, then let
	-- the authoritative server response refresh the frame.
	if open == true and isfunction(UI.OpenMarketplace) then
		UI.OpenMarketplace()
	end
	sendAction("request", { open = open == true })
end

local function listingByID(id)
	for _, listing in ipairs(UI.State.myListings or {}) do if listing.id == id then return listing end end
	for _, listing in ipairs(UI.State.listings or {}) do if listing.id == id then return listing end end
end

local function statusColor(status)
	if status == "active" then return colors.green end
	if status == "in_progress" then return colors.accent end
	if status == "draft" then return colors.purple end
	return colors.muted
end

local function styleEntry(entry)
	entry:SetFont("DRP.Admin.Body")
	entry:SetTextColor(color_white)
	entry:SetPaintBackground(false)
	entry.Paint = function(self, width, height)
		draw.RoundedBox(6, 0, 0, width, height, Color(8, 13, 25, 245))
		surface.SetDrawColor(self:HasFocus() and colors.accent or colors.line)
		surface.DrawOutlinedRect(0, 0, width, height, 1)
		self:DrawTextEntryText(color_white, colors.accent, color_white)
	end
end

function UI.OpenEditor(id)
	local listing = listingByID(id)
	if not listing then pendingEditor = id UI.Request(false) return end
	local frame = DRP.UI.Frame("CREATE MARKETPLACE LISTING", 720, 600)

	local eyebrow = vgui.Create("DLabel", frame)
	eyebrow:SetPos(28, 78)
	eyebrow:SetSize(664, 22)
	eyebrow:SetFont("DRP.Admin.Small")
	eyebrow:SetTextColor(colors.accent)
	eyebrow:SetText("SELLER ESCROW  •  LISTING #" .. listing.id)

	local title = vgui.Create("DTextEntry", frame)
	title:SetPos(28, 112)
	title:SetSize(664, 42)
	title:SetValue(listing.title or "")
	title:SetPlaceholderText("Listing title")
	styleEntry(title)

	local description = vgui.Create("DTextEntry", frame)
	description:SetPos(28, 166)
	description:SetSize(664, 92)
	description:SetMultiline(true)
	description:SetValue(listing.description or "")
	description:SetPlaceholderText("Describe the goods, condition and delivery expectations")
	styleEntry(description)

	local price = vgui.Create("DTextEntry", frame)
	price:SetPos(28, 270)
	price:SetSize(220, 42)
	price:SetNumeric(true)
	price:SetValue(tostring(listing.unitPrice or 100))
	price:SetPlaceholderText("Price per item")
	styleEntry(price)

	local count = vgui.Create("DLabel", frame)
	count:SetPos(268, 270)
	count:SetSize(424, 42)
	count:SetFont("DRP.Admin.Body")
	count:SetTextColor(colors.muted)
	count:SetContentAlignment(4)
	count:SetText(#(listing.items or {}) .. " escrowed item(s)  •  Add more with /listing" .. listing.id .. "add")

	local scroll = vgui.Create("DScrollPanel", frame)
	scroll:SetPos(28, 326)
	scroll:SetSize(664, 184)
	for _, item in ipairs(listing.items or {}) do
		local row = vgui.Create("DPanel", scroll)
		row:Dock(TOP)
		row:DockMargin(0, 0, 0, 7)
		row:SetTall(42)
		row.Paint = function(_, width, height)
			draw.RoundedBox(6, 0, 0, width, height, colors.panel)
			draw.RoundedBox(3, 0, 0, 4, height, item.valid and colors.green or colors.red)
			draw.SimpleText(item.label, "DRP.Admin.Body", 16, height * 0.5, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(string.upper(item.source), "DRP.Admin.Small", width - 14, height * 0.5, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
	end

	local publish = DRP.UI.Button(frame, listing.status == "active" and "SAVE CHANGES" or "PUBLISH LISTING", colors.green, function()
		sendAction("save_listing", {
			id = listing.id,
			title = title:GetValue(),
			description = description:GetValue(),
			unitPrice = tonumber(price:GetValue()) or 0
		})
		frame:Close()
	end)
	publish:SetPos(392, 530)
	publish:SetSize(300, 44)

	local cancel = DRP.UI.Button(frame, "CANCEL LISTING", colors.red, function()
		DRP.UI.Confirm("CANCEL LISTING", "Return all escrowed Hands items and unlock all listed entities?", "CANCEL LISTING", function()
			sendAction("cancel_listing", { id = listing.id })
			frame:Close()
		end, colors.red)
	end)
	cancel:SetPos(28, 530)
	cancel:SetSize(250, 44)
end

local function marketplaceCard(parent, listing, mine)
	local card = vgui.Create("DButton", parent)
	card:Dock(TOP)
	card:DockMargin(0, 0, 0, 10)
	card:SetTall(112)
	card:SetText("")
	card.Paint = function(self, width, height)
		draw.RoundedBox(8, 0, 0, width, height, self:IsHovered() and colors.panelHover or colors.panel)
		draw.RoundedBoxEx(8, 0, 0, 5, height, statusColor(listing.status), true, false, true, false)
		draw.SimpleText(listing.title, "DRP.Admin.Header", 20, 25, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(listing.sellerName .. "  •  " .. #listing.items .. " item(s)", "DRP.Admin.Small", 20, 50, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(string.upper(listing.status), "DRP.Admin.Small", width - 18, 22, statusColor(listing.status), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		draw.SimpleText("$" .. string.Comma(listing.unitPrice) .. " EACH", "DRP.Contracts.Price", width - 18, 52, colors.green, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		draw.SimpleText(string.sub(listing.description or "No description", 1, 100), "DRP.Admin.Small", 20, 83, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	card.DoClick = function()
		if mine and (listing.status == "draft" or listing.status == "active") then UI.OpenEditor(listing.id)
		elseif listing.status == "active" then
			DRP.UI.Confirm("OPEN NEGOTIATION", "Begin an escrow negotiation with " .. listing.sellerName .. " for " .. listing.title .. "?", "NEGOTIATE", function()
				sendAction("begin", { id = listing.id })
			end, colors.accent)
		end
	end
	return card
end

function UI.OpenMarketplace()
	if IsValid(marketplaceFrame) then marketplaceFrame:Remove() end
	local frame = DRP.UI.Frame("CONTRACT MARKETPLACE", 1080, 760)
	marketplaceFrame = frame

	local hero = vgui.Create("DPanel", frame)
	hero:SetPos(22, 74)
	hero:SetSize(frame:GetWide() - 44, 92)
	hero.Paint = function(_, width, height)
		draw.RoundedBox(9, 0, 0, width, height, Color(18, 35, 59, 252))
		draw.RoundedBoxEx(9, 0, 0, 6, height, colors.accent, true, false, true, false)
		draw.SimpleText("PLAYER-DRIVEN COMMERCE", "DRP.Contracts.Hero", 24, 31, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("Server-secured escrow • negotiated value • physical delivery", "DRP.Admin.Body", 25, 65, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local refresh = DRP.UI.Button(hero, "REFRESH", colors.panelHover, function() UI.Request(false) end)
	refresh:SetSize(120, 38)
	refresh:SetPos(hero:GetWide() - 138, 27)

	local public = DRP.UI.Card(frame)
	public:SetPos(22, 180)
	public:SetSize(math.floor((frame:GetWide() - 56) * 0.61), frame:GetTall() - 202)
	local publicTitle = vgui.Create("DLabel", public)
	publicTitle:Dock(TOP)
	publicTitle:DockMargin(18, 10, 18, 6)
	publicTitle:SetTall(35)
	publicTitle:SetFont("DRP.Admin.Header")
	publicTitle:SetTextColor(color_white)
	publicTitle:SetText("LIVE LISTINGS")
	local publicScroll = vgui.Create("DScrollPanel", public)
	publicScroll:Dock(FILL)
	publicScroll:DockMargin(14, 0, 8, 12)
	local publicCount = 0
	for _, listing in ipairs(UI.State.listings or {}) do
		if listing.status == "active" and listing.sellerID ~= LocalPlayer():SteamID64() then
			marketplaceCard(publicScroll, listing, false)
			publicCount = publicCount + 1
		end
	end
	if publicCount == 0 then
		local empty = vgui.Create("DLabel", publicScroll)
		empty:Dock(TOP)
		empty:SetTall(90)
		empty:SetFont("DRP.Admin.Body")
		empty:SetTextColor(colors.muted)
		empty:SetContentAlignment(5)
		empty:SetText("No public listings are available.\nUse /contracttestbuyer to test a purchase alone.")
	end

	local mine = DRP.UI.Card(frame)
	mine:SetPos(public:GetX() + public:GetWide() + 12, 180)
	mine:SetSize(frame:GetWide() - public:GetWide() - 56, frame:GetTall() - 202)
	local mineTitle = vgui.Create("DLabel", mine)
	mineTitle:Dock(TOP)
	mineTitle:DockMargin(18, 10, 18, 6)
	mineTitle:SetTall(35)
	mineTitle:SetFont("DRP.Admin.Header")
	mineTitle:SetTextColor(color_white)
	mineTitle:SetText("MY SALES / IN PROGRESS")
	local mineScroll = vgui.Create("DScrollPanel", mine)
	mineScroll:Dock(FILL)
	mineScroll:DockMargin(14, 0, 8, 12)
	if UI.State.delivery then
		local delivery = UI.State.delivery
		local progress = vgui.Create("DPanel", mineScroll)
		progress:Dock(TOP)
		progress:DockMargin(0, 0, 0, 10)
		progress:SetTall(108)
		progress.Paint = function(_, width, height)
			draw.RoundedBox(8, 0, 0, width, height, Color(20, 48, 68, 252))
			draw.RoundedBoxEx(8, 0, 0, 5, height, colors.accent, true, false, true, false)
			draw.SimpleText("TRADE #" .. delivery.id .. " IN PROGRESS", "DRP.Admin.Header", 18, 24, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(delivery.sellerName .. "  ↔  " .. delivery.buyerName, "DRP.Admin.Small", 18, 52, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText("$" .. string.Comma(delivery.offer) .. " IN ESCROW", "DRP.Admin.Body", 18, 82, colors.green, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end
	for _, listing in ipairs(UI.State.myListings or {}) do marketplaceCard(mineScroll, listing, true) end
end

local function hasSelected(negotiation, itemID)
	for _, item in ipairs(negotiation.items or {}) do if item.id == itemID then return true end end
	return false
end

function UI.OpenTrade()
	local negotiation = UI.State.negotiation
	if not negotiation then return end
	if IsValid(tradeFrame) then tradeFrame:Remove() end
	local frame = DRP.UI.Frame("ESCROW NEGOTIATION #" .. negotiation.id, 1080, 720)
	tradeFrame = frame

	local function offerPanel(x, title, name, accent)
		local panel = DRP.UI.Card(frame)
		panel:SetPos(x, 82)
		panel:SetSize(500, 360)
		panel.Paint = function(_, width, height)
			draw.RoundedBox(9, 0, 0, width, height, colors.panel)
			draw.RoundedBoxEx(9, 0, 0, width, 5, accent, true, true, false, false)
		end
		local label = vgui.Create("DLabel", panel)
		label:SetPos(18, 14)
		label:SetSize(464, 52)
		label:SetFont("DRP.Admin.Header")
		label:SetTextColor(color_white)
		label:SetText(title .. "\n" .. name)
		return panel
	end

	local sellerPanel = offerPanel(22, "SELLER OFFER", negotiation.sellerName, colors.purple)
	local buyerPanel = offerPanel(558, "BUYER ESCROW", negotiation.buyerName, colors.green)

	local itemScroll = vgui.Create("DScrollPanel", sellerPanel)
	itemScroll:SetPos(16, 76)
	itemScroll:SetSize(468, 265)
	local source = negotiation.isSeller and negotiation.pool or negotiation.items
	for _, item in ipairs(source or {}) do
		local selected = hasSelected(negotiation, item.id)
		local row = vgui.Create("DButton", itemScroll)
		row:Dock(TOP)
		row:DockMargin(0, 0, 0, 7)
		row:SetTall(44)
		row:SetText("")
		row.Paint = function(self, width, height)
			draw.RoundedBox(6, 0, 0, width, height, selected and Color(34, 77, 103, 245) or Color(8, 13, 25, 235))
			draw.SimpleText((selected and "✓  " or "＋  ") .. item.label, "DRP.Admin.Body", 14, height * 0.5, selected and colors.accent or colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(string.upper(item.source), "DRP.Admin.Small", width - 14, height * 0.5, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
		row:SetEnabled(negotiation.isSeller)
		row.DoClick = function() sendAction("toggle_item", { itemID = item.id }) end
	end

	local requested = vgui.Create("DLabel", buyerPanel)
	requested:SetPos(18, 82)
	requested:SetSize(464, 46)
	requested:SetFont("DRP.Contracts.Price")
	requested:SetTextColor(colors.muted)
	requested:SetText("ASKING  $" .. string.Comma(negotiation.requested))

	local money = vgui.Create("DTextEntry", buyerPanel)
	money:SetPos(18, 140)
	money:SetSize(464, 48)
	money:SetNumeric(true)
	money:SetValue(tostring(negotiation.offer))
	money:SetEnabled(negotiation.isBuyer)
	styleEntry(money)

	local difference = negotiation.offer - negotiation.requested
	local warning = vgui.Create("DLabel", buyerPanel)
	warning:SetPos(18, 198)
	warning:SetSize(464, 52)
	warning:SetFont("DRP.Admin.Body")
	warning:SetTextColor(difference == 0 and colors.green or colors.red)
	warning:SetWrap(true)
	warning:SetText(difference == 0 and "The buyer is offering the requested sum."
		or ("Negotiated offer differs by " .. (difference > 0 and "+" or "-") .. "$" .. string.Comma(math.abs(difference)) .. "."))

	if negotiation.isBuyer then
		local submit = DRP.UI.Button(buyerPanel, "UPDATE MONEY OFFER", colors.green, function()
			sendAction("offer", { amount = tonumber(money:GetValue()) or 0 })
		end)
		submit:SetPos(18, 278)
		submit:SetSize(464, 48)
	end

	local terms = DRP.UI.Card(frame)
	terms:SetPos(22, 458)
	terms:SetSize(1036, 118)
	local termsTitle = vgui.Create("DLabel", terms)
	termsTitle:SetPos(18, 12)
	termsTitle:SetSize(220, 28)
	termsTitle:SetFont("DRP.Admin.Header")
	termsTitle:SetTextColor(color_white)
	termsTitle:SetText("DELIVERY POINT")
	local choices = {
		{ key = "buyer", label = "BUYER" },
		{ key = "seller", label = "SELLER" },
		{ key = "trade_center", label = "TRADE CENTER" },
		{ key = "random", label = "RANDOM" }
	}
	for index, choice in ipairs(choices) do
		local selected = negotiation.delivery == choice.key
		local button = DRP.UI.Button(terms, choice.label, selected and colors.accent or colors.panelHover, function()
			sendAction("delivery", { choice = choice.key })
		end)
		button:SetPos(18 + (index - 1) * 250, 54)
		button:SetSize(232, 44)
	end

	local cancel = DRP.UI.Button(frame, "CANCEL TRADE", colors.red, function() sendAction("cancel", {}) frame:Close() end)
	cancel:SetPos(22, 596)
	cancel:SetSize(250, 48)

	local confirmed = (negotiation.isSeller and negotiation.sellerConfirmed) or (negotiation.isBuyer and negotiation.buyerConfirmed)
	local confirm = DRP.UI.Button(frame, confirmed and "WAITING FOR OTHER PARTY" or "REVIEW & CONFIRM TERMS", confirmed and colors.panelHover or colors.green, function()
		if confirmed then return end
		DRP.UI.Confirm("FINAL TRADE CONFIRMATION",
			"You are committing to $" .. string.Comma(negotiation.offer) .. " for " .. #negotiation.items .. " item(s). Money enters server escrow immediately once both parties confirm. Delivery must finish within 10 minutes.",
			"CONFIRM TRADE", function() sendAction("confirm", {}) end, colors.green)
	end)
	confirm:SetPos(728, 596)
	confirm:SetSize(330, 48)
end

function UI.AddPocketMenu(menu, itemID, legacyIndex)
	if not IsValid(menu) then return end
	menu:AddSpacer()
	local listings = UI.State.myListings or {}
	local add = menu:AddSubMenu("Add to Listing #")
	local added = false
	for _, listing in ipairs(listings) do
		if listing.status == "draft" or listing.status == "active" then
			added = true
			local id = listing.id
			add:AddOption("#" .. id .. " — " .. listing.title, function()
				sendAction("pocket_add", { itemID = itemID, index = legacyIndex, listingID = id })
			end)
		end
	end
	if not added then add:AddOption("No editable listings", function() end) end
	menu:AddOption("Create new listing", function()
		sendAction("pocket_add", { itemID = itemID, index = legacyIndex, createNew = true })
	end):SetIcon("icon16/add.png")
	if UI.State.negotiation and UI.State.negotiation.isSeller then
		menu:AddOption("Add to current negotiation", function()
			sendAction("pocket_add", { itemID = itemID, index = legacyIndex, negotiationID = UI.State.negotiation.id })
		end):SetIcon("icon16/arrow_switch.png")
	end
end

net.Receive("drp_contracts_sync_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local shouldOpen = net.ReadBool()
	local length = net.ReadUInt(20)
	if length > 524288 then return end
	local payload = net.ReadData(length)
	local json = util.Decompress(payload or "")
	local decoded = json and util.JSONToTable(json)
	if not istable(decoded) then return end
	if decoded.delivery and istable(decoded.delivery.position) then
		local position = decoded.delivery.position
		decoded.delivery.positionVector = Vector(position.x or 0, position.y or 0, position.z or 0)
	end
	UI.State = decoded
	if shouldOpen then UI.OpenMarketplace() end
	if pendingEditor then local id = pendingEditor pendingEditor = nil timer.Simple(0, function() UI.OpenEditor(id) end) end
	if pendingTrade then pendingTrade = nil timer.Simple(0, function() UI.OpenTrade() end) end
	if IsValid(marketplaceFrame) then timer.Simple(0, function() if IsValid(marketplaceFrame) then UI.OpenMarketplace() end end) end
	if IsValid(tradeFrame) and decoded.negotiation then timer.Simple(0, function() UI.OpenTrade() end) end
end)

net.Receive("drp_contracts_editor_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local id = net.ReadUInt(24)
	timer.Simple(0, function() UI.OpenEditor(id) end)
end)

net.Receive("drp_contracts_trade_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	pendingTrade = net.ReadUInt(24)
	timer.Simple(0, function()
		if UI.State.negotiation and UI.State.negotiation.id == pendingTrade then pendingTrade = nil UI.OpenTrade() end
	end)
end)

hook.Add("HUDPaint", "DRP.Contracts.DeliveryMarker", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	local delivery = UI.State.delivery
	if not delivery or not isvector(delivery.positionVector) then return end
	local position = delivery.positionVector
	local screen = position:ToScreen()
	local distance = math.floor(LocalPlayer():GetPos():Distance(position))
	local remaining = math.max(0, math.ceil((delivery.expires or 0) - CurTime()))
	draw.RoundedBox(8, screen.x - 104, screen.y - 32, 208, 64, Color(8, 13, 25, 235))
	draw.RoundedBox(3, screen.x - 104, screen.y - 32, 5, 64, colors.accent)
	draw.SimpleText("TRADE DELIVERY", "DRP.Admin.Header", screen.x, screen.y - 13, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	draw.SimpleText(distance .. "u  •  " .. string.FormattedTime(remaining, "%02i:%02i"), "DRP.Admin.Small", screen.x, screen.y + 14, colors.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

concommand.Add("drp_marketplace", function() UI.Request(true) end)
