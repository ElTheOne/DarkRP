local Tests = { Last = nil }
DRP.Tests = Tests
DRP.Services.Register("tests", Tests)

if SERVER then
	local allowTestCommands = CreateConVar("drp_enable_test_commands", "0", FCVAR_ARCHIVE,
		"Allow Owner/server-console test and bot commands. Never enable on a public server.", 0, 1)

	local function canRunTestCommand(ply)
		if not allowTestCommands:GetBool() then return false end
		return not IsValid(ply) or (DRP.Admin and DRP.Admin.IsOwner(ply))
	end

	concommand.Add("addbots", function(ply, _, args)
		if not canRunTestCommand(ply) then return end
		local count = math.Clamp(math.floor(tonumber(args[1]) or 0), 0, 64)
		for _ = 1, count do RunConsoleCommand("bot") end
	end)

	concommand.Add("kickbots", function(ply)
		if not canRunTestCommand(ply) then return end
		for _, target in player.Iterator() do if target:IsBot() then target:Kick() end end
	end)

	function Tests.CanRunProductionTest(ply)
		return canRunTestCommand(ply)
	end
end

local function scenarioOutcome(incidentType, resolution, winnerSide, loserSide)
	local instigator, victim = {}, {}
	local outcome = DRP.Incidents.BuildOutcome({ type = incidentType, instigator = instigator, victim = victim }, resolution, "automated scenario")
	local expectedWinner = winnerSide == "instigator" and instigator or victim
	local expectedLoser = loserSide == "instigator" and instigator or victim
	local rewards = DRP.Incidents.OutcomeRewards(outcome)
	return istable(outcome)
		and outcome.instigator == instigator and outcome.victim == victim
		and outcome.winner == expectedWinner and outcome.loser == expectedLoser
		and #rewards == (instigator == victim and 1 or 2)
		and rewards[1] and rewards[1].amount == 38 and rewards[1].player == expectedWinner
		and rewards[2] and rewards[2].amount == 26 and rewards[2].player == expectedLoser
end

function Tests.Run()
	local results = {}
	local function check(name, condition, detail)
		results[#results + 1] = { name = name, passed = condition == true, detail = tostring(detail or "") }
	end

	check("xp_level_1_threshold", DRP.Experience:XPNeededForNext(1) == 110, DRP.Experience:XPNeededForNext(1))
	check("xp_compound_level_2", DRP.Experience:XPNeededForNext(2) == 118, DRP.Experience:XPNeededForNext(2))
	check("xp_compound_level_3", DRP.Experience:XPNeededForNext(3) == 126, DRP.Experience:XPNeededForNext(3))
	check("xp_compound_level_4", DRP.Experience:XPNeededForNext(4) == 135, DRP.Experience:XPNeededForNext(4))
	check("xp_high_level_curve_bounded", DRP.Experience:XPNeededForNext(45) == 2160, DRP.Experience:XPNeededForNext(45))
	local level, remainder = DRP.Experience:TotalToState(110)
	check("xp_level_transition", level == 2 and remainder == 0, "level=" .. level .. " remainder=" .. remainder)
	local sampleTotal = DRP.Experience:XPForLevel(12) + 73
	local sampleLevel, sampleRemainder = DRP.Experience:TotalToState(sampleTotal)
	check("xp_total_roundtrip", sampleLevel == 12 and sampleRemainder == 73, "level=" .. sampleLevel .. " remainder=" .. sampleRemainder)
	local persisted = DRP.Experience:NormalizePersistentState({ xp_points = 73, xp_level = 12, xp_prestige = 2, xp_prestige_tokens = 1, xp_prestige_items = '["weapon:weapon_crowbar"]' }, true)
	check("xp_persistence_roundtrip", persisted.xp == 73 and persisted.level == 12 and persisted.prestige == 2 and persisted.tokens == 1 and persisted.unlocked["weapon:weapon_crowbar"] == true)
	local maximumPrestige = DRP.Experience:NormalizePersistentState({ xp_points = 0, xp_level = 100, xp_prestige = 999, xp_prestige_tokens = 999 }, true)
	check("prestige_ten_rank_cap", DRP.Experience.MaxPrestige == 10 and maximumPrestige.level == 100
		and maximumPrestige.prestige == 10 and maximumPrestige.tokens == 10)
	local reloadedUnlocks = DRP.Experience:NormalizeUnlockedItems(persisted.unlocked)
	check("prestige_unlock_set_survives_join_sanitizer", reloadedUnlocks["weapon:weapon_crowbar"] == true)
	local legacyUnlocks = DRP.Experience:NormalizeUnlockedItems({ ["weapon:weapon_crowbar"] = true })
	check("prestige_unlock_legacy_set_supported", legacyUnlocks["weapon:weapon_crowbar"] == true)
	local weaponEligible, weaponKey = DRP.Experience:IsPrestigeWeapon("weapon:weapon_crowbar")
	local propEligible = DRP.Experience:IsPrestigeWeapon("prop:models/props_c17/oildrum001a.mdl")
	check("prestige_individual_weapons_only", weaponEligible == true and weaponKey == "weapon:weapon_crowbar" and propEligible == false)

	check("mugging_payment", scenarioOutcome("mugging", "payment_received", "instigator", "victim"))
	check("mugging_victim_death", scenarioOutcome("mugging", "victim_killed", "instigator", "victim"))
	check("mugging_mugger_death", scenarioOutcome("mugging", "mugger_killed", "victim", "instigator"))
	check("arrest_booking", scenarioOutcome("legal_warrant", "suspect_arrested", "instigator", "victim"))
	check("police_sighting_arrest", scenarioOutcome("police_weapon_sighting", "suspect_arrested", "instigator", "victim"))
	check("raid_attacker_victory", scenarioOutcome("property_raid", "attackers_victory", "instigator", "victim"))
	check("raid_defender_victory", scenarioOutcome("property_raid", "defenders_victory", "victim", "instigator"))
	check("treasury_raid_attacker_victory", scenarioOutcome("treasury_raid", "raiders_victory", "instigator", "victim"))
	check("treasury_raid_defender_victory", scenarioOutcome("treasury_raid", "defenders_victory", "victim", "instigator"))
	check("treasury_raid_policy", DRP.Treasury.RaidDuration == 90 and DRP.Treasury.RaidCooldown == 600
		and DRP.Treasury.MinimumBalance == 1000 and DRP.Treasury:LootForBalance(1000) == 250
		and DRP.Treasury:LootForBalance(400000) == 100000 and DRP.Treasury:LootForBalance(1000000) == 100000
		and isfunction(DRP.Government.GetTreasury) and isfunction(DRP.Government.SetTreasury)
		and isfunction(DRP.Government.DepositTreasury) and isfunction(DRP.Government.WithdrawTreasury)
		and isfunction(DRP.Money.SpawnSystemDrop) and isfunction(DRP.Money.RefundSystemDrop))
	local firstRaider, secondRaider = {}, {}
	local split = DRP.Treasury:BuildLootShares({ instigator = firstRaider }, 100, { secondRaider, firstRaider })
	check("treasury_loot_split", #split == 2 and split[1].amount == 50 and split[2].amount == 50)
	local remainderSplit = DRP.Treasury:BuildLootShares({ instigator = secondRaider }, 101, { firstRaider, secondRaider })
	check("treasury_loot_remainder_to_instigator", #remainderSplit == 2
		and remainderSplit[1].amount == 50 and remainderSplit[2].amount == 51)
	local treasuryDefinition = DRP.JobEntityService.ByKey.treasury_vault
	check("treasury_vault_registration", istable(treasuryDefinition)
		and treasuryDefinition.class == "drp_treasury_vault" and treasuryDefinition.ownerOnly == true
		and scripted_ents.GetStored("drp_treasury_vault") ~= nil
		and DRP.Incidents.TeamShareTypes.treasury_raid == true
		and isfunction((hook.GetTable().EntityRemoved or {})["DRP.Treasury.EntityRemoved"])
		and isfunction((hook.GetTable().PhysgunPickup or {})["DRP.Treasury.LockDuringRaid"])
		and isfunction((hook.GetTable().GravGunPickupAllowed or {})["DRP.Treasury.LockDuringRaid"])
		and isfunction((hook.GetTable().CanTool or {})["DRP.Treasury.LockDuringRaid"])
		and isfunction((hook.GetTable().CanProperty or {})["DRP.Treasury.LockDuringRaid"])
		and isfunction((hook.GetTable().DRPAdminModeChanged or {})["DRP.Treasury.AdminMode"]))
	local sameParty = {}
	local singleOutcome = DRP.Incidents.BuildOutcome({ type = "lockdown", instigator = sameParty, victim = sameParty }, "ended", "single-party scenario")
	check("single_party_reward_deduplicated", #DRP.Incidents.OutcomeRewards(singleOutcome) == 1)
	check("death_hook", isfunction((hook.GetTable().PlayerDeath or {})["DRP.Incidents.ParticipantDeath"]))

	local disconnectHooks = hook.GetTable().PlayerDisconnected or {}
	check("xp_not_cleared_before_save", disconnectHooks["DRP.Experience.ClearState"] == nil)
	check("persistence_writer", isfunction(DRP.Storage.SavePlayer) and isfunction(DRP.Economy.SavePlayer) and isfunction(DRP.Inventory.SaveNow))
	check("persistence_disconnect_inventory", isfunction(GAMEMODE.PlayerDisconnected)
		and not isfunction(disconnectHooks["DRP.Inventory.Clear"]))
	local ammoWidth, ammoHeight = DRP.Inventory.Footprint({ kind = "ammo", ammo_type = "Pistol", class = "drp_ammo_stack" })
	DRP.Inventory.WeaponFootprintOverrides["weapon_drp_grid_test"] = { 5, 2 }
	local rifleWidth, rifleHeight = DRP.Inventory.Footprint({ kind = "weapon", class = "weapon_drp_grid_test" })
	check("hands_item_footprints", ammoWidth == 1 and ammoHeight == 1 and rifleWidth == 5 and rifleHeight == 2)
	local occupied = { { id = "existing", x = 1, y = 1, w = 2, h = 2 } }
	local overlap = DRP.Inventory.CanPlaceRecords(occupied, { id = "candidate", kind = "resource", class = "drp_cocaine_item", resource = "salvage_scrap" }, 2, 2, false)
	local edge = DRP.Inventory.CanPlaceRecords(occupied, { id = "candidate", kind = "resource", class = "drp_cocaine_item", resource = "salvage_scrap" }, 6, 10, false)
	local outside = DRP.Inventory.CanPlaceRecords(occupied, { id = "candidate", kind = "weapon", class = "weapon_drp_grid_test" }, 3, 10, false)
	check("hands_grid_placement", overlap == false and edge == true and outside == false)
	local migrationSource = {}
	for index = 1, 13 do migrationSource[index] = { kind = "weapon", class = "weapon_drp_grid_test", label = "Legacy Rifle " .. index } end
	local migrated, overflow = DRP.Inventory.LayoutRecordsForTest(migrationSource, false)
	-- The 6x10 grid may rotate 5x2 rifles into 2x5 footprints, fitting six
	-- records.  The preservation invariant is the important part: all thirteen
	-- records must end up either placed or in overflow without loss.
	check("hands_legacy_overflow_preserved", #migrated == 6 and #overflow == 7 and (#migrated + #overflow) == #migrationSource,
		string.format("placed=%d overflow=%d source=%d", #migrated, #overflow, #migrationSource))
	local packedBatch = DRP.Inventory.CanInsertBatchRecords({}, {
		{ kind = "weapon", class = "weapon_drp_grid_test" },
		{ kind = "weapon", class = "weapon_drp_grid_test" },
		{ kind = "ammo", class = "drp_ammo_stack", ammo_type = "Pistol", amount = 30 }
	})
	local rejectedBatch = DRP.Inventory.CanInsertBatchRecords(migrated, { { kind = "weapon", class = "weapon_drp_grid_test" } })
	check("hands_transactional_batch_capacity", packedBatch == true and rejectedBatch == false)
	check("hands_vip_alt_slot_policy", isfunction(DRP.Inventory.CanUseEquipmentSlot)
		and isfunction(DRP.Inventory.EnforceEquipmentAccess)
		and DRP.Inventory.EquipmentSlots.alt1 == true and DRP.Inventory.EquipmentSlots.alt6 == true
		and DRP.Inventory.VIPEquipmentSlots.alt3 ~= true and DRP.Inventory.VIPEquipmentSlots.alt4 == true
		and DRP.Inventory.VIPEquipmentSlots.alt5 == true and DRP.Inventory.VIPEquipmentSlots.alt6 == true
		and DRP.AdminRankLevel("owner") > DRP.AdminRankLevel("headadmin")
		and DRP.AdminRankLevel("headadmin") > DRP.AdminRankLevel("admin")
		and DRP.AdminRankLevel("admin") > DRP.AdminRankLevel("moderator")
		and DRP.AdminRankLevel("moderator") > DRP.AdminRankLevel("supporter")
		and DRP.AdminRankLevel("supporter") > DRP.AdminRankLevel("vipplus")
		and DRP.AdminRankLevel("vipplus") > DRP.AdminRankLevel("vip")
		and DRP.AdminRankLevel("vip") > DRP.AdminRankLevel("trusted")
		and DRP.AdminRankLevel("trusted") > DRP.AdminRankLevel("user")
		and DRP.RankHasVIPBenefits("trusted") == false
		and DRP.RankHasVIPBenefits("vip") == true
		and DRP.RankHasVIPBenefits("moderator") == false
		and DRP.RankHasVIPBenefits("owner") == true)
	local entitlementTestIDs = {
		user = "76561197960265729", admin = "76561197960265730",
		headadmin = "76561197960265731", owner = "76561197960265732"
	}
	local entitlementOriginals = {}
	for _, steamID64 in pairs(entitlementTestIDs) do entitlementOriginals[steamID64] = DRP.Admin.Records[steamID64] end
	DRP.Admin.Records[entitlementTestIDs.user] = { name = "Flag Test", rank = "user", trusted = true, supporter_tier = 1 }
	DRP.Admin.Records[entitlementTestIDs.admin] = { name = "Admin Flag Test", rank = "admin", trusted = false, supporter_tier = 1 }
	DRP.Admin.Records[entitlementTestIDs.headadmin] = { name = "HeadAdmin Test", rank = "headadmin", trusted = false, supporter_tier = 0 }
	DRP.Admin.Records[entitlementTestIDs.owner] = { name = "Owner Test", rank = "owner", trusted = false, supporter_tier = 0 }
	check("admin_entitlement_resolution",
		DRP.Admin.BaseRankKey(entitlementTestIDs.user) == "user"
		and DRP.Admin.DisplayRankKey(entitlementTestIDs.user) == "vip"
		and DRP.Admin.DisplayRankKey(entitlementTestIDs.admin) == "admin"
		and DRP.Admin.HasVIP(entitlementTestIDs.admin)
		and DRP.Admin.HasVIP(entitlementTestIDs.headadmin)
		and DRP.Admin.HasVIP(entitlementTestIDs.owner)
		and DRP.Admin.MaskForRank(DRP.Admin.BaseRankKey(entitlementTestIDs.user)) == 0)
	check("supporter_reward_rounding", DRP.Supporter.ApplyReward(entitlementTestIDs.user, 101) == 126
		and DRP.Supporter.ApplyRollCount(entitlementTestIDs.user, 1) == 2)
	DRP.Admin.Records[entitlementTestIDs.user].supporter_tier = 0
	check("admin_entitlement_vip_expiry_fallback", DRP.Admin.DisplayRankKey(entitlementTestIDs.user) == "trusted"
		and DRP.Admin.HasFlag(entitlementTestIDs.user, "trusted")
		and not DRP.Admin.HasVIP(entitlementTestIDs.user))
	DRP.Admin.Records[entitlementTestIDs.admin].supporter_tier = 0
	check("admin_vip_access_requires_entitlement", not DRP.Admin.HasVIP(entitlementTestIDs.admin)
		and DRP.Admin.HasVIP(entitlementTestIDs.headadmin) and DRP.Admin.HasVIP(entitlementTestIDs.owner))
	check("admin_entitlement_interfaces", isfunction(DRP.Admin.SetFlag) and isfunction(DRP.Admin.SetSupporterTier)
		and isfunction(DRP.Admin.HasFlag) and isfunction(DRP.Admin.HasTrusted)
		and isfunction(DRP.Trust.CheckDiscordRole))
	DRP.Admin.Records[entitlementTestIDs.user].supporter_tier = 3
	check("supporter_tier_values", DRP.Supporter.RewardMultiplier(entitlementTestIDs.user) == 2
		and DRP.Supporter.EntityBonus(entitlementTestIDs.user) == 40
		and DRP.Supporter.PropertyLimit(entitlementTestIDs.user) == 3
		and DRP.Supporter.ApplyReward(entitlementTestIDs.user, 101) == 202
		and DRP.Props and isfunction(DRP.Props.TrustEntityLimit)
		and DRP.Props.TrustEntityLimit(entitlementTestIDs.user) == 120
		and DRP.Supporter.RewardMultiplier(entitlementTestIDs.headadmin) == 1
		and DRP.Supporter.RewardMultiplier(entitlementTestIDs.owner) == 1)
	for _, steamID64 in pairs(entitlementTestIDs) do DRP.Admin.Records[steamID64] = entitlementOriginals[steamID64] end
	local inventoryHooks = hook.GetTable()
	check("hands_weapon_loadout_authority", isfunction(DRP.Inventory.CreateWeaponRecord)
		and isfunction(DRP.Inventory.CanPossessWeapon)
		and isfunction(DRP.Inventory.GrantEquippedWeapons)
		and isfunction(DRP.Inventory.ReconcileWeapons)
		and isfunction((inventoryHooks.PlayerCanPickupWeapon or {})["DRP.Inventory.RequireEquippedWeapon"])
		and isfunction((inventoryHooks.PlayerSwitchWeapon or {})["DRP.Inventory.RequireEquippedWeapon"])
		and isfunction((inventoryHooks.WeaponEquip or {})["DRP.Inventory.RequireEquippedWeapon"])
		and DRP.JobService.IsUtilityWeapon("weapon_drp_keys")
		and DRP.JobService.IsUtilityWeapon("weapon_drp_pocket")
		and DRP.JobService.IsUtilityWeapon("weapon_physgun")
		and DRP.JobService.IsUtilityWeapon("weapon_physcannon")
		and DRP.JobService.IsUtilityWeapon("gmod_tool")
		and DRP.JobService.IsUtilityWeapon("ephone")
		and DRP.DropPolicy.nonDroppableWeapons.weapon_physcannon == true)
	check("death_suitcase_authority", DRP.DeathLoot == DRP.Services.Get("death_loot")
		and scripted_ents.GetStored("drp_death_suitcase") ~= nil
		and isfunction(DRP.Inventory.ExtractAll)
		and isfunction((hook.GetTable().PhysgunPickup or {})["DRP.DeathLoot.Protect"])
		and isfunction((hook.GetTable().GravGunPickupAllowed or {})["DRP.DeathLoot.ProtectGravGun"])
		and isfunction((hook.GetTable().GravGunPunt or {})["DRP.DeathLoot.ProtectPunt"])
		and isfunction((hook.GetTable().CanTool or {})["DRP.DeathLoot.ProtectTools"])
		and isfunction((hook.GetTable().CanProperty or {})["DRP.DeathLoot.ProtectProperties"])
		and (hook.GetTable().Think or {})["DRP.DeathLoot"] == nil)
	local salvageDump = DRP.JobEntityService.ByKey.salvage_dumpster
	local salvageTrash = DRP.JobEntityService.ByKey.salvage_trashcan
	check("salvage_container_registration", DRP.Salvage == DRP.Services.Get("salvage")
		and istable(salvageDump) and salvageDump.ownerOnly == true and salvageDump.countLimit == 16
		and istable(salvageTrash) and salvageTrash.ownerOnly == true and salvageTrash.countLimit == 32
		and scripted_ents.GetStored("drp_salvage_dumpster") ~= nil and scripted_ents.GetStored("drp_salvage_trashcan") ~= nil)
	check("salvage_policy", DRP.Salvage.Types.trashcan.personalCooldown == 600
		and DRP.Salvage.Types.trashcan.sharedCooldown == 1800
		and DRP.Salvage.Types.dumpster.personalCooldown == 1200
		and DRP.Salvage.Types.dumpster.sharedCooldown == 2700
		and DRP.Salvage:IsRareWeaponAllowed("weapon_rpg") == false
		and DRP.Salvage:IsRecordAllowed({ kind = "weapon", class = "weapon_pistol" }) == false
		and DRP.Salvage:IsRecordAllowed({ kind = "ammo", class = "drp_ammo_stack", ammo_type = "Pistol" }) == false
		and DRP.Salvage:IsRecordAllowed({ kind = "drug", class = "drp_drug", drug = "weed" }) == false
		and DRP.Salvage:IsRecordAllowed({ kind = "entity", class = "zwf_jar" }) == true
		and DRP.Salvage:IsRecordAllowed({ kind = "entity", class = "zmlab2_item_meth" }) == true
		and (hook.GetTable().Think or {})["DRP.Salvage"] == nil)
	check("roleplay_calendar_authority", DRP.Calendar == DRP.Services.Get("calendar")
		and DRP.Calendar.RealSecondsPerDay == 3600 and DRP.Calendar.Scale == 24
		and isfunction(DRP.Calendar.Now) and isfunction(DRP.Calendar.Format)
		and isfunction(DRP.Calendar.SyncDayNight)
		and DRP.Net.ReceiverAudit[DRP.Calendar.RequestMessage] ~= nil)
	check("contracts_escrow_authority", DRP.Contracts == DRP.Services.Get("contracts")
		and isfunction(DRP.Contracts.AddAimedEntity) and isfunction(DRP.Contracts.AddPocketItem)
		and isfunction(DRP.Contracts.TryAccept) and isfunction(DRP.Contracts.Fulfill)
		and isfunction(DRP.Contracts.HandleParticipantDeath)
		and isfunction(DRP.Inventory.TakeRaw) and isfunction(DRP.Inventory.InsertRaw)
		and isfunction(DRP.Inventory.SpawnRecordAt) and isfunction(DRP.Inventory.DropAllAt)
		and isfunction(DRP.Props.TransferOwnership))
	check("contextual_objective_authority", DRP.Objectives == DRP.Services.Get("objectives")
		and DRP.Hints == DRP.Services.Get("hints")
		and isfunction(DRP.Hints.Send) and isfunction(DRP.Hints.CivicGuidance)
		and DRP.Objectives.MaxOffers == 3 and DRP.Objectives.MaxActive == 2
		and isfunction(DRP.Objectives.RefreshOffers) and isfunction(DRP.Objectives.Emit)
		and isfunction(DRP.Objectives.Complete) and isfunction(DRP.Objectives.PruneInvalid)
		and isfunction(DRP.Objectives.BuildRoleGoal) and isfunction(DRP.Objectives.SetRoleGoal)
		and isfunction(DRP.Objectives.CheckRoleGoal)
		and isfunction(DRP.Objectives.EnsureBeginnerGuide) and isfunction(DRP.Objectives.SaveGuideProgress)
		and DRP.ProtocolVersion >= 34
		and istable(DRP.Objectives.Templates.welcome_identity)
		and DRP.Objectives.Templates.welcome_identity.automatic == true
		and DRP.Objectives.Templates.beginner_property_purchase.event == "property_purchased"
		and DRP.Objectives.Templates.welcome_pockets.automatic == true
		and DRP.Objectives.Templates.beginner_mugging.event == "mugging_resolved"
		and DRP.Objectives.Templates.beginner_healing.event == "player_healed"
		and DRP.Objectives.Templates.beginner_review.event == "guide_reviewed"
		and #DRP.Objectives.GuideSequence == 6
		and istable(DRP.Objectives.Templates.police_booking)
		and istable(DRP.Objectives.Templates.medic_response)
		and istable(DRP.Objectives.Templates.criminal_mugging)
		and istable(DRP.Objectives.Templates.merchant_delivery)
		and istable(DRP.Objectives.Templates.property_funding)
		and istable(DRP.Objectives.Templates.mayor_confidence)
		and isfunction((hook.GetTable().DRPIncidentResolved or {})["DRP.Objectives.Incident"])
		and isfunction((hook.GetTable().DRPPlayerHealed or {})["DRP.Objectives.HealingGuide"])
		and isfunction((hook.GetTable().DRPPropertyOwnershipChanged or {})["DRP.Objectives.PropertyGuide"])
		and isfunction((hook.GetTable().DRPMarketplaceFulfilled or {})["DRP.Objectives.Market"]))
	local normalizedEvidence = DRP.Roles:Normalize({
		hitEvidence = 99,
		hitEvidenceVictims = { "76561198000000001", "76561198000000001", "invalid", "76561198000000002" }
	})
	local hitmanByEvidence = DRP.Roles:Resolve(-200, {
		hitEvidenceVictims = { "76561198000000001", "76561198000000002", "76561198000000003" }
	})
	check("hitman_evidence_authority", DRP.HitmanEvidence == DRP.Services.Get("hitman_evidence")
		and DRP.HitmanEvidence.RequiredProofs == 3
		and isfunction(DRP.HitmanEvidence.CaptureDeath)
		and isfunction(DRP.HitmanEvidence.VisibleCorpses)
		and isfunction(DRP.Roles.RecordHitEvidence)
		and normalizedEvidence.hitEvidence == 2
		and #normalizedEvidence.hitEvidenceVictims == 2
		and hitmanByEvidence == DRP.Job.HITMAN
		and isfunction((hook.GetTable().DRPMedicalBodyCreated or {})["DRP.HitmanEvidence.Corpse"])
		and isfunction((hook.GetTable().DRPPhonePhotoCaptured or {})["DRP.HitmanEvidence.Photo"])
		and isfunction((hook.GetTable().DRPIncidentResolved or {})["DRP.HitmanEvidence.Outcome"]))
	check("proximity_voice_authority", DRP.Voice == DRP.Services.Get("voice")
		and DRP.Voice:Distance() >= DRP.Voice.MinimumDistance
		and DRP.Voice:Distance() <= DRP.Voice.MaximumDistance
		and isfunction(DRP.Voice.CanHear)
		and isfunction((hook.GetTable().PlayerCanHearPlayersVoice or {})["DRP.Voice.Proximity"]))
	local registeredPhone = weapons.GetStored("ephone")
	check("phone_server_authority", DRP.Phone == DRP.Services.Get("phone")
		and istable(registeredPhone) and registeredPhone.Spawnable == true
		and DRP.JobService.IsUtilityWeapon("ephone")
		and DRP.DropPolicy.nonDroppableWeapons.ephone == true
		and DRP.PVP.IgnoredWeapons.ephone == true
		and DRP.Net.ReceiverAudit.iPhone ~= nil
		and isfunction(DRP.Phone.StartCall) and isfunction(DRP.Phone.Message)
		and isfunction(DRP.Phone.CanHearRemote)
		and isfunction((hook.GetTable().PlayerDeath or {})["DRP.Phone.Death"])
		and isfunction((hook.GetTable().PlayerDisconnected or {})["DRP.Phone.Disconnect"]))
	local mayorTablet = weapons.GetStored("weapon_drp_mayor_tablet")
	local ephone = weapons.GetStored("ephone")
	check("mayor_tablet_registration", istable(mayorTablet)
		and mayorTablet.PrintName == "Mayoral Records Tablet"
		and mayorTablet.Base == "ephone"
		and istable(ephone)
		and mayorTablet.ViewModel == "models/zerochain/props_weedfarm/zwf_tablet_vm.mdl"
		and mayorTablet.WorldModel == "models/zerochain/props_weedfarm/zwf_tablet.mdl"
		and mayorTablet.DRPTabletHardware == true
		and istable(mayorTablet.DRPTabletScreen)
		and mayorTablet.DRPTabletScreen.bone == "tablet_main"
		and mayorTablet.DRPPhoneDeviceContext == "mayor_tablet"
		and table.HasValue(DRP.Jobs[DRP.Job.MAYOR].weapons or {}, "weapon_drp_mayor_tablet")
		and DRP.JobService.IsUtilityWeapon("weapon_drp_mayor_tablet")
		and DRP.DropPolicy.nonDroppableWeapons.weapon_drp_mayor_tablet == true
		and DRP.PVP.IgnoredWeapons.weapon_drp_mayor_tablet == true
		and isfunction(DRP.Phone.HasPoliceTerminal))
	local arcadeDefinition = DRP.JobEntityService.ByKey.arcade_cabinet
	check("arcade_server_authority", DRP.Arcade == DRP.Services.Get("arcade")
		and istable(arcadeDefinition) and arcadeDefinition.ownerOnly == true
		and arcadeDefinition.class == "drp_arcade_cabinet"
		and scripted_ents.GetStored("drp_arcade_cabinet") ~= nil
		and isfunction(DRP.Arcade.StartSession) and isfunction(DRP.Arcade.EndSession)
		and isfunction(DRP.Arcade.RelayFrame) and isfunction(DRP.Arcade.ApplyMove)
		and DRP.Arcade.Config.stream.fps <= 3
		and DRP.Arcade.Config.stream.max_frame_bytes <= 49152
		and DRP.Arcade.Config.stream.max_viewers_per_machine <= 16
		and DRP.Arcade.Config.stream.max_active_streams <= 8
		and DRP.Arcade.Config.stream.max_relay_bytes_per_second <= 1048576
		and DRP.Net.ReceiverAudit[DRP.ArcadeMessages.START] ~= nil
		and DRP.Net.ReceiverAudit[DRP.ArcadeMessages.EXIT] ~= nil
		and DRP.Net.ReceiverAudit[DRP.ArcadeMessages.FRAME] ~= nil)
	local mp3Definition = DRP.JobEntityService.ByKey.mp3_player
	local mp3Stored = scripted_ents.GetStored("drp_mp3_player")
	check("mp3_player_authority", istable(mp3Definition)
		and mp3Definition.public == true and mp3Definition.mediaPlayer == true
		and istable(mp3Stored) and mp3Stored.t.MediaPlayerType == "spatial"
		and istable(mp3Stored.t.PlayerConfig) and mp3Stored.t.PlayerConfig.width > 0 and mp3Stored.t.PlayerConfig.height > 0
		and DRP.MP3Player.DefaultRadius < 1800
		and DRP.MP3Player.ListenerInterval >= 0.5
		and isfunction(DRP.MediaPlayerIntegration.IsMP3Owner)
		and isfunction(DRP.MediaPlayerIntegration.OpenMP3Controls)
		and isfunction(DRP.MediaPlayerIntegration.LoadLibrary)
		and isfunction(DRP.MediaPlayerIntegration.SaveLibrary)
		and DRP.Net.ReceiverAudit[DRP.MediaPlayerIntegration.MP3VolumeMessage] ~= nil
		and DRP.Net.ReceiverAudit[DRP.MediaPlayerIntegration.MP3QueueMessage] ~= nil
		and DRP.Net.ReceiverAudit[DRP.MediaPlayerIntegration.MP3LibraryRequestMessage] ~= nil
		and DRP.Net.ReceiverAudit[DRP.MediaPlayerIntegration.MP3LibraryActionMessage] ~= nil)
	check("property_lease_and_vault_authority", DRP.Properties == DRP.Services.Get("properties")
		and DRP.Properties.LeaseInterval == 86400 and DRP.Properties.MaxPrepaidDays == 3
		and DRP.Properties.VaultCapacity >= 32
		and isfunction(DRP.Properties.PayLease) and isfunction(DRP.Properties.SetMemberRent)
		and isfunction(DRP.Properties.VaultDeposit) and isfunction(DRP.Properties.VaultWithdraw)
		and isfunction(DRP.Properties.SetPrice) and isfunction(DRP.Properties.SetLeasePrice)
		and isfunction(DRP.Properties.SetBuyable) and isfunction(DRP.Properties.BuildManagementSnapshot)
		and isfunction(DRP.Properties.AddDoor)
		and isfunction(DRP.Commands.propertyaddsingledoor)
		and DRP.Commands.propertydooradd == DRP.Commands.propertyaddsingledoor
		and DRP.Commands.adddoortoproperty == DRP.Commands.propertyaddsingledoor)
	check("property_build_zone_authority", isfunction(DRP.Properties.AddBuildZone)
		and isfunction(DRP.Properties.RemoveBuildZoneAt)
		and isfunction(DRP.Properties.BuildPermissionAt)
		and isfunction(DRP.Properties.ValidateEntityPlacement)
		and isfunction(DRP.Properties.BoundsInsideBuildZoneUnion)
		and isfunction(DRP.Properties.OrientedBoundsInsideBuildZoneUnion)
		and isfunction(DRP.Properties.EntityBoundsInsideBuildZoneUnion)
		and isfunction(DRP.Properties.JobCanBuild)
		and DRP.Doors and isfunction(DRP.Doors.JobMask)
		and DRP.Properties.MaxBuildZones == 32
		and DRP.Properties.BuildZoneTolerance == 1)
	local unionCheck = DRP.Properties and DRP.Properties.BoundsInsideBuildZoneUnion
	local adjacentZones = {
		{ mins = { x = 0, y = 0, z = 0 }, maxs = { x = 10, y = 10, z = 10 } },
		{ mins = { x = 10, y = 0, z = 0 }, maxs = { x = 20, y = 10, z = 10 } }
	}
	local separatedZones = {
		{ mins = { x = 0, y = 0, z = 0 }, maxs = { x = 8, y = 10, z = 10 } },
		{ mins = { x = 12, y = 0, z = 0 }, maxs = { x = 20, y = 10, z = 10 } }
	}
	local narrowGapZones = {
		{ mins = { x = 0, y = 0, z = 0 }, maxs = { x = 9.5, y = 10, z = 10 } },
		{ mins = { x = 10.5, y = 0, z = 0 }, maxs = { x = 20, y = 10, z = 10 } }
	}
	check("property_adjacent_build_zone_union", isfunction(unionCheck)
		and unionCheck(Vector(1, 1, 1), Vector(19, 9, 9), adjacentZones, 1))
	check("property_build_zone_union_rejects_gaps", isfunction(unionCheck)
		and not unionCheck(Vector(1, 1, 1), Vector(19, 9, 9), separatedZones, 1))
	check("property_tolerance_does_not_join_zones", isfunction(unionCheck)
		and not unionCheck(Vector(1, 1, 1), Vector(19, 9, 9), narrowGapZones, 1))
	local toleranceZone = {
		{ mins = { x = 0, y = 0, z = 0 }, maxs = { x = 10, y = 10, z = 10 } }
	}
	check("property_build_zone_coordinate_tolerance",
		isfunction(unionCheck)
		and unionCheck(Vector(-1, -1, -1), Vector(11, 11, 11), toleranceZone, DRP.Properties.BuildZoneTolerance)
		and not unionCheck(Vector(-2, -2, -2), Vector(12, 12, 12), toleranceZone, DRP.Properties.BuildZoneTolerance))
	local orientedCheck = DRP.Properties and DRP.Properties.OrientedBoundsInsideBuildZoneUnion
	local centeredZone = {
		{ mins = { x = -10, y = -10, z = -10 }, maxs = { x = 10, y = 10, z = 10 } }
	}
	check("property_oriented_bounds_rotation",
		isfunction(orientedCheck)
		and orientedCheck(Vector(-6, -6, -2), Vector(6, 6, 2), vector_origin, Angle(0, 45, 0), centeredZone, 1)
		and not orientedCheck(Vector(-8, -8, -2), Vector(8, 8, 2), vector_origin, Angle(0, 45, 0), centeredZone, 1))
	local overlappingZones = {
		{ mins = { x = 0, y = 0, z = 0 }, maxs = { x = 11, y = 10, z = 10 } },
		{ mins = { x = 9, y = 0, z = 0 }, maxs = { x = 20, y = 10, z = 10 } }
	}
	check("property_overlapping_build_zone_union", isfunction(unionCheck)
		and unionCheck(Vector(1, 1, 1), Vector(19, 9, 9), overlappingZones, 1))
	local propService = DRP.Services.Get("props") or {}
	check("trust_scaled_entity_limits", isfunction(propService.TrustEntityLimit)
		and isfunction(propService.OwnedEntityCount) and isfunction(propService.CanCreateOwnedEntity)
		and propService.TrustEntityLimit(0) == 20
		and propService.TrustEntityLimit(50) == 20
		and propService.TrustEntityLimit(51) == 30
		and propService.TrustEntityLimit(60) == 30
		and propService.TrustEntityLimit(61) == 45
		and propService.TrustEntityLimit(75) == 45
		and propService.TrustEntityLimit(76) == 60
		and propService.TrustEntityLimit(89) == 60
		and propService.TrustEntityLimit(90) == 80
		and propService.TrustEntityLimit(100) == 80)
	check("property_active_physgun_enforcement", istable(propService.ActiveZonePhysgun)
		and next(propService.ActiveZonePhysgun) == nil
		and propService.ZonePhysgunInterval == 0.1
		and isfunction(propService.ValidateActiveZonePhysgun)
		and isfunction(propService.RestoreLastValidBuildTransform)
		and isfunction(propService.ArmZonePhysgunValidation)
		and isfunction(propService.DisarmZonePhysgunValidation)
		and not isfunction((hook.GetTable().Think or {})["DRP.Props.ActiveZonePhysgun"]))
	check("xp_sole_authority", DRP.Experience == DRP.Services.Get("experience") and isfunction(DRP.Experience.Add) and isfunction(DRP.Experience.SetTotalXP))
	check("civic_authority", DRP.Civic == DRP.Services.Get("civic") and isfunction(DRP.Civic.ApplyIncidentOutcome) and DRP.Civic.Minimum == -1000 and DRP.Civic.Maximum == 1000)
	check("role_identity_civic_ladder", DRP.Roles:Resolve(-149, {}) == DRP.Job.CITIZEN
		and DRP.Roles:Resolve(-150, {}) == DRP.Job.THIEF
		and DRP.Roles:Resolve(-325, {}) == DRP.Job.HITMAN
		and DRP.Roles:Resolve(-525, {}) == DRP.Job.GANGSTER
		and DRP.Roles:Resolve(-999, {}) ~= DRP.Job.MOB_BOSS
		and DRP.Roles:Resolve(-1000, {}) == DRP.Job.MOB_BOSS)
	check("role_identity_behavior_specialists", DRP.Roles:Resolve(-100, { narcotics = 12 }) == DRP.Job.DRUG_DEALER
		and DRP.Roles:Resolve(-100, { forceDrugging = 3 }) == DRP.Job.KIDNAPPER
		and DRP.Roles:Resolve(100, { healing = 8 }) == DRP.Job.MEDIC
		and DRP.Roles:Resolve(0, { weaponTrades = 8 }) == DRP.Job.GUN_DEALER)
	check("role_identity_selection_restricted", DRP.Jobs[DRP.Job.POLICE].manualSelectable == true
		and DRP.Jobs[DRP.Job.MAYOR].electionOnly == true
		and DRP.Jobs[DRP.Job.THIEF].manualSelectable ~= true
		and DRP.Jobs[DRP.Job.MOB_BOSS].limit == 1
		and isfunction(DRP.Roles.Serialize) and isfunction(DRP.Roles.Record)
		and isfunction(DRP.Roles.CanBecomeMobBoss) and isfunction(DRP.Roles.FillMobBossVacancy))
	check("mugging_available_to_all_non_government_roles", DRP.JobAllowsMugging(DRP.Jobs[DRP.Job.CITIZEN]) == true
		and DRP.JobAllowsMugging(DRP.Jobs[DRP.Job.THIEF]) == true
		and DRP.JobAllowsMugging(DRP.Jobs[DRP.Job.DRUG_DEALER]) == true
		and DRP.JobAllowsMugging(DRP.Jobs[DRP.Job.POLICE]) == false
		and DRP.JobAllowsMugging(DRP.Jobs[DRP.Job.MAYOR]) == false
		and DRP.Jobs[DRP.Job.CITIZEN].canMug == true
		and DRP.Jobs[DRP.Job.POLICE].canMug == false)
	local allJobsProfiled = table.Count(DRP.JobPermissionProfiles or {}) == #DRP.Jobs
	for id in ipairs(DRP.Jobs) do
		local profile = DRP.JobPermissionProfiles[id]
		allJobsProfiled = allJobsProfiled and istable(profile)
			and isstring(profile.requirement) and profile.requirement ~= ""
			and isstring(profile.permissions) and profile.permissions ~= ""
	end
	check("civic_permission_hierarchy_accounts_for_every_job", allJobsProfiled
		and DRP.CivicCapabilityThresholds.canRaid == -150
		and DRP.CivicCapabilityThresholds.canExecuteHits == -325
		and DRP.CivicCapabilityThresholds.canKidnap == -425
		and DRP.CivicCapabilityThresholds.canUseCriminalAgenda == -525
		and DRP.CivicCapabilityThresholds.canSpawnDrugs == -650)
	local pistolCrate = DRP.JobEntityService.ByKey.pistol_crate
	local rifleCrate = DRP.JobEntityService.ByKey.rifle_crate
	local heroin = DRP.JobEntityService.ByKey.drug_heroin
	check("civic_item_permission_authority", DRP.CivicPermissions == DRP.Services.Get("civic_permissions")
		and isfunction(DRP.CivicPermissions.CanSpawn)
		and DRP.CivicPermissions:IsWeaponCrate(pistolCrate)
		and DRP.CivicPermissions:DefaultThreshold(pistolCrate) == nil
		and DRP.CivicPermissions:DefaultThreshold(heroin) == -650
		and DRP.CivicPermissions:RoleCanSpawnCrate("gun_dealer", rifleCrate) == true
		and DRP.CivicPermissions:RoleCanSpawnCrate("gangster", pistolCrate) == false
		and DRP.CivicPermissions:RoleCanSpawnCrate("hitman", pistolCrate) == false
		and isfunction(DRP.CivicPermissions.BuildDynamicCrate)
		and isfunction(DRP.CivicPermissions.SetWeaponCrate)
		and isfunction(DRP.CivicPermissions.DynamicCrateForWeapon)
		and DRP.CivicPermissions.DefaultMobBossCrates.pistol_crate == true
		and DRP.CivicPermissions.DefaultMobBossCrates.smg_crate == true
		and DRP.CivicPermissions.DefaultMobBossCrates[rifleCrate.key] ~= true)
	local dynamicCrateKey = DRP.CivicPermissions:DynamicCrateKey("arc9_go_glock")
	check("dynamic_weapon_crate_registry", isstring(dynamicCrateKey) and #dynamicCrateKey <= 32
		and isfunction(DRP.CivicPermissions.RegisterDynamicCrate)
		and isfunction(DRP.CivicPermissions.UnregisterDynamicCrate)
		and istable(DRP.CivicPermissions.DynamicCrates)
		and istable(DRP.CivicPermissions.DynamicCrateWeapons))
	local compactWeaponCases = DRP.WeaponCaseWorkshopID == "542866829"
		and DRP.WeaponCaseModel == "models/ptejack/props/crates/weapons_crate.mdl"
		and isstring(DRP.WeaponCaseFallbackModel) and DRP.WeaponCaseFallbackModel ~= ""
	for _, definition in ipairs(DRP.JobEntities or {}) do
		if definition.class == "drp_weapon_crate" then
			compactWeaponCases = compactWeaponCases and definition.model == DRP.WeaponCaseModel
				and definition.name:find("Case", 1, true) ~= nil
		end
	end
	check("compact_weapon_case_definitions", compactWeaponCases)
	check("civic_admin_commands", DRP.AdminPermissionBits.civic > 65535 and isfunction(DRP.Commands.setcivic) and isfunction(DRP.Commands.addcivic) and isfunction(DRP.Commands.deductcivic))
	check("admin_extended_actions", DRP.AdminModeAction.TOGGLE_TARGET_MODE == 14 and DRP.AdminModeAction.RELEASE_ARREST == 15)
	local expectedSteamID64 = "76561198178574331"
	check("offline_blacklist_steamid_formats", isfunction(DRP.Admin.NormalizeSteamID)
		and DRP.Admin.NormalizeSteamID(expectedSteamID64) == expectedSteamID64
		and DRP.Admin.NormalizeSteamID("STEAM_0:1:109154301") == expectedSteamID64
		and DRP.Admin.NormalizeSteamID("[U:1:218308603]") == expectedSteamID64
		and DRP.Admin.NormalizeSteamID("https://steamcommunity.com/profiles/" .. expectedSteamID64 .. "/") == expectedSteamID64
		and DRP.Admin.NormalizeSteamID("not-a-steamid") == nil)
	check("roster_snapshot_authority", DRP.Roster == DRP.Services.Get("roster") and DRP.Roster.ALL == 255
		and DRP.Roster.Field.TRUST == 128 and isfunction(DRP.Roster.SendSnapshot) and isfunction(DRP.Roster.Update))
	local newTrust, newKnown = DRP.Trust.ScoreSignals({ returning = false, serverHours = 0, discordLinked = false })
	local establishedTrust, establishedKnown = DRP.Trust.ScoreSignals({
		returning = true, serverHours = 100, gmodHours = 1000, onlyGMod = false,
		vacBans = 0, daysSinceBan = 99999, vpn = false, discordLinked = true
	})
	local highRiskTrust, highRiskKnown = DRP.Trust.ScoreSignals({
		returning = false, serverHours = 0, gmodHours = 1, onlyGMod = true,
		vacBans = 2, daysSinceBan = 30, vpn = true, discordLinked = false
	})
	local trustedRankTrust, trustedRankKnown = DRP.Trust.ScoreSignals({
		returning = false, serverHours = 0, discordLinked = false, trustedRank = true
	})
	check("trust_score_deterministic", newTrust == 47 and newKnown == 4
		and establishedTrust == 100 and establishedKnown == 8
		and highRiskTrust == 0 and highRiskKnown == 8
		and trustedRankTrust == 57 and trustedRankKnown == 4,
		string.format("new=%d/%d established=%d/%d risk=%d/%d", newTrust, newKnown, establishedTrust, establishedKnown, highRiskTrust, highRiskKnown))
	check("trust_event_driven_authority", DRP.Trust == DRP.Services.Get("trust")
		and isfunction((hook.GetTable().DRPPlayerReady or {})["DRP.Trust.Evaluate"])
		and timer.Exists("DRP.Trust.Periodic") == false
		and isfunction(DRP.Trust.SendSelf)
		and isfunction(DRP.Trust.JoinDiscord) and isfunction(DRP.Trust.BeginOrCheckDiscordVerification)
		and isfunction(DRP.Trust.BeginDiscordLink) and isfunction(DRP.Trust.VerifyDiscordLink)
		and isfunction(DRP.Trust.StartDiscordRoleDeadline) and isfunction(DRP.Trust.ClearDiscordRoleDeadline)
		and isfunction(DRP.Trust.CheckExistingDiscordRole) and isfunction(DRP.Trust.CheckDiscordRole)
		and isfunction(DRP.Trust.IsDiscordKickExempt)
		and DRP.Net.ReceiverAudit["drp_trust_self_action_v1"] ~= nil)
	local cellX, cellY = DRP.PVP.CellCoordinates(Vector(767, 768, 0))
	check("pvp_spatial_visibility_index", DRP.PVP.CellSize == 768 and cellX == 0 and cellY == 1 and DRP.PVP.PairBudget == nil and isfunction(DRP.PVP.RebuildSpatialIndex) and isfunction(DRP.PVP.ScanActive))
	check("pvp_officer_batch_scanner", DRP.PVP.DiscoveryTraceLimit == 1 and DRP.PVP.SightingBatchWindow >= 0.25
		and istable(DRP.PVP.DiscoveryQueues) and isfunction(DRP.PVP.QueueConfirmedSighting)
		and isfunction(DRP.PVP.FlushSightingBatches) and isfunction(DRP.Incidents.SyncBatch))
	check("forced_drugging_requires_police_witness", isfunction(DRP.PVP.QueueWitnessedOffence)
		and isfunction(DRP.PVP.ScanWitnessEvents)
		and DRP.PVP.WitnessEventLifetime <= 1
		and DRP.PVP.WitnessQueueCapacity <= 512
		and DRP.PVP.WitnessSkipBudget <= 32
		and isfunction(DRP.Drugs.ApplyPoliceWitness)
		and isfunction((hook.GetTable().DRPPoliceWitnessedOffence or {})["DRP.Drugs.PoliceWitness"]))
	check("incident_lifetime_until_reset", DRP.Incidents.PersistentUntilReset == true
		and isfunction(DRP.Incidents.HoldOpen)
		and isfunction(DRP.PVP.RevalidateSightingDeadline)
		and isfunction((DRP.Incidents.Definitions.police_weapon_sighting or {}).onDeadline)
		and isfunction((hook.GetTable().PlayerDeath or {})["DRP.Incidents.ParticipantDeath"]))
	check("pvp_engine_damage_authority", isfunction((hook.GetTable().PlayerShouldTakeDamage or {})["DRP.PVP.DefaultSafe"])
		and isfunction((hook.GetTable().EntityTakeDamage or {})["DRP.PVP.IndirectDamage"])
		and isfunction(DRP.PVP.HasStandingDirectionalPermission)
		and isfunction(DRP.PVP.CustodySecured)
		and isfunction(DRP.PVP.TaserAttempt) and isfunction(DRP.PVP.NonLethalAttempt)
		and DRP.Incidents.Definitions.police_weapon_sighting.transitions.nonlethal_required.suspect_retaliation_authorized == true
		and DRP.Incidents.Definitions.police_weapon_sighting.transitions.suspect_retaliation_authorized.lethal_force_authorized == true
		and isfunction((hook.GetTable().DRPAdminModeChanged or {})["DRP.PVP.AdminModeIndex"])
		and DRP.PVP.JobHasUniversalOffense(DRP.Jobs[DRP.Job.MOB_BOSS]) == true
		and DRP.PVP.JobHasUniversalOffense(DRP.Jobs[DRP.Job.GANGSTER]) == false
		and DRP.PVP.JobHasUniversalOffense(DRP.Jobs[DRP.Job.POLICE]) == false)
	check("mob_boss_team_assault", istable(DRP.Incidents.Definitions.mob_boss_assault)
		and DRP.Incidents.Definitions.mob_boss_assault.initial == "active"
		and isfunction(DRP.Incidents.Definitions.mob_boss_assault.onParticipantUnavailable)
		and isfunction(DRP.PVP.BeginMobBossAssault)
		and isfunction(DRP.PVP.RefreshMobBossAssaultMembership)
		and isfunction((hook.GetTable().EntityTakeDamage or {})["DRP.PVP.IndirectDamage"]))
	check("legal_custody_tether", DRP.Legal.EscortDistance <= 48
		and DRP.Legal.EscortSnapDistance <= 150
		and DRP.Legal.CuffWindow >= 12 and istable(DRP.Legal.TasedCustody)
		and isfunction(DRP.Legal.ApplyCommand) and isfunction(DRP.Legal.ApplyMove))
	check("prop_catalog_global_queue", istable(DRP.Props.CatalogTransferQueue) and DRP.Props.CatalogChunksPerPump <= 2 and isfunction(DRP.Props.PrepareCatalogPayload) and isfunction(DRP.Props.PumpCatalogTransfers))
	check("incident_delta_indexes", istable(DRP.Incidents.ByPairType) and istable(DRP.Incidents.ByReasonKey) and DRP.Incidents.EvidenceCapacity <= 16 and isfunction(DRP.Incidents.QueueDelta))
	check("incident_nearby_team_sharing", DRP.Incidents.TeamShareRadius == 900
		and DRP.Incidents.TeamShareCapPerSide == 8
		and DRP.Incidents.TeamShareTypes.police_weapon_sighting == true
		and DRP.Incidents.TeamShareTypes.mugging == true
		and DRP.Incidents.TeamSharedActions.damage == true
		and DRP.Incidents.TeamSharedActions.tase == true
		and isfunction(DRP.Incidents.RefreshNearbyTeams))
	check("incident_permission_authority", isfunction(DRP.Incidents.CanInIncident) and isfunction(DRP.Incidents.Can) and isfunction(DRP.Incidents.Deny))
	local hooks = hook.GetTable()
	check("movement_single_dispatcher", isfunction((hooks.StartCommand or {})["DRP.Movement.DispatchCommand"])
		and isfunction((hooks.SetupMove or {})["DRP.Movement.DispatchMove"])
		and (hooks.StartCommand or {})["DRP.Legal.CustodyMovement"] == nil
		and (hooks.SetupMove or {})["DRP.Drugs.Movement"] == nil)
	check("storage_join_concurrency", DRP.Storage.MaxConcurrentPlayerLoads == 4 and DRP.Storage.MaxConcurrentPocketLoads == 2
		and istable(DRP.Storage.PlayerLoadQueue) and istable(DRP.Storage.PocketLoadQueue))
	check("singleplayer_local_storage_backend", DRP.Storage.LocalPath == "darkrp/singleplayer/database.json"
		and isfunction(DRP.Storage.IsLocal) and isfunction(DRP.Storage.LoadLocalGovernment)
		and isfunction(DRP.Storage.SaveLocalGovernment) and isfunction(DRP.Storage.LocalPlayerKey)
		and isfunction(DRP.Storage.ShouldUseLocal))
	check("virtual_loadtest_isolated", DRP.LoadTest == DRP.Services.Get("loadtest")
		and isfunction(DRP.LoadTest.Spawn) and isfunction(DRP.LoadTest.QueueIncidents)
		and isfunction(DRP.LoadTest.RunTicks) and isfunction(DRP.LoadTest.Report)
		and DRP.LoadTest.MaxActors >= 64 and DRP.LoadTest.TicksPerFrame <= 4)
	local citizenLoadout = DRP.JobService.GetCachedLoadout(DRP.Job.CITIZEN)
	check("job_loadouts_cached_and_staged", DRP.JobService.CacheReady == true
		and istable(citizenLoadout) and citizenLoadout.model == DRP.Jobs[DRP.Job.CITIZEN].model
		and istable(citizenLoadout.weapons) and isfunction(DRP.JobService.QueueAppearanceUpdate)
		and isfunction(DRP.JobService.BuildLoadoutCache) and isfunction(DRP.JobService.SelectBotTestWeapon)
		and isfunction((hook.GetTable().PlayerSpawn or {})["DRP.Jobs.BotTestLoadout"]))
	local registeredToolgun = weapons.GetStored("gmod_tool")
	check("building_utility_weapon_registration", istable(registeredToolgun)
		and istable(registeredToolgun.Tool) and table.Count(registeredToolgun.Tool) > 0
		and istable(registeredToolgun.Tool.drp_property_zone)
		and DRP.JobService.IsUtilityWeapon("gmod_tool")
		and DRP.JobService.IsUtilityWeapon("weapon_physgun")
		and isfunction(DRP.JobService.GiveUtilityWeapon)
		and isfunction(GAMEMODE.CanTool)
		and GAMEMODE.IsSandboxDerived == true
		and istable(GAMEMODE.BaseClass) and isfunction(GAMEMODE.BaseClass.CanTool)
		and istable(registeredToolgun.Tool.precision)
		and isfunction(registeredToolgun.Tool.precision.LeftClick)
		and istable(registeredToolgun.Tool.stacker_improved)
		and isfunction(registeredToolgun.Tool.stacker_improved.LeftClick)
		and DRP.ToolPropSpawnModes.creator == true
		and DRP.ToolPropSpawnModes.stacker_improved == true)
	check("arc9_population_caps", DRP.ARC9Integration.MaxExplosives <= 24 and DRP.ARC9Integration.MaxAreaEffects <= 8
		and GetConVar("arc9_bullet_physics") and not GetConVar("arc9_bullet_physics"):GetBool())
	local workshopDelivery = DRP.WorkshopDelivery or {}
	check("workshop_client_manifest", workshopDelivery.CollectionID == "3768835284"
		and table.Count(workshopDelivery.Items or {}) >= 9
		and (workshopDelivery.Items or {})[workshopDelivery.CollectionID] == nil
		and table.Count(workshopDelivery.Unavailable or {}) == 2,
		string.format("items=%d unavailable=%d", table.Count(workshopDelivery.Items or {}), table.Count(workshopDelivery.Unavailable or {})))
	check("cocaine_service_authority", DRP.Cocaine == DRP.Services.Get("cocaine")
		and isfunction(DRP.Cocaine.HarvestWild) and isfunction(DRP.Cocaine.UseHotplate) and isfunction(DRP.Cocaine.TableAction))
	check("cocaine_inventory_stacks", isfunction(DRP.Inventory.AddResource) and isfunction(DRP.Inventory.TakeResource)
		and isfunction(DRP.Inventory.AddDrug) and isfunction(DRP.Inventory.TakeDrug))
	check("portable_valuable_policy", isfunction(DRP.Inventory.IsPortableValuableRecord)
		and isfunction(DRP.Inventory.RegisterPortableValuable)
		and DRP.Inventory.IsPortableValuableRecord({ kind = "resource", class = "drp_cocaine_item" })
		and DRP.Inventory.IsPortableValuableRecord({ kind = "dupe", class = "zmlab2_item_meth" })
		and not DRP.Inventory.IsPortableValuableRecord({ kind = "entity", class = "prop_physics" })
		and isfunction(DRP.Props.IsPortableValuable))
	check("cocaine_entities_registered", scripted_ents.GetStored("drp_coca_wild") ~= nil
		and scripted_ents.GetStored("drp_coca_pot") ~= nil and scripted_ents.GetStored("drp_cocaine_hotplate") ~= nil
		and scripted_ents.GetStored("drp_narcotics_table") ~= nil and scripted_ents.GetStored("drp_cocaine_buyer") ~= nil)
	local medicLoadout = DRP.JobService.GetCachedLoadout(DRP.Job.MEDIC)
	local registeredMedkit = weapons.GetStored("weapon_drp_medkit")
	local registeredDefibrillator = weapons.GetStored("weapon_drp_defibrillator")
	local medicHasDefibrillator = false
	for _, class in ipairs(medicLoadout and medicLoadout.weapons or {}) do
		if class == "weapon_drp_defibrillator" then medicHasDefibrillator = true break end
	end
	check("medical_emergency_authority", DRP.Medical == DRP.Services.Get("medical")
		and isfunction(DRP.Medical.CreateCorpse) and isfunction(DRP.Medical.RequestMedic)
		and isfunction(DRP.Medical.HealAimed) and isfunction(DRP.Medical.TraceLivingPlayer)
		and isfunction(DRP.Medical.InstallHLMedkitTracking)
		and isfunction(DRP.Medical.BeginDefibrillation) and isfunction(DRP.Medical.Revive)
		and isfunction((hook.GetTable().PlayerDeath or {})["DRP.Medical.Death"])
		and isfunction((hook.GetTable().PlayerSpawn or {})["DRP.Medical.Spawn"])
		and isfunction((hook.GetTable().PlayerUse or {})["DRP.Medical.CorpseUse"])
		and registeredMedkit ~= nil and registeredMedkit.Spawnable == true
		and isfunction(registeredMedkit.PrimaryAttack)
		and registeredDefibrillator ~= nil and registeredDefibrillator.Spawnable == true
		and isfunction(registeredDefibrillator.PrimaryAttack)
		and DRP.JobService.IsUtilityWeapon("weapon_drp_medkit")
		and DRP.JobService.IsUtilityWeapon("weapon_drp_defibrillator")
		and DRP.JobService.IsUtilityWeapon("weapon_medkit")
		and istable(weapons.GetStored("weapon_medkit"))
		and weapons.GetStored("weapon_medkit").DRPHLHealingTrackingInstalled == true
		and medicHasDefibrillator)
	check("medical_scanners_idle_without_patients", timer.Exists("DRP.Medical.Distances") == false
		and timer.Exists("DRP.Medical.Defibrillation") == false)

	local kidnappingDefinition = DRP.Incidents.Definitions.kidnapping
	local persistedKidnapState = DRP.Roles:Normalize({
		kidnapCooldownUntil = 2000000000,
		kidnapImmunityUntil = 2000000100
	})
	local kidnapperLoadout = DRP.JobService.GetCachedLoadout(DRP.Job.KIDNAPPER)
	local kidnapWeapons = {}
	for _, class in ipairs(kidnapperLoadout and kidnapperLoadout.weapons or {}) do kidnapWeapons[class] = true end
	check("kidnapping_incident_authority", DRP.Kidnapping == DRP.Services.Get("kidnapping")
		and istable(kidnappingDefinition)
		and kidnappingDefinition.initial == "captive"
		and kidnappingDefinition.transitions.captive.overdue == true
		and kidnappingDefinition.outcomes.victim_rescued.winner == "victim"
		and kidnappingDefinition.outcomes.victim_killed.winner == "instigator"
		and isfunction(kidnappingDefinition.onDeadline)
		and DRP.Incidents.TeamShareTypes.kidnapping ~= true)
	check("kidnapping_weapons_and_policy", istable(weapons.GetStored("weapon_drp_kidnap_baton"))
		and istable(weapons.GetStored("weapon_drp_blindfold"))
		and istable(weapons.GetStored("weapon_drp_gag"))
		and kidnapWeapons.weapon_drp_kidnap_baton == true
		and kidnapWeapons.weapon_drp_blindfold == true
		and kidnapWeapons.weapon_drp_gag == true
		and DRP.JobService.IsUtilityWeapon("weapon_drp_kidnap_baton")
		and DRP.DropPolicy.nonDroppableWeapons.weapon_drp_kidnap_baton == true
		and DRP.DropPolicy.nonDroppableWeapons.weapon_drp_blindfold == true
		and DRP.DropPolicy.nonDroppableWeapons.weapon_drp_gag == true)
	check("kidnapping_timing_and_persistence", DRP.Kidnapping.Duration == 600
		and DRP.Kidnapping.Cooldown == 900
		and DRP.Kidnapping.VictimImmunity == 600
		and DRP.Kidnapping.KnockoutDuration == 5
		and DRP.Kidnapping.OverdueDamage == 2
		and DRP.Kidnapping.OverdueInterval == 5
		and persistedKidnapState.kidnapCooldownUntil == 2000000000
		and persistedKidnapState.kidnapImmunityUntil == 2000000100)
	check("kidnapping_idle_work_absent", timer.Exists("DRP.Kidnapping.Overdue") == false
		and timer.Exists("DRP.Kidnapping.Interactions") == false)

	local craftingCovered, craftingMissing = DRP.Crafting:ValidateCoverage()
	check("crafting_service_authority", DRP.Crafting == DRP.Services.Get("crafting")
		and DRP.CraftingShared.XPForNext(1) == 100 and DRP.CraftingShared.XPForNext(50) == 1815
		and math.abs(DRP.CraftingShared.TimeMultiplier(50) - 0.8) < 0.0001)
	check("crafting_arc9_catalog_coverage", craftingCovered, table.concat(craftingMissing or {}, ", "))
	check("crafting_starter_schematic", istable(DRP.Crafting:Recipe("weapon:arc9_go_glock"))
		and DRP.Crafting:Recipe("weapon:arc9_go_glock").grade == 2)
	local craftingResource=DRP.CraftingShared.ItemRecord("ferrous_scrap",1)
	check("crafting_material_and_research_policy", craftingResource and craftingResource.class=="drp_crafting_item"
		and DRP.Crafting:Recipe("research:folio_g1").ingredients.technical_notes_g1==10
		and DRP.Crafting:Recipe("research:folio_g5").output.grade==5
		and DRP.Crafting:Recipe("equipment:optic_alignment").output.resource=="optic_alignment_jig")
	check("crafting_inventory_kinds", DRP.Inventory.Footprint({kind="attachment"}) == 1
		and DRP.Inventory.Footprint({kind="schematic"}) == 1
		and isfunction(DRP.Inventory.ReserveResources) and isfunction(DRP.Inventory.RestoreRecords))
	local craftingDefinition = DRP.JobEntityService.ByKey.crafting_table
	check("crafting_table_registration", istable(craftingDefinition)
		and craftingDefinition.class == "drp_crafting_table" and craftingDefinition.price == 1500
		and craftingDefinition.limitedKind=="production" and craftingDefinition.crafting==true
		and scripted_ents.GetStored("drp_crafting_table") ~= nil and scripted_ents.GetStored("drp_crafting_item") ~= nil
		and DRP.Properties.DefaultRoles.coowner.crafting==true and DRP.Properties.DefaultRoles.tenant.crafting==false)
	check("crafting_persistence_authority",isfunction(DRP.Storage.LoadCrafting) and isfunction(DRP.Storage.SaveCrafting)
		and isfunction(DRP.Crafting.SaveProfileID) and isfunction(DRP.Crafting.ReleaseProperty))
	check("crafting_deadline_idle", timer.Exists("DRP.Crafting.Think") == false)
	check("crafting_catalog_global_budget", isstring(DRP.Crafting.CatalogCompressed)
		and #DRP.Crafting.CatalogCompressed > 0 and DRP.Crafting.CatalogChunkSize <= 48000
		and DRP.Crafting.CatalogChunksPerTick == 2 and isfunction(DRP.Crafting.QueueCatalog)
		and isfunction(DRP.Crafting.PumpCatalogTransfers)
		and isfunction(DRP.Crafting.ArmCatalogPump) and isfunction(DRP.Crafting.DisarmCatalogPump))
	local craftingTransferActive = DRP.Crafting.CatalogTransfers[DRP.Crafting.CatalogTransferHead] ~= nil
	local contractDeliveryActive = false
	for _, delivery in pairs(DRP.Contracts.Deliveries) do if delivery.status == "in_progress" then contractDeliveryActive = true break end end
	local propCleanupActive = DRP.Props.CleanupHead <= DRP.Props.CleanupTail
	local arcadeSessionActive = not table.IsEmpty(DRP.Arcade.Sessions)
	check("idle_services_do_not_poll", (craftingTransferActive or timer.Exists("DRP.Crafting.CatalogBudget") == false)
		and (contractDeliveryActive or timer.Exists("DRP.Contracts.Deliveries") == false)
		and (propCleanupActive or timer.Exists("DRP.Props.EntityCleanup") == false)
		and (arcadeSessionActive or timer.Exists("DRP.Arcade.Maintain") == false))
	check("profile_outbox_authority", isfunction(DRP.Economy.WriteOutbox)
		and isfunction(DRP.Economy.RecoverPlayerRow) and isstring(DRP.Economy.OutboxDirectory))
	check("disconnect_save_single_owner", not isfunction((hook.GetTable().PlayerDisconnected or {})["DRP.Inventory.Clear"])
		and not isfunction((hook.GetTable().PlayerDisconnected or {})["DRP.Contracts.Disconnect"])
		and isfunction(GAMEMODE.PlayerDisconnected))
	local testToggle=GetConVar("drp_enable_test_commands")
	check("production_test_commands_locked", testToggle~=nil and isfunction(DRP.Tests.CanRunProductionTest))
	check("service_dependencies_declared", table.HasValue(DRP.Inventory.Dependencies or {},"storage")
		and table.HasValue(DRP.Crafting.Dependencies or {},"inventory")
		and table.HasValue(DRP.EconomyDirector.Dependencies or {},"economy"))
	check("economy_commodity_namespace", DRP.Commodities.Key({kind="resource",resource="ferrous_scrap"})=="resource:ferrous_scrap"
		and istable(DRP.Commodities.Definition("resource:ferrous_scrap")))
	check("economy_projection_hotpath", isfunction(DRP.EconomyDirector.MoneySummary)
		and isfunction(DRP.EconomyDirector.QueueJournal)
		and isfunction(DRP.EconomyDirector.FlushJournal)
		and DRP.EconomyDirector.JournalBatchSize >= 16
		and DRP.EconomyDirector.MoneyQuoteCacheSeconds <= 5)

	local passed = 0
	for _, result in ipairs(results) do
		if result.passed then passed = passed + 1 end
		print(string.format("[DRP TEST] %s %s%s", result.passed and "PASS" or "FAIL", result.name, result.detail ~= "" and (" — " .. result.detail) or ""))
	end
	Tests.Last = { passed = passed, total = #results, results = results, time = os.time() }
	print(string.format("[DRP TEST] completed %d/%d passing", passed, #results))
	return passed == #results, Tests.Last
end

function Tests:Start()
	timer.Simple(0, function() if DRP.Tests then DRP.Tests.Run() end end)
end

function Tests:Stop() end

concommand.Add("drp_test_scenarios", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local ok, report = Tests.Run()
	if IsValid(ply) then DRP.Net.Notify(ply, string.format("Scenario tests: %d/%d passing.", report.passed, report.total), ok and 1 or 3) end
end)
