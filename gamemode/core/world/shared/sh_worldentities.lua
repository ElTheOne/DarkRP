DRP.AllowedToolModes = DRP.AllowedToolModes or {
	-- Complete stock Sandbox Tool Gun suite. The example stool is deliberately
	-- omitted because it is developer documentation rather than a usable tool.
	axis = true, balloon = true, ballsocket = true, button = true,
	camera = true, colour = true, creator = true, duplicator = true,
	dynamite = true, editentity = true, elastic = true, emitter = true,
	eyeposer = true, faceposer = true, finger = true, hoverball = true,
	hydraulic = true, inflator = true, lamp = true, leafblower = true,
	light = true, material = true, motor = true, muscle = true,
	nocollide = true, paint = true, physprop = true, pulley = true,
	remover = true, rope = true, slider = true, thruster = true,
	trails = true, weld = true, wheel = true, winch = true,
	-- Building extensions are shown only when their addon has registered the
	-- corresponding stool. Ownership is still enforced by CanTool server-side.
	advballsocket = true, precision = true, easy_precision = true,
	stacker_improved = true, parent = true, multi_parent = true, advdupe2 = true,
	mediaplayer_spatial = true, mediaplayer_mimic = true,
	drp_property_zone = true
}
DRP.AllowedToolModes.stacker = nil
DRP.AllowedToolModes.stacker_improved = true

-- The custom spawn menu uses this manifest as a deterministic fallback. That
-- keeps the stock suite visible before a live gmod_tool instance exists while
-- addon-provided tools still have to register normally.
DRP.BuiltinToolModes = DRP.BuiltinToolModes or {
	axis = "Constraints", ballsocket = "Constraints", elastic = "Constraints",
	hydraulic = "Constraints", motor = "Constraints", muscle = "Constraints",
	nocollide = "Constraints", pulley = "Constraints", rope = "Constraints",
	slider = "Constraints", weld = "Constraints", winch = "Constraints",
	balloon = "Construction", button = "Construction", creator = "Construction",
	dynamite = "Construction", emitter = "Construction", hoverball = "Construction",
	lamp = "Construction", light = "Construction", thruster = "Construction",
	wheel = "Construction",
	camera = "Render", colour = "Render", material = "Render", paint = "Render",
	trails = "Render",
	editentity = "Posing", eyeposer = "Posing", faceposer = "Posing",
	finger = "Posing", inflator = "Posing", physprop = "Posing",
	duplicator = "Tools", leafblower = "Tools", remover = "Tools",
	precision = "Construction", stacker_improved = "Construction",
	mediaplayer_spatial = "Media Player", mediaplayer_mimic = "Media Player",
	drp_property_zone = "DarkRP Server"
}
DRP.BuiltinToolModes.stacker = nil
DRP.BuiltinToolModes.stacker_improved = "Construction"

DRP.ToolPasteModes = DRP.ToolPasteModes or {
	duplicator = true,
	advdupe2 = true
}

DRP.ToolPropSpawnModes = DRP.ToolPropSpawnModes or {
	creator = true,
	duplicator = true,
	advdupe2 = true,
	stacker_improved = true
}
DRP.ToolPropSpawnModes.stacker = nil
DRP.ToolPropSpawnModes.stacker_improved = true

-- Stock gmod_tool calls gamemode.Call("CanTool") in both realms before it
-- invokes any stool action. Our server-side CanTool hooks still run first and
-- may deny ownership/property violations; this method supplies the required
-- final allow result that Sandbox normally contributes through inheritance.
function GM:CanTool(ply, trace, mode, tool, button)
	if not IsValid(ply) or not ply:IsPlayer() then return false end
	mode = string.lower(tostring(mode or ""))
	if mode == "" then return false end
	if SERVER and isfunction(ply.DRPReady) and not ply:DRPReady() then return false end

	local sandbox = self.BaseClass
	if sandbox and isfunction(sandbox.CanTool) then
		return sandbox.CanTool(self, ply, trace, mode, tool, button)
	end
	return true
end

local tool = {
	Base = "weapon_base",
	PrintName = "Persistent Entity Tool",
	Author = "UltraRP",
	Instructions = "Left click: persist aimed entity. Right click: stop persisting it. Reload: save its current transform.",
	Spawnable = false,
	AdminOnly = true,
	UseHands = true,
	ViewModel = "models/weapons/c_toolgun.mdl",
	WorldModel = "models/weapons/w_toolgun.mdl",
	HoldType = "revolver",
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
}

function tool:Initialize() self:SetHoldType("revolver") end
function tool:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 0.35)
	if SERVER and DRP.WorldEntities then DRP.WorldEntities:PersistAimed(self:GetOwner()) end
end
function tool:SecondaryAttack()
	self:SetNextSecondaryFire(CurTime() + 0.35)
	if SERVER and DRP.WorldEntities then DRP.WorldEntities:UnpersistAimed(self:GetOwner()) end
end
function tool:Reload()
	if self.DRPNextReload and self.DRPNextReload > CurTime() then return end
	self.DRPNextReload = CurTime() + 0.35
	if SERVER and DRP.WorldEntities then DRP.WorldEntities:PersistAimed(self:GetOwner(), true) end
end

weapons.Register(tool, "weapon_drp_persistence_tool")
