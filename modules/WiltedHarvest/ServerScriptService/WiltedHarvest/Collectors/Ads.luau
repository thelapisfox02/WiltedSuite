--!strict
--[[
	=== Collectors.Ads =========================================================

	Rewarded-video ads (plan H5 / spec 04-monetization:02). Built "as if ads
	will be there" (H15): everything works with no ads at all, and counts
	only what the platform verifies.

	TWO SOURCES, BOTH VERIFIED

	  ad_reward_granted   the REWARD: Roblox grants an ad's developer product
	                      through ProcessReceipt with
	                      ProductPurchaseChannel = AdReward. MonetizationGlue
	                      reports it (event id "receipt:<PurchaseId>"), so a
	                      redelivered receipt counts once. This is the "ad
	                      completed and rewarded" fact. A host-emitted
	                      purchase_verified with Channel = "AdReward" counts
	                      here too (same id = counted once), never as spend.
	                      Needs the product in WiltedConfig.Products (H18).

	  ad_shown            the SHOW: whoever calls
	                      AdService:ShowRewardedVideoAdAsync (the game, on the
	                      server) reports the Enum.ShowAdResult it returned:
	                          HarvestService.Emit(player, "ad_shown",
	                              { Result = result.Name, Placement = "shop" })
	                      Roblox says not to grant from this result; Harvest
	                      only counts it.

	HARVEST NEVER SHOWS, PROMPTS OR GRANTS AN AD. Eligibility and frequency
	are the game's decisions (spec principle: ads stay voluntary).

	NOT AVAILABLE: per-player ad revenue (Roblox reports earnings only as
	dashboard aggregates, H0) - GetDerived reports EstimatedAdRevenue =
	"unavailable", never a number. Ad availability is client-only, so
	"how often an ad could have been shown" is not measured.

	Result names outside the known Enum.ShowAdResult list count under
	"Other" (a future enum value must not be refused or invent a field).
	Placements are the game's own words (max 32), capped at
	Tunables.AdPlacementLimit; more go to "_other".
]]

local Ads = {}
Ads.Name = "Ads"

local KNOWN_RESULTS = {
	ShowCompleted = true,
	ShowInterrupted = true,
	AdNotReady = true,
	AdAlreadyShowing = true,
	InternalError = true,
	InsufficientMemory = true,
}
Ads.KNOWN_RESULTS = KNOWN_RESULTS

local function capped(ctx: any, map: { [string]: number }, key: any)
	if type(key) ~= "string" or key == "" then
		return
	end
	key = string.sub(key, 1, 32)
	if map[key] == nil then
		local n = 0
		for _ in pairs(map) do
			n += 1
		end
		if n >= ctx.config.Tunables.AdPlacementLimit then
			key = "_other"
		end
	end
	map[key] = (map[key] or 0) + 1
end

local function reward(ctx: any, state: any, envelope: any)
	local ads = state.Summary.Ads
	ads.RewardReceipts += 1
	if ads.FirstRewardAt == 0 then
		ads.FirstRewardAt = envelope.ServerTime
	end
	ads.LastRewardAt = envelope.ServerTime
	capped(ctx, ads.PlacementRewards, envelope.Payload.Placement)
	state.Dirty = true
end

function Ads.OnEvent(ctx: any, state: any, envelope: any, writable: boolean)
	if not writable then
		return
	end
	local eventType = envelope.EventType
	if eventType == "ad_reward_granted" then
		reward(ctx, state, envelope)
	elseif eventType == "purchase_verified" and envelope.Payload.Channel == "AdReward" then
		reward(ctx, state, envelope)
	elseif eventType == "ad_shown" then
		local ads = state.Summary.Ads
		local result: string = envelope.Payload.Result
		if not KNOWN_RESULTS[result] then
			result = "Other"
		end
		ads.Shows[result] = (ads.Shows[result] or 0) + 1
		ads.LastShowAt = envelope.ServerTime
		if result == "ShowCompleted" then
			ads.ShowsCompleted += 1
			capped(ctx, ads.PlacementCompleted, envelope.Payload.Placement)
		elseif result == "ShowInterrupted" then
			ads.ShowsInterrupted += 1
		end
		state.Dirty = true
	end
end

-- Numbers for GetDerived. Rates are nil until there is something to divide.
function Ads.Derive(summary: { [string]: any }): { [string]: any }
	local ads = summary.Ads
	local out: { [string]: any } = { EstimatedAdRevenue = "unavailable" }
	if type(ads) ~= "table" then
		return out
	end
	local completed = ads.ShowsCompleted or 0
	local started = completed + (ads.ShowsInterrupted or 0)
	out.HasWatchedAd = completed > 0 or (ads.RewardReceipts or 0) > 0
	-- Of the ads that actually started playing, the share watched to the end.
	out.AdCompletionRate = if started > 0 then completed / started else nil
	return out
end

return Ads
