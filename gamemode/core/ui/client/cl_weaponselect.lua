local Selection = {
	LastCategory = 0,
	LastClass = "",
	SelectedAt = 0
}

DRP.WeaponSelection = Selection

local categoryNames = {
	[1] = "PRIMARY",
	[2] = "SECONDARY",
	[3] = "ALT ITEMS",
	[4] = "PRESTIGE",
	[5] = "BUILDING"
}

local buildingOrder = {
	weapon_drp_keys = 1,
	weapon_drp_pocket = 2,
	weapon_physgun = 3,
	weapon_physcannon = 4,
	gmod_tool = 5,
	weapon_drp_creator = 6,
	weapon_drp_persistence_tool = 7,
	gmod_camera = 8,
	ephone = 9
}

local altSlotOrder = {
	alt1 = 1,
	alt2 = 2,
	alt3 = 3,
	alt4 = 4,
	alt5 = 5,
	alt6 = 6
}

local function normalizedClass(value)
	return string.lower(string.Trim(tostring(value or "")))
end

local function itemByID(itemID)
	for _, item in ipairs((DRP.InventoryUI and DRP.InventoryUI.Items) or {}) do
		if tostring(item.id or "") == tostring(itemID or "") then return item end
	end
end

local function equippedClasses()
	local classes, slots = {}, {}
	for slot, itemID in pairs((DRP.InventoryUI and DRP.InventoryUI.Equipped) or {}) do
		local item = itemByID(itemID)
		if item and item.kind == "weapon" then
			local class = normalizedClass(item.class)
			if class ~= "" then classes[class], slots[class] = slot, altSlotOrder[slot] end
		end
	end
	return classes, slots
end

local function prestigeClasses()
	local output = {}
	for _, rawClass in ipairs((DRP.ClientProfile and DRP.ClientProfile.prestigeItems) or {}) do
		local class = normalizedClass(rawClass)
		if class ~= "" then output[class] = true end
	end
	return output
end

function Selection.CategoryName(category)
	return categoryNames[tonumber(category) or 0] or "WEAPON"
end

function Selection.CategoryForClass(class)
	class = normalizedClass(class)
	if class == "" then return 3 end
	local equipped = equippedClasses()
	if equipped[class] == "primary" then return 1 end
	if equipped[class] == "secondary" then return 2 end
	if equipped[class] and string.StartWith(equipped[class], "alt") then return 3 end
	if prestigeClasses()[class] then return 4 end
	if buildingOrder[class] then return 5 end
	-- Role and job loadout weapons remain reachable without consuming a Hands slot.
	return 3
end

function Selection.CategoryForWeapon(weapon)
	return IsValid(weapon) and Selection.CategoryForClass(weapon:GetClass()) or 3
end

local function weaponName(weapon)
	local name = tostring(IsValid(weapon) and weapon:GetPrintName() or "")
	if string.StartWith(name, "#") then name = language.GetPhrase(string.sub(name, 2)) end
	return string.lower(name ~= "" and name or (IsValid(weapon) and weapon:GetClass() or ""))
end

function Selection.Weapons(category)
	local ply = LocalPlayer()
	if not IsValid(ply) then return {} end
	category = math.Clamp(math.floor(tonumber(category) or 3), 1, 5)
	local equipped, altOrder = equippedClasses()
	local prestige = prestigeClasses()
	local output = {}
	for _, weapon in ipairs(ply:GetWeapons()) do
		if IsValid(weapon) and Selection.CategoryForClass(weapon:GetClass()) == category then output[#output + 1] = weapon end
	end
	table.sort(output, function(first, second)
		local firstClass, secondClass = normalizedClass(first:GetClass()), normalizedClass(second:GetClass())
		local firstOrder, secondOrder = 1000, 1000
		if category == 1 then firstOrder, secondOrder = equipped[firstClass] == "primary" and 1 or 2, equipped[secondClass] == "primary" and 1 or 2
		elseif category == 2 then firstOrder, secondOrder = equipped[firstClass] == "secondary" and 1 or 2, equipped[secondClass] == "secondary" and 1 or 2
		elseif category == 3 then firstOrder, secondOrder = altOrder[firstClass] or 100, altOrder[secondClass] or 100
		elseif category == 4 then firstOrder, secondOrder = prestige[firstClass] and 1 or 2, prestige[secondClass] and 1 or 2
		elseif category == 5 then firstOrder, secondOrder = buildingOrder[firstClass] or 100, buildingOrder[secondClass] or 100 end
		if firstOrder == secondOrder then return weaponName(first) < weaponName(second) end
		return firstOrder < secondOrder
	end)
	return output
end

local function selectWeapon(weapon, category)
	if not IsValid(weapon) then return false end
	input.SelectWeapon(weapon)
	Selection.LastCategory = category or Selection.CategoryForWeapon(weapon)
	Selection.LastClass = normalizedClass(weapon:GetClass())
	Selection.SelectedAt = RealTime()
	hook.Run("DRPWeaponSelected", weapon, Selection.LastCategory)
	return true
end

function Selection.SelectCategory(category)
	local weapons = Selection.Weapons(category)
	if #weapons == 0 then return false end
	local ply, current = LocalPlayer(), 0
	local active = IsValid(ply) and ply:GetActiveWeapon() or NULL
	for index, weapon in ipairs(weapons) do if weapon == active then current = index break end end
	-- Category keys select immediately; repeated presses cycle that category.
	local nextIndex = current > 0 and current % #weapons + 1 or 1
	return selectWeapon(weapons[nextIndex], category)
end

function Selection.Cycle(direction)
	local ordered = {}
	for category = 1, 5 do
		for _, weapon in ipairs(Selection.Weapons(category)) do ordered[#ordered + 1] = { weapon = weapon, category = category } end
	end
	if #ordered == 0 then return false end
	local active, current = LocalPlayer():GetActiveWeapon(), 0
	for index, entry in ipairs(ordered) do if entry.weapon == active then current = index break end end
	local nextIndex
	if direction < 0 then nextIndex = current > 1 and current - 1 or #ordered
	else nextIndex = current > 0 and current % #ordered + 1 or 1 end
	return selectWeapon(ordered[nextIndex].weapon, ordered[nextIndex].category)
end

local function gameplayInputAvailable()
	if gui.IsGameUIVisible() or gui.IsConsoleVisible() then return false end
	if vgui.CursorVisible() then return false end
	return not IsValid(vgui.GetKeyboardFocus())
end

hook.Add("PlayerBindPress", "DRP.WeaponSelection.Instant", function(ply, bind, pressed)
	if ply ~= LocalPlayer() or not pressed or not gameplayInputAvailable() then return end
	local command = string.match(string.lower(string.Trim(tostring(bind or ""))), "^(%S+)") or ""
	if command == "invnext" then Selection.Cycle(1) return true end
	if command == "invprev" then Selection.Cycle(-1) return true end
	local slot = tonumber(string.match(command, "^slot(%d+)$"))
	if slot then
		if slot >= 1 and slot <= 5 then Selection.SelectCategory(slot) end
		-- Suppress every stock slot bind so Source cannot reopen its selector.
		return true
	end
end)

hook.Add("HUDShouldDraw", "DRP.WeaponSelection.HideStock", function(name)
	if name == "CHudWeaponSelection" then return false end
end)

concommand.Add("drp_weapon_selection_status", function()
	local active = LocalPlayer():GetActiveWeapon()
	print(string.format("[DRP WEAPONS] active=%s category=%d/%s inventory=%d prestige=%d",
		IsValid(active) and active:GetClass() or "none",
		Selection.CategoryForWeapon(active), Selection.CategoryName(Selection.CategoryForWeapon(active)),
		#((DRP.InventoryUI and DRP.InventoryUI.Items) or {}),
		#((DRP.ClientProfile and DRP.ClientProfile.prestigeItems) or {})))
	for category = 1, 5 do
		local classes = {}
		for _, weapon in ipairs(Selection.Weapons(category)) do classes[#classes + 1] = weapon:GetClass() end
		print(string.format("  %d %-10s %s", category, Selection.CategoryName(category), table.concat(classes, ", ")))
	end
end)
