local Treasury = {
	Entity = nil,
	ActiveIncidentID = nil,
	RaidDuration = 90,
	RaidCooldown = 600,
	MinimumBalance = 1000,
	LootFraction = 0.25,
	LootCap = 100000,
	NextRaidUnix = 0,
	Claims = setmetatable({}, { __mode = "k" }),
	DataPath = "darkrp/treasury_raid_state.json"
}

DRP.Treasury = Treasury
DRP.Services.Register("treasury", Treasury)

local function adminModeActive(ply)
	return DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(ply)
end

local function readyAlive(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:Alive() and ply.DRPReady and ply:DRPReady()
end

local function canRaid(ply)
	return readyAlive(ply) and not adminModeActive(ply) and not ply:DRPJob().isGovernment
		and ply.DRPHasRoleCapability and ply:DRPHasRoleCapability("canRaid")
end

local function teamShareEligible(ply, side)
	if side == "instigator" then return canRaid(ply) end
	return side == "victim" and readyAlive(ply) and not adminModeActive(ply)
		and ply.DRPJob and ply:DRPJob().isPolice == true
end

local function sideFor(incident, ply)
	if not incident or not IsValid(ply) then return nil end
	if ply == incident.instigator then return "instigator" end
	if ply == incident.victim then return "victim" end
	return incident.participantSides and incident.participantSides[ply] or nil
end

local function participantsOnSide(incident, side, requireAlive)
	local found, seen = {}, {}
	for _, participant in ipairs(incident and incident.participants or {}) do
		local ply = participant.player
		if IsValid(ply) and not seen[ply] and sideFor(incident, ply) == side
			and (not requireAlive or readyAlive(ply)) then
			seen[ply] = true
			found[#found + 1] = ply
		end
	end
	table.sort(found, function(first, second) return first:SteamID64() < second:SteamID64() end)
	return found
end

function Treasury:SaveState()
	file.CreateDir("darkrp")
	file.Write(self.DataPath, util.TableToJSON({ next_raid_unix = math.max(0, math.floor(self.NextRaidUnix or 0)) }, false))
end

function Treasury:ActiveIncident()
	local incident = self.ActiveIncidentID and DRP.Incidents.Get(self.ActiveIncidentID) or nil
	if not incident then self.ActiveIncidentID = nil end
	return incident
end

function Treasury:UpdateEntityState()
	local entity = self.Entity
	if not IsValid(entity) then return end
	local incident = self:ActiveIncident()
	entity:SetNW2Bool("DRPTreasuryVault", true)
	entity:SetNW2Bool("DRPTreasuryRaidActive", incident ~= nil)
	entity:SetNW2Int("DRPTreasuryIncident", incident and incident.id or 0)
	entity:SetNW2Float("DRPTreasuryDeadline", incident and (incident.deadline or 0) or 0)
	entity:SetNW2Int("DRPTreasuryCooldownUnix", math.max(0, math.floor(self.NextRaidUnix or 0)))
end

function Treasury:RegisterEntity(entity)
	if not IsValid(entity) or entity:GetClass() ~= "drp_treasury_vault" then return false, "Invalid treasury entity" end
	if IsValid(self.Entity) and self.Entity ~= entity then return false, "A Treasury Vault already exists" end
	self.Entity = entity
	entity.DRPTreasuryVault = true
	self:UpdateEntityState()
	return true
end

function Treasury:Status()
	local incident = self:ActiveIncident()
	return {
		balance = DRP.Government and DRP.Government.GetTreasury() or 0,
		entity = IsValid(self.Entity) and self.Entity or nil,
		incident = incident and incident.id or 0,
		remaining = incident and math.max(0, math.ceil((incident.deadline or CurTime()) - CurTime())) or 0,
		cooldown = math.max(0, math.floor((self.NextRaidUnix or 0) - os.time()))
	}
end

function Treasury:LootForBalance(balance)
	return math.min(math.floor(math.max(0, tonumber(balance) or 0) * self.LootFraction), self.LootCap)
end

function Treasury:BuildLootShares(incident, amount, raiders)
	amount = math.max(0, math.floor(tonumber(amount) or 0))
	if amount <= 0 or not istable(raiders) or #raiders == 0 then return {} end
	local preferred = incident and incident.instigator or nil
	local preferredPresent = false
	for _, raider in ipairs(raiders) do
		if raider == preferred then preferredPresent = true break end
	end
	if not preferredPresent then preferred = raiders[1] end
	local base = math.floor(amount / #raiders)
	local remainder = amount - base * #raiders
	local shares = {}
	for _, raider in ipairs(raiders) do
		shares[#shares + 1] = {
			player = raider,
			amount = base + (raider == preferred and remainder or 0)
		}
	end
	return shares
end

function Treasury:GrantRaidCombat(incident)
	if not incident or not DRP.Incidents.Get(incident.id) then return false end
	local attackers = participantsOnSide(incident, "instigator", false)
	local defenders = participantsOnSide(incident, "victim", false)
	local granted = false
	for _, attacker in ipairs(attackers) do
		for _, defender in ipairs(defenders) do
			if readyAlive(attacker) and readyAlive(defender) then
				granted = DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, attacker, defender, "Active treasury raid", incident.deadline) or granted
				granted = DRP.Incidents.Grant(incident, DRP.IncidentAction.DAMAGE, defender, attacker, "Defending the government treasury", incident.deadline) or granted
			end
		end
	end
	return granted
end

function Treasury:StartOrJoinRaid(ply, entity)
	entity = IsValid(entity) and entity or self.Entity
	if entity ~= self.Entity or not IsValid(entity) or ply:GetPos():DistToSqr(entity:GetPos()) > 65536 then
		DRP.Net.Notify(ply, "Stand near the active Treasury Vault.", 3)
		return false
	end
	if not canRaid(ply) then
		DRP.Net.Notify(ply, adminModeActive(ply) and "Leave admin mode before participating in a treasury raid." or "Your role identity cannot raid the treasury.", 3)
		return false
	end

	local incident = self:ActiveIncident()
	if incident then
		if DRP.Incidents.Role(incident, ply) then
			DRP.Net.Notify(ply, "You are already participating in treasury raid #" .. incident.id .. ".", 0)
			return false
		end
		if not DRP.Incidents.AddParticipant(incident, "raider", ply, "instigator") then return false end
		self:GrantRaidCombat(incident)
		DRP.Net.Notify(ply, "Joined treasury raid #" .. incident.id .. ". The original countdown was not reset.", 1)
		return true
	end

	if #DRP.Incidents.ForPlayer(ply, "treasury_raid") > 0 then
		DRP.Net.Notify(ply, "You are already involved in a treasury raid.", 3)
		return false
	end
	if os.time() < (self.NextRaidUnix or 0) then
		DRP.Net.Notify(ply, "The Treasury Vault is secured for another " .. (self.NextRaidUnix - os.time()) .. " seconds.", 3)
		return false
	end
	local balance = DRP.Government and DRP.Government.GetTreasury() or 0
	if balance < self.MinimumBalance then
		DRP.Net.Notify(ply, "The treasury needs at least $" .. string.Comma(self.MinimumBalance) .. " before it can be raided.", 3)
		return false
	end

	local defender
	for _, candidate in ipairs(DRP.Players.List or {}) do
		if candidate ~= ply and readyAlive(candidate) and not adminModeActive(candidate) and candidate:DRPJob().isPolice then
			defender = candidate
			break
		end
	end
	if not IsValid(defender) then
		DRP.Net.Notify(ply, "At least one active police defender is required.", 3)
		return false
	end

	incident = DRP.Incidents.Create("treasury_raid", {
		state = "active",
		reason = ply:DRPName() .. " began raiding the government treasury",
		instigator = ply,
		victim = defender,
		participants = { raider = ply, defender = defender },
		deadline = CurTime() + self.RaidDuration,
		teamShareFilter = teamShareEligible,
		metadata = { treasury_entity = entity:EntIndex(), starting_balance = balance }
	})
	if not incident then return false end
	incident.treasuryEntity = entity
	self.ActiveIncidentID = incident.id
	self.NextRaidUnix = os.time() + self.RaidCooldown
	self:SaveState()
	for _, candidate in ipairs(DRP.Players.List or {}) do
		if candidate ~= defender and readyAlive(candidate) and not adminModeActive(candidate) and candidate:DRPJob().isPolice
			and not DRP.Incidents.Role(incident, candidate) then
			DRP.Incidents.AddParticipant(incident, "defender", candidate, "victim")
		end
	end
	self:GrantRaidCombat(incident)
	self:UpdateEntityState()
	DRP.Incidents.AddEvidence(incident, "treasury_raid_started", ply, defender,
		self.RaidDuration .. " second hold; live treasury $" .. balance)
	for _, candidate in ipairs(DRP.Players.List or {}) do
		if candidate:DRPReady() then DRP.Net.Notify(candidate, "Treasury raid #" .. incident.id .. " started. Raiders must hold the vault for " .. self.RaidDuration .. " seconds.", 2) end
	end
	if DRP.Audit then DRP.Audit.Log(ply, "treasury_raid_started", defender, "incident #" .. incident.id .. " balance $" .. balance) end
	return true
end

function Treasury:RefundClaim(entity, amount, reason)
	local claim = self.Claims[entity]
	if claim then self.Claims[entity] = nil end
	local funded = claim and math.max(0, math.floor(tonumber(claim.funded) or 0)) or math.max(0, math.floor(tonumber(amount) or 0))
	if not DRP.Government or funded <= 0 then return false end
	DRP.Government.DepositTreasury(funded, reason or "unclaimed treasury raid money refunded", true)
	DRP.Government.Save()
	if DRP.Audit then DRP.Audit.Log(nil, "treasury_raid_loot_refunded", entity, funded) end
	return true
end

function Treasury:SpawnLoot(incident, amount, raiders)
	if not DRP.Money or not DRP.Money.SpawnSystemDrop or not IsValid(self.Entity) then return 0 end
	local shares = self:BuildLootShares(incident, amount, raiders)
	local spawned = 0
	for index, claim in ipairs(shares) do
		local raider, ordinaryShare = claim.player, claim.amount
		local share = DRP.Supporter and DRP.Supporter.ApplyReward(raider, ordinaryShare) or ordinaryShare
		local angle = (index - 1) * (360 / #shares)
		local position = self.Entity:GetPos() + Vector(math.cos(math.rad(angle)) * 58, math.sin(math.rad(angle)) * 58, 18)
		local entity = DRP.Money.SpawnSystemDrop(share, position, { [raider:SteamID64()] = true }, {
			source = "treasury raid #" .. incident.id,
			expires = 180,
			onRefund = function(drop, refundAmount, refundReason)
				Treasury:RefundClaim(drop, refundAmount, refundReason)
			end
		})
		if IsValid(entity) then
			self.Claims[entity] = { amount = share, funded = ordinaryShare, bonus = share - ordinaryShare, incident = incident.id, owner = raider:SteamID64() }
			spawned = spawned + share
		else
			self:RefundClaim(nil, ordinaryShare, "failed treasury raid cash spawn refunded")
		end
	end
	return spawned
end

function Treasury:ResolveRaid(incident, resolution, detail)
	if not incident or incident.id ~= self.ActiveIncidentID or not DRP.Incidents.Get(incident.id) then return false end
	if resolution ~= "raiders_victory" then
		return DRP.Incidents.Resolve(incident, "defenders_victory", detail or "Government defenders secured the Treasury Vault")
	end
	local raiders = participantsOnSide(incident, "instigator", true)
	if #raiders == 0 then return DRP.Incidents.Resolve(incident, "defenders_victory", "No surviving raiders remained to claim the treasury") end
	if not DRP.Money or not DRP.Money.SpawnSystemDrop then
		return DRP.Incidents.Resolve(incident, "defenders_victory", "Treasury cash service was unavailable")
	end
	local balance = DRP.Government.GetTreasury()
	local loot = self:LootForBalance(balance)
	if loot <= 0 then return DRP.Incidents.Resolve(incident, "defenders_victory", "The treasury was empty when the raid completed") end
	if not DRP.Government.WithdrawTreasury(loot, "treasury raid #" .. incident.id, true) then
		return DRP.Incidents.Resolve(incident, "defenders_victory", "Treasury settlement failed because the balance changed")
	end
	local spawned = self:SpawnLoot(incident, loot, raiders)
	DRP.Government.Save()
	DRP.Incidents.AddEvidence(incident, "treasury_loot_released", incident.instigator, incident.victim,
		"$" .. spawned .. " split between " .. #raiders .. " surviving raiders")
	if DRP.Audit then DRP.Audit.Log(incident.instigator, "treasury_raid_loot", incident.victim, "$" .. spawned .. " paid from $" .. loot .. " treasury funding; incident #" .. incident.id) end
	for _, candidate in ipairs(DRP.Players.List or {}) do
		if candidate:DRPReady() then DRP.Net.Notify(candidate, "Treasury raid #" .. incident.id .. " succeeded. $" .. string.Comma(spawned) .. " was released as reserved cash.", 2) end
	end
	return DRP.Incidents.Resolve(incident, "raiders_victory", detail or ("Raiders held the vault and stole $" .. spawned))
end

function Treasury:Use(ply, entity)
	if not readyAlive(ply) or entity ~= self.Entity or ply:GetPos():DistToSqr(entity:GetPos()) > 65536 then return false end
	if ply:DRPJob().isGovernment then
		local status = self:Status()
		DRP.Net.Notify(ply, "Treasury $" .. string.Comma(status.balance)
			.. (status.incident > 0 and (" — RAID #" .. status.incident .. " " .. status.remaining .. "s")
				or (status.cooldown > 0 and (" — secured " .. status.cooldown .. "s") or " — secure")), 0)
		return true
	end
	if canRaid(ply) then return self:StartOrJoinRaid(ply, entity) end
	DRP.Net.Notify(ply, "The vault contains the public treasury. Only raid-capable roles can attack it.", 3)
	return false
end

function Treasury:Start()
	local state = util.JSONToTable(file.Read(self.DataPath, "DATA") or "")
	self.NextRaidUnix = istable(state) and math.max(0, math.floor(tonumber(state.next_raid_unix) or 0)) or 0
end

function Treasury:Stop()
	for entity in pairs(self.Claims) do
		if IsValid(entity) and DRP.Money and DRP.Money.RefundSystemDrop then
			DRP.Money.RefundSystemDrop(entity, "server shutdown treasury claim refund")
		end
	end
	self:SaveState()
end

DRP.Incidents.RegisterType("treasury_raid", {
	initial = "active",
	outcomes = {
		raiders_victory = { winner = "instigator", loser = "victim" },
		default = { winner = "victim", loser = "instigator" }
	}
})

DRP.Incidents.Definitions.treasury_raid.onDeadline = function(incident)
	Treasury:ResolveRaid(incident, "raiders_victory", "Raiders held the Treasury Vault for the full countdown")
	return true
end

DRP.Incidents.Definitions.treasury_raid.onParticipantUnavailable = function(incident, ply, resolution, detail)
	local side = sideFor(incident, ply)
	if side == "victim" and resolution == "participant_died" then
		DRP.Incidents.AddEvidence(incident, "defender_downed", ply, nil, "Police defender may return after respawning")
		return true
	end
	DRP.Incidents.RemoveParticipant(incident, ply, detail or "Participant unavailable")
	local remaining = participantsOnSide(incident, side, false)
	if #remaining > 0 then
		if side == "instigator" and incident.instigator == ply then incident.instigator = remaining[1] end
		if side == "victim" and incident.victim == ply then incident.victim = remaining[1] end
		return true
	end
	Treasury:ResolveRaid(incident, "defenders_victory", side == "instigator" and "All treasury raiders were eliminated" or "Raid cancelled because no police defenders remained")
	return true
end

hook.Add("DRPIncidentResolved", "DRP.Treasury.RaidResolved", function(incident)
	if not incident or incident.type ~= "treasury_raid" then return end
	if Treasury.ActiveIncidentID == incident.id then Treasury.ActiveIncidentID = nil end
	Treasury:UpdateEntityState()
end)

hook.Add("EntityRemoved", "DRP.Treasury.EntityRemoved", function(entity)
	if entity ~= Treasury.Entity then return end
	local incident = Treasury:ActiveIncident()
	Treasury.Entity = nil
	if incident then Treasury:ResolveRaid(incident, "defenders_victory", "The Treasury Vault became unavailable") end
end)

hook.Add("PhysgunPickup", "DRP.Treasury.LockDuringRaid", function(_, entity)
	if entity == Treasury.Entity and Treasury:ActiveIncident() then return false end
end)

hook.Add("CanTool", "DRP.Treasury.LockDuringRaid", function(_, trace)
	if trace and trace.Entity == Treasury.Entity and Treasury:ActiveIncident() then return false end
end)

hook.Add("CanProperty", "DRP.Treasury.LockDuringRaid", function(_, _, entity)
	if entity == Treasury.Entity and Treasury:ActiveIncident() then return false end
end)

hook.Add("GravGunPickupAllowed", "DRP.Treasury.LockDuringRaid", function(_, entity)
	if entity == Treasury.Entity and Treasury:ActiveIncident() then return false end
end)

hook.Add("CanPlayerUnfreeze", "DRP.Treasury.LockDuringRaid", function(_, entity)
	if entity == Treasury.Entity and Treasury:ActiveIncident() then return false end
end)

hook.Add("CanDrive", "DRP.Treasury.LockDuringRaid", function(_, entity)
	if entity == Treasury.Entity and Treasury:ActiveIncident() then return false end
end)

hook.Add("DRPAdminModeChanged", "DRP.Treasury.AdminMode", function(ply, active)
	if not active then return end
	local affected = {}
	for _, incident in ipairs(DRP.Incidents.ForPlayer(ply, "treasury_raid")) do affected[#affected + 1] = incident end
	for _, incident in ipairs(affected) do
		if DRP.Incidents.Get(incident.id) then
			DRP.Incidents.Definitions.treasury_raid.onParticipantUnavailable(
				incident, ply, "admin_mode", "Participant entered Admin Mode")
		end
	end
end)
