--!strict
--[[
	=== Collectors.Sessions ====================================================

	Sessions and daily streaks (plan H2). Updates the Sessions and Streaks
	sections of the summary and reports session_started, session_ended and
	daily_streak_updated. Rules for days and streaks: shared module Days.

	---------------------------------------------------------------------------
	WHAT A SESSION IS
	---------------------------------------------------------------------------

	From the moment HarvestService first sees the player in this server
	(JoinedAt) until they leave or the server closes. Time is measured with
	the server clock only.

	REJOIN: a join within RejoinGraceSeconds (default 60) of the previous
	leave, e.g. a disconnect-reconnect or a teleport between servers, is
	reported with Rejoin = true and does NOT add to TotalSessions (Rejoins
	instead). Its seconds still count: the two intervals do not overlap, so
	nothing is credited twice.

	---------------------------------------------------------------------------
	WHY TIME IS ADDED ON EVERY TICK, AND WHAT A CRASH COSTS
	---------------------------------------------------------------------------

	Every tick (Tunables.SaveIntervalSeconds) adds the seconds since the last
	tick to TotalPlaySeconds and the day tally, and stamps Sessions.Open
	(Id, StartedAt, LastBeat) in the SAME change that is then saved. So:

	  * a server crash loses at most one tick of time (undercount <= one
	    SaveIntervalSeconds), never adds time that was not played;
	  * the next load that finds an Open from another session closes it:
	    LastLeaveAt = LastBeat, LongestSessionSeconds checked, Recovered + 1,
	    and session_ended is reported with Recovered = true. No time is added
	    there because the ticks already added it.

	IDLE TIME is counted as play time in v1 (spec question left open; Roblox
	disconnects idle players after 20 minutes). A game that wants to exclude
	its own idle modes reports them as its own events.

	Collector contract (HarvestService calls these; all receive ctx, state, now):
	  OnReady(ctx, state, now, writable)   summary loaded (or never will be)
	  OnTick(ctx, state, now)              periodic, writable summaries only
	  OnLeave(ctx, state, now, writable)   player left / server closing
]]

local Sessions = {}
Sessions.Name = "Sessions"

local function dayOptions(ctx: any)
	local t = ctx.config.Tunables
	return {
		OffsetHours = t.DayOffsetHours,
		MinSeconds = t.ActiveDayMinSeconds,
		GraceDays = t.StreakGraceDays,
	}
end

-- Adds [scratch.EvalAt, now] to totals and days; stamps the heartbeat.
local function advance(ctx: any, state: any, now: number)
	local scratch = state.Scratch
	local summary = state.Summary
	local from: number = scratch.EvalAt
	if now <= from then
		return
	end
	summary.Sessions.TotalPlaySeconds += now - from
	local credited = ctx.harvest.Days.AddPlay(summary.Streaks, from, now, dayOptions(ctx))
	scratch.EvalAt = now
	summary.Sessions.Open.LastBeat = now
	state.Dirty = true
	local streaks = summary.Streaks
	for _, day in ipairs(credited) do
		ctx.emit(state.Player, "daily_streak_updated", {
			Current = streaks.Current,
			Highest = streaks.Highest,
		}, string.format("streak:%d:%d", state.UserId, day))
	end
end

function Sessions.OnReady(ctx: any, state: any, now: number, writable: boolean)
	local joinedAt: number = state.JoinedAt
	if not writable then
		ctx.emit(state.Player, "session_started", {}, state.SessionId .. ":start")
		return
	end
	local summary = state.Summary
	local s = summary.Sessions

	-- Close a session that never ended (server crash, failed final save).
	local open = s.Open
	if type(open.Id) == "string" and open.Id ~= state.SessionId and type(open.StartedAt) == "number" then
		local lastBeat: number = if type(open.LastBeat) == "number" then open.LastBeat else open.StartedAt
		local seconds = math.max(0, lastBeat - open.StartedAt)
		if seconds > s.LongestSessionSeconds then
			s.LongestSessionSeconds = seconds
		end
		if lastBeat > s.LastLeaveAt then
			s.LastLeaveAt = lastBeat
		end
		s.Recovered += 1
		ctx.emit(state.Player, "session_ended", { Seconds = seconds, Recovered = true }, open.Id .. ":end")
	end

	local rejoin = s.LastLeaveAt > 0 and joinedAt >= s.LastLeaveAt
		and joinedAt - s.LastLeaveAt <= ctx.config.Tunables.RejoinGraceSeconds
	state.Scratch.IsRejoin = rejoin -- read by Social (a rejoin is not a new social session)
	if rejoin then
		s.Rejoins += 1
	else
		s.TotalSessions += 1
	end
	if s.FirstJoinAt == 0 then
		s.FirstJoinAt = joinedAt
	end
	s.LastJoinAt = joinedAt
	table.clear(s.Open)
	s.Open.Id = state.SessionId
	s.Open.StartedAt = joinedAt
	s.Open.LastBeat = joinedAt
	state.Scratch.EvalAt = joinedAt
	state.Dirty = true
	ctx.emit(state.Player, "session_started", { Rejoin = rejoin }, state.SessionId .. ":start")

	-- The load may have taken a while: count the time since the join.
	advance(ctx, state, now)
end

function Sessions.OnTick(ctx: any, state: any, now: number)
	advance(ctx, state, now)
end

function Sessions.OnLeave(ctx: any, state: any, now: number, writable: boolean)
	local seconds = math.max(0, now - (state.JoinedAt :: number))
	if writable then
		advance(ctx, state, now)
		local s = state.Summary.Sessions
		if seconds > s.LongestSessionSeconds then
			s.LongestSessionSeconds = seconds
		end
		s.LastLeaveAt = now
		table.clear(s.Open)
		state.Dirty = true
	end
	ctx.emit(state.Player, "session_ended", { Seconds = seconds }, state.SessionId .. ":end")
end

return Sessions
