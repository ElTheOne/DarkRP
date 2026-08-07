local Properties = assert(DRP and DRP.Properties, "properties service must exist before geometry loads")
local Geometry = {}

local function vectorData(value)
	return {
		x = tonumber(value and value.x) or 0,
		y = tonumber(value and value.y) or 0,
		z = tonumber(value and value.z) or 0
	}
end

local function zoneVectors(zone)
	local mins = zone and (zone.mins or zone.min) or {}
	local maxs = zone and (zone.maxs or zone.max) or {}
	return Vector(tonumber(mins.x) or 0, tonumber(mins.y) or 0, tonumber(mins.z) or 0),
		Vector(tonumber(maxs.x) or 0, tonumber(maxs.y) or 0, tonumber(maxs.z) or 0)
end

local function zoneBaseCorners(zone)
	local source = zone and (zone.corners or zone.base) or nil
	if not istable(source) or #source ~= 4 then return nil end
	local corners = {}
	for index = 1, 4 do
		local point = source[index]
		if not istable(point) then return nil end
		corners[index] = Vector(tonumber(point.x) or 0, tonumber(point.y) or 0, tonumber(point.z) or 0)
	end
	return corners
end

local function normalizeBuildZone(first, second)
	first, second = Vector(first.x, first.y, first.z), Vector(second.x, second.y, second.z)
	local mins = Vector(
		math.min(first.x, second.x),
		math.min(first.y, second.y),
		math.min(first.z, second.z)
	)
	local maxs = Vector(
		math.max(first.x, second.x),
		math.max(first.y, second.y),
		math.max(first.z, second.z)
	)
	local size = maxs - mins
	if size.x < Properties.MinBuildZoneAxis or size.y < Properties.MinBuildZoneAxis or size.z < Properties.MinBuildZoneAxis then
		return nil, "Each build-zone axis must be at least " .. Properties.MinBuildZoneAxis .. " units."
	end
	if size.x > Properties.MaxBuildZoneAxis or size.y > Properties.MaxBuildZoneAxis or size.z > Properties.MaxBuildZoneAxis then
		return nil, "A build-zone axis cannot exceed " .. Properties.MaxBuildZoneAxis .. " units."
	end
	return { mins = vectorData(mins), maxs = vectorData(maxs) }
end

local function normalizeCornerBuildZone(points, heightPoint)
	if not istable(points) or #points ~= 4 or not isvector(heightPoint) then
		return nil, "Select four base corners followed by one height point."
	end
	local corners = {}
	local minimumZ, maximumZ, averageZ = math.huge, -math.huge, 0
	for index = 1, 4 do
		local point = points[index]
		if not isvector(point) then return nil, "All four base selections must be valid world positions." end
		corners[index] = Vector(point.x, point.y, point.z)
		minimumZ = math.min(minimumZ, point.z)
		maximumZ = math.max(maximumZ, point.z)
		averageZ = averageZ + point.z
	end
	averageZ = averageZ / 4
	if maximumZ - minimumZ > Properties.MinBuildZoneAxis then
		return nil, "The four base corners must be selected on approximately the same floor height."
	end
	for index = 1, 4 do corners[index].z = averageZ end
	local topZ = tonumber(heightPoint.z) or averageZ
	if math.abs(topZ - averageZ) < Properties.MinBuildZoneAxis then
		return nil, "The fifth selection must set a height of at least " .. Properties.MinBuildZoneAxis .. " units."
	end
	if math.abs(topZ - averageZ) > Properties.MaxBuildZoneAxis then
		return nil, "Build-zone height cannot exceed " .. Properties.MaxBuildZoneAxis .. " units."
	end

	local area = 0
	local winding
	for index = 1, 4 do
		local current = corners[index]
		local following = corners[(index % 4) + 1]
		local edgeLength = Vector(current.x - following.x, current.y - following.y, 0):Length()
		if edgeLength < Properties.MinBuildZoneAxis then
			return nil, "Each base edge must be at least " .. Properties.MinBuildZoneAxis .. " units."
		end
		if edgeLength > Properties.MaxBuildZoneAxis then
			return nil, "A base edge cannot exceed " .. Properties.MaxBuildZoneAxis .. " units."
		end
		area = area + current.x * following.y - following.x * current.y
	end
	if math.abs(area) < Properties.MinBuildZoneAxis * Properties.MinBuildZoneAxis then
		return nil, "The four base corners do not form a usable box."
	end
	winding = area > 0 and 1 or -1
	for index = 1, 4 do
		local previous = corners[((index + 2) % 4) + 1]
		local current = corners[index]
		local following = corners[(index % 4) + 1]
		local cross = (current.x - previous.x) * (following.y - current.y)
			- (current.y - previous.y) * (following.x - current.x)
		if cross * winding <= 0.01 then
			return nil, "Select the four base corners in order around a convex box without crossing edges."
		end
	end
	return {
		corners = {
			vectorData(corners[1]), vectorData(corners[2]),
			vectorData(corners[3]), vectorData(corners[4])
		},
		top_z = topZ
	}
end

local function sanitizeBuildZones(rawZones)
	local output = {}
	for _, raw in ipairs(istable(rawZones) and rawZones or {}) do
		local base = zoneBaseCorners(raw)
		local zone
		if base and tonumber(raw.top_z or raw.height_z) then
			zone = normalizeCornerBuildZone(base, Vector(0, 0, tonumber(raw.top_z or raw.height_z)))
		else
			local mins, maxs = zoneVectors(raw)
			zone = normalizeBuildZone(mins, maxs)
		end
		if zone then
			output[#output + 1] = zone
			if #output >= Properties.MaxBuildZones then break end
		end
	end
	return output
end

local function pointInsideCornerZone(position, zone, inset)
	local corners = zoneBaseCorners(zone)
	if not corners then return false end
	local topZ = tonumber(zone.top_z or zone.height_z)
	if not topZ then return false end
	inset = tonumber(inset) or 0
	local bottomZ = 0
	for index = 1, 4 do bottomZ = bottomZ + corners[index].z end
	bottomZ = bottomZ / 4
	local minimumZ, maximumZ = math.min(bottomZ, topZ), math.max(bottomZ, topZ)
	if position.z < minimumZ + inset or position.z > maximumZ - inset then return false end
	local area = 0
	for index = 1, 4 do
		local current, following = corners[index], corners[(index % 4) + 1]
		area = area + current.x * following.y - following.x * current.y
	end
	local winding = area >= 0 and 1 or -1
	for index = 1, 4 do
		local current, following = corners[index], corners[(index % 4) + 1]
		local edgeX, edgeY = following.x - current.x, following.y - current.y
		local length = math.sqrt(edgeX * edgeX + edgeY * edgeY)
		if length <= 0 then return false end
		local cross = edgeX * (position.y - current.y) - edgeY * (position.x - current.x)
		if cross * winding < inset * length then return false end
	end
	return true
end

local function pointInsideZone(position, zone, tolerance)
	tolerance = math.max(0, tonumber(tolerance) or 0)
	if zoneBaseCorners(zone) then
		return pointInsideCornerZone(position, zone, -tolerance)
	end
	local mins, maxs = zoneVectors(zone)
	return position.x >= mins.x - tolerance and position.x <= maxs.x + tolerance
		and position.y >= mins.y - tolerance and position.y <= maxs.y + tolerance
		and position.z >= mins.z - tolerance and position.z <= maxs.z + tolerance
end

local function boundsInsideZone(boundsMins, boundsMaxs, zone, tolerance)
	tolerance = math.max(0, tonumber(tolerance) or 0)
	if zoneBaseCorners(zone) then
		for x = 0, 1 do
			for y = 0, 1 do
				for z = 0, 1 do
					local point = Vector(
						x == 0 and boundsMins.x or boundsMaxs.x,
						y == 0 and boundsMins.y or boundsMaxs.y,
						z == 0 and boundsMins.z or boundsMaxs.z
					)
					if not pointInsideZone(point, zone, tolerance) then return false end
				end
			end
		end
		return true
	end
	local mins, maxs = zoneVectors(zone)
	return boundsMins.x >= mins.x - tolerance and boundsMaxs.x <= maxs.x + tolerance
		and boundsMins.y >= mins.y - tolerance and boundsMaxs.y <= maxs.y + tolerance
		and boundsMins.z >= mins.z - tolerance and boundsMaxs.z <= maxs.z + tolerance
end

function Properties:LocationAt(position)
	if not isvector(position) then return nil end
	for propertyID, definition in pairs(self.Definitions) do
		for _, zone in ipairs(definition.build_zones or {}) do
			if pointInsideZone(position, zone, self.BuildZoneTolerance) then
				return definition, propertyID
			end
		end
	end
	return nil
end

local function zoneBounds(zone)
	local corners = zoneBaseCorners(zone)
	if not corners then return zoneVectors(zone) end
	local mins = Vector(math.huge, math.huge, math.huge)
	local maxs = Vector(-math.huge, -math.huge, -math.huge)
	local bottomZ = 0
	for index = 1, 4 do
		local point = corners[index]
		mins.x, mins.y = math.min(mins.x, point.x), math.min(mins.y, point.y)
		maxs.x, maxs.y = math.max(maxs.x, point.x), math.max(maxs.y, point.y)
		bottomZ = bottomZ + point.z
	end
	bottomZ = bottomZ / 4
	local topZ = tonumber(zone.top_z or zone.height_z) or bottomZ
	mins.z, maxs.z = math.min(bottomZ, topZ), math.max(bottomZ, topZ)
	return mins, maxs
end

local function boundsOverlapZone(boundsMins, boundsMaxs, zone, tolerance)
	local zoneMins, zoneMaxs = zoneBounds(zone)
	tolerance = math.max(0, tonumber(tolerance) or 0)
	return boundsMaxs.x >= zoneMins.x - tolerance and boundsMins.x <= zoneMaxs.x + tolerance
		and boundsMaxs.y >= zoneMins.y - tolerance and boundsMins.y <= zoneMaxs.y + tolerance
		and boundsMaxs.z >= zoneMins.z - tolerance and boundsMins.z <= zoneMaxs.z + tolerance
end

local function zonePolygon(zone)
	local corners = zoneBaseCorners(zone)
	if corners then return corners end
	local mins, maxs = zoneVectors(zone)
	return {
		Vector(mins.x, mins.y, mins.z), Vector(maxs.x, mins.y, mins.z),
		Vector(maxs.x, maxs.y, mins.z), Vector(mins.x, maxs.y, mins.z)
	}
end

local function polygonsTouchOrOverlap(first, second)
	local function separatedOnEdges(source, firstPolygon, secondPolygon)
		for index = 1, #source do
			local current, following = source[index], source[(index % #source) + 1]
			local axisX, axisY = -(following.y - current.y), following.x - current.x
			local firstMin, firstMax = math.huge, -math.huge
			local secondMin, secondMax = math.huge, -math.huge
			for _, point in ipairs(firstPolygon) do
				local projection = point.x * axisX + point.y * axisY
				firstMin, firstMax = math.min(firstMin, projection), math.max(firstMax, projection)
			end
			for _, point in ipairs(secondPolygon) do
				local projection = point.x * axisX + point.y * axisY
				secondMin, secondMax = math.min(secondMin, projection), math.max(secondMax, projection)
			end
			if firstMax < secondMin - 0.01 or secondMax < firstMin - 0.01 then return true end
		end
		return false
	end
	return not separatedOnEdges(first, first, second) and not separatedOnEdges(second, first, second)
end

local function zonesTouchOrOverlap(first, second)
	local firstMins, firstMaxs = zoneBounds(first)
	local secondMins, secondMaxs = zoneBounds(second)
	if firstMaxs.z < secondMins.z - 0.01 or secondMaxs.z < firstMins.z - 0.01 then return false end
	return polygonsTouchOrOverlap(zonePolygon(first), zonePolygon(second))
end

local function connectedZoneComponents(zones)
	local components, visited = {}, {}
	for start = 1, #zones do
		if not visited[start] then
			local component, pending = {}, { start }
			visited[start] = true
			while #pending > 0 do
				local index = table.remove(pending)
				component[#component + 1] = zones[index]
				for candidate = 1, #zones do
					if not visited[candidate] and zonesTouchOrOverlap(zones[index], zones[candidate]) then
						visited[candidate] = true
						pending[#pending + 1] = candidate
					end
				end
			end
			components[#components + 1] = component
		end
	end
	return components
end

local function transformedPoint(localPoint, origin, angles)
	local point = Vector(localPoint.x, localPoint.y, localPoint.z)
	point:Rotate(angles)
	return origin + point
end

local function cellCorners(localMins, localMaxs, origin, angles)
	local corners = {}
	for x = 0, 1 do
		for y = 0, 1 do
			for z = 0, 1 do
				corners[#corners + 1] = transformedPoint(Vector(
					x == 0 and localMins.x or localMaxs.x,
					y == 0 and localMins.y or localMaxs.y,
					z == 0 and localMins.z or localMaxs.z
				), origin, angles)
			end
		end
	end
	return corners
end

local function cornersInsideSingleZone(corners, zones, tolerance)
	for _, zone in ipairs(zones) do
		local contained = true
		for _, point in ipairs(corners) do
			if not pointInsideZone(point, zone, tolerance) then contained = false break end
		end
		if contained then return true end
	end
	return false
end

local function pointInsideZoneUnion(point, zones, tolerance)
	for _, zone in ipairs(zones) do
		if pointInsideZone(point, zone, tolerance) then return true end
	end
	return false
end

-- Prove that the complete oriented box is covered by one property's zone
-- union. Cells wholly contained by one convex zone terminate immediately;
-- cells crossing internal seams are subdivided in local entity space.
local function orientedBoundsInsideZoneUnion(localMins, localMaxs, origin, angles, zones, tolerance)
	zones = istable(zones) and zones or {}
	tolerance = math.max(0, tonumber(tolerance) or 0)
	if #zones == 0 or not isvector(localMins) or not isvector(localMaxs)
		or not isvector(origin) or not isangle(angles) then return false end

	local outerCorners = cellCorners(localMins, localMaxs, origin, angles)
	local worldMins = Vector(math.huge, math.huge, math.huge)
	local worldMaxs = Vector(-math.huge, -math.huge, -math.huge)
	for _, point in ipairs(outerCorners) do
		worldMins.x, worldMins.y, worldMins.z = math.min(worldMins.x, point.x), math.min(worldMins.y, point.y), math.min(worldMins.z, point.z)
		worldMaxs.x, worldMaxs.y, worldMaxs.z = math.max(worldMaxs.x, point.x), math.max(worldMaxs.y, point.y), math.max(worldMaxs.z, point.z)
	end
	local relevant = {}
	for _, zone in ipairs(zones) do
		if boundsOverlapZone(worldMins, worldMaxs, zone, tolerance) then relevant[#relevant + 1] = zone end
	end
	if #relevant == 0 then return false end

	local checks = 0
	local function componentCovered(component)
		local function covered(mins, maxs, depth)
			checks = checks + 1
			if checks > Properties.BuildZoneUnionMaxChecks then return false end
			local corners = cellCorners(mins, maxs, origin, angles)
			if cornersInsideSingleZone(corners, component, tolerance) then return true end
			for _, point in ipairs(corners) do
				if not pointInsideZoneUnion(point, component, tolerance) then return false end
			end

			local middle = (mins + maxs) * 0.5
			if not pointInsideZoneUnion(transformedPoint(middle, origin, angles), component, tolerance) then return false end
			local size = maxs - mins
			local longest = math.max(size.x, size.y, size.z)
			if longest <= Properties.BuildZoneUnionResolution or depth >= 18 then
				-- At the numerical-resolution leaf, also sample face/edge interiors on
				-- a 3x3x3 lattice so a narrow uncovered seam cannot hide between corners.
				for x = 0, 2 do
					for y = 0, 2 do
						for z = 0, 2 do
							local point = Vector(
								Lerp(x * 0.5, mins.x, maxs.x),
								Lerp(y * 0.5, mins.y, maxs.y),
								Lerp(z * 0.5, mins.z, maxs.z)
							)
							if not pointInsideZoneUnion(transformedPoint(point, origin, angles), component, tolerance) then return false end
						end
					end
				end
				return true
			end

			if size.x >= size.y and size.x >= size.z then
				return covered(mins, Vector(middle.x, maxs.y, maxs.z), depth + 1)
					and covered(Vector(middle.x, mins.y, mins.z), maxs, depth + 1)
			elseif size.y >= size.z then
				return covered(mins, Vector(maxs.x, middle.y, maxs.z), depth + 1)
					and covered(Vector(mins.x, middle.y, mins.z), maxs, depth + 1)
			end
			return covered(mins, Vector(maxs.x, maxs.y, middle.z), depth + 1)
				and covered(Vector(mins.x, mins.y, middle.z), maxs, depth + 1)
		end
		return covered(localMins, localMaxs, 0)
	end

	-- Numerical tolerance may soften an exterior edge, but it must never join
	-- physically separated zones into one authorised volume.
	for _, component in ipairs(connectedZoneComponents(relevant)) do
		if componentCovered(component) then return true end
	end
	return false
end

local function boundsInsideZoneUnion(boundsMins, boundsMaxs, zones, tolerance)
	return orientedBoundsInsideZoneUnion(boundsMins, boundsMaxs, vector_origin, angle_zero, zones, tolerance)
end

local function entityInsideZoneUnion(entity, zones, tolerance)
	if not IsValid(entity) then return false end
	return orientedBoundsInsideZoneUnion(entity:OBBMins(), entity:OBBMaxs(), entity:GetPos(), entity:GetAngles(), zones, tolerance)
end

Properties.BoundsInsideBuildZoneUnion = boundsInsideZoneUnion
Properties.OrientedBoundsInsideBuildZoneUnion = orientedBoundsInsideZoneUnion
Properties.EntityBoundsInsideBuildZoneUnion = entityInsideZoneUnion

local function zoneVolume(zone)
	local corners = zoneBaseCorners(zone)
	if corners then
		local area, bottomZ = 0, 0
		for index = 1, 4 do
			local current, following = corners[index], corners[(index % 4) + 1]
			area = area + current.x * following.y - following.x * current.y
			bottomZ = bottomZ + current.z
		end
		return math.abs(area) * 0.5 * math.abs((tonumber(zone.top_z or zone.height_z) or 0) - bottomZ / 4)
	end
	local mins, maxs = zoneVectors(zone)
	local size = maxs - mins
	return math.abs(size.x * size.y * size.z)
end


Geometry.VectorData = vectorData
Geometry.NormalizeBuildZone = normalizeBuildZone
Geometry.NormalizeCornerBuildZone = normalizeCornerBuildZone
Geometry.SanitizeBuildZones = sanitizeBuildZones
Geometry.PointInsideZone = pointInsideZone
Geometry.EntityInsideZoneUnion = entityInsideZoneUnion
Geometry.ZoneVolume = zoneVolume
Properties.Geometry = Geometry
Properties.GeometryModuleLoaded = true
return Geometry
