# WiltedStock

Version 1.2.0. Needs WiltedCore 1.1.0 or newer (see the [root README](../../README.md)).

A limited, global stock: a finite pool shared by every server that can be claimed exactly once per item, such as "650 / 1000 left". A sku is just a name with a total, so nothing here knows about pets, eggs or Robux.

## What is in here

```
ReplicatedStorage/WiltedStock/              the shared half
    init.luau
    StockClient.luau                        a local mirror of how many are left, kept fresh by the server
ServerScriptService/WiltedStock/
    StockService.luau                       claims, the shared pool, idempotency, rollback
```

## Install

1. Copy `ReplicatedStorage/WiltedStock` into ReplicatedStorage and `ServerScriptService/WiltedStock` into ServerScriptService.
2. List your skus and their totals in `ReplicatedStorage.WiltedConfig.Skus` ([config-examples/Skus.luau](../../config-examples/Skus.luau)).
3. Call `StockService.Start(dependencies)` from a server script.

## Design decisions

- The durable number is `sold`, not `remaining`. `sold` only counts up, so a lost key reads as "nothing sold" instead of "sold out", counts from separate shards simply add up, and raising a total later cannot corrupt earlier counts.
- A claim takes an `idempotencyKey` (for a purchase, the receipt's `PurchaseId`). A repeated key returns the earlier answer. If the claim fails after the allowance was taken, the allowance is given back.
- Missing content is a warning, not a crash: an unknown sku returns a reason string.
