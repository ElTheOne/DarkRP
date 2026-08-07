net.Receive("drp_state_v1", function()
	local version = net.ReadUInt(8)
	local state = net.ReadUInt(2)

	if version ~= DRP.ProtocolVersion then
		ErrorNoHalt(string.format("[DRP] protocol mismatch: server=%d client=%d\n", version, DRP.ProtocolVersion))
		return
	end

	DRP.ClientState = state
	hook.Run("DRPLifecycleChanged", state, DRP.StateName[state])
end)

DRP.ClientProfile = DRP.ClientProfile or {
	money = 0,
	job = DRP.Job.CITIZEN,
	salaryAt = 0,
	xp = 0,
	level = 1,
	prestige = 0,
	prestigeTokens = 0,
	sessionStartedAt = CurTime(),
	totalPlaytimeBase = 0,
	prestigeItems = {}
}
DRP.ClientDoors = DRP.ClientDoors or {}
DRP.ClientDoorPolicies = DRP.ClientDoorPolicies or {}
DRP.ClientLockdown = DRP.ClientLockdown or { active = false, reason = "", startedAt = 0 }

net.Receive("drp_lockdown_state_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local active = net.ReadBool()
	local reason = net.ReadString()
	local elapsed = net.ReadUInt(16)
	local changed = DRP.ClientLockdown.active ~= active
	DRP.ClientLockdown.active = active
	DRP.ClientLockdown.reason = reason
	DRP.ClientLockdown.startedAt = CurTime() - elapsed
	if changed then
		local text = active and ("LOCKDOWN announced: " .. reason .. ". Citizens have 60 seconds to get under a roof.") or "The city lockdown has ended."
		if DRP.Chat and DRP.Chat.System then DRP.Chat.System(text, active and 2 or 1) else chat.AddText(Color(156, 241, 255), "[DRP] ", color_white, text) end
	end
	hook.Run("DRPLockdownChanged", active, reason)
end)

net.Receive("drp_profile_v2", function()
	local version = net.ReadUInt(8)
	local money = net.ReadUInt(32)
	local job = net.ReadUInt(8)
	local salaryIn = net.ReadUInt(16)
	local xp = net.ReadDouble()
	local level = net.ReadUInt(8)
	local prestige = net.ReadUInt(8)
	local prestigeTokens = net.ReadUInt(8)
	local sessionElapsed = net.ReadUInt(32)
	local totalPlaytimeBase = net.ReadUInt(32)
	local prestigeItemCount = net.ReadUInt(6)
	local prestigeItems = {}
	for index = 1, prestigeItemCount do prestigeItems[index] = string.lower(net.ReadString()) end
	if version ~= DRP.ProtocolVersion or not DRP.Jobs[job] then return end

	DRP.ClientProfile.money = money
	DRP.ClientProfile.job = job
	DRP.ClientProfile.salaryAt = CurTime() + salaryIn
	DRP.ClientProfile.xp = xp
	DRP.ClientProfile.level = level
	DRP.ClientProfile.prestige = prestige
	DRP.ClientProfile.prestigeTokens = prestigeTokens
	DRP.ClientProfile.sessionStartedAt = CurTime() - sessionElapsed
	DRP.ClientProfile.totalPlaytimeBase = totalPlaytimeBase
	DRP.ClientProfile.prestigeItems = prestigeItems
	hook.Run("DRPProfileChanged", money, job)
end)

net.Receive("drp_notice_v2", function()
	local version = net.ReadUInt(8)
	local kind = net.ReadUInt(2)
	local text = string.sub(net.ReadString(), 1, 160)
	if version ~= DRP.ProtocolVersion then return end

	local colors = { Color(156, 241, 255), Color(100, 220, 120), Color(255, 190, 75), Color(255, 95, 95) }
	if DRP.Chat and DRP.Chat.System then
		DRP.Chat.System(text, kind)
	else
		chat.AddText(colors[kind + 1] or color_white, "[DRP] ", color_white, text)
	end
end)

net.Receive("drp_door_v2", function()
	local version = net.ReadUInt(8)
	local doorIndex = net.ReadUInt(13)
	local ownerIndex = net.ReadUInt(8)
	if version ~= DRP.ProtocolVersion then return end

	DRP.ClientDoors[doorIndex] = ownerIndex > 0 and ownerIndex or nil
end)

net.Receive("drp_door_policy_v1", function()
	local version = net.ReadUInt(8)
	local doorIndex = net.ReadUInt(13)
	local ownable = net.ReadBool()
	local jobs = net.ReadUInt(16)
	if version ~= DRP.ProtocolVersion then return end
	DRP.ClientDoorPolicies[doorIndex] = { ownable = ownable, jobs = jobs }
end)

net.Receive("drp_door_breach_fx_v1", function()
	local model = net.ReadString()
	local position = net.ReadVector()
	local angles = net.ReadAngle()
	local skin = net.ReadUInt(8)
	local velocity = net.ReadVector()
	local lifetime = math.Clamp(net.ReadUInt(10), 1, 600)
	if model == "" or not util.IsValidModel(model) then return end

	local debris = ClientsideModel(model, RENDERGROUP_OPAQUE)
	if not IsValid(debris) then return end
	debris:SetPos(position)
	debris:SetAngles(angles)
	debris:SetSkin(skin)
	debris:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
	debris:PhysicsInit(SOLID_VPHYSICS)
	debris:SetMoveType(MOVETYPE_VPHYSICS)
	debris:SetSolid(SOLID_VPHYSICS)
	local physics = debris:GetPhysicsObject()
	if IsValid(physics) then
		physics:EnableGravity(true)
		physics:Wake()
		physics:SetVelocity(velocity)
	end
	timer.Simple(lifetime, function() if IsValid(debris) then debris:Remove() end end)
end)
