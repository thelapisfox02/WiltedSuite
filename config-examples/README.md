# Sample configuration

A game's data lives in `ReplicatedStorage.WiltedConfig`, an ordinary Folder the game owns, so updating a module never overwrites game data. These are the sample files from the private test place. Copy and edit them; do not use them as they are.

- `Products.luau` is a full catalogue for WiltedMonetization. **Every developer product and gamepass id has been replaced with `nil`**, which the service treats as "this product does not exist on Roblox yet": it is listed and validated, and refuses to prompt with a clear reason. Paste your own ids into the `AssetId` fields. The product names are examples.
- `Skus.luau` lists limited stock for WiltedStock.
- `Harvest.luau` is a minimal WiltedHarvest config. It is the test place's own, so do not copy its `Experience` name.
