local Social = {
	ActiveByActor = setmetatable({}, { __mode = "k" }),
	ActiveByTarget = setmetatable({}, { __mode = "k" }),
	PairCooldowns = {},
	NextID = 1,
	BodyguardSeconds = 180,
	BodyguardRange = 850,
	CourierRange = 150
}

DRP.SocialObjectives = Social
DRP.Services.Register("social_objectives", Social)
DRP.Services.DependsOn("social_objectives", { "objectives", "incidents", "hits" })

local function ready(ply)
	return IsValid(ply) and ply:IsPlayer() and not ply:IsBot() and ply:Alive()
		and ply.DRPReady and ply:DRPReady()
		and not (DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(ply))
end

local function pairKey(first, second)
	if not IsValid(first) or not IsValid(second) then return "" end
	local a, b = first:SteamID64(), second:SteamID64()
	if a > b then a, b = b, a end
	return a .. ":" .. b
end

function Social:CanOffer(ply, kind)
	if not ready(ply) or self.ActiveByActor[ply] or self.ActiveByTarget[ply] then return false end
	if kind == "hit" and not ply:DRPHasRoleCapability("canExecuteHits") then return false end
	local count = 0
	for _, candidate in ipairs((DRP.Players and DRP.Players.List) or {}) do
		if ready(candidate) and candidate ~= ply and not self.ActiveByActor[candidate]
			and not self.ActiveByTarget[candidate]
			and (self.PairCooldowns[pairKey(ply, candidate)] or 0) <= CurTime() then
			count = count + 1
		end
	end
	return count > 0
end

function Social:SelectTarget(actor)
	local candidates = {}
	for _, candidate in ipairs((DRP.Players and DRP.Players.List) or {}) do
		if ready(candidate) and candidate ~= actor and not self.ActiveByActor[candidate]
			and not self.ActiveByTarget[candidate]
			and (self.PairCooldowns[pairKey(actor, candidate)] or 0) <= CurTime() then
			candidates[#candidates + 1] = candidate
		end
	end
	if #candidates == 0 then return nil end
	return candidates[math.random(1, #candidates)]
end

local function deadlineKey(record)
	return "social_objective:" .. record.id
end

function Social:Remove(record)
	if not record or record.finished then return false end
	record.finished = true
	DRP.Deadlines.Cancel(deadlineKey(record))
	if IsValid(record.actor) and self.ActiveByActor[record.actor] == record then self.ActiveByActor[record.actor] = nil end
	if IsValid(record.target) and self.ActiveByTarget[record.target] == record then self.ActiveByTarget[record.target] = nil end
	self.PairCooldowns[record.pair] = CurTime() + 20 * 60
	return true
end

function Social:Cancel(record, reason, preserveObjective)
	if not self:Remove(record) then return false end
	if record.kind == "hit" and record.hitRecord and not record.hitRecord.finished then
		DRP.Hits.Finish(record.hitRecord, false, reason or "social contract cancelled")
	end
	if not preserveObjective and IsValid(record.actor) and DRP.Objectives then
		DRP.Objectives:CancelActive(record.actor, record.objective, reason or "Assigned player became unavailable", 180)
	end
	if IsValid(record.actor) then DRP.Net.Notify(record.actor, reason or "Social objective cancelled.", 2) end
	return true
end

function Social:Complete(record)
	if not self:Remove(record) then return false end
	if IsValid(record.actor) and DRP.Objectives then
		DRP.Objectives:Emit(record.actor, record.event, 1)
	end
	if IsValid(record.target) then
		DRP.Net.Notify(record.target, record.kind == "courier"
			and (record.actor:DRPName() .. " delivered a secure dispatch to you.")
			or (record.actor:DRPName() .. " completed their protection assignment."), 1)
	end
	return true
end

function Social:TickBodyguard(record)
	if record.finished then return end
	if not ready(record.actor) or not ready(record.target) then
		self:Cancel(record, "The protection assignment ended because a participant became unavailable.")
		return
	end
	if record.actor:GetPos():DistToSqr(record.target:GetPos()) <= self.BodyguardRange * self.BodyguardRange then
		record.progress = record.progress + 1
	end
	if record.progress >= self.BodyguardSeconds then self:Complete(record) return end
	DRP.Deadlines.Schedule(deadlineKey(record), CurTime() + 1, function() self:TickBodyguard(record) end)
end

function Social:Begin(actor, kind, objectiveKey)
	if not self:CanOffer(actor, kind) then return false, "No eligible player is currently available for that assignment." end
	local target = self:SelectTarget(actor)
	if not target then return false, "No eligible player is currently available for that assignment." end
	local record = {
		id = self.NextID, kind = kind, actor = actor, target = target,
		objective = objectiveKey, event = "social_" .. kind .. "_completed",
		started = CurTime(), progress = 0, pair = pairKey(actor, target)
	}
	self.NextID = self.NextID + 1
	self.ActiveByActor[actor], self.ActiveByTarget[target] = record, record

	if kind == "hit" then
		local hitRecord, reason = DRP.Hits.StartGenerated(actor, target, objectiveKey)
		if not hitRecord then self:Remove(record) return false, reason or "The hit contract could not be created." end
		record.hitRecord = hitRecord
		hitRecord.socialRecord = record
		DRP.Net.Notify(actor, "Objective target: " .. target:DRPName() .. ". The target knows a contract exists, but not your identity.", 2)
	elseif kind == "bodyguard" then
		DRP.Net.Notify(actor, "Protection assignment: remain near " .. target:DRPName() .. " for " .. self.BodyguardSeconds .. " active seconds.", 1)
		DRP.Net.Notify(target, actor:DRPName() .. " has been assigned as your temporary bodyguard.", 0)
		DRP.Deadlines.Schedule(deadlineKey(record), CurTime() + 1, function() self:TickBodyguard(record) end)
	elseif kind == "courier" then
		DRP.Net.Notify(actor, "Secure dispatch: find " .. target:DRPName() .. ", look at them and press E within close range.", 1)
		DRP.Net.Notify(target, "A courier has a secure dispatch for you. Their identity is not disclosed until delivery.", 0)
	else
		self:Remove(record)
		return false, "Unknown social assignment."
	end
	if DRP.Audit then DRP.Audit.Log(actor, "social_objective_started", target, kind .. " #" .. record.id) end
	return true
end

function Social:HitFinished(hitRecord, success, reason)
	local record = hitRecord and hitRecord.socialRecord
	if not record or record.finished then return end
	if success then
		self:Remove(record)
		if IsValid(record.actor) and DRP.Objectives then DRP.Objectives:Emit(record.actor, record.event, 1) end
	else
		self:Cancel(record, reason or "The assigned hit failed.", false)
	end
end

function Social:Start()
	hook.Add("KeyPress", "DRP.SocialObjectives.Courier", function(ply, key)
		if key ~= IN_USE then return end
		local record = Social.ActiveByActor[ply]
		if not record or record.kind ~= "courier" or not ready(record.target) then return end
		local trace = ply:GetEyeTrace()
		if trace.Entity == record.target and ply:GetPos():DistToSqr(record.target:GetPos()) <= Social.CourierRange * Social.CourierRange then
			Social:Complete(record)
		end
	end)
	hook.Add("PlayerDeath", "DRP.SocialObjectives.Death", function(ply)
		local record = Social.ActiveByActor[ply] or Social.ActiveByTarget[ply]
		if record and record.kind ~= "hit" then Social:Cancel(record, "A participant died before the assignment was completed.") end
	end)
	for _, event in ipairs({ "PlayerDisconnected", "DRPJobChanged" }) do
		hook.Add(event, "DRP.SocialObjectives." .. event, function(ply)
			local record = Social.ActiveByActor[ply] or Social.ActiveByTarget[ply]
			if record then Social:Cancel(record, "A participant became unavailable.") end
		end)
	end
	hook.Add("DRPObjectiveCancelled", "DRP.SocialObjectives.Cancelled", function(ply, key)
		local record = Social.ActiveByActor[ply]
		if record and record.objective == key then Social:Cancel(record, "Objective abandoned.", true) end
	end)
end

function Social:Stop()
	local records = {}
	for _, record in pairs(self.ActiveByActor) do records[#records + 1] = record end
	for _, record in ipairs(records) do self:Cancel(record, "Server shutting down.", true) end
	for _, event in ipairs({ "KeyPress", "PlayerDeath", "PlayerDisconnected", "DRPJobChanged", "DRPObjectiveCancelled" }) do
		hook.Remove(event, "DRP.SocialObjectives." .. (event == "KeyPress" and "Courier" or event == "PlayerDeath" and "Death" or event == "DRPObjectiveCancelled" and "Cancelled" or event))
	end
end

