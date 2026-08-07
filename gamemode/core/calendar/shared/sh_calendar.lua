DRP.Calendar = DRP.Calendar or {}

local Calendar = DRP.Calendar

Calendar.ProtocolVersion = 1
Calendar.RealSecondsPerDay = 60 * 60
Calendar.RoleplaySecondsPerDay = 24 * 60 * 60
Calendar.Scale = Calendar.RoleplaySecondsPerDay / Calendar.RealSecondsPerDay
Calendar.SyncMessage = "drp_calendar_sync_v1"
Calendar.RequestMessage = "drp_calendar_request_v1"

function Calendar.Components(timestamp)
	return os.date("!*t", math.max(0, math.floor(tonumber(timestamp) or 0)))
end

function Calendar.DayKey(timestamp)
	local parts = Calendar.Components(timestamp)
	return string.format("%04d-%02d-%02d", parts.year, parts.month, parts.day)
end

function Calendar.MinuteKey(timestamp)
	return math.floor(math.max(0, tonumber(timestamp) or 0) / 60)
end

function Calendar.HourKey(timestamp)
	return math.floor(math.max(0, tonumber(timestamp) or 0) / 3600)
end

function Calendar.FormatDate(timestamp)
	return string.upper(os.date("!%d %b %Y", math.max(0, math.floor(tonumber(timestamp) or 0))))
end

function Calendar.FormatTime(timestamp, includeSeconds)
	local format = includeSeconds and "!%H:%M:%S" or "!%H:%M"
	return os.date(format, math.max(0, math.floor(tonumber(timestamp) or 0)))
end

function Calendar.Format(timestamp, includeSeconds)
	return Calendar.FormatDate(timestamp) .. "  •  " .. Calendar.FormatTime(timestamp, includeSeconds)
end

if CLIENT then
	Calendar.ClientRoleplayUnix = Calendar.ClientRoleplayUnix or 0
	Calendar.ClientReceivedAt = Calendar.ClientReceivedAt or 0
	Calendar.ClientScale = Calendar.ClientScale or Calendar.Scale

	function Calendar.Now()
		if Calendar.ClientRoleplayUnix <= 0 then return os.time() end
		return Calendar.ClientRoleplayUnix
			+ math.max(0, RealTime() - Calendar.ClientReceivedAt) * Calendar.ClientScale
	end
end
