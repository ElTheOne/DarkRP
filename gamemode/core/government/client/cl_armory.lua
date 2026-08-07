DRP.WeaponUnlockLevels = DRP.WeaponUnlockLevels or {}

local UI = DRP.UI
local colors = UI.Colors

net.Receive("drp_weapon_unlock_sync_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local levels = {}
	for _ = 1, net.ReadUInt(12) do levels[string.lower(net.ReadString())] = net.ReadUInt(7) end
	DRP.WeaponUnlockLevels = levels
	hook.Run("DRPWeaponUnlockLevelsUpdated")
end)

net.Receive("drp_armory_open_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local armory = net.ReadEntity()
	local entries = {}
	for _ = 1, net.ReadUInt(10) do
		entries[#entries + 1] = {
			class = net.ReadString(), name = net.ReadString(), category = net.ReadString(),
			price = net.ReadUInt(16), level = net.ReadUInt(7)
		}
	end

	local frame = vgui.Create("DFrame")
	frame:SetSize(math.min(ScrW() - 80, 900), math.min(ScrH() - 80, 680))
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()
	frame.Paint = function(_, width, height)
		draw.RoundedBox(8, 0, 0, width, height, Color(10, 15, 24, 248))
		draw.RoundedBoxEx(8, 0, 0, width, 58, Color(18, 29, 47, 255), true, true, false, false)
		draw.RoundedBox(0, 0, 56, width, 2, colors.accent)
		draw.SimpleText("POLICE ARMORY", "DRP.Admin.Title", 22, 28, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("Weapons are level-gated and purchased from department stock", "DRP.Admin.Small", width - 56, 29, colors.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	end

	local search = vgui.Create("DTextEntry", frame)
	search:Dock(TOP)
	search:DockMargin(18, 68, 18, 10)
	search:SetTall(38)
	search:SetPlaceholderText("Search weapons, classes or categories...")
	search:SetUpdateOnType(true)

	local scroll = vgui.Create("DScrollPanel", frame)
	scroll:Dock(FILL)
	scroll:DockMargin(18, 0, 18, 18)

	local function rebuild(needle)
		scroll:GetCanvas():Clear()
		needle = string.lower(string.Trim(needle or ""))
		local level = tonumber(DRP.ClientProfile.level) or 1
		for _, entry in ipairs(entries) do
			local haystack = string.lower(entry.name .. " " .. entry.class .. " " .. entry.category)
			if needle == "" or string.find(haystack, needle, 1, true) then
				local row = vgui.Create("DButton", scroll)
				row:Dock(TOP)
				row:DockMargin(0, 0, 0, 7)
				row:SetTall(58)
				row:SetText("")
				row.Paint = function(self, width, height)
					local unlocked = level >= entry.level
					draw.RoundedBox(6, 0, 0, width, height, self:IsHovered() and Color(31, 47, 69, 245) or Color(18, 27, 41, 240))
					draw.RoundedBoxEx(6, 0, 0, 4, height, unlocked and colors.accent or colors.red, true, false, true, false)
					draw.SimpleText(entry.name, "DRP.Admin.Body", 18, 18, unlocked and color_white or colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
					draw.SimpleText(entry.class .. "  •  " .. entry.category, "DRP.Admin.Small", 18, 41, colors.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
					draw.SimpleText(unlocked and ("$" .. string.Comma(entry.price)) or ("UNLOCKS LEVEL " .. entry.level), "DRP.Admin.Body", width - 18, height * 0.5, unlocked and colors.green or colors.red, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
				end
				row.DoClick = function()
					if level < entry.level or not IsValid(armory) then surface.PlaySound("buttons/button10.wav") return end
					net.Start("drp_armory_buy_v1")
					net.WriteUInt(DRP.ProtocolVersion, 8)
					net.WriteEntity(armory)
					net.WriteString(entry.class)
					net.SendToServer()
				end
			end
		end
	end
	search.OnValueChange = function(_, value) rebuild(value) end
	rebuild("")
end)
