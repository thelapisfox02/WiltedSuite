--!strict
--[[
	=== HarvestEnums ===========================================================

	The vocabulary shared by the server half, sinks and anything that reads
	exported events. Strings only, no logic beyond two lookups.

	NEVER rename or reuse a value: event type strings end up in saved
	summaries (Meta.EventCounts) and in analytics dashboards. Add new ones.

	WHY TRI-STATE IS A STRING, NOT true / false / "unknown"

	The Harvest docs ask that an unknown platform answer never reads as a
	verified "no". Mixing booleans and a string in one field makes every
	reader write a three-way type check, and a careless `if field then`
	treats "unknown" as yes. One string type per field, with Unknown and
	Unavailable spelled out, makes the careless check impossible.
]]

local Enums = {}

-- How a summary field was obtained (Harvest docs: "Data quality").
Enums.Quality = table.freeze({
	Verified = "verified",       -- from a platform callback we trust (receipts)
	Measured = "measured",       -- observed by the server (session time)
	Derived = "derived",         -- computed from other fields (streaks)
	Estimated = "estimated",     -- a best guess, labelled as such
	Unavailable = "unavailable", -- the platform does not expose it
})

-- Answers to a yes/no question asked of the platform.
Enums.Tri = table.freeze({
	Yes = "yes",
	No = "no",
	Unknown = "unknown",         -- we asked and the platform did not answer
	Unavailable = "unavailable", -- there is no way to ask
})

Enums.EventType = table.freeze({
	-- Emitted by Harvest itself (hosts may not emit these).
	SessionStarted = "session_started",
	SessionEnded = "session_ended",
	StreakUpdated = "daily_streak_updated",
	GroupChecked = "group_checked",
	FriendCoplay = "friend_coplay_interval",

	-- Emitted by glue or by the host's adapter.
	PurchaseVerified = "purchase_verified",
	GamePassPurchased = "gamepass_purchased",
	AdShown = "ad_shown",
	AdRewardGranted = "ad_reward_granted",
	GroupBonusClaimed = "group_bonus_claimed",
	Counter = "counter",
	Milestone = "milestone",
})

-- Events only Harvest may emit. A host emitting one would fake a session or
-- a platform check.
Enums.Internal = table.freeze({
	session_started = true,
	session_ended = true,
	daily_streak_updated = true,
	group_checked = true,
	friend_coplay_interval = true,
})

--[[
	Payload fields of every built-in event: "type" required, "type?" optional.
	Any other field is refused, so a typo surfaces at the Emit call.
]]
Enums.PayloadSpec = table.freeze({
	session_started = table.freeze({ Rejoin = "boolean?" }),
	session_ended = table.freeze({ Seconds = "number", Recovered = "boolean?" }),
	daily_streak_updated = table.freeze({ Current = "number", Highest = "number" }),
	group_checked = table.freeze({ IsMember = "string", GroupId = "number?" }),
	friend_coplay_interval = table.freeze({ Seconds = "number", Friends = "number", Verified = "string" }),

	purchase_verified = table.freeze({
		ProductId = "string",   -- the game's own product id, never a Roblox id
		PurchaseId = "string",  -- receipt PurchaseId; also the event id
		Robux = "number?",      -- receipt CurrencySpent; absent = amount unknown
		Channel = "string?",    -- Enum.ProductPurchaseChannel name
		Category = "string?",   -- host's grouping for the spend summary
		IsGift = "boolean?",
	}),
	gamepass_purchased = table.freeze({
		ProductId = "string",
		EstimatedRobux = "number?", -- catalogue price; no receipt exists (H17)
		Category = "string?",
	}),
	ad_shown = table.freeze({
		Result = "string",      -- Enum.ShowAdResult name
		Placement = "string?",
	}),
	ad_reward_granted = table.freeze({
		PurchaseId = "string",  -- the AdReward receipt
		ProductId = "string?",
		Placement = "string?",
	}),
	group_bonus_claimed = table.freeze({ ClaimId = "string?" }),
	counter = table.freeze({ Key = "string", Amount = "number", Exponent = "number?" }), -- Amount x 10^Exponent (Big counters only)
	milestone = table.freeze({ Key = "string" }),
})

function Enums.IsBuiltinEvent(eventType: string): boolean
	return Enums.PayloadSpec[eventType] ~= nil
end

return table.freeze(Enums)
