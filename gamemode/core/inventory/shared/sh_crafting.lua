DRP.CraftingShared = DRP.CraftingShared or {}
local Shared = DRP.CraftingShared

Shared.SchemaVersion = 2
Shared.MaxLevel = 50
Shared.GridKinds = { attachment = true, schematic = true }
Shared.GradeLevels = { 1, 5, 12, 20, 30, 40 }
Shared.GradeNames = { "Grade I", "Grade II", "Grade III", "Grade IV", "Grade V", "Ordnance" }
Shared.BenchRequirements = { "Basic Bench", "Basic Bench", "Bench Vice & Drill", "Rifling Rig", "Precision Rig", "Ordnance Toolkit" }

function Shared.XPForNext(level)
	level = math.Clamp(math.floor(tonumber(level) or 1), 1, Shared.MaxLevel)
	return 100 + 35 * (level - 1)
end

function Shared.GradeForLevel(level)
	level = math.Clamp(math.floor(tonumber(level) or 1), 1, Shared.MaxLevel)
	local grade = 1
	for index, required in ipairs(Shared.GradeLevels) do if level >= required then grade = index end end
	return grade
end

function Shared.TimeMultiplier(level)
	level = math.Clamp(math.floor(tonumber(level) or 1), 1, Shared.MaxLevel)
	return 1 - 0.20 * ((level - 1) / (Shared.MaxLevel - 1))
end

Shared.Items = {
	ferrous_scrap={name="Ferrous Scrap",model="models/gibs/metal_gib4.mdl",group="raw"}, aluminium_offcuts={name="Aluminium Offcuts",model="models/gibs/metal_gib2.mdl",group="raw"}, copper_wire={name="Copper Wire",model="models/props_lab/tpplug.mdl",group="raw"}, polymer_scrap={name="Polymer Scrap",model="models/gibs/antlion_gib_small_2.mdl",group="raw"}, hardwood_offcuts={name="Hardwood Offcuts",model="models/gibs/wood_gib01e.mdl",group="raw"}, cloth_roll={name="Cloth Roll",model="models/props_junk/garbage_bag001a.mdl",group="raw"}, fastener_kit={name="Fastener Kit",model="models/props_lab/box01a.mdl",group="raw"}, brass_casings={name="Brass Casings",model="models/items/boxsrounds.mdl",group="ammo"}, primer_tray={name="Primer Tray",model="models/props_lab/box01a.mdl",group="ammo"}, projectile_cores={name="Projectile Cores",model="models/items/boxmrounds.mdl",group="ammo"}, shell_hulls={name="Shell Hulls",model="models/items/boxbuckshot.mdl",group="ammo"}, shot_pellets={name="Shot Pellets",model="models/items/boxbuckshot.mdl",group="ammo"}, chemical_reagent={name="Chemical Reagent",model="models/props_lab/jar01b.mdl",group="chemical"}, propellant_powder={name="Propellant Powder",model="models/props_lab/jar01a.mdl",group="ammo"}, optic_glass={name="Optic Glass",model="models/props_lab/lens.mdl",group="precision"}, circuit_components={name="Circuit Components",model="models/props_lab/reciever01b.mdl",group="electronic"},
	steel_bar={name="Steel Bar",model="models/props_c17/signpole001.mdl",group="refined"}, aluminium_plate={name="Aluminium Plate",model="models/props_phx/construct/metal_plate1.mdl",fallback="models/props_c17/metalPot001a.mdl",group="refined"}, copper_coil={name="Copper Coil",model="models/props_lab/tpplug.mdl",group="refined"}, polymer_sheet={name="Polymer Sheet",model="models/props_junk/garbage_plasticbottle003a.mdl",group="refined"}, treated_stock={name="Treated Stock",model="models/props_c17/FurnitureDrawer001a.mdl",group="refined"}, woven_cloth={name="Woven Cloth",model="models/props_junk/garbage_bag001a.mdl",group="refined"}, spring_set={name="Spring Set",model="models/props_c17/TrapPropeller_Lever.mdl",group="refined"}, adhesive_compound={name="Adhesive Compound",model="models/props_junk/garbage_glassbottle003a.mdl",group="refined"},
	receiver_blank={name="Receiver Blank",model="models/gibs/metal_gib4.mdl",group="component"}, pistol_receiver={name="Pistol Receiver",model="models/gibs/metal_gib4.mdl",group="component"}, smg_receiver={name="SMG Receiver",model="models/gibs/metal_gib4.mdl",group="component"}, shotgun_receiver={name="Shotgun Receiver",model="models/gibs/metal_gib4.mdl",group="component"}, rifle_receiver={name="Rifle Receiver",model="models/gibs/metal_gib4.mdl",group="component"}, precision_receiver={name="Precision Receiver",model="models/gibs/metal_gib4.mdl",group="precision"}, heavy_receiver={name="Heavy Receiver",model="models/gibs/metal_gib4.mdl",group="precision"}, short_barrel={name="Short Barrel",model="models/props_c17/signpole001.mdl",group="component"}, shotgun_barrel={name="Shotgun Barrel",model="models/props_c17/signpole001.mdl",group="component"}, rifle_barrel={name="Rifle Barrel",model="models/props_c17/signpole001.mdl",group="component"}, precision_barrel={name="Precision Barrel",model="models/props_c17/signpole001.mdl",group="precision"}, barrel_blank={name="Barrel Blank",model="models/props_c17/signpole001.mdl",group="component"}, bolt_assembly={name="Bolt Assembly",model="models/props_lab/reciever01b.mdl",group="component"}, heavy_bolt={name="Heavy Bolt",model="models/props_lab/reciever01b.mdl",group="precision"}, calibrated_bolt={name="Calibrated Bolt",model="models/props_lab/reciever01b.mdl",group="precision"}, action_assembly={name="Action Assembly",model="models/props_lab/reciever01b.mdl",group="component"}, gas_system={name="Gas System",model="models/props_lab/pipesystem03b.mdl",group="component"}, trigger_group={name="Trigger Group",model="models/props_lab/reciever01b.mdl",group="component"}, grip_assembly={name="Grip Assembly",model="models/props_c17/TrapPropeller_Lever.mdl",group="component"}, stock_assembly={name="Stock Assembly",model="models/props_c17/FurnitureDrawer001a.mdl",group="component"}, magazine_body={name="Magazine Body",model="models/items/boxsrounds.mdl",group="component"}, tube_magazine={name="Tube Magazine",model="models/props_c17/signpole001.mdl",group="component"}, drum_assembly={name="Drum Assembly",model="models/props_lab/reciever01b.mdl",group="precision"}, cooling_jacket={name="Cooling Jacket",model="models/props_c17/utilityconnecter006c.mdl",group="precision"}, optic_housing={name="Optic Housing",model="models/props_lab/lens.mdl",group="precision"}, electronic_control_unit={name="Electronic Control Unit",model="models/props_lab/reciever01b.mdl",group="electronic"}, suppressor_baffle_set={name="Suppressor Baffle Set",model="models/props_c17/signpole001.mdl",group="precision"}, calibrated_parts={name="Calibrated Parts",model="models/props_lab/box01a.mdl",group="precision"},
	explosive_compound={name="Explosive Compound",model="models/props_lab/jar01b.mdl",group="controlled"}, detonator={name="Detonator",model="models/props_lab/reciever01b.mdl",group="controlled"}, fuse_assembly={name="Fuse Assembly",model="models/props_lab/tpplug.mdl",group="controlled"}, fragmentation_shell={name="Fragmentation Shell",model="models/Items/grenadeAmmo.mdl",group="controlled"}, smoke_compound={name="Smoke Compound",model="models/props_lab/jar01a.mdl",group="controlled"}, incendiary_compound={name="Incendiary Compound",model="models/props_junk/gascan001a.mdl",group="controlled"}, shaped_charge={name="Shaped Charge",model="models/props_lab/reciever01b.mdl",group="controlled"}, rocket_motor={name="Rocket Motor",model="models/props_c17/canister01a.mdl",group="controlled"},
	bench_vice_drill={name="Bench Vice & Drill",model="models/props_c17/tools_wrench01a.mdl",group="equipment",w=2,h=2}, rifling_rig={name="Rifling Rig",model="models/props_c17/TrapPropeller_Engine.mdl",group="equipment",w=3,h=2}, precision_gauge_set={name="Precision Gauge Set",model="models/props_lab/box01a.mdl",group="equipment",w=2,h=2}, optic_alignment_jig={name="Optic Alignment Jig",model="models/props_lab/lens.mdl",group="equipment",w=2,h=2}, ordnance_toolkit={name="Ordnance Toolkit",model="models/props_c17/BriefCase001a.mdl",group="equipment",w=3,h=2}, technical_notes={name="Technical Notes",model="models/props_lab/clipboard.mdl",group="research"}, research_folio={name="Research Folio",model="models/props_lab/binderblue.mdl",group="research",w=2,h=2}
}

for grade=1,5 do
	Shared.Items["technical_notes_g"..grade]={name="Grade "..grade.." Technical Notes",model="models/props_lab/clipboard.mdl",group="research"}
	Shared.Items["research_folio_g"..grade]={name="Grade "..grade.." Research Folio",model="models/props_lab/binderblue.mdl",group="research",w=2,h=2,grade=grade}
end

function Shared.Item(key) return Shared.Items[string.lower(tostring(key or ""))] end
function Shared.ItemRecord(key, amount)
	local definition = Shared.Item(key)
	if not definition then return nil end
	local model = definition.model
	if SERVER and model and not util.IsValidModel(model) then model = definition.fallback or "models/props_lab/box01a.mdl" end
	return { kind="resource", class="drp_crafting_item", resource=key, label=definition.name, model=model, amount=math.max(1, math.floor(tonumber(amount) or 1)), grade=definition.grade, crafting=true }
end
