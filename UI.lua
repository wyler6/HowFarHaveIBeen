-- HowFarHaveIBeen / UI.lua
-- Small draggable panel plus tooltip. Built by Core via ns.UI_Init() once
-- the saved variables are initialised (PLAYER_LOGIN).

local addonName, ns = ...

local REFRESH_INTERVAL = 1.0
local SOURCE_TEXT = { UnitPosition = "Position (UnitPosition)", map = "Position (map)" }

local panel, line1, line2

local function settings() return ns.GetSettings() or {} end

local function dim(text) return "|cffaaaaaa" .. text .. "|r" end

function ns.UI_Refresh()
    if not panel then return end
    local f = ns.Format
    line1:SetText("On foot: " .. f(ns.OnFoot(ns.GetCharTotals())))
    line2:SetText(dim("Session: " .. f(ns.OnFoot(ns.GetSessionTotals()))))
end

local function applyPosition()
    local p = settings().point
    panel:ClearAllPoints()
    if type(p) == "table" and p[1] then
        panel:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
    else
        panel:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
end

-- Forget the saved position and go back to the default anchor.
function ns.UI_ResetPosition()
    local s = ns.GetSettings()
    if s then s.point = nil end
    if panel then applyPosition() end
end

function ns.UI_SetShown(show)
    if not panel then return end
    if show then panel:Show() else panel:Hide() end
end

local function showTooltip(owner)
    local f = ns.Format
    local c = ns.GetCharTotals() or {}
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("How Far Have I Been", 1, 0.82, 0)
    GameTooltip:AddDoubleLine("Walked", f(c.walk or 0), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Ran", f(c.run or 0), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Swam", f(c.swim or 0), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Rode", f(c.mount or 0), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("As a ghost", f(c.ghost or 0), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Total (this character)", f(ns.Total(c)), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("This session", f(ns.Total(ns.GetSessionTotals())), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("All characters (on foot)", f(ns.OnFoot(ns.GetAccountTotals())), 1, 1, 1, 1, 1, 1)
    if c.firstSeen then
        GameTooltip:AddLine("Tracking since " .. date("%b %d, %Y", c.firstSeen), 0.7, 0.7, 0.7)
    end
    local src = ns.CurrentSource and ns.CurrentSource()
    GameTooltip:AddLine("Method: " .. (SOURCE_TEXT[src] or "Speed estimate"), 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Drag to move \194\183 Right-click: options", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

function ns.UI_Init()
    if panel then return end
    panel = CreateFrame("Frame", "HowFarHaveIBeenFrame", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(170, 44)
    panel:SetFrameStrata("MEDIUM")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")

    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        panel:SetBackdropColor(0, 0, 0, 0.7)
        panel:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    end

    line1 = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    line1:SetPoint("TOPLEFT", 8, -7)
    line2 = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    line2:SetPoint("TOPLEFT", line1, "BOTTOMLEFT", 0, -3)

    -- Restore saved position, or use the default.
    applyPosition()

    panel:SetScript("OnDragStart", function(self)
        if not settings().locked then self:StartMoving() end
    end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        local s = ns.GetSettings()
        if s then s.point = { point, relPoint, x, y } end
    end)
    panel:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            if ns.ToggleOptions then ns.ToggleOptions() end
        end
    end)
    panel:SetScript("OnEnter", function(self) showTooltip(self) end)
    panel:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Refresh about once per second rather than every frame.
    local acc = 0
    panel:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc >= REFRESH_INTERVAL then
            acc = 0
            ns.UI_Refresh()
        end
    end)

    ns.UI_Refresh()
    ns.UI_SetShown(not settings().hidden)
end
