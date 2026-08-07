local Cocaine = {
	ActiveHotplates = setmetatable({}, { __mode = "k" }),
	EntityGeneration = setmetatable({}, { __mode = "k" })
}

DRP.Cocaine = Cocaine
DRP.Services.Register("cocaine", Cocaine)

local MENU = "drp_cocaine_menu_v1"
local ACTION = "drp_cocaine_action_v1"
util.AddNetworkString(MENU)
util.AddNetworkString(ACTION)

local resources = {
	coca_leaf = { label = "Coca Leaves", model = "models/props_lab/box01a.mdl" },
	coca_seed = { label = "Coca Seed", model = "models/props_junk/garbage_coffeemug001a.mdl" },
	petroleum = { label = "Petroleum", model = "models/props_junk/metalgascan.mdl" },
	cocaine_product = { label = "Unpackaged Cocaine", model = "models/props_lab/jar01b.mdl" },
	cocaine_brick = { label = "Cocaine Brick", model = "models/props_junk/garbage_bag001a.mdl" }
}
Cocaine.Resources = resources

local productionClasses = {
	drp_coca_wild = true, drp_coca_pot = true, drp_cocaine_bucket = true,
	drp_cocaine_petroleum = true, drp_cocaine_hotplate = true,
	drp_narcotics_table = true, drp_cocaine_buyer = true
}

local function notify(ply, message, kind)
	if IsValid(ply) then DRP.Net.Notify(ply, message, kind or 0) end
end

local function generationKey(entity, suffix)
	Cocaine.EntityGeneration[entity] = Cocaine.EntityGeneration[entity] or math.random(1, 2147483646)
	return "cocaine:" .. entity:EntIndex() .. ":" .. Cocaine.EntityGeneration[entity] .. ":" .. tostring(suffix)
end

local function owner(entity)
	return DRP.Props and DRP.Props.Owner(entity) or nil
end

local function mayOperate(ply, entity)
	local entityOwner = owner(entity)
	return not IsValid(entityOwner) or entityOwner == ply or (DRP.Admin and DRP.Admin.Has(ply, "panel"))
end

local function selectedResource(ply, key)
	local record, index = DRP.Inventory.Selected(ply)
	return record and record.kind == "resource" and record.resource == key and record, index
end

local function giveResource(ply, key, amount)
	local definition = resources[key]
	if not definition then return false end
	return DRP.Inventory.AddResource(ply, key, amount, definition.label, definition.model)
end

local function cancelEntity(entity)
	if not IsValid(entity) then return end
	for _, suffix in ipairs({ "regrow", "grow", "stir", "miss", "finish" }) do DRP.Deadlines.Cancel(generationKey(entity, suffix)) end
end

function Cocaine:HarvestWild(entity, ply)
	if not entity:GetNW2Bool("DRPCocaReady", true) then
		local remaining = math.max(0, math.ceil(entity:GetNW2Float("DRPCocaReadyAt", 0) - CurTime()))
		notify(ply, "That coca plant is regrowing (" .. remaining .. "s).", 2)
		return false
	end
	if not DRP.Inventory.CanAdd(ply, "resource", "coca_leaf", 1) or not DRP.Inventory.CanAdd(ply, "resource", "coca_seed", 1) then
		notify(ply, "You need room in Hands for leaves and a seed.", 3)
		return false
	end
	if not giveResource(ply, "coca_leaf", 1) then return false end
	if not giveResource(ply, "coca_seed", 1) then DRP.Inventory.TakeResource(ply, "coca_leaf", 1) return false end
	entity:SetNW2Bool("DRPCocaReady", false)
	local readyAt = CurTime() + DRP.CocaineConfig.WildRegrowTime
	entity:SetNW2Float("DRPCocaReadyAt", readyAt)
	DRP.Deadlines.Schedule(generationKey(entity, "regrow"), readyAt, function()
		if IsValid(entity) then entity:SetNW2Bool("DRPCocaReady", true) entity:SetNW2Float("DRPCocaReadyAt", 0) end
	end)
	notify(ply, "Harvested 1 coca leaf and 1 coca seed.", 1)
	if DRP.Civic then DRP.Civic:Adjust(ply, -2, "harvested coca", true) end
	if DRP.Audit then DRP.Audit.Log(ply, "coca_harvested", entity, "wild") end
	return true
end

local function createPlantVisual(pot)
	if IsValid(pot.DRPCocaPlantVisual) then pot.DRPCocaPlantVisual:Remove() end
	local visual = ents.Create("prop_dynamic")
	if not IsValid(visual) then return end
	visual:SetModel(DRP.CocaineModel("wild"))
	visual:SetPos(pot:LocalToWorld(Vector(0, 0, math.max(4, pot:OBBMaxs().z - 2))))
	visual:SetAngles(pot:GetAngles())
	visual:SetParent(pot)
	visual:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
	visual:Spawn()
	visual:SetModelScale(0.48, 0)
	pot.DRPCocaPlantVisual = visual
	pot:DeleteOnRemove(visual)
end

function Cocaine:UsePot(entity, ply)
	if not mayOperate(ply, entity) then notify(ply, "That growing pot belongs to another player.", 3) return false end
	local stage = entity:GetNW2Int("DRPCocaineStage", 0)
	if stage == 0 then
		if not selectedResource(ply, "coca_seed") then notify(ply, "Select a coca seed in Hands first.", 2) return false end
		DRP.Inventory.TakeResource(ply, "coca_seed", 1)
		stage = 1
		entity:SetNW2Int("DRPCocaineStage", stage)
		local growEnd = CurTime() + DRP.CocaineConfig.PotGrowTime
		entity:SetNW2Float("DRPCocaineReadyAt", growEnd)
		createPlantVisual(entity)
		DRP.Deadlines.Schedule(generationKey(entity, "grow"), growEnd, function()
			if IsValid(entity) and entity:GetNW2Int("DRPCocaineStage", 0) == 1 then
				entity:SetNW2Int("DRPCocaineStage", 2)
				entity:SetNW2Float("DRPCocaineReadyAt", 0)
			end
		end)
		notify(ply, "Coca seed planted. This cultivated plant yields three times the wild leaves.", 1)
		return true
	elseif stage == 1 then
		notify(ply, "The coca plant needs " .. math.max(0, math.ceil(entity:GetNW2Float("DRPCocaineReadyAt", 0) - CurTime())) .. " more seconds.", 2)
		return false
	end
	if not DRP.Inventory.CanAdd(ply, "resource", "coca_leaf", 3) or not DRP.Inventory.CanAdd(ply, "resource", "coca_seed", 2) then
		notify(ply, "You need room for 3 leaves and 2 seeds.", 3)
		return false
	end
	if not giveResource(ply, "coca_leaf", 3) then return false end
	if not giveResource(ply, "coca_seed", 2) then DRP.Inventory.TakeResource(ply, "coca_leaf", 3) return false end
	if IsValid(entity.DRPCocaPlantVisual) then entity.DRPCocaPlantVisual:Remove() end
	entity:SetNW2Int("DRPCocaineStage", 0)
	notify(ply, "Harvested 3 coca leaves and recovered 2 seeds.", 1)
	if DRP.Civic then DRP.Civic:Adjust(ply, -5, "cultivated coca", true) end
	if DRP.Audit then DRP.Audit.Log(ply, "coca_harvested", entity, "cultivated x3") end
	return true
end

function Cocaine:UsePetroleum(entity, ply)
	if not mayOperate(ply, entity) then return false end
	if not DRP.Inventory.CanAdd(ply, "resource", "petroleum", 1) then notify(ply, "Your Hands grid is full.", 3) return false end
	giveResource(ply, "petroleum", 1)
	entity:Remove()
	notify(ply, "Stored the petroleum can in Hands.", 1)
	return true
end

function Cocaine:UseBucket(entity, ply)
	if not mayOperate(ply, entity) then notify(ply, "That bucket belongs to another player.", 3) return false end
	local stage = entity:GetNW2Int("DRPCocaineStage", 0)
	if stage >= 2 then notify(ply, stage == 4 and "This batch must be strained at a narcotics table." or "Use the hotplate to continue this batch.", 2) return false end
	if stage == 1 then
		entity:SetNW2Int("DRPCocaineStage", 2)
		notify(ply, "Batch mixed. Move the bucket beside your portable hotplate, then use the hotplate.", 1)
		return true
	end
	local leaf = selectedResource(ply, "coca_leaf")
	local petroleum = selectedResource(ply, "petroleum")
	if leaf then
		local leaves = entity:GetNW2Int("DRPCocaineLeaves", 0)
		if leaves >= DRP.CocaineConfig.LeavesPerBatch then notify(ply, "The bucket already has enough coca leaves.", 2) return false end
		DRP.Inventory.TakeResource(ply, "coca_leaf", 1)
		entity:SetNW2Int("DRPCocaineLeaves", leaves + 1)
		notify(ply, "Added coca leaves (" .. (leaves + 1) .. "/" .. DRP.CocaineConfig.LeavesPerBatch .. ").", 1)
	elseif petroleum then
		if entity:GetNW2Int("DRPCocainePetroleum", 0) >= 1 then notify(ply, "The bucket already contains petroleum.", 2) return false end
		DRP.Inventory.TakeResource(ply, "petroleum", 1)
		entity:SetNW2Int("DRPCocainePetroleum", 1)
		notify(ply, "Added petroleum to the bucket.", 1)
	else
		notify(ply, "Select coca leaves or petroleum. The batch needs " .. DRP.CocaineConfig.LeavesPerBatch .. " leaves and 1 petroleum.", 2)
		return false
	end
	if entity:GetNW2Int("DRPCocaineLeaves", 0) >= DRP.CocaineConfig.LeavesPerBatch and entity:GetNW2Int("DRPCocainePetroleum", 0) >= 1 and entity:GetNW2Int("DRPCocaineStage", 0) == 0 then entity:SetNW2Int("DRPCocaineStage", 1) end
	return true
end

local function nearestOwnedBucket(ply, hotplate)
	local nearest, nearestDistance
	for _, candidate in ipairs(ents.FindInSphere(hotplate:GetPos(), 105)) do
		if candidate:GetClass() == "drp_cocaine_bucket" and candidate:GetNW2Int("DRPCocaineStage", 0) == 2 and mayOperate(ply, candidate) then
			local distance = candidate:GetPos():DistToSqr(hotplate:GetPos())
			if not nearestDistance or distance < nearestDistance then nearest, nearestDistance = candidate, distance end
		end
	end
	return nearest
end

function Cocaine:Explode(hotplate, reason)
	if not IsValid(hotplate) or hotplate.DRPCocaineExploded then return end
	hotplate.DRPCocaineExploded = true
	local position = hotplate:WorldSpaceCenter()
	local operator = owner(hotplate)
	util.BlastDamage(hotplate, IsValid(operator) and operator or hotplate, position, DRP.CocaineConfig.ExplosionRadius, DRP.CocaineConfig.ExplosionDamage)
	local effect = EffectData() effect:SetOrigin(position) util.Effect("Explosion", effect, true, true)
	sound.Play("BaseExplosionEffect.Sound", position, 95, 100, 1)
	for _, entity in ipairs(ents.FindInSphere(position, DRP.CocaineConfig.ExplosionRadius)) do
		if productionClasses[entity:GetClass()] and entity:GetClass() ~= "drp_cocaine_buyer" then entity:Remove() end
	end
	if IsValid(operator) then notify(operator, "The hotplate exploded: " .. tostring(reason or "the batch was not stirred") .. ".", 3) end
	if DRP.Audit then DRP.Audit.Log(operator, "cocaine_hotplate_exploded", hotplate, tostring(reason or "missed stir")) end
end

function Cocaine:ScheduleStir(hotplate)
	if not IsValid(hotplate) or not self.ActiveHotplates[hotplate] then return end
	local batch = self.ActiveHotplates[hotplate]
	local due = CurTime() + math.Rand(DRP.CocaineConfig.StirIntervalMin, DRP.CocaineConfig.StirIntervalMax)
	if due + DRP.CocaineConfig.StirWindow + 2 >= batch.finishAt then return end
	DRP.Deadlines.Schedule(generationKey(hotplate, "stir"), due, function()
		if not IsValid(hotplate) or not Cocaine.ActiveHotplates[hotplate] then return end
		local deadline = CurTime() + DRP.CocaineConfig.StirWindow
		hotplate:SetNW2Float("DRPCocaineStirDeadline", deadline)
		local operator = owner(hotplate)
		notify(operator, "Your cocaine batch needs stirring now.", 2)
		DRP.Deadlines.Schedule(generationKey(hotplate, "miss"), deadline, function()
			if IsValid(hotplate) and Cocaine.ActiveHotplates[hotplate] and hotplate:GetNW2Float("DRPCocaineStirDeadline", 0) > 0 then Cocaine:Explode(hotplate, "a stir interval was missed") end
		end)
	end)
end

function Cocaine:FinishCook(hotplate)
	local batch = IsValid(hotplate) and self.ActiveHotplates[hotplate]
	if not batch or not IsValid(batch.bucket) then return end
	batch.bucket:SetNW2Int("DRPCocaineStage", 4)
	batch.bucket:SetParent(nil)
	batch.bucket:SetPos(hotplate:LocalToWorld(Vector(42, 0, 12 - batch.bucket:OBBMins().z)))
	local physics = batch.bucket:GetPhysicsObject()
	if IsValid(physics) then physics:EnableMotion(false) physics:Sleep() end
	hotplate:SetNW2Entity("DRPCocaineBucket", NULL)
	hotplate:SetNW2Float("DRPCocaineCookEnd", 0)
	hotplate:SetNW2Float("DRPCocaineStirDeadline", 0)
	self.ActiveHotplates[hotplate] = nil
	notify(owner(hotplate), "Heating complete. Take the cooked bucket to a narcotics table for straining.", 1)
end

function Cocaine:UseHotplate(hotplate, ply)
	if not mayOperate(ply, hotplate) then notify(ply, "That hotplate belongs to another player.", 3) return false end
	local batch = self.ActiveHotplates[hotplate]
	if batch then
		local deadline = hotplate:GetNW2Float("DRPCocaineStirDeadline", 0)
		if deadline <= CurTime() then notify(ply, "The mixture does not need stirring yet.", 2) return false end
		hotplate:SetNW2Float("DRPCocaineStirDeadline", 0)
		DRP.Deadlines.Cancel(generationKey(hotplate, "miss"))
		notify(ply, "Batch stirred successfully.", 1)
		self:ScheduleStir(hotplate)
		return true
	end
	local bucket = nearestOwnedBucket(ply, hotplate)
	if not IsValid(bucket) then notify(ply, "Place a mixed bucket within reach of the hotplate.", 2) return false end
	bucket:SetNW2Int("DRPCocaineStage", 3)
	bucket:SetPos(hotplate:LocalToWorld(Vector(0, 0, hotplate:OBBMaxs().z - bucket:OBBMins().z)))
	bucket:SetAngles(hotplate:GetAngles())
	bucket:SetParent(hotplate)
	local finishAt = CurTime() + DRP.CocaineConfig.CookTime
	self.ActiveHotplates[hotplate] = { bucket = bucket, finishAt = finishAt }
	hotplate:SetNW2Entity("DRPCocaineBucket", bucket)
	hotplate:SetNW2Float("DRPCocaineCookEnd", finishAt)
	self:ScheduleStir(hotplate)
	DRP.Deadlines.Schedule(generationKey(hotplate, "finish"), finishAt, function()
		if IsValid(hotplate) and Cocaine.ActiveHotplates[hotplate] then Cocaine:FinishCook(hotplate) end
	end)
	notify(ply, "Heating started. Stir whenever prompted or the operation will explode.", 2)
	if DRP.Audit then DRP.Audit.Log(ply, "cocaine_batch_started", hotplate) end
	return true
end

local function nearestCookedBucket(ply, entity)
	for _, candidate in ipairs(ents.FindInSphere(entity:GetPos(), 125)) do
		if candidate:GetClass() == "drp_cocaine_bucket" and candidate:GetNW2Int("DRPCocaineStage", 0) == 4 and mayOperate(ply, candidate) then return candidate end
	end
end

function Cocaine:SendMenu(ply, entity, mode)
	ply.DRPCocaineMenuEntity = entity
	net.Start(MENU)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteString(mode)
		net.WriteEntity(entity)
		net.WriteUInt(math.min(DRP.Inventory.CountResource(ply, "cocaine_product"), 255), 8)
		net.WriteUInt(math.min(DRP.Inventory.CountDrug(ply, "cocaine"), 255), 8)
		net.WriteUInt(math.min(DRP.Inventory.CountResource(ply, "cocaine_brick"), 255), 8)
		net.WriteBool(IsValid(nearestCookedBucket(ply, entity)))
	net.Send(ply)
end

function Cocaine:TableAction(ply, entity, action)
	if action == 0 then
		local bucket = nearestCookedBucket(ply, entity)
		if not IsValid(bucket) then notify(ply, "Place a cooked bucket beside the table first.", 3) return end
		if not DRP.Inventory.CanAdd(ply, "resource", "cocaine_product", DRP.CocaineConfig.ProductPerBatch) then notify(ply, "You need Hands grid space for the finished product.", 3) return end
		giveResource(ply, "cocaine_product", DRP.CocaineConfig.ProductPerBatch)
		bucket:Remove()
		notify(ply, "Petroleum strained. Recovered " .. DRP.CocaineConfig.ProductPerBatch .. " units of unpackaged cocaine.", 1)
		if DRP.Civic then DRP.Civic:Adjust(ply, -15, "produced cocaine") end
		if DRP.Roles then DRP.Roles:Record(ply, "narcotics", math.max(2, DRP.CocaineConfig.ProductPerBatch), "cocaine production") end
		if DRP.Audit then DRP.Audit.Log(ply, "cocaine_batch_finished", entity, tostring(DRP.CocaineConfig.ProductPerBatch)) end
	elseif action == 1 then
		if DRP.Inventory.CountResource(ply, "cocaine_product") < 1 then notify(ply, "You do not have unpackaged cocaine.", 3) return end
		DRP.Inventory.TakeResource(ply, "cocaine_product", 1)
		if not DRP.Inventory.AddDrug(ply, "cocaine", 1, "Cocaine Dose", DRP.CocaineModel("item")) then
			giveResource(ply, "cocaine_product", 1)
			notify(ply, "You need another free Hands cell.", 3)
			return
		end
		notify(ply, "Packaged one usable cocaine dose.", 1)
	elseif action == 2 then
		if DRP.Inventory.CountDrug(ply, "cocaine") < 5 then notify(ply, "You need 5 cocaine doses to make a brick.", 3) return end
		DRP.Inventory.TakeDrug(ply, "cocaine", 5)
		if not giveResource(ply, "cocaine_brick", 1) then
			DRP.Inventory.AddDrug(ply, "cocaine", 5, "Cocaine Dose", DRP.CocaineModel("item"))
			notify(ply, "You need another free Hands cell.", 3)
			return
		end
		notify(ply, "Combined 5 doses into a cocaine brick.", 1)
	elseif action == 3 then
		if not DRP.Inventory.TakeResource(ply, "cocaine_brick", 1) then notify(ply, "You do not have a cocaine brick.", 3) return end
		if not DRP.Inventory.AddDrug(ply, "cocaine", 5, "Cocaine Dose", DRP.CocaineModel("item")) then
			giveResource(ply, "cocaine_brick", 1)
			notify(ply, "You need another free Hands cell.", 3)
			return
		end
		notify(ply, "Split one cocaine brick into 5 doses.", 1)
	end
end

function Cocaine:BuyerAction(ply, entity, action)
	local key, amount, value
	if action == 4 then key, amount, value = "dose", 1, DRP.CocaineConfig.Prices.dose
	elseif action == 5 then key, amount, value = "brick", 1, DRP.CocaineConfig.Prices.brick else return end
	local removed = key == "dose" and DRP.Inventory.TakeDrug(ply, "cocaine", amount) or DRP.Inventory.TakeResource(ply, "cocaine_brick", amount)
	if not removed then notify(ply, "You do not have that packaged product.", 3) return end
	DRP.Economy.Reward(ply, value, "cocaine sold")
	if DRP.Civic then DRP.Civic:Adjust(ply, key == "brick" and -18 or -4, "sold cocaine") end
	if DRP.Roles then DRP.Roles:Record(ply, "narcotics", key == "brick" and 5 or 1, "cocaine trade") end
	notify(ply, "Sold a cocaine " .. key .. " for $" .. string.Comma(value) .. ".", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "cocaine_sold", entity, key .. " $" .. value) end
end

function Cocaine:Use(entity, ply)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() or not ply:DRPReady() then return end
	if ply:GetPos():DistToSqr(entity:GetPos()) > 22500 then return end
	local class = entity:GetClass()
	if class == "drp_coca_wild" then self:HarvestWild(entity, ply)
	elseif class == "drp_coca_pot" then self:UsePot(entity, ply)
	elseif class == "drp_cocaine_petroleum" then self:UsePetroleum(entity, ply)
	elseif class == "drp_cocaine_bucket" then self:UseBucket(entity, ply)
	elseif class == "drp_cocaine_hotplate" then self:UseHotplate(entity, ply)
	elseif class == "drp_narcotics_table" then if mayOperate(ply, entity) then self:SendMenu(ply, entity, "table") end
	elseif class == "drp_cocaine_buyer" then self:SendMenu(ply, entity, "buyer") end
end

DRP.Net.Receive(ACTION, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "cocaine_action", 0.25, 5) then return end
	local entity, action = net.ReadEntity(), net.ReadUInt(3)
	if not IsValid(entity) or entity ~= ply.DRPCocaineMenuEntity or ply:GetPos():DistToSqr(entity:GetPos()) > 22500 then return end
	if entity:GetClass() == "drp_narcotics_table" and mayOperate(ply, entity) then Cocaine:TableAction(ply, entity, action)
	elseif entity:GetClass() == "drp_cocaine_buyer" then Cocaine:BuyerAction(ply, entity, action) end
	Cocaine:SendMenu(ply, entity, entity:GetClass() == "drp_narcotics_table" and "table" or "buyer")
end)

hook.Add("EntityRemoved", "DRP.Cocaine.Cleanup", function(entity)
	if not productionClasses[entity:GetClass()] then return end
	cancelEntity(entity)
	if Cocaine.ActiveHotplates[entity] then
		local batch = Cocaine.ActiveHotplates[entity]
		if IsValid(batch.bucket) then batch.bucket:Remove() end
		Cocaine.ActiveHotplates[entity] = nil
	end
end)

function Cocaine:Start() end
function Cocaine:Stop()
	for entity in pairs(self.EntityGeneration) do if IsValid(entity) then cancelEntity(entity) end end
	table.Empty(self.ActiveHotplates)
end
