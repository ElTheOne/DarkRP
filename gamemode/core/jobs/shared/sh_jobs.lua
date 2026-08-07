DRP.Job = {
	CITIZEN = 1,
	POLICE = 2,
	MAYOR = 3,
	THIEF = 4,
	HITMAN = 5,
	MEDIC = 6,
	HOBO = 7,
	GUN_DEALER = 8,
	GANGSTER = 9,
	MOB_BOSS = 10,
	DRUG_DEALER = 11,
	KIDNAPPER = 12
}

DRP.Jobs = {
	[DRP.Job.CITIZEN] = {
		key = "citizen",
		name = "Citizen",
		color = Color(72, 174, 96),
		model = "models/player/Group01/male_07.mdl",
		weapons = { "weapon_crowbar", "weapon_physgun" },
		salary = 45,
		limit = 0,
		rolePath = { kind = "baseline", description = "Default civic identity while no stronger behavior pattern applies." }
	},
	[DRP.Job.POLICE] = {
		key = "police",
		name = "Police Officer",
		color = Color(70, 120, 220),
		model = "models/player/police.mdl",
		weapons = { "weapon_stunstick", "arc9_go_p2000", "weapon_drp_taser", "weapon_drp_cuffs", "weapon_physgun" },
		salary = 75,
		limit = 16,
		isPolice = true,
		isGovernment = true,
		manualSelectable = true,
		civicMinimum = 100,
		rolePath = { kind = "government", description = "Selectable government service role. Requires at least +100 civic standing." },
		agendaGroup = "government"
	},
	[DRP.Job.MAYOR] = {
		key = "mayor",
		name = "Mayor",
		color = Color(170, 75, 190),
		model = "models/player/breen.mdl",
		weapons = { "weapon_physgun", "weapon_drp_mayor_tablet" },
		salary = 110,
		limit = 1,
		isGovernment = true,
		electionOnly = true,
		canUsePoliceTablet = true,
		civicMinimum = 250,
		rolePath = { kind = "government", description = "Elected government role. Candidates require at least +250 civic standing." },
		canSetAgenda = true,
		agendaGroup = "government"
	},
	[DRP.Job.THIEF] = {
		key = "thief",
		name = "Thief",
		color = Color(145, 105, 65),
		model = "models/player/Group03/male_07.mdl",
		weapons = { "weapon_crowbar", "weapon_physgun" },
		salary = 55,
		limit = 8,
		-- Generic capability flag so future jobs can opt into mugging without
		-- being hard-coded into the mugging service.
		canMug = true,
		canRaid = true,
		rolePath = { kind = "civic", civicMaximum = -150, description = "Recognised automatically at −150 civic standing." }
	},
	[DRP.Job.HITMAN] = {
		key = "hitman",
		name = "Hitman",
		color = Color(175, 70, 70),
		model = "models/player/Group03/male_04.mdl",
		weapons = { "arc9_go_usp", "weapon_physgun" },
		salary = 60,
		limit = 4,
		-- Contract incidents can use this capability without hard-coding a job ID.
		canExecuteHits = true,
		rolePath = { kind = "civic", civicMaximum = -325, description = "Recognised at −325 civic standing, or through repeated completed hit contracts." }
	},
	[DRP.Job.MEDIC] = {
		key = "medic",
		name = "Medic",
		color = Color(65, 185, 165),
		model = "models/player/kleiner.mdl",
		weapons = { "weapon_drp_medkit", "weapon_drp_defibrillator", "weapon_physgun" },
		salary = 70,
		limit = 4,
		canHeal = true,
		rolePath = { kind = "behavior", metric = "healing", threshold = 8, civicMinimum = 100, description = "Earned by using the public HL medkit to provide repeated genuine aid with positive civic standing." }
	},
	[DRP.Job.HOBO] = {
		key = "hobo",
		name = "Hobo",
		color = Color(145, 115, 70),
		model = "models/jessev92/kuma/characters/saddam_ply.mdl",
		weapons = { "weapon_bugbait", "weapon_physgun" },
		salary = 15,
		limit = 8,
		isHobo = true,
		rolePath = { kind = "economic", description = "Recognised automatically when your wallet is empty or you do not own a property." }
	},
	[DRP.Job.GUN_DEALER] = {
		key = "gun_dealer",
		name = "Gun Dealer",
		color = Color(215, 150, 55),
		model = "models/player/Group03/male_06.mdl",
		weapons = { "arc9_go_glock", "weapon_physgun" },
		salary = 55,
		limit = 4,
		canSpawnWeaponCrates = true,
		rolePath = { kind = "behavior", metric = "weaponTrades", threshold = 8, description = "Earned by completing weapon trades through the marketplace." }
	},
	[DRP.Job.GANGSTER] = {
		key = "gangster",
		name = "Gangster",
		color = Color(100, 100, 115),
		model = "models/player/Group03/male_03.mdl",
		weapons = { "weapon_crowbar", "weapon_physgun" },
		salary = 50,
		limit = 10,
		canRaid = true,
		agendaGroup = "criminal",
		rolePath = { kind = "civic", civicMaximum = -525, description = "Recognised automatically at −525 civic standing, with raiding behavior reinforcing the role." }
	},
	[DRP.Job.MOB_BOSS] = {
		key = "mob_boss",
		name = "Mob Boss",
		color = Color(85, 85, 100),
		model = "models/player/gman_high.mdl",
		weapons = { "arc9_go_deagle", "weapon_physgun" },
		salary = 75,
		limit = 1,
		canRaid = true,
		canSetAgenda = true,
		agendaGroup = "criminal",
		rolePath = { kind = "civic", civicMaximum = -1000, exclusive = true, description = "Final criminal identity. Requires the minimum −1000 civic standing and only one player may hold it server-wide." }
	},
	[DRP.Job.DRUG_DEALER] = {
		key = "drug_dealer",
		name = "Drug Dealer",
		color = Color(115, 185, 90),
		model = "models/player/Group03/male_05.mdl",
		weapons = { "weapon_crowbar", "weapon_physgun", "zwf_shoptablet", "zwf_cable", "zwf_wateringcan" },
		salary = 50,
		limit = 4,
		canSpawnDrugs = true,
		agendaGroup = "criminal",
		rolePath = { kind = "behavior", metric = "narcotics", threshold = 12, civicMaximum = -100, description = "Earned through sustained drug production and sales below −100 civic standing." }
	},
	[DRP.Job.KIDNAPPER] = {
		key = "kidnapper",
		name = "Kidnapper",
		color = Color(154, 72, 132),
		model = "models/player/Group03/male_01.mdl",
		weapons = { "weapon_crowbar", "weapon_physgun", "weapon_drp_kidnap_baton", "weapon_drp_blindfold", "weapon_drp_gag" },
		salary = 45,
		limit = 0,
		canMug = true,
		canKidnap = true,
		agendaGroup = "criminal",
		rolePath = { kind = "behavior", metric = "forceDrugging", threshold = 3, civicMaximum = -100, description = "Earned by repeatedly force-drugging victims after entering negative civic standing." }
	}
}

DRP.JobByKey = {}
for id, job in pairs(DRP.Jobs) do
	-- Mugging is a civilian action, not an earned criminal-class permission.
	-- Keep legacy job metadata aligned for integrations that inspect it.
	job.canMug = job.isGovernment ~= true
	DRP.JobByKey[job.key] = id
	team.SetUp(id, job.name, job.color, false)
end

-- Displayed identities and gameplay permissions are intentionally separate.
-- Negative civic standing opens the cumulative criminal ladder even when a
-- behavior specialist identity (for example Drug Dealer) is displayed.
DRP.CivicCapabilityThresholds = {
	canRaid = -150,
	canExecuteHits = -325,
	canKidnap = -425,
	canUseCriminalAgenda = -525,
	canSpawnDrugs = -650
}

DRP.JobPermissionProfiles = {
	[DRP.Job.CITIZEN] = {
		requirement = "Any civic standing while outside government",
		permissions = "Mugging"
	},
	[DRP.Job.POLICE] = {
		requirement = "+100 civic and an available government position",
		permissions = "Police equipment, armory access, detention and arrest"
	},
	[DRP.Job.MAYOR] = {
		requirement = "+250 civic and election victory",
		permissions = "Government agenda, taxation, treasury and lockdowns"
	},
	[DRP.Job.THIEF] = {
		requirement = "−150 civic or lower",
		permissions = "Mugging and declared raids"
	},
	[DRP.Job.HITMAN] = {
		requirement = "−325 civic or lower",
		permissions = "All Thief permissions and hit contracts"
	},
	[DRP.Job.MEDIC] = {
		requirement = "+100 civic and 8 credited HL medkit aid events",
		permissions = "Medical equipment and credited healing"
	},
	[DRP.Job.HOBO] = {
		requirement = "Empty wallet or no owned property",
		permissions = "Tip jars and Hobo equipment"
	},
	[DRP.Job.GUN_DEALER] = {
		requirement = "8 weapon trades while at −50 civic or higher",
		permissions = "All configured Gun Dealer weapon crates; civic alone never grants this"
	},
	[DRP.Job.GANGSTER] = {
		requirement = "−525 civic or lower",
		permissions = "All Hitman permissions and the criminal agenda"
	},
	[DRP.Job.MOB_BOSS] = {
		requirement = "Exactly −1000 civic; one server-wide position",
		permissions = "Every criminal permission, one-way PvP against everyone, all criminal gear, and approved weapon crates"
	},
	[DRP.Job.DRUG_DEALER] = {
		requirement = "12 narcotics events below −100 civic, or −650 civic for drug-item access",
		permissions = "Drug packages and production equipment"
	},
	[DRP.Job.KIDNAPPER] = {
		requirement = "3 force-drugging events below −100 civic, or −425 civic for kidnapping access",
		permissions = "Kidnapping and force-drugging equipment"
	}
}

DRP.JobEntityCapabilityByRole = {
	drug_dealer = "canSpawnDrugs",
	kidnapper = "canKidnap",
	gun_dealer = "canSpawnWeaponCrates"
}

local playerMeta = FindMetaTable("Player")

function playerMeta:DRPJobID()
	if SERVER then return self.DRPJobValue or DRP.Job.CITIZEN end
	local rosterJob = DRP.Roster and DRP.Roster.Value(self, "job")
	if rosterJob and DRP.Jobs[rosterJob] then return rosterJob end
	if self == LocalPlayer() then return DRP.ClientProfile and DRP.ClientProfile.job or DRP.Job.CITIZEN end
	return DRP.Jobs[self:Team()] and self:Team() or DRP.Job.CITIZEN
end

function playerMeta:DRPJob()
	return DRP.Jobs[self:DRPJobID()] or DRP.Jobs[DRP.Job.CITIZEN]
end

function DRP.JobAllowsMugging(job)
	return istable(job) and job.isGovernment ~= true
end

function playerMeta:DRPHasRoleCapability(capability)
	local job = self:DRPJob()
	if capability == "canMug" then return DRP.JobAllowsMugging(job) end
	local criminalThreshold = DRP.CivicCapabilityThresholds[capability]
	if criminalThreshold and job.isGovernment then return false end
	if job.key == "mob_boss" and (criminalThreshold or capability == "canSpawnWeaponCrates") then return true end
	if job[capability] == true then return true end
	local civic
	if SERVER then civic = DRP.Civic and DRP.Civic:Get(self) or 0
	else civic = DRP.Roster and DRP.Roster.Value(self, "civic", 0) or 0 end
	if criminalThreshold then return civic <= criminalThreshold end
	return false
end

function playerMeta:DRPJobName()
	local title
	if SERVER then title = self.DRPJobNameValue
	elseif DRP.Roster then title = DRP.Roster.Value(self, "jobTitle", "") end
	title = tostring(title or "")
	return title ~= "" and title or self:DRPJob().name
end

function playerMeta:DRPName()
	local name
	if SERVER then name = self.DRPRPNameValue
	elseif DRP.Roster then name = DRP.Roster.Value(self, "rpName", "") end
	name = tostring(name or "")
	return name ~= "" and name or self:Nick()
end

function playerMeta:DRPMoney()
	if SERVER then return self.DRPMoneyValue or 0 end
	if self == LocalPlayer() then return DRP.ClientProfile and DRP.ClientProfile.money or 0 end
	return 0
end

-- Minimal DarkRP-compatible player facade for paid addons which delegate their
-- balance operations to the active gamemode. DRP remains the sole authority.
if not playerMeta.addMoney then
	function playerMeta:addMoney(amount)
		amount = math.floor(tonumber(amount) or 0)
		if not SERVER or not DRP.Economy or amount == 0 then return false end
		if amount > 0 then return DRP.Economy.Add(self, amount, "external addon") end
		return DRP.Economy.Take(self, -amount, "external addon")
	end
end

if not playerMeta.canAfford then
	function playerMeta:canAfford(amount)
		return self:DRPMoney() >= math.max(0, math.floor(tonumber(amount) or 0))
	end
end

if not playerMeta.getDarkRPVar then
	function playerMeta:getDarkRPVar(key)
		if key == "money" then return self:DRPMoney() end
		if key == "job" then return self:DRPJobName() end
		if key == "rpname" then return self:DRPName() end
	end
end

if not playerMeta.wanted then
	function playerMeta:wanted(officer, reason)
		if not SERVER or not DRP.Legal or not IsValid(officer) then return false end
		return DRP.Legal.RequestWarrant(officer, self, tostring(reason or "illegal narcotics activity"))
	end
end

function playerMeta:DRPXP()
	if SERVER then return self.DRPXPValue or 0 end
	if self == LocalPlayer() then return DRP.ClientProfile and DRP.ClientProfile.xp or 0 end
	return 0
end

function playerMeta:DRPXPLevel()
	if SERVER then return self.DRPXPLevelValue or 1 end
	local rosterLevel = DRP.Roster and DRP.Roster.Value(self, "level")
	if rosterLevel then return rosterLevel end
	if self == LocalPlayer() then return DRP.ClientProfile and DRP.ClientProfile.level or 1 end
	return 1
end

function playerMeta:DRPXPPrestige()
	if SERVER then return self.DRPXPPrestigeValue or 0 end
	local rosterPrestige = DRP.Roster and DRP.Roster.Value(self, "prestige")
	if rosterPrestige ~= nil then return rosterPrestige end
	if self == LocalPlayer() then return DRP.ClientProfile and DRP.ClientProfile.prestige or 0 end
	return 0
end

function playerMeta:DRPXPPrestigeTokens()
	if SERVER then return self.DRPXPPrestigeTokensValue or 0 end
	if self == LocalPlayer() then return DRP.ClientProfile and DRP.ClientProfile.prestigeTokens or 0 end
	return 0
end

function playerMeta:DRPXPUnlockedItems()
	if self == LocalPlayer() then return DRP.ClientProfile and DRP.ClientProfile.prestigeItems or {} end
	return self.DRPXPUnlockedItemsValue or {}
end
