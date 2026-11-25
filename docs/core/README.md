# WiltedCore (documentation only)

WiltedCore 1.1.0 is the shared base the four modules stand on. **Its source is not published.** This page documents what it provides and what the modules need from it.

It is plumbing only. It contains no game logic and knows nothing about any particular service, and it creates no Instances of its own: `Remote.Get` creates RemoteEvents as children of whatever owner a service passes in.

## How a module finds it

The only fixed path in the whole family is `ReplicatedStorage.WiltedCore`. Every module does the same check at load:

```lua
local coreModule = ReplicatedStorage:FindFirstChild("WiltedCore")
local ok, Core = pcall(require, coreModule)
if not ok then
    warn("[WiltedThing] WiltedCore not found at ReplicatedStorage.WiltedCore - service disabled")
    -- return a table whose functions all refuse with a reason
end
if not Core.Version.Check("WiltedThing", "1.1.0", log) then
    -- core too old: refuse, do not crash
end
```

A missing or too-old core disables the module. It does not crash it.

## What each module uses

| Module | Core pieces it calls |
|---|---|
| WiltedMonetization | Config.Load, Lifecycle.new, Log.new, Players.ForEach, Problems, Registry.new, Remote.Find / Get / Wait, Services.Register, Signal.new, Version.Check |
| WiltedStock | Config.Load, Lifecycle.new, Log.new, Remote.Get / Wait, Retry.Call, Services.Get / Register, Signal.new, Version.Check |
| WiltedInventory | Log.new, Services.Register, Version.Check |
| WiltedHarvest | Config.Load, Lifecycle.new, Log.new, Players.ForEach, Registry.new, Retry.Call, Services.OnRegistered / Register, Signal.new, Version.Check |

## The pieces

`require(ReplicatedStorage.WiltedCore)` returns one table that re-exports all of these, plus `VERSION` ("1.1.0"). There is one root so a service needs one `pcall`'d require to learn whether the core is usable at all.

| Piece | What it does | Public functions |
|---|---|---|
| **Version** | The core's own version, and the check each service runs at start so a half-updated place says what is wrong. Versions are `MAJOR.MINOR.PATCH`, compared numerically, so 1.10.0 is newer than 1.9.0. | `Parse(text)`, `Compare(a, b)`, `Check(serviceName, minCoreVersion, log?, installed?)` |
| **Log** | One logger per service, so every line carries the same prefix. A thin wrapper over `print` and `warn`; it does not buffer, filter or send anything. | `Log.new(name, sink?)`, then `:Info`, `:Warn`, `:Detail` |
| **Signal** | A minimal signal: Connect, Fire, Disconnect. | `Signal.new(log?)`, `:Connect(handler)`, `:Fire(...)` |
| **Remote** | Finding and creating the RemoteEvents a service uses. `Get` is server only, finds or creates, and never yields. `Find` works on either side, never yields and never creates. `Wait` is for the client's background only. | `Find(owner, name)`, `Get(owner, name, options?)`, `Wait(owner, name, log?, options?)` |
| **Config** | Reads this game's data for a service from `ReplicatedStorage.WiltedConfig`. Game data lives outside the packages so an update can never overwrite it. A bad config is one warning and an empty table. | `Load(moduleName, log?, options?)` |
| **Problems** | A collector for `Validate()` functions, plus the small checks every catalogue validator repeats. | `Problems.new()` with `:Add`, `:List`, `:Count`; `Unique()` with `:Claim`; `IsNonEmptyString`, `IsWholeAtLeast`, `IsPositiveInteger`, `IsPositiveNumber`, `IsWithinLength`, `KeyMatchesField` |
| **Registry** | A named table of functions a host fills in at boot (rules, grant kinds, handlers). | `Registry.new(options?)` with `:Register`, `:Registered`, `:IsRegistered`, `:Get` |
| **Lifecycle** | The guards every server half repeats at the top of `Start`: server only, start once, report catalogue problems, print one "started" line. | `Lifecycle.new(name, log?, options?)` with `:GuardServer`, `:GuardStart`, `:IsStarted`, `:ValidateAndLog`, `:StartedLine` |
| **Dependencies** | Reads what a host passed to `Start(dependencies)`, so a missing or wrong-typed entry becomes a refusal with a reason instead of "attempt to call a nil value". | `Get(dependencies, key, kind?)` returns `(value, reason)` |
| **Retry** | Bounded exponential backoff with jitter for calls that throttle (DataStore, MemoryStore, HTTP). Returns `(true, result)` or `(false, lastErrorMessage)` and warns once on final failure. | `Call(label, fn, { attempts, backoff, log })`, `IsThrottle(message)` |
| **Players** | "Do this for every player: the ones here now and every one who joins." Connecting only to `PlayerAdded` misses anyone already in the server. | `ForEach(fn, options?)` returns a connection |
| **Services** | The service directory: how Wilted services find each other without hardcoded paths and without depending on each other being installed. | `Register(name, api)`, `Get(name)` returns `(api, reason)`, `OnRegistered(name, fn)`, `Registered()` |

## Rules every piece follows

1. Siblings are required through `script.Parent`, so the tree works wherever it is parented.
2. Nothing host-specific is required. The only piece that reads game content is Config, and it degrades to an empty table with one warning.
3. Missing content is a warning, not a crash. Lookups return `(nil, reason)`, registries refuse bad input with a warning, and nothing throws during `require`.

## Using the modules without the original core

The modules only need the interface above. A core that provides the same pieces at version 1.1.0 or newer would work, but that has not been tried here, and the exact behaviour of each piece (for example `Retry`'s backoff or `Lifecycle`'s messages) is not specified beyond this page.
