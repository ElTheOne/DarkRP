local requestMessage = "drp_mug_request_v1"
local noticeMessage = "drp_mug_notice_v1"
local moneyMessage = "drp_money_drop_v1"
local actionMessage = "drp_mug_action_v1"
local amountConVar = CreateClientConVar("drp_mug_amount", "500", true, false, "Default mugging demand", 1, 5000)

local heldAt
local mugKeyDown = false
local openedAmountMenu = false
local notice
local victimPanel
local reopenPrompt
local moneyDrops = setmetatable({}, { __mode = "k" })

DRP.MuggingClient = DRP.MuggingClient or {}

local function canUseMugKey()
	if gui.IsGameUIVisible() or IsValid(vgui.GetKeyboardFocus()) then return false end
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return false end
	return ply:DRPHasRoleCapability("canMug")
end

local function openAmountMenu()
	if IsValid(DRP.MuggingClient.AmountFrame) then DRP.MuggingClient.AmountFrame:Remove() end
	openedAmountMenu = true
	local colors = DRP.UI.Colors
	local frame = DRP.UI.Frame("SET MUGGING DEMAND", 560, 360)
	DRP.MuggingClient.AmountFrame = frame
	frame:SetDeleteOnClose(true)

	local detail = vgui.Create("DLabel", frame)
	detail:SetPos(28, 78) detail:SetSize(frame:GetWide() - 56, 45)
	detail:SetFont("DRP.Admin.Body") detail:SetTextColor(colors.muted) detail:SetWrap(true)
	detail:SetText("Aim at a stationary player, choose the amount and issue the demand. A quick tap of M uses your saved amount.")

	local amount = vgui.Create("DTextEntry", frame)
	amount:SetPos(28, 140) amount:SetSize(frame:GetWide() - 56, 54)
	amount:SetFont("DRP.Admin.Title") amount:SetTextColor(color_white) amount:SetDrawLanguageID(false)
	amount:SetText(tostring(math.Clamp(amountConVar:GetInt(), 1, 5000))) amount:SetNumeric(true)
	amount.Paint = function(self, width, height)
		draw.RoundedBox(8, 0, 0, width, height, colors.panelHover)
		draw.RoundedBoxEx(8, 0, 0, 5, height, colors.green, true, false, true, false)
		draw.SimpleText("$", "DRP.Admin.Title", 22, height * 0.5, colors.green, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		self:DrawTextEntryText(color_white, colors.accent, color_white)
	end
	amount:SetTextInset(48, 0)

	local presets = { 250, 500, 1000, 2500, 5000 }
	for index, value in ipairs(presets) do
		local presetWidth = (frame:GetWide() - 76) / #presets
		local preset = DRP.UI.Button(frame, "$" .. string.Comma(value), colors.panelHover, function() amount:SetText(tostring(value)) end)
		preset:SetPos(28 + (index - 1) * ((frame:GetWide() - 64) / #presets), 208)
		preset:SetSize(presetWidth, 35)
	end

	local start = DRP.UI.Button(frame, "ISSUE DEMAND", colors.green, function()
		local value = math.floor(tonumber(amount:GetValue()) or 0)
		if value < 1 or value > 5000 then
			notification.AddLegacy("Mugging amount must be between $1 and $5,000.", NOTIFY_ERROR, 4)
			return
		end
		RunConsoleCommand("drp_mug_amount", tostring(value))
		net.Start(requestMessage)
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.WriteUInt(value, 13)
		net.SendToServer()
		frame:Close()
	end)
	start:SetPos(28, 270) start:SetSize(frame:GetWide() - 184, 46)
	local cancel = DRP.UI.Button(frame, "CANCEL", colors.panelHover, function() frame:Close() end)
	cancel:SetPos(frame:GetWide() - 144, 270) cancel:SetSize(116, 46)
	frame.OnRemove = function() if DRP.MuggingClient.AmountFrame == frame then DRP.MuggingClient.AmountFrame = nil end end
end

-- PlayerButtonDown is not reliable for unbound letter keys on every client.
-- Track only the local M key and keep all gameplay authorization server-side.
hook.Add("Think", "DRP.Mugging.MKey", function()
	local down = input.IsKeyDown(KEY_M)
	if down and not mugKeyDown then
		mugKeyDown = true
		if canUseMugKey() then heldAt, openedAmountMenu = RealTime(), false end
	elseif down and heldAt and not openedAmountMenu and RealTime() - heldAt >= 3 then
		if canUseMugKey() then openAmountMenu() end
		heldAt = nil
	elseif not down and mugKeyDown then
		mugKeyDown = false
		local started = heldAt
		heldAt = nil
		if started and not openedAmountMenu and RealTime() - started < 3 and canUseMugKey() then
			net.Start(requestMessage)
				net.WriteUInt(DRP.ProtocolVersion, 8)
				net.WriteUInt(math.Clamp(amountConVar:GetInt(), 1, 5000), 13)
			net.SendToServer()
		end
	end
end)

local function clearVictimUI()
	if IsValid(victimPanel) then victimPanel.DRPResolved = true victimPanel:Remove() end
	if IsValid(reopenPrompt) then reopenPrompt:Remove() end
	victimPanel, reopenPrompt = nil, nil
end

local openVictimPanel
local function showReopenPrompt()
	if not notice or notice.state ~= 1 or not notice.isVictim or notice.expires <= RealTime() or IsValid(reopenPrompt) then return end
	local colors = DRP.UI.Colors
	local prompt = vgui.Create("DButton")
	reopenPrompt = prompt
	prompt:SetText("") prompt:SetSize(math.min(350, ScrW() - 40), 86)
	prompt:SetMouseInputEnabled(true) prompt:SetKeyboardInputEnabled(false)
	prompt.Think = function(button)
		button:SetPos(ScrW() - button:GetWide() - 26, ScrH() - button:GetTall() - 26)
		if not notice or notice.state ~= 1 or notice.expires <= RealTime() then button:Remove() end
	end
	prompt.Paint = function(_, width, height)
		draw.RoundedBox(8, 0, 0, width, height, colors.panel)
		draw.RoundedBoxEx(8, 0, 0, 5, height, colors.red, true, false, true, false)
		draw.SimpleText("MUGGING DEMAND PENDING", "DRP.Admin.Small", 16, 17, colors.red, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("$" .. string.Comma(notice.amount) .. "  •  " .. math.max(0, math.ceil(notice.expires - RealTime())) .. "s", "DRP.Admin.Header", 16, 42, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("Z / F3 for cursor  •  CLICK TO REOPEN", "DRP.Admin.Small", 16, 66, colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	prompt.DoClick = function()
		if IsValid(prompt) then prompt:Remove() end
		reopenPrompt = nil
		openVictimPanel()
	end
	prompt.OnRemove = function() if reopenPrompt == prompt then reopenPrompt = nil end end
end

openVictimPanel = function()
	if not notice or notice.state ~= 1 or not notice.isVictim or notice.expires <= RealTime() then return end
	if IsValid(victimPanel) then victimPanel:MakePopup() return end
	if IsValid(reopenPrompt) then reopenPrompt:Remove() reopenPrompt = nil end
	local colors = DRP.UI.Colors
	local frame = DRP.UI.Frame("MUGGING DEMAND", 610, 390)
	victimPanel = frame
	frame:SetDeleteOnClose(true)

	local accent = vgui.Create("DPanel", frame)
	accent:SetPos(28, 82) accent:SetSize(frame:GetWide() - 56, 116)
	accent.Paint = function(_, width, height)
		draw.RoundedBox(8, 0, 0, width, height, colors.panel)
		draw.RoundedBoxEx(8, 0, 0, 6, height, colors.red, true, false, true, false)
		draw.SimpleText("DEMANDED BY " .. string.upper(notice.other), "DRP.Admin.Small", 22, 22, colors.red, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("$" .. string.Comma(notice.amount), "DRP.Admin.Title", 22, 57, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(math.max(0, math.ceil(notice.expires - RealTime())) .. " SECONDS REMAIN", "DRP.Admin.Header", width - 22, 57, colors.accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		draw.SimpleText("Paying drops reserved physical cash. Refusing or timing out leaves the incident active.", "DRP.Admin.Small", 22, 91, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local warning = vgui.Create("DLabel", frame)
	warning:SetPos(28, 214) warning:SetSize(frame:GetWide() - 56, 50)
	warning:SetFont("DRP.Admin.Body") warning:SetTextColor(colors.muted) warning:SetWrap(true)
	warning:SetText("Moving, changing weapons or attacking escalates the mugging to mutual PvP. You may close this panel and reopen it from the HUD before the timer expires.")

	local pay = DRP.UI.Button(frame, "DROP $" .. string.Comma(notice.amount), colors.green)
	pay.DoClick = function()
		net.Start(actionMessage) net.WriteUInt(DRP.ProtocolVersion, 8) net.WriteUInt(1, 2) net.SendToServer()
		pay:SetEnabled(false)
	end
	pay:SetPos(28, 292) pay:SetSize(330, 48)
	local cancel = DRP.UI.Button(frame, "CANCEL / DECIDE LATER", colors.panelHover, function() frame:Close() end)
	cancel:SetPos(370, 292) cancel:SetSize(frame:GetWide() - 398, 48)

	frame.OnClose = function(self)
		if self.DRPReopenQueued or self.DRPResolved or not notice or notice.state ~= 1 or notice.expires <= RealTime() then return end
		self.DRPReopenQueued = true
		timer.Simple(0, showReopenPrompt)
	end
	frame.OnRemove = function(self)
		if victimPanel == self then victimPanel = nil end
		self:OnClose()
	end
end

function DRP.MuggingClient.ShouldHideObjectives()
	return IsValid(reopenPrompt)
end

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
	if state == 1 and isVictim then
		timer.Simple(0, openVictimPanel)
	else
		clearVictimUI()
	end
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
