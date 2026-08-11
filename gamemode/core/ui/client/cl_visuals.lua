-- A light white-balance pass for maps with warm baked lighting. This runs as a
-- screenspace grade, so it changes the world image without tinting the HUD.
local enabled = CreateClientConVar(
	"drp_neutral_lighting",
	"1",
	true,
	false,
	"Use the DarkRP neutral lighting grade"
)

-- A color-modify pass touches the entire framebuffer every frame. It is purely
-- cosmetic, so the performance profile keeps it off by default while leaving
-- incident/drug effects authoritative and available. Players who prefer the
-- grade can opt in without restarting.
local cosmeticPostprocess = CreateClientConVar(
	"drp_client_cosmetic_postprocess",
	"0",
	true,
	false,
	"Allow optional DarkRP cosmetic full-screen post processing"
)

local strength = CreateClientConVar(
	"drp_neutral_lighting_strength",
	"1",
	true,
	false,
	"Strength of the DarkRP neutral lighting grade",
	0,
	1
)

local grade = {
	["$pp_colour_addr"] = -0.008,
	["$pp_colour_addg"] = 0.002,
	["$pp_colour_addb"] = 0.018,
	["$pp_colour_brightness"] = 0.004,
	["$pp_colour_contrast"] = 1.025,
	["$pp_colour_colour"] = 0.97,
	["$pp_colour_mulr"] = -0.025,
	["$pp_colour_mulg"] = 0,
	["$pp_colour_mulb"] = 0.035,
	["$pp_colour_inv"] = 0
}

local neutral = {
	["$pp_colour_addr"] = 0,
	["$pp_colour_addg"] = 0,
	["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0,
	["$pp_colour_contrast"] = 1,
	["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0,
	["$pp_colour_mulg"] = 0,
	["$pp_colour_mulb"] = 0,
	["$pp_colour_inv"] = 0
}

local output = {}

local function drawNeutralLighting()
	if not DrawColorModify then return end
	local amount = math.Clamp(strength:GetFloat(), 0, 1)
	if amount <= 0 then return end

	for key, value in pairs(grade) do
		output[key] = Lerp(amount, neutral[key], value)
	end

	DrawColorModify(output)
end

local function updateNeutralLightingHook()
	if cosmeticPostprocess:GetBool() and enabled:GetBool() then
		hook.Add("RenderScreenspaceEffects", "DRP.NeutralLighting", drawNeutralLighting)
	else
		hook.Remove("RenderScreenspaceEffects", "DRP.NeutralLighting")
	end
end

cvars.AddChangeCallback("drp_client_cosmetic_postprocess", updateNeutralLightingHook, "DRP.NeutralLighting")
cvars.AddChangeCallback("drp_neutral_lighting", updateNeutralLightingHook, "DRP.NeutralLighting")
updateNeutralLightingHook()

-- ARC9's full render-target scope path can display an error texture over the
-- entire screen when a client cannot compile one of its scope shaders or RT
-- materials. ARC9's performance setting still executes its RT reticle pass, so
-- safe mode disables only ARC9's RT rendering hooks while preserving ordinary ADS
-- zoom and weapon handling. The client settings remain forced as a second safeguard.
DRP = DRP or {}
DRP.ARC9ScopeCompatibility = DRP.ARC9ScopeCompatibility or {}

local arc9ScopeCompatibility = DRP.ARC9ScopeCompatibility
local arc9ScopeSettings = {
	arc9_cheapscopes = "1",
	arc9_fx_rtvm = "0",
	arc9_fx_rt_fxaa = "0",
	arc9_fx_rt_shader = "0",
	arc9_fx_rt_alwaysdraw = "0"
}

function arc9ScopeCompatibility.Apply()
	local ready = true

	for name, wanted in pairs(arc9ScopeSettings) do
		local convar = GetConVar(name)
		if not convar then
			ready = false
		elseif convar:GetString() ~= wanted then
			RunConsoleCommand(name, wanted)
		end
	end

	return ready
end

local riskyScopeHooks = {
	{ event = "PreRender", identifier = "ARC9_PreRender" },
	{ event = "PreDrawViewModels", identifier = "ARC9_PreDrawViewModels" },
	{ event = "RenderScreenspaceEffects", identifier = "ARC9_PostDrawViewModels" }
}

local function disableARC9RenderTargetScopes()
	for _, definition in ipairs(riskyScopeHooks) do
		hook.Remove(definition.event, definition.identifier)
	end

	if istable(ARC9) then
		ARC9.RTScopeRender = false
	end

	local player = LocalPlayer()
	if not IsValid(player) then return end
	local weapon = player:GetActiveWeapon()
	if not IsValid(weapon) or not weapon.ARC9 then return end

	weapon.RenderingRTScope = false
	if IsValid(weapon.RTScopeModel) then
		weapon.RTScopeModel.RTScopeDrawingRN = false
	end
end

local function applyARC9ScopeCompatibility()
	arc9ScopeCompatibility.Apply()
	disableARC9RenderTargetScopes()
end

-- Some Windows clients can load ARC9's Lua while the optic model/material
-- content is missing or compiled incorrectly. At full ADS that broken optic
-- occupies most of the screen. Hide only the first-person weapon model while
-- an RT optic is being used and draw a neutral reticle over ARC9's normal
-- camera zoom. Iron sights and hip-fire weapon rendering remain untouched.
local scopeCacheFrame = -1
local scopeCacheWeapon
local function activeARC9Scope()
	local frame = FrameNumber()
	if scopeCacheFrame == frame then return scopeCacheWeapon end
	scopeCacheFrame, scopeCacheWeapon = frame, nil
	local player = LocalPlayer()
	if not IsValid(player) or player:ShouldDrawLocalPlayer() then return end

	local weapon = player:GetActiveWeapon()
	if not IsValid(weapon) or not weapon.ARC9
		or not isfunction(weapon.IsUsingRTScope) then return end

	local ok, scoped = pcall(weapon.IsUsingRTScope, weapon)
	if not ok or not scoped then return end
	scopeCacheWeapon = weapon
	return scopeCacheWeapon
end

hook.Add("PreDrawViewModel", "DRP.ARC9SafeADSViewModel", function(_, _, weapon)
	local scopedWeapon = activeARC9Scope()
	if IsValid(scopedWeapon) and scopedWeapon == weapon then return true end
end)

hook.Add("HUDPaint", "DRP.ARC9SafeADSReticle", function()
	if not IsValid(activeARC9Scope()) then return end

	local x, y = math.floor(ScrW() * 0.5), math.floor(ScrH() * 0.5)
	local gap = math.max(4, math.floor(ScrH() * 0.004))
	local length = math.max(7, math.floor(ScrH() * 0.008))

	surface.SetDrawColor(0, 0, 0, 210)
	surface.DrawLine(x - gap - length - 1, y + 1, x - gap + 1, y + 1)
	surface.DrawLine(x + gap - 1, y + 1, x + gap + length + 1, y + 1)
	surface.DrawLine(x + 1, y - gap - length - 1, x + 1, y - gap + 1)
	surface.DrawLine(x + 1, y + gap - 1, x + 1, y + gap + length + 1)

	surface.SetDrawColor(235, 248, 255, 245)
	surface.DrawLine(x - gap - length, y, x - gap, y)
	surface.DrawLine(x + gap, y, x + gap + length, y)
	surface.DrawLine(x, y - gap - length, x, y - gap)
	surface.DrawLine(x, y + gap, x, y + gap + length)
	surface.DrawRect(x, y, 1, 1)
end)

hook.Add("InitPostEntity", "DRP.ARC9ScopeCompatibility", function()
	timer.Simple(0, applyARC9ScopeCompatibility)
	-- ARC9 can recreate its hooks after a clientside reload or settings reset.
	-- Reassert safe ADS mode cheaply instead of letting the broken RT remain active.
		timer.Create("DRP.ARC9ScopeCompatibility", 2, 15, applyARC9ScopeCompatibility)
end)

hook.Add("OnReloaded", "DRP.ARC9ScopeCompatibility", function()
	timer.Simple(0, applyARC9ScopeCompatibility)
end)

timer.Simple(0, applyARC9ScopeCompatibility)

concommand.Add("drp_arc9_scope_status", function()
	print("[DRP ARC9] scope compatibility")
	print("  non_rt_viewmodel_fallback=true")
	for name, wanted in SortedPairs(arc9ScopeSettings) do
		local convar = GetConVar(name)
		print(string.format(
			"  %s=%s expected=%s",
			name,
			convar and convar:GetString() or "missing",
			wanted
		))
	end

	for _, definition in ipairs(riskyScopeHooks) do
		local installed = hook.GetTable()[definition.event]
			and hook.GetTable()[definition.event][definition.identifier] ~= nil
		print(string.format(
			"  hook %s/%s active=%s expected=false",
			definition.event,
			definition.identifier,
			tostring(installed)
		))
	end

	for _, path in ipairs({
		"effects/arc9/rt",
		"effects/arc9/rt_cheap",
		"effects/arc9/rt_cheap_sharpen"
	}) do
		local material = Material(path)
		print(string.format("  material %s error=%s", path, tostring(material:IsError())))
	end
end)
