local Massie = {
	Duration = 30,
	CivicPenalty = 400,
	Grants = {},
	Pending = setmetatable({}, { __mode = "k" }),
	Active = setmetatable({}, { __mode = "k" }),
	DataPath = "darkrp/massie_access.json"
}

DRP.Massie = Massie
DRP.Services.Register("massie", Massie)

local CONFIRM = "drp_massie_confirm_v1"
local ACCEPT = "drp_massie_accept_v1"
local ACCESS_SET = "drp_massie_access_set_v1"
util.AddNetworkString(CONFIRM)
util.AddNetworkString(ACCEPT)
util.AddNetworkString(ACCESS_SET)

local function validSteamID64(value)
	return isstring(value) and #value == 17 and string.match(value, "^%d+$") ~= nil
end

function Massie:HasGrant(value)
	local steamID64 = IsValid(value) and value:SteamID64() or tostring(value or "")
	return self.Grants[steamID64] ~= nil
end

function Massie:CanUse(ply)
	if not IsValid(ply) or not ply:DRPReady() then return false end
	return DRP.AdminRankLevel(DRP.Admin.RankKey(ply)) >= DRP.AdminRankLevel("headadmin") or self:HasGrant(ply)
end

function Massie:Save()
	file.CreateDir("darkrp")
	file.Write(self.DataPath, util.TableToJSON(self.Grants, true))
end

function Massie:Request(ply)
	if not self:CanUse(ply) then DRP.Net.Notify(ply, "The /massie feature requires HeadAdmin+ or an individual grant.", 3) return false end
	if not ply:Alive() then DRP.Net.Notify(ply, "You must be alive to begin a massie.", 3) return false end
	if self.Active[ply] and DRP.Incidents.Get(self.Active[ply]) then DRP.Net.Notify(ply, "Your massie is already active.", 3) return false end
	local targets = 0
	for _, target in player.Iterator() do if target ~= ply and target:DRPReady() and target:Alive() then targets = targets + 1 end end
	if targets == 0 then DRP.Net.Notify(ply, "At least one other active player is required.", 3) return false end
	self.Pending[ply] = CurTime() + 15
	net.Start(CONFIRM)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.Send(ply)
	return true
end

function Massie:Begin(ply)
	if not self:CanUse(ply) or not ply:Alive() then return false end
	if (self.Pending[ply] or 0) < CurTime() then DRP.Net.Notify(ply, "The massie confirmation expired. Use /massie again.", 3) return false end
	self.Pending[ply] = nil
	if self.Active[ply] and DRP.Incidents.Get(self.Active[ply]) then return false end
	local hunters = {}
	for _, target in player.Iterator() do if target ~= ply and target:DRPReady() and target:Alive() then hunters[#hunters + 1] = target end end
	if #hunters == 0 then return false end
	local deadline = CurTime() + self.Duration
	local victim = hunters[1]
	local incident = DRP.Incidents.Create("massie", {
		state = "active",
		reason = ply:DRPName() .. " committed a massie and may be attacked by everyone",
		instigator = ply,
		victim = victim,
		participants = { instigator = ply, victim = victim },
		deadline = deadline,
		metadata = { duration = self.Duration }
	})
	if not incident then return false end
	for index = 2, #hunters do DRP.Incidents.AddParticipant(incident, "hunter", hunters[index]) end
	for _, hunter in ipairs(hunters) do DRP.Incidents.Grant(incident, "damage", hunter, ply, "Massie target is vulnerable", deadline) end
	self.Active[ply] = incident.id
	ply:SetNW2Float("DRPMassieUntil", deadline)
	if DRP.Civic then DRP.Civic:Adjust(ply, -self.CivicPenalty, "committed a massie") end
	DRP.Incidents.AddEvidence(incident, "massie_confirmed", ply, victim, #hunters .. " players authorized to attack for " .. self.Duration .. " seconds")
	for _, target in player.Iterator() do
		DRP.Net.Notify(target, ply:DRPName() .. " committed a massie. Everyone may attack them for " .. self.Duration .. " seconds.", 2)
	end
	if DRP.Audit then DRP.Audit.Log(ply, "massie_started", victim, "incident #" .. incident.id .. "; civic -" .. self.CivicPenalty) end
	return true
end

function Massie:EnrollHunter(ply)
	if not IsValid(ply) or not ply:DRPReady() or not ply:Alive() then return end
	for initiator, incidentID in pairs(self.Active) do
		local incident = IsValid(initiator) and DRP.Incidents.Get(incidentID) or nil
		if incident and initiator ~= ply and (incident.deadline or 0) > CurTime() then
			if not DRP.Incidents.Role(incident, ply) then DRP.Incidents.AddParticipant(incident, "hunter", ply) end
			DRP.Incidents.Grant(incident, "damage", ply, initiator, "Massie target is vulnerable", incident.deadline)
		end
	end
end

function Massie:Start()
	local decoded = util.JSONToTable(file.Read(self.DataPath, "DATA") or "", false, true)
	if not istable(decoded) then return end
	for steamID64, record in pairs(decoded) do
		if validSteamID64(steamID64) then
			self.Grants[steamID64] = { name = string.sub(tostring(istable(record) and record.name or record or steamID64), 1, 64) }
		end
	end
end

function Massie:Stop() self:Save() end

DRP.Incidents.RegisterType("massie", {
	initial = "active",
	outcomes = {
		survived = { winner = "instigator", loser = "victim" },
		no_hunters = { winner = "instigator", loser = "victim" },
		default = { winner = "victim", loser = "instigator" }
	}
})

DRP.Incidents.Definitions.massie.onDeadline = function(incident)
	DRP.Incidents.Resolve(incident, "survived", "Massie initiator survived the 30-second hunt")
	return true
end

DRP.Incidents.Definitions.massie.onParticipantUnavailable = function(incident, ply, resolution, detail)
	if ply == incident.instigator then
		DRP.Incidents.Resolve(incident, resolution == "participant_died" and "initiator_killed" or "initiator_unavailable", detail or "Massie initiator became unavailable")
		return true
	end
	DRP.Incidents.RemoveParticipant(incident, ply, detail or "Hunter unavailable")
	if ply == incident.victim then
		for _, participant in ipairs(incident.participants) do
			if participant.player ~= incident.instigator and IsValid(participant.player) then incident.victim = participant.player return true end
		end
		DRP.Incidents.Resolve(incident, "no_hunters", "No eligible hunters remained")
	end
	return true
end

hook.Add("DRPIncidentResolved", "DRP.Massie.Resolved", function(incident)
	if incident.type ~= "massie" then return end
	if IsValid(incident.instigator) then
		Massie.Active[incident.instigator] = nil
		incident.instigator:SetNW2Float("DRPMassieUntil", 0)
	end
end)

hook.Add("DRPPlayerReady", "DRP.Massie.JoiningHunter", function(ply) Massie:EnrollHunter(ply) end)
hook.Add("PlayerSpawn", "DRP.Massie.RespawnedHunter", function(ply)
	timer.Simple(0, function() if IsValid(ply) then Massie:EnrollHunter(ply) end end)
end)

DRP.Net.Receive(ACCEPT, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "massie_accept", 1, 2) then return end
	Massie:Begin(ply)
end)

DRP.Net.Receive(ACCESS_SET, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "massie_access_set", 0.5, 3) then return end
	local steamID64 = string.sub(net.ReadString(), 1, 17)
	local enabled = net.ReadBool()
	if not validSteamID64(steamID64) or DRP.AdminRankLevel(DRP.Admin.RankKey(ply)) < DRP.AdminRankLevel("headadmin") then return end
	local target = DRP.Players.Online(steamID64)
	local targetRank = DRP.Admin.RankKey(steamID64)
	if not DRP.Admin.IsOwner(ply) and DRP.AdminRankLevel(targetRank) >= DRP.AdminRankLevel(DRP.Admin.RankKey(ply)) then
		DRP.Net.Notify(ply, "You cannot change special access for an equal or higher rank.", 3)
		return
	end
	if enabled then
		local previous = Massie.Grants[steamID64]
		Massie.Grants[steamID64] = { name = IsValid(target) and target:Nick() or (previous and previous.name or steamID64) }
	else
		Massie.Grants[steamID64] = nil
	end
	Massie:Save()
	DRP.Net.Notify(ply, enabled and "Massie access granted." or "Massie access revoked.", 1)
	if DRP.Audit then DRP.Audit.Log(ply, enabled and "massie_access_granted" or "massie_access_revoked", target or steamID64) end
	DRP.Admin.SendSnapshot(ply)
end)
