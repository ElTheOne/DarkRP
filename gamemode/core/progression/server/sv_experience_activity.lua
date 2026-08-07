local Experience = DRP.Experience
local ACTIVE_REWARD_INTERVAL = 600
local ACTIVE_REWARD_AMOUNT = 50
local ACTIVE_GRACE = 20
local ACTIVE_TICK = 5
local AFK_THRESHOLD = 120
local ACTIVITY_SAMPLE_INTERVAL = 0.25

local function setAFK(ply, value)
	value = value == true
	if ply.DRPAFKState == value then return end
	ply.DRPAFKState = value
	if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.AFK) end
end

function Experience.TrackActivity(ply, move)
	if not IsValid(ply) or not ply:DRPReady() then return end
	local now = CurTime()
	if (ply.DRPNextActivitySample or 0) > now then return end
	ply.DRPNextActivitySample = now + ACTIVITY_SAMPLE_INTERVAL
	local angles = move:GetAngles()
	local previousPitch, previousYaw = ply.DRPLastActivityPitch, ply.DRPLastActivityYaw
	local looked = previousPitch == nil or math.abs(math.AngleDifference(angles.y, previousYaw)) > 0.25 or math.abs(math.AngleDifference(angles.p, previousPitch)) > 0.25
	local moved = math.abs(move:GetForwardSpeed()) > 1 or math.abs(move:GetSideSpeed()) > 1 or math.abs(move:GetUpSpeed()) > 1
	local acted = move:GetButtons() ~= 0
	ply.DRPLastActivityPitch, ply.DRPLastActivityYaw = angles.p, angles.y
	if moved or acted or looked then
		ply.DRPXPLastActivityAt = now
		if ply.DRPAFKState then setAFK(ply, false) end
		hook.Run("DRPPlayerActivity", ply, now)
	end
end
hook.Add("DRPPlayerReady", "DRP.Experience.StartActivity", function(ply)
	ply.DRPXPLastActivityAt = CurTime()
	ply.DRPXPActiveSeconds = 0
	ply.DRPXPActivityCheckedAt = CurTime()
	ply.DRPNextActivitySample = 0
	ply.DRPLastActivityPitch, ply.DRPLastActivityYaw = nil, nil
	setAFK(ply, false)
end)

function Experience:ProcessActivityRewards()
	local now = CurTime()
	for _, ply in ipairs(DRP.Players.List) do
		if IsValid(ply) and not ply:IsBot() and ply:DRPReady() then
			local previousCheck = ply.DRPXPActivityCheckedAt or now
			local elapsed = math.Clamp(now - previousCheck, 0, ACTIVE_TICK * 2)
			ply.DRPXPActivityCheckedAt = now
			setAFK(ply, now - (ply.DRPXPLastActivityAt or now) >= AFK_THRESHOLD)
			if now - (ply.DRPXPLastActivityAt or 0) <= ACTIVE_GRACE then
				ply.DRPXPActiveSeconds = (ply.DRPXPActiveSeconds or 0) + elapsed
				while ply.DRPXPActiveSeconds >= ACTIVE_REWARD_INTERVAL do
					ply.DRPXPActiveSeconds = ply.DRPXPActiveSeconds - ACTIVE_REWARD_INTERVAL
					if self:Add(ply, ACTIVE_REWARD_AMOUNT, "active_play", "10 minutes of active play", true) then
						DRP.Net.Notify(ply, "+50 XP — 10 minutes of active play.", 1)
					end
				end
			end
		end
	end
end

function Experience:Start()
	timer.Create("DRP.Experience.ActiveReward", ACTIVE_TICK, 0, function()
		if DRP.Experience then DRP.Experience:ProcessActivityRewards() end
	end)
end

function Experience:Stop()
	timer.Remove("DRP.Experience.ActiveReward")
end
