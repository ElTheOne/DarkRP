DRP.Supporter = DRP.Supporter or {}

local Supporter = DRP.Supporter

if DRP.Services and not DRP.Services.Get("supporter") then DRP.Services.Register("supporter", Supporter) end

Supporter.Tiers = {
	[0] = { key = "none", label = "None", multiplier = 1, entityBonus = 0, propertyLimit = 1 },
	[1] = { key = "vip", label = "VIP", multiplier = 1.25, entityBonus = 0, propertyLimit = 1 },
	[2] = { key = "vipplus", label = "VIP+", multiplier = 1.5, entityBonus = 20, propertyLimit = 2 },
	[3] = { key = "supporter", label = "Supporter", multiplier = 2, entityBonus = 40, propertyLimit = 3 }
}

Supporter.ByKey = {}
for tier, definition in pairs(Supporter.Tiers) do Supporter.ByKey[definition.key] = tier end
Supporter.ByKey["vip+"] = 2

function Supporter.Normalize(value)
	if isstring(value) then value = Supporter.ByKey[string.lower(string.Trim(value))] end
	return math.Clamp(math.floor(tonumber(value) or 0), 0, 3)
end

function Supporter.Definition(value)
	return Supporter.Tiers[Supporter.Normalize(value)]
end

function Supporter.Tier(value)
	if CLIENT and (value == LocalPlayer() or value == nil) then return Supporter.Normalize(DRP.ClientSupporterTier) end
	if SERVER and DRP.Admin and DRP.Admin.Record then
		local record = DRP.Admin.Record(value)
		if record then return Supporter.Normalize(record.supporter_tier) end
	end
	return 0
end

function Supporter.RewardMultiplier(value) return Supporter.Definition(Supporter.Tier(value)).multiplier end
function Supporter.EntityBonus(value) return Supporter.Definition(Supporter.Tier(value)).entityBonus end
function Supporter.PropertyLimit(value) return Supporter.Definition(Supporter.Tier(value)).propertyLimit end

function Supporter.ApplyReward(value, amount)
	amount = math.max(0, tonumber(amount) or 0)
	return math.floor(amount * Supporter.RewardMultiplier(value))
end

function Supporter.ApplyRollCount(value, amount)
	amount = math.max(0, tonumber(amount) or 0)
	return math.ceil(amount * Supporter.RewardMultiplier(value))
end
