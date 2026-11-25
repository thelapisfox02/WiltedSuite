--!strict
--[[
	=== Products ==============================================================
	THE CATALOGUE. This is the file you edit to add something buyable.

	DATA ONLY. No functions, no requires, no game logic - so it can be read on
	the client (for prices and names) without dragging server code with it, and
	so adding a product is never a code change.

	---------------------------------------------------------------------------
	ADDING A PRODUCT - the whole procedure
	---------------------------------------------------------------------------

	1. In Studio: Game Settings -> Monetization -> Developer Products (or
	   Passes) -> Create. Note the id it gives you.
	2. Add an entry below. The KEY and the ProductId field must be identical.
	3. Pick a GrantKind that GrantingManager already knows
	   (GrantingManager.RegisteredKinds() lists them), or register a new one.
	4. List any Rules by NAME. PurchaseRules.RegisteredRules() lists them.

	That is all. Nothing else needs touching - the service validates the
	catalogue at boot and reports mistakes in the console.

	---------------------------------------------------------------------------
	THE FIELDS
	---------------------------------------------------------------------------

	  ProductId     [string]  REQUIRED. Our own stable id, identical to the key.
	                          Receipts, logs and the audit trail all use this,
	                          so NEVER renumber or rename it once it has sold -
	                          purchase history is keyed on it.

	  DisplayName   [string]  REQUIRED. What a human sees. Safe to change.

	  AssetId       [number?] The Roblox developer product id, or the gamepass id
	                          for a GamePass. nil is LEGAL and
	                          means "the Roblox asset does not exist yet": the
	                          product is listed, validates, and refuses to prompt
	                          with a clear reason. That is deliberate, so a
	                          catalogue can be written before the assets exist.

	  PurchaseKind  [string?] "DeveloperProduct" (default) - CONSUMED. Bought
	                          any number of times; each purchase is granted
	                          exactly once.
	                          "GamePass" - OWNED. Bought once, forever. Its
	                          grant runs ONCE PER SESSION (on join, and at
	                          purchase), so it must apply a benefit - never pay
	                          out currency, which would repeat every join.

	  GrantKind     [string]  Which granting function runs on success. REQUIRED
	                          for developer products. OPTIONAL for gamepasses:
	                          ownership alone can be the benefit, read by game
	                          code through PlayerOwnsGamePass.

	  GrantData     [table?]  Arguments for that granting function. Its shape is
	                          the granting function's business, not the service's.

	  Rules         [table?]  Rule NAMES, checked in order. Any failure blocks
	                          the purchase. Empty or nil means "always allowed".

	  Description   [string?] Free text for a shop tooltip. Unused by the service.

	---------------------------------------------------------------------------
	WHY RULES ARE NAMES AND NOT FUNCTIONS
	---------------------------------------------------------------------------

	A rule usually needs a real service - the player's profile, an inventory, a
	world lookup - and this file must stay data-only and client-safe, so it
	cannot require any of them. So rules live in PurchaseRules, which is given
	whatever it needs at Start, and the catalogue refers to them by name. The
	tradeoff is one indirection; what it buys is a catalogue that a human or an
	AI can edit with no risk of importing a cycle or leaking server code to the
	client.
]]

local Products = {}

--[[
	========================= EXAMPLE, NOT LIVE ==============================
	Kept commented out on purpose: an entry with a placeholder AssetId would
	validate, appear in shops and then refuse at the till, which reads as a bug.
	Copy it, fill in a real id, uncomment.

	Products["SteelPickaxe"] = {
		ProductId   = "SteelPickaxe",
		DisplayName = "Steel Pickaxe",
		AssetId     = nil,

		GrantKind   = "Item",
		GrantData   = { ItemId = "SteelPickaxe", ItemAmount = 1 },

		-- Refuses if the player already owns it, so a unique item cannot be
		-- bought twice. The player is never charged: the rule runs before the
		-- prompt as well as at receipt time.
		Rules       = { "NotAlreadyOwned" },
	}

	Products["100Gold"] = {
		ProductId   = "100Gold",
		DisplayName = "100 Gold",
		AssetId     = nil,

		GrantKind   = "Currency",
		GrantData   = { Stat = "money", Amount = 100 },

		-- No rules: currency is repeatable and always grantable.
	}

	Products["VIP"] = {
		ProductId    = "VIP",
		DisplayName  = "VIP",
		AssetId      = 11223344,      -- the GAMEPASS id
		PurchaseKind = "GamePass",

		-- No GrantKind: game code asks
		--   MonetizationService:PlayerOwnsGamePass(player, "VIP")
		-- wherever the perk matters. Add a GrantKind only for a benefit that
		-- must be applied (a tool, an attribute) - and it runs every session.
	}
	===========================================================================
]]

--=============================================================================
-- LIVE PRODUCTS
--=============================================================================

-- FIRST REAL PRODUCT - fill in AssetId once the developer product exists.
--
-- Left in with AssetId = nil deliberately: it proves the whole path end to end
-- (catalogue -> validate -> rules -> prompt refusal -> grant) while the Roblox
-- asset is still being created, and the refusal message names exactly what is
-- missing. Set the number and it goes live with no other edit.
Products["Money1000"] = {
	ProductId   = "Money1000",
	DisplayName = "1,000 Coins",
	AssetId     = nil, -- <- paste your developer product id here

	GrantKind   = "Currency",
	GrantData   = { Stat = "money", Amount = 1000 },

	Description = "A pile of coins, straight to your balance.",
}

-- FIRST GAMEPASS - fill in AssetId once the pass exists.
--
-- Ownership-only (no GrantKind) on purpose, so it can be bought and tested
-- before deciding what it should DO: buy it, then /products shows it and
-- MonetizationService:PlayerOwnsGamePass(player, "TestGamePass") is true.
Products["TestGamePass"] = {
	ProductId    = "TestGamePass",
	DisplayName  = "Test Gamepass",
	AssetId      = nil, -- <- paste your GAMEPASS id here
	PurchaseKind = "GamePass",

	Description = "Ownership-only test pass.",
}

--=============================================================================
-- JETPACK BOOST PASSES (the two buttons above the fuel bar)
--
-- Ownership-only gamepasses: no GrantKind. Bootstrap stamps the attribute
-- Owns_<ProductId> on the player when ownership is known (join or purchase),
-- and FlyService reads that to double the tank / the flight speed.
-- TO GO LIVE: create both passes in Creator Hub and paste their ids below.
-- Until then AssetId = nil and the buttons refuse with a clear message.
--=============================================================================
Products["Stamina2x"] = {
	ProductId    = "Stamina2x",
	DisplayName  = "x2 Fuel",
	AssetId      = nil,
	PurchaseKind = "GamePass",

	Description = "Doubles your jetpack fuel.",
}

Products["Speed2x"] = {
	ProductId    = "Speed2x",
	DisplayName  = "x2 Speed",
	AssetId      = nil,
	PurchaseKind = "GamePass",

	Description = "Doubles your jetpack flight speed.",
}

--=============================================================================
-- PERMANENT MULTIPLIER PASSES (the two Shop "PASSES" banners)
--
-- Ownership-only, like the jetpack pair above: no GrantKind, because owning
-- the pass IS the benefit. Bootstrap stamps Owns_<ProductId> when ownership
-- is known, and the consumer reads that attribute.
--
-- These are PERMANENT, which is why they are passes and not Boost products:
-- the banners say "x2 Cash" with no duration, and a timed product behind that
-- copy would read as a broken promise once it expired.
--
-- They stack with the TIMED boosts of the same stat by design - a 2x pass and
-- a 2x Cash (15 min) product together give 4x, which is the documented
-- multiplicative rule in BoostService.
--=============================================================================
Products["Cash2x"] = {
	ProductId    = "Cash2x",
	DisplayName  = "x2 Cash",
	AssetId      = nil,
	PurchaseKind = "GamePass",

	Description = "Permanently doubles all cash you earn.",
}

Products["Growth2x"] = {
	ProductId    = "Growth2x",
	DisplayName  = "x2 Growth",
	AssetId      = nil,
	PurchaseKind = "GamePass",

	Description = "Permanently doubles how fast your eggs grow.",
}


--=============================================================================
-- JETPACKS
--
-- Sold for Robux from the jetpack shop. Each one is linked FROM its row in
-- Config.Jetpacks via `product = "<ProductId>"`; that link is how the grant
-- knows which pack to give, so no jetpack id is repeated here. To sell another
-- pack:
--   1. Create the developer product in Game Settings and copy its id.
--   2. Add an entry below, AssetId = that id.
--   3. Set `product = "<the same ProductId>"` on the pack's Config.Jetpacks row.
-- The game checks both directions at boot and warns about a missing link.
--=============================================================================

--=============================================================================
-- OFFLINE 2x - the "2x COLLECT" button on the welcome back screen.
--
-- Pays this session's offline earnings a second time (OfflineService.
-- grantDouble). Repeatable across sessions, once per session.
--
-- TODO: create the developer product (Game Settings -> Monetization ->
-- Developer Products), then paste its id into AssetId. Until then the button
-- shows "soon" and the server refuses to prompt, with a clear reason.
-- /offline2x (admin) runs the same grant without a purchase, for testing.
--=============================================================================

Products["OfflineDouble"] = {
	ProductId   = "OfflineDouble",
	DisplayName = "2x Offline Earnings",
	AssetId     = nil,

	GrantKind   = "OfflineDouble",

	-- Only refuses what cannot change between prompt and receipt: nothing to
	-- double, or already doubled this session.
	Rules       = { "OfflineDoubleAvailable" },

	Description = "Double what your pets earned while you were away.",
}

Products["Twin Burner"] = {
	ProductId   = "Twin Burner",
	DisplayName = "Twin Burner",
	AssetId     = nil,

	GrantKind   = "Jetpack",

	-- Only an UPGRADE may be bought: paying Robux for a pack you already have,
	-- or one worse than yours, gives you nothing.
	Rules       = { "JetpackIsUpgrade" },
}

local JETPACK_PRODUCTS = {
	-- ProductId must equal the `product` field on the matching Config.Jetpacks
	-- row; that row owns the jetpack id, so nothing is duplicated here.
	{ id = "Blue Flame",   assetId = nil, title = "Burns hotter than it looks" },
	{ id = "Heavy Lifter", assetId = nil, title = "Built for the long climb" },
	{ id = "Afterburner",  assetId = nil, title = "No such thing as too much thrust" },
	{ id = "Inferno Core", assetId = nil, title = "Handle with gloves" },
	{ id = "Singularity",  assetId = nil, title = "It should not work. It does." },
}

for _, jetpack in ipairs(JETPACK_PRODUCTS) do
	Products[jetpack.id] = {
		ProductId   = jetpack.id,
		DisplayName = jetpack.id,
		AssetId     = jetpack.assetId,

		GrantKind   = "Jetpack",

		-- Only an UPGRADE may be bought: paying Robux for a pack you already
		-- have, or one worse than yours, gives you nothing.
		Rules       = { "JetpackIsUpgrade" },

		Description = jetpack.title .. ".",
	}
end


--=============================================================================
-- INSTANT HATCH - the "Hatch Now" prompt on an egg still hatching.
--
-- Five tiers by time LEFT (Config.Economy.InstantHatchTiers). The tier is in
-- GrantData so the grant can refuse to finish an egg longer than what was paid
-- for. TODO: create five developer products and paste their ids into AssetId
-- (suggested prices: 9 / 29 / 59 / 99 / 149 R$). Until then the prompt says
-- "soon" and /hatchnow (admin) runs the same grant for testing.
--=============================================================================
local INSTANT_HATCH_IDS = { nil, nil, nil, nil, nil }
local INSTANT_HATCH_NAMES = { "under 5 min", "5-30 min", "30 min-2 h", "2-6 h", "6 h+" }
for tier = 1, 5 do
	local id = "InstantHatch" .. tier
	Products[id] = {
		ProductId   = id,
		DisplayName = "Hatch Now (" .. INSTANT_HATCH_NAMES[tier] .. ")",
		AssetId     = INSTANT_HATCH_IDS[tier],
		GrantKind   = "InstantHatch",
		GrantData   = { Tier = tier },
		Rules       = { "InstantHatchAvailable" },
		Description = "Finish hatching an egg instantly.",
	}
end


--=============================================================================
-- BOOSTS
--
-- Timed multipliers. One GrantKind ("Boost") serves every one of them: the
-- stat, factor, duration and stacking mode all live in GrantData, so a new
-- boost product is a catalogue entry and nothing else.
--
--   Stat    cash | training | speed | fuel | luck | serverLuck | hatch
--   Factor  the multiplier. 2 means "2x".
--   Seconds how long, in seconds. OMIT for a permanent boost (a gamepass).
--   Mode    "mul" (default) multiplies with other mul boosts
--           "add" sums with other add boosts
--           See BoostService's header for how the two combine.
--
-- Durations are in seconds rather than minutes so no product has to document
-- its own unit, and the numbers below read as the names do: 15 * 60.
--=============================================================================

local BOOST_PRODUCTS = {
	-- CASH
	{ id = "Cash2x15m", assetId = nil,  name = "2x Cash (15 min)",      stat = "cash",     factor = 2,  seconds = 15 * 60 },
	{ id = "Cash2x1h", assetId = nil,   name = "2x Cash (1 hour)",      stat = "cash",     factor = 2,  seconds = 60 * 60 },
	{ id = "Cash3x15m", assetId = nil,  name = "3x Cash (15 min)",      stat = "cash",     factor = 3,  seconds = 15 * 60 },

	-- TRAINING
	{ id = "Train2x15m", assetId = nil, name = "2x Training (15 min)",  stat = "training", factor = 2,  seconds = 15 * 60 },
	{ id = "Train3x15m", assetId = nil, name = "3x Training (15 min)",  stat = "training", factor = 3,  seconds = 15 * 60 },

	-- MOVEMENT
	{ id = "Speed2x15m", assetId = nil, name = "2x Speed (15 min)",     stat = "speed",    factor = 2,  seconds = 15 * 60 },
	{ id = "Fuel2x15m", assetId = nil,  name = "2x Fuel (15 min)",      stat = "fuel",     factor = 2,  seconds = 15 * 60 },

	-- LUCK. Player luck biases what comes out of YOUR eggs.
	{ id = "Luck2x15m", assetId = nil,  name = "2x Luck (15 min)",      stat = "luck",     factor = 2,  seconds = 15 * 60 },
	{ id = "Luck5x15m", assetId = nil,  name = "5x Luck (15 min)",      stat = "luck",     factor = 5,  seconds = 15 * 60 },

	-- SERVER LUCK. Affects what spawns for EVERYONE on this server, so it is
	-- priced as a gift to the whole lobby and is not durable - a restart clears
	-- it, because the players who paid for it have gone.
	{ id = "ServerLuck2x30m", assetId = nil, name = "2x Server Luck (30 min)", stat = "serverLuck", factor = 2, seconds = 30 * 60 },

	-- HATCH SPEED. Higher is better: 2x halves the remaining timer.
	{ id = "Hatch2x15m", assetId = nil, name = "2x Hatch Speed (15 min)", stat = "hatch",  factor = 2,  seconds = 15 * 60 },
}

for _, boost in ipairs(BOOST_PRODUCTS) do
	Products[boost.id] = {
		ProductId   = boost.id,
		DisplayName = boost.name,
		AssetId     = boost.assetId,

		GrantKind   = "Boost",
		GrantData   = {
			Stat    = boost.stat,
			Factor  = boost.factor,
			Seconds = boost.seconds,
			Mode    = boost.mode,
		},

		-- No rules: a boost is always grantable. Buying a second one stacks
		-- rather than being refused, so there is nothing to guard against.
		Description = boost.name,
	}
end


--=============================================================================
-- HATCH ALL - finish every hatching egg at once.
--
-- One product, one flat price, however many eggs are going. See
-- Economy.HatchAllRobux for why flat rather than per-egg.
--=============================================================================
Products["HatchAll"] = {
	ProductId   = "HatchAll",
	DisplayName = "Hatch All",
	AssetId     = nil,

	GrantKind   = "HatchAll",

	-- Only refuses what cannot change between prompt and receipt: having
	-- nothing hatching at all. The COUNT is free to change - a player whose
	-- second egg finished on its own while the prompt was open still gets
	-- what they paid for on the rest.
	Rules       = { "InstantHatchAvailable" },

	Description = "Finish every egg that is still hatching.",
}


--=============================================================================
-- PACKS
--
-- A bundle is a LIST OF REWARDS. One grant kind ("Pack") pays every entry, so
-- adding a bundle is a catalogue entry and no code at all. The reward kinds
-- PackService understands are:
--
--   { Kind = "money",   Amount = 10000 }
--   { Kind = "power",   Amount = 500 }
--   { Kind = "pet",     PetId = "...", Rarity = "Rare", Size = "Big", Finish = "Silver" }
--   { Kind = "egg",     EggId = "...", Count = 3, Size = ..., Finish = ... }
--   { Kind = "boost",   Stat = "cash", Factor = 2, Seconds = 900, Mode = "mul" }
--   { Kind = "petslot", Amount = 1 }
--
-- A PET REWARD MUST STATE ITS Rarity. Pets inherit rarity from their egg in
-- Config.Eggs, so a pack pet has none of its own; without Rarity it falls back
-- to Common and a premium pet would pay a Common's income. PackService warns
-- when that happens.
--
-- Packs pay every reward they can rather than all-or-nothing - see
-- PackService's header for why that is the safer contract for a receipt.
--=============================================================================

Products["StarterPack"] = {
	ProductId   = "StarterPack",
	DisplayName = "Starter Pack!",
	AssetId     = nil,

	GrantKind   = "Pack",
	GrantData   = {
		Rewards = {
			{ Kind = "money", Amount = 10000 },
			{ Kind = "power", Amount = 500 },
			{ Kind = "pet", PetId = "Golden Retriver", Rarity = "Rare", Finish = "Silver" },
		},
	},

	-- Repeatable on purpose: it grants currency and a pet, both of which stack.
	-- A once-per-account starter pack would need its own rule; see
	-- "NotAlreadyOwned" for the shape that takes.
	Description = "$10,000 + 500 POW + a Silver Golden Retriever.",
}

Products["GrowthPack"] = {
	ProductId   = "GrowthPack",
	DisplayName = "Growth Pack",
	AssetId     = nil,

	GrantKind   = "Pack",
	GrantData   = {
		Rewards = {
			{ Kind = "money", Amount = 100000 },
			{ Kind = "boost", Stat = "cash", Factor = 2, Seconds = 30 * 60 },
			{ Kind = "boost", Stat = "luck", Factor = 2, Seconds = 30 * 60 },
			{ Kind = "petslot", Amount = 1 },
		},
	},

	Description = "$100,000 + 2x Cash + 2x Luck for 30 min + a pet slot.",
}

Products["EggPack"] = {
	ProductId   = "EggPack",
	DisplayName = "Egg Pack",
	AssetId     = nil,

	GrantKind   = "Pack",
	GrantData   = {
		Rewards = {
			{ Kind = "egg", EggId = "DragonEgg", Count = 3 },
			{ Kind = "boost", Stat = "hatch", Factor = 2, Seconds = 15 * 60 },
		},
	},

	Description = "3x Dragon Egg + 2x Hatch Speed for 15 min.",
}


--=============================================================================
-- LIMITED PRODUCTS
--
-- A limited product is an ordinary pack with a stock gate: GrantData.Sku names
-- an entry in WiltedStock.Skus, and the "LimitedStockAvailable" rule stops the
-- prompt once the pool is empty. The claim itself happens inside the grant,
-- keyed on the receipt id, so a retried receipt cannot take two items.
--
-- Rewards use the same reward list a normal pack does, so a limited item can
-- give anything - see PackService for the kinds.
--=============================================================================

Products["FounderPet"] = {
	ProductId   = "FounderPet",
	DisplayName = "Founder Pet",
	AssetId     = nil,

	GrantKind   = "LimitedStock",
	GrantData   = {
		-- Must match a SkuId in WiltedStock.Skus (Total 250, 1 per account).
		Sku     = "FounderPet",
		Rewards = {
			{ Kind = "pet", PetId = "Evil Dog", Rarity = "Mythical", Size = "Huge", Finish = "Rainbow" },
			{ Kind = "money", Amount = 50000 },
		},
	},

	Rules       = { "LimitedStockAvailable" },

	Description = "One of only 250 ever. A Huge Rainbow Evil Dog + $50,000.",
}


--=============================================================================
-- RAW CASH
--
-- Six tiers of straight cash. The NAMES are deliberately vague ("Crate of
-- Cash", not "500,000 Coins") so the payout can be retuned at any time
-- without renaming a product players have already bought - ProductId is the
-- key purchase history is written against and must never change.
--
-- The amounts below are PLACEHOLDERS, chosen only to be a sane ascending
-- ladder (roughly x5 per step). Retune freely: edit Amount here and the
-- Robux price in Creator Hub, and nothing else needs touching. Neither the
-- DisplayName nor the Description states a figure, so they stay correct.
--=============================================================================

local CASH_PRODUCTS = {
	-- id                      assetId      display                amount  -- TUNING TODO
	{ id = "CashHandful",   assetId = nil, name = "Handful of Cash",    amount = 5000 },
	{ id = "CashPouch",     assetId = nil, name = "Pouch of Cash",      amount = 25000 },
	{ id = "CashSmallPile", assetId = nil, name = "Small Pile of Cash", amount = 125000 },
	{ id = "CashBigPile",   assetId = nil, name = "Big Pile of Cash",   amount = 600000 },
	{ id = "CashCrate",     assetId = nil, name = "Crate of Cash",      amount = 3000000 },
	{ id = "CashVault",     assetId = nil, name = "Vault of Cash",      amount = 15000000 },
}

for _, cash in ipairs(CASH_PRODUCTS) do
	Products[cash.id] = {
		ProductId   = cash.id,
		DisplayName = cash.name,
		AssetId     = cash.assetId,

		GrantKind   = "Currency",
		GrantData   = { Stat = "money", Amount = cash.amount },

		-- No rules: cash is repeatable and always grantable.
		Description = cash.name .. ", straight to your balance.",
	}
end


--=============================================================================
-- RAW POWER (TRAINING POINTS)
--
-- Six tiers of straight training power. Stat is "trainPoints" - the SAME
-- stat the launch pad accrues and /power grants, so it feeds launch height,
-- walk speed and jetpack tank exactly as earned power does. PackService pays
-- its own "power" reward kind into the same field.
--
-- Garment sizing rather than figures, for the same reason as the cash tiers:
-- the amount can be retuned without renaming a product that has already
-- sold, and ProductId (what purchase history keys on) never moves.
--
-- Amounts are PLACEHOLDERS - a rough x3 ladder. Retune freely here; the
-- DisplayName and Description state no number, so they stay true.
--=============================================================================

local POWER_PRODUCTS = {
	-- id                    assetId      display                 amount  -- TUNING TODO
	{ id = "PowerSmall",  assetId = nil, name = "Small Power Boost",  amount = 250 },
	{ id = "PowerMedium", assetId = nil, name = "Medium Power Boost", amount = 750 },
	{ id = "PowerLarge",  assetId = nil, name = "Large Power Boost",  amount = 2250 },
	{ id = "PowerXL",     assetId = nil, name = "XL Power Boost",     amount = 7000 },
	{ id = "PowerXXL",    assetId = nil, name = "XXL Power Boost",    amount = 20000 },
	{ id = "PowerXXXL",   assetId = nil, name = "XXXL Power Boost",   amount = 60000 },
}

for _, power in ipairs(POWER_PRODUCTS) do
	Products[power.id] = {
		ProductId   = power.id,
		DisplayName = power.name,
		AssetId     = power.assetId,

		-- The live Currency grant reads GrantData.Stat and forwards it to
		-- Profile.add, so no new GrantKind is needed: trainPoints is already
		-- in ProfileService.NUMERIC with a floor of 0.
		GrantKind   = "Currency",
		GrantData   = { Stat = "trainPoints", Amount = power.amount },

		-- No rules: power is repeatable and always grantable.
		Description = power.name .. " - training points, straight to your power.",
	}
end


--=============================================================================
-- POWER MULTIPLIER (sold as a power boost; mechanically a TRAINING boost)
--
-- Six tiers that REPLACE each other: x2 x4 x8 x16 x32 x64. Owning nothing is
-- tier 0 = x1 = no effect, so a fresh player is unaffected.
--
-- WHAT IT ACTUALLY DOES: multiplies the power GAINED from training, at the
-- accrual site in GameLoop. It does NOT scale power already banked, so a
-- purchase cannot retroactively inflate a balance.
--
-- The tier lives in profile.trainMultTier as ONE number (not an inventory),
-- and the PowerMultIsUpgrade rule refuses a tier at or below the one held -
-- so a player can never pay to go sideways or backwards.
--
-- The factor itself is Economy.trainMultFor(tier), so retuning the ladder is
-- a one-line change there and nothing here moves.
--=============================================================================

local POWER_MULT_PRODUCTS = {
	-- tier  assetId      (factor comes from Economy.trainMultFor)
	{ tier = 1, assetId = nil },
	{ tier = 2, assetId = nil },
	{ tier = 3, assetId = nil },
	{ tier = 4, assetId = nil },
	{ tier = 5, assetId = nil },
	{ tier = 6, assetId = nil },
}

for _, entry in ipairs(POWER_MULT_PRODUCTS) do
	local id = "PowerMult" .. entry.tier
	Products[id] = {
		ProductId   = id,
		DisplayName = string.format("Power multiplier! (tier %d)", entry.tier),
		AssetId     = entry.assetId,

		GrantKind   = "PowerMultiplier",
		GrantData   = { Tier = entry.tier },

		-- Refuses a tier at or below the one already owned. Checked before the
		-- prompt as well as at receipt time, so the player is never charged for
		-- a downgrade bought in a parallel session.
		Rules       = { "PowerMultIsUpgrade" },

		Description = "Permanently multiplies the power you gain from training. Replaces any lower tier.",
	}
end


--=============================================================================
-- PLOT SIGN UPGRADES (the Robux half of the two world signs)
--
-- Each plot carries two signs that already sell an upgrade FOR CASH:
--   UgpgradeTrampolineSign  -> trainerTier + 1   (Economy.TrainerTiers)
--   UpgradePlotSizeSign     -> petSlots + 1      (Economy.petSlotUpgradeCost)
--
-- Both signs were authored with an UpgradeButton_Robux that had no product
-- behind it. These are those products: the same upgrade, skipping the grind.
--
-- ONE TIER PER PURCHASE, deliberately. A product that jumped straight to max
-- would need a different price per starting tier, which a fixed-price Roblox
-- product cannot express - and charging one price for wildly different
-- amounts of progress is the kind of thing players rightly complain about.
--
-- THE CEILING IS A RULE, NOT A GRANT CHECK. Refusing before the prompt means
-- a maxed player is never charged; the rule runs again at receipt time, so a
-- purchase that was legal when prompted but maxed out in between (a cash
-- upgrade bought meanwhile) is refused rather than taking money for nothing.
--=============================================================================

Products["UpgradeTraining"] = {
	ProductId   = "UpgradeTraining",
	DisplayName = "Upgrade Training",
	AssetId     = nil,

	GrantKind   = "TrainerTier",

	Rules       = { "TrainerNotMaxTier" },

	Description = "Upgrade your training pad to the next tier.",
}

Products["UpgradePlot"] = {
	ProductId   = "UpgradePlot",
	DisplayName = "Upgrade Plot",
	AssetId     = nil,

	GrantKind   = "PetSlot",

	Rules       = { "PlotNotMaxSize" },

	Description = "Upgrade your plot, adding another pet slot.",
}

-- 1 R$ TEST PRODUCT (Chris, 2026-10-19) - the T8 real-money check.
-- Grants nothing of value: the "TestPurchase" kind (registered by
-- ServerScriptService.WiltedSuiteBootstrap) just counts purchases in the
-- player's saved data and prints the count.
Products["TestPurchase"] = {
	ProductId   = "TestPurchase",
	DisplayName = "Test Purchase",
	AssetId     = nil,

	GrantKind   = "TestPurchase",

	Description = "1 R$ test of the full receipt path.",
}

return Products
