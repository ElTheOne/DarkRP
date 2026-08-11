local OPEN = "drp_bed_open_v1"
local ACTION = "drp_bed_action_v1"

local activeFrame

local function sendAction(source, action, bedID)
	if not IsValid(source) then return end
	net.Start(ACTION)
		net.WriteUInt(DRP.ProtocolVersion, 8)
		net.WriteEntity(source)
		net.WriteUInt(action, 2)
		net.WriteUInt(math.max(0, math.floor(tonumber(bedID) or 0)), 32)
	net.SendToServer()
end

local function openMenu(source, sourceID, beds)
	if IsValid(activeFrame) then activeFrame:Remove() end
	local colors = DRP.UI.Colors
	local frame = vgui.Create("DFrame")
	activeFrame = frame
	frame:SetSize(math.min(620, ScrW() - 48), math.min(620, ScrH() - 48))
	frame:Center()
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:MakePopup()
	frame:SetAlpha(0)
	frame:AlphaTo(255, 0.16, 0)
	frame.Paint = function(_, width, height)
		draw.RoundedBox(12, 0, 0, width, height, Color(5, 10, 19, 252))
		draw.RoundedBoxEx(12, 0, 0, width, 66, colors.panel, true, true, false, false)
		draw.RoundedBox(12, 0, 0, 5, height, colors.accent)
		draw.SimpleText("BASE BEDS", "DRP.Admin.Title", 24, 25, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("HOME SPAWN & FAST TRAVEL", "DRP.Admin.Small", 24, 49, colors.accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local close = DRP.UI.Button(frame, "×", colors.red, function()
		frame:AlphaTo(0, 0.12, 0, function() if IsValid(frame) then frame:Remove() end end)
	end)
	close:SetPos(frame:GetWide() - 52, 16)
	close:SetSize(34, 34)

	local hint = vgui.Create("DLabel", frame)
	hint:SetPos(24, 76)
	hint:SetSize(frame:GetWide() - 48, 44)
	hint:SetFont("DRP.Admin.Body")
	hint:SetTextColor(colors.muted)
	hint:SetWrap(true)
	hint:SetText("Set one bed as your home spawn, or travel between your bases while no incident is active.")

	local scroll = vgui.Create("DScrollPanel", frame)
	scroll:SetPos(18, 126)
	scroll:SetSize(frame:GetWide() - 36, frame:GetTall() - 144)

	if #beds == 0 then
		local empty = vgui.Create("DLabel", scroll)
		empty:Dock(TOP)
		empty:SetTall(70)
		empty:SetFont("DRP.Admin.Body")
		empty:SetTextColor(colors.muted)
		empty:SetContentAlignment(5)
		empty:SetText("No accessible beds were found.")
		return
	end

	for _, bed in ipairs(beds) do
		local row = vgui.Create("DPanel", scroll)
		row:Dock(TOP)
		row:DockMargin(6, 0, 6, 10)
		row:SetTall(90)
		row.Paint = function(_, width, height)
			draw.RoundedBox(9, 0, 0, width, height, colors.panel)
			draw.RoundedBoxEx(9, 0, 0, 5, height, bed.home and colors.green or colors.accent, true, false, true, false)
			draw.SimpleText(bed.name, "DRP.Admin.Header", 20, 25, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText("PROPERTY #" .. bed.propertyID .. (bed.home and "  •  ACTIVE HOME" or ""),
				"DRP.Admin.Small", 20, 57, bed.home and colors.green or colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		local travel = DRP.UI.Button(row, bed.id == sourceID and "CURRENT BED" or "TRAVEL", colors.accent, function()
			if bed.id == sourceID then return end
			sendAction(source, 2, bed.id)
			frame:Close()
		end)
		travel:SetSize(104, 36)
		travel:SetPos(row:GetWide() - 116, 12)
		travel:SetEnabled(bed.id ~= sourceID)
		travel.Think = function(self) self:SetPos(row:GetWide() - 116, 12) end

		if not bed.home then
			local home = DRP.UI.Button(row, "SET HOME", colors.green, function()
				sendAction(source, 1, bed.id)
				frame:Close()
			end)
			home:SetSize(104, 30)
			home:SetPos(row:GetWide() - 116, 53)
			home.Think = function(self) self:SetPos(row:GetWide() - 116, 53) end
		end
	end
end

net.Receive(OPEN, function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local source = net.ReadEntity()
	local sourceID = net.ReadUInt(32)
	local count = math.min(net.ReadUInt(6), 32)
	local beds = {}
	for index = 1, count do
		beds[index] = {
			id = net.ReadUInt(32),
			propertyID = net.ReadUInt(16),
			name = string.sub(net.ReadString(), 1, 64),
			home = net.ReadBool()
		}
	end
	if IsValid(source) then openMenu(source, sourceID, beds) end
end)
