local SYNC = "drp_mercenary_sync_v1"
util.AddNetworkString(SYNC)

local Mercenaries = {
	ActiveByPlayer = setmetatable({}, { __mode = "k" }),
	ByID = {},
	NPCToMission = setmetatable({}, { __mode = "k" }),
	PropertyReservations = {},
	NextID = 1,
	MaxActive = 4,
	MissionDuration = 15 * 60,
	RewardReservation = 5 * 60,
	DirectorInterval = 0.5,
	EngagementRange = 2600
}

DRP.Mercenaries = Mercenaries
DRP.Services.Register("mercenaries", Mercenaries)
DRP.Services.DependsOn("mercenaries", { "properties", "objectives", "crafting", "inventory", "economy" })

local tiers = {
	[1] = {
		name = "Minor cell", count = 3, event = "mercenary_easy_kill", drops = 1,
		npcs = {
			{ class = "npc_metropolice", weapon = "weapon_pistol", health = 60 },
			{ class = "npc_metropolice", weapon = "weapon_pistol", health = 60 },
			{ class = "npc_metropolice", weapon = "weapon_pistol", health = 60 }
		}
	},
	[2] = {
		name = "Fortified cell", count = 5, event = "mercenary_medium_kill", drops = 2,
		npcs = {
			{ class = "npc_metropolice", weapon = "weapon_pistol", health = 75 },
			{ class = "npc_metropolice", weapon = "weapon_pistol", health = 75 },
			{ class = "npc_combine_s", weapon = "weapon_smg1", health = 85 },
			{ class = "npc_combine_s", weapon = "weapon_smg1", health = 85 },
			{ class = "npc_combine_s", weapon = "weapon_smg1", health = 90 }
		}
	},
	[3] = {
		name = "Elite unit", count = 8, event = "mercenary_hard_kill", drops = 3,
		npcs = {
			{ class = "npc_combine_s", weapon = "weapon_smg1", health = 125 },
			{ class = "npc_combine_s", weapon = "weapon_smg1", health = 125 },
			{ class = "npc_combine_s", weapon = "weapon_ar2", health = 140 },
			{ class = "npc_combine_s", weapon = "weapon_ar2", health = 140 },
			{ class = "npc_combine_s", weapon = "weapon_shotgun", health = 150 },
			{ class = "npc_combine_s", weapon = "weapon_shotgun", health = 150 },
			{ class = "npc_combine_s", weapon = "weapon_smg1", health = 160 },
			{ class = "npc_combine_s", weapon = "weapon_ar2", health = 175 }
		}
	}
}

local function ready(ply)
	return IsValid(ply) and ply:IsPlayer() and not ply:IsBot() and ply:Alive()
		and ply.DRPReady and ply:DRPReady()
end

local function adminMode(ply)
	return DRP.AdminMode and DRP.AdminMode.IsActive and DRP.AdminMode.IsActive(ply)
end

local function aiBlockReason()
	local disabled = GetConVar("ai_disabled")
	if disabled and disabled:GetBool() then return "Source NPC AI is disabled (ai_disabled 1)." end
	local ignored = GetConVar("ai_ignoreplayers")
	if ignored and ignored:GetBool() then return "Source NPCs are configured to ignore players (ai_ignoreplayers 1)." end
	return nil
end

local function inIncident(ply)
	return DRP.Incidents and next(DRP.Incidents.ByPlayer[ply] or {}) ~= nil
end

local function zoneBounds(zone)
	if istable(zone.corners) and #zone.corners == 4 then
		local mins, maxs, bottom = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge), 0
		for index = 1, 4 do
			local point = zone.corners[index]
			mins.x, mins.y = math.min(mins.x, tonumber(point.x) or 0), math.min(mins.y, tonumber(point.y) or 0)
			maxs.x, maxs.y = math.max(maxs.x, tonumber(point.x) or 0), math.max(maxs.y, tonumber(point.y) or 0)
			bottom = bottom + (tonumber(point.z) or 0)
		end
		bottom = bottom / 4
		local top = tonumber(zone.top_z or zone.height_z) or bottom
		mins.z, maxs.z = math.min(bottom, top), math.max(bottom, top)
		return mins, maxs
	end
	local rawMins, rawMaxs = zone.mins or zone.min or {}, zone.maxs or zone.max or {}
	return Vector(tonumber(rawMins.x) or 0, tonumber(rawMins.y) or 0, tonumber(rawMins.z) or 0),
		Vector(tonumber(rawMaxs.x) or 0, tonumber(rawMaxs.y) or 0, tonumber(rawMaxs.z) or 0)
end

local function pointInProperty(definition, position)
	for _, zone in ipairs(definition.build_zones or {}) do
		if DRP.Properties.Geometry.PointInsideZone(position, zone, 0) then return true end
	end
	return false
end

local function npcHullInProperty(definition, position)
	for _, x in ipairs({ -16, 16 }) do
		for _, y in ipairs({ -16, 16 }) do
			if not pointInProperty(definition, position + Vector(x, y, 2))
				or not pointInProperty(definition, position + Vector(x, y, 70)) then return false end
		end
	end
	return true
end

local function propertyHasPlayer(propertyID)
	for _, ply in ipairs(DRP.Players.List or {}) do
		if ready(ply) then
			local _, locatedID = DRP.Properties:LocationAt(ply:GetPos())
			if tonumber(locatedID) == tonumber(propertyID) then return true end
		end
	end
	return false
end

local function propertyEligible(propertyID, definition, checkOccupants)
	if not istable(definition) or #(definition.build_zones or {}) == 0 then return false end
	if DRP.Properties.IsWorldDefinition and DRP.Properties.IsWorldDefinition(definition) then return false end
	if definition.buyable == false then return false end
	if DRP.Properties.Leases[propertyID] or (DRP.Properties.ActiveRaids or {})[propertyID] then return false end
	if Mercenaries.PropertyReservations[propertyID] or (checkOccupants and propertyHasPlayer(propertyID)) then return false end
	return true
end

local function eligibleProperties()
	local result = {}
	for propertyID, definition in pairs(DRP.Properties.Definitions or {}) do
		propertyID = tonumber(propertyID)
		if propertyID and propertyEligible(propertyID, definition, true) then
			result[#result + 1] = { id = propertyID, definition = definition }
		end
	end
	return result
end

local function sampleSpawnPoints(definition, count)
	local zones, points = definition.build_zones or {}, {}
	if #zones == 0 then return nil end
	for _ = 1, math.max(80, count * 45) do
		local zone = zones[math.random(1, #zones)]
		local mins, maxs = zoneBounds(zone)
		local inset = 24
		if maxs.x - mins.x <= inset * 2 or maxs.y - mins.y <= inset * 2 or maxs.z - mins.z < 74 then
			inset = 8
		end
		local x = math.Rand(mins.x + inset, maxs.x - inset)
		local y = math.Rand(mins.y + inset, maxs.y - inset)
		local trace = util.TraceLine({
			start = Vector(x, y, maxs.z - 2),
			endpos = Vector(x, y, mins.z + 2),
			mask = MASK_NPCSOLID_BRUSHONLY
		})
		local position = trace.Hit and trace.HitPos + Vector(0, 0, 2) or Vector(x, y, mins.z + 2)
		local clear = not util.TraceHull({
			start = position, endpos = position,
			mins = Vector(-16, -16, 0), maxs = Vector(16, 16, 72), mask = MASK_NPCSOLID
		}).Hit
		if clear and npcHullInProperty(definition, position) then
			local separated = true
			for _, existing in ipairs(points) do
				if existing:DistToSqr(position) < 72 * 72 then separated = false break end
			end
			if separated then
				points[#points + 1] = position
				if #points >= count then return points end
			end
		end
	end
	return nil
end

local function fallbackPart(tier)
	local pools = {
		[1] = { "ferrous_scrap", "aluminium_offcuts", "copper_wire", "polymer_scrap" },
		[2] = { "steel_bar", "aluminium_plate", "copper_coil", "receiver_blank", "bolt_assembly" },
		[3] = { "precision_receiver", "precision_barrel", "calibrated_bolt", "electronic_control_unit" }
	}
	local resource = table.Random(pools[tier] or pools[1])
	return {
		kind = "resource", class = "drp_crafting_item", resource = resource,
		model = "models/gibs/metal_gib4.mdl", grade = tier,
		amount = tier == 1 and math.random(2, 4) or 1,
		label = string.Replace(string.upper(string.sub(resource, 1, 1)) .. string.sub(resource, 2), "_", " ")
	}
end

local function craftingPart(ply, tier)
	for _ = 1, 6 do
		local record = DRP.Crafting:GeneratePersonalLoot(ply)
		if istable(record) then return record end
	end
	return fallbackPart(tier)
end

local function schematic(tier)
	local minimum, maximum = math.max(1, tier - 1), math.min(5, tier + 1)
	for _ = 1, 12 do
		local record = DRP.Crafting:GenerateSchematicLoot(math.random(minimum, maximum))
		if istable(record) then return record end
	end
	return nil
end

local function weaponReward(tier)
	local choices, maximum = {}, ({ 1, 2, 4 })[tier] or 1
	for _, recipe in ipairs(DRP.Crafting.Catalog or {}) do
		if recipe.kind == "weapon" and (tonumber(recipe.grade) or 99) <= maximum
			and recipe.category ~= "Ordnance" and istable(recipe.output) then
			choices[#choices + 1] = recipe.output
		end
	end
	local chosen = table.Random(choices)
	return chosen and table.Copy(chosen) or nil
end

local function drugReward()
	local key = table.Random({ "heroin", "speed", "weed", "pcp", "crack", "fentanyl", "cocaine" })
	local definition = DRP.Drugs and DRP.Drugs.Definitions[key]
	return {
		kind = "drug", class = "drp_drug", drug = key, amount = 1,
		model = "models/props_lab/jar01b.mdl", label = definition and definition.name or key
	}
end

local function buildRewards(ply, tier, amount)
	local rewards = {}
	for index = 1, amount do
		local roll, record = math.random(1, 100)
		if tier == 1 then
			if roll <= 35 then record = schematic(1)
			elseif roll <= 45 then record = weaponReward(1)
			elseif roll <= 70 then record = drugReward()
			else record = craftingPart(ply, 1) end
		elseif tier == 2 then
			if roll <= 45 then record = schematic(2)
			elseif roll <= 70 then record = weaponReward(2)
			elseif roll <= 82 then record = drugReward()
			else record = craftingPart(ply, 2) end
		else
			if index == 1 then record = schematic(3)
			elseif index == 2 then record = weaponReward(3)
			elseif roll <= 35 then record = schematic(4)
			elseif roll <= 55 then record = weaponReward(3)
			elseif roll <= 70 then record = drugReward()
			else record = craftingPart(ply, 3) end
		end
		record = table.Copy(record or craftingPart(ply, tier))
		local commodity = DRP.Commodities and DRP.Commodities.Key(record)
		if tonumber(record.amount) and record.amount > 0 then
			if commodity and DRP.EconomyDirector then
				record.amount = math.max(1, math.floor(record.amount * DRP.EconomyDirector:LootFactor(commodity) + 0.5))
			end
			if DRP.Supporter and DRP.Supporter.ApplyRollCount then
				record.amount = DRP.Supporter.ApplyRollCount(ply, record.amount)
			end
		end
		rewards[#rewards + 1] = record
	end
	return rewards
end

local function missionAttacker(entity)
	if not IsValid(entity) then return nil end
	if entity:IsPlayer() then return entity end
	local owner = entity.GetOwner and entity:GetOwner()
	return IsValid(owner) and owner:IsPlayer() and owner or nil
end

local function activeWeaponClass(npc)
	local weapon = IsValid(npc) and npc.GetActiveWeapon and npc:GetActiveWeapon() or nil
	return IsValid(weapon) and string.lower(weapon:GetClass()) or ""
end

local function ensureNPCWeapon(npc, npcState)
	local wanted = string.lower(tostring(npcState and npcState.weapon or ""))
	if wanted == "" or not IsValid(npc) then return true end
	if activeWeaponClass(npc) == wanted then return true end
	-- additionalequipment is the normal Source spawn path. GiveWeapon and Give
	-- are guarded fallbacks for maps/addons which replace an NPC loadout during
	-- activation; the next director pass verifies the result again.
	npc:Fire("GiveWeapon", wanted, 0)
	if npc.Give then npc:Give(wanted) end
	return activeWeaponClass(npc) == wanted
end

local function canSeeOwner(npc, owner)
	if not IsValid(npc) or not ready(owner) then return false end
	local trace = util.TraceLine({
		start = npc:EyePos(), endpos = owner:WorldSpaceCenter(),
		filter = { npc, owner }, mask = MASK_VISIBLE_AND_NPCS
	})
	return not trace.Hit or trace.Fraction >= 0.98
end

function Mercenaries:DirectNPC(mission, npc, npcState, now)
	local owner = mission.owner
	if not IsValid(npc) or not ready(owner) then return end
	if npcState.weapon and (npcState.nextWeaponCheck or 0) <= now then
		npcState.nextWeaponCheck = now + 2
		ensureNPCWeapon(npc, npcState)
	end
	local distanceSquared = npc:GetPos():DistToSqr(owner:GetPos())
	if distanceSquared > self.EngagementRange * self.EngagementRange then
		npcState.hadSight = false
		return
	end
	local enemy = npc.GetEnemy and npc:GetEnemy() or nil
	if enemy ~= owner then npc:SetEnemy(owner) end
	npc:UpdateEnemyMemory(owner, owner:GetPos())
	if npc.SetNPCState then npc:SetNPCState(NPC_STATE_COMBAT) end
	local visible = canSeeOwner(npc, owner)
	if visible then
		if not npcState.hadSight then
			npcState.hadSight = true
			npc:ClearSchedule()
			npc:SetSchedule(SCHED_CHASE_ENEMY)
		end
		return
	end

	npcState.hadSight = false
	if (npcState.nextMoveCommand or 0) <= now then
		npcState.nextMoveCommand = now + 1.5
		npc:SetLastPosition(owner:GetPos())
		npc:SetSchedule(SCHED_FORCED_GO_RUN)
	end
end

function Mercenaries:DirectorTick()
	local now = CurTime()
	for _, mission in pairs(self.ByID) do
		for npc, npcState in pairs(mission.npcs) do
			if IsValid(npc) then self:DirectNPC(mission, npc, npcState, now) end
		end
	end
	if next(self.ByID) then
		DRP.Deadlines.Schedule("mercenaries:director", now + self.DirectorInterval, function() self:DirectorTick() end)
	end
end

function Mercenaries:ArmDirector()
	if next(self.ByID) and not DRP.Deadlines.ByKey["mercenaries:director"] then
		DRP.Deadlines.Schedule("mercenaries:director", CurTime() + self.DirectorInterval, function() self:DirectorTick() end)
	end
end

local function syncMission(mission, active)
	if not IsValid(mission.owner) then return end
	net.Start(SYNC)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(active == true)
	if active then
		net.WriteUInt(mission.id, 32)
		net.WriteUInt(mission.tier, 2)
		net.WriteString(string.sub(mission.propertyName, 1, 64))
		net.WriteVector(mission.waypoint)
		net.WriteUInt(math.max(0, mission.remaining), 8)
		net.WriteUInt(mission.total, 8)
		net.WriteFloat(mission.deadline)
	end
	net.Send(mission.owner)
end

local function removeMissionNPCs(mission)
	mission.cleaning = true
	for npc in pairs(mission.npcs) do
		Mercenaries.NPCToMission[npc] = nil
		if IsValid(npc) then npc:Remove() end
	end
	mission.npcs = {}
end

local function releaseMission(mission)
	DRP.Deadlines.Cancel("mercenary:" .. mission.id)
	Mercenaries.PropertyReservations[mission.propertyID] = nil
	Mercenaries.ByID[mission.id] = nil
	if IsValid(mission.owner) and Mercenaries.ActiveByPlayer[mission.owner] == mission then
		Mercenaries.ActiveByPlayer[mission.owner] = nil
	end
	syncMission(mission, false)
end

function Mercenaries:CanOffer(ply, tier)
	if not tiers[tonumber(tier)] or not ready(ply) or adminMode(ply) then return false end
	local active = self.ActiveByPlayer[ply]
	if active then return active.tier == tonumber(tier) end
	if table.Count(self.ByID) >= self.MaxActive or inIncident(ply) then return false end
	for propertyID, definition in pairs(DRP.Properties.Definitions or {}) do
		propertyID = tonumber(propertyID)
		if propertyID and propertyEligible(propertyID, definition, false) then return true end
	end
	return false
end

function Mercenaries:Begin(ply, tier, objectiveKey)
	tier = math.Clamp(math.floor(tonumber(tier) or 0), 1, 3)
	local config = tiers[tier]
	local blocked = aiBlockReason()
	if blocked then return false, blocked end
	if not self:CanOffer(ply, tier) then return false, "No safe vacant property is currently available for that contract." end
	local properties = eligibleProperties()
	while #properties > 0 do
		local selected = table.remove(properties, math.random(1, #properties))
		local points = sampleSpawnPoints(selected.definition, config.count)
		if points then
			local id = self.NextID
			self.NextID = self.NextID >= 4294967294 and 1 or self.NextID + 1
			local rewards = buildRewards(ply, tier, config.drops)
			local mission = {
				id = id, owner = ply, ownerID = ply:SteamID64(), tier = tier,
				objectiveKey = tostring(objectiveKey), event = config.event,
				propertyID = selected.id, propertyName = tostring(selected.definition.name or ("Property #" .. selected.id)),
				waypoint = points[1] + Vector(0, 0, 48), total = config.count, remaining = config.count,
				deadline = CurTime() + self.MissionDuration, npcs = {}, rewardEntities = {}, cleaning = false
			}
			local spawned = true
			for index, npcDefinition in ipairs(config.npcs) do
				local npc = ents.Create(npcDefinition.class)
				if not IsValid(npc) then spawned = false break end
				npc:SetPos(points[index])
				npc:SetAngles(Angle(0, math.random(0, 359), 0))
				if npcDefinition.weapon then npc:SetKeyValue("additionalequipment", npcDefinition.weapon) end
				npc:SetKeyValue("spawnflags", "8192")
				npc:Spawn()
				npc:Activate()
				npc:SetHealth(npcDefinition.health)
				npc:SetMaxHealth(npcDefinition.health)
				if npc.CapabilitiesAdd then
					local capabilities = bit.bor(tonumber(CAP_MOVE_GROUND) or 0, tonumber(CAP_OPEN_DOORS) or 0,
						tonumber(CAP_AUTO_DOORS) or 0, tonumber(CAP_USE_WEAPONS) or 0)
					if capabilities ~= 0 then npc:CapabilitiesAdd(capabilities) end
				end
				npc.DRPMercenaryMissionID, npc.DRPMercenaryOwnerID = id, mission.ownerID
				npc:AddEntityRelationship(ply, D_HT, 99)
				for _, other in ipairs(DRP.Players.List or {}) do
					if IsValid(other) and other ~= ply then npc:AddEntityRelationship(other, D_NU, 99) end
				end
				if npc.SetNPCState then npc:SetNPCState(NPC_STATE_ALERT) end
				local npcState = {
					weapon = npcDefinition.weapon,
					nextWeaponCheck = 0,
					nextMoveCommand = 0,
					hadSight = false
				}
				mission.npcs[npc], self.NPCToMission[npc] = npcState, mission
				ensureNPCWeapon(npc, npcState)
			end
			if spawned and table.Count(mission.npcs) == config.count then
				local candidates = {}
				for npc in pairs(mission.npcs) do candidates[#candidates + 1] = npc end
				for _, record in ipairs(rewards) do
					local chosen = table.remove(candidates, math.random(1, #candidates))
					chosen.DRPMercenaryReward = record
				end
				self.ActiveByPlayer[ply], self.ByID[id], self.PropertyReservations[selected.id] = mission, mission, id
				self:ArmDirector()
				DRP.Deadlines.Schedule("mercenary:" .. id, mission.deadline, function()
					local current = Mercenaries.ByID[id]
					if current then Mercenaries:Cancel(current.owner, "The mercenary contract expired.", true) end
				end)
				syncMission(mission, true)
				DRP.Net.Notify(ply, "Mercenary contract deployed at " .. mission.propertyName .. ". Eliminate all " .. config.count .. " hostiles.", 1)
				if DRP.Audit then DRP.Audit.Log(ply, "mercenary_started", nil, "mission=" .. id .. " property=" .. selected.id .. " tier=" .. tier) end
				return true
			end
			removeMissionNPCs(mission)
		end
	end
	return false, "The available properties do not currently contain enough safe NPC spawn space."
end

function Mercenaries:Cancel(ply, reason, removeObjective)
	local mission = IsValid(ply) and self.ActiveByPlayer[ply] or nil
	if not mission then return false end
	removeMissionNPCs(mission)
	for entity in pairs(mission.rewardEntities) do
		if IsValid(entity) then
			local record = entity.DRPMercenaryRewardRecord
			local commodity = istable(record) and DRP.Commodities and DRP.Commodities.Key(record)
			if commodity and DRP.EconomyDirector then
				DRP.EconomyDirector:RecordItem(commodity, -math.max(1, tonumber(record.amount) or 1), "world", "burn", "cancelled mercenary reward")
			end
			entity:Remove()
		end
	end
	releaseMission(mission)
	if removeObjective and IsValid(ply) and DRP.Objectives then
		DRP.Objectives:CancelActive(ply, mission.objectiveKey, reason, 300)
	end
	if IsValid(ply) then DRP.Net.Notify(ply, tostring(reason or "Mercenary contract cancelled."), 3) end
	if DRP.Audit then DRP.Audit.Log(IsValid(ply) and ply or nil, "mercenary_cancelled", nil, "mission=" .. mission.id .. " reason=" .. tostring(reason)) end
	return true
end

function Mercenaries:Complete(ply)
	local mission = IsValid(ply) and self.ActiveByPlayer[ply] or nil
	if not mission then return false end
	removeMissionNPCs(mission)
	for entity in pairs(mission.rewardEntities) do
		if IsValid(entity) then
			entity.DRPMercenaryRewardMissionID = nil
			local rewardEntity = entity
			DRP.Deadlines.Schedule("mercenary_reward:" .. mission.id .. ":" .. rewardEntity:EntIndex(), CurTime() + self.RewardReservation, function()
				if IsValid(rewardEntity) then rewardEntity.DRPMercenaryRewardOwnerID = nil end
			end)
		end
	end
	releaseMission(mission)
	DRP.Net.Notify(ply, "Mercenary contract complete. Cash was paid and reserved item rewards remain where their carriers fell.", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "mercenary_completed", nil, "mission=" .. mission.id .. " tier=" .. mission.tier) end
	return true
end

function Mercenaries:Status()
	local npcCount, armed, missingWeapons = 0, 0, 0
	for _, mission in pairs(self.ByID) do
		for npc, npcState in pairs(mission.npcs) do
			if IsValid(npc) then
				npcCount = npcCount + 1
				if not npcState.weapon or activeWeaponClass(npc) == string.lower(npcState.weapon) then armed = armed + 1
				else missingWeapons = missingWeapons + 1 end
			end
		end
	end
	return {
		active = table.Count(self.ByID), reserved_properties = table.Count(self.PropertyReservations), maximum = self.MaxActive,
		npcs = npcCount, armed = armed, missing_weapons = missingWeapons, ai_block = aiBlockReason()
	}
end

local function spawnReward(mission, npc, record)
	if not istable(record) or not IsValid(mission.owner) then return end
	local entity = DRP.Inventory.SpawnRecordAt(mission.owner, table.Copy(record), npc:GetPos(), Vector(0, 0, 1), true, true)
	if not IsValid(entity) then
		DRP.Net.Notify(mission.owner, "A carried reward could not be spawned because its world entity budget is full.", 3)
		return
	end
	entity.DRPMercenaryRewardOwnerID = mission.ownerID
	entity.DRPMercenaryRewardMissionID = mission.id
	entity.DRPMercenaryRewardRecord = table.Copy(record)
	mission.rewardEntities[entity] = true
	if DRP.EconomyDirector and DRP.Commodities then
		local commodity = DRP.Commodities.Key(record)
		if commodity then DRP.EconomyDirector:RecordItem(commodity, math.max(1, tonumber(record.amount) or 1), "world", "mint", "mercenary reward") end
	end
	DRP.Net.Notify(mission.owner, "A hostile dropped a reserved " .. tostring(record.label or "item reward") .. ".", 1)
end

function Mercenaries:Start()
	hook.Add("OnNPCKilled", "DRP.Mercenaries.NPCKilled", function(npc, attacker)
		local mission = Mercenaries.NPCToMission[npc]
		if not mission or mission.cleaning then return end
		local heldWeapon = npc.GetActiveWeapon and npc:GetActiveWeapon() or nil
		if IsValid(heldWeapon) then heldWeapon:Remove() end
		Mercenaries.NPCToMission[npc], mission.npcs[npc] = nil, nil
		if missionAttacker(attacker) ~= mission.owner then
			Mercenaries:Cancel(mission.owner, "The contract target was killed by an unauthorized source.", true)
			return
		end
		mission.remaining = math.max(0, mission.remaining - 1)
		spawnReward(mission, npc, npc.DRPMercenaryReward)
		syncMission(mission, true)
		DRP.Objectives:Emit(mission.owner, mission.event, 1)
	end)

	hook.Add("EntityTakeDamage", "DRP.Mercenaries.IsolateCombat", function(target, damage)
		local targetMission = Mercenaries.NPCToMission[target]
		if targetMission and missionAttacker(damage:GetAttacker()) ~= targetMission.owner then
			damage:SetDamage(0)
			return true
		end
		local attackerMission = Mercenaries.NPCToMission[damage:GetAttacker()]
		if attackerMission and target:IsPlayer() and target ~= attackerMission.owner then
			damage:SetDamage(0)
			return true
		end
	end)

	hook.Add("EntityRemoved", "DRP.Mercenaries.TargetRemoved", function(entity)
		local mission = Mercenaries.NPCToMission[entity]
		if not mission or mission.cleaning then return end
		Mercenaries.NPCToMission[entity], mission.npcs[entity] = nil, nil
		timer.Simple(0, function()
			if Mercenaries.ByID[mission.id] then Mercenaries:Cancel(mission.owner, "A contract target became unavailable.", true) end
		end)
	end)

	hook.Add("PlayerDeath", "DRP.Mercenaries.Death", function(ply)
		if Mercenaries.ActiveByPlayer[ply] then Mercenaries:Cancel(ply, "Mercenary contract cancelled because you died.", true) end
	end)
	hook.Add("DRPJobChanged", "DRP.Mercenaries.JobChanged", function(ply)
		if Mercenaries.ActiveByPlayer[ply] then Mercenaries:Cancel(ply, "Mercenary contract cancelled because your role changed.", true) end
	end)
	hook.Add("PlayerDisconnected", "DRP.Mercenaries.Disconnect", function(ply)
		if Mercenaries.ActiveByPlayer[ply] then Mercenaries:Cancel(ply, "Contractor disconnected.", false) end
	end)
	hook.Add("DRPObjectiveCancelled", "DRP.Mercenaries.ObjectiveCancelled", function(ply, key)
		local mission = Mercenaries.ActiveByPlayer[ply]
		if mission and mission.objectiveKey == key then Mercenaries:Cancel(ply, "Mercenary objective abandoned.", false) end
	end)
	hook.Add("DRPObjectiveCompleted", "DRP.Mercenaries.ObjectiveCompleted", function(ply, key)
		local mission = Mercenaries.ActiveByPlayer[ply]
		if mission and mission.objectiveKey == key then Mercenaries:Complete(ply) end
	end)
	hook.Add("DRPPropertyOwnershipChanged", "DRP.Mercenaries.PropertyChanged", function(_, propertyID, acquired)
		local missionID = acquired and Mercenaries.PropertyReservations[tonumber(propertyID)] or nil
		local mission = missionID and Mercenaries.ByID[missionID]
		if mission then Mercenaries:Cancel(mission.owner, "The contract property became occupied.", true) end
	end)
	hook.Add("PreCleanupMap", "DRP.Mercenaries.MapCleanup", function()
		local owners = {}
		for _, mission in pairs(Mercenaries.ByID) do owners[#owners + 1] = mission.owner end
		for _, owner in ipairs(owners) do if IsValid(owner) then Mercenaries:Cancel(owner, "Map cleanup cancelled the mercenary contract.", true) end end
	end)
	concommand.Add("drp_mercenary_npc_status", function(ply)
		if IsValid(ply) and not (DRP.Admin and DRP.Admin.CanSetRanks and DRP.Admin.CanSetRanks(ply)) then return end
		local status = Mercenaries:Status()
		print(string.format("[DRP MERCENARY NPC] missions=%d npcs=%d armed=%d missing_weapons=%d ai_block=%s",
			status.active, status.npcs, status.armed, status.missing_weapons, tostring(status.ai_block or "none")))
		for id, mission in pairs(Mercenaries.ByID) do
			for npc, npcState in pairs(mission.npcs) do
				if IsValid(npc) then
					local enemy = npc.GetEnemy and npc:GetEnemy() or nil
					local enemyName = IsValid(enemy) and (enemy:IsPlayer() and enemy:Nick() or enemy:GetClass()) or "none"
					local distance = IsValid(mission.owner) and npc:GetPos():Distance(mission.owner:GetPos()) or -1
					print(string.format("  mission=%d npc=%d class=%s weapon=%s expected=%s enemy=%s schedule=%s state=%s distance=%.0f",
						id, npc:EntIndex(), npc:GetClass(), activeWeaponClass(npc), tostring(npcState.weapon or "none"),
						enemyName, tostring(npc.GetCurrentSchedule and npc:GetCurrentSchedule() or "unknown"),
						tostring(npc.GetNPCState and npc:GetNPCState() or "unknown"), distance))
				end
			end
		end
	end)
end

function Mercenaries:Stop()
	DRP.Deadlines.Cancel("mercenaries:director")
	local owners = {}
	for _, mission in pairs(self.ByID) do owners[#owners + 1] = mission.owner end
	for _, owner in ipairs(owners) do if IsValid(owner) then self:Cancel(owner, "Server shutdown.", false) end end
	for _, event in ipairs({ "OnNPCKilled", "EntityTakeDamage", "EntityRemoved", "PlayerDeath", "DRPJobChanged", "PlayerDisconnected", "DRPObjectiveCancelled", "DRPObjectiveCompleted", "DRPPropertyOwnershipChanged", "PreCleanupMap" }) do
		for identifier in pairs(hook.GetTable()[event] or {}) do
			if string.StartWith(identifier, "DRP.Mercenaries.") then hook.Remove(event, identifier) end
		end
	end
end
