-- Constants and shared state.
local ADDON_NAME = ...
local FRAME_NAME = "ProfessionsFrame"
local BUTTON_SIZE = 40
local BUTTON_SPACING = 42

local PRIMARY_PROFESSION_TYPES = {
    alchemy = true,
    blacksmithing = true,
    enchanting = true,
    engineering = true,
    herbalism = true,
    leatherworking = true,
    mining = true,
    skinning = true,
    tailoring = true,
}

local SECONDARY_ENUM_NAMES = {
    firstaid = true,
    cooking = true,
    fishing = true,
}

local ICONS = {
    alchemy = "Interface\\Icons\\Trade_Alchemy",
    blacksmithing = "Interface\\Icons\\Trade_BlackSmithing",
    enchanting = "Interface\\Icons\\Trade_Engraving",
    engineering = "Interface\\Icons\\Trade_Engineering",
    herbalism = "Interface\\Icons\\Trade_Herbalism",
    leatherworking = "Interface\\Icons\\Trade_LeatherWorking",
    mining = "Interface\\Icons\\Trade_Mining",
    skinning = "Interface\\Icons\\Trade_Skinning",
    tailoring = "Interface\\Icons\\Trade_Tailoring",
}

local primarySkillLines = {}
local secondarySkillLines = {}
local professionNameBySkillLine = {}
local extraProfessions = {}
local buttons = {}
local selectedExtraButton
local nativeTabSelectionHooks = {}
local professionsFrame
local rail
local scrollFrame
local scrollChild
local scanQueued = false

-- Copy native rank-label styling so custom bars match Blizzard.
local function CopyFontStringStyle(source, target)
    if not (source and target) then return end
    local function CopyValue(getter, setter)
        if source[getter] and target[setter] then
            local ok, a, b, c, d = pcall(source[getter], source)
            if ok and a ~= nil then pcall(target[setter], target, a, b, c, d) end
        end
    end
    CopyValue("GetFontObject", "SetFontObject")
    CopyValue("GetFont", "SetFont")
    CopyValue("GetTextColor", "SetTextColor")
    CopyValue("GetAlpha", "SetAlpha")
    CopyValue("GetShadowColor", "SetShadowColor")
    CopyValue("GetShadowOffset", "SetShadowOffset")
    CopyValue("GetSpacing", "SetSpacing")
    CopyValue("GetJustifyH", "SetJustifyH")
    CopyValue("GetJustifyV", "SetJustifyV")
    CopyValue("GetMaxLines", "SetMaxLines")
    CopyValue("GetWordWrap", "SetWordWrap")
    CopyValue("GetNonSpaceWrap", "SetNonSpaceWrap")
    CopyValue("GetIndentedWordWrap", "SetIndentedWordWrap")
    if source.GetDrawLayer and target.SetDrawLayer then
        local ok, layer, sublevel = pcall(source.GetDrawLayer, source)
        if ok and layer then pcall(target.SetDrawLayer, target, layer, sublevel) end
    end
end

local function FindStatusBarRankText(statusBar, rank, maxRank)
    if not statusBar then return nil end

    local rankOnly = rank ~= nil and maxRank ~= nil and string.format("%d/%d", rank, maxRank)
    local firstFontString
    local lastRankMatch
    if statusBar.GetRegions then
        for _, region in ipairs({ statusBar:GetRegions() }) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                firstFontString = firstFontString or region
                local text = region.GetText and region:GetText()
                if rankOnly and text and text:find(rankOnly, 1, true) then
                    -- Choose the lower duplicate label used by the native bar.
                    lastRankMatch = region
                end
            end
        end
    end
    return lastRankMatch or statusBar.rankText or firstFontString
end

local function Normalize(value)
    return (value or ""):lower():gsub("[%s%p]", "")
end

-- Identify primary and secondary skill-line IDs from the client enum.
local function BuildProfessionSkillLineSets()
    wipe(primarySkillLines)
    wipe(secondarySkillLines)
    wipe(professionNameBySkillLine)

    if not (Enum and Enum.Profession and C_TradeSkillUI and C_TradeSkillUI.GetProfessionSkillLineID) then
        return
    end

    for enumName, enumValue in pairs(Enum.Profession) do
        if type(enumValue) == "number" then
            local ok, skillLineID = pcall(C_TradeSkillUI.GetProfessionSkillLineID, enumValue)
            if ok and skillLineID then
                local professionType = Normalize(enumName)
                professionNameBySkillLine[skillLineID] = professionType
                if PRIMARY_PROFESSION_TYPES[professionType] then
                    primarySkillLines[skillLineID] = true
                elseif SECONDARY_ENUM_NAMES[professionType] then
                    secondarySkillLines[skillLineID] = true
                end
            end
        end
    end
end

local function GetSkillLines()
    local rows = {}
    if not (C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo) then
        return rows
    end

    local count = C_SkillInfo.GetNumSkillLines() or 0
    for index = 1, count do
        local ok, info = pcall(C_SkillInfo.GetSkillLineInfo, index)
        if ok and type(info) == "table" and info.skillID and not info.isHeader then
            info.skillLineIndex = index
            rows[#rows + 1] = info
        end
    end
    return rows
end

local function GetLegacyProfessionIndexBySkillLine(skillLineID, professionName)
    local getLegacyProfessionInfo = _G.GetProfessionInfo
    if not getLegacyProfessionInfo then return nil end
    local wantedName = Normalize(professionName)

    -- Find the profession index used by the book formatter.
    if GetProfessions then
        for _, professionIndex in pairs({ GetProfessions() }) do
            if professionIndex and professionIndex > 0 then
                local ok, returnedName, _, _, _, _, _, returnedSkillLine = pcall(getLegacyProfessionInfo, professionIndex)
                if ok and (returnedSkillLine == skillLineID or (wantedName ~= "" and Normalize(returnedName) == wantedName)) then
                    return professionIndex
                end
            end
        end
    end

    -- Check additional indexes exposed by extended clients.
    local count = C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetNumSkillLines() or 0
    for index = 1, count do
        local ok, returnedName, _, _, _, _, _, returnedSkillLine = pcall(getLegacyProfessionInfo, index)
        if ok and (returnedSkillLine == skillLineID or (wantedName ~= "" and Normalize(returnedName) == wantedName)) then
            return index
        end
    end
end

local function GetProfessionInfo(skillLineID)
    if not (C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID) then
        return nil
    end
    local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)
    if ok and type(info) == "table" then
        return info
    end
end

local function GetCanonicalSkillLineID(skillLineID, info)
    if not (C_TradeSkillUI and C_TradeSkillUI.GetProfessionSkillLineID) then
        return skillLineID
    end

    local professionEnum = info and (info.profession or info.professionID)
    if professionEnum then
        local ok, canonicalID = pcall(C_TradeSkillUI.GetProfessionSkillLineID, professionEnum)
        if ok and canonicalID then
            return canonicalID
        end
    end
    return skillLineID
end

-- Scan learned lines and keep one entry per primary profession type.
local function ScanExtraProfessions()
    BuildProfessionSkillLineSets()
    local foundByType = {}
    local found = {}

    for _, skill in ipairs(GetSkillLines()) do
        local skillLineID = skill.skillID
        local info = GetProfessionInfo(skillLineID)
        local professionName = skill.name or (info and (info.professionName or info.name)) or ("Skill " .. skillLineID)
        local professionType = professionNameBySkillLine[skillLineID]
            or Normalize((info and (info.professionName or info.name)) or professionName)
        local isPrimary = PRIMARY_PROFESSION_TYPES[professionType]

        if isPrimary and not foundByType[professionType] then
            local rank = skill.rank or (info and info.skillLevel) or 0
            local maxRank = skill.maxRank or (info and info.maxSkillLevel) or 0
            if rank > 0 or maxRank > 0 then
                foundByType[professionType] = true
                found[#found + 1] = {
                    professionType = professionType,
                    skillLineID = GetCanonicalSkillLineID(skillLineID, info),
                    professionIndex = GetLegacyProfessionIndexBySkillLine(skillLineID, professionName),
                    name = professionName,
                    rank = rank,
                    maxRank = maxRank,
                }
            end
        end
    end

    table.sort(found, function(left, right)
        return left.name:lower() < right.name:lower()
    end)
    extraProfessions = found
end
-- Custom tab rail: reuse Blizzard templates and preserve secondary tabs.
local nativeTabTemplate
local nativeTabs = {}

local function FindNativeProfessionTabs(frame)
    local found = {}
    for index = 1, 30 do
        local tabName = "Professions" .. index .. "Tab"
        local tab = frame[tabName] or _G[tabName]
        if tab and tab.GetObjectType then found[#found + 1] = tab end
    end
    if #found == 0 and frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            local name = child.GetName and child:GetName()
            if name and name:match("Professions(%d+)Tab$") then found[#found + 1] = child end
        end
        table.sort(found, function(left, right)
            return (tonumber(left:GetName():match("Professions(%d+)Tab$")) or 0)
                < (tonumber(right:GetName():match("Professions(%d+)Tab$")) or 0)
        end)
    end
    return found
end

local function EnsureRail(parent)
    if rail then return end
    rail = CreateFrame("Frame", "ExtraProfessionTabsRail", parent or UIParent)
    rail:SetAllPoints(parent or UIParent)
    rail:SetFrameStrata("DIALOG")
    rail:EnableMouse(false)
    rail:Hide()
end

local function ClearCustomSelection()
    selectedExtraButton = nil
    for _, button in ipairs(buttons) do
        if button.SetChecked then button:SetChecked(false) end
    end
end

local function SetCustomSelection(button)
    selectedExtraButton = button
    local overviewTab = professionsFrame and professionsFrame.ProfessionsOverviewTab
    if overviewTab and overviewTab.SetChecked then overviewTab:SetChecked(false) end
    for index = 1, math.min(2, #nativeTabs) do
        local tab = nativeTabs[index]
        if tab.SetChecked then tab:SetChecked(false) end
    end
    for _, customButton in ipairs(buttons) do
        if customButton.SetChecked then
            customButton:SetChecked(customButton == button)
        end
    end
end

local function OpenProfessionFromTab(self, mouseButton, upInside)
    if mouseButton ~= "LeftButton" or not upInside then return end
    local profession = self.profession
    if not profession or not C_TradeSkillUI or not C_TradeSkillUI.OpenTradeSkill then
        print("|cffff5555Extra Profession Tabs:|r This client does not expose C_TradeSkillUI.OpenTradeSkill.")
        return
    end

    SetCustomSelection(self)
    self.skillLine = profession.skillLineID

    if professionsFrame and professionsFrame.RightTabSelected then
        professionsFrame:RightTabSelected(self)
        SetCustomSelection(self)
    end
    -- Reopen a skill that remains active behind the overview.
    local bookPage = professionsFrame and professionsFrame.BookPage
    local effectiveSkillLineID = Professions and Professions.GetEffectiveSkillLineID
        and Professions.GetEffectiveSkillLineID()
    if bookPage and bookPage:IsShown()
        and effectiveSkillLineID == profession.skillLineID
        and C_TradeSkillUI.CloseTradeSkill then
        pcall(C_TradeSkillUI.CloseTradeSkill)
    end

    local ok, opened = pcall(C_TradeSkillUI.OpenTradeSkill, profession.skillLineID)
    if not ok or opened == false then
        print("|cffff5555Extra Profession Tabs:|r Could not open " .. profession.name .. " (skill line " .. profession.skillLineID .. ").")
    end
end

local function CreateButton(index)
    local button = CreateFrame("Frame", nil, rail, "ProfessionsFrameRightTabTemplateWrapper")
    button:EnableMouse(true)
    if button.SetFillToInterior then
        button:SetFillToInterior(true)
    end
    if button.SetCustomOnMouseUpHandler then
        button:SetCustomOnMouseUpHandler(OpenProfessionFromTab)
    else
        button:HookScript("OnMouseUp", OpenProfessionFromTab)
    end
    local lastNativeID = nativeTabs[#nativeTabs] and nativeTabs[#nativeTabs]:GetID() or 1
    button:SetID(lastNativeID + index)
    buttons[index] = button
    return button
end
local function PositionRailAfterNativeTabs()
    if not rail or not professionsFrame then return end
    nativeTabs = FindNativeProfessionTabs(professionsFrame)
    for _, tab in ipairs(nativeTabs) do
        if not nativeTabSelectionHooks[tab] and tab.HookScript then
            local hooked = pcall(tab.HookScript, tab, "OnMouseUp", ClearCustomSelection)
            nativeTabSelectionHooks[tab] = hooked
        end
    end
    local overviewTab = professionsFrame.ProfessionsOverviewTab
    if overviewTab and not nativeTabSelectionHooks[overviewTab] and overviewTab.HookScript then
        local hooked = pcall(overviewTab.HookScript, overviewTab, "OnMouseUp", ClearCustomSelection)
        nativeTabSelectionHooks[overviewTab] = hooked
    end
    nativeTabTemplate = nativeTabs[1] or nativeTabs[2]
    if not nativeTabTemplate then return end
    local tabWidth, tabHeight = nativeTabTemplate:GetWidth(), nativeTabTemplate:GetHeight()
    if tabHeight and tabHeight > 0 then BUTTON_SIZE = tabHeight end
    local pitch = BUTTON_SPACING
    if nativeTabs[1] and nativeTabs[2] then
        local top1, top2 = nativeTabs[1]:GetTop(), nativeTabs[2]:GetTop()
        if top1 and top2 then
            local measured = math.abs(top1 - top2)
            if measured > BUTTON_SIZE then pitch = measured else pitch = BUTTON_SIZE + 2 end
        end
    end
    BUTTON_SPACING = pitch
end

local function HasNativeTabIcon(tab)
    for _, key in ipairs({ "Icon", "icon", "IconTexture", "iconTexture" }) do
        local texture = tab and tab[key]
        if texture and texture.GetTexture then
            local asset = texture:GetTexture()
            return asset ~= nil and asset ~= 0 and asset ~= ""
        end
    end
    return nil
end
local function RefreshButtons()
    EnsureRail(professionsFrame)
    PositionRailAfterNativeTabs()
    if #extraProfessions <= 2 or not nativeTabTemplate then return end

    local pitch = BUTTON_SPACING
    for index, profession in ipairs(extraProfessions) do
        local button = buttons[index] or CreateButton(index)
        button.profession = profession
        button.tooltipText = profession.name
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", nativeTabTemplate, "TOPLEFT", 0, -((index - 1) * pitch))
        button.Icon:SetTexture(ICONS[profession.professionType] or ICONS[Normalize(profession.name)] or "Interface\\Icons\\INV_Misc_Gear_01")
        if button.SetChecked then button:SetChecked(selectedExtraButton == button) end
        button:Show()
    end
    for index = #extraProfessions + 1, #buttons do
        buttons[index].profession = nil
        buttons[index]:Hide()
    end
    -- Replace primary tabs and preserve secondary tabs.
    for index, tab in ipairs(nativeTabs) do
        if index <= 2 then
            tab:Hide()
        else
            local hasIcon = HasNativeTabIcon(tab)
            -- Hide empty primary slots; keep populated secondary tabs.
            if hasIcon == false or (hasIcon == nil and index > 3) then
                tab:Hide()
            else
                tab:ClearAllPoints()
                tab:SetPoint("TOPLEFT", nativeTabTemplate, "TOPLEFT", 0, -((#extraProfessions + index - 3) * pitch))
                tab:Show()
            end
        end
    end
end
-- Profession book: lay out extra primary cards and native secondary cards.
local bookProfessionFrames = {}
local maxBookProfessionCardIndex = 2
local hookedBookFrames = setmetatable({}, { __mode = "k" })
local hookedBookPages = setmetatable({}, { __mode = "k" })

local function HasProfessionCards(frame)
    return frame and frame.PrimaryProfession1 and frame.PrimaryProfession2
end

local function FindProfessionBookContent(root, depth, seen)
    if not root or depth < 0 or seen[root] then return nil end
    seen[root] = true

    local content = root.ProfessionsContentFrame
    if HasProfessionCards(content) then
        return root, content
    end
    if HasProfessionCards(root) then
        return (root.GetParent and root:GetParent()) or root, root
    end

    if root.GetChildren then
        for _, child in ipairs({ root:GetChildren() }) do
            local book, childContent = FindProfessionBookContent(child, depth - 1, seen)
            if book and childContent then return book, childContent end
        end
    end
end

local function ResolveProfessionBookContent()
    local roots = { professionsFrame, _G.ProfessionsBookFrame, _G.ProfessionsFrame }
    local seen = {}
    for _, root in ipairs(roots) do
        local book, content = FindProfessionBookContent(root, 5, seen)
        if book and content then return book, content end
    end
end

local function EnsureBookScroll(book, content)
    local state = book._extraProfessionScroll
    if not state then
        local scrollFrame = CreateFrame("ScrollFrame", nil, book, "UIPanelScrollFrameTemplate")
        scrollFrame:ClearAllPoints()
        -- Keep the book header outside the scroll viewport.
        scrollFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -41)
        -- Leave room for the scrollbar inside the content frame.
        scrollFrame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -20, 10)
        scrollFrame:SetFrameLevel(content:GetFrameLevel() + 2)

        local scrollBar = scrollFrame.ScrollBar
        if scrollBar then
            scrollBar:ClearAllPoints()
            scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", -2.5, -2)
            scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", -2.5, 11)
        end

        scrollFrame:EnableMouseWheel(true)
        if scrollFrame.SetPropagateMouseWheel then scrollFrame:SetPropagateMouseWheel(true) end
        scrollFrame:SetScript("OnMouseWheel", function(self, delta)
            local current = self:GetVerticalScroll() or 0
            local scrollState = book._extraProfessionScroll
            local maximum = (scrollState and scrollState.maxScroll) or self:GetVerticalScrollRange() or 0
            self:SetVerticalScroll(math.max(0, math.min(maximum, current - (delta * 48))))
        end)

        local scrollChild = CreateFrame("Frame", nil, scrollFrame)
        scrollChild:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
        scrollChild:SetWidth(math.max(1, scrollFrame:GetWidth()))
        scrollFrame:SetScrollChild(scrollChild)

        state = { frame = scrollFrame, child = scrollChild, content = content, scrollBar = scrollBar, maxScroll = 0 }
        book._extraProfessionScroll = state

        for index = 1, 2 do
            local card = content["PrimaryProfession" .. index]
            if card then
                card:Hide()
                card:SetParent(content)
            end
        end
        for index = 3, 30 do
            local card = content["PrimaryProfession" .. index]
            if card and card.SetParent then
                bookProfessionFrames[index] = card
                maxBookProfessionCardIndex = math.max(maxBookProfessionCardIndex, index)
            end
        end
        for index = 1, 3 do
            local card = content["SecondaryProfession" .. index]
            if card then card:SetParent(scrollChild) end
        end
        for _, card in pairs(bookProfessionFrames) do
            if type(card) == "table" and card.SetParent then card:SetParent(scrollChild) end
        end
        scrollFrame:Show()
    end
    return state
end

local function RefreshBookProfessionPanels()
    if not professionsFrame then return end
    local book, content = ResolveProfessionBookContent()
    local formatter = book and (book.FormatProfession or (ProfessionsBookFrameMixin and ProfessionsBookFrameMixin.FormatProfession))
    if not (book and content and content.PrimaryProfession1 and content.PrimaryProfession2 and formatter) then return end

    if #extraProfessions <= 2 then return end

    local state = EnsureBookScroll(book, content)
    local scrollFrame = state.frame
    local scrollChild = state.child
    scrollFrame:SetShown(book:IsShown())
    local viewportWidth = math.max(1, scrollFrame:GetWidth())
    scrollChild:SetWidth(viewportWidth)
    local primaryCardWidth = viewportWidth * 0.975
    local primaryCardInset = (viewportWidth - primaryCardWidth) / 2
    local primaryCardGap = 5
    local previous
    local primaryStyleText
    local primaryCards = {}

    -- Hide stale native primary cards left on the persistent book frame.
    for index = 1, 2 do
        local oldCard = content["PrimaryProfession" .. index]
        if oldCard and not oldCard._eptReplacementCard then
            oldCard:Hide()
        end
    end

    for index, profession in ipairs(extraProfessions) do
        local card = bookProfessionFrames[index]
        if not card then
            local existingCard = content["PrimaryProfession" .. index]
            if existingCard and (existingCard._eptReplacementCard or index > 2) then
                card = existingCard
            end
        end
        if not card then
            card = CreateFrame("Frame", nil, scrollChild, "PrimaryProfessionTemplate")
        end
        bookProfessionFrames[index] = card
        maxBookProfessionCardIndex = math.max(maxBookProfessionCardIndex, index)
        content["PrimaryProfession" .. index] = card
        primaryCards[index] = card

        card:SetParent(scrollChild)
        card:SetWidth(primaryCardWidth)
        card:ClearAllPoints()
        if previous then
            card:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, primaryCardGap)
        else
            card:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", primaryCardInset, 0)
        end
        card:Show()
        previous = card

        local ok, err = pcall(formatter, book, card, profession.professionIndex)
        if not ok then
            card:Hide()
            if not card._eptFormatErrorShown then
                card._eptFormatErrorShown = true
                print("|cffff5555Extra Profession Tabs:|r Could not format " .. profession.name .. " in the professions book: " .. tostring(err))
            end
        end
        if book.UpdateStatusBar then
            pcall(book.UpdateStatusBar, book, card, profession.rank or 0, profession.maxRank or 0, 0)
        end

        local statusBar = card.StatusBar
        if statusBar then
            local rankText = FindStatusBarRankText(statusBar, profession.rank or 0, profession.maxRank or 0)
            if not rankText and statusBar.CreateFontString then
                rankText = statusBar:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
            end
            if rankText then
                if primaryStyleText and rankText ~= primaryStyleText then
                    CopyFontStringStyle(primaryStyleText, rankText)
                else
                    primaryStyleText = rankText
                end
                statusBar._eptRankText = rankText
                rankText:ClearAllPoints()
                rankText:SetPoint("CENTER", statusBar, "CENTER", 0, 0)
                rankText:SetText(string.format("%s %d/%d", profession.name, profession.rank or 0, profession.maxRank or 0))
                rankText:Show()
            end
            statusBar:Show()
        end
    end

    for index = #extraProfessions + 1, maxBookProfessionCardIndex do
        local card = bookProfessionFrames[index]
        if card then card:Hide() end
    end

    local secondary1 = content.SecondaryProfession1
    local secondary2 = content.SecondaryProfession2
    local secondary3 = content.SecondaryProfession3
    local secondaryOriginalWidth1 = secondary1 and (secondary1._eptOriginalWidth or secondary1:GetWidth()) or 225
    local secondaryOriginalWidth2 = secondary2 and (secondary2._eptOriginalWidth or secondary2:GetWidth()) or secondaryOriginalWidth1
    local secondaryOriginalWidth3 = secondary3 and (secondary3._eptOriginalWidth or secondary3:GetWidth()) or secondaryOriginalWidth1
    if secondary1 then secondary1._eptOriginalWidth = secondaryOriginalWidth1 end
    if secondary2 then secondary2._eptOriginalWidth = secondaryOriginalWidth2 end
    if secondary3 then secondary3._eptOriginalWidth = secondaryOriginalWidth3 end

    local secondaryTotalWidth = viewportWidth * 0.975
    local originalTotalWidth = secondaryOriginalWidth1 + secondaryOriginalWidth2 + secondaryOriginalWidth3
    local secondaryWidth1 = secondaryTotalWidth * (secondaryOriginalWidth1 / originalTotalWidth)
    local secondaryWidth2 = secondaryTotalWidth * (secondaryOriginalWidth2 / originalTotalWidth)
    local secondaryWidth3 = secondaryTotalWidth - secondaryWidth1 - secondaryWidth2
    local secondaryInset = (viewportWidth - secondaryTotalWidth) / 2
    local lastPrimary = primaryCards[#primaryCards]
    if secondary1 then
        secondary1:SetParent(scrollChild)
        secondary1:SetWidth(secondaryWidth1)
        secondary1:ClearAllPoints()
        secondary1:SetPoint("TOPLEFT", lastPrimary, "BOTTOMLEFT", secondaryInset - primaryCardInset, 4)
    end
    if secondary2 and secondary1 then
        secondary2:SetParent(scrollChild)
        secondary2:SetWidth(secondaryWidth2)
        secondary2:ClearAllPoints()
        secondary2:SetPoint("TOPLEFT", secondary1, "TOPRIGHT", 0, 0)
    end
    if secondary3 and secondary2 then
        secondary3:SetParent(scrollChild)
        secondary3:SetWidth(secondaryWidth3)
        secondary3:ClearAllPoints()
        secondary3:SetPoint("TOPLEFT", secondary2, "TOPRIGHT", 0, 0)
    end

    local primaryStackHeight = 0
    for _, card in ipairs(primaryCards) do
        primaryStackHeight = primaryStackHeight + (card:GetHeight() or 142)
    end
    primaryStackHeight = primaryStackHeight - ((#primaryCards - 1) * primaryCardGap)
    local secondaryHeight = 0
    for _, card in ipairs({ secondary1, secondary2, secondary3 }) do
        if card and card:IsShown() then
            secondaryHeight = math.max(secondaryHeight, card:GetHeight() or 0)
        end
    end
    local contentHeight = primaryStackHeight - 4 + secondaryHeight
    scrollChild:SetHeight(math.max(1, contentHeight))
    scrollFrame:SetScrollChild(scrollChild)
    scrollFrame:UpdateScrollChildRect()
    local viewportHeight = math.max(1, scrollFrame:GetHeight())
    local nativeRange = math.max(0, scrollChild:GetHeight() - viewportHeight)
    local actualRange = math.max(0, scrollFrame:GetVerticalScrollRange() or 0)
    state.maxScroll = math.min(nativeRange, actualRange)
    scrollFrame:SetVerticalScroll(math.min(scrollFrame:GetVerticalScroll() or 0, state.maxScroll))
    if state.scrollBar and state.scrollBar.SetMinMaxValues then
        state.scrollBar:SetMinMaxValues(0, state.maxScroll)
    end
end
-- Reapply layout when the book or its content changes size or appears.
local function HookBookPanels()
    local book, content = ResolveProfessionBookContent()
    if book and not hookedBookFrames[book] then
        hookedBookFrames[book] = true
        if book.HookScript then
            book:HookScript("OnShow", function()
                if professionsFrame and professionsFrame:IsShown() then
                    RefreshBookProfessionPanels()
                end
            end)
            book:HookScript("OnSizeChanged", function()
                if professionsFrame and professionsFrame:IsShown() then
                    RefreshBookProfessionPanels()
                end
            end)
        end
    end
    if content and not hookedBookPages[content] then
        hookedBookPages[content] = true
        if content.HookScript then
            content:HookScript("OnSizeChanged", function()
                if professionsFrame and professionsFrame:IsShown() then
                    RefreshBookProfessionPanels()
                end
            end)
        end
    end
end

local function UpdateRailVisibility()
    if not professionsFrame then return end
    if #extraProfessions <= 2 then
        if rail then rail:Hide() end
        return
    end
    if professionsFrame:IsShown() then
        RefreshButtons()
        HookBookPanels()
        RefreshBookProfessionPanels()
        if rail then rail:Show() end
    elseif rail then
        rail:Hide()
    end
end
local function AttachToProfessionsFrame()
    local frame = _G[FRAME_NAME]
    if not frame or frame == professionsFrame then
        return
    end

    professionsFrame = frame
    EnsureRail(professionsFrame)
    rail:SetFrameLevel((professionsFrame:GetFrameLevel() or 1) + 20)
    PositionRailAfterNativeTabs()
    HookBookPanels()
    professionsFrame:HookScript("OnShow", UpdateRailVisibility)
    professionsFrame:HookScript("OnHide", function()
        rail:Hide()
    end)

    if professionsFrame:IsShown() then
        UpdateRailVisibility()
    end
end

-- Debounce scans triggered by skill changes and profession-window events.
local function QueueRefresh()
    if scanQueued then return end
    scanQueued = true
    local delay = C_Timer and C_Timer.After or function(_, callback) callback() end
    delay(0.25, function()
        scanQueued = false
        ScanExtraProfessions()
        -- Leave Blizzard's UI untouched until a third primary profession is learned.
        if #extraProfessions <= 2 then return end
        AttachToProfessionsFrame()
        if professionsFrame then UpdateRailVisibility() end
    end)
end

local watchedProfessionWindow
local function WatchProfessionWindow()
    local frame = _G[FRAME_NAME]
    if frame and frame ~= watchedProfessionWindow then
        watchedProfessionWindow = frame
        frame:HookScript("OnShow", QueueRefresh)
    end
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:RegisterEvent("ADDON_LOADED")
watcher:RegisterEvent("SKILL_LINES_CHANGED")
watcher:RegisterEvent("TRADE_SKILL_SHOW")
watcher:SetScript("OnEvent", function(_, event, loadedAddon)
    WatchProfessionWindow()
    if event == "ADDON_LOADED" and loadedAddon ~= ADDON_NAME then return end
    QueueRefresh()
end)
