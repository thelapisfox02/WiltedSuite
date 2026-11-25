--!strict
--[[
	=== StockService ==========================================================

	The server half of WiltedStock. Claims items from a finite global pool.
	Lives in ServerScriptService.WiltedStock; finds its shared half at the
	fixed path ReplicatedStorage.WiltedStock.

	    local ok, result = StockService.Claim("GoldenDragon", player.UserId, {
	        idempotencyKey = receipt.PurchaseId,
	    })
	    -- ok     -> result.remaining, result.sold, result.replayed
	    -- not ok -> result is a player-facing reason string

	Every public function is PascalCase. The original lowercase names
	(claim, soldOf, ...) still work and forward to them.

	Another Wilted service finds this one through the core's directory:
	    Core.Services.Get("Stock")   -- registered at the end of Start

	If WiltedCore or ReplicatedStorage.WiltedStock is missing, every function
	refuses with the reason (false, reason) and Start warns and returns.

	---------------------------------------------------------------------------
	THE CLAIM SEQUENCE, AND WHY IT IS IN THIS ORDER
	---------------------------------------------------------------------------

	  1. IDEMPOTENCY  Has this exact key already claimed? Return the old answer.
	  2. PER-USER CAP Atomically take one of this account's allowance.
	  3. STOCK        Atomically take one item from a shard.
	  4. ROLLBACK     If 3 failed, give the allowance from 2 back.

	The cap is claimed BEFORE the stock on purpose. If the order were reversed,
	a buyer who is over their limit would have an item removed from the global
	pool and then be refused - the drop would show 999 left having sold nothing,
	and no code could tell that item was never really sold. Refusing before
	touching the shared pool keeps the public number honest, and the rollback in
	step 4 is only reached on a genuine sell-out.

	---------------------------------------------------------------------------
	WHY IDEMPOTENCY IS NOT OPTIONAL FOR PURCHASES
	---------------------------------------------------------------------------

	Roblox re-delivers a developer product receipt until the server answers
	PurchaseGranted. If a server claims an item and then dies before
	acknowledging, the retry would claim a SECOND item for the same sale. The
	receipt ledger in the host profile cannot catch it, because that write died
	with the server too.

	So a caller passes the purchase id as `idempotencyKey` and a repeat returns
	the first outcome with `replayed = true`, consuming nothing. The record
	lives in MemoryStore: receipts retry within minutes, so a short shared TTL
	is exactly the right lifetime and costs no durable storage.

	---------------------------------------------------------------------------
	THROTTLING FAILS CLOSED
	---------------------------------------------------------------------------

	Measured: 400 simultaneous claims produced 398 RequestThrottled errors and
	ZERO oversells. A throttled claim is a refusal, never a grant, so the worst
	case is "could not buy" - recoverable with a retry - rather than an item
	sold twice. Every call is wrapped in bounded exponential backoff to turn
	that into a short delay.
]]

local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StockService = {}

--=============================================================================
-- THE SHARED HALF AND THE CORE
--
-- Neither may be missing at require time without a clear reason: a missing
-- piece disables the service (every call refuses), it never throws.
--=============================================================================

local WiltedStock: any = nil
local Core: any = nil
local disabledReason: string? = nil

do
	local rootModule = ReplicatedStorage:FindFirstChild("WiltedStock")
	if not rootModule or not rootModule:IsA("ModuleScript") then
		disabledReason = "WiltedStock is not installed at ReplicatedStorage.WiltedStock"
		warn("[WiltedStock] " .. disabledReason .. " - service disabled")
	else
		local ok, result = pcall(require, rootModule)
		if not ok or type(result) ~= "table" then
			disabledReason = "WiltedStock failed to load"
			warn("[WiltedStock] ReplicatedStorage.WiltedStock failed to load - service disabled: " .. tostring(result))
		else
			WiltedStock = result
			-- The shared half has already warned once if the core is missing
			-- or too old; this only takes over its reason.
			Core, disabledReason = WiltedStock.GetCore()
		end
	end
end

local log = Core and Core.Log.new("WiltedStock")
local life = Core and Core.Lifecycle.new("WiltedStock", log, {
	-- The original wording, kept: hosts may match on it.
	messages = { repeatStart = "Start called more than once - ignoring" },
})

--=============================================================================
-- TUNABLES
--=============================================================================

-- Retries for one throttled call, and the first backoff gap. Doubles each
-- attempt with jitter, so a burst of servers does not retry in lockstep.
StockService.MAX_ATTEMPTS = 4
StockService.BACKOFF_SECONDS = 0.35

-- How long a cached count and an idempotency record live in MemoryStore.
-- The cache is short because it is only a display convenience. The
-- idempotency record has to outlast every redelivery of a receipt, which can
-- come days later when the buyer next joins, so it uses MemoryStore's maximum
-- of 45 days (decision 20; was 900 s, which let a receipt retried after 15
-- minutes claim a second unit).
StockService.CACHE_TTL = 30
StockService.IDEMPOTENCY_TTL = 45 * 24 * 60 * 60

-- Name of the DataStore holding the durable counters. Exposed so a host can
-- namespace it per environment (a test place pointing at live stock would
-- burn real items).
StockService.STORE_NAME = "WiltedStock_v1"
StockService.MEMORY_NAME = "WiltedStock_v1"

--=============================================================================
-- INTERNALS
--=============================================================================

local dependencies: { [string]: any } = {}

-- Injectable randomness (plan 9.5). Production never touches these:
--   randomInt(1, shards)  the shard a claim tries first
--   randomUnit()          the jitter on a retry wait
-- _SetRandomForTests(int?, unit?) swaps them; nil restores math.random.
local randomInt: (number, number) -> number = math.random
local randomUnit: () -> number = math.random

function StockService._SetRandomForTests(int: ((number, number) -> number)?, unit: (() -> number)?)
	randomInt = int or math.random
	randomUnit = unit or math.random
end

local function store(): DataStore
	return DataStoreService:GetDataStore(StockService.STORE_NAME)
end

local function memory(): MemoryStoreHashMap
	return MemoryStoreService:GetHashMap(StockService.MEMORY_NAME)
end

--[[
	Run a cloud call with bounded exponential backoff (the core's Retry).

	Returns ok, value. A throttle is retried; anything else fails immediately,
	because retrying a malformed request just burns quota. The tunables are
	read on every call, so a host changing them takes effect at once.
]]
local function withRetry(label: string, call: () -> any): (boolean, any)
	return Core.Retry.Call(label, call, {
		attempts = StockService.MAX_ATTEMPTS,
		backoff = StockService.BACKOFF_SECONDS,
		log = log,
		random = randomUnit,
	})
end

--=============================================================================
-- READING
--=============================================================================

--[[
	How many of this sku have been sold, summed across shards.

	Reads the DataStore - the authority - so this is the honest number. Costs
	one read per shard, which is why the display path uses the cache instead.
]]
function StockService.SoldOf(skuId: string): (boolean, number | string)
	if disabledReason then
		return false, disabledReason
	end
	local sku, reason = WiltedStock.FindSku(skuId)
	if not sku then
		return false, reason :: string
	end

	local shards = WiltedStock.ShardsOf(sku)
	local total = 0
	local dataStore = store()

	for index = 1, shards do
		local key = WiltedStock.ShardKey(skuId, index, shards)
		local ok, value = withRetry("soldOf " .. key, function()
			return dataStore:GetAsync(key)
		end)
		if not ok then
			return false, "stock is temporarily unavailable"
		end
		-- A missing key is zero sold, which is the whole reason the durable
		-- number counts up rather than down.
		total += (type(value) == "number" and value or 0)
	end

	return true, total
end

-- Items left, or a reason. Never negative.
function StockService.RemainingOf(skuId: string): (boolean, number | string)
	if disabledReason then
		return false, disabledReason
	end
	local sku, reason = WiltedStock.FindSku(skuId)
	if not sku then
		return false, reason :: string
	end
	local ok, sold = StockService.SoldOf(skuId)
	if not ok then
		return false, sold :: string
	end
	local total = math.floor(tonumber(sku.Total) or 0)
	return true, math.max(0, total - (sold :: number))
end

-- How many this account has claimed.
function StockService.ClaimedBy(skuId: string, userId: number): (boolean, number | string)
	if disabledReason then
		return false, disabledReason
	end
	local ok, value = withRetry("claimedBy", function()
		return store():GetAsync(WiltedStock.UserKey(skuId, userId))
	end)
	if not ok then
		return false, "stock is temporarily unavailable"
	end
	return true, (type(value) == "number" and value or 0)
end

--=============================================================================
-- THE CACHE
--
-- A display-only mirror of `sold`, in MemoryStore so every server shares one
-- copy. Deliberately never trusted for a decision: it expires, and an expired
-- key is indistinguishable from "nothing sold yet".
--=============================================================================

local function writeCache(skuId: string, sold: number)
	pcall(function()
		memory():SetAsync("c:" .. skuId, sold, StockService.CACHE_TTL)
	end)
end

--[[
	Remaining for display. Uses the shared cache, falling back to the
	authority on a miss and re-filling the cache.

	`fresh = true` skips the cache, for the moment right after a claim where
	the buyer must see their own purchase reflected.
]]
function StockService.DisplayRemaining(skuId: string, fresh: boolean?): (boolean, number | string)
	if disabledReason then
		return false, disabledReason
	end
	local sku, reason = WiltedStock.FindSku(skuId)
	if not sku then
		return false, reason :: string
	end
	local total = math.floor(tonumber(sku.Total) or 0)

	if not fresh then
		local ok, cached = pcall(function()
			return memory():GetAsync("c:" .. skuId)
		end)
		if ok and type(cached) == "number" then
			return true, math.max(0, total - cached)
		end
	end

	local ok, sold = StockService.SoldOf(skuId)
	if not ok then
		return false, sold :: string
	end
	writeCache(skuId, sold :: number)
	return true, math.max(0, total - (sold :: number))
end

--=============================================================================
-- CLAIMING
--=============================================================================

export type ClaimResult = {
	remaining: number,
	sold: number,
	shard: number,
	replayed: boolean,
}

--[[
	Take one unit of this account's per-user allowance, atomically.

	Returns ok, newCount. The transform refuses by returning nil when the cap
	is already met, which is what makes two simultaneous buys by one account
	on two servers impossible to slip past.
]]
local function claimUserSlot(skuId: string, userId: number, limit: number): (boolean, string?)
	local key = WiltedStock.UserKey(skuId, userId)
	local ok, result = withRetry("claimUserSlot " .. key, function()
		return store():UpdateAsync(key, function(current)
			local claimed = type(current) == "number" and current or 0
			if claimed >= limit then
				return nil
			end
			return claimed + 1
		end)
	end)

	if not ok then
		return false, "stock is temporarily unavailable, try again"
	end
	if result == nil then
		return false, limit == 1
			and "you have already claimed this"
			or string.format("you have claimed your limit of %d", limit)
	end
	return true, nil
end

-- Give a user slot back, after the stock claim failed.
local function releaseUserSlot(skuId: string, userId: number)
	local key = WiltedStock.UserKey(skuId, userId)
	withRetry("releaseUserSlot " .. key, function()
		return store():UpdateAsync(key, function(current)
			local claimed = type(current) == "number" and current or 0
			-- Clamped at zero: a double release must never hand out a negative
			-- allowance, which would read as "infinite remaining".
			return math.max(0, claimed - 1)
		end)
	end)
end

--[[
	Take one item from a specific shard, atomically.

	Returns ok, soldAfter. nil from the transform means this shard is empty -
	not that the drop is over, because another shard may still hold stock.
]]
local function claimFromShard(skuId: string, index: number, shards: number, capacity: number): (boolean, number?)
	local key = WiltedStock.ShardKey(skuId, index, shards)
	local ok, result = withRetry("claimFromShard " .. key, function()
		return store():UpdateAsync(key, function(current)
			local sold = type(current) == "number" and current or 0
			if sold >= capacity then
				return nil
			end
			return sold + 1
		end)
	end)

	if not ok or result == nil then
		return false, nil
	end
	return true, result :: number
end

--[[
	THE IDEMPOTENCY RECORD HAS TWO STATES (decision 23).

	    { state = "pending" }   a claim with this key has STARTED
	    { state = "done" }      a claim with this key SUCCEEDED

	Only "done" is a replay. Before, the key was recorded before the claim was
	known to work, so a claim that was then refused (sold out, per-account
	cap, store busy) left the key behind - and every retry with that key was
	answered "replayed, success" while taking nothing. A seller trusting that
	answer would hand out an item that was never in stock.

	Now a retry that finds "pending" runs the claim again. The accepted worst
	case: a crash (or a second server with the same receipt) between the shard
	write and the "done" write makes one key take 2 units. The pool still can
	never be oversold, and nothing is ever reported claimed that was not.

	A record without a state field was written before this change, when a
	record meant "claimed"; it is read as "done", exactly as before.
]]
local function isDone(record: any): boolean
	return type(record) == "table" and (record.state == "done" or record.state == nil)
end

--[[
	Start a claim under this key. Returns "new" | "replay" | "unavailable".

	"new" covers both a first use and a retry of a claim that never finished.
	The record is written with UpdateAsync, which refuses on a "done" record,
	so two servers replaying a completed receipt at once both see "replay".
]]
local function claimIdempotencyKey(key: string): string
	local sawDone = false
	local ok = withRetry("idempotency " .. key, function()
		sawDone = false
		return memory():UpdateAsync("i:" .. key, function(current)
			if current ~= nil and isDone(current) then
				-- Already claimed; refusing leaves the original untouched.
				sawDone = true
				return nil
			end
			return { state = "pending", t = os.time() }
		end, StockService.IDEMPOTENCY_TTL)
	end)

	if not ok then
		return "unavailable"
	end
	if sawDone then
		return "replay"
	end
	return "new"
end

-- The claim under this key succeeded. If this write fails the record stays
-- "pending", so a retry claims again: the accepted worst case, logged.
local function markIdempotencyKeyDone(key: string)
	local ok = withRetry("idempotency done " .. key, function()
		return memory():SetAsync("i:" .. key, { state = "done", t = os.time() }, StockService.IDEMPOTENCY_TTL)
	end)
	if not ok then
		log:Warn("could not mark claim %q done - a retry with this key would claim again", key)
	end
end

--[[
	Has a claim with this key SUCCEEDED? Read-only: one MemoryStore read, never
	a write (decision 20).

	Returns ok, recorded | reason. For a seller whose payout failed AFTER a
	successful claim: on the retry, "recorded" means this purchase already owns
	its unit, so it must not be refused as sold out.
]]
function StockService.IsClaimRecorded(key: string): (boolean, boolean | string)
	if disabledReason then
		return false, disabledReason
	end
	if type(key) ~= "string" or key == "" then
		return false, "an idempotency key must be a non-empty string"
	end
	local ok, record = withRetry("isClaimRecorded " .. key, function()
		return memory():GetAsync("i:" .. key)
	end)
	if not ok then
		return false, "stock is temporarily unavailable"
	end
	return true, record ~= nil and isDone(record)
end

--[[
	Claim one item.

	options.idempotencyKey  pass a receipt/purchase id to make retries safe
	options.ignoreUserLimit set for an admin grant that should bypass the cap

	Returns ok, ClaimResult | reason. The reason is player-facing.
]]
function StockService.Claim(skuId: string, userId: number, options: { [string]: any }?): (boolean, ClaimResult | string)
	if disabledReason then
		return false, disabledReason
	end
	local sku, reason = WiltedStock.FindSku(skuId)
	if not sku then
		log:Warn("claim: " .. tostring(reason))
		return false, "that item does not exist"
	end
	if type(userId) ~= "number" then
		return false, "a claim needs a user id"
	end

	local settings = options or {}

	-- 1. IDEMPOTENCY, before anything is consumed.
	local idempotencyKey = settings.idempotencyKey
	local keyed = type(idempotencyKey) == "string" and idempotencyKey ~= ""
	if keyed then
		local state = claimIdempotencyKey(idempotencyKey)
		if state == "replay" then
			-- Already granted for this receipt. Report success so the caller
			-- acknowledges it, but consume nothing.
			local okRemaining, remaining = StockService.DisplayRemaining(skuId, true)
			return true, {
				remaining = okRemaining and (remaining :: number) or 0,
				sold = 0,
				shard = 0,
				replayed = true,
			}
		end
		if state == "unavailable" then
			-- Cannot prove this is not a replay, so refuse. A retry is safe;
			-- a double grant is not.
			return false, "stock is busy, try again in a moment"
		end
	end

	-- 2. PER-USER CAP, before the shared pool is touched. See the header.
	local limit = tonumber(sku.PerUserLimit)
	local tookUserSlot = false
	if limit and not settings.ignoreUserLimit then
		local ok, why = claimUserSlot(skuId, userId, math.floor(limit))
		if not ok then
			return false, why :: string
		end
		tookUserSlot = true
	end

	-- 3. STOCK. Start at a random shard so concurrent servers spread their
	-- writes, then walk the rest: stock must never be stranded in a shard
	-- that nobody happened to pick.
	local shards = WiltedStock.ShardsOf(sku)
	local start = randomInt(1, shards)
	for offset = 0, shards - 1 do
		local index = ((start - 1 + offset) % shards) + 1
		local capacity = WiltedStock.ShardCapacity(sku, index)
		if capacity > 0 then
			local ok, soldAfter = claimFromShard(skuId, index, shards, capacity)
			if ok then
				if keyed then
					markIdempotencyKeyDone(idempotencyKey)
				end
				local okRemaining, remaining = StockService.DisplayRemaining(skuId, true)
				StockService.onChanged(skuId, okRemaining and (remaining :: number) or nil)
				return true, {
					remaining = okRemaining and (remaining :: number) or 0,
					sold = soldAfter :: number,
					shard = index,
					replayed = false,
				}
			end
		end
	end

	-- 4. ROLLBACK. Every shard is empty, so the allowance taken in step 2 was
	-- never used and must go back - otherwise a sold-out drop would silently
	-- eat the buyer's future entitlement.
	if tookUserSlot then
		releaseUserSlot(skuId, userId)
	end

	return false, "sold out"
end

--[[
	Could this account claim one now? Read-only: never writes, never takes a
	unit (decision 21).

	options.fresh = false   the pool from the shared display cache (cheap; for
	                        greying out a button before a prompt)
	options.fresh = true    the pool from the DataStore authority (for a
	                        decision that must be right)

	The per-account count has no cache and is always read from the DataStore.

	Returns true, or false, reason, code. The reason is player-facing. The code
	lets a caller tell "no" from "could not ask":
	    "disabled" | "unknown" | "baduser" | "unavailable" | "soldout" | "limit"
	Only the atomic Claim is the real gate: a true here can still lose the race
	for the last unit.
]]
function StockService.CheckClaimable(skuId: string, userId: number, options: { [string]: any }?): (boolean, string?, string?)
	if disabledReason then
		return false, disabledReason, "disabled"
	end
	local sku = WiltedStock.FindSku(skuId)
	if not sku then
		return false, "that item does not exist", "unknown"
	end
	if type(userId) ~= "number" then
		return false, "a claim needs a user id", "baduser"
	end

	local fresh = options ~= nil and options.fresh == true
	local okRemaining, remaining
	if fresh then
		okRemaining, remaining = StockService.RemainingOf(skuId)
	else
		okRemaining, remaining = StockService.DisplayRemaining(skuId)
	end
	if not okRemaining then
		return false, "stock is temporarily unavailable", "unavailable"
	end
	if (remaining :: number) <= 0 then
		return false, "sold out", "soldout"
	end

	local limit = tonumber(sku.PerUserLimit)
	if limit then
		limit = math.floor(limit)
		local okClaimed, claimed = StockService.ClaimedBy(skuId, userId)
		if not okClaimed then
			return false, "stock is temporarily unavailable", "unavailable"
		end
		if (claimed :: number) >= limit then
			return false, limit == 1
				and "you have already claimed this"
				or string.format("you have claimed your limit of %d", limit), "limit"
		end
	end
	return true, nil, nil
end

--[[
	Hand an item back to the pool.

	For a refund or a failed grant AFTER a successful claim. Not part of the
	normal path: a claim that fails never consumed anything.
]]
function StockService.Release(skuId: string, userId: number?, options: { [string]: any }?): (boolean, string?)
	if disabledReason then
		return false, disabledReason
	end
	local sku, reason = WiltedStock.FindSku(skuId)
	if not sku then
		return false, reason
	end

	local settings = options or {}
	local shards = WiltedStock.ShardsOf(sku)
	-- Return it to the shard it came from when known; otherwise to whichever
	-- shard still shows a sale, so the total stays correct.
	local preferred = tonumber(settings.shard)

	local order = {}
	if preferred and preferred >= 1 and preferred <= shards then
		table.insert(order, preferred)
	end
	for index = 1, shards do
		if index ~= preferred then
			table.insert(order, index)
		end
	end

	for _, index in ipairs(order) do
		local key = WiltedStock.ShardKey(skuId, index, shards)
		local ok, result = withRetry("release " .. key, function()
			return store():UpdateAsync(key, function(current)
				local sold = type(current) == "number" and current or 0
				if sold <= 0 then
					-- Nothing to give back here; try the next shard rather
					-- than writing a negative sold count.
					return nil
				end
				return sold - 1
			end)
		end)
		if ok and result ~= nil then
			if userId and tonumber(sku.PerUserLimit) and not settings.ignoreUserLimit then
				releaseUserSlot(skuId, userId)
			end
			local okRemaining, remaining = StockService.DisplayRemaining(skuId, true)
			StockService.onChanged(skuId, okRemaining and (remaining :: number) or nil)
			return true, nil
		end
	end

	return false, "nothing to release"
end

-- Hook: the host pushes the new count to clients. The service does not know
-- what a UI is. Set it with SetOnChanged(fn); assigning StockService.onChanged
-- directly still works, because it is read at the moment of every change.
local function noChange(_skuId: string, _remaining: number?) end
StockService.onChanged = noChange

--[[
	Set the change hook. nil restores the silent default. Anything else that
	is not a function is refused (warning, false) and changes nothing.
]]
function StockService.SetOnChanged(fn: ((string, number?) -> ())?): boolean
	if fn == nil then
		StockService.onChanged = noChange
		return true
	end
	if type(fn) ~= "function" then
		if log then
			log:Warn("SetOnChanged expects a function or nil, got %s", typeof(fn))
		end
		return false
	end
	StockService.onChanged = fn
	return true
end

--=============================================================================
-- ADMIN
--=============================================================================

--[[
	Reset a sku's counters to zero sold, restoring the full drop.

	Destructive and deliberately explicit: it does NOT clear per-user records,
	because someone who already claimed should not silently get another during
	a test. Pass clearUsers to wipe a specific account's record too.
]]
function StockService.Reset(skuId: string, clearUserIds: { number }?): (boolean, string?)
	if disabledReason then
		return false, disabledReason
	end
	local sku, reason = WiltedStock.FindSku(skuId)
	if not sku then
		return false, reason
	end

	local shards = WiltedStock.ShardsOf(sku)
	local dataStore = store()
	for index = 1, shards do
		local key = WiltedStock.ShardKey(skuId, index, shards)
		withRetry("reset " .. key, function()
			return dataStore:RemoveAsync(key)
		end)
	end

	for _, userId in ipairs(clearUserIds or {}) do
		withRetry("reset user", function()
			return dataStore:RemoveAsync(WiltedStock.UserKey(skuId, userId))
		end)
	end

	pcall(function()
		memory():RemoveAsync("c:" .. skuId)
	end)
	StockService.onChanged(skuId, math.floor(tonumber(sku.Total) or 0))
	return true, nil
end

-- Every sku with its current remaining count, for a shop or an admin command.
function StockService.Snapshot(): { [string]: number }
	local out = {}
	if disabledReason then
		return out
	end
	for skuId in pairs(WiltedStock.AllSkus()) do
		local ok, remaining = StockService.DisplayRemaining(skuId)
		out[skuId] = ok and (remaining :: number) or -1
	end
	return out
end

function StockService.Start(suppliedDependencies: { [string]: any }?)
	if disabledReason then
		warn("[WiltedStock] Start: service disabled - " .. disabledReason)
		return StockService
	end
	if not life:GuardServer() then
		return StockService
	end
	if not life:GuardStart() then
		return StockService
	end
	dependencies = suppliedDependencies or {}

	life:ValidateAndLog(WiltedStock.Validate())

	local remote = WiltedStock.Remote(WiltedStock.REMOTE_SYNC)
	if remote then
		remote.OnServerEvent:Connect(function(player)
			-- The client asks for everything; the server answers with the
			-- catalogue it has, so a client cannot probe invented skus.
			remote:FireClient(player, StockService.Snapshot())
		end)
	end

	local count = 0
	for _ in pairs(WiltedStock.AllSkus()) do
		count += 1
	end
	life:StartedLine(WiltedStock.VERSION, "%d sku(s)", count)

	-- Last, so a service that finds Stock in the directory finds it started.
	Core.Services.Register("Stock", StockService)
	return StockService
end

--=============================================================================
-- ORIGINAL LOWERCASE NAMES (decision 3), kept indefinitely. Each looks up its
-- PascalCase twin at call time, so the two can never disagree.
--=============================================================================

function StockService.soldOf(...)
	return StockService.SoldOf(...)
end
function StockService.remainingOf(...)
	return StockService.RemainingOf(...)
end
function StockService.claimedBy(...)
	return StockService.ClaimedBy(...)
end
function StockService.displayRemaining(...)
	return StockService.DisplayRemaining(...)
end
function StockService.claim(...)
	return StockService.Claim(...)
end
function StockService.release(...)
	return StockService.Release(...)
end
function StockService.reset(...)
	return StockService.Reset(...)
end
function StockService.snapshot(...)
	return StockService.Snapshot(...)
end

return StockService
