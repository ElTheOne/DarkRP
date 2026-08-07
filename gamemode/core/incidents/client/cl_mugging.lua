local requestMessage = "drp_mug_request_v1"
local noticeMessage = "drp_mug_notice_v1"
local moneyMessage = "drp_money_drop_v1"
local amountConVar = CreateClientConVar("drp_mug_amount", "500", true, false, "Default mugging demand", 1, 5000)

local heldAt
local openedAmountMenu = false
local notice
local moneyDrops = setmetatable({}, { __mode = "k" })

local function canUseMugKey()
	if gui.IsGameUIVisible() or IsValid(vgui.GetKeyboardFocus()) then return false end
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return false end
	return ply:DRPHasRoleCapability("canMug")
end

local function openAmountMenu()
	openedAmountMenu = true
	Derma_StringRequest(
		"Mugging Demand",
		"Set the cash demand used when you short-press M (maximum $5,000).",
		tostring(math.Clamp(amountConVar:GetInt(), 1, 5000)),
		function(value)
			local amount = math.floor(tonumber(value) or 0)
			if amount < 1 or amount > 5000 then
				notification.AddLegacy("Mugging amount must be between $1 and $5,000.", NOTIFY_ERROR, 4)
				return
			end
			RunConsoleCommand("drp_mug_amount", tostring(amount))
			notification.AddLegacy("Mugging demand set to $" .. string.Comma(amount) .. ".", NOTIFY_GENERIC, 4)
		end,
		nil,
		"Save amount",
		"Cancel"
	)
end

hook.Add("PlayerButtonDown", "DRP.Mugging.KeyDown", function(ply, button)
	if ply ~= LocalPlayer() or button ~= KEY_M or heldAt or not canUseMugKey() then return end
	heldAt = RealTime()
	openedAmountMenu = false
	timer.Create("DRP.Mugging.Hold", 3, 1, function()
		if heldAt and input.IsKeyDown(KEY_M) and canUseMugKey() then openAmountMenu() end
	end)
end)

hook.Add("PlayerButtonUp", "DRP.Mugging.KeyUp", function(ply, button)
	if ply ~= LocalPlayer() or button ~= KEY_M or not heldAt then return end
	timer.Remove("DRP.Mugging.Hold")
	local wasHeld = RealTime() - heldAt
	heldAt = nil
	if openedAmountMenu or wasHeld >= 3 or not canUseMugKey() then return end
	net.Start(requestMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.Clamp(amountConVar:GetInt(), 1, 5000), 13)
	net.SendToServer()
end)

net.Receive(noticeMessage, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local state = net.ReadUInt(2)
	local isVictim = net.ReadBool()
	local other = net.ReadString()
	local amount = net.ReadUInt(16)
	local duration = net.ReadUInt(8)
	local reason = net.ReadString()
	notice = {
		state = state,
		isVictim = isVictim,
		other = other,
		amount = amount,
		reason = reason,
		expires = RealTime() + (state == 1 and math.max(duration, 1) or 5)
	}
end)

net.Receive(moneyMessage, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local entity = net.ReadEntity()
	local amount = net.ReadUInt(32)
	if IsValid(entity) then moneyDrops[entity] = amount end
end)

local function discoverMoneyDrop(entity)
	if not IsValid(entity) or entity:GetClass() ~= "prop_physics" then return end
	if entity:GetNW2Bool("DRPMoneyDrop", false) then
		moneyDrops[entity] = math.max(0, entity:GetNW2Int("DRPMoneyAmount", 0))
	end
end

-- Index only when entities arrive or their PVS-backed values change. This
-- covers late join/PVS entry without searching every physics prop each second.
hook.Add("InitPostEntity", "DRP.Money.IndexExisting", function()
	for _, entity in ipairs(ents.FindByClass("prop_physics")) do discoverMoneyDrop(entity) end
end)

hook.Add("OnEntityCreated", "DRP.Money.IndexCreated", function(entity)
	if not IsValid(entity) or entity:GetClass() ~= "prop_physics" then return end
	timer.Simple(0, function() discoverMoneyDrop(entity) end)
end)

hook.Add("EntityNetworkedVarChanged", "DRP.Money.IndexNetworked", function(entity, key)
	if key == "DRPMoneyDrop" or key == "DRPMoneyAmount" then discoverMoneyDrop(entity) end
end)

hook.Add("EntityRemoved", "DRP.Money.Unindex", function(entity)
	moneyDrops[entity] = nil
end)

hook.Add("HUDPaint", "DRP.Mugging.Notice", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	if not notice or notice.expires <= RealTime() then notice = nil return end
	local colors = DRP.UI.Colors
	local width, height = math.min(580, ScrW() - 40), 78
	local x, y = (ScrW() - width) * 0.5, 145
	local accent = notice.state == 3 and colors.red or (notice.state == 2 and colors.green or colors.accent)
	local title
	if notice.state == 1 then
		title = notice.isVictim and ("MUGGED BY " .. string.upper(notice.other)) or ("MUGGING " .. string.upper(notice.other))
	elseif notice.state == 2 then
		title = "MUGGING DEMAND PAID"
	elseif notice.state == 3 then
		title = "MUGGING ESCALATED — TWO-WAY PVP"
	else
		title = "MUGGING ENDED"
	end
	local detail = "$" .. string.Comma(notice.amount) .. "  •  " .. notice.reason
	if notice.state == 1 then detail = detail .. "  •  " .. math.max(0, math.ceil(notice.expires - RealTime())) .. "s" end

	draw.RoundedBox(8, x, y, width, height, colors.background)
	draw.RoundedBoxEx(8, x, y, 6, height, accent, true, false, true, false)
	draw.SimpleText(title, "DRP.Admin.Header", x + 22, y + 24, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText(detail, "DRP.Admin.Small", x + 22, y + 53, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
end)

hook.Add("PostDrawTranslucentRenderables", "DRP.Money.Labels", function(_, drawingSkybox)
	if drawingSkybox then return end
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	for entity, amount in pairs(moneyDrops) do
		if not IsValid(entity) then
			moneyDrops[entity] = nil
		elseif ply:GetPos():DistToSqr(entity:GetPos()) <= 900 * 900 then
			local angle = Angle(0, ply:EyeAngles().y - 90, 90)
			cam.Start3D2D(entity:WorldSpaceCenter() + Vector(0, 0, 18), angle, 0.08)
				draw.RoundedBox(8, -115, -34, 230, 68, Color(12, 16, 24, 235))
				draw.SimpleText("$" .. string.Comma(amount), "DRP.Admin.Header", 0, -9, DRP.UI.Colors.green, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				draw.SimpleText("PRESS E TO COLLECT", "DRP.Admin.Small", 0, 16, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			cam.End3D2D()
		end
	end
end)
