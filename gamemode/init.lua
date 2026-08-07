AddCSLuaFile("core/bootstrap/sh_manifest.lua")
local manifest = include("core/bootstrap/sh_manifest.lua")

AddCSLuaFile("shared.lua")
for _, group in ipairs({ manifest.Shared, manifest.ClientShared, manifest.Client, manifest.ClientSubmodules, manifest.ClientResources }) do
	for index = 1, #group do AddCSLuaFile(group[index]) end
end

include("shared.lua")
for index = 1, #manifest.ServerPreload do include(manifest.ServerPreload[index]) end

for index = 1, #manifest.Server do
	local path = manifest.Server[index]
	local started = SysTime()
	print(string.format("[DRP STARTUP] loading %02d/%02d %s", index, #manifest.Server, path))
	include(path)
	print(string.format("[DRP STARTUP] loaded  %02d/%02d %s (%.2fms)", index, #manifest.Server, path, (SysTime() - started) * 1000))
end
