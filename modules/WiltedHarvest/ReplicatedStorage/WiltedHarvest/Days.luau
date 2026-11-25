--!strict
--[[
	=== Days ===================================================================

	Calendar-day arithmetic and the streak/active-day rules, as pure
	functions over plain numbers and summary sections. No clock, no
	Instances; the caller passes `now`. Shared so the server collector, tests
	and any reader (a dashboard, a LiveOps rule) compute the SAME answer.

	---------------------------------------------------------------------------
	THE RULES (plan H7, approved: UTC, active day = 1 minute)
	---------------------------------------------------------------------------

	  DAY       day number = floor((unixSeconds + DayOffsetHours * 3600) / 86400).
	            DayOffsetHours is one fixed number per game (default 0 = UTC),
	            never per player: a player who changes timezone must not gain
	            or lose a streak day.

	  ACTIVE    a day becomes active once the player has played at least
	            ActiveDayMinSeconds (default 60) inside that day, summed over
	            all of that day's sessions. A session across midnight adds its
	            seconds to each day it covers, so it can make both days active
	            and never makes one day count twice.

	  STREAK    crediting day d after last active day L:
	              d == L              nothing (repeat same-day joins)
	              d <= L + 1 + grace  Current + 1
	              otherwise           Current = 1, absence recorded
	            Highest = max(Highest, Current) always, so a broken streak
	            keeps Highest. StreakGraceDays (default 0) allows that many
	            missed days without breaking.

	  BACKWARDS a day earlier than L (server clocks disagreeing) is ignored.

	  Current is only updated when a day is credited, so a player who stopped
	  playing still shows their last Current. Readers that need "streak as of
	  today" use Days.Derive (CurrentAsOfToday).
]]

local Days = {}

Days.SECONDS = 86400
Days.RECENT_BITS = 30
local RECENT_MASK = 2 ^ Days.RECENT_BITS - 1

-- Longest interval walked day by day. Longer gaps (a clock jump) only
-- credit the last MAX_SPAN days, so a bad timestamp cannot spin a loop.
Days.MAX_SPAN = 400

function Days.DayOf(t: number, offsetHours: number): number
	return math.floor((t + offsetHours * 3600) / Days.SECONDS)
end

function Days.DayStart(day: number, offsetHours: number): number
	return day * Days.SECONDS - offsetHours * 3600
end

--[[
	Credits day `day` on a Streaks section. Returns true when it changed
	anything (false for a repeat or a day in the past).
]]
function Days.CreditDay(streaks: { [string]: any }, day: number, graceDays: number): boolean
	local last: number = streaks.LastActiveDay
	if last >= 0 and day <= last then
		return false
	end
	if last < 0 then
		streaks.Current = 1
		streaks.RecentDays = 1
	else
		local gap = day - last
		if gap <= 1 + graceDays then
			streaks.Current += 1
		else
			streaks.Current = 1
		end
		if gap - 1 > streaks.LongestAbsenceDays then
			streaks.LongestAbsenceDays = gap - 1
		end
		if gap >= Days.RECENT_BITS then
			streaks.RecentDays = 1
		else
			streaks.RecentDays = bit32.bor(bit32.band(bit32.lshift(streaks.RecentDays, gap), RECENT_MASK), 1)
		end
	end
	if streaks.Current > streaks.Highest then
		streaks.Highest = streaks.Current
	end
	streaks.LastActiveDay = day
	streaks.DistinctActiveDays += 1
	return true
end

--[[
	Adds the played interval [from, to] to the per-day tally and credits each
	day that reaches minSeconds. Returns the list of newly credited days (in
	order). Pure apart from editing `streaks`.

	PendingDay / PendingSeconds hold the tally of the newest not-yet-active
	day, so two short sessions on one day add up.
]]
function Days.AddPlay(streaks: { [string]: any }, from: number, to: number, options: {
	OffsetHours: number,
	MinSeconds: number,
	GraceDays: number,
}): { number }
	local credited: { number } = {}
	if to < from then
		return credited
	end
	local offset = options.OffsetHours
	local firstDay = Days.DayOf(from, offset)
	local lastDay = Days.DayOf(to, offset)
	if lastDay - firstDay > Days.MAX_SPAN then
		firstDay = lastDay - Days.MAX_SPAN
		from = Days.DayStart(firstDay, offset)
	end
	for day = firstDay, lastDay do
		if streaks.LastActiveDay >= 0 and day <= streaks.LastActiveDay then
			continue
		end
		local dayStart = Days.DayStart(day, offset)
		local overlap = math.min(to, dayStart + Days.SECONDS) - math.max(from, dayStart)
		if overlap < 0 then
			overlap = 0
		end
		if streaks.PendingDay ~= day then
			streaks.PendingDay = day
			streaks.PendingSeconds = 0
		end
		streaks.PendingSeconds += overlap
		if streaks.PendingSeconds >= options.MinSeconds then
			if Days.CreditDay(streaks, day, options.GraceDays) then
				table.insert(credited, day)
			end
			streaks.PendingDay = -1
			streaks.PendingSeconds = 0
		end
	end
	return credited
end

--[[
	Numbers a reader wants that are not stored (they depend on "now"):
	  Today, DaysSinceLastVisit, ActiveDaysLast7, ActiveDaysLast30,
	  CurrentAsOfToday, AverageSessionSeconds
]]
function Days.Derive(summary: { [string]: any }, now: number, offsetHours: number, graceDays: number?): { [string]: any }
	local sessions = summary.Sessions or {}
	local streaks = summary.Streaks or {}
	local today = Days.DayOf(now, offsetHours)
	local last: number = streaks.LastActiveDay or -1
	local out: { [string]: any } = { Today = today }

	local function activeInLast(n: number): number
		if last < 0 then
			return 0
		end
		local count = 0
		local bits: number = streaks.RecentDays or 0
		for k = 0, Days.RECENT_BITS - 1 do
			if today - (last - k) < n and bit32.btest(bits, bit32.lshift(1, k)) then
				count += 1
			end
		end
		return count
	end
	out.ActiveDaysLast7 = activeInLast(7)
	out.ActiveDaysLast30 = activeInLast(30)

	if (sessions.LastLeaveAt or 0) > 0 then
		out.DaysSinceLastVisit = today - Days.DayOf(sessions.LastLeaveAt, offsetHours)
	end
	if last >= 0 and today - last <= 1 + (graceDays or 0) then
		out.CurrentAsOfToday = streaks.Current
	else
		out.CurrentAsOfToday = 0
	end
	local total = sessions.TotalSessions or 0
	if total > 0 then
		out.AverageSessionSeconds = math.floor((sessions.TotalPlaySeconds or 0) / total)
	end
	return out
end

return Days
