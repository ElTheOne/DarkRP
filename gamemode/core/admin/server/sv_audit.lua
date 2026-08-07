local Audit = {
	Capacity = 2048,
	FlushBatchSize = 256,
	Entries = {},
	Count = 0,
	Cursor = 0,
	NextID = 1,
	WriteQueue = {},
	ReceiptQueue = {},
	UseThrottle = setmetatable({}, { __mode = "k" }),
	ToolThrottle = setmetatable({}, { __mode = "k" })
}

DRP.Audit = Audit
DRP.Services.Register("audit", Audit)

local requestMessage = "drp_audit_request_v1"
local snapshotMessage = "drp_audit_snapshot_v1"
util.AddNetworkString(requestMessage)
util.AddNetworkString(snapshotMessage)

local function identity(value)
	if IsValid(value) and value:IsPlayer() then
		return value:SteamID64(), string.sub(value:Nick(), 1, 64)
	end
	if IsValid(value) then
		local class = string.sub(value:GetClass(), 1, 48)
		return class .. "#" .. value:EntIndex(), class
	end
	if isstring(value) then return string.sub(value, 1, 32), string.sub(value, 1, 64) end
	return "SERVER", "Server"
end

function Audit:Flush()
	if #self.WriteQueue == 0 and #self.ReceiptQueue == 0 then return end
	local started = DRP.Profile.Begin()
	file.CreateDir("darkrp")
	file.CreateDir("darkrp/logs")
	-- GMod's DATA realm only permits a fixed extension allowlist. Keep the
	-- append-friendly JSON-lines format under an allowed .txt suffix.
	local date = os.date("%Y-%m-%d")
	if #self.WriteQueue > 0 then
		local path = "darkrp/logs/" .. date .. ".jsonl.txt"
		local payload = table.concat(self.WriteQueue)
		if file.Exists(path, "DATA") then file.Append(path, payload) else file.Write(path, payload) end
	end
	if #self.ReceiptQueue > 0 then
		local path = "darkrp/logs/incidents-" .. date .. ".jsonl.txt"
		local payload = table.concat(self.ReceiptQueue)
		if file.Exists(path, "DATA") then file.Append(path, payload) else file.Write(path, payload) end
	end
	self.WriteQueue = {}
	self.ReceiptQueue = {}
	DRP.Profile.Finish("audit.flush", started)
end

function Audit:Start()
	self.Log(nil, "server_start", nil, game.GetMap())
end

function Audit:Stop()
	self.Log(nil, "server_stop", nil, game.GetMap())
	self:Flush()
end

function Audit.Log(suspect, eventType, victim, details)
	local suspectID, suspectName = identity(suspect)
	local victimID, victimName = identity(victim)
	if victim == nil then victimID, victimName = "", "" end
	local entry = {
		id = Audit.NextID,
		time = os.time(),
		suspect_id = suspectID,
		suspect = suspectName,
		event_type = string.sub(tostring(eventType or "unknown"), 1, 40),
		victim_id = victimID,
		victim = victimName,
		details = string.sub(tostring(details or ""), 1, 192)
	}
	Audit.NextID = Audit.NextID + 1
	Audit.Cursor = (Audit.Cursor % Audit.Capacity) + 1
	Audit.Entries[Audit.Cursor] = entry
	Audit.Count = math.min(Audit.Count + 1, Audit.Capacity)
	Audit.WriteQueue[#Audit.WriteQueue + 1] = util.TableToJSON(entry) .. "\n"
	if #Audit.WriteQueue + #Audit.ReceiptQueue >= Audit.FlushBatchSize then Audit:Flush() end
	hook.Run("DRPGameplayEvent", suspect, entry.event_type, victim, entry.details, entry)
end

-- Incident receipts retain the complete participant, permission and evidence
-- snapshot. They are separate from the compact live log used by the UI.
function Audit.Receipt(receipt)
	if not istable(receipt) then return false end
	local payload = util.TableToJSON(receipt)
	if not payload then return false end
	Audit.ReceiptQueue[#Audit.ReceiptQueue + 1] = payload .. "\n"
	if #Audit.WriteQueue + #Audit.ReceiptQueue >= Audit.FlushBatchSize then Audit:Flush() end
	return true
end

function Audit.Latest(limit)
	local entries = {}
	limit = math.min(math.max(math.floor(limit or 100), 1), 100, Audit.Count)
	for offset = 0, limit - 1 do
		local index = ((Audit.Cursor - offset - 1) % Audit.Capacity) + 1
		entries[#entries + 1] = Audit.Entries[index]
	end
	return entries
end

DRP.Net.Receive(requestMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "audit_panel", 1, 2) then return end
	if not DRP.Admin or not DRP.Admin.Has(ply, "logs") then return end
	Audit.Log(ply, "audit_panel_open")
	local entries = Audit.Latest(100)
	net.Start(snapshotMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(#entries, 7)
	for _, entry in ipairs(entries) do
		net.WriteUInt(entry.id % 4294967296, 32)
		net.WriteUInt(entry.time, 32)
		net.WriteString(entry.suspect_id)
		net.WriteString(entry.suspect)
		net.WriteString(entry.event_type)
		net.WriteString(entry.victim_id)
		net.WriteString(entry.victim)
		net.WriteString(entry.details)
	end
	net.Send(ply)
end)

hook.Add("PlayerInitialSpawn", "DRP.Audit.Join", function(ply) Audit.Log(ply, "player_join") end)
hook.Add("PlayerDisconnected", "DRP.Audit.Leave", function(ply) Audit.Log(ply, "player_leave") end)
hook.Add("PlayerSpawn", "DRP.Audit.Spawn", function(ply) Audit.Log(ply, "player_spawn") end)
hook.Add("PlayerDeath", "DRP.Audit.Death", function(victim, inflictor, attacker)
	Audit.Log(IsValid(attacker) and attacker or nil, "player_death", victim, IsValid(inflictor) and inflictor:GetClass() or "")
end)
hook.Add("PlayerSay", "DRP.Audit.Chat", function(ply, text)
	-- Ordinary chat is audited by the category-aware chat service. Commands
	-- still pass through PlayerSay and are recorded here.
	if string.StartWith(text, "/") then Audit.Log(ply, "command", nil, text) end
end)
hook.Add("PlayerSpawnedProp", "DRP.Audit.Prop", function(ply, model, entity) Audit.Log(ply, "spawn_prop", entity, model) end)
hook.Add("PlayerSpawnedSENT", "DRP.Audit.SENT", function(ply, entity) Audit.Log(ply, "spawn_sent", entity, entity:GetClass()) end)
hook.Add("PlayerSpawnedVehicle", "DRP.Audit.Vehicle", function(ply, entity) Audit.Log(ply, "spawn_vehicle", entity, entity:GetClass()) end)
hook.Add("PlayerSpawnedNPC", "DRP.Audit.NPC", function(ply, entity) Audit.Log(ply, "spawn_npc", entity, entity:GetClass()) end)
hook.Add("PlayerPickupWeapon", "DRP.Audit.Weapon", function(ply, weapon) Audit.Log(ply, "pickup_weapon", weapon, weapon:GetClass()) end)
hook.Add("CanTool", "DRP.Audit.Tool", function(ply, trace, tool)
	local entity = IsValid(trace.Entity) and trace.Entity or game.GetWorld()
	local perPlayer = Audit.ToolThrottle[ply]
	if not perPlayer then perPlayer = setmetatable({}, { __mode = "k" }) Audit.ToolThrottle[ply] = perPlayer end
	local perEntity = perPlayer[entity]
	if not perEntity then perEntity = {} perPlayer[entity] = perEntity end
	local now = CurTime()
	if (perEntity[tool] or 0) > now then return end
	perEntity[tool] = now + 0.75
	Audit.Log(ply, "tool_use", IsValid(trace.Entity) and trace.Entity or nil, tool)
end)
hook.Add("PlayerUse", "DRP.Audit.Use", function(ply, entity)
	if not IsValid(entity) then return end
	if DRP.Doors and DRP.Doors.IsDoor and DRP.Doors.IsDoor(entity) then return end
	if entity.DRPMoneyDrop then return end
	local byEntity = Audit.UseThrottle[ply]
	if not byEntity then
		byEntity = setmetatable({}, { __mode = "k" })
		Audit.UseThrottle[ply] = byEntity
	end
	local now = CurTime()
	if (byEntity[entity] or 0) > now then return end
	byEntity[entity] = now + 0.75
	Audit.Log(ply, "use", entity, entity:GetClass())
end)
