--!strict
--[[
	=== MonetizationClient ====================================================
	The client half. Deliberately almost featureless.

	USAGE

		local MonetizationClient = require(ReplicatedStorage.WiltedMonetization.MonetizationClient)

		Button.MouseButton1Click:Connect(function()
			MonetizationClient:PromptPurchase("Money1000")
		end)

		-- Optional: react to the outcome.
		MonetizationClient.PurchaseFinished:Connect(function(result)
			if result.Granted then
				print("got", result.DisplayName)
			else
				print("no sale:", result.Reason)
			end
		end)

		-- Gamepasses are prompted the same way, and ownership can be read
		-- locally to draw "OWNED" on a button:
		if MonetizationClient:OwnsGamePass("VIP") then ... end
		MonetizationClient.GamePassOwnershipChanged:Connect(function() redrawShop() end)

	WHAT IT CANNOT DO, ON PURPOSE

	It cannot grant anything, it cannot evaluate a rule, and it cannot name a
	Roblox asset id. PromptPurchase sends one of OUR product ids and nothing
	else; the server resolves the asset, re-checks every rule and decides whether
	to prompt at all. So a modified client can ask for a different product - and
	get the same refusal a legitimate one would.

	It does not even call MarketplaceService:PromptProductPurchase itself. That
	call has to happen on the server here, because the server is what knows
	whether the rules passed, and a client-side prompt would let someone skip
	straight to paying for something they can never receive.

	READING THE CATALOGUE IS FINE

	GetProduct is exposed so a shop can draw names and prices without a
	round-trip. The catalogue holds no secrets: asset ids are public, and
	nothing in it is trusted by the server.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Sibling lookup, so the subtree can be parented anywhere.
local Monetization = require(script.Parent)

local Core, disabledReason = Monetization.GetCore()
local log = Core and Core.Log.new("WiltedMonetization")

local MonetizationClient = {}

--[[
	Fired when a purchase attempt concludes, successfully or not.

	The payload is a table rather than positional arguments so a field can be
	added later without breaking existing listeners:

		ProductId    [string]   which of our products
		DisplayName  [string?]  convenience, for a message
		Granted      [boolean]  did the player actually receive it
		Reason       [string?]  why not, when Granted is false

	This fires for REFUSALS TOO (a failed rule, an unknown product, a product
	with no asset yet), which is the whole point: a dead button with no
	explanation is the worst outcome for the player.
]]
MonetizationClient.PurchaseFinished = Monetization.Signal.new()

--[[
	Fired whenever the server sends this player's gamepass ownership - once
	after join, and again after each gamepass purchase. No arguments: read
	OwnsGamePass for the new state.

	OWNERSHIP HERE IS FOR DISPLAY ONLY. A modified client can make
	OwnsGamePass return anything, so the server must never take a client's
	word for it - server code asks MonetizationService:PlayerOwnsGamePass.
]]
MonetizationClient.GamePassOwnershipChanged = Monetization.Signal.new()

-- productId -> true for every gamepass the server says this player owns.
local ownedGamePasses: { [string]: boolean } = {}
-- False until the server's first answer arrives, so "not owned" and "not
-- known yet" can be told apart.
local gamePassOwnershipLoaded = false

-- Does this player own this gamepass? Takes OUR product id. Display only.
function MonetizationClient:OwnsGamePass(productId: string): boolean
	return ownedGamePasses[productId] == true
end

-- Has the server reported ownership yet? A shop can show "..." until it has.
function MonetizationClient:IsGamePassOwnershipLoaded(): boolean
	return gamePassOwnershipLoaded
end

-- One product's catalogue entry, for drawing a shop. nil when unknown.
function MonetizationClient:GetProduct(productId: string)
	local product = Monetization.FindProduct(productId)
	return product
end

-- The whole catalogue. Treat it as read-only.
function MonetizationClient:GetAllProducts()
	return Monetization.AllProducts()
end

--[[
	Ask the server to prompt a purchase.

	Returns true when the REQUEST was sent, which is not the same as the sale
	succeeding - listen to PurchaseFinished for that. Returns false plus a
	reason when the request could not even be made, so a caller can show
	something immediately rather than waiting for a reply that is not coming.

	The local product check is a COURTESY, not a security boundary: it catches a
	typo in a shop script with a clear message instead of a silent no-op. The
	server re-checks everything regardless.
]]
function MonetizationClient:PromptPurchase(productId: string, recipient: (Player | number)?): (boolean, string?)
	if not RunService:IsClient() then
		return false, "PromptPurchase must be called from a client script"
	end

	if not Core then
		return false, disabledReason
	end

	local product, reason = Monetization.FindProduct(productId)
	if not product then
		log:Warn("PromptPurchase: %s", tostring(reason))
		return false, reason
	end

	-- A click must never yield (decision 2): Find answers now, and a remote the
	-- server has not created yet is an immediate refusal with a reason.
	local remote = Core.Remote.Find(script.Parent, Monetization.REMOTE_PROMPT_PURCHASE)
	if not remote then
		return false, "monetization is not ready yet"
	end

	-- GIFT TARGET, sent as a UserId. A Player instance is accepted for
	-- convenience but reduced to its id before it crosses the wire: the server
	-- re-resolves it, because an instance reference from a client proves
	-- nothing about who is actually in the server.
	local recipientUserId: number? = nil
	if recipient ~= nil then
		if type(recipient) == "number" then
			recipientUserId = recipient
		elseif typeof(recipient) == "Instance" and recipient:IsA("Player") then
			recipientUserId = recipient.UserId
		else
			return false, "recipient must be a Player or a UserId"
		end
	end

	remote:FireServer(productId, recipientUserId)
	return true, nil
end

--=============================================================================
-- RESULT LISTENER
--=============================================================================

-- Connected at require time on the client, so a caller never has to remember a
-- Start() step. On the server this module is inert, which keeps a shared
-- require from erroring in a project that requires it from both sides.
--
-- Each listener waits for its remote in the BACKGROUND with no timeout,
-- warning at 10 s and every 15 s after (decision 2), so a server that starts
-- late still connects instead of being given up on.
if RunService:IsClient() and Core then
	task.spawn(function()
		local remote = Core.Remote.Wait(script.Parent, Monetization.REMOTE_PURCHASE_RESULT, log)
		if not remote then
			return
		end
		remote.OnClientEvent:Connect(function(payload)
			-- Shape-checked before being handed on: a listener should not have to
			-- defend against a malformed payload.
			if type(payload) ~= "table" or type(payload.ProductId) ~= "string" then
				return
			end
			MonetizationClient.PurchaseFinished:Fire({
				ProductId = payload.ProductId,
				DisplayName = payload.DisplayName,
				Granted = payload.Granted == true,
				Reason = payload.Reason,
			})
		end)
	end)

	task.spawn(function()
		local remote = Core.Remote.Wait(script.Parent, Monetization.REMOTE_GAME_PASS_OWNERSHIP, log)
		if not remote then
			return
		end
		remote.OnClientEvent:Connect(function(ownedProductIds)
			if type(ownedProductIds) ~= "table" then
				return
			end
			-- Replaced wholesale: the server always sends the complete list.
			table.clear(ownedGamePasses)
			for _, productId in ipairs(ownedProductIds) do
				if type(productId) == "string" then
					ownedGamePasses[productId] = true
				end
			end
			gamePassOwnershipLoaded = true
			MonetizationClient.GamePassOwnershipChanged:Fire()
		end)
		-- Ask once now that the listener exists. The server's own push after
		-- its join lookup may have landed before this script ran.
		remote:FireServer()
	end)
end

return MonetizationClient
