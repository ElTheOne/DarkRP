local CLASS = "drp_mp3_player"

local ENT = {}
ENT.Type = "anim"
ENT.Base = "mediaplayer_base"
ENT.PrintName = "MP3 Player"
ENT.Category = "DarkRP"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.IsMediaPlayerEntity = true
ENT.MediaPlayerType = "spatial"
ENT.Model = Model("models/props_lab/citizenradio.mdl")
-- Browser-backed audio services still ask the entity for render dimensions
-- while constructing their hidden DHTML player. This dummy configuration is
-- never drawn, but without it YouTube metadata succeeds and playback aborts.
ENT.PlayerConfig = {
	offset = Vector(0, 0, 0),
	angle = Angle(0, 0, 0),
	width = 64,
	height = 36
}

DRP.MP3Player = DRP.MP3Player or {
	Class = CLASS,
	DefaultVolume = 0.65,
	DefaultRadius = 650,
	MinimumRadius = 256,
	MaximumRadius = 900,
	ListenerInterval = 0.5
}

function ENT:SetupDataTables()
	-- Keep the base entity's slot so Media Player Redux can resolve this entity.
	self:NetworkVar("String", 0, "MediaPlayerID")
	self:NetworkVar("Float", 0, "MP3Volume")
	self:NetworkVar("Float", 1, "MP3Radius")
end

function ENT:SetupMediaPlayer(mediaPlayer)
	if SERVER then
		if self:GetMP3Volume() <= 0 then self:SetMP3Volume(DRP.MP3Player.DefaultVolume) end
		if self:GetMP3Radius() <= 0 then self:SetMP3Radius(DRP.MP3Player.DefaultRadius) end

		local entity = self
		mediaPlayer.UpdateListeners = function(mp)
			local now = CurTime()
			if (mp.DRPNextMP3ListenerUpdate or 0) > now then return end
			mp.DRPNextMP3ListenerUpdate = now + DRP.MP3Player.ListenerInterval

			if not IsValid(entity) then
				mp:SetListeners({})
				return
			end

			local radius = math.Clamp(
				entity:GetMP3Radius(),
				DRP.MP3Player.MinimumRadius,
				DRP.MP3Player.MaximumRadius
			)
			local radiusSquared = radius * radius
			local origin = entity:GetPos()
			local listeners = {}
			for _, listener in ipairs(player.GetHumans()) do
				if listener:Alive() and listener:GetPos():DistToSqr(origin) <= radiusSquared then
					listeners[#listeners + 1] = listener
				end
			end
			mp:SetListeners(listeners)
		end
		-- Spatial Media Player Redux normally restricts requests to its owner.
		-- This entity is a shared jukebox: nearby listeners may add music while
		-- playback, volume and queue administration remain owner-controlled.
		mediaPlayer.CanPlayerRequestMedia = function(mp, ply, media)
			if not IsValid(ply) or not mp:HasListener(ply) then return false, "You are not close enough to this MP3 player." end
			if mp.ServiceWhitelist and not (
				table.HasValue(mp.ServiceWhitelist, media.Id)
				or MediaPlayer.PlayerHasAnyPrivilege(ply, "MediaPlayer_BypassWhitelist")
			) then
				return false, "That media service is not supported by this MP3 player."
			end
			if mp:GetQueueLocked() and not mp:IsPlayerPrivileged(ply) then
				return false, "This MP3 player's queue is locked."
			end
			return true
		end
	else
		local baseThink = mediaPlayer.Think
		local entity = self
		mediaPlayer.Think = function(mp)
			baseThink(mp)
			if not IsValid(entity) then return end
			local media = mp:GetMedia()
			if not IsValid(media) then return end

			local localPlayer = LocalPlayer()
			if not IsValid(localPlayer) then return end
			local radius = math.max(entity:GetMP3Radius(), 1)
			local innerRadius = math.max(radius * 0.18, 48)
			local distance = localPlayer:GetPos():Distance(entity:GetPos())
			local falloff = 1 - math.Clamp((distance - innerRadius) / math.max(radius - innerRadius, 1), 0, 1)
			-- This deliberately ignores Media Player's per-client opt-in volume. The
			-- entity owner's replicated setting is authoritative inside its radius.
			-- Server/gamemode safety hooks can still silence a broken media source.
			local volume = math.Round(math.Clamp(entity:GetMP3Volume(), 0, 1) * falloff, 3)
			if hook.Run("MediaPlayerShouldMute", mp, media) then volume = 0 end
			local baseVolumeChanged = mp.DRPCachedMediaPlayerVolume ~= mp._cachedVolume
			if mp.DRPCachedMP3Media ~= media or mp.DRPCachedMP3Volume ~= volume or baseVolumeChanged then
				media:Volume(volume)
				mp.DRPCachedMP3Media = media
				mp.DRPCachedMP3Volume = volume
				mp.DRPCachedMediaPlayerVolume = mp._cachedVolume
			end
		end
	end
end

if SERVER then
	function ENT:Use(activator)
		if not IsValid(activator) or not activator:IsPlayer() then return end
		if (activator.DRPNextMP3Use or 0) > CurTime() then return end
		activator.DRPNextMP3Use = CurTime() + 0.5
		if DRP.MediaPlayerIntegration then
			DRP.MediaPlayerIntegration:OpenMP3Controls(self, activator)
		end
	end
else
	function ENT:Draw()
		self:DrawModel()
	end
end

scripted_ents.Register(ENT, CLASS)
