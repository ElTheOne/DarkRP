local ZeroAddons = {
	Workshop = {
		zclib = "2532060111",
		weedContent = "1741741175",
		methContent = "2486834214"
	},
	CompatibilityApplied = false
}

DRP.ZeroAddons = ZeroAddons
DRP.Services.Register("zero_addons", ZeroAddons)

for _, workshopID in pairs(ZeroAddons.Workshop) do resource.AddWorkshop(workshopID) end

local function cleanMoney(amount)
	return math.max(0, math.floor(tonumber(amount) or 0))
end

local rankAliases = {
	root = 60,
	owner = 60,
	superadmin = 60,
	headadmin = 50,
	head_admin = 50,
	admin = 40,
	moderator = 30,
	mod = 30,
	vip = 20,
	vipplus = 22,
	supporter = 23,
	trusted = 10,
	user = 0,
	default = 0
}

local function cleanRankKey(value)
	return string.lower(string.Trim(tostring(value or "")))
end

function ZeroAddons:RankCheck(ply, ranks)
	if not IsValid(ply) or not istable(ranks) then return false end
	if table.Count(ranks) == 0 then return true end
	local playerKey = cleanRankKey(ply.DRPRank and ply:DRPRank() or ply:GetUserGroup())
	local baseKey = DRP.Admin and DRP.Admin.BaseRankKey and DRP.Admin.BaseRankKey(ply) or playerKey
	local playerLevel = DRP.AdminRankLevel and DRP.AdminRankLevel(baseKey) or (rankAliases[baseKey] or 0)
	for key, value in pairs(ranks) do
		local required = isnumber(key) and value or key
		local requiredKey = cleanRankKey(required)
		local requiredLevel = rankAliases[requiredKey]
		if requiredKey == "vip" then
			if DRP.Admin and DRP.Admin.HasVIP and DRP.Admin.HasVIP(ply) then return true end
		elseif requiredKey == "trusted" then
			if DRP.Admin and DRP.Admin.HasTrusted and DRP.Admin.HasTrusted(ply) then return true end
		elseif requiredLevel ~= nil and playerLevel >= requiredLevel then
			return true
		end
		if requiredKey ~= "" and requiredKey == baseKey then return true end
		-- Preserve compatibility with an unknown rank supplied by another admin
		-- system without letting it replace the DRP hierarchy above.
		if requiredKey ~= "" and isfunction(ply.IsUserGroup) and ply:IsUserGroup(requiredKey) then return true end
	end
	return false
end

function ZeroAddons:ApplyCompatibility()
	if not zclib then return false, "zcLib is not mounted" end
	zclib.Money = zclib.Money or {}
	zclib.Money.Has = function(ply, amount)
		return IsValid(ply) and ply:DRPMoney() >= cleanMoney(amount)
	end
	zclib.Money.Give = function(ply, amount)
		if not IsValid(ply) then return false end
		return DRP.Economy.Set(ply, ply:DRPMoney() + cleanMoney(amount))
	end
	zclib.Money.Take = function(ply, amount)
		if not IsValid(ply) then return false end
		amount = cleanMoney(amount)
		if ply:DRPMoney() < amount then return false end
		return DRP.Economy.Set(ply, ply:DRPMoney() - amount)
	end
	zclib.Player = zclib.Player or {}
	zclib.Player.GetJob = function(ply)
		return IsValid(ply) and ply:DRPJobID() or DRP.Job.CITIZEN
	end
	zclib.Player.GetRank = function(ply)
		return IsValid(ply) and ply:DRPRank() or "user"
	end
	zclib.Player.RankCheck = function(ply, ranks)
		return self:RankCheck(ply, ranks)
	end
	-- Zero's Weed Farm carries its own rank helpers instead of consistently
	-- using zcLib.  Bridge both APIs to the same DRP rank authority.
	if zwf and zwf.f then
		zwf.f.GetPlayerRank = function(ply)
			return IsValid(ply) and ply:DRPRank() or "user"
		end
		zwf.f.PlayerRankCheck = function(ply, ranks)
			return self:RankCheck(ply, ranks)
		end
	end
	self.CompatibilityApplied = true
	return true
end

function ZeroAddons:Status()
	return {
		weed = zwf ~= nil and zwf.config ~= nil and zwf.f ~= nil,
		meth = zmlab2 ~= nil and zmlab2.config ~= nil and zmlab2.Tent ~= nil,
		zclib = zclib ~= nil,
		models = util.IsValidModel("models/zerochain/props_methlab/zmlab2_tentkit.mdl")
			and util.IsValidModel("models/zerochain/props_weedfarm/zwf_generator.mdl"),
		compatibility = self.CompatibilityApplied
	}
end

function ZeroAddons:Start()
	timer.Simple(1, function()
		local ok, reason = self:ApplyCompatibility()
		local status = self:Status()
		local level = ok and "READY" or "BLOCKED"
		print(string.format("[DRP ZERO] %s weed=%s meth=%s zclib=%s models=%s compatibility=%s%s", level, tostring(status.weed), tostring(status.meth), tostring(status.zclib), tostring(status.models), tostring(status.compatibility), reason and (" reason=" .. reason) or ""))
		if not status.weed then ErrorNoHalt("[DRP ZERO] Zero's Weed Farm source did not initialize.\n") end
		if not status.meth then ErrorNoHalt("[DRP ZERO] Zero's MethLab 2 source did not initialize.\n") end
		if not status.zclib then ErrorNoHalt("[DRP ZERO] Add Workshop 2532060111 (zcLib) to the server collection.\n") end
		if not status.models then ErrorNoHalt("[DRP ZERO] Weed/Meth content models are not mounted on the server.\n") end
	end)

	hook.Add("zwf_OnWeedSold", "DRP.ZeroAddons.WeedSold", function(ply, _, earning, blockCount)
		if not IsValid(ply) then return end
		local ordinary = cleanMoney(earning)
		local rewarded = DRP.Supporter and DRP.Supporter.ApplyReward(ply, ordinary) or ordinary
		if rewarded > ordinary then DRP.Economy.Add(ply, rewarded - ordinary, "supporter cannabis-sale bonus") end
		local penalty = -math.Clamp(math.ceil((tonumber(blockCount) or 1) / 2), 2, 15)
		if DRP.Civic then DRP.Civic:Adjust(ply, penalty, "sold cannabis") end
		if DRP.Roles then DRP.Roles:Record(ply, "narcotics", math.Clamp(math.ceil((tonumber(blockCount) or 1) / 2), 1, 8), "cannabis trade") end
		if DRP.Audit then DRP.Audit.Log(ply, "weed_sold", nil, string.format("blocks=%d value=$%d", tonumber(blockCount) or 0, tonumber(earning) or 0)) end
	end)

	hook.Add("zmlab2_PostMethSell", "DRP.ZeroAddons.MethSold", function(ply, earning, methList)
		if not IsValid(ply) then return end
		local ordinary = cleanMoney(earning)
		local rewarded = DRP.Supporter and DRP.Supporter.ApplyReward(ply, ordinary) or ordinary
		if rewarded > ordinary then DRP.Economy.Add(ply, rewarded - ordinary, "supporter meth-sale bonus") end
		local batches = istable(methList) and table.Count(methList) or 1
		local penalty = -math.Clamp(batches * 3, 5, 25)
		if DRP.Civic then DRP.Civic:Adjust(ply, penalty, "sold methamphetamine") end
		if DRP.Roles then DRP.Roles:Record(ply, "narcotics", math.Clamp(batches * 2, 2, 12), "methamphetamine trade") end
		if DRP.Audit then DRP.Audit.Log(ply, "meth_sold", nil, string.format("batches=%d value=$%d", batches, tonumber(earning) or 0)) end
	end)
end

function ZeroAddons:Stop()
	timer.Remove("DRP.ZeroAddons.Compatibility")
	hook.Remove("zwf_OnWeedSold", "DRP.ZeroAddons.WeedSold")
	hook.Remove("zmlab2_PostMethSell", "DRP.ZeroAddons.MethSold")
end

concommand.Add("drp_zero_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local status = ZeroAddons:Status()
	local message = string.format("weed=%s meth=%s zclib=%s models=%s compatibility=%s", tostring(status.weed), tostring(status.meth), tostring(status.zclib), tostring(status.models), tostring(status.compatibility))
	print("[DRP ZERO] " .. message)
	if IsValid(ply) then DRP.Net.Notify(ply, message, status.weed and status.meth and status.models and status.compatibility and 1 or 3) end
end)
