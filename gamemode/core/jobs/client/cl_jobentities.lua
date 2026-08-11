local trackedEntities = setmetatable({}, { __mode = "k" })
local labelCache = setmetatable({}, { __mode = "k" })
local labelBackground = Color(12, 16, 22, 225)
local trackedClasses = {
	drp_weapon_crate = true,
	drp_tip_jar = true,
	drp_drug = true,
	drp_jailer = true,
	drp_councilman = true,
	drp_police_armory = true,
	drp_atm = true,
	drp_spawn_bed = true,
	drp_mp3_player = true
}

local function refreshTrackedEntity(entity)
	if not IsValid(entity) then return end
	trackedEntities[entity] = trackedClasses[entity:GetClass()] == true or entity:GetNW2Bool("DRPEvidenceLocker", false) or nil
end

hook.Add("InitPostEntity", "DRP.JobEntities.IndexExisting", function()
	for _, entity in ents.Iterator() do refreshTrackedEntity(entity) end
end)

hook.Add("OnEntityCreated", "DRP.JobEntities.IndexCreated", function(entity)
	if not IsValid(entity) or not trackedClasses[entity:GetClass()] then return end
	timer.Simple(0, function() refreshTrackedEntity(entity) end)
end)

hook.Add("EntityNetworkedVarChanged", "DRP.JobEntities.IndexEvidence", function(entity, key)
	if key == "DRPEvidenceLocker" then refreshTrackedEntity(entity) end
	if string.StartWith(tostring(key or ""), "DRP") then labelCache[entity] = nil end
end)

hook.Add("EntityRemoved", "DRP.JobEntities.Unindex", function(entity)
	trackedEntities[entity] = nil
	labelCache[entity] = nil
end)

local function entityLabel(ply, entity, now)
	local cached = labelCache[entity]
	if cached and cached.expires > now then return cached.title, cached.detail end
	local class = entity:GetClass()
	local title = entity:GetNW2String("DRPJobEntityName", entity:GetNW2Bool("DRPEvidenceLocker", false) and "Evidence Storage" or entity.PrintName or class)
	local detail = entity:GetNW2String("DRPOwnerName", "")
	if class == "drp_weapon_crate" then
		detail = "CASE QUANTITY  ×" .. entity:GetNW2Int("DRPCount", 0)
	elseif class == "drp_drug" then
		detail = "Press E to consume"
	elseif class == "drp_jailer" then
		detail = "Bring a cuffed suspect here • Press E to book"
	elseif class == "drp_councilman" then
		detail = "Press E to register or update your civic identity"
	elseif class == "drp_mp3_player" then
		detail = "Press E to control • Radius " .. math.Round(entity:GetMP3Radius()) .. "u"
	elseif class == "drp_police_armory" then
		detail = ply:DRPJob().isPolice and "Press E to purchase weapons"
			or (ply:DRPHasRoleCapability("canRaid") and "Press E to begin or join a raid" or "Police access only")
	elseif class == "drp_spawn_bed" then
		detail = "Press E to set home or fast travel"
	elseif class == "drp_atm" then
		detail = "Press E to buy treasury-backed municipal bonds"
	end
	labelCache[entity] = { title = title, detail = detail, expires = now + 0.25 }
	return title, detail
end

hook.Add("PostDrawTranslucentRenderables", "DRP.JobEntities.Labels", function(_, sky)
	if sky then return end
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local playerPosition, eyeYaw, now = ply:GetPos(), EyeAngles().y, CurTime()
	local angle = Angle(0, eyeYaw - 90, 90)
	for entity in pairs(trackedEntities) do
		if not IsValid(entity) then
			trackedEntities[entity] = nil
		elseif not entity:IsDormant() and not entity:GetNoDraw() and playerPosition:DistToSqr(entity:GetPos()) < 262144 then
			local title, detail = entityLabel(ply, entity, now)
			cam.Start3D2D(entity:GetPos() + Vector(0, 0, entity:OBBMaxs().z + 8), angle, 0.08)
				draw.RoundedBox(6, -120, -28, 240, 56, labelBackground)
				draw.SimpleText(title, "DRP.Admin.Body", 0, -12, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				draw.SimpleText(detail, "DRP.Admin.Small", 0, 12, DRP.UI.Colors.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			cam.End3D2D()
		end
	end
end)
