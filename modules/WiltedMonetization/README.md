# WiltedMonetization

Version 1.3.0. Needs WiltedCore 1.1.0 or newer (see the [root README](../../README.md)).

The game's product catalogue lives in data, not in code. Adding something buyable is a catalogue entry, and the service checks the catalogue when it starts and reports mistakes in the console.

## What is in here

```
ReplicatedStorage/WiltedMonetization/       the shared half: catalogue loading, signal type, remote plumbing
    init.luau
    MonetizationClient.luau
    MonetizationEnums.luau
    ProductInfo.luau
ServerScriptService/WiltedMonetization/     the server half, kept out of clients' reach
    MonetizationService.luau                Start(dependencies), receipts, prompts
    PurchaseRules.luau                      named rules that can stop a prompt
    GrantingManager.luau                    named grant kinds that pay out
    StockGlue.luau                          optional bridge to WiltedStock
```

## Install

1. Copy `ReplicatedStorage/WiltedMonetization` into ReplicatedStorage and `ServerScriptService/WiltedMonetization` into ServerScriptService.
2. Put your catalogue in `ReplicatedStorage.WiltedConfig.Products` (a ModuleScript that returns a table). [config-examples/Products.luau](../../config-examples/Products.luau) is a full example with the developer product ids removed.
3. From a server script, call `MonetizationService.Start(dependencies)`. Whatever the service needs from your game arrives through `dependencies`; a missing dependency becomes a refusal with a reason, not an error.
4. Register your own grant kinds and rules with `GrantingManager` and `PurchaseRules`. `GrantingManager.RegisteredKinds()` and `PurchaseRules.RegisteredRules()` list what is known.

## Behaviour worth knowing

- An unknown product id, an unregistered rule or an unregistered grant kind returns a reason string. It does not throw.
- A receipt that cannot be granted yet is left unconsumed, so Roblox redelivers it later.
- `StockGlue` is optional. It registers a `LimitedStock` grant kind and a `LimitedStockAvailable` rule only if WiltedStock is in the core's service directory. Without Stock, a product that names them is refused and its receipt is never consumed, so it fails closed.
- The RemoteEvents are created under `ReplicatedStorage.WiltedMonetization` on first use by the server.
