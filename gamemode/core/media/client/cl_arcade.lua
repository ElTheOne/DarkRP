local Arcade = {
	Active = nil,
	Watching = nil,
	RemotePanels = setmetatable({}, { __mode = "k" }),
	MaterialCache = setmetatable({}, { __mode = "k" }),
	Capture = {
		enabled = false,
		nextAt = 0,
		sequence = 0,
		fps = 1,
		width = 256,
		height = 192,
		quality = 30,
		maxBytes = 24576
	}
}

DRP.ArcadeClient = Arcade
local message = DRP.ArcadeMessages

local function jsonString(value)
	local encoded = util.TableToJSON({ tostring(value or "") }, false) or "[\"\"]"
	return string.sub(encoded, 2, -2)
end

local function escapeHTML(value)
	value = tostring(value or "")
	value = string.Replace(value, "&", "&amp;")
	value = string.Replace(value, "<", "&lt;")
	value = string.Replace(value, ">", "&gt;")
	value = string.Replace(value, '"', "&quot;")
	return value
end

local function urlEncode(value)
	local encoded = string.gsub(tostring(value or ""), "([^%w%-_%.~])", function(character)
		return string.format("%%%02X", string.byte(character))
	end)
	return encoded
end

local function emulatorHTML(game)
	local dataURL = tostring(game.dataURL or "https://cdn.emulatorjs.org/4.2.0/data/")
	if string.sub(dataURL, -1) ~= "/" then dataURL = dataURL .. "/" end
	return [[<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body,#game{width:100%;height:100%;margin:0;overflow:hidden;background:#050914}
body{font-family:Arial,sans-serif;color:#fff}
#boot{position:fixed;z-index:20;left:18px;top:16px;padding:10px 14px;border-left:4px solid #45d8ff;
background:rgba(5,12,28,.92);letter-spacing:.08em;font-size:12px;text-transform:uppercase}
</style>
</head>
<body>
<div id="boot">Loading ]] .. escapeHTML(game.title) .. [[ — click the screen if emulation pauses</div>
<div id="game"></div>
<script>
window.EJS_player = "#game";
window.EJS_core = ]] .. jsonString(game.core) .. [[;
window.EJS_gameUrl = ]] .. jsonString(game.romURL) .. [[;
window.EJS_gameName = ]] .. jsonString(game.title) .. [[;
window.EJS_gameID = ]] .. tostring(math.max(1, math.floor(tonumber(game.gameID) or 1))) .. [[;
window.EJS_pathtodata = ]] .. jsonString(dataURL) .. [[;
window.EJS_startOnLoaded = true;
window.EJS_forceLegacyCores = ]] .. (game.forceLegacy and "true" or "false") .. [[;
window.EJS_threads = false;
window.EJS_fixedSaveInterval = 60000;
window.EJS_CacheLimit = 268435456;
window.EJS_Buttons = {fullscreen:false,screenRecord:false,cacheManager:false};
window.EJS_ready = function(){var boot=document.getElementById("boot");if(boot)boot.remove();};
window.EJS_onGameStart = window.EJS_ready;
</script>
<script src=]] .. jsonString(dataURL .. "loader.js") .. [[></script>
</body>
</html>]]
end

local function spectatorHTML(title)
	return [[<!doctype html><html><head><meta charset="utf-8"><style>
html,body{width:100%;height:100%;margin:0;overflow:hidden;background:#050914}
img{width:100%;height:100%;object-fit:fill;image-rendering:auto}
#status{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:#50d9ff;
font:700 12px Arial;letter-spacing:.08em;text-transform:uppercase;background:linear-gradient(135deg,#081226,#050914)}
</style></head><body><div id="status">Waiting for ]] .. escapeHTML(title) .. [[ stream…</div><img id="frame">
<script>window.drpSetFrame=function(src){var i=document.getElementById("frame");i.src=src;
var s=document.getElementById("status");if(s)s.style.display="none";};</script></body></html>]]
end

local function panelMaterial(panel)
	if not IsValid(panel) then return nil end
	local htmlMaterial = panel:GetHTMLMaterial()
	if not htmlMaterial or htmlMaterial:IsError() then return nil end
	local sourceName = htmlMaterial:GetName()
	local cached = Arcade.MaterialCache[panel]
	if cached and cached.source == sourceName and cached.material and not cached.material:IsError() then return cached.material end
	local uid = string.gsub(sourceName, "[^%w_]", "")
	local material = CreateMaterial("drp_arcade_" .. uid, "UnlitGeneric", {
		["$basetexture"] = sourceName,
		["$model"] = "1",
		["$vertexcolor"] = "1",
		["$vertexalpha"] = "1"
	})
	Arcade.MaterialCache[panel] = { source = sourceName, material = material }
	return material
end

function Arcade:SendExit(machine)
	if not IsValid(machine) then return end
	net.Start(message.EXIT)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteEntity(machine)
	net.SendToServer()
end

function Arcade:CloseActive(serverInitiated)
	local active = self.Active
	if not active then return end
	self.Active = nil
	self.Capture.enabled = false
	if IsValid(active.frame) then
		active.frame.DRPServerClosing = serverInitiated == true
		active.frame:Remove()
	elseif not serverInitiated then
		self:SendExit(active.machine)
	end
end

function Arcade:CloseWatcher(serverInitiated)
	local watching = self.Watching
	if not watching then return end
	self.Watching = nil
	if not serverInitiated then self:SendExit(watching) end
	local panel = self.RemotePanels[watching]
	if IsValid(panel) then panel:Remove() end
	self.RemotePanels[watching] = nil
end

function Arcade:OpenGame(machine, game)
	self:CloseActive(true)
	local frame = vgui.Create("DFrame")
	frame:SetSize(math.floor(ScrW() * 0.9), math.floor(ScrH() * 0.9))
	frame:Center()
	frame:SetTitle("")
	frame:ShowCloseButton(true)
	frame:SetDraggable(false)
	frame:MakePopup()
	frame.Paint = function(_, width, height)
		draw.RoundedBox(10, 0, 0, width, height, Color(5, 10, 23, 252))
		draw.RoundedBoxEx(10, 0, 0, width, 42, Color(12, 27, 52, 255), true, true, false, false)
		draw.RoundedBox(0, 0, 40, width, 2, Color(67, 215, 255))
		draw.SimpleText("MEGA DRIVE ARCADE  /  " .. game.title, "DRP.Admin.Header", 16, 21, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("SAVES STAY ON THIS CLIENT", "DRP.Admin.Small", width - 52, 21, Color(94, 225, 177), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end

	local html = vgui.Create("DHTML", frame)
	html:Dock(FILL)
	html:DockMargin(10, 48, 10, 10)
	html:SetAllowLua(false)
	local externalURL
	if string.StartWith(string.lower(game.pageURL or ""), "https://") or string.StartWith(string.lower(game.pageURL or ""), "http://") then
		local separator = string.find(game.pageURL, "?", 1, true) and "&" or "?"
		local query = table.concat({
			"rom=" .. urlEncode(game.romURL),
			"title=" .. urlEncode(game.title),
			"core=" .. urlEncode(game.core),
			"id=" .. tostring(math.max(1, math.floor(tonumber(game.gameID) or 1))),
			"data=" .. urlEncode(game.dataURL),
			"legacy=" .. (game.forceLegacy and "1" or "0")
		}, "&")
		externalURL = game.pageURL .. separator .. query
		html:OpenURL(externalURL)
	else
		html:SetHTML(emulatorHTML(game))
	end
	function html:OnDocumentReady()
		self:AddFunction("drpArcade", "openExternal", function(requestedURL)
			local target = tostring(requestedURL or "")
			if target ~= externalURL or not string.StartWith(string.lower(target), "https://") then return end
			gui.OpenURL(target)
		end)
	end
	function html:ConsoleMessage(text)
		text = string.sub(tostring(text or ""), 1, 300)
		local lowered = string.lower(text)
		local compatibilityFallback = string.find(lowered, "drp arcade compatibility fallback", 1, true) ~= nil
		if compatibilityFallback and externalURL and not self.DRPExternalOpened then
			self.DRPExternalOpened = true

			local overlay = vgui.Create("DPanel", frame)
			overlay:SetPos(10, 48)
			overlay:SetSize(frame:GetWide() - 20, frame:GetTall() - 58)
			overlay:SetZPos(1000)
			overlay.Paint = function(_, width, height)
				draw.RoundedBox(8, 0, 0, width, height, Color(5, 9, 20, 255))
				draw.SimpleText("BROWSER COMPATIBILITY REQUIRED", "DRP.Admin.Header", width * 0.5, height * 0.5 - 52, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				draw.SimpleText("Garry's Mod cannot provide WebGL on this Mac.", "DRP.Admin.Body", width * 0.5, height * 0.5 - 18, Color(169, 186, 211), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				draw.SimpleText("The game link is copied — paste it into Safari or Chrome.", "DRP.Admin.Body", width * 0.5, height * 0.5 + 6, Color(94, 225, 177), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end

			local copyButton = vgui.Create("DButton", overlay)
			copyButton:SetSize(230, 42)
			copyButton:SetPos(overlay:GetWide() * 0.5 - 238, overlay:GetTall() * 0.5 + 38)
			copyButton:SetText("COPY BROWSER LINK")
			copyButton.DoClick = function()
				SetClipboardText(externalURL)
				copyButton:SetText("LINK COPIED")
			end

			local steamButton = vgui.Create("DButton", overlay)
			steamButton:SetSize(230, 42)
			steamButton:SetPos(overlay:GetWide() * 0.5 + 8, overlay:GetTall() * 0.5 + 38)
			steamButton:SetText("TRY STEAM BROWSER")
			steamButton.DoClick = function()
				gui.OpenURL(externalURL)
			end

			SetClipboardText(externalURL)
		end
		if compatibilityFallback or string.find(lowered, "error", 1, true) then
			ErrorNoHalt("[DRP ARCADE HTML] " .. text .. "\n")
		end
	end

	self.Active = { machine = machine, game = game, frame = frame, html = html }
	frame.OnRemove = function(panel)
		if self.Active and self.Active.frame == panel then
			self.Active = nil
			self.Capture.enabled = false
			if not panel.DRPServerClosing then self:SendExit(machine) end
		end
	end
end

function Arcade:OpenSelector(machine, catalog)
	if not IsValid(machine) then return end
	local frame = vgui.Create("DFrame")
	frame:SetSize(math.min(620, ScrW() - 80), math.min(620, ScrH() - 80))
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()
	frame.Paint = function(_, width, height)
		draw.RoundedBox(10, 0, 0, width, height, Color(7, 13, 28, 250))
		draw.RoundedBoxEx(10, 0, 0, width, 64, Color(13, 31, 59), true, true, false, false)
		draw.RoundedBox(0, 0, 62, width, 2, Color(67, 215, 255))
		draw.SimpleText("MEGA DRIVE ARCADE", "DRP.Admin.Header", 20, 22, color_white)
		draw.SimpleText("Select a server-hosted ROM", "DRP.Admin.Small", 20, 45, Color(140, 165, 202))
	end

	local scroll = vgui.Create("DScrollPanel", frame)
	scroll:Dock(FILL)
	scroll:DockMargin(14, 72, 14, 14)
	for _, game in ipairs(catalog.games or {}) do
		local id, title = tostring(game.id or ""), tostring(game.title or "Mega Drive Game")
		local button = scroll:Add("DButton")
		button:Dock(TOP)
		button:DockMargin(0, 0, 0, 8)
		button:SetTall(58)
		button:SetText("")
		button.Paint = function(panel, width, height)
			local hovered = panel:IsHovered()
			draw.RoundedBox(7, 0, 0, width, height, hovered and Color(24, 57, 90) or Color(13, 25, 47))
			draw.RoundedBox(7, 0, 0, 5, height, hovered and Color(94, 225, 177) or Color(67, 215, 255))
			draw.SimpleText(title, "DRP.Admin.Body", 18, 18, color_white)
			draw.SimpleText("SEGA MEGA DRIVE  •  SOFTWARE EMULATION", "DRP.Admin.Small", 18, 39, Color(130, 157, 195))
			draw.SimpleText("PLAY", "DRP.Admin.Small", width - 18, height * 0.5, hovered and Color(94, 225, 177) or Color(67, 215, 255), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
		button.DoClick = function()
			if not IsValid(machine) then frame:Remove() return end
			net.Start(message.START)
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.WriteEntity(machine)
			net.WriteString(id)
			net.SendToServer()
			frame:Remove()
		end
	end
end

function Arcade:EnsureRemotePanel(machine, title)
	local existing = self.RemotePanels[machine]
	if IsValid(existing) then return existing end
	local panel = vgui.Create("DHTML")
	panel:SetSize(256, 192)
	panel:SetPos(-512, -512)
	panel:SetAlpha(0)
	panel:SetMouseInputEnabled(false)
	panel:SetKeyboardInputEnabled(false)
	panel:SetAllowLua(false)
	panel:SetHTML(spectatorHTML(title))
	function panel:ConsoleMessage() end
	self.RemotePanels[machine] = panel
	return panel
end

function Arcade:MachineMaterial(machine)
	if self.Active and self.Active.machine == machine then return panelMaterial(self.Active.html) end
	if self.Watching == machine then return panelMaterial(self.RemotePanels[machine]) end
	return nil
end

function Arcade:VisualBody(machine)
	if string.lower(tostring(machine:GetModel() or "")) == string.lower(DRP.ArcadeCabinetModel) then
		if IsValid(machine.DRPArcadeVisualBody) then machine.DRPArcadeVisualBody:Remove() end
		machine.DRPArcadeVisualBody = nil
		machine.DRPArcadeVisualTop = machine:OBBMaxs().z
		return machine
	end
	if not util.IsValidModel(DRP.ArcadeCabinetModel) then return machine end
	local body = machine.DRPArcadeVisualBody
	if not IsValid(body) then
		body = ClientsideModel(DRP.ArcadeCabinetModel, RENDERGROUP_OPAQUE)
		if not IsValid(body) then return machine end
		body:SetNoDraw(true)
		body:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
		body:DrawShadow(true)
		machine.DRPArcadeVisualBody = body
		local mins, maxs = body:GetRenderBounds()
		machine.DRPArcadeVisualMins = mins
		machine.DRPArcadeVisualMaxs = maxs
	end
	local mins = machine.DRPArcadeVisualMins or Vector()
	local maxs = machine.DRPArcadeVisualMaxs or Vector(0, 0, machine:OBBMaxs().z)
	local offset = Vector(0, 0, machine:OBBMins().z - mins.z)
	body:SetPos(machine:LocalToWorld(offset))
	body:SetAngles(machine:GetAngles())
	body:SetupBones()
	machine.DRPArcadeVisualTop = offset.z + maxs.z
	return body
end

function Arcade:DrawMachine(machine)
	local body = self:VisualBody(machine)
	local material = self:MachineMaterial(machine)
	if material and IsValid(body) and string.lower(tostring(body:GetModel() or "")) == string.lower(DRP.ArcadeCabinetModel) then
		render.MaterialOverrideByIndex(1, material)
	end
	if IsValid(body) then body:DrawModel() else machine:DrawModel() end
	render.MaterialOverrideByIndex()

	if EyePos():DistToSqr(machine:GetPos()) > 524288 then return end
	local controller = machine:GetArcadeController()
	local title = machine:GetArcadeGameTitle()
	local detail
	if IsValid(controller) then
		detail = controller:Nick() .. " playing" .. (machine:GetArcadeViewerCount() > 0 and ("  •  " .. machine:GetArcadeViewerCount() .. " watching") or "")
	else
		title = "MEGA DRIVE ARCADE"
		detail = "Press E to choose a game"
	end
	local angle = Angle(0, EyeAngles().y - 90, 90)
	cam.Start3D2D(machine:GetPos() + Vector(0, 0, (machine.DRPArcadeVisualTop or machine:OBBMaxs().z) + 11), angle, 0.075)
		draw.RoundedBox(7, -150, -30, 300, 60, Color(5, 10, 23, 235))
		draw.RoundedBox(7, -150, -30, 5, 60, Color(67, 215, 255))
		draw.SimpleText(title ~= "" and title or "MEGA DRIVE ARCADE", "DRP.Admin.Body", 0, -11, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText(detail, "DRP.Admin.Small", 0, 12, Color(94, 225, 177), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	cam.End3D2D()
end

function Arcade:RemoveMachine(machine)
	if self.Active and self.Active.machine == machine then self:CloseActive(true) end
	if self.Watching == machine then self:CloseWatcher(true) end
	local panel = self.RemotePanels[machine]
	if IsValid(panel) then panel:Remove() end
	self.RemotePanels[machine] = nil
	if IsValid(machine.DRPArcadeVisualBody) then machine.DRPArcadeVisualBody:Remove() end
	machine.DRPArcadeVisualBody = nil
end

net.Receive(message.OPEN, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local machine = net.ReadEntity()
	local length = net.ReadUInt(16)
	local raw = length > 0 and net.ReadData(length) or ""
	local decoded = util.JSONToTable(util.Decompress(raw or "") or "")
	if not IsValid(machine) or not istable(decoded) then return end
	Arcade:OpenSelector(machine, decoded)
end)

net.Receive(message.SESSION, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local active = net.ReadBool()
	local machine = net.ReadEntity()
	if not active then Arcade:CloseActive(true) return end
	local game = {
		id = net.ReadString(),
		title = net.ReadString(),
		core = net.ReadString(),
		romURL = net.ReadString(),
		gameID = net.ReadUInt(31),
		pageURL = net.ReadString(),
		dataURL = net.ReadString(),
		forceLegacy = net.ReadBool()
	}
	if not IsValid(machine) then return end
	Arcade:OpenGame(machine, game)
end)

net.Receive(message.WATCH, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local active = net.ReadBool()
	local machine = net.ReadEntity()
	if not active then Arcade:CloseWatcher(true) return end
	local title = net.ReadString()
	Arcade:CloseWatcher(true)
	Arcade.Watching = machine
	Arcade:EnsureRemotePanel(machine, title)
end)

net.Receive(message.STREAM, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local capture = Arcade.Capture
	capture.enabled = net.ReadBool()
	local machine = net.ReadEntity()
	capture.fps = math.Clamp(net.ReadUInt(3), 1, 3)
	capture.width = math.Clamp(net.ReadUInt(9), 128, 320)
	capture.height = math.Clamp(net.ReadUInt(9), 96, 240)
	capture.quality = math.Clamp(net.ReadUInt(7), 10, 55)
	capture.maxBytes = math.Clamp(net.ReadUInt(16), 4096, 49152)
	capture.nextAt = 0
	if not Arcade.Active or Arcade.Active.machine ~= machine then capture.enabled = false end
end)

net.Receive(message.FRAME, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local machine = net.ReadEntity()
	net.ReadUInt(16)
	local length = net.ReadUInt(16)
	if not IsValid(machine) or Arcade.Watching ~= machine or length < 64 or length > 49152 then return end
	local data = net.ReadData(length)
	if not data or #data ~= length then return end
	local panel = Arcade:EnsureRemotePanel(machine, machine:GetArcadeGameTitle())
	if not IsValid(panel) then return end
	panel:Call("window.drpSetFrame(" .. jsonString("data:image/jpeg;base64," .. util.Base64Encode(data)) .. ");")
end)

hook.Add("PostRender", "DRP.Arcade.Capture", function()
	local capture, active = Arcade.Capture, Arcade.Active
	if not capture.enabled or not active or not IsValid(active.machine) or not IsValid(active.html) then return end
	if RealTime() < capture.nextAt then return end
	local material = panelMaterial(active.html)
	if not material then return end
	capture.nextAt = RealTime() + (1 / capture.fps)
	local targetName = string.format("drp_arcade_capture_%dx%d", capture.width, capture.height)
	if not capture.target or capture.targetName ~= targetName then
		capture.targetName = targetName
		capture.target = GetRenderTarget(targetName, capture.width, capture.height, false)
	end
	render.PushRenderTarget(capture.target)
	render.Clear(3, 6, 14, 255, true, true)
	cam.Start2D()
		surface.SetDrawColor(255, 255, 255, 255)
		surface.SetMaterial(material)
		surface.DrawTexturedRect(0, 0, capture.width, capture.height)
	cam.End2D()
	local data = render.Capture({
		format = "jpeg",
		x = 0,
		y = 0,
		w = capture.width,
		h = capture.height,
		quality = capture.quality
	})
	render.PopRenderTarget()
	if not data or #data < 64 or #data > capture.maxBytes then return end
	capture.sequence = (capture.sequence + 1) % 65536
	net.Start(message.FRAME)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteEntity(active.machine)
	net.WriteUInt(capture.sequence, 16)
	net.WriteUInt(#data, 16)
	net.WriteData(data, #data)
	net.SendToServer()
end)

hook.Add("ShutDown", "DRP.Arcade.ClientShutdown", function()
	Arcade:CloseActive(true)
	Arcade:CloseWatcher(true)
end)
