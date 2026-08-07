local Agendas = { Values = {} }
DRP.Agendas = Agendas
DRP.Services.Register("agendas", Agendas)

local function path() return "darkrp/agendas.json" end

function Agendas:Set(ply, text)
	local job = ply:DRPJob()
	if not job.canSetAgenda or not job.agendaGroup then DRP.Net.Notify(ply, "Your job cannot set an agenda.", 3) return false end
	text = string.sub(string.Trim(tostring(text or "")), 1, 220)
	if text == "" then text = "No active agenda." end
	self.Values[job.agendaGroup] = text
	SetGlobalString("DRPAgenda." .. job.agendaGroup, text)
	file.CreateDir("darkrp")
	file.Write(path(), util.TableToJSON(self.Values, true))
	for _, target in ipairs(DRP.Players.List) do if target:DRPJob().agendaGroup == job.agendaGroup then DRP.Net.Notify(target, job.name .. " agenda: " .. text, 0) end end
	if DRP.Audit then DRP.Audit.Log(ply, "agenda_updated", nil, text) end
	return true
end

function Agendas:Get(ply)
	local group = ply:DRPJob().agendaGroup
	return group and (self.Values[group] or "No active agenda.") or "Your job has no agenda group."
end

function Agendas:Start()
	local decoded = util.JSONToTable(file.Read(path(), "DATA") or "")
	if istable(decoded) then self.Values = decoded end
	for group, text in pairs(self.Values) do SetGlobalString("DRPAgenda." .. group, text) end
end
