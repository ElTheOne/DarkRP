DRP.MediaPlayerLiveUI = DRP.MediaPlayerLiveUI or {}

local LiveUI = DRP.MediaPlayerLiveUI
local config = DRP.MediaPlayerLiveUIConfig or {}
local ENTRY_RANGE = math.max(128, tonumber(config.EntryRange) or 280)
local EXIT_RANGE = math.max(ENTRY_RANGE, tonumber(config.ExitRange) or 340)
local SCAN_INTERVAL = math.max(0.2, tonumber(config.ScanInterval) or 0.4)
local SCREEN_CLASS = "mediaplayer_tv"
local TIMER_NAME = "DRP.MediaPlayer.LiveProximity"

LiveUI.Entity = IsValid(LiveUI.Entity) and LiveUI.Entity or nil
LiveUI.Player = LiveUI.Player and IsValid(LiveUI.Player) and LiveUI.Player or nil
LiveUI.OwnsSidebar = LiveUI.OwnsSidebar == true
LiveUI.UsingNativeSidebar = LiveUI.UsingNativeSidebar == true
LiveUI.Panel = IsValid(LiveUI.Panel) and LiveUI.Panel or nil
LiveUI.NextListenerRequest = tonumber(LiveUI.NextListenerRequest) or 0
LiveUI.NextVisibilityCheck = tonumber(LiveUI.NextVisibilityCheck) or 0
LiveUI.LastVisibility = LiveUI.LastVisibility == true
local screens = setmetatable({}, { __mode = "k" })
local visibilityTrace = { start = vector_origin, endpos = vector_origin, filter = NULL, mask = MASK_SOLID }

local function requestListener(entity, listening)
	if not isstring(DRP.MediaPlayerLiveMessage) or DRP.MediaPlayerLiveMessage == "" then return end
	net.Start(DRP.MediaPlayerLiveMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteEntity(IsValid(entity) and entity or NULL)
		net.WriteBool(listening == true)
	net.SendToServer()
end

local function addonReady()
	return istable(MediaPlayer)
		and isfunction(MediaPlayer.GetByObject)
end

local function nativeLiveSidebarReady()
	return addonReady()
		and isfunction(MediaPlayer.ShowLiveSidebar)
		and isfunction(MediaPlayer.HideSidebar)
end

local function canDisplay()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return false end
	if gui.IsGameUIVisible() or gui.IsConsoleVisible() then return false end
	if DRP.UI and isfunction(DRP.UI.ToolgunFocus) and DRP.UI.ToolgunFocus() then return false end
	return true
end

local function isScreen(entity)
	return IsValid(entity)
		and entity:GetClass() == SCREEN_CLASS
		and entity.IsMediaPlayerEntity == true
end

local function screenDistanceSquared(ply, entity)
	local eyePosition = ply:EyePos()
	return eyePosition:DistToSqr(entity:NearestPoint(eyePosition))
end

local function hasLineOfSight(ply, entity)
	local eyePosition = ply:EyePos()
	visibilityTrace.start = eyePosition
	visibilityTrace.filter = ply
	for index = 1, 2 do
		visibilityTrace.endpos = index == 1 and entity:NearestPoint(eyePosition) or entity:WorldSpaceCenter()
		local trace = util.TraceLine(visibilityTrace)
		if not trace.Hit or trace.Entity == entity or trace.Fraction >= 0.98 then return true end
	end
	return false
end

local function indexScreen(entity)
	if IsValid(entity) and entity:GetClass() == SCREEN_CLASS then screens[entity] = true end
end

hook.Add("InitPostEntity", "DRP.MediaPlayer.LiveScreenIndex", function()
	for _, entity in ipairs(ents.FindByClass(SCREEN_CLASS)) do indexScreen(entity) end
end)

hook.Add("OnEntityCreated", "DRP.MediaPlayer.LiveScreenIndex", function(entity)
	if not IsValid(entity) or entity:GetClass() ~= SCREEN_CLASS then return end
	timer.Simple(0, function() indexScreen(entity) end)
end)

hook.Add("EntityRemoved", "DRP.MediaPlayer.LiveScreenUnindex", function(entity)
	screens[entity] = nil
end)

local function resolvePlayer(entity)
	if not isScreen(entity) or not addonReady() then return nil end
	local mediaPlayer = MediaPlayer.GetByObject(entity)
	return IsValid(mediaPlayer) and mediaPlayer or nil
end

local function mediaValue(media, method, fallback)
	if not media or not isfunction(media[method]) then return fallback end
	local ok, value = pcall(media[method], media)
	if not ok or value == nil then return fallback end
	return value
end

local function removeFallbackPanel()
	if IsValid(LiveUI.Panel) then LiveUI.Panel:Remove() end
	LiveUI.Panel = nil
end

local function createFallbackPanel()
	if IsValid(LiveUI.Panel) then return LiveUI.Panel end
	local colors = DRP.UI.Colors
	local panel = vgui.Create("DPanel")
	panel:SetSize(math.min(380, ScrW() - 36), math.min(520, ScrH() - 72))
	panel:SetPos(18, math.max(36, math.floor((ScrH() - panel:GetTall()) * 0.5)))
	panel:SetZPos(32767)
	panel:SetDrawOnTop(true)
	panel:SetKeyboardInputEnabled(false)
	panel:SetMouseInputEnabled(DRP.UI.CursorMode == true)
	panel.MediaPlayer = nil
	panel.Entity = nil
	panel.Fingerprint = ""
	panel.Status = "Synchronizing media player..."
	panel.Paint = function(self, width, height)
		draw.RoundedBox(10, 0, 0, width, height, ColorAlpha(colors.background, 244))
		draw.RoundedBoxEx(10, 0, 0, 5, height, colors.accent, true, false, true, false)
		draw.RoundedBoxEx(10, 5, 0, width - 5, 66, colors.panel, false, true, false, false)
		draw.SimpleText("MEDIA PLAYER", "DRP.Admin.Title", 22, 20, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText(DRP.UI.CursorMode and "LIVE CONTROLS  •  F3 / Z TO RETURN" or "LIVE  •  F3 / Z TO INTERACT",
			"DRP.Admin.Small", 22, 48, colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(self.Status, "DRP.Admin.Small", 20, height - 18, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local nowPlaying = vgui.Create("DPanel", panel)
	nowPlaying:SetPos(18, 82)
	nowPlaying:SetSize(panel:GetWide() - 36, 82)
	nowPlaying.Title = "Waiting for media..."
	nowPlaying.Detail = "The server is sending the live queue."
	nowPlaying.Paint = function(self, width, height)
		draw.RoundedBox(7, 0, 0, width, height, colors.panelHover)
		draw.RoundedBox(0, 0, 0, 4, height, colors.green)
		draw.SimpleText("NOW PLAYING", "DRP.Admin.Small", 14, 12, colors.green, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText(self.Title, "DRP.Admin.Header", 14, 32, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText(self.Detail, "DRP.Admin.Small", 14, 58, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	end
	panel.NowPlaying = nowPlaying

	local request = DRP.UI.Button(panel, "REQUEST MEDIA", colors.green, function()
		if not DRP.UI.CursorMode or not IsValid(panel.MediaPlayer) then return end
		if MediaPlayer and isfunction(MediaPlayer.OpenRequestMenu) then MediaPlayer.OpenRequestMenu(panel.MediaPlayer) end
	end)
	request:SetPos(18, 176)
	request:SetSize(panel:GetWide() - 36, 38)
	panel.RequestButton = request

	local half = math.floor((panel:GetWide() - 46) * 0.5)
	local pause = DRP.UI.Button(panel, "PLAY / PAUSE", colors.accent, function()
		if DRP.UI.CursorMode and IsValid(panel.MediaPlayer) and MediaPlayer and isfunction(MediaPlayer.Pause) then
			MediaPlayer.Pause(panel.MediaPlayer)
		end
	end)
	pause:SetPos(18, 224)
	pause:SetSize(half, 36)
	panel.PauseButton = pause

	local skip = DRP.UI.Button(panel, "SKIP", colors.red, function()
		if DRP.UI.CursorMode and IsValid(panel.MediaPlayer) and MediaPlayer and isfunction(MediaPlayer.Skip) then
			MediaPlayer.Skip(panel.MediaPlayer)
		end
	end)
	skip:SetPos(28 + half, 224)
	skip:SetSize(panel:GetWide() - half - 46, 36)
	panel.SkipButton = skip

	local queueTitle = vgui.Create("DLabel", panel)
	queueTitle:SetPos(18, 272)
	queueTitle:SetSize(panel:GetWide() - 36, 24)
	queueTitle:SetFont("DRP.Admin.Header")
	queueTitle:SetTextColor(color_white)
	queueTitle:SetText("UP NEXT")
	panel.QueueTitle = queueTitle

	local queue = vgui.Create("DScrollPanel", panel)
	queue:SetPos(18, 302)
	queue:SetSize(panel:GetWide() - 36, panel:GetTall() - 338)
	panel.Queue = queue
	LiveUI.Panel = panel
	return panel
end

local function refreshFallbackPanel(entity, mediaPlayer)
	local panel = createFallbackPanel()
	panel.Entity = entity
	panel.MediaPlayer = mediaPlayer
	local interactive = DRP.UI.CursorMode == true
	panel:SetMouseInputEnabled(interactive)
	local ready = IsValid(mediaPlayer)
	panel.RequestButton:SetEnabled(ready and interactive)
	panel.PauseButton:SetEnabled(ready and interactive)
	panel.SkipButton:SetEnabled(ready and interactive)
	if not ready then
		panel.Status = addonReady() and "Synchronizing media player..." or "Waiting for Media Player Redux client files..."
		panel.NowPlaying.Title = "Connecting..."
		panel.NowPlaying.Detail = "Stay near the screen while its live state is loaded."
		return
	end

	panel.Status = interactive and "Controls enabled." or "Playback is live; enable cursor mode to interact."
	local current = isfunction(mediaPlayer.GetMedia) and mediaPlayer:GetMedia() or nil
	panel.NowPlaying.Title = tostring(mediaValue(current, "Title", "Nothing playing"))
	panel.NowPlaying.Detail = current and tostring(mediaValue(current, "OwnerName", "Unknown requester")) or "Request media to begin playback."
	local mediaQueue = isfunction(mediaPlayer.GetMediaQueue) and mediaPlayer:GetMediaQueue() or {}
	local parts = { tostring(mediaValue(current, "UniqueID", "none")), tostring(#mediaQueue) }
	for index, media in ipairs(mediaQueue) do
		parts[#parts + 1] = tostring(mediaValue(media, "UniqueID", index))
	end
	local fingerprint = table.concat(parts, ":")
	if panel.Fingerprint == fingerprint then return end
	panel.Fingerprint = fingerprint
	panel.QueueTitle:SetText("UP NEXT  •  " .. #mediaQueue)
	panel.Queue:GetCanvas():Clear()
	for index, media in ipairs(mediaQueue) do
		local row = panel.Queue:Add("DPanel")
		row:Dock(TOP)
		row:DockMargin(0, 0, 0, 6)
		row:SetTall(48)
		row.TrackTitle = tostring(mediaValue(media, "Title", "Unknown media"))
		row.Paint = function(self, width, height)
			draw.RoundedBox(6, 0, 0, width, height, DRP.UI.Colors.panelHover)
			draw.SimpleText(string.format("%02d", index), "DRP.Admin.Small", 12, height * 0.5, DRP.UI.Colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(self.TrackTitle, "DRP.Admin.Body", 44, height * 0.5, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end
end

function LiveUI.Hide()
	local entity = LiveUI.Entity
	if LiveUI.UsingNativeSidebar and nativeLiveSidebarReady()
		and isfunction(MediaPlayer.IsLiveSidebarVisible) and MediaPlayer.IsLiveSidebarVisible() then
		MediaPlayer.HideSidebar()
	end
	removeFallbackPanel()
	LiveUI.Entity = nil
	LiveUI.Player = nil
	LiveUI.OwnsSidebar = false
	LiveUI.UsingNativeSidebar = false
	LiveUI.NextListenerRequest = 0
	LiveUI.NextVisibilityCheck = 0
	LiveUI.LastVisibility = false
	if IsValid(entity) then requestListener(entity, false) end
end

local function chooseScreen(ply)
	local current = LiveUI.Entity
	if isScreen(current) and screenDistanceSquared(ply, current) <= EXIT_RANGE * EXIT_RANGE then
		if RealTime() >= LiveUI.NextVisibilityCheck then
			LiveUI.NextVisibilityCheck = RealTime() + 0.5
			LiveUI.LastVisibility = hasLineOfSight(ply, current)
		end
		if LiveUI.LastVisibility then return current end
	end

	local nearest
	local nearestDistance = ENTRY_RANGE * ENTRY_RANGE
	-- Screens are capped server-side, so a class index is both cheaper and more
	-- accurate than a radius query around origins of very large billboards.
	for entity in pairs(screens) do
		if isScreen(entity) then
			local distance = screenDistanceSquared(ply, entity)
			if distance < nearestDistance and hasLineOfSight(ply, entity) then
				nearest = entity
				nearestDistance = distance
			end
		else
			screens[entity] = nil
		end
	end
	return nearest
end

function LiveUI.Refresh()
	if not canDisplay() then
		LiveUI.Hide()
		return
	end

	local entity = chooseScreen(LocalPlayer())
	if entity ~= LiveUI.Entity then
		local previous = LiveUI.Entity
		if IsValid(previous) then requestListener(previous, false) end
		LiveUI.Entity = entity
		LiveUI.Player = nil
		LiveUI.NextListenerRequest = RealTime() + 1
		LiveUI.NextVisibilityCheck = RealTime() + 0.5
		LiveUI.LastVisibility = IsValid(entity)
		if IsValid(entity) then requestListener(entity, true) end
	end
	if not IsValid(entity) then
		LiveUI.Hide()
		return
	end

	local mediaPlayer = resolvePlayer(entity)
	if not IsValid(mediaPlayer) then
		LiveUI.OwnsSidebar = true
		LiveUI.UsingNativeSidebar = false
		refreshFallbackPanel(entity, nil)
		if LiveUI.NextListenerRequest <= RealTime() then
			LiveUI.NextListenerRequest = RealTime() + 1
			requestListener(entity, true)
		end
		return
	end

	LiveUI.Player = mediaPlayer
	LiveUI.OwnsSidebar = true
	-- Keep the proximity presentation owned by the gamemode. Workshop clients
	-- commonly have the stock sidebar, which has no non-modal live API, while a
	-- server may have a newer source copy. A single DRP panel behaves identically
	-- for both and never steals movement input.
	LiveUI.UsingNativeSidebar = false
	refreshFallbackPanel(entity, mediaPlayer)
end

timer.Remove(TIMER_NAME)
timer.Create(TIMER_NAME, SCAN_INTERVAL, 0, LiveUI.Refresh)

hook.Add("DRPCursorModeChanged", "DRP.MediaPlayer.LiveInteraction", function(enabled)
	if not LiveUI.OwnsSidebar then return end
	if LiveUI.UsingNativeSidebar and nativeLiveSidebarReady() and isfunction(MediaPlayer.SetLiveSidebarInteraction) then
		MediaPlayer.SetLiveSidebarInteraction(enabled == true)
	end
	if IsValid(LiveUI.Panel) then
		LiveUI.Panel:SetMouseInputEnabled(enabled == true)
		refreshFallbackPanel(LiveUI.Entity, LiveUI.Player)
	end
end)

hook.Add("EntityRemoved", "DRP.MediaPlayer.LiveEntityRemoved", function(entity)
	if entity == LiveUI.Entity then LiveUI.Hide() end
end)

hook.Add("ShutDown", "DRP.MediaPlayer.LiveShutdown", function()
	timer.Remove(TIMER_NAME)
	LiveUI.Hide()
end)

concommand.Add("drp_media_live_status", function()
	local entity = LiveUI.Entity
	print(string.format(
		"[DRP MEDIA LIVE] addon=%s native=%s active=%s entity=%s distance=%s cursor=%s sidebar=%s fallback=%s controller=%s",
		tostring(addonReady()),
		tostring(nativeLiveSidebarReady()),
		tostring(LiveUI.OwnsSidebar),
		IsValid(entity) and (entity:GetClass() .. "#" .. entity:EntIndex()) or "none",
		IsValid(entity) and math.floor(math.sqrt(screenDistanceSquared(LocalPlayer(), entity))) or "n/a",
		tostring(DRP.UI and DRP.UI.CursorMode == true),
		tostring(nativeLiveSidebarReady() and isfunction(MediaPlayer.IsLiveSidebarVisible) and MediaPlayer.IsLiveSidebarVisible() or false),
		tostring(IsValid(LiveUI.Panel)),
		tostring(IsValid(LiveUI.Player))
	))
end)
