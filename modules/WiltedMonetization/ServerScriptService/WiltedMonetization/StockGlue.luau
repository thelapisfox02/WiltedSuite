--!strict
--[[
	=== StockGlue ==============================================================
	The optional bridge from Monetization to WiltedStock: what lets a product
	such as FounderPet be sold out of a finite global pool.

	    GrantKind = "LimitedStock"            the grant (claims, then pays out)
	    Rules     = { "LimitedStockAvailable" } the rule (stops a prompt when none
	                                           can be claimed)
	    GrantData = { Sku = "<SkuId>", Rewards = { ... } }

	HOW IT ATTACHES (decisions 10 and 24)

	MonetizationService.Start calls StockGlue.Attach once, inside pcall. Attach
	only SUBSCRIBES: the rule and the grant are registered when, and only if,
	Stock appears in the core's service directory. With Stock absent they are
	never registered, so a product naming them refuses ("unknown rule") and
	its receipt is never consumed - it fails closed. Monetization keeps no hard
	dependency on Stock.

	A name the host has already registered by hand is left alone: one info
	line, and that name is skipped (decision 19).

	THE RULE: LimitedStockAvailable (decisions 18, 20, 21, 22)

	  Before the prompt  StockService.CheckClaimable with the cached pool. A
	                     failed read refuses: no money has moved yet.
	  At receipt         (context.ReceiptInfo present) first: has THIS receipt's
	                     claim already succeeded? Then it passes - the purchase
	                     owns its unit, and only the payout is being retried.
	                     Otherwise CheckClaimable against the authority. A
	                     failed read PASSES here: refusing would consume a paid
	                     receipt as REFUNDABLE, while the atomic claim in the
	                     grant is still the real gate.

	THE GRANT: LimitedStock (decision 17)

	  1. Claim one unit for the recipient, idempotency key = the receipt's
	     PurchaseId, so a redelivered receipt cannot take two.
	  2. Hand the same product to the host's "Pack" grant kind, which pays out
	     GrantData.Rewards. Pack missing or failing = the grant fails, the
	     receipt is kept and retried; the retried claim is a replay and takes
	     nothing.

	Nothing is granted without a successful claim.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The shared root, by its documented fixed path (layout 4b), inside pcall so a
-- missing package refuses instead of erroring.
local Core: any = nil
do
	local rootModule = ReplicatedStorage:FindFirstChild("WiltedMonetization")
	if rootModule and rootModule:IsA("ModuleScript") then
		local ok, root = pcall(require, rootModule)
		if ok and type(root) == "table" and type(root.GetCore) == "function" then
			Core = root.GetCore()
		end
	end
end
local log = Core and Core.Log.new("WiltedMonetization")

local StockGlue = {}

StockGlue.RULE = "LimitedStockAvailable"
StockGlue.GRANT = "LimitedStock"
StockGlue.PAYOUT_KIND = "Pack"
StockGlue.SERVICE = "Stock"

-- The Stock functions the glue calls. An older Stock without them is not
-- attached to, so the products fail closed instead of erroring mid-sale.
local REQUIRED = { "Claim", "CheckClaimable", "IsClaimRecorded" }

local function skuOf(product: any): string?
	local data = type(product) == "table" and product.GrantData or nil
	local sku = type(data) == "table" and data.Sku or nil
	if type(sku) == "string" and sku ~= "" then
		return sku
	end
	return nil
end

local function purchaseIdOf(context: any): string?
	local receipt = type(context) == "table" and context.ReceiptInfo or nil
	local purchaseId = type(receipt) == "table" and receipt.PurchaseId or nil
	if type(purchaseId) == "string" and purchaseId ~= "" then
		return purchaseId
	end
	return nil
end

--[[
	Subscribe to Stock. Returns the directory connection, or nil when the core
	is missing (nothing to subscribe to).

	options.rules     PurchaseRules (required)
	options.granting  GrantingManager (required)
	options.services  a service directory; default the core's (tests inject one)
]]
function StockGlue.Attach(options: { [string]: any }): any
	if not Core then
		return nil
	end
	local rules = options.rules
	local granting = options.granting
	local services = options.services or Core.Services

	local stock: any = nil
	local ownsRule, ownsGrant = false, false

	local function rule(player: Player, product: any, context: any): (boolean, string?)
		local sku = skuOf(product)
		if not sku then
			log:Warn("product %q uses %s but has no GrantData.Sku", tostring(product and product.ProductId), StockGlue.RULE)
			return false, "this product is misconfigured"
		end

		local purchaseId = purchaseIdOf(context)
		if purchaseId then
			-- A retry after a successful claim whose payout failed.
			local okRecorded, recorded = stock.IsClaimRecorded(purchaseId)
			if okRecorded and recorded == true then
				return true, nil
			end
		end

		local ok, reason, code = stock.CheckClaimable(sku, player.UserId, { fresh = purchaseId ~= nil })
		if ok then
			return true, nil
		end
		if purchaseId and code == "unavailable" then
			log:Warn("%s could not read stock for %q at receipt (%s) - passing; the claim decides",
				StockGlue.RULE, sku, tostring(reason))
			return true, nil
		end
		return false, reason
	end

	local function grant(player: Player, product: any, context: any): (boolean, string?)
		local sku = skuOf(product)
		if not sku then
			return false, string.format("product %q has no GrantData.Sku", tostring(product and product.ProductId))
		end
		local purchaseId = purchaseIdOf(context)
		if not purchaseId then
			-- Without a receipt id the claim could not be made retry-safe.
			return false, StockGlue.GRANT .. " needs a receipt PurchaseId"
		end

		local okClaim, result = stock.Claim(sku, player.UserId, { idempotencyKey = purchaseId })
		if not okClaim then
			return false, "stock claim failed: " .. tostring(result)
		end

		-- Pay out through the host's Pack kind. A copy of the product with the
		-- kind swapped, so the host's Pack grant reads the same GrantData.
		local payout = table.clone(product)
		payout.GrantKind = StockGlue.PAYOUT_KIND
		local okPay, payReason = granting.Grant(player, payout, context)
		if not okPay then
			return false, string.format("claimed %q but the %s payout failed (receipt kept for retry): %s",
				sku, StockGlue.PAYOUT_KIND, tostring(payReason))
		end
		return true, nil
	end

	local function attach(api: any)
		for _, name in ipairs(REQUIRED) do
			if type(api) ~= "table" or type(api[name]) ~= "function" then
				log:Warn("Stock has no %s - update WiltedStock; %s products stay unavailable",
					name, StockGlue.GRANT)
				return
			end
		end
		-- Re-registration of Stock: the closures read `stock`, so swapping it
		-- is enough; registering again would only warn.
		local first = stock == nil
		stock = api
		if not first then
			return
		end

		if rules.IsRegistered(StockGlue.RULE) then
			log:Info("rule %q is already registered by the host - keeping the host's", StockGlue.RULE)
		else
			rules.Register(StockGlue.RULE, rule)
			ownsRule = true
		end
		if granting.IsRegistered(StockGlue.GRANT) then
			log:Info("grant kind %q is already registered by the host - keeping the host's", StockGlue.GRANT)
		else
			granting.Register(StockGlue.GRANT, grant)
			ownsGrant = true
		end
		if ownsRule or ownsGrant then
			log:Info("Stock found - %s glue attached", StockGlue.GRANT)
		end
	end

	return services.OnRegistered(StockGlue.SERVICE, attach)
end

return StockGlue
