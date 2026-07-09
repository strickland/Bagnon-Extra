--[[
	Bagnon Extra
	------------
	A small companion for Bagnon / Bagnonium that adds:

	1) Locked containers (lockboxes, chests, anything you don't currently
	   have the key/skill/tool to open) get a red tint over their icon.

	2) Items whose tooltip shows a charge count (e.g. "Charges: 3") get a
	   yellow "x3" label in the bottom right corner of the icon.

	3) (Bagnonium only, when Bagnon isn't also loaded) Profession recipes
	   for a profession you haven't learned get a blue tint. Bagnon
	   already does this natively; Bagnonium doesn't, so we add it only
	   when Bagnonium is the one actually in use.

	4) (Same condition as #3) Class-restricted tokens whose tooltip
	   "Classes:" line doesn't include your class get the same blue tint.

	5) Equippable gear (weapons, armor, trinkets, etc.) whose tooltip
	   shows a requirement you don't meet -- profession skill, zone,
	   faction, level, and so on -- gets a pink tint. Works regardless
	   of which of Bagnon/Bagnonium is loaded.

	6) Openable containers (caches, chests, anything with a "Right
	   Click to Open" tooltip line, or a name suggesting the same) get
	   a yellow "OPN" label in the bottom left corner.

	7) Learnable mounts, companion pets, and toys get a bright orange "LRN"
	   label in the same bottom-left corner (mutually exclusive with
	   #6 -- an item is never both).

	Implementation notes:

	- Bagnon and Bagnonium share the same underlying engine (Wildpants,
	  formerly BagBrother), so their item buttons follow the same
	  "<Prefix><index>" naming convention, just with a different addon
	  name as the prefix (e.g. "BagnonContainerItem25"). We build the
	  prefix list from whichever of the two addons is actually loaded.
	  Bagnonium was formerly named Combuctor, so its legacy prefix is
	  included as a fallback in case any frame names still carry it.

	- We read buttons directly (button.bag / button:GetID()) rather
	  than through Bagnon/Bagnonium's internal plugin classes, since
	  those class names have shifted across versions and skins.

	- The "locked" field from GetContainerItemInfo/C_Container.
	  GetContainerItemInfo is a SERVER lock flag (brief drag-lock during
	  item moves, rare server-managed locked caches). It does NOT cover
	  ordinary lockboxes/junkboxes you simply lack the lockpicking skill
	  or key for -- those only reveal their locked status as a plain
	  "Locked" line of tooltip text, which we scan for as well.

	- There's no clean boolean API for "can I equip this item right
	  now" that covers professions/zones/factions all at once. Blizzard
	  already colors the failing requirement line red in the tooltip
	  itself, so feature #5 detects that color directly rather than
	  trying to special-case every requirement type.

	- Only works against your OWN live bags and bank (while at a
	  banker). Viewing a cached/other character (e.g. right-clicking to
	  an alt via BagBrother) is explicitly skipped via the item
	  button's own IsCached() check -- container queries like
	  GetContainerItemInfo always read your currently logged-in
	  character's live bags, so without that guard a cached button
	  would get tinted using an unrelated item from your own bags at
	  the same bag/slot number.

	- Performance: scanning an item's tooltip is the expensive part of
	  this addon. Each button caches a lightweight numeric fingerprint
	  of its current item (no table allocation) and only does the real
	  work -- fetching the full item link and scanning its tooltip --
	  when that fingerprint changes, or when a relevant game event (bag
	  update, profession learned) forces a full refresh. A once-a-second
	  safety-net timer catches anything event-driven updates might miss,
	  but reuses the same cheap fingerprint check so it costs almost
	  nothing when bags are sitting idle. The profession/class-token
	  checks are skipped entirely (no extra cost at all) unless
	  Bagnonium-without-Bagnon is actually detected.
]]

local hasBagnon = _G.Bagnon ~= nil
local hasBagnonium = _G.Bagnonium ~= nil

if not hasBagnon and not hasBagnonium then
	return
end

-- The recipe/class-token tint is only meant to fill the gap in
-- Bagnonium, since Bagnon already marks unknown-profession recipes on
-- its own.
local ENABLE_EXTRA_WARNINGS = hasBagnonium and not hasBagnon

-----------------------------------------------------------
-- Config
-----------------------------------------------------------

local LOCK_COLOR        = { r = 0.65, g = 0.05, b = 0.05, a = 0.55 } -- red taint over locked items
local CHARGE_COLOR      = { r = 1.00, g = 0.85, b = 0.10, a = 1.00 } -- yellow charge text
local WARNING_COLOR     = { r = 0.10, g = 0.35, b = 0.95, a = 0.55 } -- blue taint for unusable recipes/tokens
local RESTRICTION_COLOR = { r = 1.00, g = 0.35, b = 0.65, a = 0.45 } -- clear pink taint for gear you can't equip (profession/zone/etc requirement not met)
local OPENABLE_COLOR    = { r = 1.00, g = 0.85, b = 0.10, a = 1.00 } -- yellow "OPN" text for openable caches/chests
local LEARNABLE_COLOR   = { r = 1.00, g = 0.60, b = 0.10, a = 1.00 } -- bright orange "LRN" text for learnable mounts/pets/toys
local CHARGE_FONT_SIZE = 12

local LOCKED_STRING = _G.LOCKED -- localized "Locked", used by Blizzard's own UI elsewhere
local OPENABLE_STRING = _G.ITEM_OPENABLE -- localized "<Right Click to Open>"
local PLAYER_CLASS_NAME = (UnitClass("player"))
local RECIPE_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Recipe) or 9
local PROFESSION_CLASS_ID = Enum and Enum.ItemClass and Enum.ItemClass.Profession -- added in Dragonflight; nil on older clients
local ARMOR_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4
local WEAPON_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local MISC_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Miscellaneous) or 15
local MOUNT_SUBCLASS_ID = 5 -- Enum.ItemSubclass.Miscellaneous.Mount, but that enum path isn't reliably exposed; the numeric ID is stable
local PET_SUBCLASS_ID = 2 -- companion pets

local SAFETY_NET_INTERVAL = 1.0 -- seconds between cache-only safety-net passes

-- Blizzard colors a tooltip requirement line (profession, zone, faction,
-- level, etc.) red when you don't meet it, and white/normal when you do.
-- There's no clean boolean API for "can I equip this", so we detect the
-- red color directly. These thresholds distinguish it from item-quality
-- colors (green/blue/purple/orange item names, none of which are this
-- red/low-green/low-blue combination).
local REQUIREMENT_RED_MIN_R = 0.75
local REQUIREMENT_RED_MAX_G = 0.35
local REQUIREMENT_RED_MAX_B = 0.35

-- Item buttons across Bagnon/Bagnonium's windows follow this
-- "<Prefix><index>" naming scheme.
local BUTTON_PREFIXES = {}
local function AddPrefixSet(addonName)
	table.insert(BUTTON_PREFIXES, addonName .. "ContainerItem")
	table.insert(BUTTON_PREFIXES, addonName .. "BankItem")
	table.insert(BUTTON_PREFIXES, addonName .. "ReagentItem")
	table.insert(BUTTON_PREFIXES, addonName .. "VaultItem")
end
if hasBagnon then
	AddPrefixSet("Bagnon")
end
if hasBagnonium then
	AddPrefixSet("Bagnonium")
	AddPrefixSet("Combuctor") -- Bagnonium's former name; hedges against leftover frame names
end
local MAX_BUTTONS_PER_PREFIX = 220 -- generous ceiling; scanning stops early once a gap is found

-----------------------------------------------------------
-- Scanning tooltip (hidden, used only to read tooltip text)
-----------------------------------------------------------

local Scanner = _G.BagnonExtraScannerTooltip or CreateFrame("GameTooltip", "BagnonExtraScannerTooltip", nil, "GameTooltipTemplate")
local ScannerName = Scanner:GetName()

-----------------------------------------------------------
-- Widget caches (created once per item button, reused after)
-----------------------------------------------------------

local function GetLockOverlay(button)
	local overlay = button.ExtraLockOverlay
	if not overlay then
		overlay = button:CreateTexture(nil, "OVERLAY")
		overlay:SetAllPoints(button.icon or button.Icon or button.IconTexture or button)
		overlay:SetColorTexture(LOCK_COLOR.r, LOCK_COLOR.g, LOCK_COLOR.b, LOCK_COLOR.a)
		overlay:SetBlendMode("BLEND")
		overlay:Hide()
		button.ExtraLockOverlay = overlay
	end
	return overlay
end

local function GetChargeText(button)
	local fs = button.ExtraChargeText
	if not fs then
		fs = button:CreateFontString(nil, "OVERLAY")
		fs:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
		fs:SetFontObject(_G.NumberFontNormal or _G.GameFontNormal)
		fs:SetFont(fs:GetFont(), CHARGE_FONT_SIZE, "OUTLINE")
		fs:SetTextColor(CHARGE_COLOR.r, CHARGE_COLOR.g, CHARGE_COLOR.b, CHARGE_COLOR.a)
		fs:SetDrawLayer("OVERLAY", 7) -- sit above icon/other plugin overlays
		button.ExtraChargeText = fs
	end
	return fs
end

-- Bottom-left status label: "OPN" (yellow) for openable caches/chests,
-- "LRN" (purple) for learnable mounts/pets/toys. These two are
-- mutually exclusive on any single item, so one shared FontString
-- (text and color swapped as needed) covers both rather than creating
-- two separate widgets per button.
local function GetStatusText(button)
	local fs = button.ExtraStatusText
	if not fs then
		fs = button:CreateFontString(nil, "OVERLAY")
		fs:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 2, 2)
		fs:SetFontObject(_G.NumberFontNormal or _G.GameFontNormal)
		fs:SetFont(fs:GetFont(), CHARGE_FONT_SIZE, "OUTLINE")
		fs:SetDrawLayer("OVERLAY", 7)
		button.ExtraStatusText = fs
	end
	return fs
end

-- Blue tint for unusable recipes/tokens -- one shared overlay, same
-- simple full-icon tint technique as the lock overlay. This replaced
-- an earlier attempt using a thin colored border texture, which had
-- visibility problems (some items' own quality-color border sits
-- right at the icon edge and fought with a thin outline for space). A
-- full tint sidesteps that entirely and is lighter-weight too: one
-- texture instead of two border textures plus animation groups.
local function GetWarningTint(button)
	local tint = button.ExtraWarningTint
	if not tint then
		tint = button:CreateTexture(nil, "OVERLAY")
		tint:SetAllPoints(button.icon or button.Icon or button.IconTexture or button)
		tint:SetColorTexture(WARNING_COLOR.r, WARNING_COLOR.g, WARNING_COLOR.b, WARNING_COLOR.a)
		tint:SetBlendMode("BLEND")
		tint:Hide()
		button.ExtraWarningTint = tint
	end
	return tint
end

-- Pink tint for gear (weapons/armor/trinkets/etc.) whose tooltip shows
-- a requirement you don't meet -- profession skill, zone/area, faction,
-- level, and so on. Same full-icon-tint approach as the other overlays.
local function GetRestrictionTint(button)
	local tint = button.ExtraRestrictionTint
	if not tint then
		tint = button:CreateTexture(nil, "OVERLAY")
		tint:SetAllPoints(button.icon or button.Icon or button.IconTexture or button)
		tint:SetColorTexture(RESTRICTION_COLOR.r, RESTRICTION_COLOR.g, RESTRICTION_COLOR.b, RESTRICTION_COLOR.a)
		tint:SetBlendMode("BLEND")
		tint:Hide()
		button.ExtraRestrictionTint = tint
	end
	return tint
end

-----------------------------------------------------------
-- Container info (retail C_Container vs classic globals)
-----------------------------------------------------------

local function GetContainerItemLink(bag, slot)
	if C_Container and C_Container.GetContainerItemInfo then
		local info = C_Container.GetContainerItemInfo(bag, slot)
		return info and info.hyperlink
	elseif C_Container and C_Container.GetContainerItemLink then
		return C_Container.GetContainerItemLink(bag, slot)
	else
		-- Must go through _G explicitly: without it, this would resolve
		-- to this very same local function (same name) and recurse
		-- forever on any client old enough to lack C_Container entirely.
		return _G.GetContainerItemLink(bag, slot)
	end
end

-- Returns just the numeric item ID in a slot, with no table allocation.
-- Used as a cheap "has anything changed" fingerprint for the frequent
-- safety-net pass, since C_Container.GetContainerItemInfo allocates a
-- fresh table on every single call.
local function GetQuickItemID(bag, slot)
	if C_Container and C_Container.GetContainerItemID then
		return C_Container.GetContainerItemID(bag, slot)
	else
		return GetContainerItemID(bag, slot)
	end
end

-----------------------------------------------------------
-- Tooltip scan: looks for a "Locked" line, a charge count, a
-- "Classes:" restriction line (only when needed), any red-colored
-- requirement line (profession/zone/faction/level/etc. not met), and
-- whether the item is an openable container, all in one pass.
-----------------------------------------------------------

-- Fallback for openable containers whose tooltip doesn't show the
-- "Right Click to Open" line for whatever reason (older client,
-- unusual item setup) -- matches common naming patterns instead.
-- Deliberately short and conservative to avoid false positives on
-- ordinary bags/quivers that happen to share a word. "chest" is
-- deliberately excluded -- too many chest-slot armor pieces are
-- literally named "X Chestpiece"/"Chest of Y", which would falsely
-- flag gear as an openable container.
local OPENABLE_NAME_KEYWORDS = { "cache", "coffer", "stash", "footlocker", "satchel", "lockbox", "giftwrap", "parcel", "bundle" }

local function NameSuggestsOpenable(name)
	if not name then
		return false
	end
	local lower = name:lower()
	for _, keyword in ipairs(OPENABLE_NAME_KEYWORDS) do
		if lower:find(keyword, 1, true) then
			return true
		end
	end
	return false
end

local function ScanTooltipLines()
	local isLockedText = false
	local charges = nil
	local classesLine = nil
	local hasFailedRequirement = false
	local isOpenable = false
	local itemNameLine = nil

	local numLines = Scanner:NumLines()
	for i = 1, numLines do
		local line = _G[ScannerName .. "TextLeft" .. i]
		if line then
			local text = line:GetText()
			if text then
				if i == 1 then
					itemNameLine = text -- line 1 is always the item name
				end

				if not isLockedText then
					if (LOCKED_STRING and text == LOCKED_STRING) or text:match("^[Ll]ocked$") then
						isLockedText = true
					end
				end

				if not charges then
					local n = text:match("^[Cc]harges:?%s*(%d+)") or text:match("(%d+)%s+[Cc]harges")
					if n then
						charges = tonumber(n)
					end
				end

				if ENABLE_EXTRA_WARNINGS and not classesLine then
					classesLine = text:match("^[Cc]lasses:%s*(.+)$")
				end

				if not isOpenable then
					if (OPENABLE_STRING and text == OPENABLE_STRING) or text:match("[Rr]ight [Cc]lick to [Oo]pen") then
						isOpenable = true
					end
				end

				-- Line 1 is always the item name, whose color reflects
				-- item quality/rarity (green/blue/purple/orange), not a
				-- requirement -- skip it so a legendary/heirloom name
				-- doesn't get mistaken for a failed requirement.
				if i > 1 and not hasFailedRequirement then
					local r, g, b = line:GetTextColor()
					if r and r >= REQUIREMENT_RED_MIN_R
						and g and g <= REQUIREMENT_RED_MAX_G
						and b and b <= REQUIREMENT_RED_MAX_B then
						hasFailedRequirement = true
					end
				end
			end
		end
	end

	if not isOpenable then
		isOpenable = NameSuggestsOpenable(itemNameLine)
	end

	return isLockedText, charges, classesLine, hasFailedRequirement, isOpenable
end

local function ScanTooltip(bag, slot)
	Scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
	Scanner:ClearLines()

	-- The main bank container's slots are technically special
	-- "inventory slots" under the hood (the same category as equipped
	-- gear), not real bag slots -- so GameTooltip:SetBagItem silently
	-- returns an empty tooltip for them. They need to go through
	-- SetInventoryItem instead, with the slot number converted via
	-- BankButtonIDToInvSlotID. Extra bank BAGS (positive IDs) are real
	-- containers and work fine through the normal SetBagItem path.
	if bag == (_G.BANK_CONTAINER or -1) and _G.BankButtonIDToInvSlotID then
		Scanner:SetInventoryItem("player", BankButtonIDToInvSlotID(slot))
	else
		Scanner:SetBagItem(bag, slot)
	end

	return ScanTooltipLines()
end

-----------------------------------------------------------
-- Profession / class-token checks (Bagnonium-only feature)
-----------------------------------------------------------

local knownProfessions = {}

local function RefreshKnownProfessions()
	wipe(knownProfessions)
	local prof1, prof2, _archaeology, fishing, cooking = GetProfessions()
	for _, index in ipairs({ prof1, prof2, fishing, cooking }) do
		if index then
			local name = GetProfessionInfo(index)
			if name then
				knownProfessions[name:lower()] = true
			end
		end
	end
end

local function IsUnknownProfessionRecipe(itemLink)
	local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	if not getInstant then
		return false -- extremely old client without this API; feature just no-ops
	end

	local _, _, itemSubType, _, _, itemClassID, itemSubClassID = getInstant(itemLink)

	if not itemClassID or not itemSubType then
		return false
	end

	if itemClassID == RECIPE_CLASS_ID then
		-- Legacy "Recipe" class: subclass 0 is a generic "Book", not a
		-- specific profession, so it doesn't count.
		if not itemSubClassID or itemSubClassID == 0 then
			return false
		end
	elseif PROFESSION_CLASS_ID and itemClassID == PROFESSION_CLASS_ID then
		-- Newer "Profession" class (added in the Dragonflight profession
		-- revamp). Every subclass here is a real profession, including
		-- subclass 0 (Blacksmithing), so no skip needed.
	else
		return false -- not a recipe/profession item at all
	end

	return not knownProfessions[itemSubType:lower()]
end

local function IsMissingClassToken(classesLine)
	if not classesLine then
		return false
	end
	for name in classesLine:gmatch("[^,]+") do
		name = name:match("^%s*(.-)%s*$")
		if name:lower() == PLAYER_CLASS_NAME:lower() then
			return false -- your class is listed, nothing to warn about
		end
	end
	return true
end

-----------------------------------------------------------
-- Equip-requirement check (works regardless of which bag addon is
-- loaded -- unlike the recipe/token blue tint, neither Bagnon nor
-- Bagnonium already covers this).
--
-- "hasFailedRequirement" comes from the tooltip color scan; here we
-- only need to confirm the item is actually gear you wear (armor or
-- weapon -- covers weapons, shields, trinkets, rings, necks, cloaks,
-- everything worn). This deliberately checks itemClassID rather than
-- itemEquipLoc: bags/quivers also carry a non-empty equip slot
-- (INVTYPE_BAG), so an equip-slot check wrongly caught lockboxes too,
-- stacking a pink tint on top of their red locked tint. Item class is
-- the precise "is this gear" signal and has no such overlap.
--
-- Before falling back to the tooltip-color guess, we check the item's
-- actual itemMinLevel field (same approach the Bagnon Required Level
-- addon uses for its own level check) -- a plain "too low level"
-- restriction, the single most common reason gear can't be equipped,
-- is exposed as a real number, so there's no need to infer it from
-- text color. This doesn't reduce how often we scan tooltips (lock
-- and charge detection already need that scan on every item
-- regardless), but it does mean the most common restriction is
-- confirmed from data rather than a color-matching heuristic.
-----------------------------------------------------------

local function GetItemInfoCompat(itemLink)
	if C_Item and C_Item.GetItemInfo then
		return C_Item.GetItemInfo(itemLink)
	else
		return GetItemInfo(itemLink)
	end
end

local function IsRestrictedGear(itemLink, hasFailedRequirement)
	local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	if not getInstant then
		return false -- extremely old client without this API; feature just no-ops
	end

	local _, _, _, _, _, itemClassID = getInstant(itemLink)
	if itemClassID ~= ARMOR_CLASS_ID and itemClassID ~= WEAPON_CLASS_ID then
		return false -- not gear you actually wear; nothing to flag
	end

	local _, _, _, _, itemMinLevel = GetItemInfoCompat(itemLink)
	if itemMinLevel and itemMinLevel > 0 and UnitLevel("player") < itemMinLevel then
		return true -- confirmed by data: definitely a level requirement you don't meet
	end

	-- Anything else (profession/zone/faction requirement) has no
	-- numeric field to check against, so fall back to the tooltip
	-- color scan that already ran for lock/charge detection.
	return hasFailedRequirement or false
end

-- True for mounts, companion pets, and toys -- items you right-click
-- (or click in a collection UI) to permanently learn/unlock, as
-- opposed to consuming. Mounts/pets are identified by item class +
-- subclass (stable numeric IDs, not tooltip-dependent). Toys have no
-- distinct item class of their own, so C_ToyBox.GetToyInfo is used
-- instead -- retail-only (toys didn't exist before Legion), so this
-- naturally no-ops on Classic Era/MoP Classic rather than erroring.
local function IsLearnableItem(itemLink)
	local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	if not getInstant then
		return false
	end

	local itemID, _, _, _, _, itemClassID, itemSubClassID = getInstant(itemLink)

	if itemClassID == MISC_CLASS_ID and (itemSubClassID == MOUNT_SUBCLASS_ID or itemSubClassID == PET_SUBCLASS_ID) then
		return true
	end

	if C_ToyBox and C_ToyBox.GetToyInfo and itemID and C_ToyBox.GetToyInfo(itemID) then
		return true
	end

	return false
end

-----------------------------------------------------------
-- Apply visuals to a button, given its bag/slot/item link
-----------------------------------------------------------

local function ApplyVisuals(button, bag, slot, itemLink)
	local overlay = GetLockOverlay(button)
	local chargeText = GetChargeText(button)
	local restrictionTint = GetRestrictionTint(button)
	local statusText = GetStatusText(button)

	local lockedText, charges, classesLine, hasFailedRequirement, isOpenable = ScanTooltip(bag, slot)

	if lockedText then
		overlay:Show()
	else
		overlay:Hide()
	end

	if charges and charges > 0 then
		chargeText:SetText("x" .. charges)
		chargeText:Show()
	else
		chargeText:SetText("")
		chargeText:Hide()
	end

	if IsRestrictedGear(itemLink, hasFailedRequirement) then
		restrictionTint:Show()
	else
		restrictionTint:Hide()
	end

	-- OPN and LRN are mutually exclusive on any real item, so one
	-- shared label covers both; openable containers take priority in
	-- the unlikely event both somehow matched. OPN is suppressed while
	-- the item is locked (red tint above) -- "right click to open"
	-- doesn't apply until it's actually unlocked, so showing OPN on a
	-- locked box would be misleading.
	if isOpenable and not lockedText then
		statusText:SetText("OPN")
		statusText:SetTextColor(OPENABLE_COLOR.r, OPENABLE_COLOR.g, OPENABLE_COLOR.b, OPENABLE_COLOR.a)
		statusText:Show()
	elseif IsLearnableItem(itemLink) then
		statusText:SetText("LRN")
		statusText:SetTextColor(LEARNABLE_COLOR.r, LEARNABLE_COLOR.g, LEARNABLE_COLOR.b, LEARNABLE_COLOR.a)
		statusText:Show()
	else
		statusText:SetText("")
		statusText:Hide()
	end

	if ENABLE_EXTRA_WARNINGS then
		local tint = GetWarningTint(button)
		if IsUnknownProfessionRecipe(itemLink) or IsMissingClassToken(classesLine) then
			tint:Show()
		else
			tint:Hide()
		end
	end
end

local function ClearVisuals(button)
	local overlay = button.ExtraLockOverlay
	local chargeText = button.ExtraChargeText
	local warningTint = button.ExtraWarningTint
	local restrictionTint = button.ExtraRestrictionTint
	local statusText = button.ExtraStatusText

	if overlay then
		overlay:Hide()
	end
	if chargeText then
		chargeText:SetText("")
		chargeText:Hide()
	end
	if warningTint then
		warningTint:Hide()
	end
	if restrictionTint then
		restrictionTint:Hide()
	end
	if statusText then
		statusText:SetText("")
		statusText:Hide()
	end
end

-----------------------------------------------------------
-- Per-button update
--
-- force = true always re-scans (used by real bag/lock events).
-- force = false (or nil) only re-scans if the item in the slot changed
-- since the last check. That check uses GetQuickItemID (a plain
-- number, no allocation) rather than fetching the full item link, so
-- the frequent safety-net pass costs almost nothing when bags are
-- sitting idle.
-----------------------------------------------------------

local function UpdateButton(button, force)
	-- IsVisible() (not IsShown()) matters here: IsShown() only reflects
	-- the button's own explicit shown flag and ignores whether its
	-- parent bag/bank window is actually open. Cached item buttons
	-- typically stay "shown" even after the whole window is closed, so
	-- IsShown() would let every scan walk the full button list whether
	-- or not the bags are actually on screen. IsVisible() checks the
	-- whole ancestor chain and correctly skips closed windows.
	if not button:IsVisible() then
		return
	end

	-- Skip buttons that are showing a CACHED character's data (e.g.
	-- right-click switching to an alt via BagBrother) rather than your
	-- own live bags. Bagnon/Bagnonium's underlying engine (Wildpants)
	-- exposes IsCached() on item buttons for exactly this. It matters
	-- because bag/slot numbers on a cached button describe THAT
	-- character's layout, but our container queries (GetQuickItemID /
	-- GetContainerItemLink) always read your currently logged-in
	-- character's live bags -- so without this check we'd silently
	-- tint the alt's icon using an unrelated item from your own live
	-- bags at that same bag/slot number, which is what looked "random"
	-- and messy.
	if button.IsCached and button:IsCached() then
		ClearVisuals(button)
		return
	end

	local bag = button.bag or (button.GetBagID and button:GetBagID())
	local slot = button.GetID and button:GetID()

	if not bag or not slot then
		return
	end

	local quickID = GetQuickItemID(bag, slot)

	if not force and quickID == button.ExtraLastID then
		return -- nothing changed; skip the link fetch and tooltip work entirely
	end

	button.ExtraLastID = quickID

	if not quickID then
		ClearVisuals(button)
		return
	end

	local itemLink = GetContainerItemLink(bag, slot)

	if not itemLink then
		-- The item ID reported something but the link isn't available
		-- yet (e.g. slot mid-update). Don't lock in ExtraLastID here --
		-- leaving it cleared means the next pass (safety-net or event)
		-- will retry the fetch instead of assuming nothing changed.
		button.ExtraLastID = nil
		ClearVisuals(button)
		return
	end

	if _G.Item and _G.Item.CreateFromBagAndSlot then
		local item = _G.Item:CreateFromBagAndSlot(bag, slot)
		if item and not item:IsItemEmpty() then
			item:ContinueOnItemLoad(function()
				-- Guard against the slot having changed item by the
				-- time this fires.
				if GetContainerItemLink(bag, slot) == itemLink then
					ApplyVisuals(button, bag, slot, itemLink)
				end
			end)
			return
		end
	end

	ApplyVisuals(button, bag, slot, itemLink)
end

-----------------------------------------------------------
-- Scan all known item buttons across whichever addon(s) are loaded
-----------------------------------------------------------

local function ScanAllButtons(force)
	for _, prefix in ipairs(BUTTON_PREFIXES) do
		-- Fast path: if this window's first button isn't visible, the
		-- whole window is closed (all its buttons share the same
		-- parent frame), so there's nothing here worth walking. This
		-- turns the common "bags are closed" case from up to 220
		-- per-button lookups+calls into a single check, which is what
		-- was keeping CPU usage nonzero even with bags shut -- every
		-- scan (including the once-a-second safety net) was still
		-- walking the full button list just to have each one
		-- individually discover it's hidden.
		--
		-- Known edge case: if the bag window is open but Bagnon's own
		-- search/filter feature is active and specifically hides slot
		-- 1 (item doesn't match the filter), this skips the rest of
		-- that window's tint updates too, since a hidden slot 1 can't
		-- be distinguished from the whole window being closed just by
		-- checking IsVisible(). Self-corrects the moment slot 1
		-- matches the filter again, or the search is cleared.
		local firstButton = _G[prefix .. "1"]
		if firstButton and firstButton:IsVisible() then
			for i = 1, MAX_BUTTONS_PER_PREFIX do
				local button = _G[prefix .. i]
				if button then
					UpdateButton(button, force)
				else
					break -- buttons are created sequentially; a gap means we've reached the end
				end
			end
		end
	end
end

-----------------------------------------------------------
-- Trigger updates: a forced full scan right after events that
-- can change locked/charge/profession state, plus a cheap
-- cache-checking safety net for anything else (e.g. switching
-- which character's cached bags are shown).
--
-- The safety net uses C_Timer.NewTicker rather than an OnUpdate
-- script. OnUpdate scripts run (and get CPU-profiled) on every single
-- rendered frame; a ticker only fires at the interval we actually
-- need, which is what keeps this addon's footprint negligible next to
-- the bag addon itself.
--
-- Forced scans are also debounced: rearranging several items in a row
-- fires BAG_UPDATE repeatedly in a burst, so rather than doing a full
-- re-scan per event, we wait a brief moment for the burst to settle
-- and do one scan at the end. Note ITEM_LOCK_CHANGED and
-- BAG_UPDATE_COOLDOWN are intentionally NOT watched here.
-- ITEM_LOCK_CHANGED fires constantly while dragging items around
-- (that's the same transient drag-lock flag we deliberately don't use
-- for the red tint). BAG_UPDATE_COOLDOWN fires on cooldown swipe
-- updates -- in practice that means it can fire repeatedly in combat
-- every time an on-use trinket/potion goes on the GCD -- and has
-- nothing to do with lock/charge/profession state. Watching either
-- just means wasted, expensive full rescans (this was previously a
-- real combat CPU spike, since forced scans skip the fingerprint
-- cache and re-scan every button's tooltip).
-----------------------------------------------------------

local eventFrame = CreateFrame("Frame")

local function TryRegisterEvent(frame, event)
	return pcall(frame.RegisterEvent, frame, event)
end

TryRegisterEvent(eventFrame, "BAG_UPDATE")
TryRegisterEvent(eventFrame, "PLAYERBANKSLOTS_CHANGED")
TryRegisterEvent(eventFrame, "BANKFRAME_OPENED")
TryRegisterEvent(eventFrame, "PLAYER_ENTERING_WORLD")

if ENABLE_EXTRA_WARNINGS then
	-- Only needed to keep the known-professions cache current; skipped
	-- entirely when this feature set isn't active.
	TryRegisterEvent(eventFrame, "SKILL_LINES_CHANGED")
	RefreshKnownProfessions()
end

-- Stable, reused function references -- avoids allocating a new
-- closure every time an event fires.
local function CacheScan()
	ScanAllButtons(false)
end

local forceScanPending = false

local function RunPendingForceScan()
	forceScanPending = false
	ScanAllButtons(true)
end

local function RequestForceScan()
	if not (C_Timer and C_Timer.After) then
		ScanAllButtons(true) -- no timer API available; just scan immediately
		return
	end
	if forceScanPending then
		return -- a scan is already queued for this burst of events
	end
	forceScanPending = true
	C_Timer.After(0.15, RunPendingForceScan)
end

eventFrame:SetScript("OnEvent", function(self, event)
	if ENABLE_EXTRA_WARNINGS and event == "SKILL_LINES_CHANGED" then
		RefreshKnownProfessions()
	end
	RequestForceScan()
end)

if C_Timer and C_Timer.NewTicker then
	C_Timer.NewTicker(SAFETY_NET_INTERVAL, CacheScan)
else
	-- Very old clients without C_Timer: fall back to a throttled
	-- OnUpdate (rare; modern retail and classic both have C_Timer).
	local elapsedSinceScan = 0
	eventFrame:SetScript("OnUpdate", function(self, elapsed)
		elapsedSinceScan = elapsedSinceScan + elapsed
		if elapsedSinceScan >= SAFETY_NET_INTERVAL then
			elapsedSinceScan = 0
			CacheScan()
		end
	end)
end

