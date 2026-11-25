--!strict
--[[
	=== Monetization (shared core) ============================================

	The piece BOTH sides share: the product catalogue, the signal type, and the
	remote plumbing. Required by MonetizationClient, ProductInfo and by the
	server half in ServerScriptService.WiltedMonetization.

	DROP-IN CONTRACT

	This whole subtree is designed to be dragged into any project and required
	without erroring, in any order, on either side of the network, with an empty
	catalogue and with no host services wired at all. It knows nothing about
	eggs, pets, plots or profiles.

	That is enforced by four rules every module in here follows:

	  1. SIBLINGS ARE RESOLVED RELATIVELY (script.Parent / script:FindFirstChild).
	     The only fixed paths are ReplicatedStorage.WiltedCore (the shared
	     plumbing), ReplicatedStorage.WiltedConfig.Products (this game's data)
	     and, for the server half, ReplicatedStorage.WiltedMonetization (this
	     module).
	  2. NOTHING HOST-SPECIFIC IS REQUIRED. Everything the service needs from the
	     game arrives through MonetizationService.Start(dependencies). Missing
	     dependencies degrade to a refusal, never to an error.
	  3. MISSING CONTENT IS A WARNING, NOT A CRASH. An unknown product id, an
	     unregistered rule, an unregistered grant kind - all return a reason
	     string the caller can log.
	  4. A MISSING OR TOO-OLD CORE DISABLES, IT DOES NOT CRASH. One warning, an
	     empty catalogue, and every lookup refuses with the reason (decisions 9
	     and 16). Nothing can be sold, and a receipt that arrives meanwhile finds
	     no catalogue entry and is left unconsumed for a later retry.

	WHERE THE INSTANCES LIVE

	The RemoteEvents are created as children of THIS module on first use by the
	server, so the subtree carries its own networking and there is nothing to
	parent by hand. A dropped-in copy needs no setup: the server creates them,
	the client waits for them in the background.

	WHERE THE SERVER HALF LIVES

	MonetizationService, PurchaseRules, GrantingManager and StockGlue live in
	ServerScriptService.WiltedMonetization, so clients cannot read them. This
	module, MonetizationClient, MonetizationEnums and ProductInfo stay here
	because both sides need them (ProductInfo has a client half).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Monetization = {}

-- Bumped only when the shared contract between client and server changes in a
-- way a half-updated project would notice. Logged at start so a mismatched
-- drop-in is visible rather than mysterious.
Monetization.VERSION = "1.3.0"

-- Oldest WiltedCore this package works with. 1.1.0 adds Signal.new(log), so a
-- listener error names this package.
Monetization.MIN_CORE_VERSION = "1.1.0"

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
		warn("[WiltedMonetization] WiltedCore not found at ReplicatedStorage.WiltedCore - service disabled")
	elseif not result.Version.Check("WiltedMonetization", Monetization.MIN_CORE_VERSION, result.Log.new("WiltedMonetization")) then
		disabledReason = string.format("WiltedCore %s is older than the %s WiltedMonetization needs",
			tostring(result.VERSION), Monetization.MIN_CORE_VERSION)
	else
		Core = result
	end
end

--[[
	The core, or nil and the reason the package is disabled.

	For the package's own halves (MonetizationClient, ProductInfo, the server
	modules): they refuse with this reason instead of resolving the core again.
]]
function Monetization.GetCore(): (any, string?)
	return Core, disabledReason
end

local log = Core and Core.Log.new("WiltedMonetization")

--=============================================================================
-- SIGNAL
--
-- The core's signal (no Instance, arguments by REFERENCE, each handler in its
-- own task so an erroring listener cannot stop the others). A BindableEvent
-- would deep-copy its arguments, silently turning a product table into a copy
-- and a Player into something that no longer compares equal.
--
-- Monetization.Signal.new() is kept for existing callers. Handler errors are
-- reported as [WiltedMonetization]. Without the core it hands out an inert
-- signal, so a host's Connect still does not error.
--=============================================================================

export type Connection = { Disconnect: (...any) -> () }

local inertSignal = {
	Connect = function()
		return { Disconnect = function() end }
	end,
	Fire = function() end,
}

Monetization.Signal = {
	new = function()
		if Core then
			return Core.Signal.new(log)
		end
		return table.clone(inertSignal)
	end,
}

--=============================================================================
-- PURCHASE KINDS
--
-- The two ways Roblox sells something, which behave completely differently:
--
--   DeveloperProduct  CONSUMED. Bought any number of times; each purchase
--                     produces a receipt that must be granted exactly once.
--   GamePass          OWNED. Bought once, owned forever; there is no receipt,
--                     only "does this player own it", which Roblox answers.
--
-- Their asset ids are SEPARATE NUMBER SPACES on Roblox's side, so every lookup
-- by asset id has to say which kind it means.
--=============================================================================

Monetization.PURCHASE_KIND_DEVELOPER_PRODUCT = "DeveloperProduct"
Monetization.PURCHASE_KIND_GAME_PASS = "GamePass"

local SUPPORTED_PURCHASE_KINDS = {
	[Monetization.PURCHASE_KIND_DEVELOPER_PRODUCT] = true,
	[Monetization.PURCHASE_KIND_GAME_PASS] = true,
}

-- A product's purchase kind, applying the default. Products written before
-- gamepasses existed have no PurchaseKind field and are developer products.
function Monetization.PurchaseKindOf(product: any): string
	if type(product) == "table" and type(product.PurchaseKind) == "string" then
		return product.PurchaseKind
	end
	return Monetization.PURCHASE_KIND_DEVELOPER_PRODUCT
end

function Monetization.IsSupportedPurchaseKind(purchaseKind: any): boolean
	return SUPPORTED_PURCHASE_KINDS[purchaseKind] == true
end

--=============================================================================
-- PRODUCT CATALOGUE
--=============================================================================

export type Product = {
	ProductId: string,
	DisplayName: string,
	AssetId: number?,
	PurchaseKind: string?,
	GrantKind: string,
	GrantData: { [string]: any }?,
	Rules: { string }?,
	Description: string?,
}

-- ReplicatedStorage.WiltedConfig.Products. Absent or broken: one warning and
-- an EMPTY catalogue (see the core's Config module): a project that has not
-- written its products yet must still boot. No core: empty, silently, because
-- the "service disabled" warning above already said why.
local products: { [string]: Product } = if Core then Core.Config.Load("Products", log) else {}

-- PurchaseKind -> AssetId -> ProductId, built once. Receipts and purchase events
-- arrive carrying the ROBLOX id, so this turns them back into one of our
-- products. Keyed by kind first because a developer product and a gamepass may
-- legitimately share a number.
--
-- AN ASSET ID CLAIMED BY TWO PRODUCTS OF THE SAME KIND MAPS TO `false`, not to
-- whichever entry pairs() happened to visit last. Last-wins would make a
-- receipt grant an arbitrary one of the two - possibly the wrong thing, and
-- differently on different servers. `false` makes both refuse to prompt and
-- makes their receipts wait unconsumed until the catalogue is fixed. Validate
-- reports the clash at boot.
local AMBIGUOUS = false
local productIdByAssetId: { [string]: { [number]: string | boolean } } = {}
for productId, product in pairs(products) do
	if type(product) == "table" and type(product.AssetId) == "number" then
		local purchaseKind = Monetization.PurchaseKindOf(product)
		local byAssetId = productIdByAssetId[purchaseKind] or {}
		productIdByAssetId[purchaseKind] = byAssetId
		if byAssetId[product.AssetId] == nil then
			byAssetId[product.AssetId] = productId
		else
			byAssetId[product.AssetId] = AMBIGUOUS
		end
	end
end

-- Is this product's asset id shared with another product of the same kind?
function Monetization.IsAssetIdAmbiguous(product: any): boolean
	if type(product) ~= "table" or type(product.AssetId) ~= "number" then
		return false
	end
	local byAssetId = productIdByAssetId[Monetization.PurchaseKindOf(product)]
	return byAssetId ~= nil and byAssetId[product.AssetId] == AMBIGUOUS
end

--[[
	One product by OUR id, or nil with a reason.

	The reason is returned rather than warned here so a caller that legitimately
	probes for a product (a shop building its grid) does not spam the console;
	the service's own GetProductByProductId warns, because there a miss is a bug.
]]
function Monetization.FindProduct(productId: any): (Product?, string?)
	if disabledReason then
		return nil, disabledReason
	end
	if type(productId) ~= "string" then
		return nil, string.format("product id must be a string, got %s", typeof(productId))
	end
	local product = products[productId]
	if not product then
		return nil, string.format("no product named %q in the catalogue", productId)
	end
	return product, nil
end

--[[
	One product by its ROBLOX id.

	`purchaseKind` defaults to DeveloperProduct, which is what a receipt
	carries. Gamepass lookups must pass PURCHASE_KIND_GAME_PASS explicitly.
]]
function Monetization.FindProductByAssetId(assetId: any, purchaseKind: string?): (Product?, string?)
	if disabledReason then
		return nil, disabledReason
	end
	if type(assetId) ~= "number" then
		return nil, string.format("asset id must be a number, got %s", typeof(assetId))
	end
	local kind = purchaseKind or Monetization.PURCHASE_KIND_DEVELOPER_PRODUCT
	local byAssetId = productIdByAssetId[kind]
	local productId = byAssetId and byAssetId[assetId]
	if productId == AMBIGUOUS then
		return nil, string.format("%s AssetId %d is used by more than one product - fix the catalogue", kind, assetId)
	end
	if not productId then
		return nil, string.format("no %s in the catalogue has AssetId %d", kind, assetId)
	end
	return products[productId :: string], nil
end

-- The whole catalogue, for a shop that wants to build itself from data.
-- Returns the live table; treat it as read-only.
function Monetization.AllProducts(): { [string]: Product }
	return products
end

--[[
	Check the catalogue and return a list of problems, newest-project-first.

	Same idea as the host project's own content validation: a typo should be
	reported at boot in one place rather than failing at the moment a player
	clicks buy. Called by MonetizationService.Start, which logs the result.
]]
function Monetization.Validate(): { string }
	if not Core then
		return {}
	end
	local Problems = Core.Problems
	local problems = Problems.new()
	-- PurchaseKind -> AssetId -> ProductId. Per kind, matching the lookup.
	local seenAssetIds: { [string]: any } = {}

	for productId, product in pairs(products) do
		local label = string.format("product %q", tostring(productId))

		if type(productId) ~= "string" then
			problems:Add(label .. ": catalogue keys must be strings")
		end
		if type(product) ~= "table" then
			problems:Add(label .. ": entry must be a table")
			continue
		end

		-- The key and the ProductId field must agree, or a lookup by one finds a
		-- product that disagrees about its own identity.
		Problems.KeyMatchesField(problems, label, productId, product, "ProductId")

		if not Problems.IsNonEmptyString(product.DisplayName) then
			problems:Add(label .. ": DisplayName must be a non-empty string")
		end

		local purchaseKind = Monetization.PurchaseKindOf(product)
		if product.PurchaseKind ~= nil and not Monetization.IsSupportedPurchaseKind(product.PurchaseKind) then
			problems:Add("%s: PurchaseKind %q is not supported - use %q or %q",
				label, tostring(product.PurchaseKind),
				Monetization.PURCHASE_KIND_DEVELOPER_PRODUCT, Monetization.PURCHASE_KIND_GAME_PASS)
		end

		-- A developer product MUST grant something: the player paid and nothing
		-- else would happen. A gamepass need not - owning it can be the whole
		-- benefit, with game code asking PlayerOwnsGamePass - but if it names a
		-- GrantKind, the name has to be usable.
		if purchaseKind == Monetization.PURCHASE_KIND_GAME_PASS then
			if product.GrantKind ~= nil and not Problems.IsNonEmptyString(product.GrantKind) then
				problems:Add(label .. ": GrantKind must be a non-empty string or nil")
			end
		elseif not Problems.IsNonEmptyString(product.GrantKind) then
			problems:Add(label .. ": GrantKind must be a non-empty string")
		end

		-- A nil AssetId is LEGAL and deliberate: it means "the Roblox product does
		-- not exist yet". Such a product is listed but cannot be prompted, which
		-- is exactly what a developer wants while authoring the catalogue ahead of
		-- creating the assets.
		if product.AssetId ~= nil then
			if not Problems.IsPositiveNumber(product.AssetId) then
				problems:Add(label .. ": AssetId must be a positive number or nil")
			else
				seenAssetIds[purchaseKind] = seenAssetIds[purchaseKind] or Problems.Unique()
				local owner = seenAssetIds[purchaseKind]:Claim(product.AssetId, productId)
				if owner then
					problems:Add("%s: %s AssetId %d is already used by %q - a purchase could not tell them apart",
						label, purchaseKind, product.AssetId, owner)
				end
			end
		end

		if product.Rules ~= nil then
			if type(product.Rules) ~= "table" then
				problems:Add(label .. ": Rules must be a table of rule NAMES")
			else
				for index, ruleName in ipairs(product.Rules) do
					if type(ruleName) ~= "string" then
						problems:Add(
							"%s: Rules[%d] must be a rule NAME (string), not a %s - rule functions live in PurchaseRules",
							label, index, typeof(ruleName))
					end
				end
			end
		end

		if product.GrantData ~= nil and type(product.GrantData) ~= "table" then
			problems:Add(label .. ": GrantData must be a table or nil")
		end
	end

	return problems:List()
end

--=============================================================================
-- REMOTES
--
-- Three, all parented to this module so the subtree is self-contained:
--
--   PromptPurchase      client -> server   "I want to buy this ProductId"
--   PurchaseResult      server -> client   outcome, so the UI can react
--   GamePassOwnership   both ways          client: "send me my passes"
--                                          server: the owned ProductId list
--
-- THE CLIENT NEVER SENDS AN ASSET ID. It names one of OUR product ids and the
-- server resolves the asset itself, so a client cannot prompt for a product
-- that is not in the catalogue or skip the rule check by naming an arbitrary
-- Roblox id.
--=============================================================================

Monetization.REMOTE_PROMPT_PURCHASE = "PromptPurchase"
Monetization.REMOTE_PURCHASE_RESULT = "PurchaseResult"
Monetization.REMOTE_GAME_PASS_OWNERSHIP = "GamePassOwnership"

--[[
	The RemoteEvent with this name under this module, or nil.

	SERVER: finds or creates it (the core's Remote.Get, which caches the
	instance, so two threads asking at once can never make two). CLIENT: finds
	it and NEVER yields - nil means the server has not started yet. Creating on
	the client would make a local-only instance that the server never sees, so
	the client never creates. A client that must wait does so in the
	background with Core.Remote.Wait, as MonetizationClient and ProductInfo do
	(decision 2).
]]
function Monetization.Remote(remoteName: string): RemoteEvent?
	if not Core then
		return nil
	end
	local remote = Core.Remote.Get(script, remoteName)
	return remote
end

return Monetization
