DRP.ClientGovernment = DRP.ClientGovernment or {
	taxRate = 0,
	treasury = 0,
	mayor = NULL,
	allocations = {},
	phase = 0,
	deadline = 0,
	candidates = {},
	keep = 0,
	remove = 0,
	lottery = nil
}

net.Receive("drp_government_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local state = DRP.ClientGovernment
	state.taxRate = net.ReadUInt(6)
	state.treasury = net.ReadUInt(32)
	state.mayor = net.ReadEntity()
	state.allocations = {}
	for _ = 1, net.ReadUInt(4) do state.allocations[net.ReadUInt(8)] = net.ReadUInt(6) end
	state.phase = net.ReadUInt(2)
	state.deadline = CurTime() + net.ReadUInt(16)
	state.candidates = {}
	for index = 1, net.ReadUInt(6) do
		state.candidates[index] = { id = net.ReadString(), name = net.ReadString(), votes = net.ReadUInt(8) }
	end
	state.keep = net.ReadUInt(8)
	state.remove = net.ReadUInt(8)
	if net.ReadBool() then
		state.lottery = { prize = net.ReadUInt(32), deadline = CurTime() + net.ReadUInt(16), entrants = net.ReadUInt(8) }
	else
		state.lottery = nil
	end
	hook.Run("DRPGovernmentChanged", state)
end)
