DRP.MediaPlayerWorkshopID = "3001397905"

DRP.MediaPlayerScreens = {
	{
		key = "cinema_large_tv",
		name = "Cinema — Big Screen TV",
		class = "mediaplayer_tv",
		model = "models/gmod_tower/suitetv_large.mdl",
		ownerOnly = true,
		price = 0,
		countLimit = 8,
		category = "Cinema",
		mediaPlayer = true
	},
	{
		key = "cinema_billboard",
		name = "Cinema — Huge Billboard",
		class = "mediaplayer_tv",
		model = "models/hunter/plates/plate5x8.mdl",
		ownerOnly = true,
		price = 0,
		countLimit = 8,
		category = "Cinema",
		mediaPlayer = true
	},
	{
		key = "cinema_small_tv",
		name = "Cinema — Small TV",
		class = "mediaplayer_tv",
		model = "models/props_phx/rt_screen.mdl",
		ownerOnly = true,
		price = 0,
		countLimit = 8,
		category = "Cinema",
		mediaPlayer = true
	},
	{
		key = "mp3_player",
		name = "MP3 Player",
		class = "drp_mp3_player",
		model = "models/props_lab/citizenradio.mdl",
		public = true,
		price = 350,
		countLimit = 2,
		category = "Media",
		mediaPlayer = true
	}
}

local existing = {}
for _, definition in ipairs(DRP.JobEntities or {}) do
	existing[definition.key] = true
end

for _, definition in ipairs(DRP.MediaPlayerScreens) do
	if not existing[definition.key] then
		DRP.JobEntities[#DRP.JobEntities + 1] = definition
	end
	if DRP.DropPolicy then
		DRP.DropPolicy.nonDroppableJobEntities[definition.class] = true
	end
end
