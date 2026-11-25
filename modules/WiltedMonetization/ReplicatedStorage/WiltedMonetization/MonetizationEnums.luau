--!strict
--[[
	=== MonetizationEnums ======================================================
	The vocabulary shared by the server, the client and whatever analytics sink
	the host wires up. Data only - no requires, no logic - so the client can
	read it without pulling server code in.

	WHY STRINGS AND NOT NUMBERS. These values leave the game: they end up as
	analytics custom-field text in Creator Hub. A number would be meaningless
	in a funnel report and, worse, renumbering later would silently re-label
	every historical row. The string IS the wire format, so it must never
	change once it has shipped.
]]

local MonetizationEnums = {}

--=============================================================================
-- EVENTS
--
-- Custom monetization events the host may attach a handler to, via
-- MonetizationService:SetCustomEvent. Roblox core analytics records that a
-- purchase happened and for how much, but not WHICH of our products or
-- whether it was bought for the buyer or gifted - that is what these carry.
--=============================================================================

MonetizationEnums.Events = {
	-- Fires once a developer-product purchase is granted AND CONFIRMED SAVED.
	-- Never fires for a receipt that was refused, replayed, or could not be
	-- persisted, so a handler can treat it as "this definitely happened".
	PurchaseCompleted = "PurchaseCompleted",
}

--=============================================================================
-- PRODUCT RECEIVER TYPE
--
-- Who the product was bought FOR. Gifting is not implemented yet, so
-- everything the service emits today is Self; Gift exists so the analytics
-- schema does not have to change when it lands, and so a handler written now
-- can already branch on it.
--=============================================================================

MonetizationEnums.ProductReceiverType = {
	Self = "Self",
	Gift = "Gift",
}

--=============================================================================
-- VALIDATION HELPERS
--
-- A typo in an event name would otherwise register a handler that simply
-- never fires - silent, and indistinguishable from "analytics is broken".
--=============================================================================

function MonetizationEnums.isEvent(value: any): boolean
	for _, v in pairs(MonetizationEnums.Events) do
		if v == value then
			return true
		end
	end
	return false
end

function MonetizationEnums.isReceiverType(value: any): boolean
	for _, v in pairs(MonetizationEnums.ProductReceiverType) do
		if v == value then
			return true
		end
	end
	return false
end

-- Sorted, for error messages that name what WAS allowed.
function MonetizationEnums.eventNames(): { string }
	local names = {}
	for _, v in pairs(MonetizationEnums.Events) do
		table.insert(names, v)
	end
	table.sort(names)
	return names
end

return MonetizationEnums