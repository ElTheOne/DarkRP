TOOL.DRPBundledVersion = "workshop-264467687-native2"
local mode = TOOL.Mode -- defined by the name of this file (default should be stacker_improved)




local L = localify.Localize                                   -- used for translating string tokens into localized phrases
local prefix = "#tool."..mode.."."                            -- prefix used for this tool's localization tokens


improvedstacker.Initialize( mode )





local bit = bit
local cam = cam
local net = net
local util = util
local math = math
local undo = undo
local halo = halo
local game = game
local ents = ents
local draw = draw
local hook = hook
local list = list
local pairs = pairs
local table = table
local Angle = Angle
local Color = Color
local render = render
local Vector = Vector
local tobool = tobool
local CurTime = CurTime
local surface = surface
local IsValid = IsValid
local localify = localify
local language = language
local tonumber = tonumber
local GetConVar = GetConVar
local construct = construct
local duplicator = duplicator
local constraint = constraint
local concommand = concommand
local LocalPlayer = LocalPlayer
local CreateConVar = CreateConVar
local improvedstacker = improvedstacker
local GetConVarNumber = GetConVarNumber
local RunConsoleCommand = RunConsoleCommand

local IN_USE = IN_USE
local NOTIFY_ERROR = NOTIFY_ERROR or 1
local MOVETYPE_NONE = MOVETYPE_NONE
local SOLID_VPHYSICS = SOLID_VPHYSICS
local RENDERMODE_TRANSALPHA = RENDERMODE_TRANSALPHA

local TRANSPARENT = Color( 255, 255, 255, 150 )

local MIN_NOTIFY_BITS = 3 -- the minimum number of bits needed to send a NOTIFY enum
local NOTIFY_DURATION = 5 -- the number of seconds to display notifications

local MAX_ANGLE = 180

local showSettings = false



TOOL.Category = "Construction"
TOOL.Name     = L(prefix.."name")

TOOL.Information = {
	"left",
	"right",
	{ 
		name  = "shift_left",
		icon2  = "gui/e.png",
		icon = "gui/lmb.png",
		
	},
	{
		name  = "shift_right",
		icon2  = "gui/e.png",
		icon = "gui/rmb.png",
	},
	"reload",
}

if ( CLIENT ) then

	TOOL.ClientConVar[ "mode" ]          = improvedstacker.MODE_PROP
	TOOL.ClientConVar[ "direction" ]     = improvedstacker.DIRECTION_UP
	TOOL.ClientConVar[ "count" ]         = "1"
	TOOL.ClientConVar[ "freeze" ]        = "1"
	TOOL.ClientConVar[ "weld" ]          = "1"
	TOOL.ClientConVar[ "nocollide" ]     = "1"
	TOOL.ClientConVar[ "ghostall" ]      = "1"
	TOOL.ClientConVar[ "material" ]      = "1"
	TOOL.ClientConVar[ "physprop" ]      = "1"
	TOOL.ClientConVar[ "color" ]         = "1"
	TOOL.ClientConVar[ "offsetx" ]       = "0"
	TOOL.ClientConVar[ "offsety" ]       = "0"
	TOOL.ClientConVar[ "offsetz" ]       = "0"
	TOOL.ClientConVar[ "pitch" ]         = "0"
	TOOL.ClientConVar[ "yaw" ]           = "0"
	TOOL.ClientConVar[ "roll" ]          = "0"
	TOOL.ClientConVar[ "relative" ]      = "1"
	TOOL.ClientConVar[ "draw_halos" ]    = "0"
	TOOL.ClientConVar[ "halo_r" ]        = "255"
	TOOL.ClientConVar[ "halo_g" ]        = "0"
	TOOL.ClientConVar[ "halo_b" ]        = "0"
	TOOL.ClientConVar[ "halo_a" ]        = "255"
	TOOL.ClientConVar[ "draw_axis" ]     = "1"
	TOOL.ClientConVar[ "axis_labels" ]   = "1"
	TOOL.ClientConVar[ "axis_angles" ]   = "0"
	TOOL.ClientConVar[ "opacity" ]       = "100"
	TOOL.ClientConVar[ "use_shift_key" ] = "0"



	language.Add( "tool."..mode..".name",         L(prefix.."name") )
	language.Add( "tool."..mode..".desc",         L(prefix.."desc") )

	language.Add( "tool."..mode..".left",         L(prefix.."left") )
	language.Add( "tool."..mode..".shift_left",   L(prefix.."shift_left") )
	language.Add( "tool."..mode..".right",        L(prefix.."right") )
	language.Add( "tool."..mode..".shift_right",  L(prefix.."shift_right") )
	language.Add( "tool."..mode..".reload",       L(prefix.."reload") )
	language.Add( "Undone_"..mode,                L("Undone_"..mode) )
	

	

	net.Receive( mode.."_error", function( bytes )
		surface.PlaySound( "buttons/button10.wav" )
		notification.AddLegacy( net.ReadString(), net.ReadUInt(MIN_NOTIFY_BITS), NOTIFY_DURATION )
	end )
	
end







local cvarFlags, cvarFlagsNotify

if ( SERVER ) then
	cvarFlags      = bit.bor( FCVAR_REPLICATED, FCVAR_SERVER_CAN_EXECUTE, FCVAR_ARCHIVE )
	cvarFlagsNotif = bit.bor( cvarFlags, FCVAR_NOTIFY )
elseif ( CLIENT ) then
	cvarFlags      = bit.bor( FCVAR_REPLICATED, FCVAR_SERVER_CAN_EXECUTE, FCVAR_ARCHIVE )
	cvarFlagsNotif = bit.bor( cvarFlags, FCVAR_NOTIFY )
end

local oldMaxTotal    = CreateConVar( "stacker_max_total",        -1, cvarFlagsNotif, "Defines the max amount of props that a player can have spawned from stacker" )
local oldMaxCount    = CreateConVar( "stacker_max_count",        15, cvarFlagsNotif, "Defines the max amount of props that can be stacked at a time" )
local oldDelay       = CreateConVar( "stacker_delay",           0.5, cvarFlagsNotif, "Determines the amount of time that must pass before a player can use stacker again" )
local oldMaxOffX     = CreateConVar( "stacker_max_offsetx",     200, cvarFlagsNotif, "Defines the max distance on the x plane that stacked props can be offset (for individual control)" )
local oldMaxOffY     = CreateConVar( "stacker_max_offsety",     200, cvarFlagsNotif, "Defines the max distance on the y plane that stacked props can be offset (for individual control)" )
local oldMaxOffZ     = CreateConVar( "stacker_max_offsetz",     200, cvarFlagsNotif, "Defines the max distance on the z plane that stacked props can be offset (for individual control)" )
local oldFreeze      = CreateConVar( "stacker_force_freeze",      0, cvarFlagsNotif, "Determines whether props should be forced to spawn frozen or not" )
local oldWeld        = CreateConVar( "stacker_force_weld",        0, cvarFlagsNotif, "Determines whether props should be forced to spawn welded or not" )
local oldNoCollide   = CreateConVar( "stacker_force_nocollide",   0, cvarFlagsNotif, "Determines whether props should be forced to spawn nocollided or not" )
local oldStayInWorld = CreateConVar( "stacker_stayinworld",       1, cvarFlagsNotif, "Determines whether props should be restricted to spawning inside the world or not (addresses possible crashes)" )

local cvarMaxPerPlayer = CreateConVar( mode.."_max_per_player",      oldMaxTotal:GetInt(),    cvarFlags,      "Defines the max amount of props that a player can have spawned from stacker" )
local cvarMaxPerStack  = CreateConVar( mode.."_max_per_stack",       oldMaxCount:GetInt(),    cvarFlags,      "Defines the max amount of props that can be stacked at a time" )
local cvarDelay        = CreateConVar( mode.."_delay",               oldDelay:GetFloat(),     cvarFlags,      "Determines the amount of time that must pass before a player can use stacker again" )
local cvarMaxOffX      = CreateConVar( mode.."_max_offsetx",         oldMaxOffX:GetFloat(),   cvarFlags,      "Defines the max distance on the x plane that stacked props can be offset (for individual control)" )
local cvarMaxOffY      = CreateConVar( mode.."_max_offsety",         oldMaxOffY:GetFloat(),   cvarFlags,      "Defines the max distance on the y plane that stacked props can be offset (for individual control)" )
local cvarMaxOffZ      = CreateConVar( mode.."_max_offsetz",         oldMaxOffZ:GetFloat(),   cvarFlags,      "Defines the max distance on the z plane that stacked props can be offset (for individual control)" )
local cvarFreeze       = CreateConVar( mode.."_force_freeze",        oldFreeze:GetInt(),      cvarFlagsNotif, "Determines whether props should be forced to spawn frozen or not" )
local cvarWeld         = CreateConVar( mode.."_force_weld",          oldWeld:GetInt(),        cvarFlagsNotif, "Determines whether props should be forced to spawn welded or not" )
local cvarNoCollide    = CreateConVar( mode.."_force_nocollide",     oldNoCollide:GetInt(),   cvarFlagsNotif, "Determines whether props should be forced to spawn nocollided or not" )
local cvarNoCollideAll = CreateConVar( mode.."_force_nocollide_all", 0,                       cvarFlags,      "(EXPERIMENTAL, DISABLED) Determines whether props should be nocollide with everything except players, vehicles, and npcs" )
local cvarStayInWorld  = CreateConVar( mode.."_force_stayinworld",   oldStayInWorld:GetInt(), cvarFlagsNotif, "Determines whether props should be restricted to spawning inside the world or not (addresses possible crashes)" )



if ( CLIENT ) then
	
	concommand.Add( mode.."_reset_offsets", function( ply, cmd, args )

		RunConsoleCommand( mode.."_offsetx", "0.00" )
		RunConsoleCommand( mode.."_offsety", "0.00" )
		RunConsoleCommand( mode.."_offsetz", "0.00" )
	end	)
	
	concommand.Add( mode.."_reset_angles", function( ply, cmd, args )

		RunConsoleCommand( mode.."_pitch",   "0.00" )
		RunConsoleCommand( mode.."_yaw",     "0.00" )
		RunConsoleCommand( mode.."_roll",    "0.00" )
	end )
	
	concommand.Add( mode.."_reset_admin", function( ply, cmd, args )
		for cmd, val in pairs( improvedstacker.SETTINGS_DEFAULT ) do
			RunConsoleCommand( cmd, val )
		end
	end )
	
elseif ( SERVER ) then

	local function validateCommand( ply, cmd, arg )




		local result, reason = hook.Run( "StackerConVar", ply, cmd, arg )


		if ( IsValid( ply ) and result ~= true ) then

			if ( result == false )                     then
				ply:PrintMessage( HUD_PRINTTALK, L(prefix.."error_blocked_by_server", localify.GetLocale( ply )) .. (isstring(reason) and ": " .. reason or "") )
				return false
			end

			if ( result == nil and not ply:IsAdmin() ) then
				ply:PrintMessage( HUD_PRINTTALK, L(prefix.."error_not_admin", localify.GetLocale( ply )) .. ": " .. cmd )
				return false
			end
		end
		

		if ( not tonumber( arg ) ) then
			ply:PrintMessage( HUD_PRINTTALK, L(prefix.."error_invalid_argument", localify.GetLocale( ply )) )
			return false
		end
		
		return true
	end

	concommand.Add( mode.."_set_max_per_player", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_max_per_player", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_max_per_player", args[1] )
	end )

	concommand.Add( mode.."_set_max_per_stack", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_max_per_stack", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_max_per_stack", args[1] )
	end )

	concommand.Add( mode.."_set_max_offset", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_max_offset", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_max_offsetx", args[1] )
		RunConsoleCommand( mode.."_max_offsety", args[1] )
		RunConsoleCommand( mode.."_max_offsetz", args[1] )
	end )

	concommand.Add( mode.."_set_max_offsetx", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_max_offsetx", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_max_offsetx", args[1] )
	end )

	concommand.Add( mode.."_set_max_offsety", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_max_offsety", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_max_offsety", args[1] )
	end )

	concommand.Add( mode.."_set_max_offsetz", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_max_offsetz", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_max_offsetz", args[1] )
	end )

	concommand.Add( mode.."_set_force_stayinworld", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_force_stayinworld", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_force_stayinworld", tobool( args[1] ) and "1" or "0" )
	end )

	concommand.Add( mode.."_set_force_freeze", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_force_freeze", args[1] ) ) then return false end	
		RunConsoleCommand( mode.."_force_freeze", tobool( args[1] ) and "1" or "0" )
	end )

	concommand.Add( mode.."_set_force_weld", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_force_weld", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_force_weld", tobool( args[1] ) and "1" or "0" )
	end )

	concommand.Add( mode.."_set_force_nocollide", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_force_nocollide", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_force_nocollide", tobool( args[1] ) and "1" or "0" )
	end )

	concommand.Add( mode.."_set_force_nocollide_all", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_force_nocollide_all", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_force_nocollide_all", tobool( args[1] ) and "1" or "0" )
	end )

	concommand.Add( mode.."_set_delay", function( ply, cmd, args )
		if ( not validateCommand( ply, mode.."_set_delay", args[1] ) ) then return false end
		RunConsoleCommand( mode.."_delay", args[1] )
	end )

	
	util.AddNetworkString( mode.."_error" )


	function TOOL:SendError( str )		
		net.Start( mode.."_error" )
			net.WriteString( str )
			net.WriteUInt( NOTIFY_ERROR, MIN_NOTIFY_BITS )
		net.Send( self:GetOwner() )
	end

end




function TOOL:GetMaxPerPlayer()     return cvarMaxPerPlayer:GetInt() end
function TOOL:GetNumberPlayerEnts() return improvedstacker.GetEntCount( self:GetOwner(), 0 ) end


function TOOL:GetStackSize() return self:GetClientNumber( "count" ) end


function TOOL:GetMaxPerStack() return cvarMaxPerStack:GetInt() end


function TOOL:GetDirection()
	local direction = self:GetClientNumber( "direction" )
	return improvedstacker.Directions[ direction ] and direction or improvedstacker.DIRECTION_FRONT
end


function TOOL:GetStackerMode()
	local stackMode = self:GetClientNumber( "mode" )
	return improvedstacker.Modes[ stackMode ] and stackMode or improvedstacker.MODE_PROP
end


function TOOL:GetOffsetX()      return math.Clamp( self:GetClientNumber( "offsetx" ), -cvarMaxOffX:GetFloat(), cvarMaxOffX:GetFloat() ) end
function TOOL:GetOffsetY()      return math.Clamp( self:GetClientNumber( "offsety" ), -cvarMaxOffY:GetFloat(), cvarMaxOffY:GetFloat() ) end
function TOOL:GetOffsetZ()      return math.Clamp( self:GetClientNumber( "offsetz" ), -cvarMaxOffZ:GetFloat(), cvarMaxOffZ:GetFloat() ) end
function TOOL:GetOffsetVector() return Vector( self:GetOffsetX(), self:GetOffsetY(), self:GetOffsetZ() ) end


function TOOL:GetRotateP()     return math.Clamp( self:GetClientNumber( "pitch" ), -MAX_ANGLE, MAX_ANGLE ) end
function TOOL:GetRotateY()     return math.Clamp( self:GetClientNumber( "yaw" ),   -MAX_ANGLE, MAX_ANGLE ) end
function TOOL:GetRotateR()     return math.Clamp( self:GetClientNumber( "roll" ),  -MAX_ANGLE, MAX_ANGLE ) end
function TOOL:GetRotationAngle() return Angle( self:GetRotateP(), self:GetRotateY(), self:GetRotateR() ) end


function TOOL:ShouldApplyFreeze() return self:GetClientNumber( "freeze" ) == 1 end
function TOOL:ShouldForceFreeze() return cvarFreeze:GetBool() end

function TOOL:ShouldApplyWeld() return self:GetClientNumber( "weld" ) == 1 end
function TOOL:ShouldForceWeld() return cvarWeld:GetBool() end

function TOOL:ShouldApplyNoCollide() return self:GetClientNumber( "nocollide" ) == 1 end
function TOOL:ShouldForceNoCollide() return cvarNoCollide:GetBool() end

function TOOL:ShouldStackRelative() return self:GetClientNumber( "relative" ) == 1 end

function TOOL:ShouldGhostAll() return self:GetClientNumber( "ghostall" ) == 1 end


function TOOL:ShouldAddHalos() return self:GetClientNumber( "draw_halos" ) == 1 end
function TOOL:GetHaloR()       return math.Clamp( self:GetClientNumber( "halo_r" ), 0, 255 ) end
function TOOL:GetHaloG()       return math.Clamp( self:GetClientNumber( "halo_g" ), 0, 255 ) end
function TOOL:GetHaloB()       return math.Clamp( self:GetClientNumber( "halo_b" ), 0, 255 ) end
function TOOL:GetHaloA()       return math.Clamp( self:GetClientNumber( "halo_a" ), 0, 255 ) end
function TOOL:GetHaloColor()   return Color( self:GetHaloR(), self:GetHaloG(), self:GetHaloB(), self:GetHaloA() ) end


function TOOL:ShouldApplyMaterial() return self:GetClientNumber( "material" ) == 1 end


function TOOL:ShouldApplyColor() return self:GetClientNumber( "color" ) == 1 end


function TOOL:ShouldApplyPhysicalProperties() return self:GetClientNumber( "physprop" ) == 1 end


function TOOL:GetDelay() return cvarDelay:GetFloat() end


function TOOL:GetOpacity() return self:GetClientNumber( "opacity" ) end


function TOOL:GetUseShiftKey() return self:GetClientNumber( "use_shift_key" ) == 1 end



function TOOL:LeftClick( tr, isRightClick )
	local ply = self:GetOwner()
	

	if ( ply:KeyDown( IN_USE ) or (self:GetUseShiftKey() and ply:KeyDown( IN_SPEED )) ) then
		if ( CLIENT ) then return false end

		local newCount = self:GetStackSize() >= self:GetMaxPerStack() and self:GetMaxPerStack() or self:GetStackSize() + 1
		ply:ConCommand( mode.."_count "..newCount )
		return false
	end

	if ( not IsValid( tr.Entity ) or tr.Entity:GetClass() ~= "prop_physics" ) then return false end
	if ( CLIENT ) then return true end
	

	local count = (isRightClick and 1) or self:GetStackSize()

	local maxCount = hook.Run( "StackerMaxPerStack", ply, count, isRightClick ) or self:GetMaxPerStack()


	if ( maxCount >= 0 ) then
		if ( count > maxCount ) then self:SendError( L(prefix.."error_max_per_stack", localify.GetLocale( self:GetOwner() )) .. maxCount ) end
		count = math.Clamp( count, 0, maxCount )
	end
	

	local lastStackTime = improvedstacker.GetLastStackTime( ply, 0 )
	



	local delay = hook.Run( "StackerDelay", ply, lastStackTime ) or self:GetDelay()
	

	if ( lastStackTime + delay > CurTime() ) then self:SendError( L(prefix.."error_too_quick", localify.GetLocale( self:GetOwner() )) ) return false end
	improvedstacker.SetLastStackTime( ply, CurTime() )
	
	local stackDirection = self:GetDirection()
	local stackMode      = self:GetStackerMode()
	local stackOffset    = self:GetOffsetVector()
	local stackRotation  = self:GetRotationAngle()
	local stackRelative  = self:ShouldStackRelative()
	

	local stayInWorld   = cvarStayInWorld:GetBool()


	local ent = tr.Entity
	local entPos   = ent:GetPos()
	local entAng   = ent:GetAngles()
	local entMod   = ent:GetModel()
	local entSkin  = ent:GetSkin()
	local entMat   = ent:GetMaterial()
	local physMat  = ent:GetPhysicsObject():GetMaterial()
	local physGrav = ent:GetPhysicsObject():IsGravityEnabled()
	

	local colorData = {
		Color      = ent:GetColor(), 
		RenderMode = ent:GetRenderMode(), 
		RenderFX   = ent:GetRenderFX()
	}	
		
	local newEnt
	local newEnts = { ent }
	local lastEnt = ent
	
	local direction, offset

	local distance = improvedstacker.GetDistance( stackMode, stackDirection, ent )
	

	undo.Create( mode )
	

	local maxPerPlayer = hook.Run( "StackerMaxPerPlayer", ply, self:GetNumberPlayerEnts() ) or self:GetMaxPerPlayer()
	

	for i = 1, count do
		

		local stackerEntsSpawned = self:GetNumberPlayerEnts()
		if ( maxPerPlayer >= 0 and stackerEntsSpawned >= maxPerPlayer ) then self:SendError( ("%s (%s)"):format(L(prefix.."error_max_per_player", localify.GetLocale( self:GetOwner() )), maxPerPlayer) ) break end

		if ( not self:GetSWEP():CheckLimit( "props" ) )            then break end

		if ( hook.Run( "PlayerSpawnProp", ply, entMod ) == false ) then break end
		


		if ( i == 1 or ( stackMode == improvedstacker.MODE_PROP and stackRelative ) ) then
			direction = improvedstacker.GetDirection( stackMode, stackDirection, entAng )
			offset    = improvedstacker.GetOffset( stackMode, stackDirection, entAng, stackOffset )
		end


		entPos = entPos + (direction * distance) + offset

		improvedstacker.RotateAngle( stackMode, stackDirection, entAng, stackRotation )
		
		

		if ( stayInWorld and not util.IsInWorld( entPos ) ) then self:SendError( L(prefix.."error_not_in_world", localify.GetLocale( self:GetOwner() )) ) break end
		

		newEnt = ents.Create( "prop_physics" )
		newEnt:SetModel( entMod )
		newEnt:SetPos( entPos )
		newEnt:SetAngles( entAng )
		newEnt:SetSkin( entSkin )
		newEnt:Spawn()





		if ( not IsValid( newEnt ) or hook.Run( "StackerEntity", newEnt, ply ) ~= nil )             then break end
		if ( not IsValid( newEnt ) or hook.Run( "PlayerSpawnedProp", ply, entMod, newEnt ) ~= nil ) then break end



		

		improvedstacker.IncrementEntCount( ply )
		


		newEnt:CallOnRemove( "UpdateStackerTotal", function( ent, ply )

			if ( not IsValid( ply ) ) then return end
			improvedstacker.DecrementEntCount( ply )
		end, ply )
		
		self:ApplyMaterial( newEnt, entMat )
		self:ApplyColor( newEnt, colorData )
		self:ApplyFreeze( ply, newEnt )
		

		if ( not self:ApplyNoCollide( lastEnt, newEnt ) ) then
			newEnt:Remove()
			break
		end
		

		if ( not self:ApplyWeld( lastEnt, newEnt ) ) then
			newEnt:Remove()
			break
		end
		
		self:ApplyPhysicalProperties( ent, newEnt, tr.PhysicsBone, { GravityToggle = physGrav, Material = physMat } )
		
		lastEnt = newEnt
		table.insert( newEnts, newEnt )
		
		undo.AddEntity( newEnt )
		ply:AddCleanup( "props", newEnt )
	end
	
	newEnts = nil
	
	undo.SetPlayer( ply )
	undo.Finish()



	
	return true
end


function TOOL:RightClick( tr )
	local ply = self:GetOwner()


	if ( ply:KeyDown( IN_USE ) or (self:GetUseShiftKey() and ply:KeyDown( IN_SPEED )) ) then
		if ( CLIENT ) then return false end

		local count = self:GetStackSize()
		local newCount = (count <= 1 and 1) or count - 1
		ply:ConCommand( mode.."_count " .. newCount )
		return false
	else

		return self:LeftClick( tr, true )
	end
	
end


function TOOL:Reload()
	if ( CLIENT ) then return false end

	local ply = self:GetOwner()
	local direction = self:GetDirection()
	

	if ( direction == improvedstacker.DIRECTION_DOWN ) then
		direction = improvedstacker.DIRECTION_FRONT

	else
		direction = direction + 1
	end
	

	ply:ConCommand( mode.."_direction " .. direction )
	
	return false
end


function TOOL:ApplyMaterial( ent, material )
	if ( not self:ShouldApplyMaterial() ) then ent:SetMaterial( "" ) return end
	


	if ( not game.SinglePlayer() and not list.Contains( "OverrideMaterials", material ) and material ~= "" ) then return end

	ent:SetMaterial( material )
	duplicator.StoreEntityModifier( ent, "material", { MaterialOverride = material } )
end


function TOOL:ApplyColor( ent, data )
	if ( not self:ShouldApplyColor() ) then return end

	ent:SetColor( data.Color )
	ent:SetRenderMode( data.RenderMode )
	ent:SetRenderFX( data.RenderFX )
	
	duplicator.StoreEntityModifier( ent, "colour", table.Copy( data ) )
end


function TOOL:ApplyFreeze( ply, ent )
	if ( self:ShouldForceFreeze() or self:ShouldApplyFreeze() ) then
		ent:GetPhysicsObject():EnableMotion( false )
	else
		ent:GetPhysicsObject():Wake()
	end
end


function TOOL:ApplyWeld( lastEnt, newEnt )
	if ( not self:ShouldForceWeld() and not self:ShouldApplyWeld() ) then return true end
	
	local forceLimit    = 0
	local isNocollided  = self:ShouldForceNoCollide() or self:ShouldApplyNoCollide()
	local deleteOnBreak = false
	
	local ok, err = pcall( constraint.Weld, lastEnt, newEnt, 0, 0, forceLimit, isNocollided, deleteOnBreak )
	
	if ( not ok ) then
		print( mode .. ": " .. L(prefix.."error_max_constraints") .." (error: " .. err .. ")" )
		self:SendError( mode .. ": " .. L(prefix.."error_max_constraints", localify.GetLocale( self:GetOwner() )) )
	end
	
	return ok
end


function TOOL:ApplyNoCollide( lastEnt, newEnt )
	if ( not self:ShouldForceNoCollide() and not self:ShouldApplyNoCollide() ) then return true end


	if ( self:ShouldForceWeld() or self:ShouldApplyWeld() ) then return true end
	
	local ok, err = pcall( constraint.NoCollide, lastEnt, newEnt, 0, 0 )
	
	if ( not ok ) then
		print( mode .. ": " .. L(prefix.."error_max_constraints") .." (error: " .. err .. ")" )
		self:SendError( mode .. ": " .. L(prefix.."error_max_constraints", localify.GetLocale( self:GetOwner() )) )
	end
	
	return ok
end


function TOOL:ApplyPhysicalProperties( original, newEnt, boneID, properties )
	if ( not self:ShouldApplyPhysicalProperties() ) then return end
	
	if ( boneID ) then construct.SetPhysProp( nil, newEnt, boneID, nil, properties ) end
	newEnt:GetPhysicsObject():SetMass( original:GetPhysicsObject():GetMass() )
end

if ( CLIENT ) then
	



	local cvarTool       = GetConVar( "gmod_toolmode" )
	local cvarCount      = GetConVar( mode.."_count" )
	local cvarMode       = GetConVar( mode.."_mode" )
	local cvarDirection  = GetConVar( mode.."_direction" )
	local cvarOffsetX    = GetConVar( mode.."_offsetx" )
	local cvarOffsetY    = GetConVar( mode.."_offsety" )
	local cvarOffsetZ    = GetConVar( mode.."_offsetz" )
	local cvarPitch      = GetConVar( mode.."_pitch" )
	local cvarYaw        = GetConVar( mode.."_yaw" )
	local cvarRoll       = GetConVar( mode.."_roll" )
	local cvarRelative   = GetConVar( mode.."_relative" )
	local cvarMaterial   = GetConVar( mode.."_material" )
	local cvarColor      = GetConVar( mode.."_color" )
	local cvarGhostAll   = GetConVar( mode.."_ghostall" )
	local cvarOpacity    = GetConVar( mode.."_opacity" )
	local cvarHalo       = GetConVar( mode.."_draw_halos" )
	local cvarHaloR      = GetConVar( mode.."_halo_r" )
	local cvarHaloG      = GetConVar( mode.."_halo_g" )
	local cvarHaloB      = GetConVar( mode.."_halo_b" )
	local cvarHaloA      = GetConVar( mode.."_halo_a" )	
	local cvarHalo       = GetConVar( mode.."_draw_halos" )
	local cvarAxis       = GetConVar( mode.."_draw_axis" )
	local cvarAxisLbl    = GetConVar( mode.."_axis_labels" )
	local cvarAxisAng    = GetConVar( mode.."_axis_angles" )
	

	local o1 = Vector(     0, 0,  0.05 )
	local o2 = Vector(     0, 0, -0.05 )
	local o3 = Vector(  0.05, 0,     0 )
	local o4 = Vector( -0.05, 0,     0 )
	local ao = 2.5
	

	local RED   = Color( 255,  50,  50 )
	local GREEN = Color(   0, 255,   0 )
	local BLUE  = Color(  50, 150, 255 )
	local BLACK = Color(   0,   0,   0 )
	
	surface.CreateFont( mode.."_direction", {
		font = "Arial",
		size = 24,
		weight = 700,
		antialias = true
	})
	
	



	local function getStackSize()        return cvarCount:GetInt()       end
	local function getMaxPerStack()      return cvarMaxPerStack:GetInt() end
	local function getStackerMode()      return cvarMode:GetInt()        end
	local function getDirection()        return cvarDirection:GetInt()   end
	local function getOpacity()          return cvarOpacity:GetInt()     end	
	local function shouldGhostAll()      return cvarGhostAll:GetBool()   end
	local function shouldStackRelative() return cvarRelative:GetBool()   end
	local function shouldApplyMaterial() return cvarMaterial:GetBool()   end
	local function shouldApplyColor()    return cvarColor:GetBool()      end
	local function shouldAddHalos()      return cvarHalo:GetBool()       end
	
	local function getOffsetVector()
		return Vector( math.Clamp( cvarOffsetX:GetFloat(), -cvarMaxOffX:GetFloat(), cvarMaxOffX:GetFloat() ), 
	                   math.Clamp( cvarOffsetY:GetFloat(), -cvarMaxOffY:GetFloat(), cvarMaxOffY:GetFloat() ),
	                   math.Clamp( cvarOffsetZ:GetFloat(), -cvarMaxOffZ:GetFloat(), cvarMaxOffZ:GetFloat() ) )
	end

	local function getRotationAngle()
		return Angle( math.Clamp( cvarPitch:GetFloat(), -MAX_ANGLE, MAX_ANGLE ),
                      math.Clamp( cvarYaw:GetFloat(),   -MAX_ANGLE, MAX_ANGLE ),
                      math.Clamp( cvarRoll:GetFloat(),  -MAX_ANGLE, MAX_ANGLE ) )
	end
	
	local function getHaloColor()
		return Color( cvarHaloR:GetInt(),
                      cvarHaloG:GetInt(),
                      cvarHaloB:GetInt(),
	                  cvarHaloA:GetInt() )
	end
	

	function TOOL:Init()

		cvarTool       = GetConVar( "gmod_toolmode" )
		cvarCount      = GetConVar( mode.."_count" )
		cvarMode       = GetConVar( mode.."_mode" )
		cvarDirection  = GetConVar( mode.."_direction" )
		cvarOffsetX    = GetConVar( mode.."_offsetx" )
		cvarOffsetY    = GetConVar( mode.."_offsety" )
		cvarOffsetZ    = GetConVar( mode.."_offsetz" )
		cvarPitch      = GetConVar( mode.."_pitch" )
		cvarYaw        = GetConVar( mode.."_yaw" )
		cvarRoll       = GetConVar( mode.."_roll" )
		cvarRelative   = GetConVar( mode.."_relative" )
		cvarMaterial   = GetConVar( mode.."_material" )
		cvarColor      = GetConVar( mode.."_color" )
		cvarGhostAll   = GetConVar( mode.."_ghostall" )
		cvarOpacity    = GetConVar( mode.."_opacity" )
		cvarHalo       = GetConVar( mode.."_draw_halos" )
		cvarHaloR      = GetConVar( mode.."_halo_r" )
		cvarHaloG      = GetConVar( mode.."_halo_g" )
		cvarHaloB      = GetConVar( mode.."_halo_b" )
		cvarHaloA      = GetConVar( mode.."_halo_a" )
		cvarHalo       = GetConVar( mode.."_draw_halos" )
		cvarAxis       = GetConVar( mode.."_draw_axis" )
		cvarAxisLbl    = GetConVar( mode.."_axis_labels" )
		cvarAxisAng    = GetConVar( mode.."_axis_angles" )
	end
	

	local function createGhostStack( ent )
		if ( improvedstacker.GetGhosts() ) then improvedstacker.ReleaseGhosts() end


		local count    = getStackSize()
		local maxCount = getMaxPerStack()
		if ( not shouldGhostAll() and count ~= 0 ) then count = 1 end
		if ( maxCount >= 0 and count > maxCount )  then count = maxCount end

		local entMod  = ent:GetModel()
		local entSkin = ent:GetSkin()
		
		local ghosts = {}
		local ghost
		

		for i = 1, count do
			ghost = ClientsideModel( entMod )
			
			if ( not IsValid( ghost ) ) then continue end

			ghost:SetModel( entMod )
			ghost:SetSkin( entSkin )
			ghost:Spawn()

			ghost:SetRenderMode( RENDERMODE_TRANSALPHA )
			
			table.insert( ghosts, ghost )
		end
		

		improvedstacker.SetGhosts( ghosts )
		
		return true
	end


	local function validateGhostStack()

		local ghosts = improvedstacker.GetGhosts()
		if ( not ghosts ) then return false end
		

		for i = 1, #ghosts do
			if ( not IsValid( ghosts[ i ] ) ) then return false end
		end
		

		local count    = getStackSize()
		local maxCount = getMaxPerStack()
		if ( maxCount >= 0 and count > maxCount ) then count = maxCount end
		

		if     ( #ghosts ~= count and     shouldGhostAll() ) then return false

		elseif ( #ghosts ~= 1     and not shouldGhostAll() ) then return false end
		
		return true
	end


	local function updateGhostStack( ent )		
		local stackMode      = getStackerMode()
		local stackDirection = getDirection()
		local stackOffset    = getOffsetVector()
		local stackRotation  = getRotationAngle()
		local stackRelative  = shouldStackRelative()
		
		local applyMat  = shouldApplyMaterial()
		local applyCol  = shouldApplyColor()
		
		local lastEnt = ent
		local entPos = ent:GetPos()
		local entAng = ent:GetAngles()
		local entMat = ent:GetMaterial()
		local entCol = ent:GetColor()
			  entCol.a = getOpacity()
		
		local direction, offset

		local distance = improvedstacker.GetDistance( stackMode, stackDirection, ent )
		
		local ghost
		local ghosts = improvedstacker.GetGhosts()
		
		for i = 1, #ghosts do


			if ( i == 1 or ( stackMode == improvedstacker.MODE_PROP and stackRelative ) ) then
				direction = improvedstacker.GetDirection( stackMode, stackDirection, entAng )
				offset    = improvedstacker.GetOffset( stackMode, stackDirection, entAng, stackOffset )
			end


			entPos = entPos + (direction * distance) + offset

			improvedstacker.RotateAngle( stackMode, stackDirection, entAng, stackRotation )
			
			local ghost = ghosts[ i ]
			ghost:SetPos( entPos )
			ghost:SetAngles( entAng )
			ghost:SetMaterial( ( applyMat and entMat ) or "" )
			ghost:SetColor( ( applyCol and entCol ) or TRANSPARENT )
			ghost:SetNoDraw( false )
			
			lastEnt = ghost
		end
	end
	
	

	hook.Add( "PreDrawHalos", mode.."_predrawhalos", function()

		local ply = LocalPlayer()
		if ( not IsValid( ply ) ) then return end
		

		local wep = ply:GetActiveWeapon()
		if ( not ( IsValid( wep ) and wep:GetClass() == "gmod_tool" and cvarTool and cvarTool:GetString() == mode ) ) then
			improvedstacker.ReleaseGhosts()
			improvedstacker.SetLookedAt( nil )
			return
		end
		

		local lookingAt = ply:GetEyeTrace().Entity
		if ( not ( IsValid( lookingAt ) and lookingAt:GetClass() == "prop_physics" ) ) then
			improvedstacker.ReleaseGhosts()
			improvedstacker.SetLookedAt( nil )
			return
		end
		



		
		

		improvedstacker.SetLookingAt( lookingAt )

		local lookedAt = improvedstacker.GetLookedAt()
		

		if ( lookingAt == lookedAt ) then

			if ( validateGhostStack() ) then

				updateGhostStack( lookingAt )
			else

				improvedstacker.ReleaseGhosts()
				improvedstacker.SetLookedAt( nil )
				return
			end

		else

			if ( createGhostStack( lookingAt ) ) then

				improvedstacker.SetLookedAt( lookingAt )
			end
		end
		

		if ( not shouldAddHalos() ) then return end
		

		local ghosts = improvedstacker.GetGhosts()
		if ( not ghosts or #ghosts <= 0 ) then return end

		halo.Add( ghosts, getHaloColor() )
	end )
	

	
	hook.Add( "PostDrawTranslucentRenderables", mode.."_directions", function( drawingDepth, drawingSky )
		if ( drawingSky ) then return end
		

		local ply = LocalPlayer()
		if ( not IsValid( ply ) ) then return end
		

		if ( not ( cvarAxis and cvarAxis:GetBool() ) ) then return end
		

		local wep = ply:GetActiveWeapon()
		if ( not ( IsValid( wep ) and wep:GetClass() == "gmod_tool" and cvarTool and cvarTool:GetString() == mode ) ) then
			return
		end
		

		local ent = ply:GetEyeTrace().Entity
		if ( not IsValid( ent ) ) then
			return
		end
		
		local pos = ent:GetPos()
		
		local f = ent:GetForward()
		local r = ent:GetRight()
		local u = ent:GetUp()
		

		render.DrawLine( pos,    pos + (f*50),      RED, false )
		render.DrawLine( pos + (f*50) - f*ao + Vector(0,0,ao), pos + (f*50), RED, false )
		render.DrawLine( pos + (f*50) - f*ao - Vector(0,0,ao), pos + (f*50), RED, false )
		render.DrawLine( pos+o1, pos + (f*50) + o1, RED, false )
		render.DrawLine( pos+o2, pos + (f*50) + o2, RED, false )
		

		render.DrawLine( pos,    pos + (r*50),      GREEN, false )
		render.DrawLine( pos + (r*50) - r*ao + f*ao, pos + (r*50), GREEN, false )
		render.DrawLine( pos + (r*50) - r*ao - f*ao, pos + (r*50), GREEN, false )
		render.DrawLine( pos+o1, pos + (r*50) + o1, GREEN, false )
		render.DrawLine( pos+o2, pos + (r*50) + o2, GREEN, false )
		

		render.DrawLine( pos,    pos + (u*50),      BLUE, false )
		render.DrawLine( pos + (u*50) - u*ao + r*ao, pos + (u*50), BLUE, false )
		render.DrawLine( pos + (u*50) - u*ao - r*ao, pos + (u*50), BLUE, false )
		render.DrawLine( pos+o3, pos + (u*50) + o3, BLUE, false )
		render.DrawLine( pos+o4, pos + (u*50) + o4, BLUE, false )
		

		if ( not ( cvarAxisLbl           and cvarAxisAng ) )           then return end
		if ( not ( cvarAxisLbl:GetBool() or  cvarAxisAng:GetBool() ) ) then return end
		
		local fs = (pos + f*50 - u*5):ToScreen()
		local rs = (pos + r*50 - u*5):ToScreen()
		local us = (pos + u*55):ToScreen()
		
		local ang = ent:GetAngles()
		
		local front = ("%s%s"):format( cvarAxisLbl:GetBool() and L(prefix.."hud_front").." " or "", cvarAxisAng:GetBool() and "("..ang.x..")" or "" )
		local right = ("%s%s"):format( cvarAxisLbl:GetBool() and L(prefix.."hud_right").." " or "", cvarAxisAng:GetBool() and "("..ang.y..")" or "" )
		local upwrd = ("%s%s"):format( cvarAxisLbl:GetBool() and L(prefix.."hud_up").." "    or "", cvarAxisAng:GetBool() and "("..ang.z..")" or "" )
		
		cam.Start2D()
			draw.SimpleTextOutlined( front, mode.."_direction", fs.x, fs.y, RED,   0, 0, 1, BLACK )
			draw.SimpleTextOutlined( right, mode.."_direction", rs.x, rs.y, GREEN, 0, 0, 1, BLACK )
			draw.SimpleTextOutlined( upwrd, mode.."_direction", us.x, us.y, BLUE,  1, 0, 1, BLACK )
		cam.End2D()
		
	end )
	
end

if ( CLIENT ) then

	local function buildCPanel( cpanel )

		local presets = { 
			Label      = "Presets",
			MenuButton = 1,
			Folder     = mode,
			Options = {
				[L(prefix.."combobox_default")] = {
					[mode.."_mode"]        = tostring(improvedstacker.MODE_PROP),
					[mode.."_direction"]   = tostring(improvedstacker.DIRECTION_UP),
					[mode.."_count"]       = "1",
					[mode.."_freeze"]      = "1",
					[mode.."_weld"]        = "1",
					[mode.."_nocollide"]   = "1",
					[mode.."_ghostall"]    = "1",
					[mode.."_material"]    = "1",
					[mode.."_physprop"]    = "1",
					[mode.."_color"]       = "1",
					[mode.."_offsetx"]     = "0",
					[mode.."_offsety"]     = "0",
					[mode.."_offsetz"]     = "0",
					[mode.."_pitch"]       = "0",
					[mode.."_yaw"]         = "0",
					[mode.."_roll"]        = "0",
					[mode.."_relative"]    = "1",
					[mode.."_draw_halos"]  = "0",
					[mode.."_halo_r"]      = "255",
					[mode.."_halo_g"]      = "0",
					[mode.."_halo_b"]      = "0",
					[mode.."_halo_a"]      = "255",
					[mode.."_draw_axis"]   = "1",
					[mode.."_axis_labels"] = "1",
					[mode.."_axis_angles"] = "0",
				},
			},
			CVars = { 
				mode.."_mode",
				mode.."_direction",
				mode.."_count",
				mode.."_freeze",
				mode.."_weld",
				mode.."_nocollide",
				mode.."_ghostall",
				mode.."_material",
				mode.."_physprop",
				mode.."_color",
				mode.."_offsetx",
				mode.."_offsety",
				mode.."_offsetz",
				mode.."_pitch",
				mode.."_yaw",
				mode.."_roll",
				mode.."_relative",
				mode.."_draw_halos",
				mode.."_halo_r",
				mode.."_halo_g",
				mode.."_halo_b",
				mode.."_halo_a",
				mode.."_draw_axis",
				mode.."_axis_labels",
				mode.."_axis_angles",
			}
		}
		
		local relativeOptions = {
			[L(prefix.."combobox_world")] = { [mode.."_mode"] = improvedstacker.MODE_WORLD },
			[L(prefix.."combobox_prop")]  = { [mode.."_mode"] = improvedstacker.MODE_PROP  },
		}
		
		local relative = { Label = L(prefix.."label_relative"), MenuButton = "0", Options = relativeOptions }
		
		local directionOptions = {
			["1 - "..L(prefix.."combobox_direction_front")] = { [mode.."_direction"] = improvedstacker.DIRECTION_FRONT },
			["2 - "..L(prefix.."combobox_direction_back")]  = { [mode.."_direction"] = improvedstacker.DIRECTION_BACK  },
			["3 - "..L(prefix.."combobox_direction_right")] = { [mode.."_direction"] = improvedstacker.DIRECTION_RIGHT },
			["4 - "..L(prefix.."combobox_direction_left")]  = { [mode.."_direction"] = improvedstacker.DIRECTION_LEFT  },
			["5 - "..L(prefix.."combobox_direction_up")]    = { [mode.."_direction"] = improvedstacker.DIRECTION_UP    },
			["6 - "..L(prefix.."combobox_direction_down")]  = { [mode.."_direction"] = improvedstacker.DIRECTION_DOWN  },
		}
		
		local directions = { Label = L(prefix.."label_direction"), MenuButton = "0", Options = directionOptions }
		

		local languageOptions = {}
		
		for code, tbl in pairs( localify.GetLocalizations() ) do
			if ( not L(prefix.."language_"..code, code) ) then continue end
			
			languageOptions[ L(prefix.."language_"..code, code) ] = { localify_language = code }
		end
		
		local languages = {
			Label      = L(prefix.."label_language"),
			MenuButton = 0,
			Options    = languageOptions,
		}
		
		cpanel:AddControl( "ComboBox", languages )
		cpanel:ControlHelp( "\n" .. L(prefix.."label_credits") )
		cpanel:AddControl( "Label",    { Text = L(prefix.."label_presets") } )
		cpanel:AddControl( "ComboBox", presets )
		cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_freeze"),    Command = mode.."_freeze" } )
		cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_weld"),      Command = mode.."_weld" } )
		cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_nocollide"), Command = mode.."_nocollide" } )	
		cpanel:AddControl( "ComboBox", relative )	
		cpanel:AddControl( "ComboBox", directions )
		cpanel:AddControl( "Slider",   { Label = L(prefix.."label_count"), Min = 1, Max = cvarMaxPerStack:GetInt(), Command = mode.."_count", Description = "How many props to create in each stack" } )
		cpanel:AddControl( "Button",   { Label = L(prefix.."label_reset_offsets"), Command = mode.."_reset_offsets" } )
		cpanel:AddControl( "Slider",   { Label = L(prefix.."label_x"),     Type = "Float", Min = - cvarMaxOffX:GetInt(), Max = cvarMaxOffX:GetInt(), Value = 0, Command = mode.."_offsetx" } )
		cpanel:AddControl( "Slider",   { Label = L(prefix.."label_y"),     Type = "Float", Min = - cvarMaxOffY:GetInt(), Max = cvarMaxOffY:GetInt(), Value = 0, Command = mode.."_offsety" } )
		cpanel:AddControl( "Slider",   { Label = L(prefix.."label_z"),     Type = "Float", Min = - cvarMaxOffZ:GetInt(), Max = cvarMaxOffZ:GetInt(), Value = 0, Command = mode.."_offsetz" } )
		cpanel:AddControl( "Button",   { Label = L(prefix.."label_reset_angles"),  Command = mode.."_reset_angles" } )
		cpanel:AddControl( "Slider",   { Label = L(prefix.."label_pitch"), Type = "Float", Min = -MAX_ANGLE,  Max = MAX_ANGLE,  Value = 0, Command = mode.."_pitch" } )
		cpanel:AddControl( "Slider",   { Label = L(prefix.."label_yaw"),   Type = "Float", Min = -MAX_ANGLE,  Max = MAX_ANGLE,  Value = 0, Command = mode.."_yaw" } )
		cpanel:AddControl( "Slider",   { Label = L(prefix.."label_roll"),  Type = "Float", Min = -MAX_ANGLE,  Max = MAX_ANGLE,  Value = 0, Command = mode.."_roll" } )
		
		cpanel:AddControl( "Button",   { Label = L(prefix.."label_"..(showSettings and "hide" or "show").."_settings"),   Command = mode.."_show_settings" } )
		
		if ( showSettings ) then
			cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_use_shift_key"), Command = mode.."_use_shift_key", Description = "Toggles the ability to hold SHIFT and click the left and right mouse buttons to change stack size" } )
			cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_relative"),      Command = mode.."_relative",      Description = "Stacks each prop relative to the prop right before it. This allows you to create curved stacks" } )
			cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_material"),      Command = mode.."_material",      Description = "Applies the material of the original prop to all stacked props" } )
			cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_color"),         Command = mode.."_color",         Description = "Applies the color of the original prop to all stacked props" } )
			cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_physprop"),      Command = mode.."_physprop",      Description = "Applies the physical properties of the original prop to all stacked props" } )
			cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_ghost"),         Command = mode.."_ghostall",      Description = "Creates every ghost prop in the stack instead of just the first ghost prop" } )
			cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_axis"),          Command = mode.."_draw_axis", } )
			cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_axis_labels"),   Command = mode.."_axis_labels", } )
			cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_axis_angles"),   Command = mode.."_axis_angles", } )
			cpanel:AddControl( "Checkbox", { Label = L(prefix.."checkbox_halo"),          Command = mode.."_draw_halos", Description = "Gives halos to all of the props in to ghosted stack" } )
			cpanel:AddControl( "Slider",   { Label = L(prefix.."label_opacity"), Type = "Integer", Min = 0, Max = 255, Command = mode.."_opacity" } )
			cpanel:AddControl( "Color",    { Label = L(prefix.."checkbox_halo_color"), Red = mode.."_halo_r", Green = mode.."_halo_g", Blue = mode.."_halo_b", Alpha = mode.."_halo_a" } )
		end
	end
	
	concommand.Add( mode.."_show_settings", function( ply, cmd, args )
		local cpanel = controlpanel.Get( mode )
		if ( not IsValid( cpanel ) ) then return end
		showSettings = not showSettings
		cpanel:ClearControls()
		buildCPanel( cpanel )
	end )


	cvars.AddChangeCallback( "localify_language", function( name, old, new )
		local cpanel = controlpanel.Get( mode )
		if ( not IsValid( cpanel ) ) then return end
		cpanel:ClearControls()
		buildCPanel( cpanel )
	end, "improvedstacker" )
	
	TOOL.BuildCPanel = buildCPanel


	hook.Add( "PopulateToolMenu", mode.."AdminUtilities", function()
		spawnmenu.AddToolMenuOption( "Utilities", "Admin", mode.."_utils", L(prefix.."name"), "", "", function( cpanel )
			

			local presets = {
				label      = "Presets",
				menubutton = 1,
				folder     = mode.."_admin",
				options = {
					[L(prefix.."combobox_default")]      = improvedstacker.SETTINGS_DEFAULT,
					[L(prefix.."combobox_sandbox")]      = improvedstacker.SETTINGS_SANDBOX,
					[L(prefix.."combobox_darkrp")]       = improvedstacker.SETTINGS_DARKRP,
					[L(prefix.."combobox_singleplayer")] = improvedstacker.SETTINGS_SINGLEPLAYER,
				},
				cvars = {
					{ CVar = mode.."_max_per_player",    CCmd = mode.."_set_max_per_player" },
					{ CVar = mode.."_max_per_stack",     CCmd = mode.."_set_max_per_stack" },
					{ CVar = mode.."_delay",             CCmd = mode.."_set_delay" },
					{ CVar = mode.."_max_offsetx",       CCmd = mode.."_set_max_offsetx" },
					{ CVar = mode.."_max_offsety",       CCmd = mode.."_set_max_offsety" },
					{ CVar = mode.."_max_offsetz",       CCmd = mode.."_set_max_offsetz" },
					{ CVar = mode.."_force_freeze",      CCmd = mode.."_set_force_freeze" },
					{ CVar = mode.."_force_weld",        CCmd = mode.."_set_force_weld" },
					{ CVar = mode.."_force_nocollide",   CCmd = mode.."_set_force_nocollide" },
					{ CVar = mode.."_force_stayinworld", CCmd = mode.."_set_force_stayinworld" },
				},
			}
			
			local ctrl = vgui.Create( "StackerControlPresets", cpanel )
			ctrl:SetPreset( presets.folder )
			for k, v in pairs( presets.options ) do
				ctrl:AddOption( k, v )
			end
			for k, v in pairs( presets.cvars ) do
				ctrl:AddConVar( v )
			end			
			cpanel:AddItem( ctrl )

			
			
			local bg = Color( 210, 210, 210 ) or Color( 179, 216, 255 )
			local fg = Color( 240, 240, 240 ) or Color( 229, 242, 255 )
			
			local sliders = {
				{ String = "max_per_player", Min = -1, Max = 2048,  Decimals = 0 },
				{ String = "max_per_stack",  Min =  1, Max = 100,   Decimals = 0 },
				{ String = "delay",          Min =  0, Max = 5,                  },
				{ String = "max_offsetx",    Min =  0, Max = 10000,              },
				{ String = "max_offsety",    Min =  0, Max = 10000,              },
				{ String = "max_offsetz",    Min =  0, Max = 10000,              },
			}
			
			local sliderlist = vgui.Create( "DListLayout", cpanel )
			sliderlist:DockPadding( 3, 1, 3, 3 )
			sliderlist:SetPaintBackground( true )
			function sliderlist:Paint( w, h )
				draw.RoundedBox( 0, 0, 0, w, h, bg )
			end
			cpanel:AddItem( sliderlist )
			
			for k, data in pairs( sliders ) do
				local list = vgui.Create( "DListLayout", sliderlist )
				list:DockPadding( 5, 0, 5, 5 )
				list:DockMargin( 0, 2, 0, 0 )
				list:SetPaintBackground( true )
				function list:Paint( w, h )
					draw.RoundedBox( 0, 0, 0, w, h, fg )
				end
			
				local decimals = data.Decimals or 2
			
				local slider = vgui.Create( "StackerDNumSlider", list )
				slider:SetText( L(prefix.."label_"..data.String) )
				slider.Label:SetFont( "DermaDefaultBold" )
				slider:SetMinMax( data.Min, data.Max )
				slider:SetDark( true )
				slider:SizeToContents()
				slider:SetDecimals( decimals )
				slider:SetValue( decimals == 0 and GetConVar( mode.."_"..data.String ):GetInt() or GetConVar( mode.."_"..data.String ):GetFloat(), true )
				
				local cmd = mode.."_set_"..data.String
				
				function slider:OnValueChanged( value )
					value = math.Round( value, decimals )
					RunConsoleCommand( cmd, value )
				end
				
				if ( L(prefix.."help_"..data.String) ) then
					local help = vgui.Create( "DLabel", list )
					help:SetText( L(prefix.."help_"..data.String) )
					help:DockMargin( 10, 0, 5, 0 )
					help:SetWrap( true )
					help:SetDark( true )
					help:SetAutoStretchVertical( true )
					help:SetFont( "DermaDefault" )
				end
				
				if ( L(prefix.."warning_"..data.String) ) then
					local help = vgui.Create( "DLabel", list )
					help:SetText( L(prefix.."warning_"..data.String) )
					help:DockMargin( 10, 0, 5, 0 )
					help:SetWrap( true )
					help:SetDark( true )
					help:SetAutoStretchVertical( true )
					help:SetFont( "DermaDefault" )
					help:SetTextColor( Color( 200, 0, 0 ) )
				end
				
				cvars.AddChangeCallback( mode.."_"..data.String, function( name, old, new )
					if ( not IsValid( slider ) ) then return end
					slider:SetValue( GetConVar( mode.."_"..data.String ):GetFloat(), true )
				end, mode.."_"..data.String.."_utilities" )
			end
			
			
			
			local checkboxes = {
				"freeze",
				"weld",
				"nocollide",
				"nocollide_all",
				"stayinworld",
			}

			local cblist = vgui.Create( "DListLayout", cpanel )
			cblist:DockPadding( 3, 1, 3, 3 )
			cblist:SetPaintBackground( true )
			function cblist:Paint( w, h )
				draw.RoundedBox( 0, 0, 0, w, h, bg )
			end
			cpanel:AddItem( cblist )
			
			for k, data in pairs( checkboxes ) do
				local list = vgui.Create( "DListLayout", cblist )
				list:DockPadding( 5, 5, 5, 5 )
				list:DockMargin( 0, 2, 0, 0 )
				list:SetPaintBackground( true )
				function list:Paint( w, h )
					draw.RoundedBox( 0, 0, 0, w, h, fg )
				end
			
				local cb = vgui.Create( "DCheckBoxLabel", list )
				cb:SetText( L(prefix.."checkbox_"..data) )
				cb:SetChecked( GetConVar( mode.."_force_"..data ):GetBool() )
				cb.Label:SetFont( "DermaDefaultBold" )
				cb:SizeToContents()
				cb:SetDark( true )

				if ( data == "nocollide_all" ) then
					cb:SetDisabled( true )
				end
				
				function cb:OnChange( bool ) RunConsoleCommand( mode.."_set_force_"..data, bool and "1" or "0" ) end
				
				cvars.AddChangeCallback( mode.."_force_"..data, function( name, old, new )
					if ( not IsValid( cb ) ) then return end
					cb:SetChecked( tobool( new ) )
				end, mode.."_"..data.."_utilities" )
				
				if ( L(prefix.."help_"..data) ) then
					local help = vgui.Create( "DLabel", list )
					help:SetText( L(prefix.."help_"..data) )
					help:DockMargin( 25, 5, 5, 0 )
					help:SetWrap( true )
					help:SetDark( true )
					help:SetAutoStretchVertical( true )
					help:SetFont( "DermaDefault" )
				end
				
				if ( L(prefix.."warning_"..data) ) then
					local help = vgui.Create( "DLabel", list )
					help:SetText( L(prefix.."warning_"..data) )
					help:DockMargin( 25, 5, 5, 0 )
					help:SetWrap( true )
					help:SetDark( true )
					help:SetAutoStretchVertical( true )
					help:SetFont( "DermaDefault" )
					help:SetTextColor( Color( 200, 0, 0 ) )
				end
			end
		end )
	end )
end
