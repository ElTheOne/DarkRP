local incidents = {}
-- The police operations tablet consumes the same recipient-filtered incident
-- records as the Why HUD. This is a client view only; incident authority stays
-- on the server.
DRP.ClientIncidents = incidents
local denial
local nextRecoveryRequest = 0

if DRP.IncidentRecorder and isfunction(DRP.IncidentRecorder.Shutdown) then
	DRP.IncidentRecorder.Shutdown(true)
end

local autoRecord = CreateClientConVar(
	"drp_incident_autorecord",
	"0",
	true,
	false,
	"Automatically record clientside demos while participating in DarkRP incidents."
)

local Recorder = {
	Active = {},
	Captured = {},
	Suppressed = {},
	Owned = false,
	External = false,
	Starting = false,
	Stopping = false,
	ManualHold = false,
	AutoLatched = false,
	SessionActive = false,
	SessionStartedAt = 0,
	SessionWallTime = 0,
	StartDeadline = 0,
	StopAt = 0,
	StopReason = "",
	StopDeadline = 0,
	StopAfterStart = false
}
DRP.IncidentRecorder = Recorder

surface.CreateFont("DRP.Incident.Record", { font = "Roboto", size = 14, weight = 900 })

local function recordingDemo()
	return engine and isfunction(engine.IsRecordingDemo) and engine.IsRecordingDemo() == true
end

local function playerNotice(text, kind, duration)
	notification.AddLegacy(tostring(text or ""), kind or NOTIFY_GENERIC, duration or 5)
end

local function activeCount()
	local count = 0
	for _ in pairs(Recorder.Active) do count = count + 1 end
	return count
end

local function cleanParticipantText(value)
	value = string.Trim(tostring(value or ""))
	return value ~= "" and value or "Participants unavailable"
end

local function captureIncident(incident)
	if not istable(incident) or not incident.id then return end
	local record = Recorder.Captured[incident.id]
	if not record then
		record = {
			id = incident.id,
			type = tostring(incident.type or "incident"),
			participants = cleanParticipantText(incident.others),
			observedAt = RealTime(),
			observedWallTime = os.time(),
			resolution = "active"
		}
		Recorder.Captured[incident.id] = record
	else
		record.type = tostring(incident.type or record.type)
		record.participants = cleanParticipantText(incident.others or record.participants)
	end
end

local function captureActiveIncidents()
	for _, incident in pairs(Recorder.Active) do captureIncident(incident) end
end

local function resetSession()
	Recorder.Captured = {}
	Recorder.SessionActive = false
	Recorder.SessionStartedAt = 0
	Recorder.SessionWallTime = 0
	Recorder.StopAt = 0
	Recorder.StopReason = ""
	Recorder.StopDeadline = 0
	Recorder.StopAfterStart = false
	Recorder.AutoLatched = false
end

local function beginSession()
	if Recorder.SessionActive then
		captureActiveIncidents()
		return
	end
	Recorder.Captured = {}
	Recorder.SessionActive = true
	Recorder.SessionStartedAt = RealTime()
	Recorder.SessionWallTime = os.time()
	captureActiveIncidents()
end

local function sortedCaptured()
	local output = {}
	for _, record in pairs(Recorder.Captured) do output[#output + 1] = record end
	table.sort(output, function(first, second) return first.id < second.id end)
	return output
end

local function finishSummary(reason, silent)
	local records = sortedCaptured()
	local duration = Recorder.SessionStartedAt > 0 and math.max(0, math.floor(RealTime() - Recorder.SessionStartedAt)) or 0
	local started = Recorder.SessionWallTime > 0 and os.date("%d %b %Y %H:%M:%S", Recorder.SessionWallTime) or "unknown"
	local finished = os.date("%d %b %Y %H:%M:%S")

	if not silent then
		if #records > 0 then
			local ids = {}
			for _, record in ipairs(records) do ids[#ids + 1] = "#" .. record.id end
			local summary = "Incident demo finished: " .. table.concat(ids, ", ") .. " (about " .. duration .. "s)."
			playerNotice(summary, NOTIFY_GENERIC, 7)
			playerNotice("Saved locally under garrysmod/demos/", NOTIFY_HINT, 7)
			if DRP.Chat and DRP.Chat.System then DRP.Chat.System(summary .. " Saved under garrysmod/demos/", 1) end
		else
			local summary = "Client demo finished after about " .. duration .. "s. Saved under garrysmod/demos/"
			playerNotice(summary, NOTIFY_GENERIC, 7)
			if DRP.Chat and DRP.Chat.System then DRP.Chat.System(summary, 1) end
		end
	end

	MsgC(Color(244, 105, 128), "[DRP REC] ", color_white,
		"session finished; reason=", tostring(reason or "recording ended"),
		" duration=", tostring(duration), "s started=", started, " finished=", finished, "\n")
	for _, record in ipairs(records) do
		MsgC(Color(244, 105, 128), "[DRP REC] ", color_white,
			"incident #", tostring(record.id), " type=", record.type,
			" resolution=", tostring(record.resolution or "unknown"),
			" participants=", record.participants, "\n")
	end
	resetSession()
end

local function markCurrentIncidentsSuppressed()
	for id in pairs(Recorder.Active) do Recorder.Suppressed[id] = true end
end

local function startDemo(source)
	if Recorder.Owned or Recorder.Starting then
		beginSession()
		return true
	end
	if Recorder.External and recordingDemo() then
		beginSession()
		captureActiveIncidents()
		return true
	end
	if recordingDemo() then
		Recorder.External = true
		beginSession()
		captureActiveIncidents()
		playerNotice("An existing manual demo is already recording. DarkRP will bookmark incidents but will not stop it.", NOTIFY_HINT, 6)
		return true
	end

	Recorder.External = false
	Recorder.Starting = true
	Recorder.Stopping = false
	Recorder.StartDeadline = RealTime() + 3
	Recorder.StopReason = ""
	beginSession()
	RunConsoleCommand("gm_demo")
	MsgC(Color(244, 105, 128), "[DRP REC] ", color_white, "requested gm_demo start (", tostring(source or "incident"), ")\n")
	return true
end

local function stopOwnedDemo(reason, silent)
	if Recorder.Starting then
		if recordingDemo() then
			Recorder.Starting = false
			Recorder.Owned = true
		else
			Recorder.Starting = false
			Recorder.ManualHold = false
			finishSummary(reason or "start cancelled", silent)
			return true
		end
	end
	if not Recorder.Owned then return false end
	Recorder.Stopping = true
	Recorder.StopAt = 0
	Recorder.StopReason = reason or "recording complete"
	Recorder.StopDeadline = RealTime() + 3
	Recorder.SilentStop = silent == true
	if recordingDemo() then
		RunConsoleCommand("gm_demo")
	else
		Recorder.Owned = false
		Recorder.Stopping = false
		finishSummary(Recorder.StopReason, Recorder.SilentStop)
	end
	return true
end

function Recorder.IsOwnedRecording()
	return Recorder.Owned == true or Recorder.Starting == true
end

function Recorder.OnIncidentStarted(incident)
	if not istable(incident) or not incident.id then return end
	Recorder.Active[incident.id] = incident
	Recorder.Suppressed[incident.id] = nil
	if Recorder.SessionActive then captureIncident(incident) end

	if autoRecord:GetBool() then
		Recorder.AutoLatched = true
		Recorder.StopAt = 0
		startDemo("incident #" .. incident.id)
	end
end

function Recorder.OnIncidentUpdated(incident)
	if not istable(incident) or not incident.id then return end
	Recorder.Active[incident.id] = incident
	if Recorder.SessionActive then captureIncident(incident) end
end

function Recorder.OnIncidentResolved(incident, resolution)
	if not istable(incident) or not incident.id then return end
	if Recorder.SessionActive then
		captureIncident(incident)
		local record = Recorder.Captured[incident.id]
		if record then
			record.resolution = tostring(resolution or "resolved")
			record.endedAt = RealTime()
			record.endedWallTime = os.time()
		end
	end
	Recorder.Active[incident.id] = nil
	Recorder.Suppressed[incident.id] = nil

	if activeCount() == 0 and Recorder.Owned and Recorder.AutoLatched and not Recorder.ManualHold then
		Recorder.StopAt = RealTime() + 30
		Recorder.StopReason = "final incident resolved"
		playerNotice("Final incident resolved. Demo recording will stop in 30 seconds.", NOTIFY_HINT, 5)
	end
end

function Recorder.ToggleManual()
	if Recorder.Starting then
		if Recorder.ManualHold then
			Recorder.ManualHold = false
			Recorder.StopAfterStart = true
			playerNotice("Recording will stop as soon as Garry's Mod finishes starting it.", NOTIFY_HINT, 4)
		else
			Recorder.ManualHold = true
			Recorder.StopAfterStart = false
			playerNotice("Manual incident recording hold enabled. Use /recordincident again to stop.", NOTIFY_GENERIC, 6)
		end
		return
	end

	if Recorder.Owned then
		if Recorder.ManualHold then
			Recorder.ManualHold = false
			playerNotice("Manual recording hold released.", NOTIFY_HINT, 4)
			if activeCount() == 0 or not Recorder.AutoLatched then
				stopOwnedDemo("manual toggle")
			end
		else
			Recorder.ManualHold = true
			Recorder.StopAt = 0
			playerNotice("Manual incident recording hold enabled. Use /recordincident again to stop.", NOTIFY_GENERIC, 6)
		end
		return
	end

	if recordingDemo() then
		Recorder.External = true
		beginSession()
		captureActiveIncidents()
		playerNotice("Your existing manual demo remains under your control. Active incidents were bookmarked.", NOTIFY_HINT, 6)
		return
	end

	Recorder.ManualHold = true
	Recorder.StopAt = 0
	startDemo("manual command")
end

function Recorder.Shutdown(silent)
	timer.Remove("DRP.IncidentRecorder.Monitor")
	if Recorder.Owned or Recorder.Starting then stopOwnedDemo("client shutdown or reload", silent == true) end
	Recorder.External = false
end

local function monitorRecorder()
	local recording = recordingDemo()
	if Recorder.Starting then
		if recording then
			Recorder.Starting = false
			Recorder.Owned = true
			Recorder.External = false
			Recorder.StartDeadline = 0
			captureActiveIncidents()
			playerNotice("Client demo recording started. Incident footage stays on your computer.", NOTIFY_GENERIC, 5)
			if Recorder.StopAfterStart then
				Recorder.StopAfterStart = false
				stopOwnedDemo("manual toggle during startup")
			elseif Recorder.AutoLatched and activeCount() == 0 and not Recorder.ManualHold then
				Recorder.StopAt = RealTime() + 30
				Recorder.StopReason = "incident resolved during recording startup"
			end
		elseif RealTime() >= Recorder.StartDeadline then
			Recorder.Starting = false
			Recorder.ManualHold = false
			playerNotice("Garry's Mod did not start the demo recording. Check the client console for gm_demo errors.", NOTIFY_ERROR, 7)
			finishSummary("gm_demo start failed", true)
		end
		return
	end

	if Recorder.Owned and not recording then
		local expected = Recorder.Stopping
		local reason = expected and Recorder.StopReason or "stopped manually by player"
		local silent = expected and Recorder.SilentStop
		if not expected then markCurrentIncidentsSuppressed() end
		Recorder.Owned = false
		Recorder.Stopping = false
		Recorder.ManualHold = false
		Recorder.SilentStop = false
		finishSummary(reason, silent)
		return
	end

	if Recorder.Owned and Recorder.Stopping and recording
		and Recorder.StopDeadline > 0 and RealTime() >= Recorder.StopDeadline then
		Recorder.Stopping = false
		Recorder.StopDeadline = 0
		Recorder.ManualHold = true
		playerNotice("Garry's Mod did not stop the demo. Recording was left active; use /recordincident or gm_demo to try again.", NOTIFY_ERROR, 7)
		return
	end

	if Recorder.External and not recording then
		Recorder.External = false
		finishSummary("external manual demo ended")
		return
	end

	if Recorder.Owned and Recorder.StopAt > 0 and RealTime() >= Recorder.StopAt
		and activeCount() == 0 and not Recorder.ManualHold then
		stopOwnedDemo(Recorder.StopReason ~= "" and Recorder.StopReason or "incident grace elapsed")
	end
end

local recorderMonitorInterval = 1
local function recorderMonitorTick()
	monitorRecorder()
	local busy = Recorder.Starting or Recorder.Owned or Recorder.External or Recorder.Stopping
		or Recorder.ManualHold or Recorder.StopAt > 0 or activeCount() > 0
	local wantedInterval = busy and 0.25 or 1
	if wantedInterval ~= recorderMonitorInterval then
		recorderMonitorInterval = wantedInterval
		timer.Adjust("DRP.IncidentRecorder.Monitor", recorderMonitorInterval, 0, recorderMonitorTick)
	end
end
timer.Create("DRP.IncidentRecorder.Monitor", recorderMonitorInterval, 0, recorderMonitorTick)

concommand.Add("drp_recordincident", function() Recorder.ToggleManual() end)
concommand.Add("drp_incident_record_status", function()
	print(string.format(
		"[DRP REC] engine=%s owned=%s external=%s starting=%s stopping=%s manual_hold=%s auto_latched=%s active=%d captured=%d stop_in=%.1fs",
		tostring(recordingDemo()), tostring(Recorder.Owned), tostring(Recorder.External),
		tostring(Recorder.Starting), tostring(Recorder.Stopping), tostring(Recorder.ManualHold),
		tostring(Recorder.AutoLatched), activeCount(), table.Count(Recorder.Captured),
		math.max(0, Recorder.StopAt - RealTime())
	))
end)

net.Receive("drp_incident_record_toggle_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	Recorder.ToggleManual()
end)

hook.Add("ShutDown", "DRP.IncidentRecorder.Shutdown", function()
	Recorder.Shutdown(true)
end)

hook.Add("HUDPaint", "DRP.IncidentRecorder.Status", function()
	if not Recorder.SessionActive or not recordingDemo() then return end
	local ids = {}
	for id in pairs(Recorder.Active) do ids[#ids + 1] = id end
	table.sort(ids)

	local label
	if #ids == 0 then
		label = "REC  •  MANUAL"
	elseif #ids == 1 then
		label = "REC  •  INCIDENT #" .. ids[1]
	else
		local shown = {}
		for index = 1, math.min(#ids, 3) do shown[index] = "#" .. ids[index] end
		label = "REC  •  INCIDENTS " .. table.concat(shown, ", ")
		if #ids > 3 then label = label .. " +" .. (#ids - 3) end
	end

	surface.SetFont("DRP.Incident.Record")
	local textWidth = surface.GetTextSize(label)
	local width, height = textWidth + 34, 30
	local x, y = math.floor((ScrW() - width) * 0.5), 20
	draw.RoundedBox(7, x, y, width, height, Color(21, 10, 15, 230))
	draw.RoundedBoxEx(7, x, y, 5, height, Color(244, 78, 100), true, false, true, false)
	draw.SimpleText(label, "DRP.Incident.Record", x + width * 0.5 + 2, y + height * 0.5,
		Color(255, 118, 135), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

local function requestRecovery()
	if nextRecoveryRequest > RealTime() then return end
	nextRecoveryRequest = RealTime() + 5
	net.Start("drp_incident_request_v1")
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.SendToServer()
end

surface.CreateFont("DRP.Incident.Title", { font = "Roboto", size = 17, weight = 800 })
surface.CreateFont("DRP.Incident.Body", { font = "Roboto", size = 14, weight = 500 })
surface.CreateFont("DRP.Incident.Small", { font = "Roboto", size = 12, weight = 500 })

local function readFullIncident()
	local id = net.ReadUInt(32)
	local existing = incidents[id]
	local incident = {
		id = id,
		type = net.ReadString(),
		state = net.ReadString(),
		reason = net.ReadString(),
		role = net.ReadString(),
		others = net.ReadString(),
		deadline = RealTime() + net.ReadUInt(16),
		permissions = {},
		evidence = {}
	}
	for index = 1, net.ReadUInt(4) do incident.permissions[index] = net.ReadString() end
	for index = 1, net.ReadUInt(2) do
		incident.evidence[index] = { event = net.ReadString(), detail = net.ReadString() }
	end
	incidents[incident.id] = incident
	if existing then Recorder.OnIncidentUpdated(incident) else Recorder.OnIncidentStarted(incident) end
	hook.Run("DRPClientIncidentsChanged", incident.id, existing and "updated" or "started")
	return incident
end

net.Receive("drp_incident_sync_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local active = net.ReadBool()
	if not active then
		local id = net.ReadUInt(32)
		local resolution = net.ReadString()
		if incidents[id] then Recorder.OnIncidentResolved(incidents[id], resolution) end
		incidents[id] = nil
		hook.Run("DRPClientIncidentsChanged", id, "resolved")
		denial = { text = "Incident #" .. id .. " ended: " .. resolution, expires = RealTime() + 5, positive = true }
		return
	end
	readFullIncident()
end)

net.Receive("drp_incident_batch_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	for _ = 1, net.ReadUInt(8) do readFullIncident() end
	hook.Run("DRPClientIncidentsChanged", 0, "batch")
end)

net.Receive("drp_incident_delta_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local id = net.ReadUInt(32)
	local mask = net.ReadUInt(4)
	local incident = incidents[id]
	if not incident then
		requestRecovery()
		return
	end
	if bit.band(mask, 1) ~= 0 then
		incident.state = net.ReadString()
		incident.reason = net.ReadString()
		incident.deadline = RealTime() + net.ReadUInt(16)
	end
	if bit.band(mask, 2) ~= 0 then
		incident.role = net.ReadString()
		incident.others = net.ReadString()
	end
	if bit.band(mask, 4) ~= 0 then
		incident.permissions = {}
		for index = 1, net.ReadUInt(4) do incident.permissions[index] = net.ReadString() end
	end
	if bit.band(mask, 8) ~= 0 then
		for _ = 1, net.ReadUInt(3) do
			incident.evidence[#incident.evidence + 1] = { event = net.ReadString(), detail = net.ReadString() }
		end
		while #incident.evidence > 3 do table.remove(incident.evidence, 1) end
	end
	Recorder.OnIncidentUpdated(incident)
	hook.Run("DRPClientIncidentsChanged", id, "delta")
end)

concommand.Add("drp_incident_refresh", function()
	nextRecoveryRequest = 0
	requestRecovery()
end)

local function requestReadyRecovery(state)
	if state ~= DRP.State.READY then return end
	timer.Simple(0.25, function()
		if not IsValid(LocalPlayer()) then return end
		nextRecoveryRequest = 0
		requestRecovery()
	end)
end

hook.Add("DRPLifecycleChanged", "DRP.Incidents.ReadyRecovery", requestReadyRecovery)
timer.Simple(1, function() requestReadyRecovery(DRP.ClientState) end)

net.Receive("drp_incident_denied_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local id = net.ReadUInt(32)
	local action = net.ReadString()
	local explanation = net.ReadString()
	denial = { id = id, action = action, text = explanation, expires = RealTime() + 5 }
	surface.PlaySound("buttons/button10.wav")
end)

local function pretty(value)
	return string.upper(string.gsub(value or "", "_", " "))
end

local function wrapText(text, font, maxWidth, maxLines)
	text = tostring(text or "")
	surface.SetFont(font)
	local lines, line = {}, ""
	for word in string.gmatch(text, "%S+") do
		local candidate = line == "" and word or (line .. " " .. word)
		if surface.GetTextSize(candidate) > maxWidth and line ~= "" then
			lines[#lines + 1] = line
			line = word
			if maxLines and #lines >= maxLines then break end
		else
			line = candidate
		end
	end
	if line ~= "" and (not maxLines or #lines < maxLines) then lines[#lines + 1] = line end
	if #lines == 0 then lines[1] = "" end
	if maxLines and #lines > maxLines then lines[#lines] = string.sub(lines[#lines], 1, 3) .. "..." end
	return lines
end

-- Incident text changes only when the server sends an incident delta. Sorting
-- and word wrapping it in HUDPaint multiplied that work by the client's frame
-- rate, so cache the complete static layout and keep only countdown text live.
local renderCache = { dirty = true, width = 0, list = {} }

local function invalidateRenderCache()
	renderCache.dirty = true
end

hook.Add("DRPClientIncidentsChanged", "DRP.Incidents.RenderCache", invalidateRenderCache)
hook.Add("DRPClientScreenSizeChanged", "DRP.Incidents.RenderCache", invalidateRenderCache)

local function rebuildRenderCache(width)
	local sorted = {}
	for _, incident in pairs(incidents) do sorted[#sorted + 1] = incident end
	table.sort(sorted, function(a, b) return a.id < b.id end)
	local list = {}
	for index = 1, math.min(#sorted, 3) do
		local incident = sorted[index]
		local permissionCount = math.min(#incident.permissions, 3)
		local evidence = incident.evidence[#incident.evidence]
		local reasonLines = wrapText(incident.reason, "DRP.Incident.Body", width - 32, 2)
		local evidenceLines = evidence and wrapText(
			"EVIDENCE: " .. pretty(evidence.event) .. " — " .. evidence.detail,
			"DRP.Incident.Small",
			width - 36,
			2
		) or {}
		list[index] = {
			incident = incident,
			permissionCount = permissionCount,
			reasonLines = reasonLines,
			evidenceLines = evidenceLines,
			height = 78 + (#reasonLines * 16) + permissionCount * 17
				+ (#evidenceLines > 0 and (#evidenceLines * 15 + 3) or 0)
		}
	end
	renderCache.width = width
	renderCache.list = list
	renderCache.dirty = false
	return list
end

hook.Add("HUDPaint", "DRP.Incidents.Why", function()
	local colors = DRP.UI and DRP.UI.Colors
	if not colors then return end
	local width = math.min(390, ScrW() - 32)
	local list
	if renderCache.dirty or renderCache.width ~= width then
		list = rebuildRenderCache(width)
	else
		list = renderCache.list
	end
	local x = ScrW() - width - 18
	-- Incident context owns the top-right HUD zone. Civic reputation now lives
	-- below playtime on the left and Admin Mode lives at bottom-center.
	local y = 20

	if #list == 0 then
		draw.RoundedBox(7, x + width - 178, y, 178, 32, Color(12, 16, 24, 205))
		draw.RoundedBoxEx(7, x + width - 178, y, 4, 32, colors.green, true, false, true, false)
		draw.SimpleText("WHY?  SAFE MODE", "DRP.Incident.Small", x + width - 164, y + 16, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	else
		for index = 1, #list do
			local cached = list[index]
			local incident = cached.incident
			local lines = cached.permissionCount
			local reasonLines = cached.reasonLines
			local evidenceLines = cached.evidenceLines
			local height = cached.height
			draw.RoundedBox(8, x, y, width, height, Color(12, 16, 24, 232))
			draw.RoundedBoxEx(8, x, y, 5, height, colors.accent, true, false, true, false)
			draw.SimpleText("WHY?  INCIDENT #" .. incident.id .. " — " .. pretty(incident.type), "DRP.Incident.Title", x + 16, y + 17, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			local remaining = math.max(0, math.ceil(incident.deadline - RealTime()))
			draw.SimpleText(pretty(incident.state) .. (remaining > 0 and ("  •  " .. remaining .. "s") or ""), "DRP.Incident.Small", x + width - 14, y + 39, colors.accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
			draw.SimpleText(incident.others, "DRP.Incident.Small", x + 16, y + 39, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			for reasonIndex, reasonLine in ipairs(reasonLines) do
				draw.SimpleText(reasonLine, "DRP.Incident.Body", x + 16, y + 59 + (reasonIndex - 1) * 16, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end
			local contentY = y + 76 + (#reasonLines - 1) * 16
			for permissionIndex = 1, lines do
				draw.SimpleText("• " .. incident.permissions[permissionIndex], "DRP.Incident.Small", x + 18, contentY + (permissionIndex - 1) * 17, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end
			if #evidenceLines > 0 then
				local evidenceY = contentY + lines * 17 + 2
				for evidenceIndex, evidenceLine in ipairs(evidenceLines) do
					draw.SimpleText(evidenceLine, "DRP.Incident.Small", x + 18, evidenceY + (evidenceIndex - 1) * 15, colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				end
			end
			y = y + height + 8
		end
	end

	if denial and denial.expires > RealTime() then
		local boxWidth = math.min(620, ScrW() - 40)
		local boxHeight, hudBottomMargin = 58, 28
		if DRP.ClientAdminMode then hudBottomMargin = hudBottomMargin + 66 end
		local boxX, boxY = (ScrW() - boxWidth) * 0.5, ScrH() - hudBottomMargin - boxHeight
		local accent = denial.positive and colors.green or colors.red
		draw.RoundedBox(8, boxX, boxY, boxWidth, boxHeight, Color(12, 16, 24, 242))
		draw.RoundedBoxEx(8, boxX, boxY, 6, boxHeight, accent, true, false, true, false)
		draw.SimpleText(denial.positive and "INCIDENT RESOLVED" or "ACTION DENIED — WHY?", "DRP.Incident.Title", boxX + 20, boxY + 18, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(denial.text, "DRP.Incident.Body", boxX + 20, boxY + 40, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	elseif denial then
		denial = nil
	end
end)
