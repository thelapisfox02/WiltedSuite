--!strict
--[[
	=== StockClient ===========================================================

	The client half: a local mirror of "how many are left", kept fresh by the
	server rather than polled.

	    StockClient.Start()                     -- returns at once (see below)
	    StockClient.Remaining("GoldenDragon")   -> number?  (nil = unknown yet)
	    StockClient.Changed:Connect(function(skuId, remaining) ... end)

	The original lowercase names (remaining, all, label, start) still work.

	WHY Start NEVER YIELDS

	It waits for the server's StockSync remote in the BACKGROUND, with no
	timeout, warning at 10 s and every 15 s after (decisions 2 and 15). The
	host script carries on at once; the counts arrive when the server is up.
	Before, Start blocked the caller for up to 10 s and then gave up for good.

	WHY PUSH AND NOT POLL

	Measured: a purchase costs ~2 memory-store request units, but every client
	polling its own count every 5 seconds costs 12 units per player per
	minute - at 100 players that is 9% of the whole game's quota spent on a
	number that barely moves. So the server pushes on change and on request,
	and this script never polls.

	A count of nil means "not known yet", which a UI should show as blank
	rather than as zero - displaying "0 LEFT" before the first sync would read
	as sold out.
]]

local WiltedStock = require(script.Parent)

local Core = WiltedStock.GetCore()
local log = Core and Core.Log.new("WiltedStock")

local StockClient = {}

local remaining: { [string]: number } = {}

-- The core's signal: no Instance, arguments by reference, each handler
-- isolated so one erroring listener cannot stop the rest. Without the core
-- it is an inert stand-in, so a host's Connect still does not error.
StockClient.Changed = if Core
	then Core.Signal.new(log)
	else {
		Connect = function()
			return { Disconnect = function() end }
		end,
		Fire = function() end,
	}

-- Items left, or nil when the first sync has not arrived.
function StockClient.Remaining(skuId: string): number?
	return remaining[skuId]
end

-- Everything known, for a shop building itself from data.
function StockClient.All(): { [string]: number }
	return table.clone(remaining)
end

--[[
	"650/1000 LEFT", or nil while unknown.

	Formatting lives here so every shop tile in the game reads the same, and
	so a UI never has to decide what to show before the first sync.
]]
function StockClient.Label(skuId: string): string?
	local left = remaining[skuId]
	if left == nil then
		return nil
	end
	local sku = WiltedStock.FindSku(skuId)
	if not sku then
		return nil
	end
	return string.format("%d/%d LEFT", left, math.floor(tonumber(sku.Total) or 0))
end

local function listen(remote: RemoteEvent)
	remote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		for skuId, value in pairs(payload) do
			if type(skuId) == "string" and type(value) == "number" and value >= 0 then
				if remaining[skuId] ~= value then
					remaining[skuId] = value
					StockClient.Changed:Fire(skuId, value)
				end
			end
		end
	end)

	-- Ask once on start: the server's own push can land before this listener
	-- exists on a fast join.
	remote:FireServer()
end

--[[
	Start listening. Returns StockClient at once, never yields. Without the
	core it warns and returns.
]]
function StockClient.Start()
	if not Core then
		local _, reason = WiltedStock.GetCore()
		warn("[WiltedStock] StockClient.Start: service disabled - " .. tostring(reason))
		return StockClient
	end
	task.spawn(function()
		local remote = Core.Remote.Wait(script.Parent, WiltedStock.REMOTE_SYNC, log)
		if remote then
			listen(remote)
		end
	end)
	return StockClient
end

--=============================================================================
-- ORIGINAL LOWERCASE NAMES (decision 3), kept indefinitely.
--=============================================================================

function StockClient.remaining(...)
	return StockClient.Remaining(...)
end
function StockClient.all(...)
	return StockClient.All(...)
end
function StockClient.label(...)
	return StockClient.Label(...)
end
function StockClient.start(...)
	return StockClient.Start(...)
end

return StockClient
