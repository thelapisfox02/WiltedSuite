-- ReplicatedStorage.WiltedConfig.Harvest - SANDBOX values for Wilted Suite.
-- A real game writes its own (see WiltedHarvest README).
return {
	Experience = "wilted_suite_sandbox",
	Sinks = { "Memory" },
	Group = { Mode = "GameOwner" },
	Events = {
		sandbox_ping = { Fields = { N = "number" } },
	},
	Counters = { ["sandbox.pings"] = {} },
	Milestones = { ["sandbox.firstPing"] = {} },
	Tunables = {
		OwnStoreName = "WiltedHarvest_SANDBOX", -- never the shipped "WiltedHarvest_v1"
		SaveIntervalSeconds = 5,                -- short, for live tests
	},
}
