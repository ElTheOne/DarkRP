DRP.ClientProperties = DRP.ClientProperties or {}
DRP.ClientDoorProperties = DRP.ClientDoorProperties or {}
DRP.PropertyUI = DRP.PropertyUI or {}

local PropertyUI = DRP.PropertyUI
local managementFrame
local managementSnapshot
local nextManagementRefresh = 0
local zoneEditor

local function sendManagement(action, data)
	local json = util.TableToJSON(data or {}, false) or "{}"
	local payload = util.Compress(json) or ""
	net.Start("drp_property_manage_action_v1")
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteString(action)
		net.WriteUInt(#payload, 16)
		net.WriteData(payload, #payload)
	net.SendToServer()
end

function PropertyUI.Request(propertyID, open)
	sendManagement("request", { id = propertyID, open = open == true })
end

function PropertyUI.BeginZoneEditing(property)
	if not property then return end
	sendManagement("edit_zones", { id = property.id })
	if IsValid(managementFrame) then managementFrame:Remove() end
	if DRP.CloseF4Menu then DRP.CloseF4Menu() end
end

local function styledRow(parent, title, detail, accent)
	local colors = DRP.UI.Colors
	local row = vgui.Create("DButton", parent)
	row:Dock(TOP)
	row:DockMargin(0, 0, 0, 8)
	row:SetTall(66)
	row:SetText("")
	row.Paint = function(self, width, height)
		draw.RoundedBox(7, 0, 0, width, height, self:IsHovered() and colors.panelHover or colors.background)
		draw.RoundedBoxEx(7, 0, 0, 5, height, accent or colors.accent, true, false, true, false)
		draw.SimpleText(title, "DRP.Admin.Body", 18, 21, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(detail, "DRP.Admin.Small", 18, 46, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	return row
end

local function stringPrompt(title, text, default, callback)
	Derma_StringRequest(title, text, tostring(default or ""), function(value) if callback then callback(value) end end, nil, "SAVE", "CANCEL")
end

function PropertyUI.OpenAdminMenu(property)
	if not property or DRP.AdminRankLevel(DRP.ClientAdminRank or "user") < DRP.AdminRankLevel("headadmin") then return end
	local menu = DermaMenu()
	if not property.world then
		menu:AddOption("Set purchase price", function()
			stringPrompt("Property Purchase Price", "Set the property purchase price. Use 0 for automatic per-door pricing.", property.price or 0, function(value)
				sendManagement("set_price", { id = property.id, price = tonumber(value) or -1 })
			end)
		end):SetIcon("icon16/money.png")
		menu:AddOption("Set daily lease payment", function()
			stringPrompt("Daily Base Lease", "Set the scheduled daily payment. Use 0 for the automatic 10% rate.", property.leaseRate or 0, function(value)
				sendManagement("set_lease_price", { id = property.id, price = tonumber(value) or -1 })
			end)
		end):SetIcon("icon16/date.png")
		menu:AddOption(property.buyable and "Mark as not buyable" or "Allow property purchases", function()
			sendManagement("set_buyable", { id = property.id, buyable = not property.buyable })
		end):SetIcon(property.buyable and "icon16/lock.png" or "icon16/lock_open.png")
		menu:AddSpacer()
	end
	menu:AddOption("Edit prop build zones" .. ((property.buildZoneCount or 0) > 0 and (" (" .. property.buildZoneCount .. ")") or ""), function()
		PropertyUI.BeginZoneEditing(property)
	end):SetIcon("icon16/shape_handles.png")
	if (property.buildZoneCount or 0) > 0 then
		menu:AddOption("Clear all prop build zones", function()
			DRP.UI.Confirm(
				"CLEAR PROPERTY BUILD ZONES",
				"Remove all " .. property.buildZoneCount .. " build boxes from " .. property.name .. "? Players will be unable to spawn props there until new boxes are created.",
				"CLEAR ZONES",
				function() sendManagement("clear_zones", { id = property.id }) end,
				DRP.UI.Colors.red
			)
		end):SetIcon("icon16/shape_square_delete.png")
	end
	menu:Open()
end

local function addSection(scroll, text)
	local label = vgui.Create("DLabel", scroll)
	label:Dock(TOP)
	label:DockMargin(4, 8, 4, 6)
	label:SetTall(30)
	label:SetFont("DRP.Admin.Header")
	label:SetTextColor(color_white)
	label:SetText(text)
	return label
end

function PropertyUI.Open(snapshot)
	if not snapshot then return end
	managementSnapshot = snapshot
	if IsValid(managementFrame) then managementFrame:Remove() end
	local colors = DRP.UI.Colors
	local frame = DRP.UI.Frame("PROPERTY MANAGEMENT  •  #" .. snapshot.id, 920, 720)
	managementFrame = frame

	local scroll = vgui.Create("DScrollPanel", frame)
	scroll:SetPos(22, 76)
	scroll:SetSize(frame:GetWide() - 44, frame:GetTall() - 98)

	local hero = vgui.Create("DPanel", scroll)
	hero:Dock(TOP)
	hero:DockMargin(0, 0, 0, 12)
	hero:SetTall(112)
	hero.Paint = function(_, width, height)
		draw.RoundedBox(9, 0, 0, width, height, Color(17, 31, 52, 252))
		draw.RoundedBoxEx(9, 0, 0, 6, height, snapshot.raid > 0 and colors.red or colors.accent, true, false, true, false)
		draw.SimpleText(snapshot.name, "DRP.Admin.Title", 22, 27, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		local access = snapshot.world and ("Build access: Hobo  •  " .. snapshot.buildZoneCount .. " marked street zones")
			or ("Owner: " .. snapshot.owner .. "  •  Your role: " .. string.upper(snapshot.role))
		draw.SimpleText(access, "DRP.Admin.Body", 22, 58, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		local state = snapshot.world and "HOBO STREET BUILD ZONES  •  NOT PURCHASABLE"
			or snapshot.owner == "Unowned" and (snapshot.buyable and ("FOR SALE  •  $" .. string.Comma(snapshot.price)) or "NOT AVAILABLE FOR PURCHASE")
			or ("DAILY LEASE  •  $" .. string.Comma(snapshot.leaseRate))
		local stateColor = snapshot.raid > 0 and colors.red
			or (snapshot.world and colors.accent)
			or (snapshot.owner ~= "Unowned" and colors.green)
			or (snapshot.buyable and colors.green or colors.red)
		draw.SimpleText(state, "DRP.Admin.Body", 22, 88, stateColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	if snapshot.canConfigure then
		hero:SetMouseInputEnabled(true)
		hero.OnMousePressed = function(_, code) if code == MOUSE_RIGHT then PropertyUI.OpenAdminMenu(snapshot) end end
	end

	if snapshot.owner ~= "Unowned" and snapshot.role ~= "none" then
		addSection(scroll, "Scheduled Base Payments")
		local remaining = math.max(0, snapshot.leasePaidUntil - os.time())
		local days = math.floor(remaining / 86400)
		local hours = math.floor((remaining % 86400) / 3600)
		local payment = styledRow(scroll, "FUNDED THROUGH  " .. os.date("%Y-%m-%d %H:%M", snapshot.leasePaidUntil), days .. "d " .. hours .. "h remaining  •  Payments do not prevent raids.", remaining < 21600 and colors.red or colors.green)
		payment:SetEnabled(false)
		local paymentBar = vgui.Create("DPanel", scroll)
		paymentBar:Dock(TOP)
		paymentBar:DockMargin(0, 0, 0, 10)
		paymentBar:SetTall(46)
		paymentBar.Paint = nil
		local maximumFundedUntil = os.time() + (snapshot.maxPrepaidDays + 1) * 86400
		local availableDays = math.Clamp(math.floor((maximumFundedUntil - snapshot.leasePaidUntil) / 86400), 0, snapshot.maxPrepaidDays)
		for day = 1, snapshot.maxPrepaidDays do
			local count = day
			local button = DRP.UI.Button(paymentBar, "FUND +" .. day .. " DAY" .. (day == 1 and "" or "S") .. "  •  $" .. string.Comma(snapshot.leaseRate * day), colors.green, function()
				DRP.UI.Confirm("FUND BASE LEASE", "Deposit $" .. string.Comma(snapshot.leaseRate * count) .. " for " .. count .. " additional day(s)? This does not protect the property from raids.", "FUND LEASE", function()
					sendManagement("pay", { id = snapshot.id, days = count })
				end, colors.green)
			end)
			button:SetSize(math.floor((scroll:GetWide() - 20) / 3), 42)
			button:SetPos((day - 1) * (button:GetWide() + 8), 0)
			button:SetEnabled(day <= availableDays)
			if day > availableDays then
				button:SetText(availableDays == 0 and "MAXIMUM FUNDED" or ("+" .. day .. " DAYS UNAVAILABLE"))
				button:SetTextColor(colors.muted)
			end
		end
	end

	if snapshot.canMembers then
		addSection(scroll, "Co-owners and Tenants")
		local invite = DRP.UI.Button(scroll, "INVITE ONLINE PLAYER", colors.accent, function()
			local menu = DermaMenu()
			for _, target in ipairs(snapshot.players or {}) do
				local targetData = target
				local roles = menu:AddSubMenu(targetData.name)
				for _, role in ipairs({ "coowner", "tenant", "guest" }) do
					local selectedRole = role
					roles:AddOption(string.upper(role), function()
						stringPrompt("Tenant Rent", "Scheduled rent charged every five minutes. Use 0 for no rent.", "0", function(rent)
							stringPrompt("Refundable Deposit", "Deposit collected when the invitation is accepted.", "0", function(deposit)
								sendManagement("invite", { id = snapshot.id, target = targetData.entity, role = selectedRole, rent = tonumber(rent) or 0, deposit = tonumber(deposit) or 0 })
							end)
						end)
					end)
				end
			end
			if #(snapshot.players or {}) == 0 then menu:AddOption("No eligible online players", function() end) end
			menu:Open()
		end)
		invite:Dock(TOP)
		invite:DockMargin(0, 0, 0, 8)
		invite:SetTall(40)
	end

	for _, member in ipairs(snapshot.members or {}) do
		local data = member
		local eviction = data.eviction > os.time() and ("  •  EVICTION IN " .. (data.eviction - os.time()) .. "s") or ""
		local row = styledRow(scroll, data.name .. "  •  " .. string.upper(data.role), "Rent $" .. string.Comma(data.rent) .. "  •  Deposit $" .. string.Comma(data.deposit) .. eviction, data.eviction > os.time() and colors.red or colors.purple)
		row:SetEnabled(snapshot.canMembers or snapshot.canFinances)
		row.DoClick = function()
			local menu = DermaMenu()
			if snapshot.canFinances then
				menu:AddOption("Set rent", function()
					stringPrompt("Tenant Rent", "Set scheduled rent for " .. data.name .. ".", data.rent, function(value)
						sendManagement("member_rent", { id = snapshot.id, memberID = data.id, rent = tonumber(value) or -1 })
					end)
				end):SetIcon("icon16/money.png")
			end
			if snapshot.canMembers then
				local roles = menu:AddSubMenu("Change role")
				for _, role in ipairs({ "coowner", "tenant", "guest" }) do
					local selectedRole = role
					roles:AddOption(string.upper(role), function()
						sendManagement("member_role", { id = snapshot.id, memberID = data.id, role = selectedRole })
					end)
				end
				menu:AddOption("Issue eviction notice", function()
					DRP.UI.Confirm("EVICT TENANT", "Issue the configured eviction notice to " .. data.name .. "?", "ISSUE NOTICE", function()
						sendManagement("member_evict", { id = snapshot.id, memberID = data.id })
					end, colors.red)
				end):SetIcon("icon16/door_out.png")
			end
			menu:Open()
		end
	end

	if snapshot.canRoles then
		addSection(scroll,"Role Crafting Permissions")
		for _,roleName in ipairs({"coowner","tenant","guest"}) do
			local role=roleName
			local enabled=snapshot.roles and snapshot.roles[role] and snapshot.roles[role].crafting==true
			local row=styledRow(scroll,string.upper(role).."  •  CRAFTING "..(enabled and "ENABLED" or "DISABLED"),enabled and "May start, cancel and manage workbench jobs." or "May not begin workbench jobs.",enabled and colors.green or colors.red)
			row.DoClick=function() sendManagement("role_permission",{id=snapshot.id,role=role,permission="crafting",enabled=not enabled}) end
		end
	end

	if snapshot.canStorage then
		addSection(scroll, "Persistent Shared Vault  •  " .. #snapshot.vault .. "/" .. snapshot.vaultCapacity)
		local deposit = DRP.UI.Button(scroll, "DEPOSIT FROM HANDS", colors.purple, function()
			local menu = DermaMenu()
			for _, item in ipairs(snapshot.pockets or {}) do
				local data = item
				menu:AddOption(data.label .. (data.amount > 1 and (" ×" .. data.amount) or ""), function()
					sendManagement("vault_deposit", { id = snapshot.id, itemID = data.itemID, index = data.index })
				end):SetIcon("icon16/box.png")
			end
			if #(snapshot.pockets or {}) == 0 then menu:AddOption("Your Hands are empty", function() end) end
			menu:Open()
		end)
		deposit:Dock(TOP)
		deposit:DockMargin(0, 0, 0, 8)
		deposit:SetTall(40)
		for _, item in ipairs(snapshot.vault or {}) do
			local data = item
			local row = styledRow(scroll, data.label .. (data.amount > 1 and (" ×" .. data.amount) or ""), string.upper(data.kind) .. "  •  Deposited by " .. data.depositor, colors.green)
			row.DoClick = function()
				DRP.UI.Confirm("WITHDRAW VAULT ITEM", "Move " .. data.label .. " into Hands?", "WITHDRAW", function()
					sendManagement("vault_withdraw", { id = snapshot.id, index = data.index })
				end, colors.green)
			end
		end
	end

	if snapshot.canConfigure then
		addSection(scroll, "HeadAdmin Property Configuration")
		local zones = styledRow(
			scroll,
			"EDIT PROP BUILD ZONES  •  " .. tostring(snapshot.buildZoneCount or 0) .. "/32",
			"Select multiple three-dimensional boxes with the Tool Gun. Complete props must remain inside one box.",
			colors.accent
		)
		zones.DoClick = function() PropertyUI.BeginZoneEditing(snapshot) end
		local admin = styledRow(scroll, "RIGHT-CLICK FOR PROPERTY POLICY", "Set purchase price, daily lease payment, or whether the property can be bought.", colors.red)
		admin.DoClick = function() PropertyUI.OpenAdminMenu(snapshot) end
		admin.DoRightClick = admin.DoClick
	end
end

local function vectorFromData(data)
	return Vector(tonumber(data and data.x) or 0, tonumber(data and data.y) or 0, tonumber(data and data.z) or 0)
end

local function zonePrism(zone)
	local source = zone and (zone.corners or zone.base)
	if istable(source) and #source == 4 and tonumber(zone.top_z or zone.height_z) then
		local base, top = {}, {}
		local topZ = tonumber(zone.top_z or zone.height_z)
		for index = 1, 4 do
			base[index] = vectorFromData(source[index])
			top[index] = Vector(base[index].x, base[index].y, topZ)
		end
		return base, top
	end
	local mins = vectorFromData(zone and (zone.mins or zone.min))
	local maxs = vectorFromData(zone and (zone.maxs or zone.max))
	return {
		Vector(mins.x, mins.y, mins.z), Vector(maxs.x, mins.y, mins.z),
		Vector(maxs.x, maxs.y, mins.z), Vector(mins.x, maxs.y, mins.z)
	}, {
		Vector(mins.x, mins.y, maxs.z), Vector(maxs.x, mins.y, maxs.z),
		Vector(maxs.x, maxs.y, maxs.z), Vector(mins.x, maxs.y, maxs.z)
	}
end

local function drawPrism(base, top, color)
	if not base or not top then return end
	local fill = Color(color.r, color.g, color.b, 20)
	render.DrawQuad(base[1], base[2], base[3], base[4], fill)
	render.DrawQuad(top[4], top[3], top[2], top[1], fill)
	for index = 1, 4 do
		local following = (index % 4) + 1
		render.DrawQuad(base[index], top[index], top[following], base[following], fill)
		render.DrawLine(base[index], base[following], color, false)
		render.DrawLine(top[index], top[following], color, false)
		render.DrawLine(base[index], top[index], color, false)
	end
end

local function pendingZonePoints()
	if not zoneEditor or not istable(zoneEditor.pending) then return {} end
	if zoneEditor.pending.x ~= nil then return { vectorFromData(zoneEditor.pending) } end
	local output = {}
	for index, point in ipairs(zoneEditor.pending) do
		if index > 4 then break end
		output[index] = vectorFromData(point)
	end
	return output
end

local function activeZoneTool()
	local ply = LocalPlayer()
	local weapon = IsValid(ply) and ply:GetActiveWeapon() or nil
	return IsValid(weapon) and weapon:GetClass() == "gmod_tool" and isfunction(weapon.GetMode)
		and weapon:GetMode() == "drp_property_zone"
end

net.Receive("drp_property_zone_sync_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length = net.ReadUInt(18)
	if length > 262143 then return end
	local payload = net.ReadData(length)
	local json = util.Decompress(payload or "")
	local decoded = json and util.JSONToTable(json)
	if not istable(decoded) then return end
	zoneEditor = decoded
	DRP.PropertyZoneEditor = decoded
end)

hook.Add("PostDrawTranslucentRenderables", "DRP.Properties.DrawBuildZoneEditor", function()
	if not zoneEditor or not activeZoneTool() then return end
	render.SetColorMaterial()
	for index, zone in ipairs(zoneEditor.zones or {}) do
		local base, top = zonePrism(zone)
		local color = index % 2 == 0 and Color(111, 107, 255, 220) or Color(55, 211, 255, 220)
		drawPrism(base, top, color)
	end
	local pending = pendingZonePoints()
	local trace = LocalPlayer():GetEyeTrace()
	if #pending > 0 and trace.Hit and not trace.HitSky then
		local previewColor = Color(255, 184, 71, 240)
		for index, point in ipairs(pending) do
			render.DrawSphere(point, 4, 8, 8, previewColor)
			if index > 1 then render.DrawLine(pending[index - 1], point, previewColor, false) end
		end
		if #pending < 4 then
			render.DrawLine(pending[#pending], trace.HitPos, previewColor, false)
			if #pending >= 2 then render.DrawLine(trace.HitPos, pending[1], Color(255, 184, 71, 120), false) end
		else
			local top = {}
			for index = 1, 4 do top[index] = Vector(pending[index].x, pending[index].y, trace.HitPos.z) end
			drawPrism(pending, top, previewColor)
		end
	end
end)

hook.Add("HUDPaint", "DRP.Properties.BuildZoneEditorHUD", function()
	if DRP.UI and DRP.UI.ToolgunFocus and DRP.UI.ToolgunFocus() then return end
	if not zoneEditor or not activeZoneTool() then return end
	local pending = pendingZonePoints()
	local width, height = 680, #pending > 0 and 112 or 92
	local x, y = math.floor((ScrW() - width) * 0.5), 28
	draw.RoundedBox(10, x, y, width, height, Color(7, 14, 28, 235))
	draw.RoundedBoxEx(10, x, y, 6, height, DRP.UI.Colors.accent, true, false, true, false)
	draw.SimpleText("PROPERTY BUILD ZONES  •  #" .. tostring(zoneEditor.id or 0) .. " " .. tostring(zoneEditor.name or ""), "DRP.Admin.Header", x + 20, y + 24, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText("LEFT: 4 base corners + height   •   RIGHT: remove aimed box   •   RELOAD: cancel", "DRP.Admin.Small", x + 20, y + 53, DRP.UI.Colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText(tostring(#(zoneEditor.zones or {})) .. "/32 boxes saved", "DRP.Admin.Small", x + width - 18, y + 53, DRP.UI.Colors.accent, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	if #pending > 0 then
		local instruction = #pending < 4
			and ("BASE CORNER " .. #pending .. "/4 SET — select corner " .. (#pending + 1) .. " around the perimeter")
			or "BASE COMPLETE — aim at the desired top height and left-click"
		draw.SimpleText(instruction, "DRP.Admin.Body", x + 20, y + 83, Color(255, 184, 71), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
end)

net.Receive("drp_property_manage_sync_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local shouldOpen = net.ReadBool()
	local length = net.ReadUInt(20)
	if length > 524288 then return end
	local payload = net.ReadData(length)
	local json = util.Decompress(payload or "")
	local snapshot = json and util.JSONToTable(json)
	if not istable(snapshot) then return end
	managementSnapshot = snapshot
	nextManagementRefresh = RealTime() + 0.5
	if shouldOpen or IsValid(managementFrame) then timer.Simple(0, function() PropertyUI.Open(snapshot) end) end
end)

hook.Add("DRPPropertiesUpdated", "DRP.PropertyManagement.Refresh", function(changedID)
	if not IsValid(managementFrame) or not managementSnapshot then return end
	if changedID and tonumber(changedID) ~= tonumber(managementSnapshot.id) then return end
	if RealTime() < nextManagementRefresh then return end
	nextManagementRefresh = RealTime() + 0.2
	timer.Simple(0, function()
		if IsValid(managementFrame) and managementSnapshot then PropertyUI.Request(managementSnapshot.id, false) end
	end)
end)

net.Receive("drp_property_sync_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local properties, doors = {}, {}
	for _ = 1, net.ReadUInt(8) do
		local property = {
			id = net.ReadUInt(16),
			name = net.ReadString(),
			owner = net.ReadString(),
			price = net.ReadUInt(32),
			role = net.ReadString(),
			rent = net.ReadUInt(32),
			deposit = net.ReadUInt(32),
			nextRent = net.ReadUInt(16),
			eviction = net.ReadUInt(16),
			raid = net.ReadUInt(32),
			buyable = net.ReadBool(),
			world = net.ReadBool(),
			buildZoneCount = net.ReadUInt(6),
			leaseRate = net.ReadUInt(32),
			leasePaid = net.ReadUInt(32),
			vaultCount = net.ReadUInt(6),
			canManage = net.ReadBool(),
			doors = {}
		}
		property.nextRentDeadline = property.nextRent > 0 and (RealTime() + property.nextRent) or 0
		property.evictionDeadline = property.eviction > 0 and (RealTime() + property.eviction) or 0
		property.leasePaidDeadline = property.leasePaid > 0 and (RealTime() + property.leasePaid) or 0
		for index = 1, net.ReadUInt(5) do
			local entityIndex = net.ReadUInt(13)
			property.doors[index] = entityIndex
			if entityIndex > 0 then doors[entityIndex] = property.id end
		end
		properties[property.id] = property
	end
	DRP.ClientProperties = properties
	DRP.ClientDoorProperties = doors
	hook.Run("DRPPropertiesUpdated")
end)

net.Receive("drp_property_delta_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local changedID = net.ReadUInt(16)
	local exists = net.ReadBool()
	if not exists then
		DRP.ClientProperties[changedID] = nil
	else
		local property = {
			id = net.ReadUInt(16),
			name = net.ReadString(),
			owner = net.ReadString(),
			price = net.ReadUInt(32),
			role = net.ReadString(),
			rent = net.ReadUInt(32),
			deposit = net.ReadUInt(32),
			nextRent = net.ReadUInt(16),
			eviction = net.ReadUInt(16),
			raid = net.ReadUInt(32),
			buyable = net.ReadBool(),
			world = net.ReadBool(),
			buildZoneCount = net.ReadUInt(6),
			leaseRate = net.ReadUInt(32),
			leasePaid = net.ReadUInt(32),
			vaultCount = net.ReadUInt(6),
			canManage = net.ReadBool(),
			doors = {}
		}
		property.nextRentDeadline = property.nextRent > 0 and (RealTime() + property.nextRent) or 0
		property.evictionDeadline = property.eviction > 0 and (RealTime() + property.eviction) or 0
		property.leasePaidDeadline = property.leasePaid > 0 and (RealTime() + property.leasePaid) or 0
		for index = 1, net.ReadUInt(5) do property.doors[index] = net.ReadUInt(13) end
		DRP.ClientProperties[property.id] = property
	end

	DRP.ClientDoorProperties = {}
	for propertyID, property in pairs(DRP.ClientProperties) do
		for _, entityIndex in ipairs(property.doors or {}) do
			if entityIndex > 0 then DRP.ClientDoorProperties[entityIndex] = propertyID end
		end
	end
	hook.Run("DRPPropertiesUpdated", changedID)
end)
