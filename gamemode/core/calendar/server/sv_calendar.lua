local Calendar = DRP.Calendar
if not Calendar then error("DRP calendar shared module was not loaded") end

DRP.Services.Register("calendar", Calendar)

local statePath = "darkrp/calendar.json"
local dayNightWorkshopID = "1614964558"

util.AddNetworkString(Calendar.SyncMessage)
util.AddNetworkString(Calendar.RequestMessage)
resource.AddWorkshop(dayNightWorkshopID)

Calendar.AnchorRoleplayUnix = Calendar.AnchorRoleplayUnix or 0
Calendar.AnchorSystemTime = Calendar.AnchorSystemTime or 0
Calendar.DayNightAvailable = false
Calendar.LastDayNightHour = nil
Calendar.DayStartHour = 5
Calendar.DayEndHour = 19

local function cleanTimestamp(value)
	value = tonumber(value)
	if not value or value < 946684800 or value > 4294967295 then return nil end
	return value
end

function Calendar.Now()
	if Calendar.AnchorRoleplayUnix <= 0 then return os.time() end
	return Calendar.AnchorRoleplayUnix
		+ math.max(0, SysTime() - Calendar.AnchorSystemTime) * Calendar.Scale
end

function Calendar.Load()
	file.CreateDir("darkrp")
	local saved = util.JSONToTable(file.Read(statePath, "DATA") or "")
	local savedRoleplay = istable(saved) and cleanTimestamp(saved.roleplay_unix) or nil
	local savedReal = istable(saved) and cleanTimestamp(saved.real_unix) or nil
	local realNow = os.time()

	if savedRoleplay and savedReal then
		-- The RP calendar is a world clock, so it continues moving while the
		-- process is offline. A crash therefore cannot roll the date backward.
		Calendar.AnchorRoleplayUnix = savedRoleplay
			+ math.max(0, realNow - savedReal) * Calendar.Scale
	else
		Calendar.AnchorRoleplayUnix = realNow
	end
	Calendar.AnchorSystemTime = SysTime()
	Calendar.Save()
end

function Calendar.Save()
	if Calendar.AnchorRoleplayUnix <= 0 then return end
	file.CreateDir("darkrp")
	file.Write(statePath, util.TableToJSON({
		version = Calendar.ProtocolVersion,
		roleplay_unix = Calendar.Now(),
		real_unix = os.time(),
		scale = Calendar.Scale
	}, true))
end

function Calendar.Send(recipient)
	net.Start(Calendar.SyncMessage)
	net.WriteUInt(Calendar.ProtocolVersion, 8)
	net.WriteDouble(Calendar.Now())
	net.WriteFloat(Calendar.Scale)
	if IsValid(recipient) then net.Send(recipient) else net.Broadcast() end
end

function Calendar.DayNightTime()
	local parts = Calendar.Components(Calendar.Now())
	local roleplayHour = parts.hour + parts.min / 60 + parts.sec / 3600
	-- The mounted renderer has fixed visual transitions: dawn finishes at 06:30
	-- and dusk begins at 19:00. Remap those points onto our RP clock so full
	-- daylight begins at 05:00 and the sunset transition begins at 19:00.
	local rendererDayStart,rendererDuskStart = 6.5,19
	if roleplayHour>=Calendar.DayStartHour and roleplayHour<Calendar.DayEndHour then
		local fraction=(roleplayHour-Calendar.DayStartHour)/(Calendar.DayEndHour-Calendar.DayStartHour)
		return rendererDayStart+fraction*(rendererDuskStart-rendererDayStart)
	end
	local nightHours=(24-Calendar.DayEndHour)+Calendar.DayStartHour
	local elapsed=roleplayHour>=Calendar.DayEndHour and (roleplayHour-Calendar.DayEndHour) or (24-Calendar.DayEndHour+roleplayHour)
	return (rendererDuskStart+(elapsed/nightHours)*(24-rendererDuskStart+rendererDayStart))%24
end

function Calendar.ConfigureDayNight()
	local enabled = GetConVar("daynight_enabled")
	local renderer = DaynightGlobal
	if not enabled or not istable(renderer) or not isfunction(renderer.SetTime) then
		Calendar.DayNightAvailable = false
		ErrorNoHalt(
			"[DRP CALENDAR] Day & Night renderer is unavailable. Add Workshop "
			.. dayNightWorkshopID
			.. " to the server collection or upload its extracted source addon. "
			.. "convar=" .. tostring(enabled ~= nil)
			.. " api=" .. tostring(istable(renderer)) .. "\n"
		)
		return false
	end

	Calendar.DayNightAvailable = true
	RunConsoleCommand("sv_skyname", "painted")
	RunConsoleCommand("daynight_enabled", "1")
	if GetConVar("daynight_realtime") then RunConsoleCommand("daynight_realtime", "0") end
	if GetConVar("daynight_paused") then RunConsoleCommand("daynight_paused", "0") end
	if GetConVar("daynight_log") then RunConsoleCommand("daynight_log", "0") end

	-- This addon's length values are denominators for a complete 24-hour pass,
	-- selected according to the current period. Matching both to 3600 seconds
	-- keeps the renderer at the calendar's exact 24x rate.
	RunConsoleCommand("daynight_length_day", tostring(Calendar.RealSecondsPerDay))
	RunConsoleCommand("daynight_length_night", tostring(Calendar.RealSecondsPerDay))
	Calendar.SyncDayNight(true)
	print("[DRP CALENDAR] Day & Night System synchronized to the roleplay clock")
	return true
end

function Calendar.SyncDayNight(force)
	local renderer = DaynightGlobal
	if not Calendar.DayNightAvailable or not istable(renderer) or not isfunction(renderer.SetTime) then return false end
	local hourKey = Calendar.HourKey(Calendar.Now())
	if not force and Calendar.LastDayNightHour == hourKey then return true end
	Calendar.LastDayNightHour = hourKey

	-- The addon's daynight_settime console command rejects server-console
	-- callers, despite being documented as a server command. Drive its
	-- authoritative renderer object directly instead.
	local targetTime = Calendar.DayNightTime()
	local ok, reason = xpcall(function()
		renderer:SetTime(targetTime)
		renderer.m_LastPeriod = -1
		renderer.m_LastStyle = nil
		if renderer.m_InitEntities and isfunction(renderer.Think) then renderer:Think() end
	end, debug.traceback)
	if not ok then
		Calendar.DayNightAvailable = false
		ErrorNoHalt("[DRP CALENDAR] Day & Night synchronization failed:\n" .. tostring(reason) .. "\n")
		return false
	end
	return true
end

function Calendar:Start()
	self.Load()

	local now = self.Now()
	self.LastMinuteKey = self.MinuteKey(now)
	self.LastHourKey = self.HourKey(now)
	self.LastDayKey = self.DayKey(now)

	timer.Create("DRP.Calendar.Events", 1, 0, function()
		local timestamp = Calendar.Now()
		local minuteKey = Calendar.MinuteKey(timestamp)
		local hourKey = Calendar.HourKey(timestamp)
		local dayKey = Calendar.DayKey(timestamp)

		if minuteKey ~= Calendar.LastMinuteKey then
			Calendar.LastMinuteKey = minuteKey
			hook.Run("DRPCalendarMinuteChanged", timestamp, Calendar.Components(timestamp))
		end
		if hourKey ~= Calendar.LastHourKey then
			Calendar.LastHourKey = hourKey
			hook.Run("DRPCalendarHourChanged", timestamp, Calendar.Components(timestamp))
			Calendar.SyncDayNight()
		end
		if dayKey ~= Calendar.LastDayKey then
			local previous = Calendar.LastDayKey
			Calendar.LastDayKey = dayKey
			hook.Run("DRPCalendarDayChanged", timestamp, Calendar.Components(timestamp), previous)
			Calendar.Send()
		end
	end)

	-- Addons finish their initialization after the gamemode files are loaded.
	timer.Simple(3, function() Calendar.ConfigureDayNight() end)
end

function Calendar:Stop()
	timer.Remove("DRP.Calendar.Events")
	self.Save()
end

DRP.Net.Receive(Calendar.RequestMessage, function(_, ply)
	if not DRP.Net.Allow(ply, "calendar_request", 2, 2) then return end
	Calendar.Send(ply)
end)

hook.Add("DRPPlayerReady", "DRP.Calendar.InitialSync", function(ply)
	Calendar.Send(ply)
end)

concommand.Add("drp_calendar_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.CanSetRanks(ply)) then return end
	local message = string.format(
		"[DRP CALENDAR] %s | scale=%.2fx | day_length=%ds | daynight=%s renderer=%.2f sky=%s",
		Calendar.Format(Calendar.Now(), true),
		Calendar.Scale,
		Calendar.RealSecondsPerDay,
		Calendar.DayNightAvailable and "mounted" or "missing",
		(istable(DaynightGlobal) and tonumber(DaynightGlobal.m_Time)) or -1,
		tostring(istable(DaynightGlobal) and IsValid(DaynightGlobal.m_EnvSkyPaint) or false)
	)
	print(message)
	if IsValid(ply) and DRP.Net then DRP.Net.Notify(ply, message, Calendar.DayNightAvailable and 1 or 2) end
end)

concommand.Add("drp_calendar_resync_daynight", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.CanSetRanks(ply)) then return end
	Calendar.ConfigureDayNight()
end)
