# Example: connecting a game to WiltedHarvest

A real adapter from Roll Gems for Money, shown as an example. It is game-side glue, not part of WiltedHarvest. It only listens to the game's existing after-commit hooks and reports to Harvest. It never writes coins, offers, inventory, odds or rebirths, and a missing or broken Harvest, or a missing hook, never errors into the game: every call is wrapped in `pcall`.

The files are copied unchanged from the game, so some names refer to it: the header says "Roll a Gem" (the game's working title), and the counter names start with `rag.`.

## Files

- `HarvestAdapter.luau` listens to four hooks: the coin ledger's `onCommitted`, the roll service's `onEvent`, the fusion service's `onEvent` and the rebirth service's `onChanged` (it also calls the rebirth service's `getCount`). It maps each outcome to one Harvest event, counter or milestone. It also has `Adapter.storage(DataService)`, which keeps Harvest's per-player table inside the game's own save profile.
- `WiltedConfig.Harvest.luau` is that game's Harvest config: its events, counters and milestones, with coin counters marked `Big`.

## What to take from it

- One authoritative source per outcome, so nothing is counted twice.
- Event ids that reuse the game's own idempotency keys (`roll:<offerId>`, `fuse:<n>`), so a replay counts once.
- Coin amounts arrive as big numbers (mantissa and exponent) and are passed to Big counters as `{ Amount = mantissa, Exponent = e }`.

## Not included

The game's own services (the ledger, roll, fusion and rebirth services) and its save library are not part of this repository. The adapter uses them only through the small interfaces described in its header.
