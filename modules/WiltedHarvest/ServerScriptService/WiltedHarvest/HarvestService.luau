--!strict
--[[
	=== HarvestService =========================================================

	The server half of WiltedHarvest. Receives events, rejects duplicates,
	keeps each player's summary, hands summaries to storage and events to
	sinks. Never grants, prices or changes game state.

	USAGE - once, from the game's composition root (server):

		local HarvestService = require(ServerScriptService.WiltedHarvest.HarvestService)
		HarvestService.Start({
			GetHarvestTable = function(player) ... end,   -- see Storage (HostTable)
			MarkDirty = function(player) ... end,         -- optional
		})

		-- anywhere on the server, AFTER the game has committed the change:
		HarvestService.Emit(player, "thing_bought", { ItemId = "Sword", Price = 100 }, transactionId)

	---------------------------------------------------------------------------
	WHY Emit NEVER YIELDS AND NEVER THROWS
	---------------------------------------------------------------------------

	Emit is called from the game's own hot paths (a purchase, a click). It
	only validates and enqueues; counting, storage and sinks run later in
	Harvest's own tasks. A bad call returns (false, reason) instead of
	throwing, so a Harvest bug or a typo can never break the game's code path
	(Harvest docs: "Game servers must continue to function if Harvest is
	unavailable").

	---------------------------------------------------------------------------
	WHY EVERY EVENT HAS AN ID, AND WHAT A DUPLICATE IS
	---------------------------------------------------------------------------

	The same fact can arrive twice: a receipt processed on two servers at once
	(Roblox documents this), a retried game transaction, a host bug. Pass the
	game's own transaction id as `eventId` and Harvest counts it once:

	  * within this server session: an exact set of every id seen, and
	  * across servers and rejoins: the last Tunables.RecentEventIds ids,
	    saved in the summary.

	An event emitted WITHOUT an id gets a fresh one and can never be detected
	as a duplicate. Use that only for facts that cannot repeat.

	---------------------------------------------------------------------------
	WHAT HAPPENS WHILE A SUMMARY IS LOADING
	---------------------------------------------------------------------------

	Events for that player wait (up to Tunables.PendingPerPlayer) and are
	applied in order once it loads. If it never loads (storage missing or
	failing past LoadTimeoutSeconds), the player is "unrecorded" for the
	session: events still reach the sinks, nothing is saved, Stats() says so.

	---------------------------------------------------------------------------
	DEPENDENCIES (Start argument; all optional)
	---------------------------------------------------------------------------

	  GetHarvestTable, MarkDirty, EraseHarvestTable   HostTable storage (default)
	  Storage = "OwnStore"                            Harvest's own DataStore
	  StorageAdapter = adapter                        any adapter (see Storage)
	  Config = table                                  instead of WiltedConfig.Harvest
	  AnalyticsService = object                       stand-in for the sink
	  Clock, Wait, NewId, JobId, Players              injectable for tests
	  Collectors = { ... }                            replace the built-in collectors (tests)
	  MonetizationGlue = false                        do not listen to WiltedMonetization
	  Monetization = api                              use this API instead of the core lookup (tests)
	  AutoSave = false, BindToClose = false,
	  RegisterWithCore = false                        test copies only
]]

local HttpService = game:GetService("HttpService")
local PlayersService = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sinks = require(script.Parent.Sinks)
local Storage = require(script.Parent.Storage)
local Extensions = require(script.Parent.Collectors.Extensions)
local AdsCollector = require(script.Parent.Collectors.Ads)
local MonetizationGlue = require(script.Parent.MonetizationGlue)
local BUILTIN_COLLECTORS: { any } = {
	require(script.Parent.Collectors.Sessions) :: any,
	require(script.Parent.Collectors.Spend) :: any,
	Extensions :: any,
	require(script.Parent.Collectors.Social) :: any,
	require(script.Parent.Collectors.Community) :: any,
	AdsCollector :: any,
}

--=============================================================================
-- THE SHARED HALF AND THE CORE
--
-- Without the shared root or a usable core this module still loads and
-- returns a DISABLED service: every call refuses with the reason, Start wires
-- nothing. Never an error.
--=============================================================================

local Harvest: any = nil
local Core: any = nil
local disabledReason: string? = nil

do
	local root = ReplicatedStorage:FindFirstChild("WiltedHarvest")
	local ok, result = false, nil
	if root and root:IsA("ModuleScript") then
		ok, result = pcall(require, root)
	end
	if not root or not root:IsA("ModuleScript") then
		disabledReason = "the WiltedHarvest shared module is missing from ReplicatedStorage"
		warn("[WiltedHarvest] " .. tostring(disabledReason) .. " - service disabled")
	elseif not ok or type(result) ~= "table" then
		disabledReason = "the WiltedHarvest shared module failed to load: " .. tostring(result)
		warn("[WiltedHarvest] " .. tostring(disabledReason) .. " - service disabled")
	else
		Harvest = result
		local core, reason = Harvest.GetCore()
		if not core then
			disabledReason = reason or "WiltedCore is unavailable"
		else
			Core = core
		end
	end
end

local function refuse(): (boolean, string)
	return false, disabledReason :: string
end

if disabledReason then
	local inert = { Connect = function() return { Disconnect = function() end } end }
	local Disabled = {
		VERSION = if Harvest then Harvest.VERSION else "0.0.0",
		EventAccepted = inert,
		SummaryLoaded = inert,
		Emit = refuse,
		GetSummary = refuse,
		Forget = refuse,
		RegisterSink = refuse,
		ProcessQueue = function() return 0 end,
		Tick = function() return 0 end,
		GetDerived = refuse,
		SaveNow = function() return 0 end,
		Stats = function() return { Disabled = disabledReason } end,
		IsEnabled = function() return false, disabledReason end,
	}
	Disabled.Start = function()
		warn("[WiltedHarvest] Start ignored: " .. tostring(disabledReason))
		return Disabled
	end
	return Disabled :: any
end

local Enums = Harvest.Enums
local Schema = Harvest.Schema
local log = Core.Log.new("WiltedHarvest")
local life = Core.Lifecycle.new("WiltedHarvest", log, {
	messages = { problemsHeading = "%d config problem(s):" },
})

local HarvestService = {}
HarvestService.VERSION = Harvest.VERSION

-- Observation only (handbook 5.4): fire after the decision, never drive it.
-- EventAccepted(player, envelope)        an event was counted and sent on
-- SummaryLoaded(player, info)            info = Schema.MigrateInfo, or
--                                        { Unrecorded = true, Reason = "..." }
HarvestService.EventAccepted = Core.Signal.new(log)
HarvestService.SummaryLoaded = Core.Signal.new(log)

--=============================================================================
-- STATE
--=============================================================================

type PlayerState = {
	Player: Player,
	UserId: number,
	SessionId: string,
	Status: "loading" | "ready" | "unrecorded",
	Summary: { [string]: any }?,
	ReadOnly: boolean,
	Pending: { any },
	SeenIds: { [string]: boolean },
	Dirty: boolean,
	Forgotten: boolean,
	JoinedAt: number,
	-- Per-session working values owned by collectors (never saved).
	Scratch: { [string]: any },
	CollectorsReady: boolean,
}

local config: any = nil
local deps: { [string]: any } = {}
local adapter: Storage.Adapter? = nil
local sinkFns: { [string]: (any, Player?) -> () } = {}
local customSinks = Core.Registry.new({ log = log, label = "sink", nameLabel = "sink name" })
local memoryList: { any }? = nil

local collectors: { any } = BUILTIN_COLLECTORS
local collectorCtx: any = nil
local glueHandle: any = nil
local currentGroup: { Mode: string, GroupId: number? } = { Mode = "GameOwner" }
-- Id-less counter amounts summed in memory: player -> key -> amount.
local pendingCounters: { [any]: { [string]: any } } = {} -- number, or BigCount form for Big counters

local states: { [any]: PlayerState } = {}
local left: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local queue: { any } = {}
local drainScheduled = false

local clock: () -> number = os.time
local waitFn: (number) -> any = task.wait
local newId: () -> string = function()
	return HttpService:GenerateGUID(false)
end
local playersSource: any = PlayersService

local stats = {
	Accepted = 0,
	Refused = 0,
	Duplicates = 0,
	Dropped = 0,
	Unrecorded = 0,
	PendingDropped = 0,
	SinkErrors = 0,
	SaveErrors = 0,
	AnalyticsSkipped = 0,
	CountersBatched = 0,
	FriendCheckFailures = 0,
	GroupCheckFailures = 0,
}

-- One warning per key per 60 s: a broken sink or a flood must not spam.
local lastWarned: { [string]: number } = {}
local function warnThrottled(key: string, message: string, ...: any)
	local now = clock()
	local last = lastWarned[key]
	if last and now - last < 60 then
		return
	end
	lastWarned[key] = now
	log:Warn(message, ...)
end

--=============================================================================
-- SINKS
--=============================================================================

local function deliver(envelope: any, player: Player?)
	local function run(name: string, fn: (any, Player?) -> ())
		task.spawn(function()
			local ok, err = pcall(fn :: any, envelope, player)
			if not ok then
				stats.SinkErrors += 1
				warnThrottled("sink:" .. name, "sink %q errored (further errors from it hidden for 60s): %s",
					name, tostring(err))
			end
		end)
	end
	for _, name in ipairs(config.Sinks) do
		local fn = sinkFns[name]
		if fn then
			run(name, fn)
		end
	end
	for _, name in ipairs(customSinks:Registered()) do
		local fn = customSinks:Get(name)
		if fn then
			run(name, fn :: any)
		end
	end
end

-- Defined in COLLECTORS below; apply() needs it.
local runEventCollectors: (any, any) -> ()
local notifyRoster: (any) -> ()

--=============================================================================
-- PROCESSING
--=============================================================================

local function apply(state: PlayerState?, item: any)
	local envelope = item.Envelope
	local eventId: string = envelope.EventId

	if state then
		if state.SeenIds[eventId] then
			stats.Duplicates += 1
			if state.Summary and not state.ReadOnly then
				state.Summary.Meta.Duplicates += 1
				state.Dirty = true
			end
			return
		end
		state.SeenIds[eventId] = true
		local summary = state.Summary
		if summary and not state.ReadOnly then
			if not Schema.RememberEventId(summary, eventId, config.Tunables.RecentEventIds) then
				stats.Duplicates += 1
				summary.Meta.Duplicates += 1
				state.Dirty = true
				return
			end
			local counts = summary.Meta.EventCounts
			counts[envelope.EventType] = (counts[envelope.EventType] or 0) + 1
			summary.Meta.UpdatedAt = envelope.ServerTime
			state.Dirty = true
			runEventCollectors(state, envelope)
		else
			stats.Unrecorded += 1
		end
	else
		stats.Unrecorded += 1
	end

	stats.Accepted += 1
	deliver(envelope, item.Player)
	HarvestService.EventAccepted:Fire(item.Player, envelope)
end

local ensureState: (Player) -> PlayerState?

local function processItem(item: any)
	local player = item.Player
	local state = states[player]
	if not state and not left[player] then
		state = ensureState(player) :: any
	end
	if state and state.Status == "loading" then
		if #state.Pending >= config.Tunables.PendingPerPlayer then
			stats.PendingDropped += 1
			warnThrottled("pending", "events for %s are waiting on a slow summary load - dropping some", tostring(player))
			return
		end
		table.insert(state.Pending, item)
		return
	end
	apply(state, item)
end

--[[
	Processes every queued event now, in order. Returns how many. Normally
	runs on its own (deferred after Emit); exposed for BindToClose and tests.
]]
function HarvestService.ProcessQueue(): number
	drainScheduled = false
	local count = 0
	while #queue > 0 do
		local item = table.remove(queue, 1)
		count += 1
		local ok, err = pcall(processItem :: any, item)
		if not ok then
			warnThrottled("process", "processing an event errored: %s", tostring(err))
		end
	end
	return count
end

local function scheduleDrain()
	if drainScheduled then
		return
	end
	drainScheduled = true
	task.defer(HarvestService.ProcessQueue)
end

--=============================================================================
-- COLLECTORS
--
-- Built-in modules that turn the session itself into summary fields and
-- internal events (Collectors.Sessions in H2). Each hook runs inside pcall:
-- a collector bug costs that collector's numbers, never the service.
--=============================================================================

local function writable(state: PlayerState): boolean
	return state.Summary ~= nil and not state.ReadOnly and not state.Forgotten
end

local function runCollectors(hook: string, state: PlayerState, now: number)
	for _, collector in ipairs(collectors) do
		local fn = collector[hook]
		if type(fn) == "function" then
			local ok, err = pcall(fn, collectorCtx, state, now, writable(state))
			if not ok then
				warnThrottled("collector:" .. tostring(collector.Name) .. hook,
					"collector %s.%s errored: %s", tostring(collector.Name), hook, tostring(err))
			end
		end
	end
end

-- Someone joined (`joined`) or left (nil): collectors that care about who
-- is in the server (Social) re-evaluate every OTHER ready player.
function notifyRoster(joined: any)
	local now = clock()
	for _, state in pairs(states) do
		if state ~= joined and state.CollectorsReady then
			runCollectors("OnRoster", state, now)
		end
	end
end

-- An accepted event, for collectors that summarise events (Spend,
-- Extensions). Runs only for writable summaries, after dedupe and counting.
function runEventCollectors(state: any, envelope: any)
	for _, collector in ipairs(collectors) do
		local fn = collector.OnEvent
		if type(fn) == "function" then
			local ok, err = pcall(fn, collectorCtx, state, envelope, true)
			if not ok then
				warnThrottled("collector:" .. tostring(collector.Name) .. "OnEvent",
					"collector %s.OnEvent errored: %s", tostring(collector.Name), tostring(err))
			end
		end
	end
end

--[[
	Runs every collector's periodic step now (session time, streak days).
	Returns how many players were ticked. Runs before each periodic save;
	exposed for tests.
]]
function HarvestService.Tick(): number
	HarvestService.FlushCounters()
	local now = clock()
	local count = 0
	for _, collector in ipairs(collectors) do
		local fn = collector.OnServerTick
		if type(fn) == "function" then
			local ok, err = pcall(fn, collectorCtx, now)
			if not ok then
				warnThrottled("collector:" .. tostring(collector.Name) .. "OnServerTick",
					"collector %s.OnServerTick errored: %s", tostring(collector.Name), tostring(err))
			end
		end
	end
	for _, state in pairs(states) do
		if state.CollectorsReady and writable(state) then
			runCollectors("OnTick", state, now)
			count += 1
		end
	end
	return count
end

--=============================================================================
-- LOADING
--=============================================================================

local function finishLoad(state: PlayerState, summary: { [string]: any }?, info: any)
	if summary then
		state.Summary = summary
		state.ReadOnly = info.ReadOnly == true
		state.Status = "ready"
		if info.Changed and not state.ReadOnly then
			state.Dirty = true
		end
		for _, problem in ipairs(info.Problems or {}) do
			log:Warn("summary of %s: %s", tostring(state.Player), problem)
		end
	else
		state.Status = "unrecorded"
	end
	state.CollectorsReady = true
	runCollectors("OnReady", state, clock())
	local pending = state.Pending
	state.Pending = {}
	for _, item in ipairs(pending) do
		local ok, err = pcall(apply :: any, state, item)
		if not ok then
			warnThrottled("process", "processing an event errored: %s", tostring(err))
		end
	end
	HarvestService.SummaryLoaded:Fire(state.Player, info)
end

-- Copies `fresh` into `target` so a host's table keeps its identity.
local function adopt(target: { [any]: any }, fresh: { [any]: any })
	if target == fresh then
		return
	end
	table.clear(target)
	for k, v in pairs(fresh) do
		target[k] = v
	end
end

local function load(state: PlayerState)
	local store = adapter
	if not store then
		finishLoad(state, nil, { Unrecorded = true, Reason = "no storage" })
		return
	end
	local deadline = clock() + config.Tunables.LoadTimeoutSeconds
	local lastReason = "unknown"
	while true do
		if states[state.Player] ~= state then
			return -- left while loading
		end
		local ok, status, value = pcall(store.Load, state.Player)
		if not ok then
			status, value = "fail", tostring(status)
		end
		if status == "ok" then
			local saved = value
			local summary, info = Schema.Migrate(saved, clock())
			if type(saved) == "table" and not info.ReadOnly then
				adopt(saved, summary)
				summary = saved
			end
			finishLoad(state, summary, info)
			return
		elseif status == "retry" and clock() < deadline then
			lastReason = tostring(value)
			waitFn(config.Tunables.LoadRetrySeconds)
		else
			local reason = if status == "retry" then
				string.format("gave up after %ds: %s", config.Tunables.LoadTimeoutSeconds, tostring(value or lastReason))
				else tostring(value)
			log:Warn("summary for %s not loaded (%s) - not recorded this session", tostring(state.Player), reason)
			finishLoad(state, nil, { Unrecorded = true, Reason = reason })
			return
		end
	end
end

function ensureState(player: Player): PlayerState?
	local existing = states[player]
	if existing then
		return existing
	end
	if left[player] or type(player) ~= "userdata" and type(player) ~= "table" then
		return nil
	end
	local userId = (player :: any).UserId
	if type(userId) ~= "number" then
		return nil
	end
	local state: PlayerState = {
		Player = player,
		UserId = userId,
		SessionId = newId(),
		Status = "loading",
		Summary = nil,
		ReadOnly = false,
		Pending = {},
		SeenIds = {},
		Dirty = false,
		Forgotten = false,
		JoinedAt = clock(),
		Scratch = {},
		CollectorsReady = false,
	}
	states[player] = state
	notifyRoster(state)
	task.spawn(load, state)
	return state
end

--=============================================================================
-- SAVING
--=============================================================================

local function saveState(state: PlayerState, releasing: boolean): boolean
	local store = adapter
	local summary = state.Summary
	if not store or not summary or state.ReadOnly or state.Forgotten then
		return true
	end
	if not releasing and not state.Dirty then
		return true
	end
	state.Dirty = false
	local fn = if releasing then store.Release else store.Save
	local ok, saved, reason = pcall(fn, state.Player, summary)
	if not ok or saved ~= true then
		stats.SaveErrors += 1
		state.Dirty = true
		warnThrottled("save", "saving the summary of %s failed: %s", tostring(state.Player),
			tostring(if ok then reason else saved))
		return false
	end
	return true
end

--[[
	Hands every changed summary to storage now. Returns how many were saved.
	Runs every Tunables.SaveIntervalSeconds on its own; exposed for tests.
]]
function HarvestService.SaveNow(): number
	local count = 0
	for _, state in pairs(states) do
		if state.Dirty and saveState(state, false) then
			count += 1
		end
	end
	return count
end

local function onLeave(player: Player)
	-- Events emitted just before leaving still belong to this session.
	HarvestService.FlushCounters(player)
	HarvestService.ProcessQueue()
	local state = states[player]
	if state and state.CollectorsReady then
		-- Collectors close the session; their events are applied while the
		-- player still has a state, so they carry the SessionId and count.
		runCollectors("OnLeave", state, clock())
		HarvestService.ProcessQueue()
	end
	left[player] = true
	if not state then
		return
	end
	states[player] = nil
	notifyRoster(nil)
	saveState(state, true)
end

--=============================================================================
-- PUBLIC API
--=============================================================================

local function isPlayerLike(value: any): boolean
	if typeof(value) == "Instance" then
		return value:IsA("Player")
	end
	-- Test doubles: a table with a numeric UserId.
	return type(value) == "table" and type(value.UserId) == "number"
end

--[[
	Records a fact about a player. Returns (true, eventId) or (false, reason).
	Never yields, never throws.

	  player     the Player the fact is about
	  eventType  a built-in type (HarvestEnums.EventType) or one declared in
	             WiltedConfig.Harvest.Events
	  payload    table of fields (validated against the declaration)
	  eventId    the game's own transaction id, for duplicate detection
	             (optional; strongly recommended for anything that can retry)

	Emit AFTER the game has committed the change it describes.
]]
function HarvestService.Emit(player: any, eventType: any, payload: any?, eventId: any?): (boolean, string?)
	if not life:IsStarted() or config == nil then
		stats.Refused += 1
		return false, "HarvestService has not been started"
	end
	if not isPlayerLike(player) then
		stats.Refused += 1
		return false, string.format("Emit needs a Player, got %s", typeof(player))
	end
	if type(eventType) == "string" and Enums.Internal[eventType] then
		stats.Refused += 1
		return false, string.format("%q is recorded by Harvest itself and cannot be emitted", eventType)
	end
	if eventId ~= nil and not (type(eventId) == "string" and #eventId >= 1 and #eventId <= 100) then
		stats.Refused += 1
		return false, "eventId must be a string of 1-100 characters"
	end
	local valid, reason = Harvest.ValidateEvent(config, eventType, payload)
	if not valid then
		stats.Refused += 1
		return false, reason
	end
	local extOk, extReason = Extensions.Check(config, eventType, payload)
	if not extOk then
		stats.Refused += 1
		return false, extReason
	end
	-- A receipt is one fact however often it is reported: without an id,
	-- its PurchaseId becomes the id ("receipt:<PurchaseId>", the same id the
	-- glue uses), so a retried ProcessReceipt or a double report counts once.
	if eventId == nil and (eventType == "purchase_verified" or eventType == "ad_reward_granted") then
		eventId = "receipt:" .. string.sub((payload :: any).PurchaseId, 1, 90)
	end
	-- An id-less counter is summed and sent once per tick (or on leave):
	-- a counter bumped many times a second costs one event, not hundreds.
	-- With an id it is a one-off that must dedupe, so it goes straight in.
	if eventType == "counter" and eventId == nil then
		if left[player] then
			stats.Refused += 1
			return false, "player has left"
		end
		local p = payload :: any
		local perPlayer = pendingCounters[player]
		if not perPlayer then
			perPlayer = {}
			pendingCounters[player] = perPlayer
		end
		local total: any
		if config.Counters[p.Key].Big then
			-- No per-event bound: sum in BigCount form.
			total = Harvest.BigCount.add(perPlayer[p.Key] or 0, { p.Amount, p.Exponent or 0 })
		else
			total = (perPlayer[p.Key] or 0) + p.Amount
			if math.abs(total) > Extensions.MAX_PLAIN then
				-- Keep one event within the per-event bound: flush, then start over.
				HarvestService.FlushCounters(player)
				perPlayer = pendingCounters[player] or {}
				pendingCounters[player] = perPlayer
				total = p.Amount
			end
		end
		perPlayer[p.Key] = total
		stats.CountersBatched += 1
		return true, nil
	end
	return HarvestService._Enqueue(player, eventType, payload, eventId)
end

--[[
	Sends the summed id-less counter amounts as one "counter" event per key
	(all players, or one). Runs on every Tick and on leave; exposed for tests
	and for a host that wants a flush before something it cares about.
	A crash loses at most one tick of id-less counter amounts.
]]
function HarvestService.FlushCounters(player: any?): number
	local sent = 0
	local function flushOne(who: any, perPlayer: { [string]: any })
		pendingCounters[who] = nil
		local keys = {}
		for key in pairs(perPlayer) do
			table.insert(keys, key)
		end
		table.sort(keys)
		for _, key in ipairs(keys) do
			local amount = perPlayer[key]
			if type(amount) == "table" then
				-- BigCount form { mantissa, exponent } (Big counters only).
				local m, e = Harvest.BigCount.parts(amount)
				if m ~= nil and m ~= 0 then
					HarvestService._Enqueue(who, "counter", { Key = key, Amount = m, Exponent = e }, nil)
					sent += 1
				end
			elseif amount ~= 0 then
				HarvestService._Enqueue(who, "counter", { Key = key, Amount = amount }, nil)
				sent += 1
			end
		end
	end
	if player ~= nil then
		local perPlayer = pendingCounters[player]
		if perPlayer then
			flushOne(player, perPlayer)
		end
	else
		for who, perPlayer in pairs(pendingCounters) do
			flushOne(who, perPlayer)
		end
	end
	return sent
end

-- Internal path for Harvest's own collectors and glue: no internal-type
-- check. Payload must already be valid.
function HarvestService._Enqueue(player: any, eventType: string, payload: any?, eventId: string?): (boolean, string?)
	-- A player Harvest has not seen yet (emitted before PlayerAdded reached
	-- us) gets a session now, so the envelope carries a SessionId. The load
	-- runs in its own task; Emit does not wait for it.
	local state = states[player] or (if left[player] then nil else ensureState(player))
	local id = eventId or newId()
	local envelope = {
		EventId = id,
		EventType = eventType,
		SchemaVersion = Harvest.EVENT_SCHEMA_VERSION,
		Experience = config.Experience,
		SessionId = if state then state.SessionId else nil,
		ServerTime = clock(),
		ConfigVersion = config.ConfigVersion,
		UserId = player.UserId,
		Payload = if payload then table.clone(payload) else {},
	}
	if #queue >= config.Tunables.QueueLimit then
		table.remove(queue, 1)
		stats.Dropped += 1
		warnThrottled("queue", "event queue is full (%d) - dropping the oldest events", config.Tunables.QueueLimit)
	end
	table.insert(queue, { Player = player, Envelope = envelope })
	scheduleDrain()
	return true, id
end

--[[
	A read-only COPY of the player's summary, or (nil, reason) when it is not
	loaded (yet), the player is not here, or the session is unrecorded.
]]
function HarvestService.GetSummary(player: any): ({ [string]: any }?, string?)
	if not life:IsStarted() then
		return nil, "HarvestService has not been started"
	end
	local state = states[player]
	if not state then
		return nil, "player is not in this server"
	end
	if state.Status == "loading" then
		return nil, "summary is still loading"
	end
	if not state.Summary then
		return nil, "summary is not recorded this session"
	end
	return Schema.DeepCopy(state.Summary), nil
end

--[[
	Numbers that depend on "now" and are not stored: Today,
	DaysSinceLastVisit, ActiveDaysLast7, ActiveDaysLast30, CurrentAsOfToday,
	AverageSessionSeconds, IsPayer, DaysSinceLastPurchase (nil = never),
	HasPlayedWithFriends, FriendPlayShare (0..1 of verified time; nil = none),
	HasWatchedAd, AdCompletionRate (nil = no ad started),
	EstimatedAdRevenue (always "unavailable").
	(nil, reason) like GetSummary.
]]
function HarvestService.GetDerived(player: any): ({ [string]: any }?, string?)
	local summary, reason = HarvestService.GetSummary(player)
	if not summary then
		return nil, reason
	end
	local t = config.Tunables
	local now = clock()
	local derived = Harvest.Days.Derive(summary, now, t.DayOffsetHours, t.StreakGraceDays)
	-- Spend (H3). A payer has a verified receipt or a gamepass; ad-reward
	-- receipts are not payment.
	local spend = summary.Spend
	if type(spend) == "table" then
		derived.IsPayer = (spend.PurchaseCount or 0) > 0 or (spend.GamePassCount or 0) > 0
		derived.DaysSinceLastPurchase = if (spend.LastPurchaseAt or 0) > 0
			then Harvest.Days.DayOf(now, t.DayOffsetHours) - Harvest.Days.DayOf(spend.LastPurchaseAt, t.DayOffsetHours)
			else nil
	end
	-- Social (H4). nil when there is no measured time yet.
	local social = summary.Social
	if type(social) == "table" then
		local known = (social.TimeWithFriendsSec or 0) + (social.TimeAloneSec or 0)
		derived.HasPlayedWithFriends = (social.SessionsWithFriends or 0) > 0 or (social.TimeWithFriendsSec or 0) > 0
		-- Share of VERIFIED time spent with friends; unknown time is left out
		-- of both sides so an outage does not move it.
		derived.FriendPlayShare = if known > 0 then (social.TimeWithFriendsSec or 0) / known else nil
	end
	-- Ads (H5). EstimatedAdRevenue is always "unavailable" (no per-player data).
	for k, v in pairs(AdsCollector.Derive(summary)) do
		derived[k] = v
	end
	return derived, nil
end

--[[
	Deletes a user's stored summary (right-to-erasure path). If the player is
	in this server, their summary is cleared and nothing more is recorded for
	them this session. Returns (true) or (false, reason). Yields.
]]
function HarvestService.Forget(userId: any): (boolean, string?)
	if not life:IsStarted() then
		return false, "HarvestService has not been started"
	end
	if type(userId) ~= "number" or userId % 1 ~= 0 then
		return false, "Forget needs a whole-number UserId"
	end
	for _, state in pairs(states) do
		if state.UserId == userId then
			pendingCounters[state.Player] = nil
			state.Forgotten = true
			if state.Summary then
				table.clear(state.Summary)
			end
			state.Summary = nil
			state.Status = "unrecorded"
		end
	end
	if not adapter then
		return false, "no storage is configured - nothing stored to erase"
	end
	local ok, erased, reason = pcall(adapter.Erase, userId)
	if not ok then
		return false, tostring(erased)
	end
	return erased == true, reason
end

--[[
	Changes which group is checked, at runtime (plan H14). Same values as
	the config Group: { Mode = "GameOwner" } / { Mode = "Id", GroupId = n } /
	{ Mode = "Off" }. Present players are checked again. Returns (true) or
	(false, reason); a bad value changes nothing.
]]
function HarvestService.SetGroup(group: any): (boolean, string?)
	if not life:IsStarted() then
		return false, "HarvestService has not been started"
	end
	local normalised, problem = Harvest.NormaliseGroup(group)
	if problem then
		return false, problem
	end
	currentGroup = normalised
	local now = clock()
	for _, state in pairs(states) do
		if state.CollectorsReady then
			runCollectors("OnGroupChanged", state, now)
		end
	end
	return true, nil
end

-- The group setting in use: { Mode, GroupId? } (a copy).
function HarvestService.GetGroup(): { Mode: string, GroupId: number? }
	return table.clone(currentGroup)
end

--[[
	Whether a group_bonus_claimed was ever recorded for this player:
	true / false, or (nil, reason) when the summary is not available.
	Convenience only - the game must keep its own "already paid" record.
]]
function HarvestService.HasClaimedGroupBonus(player: any): (boolean?, string?)
	local summary, reason = HarvestService.GetSummary(player)
	if not summary then
		return nil, reason
	end
	return summary.Community.GroupBonusClaimedAt > 0, nil
end

-- Adds a custom sink: fn(envelope, player?) for every accepted event.
function HarvestService.RegisterSink(name: string, fn: (any, Player?) -> ()): (boolean, string?)
	if Sinks.ANALYTICS_NAMES[name] or name == "AnalyticsService" or name == "Log" or name == "Memory" then
		return false, string.format("%q is a built-in sink name - enable it in config instead", tostring(name))
	end
	if not customSinks:Register(name, fn) then
		return false, "sink not registered (see warning)"
	end
	return true, nil
end

-- Counters for debugging and dashboards. A copy.
function HarvestService.Stats(): { [string]: any }
	local copy: { [string]: any } = table.clone(stats)
	copy.QueueLength = #queue
	local players, loading, unrecorded = 0, 0, 0
	for _, state in pairs(states) do
		players += 1
		if state.Status == "loading" then
			loading += 1
		elseif state.Status == "unrecorded" then
			unrecorded += 1
		end
	end
	copy.Players = players
	copy.Loading = loading
	copy.UnrecordedPlayers = unrecorded
	copy.Storage = if adapter then adapter.Name else "none"
	copy.MonetizationLinked = glueHandle ~= nil and glueHandle.Attached()
	return copy
end

-- The Memory sink's list (nil unless "Memory" is in config.Sinks).
function HarvestService.MemoryEvents(): { any }?
	return memoryList
end

function HarvestService.IsEnabled(): (boolean, string?)
	return true, nil
end

--=============================================================================
-- START
--=============================================================================

function HarvestService.Start(dependencies: { [string]: any }?): typeof(HarvestService)
	if not life:GuardServer() then
		return HarvestService
	end
	if not life:GuardStart() then
		return HarvestService
	end
	deps = if type(dependencies) == "table" then dependencies else {}

	clock = if type(deps.Clock) == "function" then deps.Clock else os.time
	waitFn = if type(deps.Wait) == "function" then deps.Wait else task.wait
	if type(deps.NewId) == "function" then
		newId = deps.NewId
	end
	playersSource = deps.Players or PlayersService
	local jobId = if type(deps.JobId) == "string" then deps.JobId
		elseif game.JobId ~= "" then game.JobId
		else "studio-" .. HttpService:GenerateGUID(false)

	local raw = if type(deps.Config) == "table" then deps.Config else Harvest.LoadConfig()
	local problems
	config, problems = Harvest.NormaliseConfig(raw)
	if config.ConfigVersion == nil and game.PlaceVersion > 0 then
		config.ConfigVersion = tostring(game.PlaceVersion)
	end
	life:ValidateAndLog(problems)

	-- Storage
	local storageReason: string? = nil
	if type(deps.StorageAdapter) == "table" then
		adapter = deps.StorageAdapter
	elseif deps.Storage == "OwnStore" then
		adapter, storageReason = Storage.OwnStore({
			storeName = config.Tunables.OwnStoreName,
			leaseSeconds = config.Tunables.OwnStoreLeaseSeconds,
			jobId = jobId,
			clock = clock,
			dataStoreService = deps.DataStoreService,
			retry = function(label: string, call: () -> any)
				return Core.Retry.Call(label, call, { log = log })
			end,
		})
	elseif deps.Storage ~= nil and deps.Storage ~= "HostTable" then
		storageReason = string.format("Storage %s is not \"HostTable\" or \"OwnStore\"", tostring(deps.Storage))
	else
		adapter, storageReason = Storage.HostTable(deps)
	end
	if storageReason then
		log:Warn("%s", storageReason)
	end

	-- Sinks
	sinkFns, memoryList = Sinks.Build({
		config = config,
		log = log,
		stats = stats,
		clock = clock,
		players = playersSource,
		analytics = deps.AnalyticsService,
	})

	-- Collectors
	if type(deps.Collectors) == "table" then
		collectors = deps.Collectors
	end
	currentGroup = config.Group
	collectorCtx = {
		config = config,
		harvest = Harvest,
		log = log,
		stats = stats,
		clock = clock,
		-- Per-server state owned by collectors (Social's pair cache).
		shared = {},
		writable = writable,
		-- Every player state in this server (ready or loading).
		roster = function(): { any }
			local list = {}
			for _, state in pairs(states) do
				table.insert(list, state)
			end
			table.sort(list, function(a, b) return a.UserId < b.UserId end)
			return list
		end,
		group = function()
			return currentGroup
		end,
		platform = {
			IsFriendsWith = if type(deps.IsFriendsWith) == "function" then deps.IsFriendsWith
				else function(player: Player, otherUserId: number): boolean
					return player:IsFriendsWithAsync(otherUserId)
				end,
			IsInGroup = if type(deps.IsInGroup) == "function" then deps.IsInGroup
				else function(player: Player, groupId: number): boolean
					return player:IsInGroupAsync(groupId)
				end,
			GameOwner = if type(deps.GameOwner) == "function" then deps.GameOwner
				else function(): (string, number)
					return game.CreatorType.Name, game.CreatorId
				end,
		},
		emit = function(player: any, eventType: string, payload: any?, eventId: string?)
			return HarvestService._Enqueue(player, eventType, payload, eventId)
		end,
	}

	-- Purchases from WiltedMonetization, when it is (or later becomes)
	-- registered. Absent Monetization = nothing happens.
	if deps.MonetizationGlue ~= false then
		local ok, handle = pcall(MonetizationGlue.Attach, {
			core = Core,
			log = log,
			monetization = deps.Monetization,
			emit = function(player: any, eventType: string, payload: any?, eventId: string?)
				return HarvestService._Enqueue(player, eventType, payload, eventId)
			end,
		})
		if ok then
			glueHandle = handle
		else
			log:Warn("MonetizationGlue failed to attach: %s", tostring(handle))
		end
	end

	-- Players
	Core.Players.ForEach(function(player: Player)
		ensureState(player)
	end, { log = log, players = playersSource })
	playersSource.PlayerRemoving:Connect(onLeave)

	-- Periodic save. Tests pass AutoSave = false and call SaveNow themselves.
	if deps.AutoSave ~= false then task.spawn(function()
		while true do
			waitFn(config.Tunables.SaveIntervalSeconds)
			HarvestService.ProcessQueue()
			HarvestService.Tick()
			HarvestService.ProcessQueue()
			HarvestService.SaveNow()
		end
	end) end

	if deps.BindToClose ~= false then
		game:BindToClose(function()
			HarvestService.ProcessQueue()
			local remaining = 0
			for player in pairs(states) do
				remaining += 1
				task.spawn(function()
					onLeave(player)
					remaining -= 1
				end)
			end
			local started = os.clock()
			while remaining > 0 and os.clock() - started < 25 do
				task.wait(0.1)
			end
		end)
	end

	-- Tests run several copies of this module; only the real one registers.
	if deps.RegisterWithCore ~= false then
		Core.Services.Register("Harvest", HarvestService)
	end

	local eventCount = 0
	for _ in pairs(config.Events) do
		eventCount += 1
	end
	life:StartedLine(Harvest.VERSION, "%s, storage %s, sinks %s, %d game event type(s)",
		config.Experience,
		if adapter then adapter.Name else "none",
		if #config.Sinks > 0 then table.concat(config.Sinks, ",") else "none",
		eventCount)
	return HarvestService
end

return HarvestService
