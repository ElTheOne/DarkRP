local effects = {
	{ key = "heroin", name = "HEROIN", color = Color(175, 105, 210) },
	{ key = "speed", name = "SPEED", color = Color(245, 190, 70) },
	{ key = "weed", name = "WEED", color = Color(90, 205, 115) },
	{ key = "pcp", name = "PCP", color = Color(80, 185, 220) },
	{ key = "crack", name = "CRACK", color = Color(230, 100, 90) },
	{ key = "fentanyl", name = "FENTANYL", color = Color(115, 135, 175) },
	{ key = "cocaine", name = "COCAINE", color = Color(235, 235, 245) }
}

local weedColor = {
	["$pp_colour_addr"] = 0.01,
	["$pp_colour_addg"] = 0.025,
	["$pp_colour_addb"] = 0.005,
	["$pp_colour_brightness"] = -0.015,
	["$pp_colour_contrast"] = 1.04,
	["$pp_colour_colour"] = 1.22,
	["$pp_colour_mulr"] = 0,
	["$pp_colour_mulg"] = 0.015,
	["$pp_colour_mulb"] = 0
}
local statusRows = {}
local nextStatusRefresh = 0
local visualState = { nextRefresh = 0, weed = false, fentanyl = false, cocaine = false }

local function refreshVisualState(ply, now)
	if now < visualState.nextRefresh then return end
	visualState.nextRefresh = now + 0.1
	visualState.weed = ply:GetNW2Float("DRPDrug_weed", 0) > now
	visualState.fentanyl = ply:GetNW2Float("DRPDrug_fentanyl", 0) > now
	visualState.cocaine = ply:GetNW2Float("DRPDrug_cocaine", 0) > now
end

local function drawDrugVisuals()
	local ply = LocalPlayer()
	if not IsValid(ply) then hook.Remove("RenderScreenspaceEffects", "DRP.Drugs.Visuals") return end
	local now = CurTime()
	refreshVisualState(ply, now)
	if not visualState.weed and not visualState.fentanyl and not visualState.cocaine then
		hook.Remove("RenderScreenspaceEffects", "DRP.Drugs.Visuals")
		return
	end
	if visualState.weed then
		DrawColorModify(weedColor)
		DrawMotionBlur(0.08, 0.28, 0.01)
	end
	if visualState.fentanyl then
		DrawMotionBlur(0.32, 0.94, 0.015)
	end
	if visualState.cocaine then
		DrawSharpen(1.2, 0.65)
	end
end

local function enableDrugVisuals(entity, key)
	if entity ~= LocalPlayer() or not string.StartWith(tostring(key or ""), "DRPDrug_") then return end
	visualState.nextRefresh = 0
	hook.Add("RenderScreenspaceEffects", "DRP.Drugs.Visuals", drawDrugVisuals)
end

hook.Add("EntityNetworkedVarChanged", "DRP.Drugs.VisualState", enableDrugVisuals)
hook.Add("InitPostEntity", "DRP.Drugs.VisualState", function()
	visualState.nextRefresh = 0
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	refreshVisualState(ply, CurTime())
	if visualState.weed or visualState.fentanyl or visualState.cocaine then
		hook.Add("RenderScreenspaceEffects", "DRP.Drugs.Visuals", drawDrugVisuals)
	end
end)

hook.Add("HUDPaint", "DRP.Drugs.Status", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local now = CurTime()
	if now >= nextStatusRefresh then
		nextStatusRefresh = now + 0.25
		table.Empty(statusRows)
		for _, definition in ipairs(effects) do
			local deadline = ply:GetNW2Float("DRPDrug_" .. definition.key, 0)
			if deadline > now then statusRows[#statusRows + 1] = { name = definition.name, deadline = deadline, color = definition.color } end
		end
		local speedWithdrawal = ply:GetNW2Float("DRPDrug_speed_withdrawal", 0)
		if speedWithdrawal > now and ply:GetNW2Float("DRPDrug_speed", 0) <= now then statusRows[#statusRows + 1] = { name = "SPEED WITHDRAWAL", deadline = speedWithdrawal, color = DRP.UI.Colors.red } end
		local crackWithdrawal = ply:GetNW2Float("DRPDrug_crack_withdrawal", 0)
		if crackWithdrawal > now and ply:GetNW2Float("DRPDrug_crack", 0) <= now then statusRows[#statusRows + 1] = { name = "CRACK WITHDRAWAL", deadline = crackWithdrawal, color = DRP.UI.Colors.red } end
		if ply:GetNW2Bool("DRPHeroinWithdrawal", false) then statusRows[#statusRows + 1] = { name = "HEROIN WITHDRAWAL", color = DRP.UI.Colors.red } end
	end

	local width, rowHeight = 230, 27
	local x, y = ScrW() - width - 24, ScrH() * 0.38
	for index, row in ipairs(statusRows) do
		local top = y + (index - 1) * (rowHeight + 5)
		draw.RoundedBox(6, x, top, width, rowHeight, Color(12, 16, 24, 225))
		draw.RoundedBoxEx(6, x, top, 4, rowHeight, row.color, true, false, true, false)
		draw.SimpleText(row.name, "DRP.Admin.Small", x + 13, top + rowHeight * 0.5, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(row.deadline and string.FormattedTime(math.ceil(math.max(0, row.deadline - now)), "%02i:%02i") or "ACTIVE", "DRP.Admin.Small", x + width - 10, top + rowHeight * 0.5, row.color, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end

	local forceEnd = ply:GetNW2Float("DRPForceFeedEnd", 0)
	local target = ply:GetNW2Entity("DRPForceFeedTarget")
	if forceEnd > now and IsValid(target) then
		local progress = 1 - math.Clamp((forceEnd - now) / 3, 0, 1)
		local barWidth, barX, barY = 360, ScrW() * 0.5 - 180, ScrH() * 0.68
		draw.RoundedBox(7, barX, barY, barWidth, 44, Color(12, 16, 24, 235))
		draw.RoundedBox(4, barX + 8, barY + 29, (barWidth - 16) * progress, 7, DRP.UI.Colors.accent)
		draw.SimpleText("FORCE-FEEDING " .. string.upper(target:DRPName()), "DRP.Admin.Body", ScrW() * 0.5, barY + 16, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
end)
