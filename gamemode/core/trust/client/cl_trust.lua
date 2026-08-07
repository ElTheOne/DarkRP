net.Receive("drp_trust_announce_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local name = string.sub(net.ReadString(), 1, 64)
	local score = net.ReadUInt(7)
	local known = net.ReadUInt(4)
	local label = string.sub(net.ReadString(), 1, 32)
	local message = string.format("%s joined — Trust %d/100 · %s (%d/8 signals verified).", name, score, label, known)
	local kind = score >= 65 and 1 or (score >= 45 and 2 or 3)
	if DRP.Chat and DRP.Chat.System then DRP.Chat.System(message, kind) else chat.AddText(Color(74, 205, 255), "[TRUST] ", color_white, message) end
end)

net.Receive("drp_trust_link_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local botMode = net.ReadBool()
	local value = string.sub(net.ReadString(), 1, 1024)
	local fallbackURL = string.sub(net.ReadString(), 1, 1024)
	if value == "" then return end
	DRP.TrustUI = DRP.TrustUI or {}
	DRP.TrustUI.LinkPending = true
	if DRP.TrustUI.RefreshSelf then DRP.TrustUI.RefreshSelf() end
	if botMode then
		local command = "/link code:" .. value
		SetClipboardText(command)
		if fallbackURL ~= "" then gui.OpenURL(fallbackURL) end
		local message = "Discord verification command copied: " .. command
			.. ". The DarkRP channel is opening now; paste the command there."
		if DRP.Chat and DRP.Chat.System then DRP.Chat.System(message, 0) else chat.AddText(Color(74, 205, 255), "[DISCORD] ", color_white, message) end
		notification.AddLegacy("Discord command copied: " .. command, NOTIFY_HINT, 10)
		return
	end
	SetClipboardText(value)
	if DRP.Chat and DRP.Chat.System then
		DRP.Chat.System("Discord browser verification was copied. Paste it into Safari or your normal browser, then return and use /discordverify.", 0)
	end
	notification.AddLegacy("Discord verification URL copied — open it in Safari", NOTIFY_HINT, 10)
end)

net.Receive("drp_trust_invite_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local inviteURL = string.sub(net.ReadString(), 1, 1024)
	if inviteURL == "" then return end
	DRP.TrustUI = DRP.TrustUI or {}
	DRP.TrustUI.LinkPending = true
	if DRP.TrustUI.RefreshSelf then DRP.TrustUI.RefreshSelf() end
	SetClipboardText(inviteURL)
	gui.OpenURL(inviteURL)
	local message = "Discord invite copied and opened. Join the server, then return in game and use /discordverify."
	if DRP.Chat and DRP.Chat.System then DRP.Chat.System(message, 0) else chat.AddText(Color(74, 205, 255), "[DISCORD] ", color_white, message) end
	notification.AddLegacy("Discord invite copied — join, then use /discordverify", NOTIFY_HINT, 10)
end)

DRP.TrustUI = DRP.TrustUI or {}

function DRP.TrustUI.Request(steamID64)
	net.Start("drp_trust_inspect_request_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteString(string.sub(tostring(steamID64 or ""), 1, 20))
	net.SendToServer()
end

local selfPanel
local ACTION_REFRESH, ACTION_DISCORD_LINK, ACTION_DISCORD_VERIFY = 1, 2, 3

local function selfAction(action)
	net.Start("drp_trust_self_action_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(action, 2)
	net.SendToServer()
end

local function hoursText(seconds)
	local hours = math.max(0, tonumber(seconds) or 0) / 3600
	if hours < 1 then return string.format("%.1f hours", hours) end
	return string.Comma(math.floor(hours)) .. " hours"
end

local function signalRows(data)
	local colors = DRP.UI.Colors
	local rows = {
		{
			title = "RETURNING PLAYER",
			value = data.returning and "VERIFIED" or "NEW PLAYER",
			detail = data.returning and "This Steam account has completed a previous server session."
				or "This is the account's first recorded session; this resolves automatically after playing.",
			color = data.returning and colors.green or colors.accent
		},
		{
			title = "SERVER PLAYTIME",
			value = string.upper(hoursText(data.serverSeconds)),
			detail = "Trust grows naturally with active, persistent playtime on this server.",
			color = data.serverSeconds >= 7200 and colors.green or colors.accent
		}
	}

	rows[#rows + 1] = {
		title = "SERVER RANK",
		value = data.trustedRank and "TRUSTED+" or "STANDARD",
		detail = data.trustedRank and "A staff-assigned Trusted or higher rank contributes to this score."
			or "Trusted status is awarded through the server's normal rank process.",
		color = data.trustedRank and colors.green or colors.muted
	}

	if not data.steamAvailable then
		rows[#rows + 1] = {
			title = "GARRY'S MOD HISTORY",
			value = "UNAVAILABLE",
			detail = "The server has not configured Steam Web API checks.",
			color = colors.muted
		}
	elseif data.steamOwnedKnown and data.gmodVisible then
		rows[#rows + 1] = {
			title = "GARRY'S MOD HISTORY",
			value = string.upper(hoursText(data.gmodMinutes * 60)),
			detail = "Public Steam playtime was verified through the Steam Web API.",
			color = data.gmodMinutes >= 6000 and colors.green or colors.accent
		}
	else
		rows[#rows + 1] = {
			title = "GARRY'S MOD HISTORY",
			value = "NOT VISIBLE",
			detail = "Click to review Steam game-detail privacy, then use RECHECK below.",
			color = colors.purple,
			action = "steam_privacy",
			actionLabel = "OPEN PRIVACY"
		}
	end

	if not data.steamAvailable then
		rows[#rows + 1] = {
			title = "STEAM LIBRARY",
			value = "UNAVAILABLE",
			detail = "The server has not configured Steam library checks.",
			color = colors.muted
		}
	elseif data.steamOwnedKnown then
		local onlyGMod = data.steamGameCount == 1
		rows[#rows + 1] = {
			title = "STEAM LIBRARY",
			value = onlyGMod and "ONLY GMOD VISIBLE" or (string.Comma(data.steamGameCount) .. " GAMES"),
			detail = onlyGMod and "Only Garry's Mod is visible on this Steam account."
				or "An established public Steam library is visible.",
			color = onlyGMod and colors.red or colors.green
		}
	else
		rows[#rows + 1] = {
			title = "STEAM LIBRARY",
			value = "NOT CHECKED",
			detail = "Click to make game details public, then use RECHECK below.",
			color = colors.purple,
			action = "steam_privacy",
			actionLabel = "OPEN PRIVACY"
		}
	end

	rows[#rows + 1] = {
		title = "ACCOUNT BANS",
		value = not data.steamAvailable and "UNAVAILABLE" or (data.vacKnown and ((data.vacBans + data.gameBans) == 0 and "CLEAR"
			or (data.vacBans .. " VAC / " .. data.gameBans .. " GAME")) or "PENDING"),
		detail = not data.steamAvailable and "The server has not configured Steam ban checks."
			or (data.vacKnown and ((data.vacBans + data.gameBans) == 0 and "No VAC or game bans were reported."
			or ("Last reported ban was " .. data.daysSinceBan .. " days ago."))
			or "Steam has not returned the ban check yet; use RECHECK below."),
		color = data.steamAvailable and data.vacKnown
			and ((data.vacBans + data.gameBans) == 0 and colors.green or colors.red) or colors.muted
	}

	rows[#rows + 1] = {
		title = "NETWORK REPUTATION",
		value = not data.vpnAvailable and "UNAVAILABLE"
			or (data.vpnKnown and (data.vpnDetected and "VPN / PROXY" or "ORDINARY") or "PENDING"),
		detail = not data.vpnAvailable and "The server has not configured network reputation checks."
			or (data.vpnKnown and (data.vpnDetected
			and "Disable the VPN or proxy, reconnect, then request another check."
			or "No VPN or proxy was detected by the configured provider.")
			or "The network reputation provider has not completed this signal."),
		color = data.vpnAvailable and data.vpnKnown
			and (data.vpnDetected and colors.red or colors.green) or colors.muted
	}

	local pending = DRP.TrustUI.LinkPending == true and not data.discordLinked
	rows[#rows + 1] = {
		title = "DISCORD IDENTITY",
		value = data.discordLinked and "VERIFIED" or (not data.discordAvailable and "UNAVAILABLE"
			or (pending and "AWAITING VERIFICATION" or "NOT LINKED")),
		detail = data.discordLinked and ("Linked as " .. (data.discordName ~= "" and data.discordName or data.discordID) .. ".")
			or (not data.discordAvailable and "Discord verification is not configured by the server."
				or (pending and "Click VERIFY to generate a code; the DarkRP channel will open with the command copied."
					or "Click LINK to join Discord, then return and use /discordverify.")),
		color = data.discordLinked and colors.green or colors.purple,
		action = (data.discordLinked or not data.discordAvailable) and nil
			or (pending and ACTION_DISCORD_VERIFY or ACTION_DISCORD_LINK),
		actionLabel = (data.discordLinked or not data.discordAvailable) and nil
			or (pending and "VERIFY" or "LINK")
	}
	return rows
end

local function paintSelfPanel(panel, width, height)
	local colors = DRP.UI.Colors
	draw.RoundedBox(11, 0, 0, width, height, Color(8, 13, 25, 247))
	draw.RoundedBoxEx(11, 0, 0, 5, height, colors.accent, true, false, true, false)
	draw.SimpleText("TRUST CHECK", "DRP.Admin.Header", 20, 22, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText((panel.Data.label or "UNVERIFIED") .. "  •  " .. panel.Data.score .. "/100  •  "
			.. panel.Data.known .. "/8",
		"DRP.Admin.Small", width - 18, 22,
		panel.Data.score >= 65 and colors.green or (panel.Data.score >= 45 and colors.accent or colors.red),
		TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	draw.SimpleText("Click available checks after enabling cursor mode with F3 or Z.",
		"DRP.Admin.Small", 20, 46, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	local remaining = math.max(0, math.ceil((panel.ExpiresAt or RealTime()) - RealTime()))
	draw.SimpleText(remaining .. "s", "DRP.Admin.Small", width - 18, 46, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
end

local function rebuildSelfPanel(panel)
	if not IsValid(panel) or not panel.Data then return end
	if IsValid(panel.Rows) then panel.Rows:Remove() end
	local colors = DRP.UI.Colors
	local rows = vgui.Create("DScrollPanel", panel)
	panel.Rows = rows
	rows:SetPos(14, 66)
	rows:SetSize(panel:GetWide() - 28, panel:GetTall() - 116)

	for _, signal in ipairs(signalRows(panel.Data)) do
		local entry = signal
		local row = vgui.Create("DButton", rows)
		row:Dock(TOP)
		row:DockMargin(0, 0, 0, 6)
		row:SetTall(57)
		row:SetText("")
		row:SetCursor(entry.action and "hand" or "arrow")
		row.Paint = function(button, width, height)
			draw.RoundedBox(8, 0, 0, width, height,
				entry.action and button:IsHovered() and colors.panelHover or colors.panel)
			draw.RoundedBoxEx(8, 0, 0, 4, height, entry.color, true, false, true, false)
			draw.SimpleText(entry.title, "DRP.Admin.Small", 14, 16, entry.color, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(entry.detail, "DRP.Admin.Small", 14, 40, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(entry.actionLabel or entry.value, "DRP.Admin.Small", width - 14, 16,
				entry.action and colors.accent or color_white, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
		row.DoClick = function()
			if entry.action == "steam_privacy" then
				gui.OpenURL("https://steamcommunity.com/my/edit/settings")
			elseif isnumber(entry.action) then
				selfAction(entry.action)
			end
		end
	end
end

function DRP.TrustUI.ShowSelf(data, resetDuration)
	DRP.TrustUI.LastSelf = data
	if not IsValid(selfPanel) then
		selfPanel = vgui.Create("DPanel")
		selfPanel:SetSize(math.min(510, ScrW() - 30), math.min(540, ScrH() - 150))
		selfPanel:SetPos(ScrW() - selfPanel:GetWide() - 24, 116)
		selfPanel:SetMouseInputEnabled(true)
		selfPanel:SetKeyboardInputEnabled(false)
		selfPanel.Paint = paintSelfPanel
		selfPanel.Think = function(panel)
			if RealTime() >= (panel.ExpiresAt or 0) then panel:Remove() end
		end

		local refresh = DRP.UI.Button(selfPanel, "RECHECK AUTOMATIC SIGNALS", DRP.UI.Colors.accent, function()
			selfAction(ACTION_REFRESH)
		end)
		refresh:SetPos(14, selfPanel:GetTall() - 42)
		refresh:SetSize(selfPanel:GetWide() - 72, 32)

		local close = DRP.UI.Button(selfPanel, "×", DRP.UI.Colors.red, function() selfPanel:Remove() end)
		close:SetPos(selfPanel:GetWide() - 50, selfPanel:GetTall() - 42)
		close:SetSize(36, 32)
	end
	selfPanel.Data = data
	if resetDuration or not selfPanel.ExpiresAt then selfPanel.ExpiresAt = RealTime() + 60 end
	rebuildSelfPanel(selfPanel)
end

function DRP.TrustUI.RefreshSelf()
	if IsValid(selfPanel) and DRP.TrustUI.LastSelf then
		rebuildSelfPanel(selfPanel)
	end
end

net.Receive("drp_trust_self_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local show = net.ReadBool()
	local data = {
		score = net.ReadUInt(7),
		known = net.ReadUInt(4),
		label = net.ReadString(),
		steamAvailable = net.ReadBool(),
		vpnAvailable = net.ReadBool(),
		discordAvailable = net.ReadBool(),
		serverSeconds = net.ReadUInt(32),
		returning = net.ReadBool(),
		trustedRank = net.ReadBool(),
		steamOwnedKnown = net.ReadBool(),
		gmodVisible = net.ReadBool(),
		gmodMinutes = net.ReadUInt(32),
		steamGameCount = net.ReadUInt(16),
		vacKnown = net.ReadBool(),
		vacBans = net.ReadUInt(8),
		gameBans = net.ReadUInt(8),
		daysSinceBan = net.ReadUInt(16),
		vpnKnown = net.ReadBool(),
		vpnDetected = net.ReadBool(),
		discordLinked = net.ReadBool(),
		discordPending = net.ReadBool(),
		discordName = net.ReadString(),
		discordID = net.ReadString()
	}
	DRP.TrustUI.LinkPending = data.discordPending and not data.discordLinked
	if show or IsValid(selfPanel) then DRP.TrustUI.ShowSelf(data, show) else DRP.TrustUI.LastSelf = data end
end)

concommand.Add("drp_trust_panel", function()
	if DRP.TrustUI.LastSelf then DRP.TrustUI.ShowSelf(DRP.TrustUI.LastSelf, true) end
end)

net.Receive("drp_trust_inspect_response_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local found = net.ReadBool()
	local steamID64 = net.ReadString()
	local name = net.ReadString()
	if not found then
		notification.AddLegacy("No stored trust profile exists for " .. name .. ".", NOTIFY_ERROR, 6)
		return
	end

	local score = net.ReadUInt(7)
	local known = net.ReadUInt(4)
	local label = net.ReadString()
	local updatedAt = net.ReadUInt(32)
	local discordLinked = net.ReadBool()
	local discordName = net.ReadString()
	local discordID = net.ReadString()
	local reasons = {}
	for index = 1, net.ReadUInt(4) do reasons[index] = net.ReadString() end

	local UI = DRP.UI
	local colors = UI.Colors
	local frame = UI.Frame("Trust Evidence · " .. name, 680, 590)

	local header = vgui.Create("DPanel", frame)
	header:SetPos(16, 70)
	header:SetSize(frame:GetWide() - 32, 118)
	header.Paint = function(_, width, height)
		draw.RoundedBox(10, 0, 0, width, height, colors.panel)
		draw.RoundedBoxEx(10, 0, 0, 6, height, score >= 65 and colors.green or (score >= 45 and colors.accent or colors.red), true, false, true, false)
		draw.SimpleText(name, "DRP.Admin.Title", 22, 24, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(steamID64, "DRP.Admin.Small", 22, 52, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(score .. "/100", "DRP.Admin.Title", width - 22, 30, score >= 65 and colors.green or (score >= 45 and colors.accent or colors.red), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		draw.SimpleText(label .. " · " .. known .. "/8 signals", "DRP.Admin.Small", width - 22, 61, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		local discordText = discordLinked and ("Discord: " .. (discordName ~= "" and discordName or discordID) .. " · " .. discordID) or "Discord: not linked"
		draw.SimpleText(discordText, "DRP.Admin.Small", 22, 91, discordLinked and colors.accent or colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local scroll = vgui.Create("DScrollPanel", frame)
	scroll:SetPos(16, 200)
	scroll:SetSize(frame:GetWide() - 32, frame:GetTall() - 216)

	local summary = vgui.Create("DPanel", scroll)
	summary:Dock(TOP)
	summary:DockMargin(0, 0, 0, 8)
	summary:SetTall(58)
	summary.Paint = function(_, width, height)
		draw.RoundedBox(8, 0, 0, width, height, colors.panel)
		draw.SimpleText("CONTRIBUTING SIGNALS", "DRP.Admin.Small", 16, 17, colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		local updated = updatedAt > 0 and os.date("%d %b %Y · %H:%M", updatedAt) or "Never"
		draw.SimpleText("Last calculated: " .. updated, "DRP.Admin.Small", 16, 40, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	for _, reason in ipairs(reasons) do
		local contribution = reason
		local row = vgui.Create("DPanel", scroll)
		row:Dock(TOP)
		row:DockMargin(0, 0, 0, 6)
		row:SetTall(45)
		row.Paint = function(_, width, height)
			local contributionColor = string.find(contribution, "%+%d") and colors.green
				or (string.find(contribution, "%-%d") and colors.red or colors.muted)
			draw.RoundedBox(7, 0, 0, width, height, colors.panel)
			draw.RoundedBoxEx(7, 0, 0, 4, height, contributionColor, true, false, true, false)
			draw.SimpleText(contribution, "DRP.Admin.Body", 16, height * 0.5, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end

	if #reasons == 0 then
		local empty = vgui.Create("DLabel", scroll)
		empty:Dock(TOP)
		empty:SetTall(42)
		empty:SetFont("DRP.Admin.Body")
		empty:SetTextColor(colors.muted)
		empty:SetContentAlignment(5)
		empty:SetText("No contribution details were stored for this profile.")
	end
end)
