local OPEN_MESSAGE = "drp_mp3_open_v1"
local VOLUME_MESSAGE = "drp_mp3_volume_v1"
local QUEUE_MESSAGE = "drp_mp3_queue_action_v1"
local LIBRARY_REQUEST_MESSAGE = "drp_mp3_library_request_v1"
local LIBRARY_SYNC_MESSAGE = "drp_mp3_library_sync_v1"
local LIBRARY_ACTION_MESSAGE = "drp_mp3_library_action_v1"
local activePanel
local savedLibrary = { revision = 0, playlists = {} }

local QUEUE_REMOVE = 1
local QUEUE_MOVE_UP = 2
local QUEUE_MOVE_DOWN = 3
local QUEUE_CLEAR = 4

local LIBRARY_CREATE = 1
local LIBRARY_DELETE = 2
local LIBRARY_ADD_TRACK = 3
local LIBRARY_REMOVE_TRACK = 4
local LIBRARY_QUEUE_TRACK = 5
local LIBRARY_QUEUE_ALL = 6
local LIBRARY_RENAME = 7

local colors = {
	background = Color(7, 14, 27, 248),
	panel = Color(15, 28, 47, 245),
	panelLight = Color(23, 41, 65, 245),
	cyan = Color(71, 216, 255),
	green = Color(94, 225, 177),
	muted = Color(157, 177, 202),
	white = Color(242, 248, 255),
	danger = Color(244, 100, 123),
	warning = Color(255, 190, 87)
}

local function themedButton(parent, text, color)
	local button = vgui.Create("DButton", parent)
	button:SetText("")
	button.Label = text
	button.ButtonColor = color or colors.cyan
	button.Paint = function(self, width, height)
		local buttonColor = self:IsEnabled() and self.ButtonColor or colors.muted
		local alpha = self:IsHovered() and self:IsEnabled() and 245 or 205
		draw.RoundedBox(7, 0, 0, width, height, ColorAlpha(buttonColor, alpha))
		draw.SimpleText(self.Label, "DermaDefaultBold", width * 0.5, height * 0.5, colors.background, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	return button
end

local function sendVolume(entity, value)
	if not IsValid(entity) then return end
	net.Start(VOLUME_MESSAGE)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteEntity(entity)
		net.WriteUInt(math.Clamp(math.Round(value), 0, 100), 7)
	net.SendToServer()
end

local function sendQueueAction(entity, action, uid)
	if not IsValid(entity) then return end
	net.Start(QUEUE_MESSAGE)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteEntity(entity)
		net.WriteUInt(action, 3)
		net.WriteString(uid or "")
	net.SendToServer()
end

local function sendLibraryAction(entity, action, playlistID, name, title, url, trackIndex)
	net.Start(LIBRARY_ACTION_MESSAGE)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(action, 3)
		net.WriteString(playlistID or "")
		net.WriteString(name or "")
		net.WriteString(title or "")
		net.WriteString(url or "")
		net.WriteUInt(math.Clamp(math.floor(tonumber(trackIndex) or 0), 0, 63), 6)
		net.WriteEntity(IsValid(entity) and entity or NULL)
	net.SendToServer()
end

local function requestLibrary()
	net.Start(LIBRARY_REQUEST_MESSAGE)
		net.WriteUInt(DRP.ProtocolVersion, 8)
	net.SendToServer()
end

net.Receive(LIBRARY_SYNC_MESSAGE, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length = net.ReadUInt(18)
	if length <= 0 or length > 262143 then return end
	local raw = util.Decompress(net.ReadData(length) or "")
	local decoded = raw and util.JSONToTable(raw) or nil
	if not istable(decoded) or not istable(decoded.playlists) then return end
	savedLibrary = decoded
	hook.Run("DRPMP3LibraryUpdated", savedLibrary)
end)

local function mediaValue(media, method, fallback)
	if not media or not isfunction(media[method]) then return fallback end
	local ok, value = pcall(media[method], media)
	if not ok or value == nil then return fallback end
	return value
end

local function formatDuration(seconds)
	seconds = math.floor(tonumber(seconds) or -1)
	if seconds < 0 then return "LIVE / UNKNOWN" end
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor(seconds / 60) % 60
	local remaining = seconds % 60
	if hours > 0 then return string.format("%d:%02d:%02d", hours, minutes, remaining) end
	return string.format("%02d:%02d", minutes, remaining)
end

local function getMediaPlayer(entity)
	if not IsValid(entity) or not isfunction(entity.GetMediaPlayer) then return nil end
	return entity:GetMediaPlayer()
end

local function openControls(entity, initialVolume, radius, canManage)
	if IsValid(activePanel) then activePanel:Remove() end
	if not IsValid(entity) then return end

	local frame = vgui.Create("DFrame")
	activePanel = frame
	frame:SetSize(math.min(ScrW() - 40, 1180), math.min(ScrH() - 40, 620))
	frame:Center()
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:SetDraggable(true)
	frame:MakePopup()
	frame.MP3Entity = entity
	frame.SelectedUID = nil
	frame.SelectedPlaylistID = nil
	frame.CanManage = canManage == true
	frame.OnRemove = function()
		hook.Remove("OnMediaPlayerUpdate", "DRP.MP3Playlist")
		hook.Remove("DRPMP3LibraryUpdated", "DRP.MP3LibraryPanel")
		if frame.BoundMediaPlayer and MP and MP.EVENTS then
			frame.BoundMediaPlayer:removeListener(MP.EVENTS.MEDIA_CHANGED, frame.MediaChangedHandle)
			frame.BoundMediaPlayer:removeListener(MP.EVENTS.QUEUE_CHANGED, frame.QueueChangedHandle)
		end
		if activePanel == frame then activePanel = nil end
	end
	frame.Paint = function(self, width, height)
		draw.RoundedBox(10, 0, 0, width, height, colors.background)
		draw.RoundedBoxEx(10, 0, 0, width, 58, colors.panel, true, true, false, false)
		draw.RoundedBox(0, 0, 56, width, 2, colors.cyan)
		draw.SimpleText("MP3 PLAYER", "DermaLarge", 22, 19, colors.white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText("SERVER-CONTROLLED PROXIMITY AUDIO", "DermaDefaultBold", 22, 43, colors.cyan, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local close = themedButton(frame, "×", colors.danger)
	close:SetSize(34, 30)
	close:SetPos(frame:GetWide() - 48, 14)
	close.DoClick = function() frame:Close() end

	local contentWidth = frame:GetWide() - 44
	local leftWidth = math.Clamp(math.floor(contentWidth * 0.29), 280, 340)
	local libraryWidth = math.Clamp(math.floor(contentWidth * 0.27), 270, 315)
	local libraryX = 22 + leftWidth + 18
	local rightX = libraryX + libraryWidth + 18
	local rightWidth = frame:GetWide() - rightX - 22

	local description = vgui.Create("DLabel", frame)
	description:SetPos(22, 74)
	description:SetSize(leftWidth, 38)
	description:SetFont("DermaDefault")
	description:SetTextColor(colors.muted)
	description:SetWrap(true)
	description:SetText("Queue supported audio. Everyone within " .. radius .. " units hears the owner-controlled mix.")

	local url = vgui.Create("DTextEntry", frame)
	url:SetPos(22, 122)
	url:SetSize(leftWidth, 38)
	url:SetPlaceholderText("Paste an MP3, SoundCloud, YouTube, or media URL")
	url:SetUpdateOnType(true)
	url:SetTextColor(colors.white)
	url:SetPlaceholderColor(colors.muted)
	url:SetDrawBackground(false)
	url.Paint = function(self, width, height)
		draw.RoundedBox(7, 0, 0, width, height, colors.panelLight)
		self:DrawTextEntryText(colors.white, colors.cyan, colors.white)
	end

	local slider = vgui.Create("DNumSlider", frame)
	slider:SetPos(18, 174)
	slider:SetSize(leftWidth + 8, 48)
	slider:SetText("SERVER VOLUME")
	slider:SetMin(0)
	slider:SetMax(100)
	slider:SetDecimals(0)
	slider:SetValue(initialVolume)
	slider:SetEnabled(frame.CanManage)
	if IsValid(slider.Label) then slider.Label:SetTextColor(colors.white) end
	if IsValid(slider.TextArea) then slider.TextArea:SetTextColor(colors.white) end

	local halfButton = math.floor((leftWidth - 10) * 0.5)
	local apply = themedButton(frame, "APPLY VOLUME", colors.green)
	apply:SetPos(22, 234)
	apply:SetSize(halfButton, 42)
	apply.DoClick = function() sendVolume(entity, slider:GetValue()) end
	apply:SetEnabled(frame.CanManage)

	local queue = themedButton(frame, "QUEUE AUDIO", colors.cyan)
	queue:SetPos(32 + halfButton, 234)
	queue:SetSize(leftWidth - halfButton - 10, 42)
	queue.DoClick = function()
		local value = string.Trim(url:GetValue() or "")
		if value == "" then return end
		if frame.CanManage then sendVolume(entity, slider:GetValue()) end
		if MediaPlayer and MediaPlayer.Request then MediaPlayer.Request(entity, value) end
		url:SetText("")
	end

	local pause = themedButton(frame, "PLAY / PAUSE", colors.warning)
	pause:SetPos(22, 288)
	pause:SetSize(halfButton, 42)
	pause.DoClick = function()
		if MediaPlayer and MediaPlayer.Pause then MediaPlayer.Pause(entity) end
	end
	pause:SetEnabled(frame.CanManage)

	local skip = themedButton(frame, "SKIP CURRENT", colors.danger)
	skip:SetPos(32 + halfButton, 288)
	skip:SetSize(leftWidth - halfButton - 10, 42)
	skip.DoClick = function()
		if MediaPlayer and MediaPlayer.Skip then MediaPlayer.Skip(entity) end
	end
	skip:SetEnabled(frame.CanManage)

	local repeatButton = themedButton(frame, "REPEAT: OFF", colors.cyan)
	repeatButton:SetPos(22, 342)
	repeatButton:SetSize(halfButton, 38)
	repeatButton.DoClick = function()
		if MediaPlayer and MediaPlayer.RequestRepeat then MediaPlayer.RequestRepeat(entity) end
	end
	repeatButton:SetEnabled(frame.CanManage)

	local shuffleButton = themedButton(frame, "SHUFFLE: OFF", colors.cyan)
	shuffleButton:SetPos(32 + halfButton, 342)
	shuffleButton:SetSize(leftWidth - halfButton - 10, 38)
	shuffleButton.DoClick = function()
		if MediaPlayer and MediaPlayer.RequestShuffle then MediaPlayer.RequestShuffle(entity) end
	end
	shuffleButton:SetEnabled(frame.CanManage)

	local help = vgui.Create("DLabel", frame)
	help:SetPos(22, 450)
	help:SetSize(leftWidth, frame:GetTall() - 468)
	help:SetFont("DermaDefault")
	help:SetTextColor(colors.muted)
	help:SetWrap(true)
	help:SetText(frame.CanManage and "Paste a YouTube Music or supported media link. Save it to your personal library, or queue it immediately for nearby listeners." or "Browse and queue music from your personal library. Volume, playback order and queue administration remain with this MP3 player's owner.")

	local browseMusic = themedButton(frame, "BROWSE YOUTUBE MUSIC", colors.green)
	browseMusic:SetPos(22, 398)
	browseMusic:SetSize(leftWidth, 38)
	browseMusic.DoClick = function()
		gui.OpenURL("https://music.youtube.com/")
	end

	local libraryTitle = vgui.Create("DLabel", frame)
	libraryTitle:SetPos(libraryX, 72)
	libraryTitle:SetSize(libraryWidth, 24)
	libraryTitle:SetFont("DermaLarge")
	libraryTitle:SetTextColor(colors.white)
	libraryTitle:SetText("YOUTUBE MUSIC")

	local libraryPanel = vgui.Create("DPanel", frame)
	libraryPanel:SetPos(libraryX, 104)
	libraryPanel:SetSize(libraryWidth, frame:GetTall() - 124)
	libraryPanel.Paint = function(self, width, height)
		draw.RoundedBox(7, 0, 0, width, height, colors.panel)
		draw.SimpleText("MY SAVED PLAYLISTS", "DermaDefaultBold", 12, 11, colors.cyan, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	end

	local playlistSelector = vgui.Create("DComboBox", libraryPanel)
	playlistSelector:SetPos(12, 34)
	playlistSelector:SetSize(libraryWidth - 24, 34)
	playlistSelector:SetValue("Select a playlist")
	playlistSelector:SetTextColor(colors.white)
	playlistSelector.Paint = function(self, width, height)
		draw.RoundedBox(6, 0, 0, width, height, colors.panelLight)
	end

	local libraryButtonWidth = math.floor((libraryWidth - 32) / 2)
	local createPlaylist = themedButton(libraryPanel, "NEW PLAYLIST", colors.green)
	createPlaylist:SetPos(12, 78)
	createPlaylist:SetSize(libraryButtonWidth, 34)
	local deletePlaylist = themedButton(libraryPanel, "DELETE", colors.danger)
	deletePlaylist:SetPos(20 + libraryButtonWidth, 78)
	deletePlaylist:SetSize(libraryWidth - libraryButtonWidth - 32, 34)

	local trackTitle = vgui.Create("DTextEntry", libraryPanel)
	trackTitle:SetPos(12, 122)
	trackTitle:SetSize(libraryWidth - 24, 34)
	trackTitle:SetPlaceholderText("Track name (optional)")
	trackTitle:SetTextColor(colors.white)
	trackTitle:SetPlaceholderColor(colors.muted)
	trackTitle:SetDrawBackground(false)
	trackTitle.Paint = function(self, width, height)
		draw.RoundedBox(6, 0, 0, width, height, colors.panelLight)
		self:DrawTextEntryText(colors.white, colors.cyan, colors.white)
	end

	local saveTrack = themedButton(libraryPanel, "SAVE PASTED URL", colors.cyan)
	saveTrack:SetPos(12, 166)
	saveTrack:SetSize(libraryWidth - 24, 34)
	local queueAll = themedButton(libraryPanel, "QUEUE ENTIRE PLAYLIST", colors.warning)
	queueAll:SetPos(12, 210)
	queueAll:SetSize(libraryWidth - 24, 34)

	local savedTracksHeader = vgui.Create("DLabel", libraryPanel)
	savedTracksHeader:SetPos(12, 255)
	savedTracksHeader:SetSize(libraryWidth - 24, 20)
	savedTracksHeader:SetFont("DermaDefaultBold")
	savedTracksHeader:SetTextColor(colors.muted)
	savedTracksHeader:SetText("SAVED TRACKS")

	local savedTracks = vgui.Create("DScrollPanel", libraryPanel)
	savedTracks:SetPos(12, 280)
	savedTracks:SetSize(libraryWidth - 24, libraryPanel:GetTall() - 292)
	local savedBar = savedTracks:GetVBar()
	if IsValid(savedBar) then
		savedBar:SetWide(6)
		savedBar.Paint = function() end
		savedBar.btnUp.Paint = function() end
		savedBar.btnDown.Paint = function() end
		savedBar.btnGrip.Paint = function(_, width, height) draw.RoundedBox(3, 0, 0, width, height, colors.cyan) end
	end

	local refreshLibrary
	local function selectedPlaylist()
		for _, saved in ipairs(savedLibrary.playlists or {}) do
			if saved.id == frame.SelectedPlaylistID then return saved end
		end
	end

	refreshLibrary = function()
		if not IsValid(frame) then return end
		local previous = frame.SelectedPlaylistID
		frame.RefreshingLibrary = true
		playlistSelector:Clear()
		for _, saved in ipairs(savedLibrary.playlists or {}) do
			-- DComboBox:AddChoice's third argument immediately calls
			-- ChooseOption. That invokes OnSelect, which used to recursively call
			-- refreshLibrary while the combo was still being rebuilt.
			playlistSelector:AddChoice(saved.name .. "  (" .. #(saved.tracks or {}) .. ")", saved.id)
		end
		if not selectedPlaylist() then
			frame.SelectedPlaylistID = savedLibrary.playlists[1] and savedLibrary.playlists[1].id or nil
		end
		local selected = selectedPlaylist()
		playlistSelector:SetValue(selected and selected.name or "Select a playlist")
		frame.RefreshingLibrary = nil
		deletePlaylist:SetEnabled(selected ~= nil)
		saveTrack:SetEnabled(selected ~= nil)
		queueAll:SetEnabled(selected ~= nil and #(selected.tracks or {}) > 0)
		savedTracks:GetCanvas():Clear()
		if not selected then
			local empty = savedTracks:Add("DLabel")
			empty:Dock(TOP)
			empty:SetTall(60)
			empty:SetTextColor(colors.muted)
			empty:SetContentAlignment(5)
			empty:SetText("Create a playlist to save music.")
			return
		end
		for index, track in ipairs(selected.tracks or {}) do
			local trackIndex = index
			local trackData = track
			local row = savedTracks:Add("DButton")
			row:Dock(TOP)
			row:DockMargin(0, 0, 2, 6)
			row:SetTall(52)
			row:SetText("")
			row.Paint = function(self, width, height)
				draw.RoundedBox(6, 0, 0, width, height, self:IsHovered() and colors.panelLight or colors.background)
				draw.SimpleText(string.sub(tostring(trackData.title or trackData.url), 1, 30), "DermaDefaultBold", 10, 9, colors.white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
				draw.SimpleText("CLICK TO QUEUE", "DermaDefault", 10, 30, colors.green, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
				draw.SimpleText("×", "DermaLarge", width - 17, height * 0.5, colors.danger, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
			row.DoClick = function(self)
				if self:LocalCursorPos() > self:GetWide() - 42 then
					sendLibraryAction(entity, LIBRARY_REMOVE_TRACK, selected.id, "", "", "", trackIndex)
				else
					sendLibraryAction(entity, LIBRARY_QUEUE_TRACK, selected.id, "", "", "", trackIndex)
				end
			end
			row.DoRightClick = function()
				sendLibraryAction(entity, LIBRARY_REMOVE_TRACK, selected.id, "", "", "", trackIndex)
			end
		end
	end

	playlistSelector.OnSelect = function(_, _, _, data)
		if frame.RefreshingLibrary or data == nil then return end
		frame.SelectedPlaylistID = data
		refreshLibrary()
	end
	createPlaylist.DoClick = function()
		Derma_StringRequest("New playlist", "Choose a name for this saved playlist.", "My playlist", function(name)
			sendLibraryAction(entity, LIBRARY_CREATE, "", name)
		end)
	end
	deletePlaylist.DoClick = function()
		local selected = selectedPlaylist()
		if not selected then return end
		Derma_Query("Delete '" .. selected.name .. "' and its saved tracks?", "Delete playlist", "DELETE", function()
			sendLibraryAction(entity, LIBRARY_DELETE, selected.id)
		end, "CANCEL")
	end
	saveTrack.DoClick = function()
		local selected = selectedPlaylist()
		local pastedURL = string.Trim(url:GetValue() or "")
		if not selected or pastedURL == "" then return end
		sendLibraryAction(entity, LIBRARY_ADD_TRACK, selected.id, "", string.Trim(trackTitle:GetValue() or ""), pastedURL)
		trackTitle:SetText("")
	end
	queueAll.DoClick = function()
		local selected = selectedPlaylist()
		if selected then sendLibraryAction(entity, LIBRARY_QUEUE_ALL, selected.id) end
	end
	hook.Add("DRPMP3LibraryUpdated", "DRP.MP3LibraryPanel", refreshLibrary)
	refreshLibrary()

	local playlistTitle = vgui.Create("DLabel", frame)
	playlistTitle:SetPos(rightX, 72)
	playlistTitle:SetSize(rightWidth, 24)
	playlistTitle:SetFont("DermaLarge")
	playlistTitle:SetTextColor(colors.white)
	playlistTitle:SetText("PLAYLIST")

	local nowPlaying = vgui.Create("DPanel", frame)
	nowPlaying:SetPos(rightX, 104)
	nowPlaying:SetSize(rightWidth, 66)
	nowPlaying.Title = "Nothing playing"
	nowPlaying.Detail = "Queue an audio source to begin"
	nowPlaying.Paint = function(self, width, height)
		draw.RoundedBox(7, 0, 0, width, height, colors.panelLight)
		draw.RoundedBox(0, 0, 0, 4, height, colors.green)
		draw.SimpleText("NOW PLAYING", "DermaDefaultBold", 14, 10, colors.green, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText(self.Title, "DermaDefaultBold", 14, 29, colors.white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText(self.Detail, "DermaDefault", 14, 48, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	end

	local queueHeader = vgui.Create("DLabel", frame)
	queueHeader:SetPos(rightX, 178)
	queueHeader:SetSize(rightWidth, 22)
	queueHeader:SetFont("DermaDefaultBold")
	queueHeader:SetTextColor(colors.cyan)
	queueHeader:SetText("UP NEXT — 0 TRACKS")

	local playlist = vgui.Create("DScrollPanel", frame)
	playlist:SetPos(rightX, 204)
	playlist:SetSize(rightWidth, frame:GetTall() - 278)
	local scrollbar = playlist:GetVBar()
	if IsValid(scrollbar) then
		scrollbar:SetWide(7)
		scrollbar.Paint = function(_, width, height) draw.RoundedBox(4, 0, 0, width, height, colors.panel) end
		scrollbar.btnUp.Paint = function() end
		scrollbar.btnDown.Paint = function() end
		scrollbar.btnGrip.Paint = function(_, width, height) draw.RoundedBox(4, 0, 0, width, height, colors.cyan) end
	end

	local moveUp = themedButton(frame, "MOVE UP", colors.cyan)
	local moveDown = themedButton(frame, "MOVE DOWN", colors.cyan)
	local clear = themedButton(frame, "CLEAR QUEUE", colors.danger)
	local bottomY = frame:GetTall() - 58
	local third = math.floor((rightWidth - 16) / 3)
	moveUp:SetPos(rightX, bottomY)
	moveUp:SetSize(third, 38)
	moveDown:SetPos(rightX + third + 8, bottomY)
	moveDown:SetSize(third, 38)
	clear:SetPos(rightX + (third + 8) * 2, bottomY)
	clear:SetSize(rightWidth - (third + 8) * 2, 38)
	moveUp.DoClick = function()
		if frame.SelectedUID then sendQueueAction(entity, QUEUE_MOVE_UP, frame.SelectedUID) end
	end
	moveDown.DoClick = function()
		if frame.SelectedUID then sendQueueAction(entity, QUEUE_MOVE_DOWN, frame.SelectedUID) end
	end
	clear.DoClick = function()
		Derma_Query(
			"Remove every upcoming track from this MP3 player's playlist?",
			"Clear playlist",
			"CLEAR QUEUE",
			function() sendQueueAction(entity, QUEUE_CLEAR) end,
			"CANCEL"
		)
	end
	moveUp:SetEnabled(false)
	moveDown:SetEnabled(false)
	clear:SetEnabled(false)

	local refreshPlaylist
	local function bindMediaPlayer(mediaPlayer)
		if not mediaPlayer or frame.BoundMediaPlayer == mediaPlayer or not MP or not MP.EVENTS then return end
		if frame.BoundMediaPlayer then
			frame.BoundMediaPlayer:removeListener(MP.EVENTS.MEDIA_CHANGED, frame.MediaChangedHandle)
			frame.BoundMediaPlayer:removeListener(MP.EVENTS.QUEUE_CHANGED, frame.QueueChangedHandle)
		end
		frame.BoundMediaPlayer = mediaPlayer
		frame.MediaChangedHandle = function()
			if IsValid(frame) then refreshPlaylist(mediaPlayer) end
		end
		frame.QueueChangedHandle = frame.MediaChangedHandle
		mediaPlayer:on(MP.EVENTS.MEDIA_CHANGED, frame.MediaChangedHandle)
		mediaPlayer:on(MP.EVENTS.QUEUE_CHANGED, frame.QueueChangedHandle)
	end

	refreshPlaylist = function(mediaPlayer)
		if not IsValid(frame) then return end
		mediaPlayer = mediaPlayer or getMediaPlayer(entity)
		if not mediaPlayer or not isfunction(mediaPlayer.GetMediaQueue) then
			queueHeader:SetText("UP NEXT — WAITING FOR SYNC")
			return
		end
		bindMediaPlayer(mediaPlayer)

		local current = isfunction(mediaPlayer.GetMedia) and mediaPlayer:GetMedia() or nil
		if current then
			nowPlaying.Title = tostring(mediaValue(current, "Title", "Unknown track"))
			nowPlaying.Detail = formatDuration(mediaValue(current, "Duration", -1)) .. "  •  " .. tostring(mediaValue(current, "OwnerName", "Unknown requester"))
		else
			nowPlaying.Title = "Nothing playing"
			nowPlaying.Detail = "Queue an audio source to begin"
		end

		local mediaQueue = mediaPlayer:GetMediaQueue() or {}
		queueHeader:SetText("UP NEXT — " .. #mediaQueue .. (#mediaQueue == 1 and " TRACK" or " TRACKS"))
		repeatButton.Label = "REPEAT: " .. (mediaPlayer:GetQueueRepeat() and "ON" or "OFF")
		shuffleButton.Label = "SHUFFLE: " .. (mediaPlayer:GetQueueShuffle() and "ON" or "OFF")
		playlist:GetCanvas():Clear()

		local selectedStillExists = false
		local selectedIndex
		for index, media in ipairs(mediaQueue) do
			local uid = tostring(mediaValue(media, "UniqueID", ""))
			if uid == frame.SelectedUID then
				selectedStillExists = true
				selectedIndex = index
			end
			local row = playlist:Add("DButton")
			row:Dock(TOP)
			row:DockMargin(0, 0, 0, 6)
			row:SetTall(58)
			row:SetText("")
			row.MediaUID = uid
			row.QueueIndex = index
			row.QueueCount = #mediaQueue
			row.TrackTitle = tostring(mediaValue(media, "Title", "Unknown track"))
			row.TrackDetail = formatDuration(mediaValue(media, "Duration", -1)) .. "  •  " .. tostring(mediaValue(media, "OwnerName", "Unknown requester"))
			row.Paint = function(self, width, height)
				local selected = frame.SelectedUID == self.MediaUID
				draw.RoundedBox(7, 0, 0, width, height, selected and colors.panelLight or colors.panel)
				draw.RoundedBox(0, 0, 0, 4, height, selected and colors.green or colors.cyan)
				draw.SimpleText(string.format("%02d", self.QueueIndex), "DermaDefaultBold", 14, 11, selected and colors.green or colors.cyan, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
				draw.SimpleText(self.TrackTitle, "DermaDefaultBold", 45, 9, colors.white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
				draw.SimpleText(self.TrackDetail, "DermaDefault", 45, 33, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
				if frame.CanManage then draw.SimpleText("×", "DermaLarge", width - 20, height * 0.5, colors.danger, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER) end
			end
			row.DoClick = function(self)
				if not frame.CanManage then return end
				if self:LocalCursorPos() > self:GetWide() - 48 then
					sendQueueAction(entity, QUEUE_REMOVE, self.MediaUID)
					return
				end
				frame.SelectedUID = self.MediaUID
				moveUp:SetEnabled(self.QueueIndex > 1)
				moveDown:SetEnabled(self.QueueIndex < self.QueueCount)
			end
			row.DoRightClick = function(self)
				if frame.CanManage then sendQueueAction(entity, QUEUE_REMOVE, self.MediaUID) end
			end
		end

		if not selectedStillExists then frame.SelectedUID = nil end
		moveUp:SetEnabled(frame.CanManage and selectedIndex ~= nil and selectedIndex > 1)
		moveDown:SetEnabled(frame.CanManage and selectedIndex ~= nil and selectedIndex < #mediaQueue)
		clear:SetEnabled(frame.CanManage and #mediaQueue > 0)
	end

	hook.Add("OnMediaPlayerUpdate", "DRP.MP3Playlist", function(mediaPlayer)
		if not IsValid(frame) or not mediaPlayer then return end
		local current = getMediaPlayer(entity)
		if current and isfunction(current.GetId) and isfunction(mediaPlayer.GetId) and current:GetId() == mediaPlayer:GetId() then
			refreshPlaylist(mediaPlayer)
		end
	end)

	url.OnEnter = queue.DoClick
	refreshPlaylist()
	requestLibrary()
	if MediaPlayer and MediaPlayer.RequestUpdate then MediaPlayer.RequestUpdate(entity) end
end

net.Receive(OPEN_MESSAGE, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	openControls(net.ReadEntity(), net.ReadUInt(7), net.ReadUInt(10), net.ReadBool())
end)
