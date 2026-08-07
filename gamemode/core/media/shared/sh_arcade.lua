DRP.ArcadeWorkshopID = "1788979547"
DRP.ArcadeCabinetModel = "models/antmodels/objects/arcademachine/arcademachine.mdl"
DRP.ArcadeFallbackModel = "models/props_c17/consolebox01a.mdl"

DRP.ArcadeMessages = {
	OPEN = "drp_arcade_open_v1",
	START = "drp_arcade_start_v1",
	SESSION = "drp_arcade_session_v1",
	EXIT = "drp_arcade_exit_v1",
	WATCH = "drp_arcade_watch_v1",
	STREAM = "drp_arcade_stream_v1",
	FRAME = "drp_arcade_frame_v1"
}

-- Cabinets are infrastructure. The owner places and persists them; players
-- select games from the server-owned catalogue by pressing E.
local arcadeDefinition = {
	key = "arcade_cabinet",
	name = "N64 Arcade Cabinet",
	class = "drp_arcade_cabinet",
	model = DRP.ArcadeCabinetModel,
	ownerOnly = true,
	price = 0,
	countLimit = 16,
	category = "Server Infrastructure"
}

local hasArcadeDefinition = false
for _, definition in ipairs(DRP.JobEntities or {}) do
	if definition.key == arcadeDefinition.key then
		hasArcadeDefinition = true
		break
	end
end
if not hasArcadeDefinition then
	DRP.JobEntities[#DRP.JobEntities + 1] = arcadeDefinition
	if DRP.DropPolicy then DRP.DropPolicy.nonDroppableJobEntities[arcadeDefinition.class] = true end
end

local cabinet = {
	Type = "anim",
	Base = "base_anim",
	PrintName = "N64 Arcade Cabinet",
	Spawnable = false,
	AdminOnly = true,
	Model = DRP.ArcadeCabinetModel
}

function cabinet:SetupDataTables()
	self:NetworkVar("Entity", 0, "ArcadeController")
	self:NetworkVar("String", 0, "ArcadeGameTitle")
	self:NetworkVar("Int", 0, "ArcadeViewerCount")
end

function cabinet:Initialize()
	if not SERVER then return end
	local model = util.IsValidModel(self.Model) and self.Model or DRP.ArcadeFallbackModel
	self:SetModel(model)
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetUseType(SIMPLE_USE)
	self:SetArcadeGameTitle("")
	self:SetArcadeViewerCount(0)
	local physics = self:GetPhysicsObject()
	if IsValid(physics) then
		physics:EnableMotion(false)
		physics:EnableGravity(false)
		physics:Sleep()
	end
end

function cabinet:Use(activator)
	if SERVER and DRP.Arcade then DRP.Arcade:Use(self, activator) end
end

function cabinet:OnRemove()
	if SERVER and DRP.Arcade then DRP.Arcade:RemoveMachine(self) end
	if CLIENT and DRP.ArcadeClient then DRP.ArcadeClient:RemoveMachine(self) end
end

if CLIENT then
	function cabinet:Draw()
		if DRP.ArcadeClient then
			DRP.ArcadeClient:DrawMachine(self)
		else
			self:DrawModel()
		end
	end
end

scripted_ents.Register(cabinet, "drp_arcade_cabinet")
