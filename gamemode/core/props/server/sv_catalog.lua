local Props = assert(DRP and DRP.Props, "props service must exist before catalogue loads")
local blacklistSnapshotMessage = "drp_prop_blacklist_snapshot_v1"
local catalogBeginMessage = "drp_prop_catalog_begin_v1"
local catalogChunkMessage = "drp_prop_catalog_chunk_v1"
local catalogEndMessage = "drp_prop_catalog_end_v1"

local function catalogFingerprint()
	local addonParts = {}
	if engine and isfunction(engine.GetAddons) then
		local success, addons = pcall(engine.GetAddons)
		if success and istable(addons) then
			for _, addon in ipairs(addons) do
				if addon.mounted ~= false then
					addonParts[#addonParts + 1] = table.concat({
						tostring(addon.wsid or addon.file or addon.title or ""),
						tostring(addon.updated or ""),
						tostring(addon.size or "")
					}, ":")
				end
			end
		end
	end
	table.sort(addonParts)
	return util.CRC(table.concat({ tostring(VERSIONSTR or VERSION or ""), table.concat(addonParts, "|") }, "\n"))
end

function Props:LoadCatalogCache()
	local decoded = util.JSONToTable(file.Read(self.CatalogCachePath, "DATA") or "")
	if not istable(decoded) or decoded.version ~= self.CatalogCacheVersion or decoded.fingerprint ~= catalogFingerprint() then return false end
	if not istable(decoded.models) or not istable(decoded.prices) or #decoded.models == 0 or #decoded.models ~= #decoded.prices then return false end

	self.Catalog = {}
	self.CatalogByModel = {}
	self.AutomaticPrices = {}
	for index, rawModel in ipairs(decoded.models) do
		local model = DRP.Props.NormalizeModel(rawModel)
		local price = math.Clamp(math.floor(tonumber(decoded.prices[index]) or 0), 1, 65535)
		if model and not self.CatalogByModel[model] then
			self.CatalogByModel[model] = true
			self.AutomaticPrices[model] = price
			self.Catalog[#self.Catalog + 1] = model
		end
	end
	if #self.Catalog == 0 then return false end
	self.CatalogReady = true
	self.CatalogGeneration = (self.CatalogGeneration % 65535) + 1
	print(string.format("[DRP] loaded %d server props from cache", #self.Catalog))
	return true
end

function Props:SaveCatalogCache()
	local prices = {}
	for index, model in ipairs(self.Catalog) do prices[index] = self.AutomaticPrices[model] or 10 end
	local payload = util.TableToJSON({
		version = self.CatalogCacheVersion,
		fingerprint = catalogFingerprint(),
		models = self.Catalog,
		prices = prices
	}, false)
	if payload then file.Write(self.CatalogCachePath, payload) end
end

function Props:StartCatalogScan()
	self:BeginCatalogScan()
	timer.Create("DRP.Props.CatalogScan", 0.01, 0, function() self:ScanCatalogStep() end)
end

function Props:Start()
	self.Stopping = false
	file.CreateDir("darkrp")
	local decoded = util.JSONToTable(file.Read(self.DataPath, "DATA") or "")
	if istable(decoded) then
		for model, blocked in pairs(decoded) do
			model = DRP.Props.NormalizeModel(model)
			if model and blocked == true then self.Blacklist[model] = true end
		end
	end
	local prices = util.JSONToTable(file.Read(self.PriceDataPath, "DATA") or "")
	if istable(prices) then
		for model, price in pairs(prices) do
			model = DRP.Props.NormalizeModel(model)
			price = math.floor(tonumber(price) or 0)
			if model and price >= 1 and price <= 65535 then self.PriceOverrides[model] = price end
		end
	end
	self:LoadPersistence()
	if not self:LoadCatalogCache() then self:StartCatalogScan() else self:PrepareCatalogPayload() end
	hook.Add("InitPostEntity", "DRP.Props.RestorePersistent", function()
		timer.Simple(0, function()
			if DRP.Props == self then self:RestorePersistence() end
		end)
	end)
end

function Props:Stop()
	self.Stopping = true
	self.ActiveZonePhysgun = setmetatable({}, { __mode = "k" })
	self.NextZonePhysgunCheck = 0
	for ent in pairs(self.CleanupRecords or {}) do self:CancelCleanup(ent) end
	if self.DisarmZonePhysgunValidation then self:DisarmZonePhysgunValidation() end
	timer.Remove("DRP.Props.CatalogScan")
	timer.Remove("DRP.Props.CatalogTransfer")
	timer.Remove("DRP.Props.EntityCleanup")
	hook.Remove("InitPostEntity", "DRP.Props.RestorePersistent")
	self:CaptureAllPersistent()
	self:SavePersistence()
end

function Props:BeginCatalogScan()
	self.Catalog = {}
	self.CatalogByModel = {}
	self.AutomaticPrices = {}
	self.CatalogReady = false
	self.CatalogDirectories = { "models" }
	self.CatalogSeenDirectories = { models = true }
	self.CatalogCandidates = {}
	self.CatalogCandidateIndex = 1
end

local function automaticPrice(model)
	local infoOk, info = pcall(util.GetModelInfo, model)
	if not infoOk or not istable(info) then return 10 end
	-- Model KeyValues are third-party input and are frequently malformed. The
	-- engine parser prints errors before Lua's pcall can catch them, so pricing
	-- uses the model hull instead. This is deterministic, cheap and sufficient
	-- for the size-based price curve.
	local volume = 0
	if isvector(info.HullMin) and isvector(info.HullMax) then
		local size = info.HullMax - info.HullMin
		volume = math.abs(size.x * size.y * size.z)
	end
	if volume <= 0 then return 10 end
	return math.Clamp(math.ceil((volume ^ (1 / 3)) * 0.75), 5, 65535)
end

function Props.Price(model)
	model = DRP.Props.NormalizeModel(model)
	if not model then return 0 end
	if Props.PriceOverrides[model] then return Props.PriceOverrides[model], true end
	if not Props.AutomaticPrices[model] then Props.AutomaticPrices[model] = automaticPrice(model) end
	return Props.AutomaticPrices[model], false
end

function Props:SavePrices()
	file.Write(self.PriceDataPath, util.TableToJSON(self.PriceOverrides, true))
end

function Props.CanManagePrices(ply)
	return IsValid(ply) and DRP.Admin and DRP.Admin.Has(ply, "prop_prices")
end

local function addDirectoryContents(service, directory)
	local files, directories = file.Find(directory .. "/*", "GAME")
	for _, filename in ipairs(files or {}) do
		if string.sub(string.lower(filename), -4) == ".mdl" then
			service.CatalogCandidates[#service.CatalogCandidates + 1] = directory .. "/" .. filename
		end
	end
	for _, child in ipairs(directories or {}) do
		if child ~= "." and child ~= ".." then
			local path = directory .. "/" .. child
			if not service.CatalogSeenDirectories[path] then
				service.CatalogSeenDirectories[path] = true
				service.CatalogDirectories[#service.CatalogDirectories + 1] = path
			end
		end
	end
end

function Props:FinishCatalogScan()
	table.sort(self.Catalog)
	self.CatalogReady = true
	self.CatalogGeneration = (self.CatalogGeneration % 65535) + 1
	timer.Remove("DRP.Props.CatalogScan")
	self:SaveCatalogCache()
	self:PrepareCatalogPayload()
	print(string.format("[DRP] indexed %d server props", #self.Catalog))
	for ply, clientFingerprint in pairs(self.CatalogWaiting) do
		if IsValid(ply) then self:StartCatalogTransfer(ply, clientFingerprint) end
	end
	self.CatalogWaiting = setmetatable({}, {__mode = "k"})
end

function Props:ScanCatalogStep()
	if self.CatalogReady then timer.Remove("DRP.Props.CatalogScan") return end
	-- Keep discovery off the hot path and cap validation work to roughly 2 ms
	-- per server frame. The completed index is then reused for the whole uptime.
	local started = DRP.Profile.Begin()
	local deadline = SysTime() + 0.001
	while SysTime() < deadline do
		local candidate = self.CatalogCandidates[self.CatalogCandidateIndex]
		if candidate then
			self.CatalogCandidateIndex = self.CatalogCandidateIndex + 1
			local model = DRP.Props.NormalizeModel(candidate)
			if model and not self.CatalogByModel[model] and util.IsValidModel(model) and util.IsValidProp(model) then
				self.CatalogByModel[model] = true
				self.AutomaticPrices[model] = automaticPrice(model)
				self.Catalog[#self.Catalog + 1] = model
			end
		else
			self.CatalogCandidates = {}
			self.CatalogCandidateIndex = 1
			local directory = table.remove(self.CatalogDirectories)
			if not directory then self:FinishCatalogScan() DRP.Profile.Finish("props.catalog_scan", started) return end
			addDirectoryContents(self, directory)
		end
	end
	DRP.Profile.Finish("props.catalog_scan", started)
end

function Props:PrepareCatalogPayload()
	if not self.CatalogReady then return false end
	local records = {}
	for index, model in ipairs(self.Catalog) do
		local price, overridden = self.Price(model)
		records[index] = { model, price, overridden == true and 1 or 0 }
	end
	local json = util.TableToJSON(records, false) or "[]"
	local compressed = util.Compress(json) or ""
	self.CatalogFingerprint = util.CRC(json)
	self.CatalogGeneration = tonumber(self.CatalogFingerprint) or 0
	self.CatalogCompressedChunks = {}
	-- Small chunks prevent one catalogue packet from monopolising a client
	-- channel; the global pump sends at most one of these every 100 ms.
	local chunkSize = 12000
	for offset = 1, #compressed, chunkSize do
		self.CatalogCompressedChunks[#self.CatalogCompressedChunks + 1] = string.sub(compressed, offset, offset + chunkSize - 1)
	end
	if #self.CatalogCompressedChunks == 0 then self.CatalogCompressedChunks[1] = util.Compress("[]") or "" end
	return true
end

function Props:StartCatalogTransfer(ply, clientFingerprint)
	if not IsValid(ply) then return end
	if not self.CatalogReady then
		self.CatalogWaiting[ply] = tostring(clientFingerprint or "")
		return
	end
	if self.CatalogFingerprint == "" then self:PrepareCatalogPayload() end
	if tostring(clientFingerprint or "") == self.CatalogFingerprint then return end

	net.Start(catalogBeginMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteString(self.CatalogFingerprint)
	net.WriteUInt(#self.Catalog, 32)
	net.WriteBool(true)
	net.WriteUInt(#self.CatalogCompressedChunks, 16)
	net.Send(ply)
	if DRP.Net.Record then DRP.Net.Record(12 + #self.CatalogFingerprint, 1) end
	local existing = self.CatalogTransferIndex[ply]
	if existing then existing.player = nil self.CatalogTransferIndex[ply] = nil end
	local transfer = { player = ply, fingerprint = self.CatalogFingerprint, index = 1 }
	self.CatalogTransferQueue[#self.CatalogTransferQueue + 1] = transfer
	self.CatalogTransferIndex[ply] = transfer
	if not timer.Exists("DRP.Props.CatalogTransfer") then
		timer.Create("DRP.Props.CatalogTransfer", 0.1, 0, function() self:PumpCatalogTransfers() end)
	end
end

function Props:PumpCatalogTransfers()
	local sent = 0
	while sent < self.CatalogChunksPerPump and self.CatalogTransferHead <= #self.CatalogTransferQueue do
		local transfer = self.CatalogTransferQueue[self.CatalogTransferHead]
		local ply = transfer.player
		if not IsValid(ply) or transfer.fingerprint ~= self.CatalogFingerprint then
			self.CatalogTransferIndex[ply] = nil
			self.CatalogTransferHead = self.CatalogTransferHead + 1
		else
			local chunk = self.CatalogCompressedChunks[transfer.index]
			if chunk then
				net.Start(catalogChunkMessage)
				net.WriteUInt(DRP.ProtocolVersion, 8)
				net.WriteString(transfer.fingerprint)
				net.WriteUInt(transfer.index, 16)
				net.WriteUInt(#self.CatalogCompressedChunks, 16)
				net.WriteUInt(#chunk, 16)
				net.WriteData(chunk, #chunk)
				net.Send(ply)
				if DRP.Net.Record then DRP.Net.Record(#chunk + #transfer.fingerprint + 10, 1) end
				transfer.index = transfer.index + 1
				sent = sent + 1
				self.CatalogTransferQueue[#self.CatalogTransferQueue + 1] = transfer
				self.CatalogTransferHead = self.CatalogTransferHead + 1
			else
				net.Start(catalogEndMessage)
				net.WriteUInt(DRP.ProtocolVersion, 8)
				net.WriteString(transfer.fingerprint)
				net.Send(ply)
				if DRP.Net.Record then DRP.Net.Record(#transfer.fingerprint + 4, 1) end
				self.CatalogTransferIndex[ply] = nil
				self.CatalogTransferHead = self.CatalogTransferHead + 1
			end
		end
	end
	if self.CatalogTransferHead > #self.CatalogTransferQueue then
		self.CatalogTransferQueue, self.CatalogTransferHead = {}, 1
		timer.Remove("DRP.Props.CatalogTransfer")
	end
end

function Props:SaveBlacklist()
	file.Write(self.DataPath, util.TableToJSON(self.Blacklist, true))
end

function Props.IsBlacklisted(model)
	model = DRP.Props.NormalizeModel(model)
	return model ~= nil and Props.Blacklist[model] == true
end

function Props.CanManageBlacklist(ply)
	return IsValid(ply) and DRP.Admin and DRP.Admin.Has(ply, "props")
end

function Props.SendBlacklist(ply)
	if not IsValid(ply) then return end
	local models = {}
	for model in pairs(Props.Blacklist) do models[#models + 1] = model end
	table.sort(models)
	net.Start(blacklistSnapshotMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.min(#models, 65535), 16)
	for index = 1, math.min(#models, 65535) do net.WriteString(models[index]) end
	net.Send(ply)
end

function Props.BroadcastBlacklist()
	for _, ply in ipairs(DRP.Players.List) do Props.SendBlacklist(ply) end
end

Props.CatalogModuleLoaded = true
