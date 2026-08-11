DRP.IdentityCatalog = DRP.IdentityCatalog or {
	Genders = {
		{ key = "male", name = "Male", heads = { "male_01", "male_02", "male_03", "male_04", "male_05", "male_06", "male_07", "male_08", "male_09" } },
		{ key = "female", name = "Female", heads = { "female_01", "female_02", "female_03", "female_04", "female_06", "female_07" } }
	},
	Outfits = {
		{ key = "civilian", name = "Civilian", directory = "Group01" },
		{ key = "refugee", name = "Refugee", directory = "Group02" },
		{ key = "workwear", name = "Workwear", directory = "Group03" }
	}
}

local Catalog = DRP.IdentityCatalog

Catalog.PoliceUniform = Catalog.PoliceUniform or {
	name = "Police uniform",
	model = "models/player/police.mdl"
}

local function normalizeBodygroups(source)
	local bodygroups, count = {}, 0
	for rawID, rawValue in pairs(istable(source) and source or {}) do
		local id, value = tonumber(rawID), tonumber(rawValue)
		if id and value and id >= 0 and id <= 15 and value >= 0 and value <= 31 and count < 15 then
			bodygroups[math.floor(id)] = math.floor(value)
			count = count + 1
		end
	end
	return bodygroups
end

local function normalizeAppearance(source)
	source = istable(source) and source or {}
	return {
		skin = math.Clamp(math.floor(tonumber(source.skin) or 0), 0, 31),
		bodygroups = normalizeBodygroups(source.bodygroups)
	}
end

function Catalog.Model(genderIndex, outfitIndex, headIndex)
	local gender = Catalog.Genders[math.floor(tonumber(genderIndex) or 0)]
	local outfit = Catalog.Outfits[math.floor(tonumber(outfitIndex) or 0)]
	local head = gender and gender.heads[math.floor(tonumber(headIndex) or 0)]
	if not gender or not outfit or not head then return nil end
	return "models/player/" .. outfit.directory .. "/" .. head .. ".mdl"
end

function Catalog.PoliceModel()
	local police = DRP.Jobs and DRP.Job and DRP.Jobs[DRP.Job.POLICE]
	local model = police and police.model or Catalog.PoliceUniform.model
	return string.Trim(tostring(model or Catalog.PoliceUniform.model))
end

function Catalog.Normalize(state)
	state = istable(state) and state or {}
	local gender = math.Clamp(math.floor(tonumber(state.gender) or 1), 1, #Catalog.Genders)
	local outfit = math.Clamp(math.floor(tonumber(state.outfit) or 1), 1, #Catalog.Outfits)
	local heads = Catalog.Genders[gender].heads
	local legacyPolice = {
		skin = state.police_skin,
		bodygroups = state.police_bodygroups
	}
	local uniforms = istable(state.uniforms) and state.uniforms or {}
	return {
		version = 2,
		registered = state.registered == true,
		name = string.sub(string.Trim(tostring(state.name or "")), 1, 48),
		gender = gender,
		outfit = outfit,
		head = math.Clamp(math.floor(tonumber(state.head) or 1), 1, #heads),
		skin = math.Clamp(math.floor(tonumber(state.skin) or 0), 0, 31),
		bodygroups = normalizeBodygroups(state.bodygroups),
		uniforms = {
			police = normalizeAppearance(istable(uniforms.police) and uniforms.police or legacyPolice)
		},
		updated_at = math.max(0, math.floor(tonumber(state.updated_at) or 0))
	}
end
