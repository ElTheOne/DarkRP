DRP.State = {
	LOADING = 0,
	PERSISTENT = 1,
	EPHEMERAL = 2,
	READY = 3
}

DRP.StateName = {
	[0] = "LOADING",
	[1] = "PERSISTENT",
	[2] = "EPHEMERAL",
	[3] = "READY"
}

if CLIENT then
	DRP.ClientState = DRP.ClientState or DRP.State.LOADING
end

local playerMeta = FindMetaTable("Player")

function playerMeta:DRPState()
	if SERVER then return self.DRPLifecycleState or DRP.State.LOADING end
	if self == LocalPlayer() then return DRP.ClientState end
	return DRP.State.LOADING
end

function playerMeta:DRPReady()
	local state = self:DRPState()
	return state == DRP.State.PERSISTENT or state == DRP.State.EPHEMERAL or state == DRP.State.READY
end

function playerMeta:DRPPersistent()
	return self:DRPState() == DRP.State.PERSISTENT
end
