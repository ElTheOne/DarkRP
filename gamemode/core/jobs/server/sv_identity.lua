local OPEN = "drp_identity_open_v1"
local SUBMIT = "drp_identity_submit_v2"
local RESULT = "drp_identity_result_v1"
util.AddNetworkString(OPEN)
util.AddNetworkString(SUBMIT)
util.AddNetworkString(RESULT)

local Identity = { States = setmetatable({}, { __mode = "k" }), RecoveryDirectory = "darkrp/identity_recovery" }
DRP.Identity = Identity
DRP.Services.Register("identity", Identity)
file.CreateDir(Identity.RecoveryDirectory)

local function stateKey(steamID64) return "identity:" .. tostring(steamID64 or "0") end
local function recoveryPath(steamID64) return Identity.RecoveryDirectory .. "/" .. tostring(steamID64 or "0") .. ".json" end

local function cleanName(value)
	local name = string.gsub(string.gsub(string.Trim(tostring(value or "")), "%c", ""), "%s+", " ")
	if #name < 3 or #name > 48 then return nil, "Names must contain between 3 and 48 characters." end
	return name
end

local function nameAvailable(ply, name)
	local lowered = string.lower(name)
	for _, target in ipairs(DRP.Players.List or {}) do
		if target ~= ply and IsValid(target) and string.lower(tostring(target:DRPName() or "")) == lowered then
			return false
		end
	end
	return true
end

local function decode(payload)
	if not isstring(payload) or payload == "" then return nil end
	local decoded = util.JSONToTable(payload)
	if not istable(decoded) then return nil end
	return DRP.IdentityCatalog.Normalize(decoded)
end

function Identity:IsRegistered(ply)
	local state = IsValid(ply) and self.States[ply]
	return state ~= nil and state.registered == true
end

function Identity:BuildSnapshot(ply)
	local state = self.States[ply] or DRP.IdentityCatalog.Normalize()
	return table.Copy(state)
end

function Identity:Save(ply)
	if not IsValid(ply) or ply:IsBot() then return false end
	local state = self.States[ply]
	if not state then return false end
	state.updated_at = os.time()
	local payload = util.TableToJSON(state, false)
	if not payload then return false end
	local path = recoveryPath(ply:SteamID64())
	file.Write(path, payload)
	return DRP.Storage.SaveWorldState(stateKey(ply:SteamID64()), payload, function(saved)
		if saved and file.Read(path, "DATA") == payload then file.Delete(path) end
	end)
end

function Identity:Load(ply, row, persistent, callback)
	if not IsValid(ply) then return false end
	if ply:IsBot() then
		local state = DRP.IdentityCatalog.Normalize({ registered = true, name = ply:Nick(), head = 7 })
		self.States[ply] = state
		if callback then callback(state) end
		return true
	end
	local steamID64 = ply:SteamID64()
	local recovery = decode(file.Read(recoveryPath(steamID64), "DATA"))
	local function finish(databaseState)
		if not IsValid(ply) then return end
		local state = databaseState
		local migrated = false
		if recovery and (not state or recovery.updated_at >= state.updated_at) then state = recovery end
		local legacyName = persistent and row and cleanName(row.rp_name) or nil
		if not state and legacyName then
			state = DRP.IdentityCatalog.Normalize({ registered = true, name = legacyName, head = 7, updated_at = os.time() })
			migrated = true
		else
			state = DRP.IdentityCatalog.Normalize(state)
		end
		self.States[ply] = state
		if state.registered and state.name ~= "" then ply.DRPRPNameValue = state.name end
		if migrated then self:Save(ply) end
		if callback then callback(state) end
	end
	return DRP.Storage.LoadWorldState(stateKey(steamID64), function(_, payload) finish(decode(payload)) end)
end

local function canUseCouncilman(ply, entity)
	if not IsValid(ply) or not ply:DRPReady() or not ply:Alive() then return false, "You must be alive and fully loaded." end
	if not IsValid(entity) or entity:GetClass() ~= "drp_councilman" then return false, "That Councilman is unavailable." end
	local job = ply:DRPJob()
	if job and job.isHobo then
		return false, "Hobos cannot register or update a civic identity with the Councilman. Purchase a property and establish yourself first."
	end
	if ply:GetPos():DistToSqr(entity:GetPos()) > 25600 then return false, "Move closer to the Councilman." end
	if DRP.AdminMode and DRP.AdminMode.IsActive(ply) then return false, "Leave admin mode before changing an identity." end
	if DRP.Legal and DRP.Legal.IsCuffed(ply) then return false, "You cannot register while detained." end
	if DRP.Incidents and next(DRP.Incidents.ByPlayer[ply] or {}) then return false, "Resolve your active incident before changing an identity." end
	local trace = util.TraceLine({ start = ply:EyePos(), endpos = entity:WorldSpaceCenter(), filter = { ply, entity }, mask = MASK_SOLID })
	if trace.Hit then return false, "Keep the Councilman in clear view." end
	return true
end

local function sendResult(ply, success, message)
	net.Start(RESULT) net.WriteBool(success == true) net.WriteString(string.sub(tostring(message or ""), 1, 160)) net.Send(ply)
end

function Identity:Open(ply, entity)
	local allowed, reason = canUseCouncilman(ply, entity)
	if not allowed then DRP.Net.Notify(ply, reason, 3) return false end
	local payload = util.Compress(util.TableToJSON(self:BuildSnapshot(ply), false) or "{}") or ""
	net.Start(OPEN)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(entity:EntIndex(), 13)
	net.WriteUInt(math.min(#payload, 65535), 16)
	net.WriteData(payload, math.min(#payload, 65535))
	net.Send(ply)
	return true
end

local function applyModelAppearance(ply, model, appearance)
	if not model or not util.IsValidModel(model) then return false end
	appearance = istable(appearance) and appearance or {}
	ply:SetModel(model)
	ply:SetSkin(math.Clamp(math.floor(tonumber(appearance.skin) or 0), 0, math.max(0, ply:SkinCount() - 1)))
	for rawID, rawValue in pairs(appearance.bodygroups or {}) do
		local id = math.floor(tonumber(rawID) or -1)
		if id >= 0 and id < ply:GetNumBodyGroups() then
			local count = ply:GetBodygroupCount(id)
			if count and count > 0 then
				ply:SetBodygroup(id, math.Clamp(math.floor(tonumber(rawValue) or 0), 0, count - 1))
			end
		end
	end
	return true
end

function Identity:ApplyAppearance(ply)
	if not IsValid(ply) then return false end
	local job = ply:DRPJob()
	-- Hobo is a fixed visual identity. It must take precedence over the
	-- registered citizen appearance on every spawn and derived-role change.
	if job and job.isHobo then
		return applyModelAppearance(ply, job.model, { skin = 0, bodygroups = {} })
	end
	local state = self.States[ply]
	if not state or not state.registered then return false end
	if job and job.isPolice then
		local policeAppearance = state.uniforms and state.uniforms.police or {}
		return applyModelAppearance(ply, job.model or DRP.IdentityCatalog.PoliceModel(), policeAppearance)
	end
	if job and job.isGovernment then return false end
	local model = DRP.IdentityCatalog.Model(state.gender, state.outfit, state.head)
	return applyModelAppearance(ply, model, { skin = state.skin, bodygroups = state.bodygroups })
end

function Identity:UpdateName(ply, name)
	local state = self.States[ply]
	if not state or not state.registered then return false end
	state.name = name
	return self:Save(ply)
end

function Identity:Register(ply, entity, request)
	local allowed, reason = canUseCouncilman(ply, entity)
	if not allowed then return false, reason end
	local name, nameReason = cleanName(request.name)
	if not name then return false, nameReason end
	if not nameAvailable(ply, name) then return false, "That RP name is already in use." end
	local state = DRP.IdentityCatalog.Normalize(request)
	local model = DRP.IdentityCatalog.Model(state.gender, state.outfit, state.head)
	if not model or not util.IsValidModel(model) then return false, "That character combination is unavailable on this server." end
	state.registered, state.name, state.updated_at = true, name, os.time()
	self.States[ply] = state
	local previous = ply:DRPName()
	ply.DRPRPNameValue = name
	self:ApplyAppearance(ply)
	ply:SetupHands()
	self:Save(ply)
	if DRP.Economy then DRP.Economy.QueueSave(ply) end
	if DRP.Roster then DRP.Roster:Update(ply, DRP.Roster.Field.RP_NAME) DRP.Roster:Update(ply, DRP.Roster.Field.JOB) end
	if DRP.Government then DRP.Government.Sync() end
	if DRP.Audit then DRP.Audit.Log(ply, "identity_registered", entity, previous .. " -> " .. name .. " | " .. model) end
	hook.Run("DRPGameplayEvent", ply, "identity_registered", 1)
	hook.Run("DRPIdentityRegistered", ply, state)
	return true, "Identity registered. Welcome, " .. name .. "."
end

DRP.Net.Receive(SUBMIT, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return sendResult(ply, false, "Your client files are out of date. Rejoin the server.") end
	if not DRP.Net.Allow(ply, "identity_submit", 1, 2) then return sendResult(ply, false, "Please wait before submitting again.") end
	local entity = Entity(net.ReadUInt(13))
	local request = {
		name = net.ReadString(), gender = net.ReadUInt(2), outfit = net.ReadUInt(2), head = net.ReadUInt(4), skin = net.ReadUInt(5),
		bodygroups = {}, uniforms = { police = { skin = 0, bodygroups = {} } }
	}
	local count = math.min(net.ReadUInt(4), 15)
	for _ = 1, count do request.bodygroups[net.ReadUInt(4)] = net.ReadUInt(5) end
	request.uniforms.police.skin = net.ReadUInt(5)
	local policeCount = math.min(net.ReadUInt(4), 15)
	for _ = 1, policeCount do request.uniforms.police.bodygroups[net.ReadUInt(4)] = net.ReadUInt(5) end
	local success, message = Identity:Register(ply, entity, request)
	sendResult(ply, success, message)
end)

hook.Add("PlayerDisconnected", "DRP.Identity.Disconnect", function(ply) Identity.States[ply] = nil end)
