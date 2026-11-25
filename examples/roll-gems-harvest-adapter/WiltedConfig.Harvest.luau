-- ReplicatedStorage.WiltedConfig.Harvest - Roll a Gem values (game-owned).
-- Replaces the Wilted Suite sandbox config; never copy that one.
-- Coin counters are Big: no size limit (totals saved like Money: a plain
-- number below 1e15, otherwise { mantissa, exponent }).
return {
	Experience = "roll_a_gem",
	ConfigVersion = "rag-3",
	Sinks = { "AnalyticsService" }, -- add "Log" while testing in Studio
	Group = { Mode = "GameOwner" }, -- the game is group-owned
	Events = {
		mineral_purchased = {
			Fields = { MineralId = "string", Rarity = "string", Price = "number", Free = "boolean" },
			Analytics = { Value = "Price", Fields = { "Rarity", "MineralId" } },
		},
		fusion_completed = {
			Fields = { RecipeId = "string", MineralId = "string", FusionNumber = "number" },
			Analytics = { Value = "FusionNumber", Fields = { "RecipeId", "MineralId" } },
		},
		lootbox_opened = {
		Fields = { BoxId = "string", MineralId = "string", Rarity = "string" },
		Analytics = { Fields = { "BoxId", "Rarity" } },
	},
	timeskip_used = {
		Fields = { Minutes = "number" },
		Analytics = { Value = "Minutes" },
	},
	rebirth_completed = {
			Fields = { Count = "number" },
			Analytics = { Value = "Count" },
		},
	},
	Counters = {
		["rag.coinsEarned"] = { Big = true, Description = "coins credited by play (collect, rewards)" },
		["rag.coinsSpent"] = { Big = true, Description = "coins debited for minerals, upgrades, mutator" },
		["rag.coinsWelcomeBack"] = { Big = true, Description = "offline / welcome-back credits" },
		["rag.coinsRefunded"] = { Big = true, Description = "refund / undo credits" },
		["rag.coinsResetByRebirth"] = { Big = true, Description = "balance cleared by rebirths" },
		["rag.coinsAdmin"] = { Big = true, Description = "admin (Cmdr) credits and debits" },
		["rag.rolls"] = {},
		["rag.rollsPassed"] = {},
		["rag.rareOffers"] = {},
	},
	Milestones = {
		["rag.firstPayout"] = { Description = "first coins earned" },
		["rag.firstMineral"] = { Description = "first mineral bought" },
		["rag.firstFusion"] = { Description = "first fusion" },
		["rag.firstRebirth"] = { Description = "first rebirth" },
	},
}
