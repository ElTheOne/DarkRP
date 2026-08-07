DRP.Services = DRP.Services or {}

local registry = DRP.Services.Registry or {}
local order = DRP.Services.Order or {}
local started = false
local health = DRP.Services.Health or {}

DRP.Services.Registry = registry
DRP.Services.Order = order
DRP.Services.Health = health

function DRP.Services.Register(name, service)
	assert(isstring(name) and name ~= "", "service name must be a non-empty string")
	assert(istable(service), "service must be a table")
	assert(registry[name] == nil, "duplicate DRP service: " .. name)

	registry[name] = service
	order[#order + 1] = name
	return service
end

function DRP.Services.DependsOn(name, dependencies)
	local service = registry[name]
	assert(istable(service), "cannot declare dependencies for unknown service: " .. tostring(name))
	service.Dependencies = table.Copy(dependencies or {})
	return service
end

function DRP.Services.Get(name)
	return registry[name]
end

function DRP.Services.Validate(required)
	local missing = {}
	for _, requirement in ipairs(required or {}) do
		local name = isstring(requirement) and requirement or requirement.name
		local service = registry[name]
		if not istable(service) then
			missing[#missing + 1] = name
		elseif istable(requirement) then
			for _, method in ipairs(requirement.methods or {}) do
				if not isfunction(service[method]) then missing[#missing + 1] = name .. "." .. method end
			end
		end
	end
	if #missing > 0 then
		ErrorNoHalt("[DRP STARTUP] missing required modules/methods: " .. table.concat(missing, ", ") .. "\n")
		return false, missing
	end
	print(string.format("[DRP STARTUP] validated %d required services", #(required or {})))
	return true, {}
end

function DRP.Services.StartAll()
	if started then return end
	started = true

	local pending={} for _,name in ipairs(order) do pending[name]=true end
	local startedCount=0
	while next(pending) do
		local progressed=false
		for _,name in ipairs(order) do if pending[name] then
			local service=registry[name] local ready,blocked=true,nil
			for _,dependency in ipairs(service.Dependencies or {}) do
				if not registry[dependency] then ready=false blocked="missing dependency '"..dependency.."'" break end
				if pending[dependency] then ready=false break end
				if not health[dependency] or health[dependency].started~=true then ready=false blocked="dependency '"..dependency.."' failed" break end
			end
			if blocked then
				health[name]={started=false,error=blocked,blocked=true} pending[name]=nil progressed=true
				ErrorNoHalt("[DRP STARTUP] service '"..name.."' blocked: "..blocked.."\n")
			elseif ready then
				startedCount=startedCount+1
		local startedAt = SysTime()
		print(string.format("[DRP STARTUP] starting service %02d/%02d %s", startedCount, #order, name))
		local ok, failure = xpcall(function() if service.Start then service:Start() end end, debug.traceback)
		health[name] = { started = ok, error = ok and nil or tostring(failure) }
		if not ok then ErrorNoHalt("[DRP STARTUP] service '" .. name .. "' failed:\n" .. tostring(failure) .. "\n") end
		print(string.format("[DRP STARTUP] %s service %02d/%02d %s (%.2fms)", ok and "started" or "failed ", startedCount, #order, name, (SysTime() - startedAt) * 1000))
				pending[name]=nil progressed=true
			end
		end end
		if not progressed then
			for name in pairs(pending) do health[name]={started=false,error="dependency cycle",blocked=true} ErrorNoHalt("[DRP STARTUP] dependency cycle blocks service '"..name.."'\n") end
			break
		end
	end
end

function DRP.Services.StopAll()
	if not started then return end
	started = false

	for i = #order, 1, -1 do
		local name = order[i]
		local service = registry[name]
		local ok, failure = xpcall(function() if service.Stop then service:Stop() end end, debug.traceback)
		if not ok then ErrorNoHalt("[DRP SHUTDOWN] service '" .. name .. "' failed:\n" .. tostring(failure) .. "\n") end
		health[name] = health[name] or {}
		health[name].stopped = ok
	end
end
