local Service = { ByKey = {}, EvidenceLocker = nil, Evidence = {}, EvidenceDirty = false }
DRP.JobEntityService = Service
DRP.Services.Register("job_entities", Service)

local spawnMessage = "drp_job_entity_spawn_v1"
util.AddNetworkString(spawnMessage)
resource.AddWorkshop(DRP.WeaponCaseWorkshopID)

for _, definition in ipairs(DRP.JobEntities) do Service.ByKey[definition.key] = definition end

local function allowed(ply, definition)
	if not IsValid(ply) or not ply:IsPlayer() then return false, "Invalid player." end
	if not istable(definition) then return false, "Unknown job entity." end

	-- Owner is the world builder and must be able to place/test every job entity,
	-- including crafting infrastructure while currently occupying a government job.
	-- This check must precede crafting and civic-role restrictions.
	if DRP.Admin and DRP.Admin.IsOwner(ply) then return true end

	local job = ply:DRPJob()
	if definition.ownerOnly then return false, "Only the Owner can place this server infrastructure." end
	if definition.crafting then
		if job.isPolice or job.isMayor or job.isGovernment then
			return false, "Government roles cannot place crafting tables."
		end
		return true
	end

	if DRP.CivicPermissions then
		if DRP.CivicPermissions:CanSpawn(ply, definition) then return true end
		if definition.class == "drp_weapon_crate" then
			return false, "This weapon case requires Gun Dealer access or configured Mob Boss access."
		end
		if definition.police then return false, "This entity requires a police role." end
		if definition.job then
			return false, "Your current role or civic pathway cannot spawn this " .. tostring(definition.name or "entity") .. "."
		end
		return false, "Your civic standing does not permit this entity."
	end

	if definition.police and job.isPolice == true then return true end
	if definition.job and (job.key == definition.job
		or (DRP.Roles and DRP.Roles:CanAccessRoleTools(ply, definition.job))) then return true end
	if DRP.Admin and DRP.AdminRankLevel(DRP.Admin.BaseRankKey(ply)) >= DRP.AdminRankLevel("admin") then return true end
	return false, "Your current role cannot spawn this entity."
end

function Service.CanSpawn(ply, definition)
	if not istable(definition) then definition = Service.ByKey[tostring(definition or "")] end
	return allowed(ply, definition)
end

local function countOwned(ply, key)
	local count = 0
	local props = DRP.Services.Get("props")
	local owned = props and ((props.ByOwnerID and props.ByOwnerID[ply:SteamID64()]) or (props.ByPlayer and props.ByPlayer[ply])) or {}
	for entity in pairs(owned or {}) do
		if IsValid(entity) and entity.DRPJobEntityKey == key then count = count + 1 end
	end
	return count
end

local function limitedKind(definition)
	if definition.limitedKind then return definition.limitedKind end
	if definition.class == "drp_drug" then return "drug" end
	if definition.class == "drp_weapon_crate" then return "crate" end
end

local function spawnPositionFor(entity, trace)
	local mins = entity and entity:OBBMins() or Vector(-10, -10, -10)
	local offset = 4 + (-mins.z)
	if mins == nil or mins.z == 0 then offset = 18 end
	return trace.HitPos + trace.HitNormal * math.max(offset, 4)
end

local function placementTrace(ply)
	-- Do not use Player:GetEyeTrace here. Its cached result can still represent
	-- the spawn-menu cursor frame when this request arrives, causing every job
	-- entity click to be discarded with no visible result. Build a fresh,
	-- server-authoritative trace from the player's current view instead.
	local startPosition = ply:EyePos()
	local trace = util.TraceLine({
		start = startPosition,
		endpos = startPosition + ply:GetAimVector() * 512,
		filter = ply,
		mask = MASK_SOLID
	})
	if not trace.Hit then return nil, "Look at a solid surface within 512 units before spawning this entity." end
	if trace.HitSky then return nil, "Job entities cannot be spawned on the sky." end
	return trace
end

function Service.Spawn(ply, key)
	local definition = Service.ByKey[tostring(key or "")]
	if not IsValid(ply) or not ply:IsPlayer() then return false end
	if not ply.DRPReady or not ply:DRPReady() then
		DRP.Net.Notify(ply, "Your DarkRP profile is still loading. Try again in a moment.", 3)
		return false
	end
	if not ply:Alive() then
		DRP.Net.Notify(ply, "You must be alive to spawn a job entity.", 3)
		return false
	end
	if not definition then
		DRP.Net.Notify(ply, "That job entity is not registered on the server.", 3)
		return false
	end
	local hasAccess, accessReason = allowed(ply, definition)
	if not hasAccess then
		DRP.Net.Notify(ply, accessReason or "Your role cannot spawn that entity.", 3)
		return false
	end
	local budget = DRP.Services.Get("props")
	local ownerBypass = DRP.Admin and DRP.Admin.IsOwner(ply)
	if not ownerBypass and budget and budget.CanCreateOwnedEntity and not budget.CanCreateOwnedEntity(ply) then
		DRP.Net.Notify(ply, "Your personal entity limit is full. Remove an owned entity or improve your trust/supporter capacity.", 3)
		return false
	end
	if definition.mediaPlayer and (not DRP.MediaPlayerIntegration or not DRP.MediaPlayerIntegration:IsAvailable()) then
		DRP.Net.Notify(ply, "Media Player Redux is not mounted on this server.", 3)
		return false
	end
	if definition.class == "drp_treasury_vault" and DRP.Treasury and IsValid(DRP.Treasury.Entity) then
		DRP.Net.Notify(ply, "A Treasury Vault already exists. Move or persist the existing vault instead.", 3)
		return false
	end
	if definition.class == "drp_councilman" and #ents.FindByClass("drp_councilman") > 0 then
		DRP.Net.Notify(ply, "A Councilman already exists. Move or persist the existing Councilman instead.", 3)
		return false
	end
	if (definition.class == "drp_salvage_dumpster" or definition.class == "drp_salvage_trashcan") and DRP.Salvage then
		local allowedCount, limit = DRP.Salvage:CanRegisterClass(definition.class)
		if not allowedCount then DRP.Net.Notify(ply, "The map limit of " .. limit .. " salvage containers has been reached.", 3) return false end
	end
	if string.StartWith(definition.class, "zmlab2_") and (not zclib or not zmlab2 or not zmlab2.Tent) then
		DRP.Net.Notify(ply, "MethLab failed to initialize. Ask the owner to run drp_zero_status.", 3)
		return false
	end
	if countOwned(ply, definition.key) >= (definition.countLimit or 3) then DRP.Net.Notify(ply, "Job entity limit reached.", 3) return false end
	local budgetKind = limitedKind(definition)
	local canCreateLimited = budget and budget.CanCreateLimitedEntity
	local registerLimited = budget and budget.RegisterLimitedEntity
	if not isfunction(canCreateLimited) and DRP.Props then canCreateLimited = DRP.Props.CanCreateLimitedEntity end
	if not isfunction(registerLimited) and DRP.Props then registerLimited = DRP.Props.RegisterLimitedEntity end
	if budgetKind and (not isfunction(canCreateLimited) or not canCreateLimited(budgetKind)) then
		DRP.Net.Notify(ply, "The server " .. budgetKind .. " entity budget is full.", 3)
		return false
	end
	local trace, traceReason = placementTrace(ply)
	if not trace then
		DRP.Net.Notify(ply, traceReason, 3)
		return false
	end
	if DRP.Properties and DRP.Properties.ValidateSpawnPoint then
		local permitted, _, reason = DRP.Properties:ValidateSpawnPoint(ply, trace.HitPos)
		if not permitted then
			DRP.Net.Notify(ply, reason or "Entities can only be spawned inside an authorised property build zone.", 3)
			return false
		end
	end
	local free = DRP.Experience and DRP.Experience:CanPayForItem(ply, "job_entity", definition.key)
	local price = free == true and 0 or definition.price
	if price and price > 0 and DRP.EconomyDirector then
		price = DRP.EconomyDirector:Quote("entity:" .. definition.key, "sell", price)
	end
	if price > 0 and not DRP.Economy.Take(ply, price, definition.name .. " purchased") then
		DRP.Net.Notify(ply, "You need $" .. price .. ".", 3)
		return false
	end
	local entity = ents.Create(definition.class)
	if not IsValid(entity) then
		if price > 0 then DRP.Economy.Add(ply, price, definition.name .. " creation refund") end
		DRP.Net.Notify(ply, definition.name .. " could not be created because its entity class is unavailable.", 3)
		ErrorNoHalt("[DRP JOB ENTITIES] ents.Create failed for " .. tostring(definition.class) .. " (" .. tostring(definition.key) .. ")\n")
		return false
	end
	-- Establish authoritative ownership before Initialize/Spawn hooks run.  Some
	-- scripted job entities initialise frozen or create addon-owned state during
	-- Spawn, so tagging them afterwards can leave a short (or permanent) window
	-- where ownership adapters regard them as world-owned.
	local ownerID = ply:SteamID64()
	entity.DRPJobEntityKey = definition.key
	entity.DRPJobEntityOwnerID = ownerID
	entity.DRPOwnerSteamID = ownerID
	local entityModel = definition.model
	if definition.class == "drp_weapon_crate" and not util.IsValidModel(entityModel) then
		entityModel = DRP.WeaponCaseFallbackModel
	end
	entity:SetModel(entityModel)
	entity:SetAngles(Angle(0, ply:EyeAngles().y, 0))
	entity:SetPos(spawnPositionFor(entity, trace))
	entity:Spawn()
	entity:Activate()
	if not IsValid(entity) then
		if price > 0 then DRP.Economy.Add(ply, price, definition.name .. " spawn refund") end
		DRP.Net.Notify(ply, definition.name .. " was rejected while spawning; your purchase was refunded.", 3)
		return false
	end
	local placementPropertyID
	if DRP.Properties and DRP.Properties.ValidateSpawnedEntityPlacement then
		local permitted, propertyID, reason = DRP.Properties:ValidateSpawnedEntityPlacement(ply, entity, "build")
		if not permitted then
			entity:Remove()
			if price > 0 then DRP.Economy.Add(ply, price, definition.name .. " placement refund") end
			DRP.Net.Notify(ply, reason or "The complete entity must remain inside the combined authorised build zones.", 3)
			return false
		end
		placementPropertyID = propertyID
		if propertyID then entity.DRPPropertyID = propertyID end
	end
	if definition.mediaPlayer and DRP.MediaPlayerIntegration then
		DRP.MediaPlayerIntegration:Claim(entity, ply)
	end
	if definition.weapon then
		entity:SetNW2String("DRPWeapon", definition.weapon)
		entity:SetNW2Int("DRPCount", definition.count)
		entity:SetNW2String("DRPJobEntityName", definition.name)
	else
		entity:SetNW2String("DRPJobEntityName", definition.name)
	end
	if definition.drug then entity:SetNW2String("DRPDrug", definition.drug) end
	entity:SetNW2String("DRPOwnerName", ply:DRPName())
	if budget and budget.TrackOwnedEntity then budget.TrackOwnedEntity(ply, entity, "sents", false) end
	if string.StartWith(definition.class, "zwf_") and zwf and zwf.f and zwf.f.SetOwner then
		zwf.f.SetOwner(entity, ply)
	elseif string.StartWith(definition.class, "zmlab2_") and zclib and zclib.Player and zclib.Player.SetOwner then
		zclib.Player.SetOwner(entity, ply)
	end
	if budgetKind and (not isfunction(registerLimited) or not registerLimited(entity, budgetKind)) then
		entity:Remove()
		if price > 0 then DRP.Economy.Add(ply, price, definition.name .. " entity budget refund") end
		DRP.Net.Notify(ply, "The server " .. budgetKind .. " entity budget filled before spawning completed.", 3)
		return false
	end
	if definition.class == "drp_evidence_locker" then Service.AssignEvidence(ply, entity, true) end
	if definition.class == "drp_police_armory" and DRP.Armory then DRP.Armory:RegisterEntity(entity) end
	if definition.class == "drp_treasury_vault" and DRP.Treasury then
		local registered, reason = DRP.Treasury:RegisterEntity(entity)
		if not registered then
			entity:Remove()
			if price > 0 then DRP.Economy.Add(ply, price, definition.name .. " registration refund") end
			DRP.Net.Notify(ply, reason or "The Treasury Vault could not be registered.", 3)
			return false
		end
	end
	if (definition.class == "drp_salvage_dumpster" or definition.class == "drp_salvage_trashcan") and DRP.Salvage then
		local registered, reason = DRP.Salvage:RegisterEntity(entity)
		if not registered then
			entity:Remove()
			if price > 0 then DRP.Economy.Add(ply, price, definition.name .. " registration refund") end
			DRP.Net.Notify(ply, reason or "The salvage container could not be registered.", 3)
			return false
		end
	end
	if definition.class == "drp_crafting_table" and DRP.Properties then
		local propertyID = placementPropertyID or entity.DRPPropertyID
		if not propertyID or not DRP.Properties.Can(ply, propertyID, "crafting") then
			entity:Remove()
			if price > 0 then DRP.Economy.Add(ply, price, definition.name .. " placement refund") end
			DRP.Net.Notify(ply, "Place this table fully inside a property where you have crafting permission.", 3)
			return false
		end
		entity.DRPPropertyID = propertyID
		local registered, registerReason = DRP.Crafting and DRP.Crafting:RegisterTable(entity, propertyID)
		if not registered then
			entity:Remove()
			if price > 0 then DRP.Economy.Add(ply, price, definition.name .. " registration refund") end
			DRP.Net.Notify(ply, registerReason or "The crafting table could not be registered.", 3)
			return false
		end
		-- The production budget registers before the property association. A
		-- crafting table is persistent infrastructure, not a temporary drop.
		if DRP.Props and DRP.Props.CancelCleanup then DRP.Props:CancelCleanup(entity) end
	end
	if definition.class == "drp_spawn_bed" then
		local propertyID = placementPropertyID or entity.DRPPropertyID
		if not propertyID then
			entity:Remove()
			if price > 0 then DRP.Economy.Add(ply, price, definition.name .. " placement refund") end
			DRP.Net.Notify(ply, "Place the complete bed inside a property build zone.", 3)
			return false
		end
		entity.DRPPropertyID = propertyID
		local registered, registerReason = DRP.Beds and DRP.Beds:RegisterEntity(entity, ply, propertyID)
		if not registered then
			entity:Remove()
			if price > 0 then DRP.Economy.Add(ply, price, definition.name .. " registration refund") end
			DRP.Net.Notify(ply, registerReason or "The bed could not be registered.", 3)
			return false
		end
		if DRP.Props and DRP.Props.CancelCleanup then DRP.Props:CancelCleanup(entity) end
	end
	if definition.drug and DRP.Roles then DRP.Roles:Record(ply, "narcotics", 1, "drug distribution activity") end
	if DRP.Audit then
		local purchasedAs = price == 0 and "free_experience" or tostring(price)
		DRP.Audit.Log(ply, "job_entity_spawned", entity, definition.key .. " ($" .. purchasedAs .. ")")
	end
	DRP.Net.Notify(ply, definition.name .. " spawned.", 1)
	return true
end

function Service.AssignEvidence(ply, entity, spawned)
	if not IsValid(entity) or (not spawned and (not DRP.Admin or not DRP.Admin.Has(ply, "doors"))) then return false end
	if IsValid(Service.EvidenceLocker) then Service.EvidenceLocker:SetNW2Bool("DRPEvidenceLocker", false) end
	Service.EvidenceLocker = entity
	entity:SetNW2Bool("DRPEvidenceLocker", true)
	if not spawned then
		local mapID = entity:MapCreationID()
		file.CreateDir("darkrp")
		file.Write("darkrp/evidence_" .. game.GetMap() .. ".txt", mapID and mapID >= 0 and tostring(mapID) or "")
	end
	DRP.Net.Notify(ply, "Evidence storage assigned.", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "evidence_storage_assigned", entity) end
	return true
end

function Service:Start()
	if util.IsValidModel(DRP.WeaponCaseModel) then
		util.PrecacheModel(DRP.WeaponCaseModel)
	else
		util.PrecacheModel(DRP.WeaponCaseFallbackModel)
		ErrorNoHalt("[DRP] Weapon case Workshop content is not mounted server-side. Add " .. DRP.WeaponCaseWorkshopID .. " to the server Workshop collection; using the HL2 briefcase fallback.\n")
	end
	local evidence = util.JSONToTable(file.Read("darkrp/evidence_records.json", "DATA") or "")
	if istable(evidence) then Service.Evidence = evidence end
	hook.Add("InitPostEntity", "DRP.Evidence.Restore", function()
		local wanted = tonumber(file.Read("darkrp/evidence_" .. game.GetMap() .. ".txt", "DATA") or "")
		if not wanted then return end
		for _, entity in ents.Iterator() do
			if entity:MapCreationID() == wanted then Service.EvidenceLocker = entity entity:SetNW2Bool("DRPEvidenceLocker", true) break end
		end
	end)
end

function Service:SaveEvidence()
	if not self.EvidenceDirty then return end
	file.CreateDir("darkrp")
	file.Write("darkrp/evidence_records.json", util.TableToJSON(self.Evidence, false))
	self.EvidenceDirty = false
end

function Service:Stop()
	hook.Remove("InitPostEntity", "DRP.Evidence.Restore")
	self:SaveEvidence()
end

function Service.StoreEvidence(officer, suspect, weaponClass, incident)
	Service.Evidence[#Service.Evidence + 1] = { weapon = weaponClass, suspect = IsValid(suspect) and suspect:DRPName() or "Unknown", officer = IsValid(officer) and officer:DRPName() or "System", incident = incident and incident.id or 0, time = os.time() }
	if #Service.Evidence > 100 then table.remove(Service.Evidence, 1) end
	Service.EvidenceDirty = true
	hook.Run("DRPEvidenceStored", officer, suspect, weaponClass, incident)
end

hook.Add("PlayerDisconnected", "DRP.Evidence.LifecycleSave", function() Service:SaveEvidence() end)

function Service.Use(entity, ply)
	if not IsValid(ply) or not ply:DRPReady() then return end
	local class = entity:GetClass()
	if class == "drp_weapon_crate" then
		local count, weapon = entity:GetNW2Int("DRPCount", 0), entity:GetNW2String("DRPWeapon", "")
		if entity:GetNW2Bool("DRPRandomWeaponCrate", false) and DRP.Armory then weapon = DRP.Armory:RandomWeaponClass() or "" end
		if count <= 0 or weapon == "" then return end
		if DRP.WeaponAccess and not DRP.WeaponAccess.CanUse(ply, weapon) then
			DRP.Net.Notify(ply, weapon .. " requires the Admin rank or higher.", 3)
			return
		end
		if not DRP.Inventory or not DRP.Inventory.CreateWeaponRecord then DRP.Net.Notify(ply, "Hands inventory is not ready.", 3) return end
		if ply:HasWeapon(weapon) or DRP.Inventory.HasWeaponRecord(ply, weapon) then DRP.Net.Notify(ply, "You already own that weapon.", 3) return end
		local item = DRP.Inventory.CreateWeaponRecord(weapon)
		if not item or not DRP.Inventory.InsertRaw(ply, item) then DRP.Net.Notify(ply, "Make room in Hands before taking that weapon.", 3) return end
		entity:SetNW2Int("DRPCount", count - 1)
		if count <= 1 then entity:Remove() end
		DRP.Net.Notify(ply, item.label .. " was placed in Hands. Equip it before use.", 1)
		if DRP.Audit then DRP.Audit.Log(ply, "weapon_taken_from_crate", entity, weapon) end
	elseif class == "drp_tip_jar" then
		local owner = DRP.Props.Owner(entity)
		if not IsValid(owner) or owner == ply then return end
		DRP.Economy.Transfer(ply, owner, 10, "tip")
	elseif class == "drp_drug" then
		if DRP.Drugs and DRP.Drugs.Ingest(ply, entity:GetNW2String("DRPDrug", ""), nil, false) then entity:Remove() end
	elseif class == "drp_jailer" then
		if DRP.Legal then DRP.Legal.BookAtJailer(ply, entity) end
	elseif class == "drp_councilman" then
		if DRP.Identity then DRP.Identity:Open(ply, entity) end
	elseif class == "drp_police_armory" then
		if DRP.Armory then DRP.Armory:Use(ply, entity) end
	elseif class == "drp_treasury_vault" then
		if DRP.Treasury then DRP.Treasury:Use(ply, entity) end
	elseif class == "drp_atm" then
		if DRP.Bonds then DRP.Bonds:Use(ply, entity) end
	elseif class == "drp_salvage_dumpster" or class == "drp_salvage_trashcan" then
		if DRP.Salvage then DRP.Salvage:Open(ply, entity) end
	elseif class == "drp_crafting_table" then
		if DRP.Crafting then DRP.Crafting:Use(entity, ply) end
	elseif class == "drp_spawn_bed" then
		if DRP.Beds then DRP.Beds:Use(ply, entity) end
	elseif entity:GetNW2Bool("DRPEvidenceLocker", false) then
		if not ply:DRPJob().isPolice and (not DRP.Admin or not DRP.Admin.Has(ply, "logs")) then return end
		local latest = Service.Evidence[#Service.Evidence]
		DRP.Net.Notify(ply, latest and (#Service.Evidence .. " evidence items. Latest: " .. latest.weapon .. " from " .. latest.suspect .. " (incident #" .. latest.incident .. ").") or "Evidence storage is empty.", 0)
	end
end

DRP.Net.Receive(spawnMessage, function(_, ply)
	local protocol = net.ReadUInt(8)
	if protocol ~= DRP.ProtocolVersion then
		DRP.Net.Notify(ply, "Job entity request is out of date. Rejoin to load the current client files.", 3)
		return
	end
	if not DRP.Net.Allow(ply, "job_entity_spawn", 0.2, 5) then
		DRP.Net.Notify(ply, "Job entities are being selected too quickly. Wait a moment.", 3)
		return
	end
	Service.Spawn(ply, string.sub(net.ReadString(), 1, 32))
end)

concommand.Add("drp_job_entity_status", function(ply, _, args)
	if not IsValid(ply) then return end
	local key = tostring(args[1] or "")
	local definition = Service.ByKey[key]
	if key == "" then
		DRP.Net.Notify(ply, "Usage: drp_job_entity_status <entity key>", 0)
		return
	end
	if not definition then
		DRP.Net.Notify(ply, "Unknown job entity key: " .. string.sub(key, 1, 64), 3)
		return
	end
	local canSpawn, reason = Service.CanSpawn(ply, definition)
	local budget = DRP.Services.Get("props")
	local count = budget and budget.OwnedEntityCount and budget.OwnedEntityCount(ply) or 0
	local limit = budget and budget.TrustEntityLimit and budget.TrustEntityLimit(ply) or 0
	local perItem = countOwned(ply, definition.key)
	DRP.Net.Notify(ply, (canSpawn and "Allowed" or (reason or "Denied"))
		.. " | owned " .. count .. "/" .. limit
		.. " | item " .. perItem .. "/" .. (definition.countLimit or 3), canSpawn and 1 or 3)
end)

hook.Add("PlayerUse", "DRP.Evidence.Use", function(ply, entity)
	if entity:GetNW2Bool("DRPEvidenceLocker", false) then Service.Use(entity, ply) return false end
end)
