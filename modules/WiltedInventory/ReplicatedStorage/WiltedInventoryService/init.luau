--!strict
--[[
	=== WiltedInventoryService ================================================

	A self-contained inventory + hotbar GUI, independent of Roblox's default
	backpack. One manager owns many named inventories; each inventory owns its
	categories, its items and a hotbar.

	CATEGORIES ARE TABLES, not strings:

		Categories = {
			{ Name = "Pets", Icon = "rbxassetid://123", Limit = 100 },
			{ Name = "Eggs", Icon = "rbxassetid://456", Limit = 50 },
		}

	Every field except Name is optional. A bare string is still accepted and
	normalised to { Name = category }, so older call sites keep working.

	The definition table is stored, so Icon/Limit stay queryable after creation
	rather than being consumed once at build time.

	LAYOUT CONTRACT
	Templates/InventoryGui carries a Pointers folder of ObjectValues
	(InventoryTitle_TextLabel, CategoriesList_Frame, InventoryContent_Frame).
	Everything is resolved through those, so the GUI can be re-laid-out in
	Studio without touching this file. Pointers are re-resolved against the
	CLONE, since the authored ObjectValues point at the template.

	---------------------------------------------------------------------------
	DROP-IN CONTRACT
	---------------------------------------------------------------------------

	This module is meant to be dragged into any project and required on the
	client, with nothing else wired:

	  1. ITS OWN PIECES ARE RESOLVED RELATIVELY. Templates and UiText are
	     children of this module (script.Templates, script.UiText). The only
	     fixed path is ReplicatedStorage.WiltedCore (the shared plumbing).
	     The module must sit somewhere that replicates to clients.
	  2. NOTHING HOST-SPECIFIC IS REQUIRED. What an item means, what a click
	     does and how an icon is drawn are the caller's business, passed in
	     through the Set*Handler / SetIconRenderer hooks.
	  3. BAD INPUT IS A WARNING, NOT A CRASH. An unknown category or a full
	     one warns and returns nil/false.
	  4. A MISSING OR TOO-OLD CORE DISABLES, IT DOES NOT CRASH. One warning,
	     and New/Get return nil with the reason (decisions 9 and 16).

	UiText is the house text style (Ubuntu Bold plus a "ScaledStroke"-tagged
	outline) for the labels this module creates. It ships inside the package
	(decision 4). A host game's own script that scales tagged strokes picks
	the tag up; without one the outline simply stays at its fixed thickness.
]]

local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- House style for text this service CREATES (hotbar slot labels, the drag
-- ghost's fallback): Ubuntu Bold plus a ScaledStroke-tagged outline, so a
-- generated label matches the authored templates around it.
--
-- Bundled inside this package and required relatively (decision 4), so the
-- package carries its own copy and needs no host path.
local UiText = require(script.UiText)

local VERSION = "1.0.0"
local MIN_CORE_VERSION = "1.1.0"

--=============================================================================
-- THE CORE
--
-- Found by its one fixed path, inside pcall, so a place without it still
-- loads this module. Resolved once per Luau VM, so the "service disabled"
-- warning prints once however many callers require this module.
--=============================================================================

local Core: any = nil
local disabledReason: string? = nil

do
	local coreModule = ReplicatedStorage:FindFirstChild("WiltedCore")
	local ok, result = false, nil
	if coreModule and coreModule:IsA("ModuleScript") then
		ok, result = pcall(require, coreModule)
	end
	if not ok or type(result) ~= "table" then
		disabledReason = "WiltedCore is not installed"
		warn("[WiltedInventory] WiltedCore not found at ReplicatedStorage.WiltedCore - service disabled")
	elseif not result.Version.Check("WiltedInventory", MIN_CORE_VERSION, result.Log.new("WiltedInventory")) then
		disabledReason = string.format("WiltedCore %s is older than the %s WiltedInventory needs",
			tostring(result.VERSION), MIN_CORE_VERSION)
	else
		Core = result
	end
end

local log = if Core then Core.Log.new("WiltedInventory") else nil

-- Every warning below is reachable only through an inventory, and New
-- refuses while the package is disabled, so `log` is always set by then.
local function warnf(message: string, ...: any)
	if log then
		log:Warn(message, ...)
	end
end

-- LOCK STATE. Declared at the very top because EVERY interaction entry point
-- consults it, and those are scattered throughout the file.
--
-- A `local function` is only in scope for code written BELOW it. Lua binds
-- names when a function body is COMPILED, not when it runs, so a use sitting
-- textually above the declaration - even inside a callback that only fires
-- much later - binds to a GLOBAL, which is nil. That is exactly what threw
-- "attempt to call a nil value" on the first inventory click after a lock.
-- Keep this declaration above every use.
local function isLocked(inventory): boolean
	return inventory._locked == true
end


local _templates = script.Templates

local TAG_CATEGORY_CONTENT = "__WILTED_INVENTORY_CATEGORY_CONTENT"
local ALL_CATEGORY = "_all"

export type CategoryDef = {
	Name: string,
	Icon: string?,
	Limit: number?,
	LayoutOrder: number?,
}

export type ItemDef = {
	Id: string?,
	Name: string?,
	Icon: string?,
	Category: string?,
	Count: number?,
	Locked: boolean?,
	Payload: any?,
	Attributes: { [string]: any }?,
}

export type Inventory = {
	Name: string,
	Gui: typeof(_templates.InventoryGui),
	InventoryTitle: string?,
	HideHotbarItems: boolean?,

	Hotbar: {
		_slots: { [number]: any },
		_selectedSlot: number,
	},

	_categories: { CategoryDef },
	_categoryByName: { [string]: CategoryDef },
	_inventories: { [string]: { ItemDef } },
	_currentCategory: string,
}

local manager = {
	VERSION = VERSION,
	MIN_CORE_VERSION = MIN_CORE_VERSION,
	_inventories = {} :: { [string]: Inventory },
}

----------------------------------------------------------------
-- CATEGORY NORMALISATION
----------------------------------------------------------------

-- Accepts "Pets" or { Name = "Pets", Icon = ..., Limit = ... } and always
-- returns a table. Everything downstream can then assume table form.
local function normaliseCategory(category: string | CategoryDef): CategoryDef?
	if type(category) == "string" then
		return { Name = category }
	end

	if type(category) == "table" then
		if type(category.Name) ~= "string" or category.Name == "" then
			warnf("category table needs a string Name field")
			return nil
		end
		-- Copy so the caller's table cannot be mutated from in here.
		return {
			Name = category.Name,
			Icon = category.Icon,
			Limit = category.Limit,
			LayoutOrder = category.LayoutOrder,
		}
	end

	warnf("category must be a string or a table, got %s", typeof(category))
	return nil
end

-- Resolve a category argument to its stored definition, so callers may pass
-- either the name or the table itself.
local function resolveCategoryName(inventory: Inventory, category: string | CategoryDef): string?
	if type(category) == "string" then
		return category
	end
	if type(category) == "table" and type(category.Name) == "string" then
		return category.Name
	end
	return nil
end

----------------------------------------------------------------
-- POINTERS
----------------------------------------------------------------

-- The authored ObjectValues reference instances INSIDE the template. After a
-- Clone they must be re-pointed at the clone's own descendants, otherwise
-- every inventory writes into the shared template.
local function rebindPointers(templateGui: Instance, clonedGui: Instance)
	local pointers = clonedGui:FindFirstChild("Pointers")
	if not pointers then
		return
	end

	for _, pointer in ipairs(pointers:GetChildren()) do
		if pointer:IsA("ObjectValue") and pointer.Value then
			-- Walk the path from the template root, then follow the same path
			-- down the clone.
			local path = {}
			local node = pointer.Value
			while node and node ~= templateGui do
				table.insert(path, 1, node.Name)
				node = node.Parent
			end

			if node == templateGui then
				local target: Instance? = clonedGui
				for _, segment in ipairs(path) do
					target = target and target:FindFirstChild(segment)
				end
				if target then
					pointer.Value = target
				end
			end
		end
	end
end

local function pointer(inventory: Inventory, name: string): Instance?
	local pointers = inventory.Gui:FindFirstChild("Pointers")
	local value = pointers and pointers:FindFirstChild(name)
	return value and (value :: ObjectValue).Value or nil
end


----------------------------------------------------------------
-- COUNTS
----------------------------------------------------------------

local function countItems(inventory: Inventory, categoryName: string?): number
	if categoryName then
		local list = inventory._inventories[categoryName]
		return list and #list or 0
	end
	local total = 0
	for _, list in pairs(inventory._inventories) do
		total += #list
	end
	return total
end

-- Limit of the active category, or the sum of all limits when showing _all.
local function limitFor(inventory: Inventory, categoryName: string?): number?
	if categoryName then
		local def = inventory._categoryByName[categoryName]
		return def and def.Limit or nil
	end
	local total, found = 0, false
	for _, def in ipairs(inventory._categories) do
		if def.Limit then
			total += def.Limit
			found = true
		end
	end
	return found and total or nil
end

local function refreshHeader(inventory: Inventory)
	local header = inventory.Gui:FindFirstChild("Inventory")
	header = header and header:FindFirstChild("Header")
	local count = header and header:FindFirstChild("Count")
	if not count or not count:IsA("TextLabel") then
		return
	end

	local active = inventory._currentCategory ~= "" and inventory._currentCategory or nil
	local used = countItems(inventory, active)
	local max = limitFor(inventory, active)

	count.Text = max and string.format("Slots: %d/%d", used, max)
		or string.format("Slots: %d", used)
end

----------------------------------------------------------------
-- CATEGORY VIEW SWITCHING
----------------------------------------------------------------

local function contentRoot(inventory: Inventory): Instance?
	return pointer(inventory, "InventoryContent_Frame")
end

local function categoryList(inventory: Inventory): Instance?
	return pointer(inventory, "CategoriesList_Frame")
end

-- Shows exactly one content frame: the named category, or _all when nil.
local function showCategory(inventory: Inventory, categoryName: string?)
	local content = contentRoot(inventory)
	local list = categoryList(inventory)
	if not content then
		return
	end

	inventory._currentCategory = categoryName or ""

	for _, child in ipairs(content:GetChildren()) do
		if CollectionService:HasTag(child, TAG_CATEGORY_CONTENT) then
			local shouldShow
			if categoryName then
				shouldShow = child.Name == categoryName
			else
				shouldShow = child.Name == ALL_CATEGORY
			end
			;(child :: GuiObject).Visible = shouldShow
		end
	end

	-- Selected category button gets its stroke; the rest lose it.
	if list then
		for _, button in ipairs(list:GetChildren()) do
			local inner = button:FindFirstChild("Button")
			local stroke = inner and inner:FindFirstChild("UIStroke")
			if stroke and stroke:IsA("UIStroke") then
				stroke.Enabled = categoryName ~= nil and button.Name == categoryName
			end
		end
	end

	refreshHeader(inventory)
end

----------------------------------------------------------------
-- CATEGORIES
----------------------------------------------------------------

function manager.AddCategoryToInventory(inventory: Inventory, category: string | CategoryDef)
	assert(inventory, "inventory required")
	assert(category ~= nil, "category required")

	local def = normaliseCategory(category)
	if not def then
		return
	end

	if inventory._categoryByName[def.Name] then
		warnf("category %s already exists", def.Name)
		return
	end

	table.insert(inventory._categories, def)
	inventory._categoryByName[def.Name] = def
	inventory._inventories[def.Name] = {}

	local list = categoryList(inventory)
	local content = contentRoot(inventory)
	if not list or not content then
		warnf("Pointers are not wired; cannot build category UI")
		return
	end

	local button = _templates.Category_Container:Clone()
	button.Name = def.Name
	button.LayoutOrder = def.LayoutOrder or #inventory._categories
	button.Parent = list

	local inner = button:FindFirstChild("Button")
	local title = inner and inner:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Text = def.Name
	end

	-- Icon is optional: leave the authored placeholder when none is given.
	local icon = inner and inner:FindFirstChild("ImageLabel")
	if icon and icon:IsA("ImageLabel") and def.Icon then
		icon.Image = def.Icon
	end

	local stroke = inner and inner:FindFirstChild("UIStroke")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Enabled = false
	end

	local contentFrame = _templates.CategoryContent:Clone()
	contentFrame.Name = def.Name
	contentFrame.Visible = false
	contentFrame.Parent = content

	if inner and inner:IsA("GuiButton") then
		inner.MouseButton1Click:Connect(function()
			-- Clicking the active category clears the filter back to _all.
			if inventory._currentCategory == def.Name then
				showCategory(inventory, nil)
			else
				showCategory(inventory, def.Name)
			end
		end)
	end

	refreshHeader(inventory)
	return def
end

function manager.GetCategories(inventory: Inventory): { CategoryDef }
	return inventory._categories
end

function manager.GetCategory(inventory: Inventory, category: string | CategoryDef): CategoryDef?
	local name = resolveCategoryName(inventory, category)
	return name and inventory._categoryByName[name] or nil
end

----------------------------------------------------------------
-- ITEMS
--
-- Items are data. Each one renders into its own category frame AND into the
-- _all frame, so the unfiltered view needs no special-casing when switching.
----------------------------------------------------------------

-- Assigned by the hotbar section below; renderItem is defined before it.
local bindItemDrag

-- Selection highlight needs a stroke. Templates are not required to author
-- one, so create it on demand, disabled, and reuse it thereafter.
local function selectionStroke(entry: Instance): UIStroke?
	local inner = entry:FindFirstChild("Button")
	if not inner then
		return nil
	end
	local stroke = inner:FindFirstChild("__WiltedSelection")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Name = "__WiltedSelection"
		stroke.Thickness = 3
		stroke.Color = Color3.fromRGB(255, 255, 255)
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Enabled = false
		stroke.Parent = inner
	end
	return stroke
end

-- OPTIONAL ICON RENDERER. Game code may supply fn(iconLabel, item) to draw
-- something richer than item.Icon (e.g. a 3D model viewport). The service
-- still knows nothing about the game; it just calls the hook after painting.
local iconRenderer: ((ImageLabel, any) -> ())? = nil
function manager.SetIconRenderer(fn)
	iconRenderer = fn
end
local function runIconRenderer(icon, item)
	if iconRenderer and icon and item then
		local ok, err = pcall(iconRenderer, icon, item)
		if not ok then
			warnf("icon renderer: %s", tostring(err))
		end
	end
end

local refreshHotbarHook

local function renderItem(inventory: Inventory, item: ItemDef, parent: Instance)
	local entry = _templates.InventoryItem_Container:Clone()
	entry.Name = item.Id or item.Name or "Item"

	local inner = entry:FindFirstChild("Button")
	local title = inner and inner:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		local label = item.Name or item.Id or "Item"
		if item.Count and item.Count > 1 then
			label = string.format("%s x%d", label, item.Count)
		end
		title.Text = label
	end

	local icon = inner and inner:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") and item.Icon then
		icon.Image = item.Icon
	end
	if icon and icon:IsA("ImageLabel") then
		runIconRenderer(icon, item)
	end

	entry:SetAttribute("ItemId", item.Id)
	entry:SetAttribute("Category", item.Category)
	entry:SetAttribute("Locked", item.Locked == true)

	-- Caller-supplied attributes, copied verbatim. The service assigns no
	-- meaning to them; they exist so game code can tag entries it renders.
	if type(item.Attributes) == "table" then
		for key, value in pairs(item.Attributes) do
			entry:SetAttribute(key, value)
		end
	end

	-- Redraws must not lose the highlight.
	local isSelected = inventory._selectedItemId ~= nil and item.Id == inventory._selectedItemId
	entry:SetAttribute("Selected", isSelected)
	local selStroke = selectionStroke(entry)
	if selStroke then
		selStroke.Enabled = isSelected
	end

	-- One generic click hook. The service does not interpret the item.
	if inner and inner:IsA("GuiButton") then
		inner.MouseButton1Click:Connect(function()
			-- Entries built before the lock was applied still exist, so the
			-- check is here at click time rather than at build time.
			if isLocked(inventory) then
				return
			end
			local handler = inventory._onItemActivated
			if handler then
				handler(item, entry)
			end
		end)
	end

	if inner and inner:IsA("GuiButton") and bindItemDrag and item.Id then
		bindItemDrag(inventory, inner, item.Id, entry)
	end

	entry.Parent = parent
	return entry
end

-- An item assigned to a hotbar slot is hidden from the list views when
-- HideHotbarItems is on, so it reads as having MOVED rather than being in
-- two places. On by default (an item shows in one place only); pass
-- HideHotbarItems = false to show hotbar items in the list as well.
-- Assigned after redrawCategory exists; lets the hotbar refresh list views.
local redrawCategoryHook

-- Fulfilled by finishDrag below. Declared here so SetLocked can cancel a drag
-- that is in flight; declaring it below its callers would silently create a
-- global instead.
local finishDragHook

-- LOCK STATE moved to the top of the file, above every use - see the comment
-- there. It must stay above renderItem, whose click handler consults it.

local function hiddenByHotbar(inventory: Inventory, item: ItemDef): boolean
	if not inventory.HideHotbarItems then
		return false
	end
	for _, held in pairs(inventory.Hotbar._slots) do
		if held == item.Id then
			return true
		end
	end
	return false
end

local function redrawCategory(inventory: Inventory, categoryName: string)
	local content = contentRoot(inventory)
	if not content then
		return
	end

	local frame = content:FindFirstChild(categoryName)
	local allFrame = content:FindFirstChild(ALL_CATEGORY)

	-- Clear only this category's entries; layout objects must survive.
	for _, root in ipairs({ frame, allFrame }) do
		if root then
			for _, child in ipairs(root:GetChildren()) do
				if child:IsA("GuiObject") and child:GetAttribute("ItemId") ~= nil then
					if root == frame or child:GetAttribute("Category") == categoryName then
						child:Destroy()
					end
				end
			end
		end
	end

	for _, item in ipairs(inventory._inventories[categoryName] or {}) do
		if not hiddenByHotbar(inventory, item) then
			if frame then
				renderItem(inventory, item, frame)
			end
			if allFrame then
				renderItem(inventory, item, allFrame)
			end
		end
	end

	refreshHeader(inventory)
	-- Entries were rebuilt, so hotbar slots must re-resolve their ids.
	if refreshHotbarHook then
		refreshHotbarHook(inventory)
	end
end

redrawCategoryHook = redrawCategory

function manager.AddItemToInventory(inventory: Inventory, category: string | CategoryDef, item: ItemDef | string)
	assert(inventory, "inventory required")

	local name = resolveCategoryName(inventory, category)
	if not name or not inventory._categoryByName[name] then
		warnf("unknown category: %s", tostring(name))
		return nil
	end

	local def: ItemDef = type(item) == "string" and { Name = item } or item
	def.Category = name
	def.Id = def.Id or HttpService:GenerateGUID(false)

	local list = inventory._inventories[name]
	local limit = inventory._categoryByName[name].Limit
	if limit and #list >= limit then
		warnf("%s is full (%d/%d)", name, #list, limit)
		return nil
	end

	table.insert(list, def)
	redrawCategory(inventory, name)
	return def
end

function manager.RemoveItemFromInventory(inventory: Inventory, category: string | CategoryDef, itemId: string)
	local name = resolveCategoryName(inventory, category)
	local list = name and inventory._inventories[name]
	if not list then
		return false
	end

	for index, item in ipairs(list) do
		if item.Id == itemId then
			-- Locked items (a starter bat, say) cannot be dropped.
			if item.Locked then
				warnf("item is locked: %s", tostring(itemId))
				return false
			end
			table.remove(list, index)
			redrawCategory(inventory, name)
			return true
		end
	end
	return false
end

function manager.GetItems(inventory: Inventory, category: (string | CategoryDef)?): { ItemDef }
	if category == nil then
		local all = {}
		for _, def in ipairs(inventory._categories) do
			for _, item in ipairs(inventory._inventories[def.Name]) do
				table.insert(all, item)
			end
		end
		return all
	end

	local name = resolveCategoryName(inventory, category)
	return (name and inventory._inventories[name]) or {}
end

----------------------------------------------------------------
-- TITLE
----------------------------------------------------------------

function manager.SetInventoryTitle(inventory: Inventory, titleText: string?)
	assert(inventory, "inventory required")
	inventory.InventoryTitle = titleText
	local label = pointer(inventory, "InventoryTitle_TextLabel")
	if label and label:IsA("TextLabel") then
		label.Text = titleText or ""
	end
end


----------------------------------------------------------------
-- HOTBAR
--
-- The hotbar is just another container of item ids: N slots, each holding an
-- id or nil. It stores NO item data of its own, so an item can never exist in
-- the hotbar but not the inventory. Slots render by looking the id back up.
--
-- Slot frames are discovered under Gui.Hotbar and ordered by the leading
-- number in their name (1_HotbarItem_Container), falling back to LayoutOrder.
-- The service assigns no meaning to what a slot holds.
----------------------------------------------------------------

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local function hotbarRoot(inventory: Inventory): Instance?
	return pointer(inventory, "Hotbar_Frame") or inventory.Gui:FindFirstChild("Hotbar", true)
end

-- Ordered slot frames. Cached per inventory because this runs on every drag.
local function hotbarSlots(inventory: Inventory): { Instance }
	if inventory.Hotbar._frames then
		return inventory.Hotbar._frames
	end

	local root = hotbarRoot(inventory)
	local frames = {}
	if not root then
		return frames
	end

	for _, child in ipairs(root:GetChildren()) do
		if child:IsA("GuiObject") then
			local index = tonumber(string.match(child.Name, "^(%d+)")) or child.LayoutOrder
			if index and index > 0 then
				frames[index] = child
			end
		end
	end

	inventory.Hotbar._frames = frames
	return frames
end

local function findItemById(inventory: Inventory, itemId: string?): ItemDef?
	if not itemId then
		return nil
	end
	for _, item in ipairs(manager.GetItems(inventory)) do
		if item.Id == itemId then
			return item
		end
	end
	return nil
end

-- Paints one slot from whatever id it holds. The number label is authored
-- content, so it is left alone.
local function renderSlot(inventory: Inventory, index: number)
	local frame = hotbarSlots(inventory)[index]
	if not frame then
		return
	end

	local itemId = inventory.Hotbar._slots[index]
	local item = findItemById(inventory, itemId)

	--[[
		AN UNRESOLVABLE ID IS NOT PROOF THE ITEM IS GONE.

		This used to do `_slots[index] = nil` whenever an id failed to resolve,
		on the assumption that a missing item means a deleted item. That is not
		safe: `SetItems` truncates to the category's `Limit`, so any id past the
		limit is unresolvable while still being perfectly valid. Worse, the wipe
		ran synchronously inside SetHotbarSlot, so assigning such an id cleared
		it in the same call - the slot could never be filled at all.

		That silently broke the steal loop: a stolen egg lands at the END of the
		bag, which is exactly the region a Limit drops.

		Render it as empty instead, and leave the id parked. Deciding that an
		item is really gone needs the authoritative server list, which the owner
		of that list already does (InventoryClient.forgetMissing clears slots
		whose id is absent from the payload).
	]]

	local button = frame:FindFirstChild("Button")
	if not button then
		return
	end

	frame:SetAttribute("ItemId", itemId)

	local icon = button:FindFirstChild("__WiltedIcon")
	if not icon then
		icon = Instance.new("ImageLabel")
		icon.Name = "__WiltedIcon"
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromScale(0.8, 0.8)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.ZIndex = (button.ZIndex or 1) + 1
		icon.Parent = button
	end

	local label = button:FindFirstChild("__WiltedLabel")
	if not label then
		label = UiText.label({
			Name = "__WiltedLabel",
			Size = UDim2.fromScale(1, 0.42),
			Position = UDim2.fromScale(0, 0.58),
			ZIndex = (button.ZIndex or 1) + 2,
		})
		label.Parent = button
	end

	if item then
		icon.Image = item.Icon or ""
		icon.Visible = item.Icon ~= nil
		label.Text = item.Name or ""
		label.Visible = true
		runIconRenderer(icon, item)
	else
		icon.Image = ""
		icon.Visible = false
		label.Text = ""
		label.Visible = false
	end

	-- Selection highlight. The authored slot carries its own "SelectedStroke"
	-- (styled in Studio, Enabled=false at rest), so use that when present and
	-- only fall back to a generated stroke for templates without one. Every
	-- SelectedStroke* on the container is driven, so a slot can author more
	-- than one layer.
	local selected = inventory.Hotbar._selectedSlot == index
	local foundAuthored = false
	if button then
		for _, child in ipairs(button:GetChildren()) do
			if child:IsA("UIStroke") and string.sub(child.Name, 1, 14) == "SelectedStroke" then
				child.Enabled = selected
				foundAuthored = true
			end
		end
	end
	if not foundAuthored then
		local stroke = button:FindFirstChild("__WiltedSelection")
		if not stroke then
			stroke = Instance.new("UIStroke")
			stroke.Name = "__WiltedSelection"
			stroke.Thickness = 3
			stroke.Color = Color3.fromRGB(255, 255, 255)
			stroke.Enabled = false
			stroke.Parent = button
		end
		stroke.Enabled = selected
	end
end

local function renderHotbar(inventory: Inventory)
	for index in pairs(hotbarSlots(inventory)) do
		renderSlot(inventory, index)
	end
end

----------------------------------------------------------------
-- HOTBAR API
----------------------------------------------------------------

refreshHotbarHook = renderHotbar

function manager.SetHotbarSlot(inventory: Inventory, index: number, itemId: string?)
	if not hotbarSlots(inventory)[index] then
		warnf("no hotbar slot %s", tostring(index))
		return false
	end

	-- An item lives in one slot at a time: clear any previous holder.
	if itemId then
		for slot, held in pairs(inventory.Hotbar._slots) do
			if held == itemId and slot ~= index then
				inventory.Hotbar._slots[slot] = nil
				renderSlot(inventory, slot)
			end
		end
	end

	-- Both the incoming and outgoing items may change list visibility.
	local previousId = inventory.Hotbar._slots[index]
	inventory.Hotbar._slots[index] = itemId
	renderSlot(inventory, index)

	if inventory.HideHotbarItems and redrawCategoryHook then
		local touched = {}
		-- Numeric loop, not ipairs: ipairs stops at the first nil, so when
		-- the slot was empty (previousId nil) the incoming item was never
		-- redrawn and stayed visible in the list.
		local ids = { previousId, itemId }
		for i = 1, 2 do
			local item = findItemById(inventory, ids[i])
			if item and item.Category and not touched[item.Category] then
				touched[item.Category] = true
				redrawCategoryHook(inventory, item.Category)
			end
		end
	end

	if inventory._onHotbarChanged then
		inventory._onHotbarChanged(index, itemId)
	end
	return true
end

function manager.GetHotbarSlot(inventory: Inventory, index: number): ItemDef?
	return findItemById(inventory, inventory.Hotbar._slots[index])
end

-- The RAW id a slot holds, without resolving it against registered items.
--
-- WHY BOTH EXIST: GetHotbarSlot returns the resolved ItemDef and therefore
-- nil when a slot holds an id that is not currently registered (a category
-- Limit can truncate the tail of a large bag). Callers that need to know
-- "what id is parked here" - rather than "what item is here" - must not be
-- lied to by that resolution step, or they cannot repair the situation.
function manager.GetHotbarSlotId(inventory: Inventory, index: number): string?
	return inventory.Hotbar._slots[index]
end

function manager.ClearHotbarSlot(inventory: Inventory, index: number)
	return manager.SetHotbarSlot(inventory, index, nil)
end

-- Swaps two slots, which is what a hotbar-to-hotbar drag means.
function manager.SwapHotbarSlots(inventory: Inventory, a: number, b: number)
	local slots = inventory.Hotbar._slots
	slots[a], slots[b] = slots[b], slots[a]
	renderSlot(inventory, a)
	renderSlot(inventory, b)
	if inventory._onHotbarChanged then
		inventory._onHotbarChanged(a, slots[a])
		inventory._onHotbarChanged(b, slots[b])
	end
end

-- First empty slot, or nil when full.
function manager.FirstFreeHotbarSlot(inventory: Inventory): number?
	local frames = hotbarSlots(inventory)
	for index = 1, #frames do
		if frames[index] and not inventory.Hotbar._slots[index] then
			return index
		end
	end
	return nil
end

function manager.SelectHotbarSlot(inventory: Inventory, index: number?)
	-- Locked: refuse to select anything NEW, but always allow clearing, so a
	-- lock applied at the same moment as an unequip cannot leave the slot
	-- stuck highlighted.
	if index ~= nil and isLocked(inventory) then
		return
	end

	inventory.Hotbar._selectedSlot = index or 0
	renderHotbar(inventory)

	local item = index and manager.GetHotbarSlot(inventory, index) or nil
	-- Keep the two selections in step: selecting a slot selects its item.
	manager.SetSelectedItem(inventory, item and item.Id or nil)

	if inventory._onHotbarSelected then
		inventory._onHotbarSelected(index, item)
	end
end

function manager.GetSelectedHotbarSlot(inventory: Inventory): number?
	local slot = inventory.Hotbar._selectedSlot
	return slot ~= 0 and slot or nil
end

function manager.SetHotbarChangedHandler(inventory: Inventory, handler)
	inventory._onHotbarChanged = handler
end

function manager.SetHotbarSelectedHandler(inventory: Inventory, handler)
	inventory._onHotbarSelected = handler
end

function manager.RefreshHotbar(inventory: Inventory)
	renderHotbar(inventory)
end

----------------------------------------------------------------
-- LOCKING
--
-- A locked inventory is fully inert: no clicks, no drags, no selection, and
-- the whole ScreenGui is hidden. Used while something else owns the player's
-- hands - carrying a stolen egg, in particular.
--
-- WHY A SERVICE-LEVEL LOCK AND NOT JUST Gui.Enabled = false.
-- Hiding the GUI stops the player SEEING the inventory but not USING it: the
-- number-key hotbar binds are UserInputService connections that do not care
-- whether anything is visible, so 1-9 still swapped items with the UI hidden.
-- Every interaction entry point therefore checks this one flag, which also
-- means a future entry point only has to consult `isLocked` to be covered.
--
-- CLEARING IS ALWAYS ALLOWED. Locking must never trap a selection: the steal
-- flow locks the inventory AND clears the equipped egg, and if the lock also
-- blocked SelectHotbarSlot(nil) the egg would stay highlighted as equipped
-- forever. Only selecting something NEW is refused.
----------------------------------------------------------------

function manager.SetLocked(inventory: Inventory, locked: boolean)
	locked = locked == true
	if inventory._locked == locked then
		return
	end
	inventory._locked = locked

	-- Any drag in flight dies with the lock, otherwise the ghost is left
	-- hanging on screen with no input left to finish it.
	if locked and inventory._drag then
		finishDragHook(inventory)
	end

	local frame = inventory.Gui:FindFirstChild("Inventory")
	if locked then
		-- Remember whether the bag was open so unlocking does not pop it open
		-- for a player who had it closed.
		inventory._wasOpen = frame and frame:IsA("GuiObject") and frame.Visible or false
		if frame and frame:IsA("GuiObject") then
			frame.Visible = false
		end
	else
		-- Restore exactly what was there before. The hotbar returns with the
		-- ScreenGui below regardless; only the BAG's open/closed state is
		-- restored, because re-opening a bag the player had closed would be a
		-- surprise popup every time they secured an egg.
		if frame and frame:IsA("GuiObject") then
			frame.Visible = inventory._wasOpen == true
		end
		inventory._wasOpen = nil
	end

	-- Hides the hotbar too, since it lives on the same ScreenGui.
	if inventory.Gui:IsA("ScreenGui") then
		inventory.Gui.Enabled = not locked
	end
end

function manager.IsLocked(inventory: Inventory): boolean
	return isLocked(inventory)
end


local function pointerPosition(): Vector2
	local location = UserInputService:GetMouseLocation()
	-- GetMouseLocation is screen space; AbsolutePosition excludes the inset.
	local inset = GuiService:GetGuiInset()
	return Vector2.new(location.X - inset.X, location.Y - inset.Y)
end

local function containsPoint(frame: GuiObject, point: Vector2): boolean
	local origin = frame.AbsolutePosition
	local size = frame.AbsoluteSize
	return point.X >= origin.X
		and point.X <= origin.X + size.X
		and point.Y >= origin.Y
		and point.Y <= origin.Y + size.Y
end

local function slotUnderPointer(inventory: Inventory, point: Vector2): number?
	for index, frame in pairs(hotbarSlots(inventory)) do
		if frame.Visible and containsPoint(frame, point) then
			return index
		end
	end
	return nil
end

local function overInventoryList(inventory: Inventory, point: Vector2): boolean
	local content = contentRoot(inventory)
	if not content or not (content :: GuiObject).Visible then
		return false
	end
	return containsPoint(content :: GuiObject, point)
end

-- Drag state is per inventory; a second press while dragging is ignored.
-- Builds the drag visual by CLONING the source entry, so the thing under the
-- cursor is literally the item's own frame rather than a stand-in that has to
-- be kept in visual sync with the template.
--
-- The clone is frozen: interaction off, layout constraints stripped, absolute
-- pixel size copied from the source. Layout objects (UIGridLayout/UIListLayout
-- on the parent) no longer apply once it is reparented to the ScreenGui, so
-- the size must be pinned or it collapses.
local function buildDragGhost(inventory: Inventory, item: ItemDef, sourceFrame: GuiObject?): GuiObject
	local ghost

	if sourceFrame then
		ghost = sourceFrame:Clone()

		-- A clone of a bound entry must not re-fire anything.
		for _, descendant in ipairs(ghost:GetDescendants()) do
			if descendant:IsA("GuiButton") then
				descendant.Active = false
				descendant.AutoButtonColor = false
			end
			-- Attributes carry binding marks; clear them so nothing treats
			-- the ghost as a real entry.
			descendant:SetAttribute("__WiltedBound", nil)
			descendant:SetAttribute("ItemId", nil)
		end
		ghost:SetAttribute("ItemId", nil)
		ghost:SetAttribute("__WiltedBound", nil)

		-- Size/position come from the layout that no longer applies.
		local size = sourceFrame.AbsoluteSize
		ghost.Size = UDim2.fromOffset(size.X, size.Y)

		-- Aspect constraints fight a fixed pixel size.
		for _, descendant in ipairs(ghost:GetDescendants()) do
			if descendant:IsA("UIAspectRatioConstraint") then
				descendant:Destroy()
			end
		end
	else
		-- Fallback when there is no source frame to copy.
		ghost = UiText.label({
			Size = UDim2.fromOffset(120, 34),
			BackgroundTransparency = 0,
			BackgroundColor3 = Color3.fromRGB(20, 22, 30),
			Text = item.Name or "Item",
		})
	end

	ghost.Name = "__WiltedDragGhost"
	ghost.AnchorPoint = Vector2.new(0.5, 0)
	ghost.Visible = true
	ghost.Active = false
	-- Must not eat the pointer, or the drop target under it is never found.
	ghost.Interactable = false
	ghost.LayoutOrder = 0
	ghost.ZIndex = 1000
	for _, descendant in ipairs(ghost:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = 1000 + descendant.ZIndex
			descendant.Interactable = false
		end
	end
	ghost.Parent = inventory.Gui

	return ghost
end

local function beginDrag(inventory: Inventory, itemId: string, fromSlot: number?, sourceFrame: GuiObject?)
	if inventory._drag then
		return
	end
	if isLocked(inventory) then
		return
	end

	local item = findItemById(inventory, itemId)
	if not item then
		return
	end

	-- Ghost lives on the ScreenGui so it is never clipped by the scrolling
	-- frame it started in.
	local ghost = buildDragGhost(inventory, item, sourceFrame)

	inventory._drag = { itemId = itemId, fromSlot = fromSlot, ghost = ghost }

	-- Dim the origin so it reads as being moved, not duplicated. The entry
	-- Frame is often fully transparent with the Button carrying the visuals,
	-- so fade every visible layer and record the originals for restore.
	if sourceFrame then
		local faded = {}
		local function fade(obj)
			if not obj:IsA("GuiObject") then
				return
			end
			if obj.BackgroundTransparency < 1 then
				table.insert(faded, { obj = obj, prop = "BackgroundTransparency", value = obj.BackgroundTransparency })
				obj.BackgroundTransparency += (1 - obj.BackgroundTransparency) * 0.6
			end
			if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.TextTransparency < 1 then
				table.insert(faded, { obj = obj, prop = "TextTransparency", value = obj.TextTransparency })
				obj.TextTransparency += (1 - obj.TextTransparency) * 0.6
			end
			if (obj:IsA("ImageLabel") or obj:IsA("ImageButton")) and obj.ImageTransparency < 1 then
				table.insert(faded, { obj = obj, prop = "ImageTransparency", value = obj.ImageTransparency })
				obj.ImageTransparency += (1 - obj.ImageTransparency) * 0.6
			end
		end
		fade(sourceFrame)
		for _, descendant in ipairs(sourceFrame:GetDescendants()) do
			fade(descendant)
		end
		inventory._drag.faded = faded
	end

	local point = pointerPosition()
	ghost.Position = UDim2.fromOffset(point.X, point.Y)
end

local function finishDrag(inventory: Inventory)
	local drag = inventory._drag
	if not drag then
		return
	end
	inventory._drag = nil
	if drag.ghost then
		drag.ghost:Destroy()
	end
	-- Undim the origin regardless of where the drop landed.
	if drag.faded then
		for _, record in ipairs(drag.faded) do
			if record.obj and record.obj.Parent then
				record.obj[record.prop] = record.value
			end
		end
	end

	-- A lock applied mid-drag cancels it: the ghost and the dimming are undone
	-- above, but the drop itself must not take effect.
	if isLocked(inventory) then
		return
	end

	local point = pointerPosition()
	local targetSlot = slotUnderPointer(inventory, point)

	if targetSlot then
		if drag.fromSlot then
			-- hotbar -> hotbar: swap, so neither item is lost
			if targetSlot ~= drag.fromSlot then
				manager.SwapHotbarSlots(inventory, drag.fromSlot, targetSlot)
			end
		else
			-- inventory -> hotbar
			manager.SetHotbarSlot(inventory, targetSlot, drag.itemId)
		end
	elseif drag.fromSlot and overInventoryList(inventory, point) then
		-- hotbar -> inventory: unassign. The item itself is untouched;
		-- it always lived in the inventory.
		manager.ClearHotbarSlot(inventory, drag.fromSlot)
	end
end

-- Fulfils the forward declaration so SetLocked can cancel a drag in flight.
finishDragHook = finishDrag

-- Called by renderItem and renderSlot to make a button draggable.
local function bindDragSource(inventory: Inventory, button: GuiObject, getItemId, fromSlot: number?, sourceFrame: GuiObject?)
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			local itemId = getItemId()
			if itemId then
				beginDrag(inventory, itemId, fromSlot, sourceFrame)
			end
		end
	end)
end

local function bindDragInput(inventory: Inventory)
	if inventory._dragBound then
		return
	end
	inventory._dragBound = true

	UserInputService.InputChanged:Connect(function(input)
		local drag = inventory._drag
		if not drag or not drag.ghost then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local point = pointerPosition()
			drag.ghost.Position = UDim2.fromOffset(point.X, point.Y)
		end
	end)

	-- Release anywhere ends the drag, including outside every frame.
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			finishDrag(inventory)
		end
	end)
end

-- Fulfils the forward declaration: inventory entries become drag sources.
bindItemDrag = function(inventory: Inventory, button: GuiObject, itemId: string, entryFrame: GuiObject?)
	bindDragSource(inventory, button, function()
		return itemId
	end, nil, entryFrame)
	bindDragInput(inventory)
end

-- Wires every hotbar slot for click-select and drag.
local function bindHotbar(inventory: Inventory)
	for index, frame in pairs(hotbarSlots(inventory)) do
		local button = frame:FindFirstChild("Button")
		if button and button:IsA("GuiButton") and not button:GetAttribute("__WiltedBound") then
			button:SetAttribute("__WiltedBound", true)

			button.MouseButton1Click:Connect(function()
				if isLocked(inventory) then
					return
				end
				-- Only a filled slot can be selected; clicking the active
				-- slot clears it.
				if inventory.Hotbar._slots[index] == nil then
					return
				end
				if inventory.Hotbar._selectedSlot == index then
					manager.SelectHotbarSlot(inventory, nil)
				else
					manager.SelectHotbarSlot(inventory, index)
				end
			end)

			bindDragSource(inventory, button, function()
				return inventory.Hotbar._slots[index]
			end, index, frame)
		end
	end
	bindDragInput(inventory)
	renderHotbar(inventory)
end

----------------------------------------------------------------
-- CONSTRUCTION
----------------------------------------------------------------

function manager:New(
	inventoryName: string?,
	config: {
		Categories: { string | CategoryDef }?,
		InventoryTitle: string?,
		HideHotbarItems: boolean?,
	}?
): (Inventory?, string?)
	if disabledReason then
		return nil, disabledReason
	end

	if not inventoryName then
		warnf("no inventoryName given, generating a GUID")
		inventoryName = HttpService:GenerateGUID(false)
	end

	if manager._inventories[inventoryName] then
		warnf("inventory %s already exists", inventoryName)
		return manager._inventories[inventoryName]
	end

	config = config or {}
	local categories = config.Categories or {}

	local gui = _templates.InventoryGui:Clone()
	rebindPointers(_templates.InventoryGui, gui)

	local inventory: Inventory = {
		Name = inventoryName,
		InventoryTitle = config.InventoryTitle or "Inventory",
		Gui = gui,
		-- When true an item in a hotbar slot is hidden from the list views.
		-- Default true: an item shows in one place only (Chris, Phase 7).
		HideHotbarItems = config.HideHotbarItems ~= false,
		Hotbar = {
			_slots = {},
			_selectedSlot = 0,
		},
		_categories = {},
		_categoryByName = {},
		_inventories = {},
		_currentCategory = "",
		-- Set by SetLocked; every interaction entry point consults it.
		_locked = false,
	}

	-- Methods (thin wrappers so call sites read as inventory:Verb()).

	function inventory:SetTitle(titleText: string?)
		manager.SetInventoryTitle(self, titleText)
	end

	function inventory:AddCategory(category: string | CategoryDef)
		return manager.AddCategoryToInventory(self, category)
	end

	function inventory:GetCategories()
		return manager.GetCategories(self)
	end

	function inventory:GetCategory(category: string | CategoryDef)
		return manager.GetCategory(self, category)
	end

	function inventory:AddItem(category: string | CategoryDef, item: ItemDef | string)
		return manager.AddItemToInventory(self, category, item)
	end

	function inventory:RemoveItem(category: string | CategoryDef, itemId: string)
		return manager.RemoveItemFromInventory(self, category, itemId)
	end

	function inventory:SetItems(category: string | CategoryDef, items: { ItemDef })
		return manager.SetItems(self, category, items)
	end

	function inventory:ClearCategory(category: string | CategoryDef)
		return manager.ClearCategory(self, category)
	end

	function inventory:OnItemActivated(handler)
		manager.SetItemActivatedHandler(self, handler)
	end

	function inventory:SetSelected(itemId: string?)
		manager.SetSelectedItem(self, itemId)
	end

	function inventory:SetHotbarSlot(index: number, itemId: string?)
		return manager.SetHotbarSlot(self, index, itemId)
	end

	function inventory:GetHotbarSlot(index: number)
		return manager.GetHotbarSlot(self, index)
	end

	function inventory:GetHotbarSlotId(index: number)
		return manager.GetHotbarSlotId(self, index)
	end

	function inventory:ClearHotbarSlot(index: number)
		return manager.ClearHotbarSlot(self, index)
	end

	function inventory:FirstFreeHotbarSlot()
		return manager.FirstFreeHotbarSlot(self)
	end

	function inventory:SelectHotbarSlot(index: number?)
		return manager.SelectHotbarSlot(self, index)
	end

	function inventory:GetSelectedHotbarSlot()
		return manager.GetSelectedHotbarSlot(self)
	end

	function inventory:OnHotbarChanged(handler)
		manager.SetHotbarChangedHandler(self, handler)
	end

	function inventory:OnHotbarSelected(handler)
		manager.SetHotbarSelectedHandler(self, handler)
	end

	function inventory:RefreshHotbar()
		manager.RefreshHotbar(self)
	end

	function inventory:GetSelected()
		return manager.GetSelectedItem(self)
	end

	function inventory:GetItems(category: (string | CategoryDef)?)
		return manager.GetItems(self, category)
	end

	function inventory:ShowCategory(category: (string | CategoryDef)?)
		showCategory(self, category and resolveCategoryName(self, category) or nil)
	end

	function inventory:SetVisible(visible: boolean)
		-- A locked inventory cannot be opened, including by other UI calling
		-- _G.OpenInventory. Closing is always permitted.
		if visible and isLocked(self) then
			return
		end
		local frame = self.Gui:FindFirstChild("Inventory")
		if frame and frame:IsA("GuiObject") then
			frame.Visible = visible
		end
	end

	function inventory:Toggle()
		if isLocked(self) then
			return
		end
		local frame = self.Gui:FindFirstChild("Inventory")
		if frame and frame:IsA("GuiObject") then
			frame.Visible = not frame.Visible
		end
	end

	--[[
		Lock or unlock every interaction.

		Locking hides the ScreenGui (list AND hotbar) and makes clicks, drags,
		number keys and selection inert. Unlocking restores the GUI and reopens
		the bag only if it was open when the lock was applied.
	]]
	function inventory:SetLocked(locked: boolean)
		manager.SetLocked(self, locked)
	end

	function inventory:IsLocked()
		return manager.IsLocked(self)
	end

	function inventory:Destroy()
		manager._inventories[self.Name] = nil
		self.Gui:Destroy()
	end

	-- Setup

	manager.SetInventoryTitle(inventory, inventory.InventoryTitle)

	for _, category in ipairs(categories) do
		inventory:AddCategory(category)
	end

	-- Start unfiltered so _all is the visible frame.
	showCategory(inventory, nil)
	bindHotbar(inventory)

	manager._inventories[inventoryName] = inventory
	return inventory
end

function manager:Get(inventoryName: string): (Inventory?, string?)
	if disabledReason then
		return nil, disabledReason
	end
	return manager._inventories[inventoryName], nil
end

----------------------------------------------------------------
-- BULK REPLACE, ACTIVATION, SELECTION
--
-- These stay game-blind: the service knows an item has an Id, a label, an
-- icon and a locked flag. What an item MEANS is the caller's business.
----------------------------------------------------------------

function manager.ClearCategory(inventory: Inventory, category: string | CategoryDef)
	local name = resolveCategoryName(inventory, category)
	if not name or not inventory._inventories[name] then
		return false
	end
	table.clear(inventory._inventories[name])
	redrawCategory(inventory, name)
	return true
end

-- Replace a category's contents in one pass. Callers driven by a server
-- snapshot should use this instead of Add/Remove churn: it is a single
-- redraw and it cannot drift out of sync with the source of truth.
function manager.SetItems(inventory: Inventory, category: string | CategoryDef, items: { ItemDef })
	local name = resolveCategoryName(inventory, category)
	if not name or not inventory._categoryByName[name] then
		warnf("unknown category: %s", tostring(name))
		return false
	end

	local list = inventory._inventories[name]
	table.clear(list)

	local limit = inventory._categoryByName[name].Limit
	for index, item in ipairs(items or {}) do
		if limit and index > limit then
			break
		end
		local def: ItemDef = type(item) == "string" and { Name = item } or item
		def.Category = name
		def.Id = def.Id or HttpService:GenerateGUID(false)
		table.insert(list, def)
	end

	redrawCategory(inventory, name)
	return true
end

-- Fired with (item, entryFrame) when an entry is clicked. One handler per
-- inventory; the caller decides what a click does.
function manager.SetItemActivatedHandler(inventory: Inventory, handler: ((ItemDef, Instance) -> ())?)
	inventory._onItemActivated = handler
end

-- Highlights one entry and clears the rest. Pass nil to clear all.
function manager.SetSelectedItem(inventory: Inventory, itemId: string?)
	inventory._selectedItemId = itemId

	local content = contentRoot(inventory)
	if not content then
		return
	end

	for _, frame in ipairs(content:GetChildren()) do
		if CollectionService:HasTag(frame, TAG_CATEGORY_CONTENT) then
			for _, entry in ipairs(frame:GetChildren()) do
				local id = entry:GetAttribute("ItemId")
				if id ~= nil then
					local isSelected = (itemId ~= nil and id == itemId)
					entry:SetAttribute("Selected", isSelected)
					local stroke = selectionStroke(entry)
					if stroke then
						stroke.Enabled = isSelected
					end
				end
			end
		end
	end
end

function manager.GetSelectedItem(inventory: Inventory): ItemDef?
	if not inventory._selectedItemId then
		return nil
	end
	for _, item in ipairs(manager.GetItems(inventory)) do
		if item.Id == inventory._selectedItemId then
			return item
		end
	end
	return nil
end

-- Directory registration (decision 8). The client half of a service
-- registers at require; this module is that client half.
if Core then
	Core.Services.Register("Inventory", manager)
end

return manager
