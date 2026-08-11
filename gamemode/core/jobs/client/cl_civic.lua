local panel = Color(9, 15, 28, 232)
local muted = Color(164, 177, 199)
local positive = Color(75, 224, 149)
local neutral = Color(74, 205, 255)
local negative = Color(242, 88, 109)
local fringe = Color(244, 151, 72)
local barBackground = Color(26, 37, 59, 255)
local smoothedStanding
local hudEnabled = GetConVar("drp_hud_enabled")

surface.CreateFont("DRP.Civic.Title", { font = "Roboto", size = 13, weight = 900 })
surface.CreateFont("DRP.Civic.Value", { font = "Roboto", size = 16, weight = 800 })

local function standingLabel(value)
	if value <= -750 then return "NOTORIOUS", negative end
	if value <= -400 then return "CRIMINAL", negative end
	if value <= -150 then return "FRINGE", fringe end
	if value < 150 then return "NEUTRAL", neutral end
	if value < 400 then return "UPSTANDING", positive end
	if value < 750 then return "EXEMPLARY", positive end
	return "CIVIC PILLAR", positive
end

hook.Add("PostDrawHUD", "DRP.Civic.HUD", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:DRPReady() then return end
	if hudEnabled and not hudEnabled:GetBool() then return end
	local value = math.Clamp(DRP.Roster and DRP.Roster.Value(ply, "civic", 0) or 0, -1000, 1000)
	if smoothedStanding == nil then smoothedStanding = value end
	smoothedStanding = Lerp(math.Clamp(FrameTime() * 7, 0, 1), smoothedStanding, value)
	local label, color = standingLabel(value)
	local width, height = 286, 72
	-- The playtime card occupies x=24, y=22, h=76. Keep civic identity in the
	-- same left-hand HUD column with a clean eight-pixel gap beneath it.
	local x, y = 24, 106
	draw.RoundedBox(10, x, y, width, height, panel)
	draw.RoundedBoxEx(10, x, y, 5, height, color, true, false, true, false)
	draw.SimpleText("CIVIC REPUTATION", "DRP.Civic.Title", x + 18, y + 17, muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText(label, "DRP.Civic.Title", x + width - 18, y + 17, color, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	local barX, barY, barW, barH = x + 18, y + 34, width - 36, 20
	draw.RoundedBox(6, barX, barY, barW, barH, barBackground)
	local fraction = math.Clamp((smoothedStanding + 1000) / 2000, 0, 1)
	draw.RoundedBox(6, barX + 1, barY + 1, math.max(2, (barW - 2) * fraction), barH - 2, color)
	surface.SetDrawColor(255, 255, 255, 90)
	surface.DrawRect(barX + math.floor(barW * 0.5), barY + 3, 1, barH - 6)
	draw.SimpleText((value > 0 and "+" or "") .. value, "DRP.Civic.Value", barX + barW * 0.5, barY + barH * 0.5, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)
