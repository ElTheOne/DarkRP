local SYNC = "drp_objectives_sync_v1"
local ACTION = "drp_objectives_action_v1"
local ROLE_ACTION = "drp_objective_role_action_v1"
local POPUP = "drp_objective_popup_v1"

DRP.ObjectivesClient = DRP.ObjectivesClient or {
	Offers = {},
	Active = {},
	RoleGoal = nil,
	Guide = { completed = 0, total = 0, current = "" },
	Received = false
}

local Client = DRP.ObjectivesClient
local showWelcome, enqueuePopup
local objectivesHud = CreateClientConVar("drp_objectives_hud", "1", true, false, "Show accepted DarkRP objectives on the HUD.")

local function readDefinition()
	return {
		key = net.ReadString(),
		category = net.ReadString(),
		title = net.ReadString(),
		description = net.ReadString(),
		progress = net.ReadUInt(16),
		goal = net.ReadUInt(16),
		xp = net.ReadUInt(16),
		money = net.ReadUInt(32),
		automatic = net.ReadBool()
	}
end

local function sendAction(action, key)
	net.Start(ACTION)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(action, 3)
		net.WriteString(tostring(key or ""))
	net.SendToServer()
end

function Client.Request()
	sendAction(0, "")
end

function Client.ReviewGuide()
	sendAction(4, "")
end

function Client.Accept(key)
	sendAction(1, key)
end

function Client.Dismiss(key)
	sendAction(2, key)
end

function Client.Abandon(key)
	sendAction(3, key)
end

function Client.SetRoleGoal(jobID)
	net.Start(ROLE_ACTION)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteUInt(math.Clamp(math.floor(tonumber(jobID) or 0), 0, 255), 8)
	net.SendToServer()
end

function Client.ClearRoleGoal()
	Client.SetRoleGoal(0)
end

net.Receive(SYNC, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local previouslyReceived = Client.Received
	local previousOffers = {}
	for _, objective in ipairs(Client.Offers or {}) do previousOffers[objective.key] = true end
	local offers = {}
	for index = 1, net.ReadUInt(2) do offers[index] = readDefinition() end
	local active = {}
	for index = 1, net.ReadUInt(2) do active[index] = readDefinition() end
	local roleLength = net.ReadUInt(16)
	local roleGoal
	if roleLength > 0 then
		local compressed = net.ReadData(roleLength)
		roleGoal = util.JSONToTable(util.Decompress(compressed) or "")
		if not istable(roleGoal) then roleGoal = nil end
		if roleGoal then
			roleGoal._hudStep = roleGoal.steps and roleGoal.steps[#roleGoal.steps] or {}
			for _, candidate in ipairs(roleGoal.steps or {}) do
				if not candidate.complete then roleGoal._hudStep = candidate break end
			end
		end
	end
	local guide = {
		completed = net.ReadUInt(4),
		total = net.ReadUInt(4),
		current = net.ReadString(),
		mask = net.ReadUInt(8)
	}
	Client.Offers, Client.Active, Client.RoleGoal, Client.Guide, Client.Received = offers, active, roleGoal, guide, true
	hook.Run("DRPObjectivesUpdated", offers, active, roleGoal, guide)
	if not previouslyReceived then
		timer.Simple(1.5, function() if showWelcome then showWelcome() end end)
	else
		for _, objective in ipairs(offers) do
			if not previousOffers[objective.key] then
				enqueuePopup({
					kind = 0,
					title = "New objective available",
					detail = objective.title .. " — " .. objective.description,
					objective = objective
				})
				break
			end
		end
	end
end)

net.Receive(POPUP, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	enqueuePopup({
		kind = net.ReadUInt(2),
		title = net.ReadString(),
		detail = net.ReadString()
	})
end)

local function rewardText(objective)
	local rewards = {}
	if objective.xp > 0 then rewards[#rewards + 1] = string.Comma(objective.xp) .. " XP" end
	if objective.money > 0 then rewards[#rewards + 1] = "$" .. string.Comma(objective.money) end
	return #rewards > 0 and table.concat(rewards, "  •  ") or "Roleplay objective"
end

local function trackerHeight()
	local government = DRP.ClientGovernment
	if government and government.phase == 3 then return 98 end
	if not objectivesHud:GetBool() then return 0 end
	local count = #(Client.Active or {})
	if count == 0 and not Client.RoleGoal then return 0 end

	local height = Client.RoleGoal and 78 or 0
	if Client.RoleGoal and count > 0 then height = height + 8 end
	if count > 0 then height = height + count * 62 + math.max(0, count - 1) * 8 end
	return height
end

local popupQueue, popupFrame, popupSerial = {}, nil, 0

local function showNextPopup()
	if IsValid(popupFrame) or #popupQueue == 0 then return end
	local data = table.remove(popupQueue, 1)
	local colors = DRP.UI.Colors
	local accent = data.kind == 1 and colors.green or (data.kind == 2 and colors.purple or colors.accent)
	local notice = vgui.Create("DPanel")
	popupFrame = notice
	notice:SetSize(math.min(430, ScrW() - 40), 126)
	notice:SetPos(
		ScrW() - notice:GetWide() - 24,
		math.max(20, ScrH() - notice:GetTall() - 24 - trackerHeight() - 12)
	)
	notice:SetMouseInputEnabled(false)
	notice:SetKeyboardInputEnabled(false)
	notice:SetAlpha(0)
	notice:AlphaTo(255, 0.15)
	notice.Think = function(self)
		local hidden = DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus()
		if self:IsVisible() == hidden then self:SetVisible(not hidden) end
		-- Remain attached to the tracker if objectives change while this
		-- non-interactive notification is visible.
		self:SetPos(
			ScrW() - self:GetWide() - 24,
			math.max(20, ScrH() - self:GetTall() - 24 - trackerHeight() - 12)
		)
	end
	notice.Paint = function(_, width, height)
		draw.RoundedBox(9, 0, 0, width, height, Color(colors.background.r, colors.background.g, colors.background.b, 242))
		draw.RoundedBoxEx(9, 0, 0, 5, height, accent, true, false, true, false)
		draw.SimpleText(string.upper(data.title or "Objective update"), "DRP.Admin.Header", 18, 23,
			color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("F4  →  OBJECTIVES", "DRP.Admin.Small", width - 16, 23,
			accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		surface.SetDrawColor(colors.line)
		surface.DrawRect(18, 45, width - 34, 1)
	end

	local detail = vgui.Create("DLabel", notice)
	detail:SetPos(18, 55)
	detail:SetSize(notice:GetWide() - 36, 58)
	detail:SetFont("DRP.Admin.Body")
	detail:SetTextColor(colors.muted)
	detail:SetWrap(true)
	detail:SetContentAlignment(7)
	detail:SetText(data.detail or "")

	popupSerial = popupSerial + 1
	local timerName = "DRP.Objectives.Popup." .. popupSerial
	timer.Create(timerName, 6.55, 1, function()
		if not IsValid(notice) then return end
		notice:AlphaTo(0, 0.45, 0, function()
			if IsValid(notice) then notice:Remove() end
		end)
	end)
	notice.OnRemove = function()
		timer.Remove(timerName)
		if popupFrame == notice then popupFrame = nil end
		timer.Simple(0.1, showNextPopup)
	end
end

enqueuePopup = function(data)
	popupQueue[#popupQueue + 1] = data
	showNextPopup()
end

showWelcome = function(forceFullGuide)
	if cookie.GetNumber("drp_player_guide_seen_v2", 0) == 1 then
		local objective = Client.Offers and Client.Offers[1]
		if objective then
			enqueuePopup({
				kind = 0,
				title = "Objectives generated for this session",
				detail = objective.title .. " — " .. objective.description,
				objective = objective
			})
		end
		return
	end
	if not forceFullGuide then
		cookie.Set("drp_player_guide_seen_v2", "1")
		enqueuePopup({
			kind = 2,
			title = "Automatic beginner guide active",
			detail = "Follow the pinned objective on your HUD. Passive hints will explain controls and civic standing; the complete guide remains in F4 → Guide."
		})
		return
	end
	if IsValid(DRP.MOTD and DRP.MOTD.Frame) then
		timer.Simple(2, function() showWelcome(true) end)
		return
	end
	local colors = DRP.UI.Colors
	local frame = DRP.UI.Frame("WELCOME TO DARKRP FOUNDATION", 720, 470)
	frame:SetDeleteOnClose(true)

	local intro = vgui.Create("DLabel", frame)
	intro:SetPos(28, 78)
	intro:SetSize(frame:GetWide() - 56, 58)
	intro:SetFont("DRP.Admin.Header")
	intro:SetTextColor(color_white)
	intro:SetWrap(true)
	intro:SetText("Roleplay is governed by server-owned incidents, civic standing and visible permissions—not arbitrary roleplay rules.")

	local cards = {
		{ "READ THE WHY? PANEL", "It explains active incidents, evidence and exactly which actions are currently allowed.", colors.accent },
		{ "FOLLOW THE AUTOMATIC GUIDE", "Beginner steps are pinned automatically. Later, accept optional activities or pursue a permanent role pathway.", colors.green },
		{ "BUILD YOUR IDENTITY", "Your actions determine specialist and criminal roles. Select a desired role in F4 → Jobs to pin its requirements.", colors.purple }
	}
	for index, data in ipairs(cards) do
		local cardData = data
		local card = vgui.Create("DPanel", frame)
		card:SetPos(28, 145 + (index - 1) * 72)
		card:SetSize(frame:GetWide() - 56, 62)
		card.Paint = function(_, width, height)
			draw.RoundedBox(7, 0, 0, width, height, colors.panel)
			draw.RoundedBoxEx(7, 0, 0, 5, height, cardData[3], true, false, true, false)
			draw.SimpleText(cardData[1], "DRP.Admin.Body", 18, 18, cardData[3], TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(cardData[2], "DRP.Admin.Small", 18, 42, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end

	local guide = DRP.UI.Button(frame, "OPEN PLAYER GUIDE", colors.accent, function()
		cookie.Set("drp_player_guide_seen_v2", "1")
		frame:Close()
		timer.Simple(0.1, function() if DRP.OpenF4Page then DRP.OpenF4Page("guide") end end)
	end)
	guide:SetPos(28, frame:GetTall() - 62)
	guide:SetSize(250, 40)

	local objectives = DRP.UI.Button(frame, "VIEW OBJECTIVES", colors.green, function()
		cookie.Set("drp_player_guide_seen_v2", "1")
		frame:Close()
		timer.Simple(0.1, function() if DRP.OpenF4Page then DRP.OpenF4Page("objectives") end end)
	end)
	objectives:SetPos(286, frame:GetTall() - 62)
	objectives:SetSize(200, 40)

	local play = DRP.UI.Button(frame, "START PLAYING", colors.panelHover, function() frame:Close() end)
	play:SetPos(494, frame:GetTall() - 62)
	play:SetSize(frame:GetWide() - 522, 40)

	local previousRemove = frame.OnRemove
	frame.OnRemove = function(...)
		cookie.Set("drp_player_guide_seen_v2", "1")
		if previousRemove then previousRemove(...) end
	end
end

concommand.Add("drp_show_player_guide", function()
	cookie.Delete("drp_player_guide_seen_v2")
	showWelcome(true)
end)

local function addObjectiveCard(parent, objective, active)
	local colors = DRP.UI.Colors
	local card = vgui.Create("DPanel", parent)
	card:Dock(TOP)
	card:DockMargin(0, 0, 0, 10)
	card:SetTall(active and 132 or 116)
	card.Paint = function(_, width, height)
		draw.RoundedBox(8, 0, 0, width, height, colors.background)
		draw.RoundedBoxEx(8, 0, 0, 5, height, active and colors.green or colors.accent, true, false, true, false)
		surface.SetDrawColor(colors.line)
		surface.DrawOutlinedRect(0, 0, width, height, 1)
	end

	local category = vgui.Create("DLabel", card)
	category:SetPos(18, 10)
	category:SetSize(250, 18)
	category:SetFont("DRP.Admin.Small")
	category:SetTextColor(active and colors.green or colors.accent)
	category:SetText(string.upper(objective.category))

	local title = vgui.Create("DLabel", card)
	title:SetPos(18, 28)
	title:SetSize(card:GetWide() - 180, 24)
	title:SetFont("DRP.Admin.Header")
	title:SetTextColor(color_white)
	title:SetText(objective.title)

	local description = vgui.Create("DLabel", card)
	description:SetPos(18, 53)
	description:SetSize(card:GetWide() - 190, 38)
	description:SetFont("DRP.Admin.Small")
	description:SetTextColor(colors.muted)
	description:SetWrap(true)
	description:SetText(objective.description)

	local reward = vgui.Create("DLabel", card)
	reward:SetPos(18, active and 105 or 91)
	reward:SetSize(300, 18)
	reward:SetFont("DRP.Admin.Small")
	reward:SetTextColor(colors.muted)
	reward:SetText(rewardText(objective))

	if active then
		local progress = vgui.Create("DPanel", card)
		progress:SetPos(18, 93)
		progress:SetTall(7)
		progress.Paint = function(self, width, height)
			local fraction = math.Clamp(objective.progress / math.max(1, objective.goal), 0, 1)
			draw.RoundedBox(4, 0, 0, width, height, colors.panelHover)
			draw.RoundedBox(4, 0, 0, width * fraction, height, colors.green)
		end
		card.PerformLayout = function(self)
			title:SetWide(math.max(120, self:GetWide() - 190))
			description:SetWide(math.max(120, self:GetWide() - 190))
			progress:SetWide(math.max(120, self:GetWide() - 190))
		end
		if objective.automatic then
			local automatic = vgui.Create("DLabel", card)
			automatic:SetSize(138, 36)
			automatic:SetPos(card:GetWide() - 154, 46)
			automatic:SetFont("DRP.Admin.Small")
			automatic:SetTextColor(colors.green)
			automatic:SetContentAlignment(5)
			automatic:SetText("AUTOMATIC GUIDE")
			local oldLayout = card.PerformLayout
			card.PerformLayout = function(self)
				oldLayout(self)
				automatic:SetPos(self:GetWide() - 154, 46)
			end
		else
			local abandon = DRP.UI.Button(card, "ABANDON", colors.red, function()
				DRP.UI.Confirm("Abandon objective", "Stop tracking \"" .. objective.title .. "\"? It may return later.", "ABANDON", function()
					Client.Abandon(objective.key)
				end, colors.red)
			end)
			abandon:SetSize(138, 36)
			abandon:SetPos(card:GetWide() - 154, 46)
			local oldLayout = card.PerformLayout
			card.PerformLayout = function(self)
				oldLayout(self)
				abandon:SetPos(self:GetWide() - 154, 46)
			end
		end
	else
		local accept = DRP.UI.Button(card, "ACCEPT", colors.accent, function() Client.Accept(objective.key) end)
		accept:SetSize(100, 36)
		accept:SetPos(card:GetWide() - 154, 28)
		local dismiss = DRP.UI.Button(card, "×", colors.panelHover, function() Client.Dismiss(objective.key) end)
		dismiss:SetSize(38, 36)
		dismiss:SetPos(card:GetWide() - 48, 28)
		card.PerformLayout = function(self)
			title:SetWide(math.max(120, self:GetWide() - 190))
			description:SetWide(math.max(120, self:GetWide() - 190))
			accept:SetPos(self:GetWide() - 154, 28)
			dismiss:SetPos(self:GetWide() - 48, 28)
		end
	end
	return card
end

function Client.BuildPage(parent)
	local colors = DRP.UI.Colors
	Client.ReviewGuide()
	local scroll = vgui.Create("DScrollPanel", parent)
	scroll:Dock(FILL)
	scroll:DockMargin(12, 0, 12, 12)

	local guide = Client.Guide or {}
	if (guide.total or 0) > 0 and (guide.completed or 0) < guide.total then
		local guideNames = {
			welcome_identity = "Register with the Councilman",
			beginner_property_purchase = "Purchase your first property",
			welcome_pockets = "Secure an item in Hands",
			beginner_mugging = "Learn the mugging system",
			beginner_healing = "Help an injured player",
			beginner_review = "Review objectives and role pathways"
		}
		local card = vgui.Create("DPanel", scroll)
		card:Dock(TOP)
		card:DockMargin(0, 0, 0, 14)
		card:SetTall(82)
		card.Paint = function(_, width, height)
			local fraction = math.Clamp((guide.completed or 0) / math.max(1, guide.total or 1), 0, 1)
			draw.RoundedBox(8, 0, 0, width, height, colors.background)
			draw.RoundedBoxEx(8, 0, 0, 5, height, colors.green, true, false, true, false)
			draw.SimpleText("BEGINNER GUIDE", "DRP.Admin.Small", 18, 16, colors.green, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText((guide.completed or 0) .. " / " .. (guide.total or 0) .. " COMPLETE", "DRP.Admin.Small", width - 16, 16, colors.green, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
			draw.SimpleText("Next: " .. (guideNames[guide.current] or "Waiting for an available lesson"), "DRP.Admin.Body", 18, 39, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.RoundedBox(3, 18, height - 17, width - 36, 7, colors.panelHover)
			draw.RoundedBox(3, 18, height - 17, (width - 36) * fraction, 7, colors.green)
		end
	end

	local pathwayTitle = DRP.UI.SectionLabel(scroll, "Pinned role pathway")
	pathwayTitle:Dock(TOP)
	pathwayTitle:DockMargin(4, 0, 4, 6)

	if Client.RoleGoal then
		local goal = Client.RoleGoal
		local tint = Color(goal.color and goal.color.r or 157, goal.color and goal.color.g or 120, goal.color and goal.color.b or 255)
		local header = vgui.Create("DPanel", scroll)
		header:Dock(TOP)
		header:DockMargin(0, 0, 0, 8)
		header:SetTall(86)
		header.Paint = function(_, width, height)
			draw.RoundedBox(8, 0, 0, width, height, colors.background)
			draw.RoundedBoxEx(8, 0, 0, 5, height, tint, true, false, true, false)
			draw.SimpleText("PATH TO " .. string.upper(goal.name or "ROLE"), "DRP.Admin.Header", 18, 24, tint, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
		local description = vgui.Create("DLabel", header)
		description:SetPos(18, 43)
		description:SetSize(header:GetWide() - 180, 34)
		description:SetFont("DRP.Admin.Small")
		description:SetTextColor(colors.muted)
		description:SetWrap(true)
		description:SetText(goal.description or "")
		local cancel = DRP.UI.Button(header, "CLEAR PATH", colors.red, function()
			DRP.UI.Confirm("Clear role pathway", "Stop pursuing " .. tostring(goal.name or "this role") .. " and remove it from your HUD?", "CLEAR PATH", Client.ClearRoleGoal, colors.red)
		end)
		cancel:SetSize(128, 36)
		cancel:SetPos(header:GetWide() - 144, 25)
		header.PerformLayout = function(self)
			cancel:SetPos(self:GetWide() - 144, 25)
			description:SetWide(math.max(160, self:GetWide() - 180))
		end

		for _, stepData in ipairs(goal.steps or {}) do
			local step = stepData
			local row = vgui.Create("DPanel", scroll)
			row:Dock(TOP)
			row:DockMargin(0, 0, 0, 7)
			row:SetTall(76)
			row.Paint = function(_, width, height)
				local accent = step.complete and colors.green or tint
				draw.RoundedBox(7, 0, 0, width, height, colors.background)
				draw.RoundedBoxEx(7, 0, 0, 4, height, accent, true, false, true, false)
				draw.SimpleText((step.complete and "✓  " or "") .. tostring(step.title or "Requirement"), "DRP.Admin.Body", 16, 18, step.complete and colors.green or color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				draw.SimpleText(tostring(step.current or ""), "DRP.Admin.Small", width - 14, 18, accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
				draw.RoundedBox(3, 16, height - 12, width - 32, 5, colors.panelHover)
				draw.RoundedBox(3, 16, height - 12, (width - 32) * math.Clamp(tonumber(step.fraction) or 0, 0, 1), 5, accent)
			end
			local detail = vgui.Create("DLabel", row)
			detail:SetPos(16, 32)
			detail:SetSize(row:GetWide() - 32, 30)
			detail:SetFont("DRP.Admin.Small")
			detail:SetTextColor(colors.muted)
			detail:SetWrap(true)
			detail:SetText(tostring(step.detail or ""))
			row.PerformLayout = function(self) detail:SetWide(math.max(120, self:GetWide() - 32)) end
		end
	else
		local empty = vgui.Create("DLabel", scroll)
		empty:Dock(TOP)
		empty:DockMargin(4, 0, 4, 8)
		empty:SetTall(38)
		empty:SetFont("DRP.Admin.Body")
		empty:SetTextColor(colors.muted)
		empty:SetText("Select a desired role to pin its live requirements permanently on your HUD.")
	end

	local roleSelector = vgui.Create("DComboBox", scroll)
	roleSelector:Dock(TOP)
	roleSelector:DockMargin(0, 0, 0, 14)
	roleSelector:SetTall(36)
	roleSelector:SetFont("DRP.Admin.Body")
	roleSelector:SetValue(Client.RoleGoal and "Change pursued role…" or "Choose a role to pursue…")
	for jobID, job in ipairs(DRP.Jobs or {}) do
		if jobID ~= DRP.Job.CITIZEN and jobID ~= LocalPlayer():DRPJobID() then
			roleSelector:AddChoice(job.name, jobID)
		end
	end
	roleSelector.OnSelect = function(_, _, _, jobID) Client.SetRoleGoal(jobID) end

	local activeTitle = DRP.UI.SectionLabel(scroll, "Tracked objectives")
	activeTitle:Dock(TOP)
	activeTitle:DockMargin(4, 0, 4, 6)
	if #Client.Active == 0 then
		local empty = vgui.Create("DLabel", scroll)
		empty:Dock(TOP)
		empty:DockMargin(4, 0, 4, 12)
		empty:SetTall(34)
		empty:SetFont("DRP.Admin.Body")
		empty:SetTextColor(colors.muted)
		empty:SetText("No objective is being tracked. Accept up to two activities below.")
	else
		for _, objective in ipairs(Client.Active) do addObjectiveCard(scroll, objective, true) end
	end

	local offerTitle = DRP.UI.SectionLabel(scroll, "Generated for your current situation")
	offerTitle:Dock(TOP)
	offerTitle:DockMargin(4, 8, 4, 6)
	if #Client.Offers == 0 then
		local empty = vgui.Create("DLabel", scroll)
		empty:Dock(TOP)
		empty:DockMargin(4, 0, 4, 10)
		empty:SetTall(40)
		empty:SetFont("DRP.Admin.Body")
		empty:SetTextColor(colors.muted)
		empty:SetWrap(true)
		empty:SetText(Client.Received and "No suitable activities are available right now. Population and your role can unlock more." or "Waiting for the server objective board…")
	else
		for _, objective in ipairs(Client.Offers) do addObjectiveCard(scroll, objective, false) end
	end

	local refresh = DRP.UI.Button(scroll, "REFRESH OBJECTIVE BOARD", colors.panelHover, Client.Request)
	refresh:Dock(TOP)
	refresh:DockMargin(0, 4, 0, 0)
	refresh:SetTall(38)
end

hook.Add("HUDPaint", "DRP.Objectives.Tracker", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	local government = DRP.ClientGovernment
	if government and government.phase == 3 then
		local colors = DRP.UI.Colors
		local width, height = math.min(350, math.max(280, ScrW() * 0.25), ScrW() - 40), 98
		local x, y = ScrW() - width - 26, ScrH() - height - 26
		local mayor = IsValid(government.mayor) and government.mayor:DRPName() or "the Mayor"
		local remaining = math.max(0, math.ceil((government.deadline or CurTime()) - CurTime()))
		local observer = IsValid(government.mayor) and government.mayor == LocalPlayer()
		draw.RoundedBox(8, x, y, width, height, colors.panel)
		draw.RoundedBoxEx(8, x, y, 5, height, colors.purple, true, false, true, false)
		draw.SimpleText("MAYOR CONFIDENCE POLL", "DRP.Admin.Small", x + 15, y + 15, colors.purple, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(mayor, "DRP.Admin.Header", x + 15, y + 36, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(remaining .. "s", "DRP.Admin.Header", x + width - 14, y + 36, colors.purple, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		draw.SimpleText("KEEP " .. (government.keep or 0) .. "   •   REMOVE " .. (government.remove or 0), "DRP.Admin.Body", x + 15, y + 58, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(observer and "You may observe, but the sitting Mayor cannot vote." or "Type /vote keep or /vote remove in chat.",
			"DRP.Admin.Small", x + 15, y + 80, observer and colors.muted or colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		return
	end
	if DRP.MuggingClient and DRP.MuggingClient.ShouldHideObjectives and DRP.MuggingClient.ShouldHideObjectives() then return end
	if not objectivesHud:GetBool() or (#Client.Active == 0 and not Client.RoleGoal) then return end
	local colors = DRP.UI.Colors
	local width, cardHeight = math.min(330, math.max(260, ScrW() * 0.24), ScrW() - 40), 62
	local x = ScrW() - width - 26
	local y = math.max(20, ScrH() - trackerHeight() - 26)
	local activeOffset = 0
	if Client.RoleGoal then
		local goal = Client.RoleGoal
		local tint = goal._hudTint
		if not tint then
			tint = Color(goal.color and goal.color.r or 157, goal.color and goal.color.g or 120, goal.color and goal.color.b or 255)
			goal._hudTint = tint
		end
		local step = goal._hudStep or {}
		local height = 78
		draw.RoundedBox(7, x, y, width, height, colors.panel)
		draw.RoundedBoxEx(7, x, y, 4, height, tint, true, false, true, false)
		draw.SimpleText("PINNED ROLE PATHWAY", "DRP.Admin.Small", x + 14, y + 14, tint, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(goal.name or "Role", "DRP.Admin.Header", x + 14, y + 34, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(step.title or "Awaiting requirements", "DRP.Admin.Small", x + 14, y + 53, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(step.current or "", "DRP.Admin.Small", x + width - 12, y + 53, tint, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		draw.RoundedBox(3, x + 14, y + 67, width - 28, 5, colors.panelHover)
		draw.RoundedBox(3, x + 14, y + 67, (width - 28) * math.Clamp(tonumber(step.fraction) or 0, 0, 1), 5, tint)
		activeOffset = height + 8
	end
	for index, objective in ipairs(Client.Active) do
		local top = y + activeOffset + (index - 1) * (cardHeight + 8)
		local fraction = math.Clamp(objective.progress / math.max(1, objective.goal), 0, 1)
		draw.RoundedBox(7, x, top, width, cardHeight, colors.panel)
		draw.RoundedBoxEx(7, x, top, 4, cardHeight, colors.accent, true, false, true, false)
		draw.SimpleText(string.upper(objective.category), "DRP.Admin.Small", x + 14, top + 14, colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(objective.title, "DRP.Admin.Body", x + 14, top + 34, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(objective.progress .. " / " .. objective.goal, "DRP.Admin.Small", x + width - 12, top + 34, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		draw.RoundedBox(3, x + 14, top + 51, width - 28, 5, colors.panelHover)
		draw.RoundedBox(3, x + 14, top + 51, (width - 28) * fraction, 5, colors.green)
	end
end)
