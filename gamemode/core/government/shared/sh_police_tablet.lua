local CLASS = "weapon_drp_police_tablet"
local definition = {
	Base = "ephone",
	PrintName = "Police Operations Tablet",
	Author = "DarkRP Foundation",
	Purpose = "A secure police terminal for live incidents, records and field operations.",
	Instructions = "Primary fire activates the cursor. Secondary fire focuses the tablet. Reload resets it.",
	Category = "Government Utilities",
	Spawnable = false,
	AdminSpawnable = false,
	AdminOnly = false,
	UseHands = true,
	DrawAmmo = false,
	DrawCrosshair = false,
	HoldType = "camera",
	ViewModelFOV = 90,
	Slot = 2,
	SlotPos = 3,
	ViewModel = Model("models/zerochain/props_weedfarm/zwf_tablet_vm.mdl"),
	WorldModel = Model("models/zerochain/props_weedfarm/zwf_tablet.mdl"),
	DRPTabletHardware = true,
	DRPTabletInterface = "PoliceTablet",
	DRPTabletView = {
		idleUp = 10.5,
		focusedUp = 10.5,
		idleRight = 0,
		focusedRight = 0,
		idleBack = 0,
		focusedBack = 0.75,
		focusedPitch = 0,
		focusedRoll = 0,
		focusedFOV = 60,
		directCameraAnchor = false,
		autoFit = false,
		viewportMarginX = 0.025,
		viewportMarginY = 0.035,
		bezelAllowanceX = 0.11,
		bezelAllowanceY = 0.12,
		fitPositionResponse = 1
	},
	DRPTabletScreen = {
		bone = "tablet_main",
		center = Vector(0, 0, 0.015),
		horizontal = Vector(0, 1, 0),
		vertical = Vector(1, 0, 0),
		normal = Vector(0, 0, 1),
		scale = 0.01285,
		surfaceOffset = 0.06,
		canvasWidth = 1080,
		canvasHeight = 760
	},
	DRPPhoneDeviceContext = "police_tablet",
	Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
	Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
}

function definition:ShouldDropOnDie()
	return false
end

function definition:Initialize()
	self:SetHoldType(self.HoldType)
end

if CLIENT then
	local function callEPhone(method, weapon, ...)
		local base = weapons.GetStored("ephone")
		local callback = istable(base) and base[method]
		if not isfunction(callback) then return end
		return callback(weapon, ...)
	end

	function definition:PostDrawViewModel(...) return callEPhone("PostDrawViewModel", self, ...) end
	function definition:PreDrawViewModel(...) return callEPhone("PreDrawViewModel", self, ...) end
	function definition:GetViewModelPosition(...) return callEPhone("GetViewModelPosition", self, ...) end
	function definition:PrimaryAttack(...) return callEPhone("PrimaryAttack", self, ...) end
	function definition:SecondaryAttack(...) return callEPhone("SecondaryAttack", self, ...) end
	function definition:Reload(...) return callEPhone("Reload", self, ...) end
	function definition:Holster(...)
		local result = callEPhone("Holster", self, ...)
		return result == nil and true or result
	end
	function definition:OnRemove(...) return callEPhone("OnRemove", self, ...) end
end

if SERVER then
	util.PrecacheModel(definition.ViewModel)
	util.PrecacheModel(definition.WorldModel)

	function definition:Deploy()
		local owner = self:GetOwner()
		local job = IsValid(owner) and owner.DRPJob and owner:DRPJob() or nil
		if not job or job.isPolice ~= true then
			timer.Simple(0, function()
				if IsValid(self) then self:Remove() end
			end)
			return false
		end
		self:SendWeaponAnim(ACT_VM_DRAW)
		local timerName = "DRP.PoliceTablet.Idle." .. self:EntIndex()
		timer.Remove(timerName)
		timer.Create(timerName, 0.66, 1, function()
			if IsValid(self) and IsValid(self:GetOwner()) then self:SendWeaponAnim(ACT_VM_IDLE) end
		end)
		return true
	end

	function definition:Holster()
		timer.Remove("DRP.PoliceTablet.Idle." .. self:EntIndex())
		return true
	end

	function definition:OnRemove()
		timer.Remove("DRP.PoliceTablet.Idle." .. self:EntIndex())
	end
end

weapons.Register(definition, CLASS)
