--!strict
--[[
	=== ProductInfo =============================================================
	ROBLOX'S half of a product's data: price, and the name/description as they
	appear on the product page. Prefetched ONCE per server and mirrored to every
	client, so no shop ever makes a web call.

	WHY THIS EXISTS AT ALL. MarketplaceService:GetProductInfo is a throttled web
	call and the budget is PER SERVER, not per player. A shop that fetched its
	own prices would cost (players x banners) calls every time it opened - 30
	players x 15 banners is ~450 calls for 15 distinct answers, and the overflow
	does not queue, it FAILS. Prefetching costs one call per product, once.

	WHO OWNS WHAT - the split that matters:

	  ROBLOX owns   PriceInRobux    set on the product page, changes with no
	                                code edit, so it must be ASKED for
	  ROBLOX owns   Name            the product-page name (fallback only)
	  WE own        GrantData       what the product actually pays out; Roblox
	                                has no concept of it
	  WE own        DisplayName     our shop-facing copy
	  WE own        the icon        authored in the UI

	So a banner's price comes from here and its payload comes from the
	catalogue. Neither source can answer for the other.

	STALE DATA IS THE FAILURE MODE TO FEAR. If a price changes in Creator Hub
	and a long-lived server keeps serving the old number, the shop shows one
	price while Roblox charges another - the same class of bug as the
	InstantHatch config disagreeing with the product. So entries carry a
	FetchedAt and are refreshed past REFRESH_AFTER, serving the stale value in
	the meantime rather than blocking the UI on a web call.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Monetization = require(script.Parent)

local Core = Monetization.GetCore()
-- One prefix for the whole package (decision 6): ProductInfo logs as
-- [WiltedMonetization], no longer [productinfo].
local log = Core and Core.Log.new("WiltedMonetization")
local life = Core and Core.Lifecycle.new("WiltedMonetization", log, {
	-- The original wording, kept: hosts may match on it.
	messages = {
		notServer = "ProductInfo.StartServer must be called on the server",
		repeatStart = "ProductInfo.StartServer called more than once - ignoring",
	},
})

local ProductInfo = {}

--=============================================================================
-- TUNING
--=============================================================================

-- How long a cached entry is trusted before a read triggers a background
-- refresh. Long enough that a busy shop costs nothing; short enough that a
-- price edit reaches players within a session.
local REFRESH_AFTER = 15 * 60

-- Prefetch concurrency. MEASURED, not guessed: one GetProductInfo costs
-- ~0.33s of mostly-waiting, so fetching 42 products one at a time takes ~14s
-- before any sleeps. Twelve in flight at once completes the same work in
-- ~1.5s with no sign of throttling, because the calls overlap instead of
-- queueing.
local BATCH_SIZE = 12

-- Breather BETWEEN batches, not between calls. The earlier per-call gap cost
-- 0.2s x 42 = 8.4s of pure sleeping, guarding against a throttle that does
-- not materialise at this size.
local BATCH_GAP = 0.05

-- Retry budget for one product at boot. A failure is usually transient, but
-- retrying forever would hold the catalogue open indefinitely.
local MAX_ATTEMPTS = 2

-- NOT "ProductInfo": the remote is parented to the package root alongside this
-- ModuleScript, and a name collision there makes FindFirstChild return the
-- MODULE. Connecting OnClientEvent to a ModuleScript raises nothing and waits
-- forever, so the symptom is "no prices, no error".
ProductInfo.REMOTE_PRODUCT_INFO = "ProductInfoSync"

--=============================================================================
-- STATE
--=============================================================================

-- ProductId -> { Price, Name, Description, FetchedAt, Ok }
-- Keyed by OUR ProductId, not the asset id: the asset id is ambiguous across
-- purchase kinds (a developer product and a gamepass may share a number) and
-- the catalogue already warns about that case.
local cache: { [string]: any } = {}
local inFlight: { [string]: boolean } = {}
local started = false

-- THE REMOTE.
--
-- Two threads that both "find, miss, create" make two remotes with the same
-- name - and then the server pushes down one RemoteEvent while the client
-- listens on another, with no error anywhere. The prefetch makes that race
-- certain: Push() runs from spawned refresh threads while the boot loop is
-- still going. The core's Remote.Get never yields between the miss and the
-- create and caches the instance, so every caller gets the same one.
local function remote(): RemoteEvent?
	return Monetization.Remote(ProductInfo.REMOTE_PRODUCT_INFO)
end

--=============================================================================
-- FETCH
--=============================================================================

-- A developer product and a gamepass are different InfoTypes, and asking with
-- the wrong one returns an error rather than the wrong answer - so the kind
-- has to come from the catalogue, never assumed.
local function infoTypeFor(product: any): EnumItem?
	local kind = Monetization.PurchaseKindOf(product)
	if kind == Monetization.PURCHASE_KIND_GAME_PASS then
		return Enum.InfoType.GamePass
	elseif kind == Monetization.PURCHASE_KIND_DEVELOPER_PRODUCT then
		return Enum.InfoType.Product
	end
	return nil
end
--[[
	Fetch one product, synchronously. Server only - GetProductInfo yields and
	can throw, so every call is pcall-wrapped and a failure is recorded rather
	than raised: a shop with no price is still a working shop.

	Returns the entry, or nil when the product cannot be fetched at all.
]]
local function fetchOne(productId: string): any
	local product = Monetization.FindProduct(productId)
	if not product then
		return nil
	end

	local assetId = product.AssetId
	if type(assetId) ~= "number" then
		-- A catalogue entry with no Roblox asset yet. Legal and deliberate
		-- (the catalogue is allowed to precede the product), so this is not a
		-- warning - there is simply nothing to ask Roblox about.
		return nil
	end

	local infoType = infoTypeFor(product)
	if not infoType then
		return nil
	end

	local lastErr
	for attempt = 1, MAX_ATTEMPTS do
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(assetId, infoType)
		end)
		if ok and type(info) == "table" then
			local entry = {
				Price = tonumber(info.PriceInRobux),
				Name = info.Name,
				Description = info.Description,
				FetchedAt = os.clock(),
				Ok = true,
			}
			cache[productId] = entry
			return entry
		end
		lastErr = info
		if attempt < MAX_ATTEMPTS then
			task.wait(0.5)
		end
	end

	-- Remember the failure WITH a timestamp, so a dead product does not get
	-- re-fetched on every single read.
	cache[productId] = {
		Price = nil,
		FetchedAt = os.clock(),
		Ok = false,
	}
	log:Warn("could not read %q (asset %d): %s", productId, assetId, tostring(lastErr))
	return cache[productId]
end

-- Refresh in the background. Never blocks a caller, and coalesces so several
-- banners asking at once produce one web call.
local function refreshAsync(productId: string)
	if inFlight[productId] then
		return
	end
	inFlight[productId] = true
	task.spawn(function()
		fetchOne(productId)
		inFlight[productId] = nil
		ProductInfo.Push()
	end)
end

--=============================================================================
-- READ
--=============================================================================

--[[
	Everything known about one product: our catalogue entry merged with
	Roblox's price. Never yields, never throws.

	Price is nil when it has not been fetched, the product has no Roblox asset,
	or the fetch failed. A caller must treat nil as "unknown" and leave its
	authored placeholder alone - NOT render "0 R$".
]]
function ProductInfo.Get(productId: string): any
	local product = Monetization.FindProduct(productId)
	if not product then
		return nil
	end

	local entry = cache[productId]

	-- Stale or missing: serve what we have and refresh behind the caller. On
	-- the client there is nothing to refresh - the server pushes instead.
	if RunService:IsServer() then
		if not entry or (os.clock() - (entry.FetchedAt or 0)) > REFRESH_AFTER then
			refreshAsync(productId)
		end
	end

	return {
		ProductId = productId,
		AssetId = product.AssetId,
		PurchaseKind = Monetization.PurchaseKindOf(product),

		-- Ours. Authoritative for what the thing DOES.
		DisplayName = product.DisplayName,
		Description = product.Description,
		GrantKind = product.GrantKind,
		GrantData = product.GrantData,

		-- Roblox's. Authoritative for what it COSTS.
		Price = entry and entry.Price or nil,
		RobloxName = entry and entry.Name or nil,
		RobloxDescription = entry and entry.Description or nil,
		Fetched = entry ~= nil and entry.Ok == true,
	}
end

-- Just the price, for a caller that only paints a button. nil = unknown.
function ProductInfo.GetPrice(productId: string): number?
	local info = ProductInfo.Get(productId)
	return info and info.Price or nil
end

-- Snapshot of every known price. Used to seed a joining client.
function ProductInfo.Snapshot(): { [string]: any }
	local out = {}
	for productId, entry in pairs(cache) do
		if entry.Ok then
			out[productId] = {
				Price = entry.Price,
				Name = entry.Name,
				Description = entry.Description,
			}
		end
	end
	return out
end
--=============================================================================
-- REPLICATION
--
-- Mirrors the gamepass-ownership pattern already in this package: the server
-- pushes, and a client may ask once on start because its listener can be
-- created after the server's join-time push.
--=============================================================================

function ProductInfo.Push(player: Player?)
	if not RunService:IsServer() then
		return
	end
	local r = remote()
	if not r then
		return
	end
	local snapshot = ProductInfo.Snapshot()
	if player then
		r:FireClient(player, snapshot)
	else
		r:FireAllClients(snapshot)
	end
end

-- Client: accept a pushed snapshot. Merged rather than replaced so a partial
-- push cannot blank prices the client already had.
function ProductInfo._applySnapshot(snapshot: { [string]: any })
	if type(snapshot) ~= "table" then
		return
	end
	for productId, entry in pairs(snapshot) do
		if type(entry) == "table" then
			cache[productId] = {
				Price = tonumber(entry.Price),
				Name = entry.Name,
				Description = entry.Description,
				FetchedAt = os.clock(),
				Ok = true,
			}
		end
	end
	ProductInfo.Changed:Fire()
end

ProductInfo.Changed = Monetization.Signal.new()

--=============================================================================
-- START
--=============================================================================

--[[
	SERVER: prefetch the whole catalogue, then push.

	Runs in the background: a shop that opens mid-prefetch shows placeholders
	and repaints when Changed fires, which is strictly better than delaying
	the boot of everything else behind ~40 web calls.
]]
function ProductInfo.StartServer()
	if not Core then
		local _, reason = Monetization.GetCore()
		warn("[WiltedMonetization] ProductInfo.StartServer: service disabled - " .. tostring(reason))
		return ProductInfo
	end
	if not life:GuardServer() then
		return ProductInfo
	end
	if not life:GuardStart() then
		return ProductInfo
	end
	started = true

	local r = remote()
	if r then
		-- A joining client asks for the snapshot; answering per-request avoids
		-- depending on push-vs-listener ordering.
		r.OnServerEvent:Connect(function(player)
			ProductInfo.Push(player)
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		ProductInfo.Push(player)
	end)

	task.spawn(function()
		local products = Monetization.AllProducts()
		local ids = {}
		for productId in pairs(products) do
			table.insert(ids, productId)
		end
		table.sort(ids)

		local fetched, skipped, failed = 0, 0, 0
		local startedAt = os.clock()

		-- FETCH IN PARALLEL BATCHES, AND PUSH AFTER EACH ONE.
		--
		-- Two separate problems made the shop take ~30s to fill: the calls ran
		-- one at a time, each ~0.33s of mostly waiting; and nothing reached a
		-- client until ALL of them finished, so the first price waited for the
		-- last.
		--
		-- Overlapping the calls fixes the first. Pushing per batch fixes the
		-- second: the shop fills in visibly instead of sitting on placeholders
		-- and then snapping to complete.
		local index = 1
		while index <= #ids do
			local batch = {}
			for _ = 1, BATCH_SIZE do
				if index > #ids then
					break
				end
				table.insert(batch, ids[index])
				index = index + 1
			end

			local remaining = #batch
			for _, productId in ipairs(batch) do
				task.spawn(function()
					local entry = fetchOne(productId)
					if entry == nil then
						skipped = skipped + 1
					elseif entry.Ok then
						fetched = fetched + 1
					else
						failed = failed + 1
					end
					remaining = remaining - 1
				end)
			end

			-- Wait for the batch, with a ceiling so one wedged web call cannot
			-- stall the whole prefetch.
			local deadline = os.clock() + 10
			while remaining > 0 and os.clock() < deadline do
				task.wait(0.03)
			end

			-- Everything fetched so far, to everyone. Cheap: the snapshot is a
			-- small table of numbers and short strings.
			ProductInfo.Push()
			ProductInfo.Changed:Fire()
			task.wait(BATCH_GAP)
		end

		log:Info("prefetched %d price(s) in %.1fs, %d skipped (no asset), %d failed",
			fetched, os.clock() - startedAt, skipped, failed)

		ProductInfo.Push()
		ProductInfo.Changed:Fire()
	end)

	return ProductInfo
end

--[[
	CLIENT: listen for pushes and ask for the current snapshot once.
]]
function ProductInfo.StartClient()
	if not Core then
		local _, reason = Monetization.GetCore()
		warn("[WiltedMonetization] ProductInfo.StartClient: service disabled - " .. tostring(reason))
		return ProductInfo
	end
	if RunService:IsServer() then
		log:Warn("ProductInfo.StartClient must be called on a client")
		return ProductInfo
	end
	if started then
		return ProductInfo
	end
	started = true

	-- WAIT PROPERLY, AND FOREVER. The server creates this remote inside the
	-- host's boot, which legitimately finishes AFTER the player scripts start.
	-- Giving up would mean no price ever arrives and every banner keeps its
	-- placeholder forever. The core's Remote.Wait never gives up and warns at
	-- 10 s, then every 15 s (decision 2; was every 15 s with no 10 s warning).
	task.spawn(function()
		local found = Core.Remote.Wait(script.Parent, ProductInfo.REMOTE_PRODUCT_INFO, log)
		if not found then
			return
		end
		found.OnClientEvent:Connect(function(snapshot)
			ProductInfo._applySnapshot(snapshot)
		end)
		-- Ask, because the server's join-time push may have fired before this
		-- listener existed.
		found:FireServer()
	end)

	return ProductInfo
end

return ProductInfo
