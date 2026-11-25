--!strict
--[[
	=== Skus ==================================================================
	THE LIMITED STOCK CATALOGUE. This is the file you edit to add a limited
	thing.

	DATA ONLY. No functions, no requires - so it can be read on the client for
	display without dragging server code along, and so adding a drop is never
	a code change.

	---------------------------------------------------------------------------
	THE FIELDS
	---------------------------------------------------------------------------

	  SkuId         [string]  REQUIRED. Stable id, identical to the key. The
	                          durable counter is keyed on it, so NEVER rename
	                          one that has sold: the count would reset to zero
	                          and the drop would restock itself.

	  DisplayName   [string]  REQUIRED. What a human sees. Safe to change.

	  Total         [number]  REQUIRED. How many exist, ever. Safe to RAISE at
	                          any time (the durable number counts sales, not
	                          remainder, so raising the total just reopens the
	                          drop). Lowering below what has already sold shows
	                          0 left rather than going negative.

	  Shards        [number?] Split the durable counter over N DataStore keys.
	                          One key throttles under a flash drop; shards
	                          spread the writes. Rule of thumb: 1 for a slow
	                          burn, 4-8 for something that will sell out in
	                          minutes. Changing this on a LIVE sku re-keys the
	                          counters, so set it before the drop opens.

	  PerUserLimit  [number?] Most one account may ever claim. 1 makes it
	                          truly unique per player. nil means no limit, and
	                          one buyer can take the whole drop.

	  Description   [string?] Free text for a shop tile. Unused by the service.
]]

local Skus = {}

--=============================================================================
-- EXAMPLE, NOT LIVE
--
-- Kept commented out: a live sku with a placeholder would start counting
-- sales against a drop that does not exist yet. Copy it, rename, uncomment.
--
-- Skus["GoldenDragon"] = {
-- 	SkuId        = "GoldenDragon",
-- 	DisplayName  = "Golden Dragon",
-- 	Total        = 1000,
-- 	Shards       = 4,
-- 	PerUserLimit = 1,
-- 	Description  = "Only 1,000 will ever exist.",
-- }
--=============================================================================

--=============================================================================
-- LIVE SKUS
--=============================================================================

-- A real, modest drop to prove the path end to end. One per account, a single
-- shard because 250 will not sell in a minute.
Skus["FounderPet"] = {
	SkuId        = "FounderPet",
	DisplayName  = "Founder Pet",
	Total        = 250,
	Shards       = 1,
	PerUserLimit = 1,
	Description  = "One of only 250, and only one per player.",
}

return Skus
