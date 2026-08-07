local Players = {
	BySteamID = {},
	List = {},
	ListIndex = setmetatable({}, { __mode = "k" })
}

DRP.Players = Players
DRP.Services.Register("players", Players)

local function index(ply)
	if not IsValid(ply) or not ply:IsPlayer() or ply:IsBot() then return end
	local steamID64 = ply:SteamID64()
	if steamID64 and steamID64 ~= "" and steamID64 ~= "0" then Players.BySteamID[steamID64] = ply end
	if not Players.ListIndex[ply] then
		Players.List[#Players.List + 1] = ply
		Players.ListIndex[ply] = #Players.List
	end
end

function Players.Online(steamID64)
	local ply = Players.BySteamID[tostring(steamID64 or "")]
	return IsValid(ply) and ply or nil
end

function Players:Start()
	self.BySteamID = {}
	self.List = {}
	self.ListIndex = setmetatable({}, { __mode = "k" })
	for _, ply in player.Iterator() do index(ply) end
end

function Players:Stop()
	self.BySteamID, self.List = {}, {}
	self.ListIndex = setmetatable({}, { __mode = "k" })
end

hook.Add("PlayerInitialSpawn", "DRP.Players.Index", index)
hook.Add("PlayerAuthed", "DRP.Players.AuthenticatedIndex", index)
hook.Add("PlayerDisconnected", "DRP.Players.Unindex", function(ply)
	local steamID64 = ply:SteamID64()
	if Players.BySteamID[steamID64] == ply then Players.BySteamID[steamID64] = nil end
	local position = Players.ListIndex[ply]
	if position then
		local last = table.remove(Players.List)
		Players.ListIndex[ply] = nil
		if last and last ~= ply then Players.List[position] = last Players.ListIndex[last] = position end
	end
end)
