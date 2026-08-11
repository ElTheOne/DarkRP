local Integration = {
	WorkshopID = DRP.MediaPlayerWorkshopID,
	EntityClass = "mediaplayer_tv",
	MP3EntityClass = "drp_mp3_player",
	MP3OpenMessage = "drp_mp3_open_v1",
	MP3VolumeMessage = "drp_mp3_volume_v1",
	MP3QueueMessage = "drp_mp3_queue_action_v1",
	MP3LibraryRequestMessage = "drp_mp3_library_request_v1",
	MP3LibrarySyncMessage = "drp_mp3_library_sync_v1",
	MP3LibraryActionMessage = "drp_mp3_library_action_v1",
	Libraries = {},
	LibraryLoads = {}
}

DRP.MediaPlayerIntegration = Integration
DRP.Services.Register("media_player", Integration)

resource.AddWorkshop(Integration.WorkshopID)
util.AddNetworkString(Integration.MP3OpenMessage)
util.AddNetworkString(Integration.MP3VolumeMessage)
util.AddNetworkString(Integration.MP3QueueMessage)
util.AddNetworkString(Integration.MP3LibraryRequestMessage)
util.AddNetworkString(Integration.MP3LibrarySyncMessage)
util.AddNetworkString(Integration.MP3LibraryActionMessage)
util.AddNetworkString(DRP.MediaPlayerLiveMessage)

local LIVE_SCREEN_CLASS = "mediaplayer_tv"
local liveListenerRange = math.max(128, tonumber(DRP.MediaPlayerLiveUIConfig.ServerRange) or 384)
local LIVE_LISTENER_RANGE_SQR = liveListenerRange * liveListenerRange

local function canSeeLiveScreen(ply, entity)
	local eyePosition = ply:EyePos()
	local targets = { entity:NearestPoint(eyePosition), entity:WorldSpaceCenter() }
	for _, target in ipairs(targets) do
		local trace = util.TraceLine({
			start = eyePosition,
			endpos = target,
			filter = ply,
			mask = MASK_SOLID
		})
		if not trace.Hit or trace.Entity == entity or trace.Fraction >= 0.98 then return true end
	end
	return false
end

local function removeLiveListener(ply, entity)
	if not IsValid(entity) or not entity.IsMediaPlayerEntity then return end
	local mediaPlayer = isfunction(entity.GetMediaPlayer) and entity:GetMediaPlayer() or nil
	if mediaPlayer and isfunction(mediaPlayer.HasListener) and mediaPlayer:HasListener(ply) then
		mediaPlayer:RemoveListener(ply)
	end
end

DRP.Net.Receive(DRP.MediaPlayerLiveMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local entity = net.ReadEntity()
	local listening = net.ReadBool()
	if not DRP.Net.Allow(ply, "media_live_listener", 0.2, 3) then return end

	if not listening then
		if entity == ply.DRPLiveMediaEntity then
			removeLiveListener(ply, entity)
			ply.DRPLiveMediaEntity = nil
		end
		return
	end

	if not IsValid(entity) or entity:GetClass() ~= LIVE_SCREEN_CLASS or not entity.IsMediaPlayerEntity then return end
	local nearestPoint = entity:NearestPoint(ply:EyePos())
	if not ply:Alive() or ply:EyePos():DistToSqr(nearestPoint) > LIVE_LISTENER_RANGE_SQR then return end
	if not canSeeLiveScreen(ply, entity) then return end

	if IsValid(ply.DRPLiveMediaEntity) and ply.DRPLiveMediaEntity ~= entity then
		removeLiveListener(ply, ply.DRPLiveMediaEntity)
	end
	local mediaPlayer = isfunction(entity.GetMediaPlayer) and entity:GetMediaPlayer() or nil
	if not mediaPlayer or not isfunction(mediaPlayer.HasListener) then return end
	if not mediaPlayer:HasListener(ply) then mediaPlayer:AddListener(ply) end
	ply.DRPLiveMediaEntity = entity
end)

local MAX_PLAYLISTS = 8
local MAX_TRACKS = 32
local MAX_NAME = 48
local MAX_TITLE = 96
local MAX_URL = 512

local function cleanLibraryText(value, maximum)
	value = string.Trim(tostring(value or "")):gsub("[%c]", " ")
	return string.sub(value, 1, maximum)
end

local function cleanLibraryURL(value)
	value = string.sub(string.Trim(tostring(value or "")), 1, MAX_URL)
	if value == "" or not MediaPlayer or not MediaPlayer.ValidUrl or not MediaPlayer.ValidUrl(value) then return nil end
	return value
end

local function sanitizeLibrary(value)
	local output = { revision = math.max(0, math.floor(tonumber(value and value.revision) or 0)), playlists = {} }
	local used = {}
	for _, source in ipairs(istable(value) and istable(value.playlists) and value.playlists or {}) do
		if #output.playlists >= MAX_PLAYLISTS then break end
		local name = cleanLibraryText(source.name, MAX_NAME)
		local id = cleanLibraryText(source.id, 24)
		if name ~= "" and id ~= "" and not used[id] then
			used[id] = true
			local playlist = { id = id, name = name, tracks = {} }
			for _, sourceTrack in ipairs(istable(source.tracks) and source.tracks or {}) do
				if #playlist.tracks >= MAX_TRACKS then break end
				local url = cleanLibraryURL(sourceTrack.url)
				if url then
					local title = cleanLibraryText(sourceTrack.title, MAX_TITLE)
					playlist.tracks[#playlist.tracks + 1] = { title = title ~= "" and title or url, url = url }
				end
			end
			output.playlists[#output.playlists + 1] = playlist
		end
	end
	return output
end

local function libraryKey(steamID64)
	return "mp3_music_" .. string.sub(tostring(steamID64 or "0"), 1, 32)
end

local function findPlaylist(library, id)
	for index, playlist in ipairs(library.playlists or {}) do
		if playlist.id == id then return playlist, index end
	end
end

function Integration:SendLibrary(ply, library)
	if not IsValid(ply) then return end
	local encoded = util.TableToJSON(sanitizeLibrary(library), false) or "{}"
	local compressed = util.Compress(encoded) or ""
	net.Start(self.MP3LibrarySyncMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(#compressed, 18)
		net.WriteData(compressed, #compressed)
	net.Send(ply)
end

function Integration:LoadLibrary(ply, callback)
	if not IsValid(ply) then return end
	local steamID64 = ply:SteamID64()
	if self.Libraries[steamID64] then
		if callback then callback(self.Libraries[steamID64]) end
		return
	end
	self.LibraryLoads[steamID64] = self.LibraryLoads[steamID64] or {}
	if callback then self.LibraryLoads[steamID64][#self.LibraryLoads[steamID64] + 1] = callback end
	if #self.LibraryLoads[steamID64] > 1 then return end
	DRP.Storage.LoadWorldState(libraryKey(steamID64), function(success, payload)
		local decoded = success and payload and util.JSONToTable(payload) or nil
		local library = sanitizeLibrary(decoded)
		self.Libraries[steamID64] = library
		local waiting = self.LibraryLoads[steamID64] or {}
		self.LibraryLoads[steamID64] = nil
		for _, loaded in ipairs(waiting) do loaded(library) end
	end)
end

function Integration:SaveLibrary(ply, library)
	if not IsValid(ply) then return false end
	library = sanitizeLibrary(library)
	library.revision = library.revision + 1
	self.Libraries[ply:SteamID64()] = library
	local payload = util.TableToJSON(library, false)
	if not payload then return false end
	DRP.Storage.SaveWorldState(libraryKey(ply:SteamID64()), payload)
	self:SendLibrary(ply, library)
	return true
end

function Integration:IsAvailable()
	return scripted_ents.GetStored(self.EntityClass) ~= nil
		and istable(MediaPlayer)
		and isfunction(MediaPlayer.GetAll)
end

function Integration:Claim(entity, ply)
	if not IsValid(entity) or not IsValid(ply) or not entity.IsMediaPlayerEntity then return false end

	entity:SetCreator(ply)
	if isfunction(entity.CPPISetOwner) then
		entity:CPPISetOwner(ply)
	else
		local mediaPlayer = isfunction(entity.GetMediaPlayer) and entity:GetMediaPlayer() or nil
		if mediaPlayer and isfunction(mediaPlayer.SetOwner) then mediaPlayer:SetOwner(ply) end
	end
	-- Spatial requests are rejected unless the requester is already a listener.
	-- Seed the MP3 owner immediately instead of waiting for its staggered radius
	-- refresh, which also makes the first request deterministic after spawning.
	if entity:GetClass() == self.MP3EntityClass then
		local mediaPlayer = isfunction(entity.GetMediaPlayer) and entity:GetMediaPlayer() or nil
		if mediaPlayer and isfunction(mediaPlayer.HasListener) and not mediaPlayer:HasListener(ply) then
			mediaPlayer:AddListener(ply)
		end
	end
	return true
end

function Integration:IsMP3Owner(entity, ply)
	if not IsValid(entity) or entity:GetClass() ~= self.MP3EntityClass then return false end
	if not IsValid(ply) or not ply:IsPlayer() then return false end
	if DRP.Props and DRP.Props.IsOwnedBy then return DRP.Props.IsOwnedBy(ply, entity) end
	return entity:GetCreator() == ply
end

function Integration:OpenMP3Controls(entity, ply)
	if not IsValid(entity) or entity:GetClass() ~= self.MP3EntityClass or not IsValid(ply) then return false end
	if ply:GetPos():DistToSqr(entity:GetPos()) > 65536 then return false end
	local canManage = self:IsMP3Owner(entity, ply)
	local mediaPlayer = isfunction(entity.GetMediaPlayer) and entity:GetMediaPlayer() or nil
	if mediaPlayer and isfunction(mediaPlayer.HasListener) and not mediaPlayer:HasListener(ply) then
		mediaPlayer:AddListener(ply)
	end
	-- Always send an authoritative queue snapshot when the controller opens.
	-- The custom playlist is event-driven after this initial synchronization.
	if mediaPlayer and isfunction(mediaPlayer.BroadcastUpdate) then
		mediaPlayer:BroadcastUpdate(ply)
	end

	net.Start(self.MP3OpenMessage)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteEntity(entity)
		net.WriteUInt(math.Clamp(math.Round(entity:GetMP3Volume() * 100), 0, 100), 7)
		net.WriteUInt(math.Clamp(math.Round(entity:GetMP3Radius()), 0, 1023), 10)
		net.WriteBool(canManage)
	net.Send(ply)
	self:LoadLibrary(ply, function(library)
		if IsValid(ply) then self:SendLibrary(ply, library) end
	end)
	return true
end

DRP.Net.Receive(Integration.MP3VolumeMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local entity = net.ReadEntity()
	local volume = net.ReadUInt(7)
	if (ply.DRPNextMP3VolumeChange or 0) > CurTime() then return end
	ply.DRPNextMP3VolumeChange = CurTime() + 0.25
	if not Integration:IsMP3Owner(entity, ply) then return end
	if ply:GetPos():DistToSqr(entity:GetPos()) > 65536 then return end

	entity:SetMP3Volume(math.Clamp(volume, 0, 100) / 100)
	DRP.Net.Notify(ply, "MP3 player volume set to " .. math.Clamp(volume, 0, 100) .. "%.", 2)
	if DRP.Audit then
		DRP.Audit.Log(ply, "mp3_volume", entity, tostring(math.Clamp(volume, 0, 100)))
	end
end)

local LIBRARY_CREATE = 1
local LIBRARY_DELETE = 2
local LIBRARY_ADD_TRACK = 3
local LIBRARY_REMOVE_TRACK = 4
local LIBRARY_QUEUE_TRACK = 5
local LIBRARY_QUEUE_ALL = 6
local LIBRARY_RENAME = 7

local function canUseLibraryPlayer(entity, ply)
	return IsValid(entity) and entity:GetClass() == Integration.MP3EntityClass
		and IsValid(ply) and ply:GetPos():DistToSqr(entity:GetPos()) <= 65536
end

local function queueSavedTracks(entity, ply, tracks)
	if not canUseLibraryPlayer(entity, ply) then return end
	if ply.DRPMP3LibraryQueueBusy then
		DRP.Net.Notify(ply, "Your previous saved-playlist request is still being processed.", 3)
		return
	end
	local mediaPlayer = isfunction(entity.GetMediaPlayer) and entity:GetMediaPlayer() or nil
	if not mediaPlayer or not isfunction(mediaPlayer.GetMediaQueue) then return end
	if isfunction(mediaPlayer.HasListener) and not mediaPlayer:HasListener(ply) then mediaPlayer:AddListener(ply) end

	local available = math.max(0, mediaPlayer:GetQueueLimit() - #(mediaPlayer:GetMediaQueue() or {}))
	local pending = {}
	for _, track in ipairs(tracks or {}) do
		if #pending >= available then break end
		local url = cleanLibraryURL(track.url)
		if url then pending[#pending + 1] = url end
	end
	if #pending == 0 then
		DRP.Net.Notify(ply, "That playlist has no tracks or the live queue is full.", 3)
		return
	end

	local added = 0
	local batchToken = {}
	ply.DRPMP3LibraryQueueBusy = batchToken
	local function finishBatch()
		if IsValid(ply) and ply.DRPMP3LibraryQueueBusy == batchToken then
			ply.DRPMP3LibraryQueueBusy = nil
			DRP.Net.Notify(ply, "Added " .. added .. " saved track(s) to the MP3 queue.", 3)
		end
	end
	timer.Simple(30, function()
		if IsValid(ply) and ply.DRPMP3LibraryQueueBusy == batchToken then ply.DRPMP3LibraryQueueBusy = nil end
	end)
	local function addNext(index)
		if not IsValid(ply) or ply.DRPMP3LibraryQueueBusy ~= batchToken then return end
		if index > #pending or not canUseLibraryPlayer(entity, ply) then
			finishBatch()
			return
		end
		if #(mediaPlayer:GetMediaQueue() or {}) >= mediaPlayer:GetQueueLimit() then finishBatch() return end
		local media = MediaPlayer.GetMediaForUrl(pending[index], MediaPlayer.Cvars.AllowWebpages:GetBool())
		if not media then addNext(index + 1) return end
		local allowed = mediaPlayer:CanPlayerRequestMedia(ply, media)
		if not allowed then addNext(index + 1) return end

		media:GetMetadata(function(data)
			if not IsValid(ply) or ply.DRPMP3LibraryQueueBusy ~= batchToken then return end
			if not data or not canUseLibraryPlayer(entity, ply) then addNext(index + 1) return end
			if #(mediaPlayer:GetMediaQueue() or {}) >= mediaPlayer:GetQueueLimit() then finishBatch() return end
			local duplicate = false
			for _, queued in ipairs(mediaPlayer:GetMediaQueue() or {}) do
				if queued.Id == media.Id and queued:UniqueID() == media:UniqueID() then duplicate = true break end
			end
			local shouldQueue = not duplicate and mediaPlayer:ShouldQueueMedia(media)
			if shouldQueue and hook.Run("PreMediaPlayerMediaRequest", mediaPlayer, media, ply) ~= false then
				media:SetOwner(ply)
				mediaPlayer:AddMedia(media)
				mediaPlayer:QueueUpdated()
				mediaPlayer:BroadcastUpdate()
				if MediaPlayer.History then MediaPlayer.History:LogRequest(media) end
				hook.Run("PostMediaPlayerMediaRequest", mediaPlayer, media, ply)
				added = added + 1
			end
			timer.Simple(0, function() addNext(index + 1) end)
		end)
	end

	addNext(1)
end

DRP.Net.Receive(Integration.MP3LibraryRequestMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not DRP.Net.Allow(ply, "mp3_library_request", 0.5, 2) then return end
	Integration:LoadLibrary(ply, function(library)
		if IsValid(ply) then Integration:SendLibrary(ply, library) end
	end)
end)

DRP.Net.Receive(Integration.MP3LibraryActionMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local action = net.ReadUInt(3)
	local playlistID = cleanLibraryText(net.ReadString(), 24)
	local name = cleanLibraryText(net.ReadString(), MAX_NAME)
	local title = cleanLibraryText(net.ReadString(), MAX_TITLE)
	local url = cleanLibraryURL(net.ReadString())
	local trackIndex = net.ReadUInt(6)
	local entity = net.ReadEntity()
	if not DRP.Net.Allow(ply, "mp3_library_action", 0.2, 5) then return end
	if action == LIBRARY_ADD_TRACK and not url then
		DRP.Net.Notify(ply, "Paste a valid supported media URL before saving it.", 3)
		return
	end

	Integration:LoadLibrary(ply, function(library)
		if not IsValid(ply) then return end
		local playlist, playlistIndex = findPlaylist(library, playlistID)
		local changed = false
		if action == LIBRARY_CREATE then
			if name == "" then return end
			if #library.playlists >= MAX_PLAYLISTS then
				DRP.Net.Notify(ply, "You can save up to " .. MAX_PLAYLISTS .. " playlists.", 3)
				return
			end
			library.playlists[#library.playlists + 1] = {
				id = string.sub(util.CRC(ply:SteamID64() .. ":" .. tostring(SysTime()) .. ":" .. name), 1, 24),
				name = name,
				tracks = {}
			}
			changed = true
		elseif action == LIBRARY_DELETE and playlist then
			table.remove(library.playlists, playlistIndex)
			changed = true
		elseif action == LIBRARY_RENAME and playlist and name ~= "" then
			playlist.name = name
			changed = true
		elseif action == LIBRARY_ADD_TRACK and playlist and url and #playlist.tracks < MAX_TRACKS then
			playlist.tracks[#playlist.tracks + 1] = { title = title ~= "" and title or url, url = url }
			changed = true
		elseif action == LIBRARY_ADD_TRACK and playlist and #playlist.tracks >= MAX_TRACKS then
			DRP.Net.Notify(ply, "That playlist already contains the maximum of " .. MAX_TRACKS .. " tracks.", 3)
		elseif action == LIBRARY_REMOVE_TRACK and playlist and playlist.tracks[trackIndex] then
			table.remove(playlist.tracks, trackIndex)
			changed = true
		elseif action == LIBRARY_QUEUE_TRACK and playlist and playlist.tracks[trackIndex] and canUseLibraryPlayer(entity, ply) then
			queueSavedTracks(entity, ply, { playlist.tracks[trackIndex] })
		elseif action == LIBRARY_QUEUE_ALL and playlist and canUseLibraryPlayer(entity, ply) then
			queueSavedTracks(entity, ply, playlist.tracks)
		end

		if changed then
			Integration:SaveLibrary(ply, library)
			if DRP.Audit then DRP.Audit.Log(ply, "mp3_library", entity, string.format("action=%d playlist=%s", action, playlistID)) end
		end
	end)
end)

local QUEUE_REMOVE = 1
local QUEUE_MOVE_UP = 2
local QUEUE_MOVE_DOWN = 3
local QUEUE_CLEAR = 4

local function findQueuedMedia(queue, uid)
	for index, media in ipairs(queue or {}) do
		if media and isfunction(media.UniqueID) and media:UniqueID() == uid then
			return index, media
		end
	end
end

local function preserveQueueOrder(mediaPlayer)
	-- Redux normally sorts by queueTime. Re-stamp the requested order so a
	-- later QueueUpdated call cannot silently undo an owner's manual move.
	local now = RealTime()
	for index, media in ipairs(mediaPlayer:GetMediaQueue() or {}) do
		if media and isfunction(media.SetMetadataValue) then
			media:SetMetadataValue("queueTime", now + index * 0.001)
		end
	end
	if isfunction(mediaPlayer.QueueUpdated) then mediaPlayer:QueueUpdated() end
	if isfunction(mediaPlayer.BroadcastUpdate) then mediaPlayer:BroadcastUpdate() end
end

DRP.Net.Receive(Integration.MP3QueueMessage, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local entity = net.ReadEntity()
	local action = net.ReadUInt(3)
	local uid = string.sub(net.ReadString() or "", 1, 160)
	if not DRP.Net.Allow(ply, "mp3_queue", 0.12, 8) then return end
	if not Integration:IsMP3Owner(entity, ply) then return end
	if ply:GetPos():DistToSqr(entity:GetPos()) > 65536 then return end

	local mediaPlayer = isfunction(entity.GetMediaPlayer) and entity:GetMediaPlayer() or nil
	if not mediaPlayer or not isfunction(mediaPlayer.GetMediaQueue) then return end
	local queue = mediaPlayer:GetMediaQueue() or {}

	if action == QUEUE_REMOVE then
		if uid == "" then return end
		local current = isfunction(mediaPlayer.GetMedia) and mediaPlayer:GetMedia() or nil
		if current and isfunction(current.UniqueID) and current:UniqueID() == uid then
			if isfunction(mediaPlayer.NextMedia) then mediaPlayer:NextMedia() end
		else
			local index = findQueuedMedia(queue, uid)
			if not index then return end
			table.remove(queue, index)
			preserveQueueOrder(mediaPlayer)
		end
	elseif action == QUEUE_CLEAR then
		if isfunction(mediaPlayer.ClearMediaQueue) then mediaPlayer:ClearMediaQueue() end
	elseif action == QUEUE_MOVE_UP or action == QUEUE_MOVE_DOWN then
		if isfunction(mediaPlayer.SetQueueShuffle) and mediaPlayer:GetQueueShuffle() then
			mediaPlayer:SetQueueShuffle(false)
		end
		local index = findQueuedMedia(queue, uid)
		if not index then return end
		local target = index + (action == QUEUE_MOVE_UP and -1 or 1)
		if target < 1 or target > #queue then return end
		queue[index], queue[target] = queue[target], queue[index]
		preserveQueueOrder(mediaPlayer)
	else
		return
	end

	if DRP.Audit then
		DRP.Audit.Log(ply, "mp3_queue", entity, string.format("action=%d uid=%s", action, uid))
	end
end)

function Integration:Start()
	if self:IsAvailable() then
		print("[DRP MEDIA] Media Player Redux ready (Workshop " .. self.WorkshopID .. ").")
	else
		ErrorNoHalt(
			"[DRP MEDIA] Media Player Redux is not mounted. Install Workshop "
			.. self.WorkshopID
			.. " on the server and disable every other Media Player fork.\n"
		)
	end

	hook.Add("MediaPlayerIsPlayerPrivileged", "DRP.MediaPlayer.AdminPrivilege", function(_, ply)
		if IsValid(ply) and DRP.Admin and DRP.Admin.Has(ply, "server_interactions") then
			return true
		end
	end)
	hook.Add("PlayerDisconnected", "DRP.MediaPlayer.ReleaseLibrary", function(ply)
		removeLiveListener(ply, ply.DRPLiveMediaEntity)
		ply.DRPLiveMediaEntity = nil
		Integration.Libraries[ply:SteamID64()] = nil
		Integration.LibraryLoads[ply:SteamID64()] = nil
	end)
end

function Integration:Stop()
	hook.Remove("MediaPlayerIsPlayerPrivileged", "DRP.MediaPlayer.AdminPrivilege")
	hook.Remove("PlayerDisconnected", "DRP.MediaPlayer.ReleaseLibrary")
end

concommand.Add("drp_mediaplayer_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end

	local screens = 0
	local mp3Players = 0
	for _, entity in ents.Iterator() do
		if entity:GetClass() == Integration.EntityClass then screens = screens + 1 end
		if entity:GetClass() == Integration.MP3EntityClass then mp3Players = mp3Players + 1 end
	end

	print(string.format(
		"[DRP MEDIA] mounted=%s workshop=%s screens=%d mp3_players=%d media_players=%d",
		tostring(Integration:IsAvailable()),
		Integration.WorkshopID,
		screens,
		mp3Players,
		Integration:IsAvailable() and table.Count(MediaPlayer.GetAll()) or 0
	))
end)
