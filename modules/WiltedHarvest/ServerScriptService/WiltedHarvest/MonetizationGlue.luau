--!strict
--[[
	=== MonetizationGlue =======================================================

	Feeds WiltedMonetization's purchases into Harvest (plan H11). Glue lives in
	the consumer (D10): WiltedMonetization is not edited and does not know
	Harvest exists. With Monetization absent, this does nothing.

	HOW IT ATTACHES

	HarvestService.Start calls Attach once. Attach subscribes with
	Core.Services.OnRegistered("Monetization"); when Monetization registers
	(the end of its own Start) the glue connects to two of its signals:

	  ProductGranted(recipient, product, receiptInfo, { Buyer, IsGift })
	      Fires once per real purchase, AFTER the grant is confirmed saved
	      (receipt replays return before it). Reported as purchase_verified on
	      the BUYER, event id = "receipt:<PurchaseId>", so the same receipt
	      reaching two servers is counted once (Roblox documents that this
	      can happen).

	  GamePassOwned(player, product, isNewPurchase)
	      Fires on join for owned passes and on purchase. Only isNewPurchase =
	      true is reported (gamepass_purchased), event id =
	      "gamepass:<UserId>:<ProductId>": a pass can only be bought once.

	WHY THE SIGNALS AND NOT ProcessReceipt

	ProcessReceipt has exactly one owner (Monetization). These signals are
	documented for "logging, analytics and cosmetic reactions"; they fire
	after the decision and cannot change it. A Harvest failure inside a
	handler is caught by the Signal (each handler in its own task) and
	cannot reach the purchase.

	  An AdReward-channel receipt is reported as ad_reward_granted instead
	  (same event id): it was earned by watching an ad, not bought.

	WHAT IS READ FROM THE PRODUCT

	ProductId (Monetization's own id, never the Roblox asset id), and the
	optional catalogue field Category (the host's word, for the spend
	breakdown). The gamepass price, when wanted, is read from
	ReplicatedStorage.WiltedMonetization.ProductInfo if present (cached; no
	web call); otherwise the estimate is simply absent.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Glue = {}

local function categoryOf(product: any): string?
	local category = type(product) == "table" and product.Category or nil
	return if type(category) == "string" and category ~= "" then string.sub(category, 1, 32) else nil
end

local function gamePassPrice(productId: string): number?
	local folder = ReplicatedStorage:FindFirstChild("WiltedMonetization")
	local module = folder and folder:FindFirstChild("ProductInfo")
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, price = pcall(function()
		return (require(module) :: any).GetPrice(productId)
	end)
	return if ok and type(price) == "number" then price else nil
end

--[[
	ctx = { core, log, emit(player, type, payload, id), monetization? }
	Returns a handle with Detach() (tests) and Attached() (true once wired).
]]
function Glue.Attach(ctx: any)
	local connections: { any } = {}
	local attached = false

	local function onProductGranted(recipient: any, product: any, receiptInfo: any, extra: any)
		if type(product) ~= "table" or type(receiptInfo) ~= "table" then
			return
		end
		local buyer = if type(extra) == "table" and extra.Buyer ~= nil then extra.Buyer else recipient
		local purchaseId = receiptInfo.PurchaseId
		if type(purchaseId) ~= "string" or purchaseId == "" or type(product.ProductId) ~= "string" then
			ctx.log:Warn("ProductGranted without PurchaseId / ProductId - not recorded")
			return
		end
		local spent = receiptInfo.CurrencySpent
		local channel = receiptInfo.ProductPurchaseChannel
		local payload = {
			ProductId = product.ProductId,
			PurchaseId = string.sub(purchaseId, 1, 200),
			Robux = if type(spent) == "number" then spent else nil,
			Channel = if typeof(channel) == "EnumItem" then channel.Name
				elseif type(channel) == "string" then channel
				else nil,
			Category = categoryOf(product),
			IsGift = if type(extra) == "table" and extra.IsGift == true then true else nil,
		}
		local eventId = "receipt:" .. string.sub(purchaseId, 1, 90)
		if payload.Channel == "AdReward" then
			-- Watching an ad paid for this: an ad reward, not a purchase
			-- (H5). Same event id, so it can never count as both.
			ctx.emit(buyer, "ad_reward_granted", {
				PurchaseId = payload.PurchaseId,
				ProductId = payload.ProductId,
			}, eventId)
			return
		end
		ctx.emit(buyer, "purchase_verified", payload, eventId)
	end

	local function onGamePassOwned(player: any, product: any, isNewPurchase: any)
		if isNewPurchase ~= true or type(product) ~= "table" or type(product.ProductId) ~= "string" then
			return
		end
		ctx.emit(player, "gamepass_purchased", {
			ProductId = product.ProductId,
			EstimatedRobux = gamePassPrice(product.ProductId),
			Category = categoryOf(product),
		}, string.format("gamepass:%s:%s", tostring(player.UserId), string.sub(product.ProductId, 1, 60)))
	end

	local function wire(api: any)
		for _, c in ipairs(connections) do
			c:Disconnect()
		end
		table.clear(connections)
		if type(api) ~= "table" or type(api.ProductGranted) ~= "table" or type(api.GamePassOwned) ~= "table" then
			ctx.log:Warn("Monetization is registered but has no ProductGranted / GamePassOwned signals - purchases not recorded")
			return
		end
		table.insert(connections, api.ProductGranted:Connect(onProductGranted))
		table.insert(connections, api.GamePassOwned:Connect(onGamePassOwned))
		attached = true
		ctx.log:Info("recording purchases from WiltedMonetization")
	end

	-- ctx.monetization (tests) wires a given API directly; otherwise follow
	-- the core directory, so a Monetization that starts later is picked up.
	local subscription: any
	if ctx.monetization ~= nil then
		wire(ctx.monetization)
		subscription = { Disconnect = function() end }
	else
		subscription = ctx.core.Services.OnRegistered("Monetization", wire)
	end

	return {
		Attached = function(): boolean
			return attached
		end,
		Detach = function()
			subscription:Disconnect()
			for _, c in ipairs(connections) do
				c:Disconnect()
			end
			table.clear(connections)
			attached = false
		end,
		-- Exposed for tests: drive the handlers without a Monetization.
		_onProductGranted = onProductGranted,
		_onGamePassOwned = onGamePassOwned,
	}
end

return Glue
