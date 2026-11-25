--!strict
--[[
	=== WiltedHarvest (shared root) ===========================================

	Per-player engagement, spend and social SUMMARIES plus a typed EVENT
	stream, for any game. Harvest watches; it never grants, prices, randomises
	or edits game state. A game that loses Harvest keeps working.

	This module is the shared half: version, enums, summary schema, config
	normalisation and event validation. It holds no per-player state and
	creates no Instances. The server half is ServerScriptService.WiltedHarvest.
	There is no client half: everything Harvest records is decided on the
	server.

	---------------------------------------------------------------------------
	DROP-IN CONTRACT
	---------------------------------------------------------------------------

	  1. SIBLINGS ARE RESOLVED RELATIVELY (script / script.Parent). The only
	     fixed paths are ReplicatedStorage.WiltedCore (shared plumbing) and
	     ReplicatedStorage.WiltedConfig.Harvest (this game's data).
	  2. NOTHING HOST-SPECIFIC IS REQUIRED. Storage, clock and the game's own
	     event names arrive through HarvestService.Start(dependencies) and the
	     config. Missing pieces degrade to a refusal with a reason.
	  3. MISSING CONTENT IS A WARNING, NOT A CRASH. No config: one warning and
	     the built-in events still work.
	  4. A MISSING OR TOO-OLD CORE DISABLES, IT DOES NOT CRASH.
	  5. GAME-BLIND. No game words in this package. A game's own numbers are
	     DECLARED in its config (Events, Counters, Milestones), namespaced by
	     the game ("myGame.clicks"), and sent through Emit.

	---------------------------------------------------------------------------
	CONFIG: ReplicatedStorage.WiltedConfig.Harvest (data only)
	---------------------------------------------------------------------------

	    return {
	        Experience = "my_game",          -- REQUIRED. [%w_.-], 1-50 chars.
	                                         --   Tags every event. No place ids.
	        ConfigVersion = "balance-v3",    -- optional; default game.PlaceVersion
	        Sinks = { "AnalyticsService" },  -- built-in sinks to enable:
	                                         --   "AnalyticsService", "Log", "Memory"
	        Group = { Mode = "GameOwner" },  -- or { Mode = "Id", GroupId = 123 }
	                                         --   or { Mode = "Off" }   (used from H4)
	        Events = {                       -- the game's own event types
	            thing_bought = {
	                Fields = { ItemId = "string", Price = "number" },
	                Analytics = { Value = "Price", Fields = { "ItemId" } },
	                                         -- or Analytics = false to keep it
	                                         -- out of Roblox analytics
	            },
	        },
	        Counters = { ["myGame.clicks"] = { Description = "..." } },   -- H3
	                                         --   { AllowNegative = true } for refunds
	                                         --   { Big = true } no size limit (BigCount)
	        Milestones = { ["myGame.firstBoss"] = { Description = "..." } }, -- H3
	        Tunables = { SaveIntervalSeconds = 30 },  -- see DEFAULT_TUNABLES
	    }

	Event and field names are a contract with saved data and dashboards:
	NEVER rename one that has been live; add a new one instead.

	---------------------------------------------------------------------------
	WHY THE CONFIG IS NORMALISED HERE AND NOT LOADED INTO A MODULE GLOBAL
	---------------------------------------------------------------------------

	HarvestService.Start may be handed a config table directly (a host that
	builds config in code, and every test). Keeping this module stateless means
	two services in one test session can run different configs without one
	leaking into the other.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(script.HarvestEnums)
local Schema = require(script.Schema)
local Days = require(script.Days)
local BigCount = require(script.BigCount)

local Harvest = {}

-- Bumped when the contract between this root and the server half, or the
-- event envelope, changes. Pre-1.0 while the v1 phases are being built.
Harvest.VERSION = "0.6.0"

-- Oldest WiltedCore this package works with.
Harvest.MIN_CORE_VERSION = "1.1.0"

-- Version of the EVENT ENVELOPE (not the summary; that is Schema.CURRENT).
Harvest.EVENT_SCHEMA_VERSION = 1

Harvest.Enums = Enums
Harvest.Schema = Schema
Harvest.Days = Days
Harvest.BigCount = BigCount

--=============================================================================
-- THE CORE
--
-- Found by its one fixed path, inside pcall, once per Luau VM.
--=============================================================================

local Core: any = nil
local disabledReason: string? = nil

do
	local coreModule = ReplicatedStorage:FindFirstChild("WiltedCore")
	local ok, result = false, nil
	if coreModule and coreModule:IsA("ModuleScript") then
		ok, result = pcall(require, coreModule)
	end
	if not ok or type(result) ~= "table" then
		disabledReason = "WiltedCore is not installed"
		warn("[WiltedHarvest] WiltedCore not found at ReplicatedStorage.WiltedCore - service disabled")
	elseif not result.Version.Check("WiltedHarvest", Harvest.MIN_CORE_VERSION, result.Log.new("WiltedHarvest")) then
		disabledReason = string.format("WiltedCore %s is older than the %s WiltedHarvest needs",
			tostring(result.VERSION), Harvest.MIN_CORE_VERSION)
	else
		Core = result
	end
end

-- The core, or nil and the reason the package is disabled.
function Harvest.GetCore(): (any, string?)
	return Core, disabledReason
end

local log = Core and Core.Log.new("WiltedHarvest")

--=============================================================================
-- CONFIG
--=============================================================================

Harvest.DEFAULT_TUNABLES = {
	-- How often dirty summaries are handed to storage.
	SaveIntervalSeconds = 30,
	-- Events waiting to be processed, all players together. Overflow drops
	-- the OLDEST event and is counted (Stats().Dropped).
	QueueLimit = 1000,
	-- Event ids remembered per player in SAVED data, for duplicate detection
	-- across servers and rejoins. Bounded so a profile cannot grow forever.
	RecentEventIds = 64,
	-- Events held per player while their stored summary is still loading.
	PendingPerPlayer = 200,
	-- How long to wait for storage to produce a player's summary before
	-- giving up for this session (the summary then runs read-only).
	LoadTimeoutSeconds = 30,
	LoadRetrySeconds = 1,
	-- Share of Roblox's AnalyticsService rate limit (120 + 20 x players per
	-- minute) Harvest may use, leaving the rest for the game itself.
	AnalyticsBudgetShare = 0.5,
	-- OwnStore only: DataStore name and lease length.
	OwnStoreName = "WiltedHarvest_v1",
	OwnStoreLeaseSeconds = 300,
	-- Days and streaks (see Days). One fixed offset per game, never per
	-- player. 0 = UTC.
	DayOffsetHours = 0,
	-- Seconds played inside one day before it counts as active.
	ActiveDayMinSeconds = 60,
	-- Missed days allowed without breaking a streak.
	StreakGraceDays = 0,
	-- A join this soon after the previous leave is a rejoin, not a new
	-- session (disconnect-reconnect, server hop).
	RejoinGraceSeconds = 60,
	-- Distinct spend categories kept per player; more go to "_other".
	SpendCategoryLimit = 20,
	-- Friends (Collectors.Social). Attempts per pair before "unknown" for
	-- the session; checks per minute per server (no documented limit).
	FriendCheckAttempts = 3,
	FriendChecksPerMinute = 60,
	-- Seconds with a verified friend for a session to count "with friends"
	-- (same for "unknown").
	CoplayMinSeconds = 60,
	-- Repeat-friend signal: last K sessions, at most N hashes per session,
	-- extra salt mixed with the Experience name (plan H12).
	FriendHashSessions = 5,
	FriendHashesPerSession = 10,
	FriendHashSalt = "",
	-- Group (Collectors.Community): attempts before "unknown" for the session.
	GroupCheckAttempts = 3,
	-- Ads (Collectors.Ads): distinct placements kept; more go to "_other".
	AdPlacementLimit = 10,
}

local TUNABLE_RANGES: { [string]: { number } } = {
	SaveIntervalSeconds = { 1, 3600 },
	QueueLimit = { 10, 100000 },
	RecentEventIds = { 0, 1000 },
	PendingPerPlayer = { 0, 10000 },
	LoadTimeoutSeconds = { 0, 600 },
	LoadRetrySeconds = { 0, 60 },
	AnalyticsBudgetShare = { 0, 1 },
	OwnStoreLeaseSeconds = { 30, 3600 },
	DayOffsetHours = { -12, 14 },
	ActiveDayMinSeconds = { 0, 86400 },
	StreakGraceDays = { 0, 7 },
	RejoinGraceSeconds = { 0, 3600 },
	SpendCategoryLimit = { 0, 100 },
	FriendCheckAttempts = { 1, 10 },
	FriendChecksPerMinute = { 1, 600 },
	CoplayMinSeconds = { 0, 3600 },
	FriendHashSessions = { 0, 20 },
	FriendHashesPerSession = { 0, 50 },
	GroupCheckAttempts = { 1, 10 },
	AdPlacementLimit = { 0, 50 },
}

local GROUP_MODES = { GameOwner = true, Id = true, Off = true }
local FIELD_TYPES = { string = true, number = true, boolean = true }
local BUILTIN_SINKS = { AnalyticsService = true, Log = true, Memory = true }

export type Config = {
	Experience: string,
	ConfigVersion: string?,
	Sinks: { string },
	Group: { Mode: string, GroupId: number? },
	Events: { [string]: any },
	Counters: { [string]: any },
	Milestones: { [string]: any },
	Tunables: { [string]: any },
}

-- The game's raw config table from WiltedConfig.Harvest ({} with one warning
-- when absent; nothing at all when the core is missing).
function Harvest.LoadConfig(): { [any]: any }
	if not Core then
		return {}
	end
	return Core.Config.Load("Harvest", log)
end

local function isName(value: any, maxLength: number): boolean
	return type(value) == "string" and #value >= 1 and #value <= maxLength
		and string.match(value, "^[%a][%w_%.%-]*$") ~= nil
end

--[[
	Group setting -> ({ Mode, GroupId? }, problem?). Never throws, never
	guesses: an unusable value turns group features OFF (or keeps the
	GameOwner default for an unknown Mode), with the reason.
	Used by the config and by HarvestService.SetGroup.
]]
function Harvest.NormaliseGroup(g: any): ({ Mode: string, GroupId: number? }, string?)
	if type(g) ~= "table" or not GROUP_MODES[g.Mode] then
		return { Mode = "GameOwner", GroupId = nil }, "Group.Mode must be \"GameOwner\", \"Id\" or \"Off\" - using GameOwner"
	elseif g.Mode == "Id" then
		if type(g.GroupId) == "number" and g.GroupId > 0 and g.GroupId % 1 == 0 then
			return { Mode = "Id", GroupId = g.GroupId }, nil
		end
		return { Mode = "Off", GroupId = nil }, "Group.Mode \"Id\" needs a positive whole GroupId - group features off"
	end
	return { Mode = g.Mode, GroupId = nil }, nil
end

--[[
	Raw config -> (normalised config, problems). Never throws. Every problem
	is a developer-facing string; the normalised config is always usable
	(bad parts are dropped, defaults filled in).
]]
function Harvest.NormaliseConfig(raw: any): (Config, { string })
	local problems: { string } = {}
	local source: { [any]: any } = if type(raw) == "table" then raw else {}
	if raw ~= nil and type(raw) ~= "table" then
		table.insert(problems, string.format("config must be a table, got %s", typeof(raw)))
	end

	local experience = source.Experience
	if experience == nil then
		table.insert(problems, "Experience is missing - events are tagged \"unnamed\"")
		experience = "unnamed"
	elseif not (type(experience) == "string" and #experience <= 50 and string.match(experience, "^[%w_%.%-]+$")) then
		table.insert(problems, string.format("Experience %s must be 1-50 letters, digits, _ . -", tostring(experience)))
		experience = "unnamed"
	end

	local configVersion = source.ConfigVersion
	if configVersion ~= nil and not (type(configVersion) == "string" and #configVersion <= 50) then
		table.insert(problems, "ConfigVersion must be a string of at most 50 characters - ignored")
		configVersion = nil
	end

	local sinks: { string } = {}
	if source.Sinks == nil then
		sinks = { "AnalyticsService" }
	elseif type(source.Sinks) ~= "table" then
		table.insert(problems, "Sinks must be a list of sink names - using { \"AnalyticsService\" }")
		sinks = { "AnalyticsService" }
	else
		for _, name in ipairs(source.Sinks) do
			if type(name) == "string" and BUILTIN_SINKS[name] then
				if not table.find(sinks, name) then
					table.insert(sinks, name)
				end
			else
				table.insert(problems, string.format("Sinks: %s is not a built-in sink (AnalyticsService, Log, Memory); register custom sinks with RegisterSink",
					tostring(name)))
			end
		end
	end

	local group = { Mode = "GameOwner", GroupId = nil :: number? }
	if source.Group ~= nil then
		local problem
		group, problem = Harvest.NormaliseGroup(source.Group)
		if problem then
			table.insert(problems, problem)
		end
	end

	local events: { [string]: any } = {}
	if source.Events ~= nil and type(source.Events) ~= "table" then
		table.insert(problems, "Events must be a table keyed by event name - ignored")
	elseif type(source.Events) == "table" then
		for name, spec in pairs(source.Events) do
			if not isName(name, 40) then
				table.insert(problems, string.format("Events: %s is not a valid event name (letter first, then letters, digits, _ . -, max 40)",
					tostring(name)))
				continue
			end
			if Enums.IsBuiltinEvent(name) then
				table.insert(problems, string.format("Events: %q is a built-in Harvest event and cannot be redeclared", name))
				continue
			end
			if type(spec) ~= "table" then
				table.insert(problems, string.format("Events.%s must be a table", name))
				continue
			end
			local fields: { [string]: string }? = nil
			if spec.Fields ~= nil then
				if type(spec.Fields) ~= "table" then
					table.insert(problems, string.format("Events.%s.Fields must be a table of field = type", name))
					continue
				end
				fields = {}
				local bad = false
				for field, kind in pairs(spec.Fields) do
					if not isName(field, 40) or not FIELD_TYPES[kind] then
						table.insert(problems, string.format("Events.%s.Fields.%s must be \"string\", \"number\" or \"boolean\"",
							name, tostring(field)))
						bad = true
					else
						(fields :: any)[field] = kind
					end
				end
				if bad then
					continue
				end
			end
			local analytics: any = {}
			if spec.Analytics == false then
				analytics = false
			elseif spec.Analytics ~= nil then
				local a = spec.Analytics
				if type(a) ~= "table" then
					table.insert(problems, string.format("Events.%s.Analytics must be a table or false", name))
					continue
				end
				if a.Value ~= nil and (fields == nil or (fields :: any)[a.Value] ~= "number") then
					table.insert(problems, string.format("Events.%s.Analytics.Value must name a declared number field", name))
					continue
				end
				local list = {}
				if a.Fields ~= nil then
					if type(a.Fields) ~= "table" or #a.Fields > 2 then
						table.insert(problems, string.format(
							"Events.%s.Analytics.Fields: at most 2 declared fields (Roblox allows 3 custom fields; Harvest uses the first for the event name)",
							name))
						continue
					end
					local bad = false
					for _, f in ipairs(a.Fields) do
						if fields == nil or (fields :: any)[f] == nil then
							table.insert(problems, string.format("Events.%s.Analytics.Fields: %s is not a declared field", name, tostring(f)))
							bad = true
						else
							table.insert(list, f)
						end
					end
					if bad then
						continue
					end
				end
				analytics = { Value = a.Value, Fields = list }
			end
			events[name] = { Fields = fields, Analytics = analytics }
		end
	end

	local function namespaced(section: string): { [string]: any }
		local out: { [string]: any } = {}
		local value = source[section]
		if value == nil then
			return out
		end
		if type(value) ~= "table" then
			table.insert(problems, string.format("%s must be a table keyed by \"game.name\" - ignored", section))
			return out
		end
		for key, spec in pairs(value) do
			if not (isName(key, 60) and string.find(key, ".", 1, true)) then
				table.insert(problems, string.format("%s: %s must be namespaced like \"myGame.name\" (max 60)", section, tostring(key)))
			elseif type(spec) ~= "table" then
				table.insert(problems, string.format("%s.%s must be a table (use {} for no options)", section, key))
			else
				out[key] = {
					Description = if type(spec.Description) == "string" then spec.Description else nil,
					AllowNegative = if section == "Counters" and spec.AllowNegative == true then true else nil,
					Big = if section == "Counters" and spec.Big == true then true else nil,
				}
			end
		end
		return out
	end

	local tunables = table.clone(Harvest.DEFAULT_TUNABLES)
	if source.Tunables ~= nil then
		if type(source.Tunables) ~= "table" then
			table.insert(problems, "Tunables must be a table - defaults used")
		else
			for key, value in pairs(source.Tunables) do
				local default = (Harvest.DEFAULT_TUNABLES :: any)[key]
				local range = TUNABLE_RANGES[key]
				if default == nil then
					table.insert(problems, string.format("Tunables.%s is not a known tunable - ignored", tostring(key)))
				elseif type(value) ~= type(default) then
					table.insert(problems, string.format("Tunables.%s must be a %s - default kept", key, type(default)))
				elseif range and (value < range[1] or value > range[2]) then
					table.insert(problems, string.format("Tunables.%s = %s is outside %s..%s - default kept",
						key, tostring(value), tostring(range[1]), tostring(range[2])))
				elseif key == "OwnStoreName" and not isName(value, 50) then
					table.insert(problems, "Tunables.OwnStoreName must be a valid name (max 50) - default kept")
				else
					(tunables :: any)[key] = value
				end
			end
		end
	end

	local config: Config = {
		Experience = experience,
		ConfigVersion = configVersion,
		Sinks = sinks,
		Group = group,
		Events = events,
		Counters = namespaced("Counters"),
		Milestones = namespaced("Milestones"),
		Tunables = tunables,
	}
	return config, problems
end

--=============================================================================
-- EVENT VALIDATION
--
-- Runs inside Emit, on the caller's thread, so it must be cheap and must
-- never yield. A refused event returns a developer-facing reason.
--=============================================================================

local MAX_PAYLOAD_KEYS = 24
local MAX_STRING = 200

local function checkValue(eventType: string, field: string, value: any, kind: string?): string?
	local t = type(value)
	if kind ~= nil and t ~= kind then
		return string.format("%s.%s must be a %s, got %s", eventType, field, kind, t)
	end
	if t == "string" then
		if #value > MAX_STRING then
			return string.format("%s.%s is longer than %d characters", eventType, field, MAX_STRING)
		end
	elseif t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return string.format("%s.%s must be a finite number", eventType, field)
		end
	elseif t ~= "boolean" then
		return string.format("%s.%s must be a string, number or boolean, got %s", eventType, field, t)
	end
	return nil
end

--[[
	(true) or (false, reason). `config` is a normalised config. Built-in
	events are checked against their spec in HarvestEnums; declared events
	against their declared Fields (undeclared fields are refused, which is how
	a typo in a field name surfaces). Internal events are allowed here; the
	server refuses them from hosts separately.
]]
function Harvest.ValidateEvent(config: Config, eventType: any, payload: any): (boolean, string?)
	if type(eventType) ~= "string" then
		return false, string.format("event type must be a string, got %s", typeof(eventType))
	end
	if payload ~= nil and type(payload) ~= "table" then
		return false, string.format("%s payload must be a table or nil, got %s", eventType, typeof(payload))
	end
	local data: { [any]: any } = payload or {}

	local spec: { [string]: string }? = nil
	local strict = false
	local builtin = Enums.PayloadSpec[eventType]
	if builtin then
		spec = builtin
		strict = true
	else
		local declared = config.Events[eventType]
		if not declared then
			return false, string.format("unknown event type %q (declare it in WiltedConfig.Harvest.Events)", eventType)
		end
		spec = declared.Fields
		strict = spec ~= nil
	end

	local count = 0
	for key, value in pairs(data) do
		count += 1
		if count > MAX_PAYLOAD_KEYS then
			return false, string.format("%s payload has more than %d fields", eventType, MAX_PAYLOAD_KEYS)
		end
		if type(key) ~= "string" or #key > 40 then
			return false, string.format("%s payload keys must be strings of at most 40 characters", eventType)
		end
		local kind: string? = nil
		if strict and spec then
			local declared = spec[key]
			if declared == nil then
				return false, string.format("%s has no field %q", eventType, key)
			end
			kind = string.gsub(declared, "%?$", "")
		end
		local problem = checkValue(eventType, key, value, kind)
		if problem then
			return false, problem
		end
	end

	if strict and spec and builtin then
		for field, declared in pairs(spec) do
			if string.sub(declared, -1) ~= "?" and data[field] == nil then
				return false, string.format("%s needs field %q", eventType, field)
			end
		end
	end
	return true, nil
end

return Harvest
