--!strict
--[[
	=== Collectors.Social ======================================================

	Verified friend co-play (plan H4 / spec 05-social:01).

	A FRIEND is a verified Roblox friend IN THIS SERVER. Nothing else counts:
	not any co-present player, not an assumed friend.

	---------------------------------------------------------------------------
	HOW TIME IS SPLIT
	---------------------------------------------------------------------------

	At every moment a player is in one of three classes:

	    Friends   at least one present player is a VERIFIED friend
	    Unknown   no verified friend, but at least one present player whose
	              check is pending or failed (could be a friend)
	    Alone     every present player was checked and is not a friend

	The class is re-evaluated whenever it can change - a player joins or
	leaves, a friend check answers - and the elapsed time is credited to the
	class that held BEFORE the change. So "2 minutes with a friend, then 18
	alone" credits exactly 120 s and 1080 s, not a whole session either way.
	Ticks also credit time (crash cost: at most one tick, as in Sessions).

	Unknown is never Alone: an API outage cannot make a player look solo.

	---------------------------------------------------------------------------
	FRIEND CHECKS
	---------------------------------------------------------------------------

	One check per PAIR per server (Player:IsFriendsWithAsync, injectable as
	deps.IsFriendsWith). Result cached for both players. A failed check is
	retried on the next ticks, up to Tunables.FriendCheckAttempts, then stays
	Unknown for the rest of the session. Calls are capped at
	Tunables.FriendChecksPerMinute per server; pairs over the cap wait for
	the next tick (Unknown meanwhile). The docs give no rate limit (H0).

	---------------------------------------------------------------------------
	SESSIONS AND THE REPEAT-FRIEND SIGNAL (plan H12, approved K = 5)
	---------------------------------------------------------------------------

	When a session ends it is classified once:

	    WithFriends  friend time >= Tunables.CoplayMinSeconds
	    Unknown      otherwise, unknown time >= CoplayMinSeconds
	    Alone        otherwise

	REPEAT: a WithFriends session in which a friend from one of the player's
	last K sessions is here again. To know that without storing friend
	UserIds, each session keeps a short list of SALTED, TRUNCATED hashes
	(32-bit FNV-1a of salt .. ":" .. friendUserId, at most
	Tunables.FriendHashesPerSession per session). The salt is the game's
	Experience name plus Tunables.FriendHashSalt.

	PRIVACY NOTE: this is pseudonymisation, not anonymisation. Anyone holding
	the salt can test a guessed UserId against the list. 32 bits over the
	UserId range means several UserIds share each hash, which blurs but does
	not remove that. No friend UserId is stored or sent to a sink.

	A REJOIN (Sessions: within RejoinGraceSeconds) continues the previous
	session: its time is credited, its hashes join the previous session's
	list, and it is NOT classified again and never counts as a repeat.

	A crashed session (no leave) is classified on the next load from the
	saved Social.Open, like Sessions does.
]]

local Social = {}
Social.Name = "Social"

local FRIENDS, UNKNOWN, ALONE = "Friends", "Unknown", "Alone"

--=============================================================================
-- Hash
--=============================================================================

-- 32-bit FNV-1a of a string, as 8 hex digits.
function Social.Fnv1a(text: string): string
	local h = 2166136261
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		-- h * 16777619 mod 2^32. 16777619 = 2^24 + 403; each part stays
		-- below 2^53, so the double arithmetic is exact.
		h = ((h % 256) * 16777216 + h * 403) % 4294967296
	end
	return string.format("%08x", h)
end

-- Salted friend hash. Deterministic across servers and sessions.
function Social.Hash(salt: string, userId: number): string
	return Social.Fnv1a(salt .. ":" .. string.format("%d", userId))
end

--=============================================================================
-- Shared (per server) pair cache and call budget
--=============================================================================

local function shared(ctx: any): any
	local s = ctx.shared.Social
	if not s then
		s = {
			Pairs = {},          -- "lo:hi" -> { Verdict = true|false|nil, Attempts, InFlight }
			Queue = {},          -- pair keys waiting for budget / retry
			WindowStart = -1,
			Used = 0,
		}
		ctx.shared.Social = s
	end
	return s
end

local function pairKey(a: number, b: number): string
	if a < b then
		return string.format("%d:%d", a, b)
	end
	return string.format("%d:%d", b, a)
end

local function verdictOf(ctx: any, a: number, b: number): boolean?
	local entry = shared(ctx).Pairs[pairKey(a, b)]
	return if entry then entry.Verdict else nil
end

--=============================================================================
-- Per-player accounting
--=============================================================================

-- Class + verified friend count from the current roster.
local function classify(ctx: any, state: any): (string, number)
	local friends, unknown = 0, 0
	for _, other in ipairs(ctx.roster()) do
		if other ~= state then
			local v = verdictOf(ctx, state.UserId, other.UserId)
			if v == true then
				friends += 1
			elseif v == nil then
				unknown += 1
			end
		end
	end
	if friends > 0 then
		return FRIENDS, friends
	elseif unknown > 0 then
		return UNKNOWN, 0
	end
	return ALONE, 0
end

local function closeRun(ctx: any, state: any, now: number)
	local sc = state.Scratch
	local run = sc.SocialRun
	if not run then
		return
	end
	sc.SocialRun = nil
	local seconds = now - run.StartedAt
	if seconds <= 0 or run.Class == ALONE then
		return
	end
	sc.SocialRuns = (sc.SocialRuns or 0) + 1
	ctx.emit(state.Player, "friend_coplay_interval", {
		Seconds = seconds,
		Friends = run.MaxFriends,
		Verified = if run.Class == FRIENDS then "true" else "unknown",
	}, string.format("%s:co:%d", state.SessionId, sc.SocialRuns))
end

-- Credits [SocialAt, now] to the class held since SocialAt.
local function settle(ctx: any, state: any, now: number)
	local sc = state.Scratch
	local from = sc.SocialAt
	if from == nil or now <= from then
		return
	end
	sc.SocialAt = now
	if not ctx.writable(state) then
		return
	end
	local social = state.Summary.Social
	local open = social.Open
	local seconds = now - from
	if sc.SocialClass == FRIENDS then
		social.TimeWithFriendsSec += seconds
		open.FriendSec = (open.FriendSec or 0) + seconds
	elseif sc.SocialClass == UNKNOWN then
		social.TimeUnknownSec += seconds
		open.UnknownSec = (open.UnknownSec or 0) + seconds
	else
		social.TimeAloneSec += seconds
		open.AloneSec = (open.AloneSec or 0) + seconds
	end
	state.Dirty = true
end

local function rememberFriends(ctx: any, state: any)
	if not ctx.writable(state) then
		return
	end
	local open = state.Summary.Social.Open
	open.Hashes = open.Hashes or {}
	local limit = ctx.config.Tunables.FriendHashesPerSession
	local salt = ctx.config.Experience .. ctx.config.Tunables.FriendHashSalt
	for _, other in ipairs(ctx.roster()) do
		if other ~= state and verdictOf(ctx, state.UserId, other.UserId) == true then
			local h = Social.Hash(salt, other.UserId)
			if not table.find(open.Hashes, h) and #open.Hashes < limit then
				table.insert(open.Hashes, h)
				state.Dirty = true
			end
		end
	end
end

-- settle, then re-evaluate the class; a class change closes the run.
local function reevaluate(ctx: any, state: any, now: number)
	local sc = state.Scratch
	if sc.SocialAt == nil then
		return -- not started (still loading)
	end
	settle(ctx, state, now)
	local class, friends = classify(ctx, state)
	if friends > 0 then
		rememberFriends(ctx, state)
		if ctx.writable(state) then
			local open = state.Summary.Social.Open
			if friends > (open.MaxFriends or 0) then
				open.MaxFriends = friends
				state.Dirty = true
			end
		end
	end
	local run = sc.SocialRun
	if run and run.Class ~= class then
		closeRun(ctx, state, now)
		run = nil
	end
	if not run then
		sc.SocialRun = { Class = class, StartedAt = now, MaxFriends = friends }
	elseif friends > run.MaxFriends then
		run.MaxFriends = friends
	end
	sc.SocialClass = class
end

local function reevaluateAll(ctx: any, now: number)
	for _, st in ipairs(ctx.roster()) do
		reevaluate(ctx, st, now)
	end
end

--=============================================================================
-- Friend checks
--=============================================================================

local function runCheck(ctx: any, key: string, a: any, b: any)
	local s = shared(ctx)
	local entry = s.Pairs[key]
	entry.InFlight = true
	entry.Attempts += 1
	s.Used += 1
	task.spawn(function()
		local ok, result = pcall(ctx.platform.IsFriendsWith, a.Player, b.UserId)
		entry.InFlight = false
		if s.Pairs[key] ~= entry then
			return -- server state reset (tests)
		end
		if ok and type(result) == "boolean" then
			entry.Verdict = result
		else
			ctx.stats.FriendCheckFailures += 1
			if entry.Attempts < ctx.config.Tunables.FriendCheckAttempts then
				table.insert(s.Queue, key)
			else
				entry.GaveUp = true
			end
		end
		reevaluateAll(ctx, ctx.clock())
	end)
end

local function budgetLeft(ctx: any, now: number): boolean
	local s = shared(ctx)
	if s.WindowStart < 0 or now - s.WindowStart >= 60 then
		s.WindowStart = now
		s.Used = 0
	end
	return s.Used < ctx.config.Tunables.FriendChecksPerMinute
end

local function requestPair(ctx: any, a: any, b: any, now: number)
	if a == b or a.UserId == b.UserId then
		return
	end
	local s = shared(ctx)
	local key = pairKey(a.UserId, b.UserId)
	if s.Pairs[key] then
		return
	end
	s.Pairs[key] = { Verdict = nil, Attempts = 0, InFlight = false, A = a, B = b }
	if budgetLeft(ctx, now) then
		runCheck(ctx, key, a, b)
	else
		table.insert(s.Queue, key)
	end
end

-- Retries and over-budget pairs, once per tick. Pairs whose players left
-- are dropped.
function Social.OnServerTick(ctx: any, now: number)
	local s = shared(ctx)
	if #s.Queue == 0 then
		return
	end
	local present: { [number]: any } = {}
	for _, st in ipairs(ctx.roster()) do
		present[st.UserId] = st
	end
	local waiting = s.Queue
	s.Queue = {}
	for _, key in ipairs(waiting) do
		local entry = s.Pairs[key]
		if entry and entry.Verdict == nil and not entry.InFlight then
			local a, b = present[entry.A.UserId], present[entry.B.UserId]
			if a and b then
				if budgetLeft(ctx, now) then
					runCheck(ctx, key, a, b)
				else
					table.insert(s.Queue, key)
				end
			end
		end
	end
end

--=============================================================================
-- Session classification
--=============================================================================

local function classifyOpen(ctx: any, state: any, open: { [string]: any })
	local social = state.Summary.Social
	local t = ctx.config.Tunables
	local min = t.CoplayMinSeconds
	local hashes: { string } = if type(open.Hashes) == "table" then open.Hashes else {}
	local recent = social.RecentFriendHashes
	if open.Rejoin then
		-- Continues the previous session: merge, never re-classify.
		local last = recent[#recent]
		if last then
			for _, h in ipairs(hashes) do
				if not table.find(last, h) and #last < t.FriendHashesPerSession then
					table.insert(last, h)
				end
			end
		end
		if (open.MaxFriends or 0) > social.MaxFriendsInSession then
			social.MaxFriendsInSession = open.MaxFriends
		end
		return
	end
	if (open.FriendSec or 0) >= min then
		social.SessionsWithFriends += 1
		local repeated = false
		for _, previous in ipairs(recent) do
			for _, h in ipairs(hashes) do
				if table.find(previous, h) then
					repeated = true
					break
				end
			end
			if repeated then
				break
			end
		end
		if repeated then
			social.RepeatFriendSessions += 1
		end
	elseif (open.UnknownSec or 0) >= min then
		social.SessionsUnknown += 1
	else
		social.SessionsAlone += 1
	end
	if (open.MaxFriends or 0) > social.MaxFriendsInSession then
		social.MaxFriendsInSession = open.MaxFriends
	end
	table.insert(recent, table.clone(hashes))
	while #recent > t.FriendHashSessions do
		table.remove(recent, 1)
	end
end

--=============================================================================
-- Collector hooks
--=============================================================================

function Social.OnReady(ctx: any, state: any, now: number, writable: boolean)
	local sc = state.Scratch
	if writable then
		local social = state.Summary.Social
		local open = social.Open
		if type(open.Id) == "string" and open.Id ~= state.SessionId then
			-- Crashed session: classify what was saved, then start fresh.
			classifyOpen(ctx, state, open)
			social.Recovered += 1
		end
		table.clear(open)
		open.Id = state.SessionId
		open.Rejoin = sc.IsRejoin == true or nil
		state.Dirty = true
	end
	-- The time between join and ready is credited with the class at ready.
	sc.SocialAt = state.JoinedAt
	sc.SocialClass = (classify(ctx, state))
	sc.SocialRun = { Class = sc.SocialClass, StartedAt = state.JoinedAt, MaxFriends = 0 }
	for _, other in ipairs(ctx.roster()) do
		requestPair(ctx, state, other, now)
	end
	reevaluate(ctx, state, now)
end

-- Someone joined or left this server.
function Social.OnRoster(ctx: any, state: any, now: number)
	if state.Scratch.SocialAt == nil then
		return
	end
	for _, other in ipairs(ctx.roster()) do
		requestPair(ctx, state, other, now)
	end
	reevaluate(ctx, state, now)
end

function Social.OnTick(ctx: any, state: any, now: number)
	reevaluate(ctx, state, now)
end

function Social.OnLeave(ctx: any, state: any, now: number, writable: boolean)
	if state.Scratch.SocialAt == nil then
		return
	end
	reevaluate(ctx, state, now)
	closeRun(ctx, state, now)
	if writable then
		local social = state.Summary.Social
		classifyOpen(ctx, state, social.Open)
		table.clear(social.Open)
		state.Dirty = true
	end
	state.Scratch.SocialAt = nil
	-- Drop this player's pairs: the cache stays bounded by who is present
	-- and holds no reference to a departed player. A later join checks
	-- again (Roblox caches the answer on its side too).
	local s = shared(ctx)
	local mine = string.format("%d", state.UserId)
	for key in pairs(s.Pairs) do
		local a, b = string.match(key, "^(%d+):(%d+)$")
		if a == mine or b == mine then
			s.Pairs[key] = nil
		end
	end
end

return Social
