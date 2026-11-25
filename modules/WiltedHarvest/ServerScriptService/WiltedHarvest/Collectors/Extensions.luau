--!strict
--[[
	=== Collectors.Extensions ==================================================

	The game's own numbers (plan H2/H3), declared in its config and reported
	through two built-in events:

	    WiltedConfig.Harvest = {
	        Counters   = { ["myGame.clicks"]   = { Description = "..." } },
	        Milestones = { ["myGame.firstBoss"] = { Description = "..." } },
	    }

	    HarvestService.Emit(player, "counter",   { Key = "myGame.clicks", Amount = 1 })
	    HarvestService.Emit(player, "milestone", { Key = "myGame.firstBoss" }, "firstBoss:" .. player.UserId)

	Summary: Extensions.Counters[key] = lifetime total,
	         Extensions.Milestones[key] = server time first reached.

	UNDECLARED KEYS ARE REFUSED AT Emit, with a reason. That is what keeps a
	typo ("myGame.clikcs") from becoming a second, silent counter, and what
	keeps one game's numbers out of another's config: Harvest itself never
	names any key.

	A milestone is recorded once; a repeat is ignored without error (use an
	event id when the same milestone can be emitted from two places).

	SIZE. A plain counter takes amounts up to +-2^53 (~9.007e15) per event,
	the largest range where whole numbers stay exact; its total is a plain
	number (exact up to 2^53, about 15 significant digits after that).
	A counter declared { Big = true } has NO upper limit: an event may send
	{ Key, Amount = mantissa, Exponent = e } (value = Amount x 10^e), and the
	total is saved in BigCount form (a plain number below 1e15, otherwise
	{ mantissa, exponent }) - the same form many big-number money modules
	save. Exponent is refused on a plain counter, so a big value never gets
	squeezed into one silently. Read totals with Harvest.BigCount.

	Counters do not go below 0 unless the game declares { AllowNegative =
	true } - a refund path may need that, a click counter never does.

	HIGH-VOLUME COUNTERS (plan H8). A counter emitted WITHOUT an event id is
	summed in memory and sent as one event per key every save interval and
	on leave, so a counter bumped many times a second costs one event per
	interval. A crash loses at most one interval of those amounts. A counter
	emitted WITH an event id is a one-off: it goes straight in and dedupes.
]]

local Extensions = {}
Extensions.Name = "Extensions"

function Extensions.OnEvent(ctx: any, state: any, envelope: any, writable: boolean)
	if not writable then
		return
	end
	local eventType = envelope.EventType
	local payload = envelope.Payload
	local ext = state.Summary.Extensions
	if eventType == "counter" then
		local key: string = payload.Key
		local declared = ctx.config.Counters[key]
		if not declared then
			return -- refused at Emit; a stale queued event after a config change lands here
		end
		local BigCount = ctx.harvest.BigCount
		local current = ext.Counters[key] or 0
		local value: any
		if declared.Big or type(current) == "table" then
			value = BigCount.add(current, { payload.Amount, payload.Exponent or 0 })
			if BigCount.sign(value) < 0 and not declared.AllowNegative then
				value = 0
			end
		else
			value = current + payload.Amount
			if value < 0 and not declared.AllowNegative then
				value = 0
			end
		end
		ext.Counters[key] = value
		state.Dirty = true
	elseif eventType == "milestone" then
		local key: string = payload.Key
		if not ctx.config.Milestones[key] then
			return
		end
		if ext.Milestones[key] == nil then
			ext.Milestones[key] = envelope.ServerTime
			state.Dirty = true
		end
	end
end

--[[
	Extra Emit checks for counter / milestone (called by the service before
	queueing). (true) or (false, reason).
]]
Extensions.MAX_PLAIN = 2 ^ 53 -- largest exact whole number (~9.007e15)

function Extensions.Check(config: any, eventType: string, payload: any): (boolean, string?)
	if eventType == "counter" then
		local declared = config.Counters[payload.Key]
		if not declared then
			return false, string.format("counter %q is not declared in WiltedConfig.Harvest.Counters", tostring(payload.Key))
		end
		local amount = payload.Amount
		local exponent = payload.Exponent
		if declared.Big then
			if exponent ~= nil and (exponent % 1 ~= 0 or math.abs(exponent) > 1e9) then
				return false, "counter Exponent must be a whole number"
			end
		else
			if exponent ~= nil then
				return false, string.format("counter %q is not Big: declare { Big = true } to send an Exponent", payload.Key)
			end
			if amount > Extensions.MAX_PLAIN or amount < -Extensions.MAX_PLAIN then
				return false, string.format("counter Amount must be within +-2^53 (declare %q { Big = true } for larger values)", payload.Key)
			end
		end
		if amount < 0 and not declared.AllowNegative then
			return false, string.format("counter %q does not allow negative amounts (declare AllowNegative = true)", payload.Key)
		end
	elseif eventType == "milestone" then
		if not config.Milestones[payload.Key] then
			return false, string.format("milestone %q is not declared in WiltedConfig.Harvest.Milestones", tostring(payload.Key))
		end
	end
	return true, nil
end

return Extensions
