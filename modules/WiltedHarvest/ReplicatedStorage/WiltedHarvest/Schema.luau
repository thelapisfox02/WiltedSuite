--!strict
--[[
	=== Schema =================================================================

	The per-player SUMMARY: its shape, its version, and how an older saved
	summary is brought up to date. Pure functions over plain tables; no
	Instances, no yields, no clock (callers pass `now`).

	    local summary = Schema.New(now)
	    local summary, info = Schema.Migrate(saved, now)
	    if Schema.RememberEventId(summary, eventId, 64) then ... end

	---------------------------------------------------------------------------
	WHY MIGRATION IS "FILL IN, NEVER REMOVE"
	---------------------------------------------------------------------------

	A summary is written by whichever server the player is on, and during a
	rollout old and new servers run side by side. So:

	  * A missing section or field is filled from DEFAULTS. That is the
	    additive migration every Harvest update relies on: adding a field
	    never needs a version bump.
	  * A field Harvest does not know is KEPT. It may belong to a newer
	    version; deleting it would lose that version's data the moment an old
	    server saves.
	  * A summary from a NEWER schema than this server knows is returned
	    untouched with info.ReadOnly = true. The service then records nothing
	    for that player this session instead of overwriting fields it cannot
	    interpret. Losing one session of stats beats corrupting the record.
	  * Only a real change of meaning gets a numbered migration step
	    (MIGRATIONS[n] turns version n into n + 1).

	---------------------------------------------------------------------------
	SIZE
	---------------------------------------------------------------------------

	Everything here is bounded: RecentEventIds is a ring of at most N ids,
	EventCounts has one key per event TYPE (built-in + declared), never per
	event. Measured worst case is recorded in the H1 report.
]]

local HttpService = game:GetService("HttpService")

local Schema = {}

Schema.CURRENT = 1

-- One table per section. Every field must have a default. Sections for the
-- later collectors (Sessions, Streaks, Spend, Ads, Social, Community,
-- Extensions) are added here by the phase that builds them.
Schema.DEFAULTS = {
	Meta = {
		CreatedAt = 0,
		UpdatedAt = 0,
		-- Most recent event ids, oldest first, for duplicate detection
		-- across servers and rejoins.
		RecentEventIds = {},
		-- Accepted events per type, lifetime.
		EventCounts = {},
		-- Duplicates refused, lifetime (a data-quality signal).
		Duplicates = 0,
	},
	-- H2. Seconds, server clock (os.time). 0 = never.
	Sessions = {
		FirstJoinAt = 0,
		LastJoinAt = 0,
		LastLeaveAt = 0,
		TotalSessions = 0,      -- rejoins within RejoinGraceSeconds not included
		Rejoins = 0,
		TotalPlaySeconds = 0,   -- added every tick; a crash loses <= one tick
		LongestSessionSeconds = 0,
		Recovered = 0,          -- sessions closed from a crash marker
		-- The session in progress: { Id, StartedAt, LastBeat }. Empty when
		-- none. A load that finds another session's Open closes it.
		Open = {},
	},
	-- H2. Day numbers per Days.DayOf. -1 = never.
	Streaks = {
		Current = 0,
		Highest = 0,
		LastActiveDay = -1,
		DistinctActiveDays = 0,
		LongestAbsenceDays = 0,
		RecentDays = 0,         -- bit k = active on LastActiveDay - k (30 bits)
		PendingDay = -1,        -- newest day not yet active, and its seconds
		PendingSeconds = 0,
	},
	-- H3. Receipt amounts only (verified). Gamepass amounts are estimates
	-- and kept apart. Ad-reward receipts are not spend (see Ads).
	Spend = {
		PurchaseCount = 0,          -- developer-product receipts
		RobuxSpent = 0,             -- sum of receipt CurrencySpent
		UnknownAmountCount = 0,     -- receipts without CurrencySpent
		LargestPurchaseRobux = 0,
		GiftsBought = 0,
		GamePassCount = 0,          -- new gamepass purchases
		EstimatedGamePassRobux = 0, -- catalogue price at purchase (estimate)
		FirstPurchaseAt = 0,
		LastPurchaseAt = 0,
		Categories = {},            -- host category -> count (capped)
	},
	-- H3 (receipts) / H5 (shows). Watching an ad is not spend.
	Ads = {
		RewardReceipts = 0,         -- verified: receipts with channel AdReward
		FirstRewardAt = 0,
		LastRewardAt = 0,
		Shows = {},                 -- Enum.ShowAdResult name (or "Other") -> count
		ShowsCompleted = 0,
		ShowsInterrupted = 0,
		LastShowAt = 0,
		PlacementCompleted = {},    -- game placement -> completed shows (capped)
		PlacementRewards = {},      -- game placement -> rewards (host-reported, capped)
	},
	-- H3. The game's declared numbers, by namespaced key.
	Extensions = {
		Counters = {},              -- key -> lifetime total
		Milestones = {},            -- key -> server time first reached
	},
	-- H4. Verified friends in the same server (Collectors.Social).
	Social = {
		SessionsWithFriends = 0,
		SessionsAlone = 0,
		SessionsUnknown = 0,        -- friend checks failed / pending: not "alone"
		TimeWithFriendsSec = 0,
		TimeAloneSec = 0,
		TimeUnknownSec = 0,
		MaxFriendsInSession = 0,
		RepeatFriendSessions = 0,   -- a friend from one of the last K sessions again
		Recovered = 0,              -- sessions classified after a crash
		RecentFriendHashes = {},    -- K lists of salted 32-bit hashes, no UserIds
		Open = {},                  -- the current session's tallies (crash recovery)
	},
	-- H4. Group status (Collectors.Community). Strings, never booleans:
	-- "true" / "false" / "unknown" / "unavailable" / "off".
	Community = {
		GroupId = 0,                -- the group the fields below describe
		IsGroupMember = "unknown",  -- this session
		LastVerifiedMember = "",    -- last real answer: "true" / "false" / ""
		EverGroupMember = false,
		GroupCheckedAt = 0,
		GroupBonusClaimedAt = 0,    -- first reported claim (the game grants)
		GroupBonusRepeats = 0,      -- further claims with other ids: a double grant
		Favorites = "unavailable",  -- no Roblox API (H0)
	},
}

export type Summary = { [string]: any }

export type MigrateInfo = {
	Created: boolean,      -- nothing usable was saved; a fresh summary
	Changed: boolean,      -- fields were filled or a step ran
	ReadOnly: boolean,     -- saved by a newer schema; do not write
	FromVersion: number?,
	Problems: { string },
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = deepCopy(v)
	end
	return out
end
Schema.DeepCopy = deepCopy

-- Fills every default missing from `target`. Returns true if anything was
-- added. Existing values (including unknown keys) are never touched, and a
-- value of the WRONG type is left alone and reported, not overwritten.
local function fill(target: { [any]: any }, defaults: { [any]: any }, path: string, problems: { string }): boolean
	local changed = false
	for key, default in pairs(defaults) do
		local current = target[key]
		if current == nil then
			target[key] = deepCopy(default)
			changed = true
		elseif type(default) == "table" and type(current) == "table" then
			-- Lists and maps with an empty default are open-ended data; only
			-- recurse into sections with a fixed shape.
			if next(default) ~= nil then
				if fill(current, default, path .. "." .. tostring(key), problems) then
					changed = true
				end
			end
		elseif type(current) ~= type(default) then
			table.insert(problems, string.format("%s.%s is a %s, expected %s - kept as is",
				path, tostring(key), type(current), type(default)))
		end
	end
	return changed
end

function Schema.New(now: number): Summary
	local summary = deepCopy(Schema.DEFAULTS)
	summary.SchemaVersion = Schema.CURRENT
	summary.Meta.CreatedAt = now
	summary.Meta.UpdatedAt = now
	return summary
end

-- Numbered steps, MIGRATIONS[n](summary, now) turns version n into n + 1.
-- None exist yet: v1 is the first schema.
Schema.MIGRATIONS = {} :: { [number]: (Summary, number) -> () }

--[[
	Saved value -> (summary, info). Never throws.
	`options` is for tests: { Migrations = {...}, Current = n } replace
	Schema.MIGRATIONS and Schema.CURRENT.
	The input table is updated in place when it is usable, so a host's
	profile table keeps its identity.
]]
function Schema.Migrate(saved: any, now: number, options: { Migrations: { [number]: (Summary, number) -> () }?, Current: number? }?): (Summary, MigrateInfo)
	local info: MigrateInfo = {
		Created = false,
		Changed = false,
		ReadOnly = false,
		FromVersion = nil,
		Problems = {},
	}
	if type(saved) ~= "table" or next(saved) == nil then
		if saved ~= nil and type(saved) ~= "table" then
			table.insert(info.Problems, string.format("saved summary was a %s - replaced with a fresh one", typeof(saved)))
		end
		info.Created = true
		info.Changed = true
		return Schema.New(now), info
	end

	local version = saved.SchemaVersion
	if type(version) ~= "number" or version < 1 or version % 1 ~= 0 then
		table.insert(info.Problems, string.format("SchemaVersion %s is not a positive whole number - treated as 1",
			tostring(version)))
		version = 1
		saved.SchemaVersion = 1
		info.Changed = true
	end
	info.FromVersion = version

	local current = (options and options.Current) or Schema.CURRENT
	local steps = (options and options.Migrations) or Schema.MIGRATIONS

	if version > current then
		info.ReadOnly = true
		table.insert(info.Problems, string.format(
			"summary has schema %d, newer than this server's %d - read-only for this session",
			version, current))
		return saved, info
	end

	while version < current do
		local step = steps[version]
		if not step then
			table.insert(info.Problems, string.format("no migration from schema %d - read-only for this session", version))
			info.ReadOnly = true
			return saved, info
		end
		local ok, err = pcall(step :: any, saved, now)
		if not ok then
			table.insert(info.Problems, string.format("migration %d -> %d errored: %s - read-only for this session",
				version, version + 1, tostring(err)))
			info.ReadOnly = true
			return saved, info
		end
		version += 1
		saved.SchemaVersion = version
		info.Changed = true
	end

	if fill(saved, Schema.DEFAULTS, "summary", info.Problems) then
		info.Changed = true
	end
	return saved, info
end

--[[
	Records an event id in the summary's ring. Returns false when the id is
	already there (a duplicate), true when it was new and is now recorded.
	limit 0 disables duplicate memory (every id is new).
]]
function Schema.RememberEventId(summary: Summary, eventId: string, limit: number): boolean
	if limit <= 0 then
		return true
	end
	local ring = summary.Meta.RecentEventIds
	if table.find(ring, eventId) then
		return false
	end
	table.insert(ring, eventId)
	while #ring > limit do
		table.remove(ring, 1)
	end
	return true
end

-- JSON byte size, the number DataStore limits are measured in.
function Schema.Size(summary: Summary): number
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, summary)
	return if ok then #encoded else -1
end

return Schema
