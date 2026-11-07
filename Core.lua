-- HowFarHaveIBeen / Core.lua
-- Data, distance tracking, formatting, slash commands and the chat helper.
-- Targets WoW Forever (Lua 5.1, interface 16001).

local addonName, ns = ...

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local SAMPLE_INTERVAL = 0.25      -- seconds between position samples
local MAX_DT = 2.0                -- larger gaps (loading screen, lag spike) are discarded
local MAX_PLAUSIBLE_SPEED = 40    -- yd/s; sanity ceiling when our own speed is unknown
local WALK_THRESHOLD = 4.0        -- on-foot speeds below this count as "walking"
local PREFIX = "|cff33ccffHowFar:|r"

local CATEGORIES = { "walk", "run", "swim", "mount", "ghost" }

local GUILD_RETRY_INTERVAL = 5     -- seconds between attempts to flush queued guild messages
local YARDS_PER_MILE = 1760
local METERS_PER_YARD = 0.9144

local DEFAULT_SETTINGS = {
    units = "miles", locked = false, hidden = false, -- point = nil
    milestonesOn = true,       -- master switch; the step is kept while off
    milestoneStep = 5,         -- number of miles/km between milestones (> 0)
    milestoneUnit = "miles",   -- "miles" or "km"
    milestoneMode = "fixed",   -- "fixed" (every step) or "progressive" (1-5, 10, 20 ... 100, 200 ...)
    announceGuild = true,
    milestoneSound = true,
}

ns.session = { walk = 0, run = 0, swim = 0, mount = 0, ghost = 0 }
ns.lastMethod = "none"
ns.methodYards = { position = 0, speed = 0 } -- session only, not saved

------------------------------------------------------------------------
-- Secret-value guards
-- Forever returns opaque "secret" values from some APIs. Arithmetic or
-- comparison on them raises an error, so EVERY API result goes through
-- usable() first, and every API call is existence-checked.
------------------------------------------------------------------------
local function usable(v)
    return v ~= nil and not (issecretvalue and issecretvalue(v))
end

-- Call a global boolean API by name. Missing, erroring or secret -> false.
local function flag(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return false end
    local ok, v = pcall(fn, ...)
    if not ok or not usable(v) then return false end
    return v and true or false
end

------------------------------------------------------------------------
-- Chat output
-- Printing to chat during combat lockdown taints chat history on Forever,
-- so messages are queued while in combat and flushed on PLAYER_REGEN_ENABLED.
------------------------------------------------------------------------
local pending = {}

local function emit(line)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(line)
    elseif print then
        print(line)
    end
end

function ns.Print(msg)
    local line = PREFIX .. " " .. tostring(msg)
    if InCombatLockdown and InCombatLockdown() then
        pending[#pending + 1] = line
    else
        emit(line)
    end
end

local function flushPending()
    local queued = pending
    pending = {}
    for i = 1, #queued do emit(queued[i]) end
end

------------------------------------------------------------------------
-- Saved data
------------------------------------------------------------------------
local function mergeDefaults(dst, defaults)
    for k, v in pairs(defaults) do
        if dst[k] == nil then dst[k] = v end
    end
end

local function initDB()
    if type(HowFarHaveIBeenDB) ~= "table" then HowFarHaveIBeenDB = {} end
    local db = HowFarHaveIBeenDB
    if db.version == nil then db.version = 1 end
    if type(db.settings) ~= "table" then db.settings = {} end
    -- Migration: older versions stored "off" as milestoneStep = 0.
    local st = db.settings
    if st.milestoneStep ~= nil and not (type(st.milestoneStep) == "number" and st.milestoneStep > 0) then
        st.milestonesOn = false
        st.milestoneStep = 5
    end
    if st.milestoneMode ~= "fixed" and st.milestoneMode ~= "progressive" then
        st.milestoneMode = "fixed"
    end
    mergeDefaults(db.settings, DEFAULT_SETTINGS)
    if type(db.chars) ~= "table" then db.chars = {} end
end

function ns.GetSettings()
    return HowFarHaveIBeenDB and HowFarHaveIBeenDB.settings
end

local function nonEmptyString(v)
    return type(v) == "string" and usable(v) and v ~= ""
end

-- Forever characters have a first name and a surname. UnitName/UnitNameUnmodified
-- return "first, surname" there (on retail the second value is the realm).
-- Returns first name (or nil) and surname (or nil). Every value is guarded.
local function readNameParts()
    for _, fn in ipairs({ UnitNameUnmodified or false, UnitName or false }) do
        if type(fn) == "function" then
            local ok, first, surname = pcall(fn, "player")
            if ok and nonEmptyString(first) then
                if not nonEmptyString(surname) then surname = nil end
                return first, surname
            end
        end
    end
    return nil, nil
end

local function surnameSeparator()
    local c = Constants and Constants.CharacterNameSeparatorConsts
    local sep = c and c.CHARACTERNAME_SURNAME_SEPARATOR
    if nonEmptyString(sep) then return sep end
    return " "
end

-- "First Last" (never doubles an already-appended surname), the first name
-- alone without a usable surname, or "A traveller" without any usable name.
function ns.PlayerFullName()
    local first, surname = readNameParts()
    if not first then return "A traveller" end
    if not surname then return first end
    local tail = surnameSeparator() .. surname
    if #first >= #tail and first:sub(-#tail) == tail then return first end
    return first .. tail
end

local function currentRealm()
    local realm
    if GetNormalizedRealmName then realm = GetNormalizedRealmName() end
    if not nonEmptyString(realm) and GetRealmName then realm = GetRealmName() end
    if not nonEmptyString(realm) then realm = "Forever" end -- Forever is realmless
    return realm
end

-- Returns the new key and the legacy first-name-only key.
local function resolveCharKeys()
    local first, surname = readNameParts()
    local realm = currentRealm()
    local oldKey = (first or "Unknown") .. "-" .. realm
    if not surname then return oldKey, oldKey end
    return ns.PlayerFullName() .. "-" .. realm, oldKey
end

local function initChar()
    local newKey, oldKey = resolveCharKeys()
    ns.charKey = newKey
    local chars = HowFarHaveIBeenDB.chars
    -- Forever is realmless, so first names alone may not be unique: keys now
    -- include the surname. One-time migration of the old first-name-only entry;
    -- never overwrite an existing entry under the new key.
    if newKey ~= oldKey and chars[newKey] == nil and type(chars[oldKey]) == "table" then
        chars[newKey] = chars[oldKey]
        chars[oldKey] = nil
    end
    local entry = chars[ns.charKey]
    if type(entry) ~= "table" then
        entry = {}
        chars[ns.charKey] = entry
    end
    for _, cat in ipairs(CATEGORIES) do
        if type(entry[cat]) ~= "number" then entry[cat] = 0 end
    end
    if entry.firstSeen == nil then entry.firstSeen = time() end
    ns.char = entry
end

------------------------------------------------------------------------
-- Totals
------------------------------------------------------------------------
function ns.GetCharTotals() return ns.char end
function ns.GetSessionTotals() return ns.session end

function ns.GetAccountTotals()
    local sum = { walk = 0, run = 0, swim = 0, mount = 0, ghost = 0 }
    local chars = HowFarHaveIBeenDB and HowFarHaveIBeenDB.chars
    if chars then
        for _, entry in pairs(chars) do
            for _, cat in ipairs(CATEGORIES) do
                sum[cat] = sum[cat] + (tonumber(entry[cat]) or 0)
            end
        end
    end
    return sum
end

function ns.OnFoot(t) return ((t and t.walk) or 0) + ((t and t.run) or 0) end

function ns.Total(t)
    local n = 0
    if t then
        for _, cat in ipairs(CATEGORIES) do n = n + (t[cat] or 0) end
    end
    return n
end

------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------
local function withSeparators(n)
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
    local s = string.format("%d", n)
    local k
    repeat
        s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until k == 0
    return s
end

function ns.Format(yards, units)
    yards = yards or 0
    units = units or (ns.GetSettings() and ns.GetSettings().units) or "miles"
    if units == "km" then
        return string.format("%.2f km", yards * 0.9144 / 1000)
    elseif units == "yards" then
        return withSeparators(math.floor(yards + 0.5)) .. " yd"
    end
    return string.format("%.2f mi", yards / 1760)
end

------------------------------------------------------------------------
-- API readers (all guarded)
------------------------------------------------------------------------
-- Current movement speed in yd/s, or nil if unavailable / secret.
local function readSpeed()
    if not GetUnitSpeed then return nil end
    local ok, speed = pcall(GetUnitSpeed, "player")
    if ok and usable(speed) and type(speed) == "number" then return speed end
    return nil
end

local function isNumber(v) return usable(v) and type(v) == "number" end

-- Player position in yards as {x, y, key}, or nil. `key` identifies the
-- coordinate space so positions from different spaces are never compared.
local function readPosition()
    -- Preferred: world yards. On Forever this is unconfirmed, so fall through if absent.
    if UnitPosition then
        local ok, y, x, _, instanceID = pcall(UnitPosition, "player")
        if ok and isNumber(x) and isNumber(y) then
            local inst = usable(instanceID) and tostring(instanceID) or "?"
            return { x = x, y = y, key = "u" .. inst, src = "UnitPosition" }
        end
    end
    -- Fallback: normalised map coordinates scaled by the map's size in yards.
    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetMapWorldSize then
        local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
        if not (okMap and isNumber(mapID)) then return nil end
        local okPos, p = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
        if not (okPos and usable(p)) then return nil end -- nil inside instances
        local okXY, px, py = pcall(function()
            local ax, ay = p.x, p.y
            if not (isNumber(ax) and isNumber(ay)) and p.GetXY then ax, ay = p:GetXY() end
            return ax, ay
        end)
        if not (okXY and isNumber(px) and isNumber(py)) then return nil end
        local okSize, w, h = pcall(C_Map.GetMapWorldSize, mapID)
        if not (okSize and isNumber(w) and isNumber(h) and w > 0 and h > 0) then return nil end
        return { x = px * w, y = py * h, key = "m" .. tostring(mapID), src = "map" }
    end
    return nil
end

-- Which position source works right now: "UnitPosition", "map" or nil.
-- Safe at any time (all reads are guarded), including before login.
function ns.CurrentSource()
    local pos = readPosition()
    return pos and pos.src or nil
end

-- Taxi, vehicles and the corpse (dead, not yet a ghost) are not the player's own travel.
local function excluded()
    if flag("UnitOnTaxi", "player") or flag("UnitInVehicle", "player") then return true end
    return flag("UnitIsDead", "player") and not flag("UnitIsGhost", "player")
end

local function category(speed)
    if flag("UnitIsGhost", "player") then return "ghost" end
    if flag("IsSwimming") then return "swim" end
    if flag("IsMounted") or flag("IsFlying") then return "mount" end
    if speed ~= nil and speed < WALK_THRESHOLD then return "walk" end
    return "run"
end

------------------------------------------------------------------------
-- Milestones
-- Every `milestoneStep` miles/km of on-foot distance (this character only):
-- play a sound, print locally and optionally tell the guild.
------------------------------------------------------------------------
local guildQueue = {}
local guildAcc = 0

local function stepYards(step, unit)
    if unit == "km" then return step * 1000 / METERS_PER_YARD end
    return step * YARDS_PER_MILE
end

-- "5 miles", "1 mile", "10 km". Whole numbers show without decimals.
local function amountText(n, unit)
    local num = string.format("%g", n)
    if unit == "km" then return num .. " km" end
    return num .. (n == 1 and " mile" or " miles")
end

-- Guild chat is NOT sent while in combat lockdown or while Forever's chat
-- messaging lockdown is active: chat from addon code is restricted/tainting
-- there. Such messages are queued and retried (on PLAYER_REGEN_ENABLED and
-- every few seconds from OnUpdate, because chat lockdown can end without
-- combat ending).
local function chatLocked()
    if InCombatLockdown and InCombatLockdown() then return true end
    local fn = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
    if type(fn) == "function" then
        local ok, v = pcall(fn)
        if ok and usable(v) and v then return true end
    end
    return false
end

local function flushGuild()
    if #guildQueue == 0 or chatLocked() then return end
    local queued = guildQueue
    guildQueue = {}
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if type(send) ~= "function" then return end -- nothing can send; drop rather than retry forever
    for i = 1, #queued do pcall(send, queued[i], "GUILD") end
end

local function sendGuild(msg)
    if #guildQueue == 0 then guildAcc = 0 end
    guildQueue[#guildQueue + 1] = msg
    flushGuild()
end

local function playMilestoneSound()
    if type(PlaySound) ~= "function" then return end
    pcall(PlaySound, (SOUNDKIT and SOUNDKIT.LEVEL_UP) or 888, "Master")
end

-- localOnly (test mode): always plays the sound, never messages the guild.
local function announce(amount, unit, localOnly)
    local s = ns.GetSettings() or {}
    local text = amountText(amount, unit)
    if localOnly or s.milestoneSound ~= false then playMilestoneSound() end
    ns.Print("Milestone! You've travelled " .. text .. " on foot.")
    if not localOnly and s.announceGuild ~= false and flag("IsInGuild") then
        local msg = ns.PlayerFullName() .. " has travelled " .. text .. " on foot!"
        if #msg < 255 then sendGuild(msg) end
    end
end

function ns.OnMilestone(amount, unit)
    announce(amount, unit == "km" and "km" or "miles", false)
end

-- Progressive schedule: every 1 up to 5, then 10, then every 10 up to 100,
-- every 100 up to 1000, and so on. Largest milestone <= v, or nil when v < 1.
function ns.ProgressiveFloor(v)
    if v < 1 then return nil end
    if v < 5 then return math.floor(v) end
    if v < 10 then return 5 end
    local p = 10
    while v >= p * 10 do p = p * 10 end
    return math.floor(v / p) * p
end

-- Smallest progressive milestone > v.
function ns.ProgressiveNext(v)
    if v < 5 then return math.floor(v) + 1 end
    if v < 10 then return 10 end
    local p = 10
    while v >= p * 10 do p = p * 10 end
    return (math.floor(v / p) + 1) * p
end

local function checkMilestone(dist)
    local s = ns.GetSettings()
    if not (s and ns.char) then return end
    if not s.milestonesOn then return end
    if s.milestoneMode == "progressive" then
        local unit = (s.milestoneUnit == "km") and "km" or "miles"
        local y = stepYards(1, unit)
        local after = ns.OnFoot(ns.char)
        local fa = ns.ProgressiveFloor(after / y)
        if fa and fa ~= ns.ProgressiveFloor((after - dist) / y) then ns.OnMilestone(fa, unit) end
        return
    end
    local step = s.milestoneStep
    if not (isNumber(step) and step > 0) then return end
    local unit = (s.milestoneUnit == "km") and "km" or "miles"
    local y = stepYards(step, unit)
    local after = ns.OnFoot(ns.char)
    local k = math.floor(after / y)
    if k > math.floor((after - dist) / y) then ns.OnMilestone(k * step, unit) end
end

------------------------------------------------------------------------
-- Tracking
------------------------------------------------------------------------
local lastTime, base, prevSpeed

function ns.ResetBaseline()
    lastTime = GetTime and GetTime() or 0
    base = nil
    prevSpeed = nil
end

function ns.ProcessSample(now)
    local dt = now - (lastTime or now)
    lastTime = now
    -- Loading screens and lag spikes produce huge or non-positive gaps.
    if dt <= 0 or dt > MAX_DT then base = nil; return end
    if excluded() then base = nil; prevSpeed = 0; return end

    local speed = readSpeed()
    -- Standing still (or on a boat/zeppelin, where our own speed is 0): don't read position.
    if speed == 0 and prevSpeed == 0 then base = nil; return end

    local pos = readPosition()
    local dist, method
    if pos and base and pos.key == base.key then
        local dx, dy = pos.x - base.x, pos.y - base.y
        local d = math.sqrt(dx * dx + dy * dy)
        if speed ~= nil then
            local vmax = math.max(speed, prevSpeed or speed)
            if d > math.max(vmax, 7) * dt * 3 + 10 then
                dist = 0 -- teleport / blink / knockback: not travelled
            else
                -- Clip to what our own speed could produce, so platform motion
                -- (elevators, boats, being pushed) isn't credited as walking.
                dist = math.min(d, vmax * dt * 1.05)
            end
        else
            -- Speed is secret: only a coarse sanity ceiling is possible.
            dist = (d > MAX_PLAUSIBLE_SPEED * dt) and 0 or d
        end
        method = "position"
    elseif speed ~= nil then
        -- No usable position pair (e.g. inside an instance): integrate speed over time.
        dist = ((speed + (prevSpeed or speed)) / 2) * dt
        method = "speed"
    else
        dist = 0
        method = "none"
    end
    -- Classify by the speed that produced this movement: on the sample just
    -- after stopping, current speed is 0 but the distance was covered at prevSpeed.
    local movingSpeed = speed
    if speed == 0 and prevSpeed ~= nil then movingSpeed = prevSpeed end
    base = pos
    prevSpeed = speed

    if dist > 0 then
        if ns.methodYards and ns.methodYards[method] ~= nil then
            ns.methodYards[method] = ns.methodYards[method] + dist
        end
        local cat = category(movingSpeed)
        if ns.char then ns.char[cat] = ns.char[cat] + dist end
        ns.session[cat] = ns.session[cat] + dist
        if cat == "walk" or cat == "run" then checkMilestone(dist) end
    end
    ns.lastMethod = method
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
local function uiCall(name, ...)
    local fn = ns[name]
    if type(fn) == "function" then fn(...) end
end

-- "Next milestone: 5 miles (3.20 to go)" or "Milestones: off". Shared by the
-- /howfar summary and the options window.
function ns.NextMilestoneText()
    local st = ns.GetSettings()
    local c = ns.char
    local step = st and st.milestoneStep
    if not (st and st.milestonesOn) then return "Milestones: off" end
    if st.milestoneMode == "progressive" then
        if not c then return "Milestones: not ready yet" end
        local unit = (st.milestoneUnit == "km") and "km" or "miles"
        local y = stepYards(1, unit)
        local units = ns.OnFoot(c) / y
        local nxt = ns.ProgressiveNext(units)
        return string.format("Next milestone: %s (%.2f to go)", amountText(nxt, unit), nxt - units)
    end
    if not (c and isNumber(step) and step > 0) then return "Milestones: not ready yet" end
    local unit = (st.milestoneUnit == "km") and "km" or "miles"
    local y = stepYards(step, unit)
    local onFoot = ns.OnFoot(c)
    local toGo = (math.floor(onFoot / y) + 1) * y - onFoot
    return string.format("Next milestone: %s (%.2f to go)", amountText(step, unit),
        unit == "km" and toGo * METERS_PER_YARD / 1000 or toGo / YARDS_PER_MILE)
end

-- Fire a test milestone: always plays the sound, never messages the guild.
function ns.MilestoneTest()
    local settings = ns.GetSettings() or {}
    local step = isNumber(settings.milestoneStep) and settings.milestoneStep > 0 and settings.milestoneStep or 5
    if settings.milestoneMode == "progressive" then
        local unit = settings.milestoneUnit == "km" and "km" or "miles"
        step = 1
        if ns.char then step = ns.ProgressiveNext(ns.OnFoot(ns.char) / stepYards(1, unit)) end
    end
    announce(step, settings.milestoneUnit == "km" and "km" or "miles", true)
    ns.Print("Test mode: guild messages are skipped.")
end

function ns.ResetCharTotals()
    if not ns.char then return end
    for _, cat in ipairs(CATEGORIES) do ns.char[cat] = 0 end
    ns.char.firstSeen = time()
    ns.Print("This character's totals have been reset.")
    uiCall("UI_Refresh")
end

local function printHelp()
    ns.Print("commands (/howfar or /hfib):")
    ns.Print("  (none) - show a summary")
    ns.Print("  show | hide | toggle - the on-screen panel")
    ns.Print("  lock | unlock - allow or prevent dragging the panel")
    ns.Print("  units miles|km|yards - change display units")
    ns.Print("  milestone <n> [miles|km] | progressive [miles|km] | off | test - announce every n miles/km on foot (or 1-5, 10, 20 ... 100, 200 ...)")
    ns.Print("  options | config - open the options window")
    ns.Print("  announce on|off - guild message at each milestone")
    ns.Print("  sound on|off - milestone sound")
    ns.Print("  reset - erase this character's totals (asks to confirm)")
    ns.Print("  debug - show which APIs are working")
end

local function printSummary()
    local c, s, a = ns.GetCharTotals(), ns.GetSessionTotals(), ns.GetAccountTotals()
    local f = ns.Format
    if c then
        ns.Print(string.format("%s on foot: %s (walked %s, ran %s)", ns.PlayerFullName(),
            f(ns.OnFoot(c)), f(c.walk), f(c.run)))
        ns.Print(string.format("Swam %s, rode %s, as a ghost %s", f(c.swim), f(c.mount), f(c.ghost)))
    end
    ns.Print("This session on foot: " .. f(ns.OnFoot(s)))
    ns.Print("All characters on foot: " .. f(ns.OnFoot(a)))
    ns.Print(ns.NextMilestoneText())
end

local function apiStatus(label, fn)
    ns.Print(label .. ": " .. (fn and "present" or "MISSING"))
end

local function printDebug()
    apiStatus("UnitPosition", UnitPosition)
    if UnitPosition then
        local ok, y, x, _, inst = pcall(UnitPosition, "player")
        ns.Print("  returns usable x/y: " .. tostring(ok and isNumber(x) and isNumber(y))
            .. ", instance: " .. (usable(inst) and tostring(inst) or "n/a"))
    end
    local cm = C_Map
    apiStatus("C_Map.GetBestMapForUnit", cm and cm.GetBestMapForUnit)
    apiStatus("C_Map.GetPlayerMapPosition", cm and cm.GetPlayerMapPosition)
    apiStatus("C_Map.GetMapWorldSize", cm and cm.GetMapWorldSize)
    local mapID
    if cm and cm.GetBestMapForUnit then
        local ok, id = pcall(cm.GetBestMapForUnit, "player")
        if ok and usable(id) then mapID = id end
    end
    ns.Print("  current mapID: " .. tostring(mapID))
    if cm and cm.GetPlayerMapPosition and mapID then
        local ok, p = pcall(cm.GetPlayerMapPosition, mapID, "player")
        ns.Print("  map position usable: " .. tostring(ok and usable(p)))
    end
    if cm and cm.GetMapWorldSize and mapID then
        local ok, w, h = pcall(cm.GetMapWorldSize, mapID)
        ns.Print("  world size usable: " .. tostring(ok and isNumber(w) and isNumber(h)))
    end
    apiStatus("GetUnitSpeed", GetUnitSpeed)
    if GetUnitSpeed then
        local ok, v = pcall(GetUnitSpeed, "player")
        local secret = ok and v ~= nil and issecretvalue and issecretvalue(v) and true or false
        ns.Print("  secret: " .. tostring(secret) .. ", usable: " .. tostring(ok and isNumber(v)))
    end
    apiStatus("issecretvalue", issecretvalue)
    local src = ns.CurrentSource()
    local srcText = (src == "UnitPosition" and "UnitPosition")
        or (src == "map" and "map coordinates")
        or "none (speed estimate only)"
    ns.Print("Position source right now: " .. srcText)
    local my = ns.methodYards or {}
    ns.Print("This session: " .. ns.Format(my.position or 0, "yards") .. " by position, "
        .. ns.Format(my.speed or 0, "yards") .. " by speed estimate")
end

local function handleSlash(msg)
    local settings = ns.GetSettings()
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")

    if cmd == "" then
        printSummary()
    elseif cmd == "help" then
        printHelp()
    elseif not settings then
        ns.Print("Not initialised yet.")
    elseif cmd == "show" or cmd == "hide" or cmd == "toggle" then
        local show
        if cmd == "toggle" then show = settings.hidden else show = (cmd == "show") end
        settings.hidden = not show
        uiCall("UI_SetShown", show)
    elseif cmd == "lock" or cmd == "unlock" then
        settings.locked = (cmd == "lock")
        ns.Print("Panel " .. (settings.locked and "locked." or "unlocked."))
    elseif cmd == "units" then
        if arg == "miles" or arg == "km" or arg == "yards" then
            settings.units = arg
            ns.Print("Units set to " .. arg .. ".")
            uiCall("UI_Refresh")
        else
            ns.Print("Usage: /howfar units miles|km|yards")
        end
    elseif cmd == "milestone" then
        if arg == "off" then
            settings.milestonesOn = false -- the step is kept
            ns.Print("Milestones off.")
        elseif arg == "test" then
            ns.MilestoneTest()
        elseif arg:match("^progressive") then
            local unit = arg:match("^progressive%s*(%S*)$")
            if unit == "" then unit = (settings.units == "km") and "km" or "miles" end
            if unit == "miles" or unit == "km" then
                settings.milestoneMode = "progressive"
                settings.milestoneUnit = unit
                settings.milestonesOn = true
                ns.Print("Milestones: progressive (1-5, then 10, 20 ... 100, 200 ...) in " .. unit .. ".")
            else
                ns.Print("Usage: /howfar milestone <n> [miles|km] | progressive [miles|km] | off | test")
            end
        else
            local numText, unitArg = arg:match("^(%S+)%s*(%S*)$")
            local n = tonumber(numText or "")
            local unit = unitArg
            if unit == "" then unit = (settings.units == "km") and "km" or "miles" end
            if n and n > 0 and n < 1e6 and (unit == "miles" or unit == "km") then
                settings.milestoneStep = n
                settings.milestoneUnit = unit
                settings.milestoneMode = "fixed"
                settings.milestonesOn = true
                ns.Print("Milestones every " .. amountText(n, unit) .. ".")
            else
                ns.Print("Usage: /howfar milestone <n> [miles|km] | progressive [miles|km] | off | test")
            end
        end
    elseif cmd == "announce" or cmd == "sound" then
        if arg == "on" or arg == "off" then
            local on = (arg == "on")
            if cmd == "announce" then settings.announceGuild = on else settings.milestoneSound = on end
            ns.Print((cmd == "announce" and "Guild milestone messages " or "Milestone sound ") .. (on and "on." or "off."))
        else
            ns.Print("Usage: /howfar " .. cmd .. " on|off")
        end
    elseif cmd == "reset" then
        if arg == "confirm" and ns.char then
            ns.ResetCharTotals()
        else
            ns.Print("Type /howfar reset confirm to erase this character's totals.")
        end
    elseif cmd == "options" or cmd == "config" then
        uiCall("ToggleOptions")
    elseif cmd == "debug" then
        printDebug()
    else
        printHelp()
    end
end

SLASH_HOWFAR1 = "/howfar"
SLASH_HOWFAR2 = "/hfib"
SlashCmdList["HOWFAR"] = handleSlash

------------------------------------------------------------------------
-- Events and update loop
------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then initDB() end
    elseif event == "PLAYER_LOGIN" then
        initDB() -- harmless if already done; protects against odd load order
        initChar()
        ns.session = { walk = 0, run = 0, swim = 0, mount = 0, ghost = 0 }
        ns.methodYards = { position = 0, speed = 0 }
        ns.ResetBaseline()
        uiCall("UI_Init")
        uiCall("Options_Init") -- Settings entry: must not be registered at file load
    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.ResetBaseline()
    elseif event == "PLAYER_REGEN_ENABLED" then
        flushPending()
        flushGuild()
    end
end)

local acc = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    if #guildQueue > 0 then
        guildAcc = guildAcc + elapsed
        if guildAcc >= GUILD_RETRY_INTERVAL then
            guildAcc = 0
            flushGuild()
        end
    end
    acc = acc + elapsed
    if acc < SAMPLE_INTERVAL then return end
    acc = 0
    ns.ProcessSample(GetTime())
end)
