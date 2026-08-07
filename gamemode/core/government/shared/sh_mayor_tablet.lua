local CLASS = "weapon_drp_mayor_tablet"
local definition = {
	Base = "ephone",
	PrintName = "Mayoral Records Tablet",
	Author = "DarkRP Foundation",
	Purpose = "A larger government ePhone with access to the police database.",
	Instructions = "Primary fire activates the cursor. Reload resets the device.",
	Category = "Government Utilities",
	Spawnable = false,
	AdminSpawnable = false,
	AdminOnly = false,
	UseHands = true,
	DrawAmmo = false,
	DrawCrosshair = false,
	-- The first-person model has both hand bones; the camera hold type also
	-- gives remote players a two-handed presentation instead of a pistol pose.
	HoldType = "camera",
	ViewModelFOV = 90,
	Slot = 2,
	SlotPos = 2,

	-- Reuse the complete ePhone software stack, but present it on genuine
	-- tablet hardware. This viewmodel contains animated left and right hands.
	ViewModel = Model("models/zerochain/props_weedfarm/zwf_tablet_vm.mdl"),
	WorldModel = Model("models/zerochain/props_weedfarm/zwf_tablet.mdl"),
	DRPTabletHardware = true,
	DRPTabletScreen = {
		-- These are tablet_main bone-local coordinates. Following the animated
		-- bone keeps the interface attached during both draw and idle sequences.
		bone = "tablet_main",
		center = Vector(0, 0, 0.015),
		-- Both in-plane axes are reversed to match the model's screen UVs.
		horizontal = Vector(0, 1, 0),
		vertical = Vector(1, 0, 0),
		normal = Vector(0, 0, 1),
		scale = 0.01285,
		surfaceOffset = 0.06,
		canvasWidth = 970,
		canvasHeight = 725
	},
	DRPPhoneDeviceContext = "mayor_tablet",

	Primary = {
		ClipSize = -1,
		DefaultClip = -1,
		Automatic = false,
		Ammo = "none"
	},
	Secondary = {
		ClipSize = -1,
		DefaultClip = -1,
		Automatic = false,
		Ammo = "none"
	}
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

	-- A scripted weapon registered from the gamemode can be created before an
	-- addon base has finished merging its realm-specific methods. Delegate the
	-- ePhone presentation/input methods explicitly so this SWEP cannot end up
	-- with only ephone/shared.lua and a dead baked tablet display.
	function definition:PostDrawViewModel(...)
		return callEPhone("PostDrawViewModel", self, ...)
	end

	function definition:GetViewModelPosition(...)
		return callEPhone("GetViewModelPosition", self, ...)
	end

	function definition:PrimaryAttack(...)
		return callEPhone("PrimaryAttack", self, ...)
	end

	function definition:SecondaryAttack(...)
		return callEPhone("SecondaryAttack", self, ...)
	end

	function definition:Reload(...)
		return callEPhone("Reload", self, ...)
	end

	function definition:Holster(...)
		local result = callEPhone("Holster", self, ...)
		return result == nil and true or result
	end

	function definition:OnRemove(...)
		return callEPhone("OnRemove", self, ...)
	end
end

if SERVER then
	util.PrecacheModel(definition.ViewModel)
	util.PrecacheModel(definition.WorldModel)

	function definition:Deploy()
		local owner = self:GetOwner()
		if not IsValid(owner) or not owner.DRPJob or owner:DRPJob().key ~= "mayor" then
			timer.Simple(0, function()
				if IsValid(self) then self:Remove() end
			end)
			return false
		end
		self:SendWeaponAnim(ACT_VM_DRAW)
		local timerName = "DRP.MayorTablet.Idle." .. self:EntIndex()
		timer.Remove(timerName)
		timer.Create(timerName, 0.66, 1, function()
			if IsValid(self) and IsValid(self:GetOwner()) then
				self:SendWeaponAnim(ACT_VM_IDLE)
			end
		end)
		return true
	end

	function definition:Holster()
		timer.Remove("DRP.MayorTablet.Idle." .. self:EntIndex())
		return true
	end

	function definition:OnRemove()
		timer.Remove("DRP.MayorTablet.Idle." .. self:EntIndex())
	end
end

weapons.Register(definition, CLASS)
