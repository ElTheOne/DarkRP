local accent = Color(74, 205, 255)
local accentBright = Color(132, 241, 255)
local background = Color(9, 15, 28, 238)
local backgroundSoft = Color(16, 25, 45, 224)
local moneyColor = Color(108, 238, 151)
local doorClasses = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
local doorJobLabels = {}
local hudEnabled = CreateClientConVar("drp_hud_enabled", "1", true, false, "Show the DarkRP HUD")
local smoothXPProgress
local smoothHealthProgress
local smoothArmorProgress

local function configureARC9HUDCompatibility()
	if not istable(ARC9) then return end
	-- DarkRP owns the gameplay HUD. ARC9 keeps its scopes, crosshair and
	-- customization interface, but may not paint over or suppress our player HUD.
	ARC9.DisableGameplayHUD = true
	hook.Remove("HUDPaint", "ARC9_DrawHud")
	hook.Remove("HUDShouldDraw", "ARC9_HideHUD")
end

configureARC9HUDCompatibility()
hook.Add("InitPostEntity", "DRP.ARC9.HUDCompatibility", configureARC9HUDCompatibility)
hook.Add("OnReloaded", "DRP.ARC9.HUDCompatibility", configureARC9HUDCompatibility)
timer.Simple(0, configureARC9HUDCompatibility)
-- Workshop addons can remount after the player has entered the server. A cheap
-- periodic guard prevents that late mount from restoring ARC9's gameplay HUD.
timer.Create("DRP.ARC9.HUDCompatibility", 2, 0, configureARC9HUDCompatibility)

concommand.Add("drp_arc9_client_status", function()
	local modelPath = "models/weapons/csgo/c_rif_ak47.mdl"
	local materialPath = "models/csgo/ak47/ak47"
	local material = Material(materialPath)
	print(string.format(
		"[DRP ARC9 CLIENT] base=%s gsr_ak47=%s material=%s hud_hook=%s drp_hook=%s",
		tostring(istable(ARC9)),
		tostring(util.IsValidModel(modelPath)),
		tostring(material and not material:IsError()),
		tostring(isfunction((hook.GetTable().HUDPaint or {}).ARC9_DrawHud)),
		tostring(isfunction((hook.GetTable().PostDrawHUD or {})["DRP.HUD"]))
	))
end)

concommand.Add("drp_content_status", function()
	local checks = {
		{ "Portal Gun model", "models/weapons/c_portalgun.mdl", "model" }
	}

	print("[DRP CONTENT] Workshop content status")
	for _, check in ipairs(checks) do
		local available = check[3] == "model"
			and util.IsValidModel(check[2])
			or file.Exists(check[2], "GAME")
		print(string.format("  %-22s %s  %s", check[1], available and "OK" or "MISSING", check[2]))
	end

	local ply = LocalPlayer()
	local entity = IsValid(ply) and ply:GetEyeTrace().Entity or NULL
	if not IsValid(entity) or entity:IsWorld() then
		print("[DRP CONTENT] Look directly at an ERROR prop and run this command again to inspect it.")
		return
	end

	local model = entity:GetModel() or ""
	print(string.format(
		"[DRP CONTENT] aimed entity=%s class=%s model=%s valid_model=%s",
		tostring(entity),
		entity:GetClass(),
		model,
		tostring(model ~= "" and util.IsValidModel(model))
	))
	for _, materialPath in ipairs(entity:GetMaterials() or {}) do
		local material = Material(materialPath)
		print(string.format("  material=%s status=%s", materialPath, material and not material:IsError() and "OK" or "MISSING"))
	end
end)

local function doorJobLabel(mask)
	if not mask or mask == 0 then return nil end
	if doorJobLabels[mask] ~= nil then return doorJobLabels[mask] or nil end
	local names = {}
	for id, job in ipairs(DRP.Jobs) do
		if bit.band(mask, 2 ^ (id - 1)) ~= 0 then names[#names + 1] = job.name end
	end
	local label = table.concat(names, " / ")
	doorJobLabels[mask] = label ~= "" and label or false
	return label ~= "" and label or nil
end

local function eyeTrace(ply)
	return util.TraceLine({
		start = ply:EyePos(),
		endpos = ply:EyePos() + ply:GetAimVector() * 128,
		filter = ply,
		mask = MASK_SOLID
	})
end

local function xpNeededForNext(level)
	level = math.Clamp(math.floor(tonumber(level) or 1), 1, 100)
	if level >= 100 then return 0 end
	return math.max(1, math.ceil(110 * (1.07 ^ (level - 1))))
end

surface.CreateFont("DRP.HUD.Large", { font = "Roboto", size = 24, weight = 700 })
surface.CreateFont("DRP.HUD.Small", { font = "Roboto", size = 17, weight = 500 })
surface.CreateFont("DRP.HUD.XP", { font = "Roboto", size = 15, weight = 800 })
surface.CreateFont("DRP.HUD.Kicker", { font = "Roboto", size = 12, weight = 800 })

local function formatPlaytime(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local days = math.floor(seconds / 86400)
	local hours = math.floor(seconds / 3600) % 24
	local minutes = math.floor(seconds / 60) % 60
	local secs = seconds % 60
	if days > 0 then return string.format("%dd %02dh %02dm", days, hours, minutes) end
	if hours > 0 then return string.format("%02dh %02dm %02ds", hours, minutes, secs) end
	return string.format("%02dm %02ds", minutes, secs)
end

local function drawHeartIcon(centerX, centerY, color)
	draw.RoundedBox(5, centerX - 7, centerY - 5, 8, 8, color)
	draw.RoundedBox(5, centerX - 1, centerY - 5, 8, 8, color)
	draw.NoTexture()
	surface.SetDrawColor(color)
	surface.DrawPoly({
		{ x = centerX - 7, y = centerY - 1 },
		{ x = centerX + 7, y = centerY - 1 },
		{ x = centerX, y = centerY + 8 }
	})
end

local function drawShieldIcon(centerX, centerY, color)
	draw.NoTexture()
	surface.SetDrawColor(color)
	surface.DrawPoly({
		{ x = centerX - 7, y = centerY - 6 },
		{ x = centerX + 7, y = centerY - 6 },
		{ x = centerX + 6, y = centerY + 2 },
		{ x = centerX, y = centerY + 8 },
		{ x = centerX - 6, y = centerY + 2 }
	})
end

hook.Add("HUDShouldDraw", "DRP.HideStockHUD", function(name)
	if not hudEnabled:GetBool() then return end
	if name == "CHudHealth" or name == "CHudBattery" or name == "CHudTargetID"
		or name == "CHudAmmo" or name == "CHudSecondaryAmmo" or name == "CHudWeaponSelection" then return false end
end)

-- Sandbox paints its player target ID through a gamemode hook on some client
-- branches instead of CHudTargetID. Suppress that path as well so looking at a
-- player can never stack the stock name/health text over DRP's target card.
hook.Add("HUDDrawTargetID", "DRP.HideStockTargetID", function()
	return false
end)

-- Base gamemode and some HUD addons call the gamemode method directly instead
-- of respecting CHudTargetID/HUDShouldDraw. Own the method as well, otherwise
-- Sandbox's nickname and percentage health render underneath our target card.
local function suppressStockTargetID()
	return false
end

local function installTargetIDSuppression()
	if istable(GM) then GM.HUDDrawTargetID = suppressStockTargetID end
	if istable(GAMEMODE) then GAMEMODE.HUDDrawTargetID = suppressStockTargetID end
end

installTargetIDSuppression()
hook.Add("InitPostEntity", "DRP.HideStockTargetIDMethod", installTargetIDSuppression)
hook.Add("OnReloaded", "DRP.HideStockTargetIDMethod", installTargetIDSuppression)

local function weaponDisplayName(weapon)
	local name = tostring(IsValid(weapon) and weapon:GetPrintName() or "")
	if name == "" then return "WEAPON" end
	if string.StartWith(name, "#") then
		local translated = language.GetPhrase(string.sub(name, 2))
		if translated ~= "" then name = translated end
	end
	return string.upper(string.sub(name, 1, 28))
end

local function ammoValues(ply, weapon)
	if not IsValid(weapon) or weapon.DrawAmmo == false then return nil end

	local primaryType = tonumber(weapon:GetPrimaryAmmoType()) or -1
	local secondaryType = tonumber(weapon:GetSecondaryAmmoType()) or -1
	local clip = tonumber(weapon:Clip1()) or -1
	local reserve = primaryType >= 0 and ply:GetAmmoCount(primaryType) or 0
	local secondary = secondaryType >= 0 and ply:GetAmmoCount(secondaryType) or 0

	if isfunction(weapon.CustomAmmoDisplay) then
		local ok, custom = pcall(weapon.CustomAmmoDisplay, weapon)
		if ok and istable(custom) then
			if custom.Draw == false then return nil end
			clip = tonumber(custom.PrimaryClip) or clip
			reserve = tonumber(custom.PrimaryAmmo) or reserve
			secondary = tonumber(custom.SecondaryAmmo) or secondary
		end
	end

	if clip < 0 and primaryType < 0 and secondaryType < 0 then return nil end
	return math.max(-1, clip), math.max(0, reserve), math.max(0, secondary), secondaryType >= 0
end

local function drawAmmoCounter(ply, playerCardX, playerCardY, playerCardWidth, playerCardHeight)
	local weapon = ply:GetActiveWeapon()
	if not IsValid(weapon) then return end
	local clip, reserve, secondary, hasSecondary = ammoValues(ply, weapon)
	local selector = DRP.WeaponSelection
	local category = selector and selector.CategoryForWeapon and selector.CategoryForWeapon(weapon) or 3
	local categoryName = selector and selector.CategoryName and selector.CategoryName(category) or "ALT / JOB"
	local gap, desiredWidth, height = 12, 300, 94
	local x = playerCardX + playerCardWidth + gap
	local available = ScrW() - x - 20
	local width = math.min(desiredWidth, available)
	if width < 210 then return end
	local y = playerCardY + playerCardHeight - height

	draw.RoundedBox(9, x, y, width, height, background)
	draw.RoundedBoxEx(9, x, y, 5, height, accent, true, false, true, false)
	draw.SimpleText(tostring(category) .. "  " .. categoryName, "DRP.HUD.Kicker", x + 16, y + 15, accentBright, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText(weaponDisplayName(weapon), "DRP.HUD.Kicker", x + width - 14, y + 16,
		Color(160, 174, 195), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

	local primaryText = clip ~= nil and (clip >= 0 and string.Comma(clip) or string.Comma(reserve)) or "READY"
	draw.SimpleText(primaryText, "DRP.HUD.Large", x + 16, y + 46, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	if clip ~= nil and clip >= 0 then
		draw.SimpleText("/ " .. string.Comma(reserve), "DRP.HUD.Small", x + width - 14, y + 49,
			Color(160, 174, 195), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	elseif clip ~= nil and hasSecondary then
		draw.SimpleText("ALT " .. string.Comma(secondary), "DRP.HUD.Small", x + width - 14, y + 49,
			Color(160, 174, 195), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end

	local labels = { "P", "S", "ALT", "PRE", "BUILD" }
	local tabGap, tabY = 4, y + height - 24
	local tabWidth = (width - 30 - tabGap * 4) / 5
	for index = 1, 5 do
		local tabX = x + 15 + (index - 1) * (tabWidth + tabGap)
		local active = index == category
		draw.RoundedBox(4, tabX, tabY, tabWidth, 15, active and accent or Color(29, 42, 66, 245))
		draw.SimpleText(index .. " " .. labels[index], "DRP.HUD.Kicker", tabX + tabWidth * 0.5, tabY + 7,
			active and Color(5, 14, 25) or Color(145, 160, 184), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
end

hook.Add("PostDrawHUD", "DRP.HUD", function()
	if not hudEnabled:GetBool() then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local toolgunFocus = DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus()
	local profile = DRP.ClientProfile
	local job = DRP.Jobs[profile.job] or DRP.Jobs[DRP.Job.CITIZEN]
	local government = DRP.ClientGovernment or { taxRate = 0, allocations = {} }
	local bonusPercent = government.allocations[profile.job] or 0
	local salary = job.salary + math.floor(job.salary * bonusPercent / 100)
	salary = DRP.Supporter and DRP.Supporter.ApplyReward(LocalPlayer(), salary) or salary
	local agenda = job.agendaGroup and GetGlobalString("DRPAgenda." .. job.agendaGroup, "") or ""
	local sessionStarted = profile.sessionStartedAt or CurTime()
	local sessionTime = math.max(0, CurTime() - sessionStarted)
	local totalTime = (profile.totalPlaytimeBase or 0) + sessionTime
	if not toolgunFocus then
		local timeWidth, timeHeight = 286, 76
		draw.RoundedBox(10, 24, 22, timeWidth, timeHeight, background)
		draw.RoundedBoxEx(10, 24, 22, 5, timeHeight, accent, true, false, true, false)
		draw.RoundedBox(5, 40, 43, 92, 2, accentBright)
		draw.SimpleText("PLAYTIME", "DRP.HUD.Kicker", 40, 35, accentBright, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("Session", "DRP.HUD.Small", 40, 61, Color(175, 185, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(formatPlaytime(sessionTime), "DRP.HUD.Small", 294, 61, color_white, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		draw.SimpleText("Total", "DRP.HUD.Small", 40, 83, Color(175, 185, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(formatPlaytime(totalTime), "DRP.HUD.Small", 294, 83, moneyColor, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end
	local height = agenda ~= "" and 208 or 184
	local x, y, width = 24, ScrH() - height - 28, 380

	local hudLevel = profile.level or 1
	local xpNow = profile.xp or 0
	local xpMax = xpNeededForNext(hudLevel)
	local targetXPProgress = xpMax > 0 and math.Clamp(xpNow / xpMax, 0, 1) or 1
	if smoothXPProgress == nil then smoothXPProgress = targetXPProgress end
	smoothXPProgress = Lerp(math.Clamp(FrameTime() * 8, 0, 1), smoothXPProgress, targetXPProgress)

	draw.RoundedBox(10, x, y, width, height, background)
	draw.RoundedBoxEx(10, x, y, 6, height, job.color, true, false, true, false)
	draw.SimpleText(ply:DRPName(), "DRP.HUD.Large", x + 22, y + 20, color_white)
	draw.SimpleText(DRP.StateName[DRP.ClientState] or "LOADING", "DRP.HUD.Kicker", x + width - 20, y + 21, accentBright, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

	-- XP is deliberately self-contained: level and exact progress are readable inside the bar.
	local xpX, xpY, xpWidth, xpHeight = x + 22, y + 48, width - 44, 24
	draw.RoundedBox(8, xpX, xpY, xpWidth, xpHeight, Color(24, 36, 61, 255))
	local fillWidth = math.max(0, (xpWidth - 2) * smoothXPProgress)
	if fillWidth > 0 then draw.RoundedBox(8, xpX + 1, xpY + 1, fillWidth, xpHeight - 2, accent) end
	local xpText = hudLevel >= 100 and ("LVL 100   •   " .. string.Comma(xpNow) .. " XP") or ("LVL " .. hudLevel .. "   •   " .. string.Comma(xpNow) .. " / " .. string.Comma(xpMax) .. " XP")
	draw.SimpleText(xpText, "DRP.HUD.XP", xpX + xpWidth * 0.5, xpY + xpHeight * 0.5, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	local roleplayTime = DRP.Calendar and DRP.Calendar.Now and DRP.Calendar.Now() or os.time()
	draw.SimpleText(ply:DRPJobName(), "DRP.HUD.Small", x + 22, y + 84, job.color, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText(DRP.Calendar and DRP.Calendar.Format(roleplayTime, false) or os.date("%d %b %Y  •  %H:%M"),
		"DRP.HUD.Kicker", x + width - 20, y + 84, accentBright, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	draw.SimpleText("$" .. string.Comma(salary) .. " salary  •  " .. government.taxRate .. "% tax",
		"DRP.HUD.Small", x + 22, y + 106, Color(175, 185, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText("$" .. string.Comma(profile.money), "DRP.HUD.Large", x + 22, y + 129, moneyColor)

	local health = math.max(0, ply:Health())
	local armor = math.max(0, ply:Armor())
	local targetHealth = math.Clamp(health / math.max(1, ply:GetMaxHealth()), 0, 1)
	local targetArmor = math.Clamp(armor / math.max(100, armor), 0, 1)
	if smoothHealthProgress == nil then smoothHealthProgress = targetHealth end
	if smoothArmorProgress == nil then smoothArmorProgress = targetArmor end
	local lerpAmount = math.Clamp(FrameTime() * 8, 0, 1)
	smoothHealthProgress = Lerp(lerpAmount, smoothHealthProgress, targetHealth)
	smoothArmorProgress = Lerp(lerpAmount, smoothArmorProgress, targetArmor)
	local vitalY, vitalHeight, vitalGap = y + 154, 22, 8
	local vitalWidth = (width - 44 - vitalGap) * 0.5
	local healthX, armorX = x + 22, x + 22 + vitalWidth + vitalGap
	draw.RoundedBox(7, healthX, vitalY, vitalWidth, vitalHeight, Color(54, 27, 36, 245))
	draw.RoundedBox(7, healthX + 1, vitalY + 1, math.max(0, (vitalWidth - 2) * smoothHealthProgress), vitalHeight - 2, Color(232, 74, 91, 255))
	drawHeartIcon(healthX + vitalWidth * 0.5 - 20, vitalY + vitalHeight * 0.5, color_white)
	draw.SimpleText(health, "DRP.HUD.XP", healthX + vitalWidth * 0.5 + 9, vitalY + vitalHeight * 0.5, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	draw.RoundedBox(7, armorX, vitalY, vitalWidth, vitalHeight, Color(24, 39, 61, 245))
	draw.RoundedBox(7, armorX + 1, vitalY + 1, math.max(0, (vitalWidth - 2) * smoothArmorProgress), vitalHeight - 2, Color(65, 149, 245, 255))
	drawShieldIcon(armorX + vitalWidth * 0.5 - 20, vitalY + vitalHeight * 0.5, color_white)
	draw.SimpleText(armor, "DRP.HUD.XP", armorX + vitalWidth * 0.5 + 9, vitalY + vitalHeight * 0.5, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	if agenda ~= "" then draw.SimpleText("Agenda: " .. string.sub(agenda, 1, 46), "DRP.HUD.Small", x + 22, y + 190, Color(175, 185, 200)) end
	drawAmmoCounter(ply, x, y, width, height)
	local wanted = ply:GetNW2String("DRPWantedReason", "")
	if wanted ~= "" then draw.SimpleTextOutlined("WANTED — " .. wanted, "DRP.HUD.Small", x, y - 18, Color(255, 90, 90), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, color_black) end
	if ply:GetNW2Bool("DRPCuffed", false) then draw.SimpleTextOutlined("HANDCUFFED — IN POLICE CUSTODY", "DRP.HUD.Small", x, y - (wanted ~= "" and 40 or 18), Color(90, 180, 235), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, color_black)
	elseif ply:GetNW2Float("DRPTasedUntil", 0) > CurTime() then draw.SimpleTextOutlined("TASED — " .. math.ceil(ply:GetNW2Float("DRPTasedUntil", 0) - CurTime()) .. "s", "DRP.HUD.Small", x, y - (wanted ~= "" and 40 or 18), Color(90, 180, 235), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, color_black) end
	if toolgunFocus then return end

	local massieRemaining = math.max(0, ply:GetNW2Float("DRPMassieUntil", 0) - CurTime())
	if massieRemaining > 0 then
		local massieX, massieY, massieWidth, massieHeight = x + width + 10, y, 178, 58
		draw.RoundedBox(9, massieX, massieY, massieWidth, massieHeight, Color(34, 12, 19, 242))
		draw.RoundedBoxEx(9, massieX, massieY, 5, massieHeight, Color(244, 70, 91), true, false, true, false)
		draw.SimpleText("MASSIE ACTIVE", "DRP.HUD.Kicker", massieX + 16, massieY + 17, Color(255, 105, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(string.format("%.1fs", massieRemaining), "DRP.HUD.Large", massieX + 16, massieY + 40, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local trace = eyeTrace(ply)
	if IsValid(trace.Entity) and trace.Entity:IsPlayer() then
		local target = trace.Entity
		local targetWanted = target:GetNW2String("DRPWantedReason", "")
		local targetJob = target:DRPJob()
		local targetColor = targetJob and targetJob.color or accent
		local cardWidth = 340
		local cardHeight = targetWanted ~= "" and 120 or 94
		local cardX = math.floor(ScrW() * 0.5 - cardWidth * 0.5)
		local cardY = math.floor(ScrH() * 0.535)

		draw.RoundedBox(9, cardX, cardY, cardWidth, cardHeight, background)
		draw.RoundedBoxEx(9, cardX, cardY, 5, cardHeight, targetColor, true, false, true, false)
		draw.SimpleText(target:DRPName(), "DRP.HUD.Large", cardX + 18, cardY + 17, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		local custody = target:GetNW2Bool("DRPCuffed", false) and "  •  HANDCUFFED" or (target:GetNW2Float("DRPTasedUntil", 0) > CurTime() and "  •  TASED" or "")
		draw.SimpleText(target:DRPJobName() .. (target:GetNW2Bool("DRPGunLicense", false) and "  •  LICENSED" or "") .. custody,
			"DRP.HUD.Small", cardX + 18, cardY + 40,
			target:GetNW2Bool("DRPCuffed", false) and Color(90, 180, 235) or targetColor,
			TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

		local targetHealth = math.max(0, target:Health())
		local targetMaxHealth = math.max(1, target:GetMaxHealth())
		local healthX, healthY, healthWidth, healthHeight = cardX + 18, cardY + 57, cardWidth - 36, 24
		draw.RoundedBox(6, healthX, healthY, healthWidth, healthHeight, Color(54, 27, 36, 245))
		draw.RoundedBox(6, healthX + 1, healthY + 1,
			math.max(0, (healthWidth - 2) * math.Clamp(targetHealth / targetMaxHealth, 0, 1)),
			healthHeight - 2, Color(232, 74, 91, 255))
		drawHeartIcon(healthX + 16, healthY + healthHeight * 0.5, color_white)
		draw.SimpleText("HEALTH  " .. targetHealth .. " / " .. targetMaxHealth, "DRP.HUD.XP",
			healthX + healthWidth * 0.5, healthY + healthHeight * 0.5,
			color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

		if targetWanted ~= "" then
			draw.SimpleText("WANTED — " .. string.sub(targetWanted, 1, 42), "DRP.HUD.Small",
				cardX + 18, cardY + 103, Color(255, 90, 90), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end
	local door = trace.Entity
	if not ply:DRPReady() or not IsValid(door) or not doorClasses[door:GetClass()] or ply:GetPos():DistToSqr(door:GetPos()) > 16384 then return end

	local doorIndex = door:EntIndex()
	local propertyID = DRP.ClientDoorProperties and DRP.ClientDoorProperties[doorIndex]
	local property = propertyID and DRP.ClientProperties and DRP.ClientProperties[propertyID]
	if property then
		local label
		if property.owner == "Unowned" then
			label = property.buyable and (property.name .. " — Unowned — F to purchase ($" .. string.Comma(property.price) .. ")")
				or (property.name .. " — Not available for purchase")
		elseif property.role ~= "none" then
			label = property.name .. " — " .. string.upper(property.role) .. " access"
			local eviction = math.max(0, math.ceil((property.evictionDeadline or 0) - RealTime()))
			if eviction > 0 then label = label .. " — eviction in " .. eviction .. "s" end
		else
			label = property.name .. " — Owned by " .. property.owner
		end
		draw.SimpleTextOutlined(label, "DRP.HUD.Large", ScrW() * 0.5, ScrH() * 0.58, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
		return
	end
	local owner = Entity(DRP.ClientDoors[doorIndex] or 0)
	local policy = DRP.ClientDoorPolicies[doorIndex] or { ownable = true, jobs = 0 }
	local jobLabel = doorJobLabel(policy.jobs)
	local label

	if IsValid(owner) then
		label = owner == ply and "Your door — F to sell" or "Owned by " .. owner:Nick()
		if jobLabel then label = "Job door — " .. jobLabel .. "  •  " .. label end
	elseif jobLabel then
		local allowed = bit.band(policy.jobs, 2 ^ math.max(0, profile.job - 1)) ~= 0
		label = "Job door — " .. jobLabel
		if policy.ownable and allowed then label = label .. "  •  F to buy ($100)" end
	elseif policy.ownable then
		label = "Unowned — F to buy ($100)"
	else
		return
	end

	draw.SimpleTextOutlined(label, "DRP.HUD.Large", ScrW() * 0.5, ScrH() * 0.58, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
end)
