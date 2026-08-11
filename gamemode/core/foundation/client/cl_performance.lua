DRP.ClientPerformance = DRP.ClientPerformance or {}

local Performance = DRP.ClientPerformance
local sampleHook = "DRP.ClientPerformance.Sample"

Performance.ScreenWidth = ScrW()
Performance.ScreenHeight = ScrH()

hook.Add("OnScreenSizeChanged", "DRP.ClientPerformance.Screen", function(_, _, width, height)
	Performance.ScreenWidth = tonumber(width) or ScrW()
	Performance.ScreenHeight = tonumber(height) or ScrH()
	hook.Run("DRPClientScreenSizeChanged", Performance.ScreenWidth, Performance.ScreenHeight)
end)

local function percentile(values, fraction)
	if #values == 0 then return 0 end
	table.sort(values)
	return values[math.Clamp(math.ceil(#values * fraction), 1, #values)] or 0
end

local function finishSample(state)
	hook.Remove("Think", sampleHook)
	if not state or #state.frames == 0 then
		print("[DRP CLIENT PERF] no frames sampled")
		return
	end
	local total = 0
	for _, frameTime in ipairs(state.frames) do total = total + frameTime end
	local average = total / #state.frames
	local p95 = percentile(table.Copy(state.frames), 0.95)
	local p99 = percentile(table.Copy(state.frames), 0.99)
	print(string.format(
		"[DRP CLIENT PERF] duration=%.1fs frames=%d avg=%.2fms avg_fps=%.1f p95=%.2fms p99=%.2fms one_percent_low=%.1ffps",
		SysTime() - state.started,
		#state.frames,
		average * 1000,
		average > 0 and 1 / average or 0,
		p95 * 1000,
		p99 * 1000,
		p99 > 0 and 1 / p99 or 0
	))
end

concommand.Add("drp_client_perf_sample", function(_, _, arguments)
	local duration = math.Clamp(tonumber(arguments[1]) or 10, 2, 60)
	local state = { started = SysTime(), endsAt = SysTime() + duration, frames = {} }
	hook.Remove("Think", sampleHook)
	hook.Add("Think", sampleHook, function()
		state.frames[#state.frames + 1] = RealFrameTime()
		if SysTime() >= state.endsAt then finishSample(state) end
	end)
	print(string.format("[DRP CLIENT PERF] sampling %.1f seconds...", duration))
end)

concommand.Add("drp_client_perf_status", function()
	local hooks = hook.GetTable()
	local function count(name)
		local amount = 0
		for _ in pairs(hooks[name] or {}) do amount = amount + 1 end
		return amount
	end
	print(string.format(
		"[DRP CLIENT PERF] resolution=%dx%d fps=%.1f hud=%d postdraw=%d world3d=%d think=%d postprocess=%s",
		Performance.ScreenWidth,
		Performance.ScreenHeight,
		RealFrameTime() > 0 and 1 / RealFrameTime() or 0,
		count("HUDPaint") + count("PostDrawHUD"),
		count("PostDrawHUD"),
		count("PostDrawTranslucentRenderables"),
		count("Think"),
		GetConVar("drp_client_cosmetic_postprocess") and tostring(GetConVar("drp_client_cosmetic_postprocess"):GetBool()) or "not loaded"
	))
end)
