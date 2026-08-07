local Contracts = {
	Listings = {},
	Negotiations = {},
	Deliveries = {},
	NextListingID = 1,
	NextNegotiationID = 1,
	NextItemID = 1,
	DeliverySeconds = 600,
	DeliveryRadius = 160,
	MaxListingsPerPlayer = 12,
	MaxItemsPerListing = 16,
	TradeCenter = nil,
	PendingRefunds = {},
	RefundPath = "darkrp/contracts_refunds.json",
	ConfigPath = "darkrp/contracts_config.json",
	DeliveryTimerName = "DRP.Contracts.Deliveries"
}

DRP.Contracts = Contracts
DRP.Services.Register("contracts", Contracts)
DRP.Services.DependsOn("contracts", { "network", "inventory", "economy" })

local syncMessage = "drp_contracts_sync_v1"
local actionMessage = "drp_contracts_action_v1"
local openEditorMessage = "drp_contracts_editor_v1"
local openTradeMessage = "drp_contracts_trade_v1"
util.AddNetworkString(syncMessage)
util.AddNetworkString(actionMessage)
util.AddNetworkString(openEditorMessage)
util.AddNetworkString(openTradeMessage)

local function cleanText(value, maximum)
	return string.sub(string.Trim(string.gsub(tostring(value or ""), "%c", "")), 1, maximum)
end

local function online(steamID64)
	return DRP.Players and DRP.Players.Online(tostring(steamID64 or "")) or nil
end

local function notify(ply, text, kind)
	if IsValid(ply) then DRP.Net.Notify(ply, text, kind or 0) end
end

local function nextID(field)
	local value = Contracts[field]
	Contracts[field] = value + 1
	return value
end

local function itemValid(item)
	if item.source == "entity" then return IsValid(item.entity) end
	return istable(item.record)
end

local function listingCount(sellerID)
	local count = 0
	for _, listing in pairs(Contracts.Listings) do
		if listing.sellerID == sellerID and listing.status ~= "completed" and listing.status ~= "cancelled" then count = count + 1 end
	end
	return count
end

function Contracts.SaveRefunds()
	file.CreateDir("darkrp")
	file.Write(Contracts.RefundPath, util.TableToJSON(Contracts.PendingRefunds, false) or "{}")
end

local function itemSummary(item)
	return {
		id = item.id,
		label = cleanText(item.label, 64),
		source = item.source,
		listingID = item.listingID or 0,
		valid = itemValid(item)
	}
end

local function listingSummary(listing)
	local result = {
		id = listing.id,
		sellerID = listing.sellerID,
		sellerName = listing.sellerName,
		title = listing.title,
		description = listing.description,
		unitPrice = listing.unitPrice,
		status = listing.status,
		created = listing.created,
		items = {}
	}
	for _, item in ipairs(listing.items) do
		if itemValid(item) then result.items[#result.items + 1] = itemSummary(item) end
	end
	result.total = result.unitPrice * #result.items
	return result
end

local function negotiationFor(ply)
	if not IsValid(ply) then return nil end
	local id = ply:SteamID64()
	for _, negotiation in pairs(Contracts.Negotiations) do
		if negotiation.status == "negotiating" and (negotiation.sellerID == id or negotiation.buyerID == id) then return negotiation end
	end
end

local function deliveryFor(ply)
	if not IsValid(ply) then return nil end
	local id = ply:SteamID64()
	for _, delivery in pairs(Contracts.Deliveries) do
		if delivery.status == "in_progress" and (delivery.sellerID == id or delivery.buyerID == id) then return delivery end
	end
end

function Contracts.BuildSnapshot(ply)
	local id = IsValid(ply) and ply:SteamID64() or ""
	local snapshot = { listings = {}, myListings = {}, negotiation = nil, delivery = nil, serverTime = CurTime() }
	local activeDelivery = deliveryFor(ply)
	for _, listing in pairs(Contracts.Listings) do
		if listing.status == "active" or listing.sellerID == id or (activeDelivery and activeDelivery.listingID == listing.id) then
			local summary = listingSummary(listing)
			snapshot.listings[#snapshot.listings + 1] = summary
			if listing.sellerID == id then snapshot.myListings[#snapshot.myListings + 1] = summary end
		end
	end
	table.sort(snapshot.listings, function(a, b) return a.id > b.id end)
	table.sort(snapshot.myListings, function(a, b) return a.id > b.id end)

	local negotiation = negotiationFor(ply)
	if negotiation then
		local selected, pool = {}, {}
		for _, item in ipairs(negotiation.items) do selected[#selected + 1] = itemSummary(item) end
		local seller = online(negotiation.sellerID)
		if IsValid(seller) then
			for _, listing in pairs(Contracts.Listings) do
				if listing.sellerID == negotiation.sellerID and (listing.status == "active" or listing.id == negotiation.listingID) then
					for _, item in ipairs(listing.items) do
						if itemValid(item) then pool[#pool + 1] = itemSummary(item) end
					end
				end
			end
		end
		snapshot.negotiation = {
			id = negotiation.id,
			listingID = negotiation.listingID,
			sellerID = negotiation.sellerID,
			sellerName = negotiation.sellerName,
			buyerID = negotiation.buyerID,
			buyerName = negotiation.buyerName,
			requested = negotiation.requested,
			offer = negotiation.offer,
			delivery = negotiation.delivery,
			sellerConfirmed = negotiation.sellerConfirmed,
			buyerConfirmed = negotiation.buyerConfirmed,
			items = selected,
			pool = pool,
			isSeller = id == negotiation.sellerID,
			isBuyer = id == negotiation.buyerID
		}
	end

	local delivery = activeDelivery
	if delivery then
		snapshot.delivery = {
			id = delivery.id,
			listingID = delivery.listingID,
			sellerName = delivery.sellerName,
			buyerName = delivery.buyerName,
			offer = delivery.offer,
			expires = delivery.expires,
			position = { x = delivery.position.x, y = delivery.position.y, z = delivery.position.z },
			requiresSeller = delivery.requiresSeller,
			requiresBuyer = delivery.requiresBuyer
		}
	end
	return snapshot
end

function Contracts.EnsureDeliveryChecks()
	if timer.Exists(Contracts.DeliveryTimerName) then return end
	timer.Create(Contracts.DeliveryTimerName, 0.25, 0, function() Contracts.CheckDeliveries() end)
end

function Contracts.StopDeliveryChecksIfIdle()
	for _, delivery in pairs(Contracts.Deliveries) do
		if delivery.status == "in_progress" then return end
	end
	timer.Remove(Contracts.DeliveryTimerName)
end

function Contracts.Sync(ply, open)
	if not IsValid(ply) then return end
	local json = util.TableToJSON(Contracts.BuildSnapshot(ply), false) or "{}"
	local payload = util.Compress(json) or ""
	net.Start(syncMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteBool(open == true)
		net.WriteUInt(#payload, 20)
		net.WriteData(payload, #payload)
	net.Send(ply)
	DRP.Net.Record(#payload + 4)
end

function Contracts.SyncAll()
	for _, ply in ipairs(DRP.Players.List) do if IsValid(ply) and ply:DRPReady() then Contracts.Sync(ply, false) end end
end

local function openEditor(ply, listing)
	Contracts.Sync(ply, false)
	net.Start(openEditorMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(listing.id, 24)
	net.Send(ply)
end

local function openTrade(negotiation)
	for _, id in ipairs({ negotiation.sellerID, negotiation.buyerID }) do
		local ply = online(id)
		if IsValid(ply) then
			Contracts.Sync(ply, false)
			net.Start(openTradeMessage)
				net.WriteUInt(DRP.ProtocolVersion, 8)
				net.WriteUInt(negotiation.id, 24)
			net.Send(ply)
		end
	end
end

local function newListing(ply)
	if listingCount(ply:SteamID64()) >= Contracts.MaxListingsPerPlayer then
		notify(ply, "You have reached the marketplace listing limit.", 3)
		return nil
	end
	local id = nextID("NextListingID")
	local listing = {
		id = id,
		sellerID = ply:SteamID64(),
		sellerName = ply:DRPName(),
		title = "New listing #" .. id,
		description = "",
		unitPrice = 100,
		status = "draft",
		created = os.time(),
		items = {}
	}
	Contracts.Listings[id] = listing
	return listing
end

local function entityItem(ply, entity, listing)
	if not IsValid(entity) or entity:IsPlayer() or entity:IsWorld() then return nil, "Aim at an entity you own." end
	if entity.DRPContractLocked then return nil, "That entity is already reserved by a listing." end
	if DRP.Doors and DRP.Doors.IsDoor(entity) then return nil, "Doors cannot be sold on the marketplace." end
	if not DRP.Props or not DRP.Props.IsOwnedBy(ply, entity) then return nil, "You can only list entities you own." end
	if #listing.items >= Contracts.MaxItemsPerListing then return nil, "That listing is full." end
	local id = nextID("NextItemID")
	local label = entity:GetNW2String("DRPJobEntityName", "")
	if label == "" then label = entity.PrintName or entity:GetClass() end
	local item = { id = id, source = "entity", entity = entity, label = cleanText(label, 64), listingID = listing.id }
	entity.DRPContractLocked = id
	listing.items[#listing.items + 1] = item
	return item
end

function Contracts.AddAimedEntity(ply, listingID)
	if not IsValid(ply) or not ply:Alive() then return false end
	local listing = listingID and Contracts.Listings[tonumber(listingID)] or newListing(ply)
	if not listing or listing.sellerID ~= ply:SteamID64() or (listing.status ~= "draft" and listing.status ~= "active") then
		notify(ply, "That listing cannot be edited.", 3)
		return false
	end
	local trace = ply:GetEyeTrace()
	if not trace or not IsValid(trace.Entity) or trace.HitPos:DistToSqr(ply:EyePos()) > (256 * 256) then
		notify(ply, "Aim at a nearby entity you own.", 3)
		return false
	end
	local item, reason = entityItem(ply, trace.Entity, listing)
	if not item then
		if #listing.items == 0 and listing.status == "draft" then Contracts.Listings[listing.id] = nil end
		notify(ply, reason, 3)
		return false
	end
	notify(ply, item.label .. " added to listing #" .. listing.id .. ".", 1)
	openEditor(ply, listing)
	Contracts.SyncAll()
	return true
end

function Contracts.AddPocketItem(ply, reference, listingID, createNew, negotiationID)
	if not IsValid(ply) then return false end
	local record = isstring(reference) and DRP.Inventory.TakeRawByID(ply, reference) or DRP.Inventory.TakeRaw(ply, reference)
	if not record then notify(ply, "That Hands item no longer exists.", 3) return false end
	local item = {
		id = nextID("NextItemID"),
		source = "hands",
		record = record,
		label = cleanText(record.label or record.class or "Hands Item", 64)
	}
	if negotiationID then
		local negotiation = Contracts.Negotiations[tonumber(negotiationID)]
		if not negotiation or negotiation.status ~= "negotiating" or negotiation.sellerID ~= ply:SteamID64() then
			DRP.Inventory.InsertRaw(ply, record)
			return false
		end
		item.listingID = 0
		item.negotiationExtra = true
		negotiation.items[#negotiation.items + 1] = item
		negotiation.sellerConfirmed, negotiation.buyerConfirmed = false, negotiation.virtualBuyer == true
		openTrade(negotiation)
		return true
	end
	local listing = createNew and newListing(ply) or Contracts.Listings[tonumber(listingID)]
	if not listing or listing.sellerID ~= ply:SteamID64() or (listing.status ~= "draft" and listing.status ~= "active") or #listing.items >= Contracts.MaxItemsPerListing then
		DRP.Inventory.InsertRaw(ply, record)
		notify(ply, "That listing cannot accept another item.", 3)
		return false
	end
	item.listingID = listing.id
	listing.items[#listing.items + 1] = item
	notify(ply, item.label .. " reserved in listing #" .. listing.id .. ".", 1)
	openEditor(ply, listing)
	Contracts.SyncAll()
	return true
end

local function selectedContains(items, itemID)
	for index, item in ipairs(items) do if item.id == itemID then return index, item end end
end

function Contracts.BeginNegotiation(buyer, listingID, virtualBuyer)
	local listing = Contracts.Listings[tonumber(listingID)]
	if not listing or listing.status ~= "active" or #listing.items == 0 then notify(buyer, "That listing is unavailable.", 3) return false end
	if listing.negotiationID then notify(buyer, "That listing is already being negotiated.", 3) return false end
	if not virtualBuyer and listing.sellerID == buyer:SteamID64() then notify(buyer, "You cannot buy your own listing.", 3) return false end
	if negotiationFor(buyer) or deliveryFor(buyer) then notify(buyer, "Finish your current trade first.", 3) return false end
	local seller = online(listing.sellerID)
	if not IsValid(seller) and not listing.virtualSeller then notify(buyer, "The seller must be online to negotiate.", 3) return false end
	if IsValid(seller) and (negotiationFor(seller) or deliveryFor(seller)) then notify(buyer, "That seller is already trading.", 3) return false end
	local items = {}
	for _, item in ipairs(listing.items) do if itemValid(item) and not item.tradeID then items[#items + 1] = item end end
	if #items == 0 then notify(buyer, "The listing has no available items.", 3) return false end
	local id = nextID("NextNegotiationID")
	local negotiation = {
		id = id,
		listingID = listing.id,
		sellerID = listing.sellerID,
		sellerName = listing.sellerName,
		buyerID = virtualBuyer and ("virtual:buyer:" .. id) or buyer:SteamID64(),
		buyerName = virtualBuyer and "Automated Buyer" or buyer:DRPName(),
		requested = listing.unitPrice * #items,
		offer = listing.unitPrice * #items,
		delivery = "trade_center",
		items = items,
		status = "negotiating",
		sellerConfirmed = listing.virtualSeller == true,
		buyerConfirmed = virtualBuyer == true,
		virtualSeller = listing.virtualSeller == true,
		virtualBuyer = virtualBuyer == true
	}
	Contracts.Negotiations[id] = negotiation
	listing.negotiationID = id
	openTrade(negotiation)
	if negotiation.virtualBuyer or negotiation.virtualSeller then Contracts.TryAccept(negotiation) end
	return true
end

local function deliveryPosition(negotiation)
	local seller, buyer = online(negotiation.sellerID), online(negotiation.buyerID)
	local sellerPos = IsValid(seller) and seller:GetPos() or nil
	local buyerPos = IsValid(buyer) and buyer:GetPos() or nil
	if negotiation.delivery == "seller" and sellerPos then return sellerPos end
	if negotiation.delivery == "buyer" and buyerPos then return buyerPos end
	if negotiation.delivery == "trade_center" and isvector(Contracts.TradeCenter) then return Contracts.TradeCenter end
	local anchor = buyerPos or sellerPos or Vector(0, 0, 0)
	local angle = math.rad(math.random(0, 359))
	local distance = negotiation.delivery == "random" and math.random(260, 520) or 220
	local candidate = anchor + Vector(math.cos(angle) * distance, math.sin(angle) * distance, 96)
	local trace = util.TraceLine({ start = candidate, endpos = candidate - Vector(0, 0, 512), mask = MASK_PLAYERSOLID })
	return trace.Hit and (trace.HitPos + Vector(0, 0, 8)) or anchor
end

local function restoreNegotiationExtras(negotiation, disconnecting)
	local seller = IsValid(disconnecting) and disconnecting:SteamID64() == negotiation.sellerID and disconnecting or online(negotiation.sellerID)
	for index = #negotiation.items, 1, -1 do
		local item = negotiation.items[index]
		if item.negotiationExtra then
			if IsValid(seller) and item.record then DRP.Inventory.InsertRaw(seller, item.record) end
			table.remove(negotiation.items, index)
		end
	end
end

function Contracts.CancelNegotiation(negotiation, reason, disconnecting)
	if not negotiation or negotiation.status ~= "negotiating" then return false end
	negotiation.status = "cancelled"
	restoreNegotiationExtras(negotiation, disconnecting)
	local listing = Contracts.Listings[negotiation.listingID]
	if listing then listing.negotiationID = nil end
	for _, id in ipairs({ negotiation.sellerID, negotiation.buyerID }) do notify(online(id), "Trade negotiation cancelled" .. (reason and (": " .. reason) or "."), 2) end
	Contracts.Negotiations[negotiation.id] = nil
	Contracts.SyncAll()
	return true
end

function Contracts.TryAccept(negotiation)
	if not negotiation or negotiation.status ~= "negotiating" or not negotiation.sellerConfirmed or not negotiation.buyerConfirmed then return false end
	local seller, buyer = online(negotiation.sellerID), online(negotiation.buyerID)
	if not negotiation.virtualSeller and not IsValid(seller) then return Contracts.CancelNegotiation(negotiation, "seller disconnected") end
	if not negotiation.virtualBuyer and not IsValid(buyer) then return Contracts.CancelNegotiation(negotiation, "buyer disconnected") end
	if #negotiation.items == 0 then return Contracts.CancelNegotiation(negotiation, "no items selected") end
	for _, item in ipairs(negotiation.items) do
		if not itemValid(item) then return Contracts.CancelNegotiation(negotiation, "an item is no longer available") end
		if item.tradeID then return Contracts.CancelNegotiation(negotiation, "an item was committed to another trade") end
	end
	if IsValid(buyer) then
		local handsRecords = {}
		for _, item in ipairs(negotiation.items) do if item.source ~= "entity" and item.record then handsRecords[#handsRecords + 1] = item.record end end
		if not DRP.Inventory.CanInsertBatch(buyer, handsRecords) then
			notify(buyer, "Your Hands grid cannot fit every item in this trade.", 3)
			negotiation.buyerConfirmed = false
			openTrade(negotiation)
			return false
		end
		if not DRP.Economy.Take(buyer, negotiation.offer, "marketplace escrow") then
			notify(buyer, "You cannot afford this trade.", 3)
			negotiation.buyerConfirmed = false
			openTrade(negotiation)
			return false
		end
	end
	negotiation.status = "accepted"
	local affectedListingIDs = {}
	for _, item in ipairs(negotiation.items) do
		item.tradeID = negotiation.id
		if item.listingID and item.listingID > 0 then affectedListingIDs[item.listingID] = true end
	end
	for listingID in pairs(affectedListingIDs) do
		local affected = Contracts.Listings[listingID]
		if affected then affected.status = "in_progress" end
	end
	local delivery = {
		id = negotiation.id,
		listingID = negotiation.listingID,
		sellerID = negotiation.sellerID,
		sellerName = negotiation.sellerName,
		buyerID = negotiation.buyerID,
		buyerName = negotiation.buyerName,
		offer = negotiation.offer,
		items = negotiation.items,
		position = deliveryPosition(negotiation),
		expires = CurTime() + Contracts.DeliverySeconds,
		status = "in_progress",
		requiresSeller = not negotiation.virtualSeller,
		requiresBuyer = not negotiation.virtualBuyer,
		virtualSeller = negotiation.virtualSeller,
		virtualBuyer = negotiation.virtualBuyer,
		affectedListingIDs = affectedListingIDs
	}
	Contracts.Deliveries[delivery.id] = delivery
	Contracts.Negotiations[negotiation.id] = nil
	Contracts.EnsureDeliveryChecks()
	for _, id in ipairs({ delivery.sellerID, delivery.buyerID }) do
		notify(online(id), "Trade accepted. Reach the delivery point within 10 minutes.", 1)
	end
	Contracts.SyncAll()
	return true
end

local function removeItemFromListings(item)
	for _, listing in pairs(Contracts.Listings) do
		for index = #listing.items, 1, -1 do
			if listing.items[index].id == item.id then table.remove(listing.items, index) end
		end
	end
end

function Contracts.Fulfill(delivery)
	if not delivery or delivery.status ~= "in_progress" then return false end
	local seller, buyer = online(delivery.sellerID), online(delivery.buyerID)
	if not delivery.virtualSeller and not IsValid(seller) then return false end
	if not delivery.virtualBuyer and not IsValid(buyer) then return false end
	if IsValid(buyer) then
		local records = {}
		for _, item in ipairs(delivery.items) do if item.source ~= "entity" and item.record then records[#records + 1] = item.record end end
		if not DRP.Inventory.CanInsertBatch(buyer, records) then
			if (delivery.nextSpaceNotice or 0) <= CurTime() then notify(buyer, "Clear enough Hands grid space to receive every trade item.", 3) delivery.nextSpaceNotice = CurTime() + 5 end
			return false
		end
	end
	for _, item in ipairs(delivery.items) do
		item.tradeID = nil
		if item.source == "entity" then
			if IsValid(item.entity) and IsValid(buyer) then
				item.entity.DRPContractLocked = nil
				DRP.Props.TransferOwnership(item.entity, buyer)
			elseif IsValid(item.entity) and delivery.virtualBuyer then
				item.entity.DRPContractLocked = nil
				item.entity:Remove()
			end
		elseif IsValid(buyer) then
			DRP.Inventory.InsertRaw(buyer, item.record)
		end
		removeItemFromListings(item)
	end
	if IsValid(seller) then DRP.Economy.Add(seller, delivery.offer, "marketplace delivery completed") end
	delivery.status = "completed"
	Contracts.Deliveries[delivery.id] = nil
	for listingID in pairs(delivery.affectedListingIDs or { [delivery.listingID] = true }) do
		local listing = Contracts.Listings[listingID]
		if listing then
			listing.negotiationID = nil
			listing.status = #listing.items > 0 and "active" or "completed"
		end
	end
	notify(seller, "Trade #" .. delivery.id .. " completed.", 1)
	notify(buyer, "Trade #" .. delivery.id .. " completed. Items delivered.", 1)
	hook.Run("DRPMarketplaceFulfilled", seller, buyer, delivery.items, delivery.offer)
	if DRP.Audit then DRP.Audit.Log(seller or buyer, "marketplace_completed", buyer or seller, "$" .. delivery.offer .. " / " .. #delivery.items .. " item(s)") end
	Contracts.SyncAll()
	return true
end

function Contracts.Timeout(delivery, reason, disconnectingBuyerID)
	if not delivery or delivery.status ~= "in_progress" then return false end
	delivery.status = "expired"
	Contracts.Deliveries[delivery.id] = nil
	local buyer = online(delivery.buyerID)
	if disconnectingBuyerID == delivery.buyerID then buyer = nil end
	if IsValid(buyer) then
		DRP.Economy.Add(buyer, delivery.offer, "marketplace escrow refund")
	elseif not delivery.virtualBuyer then
		Contracts.PendingRefunds[delivery.buyerID] = (Contracts.PendingRefunds[delivery.buyerID] or 0) + delivery.offer
		Contracts.SaveRefunds()
	end
	for _, item in ipairs(delivery.items) do item.tradeID = nil end
	for listingID in pairs(delivery.affectedListingIDs or { [delivery.listingID] = true }) do
		local listing = Contracts.Listings[listingID]
		if listing then
			listing.negotiationID = nil
			local valid = false
			for _, item in ipairs(listing.items) do if itemValid(item) then valid = true break end end
			listing.status = valid and "active" or "cancelled"
		end
	end
	for _, id in ipairs({ delivery.sellerID, delivery.buyerID }) do notify(online(id), reason or "Trade expired; escrow was returned.", 2) end
	Contracts.SyncAll()
	return true
end

function Contracts.CheckDeliveries()
	local started = DRP.Profile and DRP.Profile.Begin and DRP.Profile.Begin() or nil
	local now = CurTime()
	for _, delivery in pairs(Contracts.Deliveries) do
		if delivery.status == "in_progress" then
			if now >= delivery.expires then
				Contracts.Timeout(delivery, "Trade expired; the listing and escrow were restored.")
			else
				local seller, buyer = online(delivery.sellerID), online(delivery.buyerID)
				local sellerReady = not delivery.requiresSeller or (IsValid(seller) and seller:GetPos():DistToSqr(delivery.position) <= Contracts.DeliveryRadius ^ 2)
				local buyerReady = not delivery.requiresBuyer or (IsValid(buyer) and buyer:GetPos():DistToSqr(delivery.position) <= Contracts.DeliveryRadius ^ 2)
				if sellerReady and buyerReady then Contracts.Fulfill(delivery) end
			end
		end
	end
	Contracts.StopDeliveryChecksIfIdle()
	if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("contracts.deliveries", started) end
end

local function readAction()
	local action = cleanText(net.ReadString(), 32)
	local length = net.ReadUInt(16)
	if length > 32768 then return action, {} end
	local compressed = length > 0 and net.ReadData(length) or ""
	local json = length > 0 and util.Decompress(compressed) or "{}"
	local data = json and util.JSONToTable(json) or {}
	return action, istable(data) and data or {}
end

local function resetConfirmations(negotiation)
	negotiation.sellerConfirmed = negotiation.virtualSeller == true
	negotiation.buyerConfirmed = negotiation.virtualBuyer == true
end

DRP.Net.Receive(actionMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "contracts_action", 0.18, 8) then return end
	local action, data = readAction()
	if action == "request" then Contracts.Sync(ply, data.open == true) return end
	if action == "save_listing" then
		local listing = Contracts.Listings[math.floor(tonumber(data.id) or 0)]
		if not listing or listing.sellerID ~= ply:SteamID64() or (listing.status ~= "draft" and listing.status ~= "active") then return end
		listing.title = cleanText(data.title, 64)
		listing.description = cleanText(data.description, 280)
		listing.unitPrice = math.Clamp(math.floor(tonumber(data.unitPrice) or 0), 1, 100000000)
		if listing.title == "" or #listing.items == 0 then notify(ply, "A listing needs a title and at least one item.", 3) return end
		listing.status = "active"
		notify(ply, "Listing #" .. listing.id .. " published.", 1)
		Contracts.SyncAll()
	elseif action == "cancel_listing" then
		local listing = Contracts.Listings[math.floor(tonumber(data.id) or 0)]
		if not listing or listing.sellerID ~= ply:SteamID64() or listing.status == "in_progress" then return end
		Contracts.CancelListing(listing, ply)
		notify(ply, "Listing #" .. listing.id .. " cancelled and its items were restored.", 1)
		Contracts.SyncAll()
	elseif action == "begin" then
		Contracts.BeginNegotiation(ply, data.id, false)
	elseif action == "offer" then
		local negotiation = negotiationFor(ply)
		if not negotiation or negotiation.buyerID ~= ply:SteamID64() then return end
		negotiation.offer = math.Clamp(math.floor(tonumber(data.amount) or 0), 1, 100000000)
		resetConfirmations(negotiation)
		if negotiation.offer ~= negotiation.requested then notify(online(negotiation.sellerID), ply:DRPName() .. " offered $" .. string.Comma(negotiation.offer) .. " instead of $" .. string.Comma(negotiation.requested) .. ".", 2) end
		openTrade(negotiation)
	elseif action == "delivery" then
		local negotiation = negotiationFor(ply)
		local allowed = { buyer = true, seller = true, trade_center = true, random = true }
		if not negotiation or not allowed[tostring(data.choice)] then return end
		negotiation.delivery = tostring(data.choice)
		resetConfirmations(negotiation)
		openTrade(negotiation)
	elseif action == "toggle_item" then
		local negotiation = negotiationFor(ply)
		if not negotiation or negotiation.sellerID ~= ply:SteamID64() then return end
		local itemID = math.floor(tonumber(data.itemID) or 0)
		local index = selectedContains(negotiation.items, itemID)
		if index then
			if #negotiation.items <= 1 then notify(ply, "A trade must contain at least one item.", 3) return end
			local item = table.remove(negotiation.items, index)
			if item.negotiationExtra and item.record then DRP.Inventory.InsertRaw(ply, item.record) end
		else
			local found
			for _, listing in pairs(Contracts.Listings) do
				if listing.sellerID == ply:SteamID64() and listing.status == "active" then
					for _, item in ipairs(listing.items) do if item.id == itemID and itemValid(item) then found = item break end end
				end
				if found then break end
			end
			if found then negotiation.items[#negotiation.items + 1] = found end
		end
		resetConfirmations(negotiation)
		openTrade(negotiation)
	elseif action == "confirm" then
		local negotiation = negotiationFor(ply)
		if not negotiation then return end
		if negotiation.sellerID == ply:SteamID64() then negotiation.sellerConfirmed = true end
		if negotiation.buyerID == ply:SteamID64() then negotiation.buyerConfirmed = true end
		openTrade(negotiation)
		Contracts.TryAccept(negotiation)
	elseif action == "cancel" then
		Contracts.CancelNegotiation(negotiationFor(ply), "cancelled by " .. ply:DRPName())
	elseif action == "pocket_add" then
		Contracts.AddPocketItem(ply, data.itemID or data.index, data.listingID, data.createNew == true, data.negotiationID)
	end
end)

function Contracts.CreateAutomatedBuyerListing(ply)
	local listing = newListing(ply)
	if not listing then return false end
	local samples = {
		{ label = "Industrial Components", model = "models/props_lab/partsbin01.mdl", price = 140 },
		{ label = "Sealed Supply Crate", model = "models/props_junk/cardboard_box004a.mdl", price = 75 },
		{ label = "Workshop Equipment", model = "models/props_c17/tools_wrench01a.mdl", price = 220 },
		{ label = "Medical Supplies", model = "models/props_lab/jar01b.mdl", price = 165 }
	}
	local sample = samples[math.random(1, #samples)]
	local item = {
		id = nextID("NextItemID"),
		source = "virtual",
		record = { kind = "entity", class = "prop_physics", model = sample.model, label = sample.label },
		label = sample.label,
		listingID = listing.id
	}
	listing.items[1] = item
	listing.title = sample.label .. " — Automated Sale"
	listing.description = "Server-operated listing used to test the buyer delivery path."
	listing.unitPrice = sample.price
	listing.status = "active"
	listing.virtualSeller = true
	listing.sellerID = "virtual:seller:" .. listing.id
	listing.sellerName = "Automated Seller"
	Contracts.SyncAll()
	Contracts.BeginNegotiation(ply, listing.id, false)
	return true
end

function Contracts.CreateAutomatedSellerTrade(ply)
	local listing
	for _, candidate in pairs(Contracts.Listings) do
		if candidate.sellerID == ply:SteamID64() and candidate.status == "active" and #candidate.items > 0 then listing = candidate break end
	end
	if not listing then
		notify(ply, "Publish a listing first; the automated buyer will purchase it.", 3)
		return false
	end
	return Contracts.BeginNegotiation(ply, listing.id, true)
end

function Contracts:SetTradeCenter(ply)
	if not IsValid(ply) or not DRP.Admin or not DRP.Admin.IsOwner(ply) then return false end
	self.TradeCenter = ply:GetPos()
	file.CreateDir("darkrp")
	file.Write(self.ConfigPath, util.TableToJSON({ tradeCenter = { x = self.TradeCenter.x, y = self.TradeCenter.y, z = self.TradeCenter.z } }, false) or "{}")
	notify(ply, "Marketplace trade center set at your position.", 1)
	return true
end

function Contracts.CancelListing(listing, seller)
	if not listing or listing.status == "in_progress" then return false end
	seller = IsValid(seller) and seller or online(listing.sellerID)
	for _, item in ipairs(listing.items) do
		if item.source == "entity" and IsValid(item.entity) then
			item.entity.DRPContractLocked = nil
		elseif item.record and IsValid(seller) then
			DRP.Inventory.InsertRaw(seller, item.record)
		end
	end
	listing.items = {}
	listing.status = "cancelled"
	return true
end

function Contracts.CancelSellerListings(ply)
	if not IsValid(ply) then return end
	for _, listing in pairs(Contracts.Listings) do
		if listing.sellerID == ply:SteamID64() and listing.status ~= "in_progress" then Contracts.CancelListing(listing, ply) end
	end
end

function Contracts.PrepareShutdown()
	if Contracts.ShuttingDown then return end
	Contracts.ShuttingDown = true
	for _, negotiation in pairs(Contracts.Negotiations) do
		if negotiation.status == "negotiating" then Contracts.CancelNegotiation(negotiation, "server shutdown") end
	end
	for _, delivery in pairs(Contracts.Deliveries) do
		if delivery.status == "in_progress" then Contracts.Timeout(delivery, "Trade refunded because the server is restarting.") end
	end
	for _, ply in ipairs(DRP.Players.List) do if IsValid(ply) then Contracts.CancelSellerListings(ply) end end
	Contracts.SaveRefunds()
end

function Contracts:Start()
	local decoded = util.JSONToTable(file.Read(self.RefundPath, "DATA") or "")
	if istable(decoded) then
		for steamID64, amount in pairs(decoded) do
			amount = math.max(0, math.floor(tonumber(amount) or 0))
			if amount > 0 then self.PendingRefunds[tostring(steamID64)] = amount end
		end
	end
	local config = util.JSONToTable(file.Read(self.ConfigPath, "DATA") or "")
	local point = istable(config) and config.tradeCenter or nil
	if istable(point) then self.TradeCenter = Vector(tonumber(point.x) or 0, tonumber(point.y) or 0, tonumber(point.z) or 0) end
	for id, delivery in pairs(self.Deliveries) do
		if delivery.status ~= "in_progress" then self.Deliveries[id] = nil end
	end
	if not table.IsEmpty(self.Deliveries) then self.EnsureDeliveryChecks() end
end

function Contracts:Stop()
	self:PrepareShutdown()
	timer.Remove(self.DeliveryTimerName)
end

hook.Add("DRPPlayerReady", "DRP.Contracts.InitialSync", function(ply)
	local refund = Contracts.PendingRefunds[ply:SteamID64()]
	if refund and refund > 0 then
		Contracts.PendingRefunds[ply:SteamID64()] = nil
		DRP.Economy.Add(ply, refund, "offline marketplace escrow refund")
		Contracts.SaveRefunds()
	end
	Contracts.Sync(ply, false)
end)

hook.Add("EntityRemoved", "DRP.Contracts.EntityRemoved", function(entity)
	local itemID = entity.DRPContractLocked
	if not itemID then return end
	for _, listing in pairs(Contracts.Listings) do
		for index = #listing.items, 1, -1 do
			if listing.items[index].id == itemID then table.remove(listing.items, index) end
		end
		if #listing.items == 0 and listing.status ~= "completed" then listing.status = "cancelled" end
	end
	timer.Simple(0, function() Contracts.SyncAll() end)
end)

hook.Add("PlayerUse", "DRP.Contracts.LockedEntityUse", function(_, entity)
	if IsValid(entity) and entity.DRPContractLocked then return false end
end)

function Contracts.HandleParticipantDeath(ply)
	if not IsValid(ply) then return end
	local deathPosition = ply:GetPos()
	local negotiation = negotiationFor(ply)
	if negotiation then Contracts.CancelNegotiation(negotiation, "a participant died", ply) end
	local delivery = deliveryFor(ply)
	if delivery then
		Contracts.Timeout(delivery, "Trade cancelled because a participant died; buyer escrow was refunded.")
	end
	-- Listing-held pocket records are restored before the single death drop.
	-- World entities are merely unlocked; only actual pocket goods spill.
	Contracts.CancelSellerListings(ply)
	DRP.Inventory.DropAllAt(ply, deathPosition)
	if not ply:IsBot() then DRP.Inventory.SaveNow(ply) end
	Contracts.SyncAll()
end

hook.Add("PlayerDeath", "DRP.Contracts.ParticipantDeath", function(ply)
	Contracts.HandleParticipantDeath(ply)
end)

function Contracts.HandleDisconnect(ply)
	local negotiation = negotiationFor(ply)
	if negotiation then Contracts.CancelNegotiation(negotiation, "a participant disconnected", ply) end
	local delivery = deliveryFor(ply)
	if delivery then Contracts.Timeout(delivery, "Trade cancelled because a participant disconnected.", ply:SteamID64() == delivery.buyerID and delivery.buyerID or nil) end
	Contracts.CancelSellerListings(ply)
	Contracts.SyncAll()
end

concommand.Add("drp_contract_test_buyer", function(ply)
	if IsValid(ply) and DRP.Tests and DRP.Tests.CanRunProductionTest and DRP.Tests.CanRunProductionTest(ply) then Contracts.CreateAutomatedBuyerListing(ply) end
end)

concommand.Add("drp_contract_test_seller", function(ply)
	if IsValid(ply) and DRP.Tests and DRP.Tests.CanRunProductionTest and DRP.Tests.CanRunProductionTest(ply) then Contracts.CreateAutomatedSellerTrade(ply) end
end)
