DRP.AdminPermissions = {
	{ key = "panel", label = "Open admin panel" },
	{ key = "users", label = "Manage user ranks" },
	{ key = "kick", label = "Kick players" },
	{ key = "slay", label = "Slay players" },
	{ key = "teleport", label = "Bring and teleport" },
	{ key = "doors", label = "Manage door policy" },
	{ key = "logs", label = "View audit logs" },
	{ key = "jobs", label = "Override job restrictions" },
	{ key = "money", label = "Manage player money" },
	{ key = "experience", label = "Manage player experience" },
	{ key = "props", label = "Manage prop blacklist" },
	{ key = "prop_prices", label = "Manage prop prices" },
	{ key = "warnings", label = "Issue player warnings" },
	{ key = "blacklists", label = "Issue and lift player blacklists" },
	{ key = "server_interactions", label = "Access server interactions" },
	{ key = "adminmode", label = "Use Admin Mode and player controls" },
	{ key = "civic", label = "Manage player civic standing" },
	{ key = "trust", label = "Inspect player trust evidence" }
}

DRP.AdminPermissionBits = {}
DRP.AdminAllPermissions = 0

for index, permission in ipairs(DRP.AdminPermissions) do
	local permissionBit = 2 ^ (index - 1)
	permission.bit = permissionBit
	DRP.AdminPermissionBits[permission.key] = permissionBit
	DRP.AdminAllPermissions = DRP.AdminAllPermissions + permissionBit
end

DRP.AdminActions = {
	{ id = 1, key = "kick", label = "Kick", permission = "kick" },
	{ id = 2, key = "slay", label = "Slay", permission = "slay" },
	{ id = 3, key = "bring", label = "Bring", permission = "teleport" },
	{ id = 4, key = "goto", label = "Go To", permission = "teleport" }
}

DRP.AdminActionByID = {}
for _, action in ipairs(DRP.AdminActions) do DRP.AdminActionByID[action.id] = action end

DRP.AdminModeAction = {
	TOGGLE = 1,
	NOCLIP = 2,
	CLOAK = 3,
	SPECTATE = 4,
	STOP_SPECTATE = 5,
	FREEZE = 6,
	UNFREEZE = 7,
	RESPAWN = 8,
	SET_HEALTH = 9,
	SET_ARMOR = 10,
	STRIP_WEAPONS = 11,
	JAIL = 12,
	UNJAIL = 13,
	TOGGLE_TARGET_MODE = 14,
	RELEASE_ARREST = 15
}

function DRP.AdminMaskHas(mask, permission)
	local permissionBit = DRP.AdminPermissionBits[permission]
	return permissionBit ~= nil and bit.band(tonumber(mask) or 0, permissionBit) ~= 0
end

function DRP.AdminMaskFromKeys(...)
	local mask = 0
	for _, permission in ipairs({ ... }) do
		local permissionBit = DRP.AdminPermissionBits[permission]
		if permissionBit then mask = bit.bor(mask, permissionBit) end
	end
	return mask
end

-- Keys remain lowercase for persistence and networking; labels are the names
-- shown to players. User is normally implicit, but is stored when it carries
-- a persistent Trusted or VIP entitlement.
DRP.AdminRanks = {
	{ key = "owner", label = "Owner", level = 60 },
	{ key = "headadmin", label = "HeadAdmin", level = 50 },
	{ key = "admin", label = "Admin", level = 40 },
	{ key = "moderator", label = "Moderator", level = 30 },
	{ key = "supporter", label = "Supporter", level = 23 },
	{ key = "vipplus", label = "VIP+", level = 22 },
	{ key = "vip", label = "VIP", level = 20 },
	{ key = "trusted", label = "Trusted", level = 10 },
	{ key = "user", label = "User", level = 0 }
}

DRP.AdminRankByKey = {}
for _, rank in ipairs(DRP.AdminRanks) do DRP.AdminRankByKey[rank.key] = rank end

function DRP.AdminRank(rankKey)
	return DRP.AdminRankByKey[string.lower(tostring(rankKey or ""))] or DRP.AdminRankByKey.user
end

function DRP.AdminRankLabel(rankKey)
	return DRP.AdminRank(rankKey).label
end

function DRP.AdminRankLevel(rankKey)
	return DRP.AdminRank(rankKey).level
end

function DRP.RankHasVIPBenefits(rankKey)
	rankKey = DRP.AdminRank(rankKey).key
	return rankKey == "vip" or rankKey == "vipplus" or rankKey == "supporter"
		or rankKey == "headadmin" or rankKey == "owner"
end

DRP.AdminDefaultRankMasks = {
	owner = DRP.AdminAllPermissions,
	headadmin = DRP.AdminAllPermissions,
	admin = DRP.AdminMaskFromKeys("panel", "kick", "slay", "teleport", "doors", "logs", "jobs", "money", "experience", "civic", "trust", "prop_prices", "warnings", "blacklists", "adminmode"),
	moderator = DRP.AdminMaskFromKeys("panel", "kick", "slay", "teleport", "logs", "warnings", "adminmode"),
	trusted = 0,
	vip = 0,
	vipplus = 0,
	supporter = 0,
	user = 0
}

function DRP.AdminCanSetRank(actorRank, targetRank, newRank)
	actorRank = DRP.AdminRank(actorRank)
	targetRank = DRP.AdminRank(targetRank)
	newRank = DRP.AdminRank(newRank)
	if actorRank.key == "owner" then
		return targetRank.key ~= "owner" and newRank.key ~= "owner"
	end
	return actorRank.key == "headadmin"
		and targetRank.level < actorRank.level
		and newRank.level < actorRank.level
end
