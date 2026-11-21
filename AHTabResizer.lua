local ADDON_NAME = ...

local DEFAULTS = {
    scale = 1.0,        -- Overall tab scale (0.50 to 1.50)
    width = nil,        -- Fixed pixel width (nil = auto-fit text)
    lastWidth = 80,     -- Remembered fixed width when toggling between auto and fixed
    padding = 0,        -- Extra horizontal padding when width is auto (-20 to 60)
    hideButton = false, -- Hide the 'Tab Size' button on the AH title bar
}

local IsSecret = issecretvalue or function()
    return false
end

local isApplying = false
local isLibHooked = false
local isGlobalHooked = false
local isRefreshingUI = false
local hookedFrames = {}
local ahButtons = {}
local knownTabs = {}
local cachedTabs = {}

local floatingFrame = nil
local uiControls = {}

local UpdateAHButtonVisibility

local function InitDB()
    if type(AHTabResizerDB) ~= "table" then
        AHTabResizerDB = {}
    end
    for k, v in pairs(DEFAULTS) do
        if AHTabResizerDB[k] == nil then
            AHTabResizerDB[k] = v
        end
    end
    if type(AHTabResizerDB.width) == "number" then
        AHTabResizerDB.lastWidth = AHTabResizerDB.width
    end
end

local function SafeNumber(v)
    if v ~= nil and not IsSecret(v) and type(v) == "number" then
        return v
    end
    return nil
end

local function SafeString(v)
    if v ~= nil and not IsSecret(v) and type(v) == "string" then
        return v
    end
    return nil
end

local function RoundToStep(val, step, minVal, maxVal)
    local rounded = math.floor((val / step) + 0.5 + 1e-9) * step
    rounded = math.max(minVal, math.min(maxVal, rounded))
    if step < 1 then
        rounded = tonumber(string.format("%.2f", rounded)) or rounded
    end
    if rounded == 0 then
        rounded = 0 -- avoid -0 formatting
    end
    return rounded
end

local function IsSafeFrame(f)
    if not f or IsSecret(f) or type(f) ~= "table" then
        return false
    end
    local ok, forbidden = pcall(function()
        return f.IsForbidden and f:IsForbidden()
    end)
    if not ok or IsSecret(forbidden) or forbidden then
        return false
    end
    return true
end

local function GetActiveAHFrame()
    if IsSafeFrame(AuctionHouseFrame) then
        return AuctionHouseFrame, "AuctionHouseFrameTab"
    elseif IsSafeFrame(AuctionFrame) then
        return AuctionFrame, "AuctionFrameTab"
    end
    return nil, nil
end

local function IsAHShown()
    local ahFrame = GetActiveAHFrame()
    if not ahFrame then
        return false
    end
    local ok, shown = pcall(ahFrame.IsShown, ahFrame)
    return ok and not IsSecret(shown) and shown == true
end

local function IsButton(f)
    if not IsSafeFrame(f) then
        return false
    end
    local ok, res = pcall(function()
        return f.IsObjectType and f:IsObjectType("Button")
    end)
    return ok and not IsSecret(res) and res == true
end

local function HasTabTraits(frame)
    local ok, res = pcall(function()
        if not IsButton(frame) then
            return false
        end
        if frame.LeftActive or frame.MiddleActive or frame.RightActive
            or frame.LeftDisabled or frame.MiddleDisabled or frame.RightDisabled
            or frame.tabID or (frame.Left and frame.Middle and frame.Right) then
            return true
        end
        local name = SafeString(frame.GetName and frame:GetName())
        if name and name:lower():find("tab") then
            return true
        end
        return false
    end)
    return ok and res == true
end

local function IsInBottomTabRow(frame, ahBottomPx, ahLeftPx, ahRightPx)
    local ok, res = pcall(function()
        if not IsSafeFrame(frame) or not frame.IsVisible then
            return false
        end
        local visible = frame:IsVisible()
        if IsSecret(visible) or not visible then
            return false
        end

        local top = SafeNumber(frame:GetTop())
        local bottom = SafeNumber(frame:GetBottom())
        local left = SafeNumber(frame:GetLeft())
        local right = SafeNumber(frame:GetRight())
        local scale = SafeNumber(frame:GetEffectiveScale())
        if not (top and bottom and left and right and scale and scale > 0) then
            return false
        end

        local topPx = top * scale
        local bottomPx = bottom * scale
        local leftPx = left * scale
        local rightPx = right * scale

        local nearBottomEdge = (topPx <= ahBottomPx + 40)
            and (topPx >= ahBottomPx - 80)
            and (bottomPx < ahBottomPx + 25)

        local nearHorizontalRow = (rightPx >= ahLeftPx - 100) and (leftPx <= ahRightPx + 2000)
        return nearBottomEdge and nearHorizontalRow
    end)
    return ok and res == true
end

local function CollectTabs()
    local ahFrame, tabPrefix = GetActiveAHFrame()
    if not ahFrame then
        cachedTabs = {}
        knownTabs = {}
        return {}
    end

    local tabs = {}
    local seen = {}

    local function AddTab(tab)
        if IsButton(tab) and not seen[tab] then
            seen[tab] = true
            table.insert(tabs, tab)
        end
    end

    -- 1. Blizzard default tabs (Retail/Forever and Classic)
    if type(ahFrame.Tabs) == "table" then
        for _, tab in ipairs(ahFrame.Tabs) do
            AddTab(tab)
        end
    end
    local numTabs = math.max(SafeNumber(ahFrame.numTabs) or 0, 12)
    for i = 1, numTabs do
        AddTab(_G[tabPrefix .. i])
    end

    -- 2. Auctionator container & LibAHTab-1-0 internal tables
    if IsSafeFrame(AuctionatorAHTabsContainer) and type(AuctionatorAHTabsContainer.Tabs) == "table" then
        for _, tab in ipairs(AuctionatorAHTabsContainer.Tabs) do
            AddTab(tab)
        end
    end
    if LibStub then
        local okLib, lib = pcall(LibStub, "LibAHTab-1-0", true)
        if okLib and type(lib) == "table" then
            local visited = {}
            local function ScanLibTable(tbl, depth)
                if depth > 3 or type(tbl) ~= "table" or visited[tbl] then
                    return
                end
                visited[tbl] = true
                for _, v in pairs(tbl) do
                    if type(v) == "table" and not IsSecret(v) then
                        if v.GetObjectType then
                            AddTab(v)
                        else
                            ScanLibTable(v, depth + 1)
                        end
                    end
                end
            end
            ScanLibTable(lib, 1)
        end
    end

    -- Measure active AH bottom edge safely
    local ahScale = SafeNumber(ahFrame.GetEffectiveScale and ahFrame:GetEffectiveScale()) or 1
    local ahBottom = SafeNumber(ahFrame.GetBottom and ahFrame:GetBottom())
    local ahLeft = SafeNumber(ahFrame.GetLeft and ahFrame:GetLeft())
    local ahRight = SafeNumber(ahFrame.GetRight and ahFrame:GetRight())
    local hasBounds = ahBottom and ahLeft and ahRight
    local ahBottomPx = hasBounds and (ahBottom * ahScale) or nil
    local ahLeftPx = hasBounds and (ahLeft * ahScale) or nil
    local ahRightPx = hasBounds and (ahRight * ahScale) or nil

    -- 3. Recursively scan AH frame children
    local function ScanDescendants(parent, depth)
        if depth > 4 or not IsSafeFrame(parent) or not parent.GetChildren then
            return
        end
        local okKids, kids = pcall(function()
            return { parent:GetChildren() }
        end)
        if not okKids or type(kids) ~= "table" then
            return
        end
        for _, child in ipairs(kids) do
            if IsSafeFrame(child) then
                if HasTabTraits(child) then
                    if not hasBounds or IsInBottomTabRow(child, ahBottomPx, ahLeftPx, ahRightPx) then
                        AddTab(child)
                    end
                end
                ScanDescendants(child, depth + 1)
            end
        end
    end
    ScanDescendants(ahFrame, 1)

    -- 4. Sandboxed fallback scan for UIParent-parented addon tabs
    if hasBounds and EnumerateFrames then
        local visibleRowButtons = {}
        local f = EnumerateFrames()
        while f do
            pcall(function()
                if IsButton(f) and IsInBottomTabRow(f, ahBottomPx, ahLeftPx, ahRightPx) then
                    table.insert(visibleRowButtons, f)
                    if HasTabTraits(f) then
                        AddTab(f)
                    end
                end
            end)
            f = EnumerateFrames(f)
        end

        local foundNew = true
        while foundNew do
            foundNew = false
            for _, btn in ipairs(visibleRowButtons) do
                if not seen[btn] then
                    pcall(function()
                        local numPoints = SafeNumber(btn.GetNumPoints and btn:GetNumPoints()) or 0
                        for i = 1, numPoints do
                            local _, relativeTo = btn:GetPoint(i)
                            if IsSafeFrame(relativeTo) and (seen[relativeTo] or relativeTo == ahFrame) then
                                AddTab(btn)
                                foundNew = true
                                break
                            end
                        end
                    end)
                end
            end
        end
    end

    knownTabs = seen
    cachedTabs = tabs
    return tabs
end

local function ApplyToTab(tab)
    if not IsSafeFrame(tab) or not AHTabResizerDB then
        return
    end

    pcall(tab.SetScale, tab, AHTabResizerDB.scale or 1.0)

    local resized = false
    if PanelTemplates_TabResize then
        if type(AHTabResizerDB.width) == "number" then
            resized = pcall(PanelTemplates_TabResize, tab, 0, AHTabResizerDB.width)
        else
            resized = pcall(PanelTemplates_TabResize, tab, AHTabResizerDB.padding or 0)
        end
    end

    if not resized then
        if type(AHTabResizerDB.width) == "number" then
            pcall(tab.SetWidth, tab, AHTabResizerDB.width)
        else
            pcall(function()
                local fs = tab.Text or (tab.GetFontString and tab:GetFontString())
                local textW = fs and SafeNumber(fs.GetStringWidth and fs:GetStringWidth())
                if textW then
                    tab:SetWidth(math.max(35, textW + 32 + (AHTabResizerDB.padding or 0)))
                end
            end)
        end
    elseif type(AHTabResizerDB.width) == "number" then
        local currentW = SafeNumber(tab.GetWidth and tab:GetWidth()) or 0
        if math.abs(currentW - AHTabResizerDB.width) > 1 then
            pcall(tab.SetWidth, tab, AHTabResizerDB.width)
        end
    end
end

local function ApplyAllTabs(useCache)
    local ahFrame = GetActiveAHFrame()
    if isApplying or not ahFrame then
        return
    end

    local tabs
    if useCache and #cachedTabs > 0 then
        tabs = cachedTabs
    else
        local okTabs, scanned = pcall(CollectTabs)
        if not okTabs or type(scanned) ~= "table" then
            return
        end
        tabs = scanned
    end

    isApplying = true
    for _, tab in ipairs(tabs) do
        pcall(ApplyToTab, tab)
    end
    isApplying = false
end

local function PrintDebugInfo()
    print("|cff00ccffAH Tab Resizer:|r Running debug scan...")
    local ahFrame = GetActiveAHFrame()
    if not ahFrame then
        print("  Auction House frame is not loaded yet (open the Auction House first).")
        return
    end
    local ahName = SafeString(ahFrame.GetName and ahFrame:GetName()) or "Unknown"
    local okShown, isShown = pcall(ahFrame.IsShown, ahFrame)
    local okLib, lib = pcall(function()
        return LibStub and LibStub("LibAHTab-1-0", true)
    end)
    print(string.format("  Frame=%s, shown=%s, LibAHTab=%s",
        ahName,
        tostring(okShown and isShown or false),
        tostring(okLib and lib ~= nil)))

    local okTabs, tabs = pcall(CollectTabs)
    if not okTabs then
        print("|cffff4444  Scan error:|r " .. tostring(tabs))
        return
    end
    print(string.format("  Found %d bottom tab(s):", #tabs))
    for i, tab in ipairs(tabs) do
        local okLine, line = pcall(function()
            local name = SafeString(tab.GetName and tab:GetName()) or "<unnamed>"
            local text = SafeString(tab.GetText and tab:GetText()) or "<no text>"
            local parent = tab.GetParent and tab:GetParent()
            local parentName = (IsSafeFrame(parent) and SafeString(parent.GetName and parent:GetName())) or "<unnamed>"
            local w = SafeNumber(tab.GetWidth and tab:GetWidth()) or 0
            local s = SafeNumber(tab.GetScale and tab:GetScale()) or 1
            return string.format("  %d. [%s] name=%s parent=%s w=%.0f scale=%.2f", i, text, name, parentName, w, s)
        end)
        print(okLine and line or ("  " .. i .. ". <error reading tab>"))
    end
end

-- ============================================================================
-- Movable Live Resizer Window & AH Title-Bar Button
-- ============================================================================

local function RefreshUI()
    if not floatingFrame or not AHTabResizerDB then
        return
    end
    isRefreshingUI = true

    local useFixedWidth = (type(AHTabResizerDB.width) == "number")
    local scaleVal = AHTabResizerDB.scale or DEFAULTS.scale
    local widthVal = useFixedWidth and AHTabResizerDB.width or (AHTabResizerDB.lastWidth or DEFAULTS.lastWidth)
    local padVal = AHTabResizerDB.padding or DEFAULTS.padding

    if uiControls.scaleSlider then
        uiControls.scaleSlider:SetValue(scaleVal)
        uiControls.scaleSlider.valueText:SetText(string.format("%.2fx", scaleVal))
    end
    if uiControls.fixedWidthCheck then
        uiControls.fixedWidthCheck:SetChecked(useFixedWidth)
    end
    if uiControls.widthSlider then
        uiControls.widthSlider:SetValue(widthVal)
        uiControls.widthSlider.valueText:SetText(string.format("%d px", widthVal))
        uiControls.widthSlider:SetControlEnabled(useFixedWidth)
    end
    if uiControls.paddingSlider then
        uiControls.paddingSlider:SetValue(padVal)
        uiControls.paddingSlider.valueText:SetText(string.format("%d px", padVal))
        uiControls.paddingSlider:SetControlEnabled(not useFixedWidth)
    end
    if uiControls.hideButtonCheck then
        uiControls.hideButtonCheck:SetChecked(AHTabResizerDB.hideButton == true)
    end

    isRefreshingUI = false
end

local function CreateCustomSlider(parent, opts)
    local sliderWidth = opts.width or 270
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(sliderWidth, 54)

    local label = container:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(opts.label)

    local valueText = container:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    valueText:SetPoint("TOPRIGHT", 0, 0)

    local slider = CreateFrame("Slider", nil, container)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(sliderWidth, 20)
    slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
    slider:SetMinMaxValues(opts.min, opts.max)
    slider:SetValueStep(opts.step)
    slider:SetObeyStepOnDrag(true)
    slider:EnableMouseWheel(true)

    local trackBg = slider:CreateTexture(nil, "BACKGROUND")
    trackBg:SetColorTexture(0.12, 0.12, 0.16, 0.9)
    trackBg:SetHeight(6)
    trackBg:SetPoint("LEFT", 6, 0)
    trackBg:SetPoint("RIGHT", -6, 0)

    local trackBorder = slider:CreateTexture(nil, "BORDER")
    trackBorder:SetColorTexture(0.45, 0.45, 0.52, 0.65)
    trackBorder:SetHeight(8)
    trackBorder:SetPoint("LEFT", 5, 0)
    trackBorder:SetPoint("RIGHT", -5, 0)

    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local thumb = slider:GetThumbTexture()
    if thumb then
        thumb:SetSize(24, 24)
    end

    local lowText = container:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    lowText:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 2, -2)
    lowText:SetText(opts.lowLabel or tostring(opts.min))
    lowText:SetTextColor(0.65, 0.65, 0.65)

    local highText = container:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    highText:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", -2, -2)
    highText:SetText(opts.highLabel or tostring(opts.max))
    highText:SetTextColor(0.65, 0.65, 0.65)

    slider.container = container
    slider.label = label
    slider.valueText = valueText

    function slider:SetControlEnabled(enabled)
        if enabled then
            self:Enable()
            container:SetAlpha(1.0)
        else
            self:Disable()
            container:SetAlpha(0.42)
        end
    end

    slider:SetScript("OnMouseWheel", function(self, delta)
        if not self:IsEnabled() then
            return
        end
        local step = (IsShiftKeyDown and IsShiftKeyDown() and opts.shiftStep) or opts.step
        local current = self:GetValue()
        local nextVal = RoundToStep(current + (delta * step), opts.step, opts.min, opts.max)
        self:SetValue(nextVal)
    end)

    local lastValue = nil
    slider:SetScript("OnValueChanged", function(self, rawValue)
        local val = RoundToStep(rawValue, opts.step, opts.min, opts.max)
        self.valueText:SetText(opts.format(val))
        if isRefreshingUI then
            lastValue = val
            return
        end
        if val == lastValue then
            return
        end
        lastValue = val
        if opts.onChange then
            opts.onChange(val)
        end
    end)

    return slider
end

local function GetOrCreateFloatingWindow()
    if floatingFrame then
        return floatingFrame
    end

    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    local f = CreateFrame("Frame", "AHTabResizerFloatingFrame", UIParent, template)
    f:SetSize(306, 376)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 90)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 },
        })
    else
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.06, 0.09, 0.94)
    end

    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    title:SetText("AH Tab Resizer")

    local sub = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    sub:SetText("Drag to move • Scroll to fine-tune (Shift = 5x)")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)

    -- 1. Scale Slider (0.01x fine steps, 0.05x with Shift+Scroll)
    local scaleSlider = CreateCustomSlider(f, {
        label = "Tab Scale",
        width = 270,
        min = 0.50,
        max = 1.50,
        step = 0.01,
        shiftStep = 0.05,
        lowLabel = "0.50x",
        highLabel = "1.50x",
        format = function(v) return string.format("%.2fx", v) end,
        onChange = function(v)
            AHTabResizerDB.scale = v
            ApplyAllTabs(true)
        end,
    })
    scaleSlider.container:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -14)
    uiControls.scaleSlider = scaleSlider

    -- 2. Fixed Width Checkbox
    local fixedCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    fixedCheck:SetPoint("TOPLEFT", scaleSlider.container, "BOTTOMLEFT", -4, -12)

    local fixedCheckLabel = fixedCheck:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fixedCheckLabel:SetPoint("LEFT", fixedCheck, "RIGHT", 4, 1)
    fixedCheckLabel:SetText("Use Fixed Tab Width")

    fixedCheck:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        if checked then
            AHTabResizerDB.width = AHTabResizerDB.lastWidth or DEFAULTS.lastWidth
        else
            AHTabResizerDB.width = nil
        end
        RefreshUI()
        ApplyAllTabs(false)
    end)
    uiControls.fixedWidthCheck = fixedCheck

    -- 3. Fixed Tab Width Slider (1 px fine steps, 5 px with Shift+Scroll)
    local widthSlider = CreateCustomSlider(f, {
        label = "Fixed Tab Width",
        width = 270,
        min = 35,
        max = 250,
        step = 1,
        shiftStep = 5,
        lowLabel = "35 px",
        highLabel = "250 px",
        format = function(v) return string.format("%d px", v) end,
        onChange = function(v)
            AHTabResizerDB.width = v
            AHTabResizerDB.lastWidth = v
            ApplyAllTabs(true)
        end,
    })
    widthSlider.container:SetPoint("TOPLEFT", fixedCheck, "BOTTOMLEFT", 4, -10)
    uiControls.widthSlider = widthSlider

    -- 4. Auto-Width Padding Slider (1 px fine steps, 5 px with Shift+Scroll)
    local paddingSlider = CreateCustomSlider(f, {
        label = "Auto-Width Padding",
        width = 270,
        min = -20,
        max = 60,
        step = 1,
        shiftStep = 5,
        lowLabel = "-20 px",
        highLabel = "+60 px",
        format = function(v) return string.format("%d px", v) end,
        onChange = function(v)
            AHTabResizerDB.width = nil
            AHTabResizerDB.padding = v
            ApplyAllTabs(true)
        end,
    })
    paddingSlider.container:SetPoint("TOPLEFT", widthSlider.container, "BOTTOMLEFT", 0, -14)
    uiControls.paddingSlider = paddingSlider

    -- 5. Hide AH Header Button Checkbox
    local hideButtonCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    hideButtonCheck:SetPoint("TOPLEFT", paddingSlider.container, "BOTTOMLEFT", -4, -10)

    local hideButtonLabel = hideButtonCheck:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    hideButtonLabel:SetPoint("LEFT", hideButtonCheck, "RIGHT", 4, 1)
    hideButtonLabel:SetText("Hide 'Tab Size' Button on AH")

    hideButtonCheck:SetScript("OnClick", function(self)
        local checked = self:GetChecked() and true or false
        AHTabResizerDB.hideButton = checked
        UpdateAHButtonVisibility()
        if checked then
            print("|cff00ccffAH Tab Resizer:|r AH button hidden. Type |cffffff00/ahtabs|r anytime to reopen this menu.")
        end
    end)
    uiControls.hideButtonCheck = hideButtonCheck

    -- Action Buttons
    local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    resetBtn:SetSize(124, 24)
    resetBtn:SetPoint("TOPLEFT", hideButtonCheck, "BOTTOMLEFT", 4, -12)
    resetBtn:SetText("Reset Defaults")
    resetBtn:SetScript("OnClick", function()
        AHTabResizerDB.scale = DEFAULTS.scale
        AHTabResizerDB.width = DEFAULTS.width
        AHTabResizerDB.lastWidth = DEFAULTS.lastWidth
        AHTabResizerDB.padding = DEFAULTS.padding
        AHTabResizerDB.hideButton = DEFAULTS.hideButton
        RefreshUI()
        UpdateAHButtonVisibility()
        ApplyAllTabs(false)
        print("|cff00ccffAH Tab Resizer:|r Reset all tab settings to defaults.")
    end)

    local rescanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    rescanBtn:SetSize(136, 24)
    rescanBtn:SetPoint("LEFT", resetBtn, "RIGHT", 10, 0)
    rescanBtn:SetText("Rescan & Debug")
    rescanBtn:SetScript("OnClick", function()
        ApplyAllTabs(false)
        PrintDebugInfo()
    end)

    f:SetScript("OnShow", function()
        InitDB()
        if IsAHShown() then
            pcall(CollectTabs)
        end
        RefreshUI()
    end)

    if UISpecialFrames then
        table.insert(UISpecialFrames, "AHTabResizerFloatingFrame")
    end

    floatingFrame = f
    return f
end

local function ToggleFloatingWindow(forceShow)
    local f = GetOrCreateFloatingWindow()
    if forceShow or not f:IsShown() then
        f:Show()
    else
        f:Hide()
    end
end

local function UpdateAHButtonLayer(ahFrame, btn)
    if not IsSafeFrame(ahFrame) or not IsSafeFrame(btn) then
        return
    end
    local ahName = SafeString(ahFrame.GetName and ahFrame:GetName()) or ""
    local closeBtn = ahFrame.CloseButton or (ahName ~= "" and _G[ahName .. "CloseButton"])

    local ahLevel = SafeNumber(ahFrame.GetFrameLevel and ahFrame:GetFrameLevel()) or 1
    local closeLevel = (IsSafeFrame(closeBtn) and SafeNumber(closeBtn.GetFrameLevel and closeBtn:GetFrameLevel())) or 0
    local nineSliceLevel = (IsSafeFrame(ahFrame.NineSlice) and SafeNumber(ahFrame.NineSlice.GetFrameLevel and ahFrame.NineSlice:GetFrameLevel())) or 0
    local titleLevel = (IsSafeFrame(ahFrame.TitleContainer) and SafeNumber(ahFrame.TitleContainer.GetFrameLevel and ahFrame.TitleContainer:GetFrameLevel())) or 0

    local targetLevel = math.max(ahLevel + 20, closeLevel + 5, nineSliceLevel + 15, titleLevel + 15, 520)
    local strata = (IsSafeFrame(closeBtn) and closeBtn.GetFrameStrata and closeBtn:GetFrameStrata())
        or (ahFrame.GetFrameStrata and ahFrame:GetFrameStrata())
        or "HIGH"

    pcall(btn.SetFrameStrata, btn, strata)
    pcall(btn.SetFrameLevel, btn, targetLevel)
end

local function EnsureAHHeaderButton(ahFrame)
    if not IsSafeFrame(ahFrame) then
        return
    end

    local shouldHide = AHTabResizerDB and AHTabResizerDB.hideButton == true
    local existing = ahButtons[ahFrame]
    if existing then
        UpdateAHButtonLayer(ahFrame, existing)
        if shouldHide then
            existing:Hide()
        else
            existing:Show()
        end
        return
    end

    if shouldHide then
        return
    end

    local btn = CreateFrame("Button", "AHTabResizerHeaderButton", ahFrame, "UIPanelButtonTemplate")
    btn:SetSize(74, 22)
    btn:SetText("Tab Size")

    local ahName = SafeString(ahFrame.GetName and ahFrame:GetName()) or ""
    local closeBtn = ahFrame.CloseButton or (ahName ~= "" and _G[ahName .. "CloseButton"])
    if IsSafeFrame(closeBtn) then
        btn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    else
        btn:SetPoint("TOPRIGHT", ahFrame, "TOPRIGHT", -34, -2)
    end

    UpdateAHButtonLayer(ahFrame, btn)

    btn:SetScript("OnClick", function()
        ToggleFloatingWindow()
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("AH Tab Resizer", 1, 1, 1)
        GameTooltip:AddLine("Open the movable live tab resizer window.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    btn:Show()
    ahButtons[ahFrame] = btn
end

UpdateAHButtonVisibility = function()
    local ahFrame = GetActiveAHFrame()
    local shouldHide = AHTabResizerDB and AHTabResizerDB.hideButton == true

    for _, btn in pairs(ahButtons) do
        if IsSafeFrame(btn) then
            if shouldHide then
                btn:Hide()
            else
                btn:Show()
            end
        end
    end

    if not shouldHide and ahFrame then
        EnsureAHHeaderButton(ahFrame)
    end
end

-- ============================================================================
-- Hooks, Events & Slash Commands
-- ============================================================================

local function ScheduleApply()
    C_Timer.After(0, function()
        local ahFrame = GetActiveAHFrame()
        if ahFrame then
            EnsureAHHeaderButton(ahFrame)
        end
        ApplyAllTabs(false)
    end)
    C_Timer.After(0.2, function() ApplyAllTabs(false) end)
end

local function HookLibAHTab()
    if isLibHooked or not LibStub then
        return
    end
    local okLib, lib = pcall(LibStub, "LibAHTab-1-0", true)
    if not okLib or type(lib) ~= "table" then
        return
    end
    isLibHooked = true
    if type(lib.CreateTab) == "function" then
        hooksecurefunc(lib, "CreateTab", ScheduleApply)
    end
    if type(lib.SetSelected) == "function" then
        hooksecurefunc(lib, "SetSelected", ScheduleApply)
    end
end

local function SetupHooks()
    HookLibAHTab()

    local ahFrame = GetActiveAHFrame()
    if ahFrame then
        EnsureAHHeaderButton(ahFrame)
        if not hookedFrames[ahFrame] then
            hookedFrames[ahFrame] = true
            ahFrame:HookScript("OnShow", ScheduleApply)
            ahFrame:HookScript("OnHide", function()
                if floatingFrame and floatingFrame:IsShown() then
                    floatingFrame:Hide()
                end
            end)
        end
    end

    if isGlobalHooked then
        return
    end
    isGlobalHooked = true

    if PanelTemplates_TabResize then
        hooksecurefunc("PanelTemplates_TabResize", function(tab)
            if not isApplying and IsSafeFrame(tab) and knownTabs[tab] then
                isApplying = true
                pcall(ApplyToTab, tab)
                isApplying = false
            end
        end)
    end

    if PanelTemplates_SetTab then
        hooksecurefunc("PanelTemplates_SetTab", function(frame)
            local currentAH = GetActiveAHFrame()
            if currentAH and frame == currentAH then
                ScheduleApply()
            end
        end)
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
pcall(eventFrame.RegisterEvent, eventFrame, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
pcall(eventFrame.RegisterEvent, eventFrame, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            InitDB()
            HookLibAHTab()
        elseif arg1 == "Blizzard_AuctionHouseUI" or arg1 == "Blizzard_AuctionUI" then
            SetupHooks()
            ScheduleApply()
        else
            HookLibAHTab()
        end
    elseif event == "AUCTION_HOUSE_SHOW" then
        SetupHooks()
        ScheduleApply()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        if floatingFrame and floatingFrame:IsShown() then
            floatingFrame:Hide()
        end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if Enum and Enum.PlayerInteractionType and arg1 == Enum.PlayerInteractionType.Auctioneer then
            SetupHooks()
            ScheduleApply()
        end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if Enum and Enum.PlayerInteractionType and arg1 == Enum.PlayerInteractionType.Auctioneer then
            if floatingFrame and floatingFrame:IsShown() then
                floatingFrame:Hide()
            end
        end
    end
end)

-- Slash commands: /ahtabs
SLASH_AHTABRESIZER1 = "/ahtabs"
SlashCmdList["AHTABRESIZER"] = function(msg)
    InitDB()
    SetupHooks()
    local cmd, arg = msg:match("^%s*(%S+)%s*(.-)%s*$")
    cmd = cmd and cmd:lower() or ""

    if cmd == "" or cmd == "live" or cmd == "popup" or cmd == "window" or cmd == "ui" then
        ToggleFloatingWindow()

    elseif cmd == "button" or cmd == "hidebutton" then
        AHTabResizerDB.hideButton = not AHTabResizerDB.hideButton
        RefreshUI()
        UpdateAHButtonVisibility()
        if AHTabResizerDB.hideButton then
            print("|cff00ccffAH Tab Resizer:|r AH button hidden. Type |cffffff00/ahtabs|r anytime to reopen the menu.")
        else
            print("|cff00ccffAH Tab Resizer:|r AH button shown.")
        end

    elseif cmd == "scale" then
        local val = tonumber(arg)
        if not val or val < 0.5 or val > 1.5 then
            print("|cff00ccffAH Tab Resizer:|r Enter a scale between 0.50 and 1.50 (e.g. /ahtabs scale 0.85)")
            return
        end
        AHTabResizerDB.scale = RoundToStep(val, 0.01, 0.5, 1.5)
        RefreshUI()
        ApplyAllTabs(false)
        print(string.format("|cff00ccffAH Tab Resizer:|r Tab scale set to %.2f", AHTabResizerDB.scale))

    elseif cmd == "width" then
        if arg:lower() == "auto" then
            AHTabResizerDB.width = nil
            RefreshUI()
            ApplyAllTabs(false)
            print("|cff00ccffAH Tab Resizer:|r Tab width set to auto-fit.")
            return
        end
        local val = tonumber(arg)
        if not val or val < 35 or val > 250 then
            print("|cff00ccffAH Tab Resizer:|r Enter a width between 35 and 250, or 'auto' (e.g. /ahtabs width 80)")
            return
        end
        val = RoundToStep(val, 1, 35, 250)
        AHTabResizerDB.width = val
        AHTabResizerDB.lastWidth = val
        RefreshUI()
        ApplyAllTabs(false)
        print(string.format("|cff00ccffAH Tab Resizer:|r Tab width set to %dpx", val))

    elseif cmd == "padding" then
        local val = tonumber(arg)
        if not val or val < -20 or val > 60 then
            print("|cff00ccffAH Tab Resizer:|r Enter padding between -20 and 60 (e.g. /ahtabs padding -10)")
            return
        end
        val = RoundToStep(val, 1, -20, 60)
        AHTabResizerDB.width = nil
        AHTabResizerDB.padding = val
        RefreshUI()
        ApplyAllTabs(false)
        print(string.format("|cff00ccffAH Tab Resizer:|r Tab padding set to %d (auto-width enabled)", val))

    elseif cmd == "debug" then
        PrintDebugInfo()

    elseif cmd == "reset" then
        AHTabResizerDB.scale = DEFAULTS.scale
        AHTabResizerDB.width = DEFAULTS.width
        AHTabResizerDB.lastWidth = DEFAULTS.lastWidth
        AHTabResizerDB.padding = DEFAULTS.padding
        AHTabResizerDB.hideButton = DEFAULTS.hideButton
        RefreshUI()
        UpdateAHButtonVisibility()
        ApplyAllTabs(false)
        print("|cff00ccffAH Tab Resizer:|r Reset all tab settings to defaults.")

    else
        local widthLabel = AHTabResizerDB.width and (AHTabResizerDB.width .. "px") or "auto"
        local buttonLabel = AHTabResizerDB.hideButton and "hidden" or "shown"
        print("|cff00ccffAH Tab Resizer commands:|r")
        print("  /ahtabs               - Toggle the movable live resizer window")
        print("  /ahtabs button        - Show or hide the 'Tab Size' button on the AH")
        print("  /ahtabs scale 0.85    - Scale tabs (0.50 to 1.50)")
        print("  /ahtabs width 80      - Fixed width in px (35 to 250) or 'auto'")
        print("  /ahtabs padding -10   - Adjust auto-width padding (-20 to 60)")
        print("  /ahtabs debug         - List every detected tab in chat")
        print("  /ahtabs reset         - Restore Blizzard defaults")
        print(string.format("  Current: scale=%.2f, width=%s, padding=%d, button=%s",
            AHTabResizerDB.scale, widthLabel, AHTabResizerDB.padding, buttonLabel))
    end
end