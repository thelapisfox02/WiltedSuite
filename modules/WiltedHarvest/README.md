# WiltedHarvest

Version 0.6.0. Needs WiltedCore 1.1.0 or newer (see the [root README](../../README.md)).

Per-player engagement, spend and social summaries, plus a typed event stream, for any game. Harvest watches. It never grants, prices, randomises or edits game state, and a game that loses Harvest keeps working. It is game-blind: your game's own numbers are declared in its config and sent through `Emit`.

## What is in here

```
ReplicatedStorage/WiltedHarvest/            the shared half: version, enums, summary schema, config and event validation
    init.luau
    BigCount.luau                           counters with no size limit
    Days.luau
    HarvestEnums.luau
    Schema.luau
ServerScriptService/WiltedHarvest/          the server half (there is no client half)
    HarvestService.luau                     Start, Emit, GetSummary, RegisterSink, ...
    MonetizationGlue.luau                   feeds WiltedMonetization's purchases into Harvest (does nothing if Monetization is absent)
    Sinks.luau
    Storage.luau
    Collectors/                             sessions, spend, social, community, ads, extensions
```

## Install

1. Copy the two folders into ReplicatedStorage and ServerScriptService.
2. Write `ReplicatedStorage.WiltedConfig.Harvest` ([config-examples/Harvest.luau](../../config-examples/Harvest.luau) is a minimal one; the [Roll Gems adapter example](../../examples/roll-gems-harvest-adapter) is a full one). It declares `Experience`, the sinks to use (`"AnalyticsService"`, `"Log"` or `"Memory"`), and your own events, counters and milestones.
3. Call `HarvestService.Start(dependencies)` and give it somewhere to keep its per-player table. How you store that is your game's business, which is what the adapter example's `storage` function shows.
4. Report your game's outcomes with `HarvestService.Emit(player, eventType, payload, eventId)`.

## Behaviour worth knowing

- With no config there is one warning and the built-in events still work.
- An event with an `eventId` is recorded once, so a replay is dropped.
- Coin-like counters can be declared `Big = true` and are saved without a size limit.
