TOOL.Category = "DarkRP Server"
TOOL.Name = "Property Build Zones"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.Information = {
	{ name = "left", stage = 0 },
	{ name = "left_1", stage = 1 },
	{ name = "left_2", stage = 2 },
	{ name = "left_3", stage = 3 },
	{ name = "left_4", stage = 4 },
	{ name = "right" },
	{ name = "reload" }
}

if CLIENT then
	language.Add("tool.drp_property_zone.name", "Property Build Zones")
	language.Add("tool.drp_property_zone.desc", "Create persistent property volumes from four base corners and one height selection.")
	language.Add("tool.drp_property_zone.left", "Select base corner 1/4")
	language.Add("tool.drp_property_zone.left_1", "Select base corner 2/4 in perimeter order")
	language.Add("tool.drp_property_zone.left_2", "Select base corner 3/4 in perimeter order")
	language.Add("tool.drp_property_zone.left_3", "Select base corner 4/4 in perimeter order")
	language.Add("tool.drp_property_zone.left_4", "Select the vertical height and save the box")
	language.Add("tool.drp_property_zone.right", "Remove the build box containing the aimed point")
	language.Add("tool.drp_property_zone.reload", "Cancel all pending selections")
end

local function validTrace(trace)
	return trace and trace.Hit and not trace.HitSky and isvector(trace.HitPos)
end

function TOOL:LeftClick(trace)
	if not validTrace(trace) then return false end
	if CLIENT then return true end
	local ply = self:GetOwner()
	if not DRP.Properties or not DRP.Properties.ZoneToolLeft then return false end
	local success = DRP.Properties:ZoneToolLeft(ply, trace.HitPos)
	local pending = success and IsValid(ply) and ply.DRPPropertyZonePoints or nil
	self:SetStage(istable(pending) and math.Clamp(#pending, 0, 4) or 0)
	return success
end

function TOOL:RightClick(trace)
	if not validTrace(trace) then return false end
	if CLIENT then return true end
	if not DRP.Properties or not DRP.Properties.ZoneToolRight then return false end
	local success = DRP.Properties:ZoneToolRight(self:GetOwner(), trace.HitPos)
	self:SetStage(0)
	return success
end

function TOOL:Reload()
	if CLIENT then return true end
	if not DRP.Properties or not DRP.Properties.ZoneToolReload then return false end
	local success = DRP.Properties:ZoneToolReload(self:GetOwner())
	self:SetStage(0)
	return success
end

function TOOL:Holster()
	self:SetStage(0)
end

function TOOL.BuildCPanel(panel)
	panel:Help("Select a property from F4 -> Properties before using this tool.")
	panel:Help("LEFT CLICK 1-4: select each base corner in order around the perimeter.")
	panel:Help("LEFT CLICK 5: aim at the desired vertical height and save the box.")
	panel:Help("RIGHT CLICK: remove the smallest box containing the aimed point.")
	panel:Help("RELOAD: cancel all pending selections.")
	panel:Help("Complex bases can use up to 32 separate boxes.")
end
