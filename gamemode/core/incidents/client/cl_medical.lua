local Medical = {
	Calls = {},
	Distances = {},
	Defibrillation = nil
}

DRP.MedicalClient = Medical

surface.CreateFont("DRP.Medical.Title", { font = "Roboto", size = 18, weight = 800 })
surface.CreateFont("DRP.Medical.Body", { font = "Roboto", size = 15, weight = 600 })
surface.CreateFont("DRP.Medical.Small", { font = "Roboto", size = 13, weight = 500 })

local promptFrame

local function colors()
	return DRP.UI and DRP.UI.Colors or {
		background = Color(8, 13, 25, 245),
		panel = Color(15, 24, 43, 245),
		accent = Color(74, 205, 255),
		green = Color(104, 235, 150),
		red = Color(244, 105, 128),
		muted = Color(158, 174, 201)
	}
end

local function openPrompt(corpse, patientName, alreadyCalled)
	if IsValid(promptFrame) then promptFrame:Remove() end
	local palette = colors()
	promptFrame = DRP.UI.Frame("Medical Emergency", 510, 260)

	local body = vgui.Create("DLabel", promptFrame)
	body:SetPos(28, 82)
	body:SetSize(promptFrame:GetWide() - 56, 76)
	body:SetFont("DRP.Admin.Body")
	body:SetTextColor(palette.muted)
	body:SetWrap(true)
	body:SetText(alreadyCalled
		and ("A Medic has already been requested for " .. patientName .. ".")
		or (patientName .. " is unresponsive. Request a Medic to revive them?"))

	local leave = DRP.UI.Button(promptFrame, "LEAVE", palette.panel, function() promptFrame:Close() end)
	leave:SetSize(145, 42)
	leave:SetPos(28, promptFrame:GetTall() - 66)

	local call = DRP.UI.Button(promptFrame, alreadyCalled and "MEDIC REQUESTED" or "CALL A MEDIC", alreadyCalled and palette.muted or palette.accent, function()
		if not alreadyCalled and IsValid(corpse) then
			net.Start("drp_medical_request_v1")
			net.WriteUInt(DRP.ProtocolVersion, 8)
			net.WriteEntity(corpse)
			net.SendToServer()
		end
		promptFrame:Close()
	end)
	call:SetEnabled(not alreadyCalled)
	call:SetSize(281, 42)
	call:SetPos(promptFrame:GetWide() - 309, promptFrame:GetTall() - 66)
end

net.Receive("drp_medical_prompt_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	openPrompt(net.ReadEntity(), net.ReadString(), net.ReadBool())
end)

net.Receive("drp_medical_call_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local active = net.ReadBool()
	local id = net.ReadUInt(24)
	if not active then
		Medical.Calls[id] = nil
		Medical.Distances[id] = nil
		return
	end
	Medical.Calls[id] = {
		id = id,
		corpse = net.ReadEntity(),
		ownerSteamID = net.ReadString(),
		ownerName = net.ReadString(),
		position = net.ReadVector(),
		called = net.ReadBool(),
		callerName = net.ReadString()
	}
end)

net.Receive("drp_medical_distances_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local id, entries = net.ReadUInt(24), {}
	for index = 1, net.ReadUInt(4) do
		entries[index] = {
			player = net.ReadEntity(),
			name = net.ReadString(),
			distance = net.ReadUInt(16)
		}
	end
	Medical.Distances[id] = entries
end)

net.Receive("drp_medical_defib_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if net.ReadBool() then
		Medical.Defibrillation = {
			id = net.ReadUInt(24),
			duration = net.ReadFloat(),
			startedAt = CurTime(),
			patientName = net.ReadString()
		}
	else
		local reason = net.ReadString()
		Medical.Defibrillation = nil
		if reason ~= "" and reason ~= "Revival complete" then notification.AddLegacy(reason, NOTIFY_HINT, 2) end
	end
end)

local function localDeathCall()
	local localPlayer = LocalPlayer()
	if not IsValid(localPlayer) then return nil end
	local steamID = localPlayer:SteamID64()
	for _, record in pairs(Medical.Calls) do
		if record.ownerSteamID == steamID then return record end
	end
end

local function drawDeadPanel(record)
	local palette = colors()
	local distances = Medical.Distances[record.id] or {}
	local width, rowHeight = 330, 20
	local height = 78 + math.max(1, math.min(#distances, 4)) * rowHeight
	local x, y = ScrW() * 0.5 - width * 0.5, ScrH() - height - 54
	draw.RoundedBox(9, x, y, width, height, Color(8, 13, 25, 238))
	draw.RoundedBoxEx(9, x, y, 5, height, palette.red, true, false, true, false)
	draw.SimpleText("MEDICAL RESPONSE", "DRP.Medical.Title", x + 18, y + 18, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText(record.called and ("Requested by " .. record.callerName) or "Someone nearby can press E to call a Medic", "DRP.Medical.Small", x + 18, y + 40, record.called and palette.accent or palette.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText("AVAILABLE MEDICS", "DRP.Medical.Small", x + 18, y + 62, palette.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	if #distances == 0 then
		draw.SimpleText("No active Medics", "DRP.Medical.Body", x + width - 18, y + 62, palette.red, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	else
		for index = 1, math.min(#distances, 4) do
			local entry = distances[index]
			local rowY = y + 62 + index * rowHeight
			draw.SimpleText(entry.name, "DRP.Medical.Body", x + 18, rowY, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(entry.distance .. " m", "DRP.Medical.Body", x + width - 18, rowY, palette.green, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
	end
end

local function drawMedicPings()
	local localPlayer = LocalPlayer()
	if not IsValid(localPlayer) or not localPlayer:Alive() or not localPlayer:DRPJob().canHeal then return end
	local palette = colors()
	for _, record in pairs(Medical.Calls) do
		if record.called then
			local position = IsValid(record.corpse) and record.corpse:WorldSpaceCenter() or record.position
			local screen = position:ToScreen()
			local x = math.Clamp(screen.x, 78, ScrW() - 78)
			local y = math.Clamp(screen.y, 88, ScrH() - 110)
			local distance = math.floor(localPlayer:GetPos():Distance(position) / 52.49 + 0.5)
			local pulse = 0.75 + math.sin(RealTime() * 5) * 0.15
			draw.RoundedBox(7, x - 74, y - 23, 148, 46, Color(8, 13, 25, 225))
			draw.RoundedBoxEx(7, x - 74, y - 23, 4, 46, Color(palette.red.r, palette.red.g, palette.red.b, 255 * pulse), true, false, true, false)
			draw.SimpleText("✚  " .. record.ownerName, "DRP.Medical.Body", x, y - 8, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			draw.SimpleText(distance .. " m  •  MEDICAL CALL", "DRP.Medical.Small", x, y + 10, palette.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
end

local function drawDefibrillation()
	local state = Medical.Defibrillation
	if not state then return end
	local palette = colors()
	local width, height = 360, 54
	local x, y = ScrW() * 0.5 - width * 0.5, ScrH() * 0.68
	local progress = math.Clamp((CurTime() - state.startedAt) / math.max(0.1, state.duration), 0, 1)
	draw.RoundedBox(8, x, y, width, height, Color(8, 13, 25, 240))
	draw.SimpleText("REVIVING " .. string.upper(state.patientName), "DRP.Medical.Body", x + 14, y + 17, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.RoundedBox(4, x + 14, y + 34, width - 28, 9, Color(28, 43, 72))
	draw.RoundedBox(4, x + 14, y + 34, (width - 28) * progress, 9, palette.green)
end

hook.Add("HUDPaint", "DRP.Medical.HUD", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	local record = localDeathCall()
	if record and not LocalPlayer():Alive() then drawDeadPanel(record) end
	drawMedicPings()
	drawDefibrillation()
end)

hook.Add("InitPostEntity", "DRP.Medical.Reset", function()
	Medical.Calls = {}
	Medical.Distances = {}
	Medical.Defibrillation = nil
end)
