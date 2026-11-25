--!strict
--[[
	=== Sinks ==================================================================

	Where accepted events go after they have been counted. A sink is a named
	function sink(envelope, player?) that must not yield for long and must
	never be trusted: every call runs in its own task inside pcall, so a
	broken or slow sink cannot stop the service or another sink.

	Built-in sinks, enabled by name in WiltedConfig.Harvest.Sinks:

	    AnalyticsService   Roblox analytics (server, published games only)
	    Log                one console line per event (Studio debugging)
	    Memory             keeps envelopes in a list (tests, debug commands)

	Custom sinks: HarvestService.RegisterSink(name, fn) - e.g. an HTTP export.

	---------------------------------------------------------------------------
	WHY THE AnalyticsService SINK USES A FIXED LIST OF EVENT NAMES (H19)
	---------------------------------------------------------------------------

	Roblox allows 100 custom event names per experience but 8,000 custom field
	values. A game's own event types therefore all go out under ONE name,
	"Harvest_Game", with the type in custom field 1 and up to two declared
	fields in fields 2 and 3. Harvest's built-in events use 12 more names.
	Total 13, whatever the game declares.

	WHY IT HAS A BUDGET

	The documented limit is 120 + 20 x players requests per minute, shared
	with everything else the game logs. The sink spends at most
	AnalyticsBudgetShare of it and counts what it skipped (Stats), rather
	than letting Roblox drop the game's own events.

	WHY IT IS OFF IN STUDIO

	Roblox: "Events can't be sent from the client or Studio." The sink says so
	once and does nothing, unless a test injects a fake AnalyticsService.
]]

local RunService = game:GetService("RunService")

local Sinks = {}

export type Envelope = {
	EventId: string,
	EventType: string,
	SchemaVersion: number,
	Experience: string,
	SessionId: string?,
	ServerTime: number,
	ConfigVersion: string?,
	UserId: number,
	Payload: { [string]: any },
}

-- Built-in event type -> (Roblox event name, value field, custom field 1).
local ANALYTICS_NAMES: { [string]: { any } } = {
	session_started = { "Harvest_Session", nil, nil },
	session_ended = { "Harvest_SessionSeconds", "Seconds", nil },
	daily_streak_updated = { "Harvest_Streak", "Current", nil },
	group_checked = { "Harvest_Group", nil, "IsMember" },
	friend_coplay_interval = { "Harvest_Coplay", "Seconds", "Verified" },
	purchase_verified = { "Harvest_Purchase", "Robux", "ProductId" },
	gamepass_purchased = { "Harvest_GamePass", "EstimatedRobux", "ProductId" },
	ad_shown = { "Harvest_AdShown", nil, "Result" },
	ad_reward_granted = { "Harvest_AdReward", nil, "Placement" },
	group_bonus_claimed = { "Harvest_GroupBonus", nil, nil },
	counter = { "Harvest_Counter", "Amount", "Key" },
	milestone = { "Harvest_Milestone", nil, "Key" },
}
Sinks.ANALYTICS_NAMES = ANALYTICS_NAMES
Sinks.ANALYTICS_GAME_EVENT = "Harvest_Game"

local function fieldKey(index: number): string
	return string.format("CustomField0%d", index)
end

--[[
	Envelope -> (eventName, value, customFields) or nil when the event is not
	sent to analytics. Pure; exposed for tests.
]]
function Sinks.MapForAnalytics(envelope: Envelope, config: any): (string?, number?, { [string]: string }?)
	local payload = envelope.Payload
	local fields: { [string]: string } = {}
	local builtin = ANALYTICS_NAMES[envelope.EventType]
	if envelope.EventType == "counter" and payload.Exponent ~= nil then
		-- Big counter amount: analytics takes a plain number; past ~1.8e308
		-- it cannot hold one, so the value is capped and the exact size kept
		-- in a field.
		local v = payload.Amount * 10 ^ payload.Exponent
		if v ~= v or v == math.huge or v == -math.huge then
			v = if payload.Amount < 0 then -1.7976931348623157e308 else 1.7976931348623157e308
		end
		fields[fieldKey(1)] = tostring(payload.Key)
		fields[fieldKey(2)] = string.format("%.4fe%d", payload.Amount, payload.Exponent)
		return builtin[1], v, fields
	end
	if builtin then
		local valueField, field1 = builtin[2], builtin[3]
		local value = if valueField then tonumber(payload[valueField]) else nil
		if field1 and payload[field1] ~= nil then
			fields[fieldKey(1)] = tostring(payload[field1])
		end
		return builtin[1], value or 1, fields
	end
	local declared = config.Events[envelope.EventType]
	if not declared or declared.Analytics == false then
		return nil, nil, nil
	end
	local analytics = declared.Analytics or {}
	fields[fieldKey(1)] = envelope.EventType
	for index, field in ipairs(analytics.Fields or {}) do
		if payload[field] ~= nil then
			fields[fieldKey(index + 1)] = tostring(payload[field])
		end
	end
	local value = if analytics.Value then tonumber(payload[analytics.Value]) else nil
	return Sinks.ANALYTICS_GAME_EVENT, value or 1, fields
end

--[[
	Builds the built-in sinks a config asks for.
	ctx = { config, log, stats, clock, players, analytics (injectable) }
	Returns { [name] = fn } and the Memory list (nil when Memory is off).
]]
function Sinks.Build(ctx: any): ({ [string]: (Envelope, Player?) -> () }, { Envelope }?)
	local built: { [string]: (Envelope, Player?) -> () } = {}
	local memory: { Envelope }? = nil

	for _, name in ipairs(ctx.config.Sinks) do
		if name == "Memory" then
			local list: { Envelope } = {}
			memory = list
			built.Memory = function(envelope: Envelope)
				table.insert(list, envelope)
			end
		elseif name == "Log" then
			built.Log = function(envelope: Envelope)
				ctx.log:Info("event %s %s user %d", envelope.EventType, envelope.EventId, envelope.UserId)
			end
		elseif name == "AnalyticsService" then
			local service = ctx.analytics
			if service == nil then
				if RunService:IsStudio() then
					ctx.log:Info("AnalyticsService sink inactive in Studio (Roblox only accepts events from published games)")
					continue
				end
				service = game:GetService("AnalyticsService")
			end
			local windowStart = ctx.clock()
			local used = 0
			built.AnalyticsService = function(envelope: Envelope, player: Player?)
				if player == nil then
					ctx.stats.AnalyticsSkipped += 1
					return
				end
				local eventName, value, fields = Sinks.MapForAnalytics(envelope, ctx.config)
				if not eventName then
					return
				end
				local now = ctx.clock()
				if now - windowStart >= 60 then
					windowStart = now
					used = 0
				end
				local limit = math.floor((120 + 20 * #ctx.players:GetPlayers()) * ctx.config.Tunables.AnalyticsBudgetShare)
				if used >= limit then
					ctx.stats.AnalyticsSkipped += 1
					return
				end
				used += 1
				service:LogCustomEvent(player, eventName, value, fields)
			end
		end
	end
	return built, memory
end

return Sinks
