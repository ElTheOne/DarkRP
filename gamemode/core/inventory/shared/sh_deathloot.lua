DRP.DeathLootMessages = DRP.DeathLootMessages or {
	OPEN = "drp_death_loot_open_v1",
	ACTION = "drp_death_loot_action_v1"
}

local ENT = {
	Type = "anim",
	Base = "base_anim",
	PrintName = "Death Suitcase",
	Spawnable = false,
	Model = "models/props_c17/SuitCase_Passenger_Physics.mdl"
}

function ENT:Initialize()
	if not SERVER then return end
	self:SetModel(self.Model)
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	self:SetUseType(SIMPLE_USE)
	local physics = self:GetPhysicsObject()
	if IsValid(physics) then
		physics:EnableGravity(false)
		physics:EnableMotion(false)
		physics:Sleep()
	end
end

function ENT:Use(activator)
	if SERVER and DRP.DeathLoot then DRP.DeathLoot:Open(activator, self) end
end

function ENT:Draw()
	self:DrawModel()
end

scripted_ents.Register(ENT, "drp_death_suitcase")
