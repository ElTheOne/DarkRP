local Arcade = {
	ConfigPath = "darkrp/arcade.json",
	Config = {},
	Games = {},
	GamesByID = {},
	Sessions = setmetatable({}, { __mode = "k" }),
	PlayerMachine = setmetatable({}, { __mode = "k" }),
	Watching = setmetatable({}, { __mode = "k" }),
	RelayWindowAt = 0,
	RelayBytes = 0
}

DRP.Arcade = Arcade
DRP.Services.Register("arcade", Arcade)

local message = DRP.ArcadeMessages
for _, name in pairs(message) do util.AddNetworkString(name) end
resource.AddWorkshop(DRP.ArcadeWorkshopID)

local function notify(ply, text, kind)
	if DRP.Net and DRP.Net.Notify then DRP.Net.Notify(ply, text, kind or 0) end
end

local function validMachine(entity)
	return IsValid(entity) and entity:GetClass() == "drp_arcade_cabinet"
end

local function validURL(value, allowHTTP)
	value = string.Trim(string.sub(tostring(value or ""), 1, 1024))
	if string.StartWith(string.lower(value), "https://") then return value end
	if allowHTTP and string.StartWith(string.lower(value), "http://") then return value end
	return nil
end

local function defaultConfig()
	return {
		version = 2,
		rom_base_url = "https://YOUR-ROM-HOST.example/arcade/roms/",
		player_page_url = "https://YOUR-ROM-HOST.example/arcade/player/",
		emulator_data_url = "https://cdn.emulatorjs.org/4.2.0/data/",
		allow_http = false,
		force_legacy_cores = true,
		stream = {
			fps = 1,
			width = 256,
			height = 192,
			jpeg_quality = 30,
			max_frame_bytes = 24576,
			max_viewers_per_machine = 8,
			max_active_streams = 4,
			max_relay_bytes_per_second = 262144
		},
		games = {
			{
				id = "example_megadrive",
				title = "Example Mega Drive Game",
				core = "megadrive",
				rom_file = "replace-this-with-your-rom.md",
				game_id = 1001,
				enabled = false
			}
		}
	}
end

local function streamValue(config, key, fallback, minimum, maximum)
	local stream = istable(config.stream) and config.stream or {}
	return math.Clamp(math.floor(tonumber(stream[key]) or fallback), minimum, maximum)
end

function Arcade:LoadConfig()
	file.CreateDir("darkrp")
	local raw = file.Read(self.ConfigPath, "DATA")
	if not raw or raw == "" then
		self.Config = defaultConfig()
		file.Write(self.ConfigPath, util.TableToJSON(self.Config, true))
		print("[DRP ARCADE] created data/" .. self.ConfigPath .. "; add HTTPS ROM entries and run drp_arcade_reload")
	else
		self.Config = util.JSONToTable(raw) or {}
	end

	local config = self.Config
	config.allow_http = config.allow_http == true
	config.emulator_data_url = validURL(config.emulator_data_url, config.allow_http)
		or "https://cdn.emulatorjs.org/4.2.0/data/"
	if string.sub(config.emulator_data_url, -1) ~= "/" then config.emulator_data_url = config.emulator_data_url .. "/" end
	config.rom_base_url = validURL(config.rom_base_url, config.allow_http) or ""
	if config.rom_base_url ~= "" and string.sub(config.rom_base_url, -1) ~= "/" then config.rom_base_url = config.rom_base_url .. "/" end
	config.player_page_url = validURL(config.player_page_url, config.allow_http) or ""
	config.force_legacy_cores = config.force_legacy_cores ~= false
	config.stream = {
		fps = streamValue(config, "fps", 1, 1, 3),
		width = streamValue(config, "width", 256, 128, 320),
		height = streamValue(config, "height", 192, 96, 240),
		jpeg_quality = streamValue(config, "jpeg_quality", 30, 10, 55),
		max_frame_bytes = streamValue(config, "max_frame_bytes", 24576, 4096, 49152),
		max_viewers_per_machine = streamValue(config, "max_viewers_per_machine", 8, 1, 16),
		max_active_streams = streamValue(config, "max_active_streams", 4, 1, 8),
		max_relay_bytes_per_second = streamValue(config, "max_relay_bytes_per_second", 262144, 65536, 1048576)
	}

	self.Games = {}
	self.GamesByID = {}
	for _, rawGame in ipairs(istable(config.games) and config.games or {}) do
		if rawGame.enabled ~= false then
			local id = string.lower(string.sub(tostring(rawGame.id or ""), 1, 48))
			id = string.gsub(id, "[^%w_%-]", "")
			local title = string.Trim(string.sub(tostring(rawGame.title or ""), 1, 80))
			local core = string.lower(string.sub(tostring(rawGame.core or "megadrive"), 1, 32))
			if core == "genesis" or core == "md" then core = "megadrive" end
			local romURL = validURL(rawGame.rom_url, config.allow_http)
			if not romURL and config.rom_base_url ~= "" then
				local filename = string.sub(tostring(rawGame.rom_file or ""), 1, 256)
				if filename ~= "" and not string.find(filename, "..", 1, true) and not string.find(filename, "\\", 1, true) then
					romURL = config.rom_base_url .. filename
				end
			end
			if id ~= "" and title ~= "" and core == "megadrive" and romURL and not self.GamesByID[id] then
				local configuredID = tonumber(rawGame.game_id)
				local gameID = configuredID and math.Clamp(math.floor(configuredID), 1, 2147483647)
					or ((math.floor(tonumber(util.CRC(id)) or 0) % 2147483646) + 1)
				local game = { id = id, title = title, core = core, rom_url = romURL, game_id = gameID }
				self.Games[#self.Games + 1] = game
				self.GamesByID[id] = game
			end
		end
	end
	table.sort(self.Games, function(a, b) return string.lower(a.title) < string.lower(b.title) end)
	print(string.format("[DRP ARCADE] loaded %d Mega Drive game(s); stream=%dfps %dx%d max=%dB",
		#self.Games, config.stream.fps, config.stream.width, config.stream.height, config.stream.max_frame_bytes))
end

function Arcade:Catalog()
	local games = {}
	for index, game in ipairs(self.Games) do games[index] = { id = game.id, title = game.title, core = game.core } end
	return games
end

function Arcade:SendOpen(ply, machine)
	if not IsValid(ply) then return end
	local payload = util.Compress(util.TableToJSON({ games = self:Catalog() }, false) or "{}") or ""
	if #payload > 65535 then
		notify(ply, "The arcade catalogue is too large.", 3)
		return
	end
	net.Start(message.OPEN)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteEntity(machine)
	net.WriteUInt(#payload, 16)
	if #payload > 0 then net.WriteData(payload, #payload) end
	net.Send(ply)
	if DRP.Net then DRP.Net.Record(#payload + 5) end
end

function Arcade:SendSession(ply, active, machine, game)
	if not IsValid(ply) then return end
	net.Start(message.SESSION)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(active == true)
	net.WriteEntity(machine or NULL)
	if active then
		net.WriteString(game.id)
		net.WriteString(game.title)
		net.WriteString(game.core)
		net.WriteString(game.rom_url)
		net.WriteUInt(game.game_id, 31)
		net.WriteString(self.Config.player_page_url)
		net.WriteString(self.Config.emulator_data_url)
		net.WriteBool(self.Config.force_legacy_cores)
	end
	net.Send(ply)
	if DRP.Net then DRP.Net.Record(active and (#game.title + #game.rom_url + #self.Config.player_page_url + #self.Config.emulator_data_url + 17) or 4) end
end

function Arcade:SendWatch(ply, active, machine, title)
	if not IsValid(ply) then return end
	net.Start(message.WATCH)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(active == true)
	net.WriteEntity(machine or NULL)
	if active then net.WriteString(string.sub(tostring(title or "Mega Drive"), 1, 80)) end
	net.Send(ply)
	if DRP.Net then DRP.Net.Record(active and (#tostring(title or "") + 5) or 4) end
end

function Arcade:SendStreamControl(session)
	local controller = session and session.controller
	if not IsValid(controller) then return end
	local enabled = table.Count(session.viewers) > 0
	net.Start(message.STREAM)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteBool(enabled)
	net.WriteEntity(session.machine)
	net.WriteUInt(self.Config.stream.fps, 3)
	net.WriteUInt(self.Config.stream.width, 9)
	net.WriteUInt(self.Config.stream.height, 9)
	net.WriteUInt(self.Config.stream.jpeg_quality, 7)
	net.WriteUInt(self.Config.stream.max_frame_bytes, 16)
	net.Send(controller)
	if DRP.Net then DRP.Net.Record(9) end
end

function Arcade:ActiveStreamCount()
	local count = 0
	for _, session in pairs(self.Sessions) do
		if table.Count(session.viewers) > 0 then count = count + 1 end
	end
	return count
end

function Arcade:RemoveViewer(ply, silent)
	local machine = self.Watching[ply]
	local session = validMachine(machine) and self.Sessions[machine] or nil
	self.Watching[ply] = nil
	if not session or not session.viewers[ply] then return false end
	session.viewers[ply] = nil
	if IsValid(machine) then machine:SetArcadeViewerCount(table.Count(session.viewers)) end
	if IsValid(ply) then self:SendWatch(ply, false, machine) end
	self:SendStreamControl(session)
	if not silent then notify(ply, "You stopped watching the arcade.", 0) end
	return true
end

function Arcade:AddViewer(ply, machine, session)
	if self.Watching[ply] == machine then
		self:RemoveViewer(ply)
		return
	end
	self:RemoveViewer(ply, true)
	if table.Count(session.viewers) >= self.Config.stream.max_viewers_per_machine then
		notify(ply, "That cabinet has reached its spectator limit.", 3)
		return
	end
	if table.Count(session.viewers) == 0 and self:ActiveStreamCount() >= self.Config.stream.max_active_streams then
		notify(ply, "The server spectator-stream budget is currently full.", 3)
		return
	end
	session.viewers[ply] = true
	self.Watching[ply] = machine
	machine:SetArcadeViewerCount(table.Count(session.viewers))
	self:SendWatch(ply, true, machine, session.game.title)
	self:SendStreamControl(session)
	notify(ply, "Watching " .. session.controller:DRPName() .. " play " .. session.game.title .. ". Press E again to stop.", 1)
end

function Arcade:Use(machine, ply)
	if not validMachine(machine) or not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() or not ply:DRPReady() then return end
	if ply:GetPos():DistToSqr(machine:GetPos()) > 262144 then return end
	if (ply.DRPArcadeNextUse or 0) > CurTime() then return end
	ply.DRPArcadeNextUse = CurTime() + 0.5
	local session = self.Sessions[machine]
	if session and IsValid(session.controller) then
		if session.controller == ply then
			notify(ply, "You are already using this cabinet.", 0)
			return
		end
		self:AddViewer(ply, machine, session)
		return
	end
	if self.PlayerMachine[ply] then
		notify(ply, "Exit your current arcade session first.", 3)
		return
	end
	if #self.Games == 0 then
		notify(ply, "No arcade ROMs are configured. The owner must edit data/darkrp/arcade.json.", 3)
		return
	end
	self:SendOpen(ply, machine)
end

function Arcade:StartSession(ply, machine, gameID)
	if not validMachine(machine) or not IsValid(ply) or not ply:Alive() or not ply:DRPReady() then return false end
	if ply:GetPos():DistToSqr(machine:GetPos()) > 262144 or self.Sessions[machine] or self.PlayerMachine[ply] then return false end
	local game = self.GamesByID[tostring(gameID or "")]
	if not game then return false end
	self:RemoveViewer(ply, true)
	local session = {
		machine = machine,
		controller = ply,
		game = game,
		viewers = setmetatable({}, { __mode = "k" }),
		lastFrameAt = 0,
		lastSequence = nil,
		startedAt = CurTime()
	}
	self.Sessions[machine] = session
	if not timer.Exists("DRP.Arcade.Maintain") then
		timer.Create("DRP.Arcade.Maintain", 1, 0, function() self:Maintain() end)
	end
	self.PlayerMachine[ply] = machine
	ply.DRPArcadeMachine = machine
	machine:SetArcadeController(ply)
	machine:SetArcadeGameTitle(game.title)
	machine:SetArcadeViewerCount(0)
	self:SendSession(ply, true, machine, game)
	notify(ply, "Starting " .. game.title .. ". Saves remain on this client.", 1)
	if DRP.Audit then DRP.Audit.Log(ply, "arcade_session_started", machine, game.id) end
	return true
end

function Arcade:EndSession(machine, reason)
	local session = self.Sessions[machine]
	if not session then return false end
	self.Sessions[machine] = nil
	local controller = session.controller
	if IsValid(controller) then
		self.PlayerMachine[controller] = nil
		controller.DRPArcadeMachine = nil
		self:SendSession(controller, false, machine)
		if reason and reason ~= "" then notify(controller, reason, 0) end
	end
	for viewer in pairs(session.viewers) do
		if IsValid(viewer) then
			self.Watching[viewer] = nil
			self:SendWatch(viewer, false, machine)
			if reason and reason ~= "" then notify(viewer, reason, 0) end
		end
	end
	if validMachine(machine) then
		machine:SetArcadeController(NULL)
		machine:SetArcadeGameTitle("")
		machine:SetArcadeViewerCount(0)
	end
	if table.IsEmpty(self.Sessions) then timer.Remove("DRP.Arcade.Maintain") end
	if IsValid(controller) and DRP.Audit then DRP.Audit.Log(controller, "arcade_session_ended", machine, session.game.id) end
	return true
end

function Arcade:RemoveMachine(machine)
	self:EndSession(machine, "The arcade cabinet was removed.")
end

function Arcade:RelayFrame(ply, machine, sequence, data)
	local session = validMachine(machine) and self.Sessions[machine] or nil
	if not session or session.controller ~= ply or table.Count(session.viewers) == 0 then return end
	local stream = self.Config.stream
	if #data < 64 or #data > stream.max_frame_bytes then return end
	if string.byte(data, 1) ~= 255 or string.byte(data, 2) ~= 216 then return end
	local now = CurTime()
	if now - session.lastFrameAt < (1 / stream.fps) * 0.8 then return end
	if session.lastSequence ~= nil and sequence == session.lastSequence then return end
	session.lastFrameAt = now
	session.lastSequence = sequence
	local recipients = {}
	for viewer in pairs(session.viewers) do
		if IsValid(viewer) and viewer:GetPos():DistToSqr(machine:GetPos()) <= 1048576 then
			recipients[#recipients + 1] = viewer
		else
			self:RemoveViewer(viewer, true)
		end
	end
	if #recipients == 0 then return end
	if now - self.RelayWindowAt >= 1 then
		self.RelayWindowAt = now
		self.RelayBytes = 0
	end
	local relayCost = #data * #recipients
	if self.RelayBytes + relayCost > stream.max_relay_bytes_per_second then return end
	self.RelayBytes = self.RelayBytes + relayCost
	net.Start(message.FRAME)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteEntity(machine)
	net.WriteUInt(sequence, 16)
	net.WriteUInt(#data, 16)
	net.WriteData(data, #data)
	net.Send(recipients)
	if DRP.Net then DRP.Net.Record(#data + 7, #recipients) end
end

function Arcade:Maintain()
	local started = DRP.Profile and DRP.Profile.Begin and DRP.Profile.Begin() or nil
	for machine, session in pairs(self.Sessions) do
		local controller = session.controller
		if not validMachine(machine) or not IsValid(controller) or not controller:Alive()
			or controller:GetPos():DistToSqr(machine:GetPos()) > 1048576 then
			self:EndSession(machine, "Arcade session ended.")
		else
			for viewer in pairs(session.viewers) do
				if not IsValid(viewer) or not viewer:Alive() or viewer:GetPos():DistToSqr(machine:GetPos()) > 1048576 then
					self:RemoveViewer(viewer, true)
				end
			end
		end
	end
	if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("arcade.maintain", started) end
end

function Arcade:ApplyCommand(ply, command)
	if not IsValid(ply.DRPArcadeMachine) then return end
	command:ClearMovement()
	command:ClearButtons()
end

function Arcade:ApplyMove(ply, move)
	if not IsValid(ply.DRPArcadeMachine) then return end
	move:SetForwardSpeed(0)
	move:SetSideSpeed(0)
	move:SetUpSpeed(0)
	move:SetMaxSpeed(0)
	move:SetMaxClientSpeed(0)
end

function Arcade:Status()
	local sessions, viewers = 0, 0
	for _, session in pairs(self.Sessions) do sessions = sessions + 1 viewers = viewers + table.Count(session.viewers) end
	return string.format("games=%d sessions=%d viewers=%d model=%s config=data/%s",
		#self.Games, sessions, viewers, util.IsValidModel(DRP.ArcadeCabinetModel) and "mounted" or "fallback", self.ConfigPath)
end

function Arcade:Start()
	self:LoadConfig()
	if util.IsValidModel(DRP.ArcadeCabinetModel) then
		util.PrecacheModel(DRP.ArcadeCabinetModel)
	else
		util.PrecacheModel(DRP.ArcadeFallbackModel)
		ErrorNoHalt("[DRP ARCADE] Workshop " .. DRP.ArcadeWorkshopID .. " is not mounted server-side; using the fallback cabinet model.\n")
	end
end

function Arcade:Stop()
	timer.Remove("DRP.Arcade.Maintain")
	for machine in pairs(self.Sessions) do self:EndSession(machine, "Server shutting down.") end
end

DRP.Net.Receive(message.START, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "arcade_start", 0.75, 2) then return end
	Arcade:StartSession(ply, net.ReadEntity(), string.sub(net.ReadString(), 1, 48))
end)

DRP.Net.Receive(message.EXIT, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "arcade_exit", 0.25, 3) then return end
	local machine = net.ReadEntity()
	if Arcade.PlayerMachine[ply] == machine then
		Arcade:EndSession(machine, "Arcade session closed.")
	elseif Arcade.Watching[ply] == machine then
		Arcade:RemoveViewer(ply)
	end
end)

DRP.Net.Receive(message.FRAME, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not DRP.Net.Allow(ply, "arcade_frame", 0.25, 4) then return end
	local machine = net.ReadEntity()
	local sequence = net.ReadUInt(16)
	local length = net.ReadUInt(16)
	local maximum = Arcade.Config.stream and Arcade.Config.stream.max_frame_bytes or 24576
	if length < 64 or length > maximum or length > net.BytesLeft() then return end
	Arcade:RelayFrame(ply, machine, sequence, net.ReadData(length) or "")
end)

hook.Add("PlayerDisconnected", "DRP.Arcade.Disconnect", function(ply)
	local machine = Arcade.PlayerMachine[ply]
	if validMachine(machine) then Arcade:EndSession(machine, "The player left the server.") end
	Arcade:RemoveViewer(ply, true)
end)

hook.Add("PlayerDeath", "DRP.Arcade.Death", function(ply)
	local machine = Arcade.PlayerMachine[ply]
	if validMachine(machine) then Arcade:EndSession(machine, "Arcade session ended on death.") end
	Arcade:RemoveViewer(ply, true)
end)

concommand.Add("drp_arcade_reload", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	Arcade:LoadConfig()
	if IsValid(ply) then notify(ply, "Arcade catalogue reloaded: " .. #Arcade.Games .. " game(s).", 1) end
end)

concommand.Add("drp_arcade_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.Has(ply, "server_interaction")) then return end
	local status = "[DRP ARCADE] " .. Arcade:Status()
	print(status)
	if IsValid(ply) then notify(ply, status, 0) end
end)
