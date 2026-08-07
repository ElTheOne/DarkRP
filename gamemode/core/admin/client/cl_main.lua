local UI = DRP.UI
local colors = UI.Colors
local modernButton = UI.Button
local modernFrame = UI.Frame
local sectionLabel = UI.SectionLabel

DRP.ClientAdminMask = DRP.ClientAdminMask or 0
DRP.ClientOwner = DRP.ClientOwner or false
DRP.ClientAdminRank = DRP.ClientAdminRank or "user"
DRP.ClientAdminBaseRank = DRP.ClientAdminBaseRank or "user"
DRP.ClientTrustedFlag = DRP.ClientTrustedFlag or false
DRP.ClientVIPFlag = DRP.ClientVIPFlag or false
DRP.ClientVIPAccess = DRP.ClientVIPAccess or false
DRP.ClientSupporterTier = DRP.ClientSupporterTier or 0

local adminFrame
local adminPreferredPage = "users"
local adminHealthSnapshot
local healthRefreshCallback
local economyHealthSnapshot
local economyHealthRefreshCallback

DRP.AdminUI = DRP.AdminUI or {}
function DRP.AdminUI.CloseAll()
	if IsValid(adminFrame) then adminFrame:Close() end
	if DRP.AdminUI.CloseDoors then DRP.AdminUI.CloseDoors() end
	if DRP.AdminUI.CloseAudit then DRP.AdminUI.CloseAudit() end
end

function DRP.AdminUI.IsOpen()
	return IsValid(adminFrame)
end

local function hasPermission(permission)
	return DRP.ClientOwner or DRP.AdminMaskHas(DRP.ClientAdminMask, permission)
end

net.Receive("drp_admin_access_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	DRP.ClientAdminRank = DRP.AdminRank(net.ReadString()).key
	DRP.ClientAdminMask = net.ReadUInt(32)
	DRP.ClientOwner = net.ReadBool()
	DRP.ClientAdminBaseRank = DRP.AdminRank(net.ReadString()).key
	DRP.ClientTrustedFlag = net.ReadBool()
	DRP.ClientSupporterTier = net.ReadUInt(2)
	DRP.ClientVIPFlag = DRP.ClientSupporterTier > 0
	DRP.ClientVIPAccess = net.ReadBool()
	if not hasPermission("panel") and not hasPermission("server_interactions") and IsValid(adminFrame) then adminFrame:Close() end
	if not hasPermission("doors") and DRP.AdminUI.CloseDoors then DRP.AdminUI.CloseDoors() end
	if not hasPermission("logs") and DRP.AdminUI.CloseAudit then DRP.AdminUI.CloseAudit() end
end)

net.Receive("drp_admin_health_snapshot_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local snapshot = {
		uptime = net.ReadUInt(32), players = net.ReadUInt(8), maxPlayers = net.ReadUInt(8), tickrate = net.ReadUInt(10),
		entities = net.ReadUInt(16), incidents = net.ReadUInt(16), deadlines = net.ReadUInt(16), memory = net.ReadUInt(32),
		database = net.ReadBool(), dbQueue = net.ReadUInt(16), dbErrors = net.ReadUInt(16), dbError = net.ReadString(),
		auditQueue = net.ReadUInt(16), netMessages = net.ReadUInt(32), netBytes = net.ReadUInt(32),
		props = net.ReadUInt(16), propWeight = net.ReadUInt(32),
		dbPlayerLoads = net.ReadUInt(8), dbPocketLoads = net.ReadUInt(8), catalogTransfers = net.ReadUInt(8),
		arcExplosives = net.ReadUInt(8), arcAreaEffects = net.ReadUInt(8), arcPhysBullets = net.ReadUInt(16), services = {}
	}
	for index = 1, net.ReadUInt(6) do
		snapshot.services[index] = { name = net.ReadString(), started = net.ReadBool(), error = net.ReadString() }
	end
	adminHealthSnapshot = snapshot
	if healthRefreshCallback then healthRefreshCallback() end
end)

net.Receive("drp_economy_health_snapshot_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length = math.min(net.ReadUInt(20), 1048575)
	local compressed = net.ReadData(length) or ""
	local decoded = util.JSONToTable(util.Decompress(compressed) or "")
	if not istable(decoded) then return end
	economyHealthSnapshot = decoded
	if economyHealthRefreshCallback then economyHealthRefreshCallback() end
end)

local function sendAdminAction(actionID, entityIndex)
	net.Start("drp_admin_action_v1")
	net.WriteUInt(actionID, 3)
	net.WriteUInt(entityIndex, 13)
	net.SendToServer()
end

local function sendPunishment(action, target, offenseOrID)
	net.Start("drp_admin_punishment_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(action, 2)
	if action == 3 then
		net.WriteUInt(math.max(math.floor(tonumber(offenseOrID) or 0), 0), 32)
	else
		net.WriteString(string.sub(string.Trim(tostring(target or "")), 1, 96))
		net.WriteString(string.sub(tostring(offenseOrID or ""), 1, 160))
	end
	net.SendToServer()
end

local function openOfflineBlacklistDialog()
	if not hasPermission("blacklists") then return end
	local frame = modernFrame("Blacklist Offline User", 590, 350)

	local explanation = vgui.Create("DLabel", frame)
	explanation:SetPos(24, 76)
	explanation:SetSize(frame:GetWide() - 48, 46)
	explanation:SetFont("DRP.Admin.Small")
	explanation:SetTextColor(colors.muted)
	explanation:SetWrap(true)
	explanation:SetText("Accepts SteamID (STEAM_0:X:Y), SteamID3 ([U:1:Z]), SteamID64, or a Steam Community /profiles/ URL. The blacklist takes effect during authentication.")

	local steamID = vgui.Create("DTextEntry", frame)
	steamID:SetPos(24, 132)
	steamID:SetSize(frame:GetWide() - 48, 40)
	steamID:SetFont("DRP.Admin.Body")
	steamID:SetTextColor(color_white)
	steamID:SetCursorColor(color_white)
	steamID:SetPlaceholderText("Steam identifier")
	steamID:SetUpdateOnType(true)
	steamID.Paint = function(self, width, height)
		draw.RoundedBox(6, 0, 0, width, height, colors.panel)
		self:DrawTextEntryText(color_white, colors.accent, color_white)
	end

	local offense = vgui.Create("DTextEntry", frame)
	offense:SetPos(24, 184)
	offense:SetSize(frame:GetWide() - 48, 70)
	offense:SetFont("DRP.Admin.Body")
	offense:SetTextColor(color_white)
	offense:SetCursorColor(color_white)
	offense:SetPlaceholderText("Blacklist reason")
	offense:SetMultiline(true)
	offense:SetUpdateOnType(true)
	offense.Paint = function(self, width, height)
		draw.RoundedBox(6, 0, 0, width, height, colors.panel)
		self:DrawTextEntryText(color_white, colors.accent, color_white)
	end

	local submit = modernButton(frame, "BLACKLIST OFFLINE USER", colors.red, function()
		local identifier = string.Trim(steamID:GetValue() or "")
		local reason = string.Trim(offense:GetValue() or "")
		if identifier == "" then steamID:RequestFocus() return end
		if reason == "" then offense:RequestFocus() return end
		Derma_Query(
			"Permanently blacklist " .. identifier .. "?\n\nOffense: " .. reason,
			"Confirm Offline Blacklist",
			"BLACKLIST", function()
				sendPunishment(2, identifier, reason)
				if IsValid(frame) then frame:Close() end
			end,
			"CANCEL"
		)
	end)
	submit:SetPos(24, 274)
	submit:SetSize(frame:GetWide() - 48, 46)
	timer.Simple(0, function() if IsValid(steamID) then steamID:RequestFocus() end end)
end

local function sendEntitlementUpdate(identifier, flag, enabled)
	net.Start("drp_admin_entitlement_update_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(string.sub(string.Trim(tostring(identifier or "")), 1, 96))
	net.WriteBool(flag == "vip")
	net.WriteBool(enabled == true)
	net.SendToServer()
end

local function sendSupporterTierUpdate(identifier, tier)
	net.Start("drp_admin_supporter_tier_update_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(string.sub(string.Trim(tostring(identifier or "")), 1, 96))
	net.WriteUInt(DRP.Supporter.Normalize(tier), 2)
	net.SendToServer()
end

local function openOfflineEntitlementDialog()
	if DRP.AdminRankLevel(DRP.ClientAdminBaseRank) < DRP.AdminRankLevel("admin") then return end
	local frame = modernFrame("Manage Offline Entitlements", 620, 350)
	local explanation = vgui.Create("DLabel", frame)
	explanation:SetPos(24, 76)
	explanation:SetSize(frame:GetWide() - 48, 44)
	explanation:SetFont("DRP.Admin.Small")
	explanation:SetTextColor(colors.muted)
	explanation:SetWrap(true)
	explanation:SetText("Enter any SteamID format. Granting Trusted performs a live Discord role lookup and fails closed if verification is unavailable.")

	local steamID = vgui.Create("DTextEntry", frame)
	steamID:SetPos(24, 128)
	steamID:SetSize(frame:GetWide() - 48, 40)
	steamID:SetFont("DRP.Admin.Body")
	steamID:SetTextColor(color_white)
	steamID:SetCursorColor(color_white)
	steamID:SetPlaceholderText("SteamID, SteamID3, SteamID64, or profile URL")
	steamID.Paint = function(self, width, height)
		draw.RoundedBox(6, 0, 0, width, height, colors.panel)
		self:DrawTextEntryText(color_white, colors.accent, color_white)
	end

	local actions = {
		{ label = "GRANT TRUSTED", flag = "trusted", enabled = true, color = colors.green },
		{ label = "REVOKE TRUSTED", flag = "trusted", enabled = false, color = colors.red }
	}
	if DRP.AdminRankLevel(DRP.ClientAdminBaseRank) >= DRP.AdminRankLevel("headadmin") then
		actions[#actions + 1] = { label = "SET VIP", tier = 1, color = colors.accent }
		actions[#actions + 1] = { label = "SET VIP+", tier = 2, color = Color(255, 175, 115) }
		actions[#actions + 1] = { label = "SET SUPPORTER", tier = 3, color = Color(255, 140, 80) }
		actions[#actions + 1] = { label = "CLEAR TIER", tier = 0, color = colors.red }
	end
	local gap, columns = 8, 3
	local buttonWidth = math.floor((frame:GetWide() - 48 - gap * (columns - 1)) / columns)
	for index, action in ipairs(actions) do
		local data = action
		local button = modernButton(frame, data.label, data.color, function()
			local identifier = string.Trim(steamID:GetValue() or "")
			if identifier == "" then steamID:RequestFocus() return end
			if data.tier ~= nil then sendSupporterTierUpdate(identifier, data.tier)
			else sendEntitlementUpdate(identifier, data.flag, data.enabled) end
		end)
		local column, row = (index - 1) % columns, math.floor((index - 1) / columns)
		button:SetPos(24 + column * (buttonWidth + gap), 190 + row * 52)
		button:SetSize(buttonWidth, 44)
	end
	timer.Simple(0, function() if IsValid(steamID) then steamID:RequestFocus() end end)
end

local function sendAdminModeAction(action, target, amount)
	if DRP.AdminModeClient and DRP.AdminModeClient.Send then
		DRP.AdminModeClient.Send(action, target, amount)
		return
	end
	net.Start("drp_admin_mode_action_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(action, 4)
	net.WriteUInt(IsValid(target) and target:EntIndex() or 0, 13)
	net.WriteUInt(math.max(0, math.floor(tonumber(amount) or 0)), 32)
	net.SendToServer()
end

local function sendPlayerAdjustment(action, target, value)
	if not IsValid(target) then return end
	net.Start("drp_admin_player_adjust_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(action, 4)
	net.WriteUInt(target:EntIndex(), 13)
	net.WriteString(string.sub(tostring(value or ""), 1, 64))
	net.SendToServer()
end

local rankColors = {
	owner = Color(245, 190, 70),
	headadmin = Color(235, 90, 90),
	admin = Color(65, 180, 220),
	moderator = Color(80, 200, 125),
	supporter = Color(255, 140, 80),
	vipplus = Color(255, 175, 115),
	trusted = Color(175, 125, 225),
	vip = Color(235, 120, 190),
	user = colors.muted
}

local function rankColor(rankKey)
	return rankColors[DRP.AdminRank(rankKey).key] or colors.muted
end

local function addInfoLabel(parent, text, color)
	local label = vgui.Create("DLabel", parent)
	label:Dock(TOP)
	label:DockMargin(18, 2, 18, 4)
	label:SetTall(22)
	label:SetFont("DRP.Admin.Small")
	label:SetTextColor(color or colors.muted)
	label:SetText(text)
	return label
end

local function openAdminPanel(entries, canConfigureRanks, rankMasks, punishments)
	punishments = punishments or {}
	local canViewManagement = hasPermission("panel")
	local canUseInteractions = hasPermission("server_interactions")
	if IsValid(adminFrame) then adminFrame:Remove() end
	local frame = modernFrame("User Management", 1060, 680)
	adminFrame = frame
	frame:SetKeyboardInputEnabled(true)
	frame:SetMouseInputEnabled(true)
	frame.OnRemove = function() if adminFrame == frame then adminFrame = nil end end

	local tabs = vgui.Create("DPanel", frame)
	tabs:SetPos(14, 70)
	tabs:SetSize(frame:GetWide() - 28, 42)
	tabs.Paint = nil

	local sidebar = vgui.Create("DPanel", frame)
	sidebar:SetPos(14, 120)
	sidebar:SetSize(300, frame:GetTall() - 134)
	sidebar.Paint = function(_, width, height) draw.RoundedBox(8, 0, 0, width, height, colors.panel) end

	local content = vgui.Create("DPanel", frame)
	content:SetPos(326, 120)
	content:SetSize(frame:GetWide() - 340, frame:GetTall() - 134)
	content.Paint = function(_, width, height) draw.RoundedBox(8, 0, 0, width, height, colors.panel) end

	local selected
	local activePage = canViewManagement and "users" or "interactions"
	local usersTab
	local ranksTab
	local punishmentsTab
	local interactionsTab
	local healthTab
	local economyTab

	local function paintTab(button, page)
		button.Paint = function(self, width, height)
			local active = activePage == page
			draw.RoundedBox(6, 0, 0, width, height, active and colors.accent or (self:IsHovered() and colors.panelHover or colors.panel))
		end
	end

	local function showUser(entry)
		selected = entry
		content:Clear()

		if entry.entity > 0 then
			local actions = vgui.Create("DPanel", content)
			actions:Dock(BOTTOM)
			actions:DockMargin(14, 8, 14, 14)
			actions:SetTall(42)
			actions.Paint = nil
			for _, action in ipairs(DRP.AdminActions) do
				local actionData = action
				if hasPermission(actionData.permission) then
					local actionColor = (actionData.key == "kick" or actionData.key == "slay") and colors.red or colors.accent
					local button = modernButton(actions, actionData.label, actionColor, function()
						sendAdminAction(actionData.id, entry.entity)
					end)
					button:Dock(LEFT)
					button:DockMargin(4, 0, 4, 0)
					button:SetWide(120)
				end
			end
		end

		if hasPermission("adminmode") then
			local adminTools = vgui.Create("DPanel", content)
			adminTools:Dock(BOTTOM)
			adminTools:DockMargin(14, 5, 14, 5)
			adminTools:SetTall(DRP.ClientAdminMode and 228 or 70)
			adminTools.Paint = function(_, width, height)
				draw.RoundedBox(7, 0, 0, width, height, colors.background)
				draw.RoundedBoxEx(7, 0, 0, 5, height, DRP.ClientAdminMode and colors.green or colors.accent, true, false, true, false)
				draw.SimpleText(DRP.ClientAdminMode and "ADMIN MODE ACTIVE" or "ADMIN MODE REQUIRED", "DRP.Admin.Small", 16, 17, DRP.ClientAdminMode and colors.green or colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end

			if not DRP.ClientAdminMode then
				local enter = modernButton(adminTools, "Enter Admin Mode", colors.accent, function()
					sendAdminModeAction(DRP.AdminModeAction.TOGGLE)
				end)
				enter:SetPos(16, 31)
				enter:SetSize(adminTools:GetWide() - 32, 30)
				adminTools.PerformLayout = function(self, width) enter:SetSize(width - 32, 30) end
			else
				local target = entry.entity > 0 and Entity(entry.entity) or nil
				local definitions = {
					{ label = DRP.ClientAdminNoclip and "Disable Noclip" or "Enable Noclip", action = DRP.AdminModeAction.NOCLIP },
					{ label = DRP.ClientAdminCloaked and "Uncloak" or "Cloak", action = DRP.AdminModeAction.CLOAK },
					{ label = "Stop Spectating", action = DRP.AdminModeAction.STOP_SPECTATE },
					{ label = "Leave Admin Mode", action = DRP.AdminModeAction.TOGGLE, color = colors.red },
					{ label = "Spectate", action = DRP.AdminModeAction.SPECTATE, target = true },
					{ label = "Freeze", action = DRP.AdminModeAction.FREEZE, target = true },
					{ label = "Unfreeze", action = DRP.AdminModeAction.UNFREEZE, target = true },
					{ label = "Respawn", action = DRP.AdminModeAction.RESPAWN, target = true, allowSelf = true },
					{ label = "Strip Weapons", action = DRP.AdminModeAction.STRIP_WEAPONS, target = true },
					{ label = "Jail", action = DRP.AdminModeAction.JAIL, target = true },
					{ label = "Unjail", action = DRP.AdminModeAction.UNJAIL, target = true },
					{ label = IsValid(target) and DRP.Roster and DRP.Roster.Value(target, "adminMode", false) and "Remove Admin Mode" or "Place in Admin Mode", action = DRP.AdminModeAction.TOGGLE_TARGET_MODE, target = true },
					{ label = "Release Arrest", action = DRP.AdminModeAction.RELEASE_ARREST, target = true },
					{ label = "Set Health", action = DRP.AdminModeAction.SET_HEALTH, target = true, allowSelf = true, prompt = true, minimum = 1 },
					{ label = "Set Armor", action = DRP.AdminModeAction.SET_ARMOR, target = true, allowSelf = true, prompt = true, minimum = 0 }
				}
				local buttons = {}
				for _, definition in ipairs(definitions) do
					local data = definition
					local available = not data.target or (IsValid(target) and (target ~= LocalPlayer() or data.allowSelf))
					if available then
						local button = modernButton(adminTools, data.label, data.color or colors.accent, function()
							if data.prompt then
								Derma_StringRequest(
									data.label,
									data.label .. " for " .. target:Nick() .. " (maximum 1,000,000)",
									data.action == DRP.AdminModeAction.SET_HEALTH and "100" or "0",
									function(value)
										local amount = math.floor(tonumber(value) or -1)
										if amount < data.minimum or amount > 1000000 then return end
										sendAdminModeAction(data.action, target, amount)
									end,
									nil,
									"Apply",
									"Cancel"
								)
							else
								sendAdminModeAction(data.action, data.target and target or nil)
							end
						end)
						buttons[#buttons + 1] = button
					end
				end
				adminTools.PerformLayout = function(self, width)
					local columns, gap = 4, 7
					local buttonWidth = math.floor((width - 32 - gap * (columns - 1)) / columns)
					for index, button in ipairs(buttons) do
						local column = (index - 1) % columns
						local row = math.floor((index - 1) / columns)
						button:SetPos(16 + column * (buttonWidth + gap), 32 + row * 37)
						button:SetSize(buttonWidth, 30)
					end
				end
			end
		end

		if entry.entity > 0 and (hasPermission("jobs") or hasPermission("money") or hasPermission("experience") or hasPermission("civic")) then
			local target = Entity(entry.entity)
			local controls = vgui.Create("DPanel", content)
			controls:Dock(BOTTOM)
			controls:DockMargin(14, 5, 14, 5)
			controls:SetTall(112)
			controls.Paint = function(_, width, height)
				draw.RoundedBox(7, 0, 0, width, height, colors.background)
				draw.SimpleText("PLAYER VALUES", "DRP.Admin.Small", 16, 17, colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end
			local definitions = {}
			if hasPermission("jobs") then definitions[#definitions + 1] = { label = "Set Job", action = 1, default = "citizen", prompt = "Job key or name" } end
			if hasPermission("money") then
				definitions[#definitions + 1] = { label = "Set Money", action = 2, default = "500" }
				definitions[#definitions + 1] = { label = "Add Money", action = 3, default = "100" }
				definitions[#definitions + 1] = { label = "Deduct Money", action = 4, default = "100" }
			end
			if hasPermission("experience") then
				definitions[#definitions + 1] = { label = "Set XP", action = 5, default = "0" }
				definitions[#definitions + 1] = { label = "Add XP", action = 6, default = "100" }
				definitions[#definitions + 1] = { label = "Deduct XP", action = 7, default = "100" }
			end
			if hasPermission("civic") then
				definitions[#definitions + 1] = { label = "Set Civic", action = 8, default = "0" }
				definitions[#definitions + 1] = { label = "Add Civic", action = 9, default = "25" }
				definitions[#definitions + 1] = { label = "Deduct Civic", action = 10, default = "25" }
			end
			local buttons = {}
			for _, definition in ipairs(definitions) do
				local data = definition
				buttons[#buttons + 1] = modernButton(controls, data.label, colors.accent, function()
					if not IsValid(target) then return end
					Derma_StringRequest(data.label, (data.prompt or "Amount") .. " for " .. target:Nick(), data.default, function(value)
						if string.Trim(value) ~= "" then sendPlayerAdjustment(data.action, target, value) end
					end, nil, "Apply", "Cancel")
				end)
			end
			controls.PerformLayout = function(self, width)
				local columns, gap = 5, 7
				local buttonWidth = math.floor((width - 32 - gap * (columns - 1)) / columns)
				for index, button in ipairs(buttons) do
					local column, row = (index - 1) % columns, math.floor((index - 1) / columns)
					button:SetPos(16 + column * (buttonWidth + gap), 32 + row * 37)
					button:SetSize(buttonWidth, 30)
				end
			end
		end

		local actorRank = DRP.AdminRank(DRP.ClientAdminBaseRank)
		local targetRank = DRP.AdminRank(entry.baseRank)
		local hierarchyAllows = targetRank.key ~= "owner" and (actorRank.key == "owner" or targetRank.level < actorRank.level)
		local canWarn = hasPermission("warnings") and entry.steamID64 ~= LocalPlayer():SteamID64() and hierarchyAllows
		local canBlacklist = hasPermission("blacklists") and entry.steamID64 ~= LocalPlayer():SteamID64() and hierarchyAllows
		if canWarn or canBlacklist then
			local moderation = vgui.Create("DPanel", content)
			moderation:Dock(BOTTOM)
			moderation:DockMargin(14, 4, 14, 4)
			moderation:SetTall(92)
			moderation.Paint = function(_, width, height) draw.RoundedBox(7, 0, 0, width, height, colors.background) end

			local offense = vgui.Create("DTextEntry", moderation)
			offense:SetFont("DRP.Admin.Body")
			offense:SetTextColor(color_white)
			offense:SetCursorColor(color_white)
			offense:SetPlaceholderText("Describe the offense…")
			offense:SetEditable(true)
			offense:SetMouseInputEnabled(true)
			offense:SetKeyboardInputEnabled(true)
			offense:SetUpdateOnType(true)
			offense.OnGetFocus = function()
				if IsValid(frame) then frame:SetKeyboardInputEnabled(true) end
			end
			offense.Paint = function(self, width, height)
				draw.RoundedBox(5, 0, 0, width, height, colors.panel)
				self:DrawTextEntryText(color_white, colors.accent, color_white)
			end

			local function submitWarning(reason)
				reason = string.Trim(string.sub(tostring(reason or ""), 1, 160))
				if reason == "" then return false end
				sendPunishment(1, entry.steamID64, reason)
				offense:SetText("")
				return true
			end

			local function requestWarningReason()
				Derma_StringRequest(
					"Issue Warning",
					"Describe the offense committed by " .. entry.name .. ".",
					"",
					function(value) submitWarning(value) end,
					nil,
					"Issue warning",
					"Cancel"
				)
			end

			local buttons = {}
			if canWarn then
				buttons[#buttons + 1] = modernButton(moderation, "Issue warning", Color(235, 170, 65), function()
					local reason = string.Trim(offense:GetValue())
					if reason == "" then requestWarningReason() return end
					submitWarning(reason)
				end)
				offense.OnEnter = function(self)
					if submitWarning(self:GetValue()) then self:KillFocus() end
				end
			end
			if canBlacklist then
				buttons[#buttons + 1] = modernButton(moderation, "Blacklist player", colors.red, function()
					local reason = string.Trim(offense:GetValue())
					if reason == "" then offense:RequestFocus() return end
					Derma_Query(
						"Blacklist " .. entry.name .. " permanently?\n\nOffense: " .. reason,
						"Confirm Blacklist",
						"Blacklist", function() sendPunishment(2, entry.steamID64, reason) end,
						"Cancel"
					)
				end)
			end
			moderation.PerformLayout = function(self, width)
				offense:SetPos(10, 9)
				offense:SetSize(width - 20, 34)
				local buttonWidth = math.floor((width - 20 - math.max(#buttons - 1, 0) * 8) / math.max(#buttons, 1))
				for index, button in ipairs(buttons) do
					button:SetPos(10 + (index - 1) * (buttonWidth + 8), 50)
					button:SetSize(buttonWidth, 32)
				end
			end
			timer.Simple(0, function()
				if IsValid(frame) and IsValid(offense) then
					frame:SetKeyboardInputEnabled(true)
					offense:RequestFocus()
				end
			end)
		end

		local body = vgui.Create("DScrollPanel", content)
		body:Dock(FILL)
		body:DockMargin(0, 0, 4, 0)
		local title = sectionLabel(body, entry.name)
		title:Dock(TOP)
		title:DockMargin(18, 14, 18, 0)

		addInfoLabel(body, entry.steamID64 .. (entry.entity > 0 and "  •  Online" or "  •  Offline"))
		addInfoLabel(body, "Displayed rank: " .. DRP.AdminRankLabel(entry.rank), rankColor(entry.rank))
		addInfoLabel(body, "Base rank: " .. DRP.AdminRankLabel(entry.baseRank), rankColor(entry.baseRank))
		local badges = {}
		if entry.trusted then badges[#badges + 1] = "TRUSTED FLAG" end
		if entry.supporterTier and entry.supporterTier > 0 then badges[#badges + 1] = string.upper(DRP.Supporter.Definition(entry.supporterTier).label) end
		addInfoLabel(body, #badges > 0 and table.concat(badges, "  •  ") or "Entitlement flags: none", #badges > 0 and colors.accent or colors.muted)
		addInfoLabel(body, entry.discordVerified and "Discord: live role verified"
			or (entry.discordLinked and "Discord: linked; live role checked when Trusted is granted"
			or "Discord: live role check required for Trusted"), entry.discordVerified and colors.green or colors.muted)
		if hasPermission("trust") then
			local inspectTrust = modernButton(body, "Inspect trust evidence", colors.accent, function()
				if DRP.TrustUI and DRP.TrustUI.Request then DRP.TrustUI.Request(entry.steamID64) end
			end)
			inspectTrust:Dock(TOP)
			inspectTrust:DockMargin(18, 8, 18, 8)
			inspectTrust:SetTall(38)
		end

		local localRankLevel = DRP.AdminRankLevel(DRP.ClientAdminBaseRank)
		local targetRankLevel = DRP.AdminRankLevel(entry.baseRank)
		local canGrantMassie = localRankLevel >= DRP.AdminRankLevel("headadmin")
			and entry.steamID64 ~= LocalPlayer():SteamID64()
			and (DRP.ClientOwner or targetRankLevel < localRankLevel)
		if canGrantMassie then
			local specialTitle = sectionLabel(body, "Special permissions")
			specialTitle:Dock(TOP)
			specialTitle:DockMargin(18, 12, 18, 2)
			local massie = vgui.Create("DCheckBoxLabel", body)
			massie:Dock(TOP)
			massie:DockMargin(20, 3, 20, 5)
			massie:SetTall(26)
			massie:SetFont("DRP.Admin.Body")
			massie:SetTextColor(color_white)
			massie:SetText("Allow /massie one-way PvP event")
			massie:SetValue(entry.massie == true)
			local saveMassie = modernButton(body, "Save special permission", colors.accent, function()
				net.Start("drp_massie_access_set_v1")
				net.WriteUInt(DRP.ProtocolVersion, 8)
				net.WriteString(entry.steamID64)
				net.WriteBool(massie:GetChecked())
				net.SendToServer()
			end)
			saveMassie:Dock(TOP)
			saveMassie:DockMargin(18, 0, 18, 10)
			saveMassie:SetTall(36)
		elseif targetRankLevel >= DRP.AdminRankLevel("headadmin") then
			addInfoLabel(body, "Massie access: included with HeadAdmin+.", colors.accent)
		elseif entry.massie then
			addInfoLabel(body, "Special access: /massie enabled.", colors.accent)
		end

		local canModifyEntitlements = entry.steamID64 ~= LocalPlayer():SteamID64()
			and entry.baseRank ~= "owner"
			and (DRP.ClientOwner or targetRankLevel < localRankLevel)
		local canSetTrusted = canModifyEntitlements and localRankLevel >= DRP.AdminRankLevel("admin")
		local canSetVIP = canModifyEntitlements and localRankLevel >= DRP.AdminRankLevel("headadmin")
		if canSetTrusted or canSetVIP then
			local entitlementTitle = sectionLabel(body, "Persistent entitlements")
			entitlementTitle:Dock(TOP)
			entitlementTitle:DockMargin(18, 12, 18, 2)
			if canSetTrusted then
				local trusted = vgui.Create("DCheckBoxLabel", body)
				trusted:Dock(TOP)
				trusted:DockMargin(20, 3, 20, 4)
				trusted:SetTall(26)
				trusted:SetFont("DRP.Admin.Body")
				trusted:SetTextColor(color_white)
				trusted:SetText("Trusted flag (grant requires live Discord verification)")
				trusted:SetValue(entry.trusted == true)
				trusted.OnChange = function(_, enabled)
					net.Start("drp_admin_entitlement_update_v1")
					net.WriteUInt(DRP.ProtocolVersion, 8)
					net.WriteString(entry.steamID64)
					net.WriteBool(false)
					net.WriteBool(enabled == true)
					net.SendToServer()
				end
			end
			if canSetVIP then
				local tier = vgui.Create("DComboBox", body)
				tier:Dock(TOP)
				tier:DockMargin(18, 4, 18, 8)
				tier:SetTall(34)
				tier:SetFont("DRP.Admin.Body")
				for value = 0, 3 do
					local definition = DRP.Supporter.Definition(value)
					tier:AddChoice(string.format("%s — %.2gx rewards, +%d entities, %d properties", definition.label, definition.multiplier, definition.entityBonus, definition.propertyLimit), value, value == entry.supporterTier)
				end
				tier.OnSelect = function(_, _, _, value) sendSupporterTierUpdate(entry.steamID64, value) end
			end
		end

		local canModify = entry.steamID64 ~= LocalPlayer():SteamID64()
		local choices = {}
		for _, rank in ipairs(DRP.AdminRanks) do
			if DRP.AdminCanSetRank(DRP.ClientAdminBaseRank, entry.baseRank, rank.key) then choices[#choices + 1] = rank end
		end
		canModify = canModify and #choices > 0

		if canModify then
			local rankTitle = sectionLabel(body, "Assign rank")
			rankTitle:Dock(TOP)
			rankTitle:DockMargin(18, 12, 18, 2)

			local rankSelect = vgui.Create("DComboBox", body)
			rankSelect:Dock(TOP)
			rankSelect:DockMargin(18, 0, 18, 8)
			rankSelect:SetTall(34)
			rankSelect:SetFont("DRP.Admin.Body")
			rankSelect:SetTextColor(color_white)
			rankSelect:SetValue(DRP.AdminRankLabel(entry.baseRank))
			rankSelect.Paint = function(_, width, height)
				draw.RoundedBox(6, 0, 0, width, height, colors.background)
			end
			local selectedRank = entry.baseRank
			for _, rank in ipairs(choices) do
				rankSelect:AddChoice(rank.label, rank.key, rank.key == entry.baseRank)
			end
			rankSelect.OnSelect = function(_, _, _, data) selectedRank = data end

			local save = modernButton(body, "Set rank", colors.accent, function()
				net.Start("drp_admin_update_v1")
				net.WriteString(entry.steamID64)
				net.WriteString(selectedRank)
				net.SendToServer()
			end)
			save:Dock(TOP)
			save:DockMargin(18, 0, 18, 10)
			save:SetTall(38)
		elseif entry.steamID64 == LocalPlayer():SteamID64() then
			addInfoLabel(body, "Your own rank cannot be changed here.")
		elseif DRP.AdminRankLevel(DRP.ClientAdminBaseRank) >= DRP.AdminRankLevel("headadmin") then
			addInfoLabel(body, "This rank is protected by the staff hierarchy.")
		end

		local permissionsTitle = sectionLabel(body, "Effective permissions")
		permissionsTitle:Dock(TOP)
		permissionsTitle:DockMargin(18, 10, 18, 2)
		for _, permission in ipairs(DRP.AdminPermissions) do
			local check = vgui.Create("DCheckBoxLabel", body)
			check:Dock(TOP)
			check:DockMargin(20, 1, 20, 0)
			check:SetTall(22)
			check:SetFont("DRP.Admin.Body")
			check:SetTextColor(colors.muted)
			check:SetText(permission.label)
			check:SetValue(DRP.AdminMaskHas(entry.mask, permission.key))
			check:SetEnabled(false)
		end
	end

	local function showUsersPage()
		activePage = "users"
		adminPreferredPage = "users"
		selected = nil
		sidebar:Clear()
		content:Clear()
		local usersTitle = sectionLabel(sidebar, "Players and staff")
		usersTitle:Dock(TOP)
		usersTitle:DockMargin(14, 10, 10, 4)
		if DRP.AdminRankLevel(DRP.ClientAdminBaseRank) >= DRP.AdminRankLevel("admin") then
			local offline = modernButton(sidebar, "Offline entitlements", colors.accent, openOfflineEntitlementDialog)
			offline:Dock(TOP)
			offline:DockMargin(8, 0, 8, 8)
			offline:SetTall(36)
		end
		local scroll = vgui.Create("DScrollPanel", sidebar)
		scroll:Dock(FILL)
		scroll:DockMargin(8, 0, 8, 8)
		for _, entry in ipairs(entries) do
			local user = entry
			local button = vgui.Create("DButton", scroll)
			button:Dock(TOP)
			button:DockMargin(0, 0, 0, 5)
			button:SetTall(50)
			button:SetText("")
			button.Paint = function(self, width, height)
				local active = selected == user
				draw.RoundedBox(6, 0, 0, width, height, active and colors.accent or (self:IsHovered() and colors.panelHover or colors.background))
				draw.SimpleText(user.name, "DRP.Admin.Body", 12, 16, color_white)
				draw.SimpleText(DRP.AdminRankLabel(user.rank), "DRP.Admin.Small", 12, 36, active and color_white or rankColor(user.rank))
			end
			button.DoClick = function() showUser(user) end
		end
		if entries[1] then showUser(entries[1]) end
	end

	local function showRankPermissionsPage()
		if not canConfigureRanks then return end
		activePage = "ranks"
		adminPreferredPage = "ranks"
		selected = nil
		sidebar:Clear()
		content:Clear()
		local ranksTitle = sectionLabel(sidebar, "Server ranks")
		ranksTitle:Dock(TOP)
		ranksTitle:DockMargin(14, 10, 10, 4)

		local function showRank(rank)
			content:Clear()
			local title = sectionLabel(content, rank.label)
			title:Dock(TOP)
			title:DockMargin(18, 14, 18, 0)
			local fixed = rank.key == "owner" or rank.key == "user"
			addInfoLabel(content, fixed and "This rank has fixed permissions." or "Changes apply to every user with this rank.", rankColor(rank.key))
			local checks = {}
			for _, permission in ipairs(DRP.AdminPermissions) do
				local permissionData = permission
				local locked = fixed or (rank.key == "headadmin" and (permission.key == "panel" or permission.key == "users" or permission.key == "server_interactions" or permission.key == "adminmode"))
				local check = vgui.Create("DCheckBoxLabel", content)
				check:Dock(TOP)
				check:DockMargin(20, 5, 20, 0)
				check:SetTall(26)
				check:SetFont("DRP.Admin.Body")
				check:SetTextColor(locked and colors.muted or color_white)
				check:SetText(permission.label .. (locked and "  (required)" or ""))
				check:SetValue(DRP.AdminMaskHas(rankMasks[rank.key] or 0, permission.key))
				check:SetEnabled(not locked)
				checks[#checks + 1] = { control = check, permission = permissionData }
			end
			if not fixed then
				local save = modernButton(content, "Save " .. rank.label .. " permissions", colors.accent, function()
					local mask = 0
					for _, item in ipairs(checks) do
						if item.control:GetChecked() then mask = bit.bor(mask, item.permission.bit) end
					end
					net.Start("drp_admin_rank_permissions_v1")
					net.WriteString(rank.key)
					net.WriteUInt(mask, 32)
					net.SendToServer()
				end)
				save:Dock(TOP)
				save:DockMargin(18, 18, 18, 0)
				save:SetTall(40)
			end
		end

		for _, rank in ipairs(DRP.AdminRanks) do
			local rankData = rank
			local button = vgui.Create("DButton", sidebar)
			button:Dock(TOP)
			button:DockMargin(8, 0, 8, 5)
			button:SetTall(42)
			button:SetText(rank.label)
			button:SetFont("DRP.Admin.Body")
			button:SetTextColor(rankColor(rank.key))
			button.Paint = function(self, width, height)
				draw.RoundedBox(6, 0, 0, width, height, self:IsHovered() and colors.panelHover or colors.background)
			end
			button.DoClick = function() showRank(rankData) end
		end
		showRank(DRP.AdminRank("headadmin"))
	end

	local function showPunishmentsPage()
		if not canViewManagement then return end
		activePage = "punishments"
		adminPreferredPage = "punishments"
		selected = nil
		sidebar:Clear()
		content:Clear()

		local warningCount, blacklistCount, activeBlacklistCount = 0, 0, 0
		for _, punishment in ipairs(punishments) do
			if punishment.kind == "warning" then
				warningCount = warningCount + 1
			else
				blacklistCount = blacklistCount + 1
				if punishment.active then activeBlacklistCount = activeBlacklistCount + 1 end
			end
		end

		local title = sectionLabel(sidebar, "Punishment ledger")
		title:Dock(TOP)
		title:DockMargin(14, 10, 10, 2)
		addInfoLabel(sidebar, warningCount .. " warnings  •  " .. activeBlacklistCount .. " active blacklists")

		local activeFilter = "all"
		local filterButtons = {}
		local searchText = ""
		local scroll
		local populate
		local filters = {
			{ key = "all", label = "All punishments", count = #punishments },
			{ key = "warnings", label = "Warnings", count = warningCount },
			{ key = "active", label = "Active blacklists", count = activeBlacklistCount },
			{ key = "blacklists", label = "All blacklists", count = blacklistCount }
		}

		for _, filter in ipairs(filters) do
			local data = filter
			local button = vgui.Create("DButton", sidebar)
			filterButtons[data.key] = button
			button:Dock(TOP)
			button:DockMargin(8, 0, 8, 6)
			button:SetTall(46)
			button:SetText("")
			button.Paint = function(self, width, height)
				local isActive = activeFilter == data.key
				draw.RoundedBox(6, 0, 0, width, height, isActive and colors.panelHover or (self:IsHovered() and colors.background or Color(0, 0, 0, 0)))
				if isActive then draw.RoundedBoxEx(6, 0, 0, 4, height, colors.accent, true, false, true, false) end
				draw.SimpleText(data.label, "DRP.Admin.Body", 14, height * 0.5, isActive and color_white or colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(data.count, "DRP.Admin.Small", width - 14, height * 0.5, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
			end
			button.DoClick = function()
				activeFilter = data.key
				populate()
			end
		end

		local search = vgui.Create("DTextEntry", content)
		search:SetPos(14, 14)
		search:SetSize(content:GetWide() - (hasPermission("blacklists") and 310 or 136), 38)
		search:SetFont("DRP.Admin.Body")
		search:SetTextColor(color_white)
		search:SetCursorColor(color_white)
		search:SetPlaceholderText("Search player, offense, or issuing admin…")
		search.Paint = function(self, width, height)
			draw.RoundedBox(6, 0, 0, width, height, colors.background)
			self:DrawTextEntryText(color_white, colors.accent, color_white)
		end

		if hasPermission("blacklists") then
			local offline = modernButton(content, "Offline blacklist", colors.red, openOfflineBlacklistDialog)
			offline:SetPos(content:GetWide() - 286, 14)
			offline:SetSize(164, 38)
		end

		local refresh = modernButton(content, "Refresh", colors.accent, function()
			net.Start("drp_admin_request_v1")
			net.SendToServer()
		end)
		refresh:SetPos(content:GetWide() - 112, 14)
		refresh:SetSize(98, 38)

		scroll = vgui.Create("DScrollPanel", content)
		scroll:SetPos(12, 64)
		scroll:SetSize(content:GetWide() - 24, content:GetTall() - 76)

		populate = function()
			scroll:GetCanvas():Clear()
			local visible = 0
			for _, punishment in ipairs(punishments) do
				local matchesFilter = activeFilter == "all"
					or (activeFilter == "warnings" and punishment.kind == "warning")
					or (activeFilter == "blacklists" and punishment.kind == "blacklist")
					or (activeFilter == "active" and punishment.kind == "blacklist" and punishment.active)
				local haystack = string.lower(punishment.target_name .. " " .. punishment.target_id .. " " .. punishment.offense .. " " .. punishment.issuer_name)
				if matchesFilter and (searchText == "" or string.find(haystack, searchText, 1, true)) then
					visible = visible + 1
					local data = punishment
					local row = vgui.Create("DPanel", scroll)
					row:Dock(TOP)
					row:DockMargin(0, 0, 0, 8)
					row:SetTall(108)
					local punishmentColor = data.kind == "blacklist" and colors.red or Color(235, 170, 65)
					row.Paint = function(_, width, height)
						draw.RoundedBox(7, 0, 0, width, height, colors.background)
						draw.RoundedBoxEx(7, 0, 0, 6, height, punishmentColor, true, false, true, false)
						draw.SimpleText(string.upper(data.kind), "DRP.Admin.Small", 18, 20, punishmentColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
						draw.SimpleText(data.target_name, "DRP.Admin.Body", 112, 20, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
						draw.SimpleText(os.date("%d %b %Y  %H:%M", data.issued_at), "DRP.Admin.Small", width - 16, 20, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
						draw.SimpleText("Issued by " .. data.issuer_name, "DRP.Admin.Small", 18, 91, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
					local revoked = (data.lifted_at or 0) > 0
					local status = data.kind == "blacklist"
						and (data.active and "ACTIVE" or ("REVOKED" .. (data.lifted_by ~= "" and " BY " .. string.upper(data.lifted_by) or "")))
						or (revoked and ("REVOKED" .. (data.lifted_by ~= "" and " BY " .. string.upper(data.lifted_by) or "")) or "RECORDED")
					draw.SimpleText(status, "DRP.Admin.Small", width - 16, 91, data.active and colors.red or colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
					end

					local offense = vgui.Create("DLabel", row)
					offense:SetFont("DRP.Admin.Body")
					offense:SetTextColor(color_white)
					offense:SetText(data.offense)
					offense:SetWrap(true)
					offense:SetContentAlignment(4)

					local lift
					local canRevoke = DRP.ClientAdminMode and ((data.kind == "blacklist" and data.active and hasPermission("blacklists"))
						or (data.kind == "warning" and (data.lifted_at or 0) == 0 and hasPermission("warnings")))
					if canRevoke then
						lift = modernButton(row, "Revoke", colors.accent, function()
							Derma_Query(
								"Revoke this " .. data.kind .. " for " .. data.target_name .. "?",
								"Revoke " .. string.upper(string.sub(data.kind, 1, 1)) .. string.sub(data.kind, 2),
								"Revoke", function() sendPunishment(3, "", data.id) end,
								"Cancel"
							)
						end)
					end
					row.PerformLayout = function(self, width)
						offense:SetPos(18, 38)
						offense:SetSize(width - (IsValid(lift) and 112 or 36), 42)
						if IsValid(lift) then lift:SetPos(width - 88, 43) lift:SetSize(72, 32) end
					end
				end
			end
			if visible == 0 then
				local empty = vgui.Create("DLabel", scroll)
				empty:Dock(TOP)
				empty:SetTall(90)
				empty:SetFont("DRP.Admin.Body")
				empty:SetTextColor(colors.muted)
				empty:SetContentAlignment(5)
				empty:SetText("No punishments match this view.")
			end
		end
		search.OnChange = function(self)
			searchText = string.lower(string.Trim(self:GetValue()))
			populate()
		end
		populate()
	end

	local function showServerInteractionsPage()
		if not canUseInteractions then return end
		activePage = "interactions"
		adminPreferredPage = "interactions"
		selected = nil
		sidebar:Clear()
		content:Clear()

		local toolsTitle = sectionLabel(sidebar, "Server interactions")
		toolsTitle:Dock(TOP)
		toolsTitle:DockMargin(14, 10, 10, 2)
		addInfoLabel(sidebar, "Live controls affecting the whole server.")

		local announcements = vgui.Create("DButton", sidebar)
		announcements:Dock(TOP)
		announcements:DockMargin(8, 8, 8, 6)
		announcements:SetTall(58)
		announcements:SetText("")
		announcements.Paint = function(_, width, height)
			draw.RoundedBox(6, 0, 0, width, height, colors.panelHover)
			draw.RoundedBoxEx(6, 0, 0, 4, height, colors.accent, true, false, true, false)
			draw.SimpleText("Global announcements", "DRP.Admin.Body", 14, 20, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText("Broadcast to every connected player", "DRP.Admin.Small", 14, 41, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		local future = vgui.Create("DPanel", sidebar)
		future:Dock(TOP)
		future:DockMargin(8, 4, 8, 0)
		future:SetTall(54)
		future.Paint = function(_, width, height)
			draw.RoundedBox(6, 0, 0, width, height, colors.background)
			draw.SimpleText("Additional tools", "DRP.Admin.Body", 14, 18, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText("New interactions will appear here", "DRP.Admin.Small", 14, 38, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		local title = sectionLabel(content, "Global announcement")
		title:SetPos(18, 16)
		title:SetSize(content:GetWide() - 36, 30)
		local description = vgui.Create("DLabel", content)
		description:SetPos(18, 48)
		description:SetSize(content:GetWide() - 36, 42)
		description:SetFont("DRP.Admin.Small")
		description:SetTextColor(colors.muted)
		description:SetWrap(true)
		description:SetText("Send a themed banner and system-chat message to every connected player. All announcements are recorded in the activity log.")

		local subject = vgui.Create("DTextEntry", content)
		subject:SetPos(18, 104)
		subject:SetSize(content:GetWide() - 36, 38)
		subject:SetFont("DRP.Admin.Body")
		subject:SetTextColor(color_white)
		subject:SetCursorColor(color_white)
		subject:SetPlaceholderText("Announcement title (optional)")
		subject.Paint = function(self, width, height)
			draw.RoundedBox(6, 0, 0, width, height, colors.background)
			self:DrawTextEntryText(color_white, colors.accent, color_white)
		end

		local message = vgui.Create("DTextEntry", content)
		message:SetPos(18, 154)
		message:SetSize(content:GetWide() - 36, 190)
		message:SetFont("DRP.Admin.Body")
		message:SetTextColor(color_white)
		message:SetCursorColor(color_white)
		message:SetPlaceholderText("Write the global announcement…")
		message:SetMultiline(true)
		message.Paint = function(self, width, height)
			draw.RoundedBox(6, 0, 0, width, height, colors.background)
			self:DrawTextEntryText(color_white, colors.accent, color_white)
		end

		local counter = vgui.Create("DLabel", content)
		counter:SetPos(18, 350)
		counter:SetSize(content:GetWide() - 36, 24)
		counter:SetFont("DRP.Admin.Small")
		counter:SetTextColor(colors.muted)
		counter:SetContentAlignment(6)
		counter:SetText("0 / 300")
		message.OnChange = function(self)
			local value = self:GetValue()
			if #value > 300 then
				self:SetText(string.sub(value, 1, 300))
				self:SetCaretPos(300)
				value = self:GetValue()
			end
			counter:SetText(#value .. " / 300")
		end
		subject.OnChange = function(self)
			local value = self:GetValue()
			if #value > 48 then self:SetText(string.sub(value, 1, 48)) self:SetCaretPos(48) end
		end

		local send = modernButton(content, "Broadcast announcement", colors.accent, function()
			local body = string.Trim(message:GetValue())
			if body == "" then message:RequestFocus() return end
			local heading = string.Trim(subject:GetValue())
			Derma_Query(
				"Broadcast this announcement to every connected player?",
				"Confirm Global Announcement",
				"Broadcast", function()
					net.Start("drp_admin_server_interaction_v1")
					net.WriteUInt(DRP.ProtocolVersion, 8)
					net.WriteUInt(1, 2)
					net.WriteString(heading)
					net.WriteString(body)
					net.SendToServer()
					message:SetText("")
				end,
				"Cancel"
			)
		end)
		send:SetPos(18, 390)
		send:SetSize(content:GetWide() - 36, 42)
	end

	local function showServerHealthPage()
		if not canUseInteractions then return end
		activePage = "health"
		adminPreferredPage = "health"
		selected = nil
		sidebar:Clear()
		content:Clear()
		local title = sectionLabel(sidebar, "Server health")
		title:Dock(TOP)
		title:DockMargin(14, 10, 10, 2)
		addInfoLabel(sidebar, "On-demand diagnostics. No polling timer.")
		local refresh = modernButton(sidebar, "Refresh snapshot", colors.accent, function()
			net.Start("drp_admin_health_request_v1")
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.SendToServer()
		end)
		refresh:Dock(TOP)
		refresh:DockMargin(10, 10, 10, 0)
		refresh:SetTall(38)

		local function render()
			content:Clear()
			local snapshot = adminHealthSnapshot
			if not snapshot then
				addInfoLabel(content, "Waiting for a server snapshot…", colors.accent)
				return
			end
			local heading = sectionLabel(content, "Runtime overview")
			heading:Dock(TOP)
			heading:DockMargin(18, 14, 18, 4)
			local hours = math.floor(snapshot.uptime / 3600)
			local minutes = math.floor(snapshot.uptime / 60) % 60
			addInfoLabel(content, string.format("Players %d/%d   •   Tickrate %d   •   Uptime %dh %02dm", snapshot.players, snapshot.maxPlayers, snapshot.tickrate, hours, minutes), color_white)
			addInfoLabel(content, string.format("Entities %s   •   Props %s   •   Prop complexity %s", string.Comma(snapshot.entities), string.Comma(snapshot.props), string.Comma(snapshot.propWeight)))
			addInfoLabel(content, string.format("Active incidents %d   •   Deadlines %d   •   Lua memory %.1f MB", snapshot.incidents, snapshot.deadlines, snapshot.memory / 1024))
			local dbColor = snapshot.database and colors.green or colors.red
			addInfoLabel(content, "Database " .. (snapshot.database and "ONLINE" or "OFFLINE") .. "   •   queue " .. snapshot.dbQueue .. "   •   errors " .. snapshot.dbErrors, dbColor)
			addInfoLabel(content, string.format("DB loads core %d / Hands %d   •   Catalogue clients %d", snapshot.dbPlayerLoads, snapshot.dbPocketLoads, snapshot.catalogTransfers))
			if snapshot.dbError ~= "" then addInfoLabel(content, "Last database status: " .. snapshot.dbError, snapshot.database and colors.muted or colors.red) end
			addInfoLabel(content, string.format("Network %s messages / %s estimated bytes   •   Audit queue %d", string.Comma(snapshot.netMessages), string.Comma(snapshot.netBytes), snapshot.auditQueue))
			addInfoLabel(content, string.format("ARC9 explosives %d   •   area effects %d   •   physical bullets %d", snapshot.arcExplosives, snapshot.arcAreaEffects, snapshot.arcPhysBullets))
			local serviceTitle = sectionLabel(content, "Service startup validation")
			serviceTitle:Dock(TOP)
			serviceTitle:DockMargin(18, 14, 18, 4)
			local scroll = vgui.Create("DScrollPanel", content)
			scroll:Dock(FILL)
			scroll:DockMargin(14, 0, 10, 12)
			for _, service in ipairs(snapshot.services) do
				local line = vgui.Create("DPanel", scroll)
				line:Dock(TOP)
				line:DockMargin(0, 0, 0, 5)
				line:SetTall(service.error ~= "" and 52 or 34)
				line.Paint = function(_, width, height)
					local stateColor = service.started and colors.green or colors.red
					draw.RoundedBox(6, 0, 0, width, height, colors.background)
					draw.RoundedBoxEx(6, 0, 0, 4, height, stateColor, true, false, true, false)
					draw.SimpleText(service.name, "DRP.Admin.Body", 14, 17, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
					draw.SimpleText(service.started and "READY" or "FAILED", "DRP.Admin.Small", width - 14, 17, stateColor, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
					if service.error ~= "" then draw.SimpleText(string.sub(service.error, 1, 100), "DRP.Admin.Small", 14, 38, colors.red, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
				end
			end
		end
		healthRefreshCallback = function() if IsValid(frame) and activePage == "health" then render() end end
		render()
		net.Start("drp_admin_health_request_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.SendToServer()
	end

	local function showEconomyHealthPage()
		if not canUseInteractions then return end
		activePage = "economy"
		adminPreferredPage = "economy"
		selected = nil
		sidebar:Clear()
		content:Clear()
		local title = sectionLabel(sidebar, "Economy health")
		title:Dock(TOP)
		title:DockMargin(14, 10, 10, 2)
		addInfoLabel(sidebar, "On-demand ledger projection. No polling timer.")
		local refresh = modernButton(sidebar, "Refresh snapshot", colors.accent, function()
			net.Start("drp_economy_health_request_v1")
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.SendToServer()
		end)
		refresh:Dock(TOP)
		refresh:DockMargin(10, 10, 10, 0)
		refresh:SetTall(38)

		local function render()
			content:Clear()
			local snapshot = economyHealthSnapshot
			if not snapshot then addInfoLabel(content, "Waiting for an economy snapshot…", colors.accent) return end
			local overview = sectionLabel(content, "Money and liquidity")
			overview:Dock(TOP)
			overview:DockMargin(18, 14, 18, 4)
			addInfoLabel(content, string.format("Exact money $%s   •   Online $%s   •   Effective $%s", string.Comma(snapshot.exactMoney or 0), string.Comma(snapshot.onlineMoney or 0), string.Comma(snapshot.effectiveMoney or 0)), color_white)
			addInfoLabel(content, string.format("Treasury $%s   •   Dormant cash $%s   •   Median wallet $%s   •   Richest %s ($%s)", string.Comma(snapshot.treasury or 0), string.Comma(snapshot.dormantCash or 0), string.Comma(snapshot.medianWallet or 0), tostring(snapshot.richestName or "Unknown"), string.Comma(snapshot.richestWallet or 0)))
			addInfoLabel(content, string.format("Supply value $%s   •   Wallet Gini %.2f   •   1h mint $%s   •   1h burn $%s   •   Net $%s",string.Comma(snapshot.supplyValue or 0),tonumber(snapshot.walletGini) or 0,string.Comma(snapshot.hourlyMint or 0),string.Comma(snapshot.hourlyBurn or 0),string.Comma(snapshot.netHourlyMoney or 0)))
			addInfoLabel(content, string.format("Revision %s   •   Mode %s   •   Journal %s bytes   •   Database %s", tostring(snapshot.revision or 0), tostring(snapshot.mode or "unknown"), string.Comma(snapshot.journalBytes or 0), snapshot.database and "ONLINE" or "OFFLINE"), snapshot.database and colors.green or colors.red)
			local warningTitle = sectionLabel(content, "Warnings")
			warningTitle:Dock(TOP)
			warningTitle:DockMargin(18, 14, 18, 4)
			for _, warning in ipairs(snapshot.warnings or {}) do
				local warningColor = warning.severity == "critical" and colors.red or (colors.warning or colors.accent)
				addInfoLabel(content, string.upper(tostring(warning.severity or "info")) .. "  " .. tostring(warning.text or warning.key or "warning"), warningColor)
			end
			if #(snapshot.warnings or {}) == 0 then addInfoLabel(content, "No active economy warnings.", colors.green) end
			local supplyTitle = sectionLabel(content, "Commodity supply")
			supplyTitle:Dock(TOP)
			supplyTitle:DockMargin(18, 14, 18, 4)
			local scroll = vgui.Create("DScrollPanel", content)
			scroll:Dock(FILL)
			scroll:DockMargin(14, 0, 10, 12)
			local keys = {}
			for key in pairs(snapshot.supply or {}) do keys[#keys + 1] = key end
			table.sort(keys)
			for _, key in ipairs(keys) do
				local item = snapshot.supply[key]
				local line = vgui.Create("DPanel", scroll)
				line:Dock(TOP)
				line:DockMargin(0, 0, 0, 5)
				line:SetTall(34)
				line.Paint = function(_, width, height)
					draw.RoundedBox(6, 0, 0, width, height, colors.background)
					draw.SimpleText(key, "DRP.Admin.Small", 12, height * .5, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
					draw.SimpleText(string.format("exact %s  effective %s  target %s  price %.2fx  loot %.2fx", string.Comma(item.exact or 0), string.Comma(math.floor(item.effective or 0)), string.Comma(item.target or 0), tonumber(item.price or 1), tonumber(item.factor or 1)), "DRP.Admin.Small", width - 12, height * .5, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
				end
			end
		end
		economyHealthRefreshCallback = function() if IsValid(frame) and activePage == "economy" then render() end end
		render()
		net.Start("drp_economy_health_request_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.SendToServer()
	end

	if canViewManagement then
		usersTab = modernButton(tabs, "Users", colors.accent, showUsersPage)
		usersTab:Dock(LEFT)
		usersTab:SetWide(150)
		paintTab(usersTab, "users")
		punishmentsTab = modernButton(tabs, "Warnings & Blacklists", colors.accent, showPunishmentsPage)
		punishmentsTab:Dock(LEFT)
		punishmentsTab:DockMargin(8, 0, 0, 0)
		punishmentsTab:SetWide(220)
		paintTab(punishmentsTab, "punishments")
	end
	if canViewManagement and canConfigureRanks then
		ranksTab = modernButton(tabs, "Rank Permissions", colors.accent, showRankPermissionsPage)
		ranksTab:Dock(LEFT)
		ranksTab:DockMargin(8, 0, 0, 0)
		ranksTab:SetWide(190)
		paintTab(ranksTab, "ranks")
	end
	if canUseInteractions then
		interactionsTab = modernButton(tabs, "Server Interactions", colors.accent, showServerInteractionsPage)
		interactionsTab:Dock(LEFT)
		interactionsTab:DockMargin(8, 0, 0, 0)
		interactionsTab:SetWide(190)
		paintTab(interactionsTab, "interactions")
		healthTab = modernButton(tabs, "Server Health", colors.accent, showServerHealthPage)
		healthTab:Dock(LEFT)
		healthTab:DockMargin(8, 0, 0, 0)
		healthTab:SetWide(145)
		paintTab(healthTab, "health")
		economyTab = modernButton(tabs, "Economy Health", colors.accent, showEconomyHealthPage)
		economyTab:Dock(LEFT)
		economyTab:DockMargin(8, 0, 0, 0)
		economyTab:SetWide(155)
		paintTab(economyTab, "economy")
	end
	if adminPreferredPage == "economy" and canUseInteractions then
		showEconomyHealthPage()
	elseif adminPreferredPage == "health" and canUseInteractions then
		showServerHealthPage()
	elseif adminPreferredPage == "interactions" and canUseInteractions then
		showServerInteractionsPage()
	elseif adminPreferredPage == "punishments" and canViewManagement then
		showPunishmentsPage()
	elseif adminPreferredPage == "ranks" and canViewManagement and canConfigureRanks then
		showRankPermissionsPage()
	elseif canViewManagement then
		showUsersPage()
	else
		showServerInteractionsPage()
	end
end

net.Receive("drp_admin_snapshot_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or (not hasPermission("panel") and not hasPermission("server_interactions")) then return end
	local entries = {}
	for index = 1, net.ReadUInt(8) do
		entries[index] = {
			entity = net.ReadUInt(13),
			steamID64 = string.sub(net.ReadString(), 1, 17),
			name = string.sub(net.ReadString(), 1, 64),
			rank = DRP.AdminRank(net.ReadString()).key,
			baseRank = DRP.AdminRank(net.ReadString()).key,
			trusted = net.ReadBool(),
			supporterTier = net.ReadUInt(2),
			discordLinked = net.ReadBool(),
			discordVerified = net.ReadBool(),
			mask = net.ReadUInt(32),
			massie = net.ReadBool()
		}
	end
	local canConfigureRanks = net.ReadBool()
	local rankMasks = {}
	if canConfigureRanks then
		for _ = 1, net.ReadUInt(4) do
			rankMasks[DRP.AdminRank(net.ReadString()).key] = net.ReadUInt(32)
		end
	end
	local punishments = {}
	for index = 1, net.ReadUInt(7) do
		punishments[index] = {
			id = net.ReadUInt(32),
			kind = net.ReadBool() and "blacklist" or "warning",
			target_id = string.sub(net.ReadString(), 1, 17),
			target_name = string.sub(net.ReadString(), 1, 64),
			offense = string.sub(net.ReadString(), 1, 160),
			issued_at = net.ReadUInt(32),
			issuer_name = string.sub(net.ReadString(), 1, 64),
			active = net.ReadBool(),
			lifted_at = net.ReadUInt(32),
			lifted_by = string.sub(net.ReadString(), 1, 64)
		}
	end
	openAdminPanel(entries, canConfigureRanks, rankMasks, punishments)
end)
