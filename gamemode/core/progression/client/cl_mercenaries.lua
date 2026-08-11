DRP.MercenaryMission = DRP.MercenaryMission or nil

net.Receive("drp_mercenary_sync_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not net.ReadBool() then
		DRP.MercenaryMission = nil
		return
	end
	DRP.MercenaryMission = {
		id = net.ReadUInt(32),
		tier = net.ReadUInt(2),
		property = net.ReadString(),
		position = net.ReadVector(),
		remaining = net.ReadUInt(8),
		total = net.ReadUInt(8),
		deadline = net.ReadFloat()
	}
end)

surface.CreateFont("DRP.Mercenary.Title", { font = "Roboto", size = 20, weight = 900, antialias = true })
surface.CreateFont("DRP.Mercenary.Body", { font = "Roboto", size = 15, weight = 700, antialias = true })

local tierColors = {
	Color(80, 210, 130),
	Color(255, 180, 65),
	Color(255, 80, 95)
}
local waypointBackground = Color(5, 14, 29, 228)
local waypointText = Color(225, 235, 245)

hook.Add("HUDPaint", "DRP.Mercenaries.Waypoint", function()
	local mission, ply = DRP.MercenaryMission, LocalPlayer()
	if not mission or not IsValid(ply) or not ply:Alive() or not isvector(mission.position) then return end
	local projected = mission.position:ToScreen()
	local x = math.Clamp(projected.x, 150, ScrW() - 150)
	local y = math.Clamp(projected.y, 120, ScrH() - 170)
	local distance = math.floor(ply:GetPos():Distance(mission.position) / 52.49)
	local remainingTime = math.max(0, math.ceil((mission.deadline or 0) - CurTime()))
	local accent = tierColors[mission.tier] or color_white
	draw.RoundedBox(7, x - 145, y - 32, 290, 64, waypointBackground)
	draw.RoundedBox(0, x - 145, y - 32, 5, 64, accent)
	draw.SimpleText("MERCENARY • " .. string.upper(mission.property), "DRP.Mercenary.Title", x - 130, y - 18, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText(string.format("%d/%d hostiles • %dm • %02d:%02d", mission.remaining, mission.total, distance, math.floor(remainingTime / 60), remainingTime % 60), "DRP.Mercenary.Body", x - 130, y + 10, waypointText, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
end)
