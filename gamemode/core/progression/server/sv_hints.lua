local MESSAGE = "drp_hint_v1"
util.AddNetworkString(MESSAGE)

local Hints = {
	Message = MESSAGE,
	Cooldowns = setmetatable({}, { __mode = "k" }),
	DefaultDuration = 7,
	DefaultCooldown = 120
}

DRP.Hints = Hints
DRP.Services.Register("hints", Hints)

local function ready(ply)
	return IsValid(ply) and ply:IsPlayer() and not ply:IsBot()
		and ply.DRPReady and ply:DRPReady()
end

function Hints:Send(ply, key, title, description, kind, duration, force)
	if not ready(ply) then return false end
	key = string.sub(string.lower(tostring(key or "general")), 1, 48)
	local cooldowns = self.Cooldowns[ply]
	if not cooldowns then cooldowns = {} self.Cooldowns[ply] = cooldowns end
	if not force and (cooldowns[key] or 0) > CurTime() then return false end
	cooldowns[key] = CurTime() + self.DefaultCooldown

	net.Start(self.Message)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteString(key)
		net.WriteUInt(math.Clamp(math.floor(tonumber(kind) or 0), 0, 3), 2)
		net.WriteUInt(math.Clamp(math.floor(tonumber(duration) or self.DefaultDuration), 3, 12), 4)
		net.WriteString(string.sub(tostring(title or "Gameplay hint"), 1, 72))
		net.WriteString(string.sub(tostring(description or ""), 1, 300))
	net.Send(ply)
	return true
end

function Hints:CivicGuidance(ply, force)
	local target = math.floor(tonumber(ply.DRPRoleGoalValue) or 0)
	local lawful = target == DRP.Job.POLICE or target == DRP.Job.MAYOR or target == DRP.Job.MEDIC
	local criminal = target == DRP.Job.THIEF or target == DRP.Job.HITMAN
		or target == DRP.Job.GANGSTER or target == DRP.Job.MOB_BOSS
		or target == DRP.Job.DRUG_DEALER or target == DRP.Job.KIDNAPPER
	local title, description, kind = "How to earn civic standing",
		"Raise civic through lawful arrests and defence outcomes, healing or reviving players, securing police evidence, and successful public service. Mugging, murder, forced drugging and criminal raids lower it.", 1
	if lawful then
		title = "Building a lawful reputation"
		description = "Heal or revive players, complete lawful arrests and defence outcomes, secure police evidence, or perform public service. These server-owned outcomes raise civic standing."
	elseif criminal then
		title = "Building a criminal identity"
		description = "Muggings, witnessed forced drugging, declared raids and criminal incident outcomes lower civic standing. Use only server-owned mechanics—random damage does not build a valid pathway."
		kind = 2
		if target == DRP.Job.HITMAN then
			description = "Reach −325 civic, or reach −200 and photograph three different people you personally killed in legitimate incidents. Frame their corpse with the ePhone camera to authenticate proof."
		end
	end
	return self:Send(ply, "civic_guidance_" .. target, title, description, kind, 7, force)
end

local function muggingHintKey(ply)
	return "hint:mugging:" .. (IsValid(ply) and ply:SteamID64() or "invalid")
end

function Hints:ScheduleMugging(ply, expectedJob)
	if not ready(ply) then return false end
	local key = muggingHintKey(ply)
	DRP.Deadlines.Cancel(key)
	local job = ply.DRPJob and ply:DRPJob() or nil
	if not istable(job) or job.isGovernment or not ply:DRPHasRoleCapability("canMug") then return false end
	expectedJob = math.floor(tonumber(expectedJob) or ply:DRPJobID())
	DRP.Deadlines.Schedule(key, CurTime() + 20, function()
		if not ready(ply) then return end
		local current = ply.DRPJob and ply:DRPJob() or nil
		if not istable(current) or ply:DRPJobID() ~= expectedJob or current.isGovernment or not ply:DRPHasRoleCapability("canMug") then return end
		Hints:Send(ply, "criminal_mugging_controls", "Mugging is available",
			"Aim at a stationary player and tap M to demand your saved amount. Hold M for three seconds to choose and issue a new demand.", 2, 7)
	end)
	return true
end

function Hints:Start()
	hook.Add("DRPPlayerReady", "DRP.Hints.Beginner", function(ply)
		if not ready(ply) then return end
		Hints:ScheduleMugging(ply)
		local newPlayer = math.max(0, tonumber(ply.DRPTotalPlaytimeBase) or 0) < 7200
		if not newPlayer then return end
		timer.Simple(5, function()
			Hints:Send(ply, "cursor_mode", "Using interface panels",
				"Press F3 or Z to toggle free cursor mode for HUD interfaces. Press it again to return control to normal movement.", 0, 7)
		end)
		timer.Simple(16, function()
			Hints:Send(ply, "automatic_objectives", "Follow the beginner guide",
				"Beginner objectives are pinned automatically. They teach property ownership, Hands inventory, mugging, healing and other server-owned mechanics without requiring an administrator.", 2, 7)
		end)
		timer.Simple(32, function() Hints:CivicGuidance(ply) end)
	end)
	hook.Add("DRPJobChanged", "DRP.Hints.MuggingRole", function(ply, _, current) Hints:ScheduleMugging(ply, current) end)
	hook.Add("PlayerDisconnected", "DRP.Hints.Disconnect", function(ply)
		Hints.Cooldowns[ply] = nil
		DRP.Deadlines.Cancel(muggingHintKey(ply))
	end)
	hook.Add("DRPCivicStandingChanged", "DRP.Hints.CivicProgress", function(ply)
		if ready(ply) and (tonumber(ply.DRPRoleGoalValue) or 0) > 0 then Hints:CivicGuidance(ply, false) end
	end)
	timer.Create("DRP.Hints.RoleGuidance", 180, 0, function()
		for _, ply in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do
			if ready(ply) and (tonumber(ply.DRPRoleGoalValue) or 0) > 0 then
				local goal = DRP.Objectives and DRP.Objectives.BuildRoleGoal and DRP.Objectives:BuildRoleGoal(ply)
				if goal and not goal.ready then Hints:CivicGuidance(ply, false) end
			end
		end
	end)
end

function Hints:Stop()
	hook.Remove("DRPPlayerReady", "DRP.Hints.Beginner")
	hook.Remove("DRPJobChanged", "DRP.Hints.MuggingRole")
	hook.Remove("PlayerDisconnected", "DRP.Hints.Disconnect")
	hook.Remove("DRPCivicStandingChanged", "DRP.Hints.CivicProgress")
	timer.Remove("DRP.Hints.RoleGuidance")
end
