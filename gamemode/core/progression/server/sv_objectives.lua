local SYNC = "drp_objectives_sync_v1"
local ACTION = "drp_objectives_action_v1"
local ROLE_ACTION = "drp_objective_role_action_v1"
local POPUP = "drp_objective_popup_v1"
util.AddNetworkString(SYNC)
util.AddNetworkString(ACTION)
util.AddNetworkString(ROLE_ACTION)
util.AddNetworkString(POPUP)

local Objectives = {
	States = setmetatable({}, { __mode = "k" }),
	GuideTesters = setmetatable({}, { __mode = "k" }),
	GuideProgress = {},
	GuidePath = "darkrp/beginner_guide_progress.json",
	GuideSequence = { "welcome_identity", "beginner_property_purchase", "welcome_pockets", "beginner_mugging", "beginner_healing", "beginner_review" },
	MaxOffers = 3,
	MaxActive = 2,
	DismissCooldown = 300,
	RepeatCooldown = 900
}

DRP.Objectives = Objectives
DRP.Services.Register("objectives", Objectives)

local function ready(ply)
	return IsValid(ply) and ply:IsPlayer() and not ply:IsBot() and ply:DRPReady()
end

local function population()
	local count = 0
	for _, ply in ipairs(DRP.Players.List or {}) do
		if ready(ply) then count = count + 1 end
	end
	return count
end

local function isGovernment(ply)
	local job = ready(ply) and ply:DRPJob() or nil
	return job and job.isGovernment == true or false
end

local function ownsProperty(ply)
	return ready(ply) and DRP.Properties
		and next(DRP.Properties.OwnedProperties[ply:SteamID64()] or {}) ~= nil
end

local function isNewPlayer(ply)
	return ready(ply) and (Objectives.GuideTesters[ply] == true
		or math.max(0, tonumber(ply.DRPTotalPlaytimeBase) or 0) < 7200)
end

local function needsRPName(ply)
	return isNewPlayer(ply) and tostring(ply.DRPRPNameValue or "") == ""
end

local function roleIs(ply, id)
	return ready(ply) and ply:DRPJobID() == id
end

local templates = {
	{
		key = "welcome_identity", category = "Getting Started", title = "Choose your identity",
		description = "Set an RP name with /rpname or /name.", event = "rp_name_changed",
		goal = 1, xp = 30, money = 150, priority = 100,
		eligible = needsRPName, once = true, beginner = true, automatic = true
	},
	{
		key = "beginner_property_purchase", category = "Beginner Guide", title = "Purchase your first property",
		description = "Open F4 → Properties, choose an available property, then press F on its main door to purchase it.",
		event = "property_purchased", goal = 1, xp = 45, money = 250, priority = 99,
		eligible = function(ply) return isNewPlayer(ply) and not ownsProperty(ply) end,
		once = true, beginner = true, automatic = true
	},
	{
		key = "beginner_mugging", category = "Beginner Guide", title = "Learn the mugging system",
		description = "As a non-government citizen, face a stationary player and press M. Hold M for three seconds to choose the demand amount, then resolve the incident.",
		event = "mugging_resolved", goal = 1, xp = 55, money = 225, minPlayers = 2, priority = 98,
		eligible = function(ply) return isNewPlayer(ply) and not isGovernment(ply) end,
		once = true, beginner = true, automatic = true
	},
	{
		key = "beginner_healing", category = "Beginner Guide", title = "Help an injured player",
		description = "Equip the Medical Kit from the weapon browser, aim at an injured player and use primary fire to heal them.",
		event = "player_healed", goal = 1, xp = 55, money = 225, minPlayers = 2, priority = 97,
		eligible = isNewPlayer, once = true, beginner = true, automatic = true
	},
	{
		key = "welcome_pockets", category = "Getting Started", title = "Secure an item",
		description = "Equip Hands, look at a dropped item and use primary fire to carry it safely.", event = "item_pocketed",
		goal = 1, xp = 35, money = 175, priority = 95,
		eligible = isNewPlayer, once = true, beginner = true, automatic = true
	},
	{
		key = "beginner_review", category = "Beginner Guide", title = "Choose what comes next",
		description = "Open F4 → Objectives, review generated activities and inspect a role pathway you may want to pursue.",
		event = "guide_reviewed", goal = 1, xp = 30, money = 100, priority = 96,
		eligible = isNewPlayer, once = true, beginner = true, automatic = true
	},
	{
		key = "welcome_property", category = "Getting Started", title = "Visit a property",
		description = "Enter the vicinity of a property you may access.", event = "visit_property",
		goal = 1, xp = 30, money = 150, priority = 90,
		eligible = isNewPlayer, once = true
	},
	{
		key = "welcome_trade", category = "Getting Started", title = "Complete a safe trade",
		description = "Complete a marketplace delivery as buyer or seller.", event = "marketplace_trade",
		goal = 1, xp = 60, money = 250, minPlayers = 2, priority = 85,
		eligible = isNewPlayer, once = true
	},
	{
		key = "police_witness", category = "Police", title = "Witness an offence",
		description = "Personally identify an offence through the police visibility system.",
		event = "police_witnessed", goal = 1, xp = 45, money = 175, minPlayers = 2, priority = 75,
		eligible = function(ply) return roleIs(ply, DRP.Job.POLICE) end
	},
	{
		key = "police_booking", category = "Police", title = "Complete lawful custody",
		description = "Book a suspect at the jailer through their originating incident.",
		event = "police_arrest", goal = 1, xp = 80, money = 300, minPlayers = 2, priority = 90,
		eligible = function(ply) return roleIs(ply, DRP.Job.POLICE) end
	},
	{
		key = "police_evidence", category = "Police", title = "Secure evidence",
		description = "Transport and register seized evidence in the evidence system.",
		event = "evidence_stored", goal = 1, xp = 55, money = 200, minPlayers = 2, priority = 70,
		eligible = function(ply) return roleIs(ply, DRP.Job.POLICE) end
	},
	{
		key = "medic_response", category = "Medical", title = "Answer the call",
		description = "Revive a player who requested medical assistance.",
		event = "medic_revive", goal = 1, xp = 75, money = 275, minPlayers = 2, priority = 90,
		eligible = function(ply) return roleIs(ply, DRP.Job.MEDIC) end
	},
	{
		key = "criminal_mugging", category = "Criminal", title = "Resolve a mugging",
		description = "Initiate a mugging and bring its incident to a terminal outcome.",
		event = "mugging_resolved", goal = 1, xp = 65, money = 225, minPlayers = 2, priority = 70,
		eligible = function(ply) return ready(ply) and not isGovernment(ply) end
	},
	{
		key = "criminal_delivery", category = "Criminal", title = "Move illicit product",
		description = "Complete a weed, meth or cocaine sale.",
		event = "drug_sale", goal = 1, xp = 60, money = 200, priority = 65,
		eligible = function(ply) return ready(ply) and not isGovernment(ply) end
	},
	{
		key = "criminal_raid", category = "Criminal", title = "Win a declared raid",
		description = "Participate as the instigator and win a property or armory raid.",
		event = "raid_victory", goal = 1, xp = 110, money = 400, minPlayers = 3, priority = 80,
		eligible = function(ply) return ready(ply) and not isGovernment(ply) end
	},
	{
		key = "merchant_delivery", category = "Commerce", title = "Fulfil an order",
		description = "Complete a marketplace delivery as the seller.",
		event = "marketplace_sold", goal = 1, xp = 70, money = 250, minPlayers = 2, priority = 70,
		eligible = function(ply) return ready(ply) and not isGovernment(ply) end
	},
	{
		key = "gunsmith_project", category = "Crafting", title = "Finish a gunsmithing project",
		description = "Place or visit a Gunsmithing Workbench, refine salvage and complete one queued recipe.",
		event = "craft_completed", goal = 1, xp = 65, money = 175, priority = 68,
		eligible = function(ply) return ready(ply) and not isGovernment(ply) end
	},
	{
		key = "property_funding", category = "Property", title = "Protect the lease",
		description = "Fund at least one day of an active property lease.",
		event = "property_lease_funded", goal = 1, xp = 45, money = 100, priority = 80,
		eligible = function(ply) return ownsProperty(ply) end
	},
	{
		key = "property_tenant", category = "Property", title = "Build a community",
		description = "Invite a player who accepts tenancy in your property.",
		event = "property_tenant_joined", goal = 1, xp = 75, money = 225, minPlayers = 2, priority = 70,
		eligible = function(ply) return ownsProperty(ply) end
	},
	{
		key = "property_defence", category = "Property", title = "Defend your property",
		description = "Win a declared property raid as the defending owner.",
		event = "property_defended", goal = 1, xp = 100, money = 350, minPlayers = 3, priority = 75,
		eligible = function(ply) return ownsProperty(ply) end
	},
	{
		key = "mayor_service", category = "Government", title = "Fund public service",
		description = "Change a job allocation or fund a treasury lottery.",
		event = "mayor_public_service", goal = 1, xp = 80, money = 0, minPlayers = 2, priority = 85,
		eligible = function(ply) return roleIs(ply, DRP.Job.MAYOR) end
	},
	{
		key = "mayor_confidence", category = "Government", title = "Retain public confidence",
		description = "Remain in office after a completed confidence poll.",
		event = "mayor_confidence_kept", goal = 1, xp = 140, money = 0, minPlayers = 3, priority = 90,
		eligible = function(ply) return roleIs(ply, DRP.Job.MAYOR) end
	},
	{
		key = "active_presence", category = "Community", title = "Stay involved",
		description = "Remain actively involved in the session for five minutes.",
		event = "active_second", goal = 300, xp = 45, money = 150, priority = 20,
		eligible = function(ply) return ready(ply) end
	},
	{
		key = "incident_participant", category = "Roleplay", title = "See it through",
		description = "Participate in an incident until the server records its outcome.",
		event = "incident_resolved", goal = 1, xp = 50, money = 150, minPlayers = 2, priority = 40,
		eligible = function(ply) return ready(ply) end
	}
}

Objectives.Templates = {}
for _, definition in ipairs(templates) do Objectives.Templates[definition.key] = definition end

local function stateFor(ply)
	local state = Objectives.States[ply]
	if state then return state end
	state = { offers = {}, active = {}, completed = {}, cooldowns = {}, activityAt = CurTime(), visitAt = 0 }
	Objectives.States[ply] = state
	return state
end

local function writeDefinition(definition, progress)
	net.WriteString(definition.key)
	net.WriteString(definition.category)
	net.WriteString(definition.title)
	net.WriteString(definition.description)
	net.WriteUInt(math.Clamp(math.floor(tonumber(progress) or 0), 0, 65535), 16)
	net.WriteUInt(math.Clamp(definition.goal or 1, 1, 65535), 16)
	net.WriteUInt(math.Clamp(definition.xp or 0, 0, 65535), 16)
	net.WriteUInt(math.Clamp(definition.money or 0, 0, 4294967295), 32)
	net.WriteBool(definition.automatic == true)
end

function Objectives:SaveGuideProgress()
	file.CreateDir("darkrp")
	file.Write(self.GuidePath, util.TableToJSON(self.GuideProgress, false) or "{}")
end

function Objectives:GuideRecord(ply)
	local steamID64 = ready(ply) and ply:SteamID64() or ""
	if steamID64 == "" then return {} end
	local record = self.GuideProgress[steamID64]
	if not istable(record) then record = {} self.GuideProgress[steamID64] = record end
	return record
end

function Objectives:GuideSummary(ply)
	if not isNewPlayer(ply) then return { completed = 0, total = 0, current = "", mask = 0, finished = false } end
	local record, completed, current, mask = self:GuideRecord(ply), 0, "", 0
	for index, key in ipairs(self.GuideSequence) do
		if record[key] then
			completed = completed + 1
			mask = bit.bor(mask, bit.lshift(1, index - 1))
		elseif current == "" then current = key end
	end
	return { completed = completed, total = #self.GuideSequence, current = current, mask = mask, finished = record.finished == true }
end

local function roleColor(job)
	local color = job and job.color or color_white
	return { r = color.r or 255, g = color.g or 255, b = color.b or 255 }
end

local function progressStep(title, detail, currentText, fraction, complete)
	return {
		title = title,
		detail = detail,
		current = currentText,
		fraction = math.Clamp(tonumber(fraction) or 0, 0, 1),
		complete = complete == true
	}
end

local function maximumCivicFraction(civic, target)
	if civic <= target then return 1 end
	if target >= 0 then return 0 end
	return math.Clamp(-math.min(civic, 0) / -target, 0, 1)
end

local function minimumCivicFraction(civic, target)
	if civic >= target then return 1 end
	if target > 0 then return math.Clamp(math.max(civic, 0) / target, 0, 1) end
	return math.Clamp((civic + 1000) / (target + 1000), 0, 1)
end

function Objectives:BuildRoleGoal(ply)
	local targetID = math.floor(tonumber(ply.DRPRoleGoalValue) or 0)
	local job = DRP.Jobs[targetID]
	if not ready(ply) or not job or targetID == DRP.Job.CITIZEN then return nil end
	local civic = DRP.Civic and DRP.Civic:Get(ply) or 0
	local behavior = DRP.Roles and DRP.Roles:Normalize(ply.DRPRoleBehavior) or {}
	local steps, requirementComplete = {}, false
	local metricLabels = {
		healing = "Medical aid",
		homelessness = "Homelessness events",
		weaponTrades = "Weapon deliveries",
		narcotics = "Narcotics activity",
		forceDrugging = "Force-drugging incidents"
	}
	local metricGuidance = {
		healing = "Answer medical calls and complete legitimate healing or revives.",
		homelessness = "Accumulate recognised homelessness events without entering a stronger identity.",
		weaponTrades = "Fulfil weapon deliveries through the marketplace.",
		narcotics = "Produce or sell supported narcotics through server-owned systems.",
		forceDrugging = "Complete witnessed force-drugging activity through the incident system."
	}
	local function metric(name) return math.max(0, math.floor(tonumber(behavior[name]) or 0)) end
	local function combinedSpecialist(metricName, threshold, civicTarget, civicMinimum)
		local value = metric(metricName)
		local metricLabel = metricLabels[metricName] or metricName
		local civicComplete = civicMinimum and civic >= civicTarget or civic <= civicTarget
		local civicFraction = civicMinimum and minimumCivicFraction(civic, civicTarget) or maximumCivicFraction(civic, civicTarget)
		local metricFraction = math.Clamp(value / threshold, 0, 1)
		requirementComplete = civicComplete and value >= threshold
		steps[#steps + 1] = progressStep(
			"Build the required identity",
			(civicMinimum and ("Maintain civic standing at " .. civicTarget .. " or higher.") or ("Reach civic standing " .. civicTarget .. " or lower."))
				.. " " .. (metricGuidance[metricName] or "Complete the required behaviour through real server outcomes."),
			"Civic " .. civic .. "  •  " .. metricLabel .. " " .. value .. "/" .. threshold,
			math.min(civicFraction, metricFraction),
			requirementComplete
		)
	end

	if targetID == DRP.Job.POLICE then
		requirementComplete = civic >= 100
		steps[#steps + 1] = progressStep("Qualify for police service", "Raise civic standing through lawful incident outcomes and medical or civic service.", "Civic " .. civic .. " / +100", minimumCivicFraction(civic, 100), requirementComplete)
	elseif targetID == DRP.Job.MAYOR then
		requirementComplete = civic >= 250
		steps[#steps + 1] = progressStep("Qualify as a candidate", "Raise civic standing, then apply and win the next Mayoral election.", "Civic " .. civic .. " / +250", minimumCivicFraction(civic, 250), requirementComplete)
	elseif targetID == DRP.Job.THIEF then
		local muggings = metric("muggings")
		local civicRoute = civic <= -150
		local behaviorRoute = civic <= -100 and muggings >= 3
		requirementComplete = civicRoute or behaviorRoute
		steps[#steps + 1] = progressStep("Establish a thief identity", "Reach −150 civic, or reach −100 civic and resolve three mugging incidents.", "Civic " .. civic .. "  •  Muggings " .. muggings .. "/3", math.max(maximumCivicFraction(civic, -150), math.min(maximumCivicFraction(civic, -100), math.Clamp(muggings / 3, 0, 1))), requirementComplete)
	elseif targetID == DRP.Job.HITMAN then
		local evidence = metric("hitEvidence")
		local civicRoute = civic <= -325
		local behaviorRoute = civic <= -200 and evidence >= 3
		requirementComplete = civicRoute or behaviorRoute
		steps[#steps + 1] = progressStep("Establish a hitman identity", "Reach −325 civic, or reach −200 civic and photograph three different people you personally killed during legitimate server-owned incidents.", "Civic " .. civic .. "  •  Hit evidence " .. evidence .. "/3", math.max(maximumCivicFraction(civic, -325), math.min(maximumCivicFraction(civic, -200), math.Clamp(evidence / 3, 0, 1))), requirementComplete)
	elseif targetID == DRP.Job.GANGSTER then
		local raids = metric("raids")
		local civicRoute = civic <= -525
		local behaviorRoute = civic <= -200 and raids >= 4
		requirementComplete = civicRoute or behaviorRoute
		steps[#steps + 1] = progressStep("Establish a gangster identity", "Reach −525 civic, or reach −200 civic and build sufficient declared-raid evidence.", "Civic " .. civic .. "  •  Raid evidence " .. raids .. "/4", math.max(maximumCivicFraction(civic, -525), math.min(maximumCivicFraction(civic, -200), math.Clamp(raids / 4, 0, 1))), requirementComplete)
	elseif targetID == DRP.Job.MOB_BOSS then
		local holder = DRP.Roles and DRP.Roles:MobBossHolder(ply)
		local slotOpen = not IsValid(holder)
		requirementComplete = civic <= -1000 and slotOpen
		steps[#steps + 1] = progressStep("Reach the bottom of civic standing", "Mob Boss requires exactly the minimum civic standing and the single server-wide position must be vacant.", "Civic " .. civic .. " / −1000  •  Slot " .. (slotOpen and "available" or "occupied"), maximumCivicFraction(civic, -1000), requirementComplete)
	elseif targetID == DRP.Job.MEDIC then
		combinedSpecialist("healing", 8, 100, true)
	elseif targetID == DRP.Job.HOBO then
		local wallet = math.max(0, math.floor(tonumber(ply:DRPMoney()) or 0))
		local owned = DRP.Properties and DRP.Properties.OwnedProperties
			and DRP.Properties.OwnedProperties[ply:SteamID64()]
		local propertyCount = istable(owned) and table.Count(owned) or 0
		requirementComplete = wallet <= 0 or propertyCount == 0
		steps[#steps + 1] = progressStep(
			"Live without financial security",
			"The Hobo identity is assigned when your wallet is empty or you own no property. Stronger civic and specialist identities retain priority.",
			"Wallet $" .. string.Comma(wallet) .. "  •  Owned properties " .. propertyCount,
			requirementComplete and 1 or 0,
			requirementComplete
		)
	elseif targetID == DRP.Job.GUN_DEALER then
		combinedSpecialist("weaponTrades", 8, -50, true)
	elseif targetID == DRP.Job.DRUG_DEALER then
		combinedSpecialist("narcotics", 12, -100, false)
	elseif targetID == DRP.Job.KIDNAPPER then
		combinedSpecialist("forceDrugging", 3, -100, false)
	end

	-- The role resolver remains the sole authority. This catches priority
	-- interactions where several identities are eligible at once.
	if not job.isGovernment and DRP.Roles then
		local resolved = DRP.Roles:DerivedJob(ply)
		requirementComplete = resolved == targetID
	end

	local current = ply:DRPJobID() == targetID
	local finishDetail
	if job.electionOnly then
		finishDetail = requirementComplete and "Apply in the Jobs page and win the election." or "Complete the qualification above before applying."
	elseif job.manualSelectable then
		finishDetail = requirementComplete and "Join from the Jobs page when a position is available." or "Complete the qualification above before joining."
	else
		finishDetail = requirementComplete and "The role resolver will assign this identity automatically." or "The server will assign this identity when its conditions are satisfied."
	end
	steps[#steps + 1] = progressStep("Become " .. job.name, finishDetail, current and "ROLE ACHIEVED" or "Awaiting identity change", current and 1 or 0, current)

	return {
		job = targetID,
		key = job.key,
		name = job.name,
		description = (job.rolePath and job.rolePath.description) or "A gameplay-earned role.",
		color = roleColor(job),
		steps = steps,
		ready = requirementComplete,
		achieved = current
	}
end

function Objectives:Popup(ply, kind, title, detail)
	if not ready(ply) then return end
	net.Start(POPUP)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.Clamp(math.floor(tonumber(kind) or 0), 0, 3), 2)
	net.WriteString(string.sub(tostring(title or "Objective update"), 1, 72))
	net.WriteString(string.sub(tostring(detail or ""), 1, 220))
	net.Send(ply)
end

function Objectives:Sync(ply)
	if not ready(ply) then return end
	local state = stateFor(ply)
	net.Start(SYNC)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.min(#state.offers, self.MaxOffers), 2)
	for index = 1, math.min(#state.offers, self.MaxOffers) do
		local definition = self.Templates[state.offers[index]]
		writeDefinition(definition, 0)
	end
	local active = {}
	for key, record in pairs(state.active) do active[#active + 1] = { key = key, progress = record.progress or 0 } end
	table.sort(active, function(a, b) return a.key < b.key end)
	net.WriteUInt(math.min(#active, self.MaxActive), 2)
	for index = 1, math.min(#active, self.MaxActive) do
		writeDefinition(self.Templates[active[index].key], active[index].progress)
	end
	local roleGoal = self:BuildRoleGoal(ply)
	local compressed = roleGoal and (util.Compress(util.TableToJSON(roleGoal, false) or "{}") or "") or ""
	net.WriteUInt(math.min(#compressed, 65535), 16)
	if #compressed > 0 then net.WriteData(compressed, math.min(#compressed, 65535)) end
	local guide = self:GuideSummary(ply)
	net.WriteUInt(math.min(guide.completed, 15), 4)
	net.WriteUInt(math.min(guide.total, 15), 4)
	net.WriteString(guide.current)
	net.WriteUInt(math.Clamp(guide.mask or 0, 0, 255), 8)
	net.Send(ply)
end

function Objectives:SetRoleGoal(ply, targetID)
	if not ready(ply) then return false, "Your profile is not ready." end
	targetID = math.floor(tonumber(targetID) or 0)
	local job = DRP.Jobs[targetID]
	if targetID == 0 then
		ply.DRPRoleGoalValue = 0
		if DRP.Economy then DRP.Economy.QueueSave(ply) end
		self:Sync(ply)
		self:Popup(ply, 0, "Role pathway cleared", "No role pathway is currently pinned.")
		return true
	end
	if not job or targetID == DRP.Job.CITIZEN then return false, "That role does not have a pursuit pathway." end
	if ply:DRPJobID() == targetID then return false, "You already hold that role." end
	ply.DRPRoleGoalValue = targetID
	if DRP.Economy then DRP.Economy.QueueSave(ply) end
	self:Sync(ply)
	self:Popup(ply, 2, job.name .. " pathway pinned", "Its live civic and behaviour requirements will remain on your HUD until achieved or cancelled.")
	if DRP.Hints then DRP.Hints:CivicGuidance(ply, true) end
	if DRP.Audit then DRP.Audit.Log(ply, "role_pathway_selected", nil, job.key) end
	return true
end

function Objectives:CheckRoleGoal(ply)
	local targetID = math.floor(tonumber(ply.DRPRoleGoalValue) or 0)
	local job = DRP.Jobs[targetID]
	if not job or ply:DRPJobID() ~= targetID then return false end
	ply.DRPRoleGoalValue = 0
	if DRP.Economy then DRP.Economy.QueueSave(ply) end
	self:Popup(ply, 1, "Role pathway complete", "You achieved the " .. job.name .. " identity.")
	if DRP.Audit then DRP.Audit.Log(ply, "role_pathway_completed", nil, job.key) end
	self:Sync(ply)
	return true
end

local function currentlyUsed(state, key)
	if state.active[key] then return true end
	for _, offered in ipairs(state.offers) do if offered == key then return true end end
	return false
end

function Objectives:EnsureBeginnerGuide(ply)
	if not isNewPlayer(ply) then return false end
	local state, record = stateFor(ply), self:GuideRecord(ply)
	-- Never pin two automatic lessons at once. Population-aware skipped steps
	-- return naturally after the current available lesson completes.
	for key in pairs(state.active) do
		local activeDefinition = self.Templates[key]
		if activeDefinition and activeDefinition.automatic then return true end
	end
	local changedProgress = false
	if not needsRPName(ply) and not record.welcome_identity then
		record.welcome_identity = true
		changedProgress = true
	end
	if ownsProperty(ply) and not record.beginner_property_purchase then
		record.beginner_property_purchase = true
		changedProgress = true
	end
	if changedProgress then self:SaveGuideProgress() end

	for _, key in ipairs(self.GuideSequence) do
		if not record[key] then
			if state.active[key] then return true end
			local definition = self.Templates[key]
			local online = population()
			local eligible = definition and online >= (definition.minPlayers or 1)
				and (not definition.eligible or definition.eligible(ply))
			if eligible and table.Count(state.active) < self.MaxActive then
				for index = #state.offers, 1, -1 do
					if state.offers[index] == key then table.remove(state.offers, index) end
				end
				state.active[key] = { progress = 0, acceptedAt = CurTime(), automatic = true }
				self:Sync(ply)
				if DRP.Hints then
					DRP.Hints:Send(ply, "guide_" .. key, "Automatic beginner objective",
						definition.title .. " — " .. definition.description, 2, 7, true)
				end
				return true
			end
		end
	end
	-- An unavailable step is still incomplete. Do not permanently finish the
	-- guide merely because its population or role requirements are unmet now.
	for _, key in ipairs(self.GuideSequence) do
		if not record[key] then return false end
	end

	if not record.finished then
		record.finished = true
		self:SaveGuideProgress()
		if DRP.Hints then
			DRP.Hints:Send(ply, "guide_complete", "Beginner guide complete",
				"You have completed the core guided activities. Population-aware objectives will continue to offer roleplay direction in F4 → Objectives.", 1, 7, true)
		end
	end
	return false
end

function Objectives:RefreshOffers(ply, force)
	if not ready(ply) then return false end
	local state, now, online = stateFor(ply), CurTime(), population()
	if force then
		state.offers = {}
	else
		local validOffers = {}
		for _, key in ipairs(state.offers) do
			local definition = self.Templates[key]
			if definition
				and not definition.automatic
				and online >= (definition.minPlayers or 1)
				and (not definition.eligible or definition.eligible(ply)) then
				validOffers[#validOffers + 1] = key
			end
		end
		state.offers = validOffers
	end
	local candidates = {}
	for _, definition in ipairs(templates) do
		local cooldown = tonumber(state.cooldowns[definition.key]) or 0
		local completed = tonumber(state.completed[definition.key]) or 0
		if not currentlyUsed(state, definition.key)
		and not definition.automatic
		and cooldown <= now
			and (not definition.once or completed == 0)
			and online >= (definition.minPlayers or 1)
			and (not definition.eligible or definition.eligible(ply)) then
			candidates[#candidates + 1] = {
				key = definition.key,
				score = (definition.priority or 0) + math.Rand(0, 15)
			}
		end
	end
	table.sort(candidates, function(a, b) return a.score > b.score end)
	while #state.offers < self.MaxOffers and #candidates > 0 do
		state.offers[#state.offers + 1] = table.remove(candidates, 1).key
	end
	self:Sync(ply)
	return true
end

function Objectives:RefreshAll()
	for _, ply in ipairs(DRP.Players.List or {}) do
		if ready(ply) then self:RefreshOffers(ply) self:EnsureBeginnerGuide(ply) end
	end
end

function Objectives:PruneInvalid(ply)
	local state, removed = stateFor(ply), false
	for key in pairs(table.Copy(state.active)) do
		local definition = self.Templates[key]
		if not definition or (definition.eligible and not definition.eligible(ply)) then
			state.active[key] = nil
			removed = true
		end
	end
	if removed then DRP.Net.Notify(ply, "Objectives incompatible with your new role were returned to the board.", 0) end
	return removed
end

function Objectives:Accept(ply, key)
	local state, selected = stateFor(ply), nil
	if table.Count(state.active) >= self.MaxActive then return false, "You may track only two objectives at once." end
	for index, offered in ipairs(state.offers) do
		if offered == key then selected = index break end
	end
	local definition = selected and self.Templates[key] or nil
	if not definition then return false, "That objective is no longer available." end
	table.remove(state.offers, selected)
	state.active[key] = { progress = 0, acceptedAt = CurTime() }
	self:RefreshOffers(ply)
	DRP.Net.Notify(ply, "Objective accepted: " .. definition.title, 1)
	self:Popup(ply, 2, "Objective pinned", definition.title .. " will now remain on your HUD until completed or abandoned.")
	return true
end

function Objectives:Dismiss(ply, key, active)
	local state = stateFor(ply)
	local definition = self.Templates[key]
	if active and definition and definition.automatic then return false, "Automatic beginner objectives advance when their gameplay outcome is completed." end
	if active then
		if not state.active[key] then return false end
		state.active[key] = nil
	else
		local found
		for index, offered in ipairs(state.offers) do
			if offered == key then table.remove(state.offers, index) found = true break end
		end
		if not found then return false end
	end
	state.cooldowns[key] = CurTime() + self.DismissCooldown
	self:RefreshOffers(ply)
	return true
end

function Objectives:Complete(ply, key)
	local state, definition = stateFor(ply), self.Templates[key]
	if not definition or not state.active[key] then return false end
	state.active[key] = nil
	state.completed[key] = (state.completed[key] or 0) + 1
	if definition.beginner then
		local record = self:GuideRecord(ply)
		record[key] = true
		self:SaveGuideProgress()
	end
	state.cooldowns[key] = CurTime() + (definition.once and math.huge or self.RepeatCooldown)
	if definition.xp > 0 and DRP.Experience then
		DRP.Experience:Add(ply, definition.xp, "objective:" .. key, definition.title)
	end
	if definition.money > 0 and DRP.Economy then
		DRP.Economy.Reward(ply, definition.money, "objective: " .. definition.title)
	end
	DRP.Net.Notify(ply, string.format("Objective complete: %s (+%d XP%s)", definition.title,
		definition.xp, definition.money > 0 and ", +$" .. string.Comma(definition.money) or ""), 1)
	self:Popup(ply, 1, "Objective complete", definition.title .. " rewarded " .. definition.xp .. " XP" .. (definition.money > 0 and " and $" .. string.Comma(definition.money) or "") .. ".")
	if DRP.Audit then DRP.Audit.Log(ply, "objective_completed", nil, key) end
	hook.Run("DRPObjectiveCompleted", ply, key, definition)
	self:RefreshOffers(ply)
	timer.Simple(0, function() if ready(ply) then self:EnsureBeginnerGuide(ply) end end)
	return true
end

function Objectives:Emit(ply, event, amount)
	if not ready(ply) then return false end
	local state, changed = stateFor(ply), false
	for key, record in pairs(table.Copy(state.active)) do
		local definition = self.Templates[key]
		if definition and definition.event == event then
			local live = state.active[key]
			if live then
				live.progress = math.min(definition.goal, (live.progress or 0) + math.max(1, math.floor(tonumber(amount) or 1)))
				changed = true
				if live.progress >= definition.goal then self:Complete(ply, key) end
			end
		end
	end
	if changed then self:Sync(ply) end
	return changed
end

local auditEvents = {
	rp_name_changed = "rp_name_changed",
	item_pocketed = "item_pocketed",
	property_lease_funded = "property_lease_funded",
	property_tenant_joined = "property_tenant_joined",
	weed_sold = "drug_sale",
	meth_sold = "drug_sale",
	cocaine_sold = "drug_sale",
	government_allocation = "mayor_public_service",
	government_lottery = "mayor_public_service"
}

local function nearAccessibleProperty(ply)
	if not DRP.Properties or not DRP.Doors then return false end
	for propertyID, definition in pairs(DRP.Properties.Definitions or {}) do
		local permitted = DRP.Properties.Can(ply, propertyID, "access")
			or (DRP.Properties.JobCanBuild and DRP.Properties.JobCanBuild(ply, propertyID))
		if permitted then
			for _, doorID in ipairs(definition.doors or {}) do
				local door = DRP.Doors.ByMapID[tostring(doorID)]
				if IsValid(door) and ply:GetPos():DistToSqr(door:GetPos()) <= 90000 then return true end
			end
		end
	end
	return false
end

function Objectives:Start()
	local decoded = util.JSONToTable(file.Read(self.GuidePath, "DATA") or "")
	self.GuideProgress = istable(decoded) and decoded or {}
	hook.Add("DRPPlayerReady", "DRP.Objectives.Ready", function(ply)
		stateFor(ply)
		timer.Simple(1, function()
			if not ready(ply) then return end
			Objectives:CheckRoleGoal(ply)
			Objectives:RefreshOffers(ply, true)
			Objectives:EnsureBeginnerGuide(ply)
			DRP.Net.Notify(ply, "Optional objectives are available in F4 → Objectives.", 0)
			Objectives:RefreshAll()
		end)
	end)
	hook.Add("PlayerDisconnected", "DRP.Objectives.Disconnect", function(ply)
		Objectives.States[ply] = nil
		timer.Simple(0, function() Objectives:RefreshAll() end)
	end)
	hook.Add("DRPJobChanged", "DRP.Objectives.Job", function(ply)
		if ready(ply) then
			Objectives:CheckRoleGoal(ply)
			Objectives:PruneInvalid(ply)
			Objectives:RefreshOffers(ply, true)
			Objectives:EnsureBeginnerGuide(ply)
		end
	end)
	hook.Add("DRPCraftCompleted","DRP.Objectives.Crafting",function(ply)
		if ready(ply) then Objectives:Emit(ply,"craft_completed",1) end
	end)
	hook.Add("DRPCivicStandingChanged", "DRP.Objectives.RoleCivic", function(ply)
		if ready(ply) and (tonumber(ply.DRPRoleGoalValue) or 0) > 0 then Objectives:Sync(ply) end
	end)
	hook.Add("DRPRoleBehaviorChanged", "DRP.Objectives.RoleBehavior", function(ply)
		if ready(ply) and (tonumber(ply.DRPRoleGoalValue) or 0) > 0 then Objectives:Sync(ply) end
	end)
	hook.Add("DRPGameplayEvent", "DRP.Objectives.Audit", function(actor, event)
		local mapped = auditEvents[event]
		if mapped and ready(actor) then Objectives:Emit(actor, mapped, 1) end
	end)
	hook.Add("DRPMarketplaceFulfilled", "DRP.Objectives.Market", function(seller, buyer)
		if ready(seller) then Objectives:Emit(seller, "marketplace_trade") Objectives:Emit(seller, "marketplace_sold") end
		if ready(buyer) then Objectives:Emit(buyer, "marketplace_trade") end
	end)
	hook.Add("DRPPoliceWitnessedOffence", "DRP.Objectives.PoliceWitness", function(_, officer)
		Objectives:Emit(officer, "police_witnessed")
	end)
	hook.Add("DRPEvidenceStored", "DRP.Objectives.Evidence", function(officer)
		Objectives:Emit(officer, "evidence_stored")
	end)
	hook.Add("DRPPlayerRevived", "DRP.Objectives.Medic", function(_, medic)
		Objectives:Emit(medic, "medic_revive")
		Objectives:Emit(medic, "player_healed")
	end)
	hook.Add("DRPPlayerHealed", "DRP.Objectives.HealingGuide", function(healer, target, amount)
		if healer ~= target and tonumber(amount) and tonumber(amount) > 0 then Objectives:Emit(healer, "player_healed") end
	end)
	hook.Add("DRPPropertyOwnershipChanged", "DRP.Objectives.PropertyGuide", function(ply, _, acquired)
		if acquired then Objectives:Emit(ply, "property_purchased") end
	end)
	hook.Add("DRPMayorConfidenceKept", "DRP.Objectives.Mayor", function(mayor)
		Objectives:Emit(mayor, "mayor_confidence_kept")
	end)
	hook.Add("DRPIncidentResolved", "DRP.Objectives.Incident", function(_, receipt)
		if not istable(receipt) then return end
		local instigator = DRP.Players.Online(receipt.instigator_id)
		local victim = DRP.Players.Online(receipt.victim_id)
		if ready(instigator) then Objectives:Emit(instigator, "incident_resolved") end
		if ready(victim) and victim ~= instigator then Objectives:Emit(victim, "incident_resolved") end
		if receipt.type == "mugging" and ready(instigator) then Objectives:Emit(instigator, "mugging_resolved") end
		if receipt.resolution == "suspect_arrested" and ready(instigator) then Objectives:Emit(instigator, "police_arrest") end
		if (receipt.type == "property_raid" or receipt.type == "armory_raid" or receipt.type == "treasury_raid")
			and receipt.winner_id == receipt.instigator_id and ready(instigator) then
			Objectives:Emit(instigator, "raid_victory")
		end
		if receipt.type == "property_raid" and receipt.winner_id == receipt.victim_id and ready(victim) then
			Objectives:Emit(victim, "property_defended")
		end
	end)
	hook.Add("DRPPlayerActivity", "DRP.Objectives.Activity", function(ply, now)
		local state = Objectives.States[ply]
		if not state or table.Count(state.active) == 0 then return end
		now = tonumber(now) or CurTime()
		if now - (state.activityAt or 0) >= 1 then
			state.activityAt = now
			Objectives:Emit(ply, "active_second")
		end
		if state.active.welcome_property and now - (state.visitAt or 0) >= 2 then
			state.visitAt = now
			if nearAccessibleProperty(ply) then Objectives:Emit(ply, "visit_property") end
		end
	end)
end

function Objectives:Stop()
	for _, event in ipairs({
		"DRPPlayerReady", "PlayerDisconnected", "DRPJobChanged", "DRPGameplayEvent",
		"DRPMarketplaceFulfilled", "DRPPoliceWitnessedOffence", "DRPEvidenceStored",
		"DRPPlayerRevived", "DRPPlayerHealed", "DRPPropertyOwnershipChanged",
		"DRPMayorConfidenceKept", "DRPIncidentResolved", "DRPPlayerActivity",
		"DRPCivicStandingChanged", "DRPRoleBehaviorChanged"
	}) do
		for identifier in pairs(hook.GetTable()[event] or {}) do
			if string.StartWith(identifier, "DRP.Objectives.") then hook.Remove(event, identifier) end
		end
	end
	self:SaveGuideProgress()
end

DRP.Net.Receive(ACTION, function(_, ply)
	if not DRP.Net.Allow(ply, "objectives_action", 0.25, 5) then return end
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local action = net.ReadUInt(3)
	local key = string.sub(net.ReadString(), 1, 48)
	if action == 0 then Objectives:RefreshOffers(ply)
	elseif action == 1 then
		local ok, reason = Objectives:Accept(ply, key)
		if not ok and reason then DRP.Net.Notify(ply, reason, 3) end
	elseif action == 2 then Objectives:Dismiss(ply, key, false)
	elseif action == 3 then
		local ok, reason = Objectives:Dismiss(ply, key, true)
		if not ok and reason then DRP.Net.Notify(ply, reason, 3) end
	elseif action == 4 then
		Objectives:Emit(ply, "guide_reviewed")
	end
end)

DRP.Net.Receive(ROLE_ACTION, function(_, ply)
	if not DRP.Net.Allow(ply, "objective_role_action", 0.35, 4) then return end
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local ok, reason = Objectives:SetRoleGoal(ply, net.ReadUInt(8))
	if not ok and reason then DRP.Net.Notify(ply, reason, 3) end
end)

-- Owner-only live testing path. This deliberately resets only the selected
-- player's beginner guide record; normal progression never calls it.
concommand.Add("drp_beginner_guide_reset", function(ply, _, arguments)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local target = IsValid(ply) and ply or nil
	local query = string.lower(string.Trim(table.concat(arguments or {}, " ")))
	if query ~= "" then
		target = nil
		for _, candidate in ipairs(DRP.Players.List or {}) do
			local matches = candidate:SteamID64() == query
				or string.find(string.lower(candidate:Nick()), query, 1, true)
				or string.find(string.lower(candidate:DRPName()), query, 1, true)
			if matches then
				if IsValid(target) then target = nil break end
				target = candidate
			end
		end
	end
	if not ready(target) then
		local message = "Usage: drp_beginner_guide_reset [unique player name or SteamID64]"
		if IsValid(ply) then DRP.Net.Notify(ply, message, 3) else print("[DRP] " .. message) end
		return
	end
	Objectives.GuideProgress[target:SteamID64()] = {}
	Objectives.GuideTesters[target] = true
	local state = stateFor(target)
	for _, key in ipairs(Objectives.GuideSequence) do
		state.active[key] = nil
		state.completed[key] = nil
		state.cooldowns[key] = nil
	end
	Objectives:SaveGuideProgress()
	Objectives:RefreshOffers(target, true)
	Objectives:EnsureBeginnerGuide(target)
	DRP.Net.Notify(target, "Your beginner guide was reset for live testing.", 1)
end)
