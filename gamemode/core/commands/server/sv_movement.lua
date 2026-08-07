-- One command/movement dispatch boundary keeps inactive players on the
-- cheapest path and prevents every restriction module installing hot hooks.
local Movement = {}
DRP.Movement = Movement
DRP.Services.Register("movement", Movement)

local function hasCommandRestriction(ply)
	local legal = DRP.Legal
	local mode = DRP.AdminMode
	local drugState = DRP.Drugs and DRP.Drugs.States[ply]
	local adminState = mode and mode.States[ply]
	local kidnapped = DRP.Kidnapping and DRP.Kidnapping:IsKnockedOut(ply)
	local isTased = legal and (
		(isfunction(legal.IsTased) and legal.IsTased(ply))
		or (istable(legal.TasedUntil) and (legal.TasedUntil[ply] or 0) > CurTime())
	)
	return kidnapped or (legal and (legal.Arrested[ply] or legal.Cuffed[ply] or isTased))
		or (drugState and (drugState.fentanylUntil or 0) > CurTime())
		or (adminState and adminState.spectating)
		or ply.DRPAdminJailed == true
		or IsValid(ply.DRPArcadeMachine)
end

local function hasMoveRestriction(ply)
	local legal = DRP.Legal
	local drugState = DRP.Drugs and DRP.Drugs.States[ply]
	return (DRP.Kidnapping and DRP.Kidnapping:IsKnockedOut(ply))
		or (legal and legal.Cuffed[ply] ~= nil)
		or (drugState and ((drugState.fentanylUntil or 0) > CurTime()
			or (drugState.speedUntil or 0) > CurTime()
			or (drugState.speedWithdrawalUntil or 0) > CurTime()
			or (drugState.cocaineUntil or 0) > CurTime()))
		or (DRP.Mugging and DRP.Mugging.ByVictim[ply] ~= nil)
		or (DRP.Drugs and DRP.Drugs.ForceFeeds[ply] ~= nil)
		or IsValid(ply.DRPArcadeMachine)
end

hook.Add("StartCommand", "DRP.Movement.DispatchCommand", function(ply, command)
	if not hasCommandRestriction(ply) then return end
	if DRP.AdminMode and isfunction(DRP.AdminMode.ApplyCommand) then DRP.AdminMode.ApplyCommand(ply, command) end
	if DRP.Legal and isfunction(DRP.Legal.ApplyCommand) then DRP.Legal.ApplyCommand(ply, command) end
	if DRP.Drugs and isfunction(DRP.Drugs.ApplyCommand) then DRP.Drugs.ApplyCommand(ply, command) end
	if DRP.Kidnapping and isfunction(DRP.Kidnapping.ApplyCommand) then DRP.Kidnapping.ApplyCommand(ply, command) end
	if DRP.Arcade and DRP.Arcade.ApplyCommand then DRP.Arcade:ApplyCommand(ply, command) end
end)

hook.Add("SetupMove", "DRP.Movement.DispatchMove", function(ply, move)
	if DRP.Experience and DRP.Experience.TrackActivity then DRP.Experience.TrackActivity(ply, move) end
	if not hasMoveRestriction(ply) then return end
	if DRP.Legal and isfunction(DRP.Legal.ApplyMove) then DRP.Legal.ApplyMove(ply, move) end
	if DRP.Drugs and isfunction(DRP.Drugs.ApplyMove) then DRP.Drugs.ApplyMove(ply, move) end
	if DRP.Kidnapping and isfunction(DRP.Kidnapping.ApplyMove) then DRP.Kidnapping.ApplyMove(ply, move) end
	if DRP.Mugging and isfunction(DRP.Mugging.ApplyVictimMove) then DRP.Mugging.ApplyVictimMove(ply) end
	if DRP.Arcade and DRP.Arcade.ApplyMove then DRP.Arcade:ApplyMove(ply, move) end
end)

function Movement:Start() end
function Movement:Stop() end
