local sendMessage = "drp_chat_send_v1"
local receiveMessage = "drp_chat_receive_v1"

util.AddNetworkString(sendMessage)
util.AddNetworkString(receiveMessage)

local CHAT_LOCAL = 1
local CHAT_TEAM = 2
local CHAT_GLOBAL = 3
local LOCAL_DISTANCE_SQR = 700 * 700

local ChatServer = {}
DRP.ChatServer = ChatServer

local function recipientsFor(ply, category)
	if category == CHAT_GLOBAL then return DRP.Players.List end

	local recipients = {}
	local origin = ply:GetPos()
	local jobID = ply:DRPJobID()
	for _, target in ipairs(DRP.Players.List) do
		if target:IsPlayer() and (category ~= CHAT_TEAM or target:DRPJobID() == jobID)
			and (category ~= CHAT_LOCAL or target:GetPos():DistToSqr(origin) <= LOCAL_DISTANCE_SQR) then
			recipients[#recipients + 1] = target
		end
	end
	return recipients
end

function ChatServer.Send(ply, category, text)
	if not IsValid(ply) or not ply:DRPReady() then return end
	if not DRP.Net.Allow(ply, "chat_message", 0.65, 5) then return end

	category = math.floor(tonumber(category) or 0)
	text = string.Trim(string.sub(tostring(text or ""), 1, 240))
	if category < CHAT_LOCAL or category > CHAT_GLOBAL or text == "" then return end
	if category == CHAT_LOCAL and DRP.Kidnapping and DRP.Kidnapping:IsGagged(ply) then
		DRP.Net.Notify(ply, "Your gag prevents local speech. Team and global text remain available.", 3)
		return
	end
	local normalized = string.lower(text)
	if normalized == "!admin" or normalized == "!adminmode" or normalized == "adminmode" then
		if DRP.AdminMode then DRP.AdminMode.Toggle(ply) end
		return
	end

	-- Commands continue through PlayerSay so the existing command permission,
	-- rate-limit and audit path remains the single source of truth.
	if string.StartWith(text, "/") then return end

	local recipients = recipientsFor(ply, category)
	if #recipients == 0 then return end

	net.Start(receiveMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(category, 2)
	net.WriteEntity(ply)
	net.WriteString(string.sub(ply:DRPName(), 1, 64))
	net.WriteString(text)
	net.Send(recipients)

	if category == CHAT_GLOBAL and DRP.Trust and DRP.Trust.RelayGlobalChat then
		DRP.Trust:RelayGlobalChat(ply, text)
	end

	if DRP.Audit then
		local labels = { "local", "team", "global" }
		DRP.Audit.Log(ply, "chat_" .. labels[category], nil, text)
	end
end

function ChatServer.SendDiscord(authorName, authorID, text)
	authorName = string.Trim(string.sub(tostring(authorName or ""), 1, 64))
	authorID = string.Trim(string.sub(tostring(authorID or ""), 1, 22))
	text = string.Trim(string.sub(tostring(text or ""), 1, 240))
	if authorName == "" or text == "" or #DRP.Players.List == 0 then return false end

	net.Start(receiveMessage)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(CHAT_GLOBAL, 2)
	net.WriteEntity(NULL)
	net.WriteString("[DISCORD] " .. authorName)
	net.WriteString(text)
	net.Send(DRP.Players.List)

	if DRP.Audit then
		DRP.Audit.Log(nil, "chat_global_discord", authorID ~= "" and authorID or nil, authorName .. ": " .. text)
	end
	return true
end

DRP.Net.Receive(sendMessage, function(_, ply)
	local version = net.ReadUInt(8)
	local category = net.ReadUInt(2)
	local text = net.ReadString()
	if version ~= DRP.ProtocolVersion then return end
	ChatServer.Send(ply, category, text)
end)
