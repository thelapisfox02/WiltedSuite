--!strict
--[[
	HarvestAdapter (Roll a Gem) - GAME-SIDE glue, not part of the WiltedHarvest
	package. Lives in the game: ServerScriptService.Telemetry.HarvestAdapter
	(any server path works).

	It only LISTENS to the game's existing after-commit hooks and reports to
	Harvest. It never writes coins, offers, inventory, odds or rebirths. A
	missing or broken Harvest, or a missing hook, never errors into the game:
	every call is pcall'd and the game's callbacks return immediately.

	    local Adapter = require(script.HarvestAdapter)
	    local handle, problems = Adapter.start({
	        Harvest        = HarvestService,   -- nil = adapter idles
	        Ledger         = Ledger,           -- onCommitted(fn(player, receipt))
	        RollService    = RollService,      -- onEvent(fn(player, name, data))
	        FusionService  = FusionService,    -- onEvent(fn(player, name, data))
	        RebirthService = RebirthService,   -- onChanged(fn(player, what)), getCount(player)
	    })

	ONE AUTHORITATIVE SOURCE PER OUTCOME (shapes read from the live code,
	read-only, 2026-10-25):
	    coins earned / spent      Ledger.onCommitted (applied only; receipt.amount is Money)
	    rolls / passes / rare     RollService.onEvent roll_offer_created / roll_passed
	    mineral bought            RollService.onEvent mineral_purchased (coins NOT counted here)
	    fusion                    FusionService.onEvent fusion_completed
	    rebirth                   RebirthService.onChanged(player, "rebirth")
	    sessions, streaks, friends, group, Robux, ads   Harvest itself (automatic)

	BIG NUMBERS. Coin amounts are Money (InfiniteMath: mantissa .first x
	10^.second, or a saved { m, e } / plain number). They are sent to Big
	counters as { Amount = mantissa, Exponent = e }, so no amount is ever
	too large and none is squeezed into a plain number.
]]

local Adapter = {}

local RARE_TIERS = { legendary = true, mythic = true }

type Deps = {
	Harvest: any?,
	Ledger: any?,
	RollService: any?,
	FusionService: any?,
	RebirthService: any?,
	Warn: ((string) -> ())?,
}

local function str(v: any): string?
	if type(v) == "string" and #v > 0 then
		return string.sub(v, 1, 60)
	end
	return nil
end

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Money (InfiniteMath object .first/.second), saved { m, e }, or a plain
-- number -> (mantissa, exponent) with 1 <= |m| < 10, or nil.
local function moneyParts(v: any): (number?, number?)
	local m, e
	if type(v) == "number" then
		m, e = v, 0
	elseif type(v) == "table" then
		m, e = v.first, v.second
		if m == nil and e == nil then
			m, e = v[1], v[2]
		end
	end
	if not finite(m) or not finite(e) or e % 1 ~= 0 then
		return nil, nil
	end
	if m == 0 then
		return 0, 0
	end
	local k = math.floor(math.log10(math.abs(m)))
	m /= 10 ^ k
	e += k
	if math.abs(m) >= 10 then
		m /= 10
		e += 1
	elseif math.abs(m) < 1 then
		m *= 10
		e -= 1
	end
	return m, e
end
Adapter._moneyParts = moneyParts

-- Plain number for an event field (prices), or nil if it does not fit.
local function moneyNumber(v: any): number?
	local m, e = moneyParts(v)
	if m == nil or e == nil then
		return nil
	end
	local n = m * 10 ^ e
	if e < 15 then
		n = math.round(n)
	end
	return if finite(n) then n else nil
end

-- Ledger reason / txId -> which coin counter. Unknown reasons still land in
-- the plain earned / spent totals, so a new game reason is never lost.
local function creditKey(reason: string, txId: string): string
	if string.sub(txId, 1, 8) == "welcome:" or reason == "welcome_back" then
		return "rag.coinsWelcomeBack"
	elseif string.sub(reason, 1, 5) == "cmdr:" then
		return "rag.coinsAdmin"
	elseif string.find(reason, "refund", 1, true) or string.find(reason, "undo", 1, true) then
		return "rag.coinsRefunded"
	end
	return "rag.coinsEarned"
end

local function debitKey(reason: string): string
	if reason == "rebirth" then
		return "rag.coinsResetByRebirth" -- the whole balance is cleared: not spending
	elseif string.sub(reason, 1, 5) == "cmdr:" then
		return "rag.coinsAdmin"
	end
	return "rag.coinsSpent"
end

function Adapter.start(deps: Deps)
	local problems: { string } = {}
	local warnFn = deps.Warn or function(msg: string)
		warn("[HarvestAdapter] " .. msg)
	end
	local harvest = deps.Harvest
	local connections: { any } = {}
	local warnedEmit = false

	-- Never throws, never yields. A refused event is reported once (it is a
	-- config/adapter mismatch worth fixing), then silently.
	local function emit(player: any, eventType: string, payload: any?, eventId: string?)
		if harvest == nil then
			return
		end
		local ok, accepted, reason = pcall(harvest.Emit, player, eventType, payload, eventId)
		if (not ok or accepted == false) and not warnedEmit then
			warnedEmit = true
			warnFn(string.format("%s not recorded: %s", eventType, tostring(if ok then reason else accepted)))
		end
	end

	local function counter(player: any, key: string, amount: number)
		emit(player, "counter", { Key = key, Amount = amount })
	end

	local function bigCounter(player: any, key: string, money: any)
		local m, e = moneyParts(money)
		if m == nil or e == nil or m <= 0 then
			return
		end
		emit(player, "counter", { Key = key, Amount = m, Exponent = e })
	end

	-- Milestones keep their first time in Harvest; sending each once per
	-- server is enough (and keeps a busy Ledger from re-sending it).
	local sent: { [any]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any
	local function milestone(player: any, key: string)
		local mine = sent[player]
		if mine == nil then
			mine = {}
			sent[player] = mine
		end
		if not mine[key] then
			mine[key] = true
			emit(player, "milestone", { Key = key })
		end
	end

	local function hook(source: any, method: string, label: string, fn: any)
		if type(source) ~= "table" or type(source[method]) ~= "function" then
			table.insert(problems, label .. " missing - not tracked")
			return
		end
		local ok, conn = pcall(source[method], function(...)
			-- The game's callback must return at once and never see an error.
			local ok2, err = pcall(fn, ...)
			if not ok2 then
				warnFn(label .. " handler: " .. tostring(err))
			end
		end)
		if ok then
			table.insert(connections, conn)
		else
			table.insert(problems, label .. " could not be connected: " .. tostring(conn))
		end
	end

	-- Coins. Receipt: { ok, status, kind, txId, reason, amount = Money, ... };
	-- the Ledger only calls listeners for "applied".
	hook(deps.Ledger, "onCommitted", "Ledger.onCommitted", function(player: any, receipt: any)
		if type(receipt) ~= "table" or receipt.status ~= "applied" then
			return -- duplicates/conflicts never reach Harvest
		end
		local txId = if type(receipt.txId) == "string" then receipt.txId else ""
		local reason = if type(receipt.reason) == "string" then receipt.reason else ""
		if receipt.kind == "credit" then
			local key = creditKey(reason, txId)
			bigCounter(player, key, receipt.amount)
			if key == "rag.coinsEarned" then
				milestone(player, "rag.firstPayout")
			end
		elseif receipt.kind == "debit" then
			bigCounter(player, debitKey(reason), receipt.amount)
		end
	end)

	-- Rolling. data uses rarityId / mineralId; prices are Money saved form.
	hook(deps.RollService, "onEvent", "RollService.onEvent", function(player: any, name: any, data: any)
		data = if type(data) == "table" then data else {}
		if name == "roll_offer_created" then
			counter(player, "rag.rolls", 1)
			if RARE_TIERS[if type(data.rarityId) == "string" then string.lower(data.rarityId) else ""] then
				counter(player, "rag.rareOffers", 1)
			end
		elseif name == "roll_passed" then
			counter(player, "rag.rollsPassed", 1)
		elseif name == "mineral_purchased" then
			local offerId = str(data.offerId)
			local payload = {
				MineralId = str(data.mineralId),
				Rarity = str(data.rarityId),
				Price = moneyNumber(data.priceCoins),
				Free = if type(data.free) == "boolean" then data.free else nil,
			}
			-- Same id as the Ledger txId ("roll:<offerId>"), so a replay counts once.
			emit(player, "mineral_purchased", payload, if offerId then "roll:" .. offerId else nil)
			milestone(player, "rag.firstMineral")
		end
	end)

	-- Fusion: FusionService.onEvent "fusion_completed" { recipeId, n, rewardMineralId, ... }.
	hook(deps.FusionService, "onEvent", "FusionService.onEvent", function(player: any, name: any, data: any)
		if name ~= "fusion_completed" or type(data) ~= "table" then
			return
		end
		local n = data.n
		if type(n) ~= "number" or n < 1 or n % 1 ~= 0 then
			return
		end
		emit(player, "fusion_completed", {
			RecipeId = str(data.recipeId),
			MineralId = str(data.rewardMineralId),
			FusionNumber = n,
		}, "fuse:" .. string.format("%d", n)) -- the game's own idempotency key
		milestone(player, "rag.firstFusion")
	end)

	-- Rebirth: onChanged(player, "rebirth") fires after the count is saved.
	-- No event id: an admin reset of the count would make "rebirth:<n>" repeat.
	local rebirth = deps.RebirthService
	hook(rebirth, "onChanged", "RebirthService.onChanged", function(player: any, what: any)
		if what ~= "rebirth" then
			return -- "perk" / "admin" are not rebirths
		end
		local count = if type(rebirth) == "table" and type(rebirth.getCount) == "function"
			then rebirth.getCount(player)
			else nil
		emit(player, "rebirth_completed", { Count = if type(count) == "number" then count else nil }, nil)
		milestone(player, "rag.firstRebirth")
	end)

	local handle = {}

	function handle.stop()
		for _, c in ipairs(connections) do
			pcall(function()
				if typeof(c) == "RBXScriptConnection" then
					c:Disconnect()
				elseif type(c) == "function" then
					c()
				elseif type(c) == "table" and type(c.Disconnect) == "function" then
					c:Disconnect()
				end
			end)
		end
		table.clear(connections)
		harvest = nil
	end

	handle.problems = problems
	return handle, problems
end

--[[
	Harvest storage inside the game's DataService profile (key "harvest").
	Pass the result to HarvestService.Start. Returns nil until the profile is
	loaded (Harvest asks again). The table is written by Harvest only.
]]
function Adapter.storage(DataService: any)
	return {
		GetHarvestTable = function(player: any)
			if not DataService:hasProfile(player) then
				return nil
			end
			local data = DataService:getProfile(player).Data
			if type(data.harvest) ~= "table" then
				data.harvest = {}
			end
			return data.harvest
		end,
		EraseHarvestTable = function(userId: number): (boolean, string?)
			local player = game:GetService("Players"):GetPlayerByUserId(userId)
			if player == nil or not DataService:hasProfile(player) then
				return false, "player must be in this server to erase (profile is session-locked)"
			end
			DataService:getProfile(player).Data.harvest = nil
			return true, nil
		end,
	}
end

return Adapter
