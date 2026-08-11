-- Server-authoritative dynamic economy projection.
-- This service deliberately has no timer or world scan. Mutations arrive through
-- Economy and registered producers; census/reconciliation is lifecycle-driven.
local Director = {
	Version = 2,
	DataPath = "darkrp/economy_director.json",
	JournalPath = "darkrp/economy_events.log",
	StateKey = "economy:director",
	Events = {},
	EventCount = 0,
	PendingBytes = 0,
	JournalBuffer = {},
	JournalBatchSize = 32,
	Revision = 0,
	MoneyRevision = 0,
	MoneyCache = nil,
	MoneyQuoteCacheSeconds = 2,
	MoneyByID = {},
	NamesByID = {},
	LastSeenByID = {},
	Holdings = {},
	Prices = {},
	Definitions = {},
	LootSources = {},
	Vendors = {},
	WarningsList = {},
	Config = {
		mode = "automatic",
		healthyMoneyPerActivePlayer = 4800,
		treasuryRatio = 0.10,
		maxHourlyMovement = 0.05,
		marketFee = 0.01,
		burnStartRatio = 1.25,
		burnResponse = 0.08,
		maxTransactionBurn = 0.15
	},
	Loaded = false,
	Dirty = false,
	LastCensus = 0,
	LastSave = 0
}

DRP.EconomyDirector = Director
DRP.Services.Register("economy_director", Director)
DRP.Services.DependsOn("economy_director", { "storage", "economy" })

local function cleanKey(value)
	value = string.lower(string.Trim(string.sub(tostring(value or ""), 1, 128)))
	if value == "" then return nil end
	return value
end

local function cleanNumber(value)
	return math.floor(tonumber(value) or 0)
end

local function isExcluded(key, definition)
	if definition and (definition.adminOnly or definition.prestige or definition.free or definition.infrastructure) then return true end
	return string.StartWith(tostring(key or ""), "admin:") or string.StartWith(tostring(key or ""), "utility:")
end

DRP.Commodities = DRP.Commodities or {}

function DRP.Commodities.Key(value)
	if isstring(value) then return cleanKey(value) end
	if not istable(value) and not IsValid(value) then return nil end
	if IsValid(value) then
		local class = value:GetClass()
		if class == "player" then return "cash" end
		local weapon = value.GetNW2String and value:GetNW2String("DRPWeapon", "") or ""
		if weapon ~= "" then return "weapon:" .. string.lower(weapon) end
		return "entity:" .. string.lower(class)
	end
	if value.commodity then return cleanKey(value.commodity) end
	if value.kind == "weapon" and value.class then return "weapon:" .. string.lower(tostring(value.class)) end
	if value.kind == "resource" and value.resource then return "resource:" .. string.lower(tostring(value.resource)) end
	if value.kind == "attachment" and value.attachment then return "attachment:" .. string.lower(tostring(value.attachment)) end
	if value.kind == "schematic" and value.schematic then return "schematic:" .. string.lower(tostring(value.schematic)) end
	if value.kind and value.key then return cleanKey(value.kind .. ":" .. value.key) end
	if value.class then return "entity:" .. string.lower(tostring(value.class)) end
	if value.weapon then return "weapon:" .. string.lower(tostring(value.weapon)) end
	if value.model then return "prop:" .. string.lower(tostring(value.model)) end
	if value.key then return cleanKey(value.key) end
	return nil
end

function DRP.Commodities.Definition(key)
	return Director.Definitions[cleanKey(key)]
end

local function holding(key)
	key = cleanKey(key)
	if not key then return nil end
	local value = Director.Holdings[key]
	if not value then
		value = { exact = 0, effective = 0, target = 0, category = "other", events = 0 }
		Director.Holdings[key] = value
	end
	return value
end

function Director:FlushJournal()
	if #self.JournalBuffer == 0 then return true end
	local started = DRP.Profile and DRP.Profile.Begin and DRP.Profile.Begin() or nil
	file.CreateDir("darkrp")
	local payload = util.TableToJSON(self.JournalBuffer, false)
	if payload and payload ~= "" then file.Append(self.JournalPath, payload .. "\n") end
	self.JournalBuffer = {}
	if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("economy.journal_flush", started) end
	return true
end

function Director:QueueJournal(event)
	if not istable(event) then return false end
	self.JournalBuffer[#self.JournalBuffer + 1] = event
	-- An estimate is sufficient for the emergency flush threshold; the normal
	-- event-count checkpoint remains authoritative.
	self.PendingBytes = self.PendingBytes + 96 + #tostring(event.source or "") + #(event.items or {}) * 64
	if #self.JournalBuffer >= self.JournalBatchSize then self:FlushJournal() end
	return true
end

function Director:InvalidateMoneySummary()
	self.MoneyRevision = self.MoneyRevision + 1
end

local function eventAllowed(kind)
	return kind == "mint" or kind == "burn" or kind == "transfer" or kind == "transform" or kind == "custody" or kind == "reconcile"
end

function Director:BeginTransaction(kind, source)
	-- Money mutations are safety-critical.  Normalize an unknown caller kind
	-- instead of returning nil and allowing a purchase to crash the server.
	if not eventAllowed(kind) then kind = "reconcile" end
	return { kind = kind, source = string.sub(tostring(source or "system"), 1, 96), money = 0, items = {}, created = os.time() }
end

function Director:Commit(transaction)
	if not istable(transaction) or not eventAllowed(transaction.kind) then return false, "invalid transaction" end
	local money = cleanNumber(transaction.money)
	local event = {
		id = tostring(os.time()) .. ":" .. tostring(self.Revision + 1) .. ":" .. tostring(self.EventCount + 1),
		revision = self.Revision + 1,
		kind = transaction.kind,
		source = string.sub(tostring(transaction.source or "system"), 1, 96),
		money = money,
		items = transaction.items or {},
		time = os.time()
	}
	self.Revision = event.revision
	self.EventCount = self.EventCount + 1
	self.Events[#self.Events + 1] = event
	if #self.Events > 2000 then table.remove(self.Events, 1) end
	self:QueueJournal(event)
	self.Dirty = true
	if self.EventCount % 100 == 0 or self.PendingBytes >= 1024 * 1024 then self:Save() end
	return true, event
end

function Director:RecordMoney(ply, amount, kind, source)
	amount = cleanNumber(amount)
	if amount == 0 then return true end
	kind = eventAllowed(kind) and kind or "reconcile"
	local steamID = IsValid(ply) and ply:SteamID64() or "system"
	if steamID and steamID ~= "0" then self.MoneyByID[steamID] = math.max(0, cleanNumber(self.MoneyByID[steamID] or 0) + amount) end
	if steamID and steamID ~= "0" and IsValid(ply) then self.NamesByID[steamID]=string.sub(ply:DRPName(),1,64) end
	if steamID and steamID ~= "0" then self.LastSeenByID[steamID] = os.time() end
	if steamID and steamID ~= "0" then self:InvalidateMoneySummary() end
	local tx = self:BeginTransaction(kind, source or "money")
	if not istable(tx) then return false, "economy transaction unavailable" end
	tx.money = amount
	tx.items = { { key = "cash", amount = amount, owner = steamID } }
	return self:Commit(tx)
end

-- Records money destroyed outside a wallet mutation. Settlement burns use
-- this after the payer has supplied the gross amount and the recipient has
-- received only the net amount. This keeps the wallet projection exact while
-- producing one explicit burn receipt for health reporting and auditing.
function Director:RecordBurn(amount, source)
	amount = math.max(0, cleanNumber(amount))
	if amount <= 0 then return true end
	local tx = self:BeginTransaction("burn", source or "transaction burn")
	tx.money = -amount
	tx.items = { { key = "cash", amount = -amount, owner = "system" } }
	return self:Commit(tx)
end

function Director:RecordItem(key, amount, custody, kind, source)
	key, amount = cleanKey(key), cleanNumber(amount)
	if not key or amount == 0 then return false end
	local item = holding(key)
	local weight = ({ listing = 1, world = 1, death = 1, hands = .85, equipped = .85, output = .70, vault = .60, escrow = .25, refund = .10 })[custody or "hands"] or .85
	item.exact = math.max(0, item.exact + amount)
	item.effective = math.max(0, item.effective + amount * weight)
	item.events = item.events + 1
	local tx = self:BeginTransaction(kind or (amount > 0 and "mint" or "burn"), source or "item")
	if not istable(tx) then return false end
	tx.items = { { key = key, amount = amount, custody = custody or "hands", weight = weight } }
	self:Commit(tx)
	return true
end

function Director:RegisterCommodity(definition)
	if not istable(definition) then return false end
	local key = DRP.Commodities.Key(definition) or cleanKey(definition.key)
	if not key then return false end
	local copy = table.Copy(definition)
	copy.key, copy.reference, copy.category = key, math.max(1, cleanNumber(copy.reference or 1)), tostring(copy.category or "other")
	copy.excluded = isExcluded(key, copy)
	self.Definitions[key] = copy
	local item = holding(key)
	if item.target == 0 then item.target = math.max(0, cleanNumber(copy.target or 0)) end
	item.category = copy.category
	return true
end

function Director:RegisterVendor(definition)
	if not istable(definition) or not definition.key then return false end
	self.Vendors[cleanKey(definition.key)] = table.Copy(definition)
	return self:RegisterCommodity(definition)
end

function Director:RegisterLootSource(definition)
	if not istable(definition) or not definition.key then return false end
	self.LootSources[cleanKey(definition.key)] = table.Copy(definition)
	return self:RegisterCommodity(definition)
end

local function clampMultiplier(value)
	return math.Clamp(tonumber(value) or 1, .5, 2.5)
end

function Director:FairValue(key)
	local definition = self.Definitions[cleanKey(key)] or {}
	return math.max(1, cleanNumber(definition.reference or 1))
end

function Director:Quote(key, direction, basePrice)
	local started = DRP.Profile and DRP.Profile.Begin and DRP.Profile.Begin() or nil
	key = cleanKey(key)
	local item, definition = holding(key), self.Definitions[key] or {}
	-- Keep configured references authoritative until the controller has enough
	-- legitimate observations to learn a baseline.
	if (item.events or 0) < 30 then
		self.Prices[key] = self.Prices[key] or { multiplier = 1, confidence = 0, updated = os.time() }
		local price, state = math.max(1, cleanNumber(basePrice or self:FairValue(key))), self.Prices[key]
		if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("economy.quote", started) end
		return price, state
	end
	local target = math.max(1, cleanNumber(item.target or definition.target or 1))
	local supply = math.max(.01, tonumber(item.effective or 0))
	local scarcity = math.sqrt(target / supply)
	local moneySummary = self:MoneySummary(true)
	local money = moneySummary.effectiveMoney
	local healthy = math.max(1, self.Config.healthyMoneyPerActivePlayer * math.max(1, moneySummary.onlinePlayers))
	local monetary = math.sqrt(math.max(.01, money) / healthy)
	local multiplier = direction == "buy" and scarcity / monetary or scarcity * monetary
	local current = self.Prices[key] and self.Prices[key].multiplier or 1
	local elapsed = self.Prices[key] and (os.time() - (self.Prices[key].updated or os.time())) or 3600
	local allowed = math.min(.05, math.max(0, elapsed / 3600) * self.Config.maxHourlyMovement)
	local nextValue = math.Clamp(multiplier, current - allowed, current + allowed)
	if self.Config.mode == "frozen" then nextValue = current end
	self.Prices[key] = { multiplier = clampMultiplier(nextValue), confidence = math.Clamp((item.events or 0) / 30, 0, 1), updated = os.time() }
	local price, state = math.max(1, math.floor(cleanNumber(basePrice or self:FairValue(key)) * self.Prices[key].multiplier)), self.Prices[key]
	if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("economy.quote", started) end
	return price, state
end

function Director:LootFactor(key)
	local item = holding(key)
	if (item.events or 0) < 30 then return 1 end
	local target = math.max(1, cleanNumber(item.target or 1))
	return math.Clamp(math.sqrt(target / math.max(.01, tonumber(item.effective or 0))), .25, 2)
end

function Director:EconomicPressure()
	local money = self:MoneySummary(true)
	local healthyMoney = math.max(1, self.Config.healthyMoneyPerActivePlayer * math.max(1, money.onlinePlayers))
	local moneyRatio = math.max(0, money.effectiveMoney) / healthyMoney
	local supplyValue, targetSupplyValue = 0, 0
	for key, item in pairs(self.Holdings) do
		local target = math.max(0, tonumber(item.target) or 0)
		local definition = self.Definitions[key]
		if target > 0 and not (definition and definition.excluded) then
			local value = self:FairValue(key)
			supplyValue = supplyValue + math.max(0, tonumber(item.effective) or 0) * value
			targetSupplyValue = targetSupplyValue + target * value
		end
	end
	local assetRatio = targetSupplyValue > 0 and (supplyValue / targetSupplyValue) or 0
	return math.max(moneyRatio, assetRatio), moneyRatio, assetRatio, math.floor(supplyValue), math.floor(targetSupplyValue)
end

function Director:TransactionBurnRate()
	if self.Config.mode ~= "automatic" then return 0 end
	local pressure = self:EconomicPressure()
	local excess = math.max(0, pressure - (tonumber(self.Config.burnStartRatio) or 1.25))
	return math.Clamp(excess * (tonumber(self.Config.burnResponse) or 0.08), 0, tonumber(self.Config.maxTransactionBurn) or 0.15)
end

function Director:CalculateTransactionBurn(amount, rateOverride)
	amount = math.max(0, cleanNumber(amount))
	local rate = math.Clamp(tonumber(rateOverride) or self:TransactionBurnRate(), 0, tonumber(self.Config.maxTransactionBurn) or 0.15)
	local burned = math.min(amount, math.floor(amount * rate))
	return burned, amount - burned, rate
end

function Director:MoneySummary(allowBriefStale)
	local minute = math.floor(os.time() / 60)
	local cached = self.MoneyCache
	if cached and cached.minute == minute and (cached.revision == self.MoneyRevision
		or (allowBriefStale and CurTime() - (cached.builtAt or 0) <= self.MoneyQuoteCacheSeconds)) then return cached end
	local started = DRP.Profile and DRP.Profile.Begin and DRP.Profile.Begin() or nil
	local exact, online, effective = 0, 0, 0
	local wallets, richestID, richest = {}, "", 0
	for steamID, amount in pairs(self.MoneyByID) do
		amount = math.max(0, cleanNumber(amount))
		exact = exact + amount
		local ply = player.GetBySteamID64(steamID)
		if IsValid(ply) then online = online + amount end
		wallets[#wallets + 1] = amount
		if amount > richest then richest, richestID = amount, steamID end
		local days = IsValid(ply) and 0 or math.max(0, (os.time() - cleanNumber(self.LastSeenByID[steamID] or os.time())) / 86400)
		local weight = days <= 7 and 1 or days <= 30 and (1 - (days - 7) / 46 * .5) or .1
		effective = effective + amount * weight
	end
	table.sort(wallets)
	local median = wallets[math.max(1, math.ceil(#wallets * .5))] or 0
	local gini=0
	if #wallets>0 and exact>0 then local weighted=0 for index,value in ipairs(wallets) do weighted=weighted+index*value end gini=math.Clamp((2*weighted)/(#wallets*exact)-(#wallets+1)/#wallets,0,1) end
	local richestPlayer=player.GetBySteamID64(richestID)
	cached = { revision=self.MoneyRevision, minute=minute, builtAt=CurTime(), exactMoney=exact, onlineMoney=online, effectiveMoney=effective, medianWallet=median, richestWallet=richest, richestSteamID64=richestID, richestName=IsValid(richestPlayer) and richestPlayer:DRPName() or self.NamesByID[richestID] or "Offline player", dormantCash=math.max(0,exact-effective), walletGini=gini, trackedWallets=#wallets, onlinePlayers=#player.GetHumans() }
	self.MoneyCache = cached
	if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("economy.money_summary", started) end
	return cached
end

function Director:Snapshot()
	local started = DRP.Profile and DRP.Profile.Begin and DRP.Profile.Begin() or nil
	local money = self:MoneySummary()
	local treasury = DRP.Government and cleanNumber(DRP.Government.Treasury) or 0
	local supply,totalSupplyValue = {},0
	for key, item in pairs(self.Holdings) do local value=math.max(0,item.effective or 0)*self:FairValue(key) totalSupplyValue=totalSupplyValue+value supply[key] = { exact = item.exact, effective = item.effective, target = item.target, category = item.category, factor = self:LootFactor(key), price = self.Prices[key] and self.Prices[key].multiplier or 1, value=value } end
	local hourlyMint,hourlyBurn=0,0 local cutoff=os.time()-3600
	for _,event in ipairs(self.Events) do
		if (event.time or 0)>=cutoff then
			if event.kind=="mint" and (event.money or 0)>0 then hourlyMint=hourlyMint+event.money
			elseif event.kind=="burn" and (event.money or 0)<0 then hourlyBurn=hourlyBurn-event.money end
		end
	end
	local pressure,moneyRatio,assetRatio,managedSupplyValue,targetSupplyValue=self:EconomicPressure()
	local burnRate=self:TransactionBurnRate()
	local bonds=DRP.Bonds and DRP.Bonds:Status() or {}
	local snapshot = { revision = self.Revision, exactMoney = money.exactMoney, onlineMoney = money.onlineMoney, effectiveMoney = money.effectiveMoney, medianWallet = money.medianWallet, richestWallet = money.richestWallet, richestSteamID64=money.richestSteamID64, richestName=money.richestName, treasury = treasury, dormantCash = money.dormantCash, supply = supply, supplyValue=math.floor(totalSupplyValue), managedSupplyValue=managedSupplyValue, targetSupplyValue=targetSupplyValue, economicPressure=pressure, moneyRatio=moneyRatio, assetRatio=assetRatio, transactionBurnRate=burnRate, walletGini=money.walletGini, trackedWallets=money.trackedWallets, onlinePlayers=money.onlinePlayers, hourlyMint=hourlyMint, hourlyBurn=hourlyBurn, netHourlyMoney=hourlyMint-hourlyBurn, warnings = self.WarningsList, mitigations={"Commodity loot weights follow live scarcity","Vendor quotes move no more than configured hourly limit","Offline cash receives declining effective weight",burnRate>0 and ("Successful transfers burn "..string.format("%.2f",burnRate*100).."%") or "Transaction burn is inactive below the pressure threshold","Existing balances are never confiscated"}, journalBytes = self.PendingBytes, lastCensus = self.LastCensus, database = DRP.Storage and DRP.Storage.IsAvailable() or false, mode = self.Config.mode }
	snapshot.bondIssuance = bonds.issuance == true
	snapshot.bondPrincipal = bonds.principal or 0
	snapshot.bondLiability = bonds.liability or 0
	snapshot.bondDebt = bonds.debt or 0
	snapshot.bondDeficit = bonds.deficit or 0
	snapshot.bondGlobalCap = bonds.globalCap or 0
	if DRP.Profile and DRP.Profile.Finish then DRP.Profile.Finish("economy.snapshot", started) end
	return snapshot
end

function Director:Warnings(snapshot)
	snapshot = snapshot or self:Snapshot()
	local warnings = {}
	local healthy = math.max(1, self.Config.healthyMoneyPerActivePlayer * math.max(1, snapshot.onlinePlayers))
	if snapshot.effectiveMoney > healthy * 1.25 then warnings[#warnings + 1] = { key = "inflation", severity = "warning", text = "Effective money is above the healthy target." } end
	if snapshot.effectiveMoney < healthy * .75 and snapshot.effectiveMoney > 0 then warnings[#warnings + 1] = { key = "deflation", severity = "warning", text = "Effective money is below the healthy target." } end
	if snapshot.treasury < snapshot.exactMoney * .02 and snapshot.exactMoney > 0 then warnings[#warnings + 1] = { key = "treasury", severity = "info", text = "Treasury liquidity is unusually low." } end
	if snapshot.walletGini>.75 and snapshot.trackedWallets>=5 then warnings[#warnings+1]={key="concentration",severity="warning",text="Wealth concentration is unusually high (Gini "..string.format("%.2f",snapshot.walletGini)..")."} end
	if snapshot.netHourlyMoney>math.max(10000,snapshot.effectiveMoney*.10) then warnings[#warnings+1]={key="velocity",severity="warning",text="Net money creation during the last hour is unusually high."} end
	if (snapshot.transactionBurnRate or 0)>0 then warnings[#warnings+1]={key="transaction_burn",severity="info",text="Automatic transaction burning is active at "..string.format("%.2f",snapshot.transactionBurnRate*100).."%."} end
	if (snapshot.bondDeficit or 0) > 0 then
		warnings[#warnings + 1] = { key = "bond_deficit", severity = "critical", text = "Government bond liabilities are in deficit by $" .. string.Comma(snapshot.bondDeficit) .. "; new issuance is locked and government revenue is servicing the debt." }
	end
	if not snapshot.database then warnings[#warnings+1]={key="database",severity="critical",text="Database is unavailable; local economy and player outboxes are retaining changes."} end
	for key, item in pairs(self.Holdings) do
		if item.target > 0 and (item.effective < item.target * .35 or item.effective > item.target * 2.5) then warnings[#warnings + 1] = { key = "supply:" .. key, severity = "warning", text = "Commodity " .. key .. " is outside its healthy supply band." } end
	end
	if self.PendingBytes > 1024 * 1024 then warnings[#warnings + 1] = { key = "journal", severity = "critical", text = "Economy journal is waiting for a database/local projection flush." } end
	self.WarningsList = warnings
	return warnings
end

function Director:Census()
	for _, ply in player.Iterator() do
		if not ply:IsBot() and ply:SteamID64() ~= "0" then
		self.MoneyByID[ply:SteamID64()] = math.max(0, cleanNumber(ply:DRPMoney()))
		self.NamesByID[ply:SteamID64()] = string.sub(ply:DRPName(),1,64)
		self.LastSeenByID[ply:SteamID64()] = os.time()
		end
	end
	self.LastCensus = os.time()
	self:InvalidateMoneySummary()
	self.Dirty = true
	return true
end

function Director:Save(callback)
	self:FlushJournal()
	local payload = util.TableToJSON({ version = self.Version, revision = self.Revision, money = self.MoneyByID, names = self.NamesByID, lastSeen = self.LastSeenByID, holdings = self.Holdings, prices = self.Prices, config = self.Config, census = self.LastCensus }, false)
	if not payload then return false end
	file.CreateDir("darkrp")
	file.Write(self.DataPath, payload)
	-- The local projection is the durable recovery source. Bound the temporary
	-- write-ahead journal once that projection has been written successfully.
	file.Write(self.JournalPath, "")
	self.PendingBytes = 0
	self.LastSave = os.time()
	self.Dirty = false
	if DRP.Storage and DRP.Storage.SaveWorldState then
		local queued = DRP.Storage.SaveWorldState(self.StateKey, payload, function(success, reason)
			if success ~= true then self.Dirty = true ErrorNoHalt("[DRP ECONOMY] projection save deferred: " .. tostring(reason or "storage unavailable") .. "\n") end
			if callback then callback(success, reason) end
		end)
		if queued == false then self.Dirty = true end
	elseif callback then callback(true) end
	return true
end

function Director:Load()
	local decoded = util.JSONToTable(file.Read(self.DataPath, "DATA") or "")
	local function apply(raw)
		local data = istable(raw) and raw or decoded
		if istable(data) then
			self.Revision = cleanNumber(data.revision)
			self.MoneyByID = istable(data.money) and data.money or self.MoneyByID
			self.NamesByID = istable(data.names) and data.names or self.NamesByID
			self.LastSeenByID = istable(data.lastSeen) and data.lastSeen or self.LastSeenByID
			self.Holdings = istable(data.holdings) and data.holdings or self.Holdings
			self.Prices = istable(data.prices) and data.prices or self.Prices
			self.Config = istable(data.config) and table.Merge(self.Config, data.config) or self.Config
			self.LastCensus = cleanNumber(data.census)
		end
		self:InvalidateMoneySummary()
		self.Loaded = true
		self:Census()
		self:Warnings()
	end
	if DRP.Storage and DRP.Storage.LoadWorldState then
		DRP.Storage.LoadWorldState(self.StateKey, function(success, payload) apply(success and util.JSONToTable(payload or "") or nil) end)
	else apply(nil) end
end

function Director:SetPolicy(actor, policy)
	if not IsValid(actor) or not DRP.Admin or not DRP.Admin.IsOwner(actor) or not istable(policy) then return false end
	for key, value in pairs(policy) do
		if key == "mode" and ({ automatic = true, observe = true, frozen = true })[value] then self.Config.mode = value end
		if key == "healthyMoneyPerActivePlayer" then self.Config.healthyMoneyPerActivePlayer = math.Clamp(cleanNumber(value), 100, 1000000) end
		if key == "burnStartRatio" then self.Config.burnStartRatio = math.Clamp(tonumber(value) or 1.25, 1, 10) end
		if key == "burnResponse" then self.Config.burnResponse = math.Clamp(tonumber(value) or 0.08, 0, 1) end
		if key == "maxTransactionBurn" then self.Config.maxTransactionBurn = math.Clamp(tonumber(value) or 0.15, 0, 0.50) end
	end
	if DRP.Audit then DRP.Audit.Log(actor, "economy_policy_changed", nil, util.TableToJSON(policy, false) or "") end
	self.Dirty = true
	return self:Save()
end

function Director:Status()
	return self:Snapshot()
end

function Director:Reconcile(scope)
	if scope == "money" or scope == "all" or scope == nil then self:Census() end
	self:Warnings()
	self.Dirty = true
	return self:Save()
end

function Director:Start()
	self:Load()
	for _, definition in ipairs(DRP.JobEntities or {}) do
		if definition.price and not definition.ownerOnly then
			self:RegisterVendor({ key = "entity:" .. tostring(definition.key), reference = definition.price, target = definition.target or 30, category = definition.category or "job entity" })
		end
	end
	for class, entry in pairs(DRP.Armory and DRP.Armory.ByClass or {}) do
		if istable(entry) and entry.price and not entry.adminOnly then
			self:RegisterVendor({ key = "weapon:" .. tostring(class), reference = entry.price, target = entry.target or 20, category = "weapon" })
		end
	end
	-- Seed the commodity registry from the authoritative crafting catalogue and
	-- item definitions.  These targets are deliberately conservative: until 30
	-- observations exist the controller leaves prices and loot at their normal
	-- values, so startup never creates a sudden economy shock.
	for key, item in pairs(DRP.CraftingShared and DRP.CraftingShared.Items or {}) do
		local group = tostring(item.group or "other")
		local target = group == "raw" and 180 or group == "component" and 90 or group == "ammo" and 120 or group == "controlled" and 24 or 60
		self:RegisterLootSource({ key = "resource:" .. key, reference = 5, target = target, category = "crafting:" .. group })
	end
	for _, recipe in ipairs(DRP.Crafting and DRP.Crafting.Catalog or {}) do
		local output = recipe.output or {}
		local key = DRP.Commodities.Key(output)
		if key then self:RegisterCommodity({ key = key, reference = math.max(1, tonumber(recipe.xp) or 1), target = recipe.kind == "weapon" and 12 or 40, category = "crafting_output" }) end
	end
	hook.Add("DRPPlayerReady", "DRP.EconomyDirector.PlayerReady", function(ply) if IsValid(ply) and not ply:IsBot() then self.MoneyByID[ply:SteamID64()] = cleanNumber(ply:DRPMoney()) self.NamesByID[ply:SteamID64()]=string.sub(ply:DRPName(),1,64) self.LastSeenByID[ply:SteamID64()] = os.time() self:InvalidateMoneySummary() self.Dirty = true end end)
	hook.Add("PlayerDisconnected", "DRP.EconomyDirector.Disconnect", function(ply) if IsValid(ply) and not ply:IsBot() then self.MoneyByID[ply:SteamID64()] = cleanNumber(ply:DRPMoney()) self.NamesByID[ply:SteamID64()]=string.sub(ply:DRPName(),1,64) self.LastSeenByID[ply:SteamID64()] = os.time() self:InvalidateMoneySummary() self:Save() end end)
end

function Director:Stop()
	if self.Dirty then self:Census() self:Save() else self:FlushJournal() end
end

local healthRequest = "drp_economy_health_request_v1"
local healthSnapshot = "drp_economy_health_snapshot_v1"
util.AddNetworkString(healthRequest)
util.AddNetworkString(healthSnapshot)

DRP.Net.Receive(healthRequest, function(_, ply)
	if net.ReadUInt(8) ~= DRP.ProtocolVersion then return end
	if not DRP.Admin or not DRP.Admin.Has(ply, "server_interactions") then DRP.Net.Notify(ply, "HeadAdmin+ access is required for Economy Health.", 3) return end
	if not DRP.Net.Allow(ply, "economy_health", 1, 2) then return end
	local snapshot = Director:Status()
	snapshot.warnings = Director:Warnings(snapshot)
	local payload = util.Compress(util.TableToJSON(snapshot, false) or "{}") or ""
	net.Start(healthSnapshot)
	net.WriteUInt(DRP.ProtocolVersion, 8)
	net.WriteUInt(math.min(#payload, 1048575), 20)
	net.WriteData(payload, math.min(#payload, 1048575))
	net.Send(ply)
end)

concommand.Add("drp_economy_status", function(ply)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local status = Director:Status()
	print(string.format("[DRP ECONOMY] revision=%d exact=$%d online=$%d effective=$%d treasury=$%d commodities=%d pressure=%.2fx burn=%.2f%% warnings=%d journal=%dB", status.revision, status.exactMoney, status.onlineMoney, status.effectiveMoney, status.treasury, table.Count(status.supply), status.economicPressure or 0, (status.transactionBurnRate or 0)*100, #Director:Warnings(status), status.journalBytes))
	if IsValid(ply) then DRP.Net.Notify(ply, "Economy status printed to the server console.", 1) end
end)

concommand.Add("drp_economy_reconcile", function(ply, _, args)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local scope = tostring(args[1] or "all")
	local ok = Director:Reconcile(scope)
	print("[DRP ECONOMY] reconciliation " .. (ok and "completed" or "deferred") .. " scope=" .. scope)
	if IsValid(ply) then DRP.Net.Notify(ply, ok and "Economy reconciliation completed." or "Economy reconciliation was deferred; the local recovery snapshot is retained.", ok and 1 or 3) end
end)

concommand.Add("drp_economy_mode", function(ply, _, args)
	if IsValid(ply) and (not DRP.Admin or not DRP.Admin.IsOwner(ply)) then return end
	local mode = tostring(args[1] or "")
	if not ({ automatic = true, observe = true, frozen = true })[mode] then
		print("[DRP ECONOMY] usage: drp_economy_mode automatic|observe|frozen")
		return
	end
	local actor = IsValid(ply) and ply or nil
	if actor then Director:SetPolicy(actor, { mode = mode }) else Director.Config.mode = mode Director:Save() end
	print("[DRP ECONOMY] controller mode=" .. mode)
end)
