DRP.CraftingUI = DRP.CraftingUI or { CatalogCache = {}, Fingerprint = "", CatalogRequestPending = false }
local UI = DRP.CraftingUI
UI.ViewState = UI.ViewState or {}
UI.ViewState.activeTab = tonumber(UI.ViewState.activeTab) or 1
UI.ViewState.lists = UI.ViewState.lists or {}
UI.ViewState.tree = UI.ViewState.tree or {}
if UI.ViewState.tree.search==nil then UI.ViewState.tree.search="" end
if UI.ViewState.tree.zoom==nil then UI.ViewState.tree.zoom=.78 end
if UI.ViewState.tree.offsetX==nil then UI.ViewState.tree.offsetX=0 end
if UI.ViewState.tree.offsetY==nil then UI.ViewState.tree.offsetY=0 end
if UI.ViewState.tree.showAttachments==nil then UI.ViewState.tree.showAttachments=true end
local openMessage, actionMessage, deltaMessage, cacheMessage, catalogChunkMessage, objectiveMessage = "drp_crafting_open_v1", "drp_crafting_action_v1", "drp_crafting_delta_v1", "drp_crafting_catalog_ready_v1", "drp_crafting_catalog_chunk_v1", "drp_crafting_objective_v1"
local frame, handsFrame
local cachePath="darkrp/crafting_catalog.json"
do local cached=util.JSONToTable(file.Read(cachePath,"DATA") or "") if istable(cached) and istable(cached.catalog) then UI.CatalogCache=cached.catalog UI.Fingerprint=tostring(cached.fingerprint or "") end end

local function decode()
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	local length=net.ReadUInt(24) if length<=0 or length>8388608 then return end
	local raw=util.Decompress(net.ReadData(length)) return raw and util.JSONToTable(raw) or nil
end
local function send(action,entity,writer)
	if not IsValid(entity) then return end net.Start(actionMessage) net.WriteUInt(DRP.ProtocolVersion,8) net.WriteString(action) net.WriteUInt(entity:EntIndex(),16) if writer then writer() end net.SendToServer()
end
local function close(immediate)
	if IsValid(frame) then if immediate then frame:Remove() else frame:Close() end end
	if IsValid(handsFrame) then if immediate then handsFrame:Remove() else handsFrame:Close() end end
	frame,handsFrame=nil,nil
	-- Allow a later table interaction to retry catalogue recovery.
	if #(UI.CatalogCache or {})==0 then UI.CatalogRequestPending=false end
end
local function accent() local p=LocalPlayer() return IsValid(p) and team.GetColor(p:Team()) or Color(74,205,255) end
local function recipeUnlocked(snapshot,r)
	if snapshot.level<(r.level or 1) then return false,"LEVEL "..(r.level or 1) end
	if r.schematic and not snapshot.learned[r.id] then return false,"SCHEMATIC" end
	if r.schematic_family and not snapshot.learned[r.schematic_family] then return false,"FAMILY SCHEMATIC" end
	local available={}
	for _,item in ipairs(snapshot.hands or {}) do
		local key=item.resource or item.ammo_type or item.attachment
		if key then available[key]=(available[key] or 0)+(tonumber(item.amount) or 1) end
	end
	for key,needed in pairs(r.ingredients or {}) do
		if (available[key] or 0)<needed then return false,"MATERIALS" end
	end
	return true,"READY"
end
local function ingredientsText(r)
	local out={} for key,count in SortedPairs(r.ingredients or {}) do local d=DRP.CraftingShared.Item(key) out[#out+1]=(d and d.name or key).." ×"..count end return table.concat(out,"  •  ")
end
local function buildCraftingPlan(snapshot,target)
	local byOutput,byID={},{}
	for _,recipe in ipairs(snapshot.catalog or {}) do
		byID[recipe.id]=recipe
		if string.StartWith(tostring(recipe.id or ""),"component:") then byOutput[string.sub(recipe.id,11)]=recipe.id end
	end
	local have={}
	for _,item in ipairs(snapshot.hands or {}) do local key=item.resource or item.ammo_type or item.attachment if key then have[key]=(have[key] or 0)+(tonumber(item.amount) or 1) end end
	local plan,visiting={},{}
	local function add(id)
		if visiting[id] then return end
		local recipe=byID[id] if not recipe then return end
		visiting[id]=true
		for key,needed in pairs(recipe.ingredients or {}) do if (have[key] or 0)<needed then local source=byOutput[key] if source then add(source) end end end
		visiting[id]=nil
		if not table.HasValue(plan,id) then plan[#plan+1]=id end
	end
	add(target.id)
	return plan,byID
end
function DRP.CraftingUITrack(snapshot,recipe)
	local plan,byID=buildCraftingPlan(snapshot,recipe)
	DRP.CraftingUI.TrackedPlan={ids=plan,byID=byID,index=1,target=recipe.name}
	chat.AddText(Color(90,220,150),"Crafting plan pinned: ",color_white,recipe.name,Color(170,185,200)," — prerequisites will be shown first.")
end
local function styleEntry(entry,colour)
	entry:SetTextColor(Color(225,235,245)) entry:SetPlaceholderColor(Color(125,145,165)) entry:SetCursorColor(colour)
	entry.Paint=function(self,w,h)
		draw.RoundedBox(7,0,0,w,h,Color(8,18,32,245))
		draw.RoundedBoxEx(7,0,h-2,w,2,colour,false,false,true,true)
		self:DrawTextEntryText(self:GetTextColor(),colour,self:GetTextColor())
	end
end

function UI.Open(snapshot, refreshing)
	-- Table mutations send a fresh authoritative snapshot. Replace the existing
	-- controls immediately while retaining navigation state so repeated crafts do
	-- not fade, change tabs or throw the player back to the top of the tree.
	refreshing = refreshing or IsValid(frame)
	close(refreshing)
	if istable(snapshot.catalog) and #snapshot.catalog>0 then
		UI.CatalogCache=snapshot.catalog UI.Fingerprint=snapshot.catalog_fingerprint UI.CatalogRequestPending=false
		file.CreateDir("darkrp") file.Write(cachePath,util.TableToJSON({fingerprint=UI.Fingerprint,catalog=UI.CatalogCache},false))
	end
	if tostring(snapshot.catalog_fingerprint or "") ~= tostring(UI.Fingerprint or "") then UI.CatalogCache={} end
	snapshot.catalog=UI.CatalogCache
	UI.CurrentSnapshot=snapshot
	if #UI.CatalogCache == 0 and not UI.CatalogRequestPending then
		UI.CatalogRequestPending=true
		net.Start(cacheMessage)
		net.WriteUInt(DRP.ProtocolVersion,8)
		net.WriteString("")
		net.SendToServer()
	end
	-- The panel must still open if the server is rebuilding its catalogue; the
	-- next snapshot will populate the recipe rows without trapping the player
	-- in an invisible interaction.
	local colour=accent() local leftWidth=math.max(900,ScrW()-40) local height=math.max(700,ScrH()-40)
	local recipeByID={} for _,recipe in ipairs(snapshot.catalog or {}) do recipeByID[recipe.id]=recipe end
	frame=DRP.UI.Frame("GUNSMITHING",leftWidth,height) frame:SetPos(20,20)
	if not refreshing and DRP.InventoryUI and DRP.InventoryUI.InstallFade then DRP.InventoryUI.InstallFade(frame,true) end
	frame.Think=function(self) local entity=Entity(snapshot.entity) if not IsValid(entity) or not LocalPlayer():Alive() or LocalPlayer():GetPos():DistToSqr(entity:GetPos())>220^2 then close() end end
	frame.Paint=function(_,w,h) draw.RoundedBox(12,0,0,w,h,Color(5,10,19,249)) draw.RoundedBoxEx(12,0,0,w,62,Color(13,23,39,252),true,true,false,false) draw.RoundedBox(8,0,0,5,h,colour) draw.SimpleText("GUNSMITHING","DRP.Admin.Title",22,28,color_white,TEXT_ALIGN_LEFT,TEXT_ALIGN_CENTER) draw.SimpleText("MASTERY "..snapshot.level.." / 50","DRP.Admin.Small",w-28,28,colour,TEXT_ALIGN_RIGHT,TEXT_ALIGN_CENTER) end
	local xp=vgui.Create("DPanel",frame) xp:SetPos(22,68) xp:SetSize(frame:GetWide()-44,38) xp.Paint=function(_,w,h) draw.RoundedBox(7,0,8,w,18,Color(15,25,42)) draw.RoundedBox(7,0,8,w*math.Clamp(snapshot.xp/math.max(snapshot.xp_next,1),0,1),18,colour) draw.SimpleText(snapshot.xp.." / "..snapshot.xp_next.." XP","DRP.Admin.Small",w/2,17,color_white,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER) end
	local tabs=vgui.Create("DPropertySheet",frame) tabs:SetPos(18,112) tabs:SetSize(frame:GetWide()-36,frame:GetTall()-130)
	tabs.OnActiveTabChanged=function(self,_,newTab)
		if not IsValid(newTab) then return end
		for index,item in ipairs(self.Items or {}) do if item.Tab==newTab then UI.ViewState.activeTab=index break end end
	end
	local function pageList(title,filter)
		local listState=UI.ViewState.lists[title] or {search="",grade=0,scroll=0}
		UI.ViewState.lists[title]=listState
		local panel=vgui.Create("DPanel",tabs) panel.Paint=function(_,w,h) draw.RoundedBox(8,0,0,w,h,Color(8,15,27,245)) end
		local search=vgui.Create("DTextEntry",panel) search:Dock(TOP) search:SetTall(34) search:SetPlaceholderText("Search technology and recipes...")
		styleEntry(search,colour)
		search:SetValue(tostring(listState.search or ""))
		local gradeBox=vgui.Create("DComboBox",panel) gradeBox:Dock(TOP) gradeBox:SetTall(30) gradeBox:SetSortItems(false) gradeBox:SetValue("ALL GRADES")
		gradeBox:AddChoice("ALL GRADES",0)
		for grade=1,6 do gradeBox:AddChoice(string.upper(DRP.CraftingShared.GradeNames[grade] or ("GRADE "..grade)),grade) end
		gradeBox:ChooseOptionID(math.Clamp(math.floor(tonumber(listState.grade) or 0)+1,1,7))
		gradeBox:SetTextColor(Color(215,230,242)) gradeBox.Paint=function(self,w,h) draw.RoundedBox(6,0,0,w,h,Color(10,24,40,245)) draw.RoundedBoxEx(6,0,h-2,w,2,colour,false,false,true,true) self:DrawTextEntryText(self:GetTextColor(),colour,self:GetTextColor()) end
		local list=vgui.Create("DScrollPanel",panel) list:Dock(FILL)
		local restoringScroll=true
		list.Think=function(self) if not restoringScroll and IsValid(self:GetVBar()) then listState.scroll=self:GetVBar():GetScroll() end end
		local function rebuild()
			local wantedScroll=tonumber(listState.scroll) or 0
			list:Clear() local wanted=string.lower(search:GetValue() or "")
			local _,selectedGrade=gradeBox:GetSelected()
			for _,r in ipairs(snapshot.catalog or {}) do if filter(r) and (not selectedGrade or selectedGrade==0 or tonumber(r.grade)==tonumber(selectedGrade)) and (wanted=="" or string.find(string.lower(r.name.." "..r.category),wanted,1,true)) then
				local row=vgui.Create("DButton",list) row:Dock(TOP) row:DockMargin(6,6,6,0) row:SetTall(82) row:SetText("")
				local icon=vgui.Create("SpawnIcon",row) icon:SetSize(64,64) icon:SetPos(8,9) icon:SetModel((r.output and r.output.model) or r.model or "models/props_lab/box01a.mdl") icon:SetTooltip(r.name or r.id)
				local ok,state=recipeUnlocked(snapshot,r)
				row.Paint=function(_,w,h) draw.RoundedBox(8,0,0,w,h,Color(13,23,39,248)) draw.RoundedBoxEx(8,0,0,4,h,ok and colour or Color(100,110,128),true,false,true,false) draw.SimpleText(r.name,"DRP.Admin.Header",82,18,color_white) draw.SimpleText((DRP.CraftingShared.GradeNames[r.grade] or "Grade").."  •  "..state.."  •  "..math.ceil(r.time).."s  •  +"..r.xp.." XP","DRP.Admin.Small",82,40,ok and colour or Color(150,158,172)) draw.SimpleText(ingredientsText(r),"DRP.Admin.Small",82,62,Color(170,180,194)) end
				row:SetTooltip("Exact ingredients:\n"..ingredientsText(r).."\n\nRight-click to track as an objective.")
				row.DoClick=function() if ok then send("start",Entity(snapshot.entity),function() net.WriteString(r.id) net.WriteUInt(1,8) end) else surface.PlaySound("buttons/button10.wav") end end
				row.DoRightClick=function() send("track",Entity(snapshot.entity),function() net.WriteString(r.id) end) end
			end end
			restoringScroll=true
			timer.Simple(0,function()
				if not IsValid(list) or not IsValid(list:GetVBar()) then return end
				list:GetVBar():SetScroll(wantedScroll)
				timer.Simple(0,function() if IsValid(list) then restoringScroll=false end end)
			end)
		end
		search.OnValueChange=function(self) listState.search=self:GetValue() or "" listState.scroll=0 rebuild() end
		gradeBox.OnSelect=function(_,_,_,data) listState.grade=tonumber(data) or 0 listState.scroll=0 rebuild() end
		rebuild() tabs:AddSheet(title,panel,nil) return panel
	end
	local function technologyTree()
		local treeState=UI.ViewState.tree
		-- Dependency edges inherit the grade of the item they originate from. The
		-- same palette is used by the grade headings so the graph has a visible key.
		local gradeColours={
			Color(88,220,132),  -- Grade I
			Color(66,205,238),  -- Grade II
			Color(78,132,255),  -- Grade III
			Color(174,104,255), -- Grade IV
			Color(244,190,72),  -- Grade V
			Color(255,92,82)    -- Ordnance
		}
		local panel=vgui.Create("DPanel",tabs) panel.Paint=function(_,w,h) draw.RoundedBox(8,0,0,w,h,Color(8,15,27,245)) end
		local toolbar=vgui.Create("DPanel",panel) toolbar:Dock(TOP) toolbar:SetTall(42) toolbar.Paint=nil
		local search=vgui.Create("DTextEntry",toolbar) search:Dock(LEFT) search:SetWide(310) search:DockMargin(6,4,8,4) search:SetPlaceholderText("Filter dependency tree...")
		styleEntry(search,colour)
		search:SetValue(tostring(treeState.search or ""))
		local attachmentToggle=vgui.Create("DCheckBoxLabel",toolbar)
		attachmentToggle:Dock(RIGHT) attachmentToggle:SetWide(190) attachmentToggle:DockMargin(12,7,8,5)
		attachmentToggle:SetText("SHOW ATTACHMENTS") attachmentToggle:SetFont("DRP.Admin.Small") attachmentToggle:SetTextColor(Color(205,220,235))
		attachmentToggle:SetChecked(treeState.showAttachments~=false)
		local zoomLabel=vgui.Create("DLabel",toolbar) zoomLabel:Dock(LEFT) zoomLabel:SetWide(62) zoomLabel:SetText("ZOOM") zoomLabel:SetFont("DRP.Admin.Small") zoomLabel:SetTextColor(Color(170,180,194))
		local zoom=vgui.Create("DNumSlider",toolbar) zoom:Dock(FILL) zoom:SetMin(.55) zoom:SetMax(1.15) zoom:SetDecimals(2) zoom:SetValue(tonumber(treeState.zoom) or .78)
		local viewport=vgui.Create("DPanel",panel) viewport:Dock(FILL) viewport:SetMouseInputEnabled(true) viewport.Paint=function(_,w,h) surface.SetDrawColor(5,10,18,180) surface.DrawRect(0,0,w,h) end
		local canvas=vgui.Create("DPanel",viewport) local offsetX,offsetY,dragX,dragY=tonumber(treeState.offsetX) or 0,tonumber(treeState.offsetY) or 0
		local focusedID=treeState.focusedID
		local rebuild
		canvas.OnMousePressed=function(_,code) if code==MOUSE_RIGHT then focusedID=nil treeState.focusedID=nil timer.Simple(0,rebuild) end end
		viewport.OnMousePressed=function(_,code)
			if code==MOUSE_RIGHT then focusedID=nil treeState.focusedID=nil timer.Simple(0,rebuild) return end
			if code==MOUSE_LEFT or code==MOUSE_MIDDLE then local mx,my=gui.MousePos() dragX,dragY=mx-offsetX,my-offsetY viewport:MouseCapture(true) end
		end
		viewport.OnMouseReleased=function() dragX,dragY=nil,nil viewport:MouseCapture(false) end
		viewport.OnMouseWheeled=function(_,delta)
			if input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL) then
				zoom:SetValue(math.Clamp(zoom:GetValue()+delta*.05,.55,1.15))
			else
				-- Scroll the dependency canvas vertically; the Think layout below
				-- clamps this against the full tree height.
				offsetY=offsetY+delta*96
			end
			return true
		end
		viewport.Think=function()
			if dragX and input.IsMouseDown(MOUSE_LEFT) or dragX and input.IsMouseDown(MOUSE_MIDDLE) then local mx,my=gui.MousePos() offsetX,offsetY=mx-dragX,my-dragY elseif dragX then dragX,dragY=nil,nil viewport:MouseCapture(false) end
			offsetX=math.Clamp(offsetX,math.min(0,viewport:GetWide()-canvas:GetWide()),0) offsetY=math.Clamp(offsetY,math.min(0,viewport:GetTall()-canvas:GetTall()),0) canvas:SetPos(offsetX,offsetY)
			treeState.offsetX,treeState.offsetY=offsetX,offsetY
		end
		local nodes,byOutput={},{}
		for _,recipe in ipairs(snapshot.catalog or {}) do if recipe.id and string.StartWith(recipe.id,"component:") then byOutput[string.sub(recipe.id,11)]=recipe.id end end
		rebuild=function()
			for _,node in pairs(nodes) do if IsValid(node.button) then node.button:Remove() end end nodes={}
			local scale=zoom:GetValue() local wanted=string.lower(search:GetValue() or "") local rows={}
			local showAttachments=attachmentToggle:GetChecked()
			if not showAttachments and focusedID then
				for _,candidate in ipairs(snapshot.catalog or {}) do if candidate.id==focusedID and candidate.kind=="attachment" then focusedID=nil treeState.focusedID=nil break end end
			end
			for grade=1,6 do rows[grade]=0 end
			local related={}
			if focusedID then
				related[focusedID]=true
			local focusedRecipe
			for _,candidate in ipairs(snapshot.catalog or {}) do if candidate.id==focusedID then focusedRecipe=candidate break end end
			-- Keep direct prerequisites only.
			if focusedRecipe then for ingredient in pairs(focusedRecipe.ingredients or {}) do local sourceID=byOutput[ingredient] if sourceID then related[sourceID]=true end end end
			-- Attachment compatibility is a real tree relationship. Keep the weapon
			-- nodes when focusing an attachment, and vice versa.
			if focusedRecipe and focusedRecipe.kind=="attachment" then for _,weaponID in ipairs(focusedRecipe.compatible_weapon_ids or {}) do related[weaponID]=true end end
			if focusedRecipe and focusedRecipe.kind=="weapon" then for _,candidate in ipairs(snapshot.catalog or {}) do if candidate.kind=="attachment" and table.HasValue(candidate.compatible_weapon_ids or {},focusedID) then related[candidate.id]=true end end end
			-- Keep direct consumers only.  Do not recursively expand the graph;
			-- that makes unrelated distant recipes appear in focused mode.
			local focusedOutput=string.sub(tostring(focusedID),11)
			for _,candidate in ipairs(snapshot.catalog or {}) do
				for ingredient in pairs(candidate.ingredients or {}) do if ingredient==focusedOutput then related[candidate.id]=true break end end
			end
		end
			local gradeSpacing,rowSpacing,nodeWidth,nodeHeight=500,150,380,104
			for _,recipe in ipairs(snapshot.catalog or {}) do
				if (showAttachments or recipe.kind~="attachment") and (not focusedID or related[recipe.id]) and (wanted=="" or string.find(string.lower(recipe.name.." "..tostring(recipe.category or "")),wanted,1,true)) then
					local grade=math.Clamp(tonumber(recipe.grade) or 1,1,6) rows[grade]=rows[grade]+1
					local x=(grade-1)*gradeSpacing*scale+32 local y=(rows[grade]-1)*rowSpacing*scale+64 local w,h=nodeWidth*scale,nodeHeight*scale
					local button=vgui.Create("DButton",canvas) button:SetPos(x,y) button:SetSize(w,h) button:SetText("")
					local ok,state=recipeUnlocked(snapshot,recipe)
					button.Paint=function(self,bw,bh)
						local selected=focusedID==recipe.id
						draw.RoundedBox(7,0,0,bw,bh,selected and Color(20,82,57,252) or (self:IsHovered() and Color(25,40,62,252) or Color(13,23,39,248)))
						draw.RoundedBoxEx(7,0,0,selected and 7 or 4,bh,selected and Color(82,230,145) or (ok and colour or Color(100,110,128)),true,false,true,false)
						if selected then surface.SetDrawColor(82,230,145,190) surface.DrawOutlinedRect(1,1,bw-2,bh-2,2) end
						draw.SimpleText(recipe.name,"DRP.Admin.Body",12,17*scale,color_white,TEXT_ALIGN_LEFT,TEXT_ALIGN_CENTER)
						draw.SimpleText("LVL "..recipe.level.."  •  "..state,"DRP.Admin.Small",12,43*scale,ok and colour or Color(150,158,172),TEXT_ALIGN_LEFT,TEXT_ALIGN_CENTER)
						local badge=ok and Color(82,220,145) or Color(255,190,82)
						draw.RoundedBox(10,bw-28,8,20,20,badge)
						draw.SimpleText(ok and "✓" or "!","DRP.Admin.Small",bw-18,18,Color(5,15,24),TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
					end
				local compatibilityTooltip=recipe.kind=="attachment" and ("\nCompatible weapons: "..(#(recipe.compatible_weapons or {})>0 and table.concat(recipe.compatible_weapons,", ") or "None detected")) or ""
				button:SetTooltip(ingredientsText(recipe).."\n"..math.ceil(recipe.time).." seconds  •  +"..recipe.xp.." mastery XP"..compatibilityTooltip)
				button.DoClick=function() if ok then send("start",Entity(snapshot.entity),function() net.WriteString(recipe.id) net.WriteUInt(1,8) end) end end
				button.DoRightClick=function() focusedID=(focusedID==recipe.id) and nil or recipe.id treeState.focusedID=focusedID rebuild() send("track",Entity(snapshot.entity),function() net.WriteString(recipe.id) end) end
				nodes[recipe.id]={recipe=recipe,button=button,x=x,y=y,w=w,h=h}
				end
			end
			local maxRows=0 for _,count in ipairs(rows) do maxRows=math.max(maxRows,count) end
			canvas:SetSize(5*gradeSpacing*scale+nodeWidth*scale+80,math.max(viewport:GetTall(),maxRows*rowSpacing*scale+110))
			canvas.Paint=function(_,cw,ch)
				for grade=1,6 do local gx=(grade-1)*gradeSpacing*scale+32 draw.SimpleText(DRP.CraftingShared.GradeNames[grade] or ("GRADE "..grade),"DRP.Admin.Header",gx,30,gradeColours[grade],TEXT_ALIGN_LEFT,TEXT_ALIGN_CENTER) end
				-- Showing every edge at once produces an unreadable web.  Only render
				-- the focused recipe's prerequisites and dependants.
				local focus
				for _,node in pairs(nodes) do if IsValid(node.button) and node.button:IsHovered() then focus=node break end end
				if not focus then return end
				local function edge(source,target)
					local grade=math.Clamp(tonumber(source.recipe and source.recipe.grade) or 1,1,6)
					local edgeColour=gradeColours[grade]
					local x1,y1=source.x+source.w,source.y+source.h/2
					local x2,y2=target.x,target.y+target.h/2
					-- A dark underlay and two-pixel coloured stroke keep nearby branches
					-- distinguishable without returning to the old solid-blue web.
					surface.SetDrawColor(2,7,14,230)
					surface.DrawLine(x1,y1-1,x2,y2-1)
					surface.DrawLine(x1,y1+2,x2,y2+2)
					surface.SetDrawColor(edgeColour.r,edgeColour.g,edgeColour.b,235)
					surface.DrawLine(x1,y1,x2,y2)
					surface.DrawLine(x1,y1+1,x2,y2+1)
				end
				for ingredient in pairs(focus.recipe.ingredients or {}) do local source=nodes[byOutput[ingredient]] if source then edge(source,focus) end end
				local focusOutput=string.sub(tostring(focus.recipe.id or ""),11)
				for _,node in pairs(nodes) do if node~=focus then for ingredient in pairs(node.recipe.ingredients or {}) do if ingredient==focusOutput then edge(focus,node) break end end end end
				if focus.recipe.kind=="attachment" then for _,weaponID in ipairs(focus.recipe.compatible_weapon_ids or {}) do local weaponNode=nodes[weaponID] if weaponNode then edge(focus,weaponNode) end end end
				if focus.recipe.kind=="weapon" then for _,node in pairs(nodes) do if node.recipe.kind=="attachment" and table.HasValue(node.recipe.compatible_weapon_ids or {},focus.recipe.id) then edge(node,focus) end end end
			end
		end
		search.OnValueChange=function(self) treeState.search=self:GetValue() or "" rebuild() end
		zoom.OnValueChanged=function(self,value) treeState.zoom=tonumber(value) or .78 rebuild() end
		attachmentToggle.OnChange=function(_,checked) treeState.showAttachments=checked and true or false rebuild() end
		panel.PerformLayout=function() timer.Create("DRP.Crafting.TreeLayout",0,1,rebuild) end
		rebuild() tabs:AddSheet("Technology Tree",panel,nil)
	end
	technologyTree()
	pageList("Weapons",function(r) return r.kind=="weapon" end)
	pageList("Attachments",function(r) return r.kind=="attachment" end)
	pageList("Components",function(r) return r.kind=="component" or r.kind=="equipment" or r.kind=="research" end)
	local queue=vgui.Create("DScrollPanel",tabs) queue.Paint=function(_,w,h) draw.RoundedBox(8,0,0,w,h,Color(8,15,27,245)) end
	for _,job in ipairs(snapshot.queue or {}) do local definition=recipeByID[job.recipe] local due=math.max(0,(tonumber(job.due) or 0)-os.time()) local r=vgui.Create("DButton",queue) r:Dock(TOP) r:DockMargin(6,6,6,0) r:SetTall(50) r:SetText("#"..job.id.."  "..(definition and definition.name or job.recipe).." ×"..job.amount..(due>0 and ("  •  "..string.ToMinutesSeconds(due)) or "  •  QUEUED").."   — click to cancel") r.DoClick=function() send("cancel",Entity(snapshot.entity),function() net.WriteUInt(job.id,32) end) end end
	tabs:AddSheet("Queue",queue,nil)
	local output=vgui.Create("DPanel",tabs) output.Paint=function(_,w,h) draw.RoundedBox(8,0,0,w,h,Color(8,15,27,245)) draw.SimpleText(#(snapshot.output or {}).." completed item(s)","DRP.Admin.Header",20,20,color_white) end
	local claim=vgui.Create("DButton",output) claim:SetPos(20,55) claim:SetSize(220,42) claim:SetText("CLAIM AVAILABLE OUTPUT") claim.DoClick=function() send("claim",Entity(snapshot.entity)) end tabs:AddSheet("Output",output,nil)
	local protected=vgui.Create("DButton",output) protected:SetPos(250,55) protected:SetSize(220,42) protected:SetText("CRAFTING CLAIMS ("..#(snapshot.claims or {})..")") protected.DoClick=function() send("claims",Entity(snapshot.entity)) end
	local outputList=vgui.Create("DScrollPanel",output) outputList:Dock(FILL) outputList:DockMargin(16,108,16,16)
	for _,item in ipairs(snapshot.output or {}) do local row=vgui.Create("DPanel",outputList) row:Dock(TOP) row:DockMargin(4,0,4,6) row:SetTall(44) row.Paint=function(_,w,h) draw.RoundedBox(6,0,0,w,h,Color(13,23,39,248)) draw.SimpleText(tostring(item.label or item.class or "Crafted item")..((item.amount or 1)>1 and (" ×"..item.amount) or ""),"DRP.Admin.Body",12,13,color_white) draw.SimpleText("Crafter: "..tostring(item.crafter or item.owner or "Unknown"),"DRP.Admin.Small",12,31,Color(160,170,184)) end end
	local dismantle=vgui.Create("DPanel",tabs) dismantle.Paint=function(_,w,h) draw.RoundedBox(8,0,0,w,h,Color(8,15,27,245)) draw.SimpleText("Right-click a weapon or attachment in Hands and choose Dismantle at this table.","DRP.Admin.Body",20,20,color_white) end tabs:AddSheet("Dismantling",dismantle,nil)
	tabs.Paint=function(_,w,h) draw.RoundedBox(10,0,0,w,h,Color(5,12,23,238)) end
	timer.Simple(0,function()
		for _,item in ipairs(tabs.Items or {}) do
			local tab=item.Tab
			if IsValid(tab) then
				tab:SetText(string.upper(tab:GetText() or "")) tab:SetFont("DRP.Admin.Small") tab:SetTextColor(Color(150,170,190))
				tab.Paint=function(self,w,h)
					local active=tabs:GetActiveTab()==self
					draw.RoundedBox(6,1,2,w-2,h-4,active and Color(24,62,82,250) or Color(10,22,37,235))
					draw.RoundedBoxEx(6,1,h-4,w-2,2,active and colour or Color(38,60,78),false,false,true,true)
				end
			end
		end
		local wanted=math.Clamp(math.floor(tonumber(UI.ViewState.activeTab) or 1),1,#(tabs.Items or {}))
		local item=tabs.Items and tabs.Items[wanted]
		if item and IsValid(item.Tab) then tabs:SetActiveTab(item.Tab) end
	end)
	-- The workbench is a focused full-screen interface. Hands stays closed here;
	-- inventory management remains available through the normal Hands menu.
end

local incomingCatalogs={}
net.Receive(catalogChunkMessage,function()
	if net.ReadUInt(8)~=DRP.ProtocolVersion then return end
	local fingerprint=string.sub(net.ReadString(),1,32) local index=net.ReadUInt(16) local count=net.ReadUInt(16) local length=net.ReadUInt(16)
	if fingerprint=="" or count<1 or count>1024 or index<1 or index>count or length>48000 then return end
	local transfer=incomingCatalogs[fingerprint]
	if not transfer or transfer.count~=count then transfer={count=count,chunks={},received=0} incomingCatalogs[fingerprint]=transfer end
	if not transfer.chunks[index] then transfer.chunks[index]=net.ReadData(length) transfer.received=transfer.received+1 else net.ReadData(length) end
	if transfer.received<count then return end
	local compressed=table.concat(transfer.chunks) local raw=util.Decompress(compressed) local catalog=raw and util.JSONToTable(raw) or nil incomingCatalogs[fingerprint]=nil
	if not istable(catalog) or #catalog==0 then UI.CatalogRequestPending=false return end
	UI.CatalogCache=catalog UI.Fingerprint=fingerprint UI.CatalogRequestPending=false file.CreateDir("darkrp") file.Write(cachePath,util.TableToJSON({fingerprint=fingerprint,catalog=catalog},false))
	net.Start(cacheMessage) net.WriteUInt(DRP.ProtocolVersion,8) net.WriteString(fingerprint) net.SendToServer()
	if istable(UI.CurrentSnapshot) then local current=table.Copy(UI.CurrentSnapshot) current.catalog=catalog current.catalog_fingerprint=fingerprint timer.Simple(0,function() UI.Open(current) end) end
end)

net.Receive(openMessage,function() local data=decode() if data then UI.Open(data) end end)
net.Receive(objectiveMessage,function()
	if net.ReadUInt(8)~=DRP.ProtocolVersion then return end
	local length=net.ReadUInt(16) if length<=0 or length>65535 then return end
	local data=util.JSONToTable(util.Decompress(net.ReadData(length)) or "")
	if not istable(data) or not istable(data.steps) then return end
	local byID={} local ids={}
	for _,step in ipairs(data.steps) do byID[step.id]=step ids[#ids+1]=step.id end
	UI.TrackedPlan={ids=ids,byID=byID,index=math.Clamp(tonumber(data.index) or 1,1,math.max(#ids,1)),target=data.target}
	hook.Run("DRPObjectivesUpdated",DRP.ObjectivesClient and DRP.ObjectivesClient.Offers or {},DRP.ObjectivesClient and DRP.ObjectivesClient.Active or {},DRP.ObjectivesClient and DRP.ObjectivesClient.RoleGoal or nil,DRP.ObjectivesClient and DRP.ObjectivesClient.Guide or {})
end)
net.Receive(deltaMessage,function()
	local data=decode() if not data then return end UI.Profile=data
	if istable(UI.CurrentSnapshot) then
		for key,value in pairs(data) do if key~="profile" then UI.CurrentSnapshot[key]=value end end
		if IsValid(frame) then timer.Create("DRP.Crafting.ProfileRefresh",.05,1,function() if IsValid(frame) and istable(UI.CurrentSnapshot) then UI.Open(UI.CurrentSnapshot) end end) end
	end
end)
hook.Add("HUDPaint","DRP.Crafting.PlanObjective",function()
	local plan=DRP.CraftingUI.TrackedPlan
	if not plan or not plan.ids or #plan.ids==0 then return end
	local current=plan.byID[plan.ids[math.min(plan.index or 1,#plan.ids)]] or plan.byID[plan.ids[#plan.ids]]
	local requirements={}
	for _,requirement in ipairs(current and current.requirements or {}) do requirements[#requirements+1]=requirement.name.." "..requirement.have.."/"..requirement.needed end
	local first,second={},{}
	for index,textValue in ipairs(requirements) do if index<=3 then first[#first+1]=textValue elseif index<=6 then second[#second+1]=textValue end end
	if #requirements>6 then second[#second+1]="+"..(#requirements-6).." more" end
	local w,h=520,104 local x=ScrW()-w-28 local y=ScrH()-h-150
	draw.RoundedBox(10,x,y,w,h,Color(7,17,29,235))
	draw.RoundedBoxEx(10,x,y,4,h,Color(87,210,145),true,false,true,true)
	draw.SimpleText("CRAFTING PLAN","DRP.Admin.Small",x+18,y+16,Color(87,210,145))
	draw.SimpleText("PREREQUISITE "..math.min(plan.index or 1,#plan.ids).." / "..#plan.ids,"DRP.Admin.Header",x+18,y+35,color_white)
	draw.SimpleText(current and current.name or plan.target or "Target item","DRP.Admin.Small",x+w-14,y+38,Color(175,195,210),TEXT_ALIGN_RIGHT)
	draw.SimpleText(#requirements>0 and ("REQUIRES  "..table.concat(first,"  •  ")) or "ALL REQUIRED MATERIALS AVAILABLE","DRP.Admin.Small",x+18,y+61,#requirements>0 and Color(230,190,95) or Color(87,210,145))
	if #second>0 then draw.SimpleText(table.concat(second,"  •  "),"DRP.Admin.Small",x+18,y+78,Color(180,195,208)) end
	draw.SimpleText("Right-click another recipe to replace plan","DRP.Admin.Small",x+18,y+95,Color(110,130,148))
end)
hook.Add("DRPInventoryContextOpening","DRP.Crafting.Close",function(context) if context~="crafting" then close() end end)
hook.Add("InitPostEntity","DRP.Crafting.CatalogCache",function()
	timer.Simple(1,function()
		if not IsValid(LocalPlayer()) then return end
		net.Start(cacheMessage)
		net.WriteUInt(DRP.ProtocolVersion,8)
		-- Never claim a cached fingerprint when the catalogue itself is empty or
		-- corrupt; otherwise the server correctly omits the catalogue and the UI
		-- has no recipes to render.
		net.WriteString(#(UI.CatalogCache or {}) > 0 and (UI.Fingerprint or "") or "")
		net.SendToServer()
	end)
end)
