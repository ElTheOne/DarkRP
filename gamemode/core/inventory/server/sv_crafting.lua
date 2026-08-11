local Crafting = {
	SchemaVersion = DRP.CraftingShared.SchemaVersion, Recipes = {}, Catalog = {}, Excluded = {}, Profiles = {}, Tables = {}, ByEntity = setmetatable({}, {__mode="k"}),
	NextTableID = 1, NextJobID = 1, DirtyWorld = false, WorldRevision = 0, DataDirectory = "darkrp/crafting", WorldKey = "crafting:" .. game.GetMap(), OpenViewers=setmetatable({}, {__mode="k"}),
	MaxQueue = 5, MaxOutputRecords=64, RaidLootDuration = 120, Overrides = {}, BlockedWeapons = { arc9_base=true, arc9_go_base=true },
	CatalogTransfers = {}, CatalogTransferHead = 1, CatalogChunkSize = 48000, CatalogChunksPerTick = 2, CatalogPumpArmed = false,
	CatalogHasAttachments = false, ARC9RegisteredAttachmentCount = 0
}
-- Gunsmithing progression is intentionally faster than the base recipe XP so
-- players can reach meaningful crafting tiers without grinding for days.
Crafting.XPMultiplier = 2.5
DRP.Crafting = Crafting
DRP.Services.Register("crafting", Crafting)
DRP.Services.DependsOn("crafting", { "storage", "network", "inventory" })

local openMessage, actionMessage, deltaMessage, cacheMessage, catalogChunkMessage, objectiveMessage = "drp_crafting_open_v1", "drp_crafting_action_v1", "drp_crafting_delta_v1", "drp_crafting_catalog_ready_v1", "drp_crafting_catalog_chunk_v1", "drp_crafting_objective_v1"
util.AddNetworkString(openMessage) util.AddNetworkString(actionMessage) util.AddNetworkString(deltaMessage) util.AddNetworkString(cacheMessage) util.AddNetworkString(catalogChunkMessage) util.AddNetworkString(objectiveMessage)

local function notify(ply, text, kind) if IsValid(ply) then DRP.Net.Notify(ply, text, kind or 0) end end
local function sid(ply) return IsValid(ply) and ply:SteamID64() or tostring(ply or "") end
local function profileDefault() return {schema=DRP.CraftingShared.SchemaVersion,level=1,xp=0,learned={},claims={},revision=0} end
local function profile(ply)
	local id = sid(ply)
	Crafting.Profiles[id] = Crafting.Profiles[id] or profileDefault()
	return Crafting.Profiles[id]
end
local function touchProfile(p) p.revision=math.max(os.time()*1000,math.floor(tonumber(p.revision) or 0)+1) end
local function validModel(model, fallback)
	return isstring(model) and model ~= "" and util.IsValidModel(model) and model or (fallback or "models/props_lab/box01a.mdl")
end
local function cleanRecord(record)
	record = table.Copy(record or {})
	record.x,record.y,record.w,record.h,record.rotated = nil,nil,nil,nil,nil
	record.amount = math.max(1, math.floor(tonumber(record.amount) or 1))
	return record
end
local function resource(key, amount) return DRP.CraftingShared.ItemRecord(key, amount) end
local function addRecipe(recipe)
	if not istable(recipe) or not isstring(recipe.id) or Crafting.Recipes[recipe.id] then return false end
	recipe.grade = math.Clamp(math.floor(tonumber(recipe.grade) or 1),1,6)
	-- Mastery is predictable by technology grade: Grade I = 20 XP, Grade II
	-- = 40 XP, etc.  This also applies to generated ARC9 weapon recipes.
	recipe.xp = recipe.grade * 20
	recipe.level = tonumber(recipe.level) or DRP.CraftingShared.GradeLevels[recipe.grade]
	recipe.time = math.max(1, tonumber(recipe.time) or 30)
	recipe.amount = math.max(1, math.floor(tonumber(recipe.amount) or 1))
	recipe.ingredients = recipe.ingredients or {}
	recipe.category = recipe.category or "Components"
	Crafting.Recipes[recipe.id] = recipe
	Crafting.Catalog[#Crafting.Catalog+1] = recipe
	return true
end

local foundations = {
	{ "steel_bar","Steel Bar",1,12,2,{ferrous_scrap=3} }, {"aluminium_plate","Aluminium Plate",1,12,2,{aluminium_offcuts=3}},
	{"copper_coil","Copper Coil",1,10,2,{copper_wire=3}}, {"polymer_sheet","Polymer Sheet",1,10,2,{polymer_scrap=3}},
	{"treated_stock","Treated Stock",1,15,2,{hardwood_offcuts=3,adhesive_compound=1}}, {"woven_cloth","Woven Cloth",1,10,2,{cloth_roll=2}},
	{"spring_set","Spring Set",1,18,8,{steel_bar=1,fastener_kit=1}}, {"adhesive_compound","Adhesive Compound",1,10,2,{chemical_reagent=1,polymer_scrap=1}},
	{"receiver_blank","Receiver Blank",1,25,8,{steel_bar=2,fastener_kit=1}}, {"pistol_receiver","Pistol Receiver",2,40,12,{receiver_blank=1,steel_bar=1}},
	{"smg_receiver","SMG Receiver",3,60,14,{receiver_blank=2,steel_bar=1}}, {"shotgun_receiver","Shotgun Receiver",3,60,14,{receiver_blank=2,steel_bar=1}},
	{"rifle_receiver","Rifle Receiver",4,80,16,{receiver_blank=2,steel_bar=2}}, {"precision_receiver","Precision Receiver",5,110,20,{rifle_receiver=1,calibrated_parts=2}},
	{"heavy_receiver","Heavy Receiver",5,130,20,{rifle_receiver=2,steel_bar=3}}, {"short_barrel","Short Barrel",2,35,10,{steel_bar=2}},
	{"shotgun_barrel","Shotgun Barrel",3,55,12,{barrel_blank=1,steel_bar=2}}, {"rifle_barrel","Rifle Barrel",4,75,16,{barrel_blank=1,steel_bar=3}},
	{"precision_barrel","Precision Barrel",5,110,20,{rifle_barrel=1,calibrated_parts=2}}, {"barrel_blank","Barrel Blank",1,30,8,{steel_bar=2}},
	{"bolt_assembly","Bolt Assembly",2,35,10,{steel_bar=1,spring_set=1}}, {"heavy_bolt","Heavy Bolt",5,80,20,{bolt_assembly=2,steel_bar=2}},
	{"calibrated_bolt","Calibrated Bolt",5,90,20,{bolt_assembly=1,calibrated_parts=2}}, {"action_assembly","Action Assembly",3,50,14,{steel_bar=2,spring_set=1}},
	{"gas_system","Gas System",3,45,14,{steel_bar=1,copper_coil=1}}, {"trigger_group","Trigger Group",2,30,10,{steel_bar=1,spring_set=1}},
	{"grip_assembly","Grip Assembly",2,25,8,{polymer_sheet=1,fastener_kit=1}}, {"stock_assembly","Stock Assembly",2,35,10,{treated_stock=1,fastener_kit=1}},
	{"magazine_body","Magazine Body",2,25,8,{aluminium_plate=1,spring_set=1}}, {"tube_magazine","Tube Magazine",3,40,12,{steel_bar=1,spring_set=1}},
	{"drum_assembly","Drum Assembly",5,80,20,{magazine_body=2,spring_set=2}}, {"cooling_jacket","Cooling Jacket",5,85,20,{aluminium_plate=2,steel_bar=1}},
	{"optic_housing","Optic Housing",4,60,16,{aluminium_plate=1,fastener_kit=1}}, {"electronic_control_unit","Electronic Control Unit",5,100,20,{circuit_components=2,copper_coil=1}},
	{"suppressor_baffle_set","Suppressor Baffle Set",4,80,16,{steel_bar=2,fastener_kit=1}}, {"calibrated_parts","Calibrated Parts",4,75,16,{steel_bar=1,fastener_kit=2}},
	{"fuse_assembly","Fuse Assembly",6,60,20,{copper_wire=1,chemical_reagent=1}}, {"explosive_compound","Explosive Compound",6,90,20,{chemical_reagent=3,propellant_powder=3}},
	{"detonator","Detonator",6,90,20,{electronic_control_unit=1,copper_coil=1}}, {"fragmentation_shell","Fragmentation Shell",6,75,20,{steel_bar=2,fastener_kit=1}},
	{"smoke_compound","Smoke Compound",6,60,20,{chemical_reagent=2,propellant_powder=1}}, {"incendiary_compound","Incendiary Compound",6,75,20,{chemical_reagent=2,propellant_powder=2}},
	{"shaped_charge","Shaped Charge",6,120,20,{explosive_compound=2,steel_bar=1}}, {"rocket_motor","Rocket Motor",6,120,20,{steel_bar=2,propellant_powder=4,electronic_control_unit=1}}
}

local function baseRecipes()
	for _, row in ipairs(foundations) do addRecipe({id="component:"..row[1],name=row[2],kind="component",category=(DRP.CraftingShared.Item(row[1]).group=="refined") and "Refining" or "Components",grade=row[3],time=row[4],xp=row[5],ingredients=row[6],output=resource(row[1],1)}) end
	for grade=1,5 do
		local output=resource("research_folio_g"..grade,1) output.grade=grade
		addRecipe({id="research:folio_g"..grade,name="Grade "..grade.." Research Folio",kind="research",category="Research",grade=grade,time=60+grade*15,xp=10*grade,ingredients={["technical_notes_g"..grade]=10},output=output})
	end
	addRecipe({id="equipment:vice",name="Bench Vice & Drill",kind="equipment",category="Workbench",grade=3,time=180,xp=40,ingredients={steel_bar=4,electronic_control_unit=1,fastener_kit=4},output=resource("bench_vice_drill",1)})
	addRecipe({id="equipment:rifling",name="Rifling Rig",kind="equipment",category="Workbench",grade=4,time=300,xp=60,ingredients={steel_bar=6,calibrated_parts=3,electronic_control_unit=1},output=resource("rifling_rig",1)})
	addRecipe({id="equipment:precision",name="Precision Gauge Set",kind="equipment",category="Workbench",grade=5,time=420,xp=80,ingredients={calibrated_parts=5,optic_glass=2,electronic_control_unit=2},output=resource("precision_gauge_set",1)})
	addRecipe({id="equipment:optic_alignment",name="Optic Alignment Jig",kind="equipment",category="Workbench",grade=5,time=360,xp=80,ingredients={optic_housing=2,optic_glass=3,calibrated_parts=3,electronic_control_unit=1},output=resource("optic_alignment_jig",1)})
	addRecipe({id="equipment:ordnance",name="Ordnance Toolkit",kind="equipment",category="Workbench",grade=6,time=480,xp=100,ingredients={steel_bar=5,electronic_control_unit=3,chemical_reagent=4},output=resource("ordnance_toolkit",1)})
end

local lethalFragments={"frag","hegrenade","molotov","incendiary","c4","mine","claymore","breach","rocket","rpg","landmine"}
local nonlethalFragments={"smoke","flash","decoy","sonar"}
local function containsAny(text, list) for _,v in ipairs(list) do if string.find(text,v,1,true) then return true end end return false end
local function classifyWeapon(class, data)
	local text=string.lower(class.." "..tostring(data.PrintName or "").." "..tostring(data.Class or "").." "..tostring(data.HoldType or ""))
	if containsAny(text,lethalFragments) then return "ordnance",6,true end
	if containsAny(text,nonlethalFragments) then return "ordnance",6,false end
	if string.find(text,"knife",1,true) or tostring(data.HoldType)=="knife" or tostring(data.HoldType)=="melee" then return "melee",1,false end
	if string.find(text,"akimbo",1,true) then return "akimbo",2,false end
	if string.find(text,"sniper",1,true) or string.find(text,"awp",1,true) or string.find(text,"scout",1,true) then return "precision",5,false end
	if string.find(text,"lmg",1,true) or tostring(data.HoldType)=="crossbow" then return "heavy",5,false end
	if tostring(data.HoldType)=="shotgun" or string.find(text,"shotgun",1,true) then return "shotgun",3,false end
	if tostring(data.HoldType)=="smg" or string.find(text,"smg",1,true) then return "smg",3,false end
	if tostring(data.HoldType)=="ar2" or string.find(text,"rifle",1,true) then return "rifle",4,false end
	return "pistol",2,false
end
local templates={
	pistol={pistol_receiver=1,short_barrel=1,bolt_assembly=1,trigger_group=1,grip_assembly=1,magazine_body=1},
	akimbo={pistol_receiver=2,short_barrel=2,bolt_assembly=2,trigger_group=2,grip_assembly=2,magazine_body=2},
	smg={smg_receiver=1,short_barrel=1,bolt_assembly=1,gas_system=1,trigger_group=1,grip_assembly=1,stock_assembly=1,magazine_body=1},
	shotgun={shotgun_receiver=1,shotgun_barrel=1,action_assembly=1,trigger_group=1,stock_assembly=1,tube_magazine=1},
	rifle={rifle_receiver=1,rifle_barrel=1,bolt_assembly=1,gas_system=1,trigger_group=1,grip_assembly=1,stock_assembly=1,magazine_body=1},
	precision={precision_receiver=1,precision_barrel=1,calibrated_bolt=1,trigger_group=1,stock_assembly=1},
	heavy={heavy_receiver=1,rifle_barrel=1,heavy_bolt=1,gas_system=1,trigger_group=1,stock_assembly=1,drum_assembly=1,cooling_jacket=1},
	melee={steel_bar=2,grip_assembly=1,woven_cloth=1},
	ordnance={explosive_compound=1,fuse_assembly=1,fragmentation_shell=1}
}
local function ordnanceIngredients(class, data)
	local text=string.lower(tostring(class or "").." "..tostring(data.PrintName or ""))
	if containsAny(text,{"smoke"}) then return {smoke_compound=2,fuse_assembly=1,aluminium_plate=1} end
	if containsAny(text,{"flash","decoy","sonar"}) then return {chemical_reagent=2,fuse_assembly=1,electronic_control_unit=1,aluminium_plate=1} end
	if containsAny(text,{"molotov","incendiary"}) then return {incendiary_compound=2,fuse_assembly=1,woven_cloth=1,aluminium_plate=1} end
	if containsAny(text,{"breach"}) then return {shaped_charge=1,detonator=1,adhesive_compound=1} end
	if containsAny(text,{"rocket","rpg"}) then return {rocket_motor=1,explosive_compound=2,detonator=1,shaped_charge=1} end
	if containsAny(text,{"c4","mine","landmine","claymore"}) then
		return {explosive_compound=2,detonator=1,electronic_control_unit=1,[containsAny(text,{"claymore"}) and "fragmentation_shell" or "shaped_charge"]=1}
	end
	return {explosive_compound=1,fuse_assembly=1,fragmentation_shell=1}
end
local function eligibleWeapon(class,data)
	if not string.StartWith(class,"arc9_go_") then return false,"outside arc9_go namespace" end
	if Crafting.BlockedWeapons[class] then return false,"blocked system/base weapon" end
	if data.AdminOnly then return false,"AdminOnly" end
	if data.Spawnable==false then return false,"not spawnable" end
	if string.find(class,"base",1,true) then return false,"base class" end
	return true
end
local function weaponOutput(class,data) return {kind="weapon",class=class,label=tostring(data.PrintName or class),model=validModel(data.WorldModel),hold_type=data.HoldType,clip1=-1,clip2=-1} end
local function buildWeapons()
	local listed=list.Get("Weapon") or {}
	local classes={}
	for class in pairs(listed) do classes[class]=true end
	for _,class in ipairs(weapons.GetList and weapons.GetList() or {}) do if istable(class) and class.ClassName then classes[class.ClassName]=true end end
	for class in pairs(classes) do
		local data=weapons.GetStored(class) or listed[class] or {}
		local eligible,excludedReason=eligibleWeapon(class,data)
		if eligible then
			local family,grade,lethal=classifyWeapon(class,data)
			local override=Crafting.Overrides[class] or {}
			grade=override.grade or grade family=override.family or family
			local ingredients=override.ingredients or (family=="ordnance" and ordnanceIngredients(class,data)) or templates[family]
			addRecipe({id="weapon:"..class,name=tostring(data.PrintName or class),kind="weapon",category=family=="ordnance" and "Ordnance" or "Weapons",class=class,grade=grade,time=override.time or (90+grade*60),xp=(family=="ordnance" and 80 or 60)*grade,ingredients=table.Copy(ingredients),schematic=true,lethal=lethal,output=weaponOutput(class,data)})
		elseif string.StartWith(class,"arc9_go_") then Crafting.Excluded[#Crafting.Excluded+1]={kind="weapon",id=class,reason=excludedReason} end
	end
end
local function buildAmmunition()
	local seen={}
	for _,r in ipairs(Crafting.Catalog) do if r.kind=="weapon" and r.class then
		local data=weapons.GetStored(r.class) or (list.Get("Weapon") or {})[r.class] or {} local ammo=tostring(data.Ammo or (istable(data.Primary) and data.Primary.Ammo) or "")
		if ammo~="" and ammo~="none" and game.GetAmmoID(ammo)>=0 and not seen[ammo] then local lower=string.lower(ammo) local shells=containsAny(lower,{"buck","shotgun","12g","shell"}) local ingredients=shells and {shell_hulls=2,primer_tray=1,shot_pellets=2,propellant_powder=1} or {brass_casings=2,primer_tray=1,projectile_cores=2,propellant_powder=1} seen[ammo]=true addRecipe({id="ammo:"..ammo,name=ammo.." Ammunition Batch",kind="ammo",category="Ammunition",grade=1,time=35,xp=10,ingredients=ingredients,output={kind="ammo",class="drp_ammo_stack",ammo_type=ammo,label=ammo.." Ammunition",model=shells and "models/items/boxbuckshot.mdl" or "models/items/boxsrounds.mdl",amount=30}}) end
	end end
end
local function attachmentGrade(key,data)
	local text=string.lower(key.." "..tostring(data.PrintName or "").." "..table.concat(istable(data.Category) and data.Category or {tostring(data.Category or "")}," "))
	if containsAny(text,{"thermal","hybrid","conversion","high capacity","drum","electronic","magnified","scope"}) then return 5 end
	if containsAny(text,{"optic","sight","suppress","silencer","barrel"}) then return 4 end
	if string.find(text,"muzzle",1,true) then return 3 end
	return 2
end
local function attachmentIngredients(key,data,grade)
	local categories=istable(data.Category) and table.concat(data.Category," ") or tostring(data.Category or "")
	local text=string.lower(key.." "..tostring(data.PrintName or "").." "..categories)
	if containsAny(text,{"optic","scope","sight"}) then return {optic_housing=1,optic_glass=1,fastener_kit=1,[grade>=5 and "electronic_control_unit" or "aluminium_plate"]=1} end
	if string.find(text,"barrel",1,true) then return {barrel_blank=1,steel_bar=1} end
	if containsAny(text,{"muzzle","suppress","silencer"}) then return {steel_bar=1,suppressor_baffle_set=1,fastener_kit=1} end
	if string.find(text,"stock",1,true) then return {stock_assembly=1} end
	if containsAny(text,{"grip","underbarrel"}) then return {grip_assembly=1,polymer_sheet=1,fastener_kit=1} end
	if containsAny(text,{"mag","drum"}) then return {magazine_body=1,spring_set=1,[string.find(text,"drum",1,true) and "drum_assembly" or "fastener_kit"]=1} end
	if containsAny(text,{"tactical","laser","light"}) then return {electronic_control_unit=1,copper_coil=1,aluminium_plate=1} end
	return {calibrated_parts=1,spring_set=1,fastener_kit=1}
end
local function categorySet(value)
	local result={}
	if istable(value) then for _,category in pairs(value) do result[tostring(category)]=true end
	elseif value~=nil then result[tostring(value)]=true end
	return result
end
local function compatibleWeaponNames(attachmentData)
	local attachmentCategories=categorySet(attachmentData.Category)
	local names,ids={},{}
	for _,weaponRecipe in ipairs(Crafting.Catalog or {}) do if weaponRecipe.kind=="weapon" and weaponRecipe.class then
		local weaponData=weapons.GetStored(weaponRecipe.class) or (list.Get("Weapon") or {})[weaponRecipe.class] or {}
		for _,slot in pairs(weaponData.Attachments or {}) do
			local matches=false for category in pairs(categorySet(slot.Category)) do if attachmentCategories[category] then matches=true break end end
			if matches then names[#names+1]=weaponRecipe.name ids[#ids+1]=weaponRecipe.id break end
		end
	end end
	local paired={} for index,name in ipairs(names) do paired[#paired+1]={name=name,id=ids[index]} end
	table.sort(paired,function(a,b) return a.name<b.name end) names,ids={},{}
	for _,entry in ipairs(paired) do names[#names+1]=entry.name ids[#ids+1]=entry.id end
	return names,ids
end
local function buildAttachments()
	if not ARC9 or not istable(ARC9.Attachments) then return end
	for key,data in pairs(ARC9.Attachments) do
		local reason=not istable(data) and "invalid definition" or (data.Free and "free attachment") or (data.AdminOnly and "AdminOnly") or (data.Hidden and "hidden") or (data.Ignore and "compatibility alias") or (data.InvAtt and "inventory alias") or ((data.Developer or data.DevOnly) and "developer only")
		if not reason then
			local grade=attachmentGrade(key,data)
			local categoryValue=data.Category
			local categoryKey=istable(categoryValue) and (util.TableToJSON(categoryValue,false) or "general") or tostring(categoryValue or "general")
			local compatibleNames,compatibleIDs=compatibleWeaponNames(data)
			local lowestWeaponGrade
			for _,weaponID in ipairs(compatibleIDs) do local weaponRecipe=Crafting.Recipes[weaponID] if weaponRecipe then lowestWeaponGrade=math.min(lowestWeaponGrade or 6,tonumber(weaponRecipe.grade) or 1) end end
			if lowestWeaponGrade then grade=math.Clamp(lowestWeaponGrade+1,2,6) end
			local family="attachment:"..util.CRC(categoryKey..":grade:"..grade)
			local attachmentText=string.lower(key.." "..tostring(data.PrintName or "").." "..categoryKey)
			addRecipe({id="attachment:"..key,name=tostring(data.PrintName or key),kind="attachment",category="Attachments",attachment=key,compatible_weapons=compatibleNames,compatible_weapon_ids=compatibleIDs,grade=grade,time=45+grade*35,xp=20*grade,ingredients=attachmentIngredients(key,data,grade),schematic_family=family,requires_equipment=grade>=5 and containsAny(attachmentText,{"optic","scope","sight","thermal","hybrid"}) and "optic_alignment_jig" or nil,output={kind="attachment",class="drp_crafting_item",attachment=key,label=tostring(data.PrintName or key),model=validModel(data.Model,"models/props_lab/box01a.mdl"),amount=1}})
		else Crafting.Excluded[#Crafting.Excluded+1]={kind="attachment",id=tostring(key),reason=reason} end
	end
end

function Crafting:BuildCatalog()
	self.Recipes,self.Catalog,self.Excluded={},{},{}
	baseRecipes() buildWeapons() buildAmmunition() buildAttachments()
	table.sort(self.Catalog,function(a,b) if a.grade==b.grade then return a.name<b.name end return a.grade<b.grade end)
	local compact={}
	self.CatalogHasAttachments=false
	local fingerprintParts={"schema="..tostring(DRP.CraftingShared.SchemaVersion)}
	for _,r in ipairs(self.Catalog) do
		if r.kind=="attachment" then self.CatalogHasAttachments=true end
		compact[#compact+1]={id=r.id,name=r.name,kind=r.kind,category=r.category,grade=r.grade,level=r.level,time=r.time,xp=r.xp,ingredients=r.ingredients,schematic=r.schematic==true,schematic_family=r.schematic_family,requires_equipment=r.requires_equipment,lethal=r.lethal==true,class=r.class,attachment=r.attachment,compatible_weapons=r.compatible_weapons,compatible_weapon_ids=r.compatible_weapon_ids}
	end
	for _,r in ipairs(self.Catalog) do local ingredients={} for key,count in SortedPairs(r.ingredients) do ingredients[#ingredients+1]=key.."="..count end fingerprintParts[#fingerprintParts+1]=table.concat({r.id,r.name,r.grade,r.level,r.time,r.xp,r.schematic_family or "",r.requires_equipment or "",table.concat(ingredients,",")},"|") end
	self.CatalogJSON=util.TableToJSON(compact,false) or "[]"
	self.CatalogFingerprint=util.CRC(table.concat(fingerprintParts,"\n"))
	self.CatalogCompressed=util.Compress(self.CatalogJSON) or ""
	return #self.Catalog
end
function Crafting:CatalogKindCount(kind)
	local count=0 for _,recipe in ipairs(self.Catalog or {}) do if recipe.kind==kind then count=count+1 end end return count
end
function Crafting:RefreshARC9Catalog(force)
	if not force and self.CatalogHasAttachments then return true end
	local registered=ARC9 and istable(ARC9.Attachments) and table.Count(ARC9.Attachments) or 0
	if registered<=0 then return false end
	self.ARC9RegisteredAttachmentCount=registered
	self:BuildCatalog()
	for _,ply in player.Iterator() do ply.DRPCraftingCatalogFingerprint=nil end
	local attachmentRecipes=self:CatalogKindCount("attachment")
	print(string.format("[DRP CRAFTING] ARC9 refresh: registered=%d attachment_recipes=%d total_recipes=%d",registered,attachmentRecipes,#self.Catalog))
	return self.CatalogHasAttachments
end
function Crafting:Recipe(id) return self.Recipes[tostring(id or "")] end
function Crafting:TrackObjective(ply,recipeID)
	local target=self:Recipe(recipeID) if not target or not IsValid(ply) then return false end
	local available={}
	for _,item in ipairs(DRP.Inventory.Items(ply) or {}) do local key=item.resource or item.ammo_type or item.attachment if key then available[key]=(available[key] or 0)+(tonumber(item.amount) or 1) end end
	local byOutput,steps,visiting={}, {}, {}
	for id,recipe in pairs(self.Recipes) do if string.StartWith(id,"component:") then byOutput[string.sub(id,11)]=id end end
	local function add(id)
		if visiting[id] then return end local recipe=self:Recipe(id) if not recipe then return end visiting[id]=true
		for key,needed in pairs(recipe.ingredients or {}) do if (available[key] or 0)<needed and byOutput[key] then add(byOutput[key]) end end
		visiting[id]=nil
		for _,entry in ipairs(steps) do if entry.id==id then return end end
		local requirements={}
		for key,needed in SortedPairs(recipe.ingredients or {}) do
			local definition=DRP.CraftingShared.Item(key)
			requirements[#requirements+1]={key=key,name=definition and definition.name or key,needed=needed,have=available[key] or 0,missing=math.max(0,needed-(available[key] or 0))}
		end
		steps[#steps+1]={id=id,name=recipe.name,grade=recipe.grade,requirements=requirements}
	end
	add(recipeID)
	net.Start(objectiveMessage) net.WriteUInt(DRP.ProtocolVersion,8)
	local payload=util.Compress(util.TableToJSON({target=target.name,steps=steps,index=1},false) or "{}") or ""
	net.WriteUInt(math.min(#payload,65535),16) if #payload>0 then net.WriteData(payload,math.min(#payload,65535)) end net.Send(ply)
	if DRP.Objectives and DRP.Objectives.Popup then DRP.Objectives:Popup(ply,2,"Crafting objective pinned",("Build prerequisites for %s first (%d step%s).%s"):format(target.name,#steps,#steps==1 and "" or "s",#steps>1 and " Use the counter on your HUD to track progress." or "")) end
	return true
end
function Crafting:SchematicRecord(recipe)
	if not istable(recipe) then return nil end
	local key=recipe.schematic_family or recipe.id
	return {kind="schematic",class="drp_crafting_item",schematic=key,grade=recipe.grade,label=(recipe.schematic_family and "Family Schematic: " or "Schematic: ")..recipe.name,model="models/props_lab/clipboard.mdl",amount=1}
end
local structural={"ferrous_scrap","aluminium_offcuts","copper_wire","polymer_scrap","hardwood_offcuts","cloth_roll","fastener_kit"}
local ammoMaterials={"brass_casings","primer_tray","projectile_cores","shell_hulls","shot_pellets","propellant_powder"}
local refined={"steel_bar","aluminium_plate","copper_coil","polymer_sheet","treated_stock","woven_cloth","spring_set","adhesive_compound"}
local commonComponents={"receiver_blank","short_barrel","barrel_blank","bolt_assembly","trigger_group","grip_assembly","magazine_body"}
local precisionComponents={"precision_receiver","precision_barrel","calibrated_bolt","calibrated_parts","optic_glass","circuit_components","electronic_control_unit"}
local controlledComponents={"explosive_compound","detonator","fuse_assembly","fragmentation_shell","smoke_compound","incendiary_compound","shaped_charge"}
local specialist={"bench_vice_drill","rifling_rig","precision_gauge_set","optic_alignment_jig","ordnance_toolkit"}
local function pickRecord(pool,minimum,maximum)
	if not istable(pool) or #pool==0 then return nil end
	local total,weighted=0,{}
	for _,key in ipairs(pool) do local factor=DRP.EconomyDirector and DRP.EconomyDirector:LootFactor("resource:"..key) or 1 total=total+factor weighted[#weighted+1]={key=key,ceiling=total} end
	local needle=math.Rand(0,total) local key=weighted[#weighted].key
	for _,entry in ipairs(weighted) do if needle<=entry.ceiling then key=entry.key break end end
	return resource(key,math.random(minimum or 1,maximum or 1))
end
function Crafting:GeneratePersonalLoot(ply)
	local roll=math.random(1,100) local record
	if roll<=52 then record=pickRecord(structural,1,4)
	elseif roll<=70 then record=pickRecord(ammoMaterials,1,4)
	elseif roll<=82 then record=pickRecord(refined,1,2)
	elseif roll<=92 then return nil -- caller retains its existing production-resource roll
	else record=pickRecord(commonComponents,1,1) end
	return record
end
local function weightedGrade(maxGrade)
	local roll=math.random(1,100) local grade=roll<=50 and 1 or (roll<=78 and 2 or (roll<=92 and 3 or (roll<=98 and 4 or 5))) return math.min(grade,maxGrade or 5)
end
function Crafting:GenerateSchematicLoot(grade)
	grade=math.Clamp(math.floor(tonumber(grade) or 1),1,6)
	local choices={}
	for _,r in ipairs(self.Catalog) do if r.grade==grade and (r.schematic or r.schematic_family) then choices[#choices+1]=r end end
	local chosen=table.Random(choices)
	return chosen and self:SchematicRecord(chosen) or nil
end
function Crafting:GenerateRareLoot(ply,containerKind,excludeSchematics)
	local roll=math.random(1,100) local maxGrade=containerKind=="trashcan" and 3 or 5
	if excludeSchematics then
		if roll<=36 then local pool={} for _,key in ipairs(specialist) do local defGrade=key=="bench_vice_drill" and 3 or (key=="rifling_rig" and 4 or 5) if defGrade<=maxGrade then pool[#pool+1]=key end end return #pool>0 and pickRecord(pool,1,1) or pickRecord(refined,1,1)
		elseif roll<=65 then return pickRecord(precisionComponents,1,1)
		elseif roll<=84 then return containerKind=="dumpster" and pickRecord(controlledComponents,1,1) or pickRecord(commonComponents,1,1)
		elseif roll<=97 then local choices={} for _,r in ipairs(self.Catalog) do if r.kind=="attachment" and r.grade<=math.min(2,maxGrade) then choices[#choices+1]=r end end local chosen=table.Random(choices) return chosen and cleanRecord(chosen.output) or pickRecord(commonComponents,1,1)
		else local choices={} for _,r in ipairs(self.Catalog) do if r.kind=="weapon" and r.grade<=2 and not r.lethal then choices[#choices+1]=r end end local chosen=table.Random(choices) return chosen and cleanRecord(chosen.output) or pickRecord(precisionComponents,1,1) end
	end
	if roll<=38 then local grade=weightedGrade(maxGrade) local choices={} for _,r in ipairs(self.Catalog) do if r.grade==grade and (r.schematic or r.schematic_family) then choices[#choices+1]=r end end local chosen=table.Random(choices) return chosen and self:SchematicRecord(chosen) or pickRecord(precisionComponents,1,1)
	elseif roll<=60 then local pool={} for _,key in ipairs(specialist) do local defGrade=key=="bench_vice_drill" and 3 or (key=="rifling_rig" and 4 or 5) if defGrade<=maxGrade then pool[#pool+1]=key end end return #pool>0 and pickRecord(pool,1,1) or pickRecord(refined,1,1)
	elseif roll<=78 then return pickRecord(precisionComponents,1,1)
	elseif roll<=90 then return containerKind=="dumpster" and pickRecord(controlledComponents,1,1) or pickRecord(commonComponents,1,1)
	elseif roll<=98 then local choices={} for _,r in ipairs(self.Catalog) do if r.kind=="attachment" and r.grade<=math.min(2,maxGrade) then choices[#choices+1]=r end end local chosen=table.Random(choices) return chosen and cleanRecord(chosen.output) or pickRecord(commonComponents,1,1)
	else local choices={} for _,r in ipairs(self.Catalog) do if r.kind=="weapon" and r.grade<=2 and not r.lethal then choices[#choices+1]=r end end local chosen=table.Random(choices) return chosen and cleanRecord(chosen.output) or pickRecord(precisionComponents,1,1) end
end
function Crafting:GenerateArmoryReward()
	if math.random(1,2)==1 then local choices={} for _,r in ipairs(self.Catalog) do if r.grade>=3 and r.grade<=5 and (r.schematic or r.schematic_family) then choices[#choices+1]=r end end local chosen=table.Random(choices) if chosen then return self:SchematicRecord(chosen) end end
	return pickRecord(math.random(1,4)==1 and controlledComponents or precisionComponents,1,1)
end
function Crafting:Mastery(ply) local p=profile(ply) return p.level,p.xp end
function Crafting:AddMastery(ply,amount,reason,alreadyBoosted)
	if not IsValid(ply) or amount<=0 then return 0 end
	amount=math.floor(amount*(tonumber(self.XPMultiplier) or 1))
	if not alreadyBoosted then amount=math.floor(DRP.Supporter and DRP.Supporter.ApplyReward and DRP.Supporter.ApplyReward(ply,amount) or amount) end
	local p=profile(ply) local granted=amount
	while amount>0 and p.level<50 do local need=DRP.CraftingShared.XPForNext(p.level)-p.xp local move=math.min(need,amount) p.xp=p.xp+move amount=amount-move if p.xp>=DRP.CraftingShared.XPForNext(p.level) then p.xp=0 p.level=p.level+1 notify(ply,"Gunsmithing mastery reached level "..p.level..".",1) end end
	if p.level>=50 then p.level=50 p.xp=0 end
	if p.level>=5 then p.learned["weapon:arc9_go_glock"]=true end
	touchProfile(p) self:SavePlayer(ply) self:SendDelta(ply)
	hook.Run("DRPCraftingMastery",ply,granted,reason)
	return granted
end
function Crafting:AddMasteryID(ownerID,amount,reason)
	local online=player.GetBySteamID64(tostring(ownerID or ""))
	if IsValid(online) then return self:AddMastery(online,amount,reason,true) end
	local id=tostring(ownerID or "") if id=="" then return 0 end local p=self.Profiles[id]
	if not p then local raw=file.Read(self.DataDirectory.."/"..id..".json","DATA") p=raw and util.JSONToTable(raw) or profileDefault() self.Profiles[id]=p end
	p.level=math.Clamp(math.floor(tonumber(p.level) or 1),1,50) p.xp=math.max(0,math.floor(tonumber(p.xp) or 0)) p.learned=istable(p.learned) and p.learned or {} p.claims=istable(p.claims) and p.claims or {}
	local remaining=math.max(0,math.floor(tonumber(amount) or 0)) local granted=remaining
	while remaining>0 and p.level<50 do local need=DRP.CraftingShared.XPForNext(p.level)-p.xp local move=math.min(need,remaining) p.xp=p.xp+move remaining=remaining-move if p.xp>=DRP.CraftingShared.XPForNext(p.level) then p.xp=0 p.level=p.level+1 end end
	if p.level>=5 then p.learned["weapon:arc9_go_glock"]=true end touchProfile(p) self:SaveProfileID(id,p) return granted
end

local function inventoryCounts(ply)
	local result={}
	for _,item in ipairs(DRP.Inventory.Items(ply)) do if item.kind=="resource" then result[item.resource]=(result[item.resource] or 0)+(item.amount or 1) end end
	return result
end
local function canRemoveIngredients(ply, ingredients, amount)
	local have=inventoryCounts(ply)
	for key,count in pairs(ingredients) do if (have[key] or 0)<count*amount then return false,key,count*amount-(have[key] or 0) end end
	return true
end
local function reserveIngredients(ply, ingredients, amount)
	local ok,reserved=DRP.Inventory.ReserveResources(ply,ingredients,amount)
	return ok and reserved or nil
end
local function returnRecords(ply, records)
	if IsValid(ply) and DRP.Inventory.CanInsertBatch(ply,records) then for _,r in ipairs(records) do DRP.Inventory.InsertRaw(ply,r) end return true end
	local p=profile(ply) for _,r in ipairs(records or {}) do p.claims[#p.claims+1]=cleanRecord(r) end
	if IsValid(ply) then Crafting:SavePlayer(ply) Crafting:SendDelta(ply) end
	return false
end
local function tableRecord(entity) return IsValid(entity) and Crafting.Tables[tostring(entity.DRPCraftingTableID or "")] end
local function canInteract(ply,entity)
	if not IsValid(ply) or not ply:Alive() or not IsValid(entity) or ply:GetPos():DistToSqr(entity:GetPos())>200^2 then return false end
	local tr=util.TraceLine({start=ply:EyePos(),endpos=entity:WorldSpaceCenter(),filter=ply,mask=MASK_SOLID}) return not tr.Hit or tr.Entity==entity
end
local function activeRaid(propertyID) return DRP.Properties and DRP.Properties.ActiveRaids[tonumber(propertyID)] end
local function isGovernment(ply) local j=IsValid(ply) and ply:DRPJob() or {} return j.isPolice or j.isMayor or j.isGovernment end
local function hasEquipment(record,key)
	for _,value in ipairs(record.upgrades or {}) do if (istable(value) and value.resource or value)==key then return true end end
	return false
end
local requiredEquipment={[3]="bench_vice_drill",[4]="rifling_rig",[5]="precision_gauge_set",[6]="ordnance_toolkit"}

function Crafting:CanCraft(ply,entity,recipeID,amount)
	local recipe,record=self:Recipe(recipeID),tableRecord(entity) amount=math.Clamp(math.floor(tonumber(amount) or 1),1,20)
	if not IsValid(ply) or not recipe or not record then return false,"Crafting data is unavailable." end
	if isGovernment(ply) then return false,"Government roles may claim completed work but cannot begin crafts." end
	if activeRaid(record.property_id) then return false,"Crafting controls are locked during a property raid." end
	if not DRP.Properties or not DRP.Properties.Can(ply,record.property_id,"crafting") then return false,"You do not have this property's crafting permission." end
	local p=profile(ply) if p.level<recipe.level then return false,"Requires Gunsmithing level "..recipe.level.."." end
	if recipe.schematic and not p.learned[recipe.id] then return false,"You have not learned this weapon schematic." end
	if recipe.schematic_family and not p.learned[recipe.schematic_family] then return false,"You have not learned this attachment-family schematic." end
	local equipmentGrade=recipe.grade
	if recipe.kind=="equipment" then equipmentGrade=math.max(2,recipe.grade-1) end
	local equipment=requiredEquipment[equipmentGrade] if equipment and not hasEquipment(record,equipment) then return false,"Workbench requires "..(DRP.CraftingShared.Item(equipment).name).."." end
	if recipe.requires_equipment and not hasEquipment(record,recipe.requires_equipment) then return false,"Workbench requires "..(DRP.CraftingShared.Item(recipe.requires_equipment).name).."." end
	if recipe.lethal then local job=ply:DRPJob() if not job.canRaid or (DRP.Civic and DRP.Civic:Get(ply) or 0)>-525 then return false,"Lethal ordnance requires raid capability and civic standing of -525 or lower." end end
	if #record.queue>=self.MaxQueue then return false,"This table already has one active and four queued crafts." end
	local projected=#record.output+amount for _,queued in ipairs(record.queue) do projected=projected+(queued.amount or 1) end if projected>self.MaxOutputRecords then return false,"Workbench output capacity is reserved by existing jobs." end
	local ok,key,missing=canRemoveIngredients(ply,recipe.ingredients,amount) if not ok then return false,"Missing "..missing.." × "..(DRP.CraftingShared.Item(key) and DRP.CraftingShared.Item(key).name or key).."." end
	return true,amount,recipe,record
end
function Crafting:StartCraft(ply,entity,recipeID,amount)
	local ok,value,recipe,record=self:CanCraft(ply,entity,recipeID,amount) if not ok then notify(ply,value,3) return false,value end amount=value
	local escrow=reserveIngredients(ply,recipe.ingredients,amount) if not escrow then return false,"Ingredient reservation failed." end
	local job={id=self.NextJobID,recipe=recipe.id,amount=amount,owner=sid(ply),owner_name=ply:DRPName(),escrow=escrow,created=os.time(),started=0,due=0,mastery_level=profile(ply).level,mastery_xp=DRP.Supporter and DRP.Supporter.ApplyReward(ply,recipe.xp*amount) or recipe.xp*amount}
	self.NextJobID=self.NextJobID+1 record.queue[#record.queue+1]=job self:StartNext(record) self:MarkWorldDirty() self:SaveWorld() self:SendTable(record)
	notify(ply,recipe.name.." added to the crafting queue.",1) return true,job
end
function Crafting:StartNext(record)
	local job=record and record.queue[1] if not job or job.started>0 then return end
	local recipe=self:Recipe(job.recipe)
	if not recipe then
		table.remove(record.queue,1)
		self:AddClaimID(job.owner,job.escrow or {})
		self:MarkWorldDirty()
		ErrorNoHalt("[DRP CRAFTING] returned escrow for unavailable recipe "..tostring(job.recipe).." (job "..tostring(job.id)..")\n")
		return self:StartNext(record)
	end
	local owner=player.GetBySteamID64(job.owner) local level=job.mastery_level or (IsValid(owner) and profile(owner).level or 1)
	job.started=os.time() job.due=job.started+math.ceil(recipe.time*job.amount*DRP.CraftingShared.TimeMultiplier(level))
	DRP.Deadlines.Schedule("crafting:"..record.id..":"..job.id,CurTime()+math.max(0,job.due-os.time()),function() self:CompleteCraft(record.id,job.id) end)
end
function Crafting:CompleteCraft(tableID,jobID)
	local record=self.Tables[tostring(tableID)] if not record then return false end local job=record.queue[1]
	if not job or job.id~=jobID then return false end local recipe=self:Recipe(job.recipe)
	if not recipe then
		table.remove(record.queue,1) self:AddClaimID(job.owner,job.escrow or {}) self:StartNext(record) self:MarkWorldDirty() self:SaveWorld() self:SendTable(record)
		ErrorNoHalt("[DRP CRAFTING] completion returned escrow for unavailable recipe "..tostring(job.recipe).." (job "..tostring(job.id)..")\n")
		return false
	end
	-- Escrow remains part of circulation while a job is queued. Consume it only
	-- at the atomic completion transition, then introduce the finished output.
	if DRP.EconomyDirector then
		for _,input in ipairs(job.escrow or {}) do local key=DRP.Commodities and DRP.Commodities.Key(input) if key then DRP.EconomyDirector:RecordItem(key,-(tonumber(input.amount) or 1),"escrow","transform","craft:"..tostring(recipe.id)) end end
	end
	for i=1,job.amount do
		local out=cleanRecord(recipe.output) out.owner=job.owner out.crafter=job.owner_name out.source_job=job.id record.output[#record.output+1]=out
		if DRP.EconomyDirector then
			local commodity=DRP.Commodities and DRP.Commodities.Key(out)
			if commodity then DRP.EconomyDirector:RecordItem(commodity, tonumber(out.amount) or 1, "output", "transform", "craft:" .. tostring(recipe.id)) end
		end
	end
	table.remove(record.queue,1) self:AddMasteryID(job.owner,job.mastery_xp or recipe.xp*job.amount,"crafting:"..recipe.id)
	self:StartNext(record) self:MarkWorldDirty() self:SaveWorld() self:SendTable(record)
	local owner=player.GetBySteamID64(job.owner) if IsValid(owner) then notify(owner,recipe.name.." completed at your workbench.",1) end
	hook.Run("DRPCraftCompleted",owner,recipe,job,record) return true
end
function Crafting:CancelCraft(ply,entity,jobID)
	local record=tableRecord(entity) if not record or activeRaid(record.property_id) then notify(ply,"Crafting is locked during this raid.",3) return false end
	if not DRP.Properties.Can(ply,record.property_id,"crafting") then return false end
	for index,job in ipairs(record.queue) do if job.id==tonumber(jobID) and (job.owner==sid(ply) or DRP.Properties.Can(ply,record.property_id,"finances")) then
		DRP.Deadlines.Cancel("crafting:"..record.id..":"..job.id) table.remove(record.queue,index) local target=player.GetBySteamID64(job.owner) if IsValid(target) then returnRecords(target,job.escrow) else self:AddClaimID(job.owner,job.escrow) end if index==1 then self:StartNext(record) end
		self:MarkWorldDirty() self:SaveWorld() self:SendTable(record) return true
	end end return false
end
function Crafting:ClaimOutput(ply,entity,ids)
	local record=tableRecord(entity) if not record then return false end
	local raid=activeRaid(record.property_id) if raid then notify(ply,"Output is locked while the raid is active.",3) return false end
	local wanted={} for _,id in ipairs(ids or {}) do wanted[tostring(id)]=true end local transfer={}
	for index=#record.output,1,-1 do local item=record.output[index] local key=tostring(item.source_job or index)..":"..index
		local lootAllowed=record.raid_loot_until and record.raid_loot_until>=os.time() and record.raid_raiders and record.raid_raiders[sid(ply)]
		if (next(wanted)==nil or wanted[key]) and (item.owner==sid(ply) or lootAllowed) then transfer[#transfer+1]=item table.remove(record.output,index) end
	end
	if #transfer==0 then return false end
	if not DRP.Inventory.CanInsertBatch(ply,transfer) then for _,item in ipairs(transfer) do record.output[#record.output+1]=item end notify(ply,"Hands needs room for the complete claim.",3) return false end
	for _,item in ipairs(transfer) do DRP.Inventory.InsertRaw(ply,item) end self:MarkWorldDirty() self:SaveWorld() self:SendTable(record) return true
end
function Crafting:LearnSchematic(ply,itemID)
	local item
	for _,r in ipairs(DRP.Inventory.Items(ply)) do if r.id==itemID then item=r break end end
	if not item or item.kind~="schematic" then return false end local p=profile(ply)
	if p.learned[item.schematic] then local notes=resource("technical_notes_g"..math.Clamp(tonumber(item.grade) or 1,1,5),1) DRP.Inventory.TakeRawByID(ply,item.id) DRP.Inventory.InsertRaw(ply,notes) notify(ply,"Duplicate schematic dismantled into grade-matched Technical Notes.",1)
	else DRP.Inventory.TakeRawByID(ply,item.id) p.learned[item.schematic]=true notify(ply,"Permanently learned "..item.label..".",1) end
	touchProfile(p) self:SavePlayer(ply) self:SendDelta(ply) return true
end
function Crafting:UseResearchFolio(ply,itemID,recipeID)
	local item for _,r in ipairs(DRP.Inventory.Items(ply)) do if r.id==itemID then item=r break end end
	local recipe=self:Recipe(recipeID) local p=profile(ply)
	if not item or item.kind~="resource" or not string.StartWith(tostring(item.resource or ""),"research_folio") or not recipe or (not recipe.schematic and not recipe.schematic_family) then return false end
	local key=recipe.schematic_family or recipe.id local folioGrade=math.Clamp(math.floor(tonumber(item.grade) or tonumber(string.match(item.resource,"g(%d+)$")) or 1),1,5)
	if recipe.grade>folioGrade or p.learned[key] then return false end
	DRP.Inventory.TakeRawByID(ply,item.id) p.learned[key]=true touchProfile(p) self:SavePlayer(ply) self:SendDelta(ply) notify(ply,"Research completed: "..recipe.name..".",1) return true
end
function Crafting:InstallUpgrade(ply,entity,itemID)
	local record=tableRecord(entity) if not record or activeRaid(record.property_id) or not DRP.Properties.Can(ply,record.property_id,"crafting") then return false end
	local item for _,r in ipairs(DRP.Inventory.Items(ply)) do if r.id==itemID then item=r break end end
	if not item or item.kind~="resource" or not DRP.CraftingShared.Item(item.resource) or DRP.CraftingShared.Item(item.resource).group~="equipment" then return false end
	if hasEquipment(record,item.resource) then notify(ply,"That workbench upgrade is already installed.",3) return false end
	DRP.Inventory.TakeRawByID(ply,item.id) record.upgrades[#record.upgrades+1]={resource=item.resource,owner=sid(ply),installed=os.time()} self:MarkWorldDirty() self:SaveWorld() self:SendTable(record) notify(ply,item.label.." installed.",1) return true
end
function Crafting:ClaimClaims(ply)
	local p=profile(ply) if #p.claims==0 then return false end
	if not DRP.Inventory.CanInsertBatch(ply,p.claims) then notify(ply,"Hands needs room for every protected crafting claim.",3) return false end
	for _,item in ipairs(p.claims) do DRP.Inventory.InsertRaw(ply,item) end p.claims={} touchProfile(p) self:SavePlayer(ply) self:SendDelta(ply) return true
end
function Crafting:Dismantle(ply,entity,itemID)
	local record=tableRecord(entity) if not record or activeRaid(record.property_id) then return false end
	local item for _,r in ipairs(DRP.Inventory.Items(ply)) do if r.id==itemID then item=r break end end
	if not item or (item.kind~="weapon" and item.kind~="attachment") then return false end
	local recipe=self:Recipe((item.kind=="weapon" and "weapon:"..item.class or "attachment:"..item.attachment)) if not recipe or recipe.lethal or DRP.Inventory.IsAlwaysAvailableWeapon(ply,item.class) then return false end
	local returns={} local ratio=math.Rand(.35,.55) for key,count in pairs(recipe.ingredients) do local amount=math.floor(count*ratio) local def=DRP.CraftingShared.Item(key) if amount>0 and def and def.group~="controlled" and def.group~="equipment" then returns[#returns+1]=resource(key,amount) end end
	for _,installed in ipairs(item.installed_attachments or {}) do local data=ARC9 and ARC9.GetAttTable and ARC9.GetAttTable(installed.attachment) or {} returns[#returns+1]={kind="attachment",class="drp_crafting_item",attachment=installed.attachment,label=tostring(data.PrintName or installed.attachment),model=validModel(data.Model),amount=1} end
	if #record.output+#returns>self.MaxOutputRecords then notify(ply,"Workbench output storage is full.",3) return false end
	DRP.Inventory.TakeRawByID(ply,item.id) for _,r in ipairs(returns) do r.owner=sid(ply) r.crafter=ply:DRPName() record.output[#record.output+1]=cleanRecord(r) end self:MarkWorldDirty() self:SaveWorld() self:SendTable(record) return true
end

function Crafting:RegisterTable(entity,propertyID,stableID)
	if not IsValid(entity) or entity:GetClass()~="drp_crafting_table" then return false,"Invalid crafting table." end
	propertyID=tonumber(propertyID or entity.DRPPropertyID) if not propertyID or not DRP.Properties.Definitions[propertyID] or not DRP.Properties.Leases[propertyID] then return false,"Crafting tables require an active property." end
	local id=tostring(stableID or entity.DRPCraftingTableID or self.NextTableID)
	for otherID,r in pairs(self.Tables) do if tostring(otherID)~=id and r.property_id==propertyID then return false,"This property already has a crafting table." end end
	if not DRP.Properties:EntityInsideAssignedBuildZones(entity,propertyID) then return false,"The complete table must remain inside the property's build zones." end
	if DRP.Props and DRP.Props.RegisterLimitedEntity and not entity.DRPLimitedEntityKind then
		if not DRP.Props.RegisterLimitedEntity(entity,"production") then return false,"The server production-entity budget is full." end
	end
	-- Persistent property infrastructure is counted by the production budget,
	-- but must never inherit the temporary dropped-entity cleanup deadline.
	if DRP.Props and DRP.Props.CancelCleanup then DRP.Props:CancelCleanup(entity) end
	self.NextTableID=math.max(self.NextTableID,tonumber(id) and tonumber(id)+1 or self.NextTableID+1)
	local r=self.Tables[id] or {id=id,property_id=propertyID,queue={},output={},upgrades={},raid_raiders={}}
	r.entity=entity r.property_id=propertyID r.owner=(DRP.Properties.Leases[propertyID] and DRP.Properties.Leases[propertyID].owner_id) or r.owner r.position={x=entity:GetPos().x,y=entity:GetPos().y,z=entity:GetPos().z} r.angle={p=entity:GetAngles().p,y=entity:GetAngles().y,r=entity:GetAngles().r}
	entity.DRPCraftingTableID=id entity.DRPPropertyID=propertyID entity.DRPPropertyStorage=true entity.DRPPropertyDefence=false entity:SetNW2String("DRPCraftingTableID",id)
	self.Tables[id]=r self.ByEntity[entity]=id DRP.Properties:IndexEntity(entity,propertyID) self:MarkWorldDirty() return true,id
end
function Crafting:BuildSnapshot(ply,entity)
	local r=tableRecord(entity) if not r then return nil end local p=profile(ply)
	-- The immutable catalogue uses a separate globally-budgeted transfer. Table
	-- state remains compact so it cannot crowd out gameplay traffic.
	return {protocol=DRP.ProtocolVersion,entity=entity:EntIndex(),table_id=r.id,property_id=r.property_id,level=p.level,xp=p.xp,xp_next=DRP.CraftingShared.XPForNext(p.level),learned=p.learned,claims=p.claims,hands=DRP.Inventory and DRP.Inventory.Items and DRP.Inventory.Items(ply) or {},queue=r.queue,output=r.output,upgrades=r.upgrades,catalog_fingerprint=self.CatalogFingerprint}
end

function Crafting:QueueCatalog(ply)
	if not IsValid(ply) or ply.DRPCraftingCatalogQueued == self.CatalogFingerprint then return false end
	local data=self.CatalogCompressed or "" if data=="" then return false end
	local count=math.max(1,math.ceil(#data/self.CatalogChunkSize))
	ply.DRPCraftingCatalogQueued=self.CatalogFingerprint
	self.CatalogTransfers[#self.CatalogTransfers+1]={player=ply,fingerprint=self.CatalogFingerprint,data=data,count=count,index=1}
	self:ArmCatalogPump()
	return true
end
function Crafting:ArmCatalogPump()
	if self.CatalogPumpArmed then return end
	self.CatalogPumpArmed=true
	hook.Add("Tick","DRP.Crafting.CatalogBudget",function() self:PumpCatalogTransfers() end)
end
function Crafting:DisarmCatalogPump()
	if not self.CatalogPumpArmed then return end
	self.CatalogPumpArmed=false
	hook.Remove("Tick","DRP.Crafting.CatalogBudget")
end
function Crafting:PumpCatalogTransfers()
	local started = DRP.Profile and DRP.Profile.Begin and DRP.Profile.Begin() or nil
	local sent=0
	while sent<self.CatalogChunksPerTick do
		local transfer=self.CatalogTransfers[self.CatalogTransferHead]
		if not transfer then if self.CatalogTransferHead>1 then self.CatalogTransfers={} self.CatalogTransferHead=1 end self:DisarmCatalogPump() if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("crafting.catalog_transfer",started) end return end
		local ply=transfer.player
		if not IsValid(ply) or transfer.fingerprint~=self.CatalogFingerprint then
			if IsValid(ply) then ply.DRPCraftingCatalogQueued=nil end self.CatalogTransfers[self.CatalogTransferHead]=nil self.CatalogTransferHead=self.CatalogTransferHead+1
		else
			local offset=(transfer.index-1)*self.CatalogChunkSize+1 local chunk=string.sub(transfer.data,offset,offset+self.CatalogChunkSize-1)
			net.Start(catalogChunkMessage) net.WriteUInt(DRP.ProtocolVersion,8) net.WriteString(transfer.fingerprint) net.WriteUInt(transfer.index,16) net.WriteUInt(transfer.count,16) net.WriteUInt(#chunk,16) net.WriteData(chunk,#chunk) net.Send(ply)
			transfer.index=transfer.index+1 sent=sent+1
			if transfer.index>transfer.count then ply.DRPCraftingCatalogQueued=nil self.CatalogTransfers[self.CatalogTransferHead]=nil self.CatalogTransferHead=self.CatalogTransferHead+1 end
		end
	end
	if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("crafting.catalog_transfer",started) end
end
local function sendCompressed(message,ply,payload)
	local data=util.Compress(util.TableToJSON(payload,false) or "{}") if not data then return end net.Start(message) net.WriteUInt(DRP.ProtocolVersion,8) net.WriteUInt(#data,24) net.WriteData(data,#data) net.Send(ply)
end
function Crafting:Open(ply,entity) if not canInteract(ply,entity) then return false end self:RefreshARC9Catalog(false) local snap=self:BuildSnapshot(ply,entity) if not snap then return false end self.OpenViewers[ply]=entity sendCompressed(openMessage,ply,snap) return true end
function Crafting:SendDelta(ply) if IsValid(ply) then local p=profile(ply) sendCompressed(deltaMessage,ply,{profile=true,level=p.level,xp=p.xp,xp_next=DRP.CraftingShared.XPForNext(p.level),learned=p.learned,claims=p.claims}) end end
function Crafting:SendTable(record) if not record or not IsValid(record.entity) then return end for ply,entity in pairs(self.OpenViewers) do if entity==record.entity and canInteract(ply,entity) then self:Open(ply,entity) elseif entity==record.entity then self.OpenViewers[ply]=nil end end end
function Crafting:Use(entity,ply) return self:Open(ply,entity) end
function Crafting:MarkWorldDirty() self.DirtyWorld=true self.WorldRevision=(self.WorldRevision or 0)+1 end
function Crafting:SavePlayer(ply)
	local id=sid(ply) if id=="" then return false end local p=self.Profiles[id] if not p then return false end file.CreateDir("darkrp") file.CreateDir(self.DataDirectory)
	local payload=util.TableToJSON(p,false) if not payload then return false end file.Write(self.DataDirectory.."/"..id..".json",payload)
	if DRP.Storage and DRP.Storage.SaveCrafting then DRP.Storage.SaveCrafting(id,payload) elseif DRP.Storage then DRP.Storage.SaveWorldState("crafting_player:"..id,payload) end return true
end
function Crafting:SaveProfileID(ownerID,p)
	ownerID=tostring(ownerID or "") if ownerID=="" or not istable(p) then return false end
	file.CreateDir("darkrp") file.CreateDir(self.DataDirectory)
	local payload=util.TableToJSON(p,false) if not payload then return false end
	file.Write(self.DataDirectory.."/"..ownerID..".json",payload)
	if DRP.Storage and DRP.Storage.SaveCrafting then DRP.Storage.SaveCrafting(ownerID,payload) elseif DRP.Storage then DRP.Storage.SaveWorldState("crafting_player:"..ownerID,payload) end
	return true
end
function Crafting:AddClaimID(ownerID,records)
	ownerID=tostring(ownerID or "") if ownerID=="" then return false end
	local p=self.Profiles[ownerID]
	if not p then local raw=file.Read(self.DataDirectory.."/"..ownerID..".json","DATA") p=raw and util.JSONToTable(raw) or profileDefault() self.Profiles[ownerID]=p end
	p.claims=istable(p.claims) and p.claims or {} for _,record in ipairs(records or {}) do p.claims[#p.claims+1]=cleanRecord(record) end touchProfile(p)
	self:SaveProfileID(ownerID,p) local online=player.GetBySteamID64(ownerID) if IsValid(online) then self:SendDelta(online) end return true
end
function Crafting:ReleaseProperty(propertyID,ownerID)
	for id,r in pairs(table.Copy(self.Tables)) do if r.property_id==tonumber(propertyID) then
		for _,job in ipairs(r.queue or {}) do DRP.Deadlines.Cancel("crafting:"..r.id..":"..job.id) self:AddClaimID(job.owner,job.escrow) end
		local byOwner={} for _,item in ipairs(r.output or {}) do local itemOwner=tostring(item.owner or ownerID) byOwner[itemOwner]=byOwner[itemOwner] or {} byOwner[itemOwner][#byOwner[itemOwner]+1]=item end
		for _,upgrade in ipairs(r.upgrades or {}) do local key=istable(upgrade) and upgrade.resource or upgrade local itemOwner=tostring(istable(upgrade) and upgrade.owner or ownerID) local item=resource(key,1) if item then byOwner[itemOwner]=byOwner[itemOwner] or {} byOwner[itemOwner][#byOwner[itemOwner]+1]=item end end
		for itemOwner,records in pairs(byOwner) do self:AddClaimID(itemOwner,records) end
		if IsValid(r.entity) then r.restoring=true r.entity:Remove() end self.Tables[id]=nil
	end end self:MarkWorldDirty() self:SaveWorld()
end
function Crafting:LoadPlayer(ply)
	local id=sid(ply) if id=="" then return end local localRaw=file.Read(self.DataDirectory.."/"..id..".json","DATA")
	local function apply(raw)
		local database=raw and util.JSONToTable(raw) or nil local recovery=localRaw and util.JSONToTable(localRaw) or nil
		local useRecovery=istable(recovery) and (not istable(database) or (tonumber(recovery.revision) or 0)>(tonumber(database.revision) or 0))
		self.Profiles[id]=useRecovery and recovery or (istable(database) and database or recovery or profileDefault()) local p=self.Profiles[id]
		p.schema=DRP.CraftingShared.SchemaVersion p.level=math.Clamp(math.floor(tonumber(p.level) or 1),1,50) p.xp=math.max(0,math.floor(tonumber(p.xp) or 0)) p.learned=istable(p.learned) and p.learned or {} p.claims=istable(p.claims) and p.claims or {} if p.level>=5 then p.learned["weapon:arc9_go_glock"]=true end
		if useRecovery then self:SaveProfileID(id,p) end self:SendDelta(ply)
	end
	if DRP.Storage and DRP.Storage.LoadCrafting then DRP.Storage.LoadCrafting(id,function(ok,raw) apply(ok and raw or nil) end) elseif DRP.Storage then DRP.Storage.LoadWorldState("crafting_player:"..id,function(ok,raw) apply(ok and raw or nil) end) else apply(nil) end
end
function Crafting:SaveWorld()
	if not self.DirtyWorld then return true end local serial={schema=2,revision=self.WorldRevision or 0,next_table_id=self.NextTableID,next_job_id=self.NextJobID,tables={}}
	for id,r in pairs(self.Tables) do local copy=table.Copy(r) copy.entity=nil serial.tables[id]=copy end local payload=util.TableToJSON(serial,false) if not payload then return false end
	local revision=self.WorldRevision or 0
	file.CreateDir("darkrp") file.Write("darkrp/crafting_"..game.GetMap()..".json",payload)
	if DRP.Storage then DRP.Storage.SaveWorldState(self.WorldKey,payload,function(ok) if ok and self.WorldRevision==revision then self.DirtyWorld=false end end) elseif self.WorldRevision==revision then self.DirtyWorld=false end
	return true
end
function Crafting:RestoreWorld(raw)
	local decoded=raw and util.JSONToTable(raw) or nil if not istable(decoded) then return end self.WorldRevision=math.max(self.WorldRevision or 0,tonumber(decoded.revision) or 0) self.NextTableID=tonumber(decoded.next_table_id) or 1 self.NextJobID=tonumber(decoded.next_job_id) or 1
	local invalid={}
	for id,r in pairs(decoded.tables or {}) do r.id=tostring(id) r.queue=istable(r.queue) and r.queue or {} r.output=istable(r.output) and r.output or {} r.upgrades=istable(r.upgrades) and r.upgrades or {} r.raid_raiders={} self.Tables[r.id]=r
		local pos=r.position and Vector(r.position.x,r.position.y,r.position.z) local ang=r.angle and Angle(r.angle.p,r.angle.y,r.angle.r)
		if pos and DRP.Properties and DRP.Properties.Definitions[r.property_id] and DRP.Properties.Leases[r.property_id] then local ent=ents.Create("drp_crafting_table") if IsValid(ent) then ent:SetPos(pos) ent:SetAngles(ang or angle_zero) ent:Spawn() local ok=self:RegisterTable(ent,r.property_id,r.id) if not ok then ent:Remove() invalid[#invalid+1]={r.property_id,r.owner} end else invalid[#invalid+1]={r.property_id,r.owner} end else invalid[#invalid+1]={r.property_id,r.owner} end
		if IsValid(r.entity) then self:StartNext(r) end
	end
	for _,entry in ipairs(invalid) do self:ReleaseProperty(entry[1],entry[2]) end
end
function Crafting:Status() local active,outputs,escrow=0,0,0 for _,r in pairs(self.Tables) do active=active+#r.queue outputs=outputs+#r.output for _,job in ipairs(r.queue or {}) do escrow=escrow+#(job.escrow or {}) end end return {recipes=#self.Catalog,excluded=#self.Excluded,tables=table.Count(self.Tables),jobs=active,escrow_records=escrow,outputs=outputs,fingerprint=self.CatalogFingerprint,dirty_world=self.DirtyWorld==true} end
function Crafting:ValidateCoverage()
	local missing={} local listed=list.Get("Weapon") or {} local classes={}
	for class in pairs(listed) do classes[class]=true end
	for _,data in ipairs(weapons.GetList and weapons.GetList() or {}) do if istable(data) and data.ClassName then classes[data.ClassName]=true end end
	for class in pairs(classes) do local data=weapons.GetStored(class) or listed[class] or {} if eligibleWeapon(class,data) and not self.Recipes["weapon:"..class] then missing[#missing+1]=class end end
	if ARC9 and istable(ARC9.Attachments) then for key,data in pairs(ARC9.Attachments) do if istable(data) and not data.Free and not data.AdminOnly and not data.Hidden and not data.Ignore and not data.InvAtt and not data.Developer and not data.DevOnly and not self.Recipes["attachment:"..key] then missing[#missing+1]="attachment:"..key end end end
	return #missing==0,missing
end
function Crafting:SyncARC9Inventory(ply)
	if not IsValid(ply) or not ARC9 then return false end local mirror={}
	for _,item in ipairs(DRP.Inventory.Items(ply)) do if item.kind=="attachment" and item.attachment then mirror[item.attachment]=(mirror[item.attachment] or 0)+(item.amount or 1) end end
	ply.ARC9_AttInv=mirror if ARC9.PlayerSendAttInv then ARC9:PlayerSendAttInv(ply) end return true
end

function Crafting:Start()
	self:BuildCatalog()
	-- ARC9 registers attachment definitions after the gamemode on some mounts.
	-- Retry briefly without a permanent timer, then retain the completed cache.
	local function lateARC9Refresh(attempt)
		if self:RefreshARC9Catalog(false) then return end
		if attempt<8 then timer.Simple(2,function() lateARC9Refresh(attempt+1) end) end
	end
	timer.Simple(1,function() lateARC9Refresh(1) end)
	hook.Add("DRPPlayerReady","DRP.Crafting.Load",function(ply) self:LoadPlayer(ply) end)
	hook.Add("PlayerDisconnected","DRP.Crafting.Save",function(ply) self:SavePlayer(ply) self.Profiles[sid(ply)]=nil end)
	hook.Add("DRPIncidentResolved","DRP.Crafting.PropertyRaid",function(incident,receipt)
		if incident.type=="armory_raid" and receipt and receipt.outcome=="raiders_victory" then
			for _,part in ipairs(incident.participants or {}) do if part.role=="raider" and IsValid(part.player) and part.player:Alive() then local reward=self:GenerateArmoryReward() if reward then if not DRP.Inventory.InsertRaw(part.player,reward) then self:AddClaimID(part.player:SteamID64(),{reward}) end notify(part.player,"You recovered a regulated gunsmithing item from the armory.",1) end end end return
		end
		if incident.type~="property_raid" then return end local propertyID=tonumber(incident.metadata and incident.metadata.property_id) if not propertyID then return end
		if receipt and receipt.outcome=="attackers_victory" then for _,r in pairs(self.Tables) do if r.property_id==propertyID then r.raid_loot_until=os.time()+self.RaidLootDuration r.raid_raiders={} for _,part in ipairs(incident.participants or {}) do local role=tostring(part.role or "") if (role=="suspect" or string.StartWith(role,"attacker")) and IsValid(part.player) and part.player:Alive() then r.raid_raiders[part.player:SteamID64()]=true end end DRP.Deadlines.Schedule("crafting:raidloot:"..r.id,CurTime()+self.RaidLootDuration,function() r.raid_loot_until=0 r.raid_raiders={} self:MarkWorldDirty() self:SaveWorld() end) end end end
	end)
	hook.Add("DRPPropertyReleasing","DRP.Crafting.PropertyRelease",function(propertyID,ownerID) self:ReleaseProperty(propertyID,ownerID) end)
	hook.Add("CanTool","DRP.Crafting.Protect",function(_,tr,tool) local r=IsValid(tr.Entity) and tableRecord(tr.Entity) if r and (#r.queue>0 or #r.output>0 or #r.upgrades>0 or activeRaid(r.property_id)) then return false end end)
	hook.Add("PhysgunPickup","DRP.Crafting.Protect",function(_,ent) local r=tableRecord(ent) if r and (#r.queue>0 or #r.output>0 or activeRaid(r.property_id)) then return false end end)
	hook.Add("GravGunPickupAllowed","DRP.Crafting.Protect",function(_,ent) local r=tableRecord(ent) if r and (#r.queue>0 or #r.output>0 or activeRaid(r.property_id)) then return false end end)
	hook.Add("CanProperty","DRP.Crafting.Protect",function(_,property,ent) local r=tableRecord(ent) if r and (#r.queue>0 or #r.output>0 or #r.upgrades>0 or activeRaid(r.property_id)) then return false end end)
	hook.Add("PhysgunDrop","DRP.Crafting.TrackTransform",function(ply,ent) local r=tableRecord(ent) if not r then return end local ok=DRP.Properties:EntityInsideAssignedBuildZones(ent,r.property_id) if not ok then ent:SetPos(Vector(r.position.x,r.position.y,r.position.z)) ent:SetAngles(Angle(r.angle.p,r.angle.y,r.angle.r)) local phys=ent:GetPhysicsObject() if IsValid(phys) then phys:SetVelocityInstantaneous(vector_origin) phys:AddAngleVelocity(-phys:GetAngleVelocity()) end notify(ply,"Workbench returned to its last valid property position.",3) else r.position={x=ent:GetPos().x,y=ent:GetPos().y,z=ent:GetPos().z} r.angle={p=ent:GetAngles().p,y=ent:GetAngles().y,r=ent:GetAngles().r} self:MarkWorldDirty() self:SaveWorld() end end)
	hook.Add("EntityRemoved","DRP.Crafting.EntityRemoved",function(ent)
		local id=self.ByEntity[ent] if not id then return end self.ByEntity[ent]=nil
		local r=self.Tables[id] if not r or r.restoring then return end
		if #r.queue==0 and #r.output==0 and #r.upgrades==0 then self.Tables[id]=nil else
			r.entity=nil
			timer.Simple(.1,function()
				if not self.Tables[id] or IsValid(r.entity) or not DRP.Properties.Leases[r.property_id] then return end
				local replacement=ents.Create("drp_crafting_table") if not IsValid(replacement) then return end
				replacement:SetPos(Vector(r.position.x,r.position.y,r.position.z)) replacement:SetAngles(Angle(r.angle.p,r.angle.y,r.angle.r)) replacement:Spawn()
				local ok=self:RegisterTable(replacement,r.property_id,id) if not ok then replacement:Remove() end
			end)
		end
		self:MarkWorldDirty() self:SaveWorld()
	end)
	hook.Add("ARC9_PlayerGetAtts","DRP.Crafting.HandsAttachmentCount",function(ply,att) local count=0 for _,item in ipairs(DRP.Inventory.Items(ply)) do if item.kind=="attachment" and item.attachment==att then count=count+(item.amount or 1) end end return count end)
	hook.Add("ARC9_PlayerGiveAtt","DRP.Crafting.HandsAttachmentGive",function(ply,att,amount) local data=ARC9 and ARC9.GetAttTable and ARC9.GetAttTable(att) or {} return DRP.Inventory.InsertRaw(ply,{kind="attachment",class="drp_crafting_item",attachment=att,label=tostring(data.PrintName or att),model=validModel(data.Model),amount=math.max(1,tonumber(amount) or 1)}) and true or false end)
	hook.Add("ARC9_PlayerTakeAtt","DRP.Crafting.HandsAttachmentTake",function(ply,att,amount) local left=math.max(1,math.floor(tonumber(amount) or 1)) local available=0 for _,item in ipairs(DRP.Inventory.Items(ply)) do if item.kind=="attachment" and item.attachment==att then available=available+(item.amount or 1) end end if available<left then return false end for _,item in ipairs(table.Copy(DRP.Inventory.Items(ply))) do if left>0 and item.kind=="attachment" and item.attachment==att then local raw=DRP.Inventory.TakeRawByID(ply,item.id) local take=math.min(left,raw.amount or 1) left=left-take if (raw.amount or 1)>take then raw.amount=raw.amount-take DRP.Inventory.InsertRaw(ply,raw) end end end return true end)
	hook.Add("DRPHandsItemAdded","DRP.Crafting.AttachmentMirror",function(ply,item) if item.kind=="attachment" then timer.Simple(0,function() if IsValid(ply) then self:SyncARC9Inventory(ply) end end) end end)
	hook.Add("DRPHandsItemRemoved","DRP.Crafting.AttachmentMirror",function(ply,item) if item.kind=="attachment" then timer.Simple(0,function() if IsValid(ply) then self:SyncARC9Inventory(ply) end end) end end)
	hook.Add("DRPInventoryLoaded","DRP.Crafting.AttachmentMirrorLoad",function(ply) self:SyncARC9Inventory(ply) end)
	local localRaw=file.Read("darkrp/crafting_"..game.GetMap()..".json","DATA")
	local function delayedRestore(raw,attempt,resyncDatabase)
		attempt=attempt or 1
		if not DRP.Properties or not DRP.Properties.InitialSyncDone then timer.Simple(1,function() delayedRestore(raw,attempt+1,resyncDatabase) end) return end
		self:RestoreWorld(raw)
		if resyncDatabase then self.DirtyWorld=true self:SaveWorld() end
	end
	if DRP.Storage then DRP.Storage.LoadWorldState(self.WorldKey,function(ok,raw)
		local database=ok and raw and util.JSONToTable(raw) or nil local recovery=localRaw and util.JSONToTable(localRaw) or nil
		local useRecovery=istable(recovery) and (not istable(database) or (tonumber(recovery.revision) or 0)>(tonumber(database.revision) or 0))
		delayedRestore(useRecovery and localRaw or (ok and raw or localRaw),1,useRecovery)
	end) else delayedRestore(localRaw) end
	print(string.format("[DRP CRAFTING] catalog=%d weapons+attachments coverage fingerprint=%s",#self.Catalog,self.CatalogFingerprint or "none"))
end
function Crafting:Stop() self:DisarmCatalogPump() for _,ply in player.Iterator() do self:SavePlayer(ply) end self:SaveWorld() end

DRP.Net.Receive(actionMessage,function(_,ply)
	if net.ReadUInt(8)~=DRP.ProtocolVersion or not DRP.Net.Allow(ply,"crafting_action",.15,8) then return end
	local action=net.ReadString() local entity=Entity(net.ReadUInt(16)) if not IsValid(entity) or entity:GetClass()~="drp_crafting_table" or not canInteract(ply,entity) then return end
	if action=="start" then Crafting:StartCraft(ply,entity,net.ReadString(),net.ReadUInt(8))
	elseif action=="cancel" then Crafting:CancelCraft(ply,entity,net.ReadUInt(32))
	elseif action=="claim" then Crafting:ClaimOutput(ply,entity,{})
	elseif action=="learn" then Crafting:LearnSchematic(ply,net.ReadString())
	elseif action=="upgrade" then Crafting:InstallUpgrade(ply,entity,net.ReadString())
	elseif action=="claims" then Crafting:ClaimClaims(ply)
	elseif action=="research" then Crafting:UseResearchFolio(ply,net.ReadString(),net.ReadString())
	elseif action=="dismantle" then Crafting:Dismantle(ply,entity,net.ReadString())
	elseif action=="track" then Crafting:TrackObjective(ply,net.ReadString()) end
end)
DRP.Net.Receive(cacheMessage,function(_,ply)
	if net.ReadUInt(8)~=DRP.ProtocolVersion then return end
	local fingerprint=string.sub(net.ReadString(),1,32)
	-- A mismatch is an explicit cache miss. Queue the cached compressed payload
	-- under the global two-chunk-per-tick budget.
	if fingerprint=="" then
		ply.DRPCraftingCatalogFingerprint=nil
		if #(Crafting.Catalog or {})==0 and isfunction(Crafting.BuildCatalog) then
			-- A late ARC9 mount or a hot-reloaded gamemode can leave the initial
			-- catalogue empty.  Rebuild on demand so opening the table recovers.
			Crafting:BuildCatalog()
		end
		Crafting:QueueCatalog(ply)
		return
	end
	if fingerprint==Crafting.CatalogFingerprint then ply.DRPCraftingCatalogFingerprint=fingerprint else Crafting:QueueCatalog(ply) end
end)
concommand.Add("drp_crafting_status",function(ply) if IsValid(ply) and not (DRP.Admin and DRP.Admin.IsOwner(ply)) then return end PrintTable(Crafting:Status()) end)
concommand.Add("drp_crafting_coverage",function(ply)
	if IsValid(ply) and not (DRP.Admin and DRP.Admin.IsOwner(ply)) then return end
	local covered,missing=Crafting:ValidateCoverage()
	print("[DRP CRAFTING] coverage="..tostring(covered).." missing="..#missing.." excluded="..#Crafting.Excluded)
	for _,entry in ipairs(Crafting.Excluded) do print("  excluded "..entry.kind.." "..entry.id.." — "..entry.reason) end
	for _,id in ipairs(missing) do print("  MISSING "..id) end
end)
