-- HowFarHaveIBeen / Options.lua
-- Standalone options window (named HowFarHaveIBeenOptions), plus a small
-- canvas in Esc > Options > AddOns that just opens it. Every change is applied
-- immediately and the widgets re-read the saved settings each time the window
-- is shown, so changes made with slash commands appear.

local addonName, ns = ...

local WINDOW_NAME = "HowFarHaveIBeenOptions"
local POPUP = "HOWFARHAVEIBEEN_RESET"
local NEXT_TEXT_INTERVAL = 1.0

-- Exposed so tests can drive the window.
local O = { widgets = {} }
ns.Options = O
local W = O.widgets

local frame
local unitGroup, stepGroup = {}, {}
local subControls = {}      -- { control, label } greyed out while milestones are off

local function settings() return ns.GetSettings() or {} end

local function call(name, ...)
    local fn = ns[name]
    if type(fn) == "function" then return fn(...) end
end

------------------------------------------------------------------------
-- Reset confirmation
-- preferredIndex = 3 keeps the dialog out of the slots the default UI uses,
-- which avoids tainting its own popups.
------------------------------------------------------------------------
if type(StaticPopupDialogs) == "table" then
    StaticPopupDialogs[POPUP] = {
        text = "Erase all distance totals for this character?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function() ns.ResetCharTotals() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

------------------------------------------------------------------------
-- Widget helpers. Templates' built-in labels are never used; every label is
-- our own FontString.
------------------------------------------------------------------------
local function makeLabel(text, font, x, y)
    local fs = frame:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
    fs:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

-- Returns the button and its label.
local function makeCheckbox(text, x, y, onChange)
    local b = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    b:SetSize(24, 24)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
    local fs = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", b, "RIGHT", 2, 0)
    fs:SetText(text)
    b:SetScript("OnClick", function(self) onChange(self:GetChecked() and true or false) end)
    return b, fs
end

-- Radio buttons behave like check buttons that cannot be unchecked by clicking.
-- UIRadioButtonTemplate is optional, so fall back to a check button.
local function makeRadio(group, text, x, y, onSelect)
    local ok, b = pcall(CreateFrame, "CheckButton", nil, frame, "UIRadioButtonTemplate")
    if not ok or not b then b = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate") end
    b:SetSize(24, 24)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
    local fs = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", b, "RIGHT", 2, 0)
    fs:SetText(text)
    group[#group + 1] = b
    b:SetScript("OnClick", function(self)
        for _, other in ipairs(group) do other:SetChecked(other == self) end
        onSelect()
    end)
    return b, fs
end

local function selectInGroup(group, active)
    for _, b in ipairs(group) do b:SetChecked(b == active) end
end

local function makeButton(text, x, y, w, onClick)
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", function() onClick() end)
    return b
end

local function setControlEnabled(control, label, on)
    -- Guarded: Enable/Disable on an InputBoxTemplate edit box is unconfirmed on
    -- Forever, and a missing method must not break the whole window.
    local method = on and control.Enable or control.Disable
    if type(method) == "function" then method(control) end
    if label then
        if on then label:SetTextColor(1, 1, 1) else label:SetTextColor(0.5, 0.5, 0.5) end
    end
end

local function applyMilestoneEnabled(on)
    for _, entry in ipairs(subControls) do
        setControlEnabled(entry[1], entry[2], on)
    end
    -- Take focus out of the box when it is greyed out.
    if not on and W.step then W.step:ClearFocus() end
end

------------------------------------------------------------------------
-- Step box
------------------------------------------------------------------------
local function stepText()
    local n = settings().milestoneStep
    if type(n) ~= "number" then n = 5 end
    return string.format("%g", n)
end

-- Accept only a number in (0, 1e6); anything else restores the current value.
local function applyStepBox()
    local box = W.step
    local n = tonumber(box:GetText() or "")
    if n and n > 0 and n < 1e6 then
        local s = ns.GetSettings()
        if s then s.milestoneStep = n end
    end
    box:SetText(stepText())
end

------------------------------------------------------------------------
-- Refresh from settings
------------------------------------------------------------------------
local function refresh()
    if not frame then return end
    local s = settings()
    W.showPanel:SetChecked(not s.hidden)
    W.lockPanel:SetChecked(s.locked and true or false)
    selectInGroup(unitGroup, (s.units == "km" and W.unitKm) or (s.units == "yards" and W.unitYards) or W.unitMiles)
    W.milestonesOn:SetChecked(s.milestonesOn and true or false)
    W.step:SetText(stepText())
    selectInGroup(stepGroup, (s.milestoneUnit == "km") and W.stepKm or W.stepMiles)
    W.announceGuild:SetChecked(s.announceGuild ~= false)
    W.sound:SetChecked(s.milestoneSound ~= false)
    W.nextText:SetText(ns.NextMilestoneText())
    applyMilestoneEnabled(s.milestonesOn and true or false)
end

------------------------------------------------------------------------
-- Build (lazily, on first open)
------------------------------------------------------------------------
local function build()
    if frame then return end
    frame = CreateFrame("Frame", WINDOW_NAME, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    O.frame = frame
    frame:SetSize(340, 440)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        frame:SetBackdropColor(0, 0, 0, 0.92)
        frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    -- Esc closes the window.
    if type(UISpecialFrames) == "table" then
        local present = false
        for _, n in ipairs(UISpecialFrames) do
            if n == WINDOW_NAME then present = true end
        end
        if not present then table.insert(UISpecialFrames, WINDOW_NAME) end
    end

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    W.close = close

    makeLabel("How Far Have I Been", "GameFontNormalLarge", 16, -16)

    -- Display
    makeLabel("Display", "GameFontNormal", 16, -48)
    W.showPanel = makeCheckbox("Show panel", 16, -64, function(on)
        settings().hidden = not on
        call("UI_SetShown", on)
    end)
    W.lockPanel = makeCheckbox("Lock panel position", 16, -90, function(on)
        settings().locked = on
    end)
    makeLabel("Units:", "GameFontHighlight", 20, -123)
    local function pickUnits(u)
        return function()
            settings().units = u
            call("UI_Refresh")
        end
    end
    W.unitMiles = makeRadio(unitGroup, "Miles", 66, -118, pickUnits("miles"))
    W.unitKm = makeRadio(unitGroup, "Kilometres", 134, -118, pickUnits("km"))
    W.unitYards = makeRadio(unitGroup, "Yards", 238, -118, pickUnits("yards"))
    W.resetPosition = makeButton("Reset panel position", 20, -148, 160, function()
        settings().point = nil
        call("UI_ResetPosition")
    end)

    -- Milestones
    makeLabel("Milestones", "GameFontNormal", 16, -188)
    W.milestonesOn = makeCheckbox("Announce milestones", 16, -204, function(on)
        settings().milestonesOn = on
        applyMilestoneEnabled(on)
        W.nextText:SetText(ns.NextMilestoneText())
    end)
    local everyLabel = makeLabel("Every", "GameFontHighlight", 38, -238)
    local box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    box:SetSize(50, 20)
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", 82, -235)
    box:SetAutoFocus(false)
    box:SetMaxLetters(8)
    box:SetScript("OnEnterPressed", function(self) applyStepBox(); self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:SetText(stepText()); self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", function() applyStepBox() end)
    W.step = box
    local function pickStepUnit(u)
        return function() settings().milestoneUnit = u end
    end
    local rMiles, lMiles = makeRadio(stepGroup, "miles", 142, -233, pickStepUnit("miles"))
    local rKm, lKm = makeRadio(stepGroup, "km", 212, -233, pickStepUnit("km"))
    W.stepMiles, W.stepKm = rMiles, rKm
    local gBtn, gLbl = makeCheckbox("Post in guild chat", 36, -262, function(on)
        settings().announceGuild = on
    end)
    W.announceGuild = gBtn
    local sBtn, sLbl = makeCheckbox("Play level-up sound", 36, -288, function(on)
        settings().milestoneSound = on
    end)
    W.sound = sBtn
    W.test = makeButton("Test milestone", 40, -320, 130, function() ns.MilestoneTest() end)
    local nextFs = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    nextFs:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -350)
    nextFs:SetWidth(300)
    nextFs:SetJustifyH("LEFT")
    W.nextText = nextFs

    subControls = {
        { box, everyLabel }, { rMiles, lMiles }, { rKm, lKm },
        { gBtn, gLbl }, { sBtn, sLbl }, { W.test, nil },
    }

    -- Data
    makeLabel("Data", "GameFontNormal", 16, -384)
    W.resetTotals = makeButton("Reset this character's totals...", 20, -404, 230, function()
        if StaticPopup_Show then StaticPopup_Show(POPUP) end
    end)

    frame:SetScript("OnShow", refresh)
    local acc = 0
    frame:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then return end
        acc = acc + elapsed
        if acc >= NEXT_TEXT_INTERVAL then
            acc = 0
            W.nextText:SetText(ns.NextMilestoneText())
        end
    end)

    frame:Hide()
end

function ns.OpenOptions()
    build()
    frame:Show()
    refresh() -- also covers the case where the window was already shown
end

function ns.ToggleOptions()
    build()
    if frame:IsShown() then frame:Hide() else ns.OpenOptions() end
end

------------------------------------------------------------------------
-- Esc > Options > AddOns entry (same pattern as Manners): a small canvas with
-- a description and a button. The button hides SettingsPanel, which cannot
-- host our window, and opens it. The category object returned by
-- RegisterCanvasLayoutCategory is what Settings identifies the entry by (the
-- canvas frame's own GetID() returns 0). Called by Core at PLAYER_LOGIN, never
-- at file load.
------------------------------------------------------------------------
local registered = false

function ns.Options_Init()
    if registered then return end
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    registered = true
    pcall(function()
        local canvas = CreateFrame("Frame")
        local title = canvas:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, -16)
        title:SetText("How Far Have I Been")
        local about = canvas:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        about:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
        about:SetPoint("RIGHT", canvas, "RIGHT", -24, 0)
        about:SetJustifyH("LEFT")
        about:SetText("Tracks how far your character has walked, run, swum and ridden, "
            .. "with optional milestone announcements.")
        local open = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
        open:SetSize(140, 24)
        open:SetPoint("TOPLEFT", about, "BOTTOMLEFT", 0, -16)
        open:SetText("Open options")
        open:SetScript("OnClick", function()
            if HideUIPanel and SettingsPanel then pcall(HideUIPanel, SettingsPanel) end
            ns.OpenOptions()
        end)
        O.canvas, O.canvasButton = canvas, open
        O.category = Settings.RegisterCanvasLayoutCategory(canvas, "How Far Have I Been")
        Settings.RegisterAddOnCategory(O.category)
    end)
end
