--!strict
--[[
	=== MonetizationService ===================================================
	The server half. The only thing here that talks to MarketplaceService, and
	the only thing that may grant anything.

	USAGE - the whole wiring, once, from your composition root:

		local Monetization = ServerScriptService.WiltedMonetization
		local MonetizationService = require(Monetization.MonetizationService)
		local GrantingManager    = require(Monetization.GrantingManager)
		local PurchaseRules      = require(Monetization.PurchaseRules)

		-- what rules and grants are allowed to touch:
		MonetizationService.Start({
			Profile = Profile,            -- anything; it is handed back verbatim
			RecordPurchase = ...,         -- REQUIRED for receipts, see below
			HasRecordedPurchase = ...,
			SavePlayer = ...,
		})

	Then a shop click needs no server code at all: the client calls
	MonetizationClient:PromptPurchase("Money1000") and this service checks the
	rules and prompts. Observe it if you want to log:

		MonetizationService.PurchaseRequested:Connect(function(player, productId, allowed, reason) ... end)
		MonetizationService.ProductGranted:Connect(function(player, product, receiptInfo) ... end)

	---------------------------------------------------------------------------
	THE ONE HARD PROBLEM: ProcessReceipt IS NOT CALLED ONCE
	---------------------------------------------------------------------------

	Roblox re-delivers a receipt until the server answers PurchaseGranted. That
	can mean the same purchase arriving again after a rejoin, on a different
	server, or after a DataStore hiccup. Two failure modes bracket us:

	  Answer PurchaseGranted before the value is durably SAVED, and a crash in
	  that window means the Robux are gone and the player has nothing. There is
	  no recovery: Roblox will never send the receipt again.

	  Answer without checking for a replay, and the same purchase grants twice.

	So the order below is not a style choice, it is the only safe one:

	  1. Is this PurchaseId already in the player's SAVED history?
	         yes -> PurchaseGranted immediately. Idempotent replay.
	  2. Re-check the rules. (Minutes may have passed; this is authoritative.)
	  3. Grant AND record the PurchaseId - in the same profile table.
	  4. Force a save, and WAIT for confirmation.
	  5. Only once the id is confirmed saved -> PurchaseGranted.
	     Anything else -> NotProcessedYet, and Roblox retries.

	Step 1 reads the SAVED history, not the live one, because an unsaved record
	is a promise that may evaporate - and treating it as proof is how a replay
	after a crash gets wrongly dismissed.

	Step 4 is why the host must supply SavePlayer and HasRecordedPurchase: only
	the project knows how its persistence confirms a write. Without them the
	service still runs, still prompts, and refuses receipts with a loud reason -
	which is strictly better than silently eating Robux.

	---------------------------------------------------------------------------
	DEPENDENCIES (all optional; each missing one degrades, never errors)
	---------------------------------------------------------------------------

	  RecordPurchase(player, purchaseId, productId) -> boolean, string?
	      Write the purchase id into the player's durable data. REQUIRED for
	      receipts to be accepted at all.

	  HasRecordedPurchase(player, purchaseId) -> boolean
	      Is this id in the player's SAVED data? Used for the replay check and
	      the post-save confirmation. REQUIRED.

	  SavePlayer(player) -> boolean, string?
	      Force a durable save and return once it has completed. REQUIRED.

	  Anything else you put in the table is passed verbatim to every rule and
	  granting function as `context`, so they can reach your services.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PurchaseRules = require(script.Parent.PurchaseRules)
local GrantingManager = require(script.Parent.GrantingManager)

--=============================================================================
-- THE SHARED HALF AND THE CORE (decision 9)
--
-- The shared root is found by its one fixed path, inside pcall. Without it
-- this module still loads: it returns a DISABLED service whose every call
-- refuses with a reason and whose Start wires nothing - so no receipt handler
-- is installed and Roblox keeps every receipt for later. Never an error.
--
-- With the root but no usable core (missing, or older than the root needs),
-- the root has already warned once; Start then refuses the same way.
--=============================================================================

local MonetizationRoot: any = ReplicatedStorage:FindFirstChild("WiltedMonetization")
local Monetization: any = nil
local rootProblem: string? = nil
if not MonetizationRoot or not MonetizationRoot:IsA("ModuleScript") then
	rootProblem = "WiltedMonetization is not installed at ReplicatedStorage.WiltedMonetization"
else
	local okRoot, loaded = pcall(require, MonetizationRoot)
	if okRoot and type(loaded) == "table" then
		Monetization = loaded
	else
		rootProblem = "ReplicatedStorage.WiltedMonetization failed to load: " .. tostring(loaded)
	end
end

if not Monetization then
	warn("[WiltedMonetization] " .. tostring(rootProblem) .. " - MonetizationService disabled")
	local reason = "WiltedMonetization is not installed"
	local function inertSignal()
		return {
			Connect = function()
				return { Disconnect = function() end }
			end,
			Fire = function() end,
		}
	end
	local Disabled: any = {
		Rules = PurchaseRules,
		Granting = GrantingManager,
		Events = {},
		ProductReceiverType = {},
		PurchaseRequested = inertSignal(),
		ReceiptReceived = inertSignal(),
		ProductGranted = inertSignal(),
		GamePassOwned = inertSignal(),
		PurchaseRefused = inertSignal(),
		GiftGranted = inertSignal(),
	}
	function Disabled.Start()
		warn("[WiltedMonetization] Start: service disabled - " .. reason)
		return Disabled
	end
	function Disabled:PromptPlayerPurchase()
		return false, reason
	end
	function Disabled:CheckProductRulesAgainstPlayer()
		return false, reason
	end
	function Disabled:PlayerOwnsGamePass()
		return false
	end
	function Disabled:GetProductByProductId()
		return nil
	end
	function Disabled:GetProductByAssetId()
		return nil
	end
	function Disabled:GetAllProducts()
		return {}
	end
	function Disabled:GetGiftIntent()
		return nil
	end
	function Disabled:SetCustomEvent()
		return function() end
	end
	function Disabled:HasCustomEvent()
		return false
	end
	function Disabled:IsCustomEventDefault()
		return false
	end
	function Disabled._processReceipt()
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return Disabled
end

local MonetizationEnums = require(MonetizationRoot.MonetizationEnums)
local Core: any, coreProblem: string? = Monetization.GetCore()
local log = Core and Core.Log.new("WiltedMonetization")
-- The original wording is the core default for all four lines; only the
-- prefix changes (decision 7).
local life = Core and Core.Lifecycle.new("WiltedMonetization", log)

local MonetizationService = {}

MonetizationService.Rules = PurchaseRules
MonetizationService.Granting = GrantingManager

--=============================================================================
-- SIGNALS
--=============================================================================

--[[
	OBSERVATION ONLY. Fired after the service has already decided.

	  PurchaseRequested(player, productId, allowed, reason)
	  ReceiptReceived(player, product, receiptInfo)
	  ProductGranted(player, product, receiptInfo)      developer products
	  GamePassOwned(player, product, isNewPurchase)     gamepasses
	  PurchaseRefused(player, productId, reason)

	WHY THESE DO NOT DRIVE THE FLOW. An earlier design had the game listen to a
	"prompted" signal and then call CheckRules + Prompt itself. That reads well
	in an example and is a trap: a handler added later that forgets the rule
	check skips every guard silently, and nothing fails loudly. Here the service
	always checks before prompting and always checks again before granting; these
	signals exist for logging, analytics and cosmetic reactions.

	ProductGranted fires only AFTER the save is confirmed, so it is the correct
	place for effects, sounds and banners.

	GamePassOwned fires once per session per owned pass: on join for passes
	already owned (isNewPurchase = false) and on purchase (true). React to a
	purchase with a banner only when isNewPurchase is true.
]]
MonetizationService.PurchaseRequested = Monetization.Signal.new()
MonetizationService.ReceiptReceived = Monetization.Signal.new()
MonetizationService.ProductGranted = Monetization.Signal.new()
MonetizationService.GamePassOwned = Monetization.Signal.new()
MonetizationService.PurchaseRefused = Monetization.Signal.new()
-- (buyer, recipient, product, receiptInfo) - fires only for a gift, after the
-- grant is confirmed saved. ProductGranted still fires too, addressed to the
-- recipient, so existing listeners keep working unchanged.
MonetizationService.GiftGranted = Monetization.Signal.new()

--=============================================================================
-- CUSTOM MONETIZATION EVENTS
--
-- Roblox core analytics records that a purchase happened and its Robux value,
-- but not WHICH of our products it was, nor whether it was bought for the
-- buyer or gifted. These events carry that detail.
--
-- THE PACKAGE SHIPS A WORKING DEFAULT. PurchaseCompleted already logs to
-- AnalyticsService with the sku in custom field 1 and the receiver type in
-- custom field 2, so a host that wires nothing still gets per-product data in
-- Creator Hub. A hook that only works once someone remembers to fill it in is
-- a hook that ships empty.
--
--   SetCustomEvent(event, fn)     replace the default with your own
--   SetCustomEvent(event, nil)    restore the shipped default
--   SetCustomEvent(event, false)  turn it off entirely
--
-- WHY ONE SLOT PER EVENT AND NOT A SIGNAL. The five signals above are
-- observers: any number of listeners, order undefined, harmless. An analytics
-- event is not - it must be emitted exactly ONCE per occurrence. With a
-- signal, two modules both connecting PurchaseCompleted would double-count
-- every sale and nothing would look broken. One slot makes that impossible.
--
-- Handlers run in a pcall AFTER the grant is confirmed saved, so a broken
-- analytics handler can never refuse a receipt or cost a player their Robux.
--
-- USAGE - overriding, from the composition root:
--
--   local Enums = require(Monetization.MonetizationEnums)
--   MonetizationService:SetCustomEvent(Enums.Events.PurchaseCompleted, function(e)
--       myOwnPipeline:send(e.Sku, e.ReceiverType, e.RobuxValue)
--   end)
--
-- THE PAYLOAD (one table, so fields can be added without breaking handlers):
--   Player        the buyer
--   Sku           our stable ProductId  -> custom field 1
--   ReceiverType  ProductReceiverType   -> custom field 2
--   Receiver      who got it; today always the buyer
--   DisplayName   shop-facing name, safe to change, never a key
--   AssetId       the Roblox developer product id
--   RobuxValue    what Roblox says was paid, or 0 if absent
--   PurchaseId    the receipt id; unique per purchase, good for dedupe
--   ReceiptInfo   the raw receipt, for anything not surfaced above
--
-- Sku is our ProductId rather than the asset id: it is stable, readable in a
-- report, and the catalogue forbids renaming it once sold.
--=============================================================================

-- A handler explicitly turned off. Distinct from nil, which means "use the
-- default" - without the sentinel there is no way to say "log nothing".
local DISABLED = newproxy(false)

local defaultEventHandlers: { [string]: (any) -> () } = {}
local customEventHandlers: { [string]: any } = {}

MonetizationService.Events = MonetizationEnums.Events
MonetizationService.ProductReceiverType = MonetizationEnums.ProductReceiverType

--=============================================================================
-- THE SHIPPED DEFAULT
--=============================================================================

-- AnalyticsService only accepts events from a published place, so in Studio
-- every call fails. Warned ONCE rather than per purchase: the failure is a
-- property of the environment, not of any single sale, and a warning on every
-- transaction would bury real problems during a playtest.
local analyticsWarned = false

local function logPurchaseCompleted(event: any)
	local player = event.Player
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end

	local fields = {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = tostring(event.Sku),
		[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = tostring(event.ReceiverType),
	}

	local ok, err = pcall(function()
		AnalyticsService:LogCustomEvent(
			player,
			MonetizationEnums.Events.PurchaseCompleted,
			tonumber(event.RobuxValue) or 0,
			fields)
	end)

	if not ok and not analyticsWarned then
		analyticsWarned = true
		warn(string.format(
			"[WiltedMonetization] AnalyticsService:LogCustomEvent failed (%s). Expected in Studio; "
				.. "this warns once per server. Override with SetCustomEvent to use your own sink.",
			tostring(err)))
	end
end

defaultEventHandlers[MonetizationEnums.Events.PurchaseCompleted] = logPurchaseCompleted

--=============================================================================
-- SETTING / OVERRIDING
--=============================================================================

--[[
	Replace, restore or disable the handler for one custom event. Returns a
	function that restores whatever was in place before, so a test or a
	hot-reload can undo itself.

		handler = function   use it instead of the default
		handler = nil        restore the shipped default
		handler = false      disable; nothing is logged for this event

	Rejects an unknown event name loudly: a typo would otherwise register a
	handler that never fires, which looks exactly like working analytics.
]]
function MonetizationService:SetCustomEvent(eventName: string, handler: any?)
	if not MonetizationEnums.isEvent(eventName) then
		warn(string.format(
			"[WiltedMonetization] SetCustomEvent: %q is not a known event. Known: %s",
			tostring(eventName), table.concat(MonetizationEnums.eventNames(), ", ")))
		return function() end
	end

	local previous = customEventHandlers[eventName]
	local function restore()
		customEventHandlers[eventName] = previous
	end

	-- Explicit restore of the shipped default.
	if handler == nil then
		customEventHandlers[eventName] = nil
		return restore
	end

	-- Explicit opt-out.
	if handler == false then
		customEventHandlers[eventName] = DISABLED
		return restore
	end

	if type(handler) ~= "function" then
		warn(string.format(
			"[WiltedMonetization] SetCustomEvent(%s): handler must be a function, nil to restore "
				.. "the default, or false to disable. Got %s.",
			tostring(eventName), typeof(handler)))
		return function() end
	end

	-- Replacing the DEFAULT is the expected path and says nothing. Replacing a
	-- handler the host already installed is warned, because the usual cause is
	-- two modules both claiming the event - which would double-count sales if
	-- this were a signal.
	if type(previous) == "function" then
		warn(string.format(
			"[WiltedMonetization] SetCustomEvent(%s) called twice - replacing the previous handler.",
			tostring(eventName)))
	end

	customEventHandlers[eventName] = handler
	return restore
end

-- True when SOMETHING will run for this event - default included.
function MonetizationService:HasCustomEvent(eventName: string): boolean
	local override = customEventHandlers[eventName]
	if override == DISABLED then
		return false
	end
	if type(override) == "function" then
		return true
	end
	return defaultEventHandlers[eventName] ~= nil
end

-- True when the shipped default is what will run.
function MonetizationService:IsCustomEventDefault(eventName: string): boolean
	return customEventHandlers[eventName] == nil
		and defaultEventHandlers[eventName] ~= nil
end

--[[
	Call whatever is in place for one event: the override, else the default,
	else nothing. ALWAYS pcall-wrapped - by the time this runs the player has
	paid and the grant is saved, so an analytics error must not propagate into
	the receipt path.
]]
local function fireCustomEvent(eventName: string, payload: any)
	local override = customEventHandlers[eventName]
	if override == DISABLED then
		return
	end

	local handler = if type(override) == "function" then override else defaultEventHandlers[eventName]
	if not handler then
		return
	end

	local ok, err = pcall(handler, payload)
	if not ok then
		warn(string.format("[WiltedMonetization] custom event %s handler errored: %s",
			tostring(eventName), tostring(err)))
	end
end

-- Exposed so the dispatch can be exercised without a real receipt.
MonetizationService._fireCustomEvent = fireCustomEvent

--=============================================================================
-- GIFTING
--
-- THE PROBLEM THIS SOLVES. A Roblox receipt carries PurchaseId, the asset id,
-- and the BUYER - and nothing else. There is no field for "who is this for".
-- So the intent has to be remembered by us, from the moment the prompt opens
-- until the receipt arrives, which may be seconds later or may be after the
-- player has left and rejoined.
--
-- Intent is keyed by buyer + ProductId, because that is all a receipt can be
-- matched on. One pending gift per product per buyer, which is also the only
-- shape a player can express through a shop button.
--
-- EXPIRY IS NOT OPTIONAL. Without it: gift CashHandful to Bob, cancel the
-- prompt, buy CashHandful for yourself tomorrow - and the stale intent sends
-- it to Bob. The TTL plus clearing on a cancelled prompt closes that.
--
-- DURABILITY IS DELEGATED. In memory the intent dies with the server, so a
-- receipt delivered after a rejoin would silently become a self-purchase.
-- A host that cares supplies SaveGiftIntent/LoadGiftIntent/ClearGiftIntent
-- and the intent survives; a host that does not still works, with the
-- failure mode documented rather than hidden.
--=============================================================================

-- How long a prompt may sit open before its gift intent is treated as
-- abandoned. Long enough for a player to read a Robux dialog and think;
-- short enough that it cannot reach a later purchase of the same product.
local GIFT_INTENT_TTL = 10 * 60

-- Host-supplied functions. Declared up here rather than beside the other
-- state because the gift-intent store below reads it: a Lua upvalue must be
-- in scope at the point the closure is CREATED, and declaring it later left
-- these functions indexing a nil that only appeared at runtime.
local dependencies: { [string]: any } = {}

-- buyer UserId -> ProductId -> { UserId, Name, At }
local giftIntents: { [number]: { [string]: any } } = {}

local function intentKey(player: Player): number
	return player.UserId
end

local function setGiftIntent(buyer: Player, productId: string, recipient: Player)
	local perPlayer = giftIntents[intentKey(buyer)]
	if not perPlayer then
		perPlayer = {}
		giftIntents[intentKey(buyer)] = perPlayer
	end
	local record = {
		UserId = recipient.UserId,
		Name = recipient.Name,
		At = os.time(),
	}
	perPlayer[productId] = record

	-- Durable copy, when the host supplies one. Failure is not fatal: the
	-- in-memory intent still covers the overwhelmingly common case where the
	-- receipt arrives on this server moments later.
	local save = dependencies.SaveGiftIntent
	if type(save) == "function" then
		local okSave, err = pcall(save, buyer, productId, record)
		if not okSave then
			warn("[WiltedMonetization] SaveGiftIntent errored: " .. tostring(err))
		end
	end
end

local function clearGiftIntent(buyer: Player, productId: string)
	local perPlayer = giftIntents[intentKey(buyer)]
	if perPlayer then
		perPlayer[productId] = nil
	end
	local clear = dependencies.ClearGiftIntent
	if type(clear) == "function" then
		pcall(clear, buyer, productId)
	end
end

--[[
	The gift intent for this buyer and product, or nil for a normal purchase.

	Reads memory first, then the durable copy - so a receipt that arrives after
	a rejoin still finds its recipient when the host persists intents.

	An expired intent is treated as absent AND cleared, so it cannot attach
	itself to some later purchase of the same product.
]]
local function takeGiftIntent(buyer: Player, productId: string): any
	local perPlayer = giftIntents[intentKey(buyer)]
	local record = perPlayer and perPlayer[productId] or nil

	if not record then
		local load = dependencies.LoadGiftIntent
		if type(load) == "function" then
			local okLoad, loaded = pcall(load, buyer, productId)
			if okLoad and type(loaded) == "table" then
				record = loaded
			end
		end
	end

	if type(record) ~= "table" or type(record.UserId) ~= "number" then
		return nil
	end

	if type(record.At) == "number" and (os.time() - record.At) > GIFT_INTENT_TTL then
		clearGiftIntent(buyer, productId)
		return nil
	end

	return record
end

-- Exposed for tests and for a shop that wants to show "gifting to X".
function MonetizationService:GetGiftIntent(buyer: Player, productId: string): any
	return takeGiftIntent(buyer, productId)
end
--=============================================================================
-- LOOKUP
--=============================================================================

--[[
	One product by our id. WARNS on a miss, because a server-side lookup that
	fails is a bug in the calling code rather than a user action.

	Use Monetization.FindProduct directly for a quiet probe.
]]
function MonetizationService:GetProductByProductId(productId: string)
	local product, reason = Monetization.FindProduct(productId)
	if not product then
		warn("[WiltedMonetization] " .. tostring(reason))
	end
	return product
end

-- One product by the ROBLOX developer product id (what a receipt carries).
function MonetizationService:GetProductByAssetId(assetId: number)
	local product, reason = Monetization.FindProductByAssetId(assetId)
	if not product then
		warn("[WiltedMonetization] " .. tostring(reason))
	end
	return product
end

function MonetizationService:GetAllProducts()
	return Monetization.AllProducts()
end

--=============================================================================
-- RULES
--=============================================================================

--[[
	Evaluate a product's rules for one player. Returns ok, reason.

	Exposed because a shop wants it: greying out a button the player cannot use
	is better than letting them click it and be refused. Cheap and side-effect
	free by contract, so calling it per frame is wasteful but harmless.
]]
function MonetizationService:CheckProductRulesAgainstPlayer(productId: string, player: Player): (boolean, string?)
	local product, reason = Monetization.FindProduct(productId)
	if not product then
		return false, reason
	end
	return PurchaseRules.Check(player, product, self:_context())
end

-- The table handed to every rule and granting function. The host's services
-- plus two fields the service adds for convenience.
function MonetizationService:_context(extra: { [string]: any }?)
	local context = {}
	for key, value in pairs(dependencies) do
		context[key] = value
	end
	if extra then
		for key, value in pairs(extra) do
			context[key] = value
		end
	end
	return context
end

--=============================================================================
-- PROMPTING
--=============================================================================

local function refuse(player: Player, productId: string, reason: string)
	MonetizationService.PurchaseRefused:Fire(player, productId, reason)
	local remote = Monetization.Remote(Monetization.REMOTE_PURCHASE_RESULT)
	if remote then
		remote:FireClient(player, {
			ProductId = productId,
			Granted = false,
			Reason = reason,
		})
	end
end

--[[
	Check the rules and, if they pass, prompt the Roblox purchase UI.

	THE ONE ENTRY POINT for starting a sale. The client's PromptPurchase lands
	here; server code can call it directly too. Handles both purchase kinds:
	developer products open PromptProductPurchase, gamepasses open
	PromptGamePassPurchase - and a gamepass the player already owns is refused
	before any prompt, since Roblox would only show "you already own this".

	The rule check here is a COURTESY to the player - it stops them paying for
	something they cannot receive. For developer products it is NOT the security
	boundary: the check at receipt time is. Gamepasses have no receipt, so for
	them this is the only rule check there is - see the GAMEPASSES section.
]]
function MonetizationService:PromptPlayerPurchase(player: Player, productId: string, recipient: Player?): (boolean, string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "first argument must be a Player"
	end

	-- GIFT TARGET. Validated here, at the only entry point, so nothing
	-- downstream has to defend against a bogus recipient.
	--
	-- Gifting to yourself is normalised to a plain purchase rather than
	-- refused: it is harmless, and refusing would make the shop UI handle a
	-- case that means nothing to a player.
	local isGift = false
	if recipient ~= nil then
		if typeof(recipient) ~= "Instance" or not recipient:IsA("Player") then
			return false, "recipient must be a Player"
		end
		if recipient.Parent == nil then
			refuse(player, tostring(productId), "that player has left")
			return false, "recipient has left"
		end
		isGift = recipient.UserId ~= player.UserId
	end

	-- WHO THE RULES ARE ABOUT. For a gift the question is not "may the buyer
	-- have this" but "may the RECIPIENT receive it" - a tier they already own,
	-- a pass they hold, a unique item already in their inventory. Checking the
	-- buyer would let someone pay for something the recipient cannot be given.
	local beneficiary = if isGift then recipient :: Player else player
	local product, lookupReason = Monetization.FindProduct(productId)
	if not product then
		warn(string.format("[WiltedMonetization] %s tried to buy %s: %s", player.Name, tostring(productId), tostring(lookupReason)))
		refuse(player, tostring(productId), "that product does not exist")
		MonetizationService.PurchaseRequested:Fire(player, productId, false, lookupReason)
		return false, lookupReason
	end

	-- A catalogue entry with no Roblox asset yet. Legal while authoring; it must
	-- refuse clearly rather than erroring deep inside MarketplaceService.
	local purchaseKind = Monetization.PurchaseKindOf(product)
	if type(product.AssetId) ~= "number" then
		local reason = string.format(
			"product %q has no AssetId yet - create the %s in Studio and paste its id into Products",
			productId, purchaseKind == Monetization.PURCHASE_KIND_GAME_PASS and "gamepass" or "developer product")
		warn("[WiltedMonetization] " .. reason)
		refuse(player, productId, "this item is not for sale yet")
		MonetizationService.PurchaseRequested:Fire(player, productId, false, reason)
		return false, reason
	end

	if not Monetization.IsSupportedPurchaseKind(purchaseKind) then
		local reason = string.format("PurchaseKind %q is not supported", tostring(purchaseKind))
		warn("[WiltedMonetization] " .. reason)
		refuse(player, productId, "this item is not for sale yet")
		MonetizationService.PurchaseRequested:Fire(player, productId, false, reason)
		return false, reason
	end

	-- Two products claiming one Roblox id: a receipt could not tell which was
	-- bought, so neither may be sold until the catalogue is fixed. Refusing
	-- here means the player is never charged for the ambiguity.
	if Monetization.IsAssetIdAmbiguous(product) then
		local reason = string.format(
			"product %q shares AssetId %d with another %s - give each its own Roblox product",
			productId, product.AssetId, purchaseKind)
		warn("[WiltedMonetization] " .. reason)
		refuse(player, productId, "this item is temporarily unavailable")
		MonetizationService.PurchaseRequested:Fire(player, productId, false, reason)
		return false, reason
	end

	-- Owning a gamepass twice is impossible, so stop before the rules and the
	-- prompt. Uses the CACHED answer when there is one; see PlayerOwnsGamePass.
	if purchaseKind == Monetization.PURCHASE_KIND_GAME_PASS and self:PlayerOwnsGamePass(beneficiary, productId) then
		local reason = if isGift then "they already own this" else "you already own this"
		refuse(player, productId, reason)
		MonetizationService.PurchaseRequested:Fire(player, productId, false, reason)
		return false, reason
	end

	local allowed, ruleReason = PurchaseRules.Check(beneficiary, product, self:_context({
		Buyer = player,
		Recipient = beneficiary,
		IsGift = isGift,
	}))
	MonetizationService.PurchaseRequested:Fire(player, productId, allowed, ruleReason)
	if not allowed then
		refuse(player, productId, ruleReason or "you cannot buy this right now")
		return false, ruleReason
	end

	-- REMEMBER THE INTENT BEFORE THE PROMPT OPENS. The receipt cannot carry it,
	-- and the player may confirm within a second of this line.
	if isGift then
		setGiftIntent(player, productId, recipient :: Player)
	else
		-- An ordinary purchase must actively CLEAR any stale intent for this
		-- product, or a cancelled gift could capture it.
		clearGiftIntent(player, productId)
	end

	-- pcall: both prompt calls throw on a bad id or a network fault, and a throw
	-- here would otherwise kill the remote handler.
	local ok, err = pcall(function()
		if purchaseKind == Monetization.PURCHASE_KIND_GAME_PASS then
			MarketplaceService:PromptGamePassPurchase(player, product.AssetId)
		else
			MarketplaceService:PromptProductPurchase(player, product.AssetId)
		end
	end)
	if not ok then
		warn(string.format("[WiltedMonetization] prompting %q failed: %s", productId, tostring(err)))
		-- No prompt means no receipt, so the intent would linger until its TTL.
		clearGiftIntent(player, productId)
		refuse(player, productId, "the purchase could not be opened, try again")
		return false, tostring(err)
	end

	return true, nil
end

--=============================================================================
-- RECEIPTS
--=============================================================================

--[[
	The receipt handler. See the header for why the order is what it is.

	EVERY FAILURE PATH RETURNS NotProcessedYet, which asks Roblox to deliver the
	receipt again later. That is always the safe answer: a retry costs a delay,
	while a wrong PurchaseGranted costs the player their Robux permanently.
]]
local function processReceipt(receiptInfo): Enum.ProductPurchaseDecision
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	if type(receiptInfo) ~= "table" then
		warn("[WiltedMonetization] receipt is not a table")
		return NOT_PROCESSED
	end

	local purchaseId = receiptInfo.PurchaseId
	local assetId = receiptInfo.ProductId -- Roblox's field name for the asset id
	local userId = receiptInfo.PlayerId

	if type(purchaseId) ~= "string" or type(assetId) ~= "number" or type(userId) ~= "number" then
		warn("[WiltedMonetization] receipt is missing PurchaseId / ProductId / PlayerId")
		return NOT_PROCESSED
	end

	-- The player must be HERE. A receipt for someone who has left cannot be
	-- granted durably, so it is deferred rather than consumed; Roblox will
	-- deliver it again when they next join.
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return NOT_PROCESSED
	end

	local product = Monetization.FindProductByAssetId(assetId, Monetization.PURCHASE_KIND_DEVELOPER_PRODUCT)
	if not product then
		warn(string.format(
			"[WiltedMonetization] receipt for asset %d has no catalogue entry - NOT consuming it. Add the product and it will be re-delivered.",
			assetId))
		return NOT_PROCESSED
	end

	MonetizationService.ReceiptReceived:Fire(player, product, receiptInfo)

	local hasRecorded = dependencies.HasRecordedPurchase
	local recordPurchase = dependencies.RecordPurchase
	local savePlayer = dependencies.SavePlayer

	-- Without durable bookkeeping we CANNOT answer PurchaseGranted safely, so we
	-- do not. Loud, because this is a wiring mistake that would otherwise only
	-- show up as players losing Robux.
	if type(hasRecorded) ~= "function" or type(recordPurchase) ~= "function" or type(savePlayer) ~= "function" then
		warn("[WiltedMonetization] RecordPurchase / HasRecordedPurchase / SavePlayer were not supplied to Start - "
			.. "refusing the receipt so the purchase is not lost. Wire them and restart.")
		return NOT_PROCESSED
	end

	-- 1. REPLAY CHECK against SAVED data.
	local okAlready, already = pcall(hasRecorded, player, purchaseId)
	if not okAlready then
		warn("[WiltedMonetization] HasRecordedPurchase errored: " .. tostring(already))
		return NOT_PROCESSED
	end
	if already == true then
		-- Already granted and saved in some earlier delivery. Acknowledge so
		-- Roblox stops re-sending, and do NOT grant again.
		return GRANTED
	end

	-- WHO IS THIS FOR? The receipt cannot say, so the intent recorded when the
	-- prompt opened decides. Absent or expired means a normal purchase, which
	-- is the safe default: the buyer paid, so the buyer gets it.
	local giftRecord = takeGiftIntent(player, product.ProductId)
	local recipient = player
	local isGift = false
	if giftRecord then
		local target = Players:GetPlayerByUserId(giftRecord.UserId)
		if target then
			recipient = target
			isGift = true
		else
			-- THE RECIPIENT HAS LEFT. Granting to the buyer instead would be
			-- wrong - they paid to give something away - but refusing the receipt
			-- forever is worse: Roblox would redeliver it at every join and the
			-- player would never get value for their Robux.
			--
			-- NotProcessedYet lets it retry: if the recipient rejoins this server
			-- or the buyer reconnects alongside them, it completes as intended.
			-- The intent is deliberately NOT cleared here.
			warn(string.format(
				"[WiltedMonetization] %s gifted %q to %s who is not here - receipt deferred",
				player.Name, tostring(product.ProductId), tostring(giftRecord.Name)))
			return NOT_PROCESSED
		end
	end

	-- 2. RULES AGAIN - authoritative. The prompt may have been minutes ago.
	-- Checked against the RECIPIENT: they are the one who must be able to
	-- receive it. A gift to someone who already owns the pass is refused here
	-- even though the buyer could have bought it for themselves.
	local allowed, ruleReason = PurchaseRules.Check(recipient, product, MonetizationService:_context({
		ReceiptInfo = receiptInfo,
		Buyer = player,
		Recipient = recipient,
		IsGift = isGift,
	}))
	if not allowed then
		-- The player HAS paid, so this is the uncomfortable case. We consume the
		-- receipt rather than retrying forever: a rule that refuses now will
		-- refuse on every retry, and leaving it unconsumed means Roblox asks
		-- again at every join for ever. Logged at warn level so it can be
		-- refunded by hand.
		warn(string.format(
			"[WiltedMonetization] REFUNDABLE: %s paid for %q but a rule refused at receipt time (%s). Receipt %s consumed.",
			player.Name, tostring(product.ProductId), tostring(ruleReason), purchaseId))
		refuse(player, product.ProductId, ruleReason or "this purchase could not be completed")
		return GRANTED
	end

	-- 3. GRANT, then record the id. Both into the player's durable data.
	-- 3. GRANT TO THE RECIPIENT, record against the BUYER.
	--
	-- The split matters: the goods go to whoever the gift names, but the
	-- idempotency ledger must stay with the person whose PurchaseId it is, or
	-- a replay could grant twice.
	local grantedOk, grantReason = GrantingManager.Grant(recipient, product, MonetizationService:_context({
		ReceiptInfo = receiptInfo,
		Buyer = player,
		Recipient = recipient,
		IsGift = isGift,
		-- Granting functions route money through the host's audited mutation API;
		-- this is the reason string that will appear in its audit log. A gift
		-- names its buyer so the audit trail explains where it came from.
		Reason = if isGift
			then string.format("gift:%s:from:%d", tostring(product.ProductId), player.UserId)
			else "purchase:" .. tostring(product.ProductId),
	}))
	if not grantedOk then
		warn(string.format("[WiltedMonetization] grant failed for %q, receipt kept for retry: %s",
			tostring(product.ProductId), tostring(grantReason)))
		return NOT_PROCESSED
	end

	local recordedOk, recordReason = pcall(recordPurchase, player, purchaseId, product.ProductId)
	if not recordedOk or recordReason == false then
		-- The value is in the live profile but the id is not, so a replay could
		-- double-grant. Refuse to acknowledge: on the retry the replay check will
		-- miss, the grant will run again, and the player may receive it twice -
		-- which is the lesser evil versus answering Granted on data that may not
		-- persist. Loud, because it needs a human eye.
		warn(string.format("[WiltedMonetization] RecordPurchase failed for receipt %s: %s",
			purchaseId, tostring(recordReason)))
		return NOT_PROCESSED
	end

	-- 4. SAVE, and wait for it. The purchase id is passed so a host that can
	-- tell saves apart waits for the one that actually carries it; hosts that
	-- ignore the second argument still work, step 5 is the real check.
	local savedOk, saveReason = pcall(savePlayer, player, purchaseId)
	if not savedOk then
		warn("[WiltedMonetization] SavePlayer errored: " .. tostring(saveReason))
		return NOT_PROCESSED
	end

	-- 5. CONFIRM the id is really in saved data before acknowledging.
	local okConfirm, confirmed = pcall(hasRecorded, player, purchaseId)
	if not okConfirm or confirmed ~= true then
		warn(string.format(
			"[WiltedMonetization] receipt %s granted but could not be confirmed saved - answering NotProcessedYet so it is re-delivered",
			purchaseId))
		return NOT_PROCESSED
	end

	-- Durable. Safe to acknowledge.
	-- DURABLE. The intent has done its job and must not outlive the receipt:
	-- leaving it would redirect the buyer's NEXT purchase of this product.
	clearGiftIntent(player, product.ProductId)

	MonetizationService.ProductGranted:Fire(recipient, product, receiptInfo, {
		Buyer = player,
		Recipient = recipient,
		IsGift = isGift,
	})

	-- A gift has TWO interested parties and the existing signal only addresses
	-- one, so this is its own signal rather than a flag nobody reads.
	if isGift then
		MonetizationService.GiftGranted:Fire(player, recipient, product, receiptInfo)
	end

	-- CUSTOM ANALYTICS. Deliberately here and not earlier: every failure path
	-- above has already returned, so reaching this line means the player paid,
	-- the grant ran, and the purchase id is CONFIRMED in saved data. A handler
	-- can therefore treat the event as final.
	--
	-- Also after the replay check, so a re-delivered receipt that was already
	-- granted returns at step 1 and never reaches here - one event per real
	-- purchase, not one per delivery attempt.
	--
	-- ReceiverType is Self for every purchase today. Gifting will set Gift and
	-- point Receiver at the recipient; the payload shape does not change.
	fireCustomEvent(MonetizationEnums.Events.PurchaseCompleted, {
		Player = player,
		Sku = product.ProductId,
		-- The whole reason custom field 2 exists: core analytics cannot tell a
		-- gift from a self-purchase, and they behave very differently.
		ReceiverType = if isGift
			then MonetizationEnums.ProductReceiverType.Gift
			else MonetizationEnums.ProductReceiverType.Self,
		Receiver = recipient,
		DisplayName = product.DisplayName,
		AssetId = product.AssetId,
		-- Roblox does not guarantee CurrencySpent is present; 0 keeps the
		-- handler arithmetic-safe rather than handing it a nil.
		RobuxValue = tonumber(receiptInfo.CurrencySpent) or 0,
		PurchaseId = purchaseId,
		ReceiptInfo = receiptInfo,
	})

	local remote = Monetization.Remote(Monetization.REMOTE_PURCHASE_RESULT)
	if remote then
		remote:FireClient(player, {
			ProductId = product.ProductId,
			DisplayName = product.DisplayName,
			Granted = true,
			IsGift = isGift,
			RecipientName = if isGift then recipient.Name else nil,
		})
		-- The recipient gets told too, or a gift arrives silently and reads as
		-- a bug. Flagged as Received so a client can word it differently.
		if isGift then
			remote:FireClient(recipient, {
				ProductId = product.ProductId,
				DisplayName = product.DisplayName,
				Granted = true,
				Received = true,
				GifterName = player.Name,
			})
		end
	end

	return GRANTED
end

-- Exposed so the idempotency logic can be exercised with a synthetic receipt.
-- Real receipts cannot be produced in Studio at all, so this is the only way to
-- test the part that must not be wrong.
MonetizationService._processReceipt = processReceipt

--=============================================================================
-- GAMEPASSES
--
-- A gamepass is OWNED, not consumed, and Roblox is the source of truth for who
-- owns what. That changes the whole model compared to developer products:
--
--   * There is NO RECEIPT and no ledger. Ownership can always be re-asked of
--     Roblox, so nothing needs recording to be safe against a crash: a player
--     who bought a pass and lost the server mid-grant simply has it applied on
--     their next join.
--
--   * A gamepass GRANT RUNS ONCE PER SESSION, not once ever - on join for a
--     pass already owned, and at the moment of purchase for a new one. So a
--     gamepass granting function APPLIES A BENEFIT ("this player has 2x
--     speed", "give the VIP tool") and must be safe to run every session.
--     Do NOT point a gamepass at a currency grant: it would pay out on every
--     join. context.IsNewPurchase tells the two cases apart if a grant needs
--     a one-off reaction.
--
--   * Rules can only gate the PROMPT. A pass bought outside this service (the
--     game's store page) arrives already owned and is applied regardless,
--     because the player paid and Roblox will not undo it.
--
--   * A GrantKind is optional. Owning the pass can be the entire benefit, with
--     game code asking PlayerOwnsGamePass wherever it matters.
--=============================================================================

-- Player -> { [productId] = true } for every catalogue gamepass they own.
-- `nil` for a player means "not loaded yet"; an empty table means "owns none".
local ownedGamePassesByPlayer: { [Player]: { [string]: boolean } } = {}

-- How many times to ask Roblox before giving up for this session. The lookup
-- is a web call and fails transiently; a few spaced retries cover a blip
-- without stalling the join.
local OWNERSHIP_LOOKUP_ATTEMPTS = 3
local OWNERSHIP_RETRY_DELAY_SECONDS = 2

-- Every catalogue entry that is a gamepass AND has an asset id to ask about.
local function catalogueGamePasses(): { any }
	local gamePasses = {}
	for _, product in pairs(Monetization.AllProducts()) do
		if type(product) == "table"
			and Monetization.PurchaseKindOf(product) == Monetization.PURCHASE_KIND_GAME_PASS
			and type(product.AssetId) == "number"
		then
			table.insert(gamePasses, product)
		end
	end
	return gamePasses
end

--[[
	Ask Roblox whether this player owns this gamepass, with retries.

	Returns owns, lookupSucceeded. A lookup that fails every attempt reports
	NOT owned for this session and says so loudly - the conservative answer,
	since the next join asks again and the player loses nothing permanent.
]]
local function lookUpGamePassOwnership(player: Player, gamePassAssetId: number): (boolean, boolean)
	for attempt = 1, OWNERSHIP_LOOKUP_ATTEMPTS do
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassAssetId)
		end)
		if ok then
			return owns == true, true
		end
		if attempt < OWNERSHIP_LOOKUP_ATTEMPTS then
			task.wait(OWNERSHIP_RETRY_DELAY_SECONDS)
		else
			warn(string.format("[WiltedMonetization] could not check gamepass %d for %s after %d attempts: %s",
				gamePassAssetId, player.Name, OWNERSHIP_LOOKUP_ATTEMPTS, tostring(owns)))
		end
	end
	return false, false
end

-- Send the player their owned gamepass ids, so MonetizationClient can answer
-- OwnsGamePass locally. A plain list of OUR product ids - nothing to trust.
local function sendGamePassOwnership(player: Player)
	local owned = ownedGamePassesByPlayer[player]
	if not owned then
		return
	end
	local remote = Monetization.Remote(Monetization.REMOTE_GAME_PASS_OWNERSHIP)
	if not remote then
		return
	end
	local ownedProductIds = {}
	for productId in pairs(owned) do
		table.insert(ownedProductIds, productId)
	end
	table.sort(ownedProductIds)
	remote:FireClient(player, ownedProductIds)
end

--[[
	Mark a gamepass as owned for this session and apply its benefit.

	Called on join for passes already owned (isNewPurchase = false) and when a
	purchase completes (isNewPurchase = true). Idempotent per session: a second
	call for the same pass does nothing, so a purchase event racing the join
	lookup cannot apply a benefit twice.
]]
local function applyOwnedGamePass(player: Player, product: any, isNewPurchase: boolean)
	local owned = ownedGamePassesByPlayer[player]
	if not owned then
		-- The player left, or their lookup has not started. A purchase
		-- arriving first creates the set so it is not lost.
		owned = {}
		ownedGamePassesByPlayer[player] = owned
	end
	if owned[product.ProductId] then
		return
	end
	owned[product.ProductId] = true

	-- The benefit, if the pass has one. A failure is reported but does not
	-- un-own the pass: ownership is Roblox's fact, and the next join retries
	-- the grant from scratch.
	if type(product.GrantKind) == "string" then
		local grantedOk, grantReason = GrantingManager.Grant(player, product, MonetizationService:_context({
			IsNewPurchase = isNewPurchase,
			Reason = "gamepass:" .. tostring(product.ProductId),
		}))
		if not grantedOk then
			warn(string.format("[WiltedMonetization] gamepass %q is owned by %s but its grant failed (retried next join): %s",
				tostring(product.ProductId), player.Name, tostring(grantReason)))
		end
	end

	MonetizationService.GamePassOwned:Fire(player, product, isNewPurchase)
	sendGamePassOwnership(player)

	if isNewPurchase then
		local remote = Monetization.Remote(Monetization.REMOTE_PURCHASE_RESULT)
		if remote then
			remote:FireClient(player, {
				ProductId = product.ProductId,
				DisplayName = product.DisplayName,
				Granted = true,
			})
		end
	end
end

-- Look up every catalogue gamepass for a player who just joined, applying the
-- owned ones. Runs in its own task per player: it yields on web calls.
local function loadGamePassOwnership(player: Player)
	if ownedGamePassesByPlayer[player] == nil then
		ownedGamePassesByPlayer[player] = {}
	end
	for _, product in ipairs(catalogueGamePasses()) do
		if not player.Parent then
			return -- left mid-lookup
		end
		local owns = lookUpGamePassOwnership(player, product.AssetId)
		if owns and player.Parent then
			applyOwnedGamePass(player, product, false)
		end
	end
	-- Sent even when nothing is owned, so the client knows the answer is
	-- final rather than still loading.
	sendGamePassOwnership(player)
end

--[[
	The engine's report that a gamepass prompt closed.

	`wasPurchased` is false for a cancel, which is not an error and needs no
	message. A purchase of a pass the catalogue does not know is applied to
	nothing but logged, since it means a pass was sold that this game cannot
	honour.
]]
local function onGamePassPromptFinished(player: Player, gamePassAssetId: number, wasPurchased: boolean)
	if not wasPurchased then
		return
	end
	local product = Monetization.FindProductByAssetId(gamePassAssetId, Monetization.PURCHASE_KIND_GAME_PASS)
	if not product then
		warn(string.format("[WiltedMonetization] %s bought gamepass %d, which is not in the catalogue - nothing applied",
			player.Name, gamePassAssetId))
		return
	end
	applyOwnedGamePass(player, product, true)
end

-- Exposed for the same reason as _processReceipt: no gamepass purchase can be
-- made in Studio, so this is how the purchase path gets exercised.
MonetizationService._onGamePassPromptFinished = onGamePassPromptFinished
MonetizationService._applyOwnedGamePass = applyOwnedGamePass

--[[
	Does this player own this gamepass? Takes OUR product id.

	Answers from the session cache once the join lookup has run. Before that it
	asks Roblox directly, which YIELDS - so do not call it in a tight loop on a
	player who has only just joined.

	False for anything that is not a catalogue gamepass, with a warning, because
	asking about a typo should be loud rather than quietly answering "no".
]]
function MonetizationService:PlayerOwnsGamePass(player: Player, productId: string): boolean
	local product, reason = Monetization.FindProduct(productId)
	if not product then
		warn("[WiltedMonetization] PlayerOwnsGamePass: " .. tostring(reason))
		return false
	end
	if Monetization.PurchaseKindOf(product) ~= Monetization.PURCHASE_KIND_GAME_PASS then
		warn(string.format("[WiltedMonetization] PlayerOwnsGamePass: %q is not a gamepass", productId))
		return false
	end

	local owned = ownedGamePassesByPlayer[player]
	if owned and owned[productId] then
		return true
	end
	if type(product.AssetId) ~= "number" then
		return false
	end
	-- Not cached as owned. Could be "not owned" or "not looked up yet"; the
	-- direct lookup settles it either way, and records a yes.
	local owns = lookUpGamePassOwnership(player, product.AssetId)
	if owns then
		applyOwnedGamePass(player, product, false)
	end
	return owns
end

--=============================================================================
-- START
--=============================================================================

--[[
	Wire the service up. Server only, once.

	Safe to call with no arguments: the service will prompt, evaluate rules and
	report, and will refuse receipts with a clear reason until the persistence
	functions are supplied. That is what makes the subtree droppable - a project
	that has not wired it yet gets warnings, not errors.
]]
function MonetizationService.Start(suppliedDependencies: { [string]: any }?)
	-- No usable core: wire NOTHING. In particular no receipt handler, so
	-- Roblox keeps every receipt until a working server takes it.
	if not Core then
		warn("[WiltedMonetization] Start: service disabled - " .. tostring(coreProblem))
		return MonetizationService
	end
	if not life:GuardServer() then
		return MonetizationService
	end
	if not life:GuardStart() then
		return MonetizationService
	end

	dependencies = suppliedDependencies or {}

	-- Catalogue problems are reported once, at boot, in one place.
	life:ValidateAndLog(Monetization.Validate())

	-- Create the remotes and bind the client request.
	local promptRemote = Monetization.Remote(Monetization.REMOTE_PROMPT_PURCHASE)
	Monetization.Remote(Monetization.REMOTE_PURCHASE_RESULT)
	local ownershipRemote = Monetization.Remote(Monetization.REMOTE_GAME_PASS_OWNERSHIP)

	if promptRemote then
		promptRemote.OnServerEvent:Connect(function(player, productId, recipientUserId)
			-- Shape-checked: a client may send anything at all.
			if type(productId) ~= "string" then
				return
			end

			-- GIFT TARGET AS A USERID, resolved server-side.
			--
			-- Deliberately not a Player instance: an instance reference from a
			-- client is attacker-controlled and may point at anything. A number
			-- can only ever resolve to a player who is actually here, and
			-- GetPlayerByUserId is the one lookup that cannot be spoofed.
			local recipient = nil
			if recipientUserId ~= nil then
				if type(recipientUserId) ~= "number" then
					return
				end
				recipient = Players:GetPlayerByUserId(recipientUserId)
				if not recipient then
					-- Named someone who is not in this server. Refused with a
					-- reason rather than silently becoming a self-purchase, which
					-- would charge them for the wrong thing.
					refuse(player, productId, "that player is not in this server")
					return
				end
			end

			MonetizationService:PromptPlayerPurchase(player, productId, recipient)
		end)
	end

	-- GAMEPASSES. The client asks for its ownership list on start, because the
	-- server's own push after the join lookup can arrive before the client's
	-- listener exists. Answered only once the lookup has run; until then the
	-- push at the end of loadGamePassOwnership covers it.
	if ownershipRemote then
		ownershipRemote.OnServerEvent:Connect(function(player)
			sendGamePassOwnership(player)
		end)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onGamePassPromptFinished)

	-- A CANCELLED PROMPT MUST DROP ITS GIFT INTENT.
	--
	-- Without this the intent lives until its TTL, so: offer a gift, change
	-- your mind, buy the same product for yourself a minute later - and the
	-- stale intent sends YOUR purchase to them. The TTL alone is not enough
	-- because the window is minutes wide and this is the common path.
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, assetId, isPurchased)
		if isPurchased then
			-- The receipt clears it; doing so here would race the grant.
			return
		end
		local buyer = Players:GetPlayerByUserId(userId)
		if not buyer then
			return
		end
		local product = Monetization.FindProductByAssetId(assetId, Monetization.PURCHASE_KIND_DEVELOPER_PRODUCT)
		if product then
			clearGiftIntent(buyer, product.ProductId)
		end
	end)

	-- Leaving the server abandons any open prompt, so the memory copy goes too.
	-- The durable copy (if the host keeps one) deliberately survives: a receipt
	-- can still arrive after a rejoin.
	Players.PlayerRemoving:Connect(function(leaving)
		giftIntents[leaving.UserId] = nil
	end)

	-- Every player here now and every one who joins, once each, each in its
	-- own task (the lookup yields on web calls). Players already present when
	-- Start runs (Studio test servers, a late Start) are included.
	Core.Players.ForEach(loadGamePassOwnership, { log = log })
	Players.PlayerRemoving:Connect(function(player)
		ownedGamePassesByPlayer[player] = nil
	end)

	-- ProcessReceipt is a single-assignment CALLBACK, not an event: whoever
	-- assigns last wins, silently, and only one handler can exist per game.
	--
	-- IT CANNOT BE READ. `MarketplaceService.ProcessReceipt` THROWS on get
	-- ("you can only set the callback value"), so there is no way to detect an
	-- existing handler and warn about it - an earlier version of this code tried
	-- and would have errored during Start in production. Assignment is wrapped
	-- so that a future engine change cannot take the whole boot down with it.
	local assignedOk, assignError = pcall(function()
		MarketplaceService.ProcessReceipt = processReceipt
	end)
	if not assignedOk then
		warn("[WiltedMonetization] could not install the receipt handler, purchases will NOT be granted: "
			.. tostring(assignError))
	end

	-- OPTIONAL Monetization -> Stock glue (decision 24). Attach only subscribes;
	-- the LimitedStock grant and rule appear if and when Stock registers.
	local glueModule = script.Parent:FindFirstChild("StockGlue")
	if glueModule then
		local okGlue, glueError = pcall(function()
			require(glueModule).Attach({ rules = PurchaseRules, granting = GrantingManager })
		end)
		if not okGlue then
			warn("[WiltedMonetization] StockGlue failed to attach: " .. tostring(glueError))
		end
	end

	local productCount = 0
	for _ in pairs(Monetization.AllProducts()) do
		productCount += 1
	end
	life:StartedLine(Monetization.VERSION, "%d product(s), %d rule(s), %d grant kind(s)",
		productCount, #PurchaseRules.RegisteredRules(), #GrantingManager.RegisteredKinds())

	-- Last, so a service that finds Monetization in the directory finds it
	-- started (decision 9 of the deltas table).
	Core.Services.Register("Monetization", MonetizationService)

	return MonetizationService
end

return MonetizationService
