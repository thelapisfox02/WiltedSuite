--!strict
--[[
	=== Storage ================================================================

	Where a player's summary is kept between sessions. Two adapters:

	    HostTable (default, H3/Q1)
	        The host hands Harvest ONE TABLE inside its own saved profile and
	        saves it with the rest of the profile. Harvest never opens a
	        DataStore. This is the right choice for any game that already has
	        a profile system (ProfileStore, DataService, ...): one save, one
	        session lock, no extra request budget.

	            HarvestService.Start({
	                GetHarvestTable = function(player)   -- REQUIRED
	                    local profile = Profiles[player]
	                    if not profile then return nil end   -- not loaded yet: asked again
	                    profile.Data.harvest = profile.Data.harvest or {}
	                    return profile.Data.harvest
	                end,
	                MarkDirty = function(player) end,    -- optional
	                EraseHarvestTable = function(userId) -> (boolean, string?),  -- optional
	            })

	        Harvest edits that table IN PLACE. The host must keep returning the
	        SAME table for the whole session (it caches it).

	    OwnStore (fallback)
	        For a game with no profile system. Harvest keeps its own
	        DataStore (Tunables.OwnStoreName, default "WiltedHarvest_v1"), key
	        "u_<UserId>", with a simple lease so two servers never both write
	        one player's summary:

	            HarvestService.Start({ Storage = "OwnStore" })

	---------------------------------------------------------------------------
	ADAPTER CONTRACT (both adapters, and any test double)
	---------------------------------------------------------------------------

	    adapter.Name
	    adapter.Load(player) -> ("ok", table?) | ("retry", reason) | ("fail", reason)
	        "ok" with nil or {} means "nothing saved yet".
	        "retry" means "not available YET" (profile still loading, lease
	        held elsewhere); the service asks again until LoadTimeoutSeconds.
	    adapter.Save(player, summary) -> (boolean, reason?)
	    adapter.Release(player, summary) -> (boolean, reason?)     on leave / shutdown
	    adapter.Erase(userId) -> (boolean, reason?)                 Forget()

	All four may yield. The service always calls them in their own task,
	inside pcall, so a slow or failing store never blocks Emit.

	---------------------------------------------------------------------------
	WHY THE OwnStore LEASE AND NOT JUST UpdateAsync
	---------------------------------------------------------------------------

	The summary is read at join and written for the whole session. Two servers
	holding the same player (a fast rejoin while the old server still saves)
	would each write their own copy, and the last save wins: every event the
	other server recorded is lost. The lease (job id + expiry, set and checked
	inside one UpdateAsync) makes the second server wait until the first has
	released or its lease has expired (OwnStoreLeaseSeconds, renewed by every
	save). A server that loses its lease stops writing.

	Harvest data is analytics, not money: when the lease cannot be had in
	LoadTimeoutSeconds the player is simply not recorded this session.
]]

local DataStoreService = game:GetService("DataStoreService")

local Storage = {}

export type Status = "ok" | "retry" | "fail"

export type Adapter = {
	Name: string,
	Load: (Player) -> (Status, any),
	Save: (Player, { [string]: any }) -> (boolean, string?),
	Release: (Player, { [string]: any }) -> (boolean, string?),
	Erase: (number) -> (boolean, string?),
}

--=============================================================================
-- HostTable
--=============================================================================

function Storage.HostTable(deps: { [string]: any }): (Adapter?, string?)
	local getTable = deps.GetHarvestTable
	if type(getTable) ~= "function" then
		return nil, "GetHarvestTable is missing - summaries are not loaded or saved (events still reach the sinks)"
	end
	local markDirty = deps.MarkDirty
	local erase = deps.EraseHarvestTable

	local function dirty(player: Player): (boolean, string?)
		if type(markDirty) ~= "function" then
			return true, nil
		end
		local ok, err = pcall(markDirty, player)
		if not ok then
			return false, "MarkDirty errored: " .. tostring(err)
		end
		return true, nil
	end

	local adapter: Adapter = {
		Name = "HostTable",
		Load = function(player: Player): (Status, any)
			local ok, result = pcall(getTable, player)
			if not ok then
				return "fail", "GetHarvestTable errored: " .. tostring(result)
			end
			if result == nil then
				return "retry", "GetHarvestTable returned nil (profile not loaded yet)"
			end
			if type(result) ~= "table" then
				return "fail", string.format("GetHarvestTable must return a table, got %s", typeof(result))
			end
			return "ok", result
		end,
		Save = function(player: Player, _summary): (boolean, string?)
			return dirty(player)
		end,
		Release = function(player: Player, _summary): (boolean, string?)
			return dirty(player)
		end,
		Erase = function(userId: number): (boolean, string?)
			if type(erase) ~= "function" then
				return false, "EraseHarvestTable was not supplied - the host must delete the harvest table from its own save"
			end
			local ok, result, reason = pcall(erase, userId)
			if not ok then
				return false, "EraseHarvestTable errored: " .. tostring(result)
			end
			if result ~= true then
				return false, tostring(reason or "EraseHarvestTable did not return true")
			end
			return true, nil
		end,
	}
	return adapter, nil
end

--=============================================================================
-- OwnStore
--
-- options = { storeName, leaseSeconds, jobId, clock, retry, log,
--             dataStoreService (injectable) }
--=============================================================================

function Storage.OwnStore(options: { [string]: any }): (Adapter?, string?)
	local service = options.dataStoreService or DataStoreService
	local okStore, store = pcall(function()
		return service:GetDataStore(options.storeName)
	end)
	if not okStore then
		return nil, "OwnStore could not open DataStore " .. tostring(options.storeName) .. ": " .. tostring(store)
	end
	local jobId: string = options.jobId
	local lease: number = options.leaseSeconds
	local clock: () -> number = options.clock
	local retry = options.retry

	local function key(userId: number): string
		return "u_" .. tostring(userId)
	end

	local function heldElsewhere(record: any, now: number): boolean
		return type(record) == "table" and record.LeaseJob ~= nil and record.LeaseJob ~= jobId
			and type(record.LeaseUntil) == "number" and record.LeaseUntil > now
	end

	local function write(player: Player, summary: { [string]: any }, releasing: boolean): (boolean, string?)
		local lost = false
		local ok, result = retry("OwnStore save " .. key(player.UserId), function()
			return store:UpdateAsync(key(player.UserId), function(old): any
				local now = clock()
				if heldElsewhere(old, now) then
					lost = true
					return nil
				end
				return {
					Summary = summary,
					LeaseJob = if releasing then nil else jobId,
					LeaseUntil = if releasing then 0 else now + lease,
				}
			end)
		end)
		if lost then
			return false, "lease is held by another server - not saved"
		end
		if not ok then
			return false, tostring(result)
		end
		return true, nil
	end

	local adapter: Adapter = {
		Name = "OwnStore",
		Load = function(player: Player): (Status, any)
			local held = false
			local ok, result = retry("OwnStore load " .. key(player.UserId), function()
				return store:UpdateAsync(key(player.UserId), function(old)
					local now = clock()
					if heldElsewhere(old, now) then
						held = true
						return nil
					end
					local record = if type(old) == "table" then old else {}
					record.LeaseJob = jobId
					record.LeaseUntil = now + lease
					return record
				end)
			end)
			if held then
				return "retry", "lease is held by another server"
			end
			if not ok then
				return "retry", tostring(result)
			end
			local record = result
			return "ok", if type(record) == "table" then record.Summary else nil
		end,
		Save = function(player: Player, summary): (boolean, string?)
			return write(player, summary, false)
		end,
		Release = function(player: Player, summary): (boolean, string?)
			return write(player, summary, true)
		end,
		Erase = function(userId: number): (boolean, string?)
			local ok, result = retry("OwnStore erase " .. key(userId), function()
				return store:RemoveAsync(key(userId))
			end)
			if not ok then
				return false, tostring(result)
			end
			return true, nil
		end,
	}
	return adapter, nil
end

return Storage
