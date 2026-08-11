local OPEN = "drp_identity_open_v1"
local SUBMIT = "drp_identity_submit_v2"
local RESULT = "drp_identity_result_v1"

local IdentityUI = { Frame = nil, Councilman = nil }
DRP.IdentityUI = IdentityUI

local function styleCombo(combo)
	combo:SetFont("DRP.Admin.Body")
	combo:SetTextColor(color_white)
	combo.Paint = function(self, width, height)
		draw.RoundedBox(6, 0, 0, width, height, DRP.UI.Colors.panelHover)
		surface.SetDrawColor(DRP.UI.Colors.line) surface.DrawOutlinedRect(0, 0, width, height, 1)
	end
end

local function fieldLabel(parent, text)
	local label = vgui.Create("DLabel", parent)
	label:Dock(TOP) label:DockMargin(0, 8, 0, 4) label:SetTall(18)
	label:SetFont("DRP.Admin.Small") label:SetTextColor(DRP.UI.Colors.accent) label:SetText(string.upper(text))
	return label
end

function IdentityUI.Open(entityIndex, state)
	if IsValid(IdentityUI.Frame) then IdentityUI.Frame:Remove() end
	state = DRP.IdentityCatalog.Normalize(state)
	IdentityUI.Councilman = Entity(entityIndex)

	local frame = DRP.UI.Frame(state.registered and "CIVIC IDENTITY OFFICE" or "REGISTER YOUR IDENTITY", 980, 700)
	IdentityUI.Frame = frame
	frame:SetDeleteOnClose(true)

	local previewCard = vgui.Create("DPanel", frame)
	previewCard:SetPos(24, 78) previewCard:SetSize(410, frame:GetTall() - 102)
	previewCard.Paint = function(_, width, height)
		draw.RoundedBox(9, 0, 0, width, height, DRP.UI.Colors.panel)
		draw.RoundedBoxEx(9, 0, 0, 5, height, DRP.UI.Colors.purple, true, false, true, false)
		draw.SimpleText("CIVIC PROFILE PREVIEW", "DRP.Admin.Small", 20, 22, DRP.UI.Colors.purple, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local modelPanel = vgui.Create("DModelPanel", previewCard)
	modelPanel:SetPos(18, 84) modelPanel:SetSize(previewCard:GetWide() - 36, previewCard:GetTall() - 164)
	modelPanel:SetFOV(32) modelPanel:SetAnimated(true)
	modelPanel.PreviewYaw = 25
	modelPanel.LayoutEntity = function(self, entity)
		entity:SetAngles(Angle(0, self.PreviewYaw or 25, 0))
	end
	modelPanel.OnMousePressed = function(self, key)
		if key ~= MOUSE_LEFT then return end
		self.DraggingPreview = true
		self.LastPreviewMouseX = gui.MouseX()
		self:MouseCapture(true)
	end
	modelPanel.OnCursorMoved = function(self)
		if not self.DraggingPreview then return end
		local mouseX = gui.MouseX()
		self.PreviewYaw = (self.PreviewYaw or 25) + (mouseX - (self.LastPreviewMouseX or mouseX)) * 0.7
		self.LastPreviewMouseX = mouseX
	end
	modelPanel.OnMouseReleased = function(self, key)
		if key ~= MOUSE_LEFT then return end
		self.DraggingPreview = false
		self:MouseCapture(false)
	end

	local previewName = vgui.Create("DLabel", previewCard)
	previewName:SetPos(20, previewCard:GetTall() - 70) previewName:SetSize(previewCard:GetWide() - 40, 28)
	previewName:SetFont("DRP.Admin.Header") previewName:SetTextColor(color_white)
	previewName:SetContentAlignment(5)

	local previewHint = vgui.Create("DLabel", previewCard)
	previewHint:SetPos(20, previewCard:GetTall() - 40) previewHint:SetSize(previewCard:GetWide() - 40, 20)
	previewHint:SetFont("DRP.Admin.Small") previewHint:SetTextColor(DRP.UI.Colors.muted)
	previewHint:SetText("DRAG THE MODEL TO ROTATE") previewHint:SetContentAlignment(5)

	local switchPreview
	local civilianPreview = DRP.UI.Button(previewCard, "CIVILIAN", DRP.UI.Colors.green, function()
		if switchPreview then switchPreview("civilian") end
	end)
	civilianPreview:SetPos(18, 42) civilianPreview:SetSize(178, 32)
	local policePreview = DRP.UI.Button(previewCard, "POLICE UNIFORM", DRP.UI.Colors.accent, function()
		if switchPreview then switchPreview("police") end
	end)
	policePreview:SetPos(214, 42) policePreview:SetSize(178, 32)

	local form = vgui.Create("DScrollPanel", frame)
	form:SetPos(458, 78) form:SetSize(frame:GetWide() - 482, frame:GetTall() - 166)

	fieldLabel(form, "Roleplay name")
	local name = vgui.Create("DTextEntry", form)
	name:Dock(TOP) name:SetTall(38) name:SetFont("DRP.Admin.Body") name:SetTextColor(color_white)
	name:SetDrawLanguageID(false) name:SetText(state.name or "") name:SetPlaceholderText("First and last name")
	name.Paint = function(self, width, height)
		draw.RoundedBox(6, 0, 0, width, height, DRP.UI.Colors.panelHover)
		self:DrawTextEntryText(color_white, DRP.UI.Colors.accent, color_white)
	end

	fieldLabel(form, "Gender")
	local gender = vgui.Create("DComboBox", form) gender:Dock(TOP) gender:SetTall(36) styleCombo(gender)
	for index, option in ipairs(DRP.IdentityCatalog.Genders) do gender:AddChoice(option.name, index, index == state.gender) end

	fieldLabel(form, "Clothing collection")
	local outfit = vgui.Create("DComboBox", form) outfit:Dock(TOP) outfit:SetTall(36) styleCombo(outfit)
	for index, option in ipairs(DRP.IdentityCatalog.Outfits) do outfit:AddChoice(option.name, index, index == state.outfit) end

	fieldLabel(form, "Face")
	local head = vgui.Create("DComboBox", form) head:Dock(TOP) head:SetTall(36) styleCombo(head)

	fieldLabel(form, "Skin variant")
	local skin = vgui.Create("DComboBox", form) skin:Dock(TOP) skin:SetTall(36) styleCombo(skin)

	fieldLabel(form, "Clothing details")
	local bodygroups = vgui.Create("DPanel", form) bodygroups:Dock(TOP) bodygroups:SetTall(32) bodygroups.Paint = nil
	local refreshing = false

	local policeState = state.uniforms and state.uniforms.police or { skin = 0, bodygroups = {} }
	local selected = { gender = state.gender, outfit = state.outfit, head = state.head }
	local appearance = {
		civilian = { skin = state.skin or 0, bodygroups = table.Copy(state.bodygroups or {}) },
		police = { skin = policeState.skin or 0, bodygroups = table.Copy(policeState.bodygroups or {}) }
	}
	local previewMode = "civilian"

	local function frameModel(entity)
		local mins, maxs = entity:GetRenderBounds()
		local center = (mins + maxs) * 0.5
		local size = maxs - mins
		local radius = math.max(size.z * 0.54, size.x * 0.65, size.y * 0.65, 24)
		local distance = math.max(64, radius / math.tan(math.rad(16)))
		modelPanel:SetLookAt(center)
		modelPanel:SetCamPos(Vector(distance, 0, center.z))
	end

	local function refreshBodygroups(entity)
		bodygroups:Clear()
		if not IsValid(entity) then bodygroups:SetTall(30) return end
		local controls = 0
		local mode = previewMode
		local saved = appearance[mode].bodygroups
		for id = 0, math.min(entity:GetNumBodyGroups() - 1, 15) do
			local count = math.min(entity:GetBodygroupCount(id) or 0, 32)
			if count > 1 then
				local bodygroupID = id
				local control = vgui.Create("DComboBox", bodygroups)
				control:Dock(TOP) control:DockMargin(0, 0, 0, 6) control:SetTall(34) styleCombo(control)
				local title = entity:GetBodygroupName(bodygroupID)
				if not title or title == "" then title = "Detail " .. (bodygroupID + 1) end
				local current = math.Clamp(tonumber(saved[bodygroupID] or saved[tostring(bodygroupID)] or 0) or 0, 0, count - 1)
				saved[bodygroupID] = current
				entity:SetBodygroup(bodygroupID, current)
				for value = 0, count - 1 do control:AddChoice(title .. "  •  " .. (value + 1), value, value == current) end
				control.OnSelect = function(_, _, _, value)
					appearance[mode].bodygroups[bodygroupID] = value
					if IsValid(modelPanel.Entity) then modelPanel.Entity:SetBodygroup(bodygroupID, value) end
				end
				controls = controls + 1
			end
		end
		if controls == 0 then
			local unavailable = vgui.Create("DLabel", bodygroups)
			unavailable:Dock(TOP) unavailable:SetTall(28) unavailable:SetFont("DRP.Admin.Small")
			unavailable:SetTextColor(DRP.UI.Colors.muted) unavailable:SetText("This model has no configurable clothing details.")
		end
		bodygroups:SetTall(math.max(30, controls * 40))
	end

	local function refreshSkin(entity)
		refreshing = true
		skin:Clear()
		local options = math.max(1, entity:SkinCount())
		local active = appearance[previewMode]
		active.skin = math.Clamp(math.floor(tonumber(active.skin) or 0), 0, options - 1)
		for value = 0, options - 1 do skin:AddChoice("Variant " .. (value + 1), value, value == active.skin) end
		refreshing = false
	end

	local function refreshModel()
		local model = previewMode == "police" and DRP.IdentityCatalog.PoliceModel()
			or DRP.IdentityCatalog.Model(selected.gender, selected.outfit, selected.head)
		if not model or not util.IsValidModel(model) then
			previewHint:SetText("MODEL UNAVAILABLE — CONTACT SERVER STAFF")
			previewHint:SetTextColor(DRP.UI.Colors.red)
			return
		end
		previewHint:SetText("DRAG THE MODEL TO ROTATE")
		previewHint:SetTextColor(DRP.UI.Colors.muted)
		modelPanel:SetModel(model)
		local entity = modelPanel.Entity
		if not IsValid(entity) then return end
		frameModel(entity)
		refreshSkin(entity)
		entity:SetSkin(appearance[previewMode].skin)
		refreshBodygroups(entity)
		local profileName = name:GetValue() ~= "" and name:GetValue() or "UNREGISTERED CITIZEN"
		previewName:SetText(previewMode == "police" and (profileName .. "  •  ON DUTY") or profileName)
	end

	switchPreview = function(mode)
		if mode ~= "civilian" and mode ~= "police" then return end
		previewMode = mode
		civilianPreview:SetText(mode == "civilian" and "●  CIVILIAN" or "CIVILIAN")
		policePreview:SetText(mode == "police" and "●  POLICE UNIFORM" or "POLICE UNIFORM")
		refreshModel()
	end

	local function refreshHeads(preserve)
		refreshing = true
		head:Clear()
		local heads = DRP.IdentityCatalog.Genders[selected.gender].heads
		selected.head = math.Clamp(preserve or selected.head or 1, 1, #heads)
		for index = 1, #heads do head:AddChoice("Face " .. index, index, index == selected.head) end
		refreshing = false
		refreshModel()
	end

	gender.OnSelect = function(_, _, _, value) if refreshing then return end selected.gender = value selected.head = 1 previewMode = "civilian" refreshHeads(1) switchPreview("civilian") end
	outfit.OnSelect = function(_, _, _, value) if refreshing then return end selected.outfit = value switchPreview("civilian") end
	head.OnSelect = function(_, _, _, value) if refreshing then return end selected.head = value switchPreview("civilian") end
	skin.OnSelect = function(_, _, _, value)
		if refreshing then return end
		appearance[previewMode].skin = value
		if IsValid(modelPanel.Entity) then modelPanel.Entity:SetSkin(value) end
	end
	name.OnChange = function()
		local profileName = name:GetValue() ~= "" and name:GetValue() or "UNREGISTERED CITIZEN"
		previewName:SetText(previewMode == "police" and (profileName .. "  •  ON DUTY") or profileName)
	end

	refreshHeads(selected.head)
	switchPreview("civilian")

	local help = vgui.Create("DLabel", frame)
	help:SetPos(458, frame:GetTall() - 80) help:SetSize(frame:GetWide() - 680, 46)
	help:SetFont("DRP.Admin.Small") help:SetTextColor(DRP.UI.Colors.muted) help:SetWrap(true)
	help:SetText("Preview both appearances above. Police use the saved official uniform while on duty; available variants depend on its model.")

	-- Lua does not place a local in scope until after its initializer finishes.
	-- Predeclare the button so this callback captures the panel instead of
	-- resolving an unrelated global named `submit` when it is clicked.
	local submit
	submit = DRP.UI.Button(frame, state.registered and "UPDATE IDENTITY" or "REGISTER IDENTITY", DRP.UI.Colors.green, function()
		local function collectGroups(source)
			local groups = {}
			for rawID, rawValue in pairs(source or {}) do
				local id, value = tonumber(rawID), tonumber(rawValue)
				if id and value and id >= 0 and id <= 15 and value >= 0 and value <= 31 and #groups < 15 then
					groups[#groups + 1] = { id = math.floor(id), value = math.floor(value) }
				end
			end
			return groups
		end
		local groups = collectGroups(appearance.civilian.bodygroups)
		local policeGroups = collectGroups(appearance.police.bodygroups)
		net.Start(SUBMIT)
		net.WriteUInt(DRP.ProtocolVersion, 8) net.WriteUInt(entityIndex, 13) net.WriteString(string.sub(name:GetValue(), 1, 64))
		net.WriteUInt(selected.gender, 2) net.WriteUInt(selected.outfit, 2) net.WriteUInt(selected.head, 4) net.WriteUInt(appearance.civilian.skin, 5)
		net.WriteUInt(#groups, 4)
		for index = 1, #groups do net.WriteUInt(groups[index].id, 4) net.WriteUInt(groups[index].value, 5) end
		net.WriteUInt(appearance.police.skin, 5)
		net.WriteUInt(#policeGroups, 4)
		for index = 1, #policeGroups do net.WriteUInt(policeGroups[index].id, 4) net.WriteUInt(policeGroups[index].value, 5) end
		net.SendToServer()
		submit:SetEnabled(false) timer.Simple(1, function() if IsValid(submit) then submit:SetEnabled(true) end end)
	end)
	submit:SetPos(frame:GetWide() - 210, frame:GetTall() - 75) submit:SetSize(185, 42)

	frame.OnRemove = function() if IdentityUI.Frame == frame then IdentityUI.Frame = nil end end
end

net.Receive(OPEN, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local entityIndex, length = net.ReadUInt(13), net.ReadUInt(16)
	local payload = length > 0 and net.ReadData(length) or ""
	local decoded = util.JSONToTable(util.Decompress(payload) or "")
	IdentityUI.Open(entityIndex, decoded)
end)

net.Receive(RESULT, function()
	local success, message = net.ReadBool(), net.ReadString()
	if chat and chat.AddText then chat.AddText(success and DRP.UI.Colors.green or DRP.UI.Colors.red, "[IDENTITY] ", color_white, message) end
	if success and IsValid(IdentityUI.Frame) then IdentityUI.Frame:Close() end
end)

local councilmen = setmetatable({}, { __mode = "k" })
local function indexCouncilman(entity)
	if IsValid(entity) and entity:GetClass() == "drp_councilman" then councilmen[entity] = true end
end
hook.Add("InitPostEntity", "DRP.Identity.IndexCouncilmen", function()
	for _, entity in ipairs(ents.FindByClass("drp_councilman")) do indexCouncilman(entity) end
end)
hook.Add("OnEntityCreated", "DRP.Identity.IndexCouncilman", function(entity)
	if not IsValid(entity) then return end
	timer.Simple(0, function() indexCouncilman(entity) end)
end)
hook.Add("EntityRemoved", "DRP.Identity.UnindexCouncilman", function(entity) councilmen[entity] = nil end)

local identityObjectiveAvailable = false
local function refreshIdentityObjective(_, active)
	identityObjectiveAvailable = false
	for _, objective in ipairs(active or (DRP.ObjectivesClient and DRP.ObjectivesClient.Active) or {}) do
		if objective.key == "welcome_identity" then
			identityObjectiveAvailable = true
			break
		end
	end
end
hook.Add("DRPObjectivesUpdated", "DRP.Identity.ObjectiveState", refreshIdentityObjective)
refreshIdentityObjective()

local function identityObjectiveActive()
	if not identityObjectiveAvailable then return false end
	local ply = LocalPlayer()
	if IsValid(ply) then
		local job = ply:DRPJob()
		if job and job.isHobo then return false end
	end
	return true
end

local markerOffset = Vector(0, 0, 32)
local markerBackground = Color(8, 13, 25, 235)
local closestCouncilman
local nextCouncilmanScan = 0

hook.Add("HUDPaint", "DRP.Identity.CouncilmanMarker", function()
	if not identityObjectiveActive() or (DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus()) then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local now = CurTime()
	if now >= nextCouncilmanScan or not IsValid(closestCouncilman) then
		nextCouncilmanScan = now + 0.2
		local bestDistance
		closestCouncilman = nil
		for entity in pairs(councilmen) do
			if not IsValid(entity) then councilmen[entity] = nil else
				local current = ply:GetPos():DistToSqr(entity:GetPos())
				if not bestDistance or current < bestDistance then closestCouncilman, bestDistance = entity, current end
			end
		end
	end
	if not IsValid(closestCouncilman) then return end
	local distance = ply:GetPos():DistToSqr(closestCouncilman:GetPos())
	local screen = (closestCouncilman:WorldSpaceCenter() + markerOffset):ToScreen()
	local x, y = math.Clamp(screen.x, 100, ScrW() - 100), math.Clamp(screen.y, 100, ScrH() - 100)
	draw.RoundedBox(7, x - 92, y - 22, 184, 44, markerBackground)
	draw.RoundedBoxEx(7, x - 92, y - 22, 4, 44, DRP.UI.Colors.accent, true, false, true, false)
	draw.SimpleText("COUNCILMAN", "DRP.Admin.Body", x, y - 7, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	draw.SimpleText(math.floor(math.sqrt(distance)) .. " units  •  PRESS E", "DRP.Admin.Small", x, y + 11, DRP.UI.Colors.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)
