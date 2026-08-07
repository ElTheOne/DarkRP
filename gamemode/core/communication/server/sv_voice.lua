local Voice = {
	DefaultDistance = 850,
	MinimumDistance = 128,
	MaximumDistance = 4096
}

DRP.Voice = Voice
DRP.Services.Register("voice", Voice)

local enabled = CreateConVar(
	"drp_voice_proximity",
	"1",
	bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Restrict player voice to local proximity.",
	0,
	1
)

local distance = CreateConVar(
	"drp_voice_distance",
	tostring(Voice.DefaultDistance),
	bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Maximum distance at which local voice can be heard.",
	Voice.MinimumDistance,
	Voice.MaximumDistance
)

local deadVoice = CreateConVar(
	"drp_voice_dead",
	"1",
	bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Allow dead players to hear other nearby dead players.",
	0,
	1
)

function Voice:Distance()
	return math.Clamp(distance:GetFloat(), self.MinimumDistance, self.MaximumDistance)
end

function Voice:EffectivePosition(listener)
	local state = DRP.AdminMode and DRP.AdminMode.States and DRP.AdminMode.States[listener]
	if state and IsValid(state.spectating) then return state.spectating:EyePos() end
	return listener:EyePos()
end

function Voice:CanHear(listener, talker)
	if not IsValid(listener) or not listener:IsPlayer() or not IsValid(talker) or not talker:IsPlayer() then
		return false
	end
	if listener == talker then return true end
	if DRP.Kidnapping and DRP.Kidnapping:IsGagged(talker) then return false end
	-- Answered ePhone calls are server-owned remote voice channels. They are
	-- intentionally non-positional and bypass local proximity only for the
	-- two participants in the active call.
	if DRP.Phone and DRP.Phone:CanHearRemote(listener, talker) then return true, true end
	if not enabled:GetBool() then return true end
	if not listener:DRPReady() or not talker:DRPReady() then return false end

	-- Remote spectators are receive-only. This lets staff hear the area around
	-- the observed player without broadcasting from their hidden body.
	local talkerState = DRP.AdminMode and DRP.AdminMode.States and DRP.AdminMode.States[talker]
	if talkerState and IsValid(talkerState.spectating) then return false end

	local listenerAlive, talkerAlive = listener:Alive(), talker:Alive()
	if listenerAlive ~= talkerAlive then return false end
	if not listenerAlive and not deadVoice:GetBool() then return false end

	local maximum = self:Distance()
	return self:EffectivePosition(listener):DistToSqr(talker:EyePos()) <= maximum * maximum
end

function Voice:Start()
	hook.Add("PlayerCanHearPlayersVoice", "DRP.Voice.Proximity", function(listener, talker)
		if DRP.Kidnapping and DRP.Kidnapping:IsGagged(talker) then return false, false end
		if DRP.Phone and DRP.Phone:CanHearRemote(listener, talker) then
			return true, false
		end
		-- The second return value enables Source's native positional attenuation.
		return Voice:CanHear(listener, talker), enabled:GetBool()
	end)
end

function Voice:Stop()
	hook.Remove("PlayerCanHearPlayersVoice", "DRP.Voice.Proximity")
end

concommand.Add("drp_voice_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local message = string.format(
		"[DRP VOICE] proximity=%s distance=%d dead_voice=%s",
		enabled:GetBool() and "true" or "false",
		math.floor(Voice:Distance()),
		deadVoice:GetBool() and "true" or "false"
	)
	if IsValid(ply) then
		ply:ChatPrint(message)
	else
		print(message)
	end
end)
