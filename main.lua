local ADDON_NAME = ...

local hasBagnon = _G.Bagnon ~= nil
local hasBagnonium = _G.Bagnonium ~= nil

if not hasBagnon and not hasBagnonium then
	return
end

local ENABLE_EXTRA_WARNINGS = hasBagnonium and not hasBagnon

local LOCK_COLOR        = { r = 0.65, g = 0.05, b = 0.05, a = 0.55 }
local CHARGE_COLOR      = { r = 1.00, g = 0.85, b = 0.10, a = 1.00 }
local WARNING_COLOR     = { r = 0.10, g = 0.35, b = 0.95, a = 0.55 }
local RESTRICTION_COLOR = { r = 1.00, g = 0.35, b = 0.65, a = 0.45 }
local OPENABLE_COLOR    = { r = 1.00, g = 0.85, b = 0.10, a = 1.00 }
local LEARNABLE_COLOR   = { r = 1.00, g = 0.60, b = 0.10, a = 1.00 }

local CONSUMABLE_COLOR  = { r = 0.00, g = 1.00, b = 1.00, a = 1.00 }
local FAVORITE_COLOR    = { r = 1.00, g = 0.85, b = 0.15, a = 1.00 }

local STAR_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local STAR_SIZE = 14
local STAR_OUTLINE_PADDING = 4

local STAR_INSET_X = 1
local STAR_INSET_Y = 1
local LABEL_FONT_SIZE = 12

local LOCKED_STRING = _G.LOCKED
local OPENABLE_STRING = _G.ITEM_OPENABLE
local PLAYER_CLASS_NAME = (UnitClass("player")):lower()

local ItemClass = Enum.ItemClass
local RECIPE_CLASS_ID     = ItemClass.Recipe
local PROFESSION_CLASS_ID = ItemClass.Profession
local ARMOR_CLASS_ID      = ItemClass.Armor
local WEAPON_CLASS_ID     = ItemClass.Weapon
local MISC_CLASS_ID       = ItemClass.Miscellaneous
local CONSUMABLE_CLASS_ID = ItemClass.Consumable

local MiscSubclass = Enum.ItemMiscellaneousSubclass
local MOUNT_SUBCLASS_ID = (MiscSubclass and MiscSubclass.Mount) or 5
local PET_SUBCLASS_ID   = (MiscSubclass and MiscSubclass.CompanionPet) or 2

local SAFETY_NET_INTERVAL = 1.0
local FORCE_SCAN_CHUNK_SIZE = 25
local FORCE_SCAN_DEBOUNCE = 0.15
local MAX_BUTTONS_PER_PREFIX = 300

local REQUIREMENT_RED_MIN_R = 0.75
local REQUIREMENT_RED_MAX_G = 0.35
local REQUIREMENT_RED_MAX_B = 0.35

local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
local GetContainerItemID = C_Container.GetContainerItemID
local GetContainerItemLink = C_Container.GetContainerItemLink

local CHAT_PREFIX = "|cff33ff99BagnonExtra:|r "

local function Print(msg)
	print(CHAT_PREFIX .. msg)
end

local DebugMode = false
local bankBranchLogged = false

local function DebugPrint(msg)
	if DebugMode then
		Print(msg)
	end
end

local function InitializeDB()
	BagnonExtraDB = BagnonExtraDB or {}
	BagnonExtraDB.consumableOverride = BagnonExtraDB.consumableOverride or {}
	BagnonExtraDB.favorites = BagnonExtraDB.favorites or {}
end
InitializeDB()

local BUTTON_PREFIXES = {}
local function AddPrefixSet(addon)
	table.insert(BUTTON_PREFIXES, addon .. "ContainerItem")
	table.insert(BUTTON_PREFIXES, addon .. "BankItem")
	table.insert(BUTTON_PREFIXES, addon .. "ReagentItem")
	table.insert(BUTTON_PREFIXES, addon .. "VaultItem")
end
if hasBagnon then
	AddPrefixSet("Bagnon")
end
if hasBagnonium then
	AddPrefixSet("Bagnonium")
	AddPrefixSet("Combuctor")
end

local function ForEachButton(onlyVisible, fn)
	for _, prefix in ipairs(BUTTON_PREFIXES) do
		local first = _G[prefix .. "1"]
		if first and (not onlyVisible or first:IsVisible()) then
			for i = 1, MAX_BUTTONS_PER_PREFIX do
				local button = _G[prefix .. i]
				if not button then
					break
				end
				fn(button, prefix)
			end
		end
	end
end

local Scanner = _G.BagnonExtraScannerTooltip or CreateFrame("GameTooltip", "BagnonExtraScannerTooltip", nil, "GameTooltipTemplate")
local ScannerName = Scanner:GetName()

local function GetTint(button, key, color)
	local tint = button[key]
	if not tint then
		tint = button:CreateTexture(nil, "OVERLAY")
		tint:SetAllPoints(button.icon or button.Icon or button.IconTexture or button)
		tint:SetColorTexture(color.r, color.g, color.b, color.a)
		tint:SetBlendMode("BLEND")
		tint:Hide()
		button[key] = tint
	end
	return tint
end

local function GetLabel(button, key, point, x, y)
	local fs = button[key]
	if not fs then
		fs = button:CreateFontString(nil, "OVERLAY")
		fs:SetPoint(point, button, point, x, y)
		fs:SetFontObject(_G.NumberFontNormal or _G.GameFontNormal)
		fs:SetFont(fs:GetFont(), LABEL_FONT_SIZE, "OUTLINE")
		fs:SetDrawLayer("OVERLAY", 7)
		fs:Hide()
		button[key] = fs
	end
	return fs
end

local function GetLockOverlay(button)     return GetTint(button, "ExtraLockOverlay", LOCK_COLOR) end
local function GetWarningTint(button)     return GetTint(button, "ExtraWarningTint", WARNING_COLOR) end
local function GetRestrictionTint(button) return GetTint(button, "ExtraRestrictionTint", RESTRICTION_COLOR) end
local function GetChargeText(button)      return GetLabel(button, "ExtraChargeText", "BOTTOMRIGHT", -2, 2) end
local function GetStatusText(button)      return GetLabel(button, "ExtraStatusText", "BOTTOMLEFT", 2, 2) end

local function GetStarIcon(button)
	local tex = button.ExtraStarIcon
	if not tex then
		tex = button:CreateTexture(nil, "OVERLAY", nil, 7)
		tex:SetSize(STAR_SIZE, STAR_SIZE)
		tex:SetPoint("TOPRIGHT", button, "TOPRIGHT", -STAR_INSET_X, -STAR_INSET_Y)
		tex:SetTexture(STAR_TEXTURE)
		tex:SetDesaturated(true)

		local outline = button:CreateTexture(nil, "OVERLAY", nil, 6)
		outline:SetSize(STAR_SIZE + STAR_OUTLINE_PADDING, STAR_SIZE + STAR_OUTLINE_PADDING)
		outline:SetPoint("CENTER", tex, "CENTER")
		outline:SetTexture(STAR_TEXTURE)
		outline:SetVertexColor(0, 0, 0)
		tex.Outline = outline

		button.ExtraStarIcon = tex
	end
	return tex
end

local function ShowStarIcon(tex, color)
	tex:SetVertexColor(color.r, color.g, color.b)
	tex:SetAlpha(color.a)
	tex.Outline:Show()
	tex:Show()
end

local function HideStarIcon(tex)
	tex.Outline:Hide()
	tex:Hide()
end

local function ShowLabel(fs, text, color)
	fs:SetText(text)
	fs:SetTextColor(color.r, color.g, color.b, color.a)
	fs:Show()
end

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

local function ScanTooltipLines(itemClassID)
	local isLocked = false
	local charges = nil
	local classesLine = nil
	local hasFailedRequirement = false
	local isOpenable = false
	local itemName = nil

	for i = 1, Scanner:NumLines() do
		local line = _G[ScannerName .. "TextLeft" .. i]
		local text = line and line:GetText()
		if text then
			if i == 1 then
				itemName = text
			else

				if not hasFailedRequirement then
					local r, g, b = line:GetTextColor()
					if r >= REQUIREMENT_RED_MIN_R and g <= REQUIREMENT_RED_MAX_G and b <= REQUIREMENT_RED_MAX_B then
						hasFailedRequirement = true
					end
				end
			end

			if not isLocked and (text == LOCKED_STRING or text:match("^[Ll]ocked$")) then
				isLocked = true
			end

			if not charges then
				local n = text:match("^[Cc]harges:?%s*(%d+)") or text:match("(%d+)%s+[Cc]harges")
				charges = n and tonumber(n)
			end

			if ENABLE_EXTRA_WARNINGS and not classesLine then
				classesLine = text:match("^[Cc]lasses:%s*(.+)$")
			end

			if not isOpenable and (text == OPENABLE_STRING or text:match("[Rr]ight [Cc]lick to [Oo]pen")) then
				isOpenable = true
			end
		end
	end

	if not isOpenable and itemClassID == MISC_CLASS_ID and NameSuggestsOpenable(itemName) then
		isOpenable = true
	end

	return isLocked, charges, classesLine, hasFailedRequirement, isOpenable
end

local function ScanTooltip(bag, slot, itemClassID)
	Scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
	Scanner:ClearLines()

	if bag == (_G.BANK_CONTAINER or -1) and _G.BankButtonIDToInvSlotID then
		if not bankBranchLogged and DebugMode then
			bankBranchLogged = true
			DebugPrint("main bank slot -> SetInventoryItem branch (bag=" .. tostring(bag) .. ")")
		end
		Scanner:SetInventoryItem("player", BankButtonIDToInvSlotID(slot))
	else
		Scanner:SetBagItem(bag, slot)
	end

	return ScanTooltipLines(itemClassID)
end

local knownProfessions = {}

local function RefreshKnownProfessions()
	wipe(knownProfessions)

	local results = { GetProfessions() }
	for i = 1, select("#", GetProfessions()) do
		local index = results[i]
		local name = index and GetProfessionInfo(index)
		if name then
			knownProfessions[name:lower()] = true
		end
	end

	if GetNumSkillLines and GetSkillLineInfo then
		for i = 1, GetNumSkillLines() do
			local skillName, isHeader = GetSkillLineInfo(i)
			if skillName and not isHeader then
				knownProfessions[skillName:lower()] = true
			end
		end
	end
end

local function RefreshKnownProfessionsDelayed()
	RefreshKnownProfessions()
	C_Timer.After(2, RefreshKnownProfessions)
end

local function IsUnknownProfessionRecipe(itemSubType, itemClassID, itemSubClassID)
	if not itemSubType then
		return false
	end
	if itemClassID == RECIPE_CLASS_ID then

		if not itemSubClassID or itemSubClassID == 0 then
			return false
		end
	elseif not (PROFESSION_CLASS_ID and itemClassID == PROFESSION_CLASS_ID) then
		return false
	end
	return not knownProfessions[itemSubType:lower()]
end

local function IsMissingClassToken(classesLine)
	if not classesLine then
		return false
	end
	for name in classesLine:gmatch("[^,]+") do
		if name:match("^%s*(.-)%s*$"):lower() == PLAYER_CLASS_NAME then
			return false
		end
	end
	return true
end

local function IsRestrictedGear(itemLink, itemClassID, hasFailedRequirement)
	if itemClassID ~= ARMOR_CLASS_ID and itemClassID ~= WEAPON_CLASS_ID then
		return false
	end
	local _, _, _, _, itemMinLevel = GetItemInfo(itemLink)
	if itemMinLevel and itemMinLevel > 0 and UnitLevel("player") < itemMinLevel then
		return true
	end
	return hasFailedRequirement
end

local function IsLearnableItem(itemID, itemClassID, itemSubClassID)
	if itemClassID == MISC_CLASS_ID and (itemSubClassID == MOUNT_SUBCLASS_ID or itemSubClassID == PET_SUBCLASS_ID) then
		return true
	end
	return (C_ToyBox and C_ToyBox.GetToyInfo and C_ToyBox.GetToyInfo(itemID)) and true or false
end

local function IsConsumableLink(itemLink)
	if not itemLink then
		return false
	end
	local _, _, _, _, _, itemClassID = GetItemInfoInstant(itemLink)
	return itemClassID == CONSUMABLE_CLASS_ID
end

local function ApplyVisuals(button, bag, slot, itemID, itemLink)
	local _, _, itemSubType, _, _, itemClassID, itemSubClassID = GetItemInfoInstant(itemLink)
	local isLocked, charges, classesLine, hasFailedRequirement, isOpenable = ScanTooltip(bag, slot, itemClassID)

	GetLockOverlay(button):SetShown(isLocked)
	GetRestrictionTint(button):SetShown(IsRestrictedGear(itemLink, itemClassID, hasFailedRequirement))

	local chargeText = GetChargeText(button)
	if charges and charges > 0 then
		ShowLabel(chargeText, "x" .. charges, CHARGE_COLOR)
	else
		chargeText:Hide()
	end

	local starIcon = GetStarIcon(button)
	local override = BagnonExtraDB.consumableOverride[itemID]
	if BagnonExtraDB.favorites[itemID] then
		ShowStarIcon(starIcon, FAVORITE_COLOR)
	elseif override == true or (override == nil and itemClassID == CONSUMABLE_CLASS_ID) then
		ShowStarIcon(starIcon, CONSUMABLE_COLOR)
	else
		HideStarIcon(starIcon)
	end

	local statusText = GetStatusText(button)
	if isOpenable and not isLocked then
		ShowLabel(statusText, "OPN", OPENABLE_COLOR)
	elseif IsLearnableItem(itemID, itemClassID, itemSubClassID) then
		ShowLabel(statusText, "LRN", LEARNABLE_COLOR)
	else
		statusText:Hide()
	end

	if ENABLE_EXTRA_WARNINGS then
		GetWarningTint(button):SetShown(
			IsUnknownProfessionRecipe(itemSubType, itemClassID, itemSubClassID) or IsMissingClassToken(classesLine)
		)
	end
end

local VISUAL_KEYS = { "ExtraLockOverlay", "ExtraChargeText", "ExtraWarningTint", "ExtraRestrictionTint", "ExtraStatusText" }

local function ClearVisuals(button)
	for _, key in ipairs(VISUAL_KEYS) do
		if button[key] then
			button[key]:Hide()
		end
	end
	if button.ExtraStarIcon then
		HideStarIcon(button.ExtraStarIcon)
	end
end

local function UpdateButton(button, force)

	if not button:IsVisible() then
		return
	end

	if button.IsCached and button:IsCached() then
		ClearVisuals(button)
		return
	end

	local bag = button.bag or (button.GetBagID and button:GetBagID())
	local slot = button.GetID and button:GetID()
	if not bag or not slot then
		return
	end

	local itemID = GetContainerItemID(bag, slot)
	if not force and itemID == button.ExtraLastID then
		return
	end
	button.ExtraLastID = itemID

	if not itemID then
		ClearVisuals(button)
		return
	end

	local itemLink = GetContainerItemLink(bag, slot)
	if not itemLink then

		button.ExtraLastID = nil
		ClearVisuals(button)
		return
	end

	local item = Item:CreateFromBagAndSlot(bag, slot)
	if item:IsItemEmpty() then
		ApplyVisuals(button, bag, slot, itemID, itemLink)
		return
	end
	item:ContinueOnItemLoad(function()

		if GetContainerItemLink(bag, slot) == itemLink then
			ApplyVisuals(button, bag, slot, itemID, itemLink)
		end
	end)
end

local function UpdateCachedButton(button)
	UpdateButton(button, false)
end

local function ScanAllButtonsCached()
	ForEachButton(true, UpdateCachedButton)
end

local forceScanQueue = {}
local forceScanQueueActive = false

local function ProcessForceScanChunk()
	for _ = 1, FORCE_SCAN_CHUNK_SIZE do
		local button = table.remove(forceScanQueue)
		if not button then
			forceScanQueueActive = false
			DebugPrint("forced rescan complete")
			return
		end
		UpdateButton(button, true)
	end
	C_Timer.After(0, ProcessForceScanChunk)
end

local function EnqueueButton(button)
	table.insert(forceScanQueue, button)
end

local function QueueButtonsForForceScan()
	wipe(forceScanQueue)
	ForEachButton(true, EnqueueButton)
	DebugPrint(("forced rescan queued: %d buttons"):format(#forceScanQueue))

	if #forceScanQueue > 0 and not forceScanQueueActive then
		forceScanQueueActive = true
		ProcessForceScanChunk()
	end
end

local forceScanPending = false

local function RunPendingForceScan()
	forceScanPending = false
	QueueButtonsForForceScan()
end

local function RequestForceScan()
	if not forceScanPending then
		forceScanPending = true
		C_Timer.After(FORCE_SCAN_DEBOUNCE, RunPendingForceScan)
	end
end

local function GetHoveredItem()
	local focus
	if GetMouseFoci then
		focus = GetMouseFoci()[1]
	elseif GetMouseFocus then
		focus = GetMouseFocus()
	end
	if not focus then
		return nil
	end

	local bag = focus.bag or (focus.GetBagID and focus:GetBagID())
	local slot = focus.GetID and focus:GetID()
	if not bag or not slot then
		return nil
	end

	local itemID = GetContainerItemID(bag, slot)
	if not itemID then
		return nil
	end

	local itemLink = GetContainerItemLink(bag, slot)
	local itemName = (itemLink and GetItemInfo(itemLink)) or ("item " .. itemID)
	return itemID, itemName, itemLink
end

local COMMANDS_HELP = "hover an item and use '/bagnonextra ignore' or '/bagnonextra add' to override its cyan consumable star, or '/bagnonextra favorite' for a yellow one."

local function CmdIgnore()
	local itemID, itemName, itemLink = GetHoveredItem()
	if not itemID then
		Print("hover over an item in your bags, then run '/bagnonextra ignore'.")
		return
	end
	local overrides = BagnonExtraDB.consumableOverride
	if overrides[itemID] == false then
		overrides[itemID] = nil
		Print(itemName .. " will use the default star behavior again.")
	elseif overrides[itemID] == true or IsConsumableLink(itemLink) then
		overrides[itemID] = false
		Print(itemName .. " will no longer be starred.")
	else
		Print(itemName .. " isn't a consumable, so there's nothing to ignore. Use '/bagnonextra add' to force a star onto it instead.")
		return
	end
	QueueButtonsForForceScan()
end

local function CmdAdd()
	local itemID, itemName, itemLink = GetHoveredItem()
	if not itemID then
		Print("hover over an item in your bags, then run '/bagnonextra add'.")
		return
	end
	local overrides = BagnonExtraDB.consumableOverride
	if overrides[itemID] == true then
		overrides[itemID] = nil
		Print(itemName .. " will use the default star behavior again.")
	elseif overrides[itemID] == nil and IsConsumableLink(itemLink) then
		Print(itemName .. " is already a consumable and gets the star automatically. Use '/bagnonextra ignore' to remove it instead.")
		return
	else
		overrides[itemID] = true
		Print(itemName .. " will now be starred.")
	end
	QueueButtonsForForceScan()
end

local function CmdFavorite()
	local itemID, itemName = GetHoveredItem()
	if not itemID then
		Print("hover over an item in your bags, then run '/bagnonextra favorite'.")
		return
	end
	if BagnonExtraDB.favorites[itemID] then
		BagnonExtraDB.favorites[itemID] = nil
		Print(itemName .. " removed from favorites.")
	else
		BagnonExtraDB.favorites[itemID] = true
		Print(itemName .. " marked as a favorite (yellow star).")
	end
	QueueButtonsForForceScan()
end

local function CmdProfessions()
	if not ENABLE_EXTRA_WARNINGS then
		Print("the profession/class-token blue tint is off right now (it only runs when Bagnonium is loaded without Bagnon), so this list isn't in use.")
		return
	end
	RefreshKnownProfessions()
	Print("professions currently counted as \"known\" (recipes outside these get blue-tinted):")
	local any = false
	for name in pairs(knownProfessions) do
		print("  " .. name)
		any = true
	end
	if not any then
		print("  (none detected -- if you do have a profession, try '/reload'; if it's still empty after that, it's a bug.)")
	end
end

local function CmdDebug()
	DebugMode = not DebugMode
	Print("debug mode " .. (DebugMode and "ON" or "OFF"))
end

local function CmdDiagnostics()
	Print("button prefix diagnostics (which of these are real on your client):")
	local counts = {}
	ForEachButton(false, function(_, prefix)
		counts[prefix] = (counts[prefix] or 0) + 1
	end)
	for _, prefix in ipairs(BUTTON_PREFIXES) do
		local count = counts[prefix]
		print(count and ("  %s: %d buttons found"):format(prefix, count) or ("  %s: none found"):format(prefix))
	end
	print("Use '/bagnonextra debug' to toggle verbose logging.")
	print("Use '/bagnonextra profs' to see which professions are detected as yours.")
	print("Tip: " .. COMMANDS_HELP)
end

local SLASH_COMMANDS = {
	debug = CmdDebug,
	profs = CmdProfessions,
	professions = CmdProfessions,
	ignore = CmdIgnore,
	add = CmdAdd,
	favorite = CmdFavorite,
	fav = CmdFavorite,
}

SLASH_BAGNONEXTRA1 = "/bagnonextra"
SlashCmdList["BAGNONEXTRA"] = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	local handler = SLASH_COMMANDS[msg] or CmdDiagnostics
	handler()
end

local eventFrame = CreateFrame("Frame")

for _, event in ipairs({ "ADDON_LOADED", "BAG_UPDATE", "PLAYERBANKSLOTS_CHANGED", "BANKFRAME_OPENED", "PLAYER_ENTERING_WORLD" }) do
	pcall(eventFrame.RegisterEvent, eventFrame, event)
end
if ENABLE_EXTRA_WARNINGS then
	eventFrame:RegisterEvent("SKILL_LINES_CHANGED")
end

local hasShownLoginReminder = false
local function ShowLoginReminder()
	if not hasShownLoginReminder then
		hasShownLoginReminder = true
		Print("tip: " .. COMMANDS_HELP)
	end
end

eventFrame:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			InitializeDB()
			self:UnregisterEvent("ADDON_LOADED")
		end
		return
	elseif event == "SKILL_LINES_CHANGED" then
		RefreshKnownProfessions()
	elseif event == "PLAYER_ENTERING_WORLD" then
		if ENABLE_EXTRA_WARNINGS then
			RefreshKnownProfessionsDelayed()
		end

		C_Timer.After(5, ShowLoginReminder)
	end
	RequestForceScan()
end)

C_Timer.NewTicker(SAFETY_NET_INTERVAL, ScanAllButtonsCached)
