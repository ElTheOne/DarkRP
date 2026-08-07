local frame
local trackedHotplate
local nextHotplateScan = 0

local function sendAction(entity, action)
	net.Start("drp_cocaine_action_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteEntity(entity)
		net.WriteUInt(action, 3)
	net.SendToServer()
end

local function actionButton(parent, y, text, detail, color, callback, enabled)
	local button = DRP.UI.Button(parent, text, color, callback)
	button:SetPos(24, y)
	button:SetSize(512, 46)
	button:SetEnabled(enabled ~= false)
	local label = vgui.Create("DLabel", parent)
	label:SetPos(28, y + 47)
	label:SetSize(504, 22)
	label:SetFont("DRP.Admin.Small")
	label:SetTextColor(DRP.UI.Colors.muted)
	label:SetText(detail)
	return button
end

local function openMenu(mode, entity, product, doses, bricks, hasBucket)
	if IsValid(frame) then frame:Remove() end
	frame = DRP.UI.Frame(mode == "table" and "NARCOTICS TABLE" or "NARCOTICS BUYER", 560, mode == "table" and 520 or 330)
	local summary = vgui.Create("DLabel", frame)
	summary:SetPos(24, 68)
	summary:SetSize(512, 52)
	summary:SetFont("DRP.Admin.Body")
	summary:SetTextColor(color_white)
	summary:SetText(string.format("Unpackaged %d    •    Doses %d    •    Bricks %d", product, doses, bricks))
	summary:SetContentAlignment(5)

	if mode == "table" then
		actionButton(frame, 128, "STRAIN COOKED BATCH", "Requires a cooked mixing bucket beside the table.", DRP.UI.Colors.accent, function() sendAction(entity, 0) end, hasBucket)
		actionButton(frame, 206, "PACKAGE ONE DOSE", "Turns one unit of unpackaged product into a usable dose.", DRP.UI.Colors.green, function() sendAction(entity, 1) end, product >= 1)
		actionButton(frame, 284, "COMBINE FIVE DOSES", "Compresses five individual doses into one sale brick.", DRP.UI.Colors.purple, function() sendAction(entity, 2) end, doses >= 5)
		actionButton(frame, 362, "BREAK DOWN ONE BRICK", "Splits one brick back into five usable doses.", DRP.UI.Colors.red, function() sendAction(entity, 3) end, bricks >= 1)
	else
		actionButton(frame, 128, "SELL ONE DOSE  •  $" .. string.Comma(DRP.CocaineConfig.Prices.dose), "Selling illegal narcotics reduces civic standing.", DRP.UI.Colors.green, function() sendAction(entity, 4) end, doses >= 1)
		actionButton(frame, 206, "SELL ONE BRICK  •  $" .. string.Comma(DRP.CocaineConfig.Prices.brick), "Bulk sales carry a larger civic-standing penalty.", DRP.UI.Colors.purple, function() sendAction(entity, 5) end, bricks >= 1)
	end
end

net.Receive("drp_cocaine_menu_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local mode, entity = net.ReadString(), net.ReadEntity()
	local product, doses, bricks, hasBucket = net.ReadUInt(8), net.ReadUInt(8), net.ReadUInt(8), net.ReadBool()
	if IsValid(entity) then openMenu(mode, entity, product, doses, bricks, hasBucket) end
end)

hook.Add("Think", "DRP.Cocaine.TrackHotplate", function()
	if nextHotplateScan > CurTime() then return end
	nextHotplateScan = CurTime() + 0.5
	trackedHotplate = nil
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local bestDistance = 90000
	for _, hotplate in ipairs(ents.FindByClass("drp_cocaine_hotplate")) do
		if hotplate:GetNW2Float("DRPCocaineCookEnd", 0) > CurTime() then
			local distance = ply:GetPos():DistToSqr(hotplate:GetPos())
			if distance < bestDistance then trackedHotplate, bestDistance = hotplate, distance end
		end
	end
end)

hook.Add("HUDPaint", "DRP.Cocaine.CookStatus", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	local hotplate = trackedHotplate
	if not IsValid(hotplate) then return end
	local now, finishAt = CurTime(), hotplate:GetNW2Float("DRPCocaineCookEnd", 0)
	if finishAt <= now then return end
	local stirDeadline = hotplate:GetNW2Float("DRPCocaineStirDeadline", 0)
	local width, height = 430, 68
	local x, y = ScrW() * 0.5 - width * 0.5, ScrH() * 0.76
	local urgent = stirDeadline > now
	draw.RoundedBox(8, x, y, width, height, Color(9, 14, 23, 238))
	draw.RoundedBoxEx(8, x, y, 5, height, urgent and DRP.UI.Colors.red or DRP.UI.Colors.accent, true, false, true, false)
	draw.SimpleText(urgent and "STIR THE BATCH NOW — PRESS E ON HOTPLATE" or "COCAINE BATCH HEATING", "DRP.Admin.Body", x + 18, y + 20, urgent and DRP.UI.Colors.red or color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText("Cook time " .. string.FormattedTime(math.ceil(finishAt - now), "%02i:%02i"), "DRP.Admin.Small", x + 18, y + 45, DRP.UI.Colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	if urgent then
		local remaining = math.max(0, stirDeadline - now)
		draw.SimpleText(string.format("%.1fs", remaining), "DRP.Admin.Header", x + width - 18, y + 34, DRP.UI.Colors.red, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end
end)
