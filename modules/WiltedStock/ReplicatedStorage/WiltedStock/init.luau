--!strict
--[[
	=== WiltedStock (shared core) =============================================

	Generic LIMITED STOCK: a finite global pool, shared by every server, that
	can be claimed exactly once per item. Nothing in here knows about eggs,
	pets or Robux - a sku is just a name with a total.

	    "Golden Dragon - 199 R$ - 650/1000 LEFT"

	---------------------------------------------------------------------------
	DROP-IN CONTRACT
	---------------------------------------------------------------------------

	Same three rules as WiltedMonetization, for the same reason - this subtree
	is meant to be dragged into any project and required in any order, on
	either side of the network, with an empty catalogue and nothing wired:

	  1. SIBLINGS ARE RESOLVED RELATIVELY (script.Parent / FindFirstChild).
	     The only fixed paths are ReplicatedStorage.WiltedCore (the shared
	     plumbing) and ReplicatedStorage.WiltedConfig.Skus (this game's data).
	  2. NOTHING HOST-SPECIFIC IS REQUIRED. What the service needs arrives
	     through StockService.Start(dependencies). Missing dependencies
	     degrade to a refusal, never an error.
	  3. MISSING CONTENT IS A WARNING, NOT A CRASH. An unknown sku returns a
	     reason string the caller can log.
	  4. A MISSING OR TOO-OLD CORE DISABLES, IT DOES NOT CRASH. One warning,
	     an empty catalogue, and every lookup refuses with the reason
	     (decisions 9 and 16). GetCore() tells the service halves why.

	---------------------------------------------------------------------------
	WHY THE DURABLE NUMBER IS `sold`, NOT `remaining`
	---------------------------------------------------------------------------

	This is the single most important decision in the package.

	`sold` only ever counts UP, which makes every failure mode safe:

	  * A missing key reads as nil -> 0 sold -> full stock. For `remaining`,
	    a missing key is indistinguishable from SOLD OUT, so one lost key
	    would either restock a finished drop or permanently close an unstarted
	    one, and the code cannot tell which.
	  * Shards sum. remaining = total - (sold across all shards), so adding a
	    shard tomorrow cannot corrupt yesterday's count.
	  * `total` lives in this catalogue, so raising a drop from 1000 to 1500 is
	    a data edit and the sold count stays true.

	Measured, two real servers contending on one counter (36 attempts, 20
	stock): exactly 20 sold, 0 oversold. The same test with a naive
	read-then-write and a realistic 0.8s grant gap sold 20 while the counter
	still read 10 remaining - 10 phantom items, a 50% oversell. Hence the hard
	rule below.

	---------------------------------------------------------------------------
	THE HARD RULE: ATOMIC OR NOTHING
	---------------------------------------------------------------------------

	Every claim is a single UpdateAsync whose transform refuses by returning
	nil. NEVER read a count, decide, then write it back: between those two
	calls another server has already sold the item, and the write silently
	restores it.

	---------------------------------------------------------------------------
	WHERE THE DATA LIVES
	---------------------------------------------------------------------------

	    DataStore    AUTHORITY. Durable, never expires, survives restarts.
	    MemoryStore  CACHE + idempotency. Fast, shared, EXPIRES.

	MemoryStore cannot hold the authority: a 1-second TTL key was measured
	vanishing after 3 seconds, and max TTL is 45 days, so a quiet drop would
	silently restock itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WiltedStock = {}

WiltedStock.VERSION = "1.2.0"

-- Oldest WiltedCore this package works with. 1.1.0 adds Signal.new(log) and
-- the dot-or-colon Disconnect that StockClient.Changed relies on.
WiltedStock.MIN_CORE_VERSION = "1.1.0"

--=============================================================================
-- THE CORE
--
-- Found by its one fixed path, inside pcall, so a place without it still
-- loads this module. Resolved ONCE per Luau VM: this module is required once,
-- so the "service disabled" warning prints once however many halves ask.
--=============================================================================

local Core: any = nil
local disabledReason: string? = nil

do
	local coreModule = ReplicatedStorage:FindFirstChild("WiltedCore")
	local ok, result = false, nil
	if coreModule and coreModule:IsA("ModuleScript") then
		ok, result = pcall(require, coreModule)
	end
	if not ok or type(result) ~= "table" then
		disabledReason = "WiltedCore is not installed"
		warn("[WiltedStock] WiltedCore not found at ReplicatedStorage.WiltedCore - service disabled")
	elseif not result.Version.Check("WiltedStock", WiltedStock.MIN_CORE_VERSION, result.Log.new("WiltedStock")) then
		disabledReason = string.format("WiltedCore %s is older than the %s WiltedStock needs",
			tostring(result.VERSION), WiltedStock.MIN_CORE_VERSION)
	else
		Core = result
	end
end

--[[
	The core, or nil and the reason the package is disabled.

	For the package's own halves (StockService, StockClient): they refuse
	every call with this reason instead of resolving the core again.
]]
function WiltedStock.GetCore(): (any, string?)
	return Core, disabledReason
end

local log = Core and Core.Log.new("WiltedStock")

-- DataStore key names are capped at 50 characters, and a sharded sku becomes
-- "<sku>:s<n>". 40 leaves room for the suffix and for a per-user key.
WiltedStock.MAX_SKU_LENGTH = 40

--=============================================================================
-- SKU CATALOGUE
--=============================================================================

export type Sku = {
	SkuId: string,
	DisplayName: string,
	Total: number,
	-- Split the durable counter over this many DataStore keys. One hot key
	-- throttles during a flash drop; shards spread the writes. Claims try a
	-- random shard first and fall through the others, so stock is never
	-- stranded in a shard nobody picked.
	Shards: number?,
	-- Most one account may ever claim. nil means no limit.
	PerUserLimit: number?,
	-- Free-form, for a shop tile.
	Description: string?,
}

-- ReplicatedStorage.WiltedConfig.Skus. Absent or broken: one warning and an
-- empty catalogue (see the core's Config module). No core: empty, silently,
-- because the "service disabled" warning above already said why.
local skus: { [string]: Sku } = if Core then Core.Config.Load("Skus", log) else {}

--[[
	One sku by id, or nil with a reason.

	The reason is returned rather than warned so a shop probing for a sku does
	not spam the console; the service warns where a miss is a real bug.
]]
function WiltedStock.FindSku(skuId: any): (Sku?, string?)
	if disabledReason then
		return nil, disabledReason
	end
	if type(skuId) ~= "string" then
		return nil, string.format("sku id must be a string, got %s", typeof(skuId))
	end
	local sku = skus[skuId]
	if not sku then
		return nil, string.format("no sku named %q in the catalogue", skuId)
	end
	return sku, nil
end

-- The live table; treat as read-only.
function WiltedStock.AllSkus(): { [string]: Sku }
	return skus
end

function WiltedStock.ShardsOf(sku: Sku): number
	local shards = tonumber(sku.Shards) or 1
	return math.max(1, math.floor(shards))
end

--[[
	How much of `total` lives in shard `index` (1-based).

	The remainder is spread over the LOW shards rather than dumped on the last
	one, so a total of 10 across 3 shards is 4/3/3 and not 3/3/4. It matters
	because claims try a random shard: an uneven tail would make one shard run
	dry much later than the others and skew the fallback walk.
]]
function WiltedStock.ShardCapacity(sku: Sku, index: number): number
	local shards = WiltedStock.ShardsOf(sku)
	if index < 1 or index > shards then
		return 0
	end
	local total = math.max(0, math.floor(tonumber(sku.Total) or 0))
	local base = math.floor(total / shards)
	local remainder = total % shards
	return base + (index <= remainder and 1 or 0)
end

-- DataStore key for one shard. Single-shard skus use the bare id so a drop
-- that later gains shards keeps its original key as shard 1.
function WiltedStock.ShardKey(skuId: string, index: number, shards: number): string
	if shards <= 1 then
		return skuId
	end
	return string.format("%s:s%d", skuId, index)
end

-- DataStore key holding how many one account has claimed.
function WiltedStock.UserKey(skuId: string, userId: number): string
	return string.format("%s:u%d", skuId, userId)
end

--=============================================================================
-- VALIDATION
--=============================================================================

--[[
	Check the catalogue and return a list of problems.

	Called by StockService.Start, which logs them, so a typo surfaces at boot
	instead of at the moment a player clicks buy on a limited item.
]]
function WiltedStock.Validate(): { string }
	local problems = {}

	for skuId, sku in pairs(skus) do
		local label = string.format("sku %q", tostring(skuId))

		if type(skuId) ~= "string" then
			table.insert(problems, label .. ": catalogue keys must be strings")
			continue
		end
		if type(sku) ~= "table" then
			table.insert(problems, label .. ": entry must be a table")
			continue
		end

		-- The key and the field must agree or a lookup by one finds a sku that
		-- disagrees about its own identity.
		if sku.SkuId ~= skuId then
			table.insert(problems, string.format(
				"%s: SkuId field is %q but the catalogue key is %q - they must match",
				label, tostring(sku.SkuId), tostring(skuId)))
		end

		-- Length is checked because the DataStore key limit is 50 and a
		-- per-user key appends ":u<userId>" - about 12 more characters.
		if #skuId > WiltedStock.MAX_SKU_LENGTH then
			table.insert(problems, string.format(
				"%s: id is %d characters; keep it under %d so the sharded and per-user keys fit DataStore's 50-character limit",
				label, #skuId, WiltedStock.MAX_SKU_LENGTH))
		end

		if type(sku.DisplayName) ~= "string" or sku.DisplayName == "" then
			table.insert(problems, label .. ": DisplayName must be a non-empty string")
		end

		local total = tonumber(sku.Total)
		if not total or total <= 0 or total ~= math.floor(total) then
			table.insert(problems, label .. ": Total must be a positive whole number")
		end

		if sku.Shards ~= nil then
			local shards = tonumber(sku.Shards)
			if not shards or shards < 1 or shards ~= math.floor(shards) then
				table.insert(problems, label .. ": Shards must be a whole number >= 1 or nil")
			elseif total and shards > total then
				-- Harmless but always a mistake: the extra shards hold nothing
				-- and only add fallback walks to every claim.
				table.insert(problems, string.format(
					"%s: Shards (%d) exceeds Total (%d), so some shards hold no stock",
					label, shards, total))
			end
		end

		if sku.PerUserLimit ~= nil then
			local limit = tonumber(sku.PerUserLimit)
			if not limit or limit < 1 or limit ~= math.floor(limit) then
				table.insert(problems, label .. ": PerUserLimit must be a whole number >= 1 or nil")
			end
		end
	end

	return problems
end

--=============================================================================
-- REMOTES
--
-- One, parented to this module so the subtree carries its own networking:
--
--   StockSync   server -> client   { [skuId] = remaining }
--               client -> server   "send me the current counts"
--
-- The client never sends a sku it invented: it asks for everything and the
-- server answers with the catalogue it actually has.
--=============================================================================

WiltedStock.REMOTE_SYNC = "StockSync"

--[[
	The RemoteEvent under this module, or nil.

	SERVER: finds or creates it. CLIENT: finds it and NEVER yields - nil
	means the server has not started yet. A client that must wait for it does
	so in the background with Core.Remote.Wait, as StockClient.Start does
	(decision 15). Creating on the client would make a local-only instance
	the server never sees, so the client never creates.
]]
function WiltedStock.Remote(remoteName: string): RemoteEvent?
	if not Core then
		return nil
	end
	local remote = Core.Remote.Get(script, remoteName)
	return remote
end

return WiltedStock
