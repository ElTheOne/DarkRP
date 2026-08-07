DRP.Profile = DRP.Profile or {}

local enabled = CreateConVar("drp_profile", "0", FCVAR_ARCHIVE, "Collect DarkRP foundation timings", 0, 1)
local metrics = {}
local sampleLimit = 1024

local function metric(name)
	local value = metrics[name]
	if value then return value end

	value = { count = 0, total = 0, max = 0, slow = 0, samples = {}, cursor = 0 }
	metrics[name] = value
	return value
end

function DRP.Profile.Begin()
	if not enabled:GetBool() then return nil end
	return SysTime()
end

function DRP.Profile.Record(name, elapsed)
	if not enabled:GetBool() then return end
	elapsed = math.max(0, tonumber(elapsed) or 0)
	local value = metric(name)
	value.count = value.count + 1
	value.total = value.total + elapsed
	value.max = math.max(value.max, elapsed)
	if elapsed >= 5 then value.slow = value.slow + 1 end
	value.cursor = (value.cursor % sampleLimit) + 1
	value.samples[value.cursor] = elapsed
end

function DRP.Profile.Finish(name, started)
	if not started then return end
	DRP.Profile.Record(name, (SysTime() - started) * 1000)
end

local function percentile(samples, fraction)
	if #samples == 0 then return 0 end
	local copy = table.Copy(samples)
	table.sort(copy)
	return copy[math.max(1, math.ceil(#copy * fraction))]
end

concommand.Add("drp_profile_report", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsAdmin(ply)) then return end

	print("[DRP] profile report")
	for name, value in pairs(metrics) do
		print(string.format("  %s count=%d avg=%.4fms p95=%.4fms p99=%.4fms max=%.4fms over5ms=%d", name, value.count, value.total / math.max(1, value.count), percentile(value.samples, 0.95), percentile(value.samples, 0.99), value.max, value.slow))
	end
	print(string.format("  lua_memory=%.1fKB", collectgarbage("count")))
end)

concommand.Add("drp_profile_reset", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsAdmin(ply)) then return end
	metrics = {}
	print("[DRP] profile metrics reset")
end)
