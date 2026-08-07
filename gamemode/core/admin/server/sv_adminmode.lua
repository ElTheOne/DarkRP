local actionMessage = "drp_admin_mode_action_v1"
local stateMessage = "drp_admin_mode_state_v1"
util.AddNetworkString(actionMessage)
util.AddNetworkString(stateMessage)

local Mode = {
	States = setmetatable({}, { __mode = "k" })
}

DRP.AdminMode = Mode

local function notify(ply, text, kind)
	if IsValid(ply) then DRP.Net.Notify(ply, text, kind or 0) end
end

local function audit(actor, eventType, target, details)
	if DRP.Audit then DRP.Audit.Log(actor, eventType, target, details) end
end

function Mode.IsActive(ply)
	return IsValid(ply) and Mode.States[ply] ~= nil and ply.DRPAdminMode == true
end

function Mode.CanUse(ply)
	return IsValid(ply) and DRP.Admin and DRP.Admin.Has(ply, "adminmode")
end

local function hasNoTarget(ply)
	return ply.IsFlagSet ~= nil and ply:IsFlagSet(FL_NOTARGET) or false
end

local function isNotSolid(ply)
	return ply.IsSolid ~= nil and not ply:IsSolid() or false
end

local function sendState(ply)
	if not IsValid(ply) then return end
	local state = Mode.States[ply]
	net.Start(stateMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(state ~= nil)
	net.WriteBool(state and state.cloaked == true or false)
	net.WriteBool(state and state.noclip == true or false)
	net.WriteUInt(state and IsValid(state.spectating) and state.spectating:EntIndex() or 0, 13)
	net.Send(ply)
end

local function setWeaponVisibility(ply, hidden)
	local state = Mode.States[ply]
	for _, weapon in ipairs(ply:GetWeapons()) do
		if hidden then
			if state.weaponVisibility[weapon] == nil then state.weaponVisibility[weapon] = weapon:GetNoDraw() end
			weapon:SetNoDraw(true)
		else
			weapon:SetNoDraw(state and state.weaponVisibility[weapon] == true or false)
		end
	end
	if not hidden and state then state.weaponVisibility = setmetatable({}, { __mode = "k" }) end
end

function Mode.SetCloak(ply, enabled)
	local state = Mode.States[ply]
	if not state then return false end
	enabled = enabled == true
	state.cloaked = enabled
	ply:SetNoDraw(enabled or state.spectating ~= nil or state.originalNoDraw)
	ply:DrawShadow(not enabled and not state.spectating and state.originalShadow)
	ply:SetNoTarget(enabled or state.originalNoTarget)
	setWeaponVisibility(ply, enabled or state.spectating ~= nil)
	sendState(ply)
	return true
end

function Mode.StopSpectate(ply, silent)
	local state = Mode.States[ply]
	if not state or not state.spectating then return false end
	local target = state.spectating
	state.spectating = nil
	ply:SetMoveType(state.spectateMoveType or (state.noclip and MOVETYPE_NOCLIP or MOVETYPE_WALK))
	ply:SetNotSolid(state.originalNotSolid)
	ply:SetNoDraw(state.cloaked or state.originalNoDraw)
	ply:DrawShadow(not state.cloaked and state.originalShadow)
	setWeaponVisibility(ply, state.cloaked)
	sendState(ply)
	if not silent then notify(ply, "Stopped spectating " .. (IsValid(target) and target:Nick() or "player") .. ".", 0) end
	return true
end

function Mode.StartSpectate(ply, target)
	local state = Mode.States[ply]
	if not state or not IsValid(target) or target == ply or not target:Alive() then return false end
	if state.spectating then Mode.StopSpectate(ply, true) end
	state.spectating = target
	state.spectateMoveType = ply:GetMoveType()
	ply:SetMoveType(MOVETYPE_NONE)
	ply:SetNotSolid(true)
	ply:SetNoDraw(true)
	ply:DrawShadow(false)
	setWeaponVisibility(ply, true)
	sendState(ply)
	notify(ply, "Remotely spectating " .. target:Nick() .. ". Your player remains at its original position.", 0)
	return true
end

function Mode.Enable(ply)
	if not Mode.CanUse(ply) or Mode.IsActive(ply) then return false end
	Mode.States[ply] = {
		cloaked = false,
		noclip = false,
		originalNoDraw = ply:GetNoDraw(),
		originalNoTarget = hasNoTarget(ply),
		originalNotSolid = isNotSolid(ply),
		originalShadow = true,
		originalCustomCollision = ply:GetCustomCollisionCheck(),
		originalMoveType = ply:GetMoveType(),
		weaponVisibility = setmetatable({}, { __mode = "k" })
	}
	ply.DRPAdminMode = true
	if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.ADMIN_MODE) end
	ply:SetCustomCollisionCheck(true)
	ply:CollisionRulesChanged()
	hook.Run("DRPAdminModeChanged", ply, true)
	sendState(ply)
	notify(ply, "Admin Mode enabled. Player collision is disabled and staff tools are available.", 1)
	audit(ply, "adminmode_enabled")
	return true
end

function Mode.Disable(ply, reason)
	local state = Mode.States[ply]
	if not state then sendState(ply) return false end
	if state.spectating then Mode.StopSpectate(ply, true) end
	state = Mode.States[ply]
	setWeaponVisibility(ply, false)
	ply:SetNoDraw(state.originalNoDraw)
	ply:DrawShadow(state.originalShadow)
	ply:SetNoTarget(state.originalNoTarget)
	ply:SetNotSolid(state.originalNotSolid)
	ply:SetCustomCollisionCheck(state.originalCustomCollision)
	ply:CollisionRulesChanged()
	if ply:Alive() and (ply:GetMoveType() == MOVETYPE_NOCLIP or ply:GetMoveType() == MOVETYPE_NONE) then
		ply:SetMoveType(state.originalMoveType == MOVETYPE_NOCLIP and MOVETYPE_WALK or state.originalMoveType)
	end
	Mode.States[ply] = nil
	ply.DRPAdminMode = nil
	hook.Run("DRPAdminModeChanged", ply, false)
	if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.ADMIN_MODE) end
	if reason ~= "disconnect" then sendState(ply) end
	if reason ~= "disconnect" then notify(ply, "Admin Mode disabled" .. (reason and (": " .. reason) or "."), 2) end
	audit(ply, "adminmode_disabled", nil, reason)
	return true
end

function Mode.Toggle(ply)
	if Mode.IsActive(ply) then return Mode.Disable(ply) end
	if not Mode.CanUse(ply) then notify(ply, "You do not have permission to use Admin Mode.", 3) return false end
	return Mode.Enable(ply)
end

function Mode.ValidateAccess(ply)
	if Mode.IsActive(ply) and not Mode.CanUse(ply) then Mode.Disable(ply, "permission revoked") end
end

local function canTarget(actor, target, allowSelf)
	if not Mode.IsActive(actor) then notify(actor, "Enable Admin Mode first with /admin or !admin.", 3) return false end
	if not IsValid(target) or not target:IsPlayer() or not target:DRPReady() then notify(actor, "That player is unavailable.", 3) return false end
	if target == actor then return allowSelf == true end
	if DRP.Admin.IsOwner(actor) then return true end
	if DRP.Admin.IsOwner(target) or DRP.AdminRankLevel(DRP.Admin.RankKey(target)) >= DRP.AdminRankLevel(DRP.Admin.RankKey(actor)) then
		notify(actor, "You cannot use Admin Mode tools on an equal or higher-ranked player.", 3)
		return false
	end
	return true
end

function Mode.CanPhysgun(actor, target)
	local allowed = Mode.CanUse(actor) and Mode.IsActive(actor) and IsValid(target) and target:IsPlayer() and canTarget(actor, target, false)
	if allowed and actor.DRPAdminHeldPlayer ~= target then
		actor.DRPAdminHeldPlayer = target
		audit(actor, "admin_physgun_pickup", target)
	end
	return allowed
end

local function updateImmobilized(target)
	local immobilized = target.DRPAdminFrozen == true or target.DRPAdminJailed == true
	target:Freeze(immobilized)
	if target.DRPAdminJailed then
		target:Lock()
	elseif target:DRPReady() then
		target:UnLock()
	end
end

local function captureInventory(target)
	local snapshot = { weapons = {}, ammo = {}, active = IsValid(target:GetActiveWeapon()) and target:GetActiveWeapon():GetClass() or nil }
	for _, weapon in ipairs(target:GetWeapons()) do
		snapshot.weapons[#snapshot.weapons + 1] = { class = weapon:GetClass(), clip1 = weapon:Clip1(), clip2 = weapon:Clip2() }
	end
	for ammoID = 0, 255 do
		local count = target:GetAmmoCount(ammoID)
		if count > 0 then snapshot.ammo[ammoID] = count end
	end
	return snapshot
end

local function restoreInventory(target, snapshot)
	if not IsValid(target) or not target:Alive() then return end
	target:StripWeapons()
	target:RemoveAllAmmo()
	for _, record in ipairs(snapshot.weapons) do
		local weapon = target:Give(record.class, true)
		if IsValid(weapon) then
			if record.clip1 >= 0 then weapon:SetClip1(record.clip1) end
			if record.clip2 >= 0 then weapon:SetClip2(record.clip2) end
		end
	end
	for ammoID, count in pairs(snapshot.ammo) do target:GiveAmmo(count, ammoID, true) end
	if snapshot.active then target:SelectWeapon(snapshot.active) end
	updateImmobilized(target)
	local state = Mode.States[target]
	if state and (state.cloaked or state.spectating) then setWeaponVisibility(target, true) end
end

function Mode.Perform(actor, action, target, amount)
	if action == DRP.AdminModeAction.TOGGLE then return Mode.Toggle(actor) end
	if not Mode.CanUse(actor) then notify(actor, "You do not have permission to use Admin Mode.", 3) return false end
	if not Mode.IsActive(actor) then notify(actor, "Enable Admin Mode first with /admin or !admin.", 3) return false end
	if action == DRP.AdminModeAction.TOGGLE_TARGET_MODE then
		if not canTarget(actor, target, false) then return false end
		local actorLevel = DRP.AdminRankLevel(DRP.Admin.RankKey(actor))
		local targetLevel = DRP.AdminRankLevel(DRP.Admin.RankKey(target))
		if targetLevel >= actorLevel then
			notify(actor, "Only lower-ranking staff can be placed into Admin Mode.", 3)
			return false
		end
		if not Mode.CanUse(target) then
			notify(actor, target:Nick() .. " does not have the Admin Mode permission.", 3)
			return false
		end
		local enabled
		if Mode.IsActive(target) then
			enabled = false
			Mode.Disable(target, "changed by " .. actor:Nick())
		else
			enabled = Mode.Enable(target)
		end
		if enabled ~= false or not Mode.IsActive(target) then
			notify(actor, target:Nick() .. " was " .. (enabled and "placed into" or "removed from") .. " Admin Mode.", 1)
			audit(actor, enabled and "adminmode_force_enabled" or "adminmode_force_disabled", target)
			return true
		end
		return false
	end

	local state = Mode.States[actor]
	if action == DRP.AdminModeAction.NOCLIP then
		if state.spectating then notify(actor, "Stop spectating before toggling noclip.", 3) return false end
		state.noclip = actor:GetMoveType() ~= MOVETYPE_NOCLIP
		actor:SetMoveType(state.noclip and MOVETYPE_NOCLIP or MOVETYPE_WALK)
		sendState(actor)
		notify(actor, "Noclip " .. (state.noclip and "enabled." or "disabled."), state.noclip and 1 or 2)
		audit(actor, "adminmode_noclip", nil, tostring(state.noclip))
		return true
	elseif action == DRP.AdminModeAction.CLOAK then
		Mode.SetCloak(actor, not state.cloaked)
		notify(actor, "Cloak " .. (state.cloaked and "enabled." or "disabled."), state.cloaked and 1 or 2)
		audit(actor, "adminmode_cloak", nil, tostring(state.cloaked))
		return true
	elseif action == DRP.AdminModeAction.STOP_SPECTATE then
		return Mode.StopSpectate(actor)
	end

	local allowSelf = action == DRP.AdminModeAction.RESPAWN or action == DRP.AdminModeAction.SET_HEALTH or action == DRP.AdminModeAction.SET_ARMOR
	if not canTarget(actor, target, allowSelf) then return false end
	if action == DRP.AdminModeAction.SPECTATE then
		if not Mode.StartSpectate(actor, target) then notify(actor, "That player cannot be spectated right now.", 3) return false end
		audit(actor, "admin_spectate", target, "remote")
	elseif action == DRP.AdminModeAction.FREEZE then
		target.DRPAdminFrozen = true
		updateImmobilized(target)
		notify(target, "You were frozen by " .. actor:Nick() .. ".", 2)
		audit(actor, "admin_freeze", target)
	elseif action == DRP.AdminModeAction.UNFREEZE then
		target.DRPAdminFrozen = nil
		updateImmobilized(target)
		notify(target, "You were unfrozen by " .. actor:Nick() .. ".", 1)
		audit(actor, "admin_unfreeze", target)
	elseif action == DRP.AdminModeAction.RESPAWN then
		local inventory = target:Alive() and captureInventory(target) or target.DRPLastDeathInventory or captureInventory(target)
		target:Spawn()
		timer.Simple(0, function()
			restoreInventory(target, inventory)
			if IsValid(target) then target.DRPLastDeathInventory = nil end
		end)
		notify(target, "You were respawned by " .. actor:Nick() .. "; your inventory was preserved.", 0)
		audit(actor, "admin_respawn", target, "inventory preserved")
	elseif action == DRP.AdminModeAction.SET_HEALTH then
		if not target:Alive() then notify(actor, "Respawn that player before setting health.", 3) return false end
		amount = math.Clamp(math.floor(tonumber(amount) or 0), 1, 1000000)
		target:SetHealth(amount)
		if target ~= actor then notify(target, actor:Nick() .. " set your health to " .. amount .. ".", 0) end
		audit(actor, "admin_sethealth", target, amount)
	elseif action == DRP.AdminModeAction.SET_ARMOR then
		amount = math.Clamp(math.floor(tonumber(amount) or 0), 0, 1000000)
		target:SetArmor(amount)
		if target ~= actor then notify(target, actor:Nick() .. " set your armor to " .. amount .. ".", 0) end
		audit(actor, "admin_setarmor", target, amount)
	elseif action == DRP.AdminModeAction.STRIP_WEAPONS then
		target:StripWeapons()
		notify(target, "Your weapons were stripped by " .. actor:Nick() .. ".", 2)
		audit(actor, "admin_strip_weapons", target)
	elseif action == DRP.AdminModeAction.JAIL then
		target.DRPAdminJailed = true
		updateImmobilized(target)
		notify(target, "You were jailed by " .. actor:Nick() .. ".", 2)
		audit(actor, "admin_jail", target)
	elseif action == DRP.AdminModeAction.UNJAIL then
		target.DRPAdminJailed = nil
		updateImmobilized(target)
		notify(target, "You were released from jail by " .. actor:Nick() .. ".", 1)
		audit(actor, "admin_unjail", target)
	elseif action == DRP.AdminModeAction.RELEASE_ARREST then
		if not DRP.Legal or not DRP.Legal.Arrested or not DRP.Legal.Arrested[target] then
			notify(actor, "That player is not arrested.", 3)
			return false
		end
		DRP.Legal.Release(target, "released by " .. actor:Nick())
		audit(actor, "admin_unarrest", target)
	else
		return false
	end
	if action ~= DRP.AdminModeAction.SPECTATE then notify(actor, "Admin action applied to " .. target:Nick() .. ".", 1) end
	return true
end

DRP.Net.Receive(actionMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local action = net.ReadUInt(4)
	local targetIndex = net.ReadUInt(13)
	local amount = net.ReadUInt(32)
	if not DRP.Net.Allow(ply, "adminmode_action", 0.2, 5) then return end
	if not Mode.CanUse(ply) then notify(ply, "You do not have permission to use Admin Mode.", 3) return end
	local target = targetIndex > 0 and Entity(targetIndex) or nil
	Mode.Perform(ply, action, target, amount)
end)

hook.Add("PlayerNoClip", "DRP.AdminMode.Noclip", function(ply, desired)
	if desired and not Mode.IsActive(ply) then return false end
	if not Mode.IsActive(ply) then return end
	local state = Mode.States[ply]
	if state.spectating then return false end
	state.noclip = desired == true
	timer.Simple(0, function() if IsValid(ply) and Mode.IsActive(ply) then sendState(ply) end end)
	return true
end)

hook.Add("ShouldCollide", "DRP.AdminMode.PlayerCollision", function(first, second)
	if IsValid(first) and IsValid(second) and first:IsPlayer() and second:IsPlayer() and (Mode.IsActive(first) or Mode.IsActive(second)) then return false end
end)

hook.Add("SetupPlayerVisibility", "DRP.AdminMode.RemotePVS", function(ply)
	local state = Mode.States[ply]
	if state and IsValid(state.spectating) then AddOriginToPVS(state.spectating:EyePos()) end
end)

hook.Add("KeyPress", "DRP.AdminMode.PhysgunFreeze", function(ply, key)
	if not Mode.IsActive(ply) then return end
	if key == IN_ATTACK2 and IsValid(ply.DRPAdminHeldPlayer) then
		Mode.Perform(ply, DRP.AdminModeAction.FREEZE, ply.DRPAdminHeldPlayer)
	elseif key == IN_RELOAD then
		local target = ply:GetEyeTrace().Entity
		if IsValid(target) and target:IsPlayer() and target.DRPAdminFrozen then Mode.Perform(ply, DRP.AdminModeAction.UNFREEZE, target) end
	end
end)

hook.Add("PhysgunPickup", "DRP.AdminMode.TrackPlayer", function(ply, target)
	if not IsValid(target) or not target:IsPlayer() or not Mode.CanPhysgun(ply, target) then return end
	return true
end)

hook.Add("PhysgunDrop", "DRP.AdminMode.UntrackPlayer", function(ply, target)
	if IsValid(target) and target:IsPlayer() and ply.DRPAdminHeldPlayer == target then ply.DRPAdminHeldPlayer = nil end
end)

hook.Add("PlayerSwitchWeapon", "DRP.AdminMode.HideWeapon", function(ply, _, weapon)
	local state = Mode.States[ply]
	if state and IsValid(weapon) and (state.cloaked or state.spectating) then
		if state.weaponVisibility[weapon] == nil then state.weaponVisibility[weapon] = weapon:GetNoDraw() end
		weapon:SetNoDraw(true)
	end
end)

function Mode.ApplyCommand(ply, command)
	local state = Mode.States[ply]
	if state and state.spectating then
		command:ClearMovement()
		command:RemoveKey(IN_ATTACK)
		command:RemoveKey(IN_ATTACK2)
		command:RemoveKey(IN_USE)
		command:RemoveKey(IN_RELOAD)
		command:RemoveKey(IN_JUMP)
		return
	end
	if ply.DRPAdminJailed then
		command:ClearMovement()
		command:RemoveKey(IN_ATTACK)
		command:RemoveKey(IN_ATTACK2)
		command:RemoveKey(IN_USE)
	end
end

hook.Add("PlayerSpawn", "DRP.AdminMode.RestoreState", function(ply)
	timer.Simple(0, function()
		if not IsValid(ply) then return end
		updateImmobilized(ply)
		local state = Mode.States[ply]
		if state then
			ply:SetCustomCollisionCheck(true)
			ply:CollisionRulesChanged()
			Mode.SetCloak(ply, state.cloaked)
			if state.noclip and not state.spectating then ply:SetMoveType(MOVETYPE_NOCLIP) end
		end
	end)
end)

hook.Add("PlayerDeath", "DRP.AdminMode.Death", function(ply)
	ply.DRPLastDeathInventory = captureInventory(ply)
	if Mode.IsActive(ply) then Mode.Disable(ply, "you died") end
	for spectator, state in pairs(Mode.States) do
		if state.spectating == ply then Mode.StopSpectate(spectator) end
	end
end)

hook.Add("PlayerDisconnected", "DRP.AdminMode.Disconnect", function(ply)
	if Mode.IsActive(ply) then Mode.Disable(ply, "disconnect") end
	for spectator, state in pairs(Mode.States) do
		if state.spectating == ply then Mode.StopSpectate(spectator) end
	end
end)
