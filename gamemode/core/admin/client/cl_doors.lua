local UI = DRP.UI
local colors = UI.Colors
local modernButton = UI.Button
local modernFrame = UI.Frame
local sectionLabel = UI.SectionLabel
local doorFrame
local function hasPermission(permission)
	return DRP.ClientOwner or DRP.AdminMaskHas(DRP.ClientAdminMask, permission)
end
function DRP.AdminUI.CloseDoors()
	if IsValid(doorFrame) then doorFrame:Close() end
end

local function openDoorPanel(data)
	if IsValid(doorFrame) then doorFrame:Remove() end
	local frame = modernFrame("Door Management", 560, 510)
	doorFrame = frame
	frame.OnRemove = function() if doorFrame == frame then doorFrame = nil end end

	local info = vgui.Create("DLabel", frame)
	info:SetPos(24, 78)
	info:SetSize(frame:GetWide() - 48, 52)
	info:SetFont("DRP.Admin.Body")
	info:SetTextColor(colors.muted)
	info:SetText(data.class .. "  •  Map door #" .. data.mapID .. "\nCurrent owner: " .. data.owner)

	local ownable = vgui.Create("DCheckBoxLabel", frame)
	ownable:SetPos(26, 142)
	ownable:SetSize(frame:GetWide() - 52, 30)
	ownable:SetFont("DRP.Admin.Header")
	ownable:SetTextColor(color_white)
	ownable:SetText("Players can purchase this door")
	ownable:SetValue(data.ownable)

	local jobsTitle = sectionLabel(frame, "Allowed jobs")
	jobsTitle:SetPos(24, 188)
	jobsTitle:SetSize(frame:GetWide() - 48, 30)

	local hint = vgui.Create("DLabel", frame)
	hint:SetPos(24, 218)
	hint:SetSize(frame:GetWide() - 48, 24)
	hint:SetFont("DRP.Admin.Small")
	hint:SetTextColor(colors.muted)
	hint:SetText("No jobs selected means everyone can use and own it.")

	local checks = {}
	for id, job in ipairs(DRP.Jobs) do
		local jobID, jobData = id, job
		local check = vgui.Create("DCheckBoxLabel", frame)
		check:SetPos(28, 248 + ((id - 1) * 38))
		check:SetSize(frame:GetWide() - 56, 30)
		check:SetFont("DRP.Admin.Body")
		check:SetTextColor(jobData.color)
		check:SetText(jobData.name)
		check:SetValue(bit.band(data.jobs, 2 ^ (jobID - 1)) ~= 0)
		checks[jobID] = check
	end

	local save = modernButton(frame, "Save door policy", colors.accent, function()
		local jobs = 0
		for id, check in ipairs(checks) do if check:GetChecked() then jobs = jobs + (2 ^ (id - 1)) end end
		net.Start("drp_door_admin_update_v1")
		net.WriteUInt(data.entity, 13)
		net.WriteBool(ownable:GetChecked())
		net.WriteUInt(jobs, 16)
		net.SendToServer()
	end)
	save:SetPos(24, frame:GetTall() - 62)
	save:SetSize(frame:GetWide() - 48, 40)
end

net.Receive("drp_door_admin_snapshot_v1", function()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion or not hasPermission("doors") then return end
	openDoorPanel({
		entity = net.ReadUInt(13),
		mapID = net.ReadUInt(16),
		class = string.sub(net.ReadString(), 1, 48),
		ownable = net.ReadBool(),
		jobs = net.ReadUInt(16),
		owner = string.sub(net.ReadString(), 1, 64)
	})
end)
