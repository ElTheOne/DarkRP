local manifest = include("core/bootstrap/sh_manifest.lua")
include("shared.lua")
for index = 1, #manifest.ClientShared do include(manifest.ClientShared[index]) end
for index = 1, #manifest.Client do include(manifest.Client[index]) end
for index = 1, #manifest.ClientSubmodules do include(manifest.ClientSubmodules[index]) end
