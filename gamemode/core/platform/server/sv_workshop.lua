-- The Portal Gun addon reads portal_vm from shared/server Think code, but its
-- own source only creates that convar clientside. Provide the missing server
-- value before any Portal Gun is equipped so portal_manager.GetIDFromConVar()
-- cannot repeatedly index nil on a dedicated server.
if not GetConVar("portal_vm") then
	CreateConVar("portal_vm", "Portal", FCVAR_ARCHIVE, "Portal Gun server compatibility viewmodel")
end

-- +host_workshop_collection mounts files on the dedicated server; it does not
-- offer ordinary collection children to connecting clients. Keep every public
-- content dependency in one early-loading, auditable WorkshopDL manifest.
local Delivery = {
	CollectionID = "3768835284",
	Items = {
		["2910505837"] = "ARC9 Weapon Base",
		["2910537020"] = "ARC9 Gunsmith Reloaded",
		["1741741175"] = "Zero's Grow OP Content",
		["2486834214"] = "Zero's MethLab 2 Content",
		["542866829"] = "Weapon Case Model",
		["844856045"] = "rp_downtown_fade_v3",
		["3001397905"] = "Media Player Redux",
		["1614964558"] = "Day & Night System",
		["2532060111"] = "zcLib",
		["1788979547"] = "Arcade Cabinet",
		["1800764828"] = "Portal Gun - Reworking in LUA",
		["1443497352"] = "Keys - Content",
		["104482086"] = "Precision Tool",
		["264467687"] = "Stacker - Improved"
	},
	-- These old dependencies remain in the Steam collection but Steam has
	-- removed them. Never queue them: doing so only creates failed downloads.
	Unavailable = {
		["2381066855"] = "ePhone Content",
		["3094844762"] = "Enhanced Saddam Hussein Playermodel"
	},
	LocalContent = {
		"addons/ephone_source",
		"addons/drp_hobo_model_source"
	}
}

DRP.WorkshopDelivery = Delivery

local count = 0
for workshopID in pairs(Delivery.Items) do
	resource.AddWorkshop(workshopID)
	count = count + 1
end

local downloadableExtensions = {
	ani = true,
	dx80 = true,
	dx90 = true,
	mdl = true,
	mp3 = true,
	ogg = true,
	phy = true,
	png = true,
	sw = true,
	ttf = true,
	vmt = true,
	vtf = true,
	vtx = true,
	vvd = true,
	wav = true
}
local contentRoots = { "materials", "models", "resource", "sound" }
local localFiles = 0
local registeredFiles = {}

local function registerLocalDirectory(physicalDirectory, virtualDirectory)
	local files, directories = file.Find(physicalDirectory .. "/*", "GAME")
	for _, filename in ipairs(files or {}) do
		if not string.StartWith(filename, "._") then
			local extension = string.lower(string.GetExtensionFromFilename(filename) or "")
			local virtualPath = virtualDirectory .. "/" .. filename
			if downloadableExtensions[extension] and not registeredFiles[virtualPath] then
				resource.AddSingleFile(virtualPath)
				registeredFiles[virtualPath] = true
				localFiles = localFiles + 1
			end
		end
	end
	for _, directory in ipairs(directories or {}) do
		if not string.StartWith(directory, "._") then
			registerLocalDirectory(physicalDirectory .. "/" .. directory, virtualDirectory .. "/" .. directory)
		end
	end
end

for _, addonDirectory in ipairs(Delivery.LocalContent) do
	for _, root in ipairs(contentRoots) do
		registerLocalDirectory(addonDirectory .. "/" .. root, root)
	end
end

Delivery.LocalContentFiles = localFiles

print(string.format(
	"[DRP WORKSHOP] queued %d public Workshop items and %d local FastDL files from collection %s; replaced dependencies=%d",
	count,
	localFiles,
	Delivery.CollectionID,
	table.Count(Delivery.Unavailable)
))

for workshopID, title in pairs(Delivery.Unavailable) do
	ErrorNoHalt(string.format(
		"[DRP WORKSHOP] REMOVED ITEM %s (%s) replaced by local FastDL content; remove it from the Steam collection.\n",
		workshopID,
		title
	))
end

concommand.Add("drp_workshop_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	print(string.format(
		"[DRP WORKSHOP] collection=%s workshop=%d fastdl_files=%d replaced=%d",
		Delivery.CollectionID,
		table.Count(Delivery.Items),
		Delivery.LocalContentFiles,
		table.Count(Delivery.Unavailable)
	))
	for workshopID, title in SortedPairs(Delivery.Items) do
		print(string.format("  READY   %s  %s", workshopID, title))
	end
	for workshopID, title in SortedPairs(Delivery.Unavailable) do
		print(string.format("  REMOVED %s  %s", workshopID, title))
	end
end)
