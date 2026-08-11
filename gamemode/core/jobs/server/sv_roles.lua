local SNAPSHOT = "drp_roles_snapshot_v1"
local REQUEST = "drp_roles_request_v1"

local Roles = {
	MaximumMetric = 65535,
	NormalizedBehavior = setmetatable({}, { __mode = "k" }),
	Metrics = {
		narcotics = true,
		forceDrugging = true,
		healing = true,
		weaponTrades = true,
		homelessness = true,
		muggings = true,
		hits = true,
		hitEvidence = true,
		raids = true
	}
}

DRP.Roles = Roles
DRP.Services.Register("roles", Roles)
util.AddNetworkString(SNAPSHOT)
util.AddNetworkString(REQUEST)

local function cleanMetric(value)
	return math.Clamp(math.floor(tonumber(value) or 0), 0, Roles.MaximumMetric)
end

function Roles:Normalize(value)
	if istable(value) and self.NormalizedBehavior[value] then return value end
	if isstring(value) then value = util.JSONToTable(value) end
	value = istable(value) and value or {}
	local normalized = {}
	for metric in pairs(self.Metrics) do normalized[metric] = cleanMetric(value[metric]) end
	-- Kidnapping cooldowns use wall-clock timestamps so reconnecting or a clean
	-- restart cannot bypass them. They share the event-driven player snapshot;
	-- no timer-driven database writes are introduced.
	normalized.kidnapCooldownUntil = math.max(0, math.floor(tonumber(value.kidnapCooldownUntil) or 0))
	normalized.kidnapImmunityUntil = math.max(0, math.floor(tonumber(value.kidnapImmunityUntil) or 0))
	normalized.hitEvidenceVictims = {}
	local seen = {}
	for _, steamID64 in ipairs(istable(value.hitEvidenceVictims) and value.hitEvidenceVictims or {}) do
		steamID64 = string.match(tostring(steamID64 or ""), "^%d+$")
		if steamID64 and #steamID64 >= 16 and #steamID64 <= 20 and not seen[steamID64]
			and #normalized.hitEvidenceVictims < 16 then
			seen[steamID64] = true
			normalized.hitEvidenceVictims[#normalized.hitEvidenceVictims + 1] = steamID64
		end
	end
	-- The receipt list is authoritative. Repair older snapshots that contained
	-- a scalar without its deduplication receipts instead of inventing victims.
	normalized.hitEvidence = #normalized.hitEvidenceVictims
	self.NormalizedBehavior[normalized] = true
	return normalized
end

function Roles:EnsureBehavior(ply)
	if not IsValid(ply) then return self:Normalize() end
	local behavior = ply.DRPRoleBehavior
	if not istable(behavior) or not self.NormalizedBehavior[behavior] then
		behavior = self:Normalize(behavior)
		ply.DRPRoleBehavior = behavior
	end
	return behavior
end

function Roles:InitializePlayer(ply, value)
	if not IsValid(ply) then return end
	ply.DRPRoleBehavior = self:Normalize(value)
	ply.DRPRoleAdminOverride = nil
end

function Roles:Serialize(ply)
	local behavior = self:EnsureBehavior(ply)
	return util.TableToJSON(behavior, false) or "{}"
end

function Roles:GetMetric(ply, metric)
	if not IsValid(ply) or not self.Metrics[metric] then return 0 end
	return self:EnsureBehavior(ply)[metric] or 0
end

function Roles:CanAccessRoleTools(ply, jobKey)
	if not IsValid(ply) then return false end
	if ply:DRPJob().key == jobKey then return true end
	-- Derived identities are authoritative for gameplay permissions.  A player
	-- who became Drug Dealer/Gun Dealer through civic behaviour must not be
	-- forced to manually select that job before its production tools work.
	local derived = self:DerivedJob(ply)
	if DRP.Jobs[derived] and DRP.Jobs[derived].key == jobKey then return true end
	local capability = DRP.JobEntityCapabilityByRole[jobKey]
	if capability then return ply:DRPHasRoleCapability(capability) end
	return false
end

function Roles:Resolve(civic, behavior)
	civic = math.Clamp(math.floor(tonumber(civic) or 0), -1000, 1000)
	behavior = self:Normalize(behavior)
	-- Civic severity establishes the main criminal ladder. Strong specialist
	-- evidence may describe the player more precisely between its tiers.
	if civic <= -1000 then return DRP.Job.MOB_BOSS, "Civic standing reached the absolute minimum required for Mob Boss." end
	if civic <= -100 and cleanMetric(behavior.forceDrugging) >= 3 then return DRP.Job.KIDNAPPER, "Repeated force-drugging defines this identity." end
	if civic <= -100 and cleanMetric(behavior.narcotics) >= 12 then return DRP.Job.DRUG_DEALER, "Sustained narcotics production and sales define this identity." end
	if civic <= -525 or (civic <= -200 and cleanMetric(behavior.raids) >= 4) then return DRP.Job.GANGSTER, "Civic standing and raid behavior reached the gangster tier." end
	if civic <= -325 or (civic <= -200 and cleanMetric(behavior.hitEvidence) >= 3) then return DRP.Job.HITMAN, "Civic standing and authenticated kill evidence reached the hitman tier." end
	if civic <= -100 and cleanMetric(behavior.muggings) >= 3 then return DRP.Job.THIEF, "Repeated mugging behavior defines this identity." end
	if civic <= -150 then return DRP.Job.THIEF, "Civic standing reached the thief tier." end

	if civic >= 100 and cleanMetric(behavior.healing) >= 8 then return DRP.Job.MEDIC, "Repeated genuine medical aid defines this identity." end
	if civic >= -50 and cleanMetric(behavior.weaponTrades) >= 8 then return DRP.Job.GUN_DEALER, "Repeated weapon commerce defines this identity." end
	return DRP.Job.CITIZEN, "No stronger civic or behavioral identity currently applies."
end

function Roles:MobBossHolder(excluded)
	for _, candidate in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do
		if candidate ~= excluded and IsValid(candidate) and candidate:IsPlayer() and candidate:DRPJobID() == DRP.Job.MOB_BOSS then
			return candidate
		end
	end
end

function Roles:CanBecomeMobBoss(ply)
	return IsValid(ply)
		and ply:IsPlayer()
		and DRP.Civic
		and DRP.Civic:Get(ply) <= DRP.Civic.Minimum
		and not IsValid(self:MobBossHolder(ply))
end

function Roles:DerivedJob(ply)
	if not IsValid(ply) then return DRP.Job.CITIZEN, "No player identity." end
	local derived, reason = self:Resolve(DRP.Civic and DRP.Civic:Get(ply) or 0, ply.DRPRoleBehavior)
	if derived == DRP.Job.MOB_BOSS and not self:CanBecomeMobBoss(ply) then
		return DRP.Job.GANGSTER, "Mob Boss requires minimum civic standing and its single server slot is occupied."
	end
	-- Hobo is the fallback economic identity. Stronger civic and behavioural
	-- identities keep priority, but an otherwise ordinary citizen becomes a
	-- Hobo when either condition requested by the role design is true.
	if derived == DRP.Job.CITIZEN then
		local hasMoney = ply.DRPMoney and ply:DRPMoney() > 0
		local owned = DRP.Properties and DRP.Properties.OwnedProperties
			and DRP.Properties.OwnedProperties[ply:SteamID64()]
		local hasProperty = istable(owned) and next(owned) ~= nil
		if not hasMoney then
			return DRP.Job.HOBO, "Your wallet is empty."
		end
		if not hasProperty then
			return DRP.Job.HOBO, "You do not own a property."
		end
	end
	return derived, reason
end

function Roles:FillMobBossVacancy(excluded)
	if IsValid(self:MobBossHolder(excluded)) then return false end

	local eligible = {}
	for _, candidate in ipairs((DRP.Players and DRP.Players.List) or player.GetAll()) do
		if candidate ~= excluded
			and IsValid(candidate)
			and candidate:IsPlayer()
			and candidate:DRPReady()
			and not candidate.DRPRoleAdminOverride
			and DRP.Civic
			and DRP.Civic:Get(candidate) <= DRP.Civic.Minimum then
			eligible[#eligible + 1] = candidate
		end
	end
	table.sort(eligible, function(a, b)
		local aID, bID = a:UserID(), b:UserID()
		if aID == bID then return a:SteamID64() < b:SteamID64() end
		return aID < bID
	end)

	local successor = eligible[1]
	if not IsValid(successor) then return false end
	return self:Evaluate(successor, "the Mob Boss position became vacant", false)
end

function Roles:InitialJob(ply, persistedJob)
	local job = DRP.Jobs[persistedJob]
	if job and job.isGovernment and not job.electionOnly and (not job.civicMinimum or DRP.Civic:Get(ply) >= job.civicMinimum) then
		return persistedJob
	end
	return self:DerivedJob(ply)
end

function Roles:BuildSnapshot(ply)
	local derived, reason = self:DerivedJob(ply)
	local mobBoss = self:MobBossHolder()
	local behavior = self:EnsureBehavior(ply)
	local publicBehavior = {}
	for metric in pairs(self.Metrics) do publicBehavior[metric] = behavior[metric] or 0 end
	return {
		civic = DRP.Civic and DRP.Civic:Get(ply) or 0,
		current = ply:DRPJobID(),
		derived = derived,
		reason = reason,
		adminOverride = ply.DRPRoleAdminOverride == true,
		mobBossOccupied = IsValid(mobBoss),
		mobBossHolder = IsValid(mobBoss) and mobBoss:DRPName() or "",
		behavior = publicBehavior
	}
end

function Roles:SendSnapshot(ply)
	if not IsValid(ply) then return false end
	local compressed = util.Compress(util.TableToJSON(self:BuildSnapshot(ply), false) or "{}") or ""
	net.Start(SNAPSHOT)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.min(#compressed, 65535), 16)
	net.WriteData(compressed, math.min(#compressed, 65535))
	net.Send(ply)
	if DRP.Net then DRP.Net.Record(#compressed + 3) end
	return true
end

function Roles:Evaluate(ply, reason, silent)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:DRPReady() or ply.DRPRoleEvaluation then return false end
	if ply.DRPRoleAdminOverride then self:SendSnapshot(ply) return false end

	local currentID = ply:DRPJobID()
	local current = DRP.Jobs[currentID]
	if current and current.isGovernment and (not current.civicMinimum or DRP.Civic:Get(ply) >= current.civicMinimum) then
		self:SendSnapshot(ply)
		return false
	end

	local derived, derivedReason = self:DerivedJob(ply)
	if derived == currentID then self:SendSnapshot(ply) return false end
	ply.DRPRoleEvaluation = true
	local changed = DRP.JobService.Set(ply, derived, false)
	ply.DRPRoleEvaluation = nil
	if changed and not silent then
		DRP.Net.Notify(ply, "Your actions now identify you as " .. DRP.Jobs[derived].name .. " — " .. (reason or derivedReason), 0)
	end
	self:SendSnapshot(ply)
	return changed
end

function Roles:Record(ply, metric, amount, reason)
	if not IsValid(ply) or not ply:IsPlayer() or not self.Metrics[metric] then return false end
	amount = math.floor(tonumber(amount) or 0)
	if amount == 0 then return false end
	local behavior = self:EnsureBehavior(ply)
	local previous = behavior[metric]
	local updated = math.Clamp(previous + amount, 0, self.MaximumMetric)
	if updated == previous then return false end
	behavior[metric] = updated
	if DRP.Economy then DRP.Economy.QueueSave(ply) end
	if ply:DRPReady() then
		self:Evaluate(ply, reason, false)
	end
	hook.Run("DRPRoleBehaviorChanged", ply, metric, previous, updated, reason)
	return true
end

function Roles:RecordHitEvidence(ply, victimSteamID64, incidentID)
	if not IsValid(ply) or not ply:IsPlayer() or ply:IsBot() then return false, 0 end
	victimSteamID64 = string.match(tostring(victimSteamID64 or ""), "^%d+$")
	if not victimSteamID64 or #victimSteamID64 < 16 or #victimSteamID64 > 20
		or victimSteamID64 == ply:SteamID64() then return false, self:GetMetric(ply, "hitEvidence") end
	local behavior = self:EnsureBehavior(ply)
	for _, existing in ipairs(behavior.hitEvidenceVictims) do
		if existing == victimSteamID64 then return false, behavior.hitEvidence end
	end
	behavior.hitEvidenceVictims[#behavior.hitEvidenceVictims + 1] = victimSteamID64
	behavior.hitEvidence = #behavior.hitEvidenceVictims
	if DRP.Economy then DRP.Economy.QueueSave(ply) end
	if ply:DRPReady() then self:Evaluate(ply, "authenticated hit evidence", false) end
	hook.Run("DRPRoleBehaviorChanged", ply, "hitEvidence", behavior.hitEvidence - 1,
		behavior.hitEvidence, "photographic proof from incident #" .. tostring(incidentID or 0))
	return true, behavior.hitEvidence
end

function Roles:Start() end
function Roles:Stop() end

DRP.Net.Receive(REQUEST, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not ply:DRPReady() then return end
	Roles:SendSnapshot(ply)
end)

hook.Add("DRPCivicStandingChanged", "DRP.Roles.CivicEvaluation", function(ply, _, _, reason)
	Roles:Evaluate(ply, reason or "civic standing changed")
end)

hook.Add("DRPMoneyZeroStateChanged", "DRP.Roles.EconomyEvaluation", function(ply)
	Roles:Evaluate(ply, "wallet status changed")
end)

hook.Add("DRPPropertyOwnershipChanged", "DRP.Roles.PropertyEvaluation", function(ply)
	Roles:Evaluate(ply, "property ownership changed")
end)

hook.Add("DRPPlayerReady", "DRP.Roles.Ready", function(ply)
	Roles:Evaluate(ply, "profile loaded", true)
end)

hook.Add("DRPJobChanged", "DRP.Roles.MobBossVacancy", function(ply, previous, current)
	if previous ~= DRP.Job.MOB_BOSS or current == DRP.Job.MOB_BOSS then return end
	timer.Simple(0, function()
		Roles:FillMobBossVacancy(ply)
	end)
end)

hook.Add("PlayerDisconnected", "DRP.Roles.MobBossVacancy", function(ply)
	if ply:DRPJobID() ~= DRP.Job.MOB_BOSS then return end
	timer.Simple(0, function()
		Roles:FillMobBossVacancy(ply)
	end)
end)

hook.Add("DRPIncidentResolved", "DRP.Roles.IncidentBehavior", function(incident, receipt)
	if not istable(incident) then return end
	local instigator = incident.instigator
	local resolution = tostring(receipt and receipt.resolution or incident.resolution or "")
	if incident.type == "mugging" then
		Roles:Record(instigator, "muggings", 1, "mugging behavior")
	elseif incident.type == "hit_contract" then
		Roles:Record(instigator, "hits", resolution == "target_eliminated" and 3 or 1, "hit-contract behavior")
	elseif incident.type == "property_raid" or incident.type == "armory_raid" or incident.type == "treasury_raid" then
		Roles:Record(instigator, "raids", string.find(resolution, "victory", 1, true) and 2 or 1, "raiding behavior")
	elseif incident.type == "lockdown_homelessness" and IsValid(incident.victim) then
		Roles:Record(incident.victim, "homelessness", 1, "homelessness behavior")
	end
end)

hook.Add("DRPMarketplaceFulfilled", "DRP.Roles.WeaponCommerce", function(seller, _, items)
	if not IsValid(seller) then return end
	local count = 0
	for _, item in ipairs(items or {}) do
		local entityWeapon = item.source == "entity" and IsValid(item.entity) and item.entity:IsWeapon()
		local pocketWeapon = item.source ~= "entity" and istable(item.record) and item.record.kind == "weapon"
		if entityWeapon or pocketWeapon then count = count + 1 end
	end
	if count > 0 then Roles:Record(seller, "weaponTrades", count, "weapon marketplace activity") end
end)
