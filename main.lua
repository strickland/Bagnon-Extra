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

	8) Consumables (potions, elixirs, flasks, food, throwables, etc.)
	   get a purple'ish star icon in the top-left corner, on by default
	   for every item the game itself classifies as a Consumable.

	9) That default can be overridden per item: "/bagnonextra ignore"
	   while hovering a consumable removes its star; "/bagnonextra add"
	   while hovering a non-consumable forces one on. Running either
	   command again on the same item undoes it. Overrides persist
	   across sessions (SavedVariables).

	10) "/bagnonextra favorite" or you can also use "/bagnonextra fav"
	    while hovering any item marks it with a yellow star instead 
            -- independent of whether it's a consom or not. 
            A favorited item always shows the yellow star rather
	    than the purple one.


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
-- Light pink/lavender star for consumables. The texture is desaturated
-- to grayscale before this tint is applied (see GetStarIcon), which is
-- what makes a real light color reachable here rather than the dark
-- maroon a straight tint of the gold original would cap out at.
local CONSUMABLE_COLOR  = { r = 0.95, g = 0.55, b = 0.95, a = 1.00 }
local FAVORITE_COLOR    = { r = 1.00, g = 0.85, b = 0.15, a = 1.00 } -- gold/yellow star for favorited items
local STAR_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local CHARGE_FONT_SIZE = 12

local LOCKED_STRING = _G.LOCKED -- localized "Locked", used by Blizzard's own UI elsewhere
local OPENABLE_STRING = _G.ITEM_OPENABLE -- localized "<Right Click to Open>"
local PLAYER_CLASS_NAME = (UnitClass("player"))
local RECIPE_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Recipe) or 9
local PROFESSION_CLASS_ID = Enum and Enum.ItemClass and Enum.ItemClass.Profession -- added in Dragonflight; nil on older clients
local ARMOR_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4
local WEAPON_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local MISC_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Miscellaneous) or 15
local CONSUMABLE_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Consumable) or 0

-- Prefer the named Enum over hardcoded numeric literals, same pattern
-- already used above for RECIPE/ARMOR/WEAPON/MISC class IDs. Guards
-- against these subclass numbers ever diverging between client
-- generations (older DBC-era item data has been observed with
-- different numbering than the modern Enum table uses), and self-
-- documents intent better than a bare magic number.
local MOUNT_SUBCLASS_ID = (Enum and Enum.ItemMiscellaneousSubclass and Enum.ItemMiscellaneousSubclass.Mount) or 5
local PET_SUBCLASS_ID = (Enum and Enum.ItemMiscellaneousSubclass and Enum.ItemMiscellaneousSubclass.CompanionPet) or 2

local SAFETY_NET_INTERVAL = 1.0 -- seconds between cache-only safety-net passes
local FORCE_SCAN_CHUNK_SIZE = 25 -- buttons processed per frame during a forced rescan; keeps a big bag opening from spiking CPU in a single frame

-- Blizzard colors a tooltip requirement line (profession, zone, faction,
-- level, etc.) red when you don't meet it, and white/normal when you do.
-- There's no clean boolean API for "can I equip this", so we detect the
-- red color directly. These thresholds distinguish it from item-quality
-- colors (green/blue/purple/orange item names, none of which are this
-- red/low-green/low-blue combination).
local REQUIREMENT_RED_MIN_R = 0.75
local REQUIREMENT_RED_MAX_G = 0.35
local REQUIREMENT_RED_MAX_B = 0.35

-----------------------------------------------------------
-- Persistent per-item star overrides (SavedVariables)
--
-- BagnonExtraDB must be a plain global (not local) for the client's
-- SavedVariables system to find and persist it -- it's populated from
-- disk automatically before this addon's ADDON_LOADED fires, so by the
-- time InitializeDB() runs below, any previously-saved data is already
-- present and just needs its substructure defaulted if missing (first
-- ever run, or an old save from before a given table existed).
--
-- consumableOverride[itemID] = true  -> force the purple star on even
--                                        though the item isn't a
--                                        Consumable ("/bagnonextra add")
-- consumableOverride[itemID] = false -> force the purple star off even
--                                        though the item IS a
--                                        Consumable ("/bagnonextra ignore")
-- consumableOverride[itemID] = nil   -> no override; default behavior
--                                        (star shows iff IsConsumable)
--
-- favorites[itemID] = true -> yellow star, regardless of the above.
-- A favorited item shows yellow, never purple, even if it's also a
-- consumable -- see the priority order in ApplyVisuals.
-----------------------------------------------------------

BagnonExtraDB = BagnonExtraDB or {}

local function InitializeDB()
	BagnonExtraDB.consumableOverride = BagnonExtraDB.consumableOverride or {}
	BagnonExtraDB.favorites = BagnonExtraDB.favorites or {}
end
InitializeDB()

-----------------------------------------------------------
-- Debug mode: "/bagnonextra" prints which button prefixes resolve to
-- real buttons on your client (use this to check whether ReagentItem/
-- VaultItem are real or just unused guesses). "/bagnonextra debug"
-- toggles verbose logging, including which branch ScanTooltip takes
-- for main-bank slots (SetInventoryItem vs SetBagItem) -- use this to
-- check the retail bank-rework question noted above.
-----------------------------------------------------------

local DebugMode = false
local bankBranchLogged = false

local function DebugPrint(msg)
	if DebugMode then
		print("|cff33ff99BagnonExtra:|r " .. msg)
	end
end

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
local MAX_BUTTONS_PER_PREFIX = 300 -- generous ceiling (padded for retail's larger bag/bank/reagent-bank slot counts); scanning stops early once a gap is found

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

-- Top-left star icon: purple for consumables, yellow for favorited
-- items (favorite takes priority when an item is both -- see
-- ApplyVisuals). Uses the client's built-in raid-target-marker star
-- texture (UI-RaidTargetingIcon_1) rather than a Unicode "★" glyph --
-- Classic Era's default UI fonts don't include that glyph and render
-- it as a blank box, but this texture has shipped with every client
-- flavor since Vanilla, so it's a safer cross-version choice than
-- depending on font coverage. Color is set dynamically per-call in
-- ApplyVisuals (same pattern as the OPN/LRN status text below), not
-- fixed at creation, since which color applies can change per item.
local STAR_SIZE = 14 -- was 10; small enough not to dominate the icon, big enough to actually read at a glance
local STAR_OUTLINE_PADDING = 4 -- how much larger the dark backing shape is than the colored star on top of it

local function GetStarIcon(button)
	local tex = button.ExtraStarIcon
	if not tex then
		tex = button:CreateTexture(nil, "OVERLAY")
		tex:SetSize(STAR_SIZE, STAR_SIZE)
		tex:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
		tex:SetTexture(STAR_TEXTURE)
		-- Desaturate to neutral grayscale BEFORE tinting. The star's
		-- native gold has almost no blue channel, so tinting the
		-- untouched original caps out at dark red/maroon no matter what
		-- color is requested (a multiply can't add a channel that isn't
		-- there). A grayscale base has roughly equal R/G/B, so tinting
		-- it can reproduce a real light pink/purple instead. Guarded
		-- since SetDesaturation needs shader support; falls back to the
		-- gold-tinted (murkier) look on any client/hardware without it,
		-- rather than erroring.
		if tex.SetDesaturation then
			tex:SetDesaturation(1)
		end
		tex:SetDrawLayer("OVERLAY", 7)

		-- Dark backing copy: same star shape, tinted near-black and
		-- slightly larger, drawn one sublevel behind the colored star so
		-- it reads as a rim/outline around it. Same purpose the OUTLINE
		-- font flag already serves for the charge/status text elsewhere
		-- in this addon -- keeps the icon readable against item icons of
		-- any color or brightness underneath it, rather than the colored
		-- shape alone potentially blending into a busy background.
		local outline = button:CreateTexture(nil, "OVERLAY")
		outline:SetSize(STAR_SIZE + STAR_OUTLINE_PADDING, STAR_SIZE + STAR_OUTLINE_PADDING)
		outline:SetPoint("CENTER", tex, "CENTER", 0, 0)
		outline:SetTexture(STAR_TEXTURE)
		outline:SetVertexColor(0, 0, 0)
		outline:SetDrawLayer("OVERLAY", 6)
		tex.Outline = outline

		button.ExtraStarIcon = tex
	end
	return tex
end

-- Shows/hides the star and its outline together -- always go through
-- these two rather than calling :Show()/:Hide() directly on the
-- texture returned by GetStarIcon, or the outline will fall out of
-- sync with it.
local function ShowStarIcon(tex)
	tex.Outline:Show()
	tex:Show()
end

local function HideStarIcon(tex)
	tex.Outline:Hide()
	tex:Hide()
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

-- Restricts the name-based openable guess above to items the game
-- itself classifies as Miscellaneous -- the item class real lootable
-- containers (footlockers, junk boxes, treasure caches) are almost
-- always filed under. This excludes false positives the name alone
-- can't catch: a passive quest charm like [Cache of Mau'ari] (item
-- class Quest, not a container at all despite the name), or a
-- "Use:"-effect consumable like [Flash Bundle] (item class Consumable,
-- an AoE fire effect, not something you loot open). Doesn't touch the
-- real "Right Click to Open" tooltip detection above, which stays
-- unconditional and authoritative -- this only narrows the guess used
-- when that text is missing.
local function ItemClassAllowsNameGuess(itemLink)
	local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	if not getInstant or not itemLink then
		return true -- can't check -- don't lose the guess entirely, just can't narrow it
	end
	local _, _, _, _, _, itemClassID = getInstant(itemLink)
	return itemClassID == MISC_CLASS_ID
end

local function ScanTooltipLines(itemLink)
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

	if not isOpenable and NameSuggestsOpenable(itemNameLine) and ItemClassAllowsNameGuess(itemLink) then
		isOpenable = true
	end

	return isLockedText, charges, classesLine, hasFailedRequirement, isOpenable
end

local function ScanTooltip(bag, slot, itemLink)
	Scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
	Scanner:ClearLines()

	-- The main bank container's slots are technically special
	-- "inventory slots" under the hood (the same category as equipped
	-- gear), not real bag slots -- so GameTooltip:SetBagItem silently
	-- returns an empty tooltip for them on the pre-Dragonflight bank.
	-- They need to go through SetInventoryItem instead, with the slot
	-- number converted via BankButtonIDToInvSlotID. Extra bank BAGS
	-- (positive IDs) are real containers and work fine through the
	-- normal SetBagItem path.
	--
	-- Blizzard has since reworked the retail bank so its tabs behave
	-- like ordinary bag containers; it hasn't been confirmed whether
	-- this branch still ever fires there, or whether it's dead code on
	-- current retail. Run "/bagnonextra debug" and open your bank once
	-- to see which branch actually fires for you.
	if bag == (_G.BANK_CONTAINER or -1) and _G.BankButtonIDToInvSlotID then
		if DebugMode and not bankBranchLogged then
			bankBranchLogged = true
			DebugPrint("main bank slot detected -> using SetInventoryItem/BankButtonIDToInvSlotID branch (bag=" .. tostring(bag) .. ")")
		end
		Scanner:SetInventoryItem("player", BankButtonIDToInvSlotID(slot))
	else
		Scanner:SetBagItem(bag, slot)
	end

	return ScanTooltipLines(itemLink)
end

-----------------------------------------------------------
-- Profession / class-token checks (Bagnonium-only feature)
-----------------------------------------------------------

local knownProfessions = {}

local function RefreshKnownProfessions()
	wipe(knownProfessions)

	-- Primary source: GetProfessions()'s own two primary-profession
	-- slots. Read defensively with select()/a numeric loop rather than
	-- destructuring into fixed locals or looping with ipairs(), since
	-- neither the count nor the order of trailing slots (archaeology,
	-- fishing, cooking, firstAid) is guaranteed identical across every
	-- client flavor, and ipairs() would stop dead at the first nil (e.g.
	-- a character with only one primary profession leaves prof2 nil,
	-- which sits before fishing/cooking in the list).
	local numResults = select("#", GetProfessions())
	local results = { GetProfessions() }
	for i = 1, numResults do
		local index = results[i]
		if index then
			local name = GetProfessionInfo(index)
			if name then
				knownProfessions[name:lower()] = true
			end
		end
	end

	-- Fallback/supplement: walk the character's actual skill list
	-- (GetNumSkillLines/GetSkillLineInfo -- the same data source the
	-- default Skills panel itself reads from) and add every non-header
	-- skill name. This exists because GetProfessions() has been observed
	-- to come back completely empty on Season of Discovery, almost
	-- certainly because SoD's Rune Engraving system reshuffles the skill
	-- list in a way that breaks the "professions always sit in these two
	-- primary slots" assumption GetProfessions() relies on.
	--
	-- This adds non-profession skills too (weapon skills, languages,
	-- riding, etc.), but that's harmless here: those names never match a
	-- real recipe's item subtype, so they can't cause a false "this is
	-- one of your professions" negative-tint result. Worth noting this
	-- is intentionally a superset, not a replacement -- keeping
	-- GetProfessions() first still gets us the fast, well-understood
	-- path on every client where it actually works correctly.
	if GetNumSkillLines and GetSkillLineInfo then
		for i = 1, GetNumSkillLines() do
			local skillName, isHeader = GetSkillLineInfo(i)
			if skillName and not isHeader then
				knownProfessions[skillName:lower()] = true
			end
		end
	end
end

-- Re-check known professions shortly after the initial login snapshot,
-- as a safety net against any residual case where profession data isn't
-- fully populated on the client yet at the moment PLAYER_ENTERING_WORLD
-- fires (e.g. very first login of a session). Cheap to run twice; wrong
-- once is what causes false "unknown profession" blue tints.
local function RefreshKnownProfessionsDelayed()
	RefreshKnownProfessions()
	if C_Timer and C_Timer.After then
		C_Timer.After(2, RefreshKnownProfessions)
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

-- True for any item classified as a Consumable (potions, elixirs,
-- flasks, food, bandages, fireworks, throwable "Use:" items like Flash
-- Bundle, etc.) -- a plain item-class check, no tooltip dependency, so
-- it's cheap and works the same on every client flavor.
local function IsConsumable(itemLink)
	local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	if not getInstant then
		return false -- extremely old client without this API; feature just no-ops
	end

	local _, _, _, _, _, itemClassID = getInstant(itemLink)
	return itemClassID == CONSUMABLE_CLASS_ID
end

-----------------------------------------------------------
-- Apply visuals to a button, given its bag/slot/item link
-----------------------------------------------------------

local function ApplyVisuals(button, bag, slot, itemLink)
	local overlay = GetLockOverlay(button)
	local chargeText = GetChargeText(button)
	local restrictionTint = GetRestrictionTint(button)
	local statusText = GetStatusText(button)
	local starIcon = GetStarIcon(button)

	local lockedText, charges, classesLine, hasFailedRequirement, isOpenable = ScanTooltip(bag, slot, itemLink)

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

	-- Star priority: favorite (yellow) beats any consumable override,
	-- which beats the default IsConsumable() check. Only one star can
	-- show at a time, so a favorited consumable shows yellow, not
	-- purple -- favoriting is the more specific, explicit user choice.
	do
		local itemID = GetQuickItemID(bag, slot)
		local isFavorited = itemID and BagnonExtraDB.favorites[itemID]
		local override = itemID and BagnonExtraDB.consumableOverride[itemID]

		local showStar, starColor
		if isFavorited then
			showStar, starColor = true, FAVORITE_COLOR
		elseif override == true then
			showStar, starColor = true, CONSUMABLE_COLOR
		elseif override == false then
			showStar = false
		elseif IsConsumable(itemLink) then
			showStar, starColor = true, CONSUMABLE_COLOR
		else
			showStar = false
		end

		if showStar then
			starIcon:SetVertexColor(starColor.r, starColor.g, starColor.b)
			starIcon:SetAlpha(starColor.a)
			ShowStarIcon(starIcon)
		else
			HideStarIcon(starIcon)
		end
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
	local starIcon = button.ExtraStarIcon

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
	if starIcon then
		HideStarIcon(starIcon)
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

-- Cheap, non-forced pass: used by the once-a-second safety net. Each
-- button's own fingerprint check inside UpdateButton means this costs
-- almost nothing when nothing has changed, so it's fine to run this
-- synchronously in one pass rather than chunking it.
local function ScanAllButtonsCached()
	for _, prefix in ipairs(BUTTON_PREFIXES) do
		-- Fast path: if this window's first button isn't visible, the
		-- whole window is closed (all its buttons share the same
		-- parent frame), so there's nothing here worth walking. This
		-- turns the common "bags are closed" case from up to N
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
					UpdateButton(button, false)
				else
					break -- buttons are created sequentially; a gap means we've reached the end
				end
			end
		end
	end
end

-----------------------------------------------------------
-- Forced rescan queue -- unlike the cached pass above, a forced
-- rescan does a full tooltip scan on every visible item regardless of
-- whether it changed, which is the expensive path. Doing that for an
-- entire open bag window synchronously in one frame is what produces
-- the CPU "spike" on clients with many slots and/or long tooltips
-- (retail, mainly, thanks to the reagent bag adding a slot category
-- Classic doesn't have and much longer per-item tooltip text). This
-- queue spreads the same total work across multiple frames instead,
-- processing a small chunk per tick via C_Timer.After(0, ...).
-----------------------------------------------------------

local forceScanQueue = {}
local forceScanQueueActive = false

local function ProcessForceScanChunk()
	local processed = 0
	while processed < FORCE_SCAN_CHUNK_SIZE do
		local button = table.remove(forceScanQueue)
		if not button then
			forceScanQueueActive = false
			DebugPrint("forced rescan complete")
			return
		end
		UpdateButton(button, true)
		processed = processed + 1
	end

	if C_Timer and C_Timer.After then
		C_Timer.After(0, ProcessForceScanChunk)
	else
		-- No timer API available (very old client): just finish the
		-- rest synchronously rather than dropping the remaining work.
		while #forceScanQueue > 0 do
			UpdateButton(table.remove(forceScanQueue), true)
		end
		forceScanQueueActive = false
	end
end

local function QueueButtonsForForceScan()
	wipe(forceScanQueue)
	for _, prefix in ipairs(BUTTON_PREFIXES) do
		local firstButton = _G[prefix .. "1"]
		if firstButton and firstButton:IsVisible() then
			for i = 1, MAX_BUTTONS_PER_PREFIX do
				local button = _G[prefix .. i]
				if button then
					table.insert(forceScanQueue, button)
				else
					break
				end
			end
		end
	end

	DebugPrint(("forced rescan queued: %d buttons"):format(#forceScanQueue))

	if #forceScanQueue == 0 then
		return
	end

	if forceScanQueueActive then
		-- A chunked scan from a previous burst is still draining;
		-- ProcessForceScanChunk will simply keep consuming from the
		-- freshly-repopulated queue, so there's no need to kick off a
		-- second parallel chain.
		return
	end

	forceScanQueueActive = true
	ProcessForceScanChunk()
end

-----------------------------------------------------------
-- Hover-target resolution for the ignore/add/favorite commands
-----------------------------------------------------------

-- Returns the item under the mouse cursor right now (itemID, display
-- name, itemLink), or nil if the cursor isn't over one of our tracked
-- item buttons or the slot is empty. GetMouseFoci() replaced the older
-- GetMouseFocus() at some point in retail; both are checked here so
-- this works across every client flavor rather than assuming one or
-- the other exists.
local function GetHoveredItem()
	local focus
	if GetMouseFoci then
		local foci = GetMouseFoci()
		focus = foci and foci[1]
	elseif GetMouseFocus then
		focus = GetMouseFocus()
	end

	if not focus then
		return nil
	end

	local bag = focus.bag or (focus.GetBagID and focus:GetBagID())
	local slot = focus.GetID and focus:GetID()
	if not bag or not slot then
		return nil -- not one of our item buttons
	end

	local itemID = GetQuickItemID(bag, slot)
	if not itemID then
		return nil -- empty slot
	end

	local itemLink = GetContainerItemLink(bag, slot)
	local itemName = (itemLink and GetItemInfoCompat(itemLink)) or ("item " .. itemID)
	return itemID, itemName, itemLink
end

-----------------------------------------------------------
-- Diagnostics slash command
-----------------------------------------------------------

SLASH_BAGNONEXTRA1 = "/bagnonextra"
SlashCmdList["BAGNONEXTRA"] = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")

	if msg == "debug" then
		DebugMode = not DebugMode
		print("|cff33ff99BagnonExtra:|r debug mode " .. (DebugMode and "ON" or "OFF"))
		return
	end

	if msg == "profs" or msg == "professions" then
		if not ENABLE_EXTRA_WARNINGS then
			print("|cff33ff99BagnonExtra:|r the profession/class-token blue tint is off right now (it only runs when Bagnonium is loaded without Bagnon), so this list isn't in use.")
			return
		end
		RefreshKnownProfessions() -- force a live read rather than showing a possibly-stale cache
		print("|cff33ff99BagnonExtra:|r professions currently counted as \"known\" (recipes outside these get blue-tinted):")
		local any = false
		for name in pairs(knownProfessions) do
			print("  " .. name)
			any = true
		end
		if not any then
			print("  (none detected -- if you do have a profession, try '/reload' and check again; if it's still empty afterwards, that's a bug, not a missing profession.)")
		end
		return
	end

	if msg == "ignore" then
		local itemID, itemName, itemLink = GetHoveredItem()
		if not itemID then
			print("|cff33ff99BagnonExtra:|r hover over an item in your bags, then run '/bagnonextra ignore'.")
			return
		end
		local override = BagnonExtraDB.consumableOverride[itemID]
		if override == false then
			-- already ignored -> toggle back to default behavior
			BagnonExtraDB.consumableOverride[itemID] = nil
			print("|cff33ff99BagnonExtra:|r " .. itemName .. " will use the default star behavior again.")
		elseif override == true or IsConsumable(itemLink) then
			-- currently showing a star (forced on, or a natural consumable) -> hide it
			BagnonExtraDB.consumableOverride[itemID] = false
			print("|cff33ff99BagnonExtra:|r " .. itemName .. " will no longer be starred.")
		else
			print("|cff33ff99BagnonExtra:|r " .. itemName .. " isn't a consumable, so there's nothing to ignore. Use '/bagnonextra add' if you want to force a star onto it instead.")
		end
		QueueButtonsForForceScan()
		return
	end

	if msg == "add" then
		local itemID, itemName, itemLink = GetHoveredItem()
		if not itemID then
			print("|cff33ff99BagnonExtra:|r hover over an item in your bags, then run '/bagnonextra add'.")
			return
		end
		local override = BagnonExtraDB.consumableOverride[itemID]
		if override == true then
			-- already force-added -> toggle back to default behavior
			BagnonExtraDB.consumableOverride[itemID] = nil
			print("|cff33ff99BagnonExtra:|r " .. itemName .. " will use the default star behavior again.")
		elseif override ~= false and IsConsumable(itemLink) then
			print("|cff33ff99BagnonExtra:|r " .. itemName .. " is already a consumable and already gets the star automatically. Use '/bagnonextra ignore' if you want to remove it instead.")
		else
			BagnonExtraDB.consumableOverride[itemID] = true
			print("|cff33ff99BagnonExtra:|r " .. itemName .. " will now be starred.")
		end
		QueueButtonsForForceScan()
		return
	end

	if msg == "favorite" or msg == "fav" then
		local itemID, itemName = GetHoveredItem()
		if not itemID then
			print("|cff33ff99BagnonExtra:|r hover over an item in your bags, then run '/bagnonextra favorite'.")
			return
		end
		if BagnonExtraDB.favorites[itemID] then
			BagnonExtraDB.favorites[itemID] = nil
			print("|cff33ff99BagnonExtra:|r " .. itemName .. " removed from favorites.")
		else
			BagnonExtraDB.favorites[itemID] = true
			print("|cff33ff99BagnonExtra:|r " .. itemName .. " marked as a favorite (yellow star).")
		end
		QueueButtonsForForceScan()
		return
	end

	print("|cff33ff99BagnonExtra:|r button prefix diagnostics (which of these are real on your client):")
	for _, prefix in ipairs(BUTTON_PREFIXES) do
		local count = 0
		for i = 1, MAX_BUTTONS_PER_PREFIX do
			if _G[prefix .. i] then
				count = count + 1
			else
				break
			end
		end
		if count > 0 then
			print(("  %s: %d buttons found"):format(prefix, count))
		else
			print(("  %s: none found"):format(prefix))
		end
	end
	print("Use '/bagnonextra debug' to toggle verbose logging (forced rescan queue size, which bank tooltip branch fires).")
	print("Use '/bagnonextra profs' to see which professions are currently detected as yours (for the recipe blue-tint feature).")
	print("Hover an item and use '/bagnonextra ignore' or '/bagnonextra add' to override its purple consumable star, or '/bagnonextra favorite' for a yellow one.")
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
	RefreshKnownProfessionsDelayed()
end

local forceScanPending = false

local function RunPendingForceScan()
	forceScanPending = false
	QueueButtonsForForceScan()
end

local function RequestForceScan()
	if not (C_Timer and C_Timer.After) then
		QueueButtonsForForceScan() -- no timer API available; just scan immediately (still chunked-if-possible internally)
		return
	end
	if forceScanPending then
		return -- a scan is already queued for this burst of events
	end
	forceScanPending = true
	C_Timer.After(0.15, RunPendingForceScan)
end

-- Printed once per session, a few seconds after PLAYER_ENTERING_WORLD
-- rather than immediately at login -- login already floods chat with
-- other addons' own messages, so a short delay makes this actually
-- visible instead of scrolling past unread.
local hasShownLoginReminder = false
local function ShowLoginReminder()
	if hasShownLoginReminder then
		return
	end
	hasShownLoginReminder = true
	print("|cff33ff99BagnonExtra:|r tip: hover an item and run '/bagnonextra ignore' or '/bagnonextra add' to override its purple consumable star, or '/bagnonextra favorite' for a yellow one.")
end

eventFrame:SetScript("OnEvent", function(self, event)
	-- SKILL_LINES_CHANGED covers gaining/losing skill points during play.
	-- PLAYER_ENTERING_WORLD covers login/reload: the very first
	-- RefreshKnownProfessions() call above runs at file-load time, before
	-- the client has actually received the character's profession data
	-- from the server, so that first snapshot is frequently empty. Without
	-- this, a character's own known professions would get wrongly blue-
	-- tinted as "unknown" for the entire session, or until they happened
	-- to skill up. RefreshKnownProfessionsDelayed() also re-checks a
	-- couple seconds later as a safety net for slower initial logins.
	if event == "SKILL_LINES_CHANGED" then
		if ENABLE_EXTRA_WARNINGS then
			RefreshKnownProfessions()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		if ENABLE_EXTRA_WARNINGS then
			RefreshKnownProfessionsDelayed()
		end
		if C_Timer and C_Timer.After then
			C_Timer.After(5, ShowLoginReminder)
		else
			ShowLoginReminder() -- no timer API available; just show it immediately rather than never
		end
	end
	RequestForceScan()
end)

if C_Timer and C_Timer.NewTicker then
	C_Timer.NewTicker(SAFETY_NET_INTERVAL, ScanAllButtonsCached)
else
	-- Very old clients without C_Timer: fall back to a throttled
	-- OnUpdate (rare; modern retail and classic both have C_Timer).
	local elapsedSinceScan = 0
	eventFrame:SetScript("OnUpdate", function(self, elapsed)
		elapsedSinceScan = elapsedSinceScan + elapsed
		if elapsedSinceScan >= SAFETY_NET_INTERVAL then
			elapsedSinceScan = 0
			ScanAllButtonsCached()
		end
	end)
end

