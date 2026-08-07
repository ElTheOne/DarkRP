DRP.CocaineConfig = DRP.CocaineConfig or {
	WildRegrowTime = 180,
	PotGrowTime = 300,
	CookTime = 70,
	StirIntervalMin = 10,
	StirIntervalMax = 14,
	StirWindow = 5,
	LeavesPerBatch = 3,
	ProductPerBatch = 6,
	ExplosionRadius = 240,
	ExplosionDamage = 135,
	Prices = { dose = 325, brick = 1625 },
	Models = {
		wild = { "models/props_foliage/plant01.mdl", "models/props/de_inferno/flower_barrel.mdl", "models/props_junk/terracotta01.mdl" },
		pot = { "models/props_junk/terracotta01.mdl", "models/props_c17/FurniturePlant001a.mdl" },
		bucket = { "models/props_junk/MetalBucket01a.mdl", "models/props_junk/garbage_metalcan001a.mdl" },
		petroleum = { "models/props_junk/metalgascan.mdl", "models/props_junk/gascan001a.mdl" },
		hotplate = { "models/props_lab/hotplate.mdl", "models/props_lab/reciever01b.mdl" },
		table = { "models/props_c17/FurnitureTable001a.mdl" },
		buyer = { "models/Humans/Group03m/male_06.mdl" },
		item = { "models/props_lab/jar01b.mdl", "models/props_lab/box01a.mdl" }
	}
}

function DRP.CocaineModel(key)
	local candidates = DRP.CocaineConfig.Models[key] or DRP.CocaineConfig.Models.item
	for _, model in ipairs(candidates) do
		if util.IsValidModel(model) then return model end
	end
	return "models/props_lab/box01a.mdl"
end

local names = {
	drp_coca_wild = "Wild Coca Plant",
	drp_coca_pot = "Coca Growing Pot",
	drp_cocaine_bucket = "Mixing Bucket",
	drp_cocaine_petroleum = "Petroleum Can",
	drp_cocaine_hotplate = "Portable Hotplate",
	drp_narcotics_table = "Narcotics Table",
	drp_cocaine_buyer = "Narcotics Buyer",
	drp_cocaine_item = "Cocaine Material"
}

local modelKeys = {
	drp_coca_wild = "wild", drp_coca_pot = "pot", drp_cocaine_bucket = "bucket",
	drp_cocaine_petroleum = "petroleum", drp_cocaine_hotplate = "hotplate",
	drp_narcotics_table = "table", drp_cocaine_buyer = "buyer", drp_cocaine_item = "item"
}

local function entityStatus(entity)
	local class = entity:GetClass()
	if class == "drp_coca_wild" then
		return entity:GetNW2Bool("DRPCocaReady", true) and "Ready to harvest" or "Regrowing"
	elseif class == "drp_coca_pot" then
		local stage = entity:GetNW2Int("DRPCocaineStage", 0)
		return stage == 0 and "Insert a selected coca seed" or (stage == 1 and "Growing" or "Ready to harvest")
	elseif class == "drp_cocaine_bucket" then
		local stages = { "Add leaves and petroleum", "Ingredients loaded", "Mixed — place on hotplate", "Heating", "Ready to strain" }
		return stages[entity:GetNW2Int("DRPCocaineStage", 0) + 1] or "Processing"
	elseif class == "drp_cocaine_hotplate" then
		return IsValid(entity:GetNW2Entity("DRPCocaineBucket")) and "Batch heating — use to stir" or "Place a mixed bucket nearby"
	elseif class == "drp_narcotics_table" then return "Package, combine, split or strain"
	elseif class == "drp_cocaine_buyer" then return "Sell packaged cocaine"
	elseif class == "drp_cocaine_petroleum" then return "Use to store in Hands" end
	return entity:GetNW2String("DRPResourceLabel", "Material")
end

for class, title in pairs(names) do
	local entityClass, entityTitle, entityModelKey = class, title, modelKeys[class]
	local ENT = { Type = "anim", Base = "base_anim", PrintName = entityTitle, Spawnable = false }
	function ENT:Initialize()
		if not SERVER then return end
		if not util.IsValidModel(self:GetModel() or "") then self:SetModel(DRP.CocaineModel(entityModelKey)) end
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		local physics = self:GetPhysicsObject()
		if not IsValid(physics) then
			self:PhysicsInitBox(self:OBBMins(), self:OBBMaxs())
			self:SetSolid(SOLID_VPHYSICS)
			physics = self:GetPhysicsObject()
		end
		if IsValid(physics) then physics:EnableMotion(false) physics:Sleep() end
	end
	function ENT:Use(activator)
		if SERVER and DRP.Cocaine then DRP.Cocaine:Use(self, activator) end
	end
	if CLIENT then
		function ENT:Draw()
			self:DrawModel()
			local viewer = LocalPlayer()
			if not IsValid(viewer) or viewer:GetPos():DistToSqr(self:GetPos()) > 160000 then return end
			local position = self:LocalToWorld(Vector(0, 0, self:OBBMaxs().z + 8))
			local angle = Angle(0, EyeAngles().y - 90, 90)
			cam.Start3D2D(position, angle, 0.085)
				draw.RoundedBox(8, -170, -34, 340, 68, Color(9, 14, 23, 230))
				draw.RoundedBoxEx(8, -170, -34, 5, 68, Color(69, 205, 242), true, false, true, false)
				draw.SimpleText(entityTitle, "DRP.Admin.Header", 0, -11, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				draw.SimpleText(entityStatus(self), "DRP.Admin.Small", 0, 15, Color(160, 179, 201), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			cam.End3D2D()
		end
	end
	scripted_ents.Register(ENT, entityClass)
end
