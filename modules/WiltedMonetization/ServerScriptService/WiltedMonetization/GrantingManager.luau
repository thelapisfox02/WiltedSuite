--!strict
--[[
	=== GrantingManager =======================================================
	What the player actually RECEIVES. One function per GrantKind.

	WRITING ONE

		GrantingManager.Register("Currency", function(player, product, context)
			local amount = product.GrantData and product.GrantData.Amount
			if type(amount) ~= "number" then
				return false, "GrantData.Amount missing"
			end
			return context.Profile.add(player, "money", amount, context.Reason)
		end)

	THE CONTRACT, AND WHY IT IS STRICTER THAN IT LOOKS

	  return true            -> the player HAS the thing. Durable.
	  return false, "reason" -> the grant did not happen.
	  error()                -> treated as FAILURE.

	Returning true is a promise that the value is in the player's persistent
	data, because the service reports PurchaseGranted to Roblox on the strength
	of it and Roblox then considers the Robux spent forever. A granting function
	that returns true after only, say, spawning a visual effect has given the
	player nothing and taken their money.

	So: write the DURABLE part (profile fields, inventory) inside the granting
	function, and leave cosmetic reactions - effects, sounds, banners - to a
	listener on MonetizationService.ProductGranted, which fires after the save is
	confirmed. Cosmetics that fail must never be able to fail a sale.

	FAILURE IS SAFE AND IS RETRIED. A false return makes the service answer
	NotProcessedYet, so Roblox re-delivers the receipt later - a profile that was
	not loaded yet, or a datastore blip, resolves itself on the retry. This is
	why a granting function should refuse rather than improvise when something is
	missing.

	IT MAY BE CALLED MORE THAN ONCE PER SALE. The service only calls it when the
	purchase id is NOT already in the player's recorded history, so a duplicate
	receipt will not reach it - but a grant that returned false and is retried
	will. Idempotent-where-cheap is the safer habit.
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

local GrantingManager = {}

-- grantKind -> function(player, product, context) -> boolean, string?
-- The core's Registry: the same warnings as before, in one shared place.
local registeredKinds = Core and Core.Registry.new({
	log = log,
	label = "grant kind",
	nameLabel = "grant kind",
})

--[[
	Register a granting function for a GrantKind.

	Re-registering warns, for the same reason PurchaseRules does: load-order
	dependent behaviour is the hardest kind of bug to find in a shop.
]]
function GrantingManager.Register(grantKind: string, grantFunction: (Player, any, any) -> (boolean, string?))
	if not registeredKinds then
		warn("[WiltedMonetization] GrantingManager.Register: service disabled - " .. tostring(disabledReason))
		return
	end
	registeredKinds:Register(grantKind, grantFunction)
end

-- Every registered grant kind, sorted. For a console check while authoring.
function GrantingManager.RegisteredKinds(): { string }
	return if registeredKinds then registeredKinds:Registered() else {}
end

function GrantingManager.IsRegistered(grantKind: string): boolean
	return registeredKinds ~= nil and registeredKinds:IsRegistered(grantKind)
end

--[[
	Run the granting function for this product.

	AN UNREGISTERED GrantKind FAILS rather than being skipped, so the receipt is
	retried instead of being consumed. If the developer registers the missing
	kind and restarts, Roblox re-delivers the receipt and the player gets what
	they paid for - which is only possible because we never answered
	PurchaseGranted.
]]
function GrantingManager.Grant(player: Player, product: any, context: any): (boolean, string?)
	-- No core: nothing is granted, and the false keeps the receipt for a retry.
	if not registeredKinds then
		return false, disabledReason
	end
	if type(product) ~= "table" then
		return false, "product is not a table"
	end

	local grantKind = product.GrantKind
	if type(grantKind) ~= "string" then
		return false, string.format("product %q has no GrantKind", tostring(product.ProductId))
	end

	local grantFunction = registeredKinds:Get(grantKind)
	if not grantFunction then
		local message = string.format(
			"grant kind %q is not registered (product %q). Registered: %s",
			grantKind, tostring(product.ProductId),
			table.concat(GrantingManager.RegisteredKinds(), ", "))
		log:Warn("%s - the receipt will be retried, not consumed", message)
		return false, message
	end

	-- pcall: an erroring grant must read as failure, so the receipt is retried
	-- rather than the Robux being taken for nothing.
	local ok, granted, reason = pcall(grantFunction, player, product, context)
	if not ok then
		log:Warn("grant %q errored: %s", grantKind, tostring(granted))
		return false, "granting errored: " .. tostring(granted)
	end
	if granted ~= true then
		return false, (type(reason) == "string" and reason) or "granting refused"
	end
	return true, nil
end

return GrantingManager
