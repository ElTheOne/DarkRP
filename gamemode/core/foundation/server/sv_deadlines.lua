local Deadlines = {
	Heap = {},
	ByKey = {},
	MinDelay = 0.01,
	MaxPerRun = 128
}

DRP.Deadlines = Deadlines
DRP.Services.Register("deadlines", Deadlines)

local function swap(first, second)
	local heap = Deadlines.Heap
	heap[first], heap[second] = heap[second], heap[first]
	heap[first].index, heap[second].index = first, second
end

local function siftUp(index)
	while index > 1 do
		local parent = math.floor(index * 0.5)
		if Deadlines.Heap[parent].deadline <= Deadlines.Heap[index].deadline then break end
		swap(parent, index)
		index = parent
	end
end

local function siftDown(index)
	local heap = Deadlines.Heap
	while true do
		local left, right, smallest = index * 2, index * 2 + 1, index
		if left <= #heap and heap[left].deadline < heap[smallest].deadline then smallest = left end
		if right <= #heap and heap[right].deadline < heap[smallest].deadline then smallest = right end
		if smallest == index then break end
		swap(index, smallest)
		index = smallest
	end
end

local function remove(entry)
	local heap, index = Deadlines.Heap, entry.index
	if not index or heap[index] ~= entry then return end
	Deadlines.ByKey[entry.key] = nil
	local last = table.remove(heap)
	entry.index = nil
	if last and last ~= entry then
		heap[index] = last
		last.index = index
		siftUp(index)
		siftDown(last.index)
	end
end

local function arm()
	local entry = Deadlines.Heap[1]
	if not entry then timer.Remove("DRP.Deadlines") return end
	local delay = math.max(Deadlines.MinDelay, entry.deadline - CurTime())
	timer.Create("DRP.Deadlines", delay, 1, function() Deadlines:Run() end)
end

function Deadlines.Schedule(key, deadline, callback)
	key, deadline = tostring(key or ""), tonumber(deadline)
	if key == "" or not deadline or not isfunction(callback) then return false end
	local entry = Deadlines.ByKey[key]
	if entry then
		local previous = entry.deadline
		entry.deadline, entry.callback = deadline, callback
		if deadline < previous then siftUp(entry.index) else siftDown(entry.index) end
		arm()
		return true
	end
	entry = { key = key, deadline = deadline, callback = callback, index = #Deadlines.Heap + 1 }
	Deadlines.Heap[entry.index] = entry
	Deadlines.ByKey[key] = entry
	siftUp(entry.index)
	arm()
	return true
end

function Deadlines.Cancel(key)
	local entry = Deadlines.ByKey[tostring(key or "")]
	if not entry then return false end
	remove(entry)
	arm()
	return true
end

function Deadlines:Run()
	local started, now, processed = DRP.Profile.Begin(), CurTime(), 0
	while processed < self.MaxPerRun do
		local entry = self.Heap[1]
		if not entry or entry.deadline > now then break end
		remove(entry)
		processed = processed + 1
		local success, reason = pcall(entry.callback, entry.key, entry.deadline)
		if not success then ErrorNoHalt("[DRP] deadline callback failed: " .. tostring(reason) .. "\n") end
	end
	DRP.Profile.Finish("deadlines.run", started)
	arm()
end

function Deadlines:Start()
	arm()
end

function Deadlines:Stop()
	timer.Remove("DRP.Deadlines")
	self.Heap, self.ByKey = {}, {}
end
