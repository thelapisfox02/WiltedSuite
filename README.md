# WiltedSuite

Four Roblox services that know nothing about any particular game, so each one can be dropped into a new project and wired by the game that uses it.

| Module | What it does | Version |
|---|---|---|
| [WiltedMonetization](modules/WiltedMonetization) | A data-only catalogue of developer products and gamepasses, purchase rules, grant kinds, and receipt handling that leaves a receipt unconsumed until it can be granted | 1.3.0 |
| [WiltedStock](modules/WiltedStock) | A finite global pool shared by every server, claimed exactly once per item | 1.2.0 |
| [WiltedInventory](modules/WiltedInventory) | An inventory and hotbar GUI independent of Roblox's default backpack | 1.0.0 |
| [WiltedHarvest](modules/WiltedHarvest) | Per-player engagement, spend and social summaries plus a typed event stream. It watches; it never grants, prices or changes game state | 0.6.0 |

There is also an [example of a game adapter](examples/roll-gems-harvest-adapter) (the glue that connects a real game to Harvest) and [sample configuration](config-examples).

## WiltedCore is not published

All four modules stand on a shared base, WiltedCore (logging, signals, remotes, config loading, registries, start-up lifecycle, retry, version checks and a service directory). The core's source is not part of this repository; its API is documented in [docs/core](docs/core).

Every module looks for `ReplicatedStorage.WiltedCore` at version 1.1.0 or newer. If it is missing or too old, the module **disables itself with one warning and does not error**. So the modules can be dropped in safely, but they do nothing until a core is present.

## Layout

The folder tree mirrors the Studio instance tree. A folder named after an instance is that instance's place, and `init.luau` is the ModuleScript that holds the others in its folder. Each module's README says which services to put its folders in. There is no project file: copy the folders into Studio.

## How this was made

Built in Roblox Studio with AI tooling under my direction. I write the recipes and the design decisions, AI writes and expands the code, and nothing is kept until it passes my own checks. The checks ran in a private test place and are not published here.

## Licence

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 TheLapisFox02.
