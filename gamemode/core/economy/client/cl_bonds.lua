local openMessage = "drp_bond_atm_open_v1"
local buyMessage = "drp_bond_atm_buy_v1"
local activeFrame

local function money(value)
	return "$" .. string.Comma(math.max(0, math.floor(tonumber(value) or 0)))
end

local function duration(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	if seconds >= 3600 then return math.floor(seconds / 3600) .. "h " .. math.floor((seconds % 3600) / 60) .. "m" end
	if seconds >= 60 then return math.floor(seconds / 60) .. "m " .. (seconds % 60) .. "s" end
	return seconds .. "s"
end

local function panel(parent, title, value, accent)
	local card = vgui.Create("DPanel", parent)
	card:Dock(TOP)
	card:DockMargin(0, 0, 0, 10)
	card:SetTall(72)
	card.Paint = function(_, w, h)
		draw.RoundedBox(8, 0, 0, w, h, Color(7, 17, 34, 235))
		draw.RoundedBoxEx(8, 0, 0, 5, h, accent, true, false, true, false)
		draw.SimpleText(string.upper(title), "DRP.Admin.Small", 18, 17, Color(150, 169, 195), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(value(), "DRP.Admin.Header", 18, 47, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	return card
end

local function closeFrame()
	if not IsValid(activeFrame) then return end
	activeFrame:AlphaTo(0, 0.12, 0, function()
		if IsValid(activeFrame) then activeFrame:Remove() end
	end)
end

local function openATM(snapshot)
	if IsValid(activeFrame) then activeFrame:Remove() end
	local colors = DRP.UI and DRP.UI.Colors or {}
	local accent = colors.accent or Color(74, 205, 255)
	local positive = colors.green or Color(80, 218, 159)
	local danger = colors.red or Color(255, 92, 112)
	local frame = vgui.Create("DFrame")
	activeFrame = frame
	frame:SetSize(math.min(ScrW() - 80, 1040), math.min(ScrH() - 80, 760))
	frame:Center()
	frame:SetTitle("")
	frame.StartTime = SysTime()
	frame:ShowCloseButton(false)
	frame:MakePopup()
	frame:SetAlpha(0)
	frame:AlphaTo(255, 0.14)
	frame.Paint = function(_, w, h)
		Derma_DrawBackgroundBlur(frame, frame.StartTime or SysTime())
		draw.RoundedBox(12, 0, 0, w, h, Color(4, 10, 24, 248))
		draw.RoundedBoxEx(12, 0, 0, w, 68, Color(9, 28, 52, 250), true, true, false, false)
		draw.RoundedBox(0, 0, 65, w, 3, accent)
		draw.SimpleText("MUNICIPAL BOND TERMINAL", "DRP.Admin.Header", 24, 26, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("FIXED RETURN • TREASURY-BACKED", "DRP.Admin.Small", 24, 48, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local close = vgui.Create("DButton", frame)
	close:SetSize(42, 36)
	close:SetPos(frame:GetWide() - 56, 16)
	close:SetText("×")
	close:SetFont("DRP.Admin.Header")
	close:SetTextColor(color_white)
	close.Paint = function(_, w, h) draw.RoundedBox(7, 0, 0, w, h, danger) end
	close.DoClick = closeFrame

	local body = vgui.Create("DPanel", frame)
	body:SetPos(20, 84)
	body:SetSize(frame:GetWide() - 40, frame:GetTall() - 104)
	body.Paint = nil

	local left = vgui.Create("DPanel", body)
	left:Dock(LEFT)
	left:SetWide(math.floor(body:GetWide() * 0.38))
	left:DockMargin(0, 0, 14, 0)
	left.Paint = nil

	panel(left, "Guaranteed return", function()
		return string.format("%.2f%% after %s", (tonumber(snapshot.interestBasisPoints) or 0) / 100, duration(snapshot.termSeconds))
	end, positive)
	panel(left, "Your available allowance", function()
		return money(snapshot.capacity and snapshot.capacity.playerAvailable)
	end, accent)
	panel(left, "Municipal issue remaining", function()
		return money(snapshot.capacity and snapshot.capacity.globalAvailable)
	end, accent)
	panel(left, "Government solvency", function()
		if (snapshot.deficit or 0) > 0 then return "DEFICIT " .. money(snapshot.deficit) end
		return "SOLVENT • " .. money(snapshot.treasury) .. " TREASURY"
	end, (snapshot.deficit or 0) > 0 and danger or positive)
	panel(left, "Inflation control", function()
		local rate = (snapshot.capacity and snapshot.capacity.burnRate or 0) * 100
		return rate > 0 and string.format("%.2f%% TRANSFER BURN", rate) or "NORMAL ISSUANCE LIMITS"
	end, (snapshot.capacity and snapshot.capacity.factor or 1) <= 0 and danger or accent)

	local buyCard = vgui.Create("DPanel", left)
	buyCard:Dock(TOP)
	buyCard:SetTall(132)
	buyCard.Paint = function(_, w, h)
		draw.RoundedBox(8, 0, 0, w, h, Color(7, 17, 34, 235))
		draw.SimpleText(snapshot.issuance and "PURCHASE A BOND" or "BOND SALES CLOSED", "DRP.Admin.Header", 16, 20, snapshot.issuance and positive or danger, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("Minimum " .. money(snapshot.minimum), "DRP.Admin.Small", 16, 44, Color(150, 169, 195), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	local amount = vgui.Create("DNumberWang", buyCard)
	amount:SetPos(14, 60)
	amount:SetSize(buyCard:GetWide() - 126, 52)
	amount:SetMinMax(snapshot.minimum or 500, math.max(snapshot.minimum or 500, snapshot.capacity and snapshot.capacity.playerAvailable or 500))
	amount:SetValue(snapshot.minimum or 500)
	amount:SetDecimals(0)
	amount:SetEnabled(snapshot.issuance == true)
	local buy = vgui.Create("DButton", buyCard)
	buy:SetPos(buyCard:GetWide() - 102, 60)
	buy:SetSize(88, 52)
	buy:SetText("BUY")
	buy:SetFont("DRP.Admin.Body")
	buy:SetTextColor(color_white)
	buy:SetEnabled(snapshot.issuance == true)
	buy.Paint = function(button, w, h)
		draw.RoundedBox(7, 0, 0, w, h, button:IsEnabled() and positive or Color(55, 65, 82))
	end
	buy.DoClick = function()
		local value = math.max(0, math.floor(tonumber(amount:GetValue()) or 0))
		net.Start(buyMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(math.min(value, 4294967295), 32)
		net.SendToServer()
	end
	buyCard.PerformLayout = function(_, w)
		amount:SetWide(math.max(80, w - 126))
		buy:SetPos(w - 102, 60)
	end

	local right = vgui.Create("DPanel", body)
	right:Dock(FILL)
	right.Paint = function(_, w, h)
		draw.RoundedBox(9, 0, 0, w, h, Color(7, 17, 34, 220))
		draw.SimpleText("YOUR GOVERNMENT BONDS", "DRP.Admin.Header", 18, 24, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("Principal and guaranteed profit are paid automatically at maturity.", "DRP.Admin.Small", 18, 49, Color(150, 169, 195), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local scroll = vgui.Create("DScrollPanel", right)
	scroll:SetPos(14, 70)
	scroll:SetSize(right:GetWide() - 28, right:GetTall() - 84)
	right.PerformLayout = function(_, w, h) scroll:SetSize(w - 28, h - 84) end
	local records = snapshot.records or {}
	if #records == 0 then
		local empty = vgui.Create("DLabel", scroll)
		empty:Dock(TOP)
		empty:SetTall(56)
		empty:SetFont("DRP.Admin.Body")
		empty:SetTextColor(Color(150, 169, 195))
		empty:SetText("You do not currently hold a municipal bond.")
	else
		for _, record in ipairs(records) do
			local row = vgui.Create("DPanel", scroll)
			row:Dock(TOP)
			row:DockMargin(0, 0, 0, 8)
			row:SetTall(84)
			row.Paint = function(_, w, h)
				local pending = record.status == "pending"
				draw.RoundedBox(7, 0, 0, w, h, Color(10, 25, 47, 245))
				draw.RoundedBoxEx(7, 0, 0, 5, h, pending and positive or accent, true, false, true, false)
				draw.SimpleText("BOND #" .. tostring(record.id), "DRP.Admin.Header", 17, 19, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(money(record.principal) .. " principal  •  " .. money(record.payout) .. " maturity", "DRP.Admin.Body", 17, 46, Color(190, 205, 225), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				local status = pending and "MATURED • PAYOUT PENDING" or ("MATURES IN " .. duration((record.matures or 0) - os.time()))
				draw.SimpleText(status, "DRP.Admin.Small", w - 16, 21, pending and positive or accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
			end
		end
	end
end

net.Receive(openMessage, function()
	local length = net.ReadUInt(20)
	if length <= 0 or length > 1048575 then return end
	local raw = net.ReadData(length)
	local decoded = util.JSONToTable(util.Decompress(raw) or raw or "")
	if not istable(decoded) then return end
	openATM(decoded)
end)
