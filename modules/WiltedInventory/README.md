# WiltedInventory

Version 1.0.0. Needs WiltedCore 1.1.0 or newer (see the [root README](../../README.md)).

An inventory and hotbar GUI that is independent of Roblox's default backpack. One manager owns many named inventories. Each inventory owns its categories (a name, and optionally an icon and a limit), its items and a hotbar.

## What is in here

```
ReplicatedStorage/WiltedInventoryService/
    init.luau                               the manager
    UiText.luau                             text style for the labels the module creates
```

## The GUI templates are not in this repository

The module reads `script.Templates` when it loads, and that folder holds four UI instances: `InventoryGui`, `CategoryContent`, `Category_Container` and `InventoryItem_Container`. They are Roblox UI objects, not source, so they are not included here.

**Without them the module cannot load.** To use it, build a `Templates` folder as a child of `WiltedInventoryService` with those four names. `InventoryGui` carries a `Pointers` folder of ObjectValues (`InventoryTitle_TextLabel`, `CategoriesList_Frame`, `InventoryContent_Frame`) that point at the title label, the category list and the content frame. Everything is found through those pointers, so the layout can be changed in Studio without touching the code.

## Install

1. Copy `ReplicatedStorage/WiltedInventoryService` into a place that replicates to clients (ReplicatedStorage), and add the `Templates` folder.
2. Require it on the client. What an item means, what a click does and how an icon is drawn are your game's business, passed in through the `Set*Handler` and `SetIconRenderer` hooks.

## Behaviour worth knowing

- A categories table is `{ Name = "Pets", Icon = "rbxassetid://...", Limit = 100 }`. Every field except `Name` is optional, and a bare string still works.
- An unknown or full category warns and returns nil or false. It does not throw.
