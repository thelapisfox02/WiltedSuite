--!strict
--[[
	=== Collectors.Spend =======================================================

	Spend summary (plan H3), from these events:

	    purchase_verified    a developer-product receipt, after the grant was
	                         saved (MonetizationGlue, or a host without
	                         WiltedMonetization). Robux = receipt CurrencySpent.
	    gamepass_purchased   a NEW gamepass purchase. No receipt exists, so the
	                         amount is the catalogue price, kept apart as
	                         EstimatedGamePassRobux (decision H17).

	VERIFIED vs ESTIMATED. RobuxSpent only ever holds receipt amounts. A
	receipt without CurrencySpent counts as a purchase with an UNKNOWN amount
	(UnknownAmountCount + 1), never as 0 Robux and never as a guess.

	AD REWARDS ARE NOT SPEND. A receipt whose Channel is "AdReward" was paid
	for by watching an ad. Collectors.Ads counts it (Ads.RewardReceipts); it
	is excluded from every spend number here.

	GIFTS. The buyer pays, so the glue reports the purchase on the BUYER.
	Gifts are also counted (GiftsBought) so a dashboard can tell them apart.

	Categories are the host's own words (a product's Category, max 32
	characters), capped at Tunables.SpendCategoryLimit distinct names. Once
	full, new names count under "_other". Bounded size, whatever the
	catalogue.

	Duplicates: the PurchaseId is the event id, so the service drops a
	repeated receipt before this collector sees it (H1 dedupe).
]]

local Spend = {}
Spend.Name = "Spend"

local OTHER = "_other"

local function addCategory(ctx: any, spend: { [string]: any }, category: any)
	if type(category) ~= "string" or category == "" then
		return
	end
	category = string.sub(category, 1, 32)
	local counts = spend.Categories
	if counts[category] == nil then
		local n = 0
		for _ in pairs(counts) do
			n += 1
		end
		if n >= ctx.config.Tunables.SpendCategoryLimit then
			category = OTHER
		end
	end
	counts[category] = (counts[category] or 0) + 1
end

function Spend.OnEvent(ctx: any, state: any, envelope: any, writable: boolean)
	if not writable then
		return
	end
	local eventType = envelope.EventType
	local payload = envelope.Payload
	local summary = state.Summary
	local now: number = envelope.ServerTime

	if eventType == "purchase_verified" then
		if payload.Channel == "AdReward" then
			return -- watching an ad is not spend; Collectors.Ads counts it
		end
		local spend = summary.Spend
		spend.PurchaseCount += 1
		if type(payload.Robux) == "number" and payload.Robux >= 0 then
			spend.RobuxSpent += payload.Robux
			if payload.Robux > spend.LargestPurchaseRobux then
				spend.LargestPurchaseRobux = payload.Robux
			end
		else
			spend.UnknownAmountCount += 1
		end
		if payload.IsGift == true then
			spend.GiftsBought += 1
		end
		if spend.FirstPurchaseAt == 0 then
			spend.FirstPurchaseAt = now
		end
		spend.LastPurchaseAt = now
		addCategory(ctx, spend, payload.Category)
		state.Dirty = true
	elseif eventType == "gamepass_purchased" then
		local spend = summary.Spend
		spend.GamePassCount += 1
		if type(payload.EstimatedRobux) == "number" and payload.EstimatedRobux >= 0 then
			spend.EstimatedGamePassRobux += payload.EstimatedRobux
		end
		if spend.FirstPurchaseAt == 0 then
			spend.FirstPurchaseAt = now
		end
		spend.LastPurchaseAt = now
		addCategory(ctx, spend, payload.Category)
		state.Dirty = true
	end
end

return Spend
