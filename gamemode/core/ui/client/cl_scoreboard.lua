local Scoreboard = DRP.Scoreboard or {}
DRP.Scoreboard = Scoreboard

local colors = DRP.UI.Colors
local activeBoard

surface.CreateFont("DRP.Scoreboard.Title", { font = "Roboto", size = 31, weight = 800 })
surface.CreateFont("DRP.Scoreboard.Name", { font = "Roboto", size = 19, weight = 700 })
surface.CreateFont("DRP.Scoreboard.Value", { font = "Roboto", size = 16, weight = 600 })
surface.CreateFont("DRP.Scoreboard.Small", { font = "Roboto", size = 13, weight = 600 })

local prestigeIcons = {}
for prestige = 1, 10 do
	prestigeIcons[prestige] = Material(string.format("darkrp/prestige/prestige_%02d.png", prestige), "smooth")
end

concommand.Add("drp_prestige_icons_status", function()
	for prestige = 1, 10 do
		local path = string.format("materials/darkrp/prestige/prestige_%02d.png", prestige)
		local material = prestigeIcons[prestige]
		print(string.format(
			"[DRP PRESTIGE] %02d file=%s material=%s",
			prestige,
			tostring(file.Exists(path, "GAME")),
			tostring(material ~= nil and not material:IsError())
		))
	end
	local ply = LocalPlayer()
	if IsValid(ply) then
		print(string.format("[DRP PRESTIGE] local level=%d prestige=%d", ply:DRPXPLevel(), ply:DRPXPPrestige()))
	end
end)

local rankColors = {
	owner = Color(255, 190, 75),
	headadmin = Color(240, 105, 145),
	admin = Color(244, 105, 128),
	moderator = Color(157, 120, 255),
	supporter = Color(255, 140, 80),
	vipplus = Color(255, 175, 115),
	trusted = Color(104, 235, 150),
	vip = Color(255, 213, 92),
	user = colors.muted
}

local function rankKey(ply)
	if not IsValid(ply) then return "user" end
	return DRP.AdminRank(DRP.Roster and DRP.Roster.Value(ply, "rank", "user") or "user").key
end

local function jobColor(ply)
	local job = IsValid(ply) and ply:DRPJob() or nil
	return job and job.color or colors.muted
end

local function fitText(text, font, maximumWidth)
	text = tostring(text or "")
	surface.SetFont(font)
	if surface.GetTextSize(text) <= maximumWidth then return text end
	local suffix = "…"
	while #text > 1 and surface.GetTextSize(text .. suffix) > maximumWidth do text = string.sub(text, 1, -2) end
	return text .. suffix
end

local function civicReputation(value)
	if value <= -750 then return "Notorious", colors.red end
	if value <= -400 then return "Criminal", colors.red end
	if value <= -150 then return "Fringe", Color(244, 151, 72) end
	if value < 150 then return "Neutral", colors.accent end
	if value < 400 then return "Upstanding", colors.green end
	if value < 750 then return "Exemplary", colors.green end
	return "Civic Pillar", colors.green
end

local function trustPresentation(score, known)
	if known <= 2 then return "PROVISIONAL", colors.muted end
	if score >= 80 then return "ESTABLISHED", colors.green end
	if score >= 65 then return "TRUSTED", colors.green end
	if score >= 45 then return "UNVERIFIED", Color(255, 190, 75) end
	if score >= 25 then return "ELEVATED", Color(244, 151, 72) end
	return "HIGH RISK", colors.red
end

-- All information after the player identity occupies the same seven-column grid.
-- Keeping one source of truth prevents Civic/Ping (or future fields) drifting
-- into one another at different resolutions.
local function scoreColumnX(width, index)
	local gridStart = width * 0.40
	local gridEnd = width - 8
	local columnWidth = (gridEnd - gridStart) / 7
	return gridStart + (index - 0.5) * columnWidth
end

local function openSteamProfile(ply)
	if not IsValid(ply) or ply:IsBot() then return end
	if isfunction(ply.ShowProfile) then
		ply:ShowProfile()
		return
	end
	local steamID64 = ply:SteamID64()
	if steamID64 and steamID64 ~= "" and steamID64 ~= "0" then
		gui.OpenURL("https://steamcommunity.com/profiles/" .. steamID64)
	end
end

local function showPlayerMenu(ply)
	if not IsValid(ply) then return end
	local menu = DermaMenu()
	menu:AddOption("Copy SteamID", function() SetClipboardText(ply:SteamID()) end):SetIcon("icon16/page_copy.png")
	menu:AddOption("Copy SteamID64", function() SetClipboardText(ply:SteamID64()) end):SetIcon("icon16/page_copy.png")
	if not ply:IsBot() then
		menu:AddSpacer()
		menu:AddOption("Open Steam profile", function() openSteamProfile(ply) end):SetIcon("icon16/world_link.png")
	end
	menu:Open()
end

local function sortedPlayers()
	local output = player.GetAll()
	table.sort(output, function(first, second)
		local firstRank = DRP.AdminRankLevel(rankKey(first))
		local secondRank = DRP.AdminRankLevel(rankKey(second))
		if firstRank ~= secondRank then return firstRank > secondRank end
		local firstJob = first:DRPJobID()
		local secondJob = second:DRPJobID()
		if firstJob ~= secondJob then return firstJob < secondJob end
		return string.lower(first:Nick()) < string.lower(second:Nick())
	end)
	return output
end

local function addPlayerRow(parent, ply)
	local row = vgui.Create("DButton", parent)
	row:Dock(TOP)
	row:DockMargin(0, 0, 0, 8)
	row:SetTall(78)
	row:SetText("")
	row:SetCursor(ply:IsBot() and "arrow" or "hand")

	local avatar = vgui.Create("AvatarImage", row)
	avatar:SetSize(52, 52)
	avatar:SetPos(14, 13)
	avatar:SetPlayer(ply, 64)
	avatar:SetMouseInputEnabled(false)

	local mute = vgui.Create("DButton", row)
	mute:SetSize(92, 34)
	mute:SetFont("DRP.Scoreboard.Small")
	mute:SetTextColor(color_white)
	mute:SetVisible(ply ~= LocalPlayer())
	mute.DoClick = function()
		if IsValid(ply) then ply:SetMuted(not ply:IsMuted()) end
	end
	mute.Paint = function(self, width, height)
		local muted = IsValid(ply) and ply:IsMuted()
		local fill = muted and colors.red or colors.panelHover
		if self:IsHovered() then fill = muted and Color(255, 125, 145) or colors.accentSoft end
		draw.RoundedBox(7, 0, 0, width, height, fill)
	end
	mute.Think = function(self)
		if IsValid(ply) then self:SetText(ply:IsMuted() and "UNMUTE" or "MUTE") end
	end

	row.PerformLayout = function(self, width)
		mute:SetPos(scoreColumnX(width, 7) - mute:GetWide() * 0.5, 22)
	end

	row.Paint = function(self, width, height)
		if not IsValid(ply) then return end
		local roleColor = jobColor(ply)
		local key = rankKey(ply)
		local rankColor = rankColors[key] or colors.muted
		local base = self:IsHovered() and colors.panelHover or colors.panel
		local roster = DRP.Roster and DRP.Roster.Get(ply) or nil
		local trust = math.Clamp(math.floor(tonumber(roster and roster.trust) or 50), 0, 100)
		local trustKnown = math.Clamp(math.floor(tonumber(roster and roster.trustKnown) or 0), 0, 7)
		local trustLabel, trustColor = trustPresentation(trust, trustKnown)

		draw.RoundedBox(9, 0, 0, width, height, base)
		draw.RoundedBox(9, 0, 0, width, height, Color(roleColor.r, roleColor.g, roleColor.b, self:IsHovered() and 35 or 20))
		if trustKnown >= 3 and trust < 45 then draw.RoundedBox(9, 0, 0, width, height, Color(trustColor.r, trustColor.g, trustColor.b, trust < 25 and 38 or 23)) end
		draw.RoundedBoxEx(9, 0, 0, 5, height, roleColor, true, false, true, false)
		draw.RoundedBoxEx(9, width - 4, 0, 4, height, trustColor, false, true, false, true)

		local steamName = ply:Nick()
		local rpName = ply:DRPName()
		local adminMode = roster and roster.adminMode == true or false
		local afk = roster and roster.afk == true or false
		local badgeWidth = (adminMode and 94 or 0) + (afk and 42 or 0) + (adminMode and afk and 6 or 0)
		local playerColumnEnd = width * 0.40 - 12
		local displayName = fitText(steamName, "DRP.Scoreboard.Name", math.max(80, playerColumnEnd - 82 - badgeWidth - 12))
		draw.SimpleText(displayName, "DRP.Scoreboard.Name", 82, 25, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		surface.SetFont("DRP.Scoreboard.Name")
		local nameWidth = surface.GetTextSize(displayName)
		local badgeX = 82 + nameWidth + 10
		if adminMode then
			draw.RoundedBox(5, badgeX, 14, 94, 22, Color(colors.accent.r, colors.accent.g, colors.accent.b, 42))
			draw.SimpleText("ADMIN MODE", "DRP.Scoreboard.Small", badgeX + 47, 25, colors.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			badgeX = badgeX + 100
		end
		if afk then
			draw.RoundedBox(5, badgeX, 14, 42, 22, Color(255, 190, 75, 42))
			draw.SimpleText("AFK", "DRP.Scoreboard.Small", badgeX + 21, 25, Color(255, 190, 75), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		if rpName ~= steamName then
			draw.SimpleText(fitText("RP: " .. rpName, "DRP.Scoreboard.Small", playerColumnEnd - 82), "DRP.Scoreboard.Small", 82, 51, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		else
			draw.SimpleText(ply:SteamID(), "DRP.Scoreboard.Small", 82, 51, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		local level = math.Clamp(ply:DRPXPLevel(), 1, 100)
		local prestige = math.Clamp(ply:DRPXPPrestige(), 0, 10)
		local levelX = scoreColumnX(width, 1)
		local prestigeIcon = prestigeIcons[prestige]
		if prestige > 0 and prestigeIcon and not prestigeIcon:IsError() then
			local iconSize = 34
			surface.SetMaterial(prestigeIcon)
			surface.SetDrawColor(255, 255, 255, 255)
			surface.DrawTexturedRect(levelX - 48, math.floor((height - iconSize) * 0.5), iconSize, iconSize)
			draw.SimpleText("LVL " .. level, "DRP.Scoreboard.Value", levelX + 13, height * 0.5, colors.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		else
			draw.SimpleText("LVL " .. level, "DRP.Scoreboard.Value", levelX, height * 0.5, colors.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		draw.SimpleText(ply:DRPJobName(), "DRP.Scoreboard.Value", scoreColumnX(width, 2), height * 0.5, roleColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		local supporterTier = math.Clamp(math.floor(tonumber(roster and roster.supporterTier) or 0), 0, 3)
		if supporterTier > 0 then
			local supporter = DRP.Supporter.Definition(supporterTier)
			draw.SimpleText(DRP.AdminRankLabel(key), "DRP.Scoreboard.Value", scoreColumnX(width, 3), 28, rankColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			draw.SimpleText(string.format("%.2gx • +%d ENT • %d BASE", supporter.multiplier, supporter.entityBonus, supporter.propertyLimit), "DRP.Scoreboard.Small", scoreColumnX(width, 3), 50, colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		else
			draw.SimpleText(DRP.AdminRankLabel(key), "DRP.Scoreboard.Value", scoreColumnX(width, 3), height * 0.5, rankColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		local civic = math.Clamp(roster and roster.civic or 0, -1000, 1000)
		local reputation, civicColor = civicReputation(civic)
		draw.SimpleText((civic > 0 and "+" or "") .. civic, "DRP.Scoreboard.Value", scoreColumnX(width, 4), 28, civicColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText(reputation, "DRP.Scoreboard.Small", scoreColumnX(width, 4), 50, colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText(trust .. "/100", "DRP.Scoreboard.Value", scoreColumnX(width, 5), 28, trustColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText(trustLabel, "DRP.Scoreboard.Small", scoreColumnX(width, 5), 50, colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText(ply:Ping() .. " ms", "DRP.Scoreboard.Value", scoreColumnX(width, 6), height * 0.5, ply:Ping() < 100 and colors.green or (ply:Ping() < 180 and Color(255, 190, 75) or colors.red), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	row.DoClick = function()
		if IsValid(ply) then openSteamProfile(ply) end
	end
	row.DoRightClick = function()
		if IsValid(ply) then showPlayerMenu(ply) end
	end
	return row
end

function Scoreboard.Close()
	if IsValid(activeBoard) then activeBoard:Remove() end
	activeBoard = nil
	gui.EnableScreenClicker(false)
end

function Scoreboard.Open()
	if IsValid(activeBoard) then return end

	local frame = vgui.Create("DFrame")
	activeBoard = frame
	frame:SetSize(math.min(1160, ScrW() - 56), math.min(760, ScrH() - 72))
	frame:Center()
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:SetDraggable(false)
	frame:SetDeleteOnClose(true)
	frame:MakePopup()

	frame.Paint = function(_, width, height)
		draw.RoundedBox(12, 0, 0, width, height, colors.background)
		draw.RoundedBoxEx(12, 0, 0, width, 82, colors.panel, true, true, false, false)
		draw.RoundedBox(12, 0, 0, 5, height, colors.accent)
		draw.SimpleText(GetHostName(), "DRP.Scoreboard.Title", 26, 29, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(#player.GetAll() .. " / " .. game.MaxPlayers() .. " ONLINE", "DRP.Scoreboard.Small", 27, 59, colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("LEFT CLICK  OPEN PROFILE    •    RIGHT CLICK  PLAYER OPTIONS", "DRP.Scoreboard.Small", width - 25, 42, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		surface.SetDrawColor(colors.accent)
		surface.DrawRect(0, 80, width, 2)
	end

	local header = vgui.Create("DPanel", frame)
	header:Dock(TOP)
	header:DockMargin(18, 90, 18, 8)
	header:SetTall(28)
	header.Paint = function(_, width, height)
		draw.SimpleText("PLAYER", "DRP.Scoreboard.Small", 82, height * 0.5, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("LEVEL", "DRP.Scoreboard.Small", scoreColumnX(width, 1), height * 0.5, colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("ROLE", "DRP.Scoreboard.Small", scoreColumnX(width, 2), height * 0.5, colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("RANK", "DRP.Scoreboard.Small", scoreColumnX(width, 3), height * 0.5, colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("CIVIC", "DRP.Scoreboard.Small", scoreColumnX(width, 4), height * 0.5, colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("TRUST", "DRP.Scoreboard.Small", scoreColumnX(width, 5), height * 0.5, colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("PING", "DRP.Scoreboard.Small", scoreColumnX(width, 6), height * 0.5, colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("VOICE", "DRP.Scoreboard.Small", scoreColumnX(width, 7), height * 0.5, colors.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	local scroll = vgui.Create("DScrollPanel", frame)
	scroll:Dock(FILL)
	scroll:DockMargin(18, 0, 18, 16)
	local canvas = scroll:GetCanvas()
	canvas:DockPadding(0, 0, 4, 0)

	local function rebuild()
		canvas:Clear()
		for _, ply in ipairs(sortedPlayers()) do addPlayerRow(canvas, ply) end
	end
	rebuild()
	frame.RebuildRoster = rebuild
	frame.OnRemove = function()
		if activeBoard == frame then activeBoard = nil end
		gui.EnableScreenClicker(false)
	end
end

local function rosterChanged()
	if IsValid(activeBoard) and isfunction(activeBoard.RebuildRoster) then activeBoard:RebuildRoster() end
end

hook.Add("DRPRosterSnapshot", "DRP.Scoreboard.RosterSnapshot", rosterChanged)
hook.Add("DRPRosterChanged", "DRP.Scoreboard.RosterChanged", rosterChanged)
hook.Add("DRPRosterRemoved", "DRP.Scoreboard.RosterRemoved", rosterChanged)

hook.Add("ScoreboardShow", "DRP.Scoreboard.Show", function()
	Scoreboard.Open()
	return true
end)

hook.Add("ScoreboardHide", "DRP.Scoreboard.Hide", function()
	Scoreboard.Close()
	return true
end)
