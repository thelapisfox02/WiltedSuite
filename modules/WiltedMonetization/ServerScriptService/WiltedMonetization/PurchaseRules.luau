--!strict
--[[
	=== PurchaseRules =========================================================
	The guards. A rule answers one question: MAY this player buy this product
	right now?

	WHY RULES EXIST SEPARATELY FROM THE CATALOGUE

	A rule almost always needs a real service - the player's profile, an
	inventory, a world lookup. The catalogue has to stay data-only and
	client-safe, so it cannot require any of those. So the catalogue names rules
	as STRINGS and the implementations live here, receiving whatever they need
	through the context the service was started with.

	WRITING ONE

		PurchaseRules.Register("NotAlreadyOwned", function(player, product, context)
			local profile = context.Profile and context.Profile.get(player)
			if not profile then
				return false, "profile not loaded"
			end
			if table.find(profile.items, product.GrantData.ItemId) then
				return false, "you already own this"
			end
			return true
		end)

	THE CONTRACT

	  return true                -> allowed
	  return false, "reason"     -> refused; the reason reaches the player
	  error()                    -> treated as a REFUSAL, never as permission

	That last line is the important one. A rule that throws must not fail open:
	an exploiter who can make a rule error would otherwise have found a way past
	it. Every rule is called inside a pcall and a thrown error refuses.

	REASONS ARE SHOWN TO THE PLAYER, so write them as a player would read them
	("you already own this"), not as a developer would ("dupe check failed").

	WHEN RULES RUN

	TWICE, deliberately:

	  1. Before prompting  - so the player is never charged for something they
	                         cannot receive. Advisory.
	  2. At receipt time   - AUTHORITATIVE. Minutes can pass between the prompt
	                         and the payment; state may have changed, and a
	                         receipt can be replayed on another server entirely.

	A rule must therefore be CHEAP and SIDE-EFFECT FREE. It may be called many
	times for one sale, including on a server that never showed the prompt.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The shared root, by its documented fixed path (layout 4b), inside pcall so a
-- missing package refuses instead of erroring. Its GetCore() says whether the
-- core is usable; the root has already warned once if it is not.
local Core: any = nil
local disabledReason: string? = "WiltedMonetization is not installed at ReplicatedStorage.WiltedMonetization"
do
	local rootModule = ReplicatedStorage:FindFirstChild("WiltedMonetization")
	if rootModule and rootModule:IsA("ModuleScript") then
		local ok, root = pcall(require, rootModule)
		if ok and type(root) == "table" and type(root.GetCore) == "function" then
			Core, disabledReason = root.GetCore()
		else
			disabledReason = "WiltedMonetization failed to load"
		end
	end
end
local log = Core and Core.Log.new("WiltedMonetization")

local PurchaseRules = {}

-- ruleName -> function(player, product, context) -> boolean, string?
-- The core's Registry: the same warnings as before, in one shared place.
local registeredRules = Core and Core.Registry.new({
	log = log,
	label = "rule",
	nameLabel = "rule name",
})

--[[
	Register a rule under a name the catalogue can refer to.

	Re-registering the same name REPLACES it and warns. Silent replacement would
	make a duplicated name in two files behave differently depending on load
	order, which is near-impossible to debug.
]]
function PurchaseRules.Register(ruleName: string, ruleFunction: (Player, any, any) -> (boolean, string?))
	if not registeredRules then
		warn("[WiltedMonetization] PurchaseRules.Register: service disabled - " .. tostring(disabledReason))
		return
	end
	registeredRules:Register(ruleName, ruleFunction)
end

-- Every registered rule name, sorted. For a console check while authoring.
function PurchaseRules.RegisteredRules(): { string }
	return if registeredRules then registeredRules:Registered() else {}
end

function PurchaseRules.IsRegistered(ruleName: string): boolean
	return registeredRules ~= nil and registeredRules:IsRegistered(ruleName)
end

--[[
	Run every rule a product lists, in order, stopping at the first refusal.

	AN UNKNOWN RULE NAME REFUSES. It would be easier to skip it with a warning,
	but a product whose guard silently stopped existing is exactly how a unique
	item gets sold twice - so a typo closes the till rather than opening it.

	Returns ok, reason. `reason` is player-facing on refusal.
]]
function PurchaseRules.Check(player: Player, product: any, context: any): (boolean, string?)
	-- No core: nothing can be checked, so nothing may pass (fail closed).
	if not registeredRules then
		return false, disabledReason
	end
	if type(product) ~= "table" then
		return false, "that product does not exist"
	end

	local ruleNames = product.Rules
	if ruleNames == nil then
		return true, nil
	end
	if type(ruleNames) ~= "table" then
		log:Warn("product %q has a malformed Rules field", tostring(product.ProductId))
		return false, "this product is misconfigured"
	end

	for _, ruleName in ipairs(ruleNames) do
		local ruleFunction = if type(ruleName) == "string" then registeredRules:Get(ruleName) else nil
		if not ruleFunction then
			log:Warn("product %q names rule %q, which is not registered - refusing the purchase. Registered: %s",
				tostring(product.ProductId), tostring(ruleName),
				table.concat(PurchaseRules.RegisteredRules(), ", "))
			return false, "this product is temporarily unavailable"
		end

		-- pcall: a rule that errors REFUSES. See the header.
		local ok, allowed, reason = pcall(ruleFunction, player, product, context)
		if not ok then
			log:Warn("rule %q errored: %s", tostring(ruleName), tostring(allowed))
			return false, "this product is temporarily unavailable"
		end
		if allowed ~= true then
			return false, (type(reason) == "string" and reason) or "you cannot buy this right now"
		end
	end

	return true, nil
end

return PurchaseRules
