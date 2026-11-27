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

local CATEGORIES = { "walk", "run", "swim", "glide", "mount", "ghost" }

local GUILD_RETRY_INTERVAL = 5     -- seconds between attempts to flush queued guild messages
local GUILD_SEND_SPACING = 0.25   -- seconds between guild messages (each is sent from a C_Timer callback)
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
    showSpeed = true,          -- current movement speed in the panel's bottom-right corner
    speedFormat = "percent",   -- "percent", "yards", "mph" or "kmh"
}

local SPEED_FORMATS = { percent = true, yards = true, mph = true, kmh = true }
local NORMAL_RUN_SPEED = 7            -- yd/s, shown as 100%

ns.session = { walk = 0, run = 0, swim = 0, glide = 0, mount = 0, ghost = 0 }
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
    if type(st.showSpeed) ~= "boolean" then st.showSpeed = true end
    if not SPEED_FORMATS[st.speedFormat] then st.speedFormat = "percent" end
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

-- Character keys carry NO realm: just the full name ("Light Ofhope"). The realm
-- name is not stable on Forever (an update on 2026-11-20 made it come back
-- empty, which split every character's totals into a second entry), so older
-- keys of the form "<name>-<realm>" (and the even older "<first>-<realm>")
-- are folded into the canonical entry at login.
local function resolveCharKey()
    local first, surname = readNameParts()
    if not first then return "Unknown", nil, nil end
    if not surname then return first, first, first end
    return ns.PlayerFullName(), first, ns.PlayerFullName()
end

local function hasPrefix(k, prefix)
    return k:sub(1, #prefix) == prefix
end

-- Folds every legacy entry for this character into chars[key] and deletes them.
local function foldLegacy(chars, key, first, full)
    local legacy = {}
    for k, v in pairs(chars) do
        if type(k) == "string" and k ~= key and type(v) == "table"
            and (hasPrefix(k, full .. "-") or hasPrefix(k, first .. "-")
                or (key == full and k == first)) then
            legacy[#legacy + 1] = k
        end
    end
    if #legacy == 0 then return end
    table.sort(legacy)
    local entry = chars[key]
    if type(entry) ~= "table" then
        entry = {}
        chars[key] = entry
    end
    local isCat = {}
    for _, cat in ipairs(CATEGORIES) do isCat[cat] = true end
    for _, k in ipairs(legacy) do
        local old = chars[k]
        for _, cat in ipairs(CATEGORIES) do
            entry[cat] = (type(entry[cat]) == "number" and entry[cat] or 0)
                + (type(old[cat]) == "number" and old[cat] or 0)
        end
        if type(old.firstSeen) == "number"
            and (type(entry.firstSeen) ~= "number" or old.firstSeen < entry.firstSeen) then
            entry.firstSeen = old.firstSeen
        end
        for f, v in pairs(old) do
            if not isCat[f] and f ~= "firstSeen" and entry[f] == nil then entry[f] = v end
        end
        chars[k] = nil
    end
end

local function initChar()
    local key, first, full = resolveCharKey()
    ns.charKey = key
    local chars = HowFarHaveIBeenDB.chars
    if first then foldLegacy(chars, key, first, full) end
    local entry = chars[key]
    if type(entry) ~= "table" then
        entry = {}
        chars[key] = entry
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
    local sum = { walk = 0, run = 0, swim = 0, glide = 0, mount = 0, ghost = 0 }
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

function ns.ReadSpeed() return readSpeed() end

-- Speed text for the panel: percent of normal run speed, yd/s, mph or km/h.
-- nil (unavailable or secret) shows "--".
function ns.FormatSpeed(yps, fmt)
    if yps == nil then return "--" end
    if fmt == "yards" then
        return string.format("%.1f yd/s", yps)
    elseif fmt == "mph" then
        return string.format("%.1f mph", yps * 3600 / YARDS_PER_MILE)
    elseif fmt == "kmh" then
        return string.format("%.1f km/h", yps * METERS_PER_YARD * 3.6)
    end
    return math.floor(yps / NORMAL_RUN_SPEED * 100 + 0.5) .. "%"
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

-- True when the player is Skyborne (the race that can glide). Unknown (API
-- missing, erroring or secret values) counts as false.
function ns.CanGlide()
    if type(UnitRace) ~= "function" then return false end
    local ok, _, raceFile, raceID = pcall(UnitRace, "player")
    if not ok then return false end
    if usable(raceFile) and type(raceFile) == "string" and raceFile == "Skyborne" then return true end
    if usable(raceID) and type(raceID) == "number" and (raceID == 95 or raceID == 96) then return true end
    return false
end

local function category(speed, glide)
    if flag("UnitIsGhost", "player") then return "ghost" end
    if flag("IsSwimming") then return "swim" end
    if flag("IsMounted") or flag("IsFlying") then return "mount" end
    if glide then return "glide" end
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

-- Guild chat goes out one message at a time, in order, each from a C_Timer
-- callback, GUILD_SEND_SPACING apart (as Details does on Forever). Sending a
-- whole report in one frame scrambled its order, and a milestone sent straight
-- from the sampling OnUpdate was refused ("Interface action failed because of
-- an AddOn"), while sends from a timer callback get through.
-- Without C_Timer the frame's OnUpdate pumps one message per spacing instead.
local lastGuildMsg, lastGuildAt   -- the last entry handed to the game, and when
local guildTimerPending = false
-- Set when the game blocked a send made from a timer: from then on queued
-- messages are sent one per hardware event (key press, panel click). The same
-- mode is remembered per character and guild in ns.char.guildKeyMode, so later
-- sessions skip the timer (and the game's block warning) altogether.
local guildNeedsHardware = false
local guildHardwareNotified = false
local keyListener              -- hidden keyboard frame, created at PLAYER_LOGIN
local keyRouteUnavailable = false
local inCombat = false         -- PLAYER_REGEN_DISABLED fires before InCombatLockdown() turns true
local sendingEntry             -- the entry being handed to the game right now
local GUILD_MAX_ATTEMPTS = 3

local function hasTimer()
    return C_Timer ~= nil and type(C_Timer.After) == "function"
end

local function currentGuildName()
    if type(GetGuildInfo) ~= "function" then return nil end
    local ok, name = pcall(GetGuildInfo, "player")
    if ok and usable(name) and type(name) == "string" and name ~= "" then return name end
    return nil
end

-- True when guild messages must go out on a hardware event. Evaluated at send
-- time because guild info can load late after login.
local function keyModeActive()
    if guildNeedsHardware then return true end
    local c = ns.char
    local stored = c and c.guildKeyMode
    if stored == nil then return false end
    local g = currentGuildName()
    if type(stored) == "string" and g and g == stored then return true end
    if g then c.guildKeyMode = nil end -- other guild (or junk): back to timer mode
    return false
end

-- The key listener is shown ONLY while a message waits for a key press, and
-- never in combat, so it can never swallow input. It must propagate keys.
local function keyListenerCanPropagate(f)
    pcall(f.SetPropagateKeyboardInput, f, true)
    if type(f.GetPropagateKeyboardInput) == "function" then
        local ok, v = pcall(f.GetPropagateKeyboardInput, f)
        if not ok or v ~= true then return false end
    end
    return true
end

local function updateKeyListener()
    local f = keyListener
    if not f then return end
    local want = not keyRouteUnavailable and #guildQueue > 0 and not inCombat
        and not (InCombatLockdown and InCombatLockdown()) and keyModeActive()
    if want then
        if not f:IsShown() then
            if not keyListenerCanPropagate(f) then
                keyRouteUnavailable = true
                return
            end
            f:Show()
        end
    elseif f:IsShown() then
        f:Hide()
    end
end

local pumpGuild

local function scheduleGuild(delay)
    if guildTimerPending or not hasTimer() then return end
    guildTimerPending = true
    C_Timer.After(delay, function()
        guildTimerPending = false
        pumpGuild(false)
    end)
end

local function noteHeldForKey()
    if guildHardwareNotified then return end
    guildHardwareNotified = true
    ns.Print("Your guild's chat only accepts addon messages on a key press (it's linked to Discord); it will post on your next key press.")
end

pumpGuild = function(fromHardware)
    if #guildQueue == 0 or chatLocked() then return end
    if keyModeActive() and not fromHardware then
        noteHeldForKey()
        updateKeyListener()
        return
    end
    if fromHardware and lastGuildAt
        and GetTime() - lastGuildAt < GUILD_SEND_SPACING - 1e-9 then return end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if type(send) ~= "function" then -- nothing can send; drop rather than retry forever
        guildQueue = {}
        updateKeyListener()
        return
    end
    local entry = table.remove(guildQueue, 1)
    entry.attempts = entry.attempts + 1
    lastGuildMsg, lastGuildAt = entry, GetTime()
    sendingEntry = entry
    pcall(send, entry.text, "GUILD")
    sendingEntry = nil
    -- A block may have arrived synchronously and put the entry back; then key
    -- mode is on and no timer send follows.
    if not fromHardware and #guildQueue > 0 and not keyModeActive() then
        scheduleGuild(GUILD_SEND_SPACING)
    end
    updateKeyListener()
end

-- Called from hardware events (key presses on the key listener, panel clicks).
function ns.GuildHardwareEvent()
    if keyModeActive() then
        pcall(pumpGuild, true)
    end
    updateKeyListener()
end

local function sendGuild(msg)
    if #guildQueue == 0 then guildAcc = 0 end
    guildQueue[#guildQueue + 1] = { text = msg, attempts = 0 }
    local delay = 0
    if lastGuildAt then
        delay = math.max(0, GUILD_SEND_SPACING - (GetTime() - lastGuildAt))
    end
    scheduleGuild(delay)
    updateKeyListener()
end

------------------------------------------------------------------------
-- Distance report (Ctrl+click on the panel, /howfar report)
------------------------------------------------------------------------
local REPORT_COOLDOWN = 10     -- seconds between reports
local lastReport               -- GetTime() of the last report that was posted or queued

-- Report lines for this character (one chat message each), or nil before the
-- totals exist. Walked/Ran only show when both are non-zero (otherwise they
-- would just repeat the On foot line).
function ns.BuildReport()
    local c = ns.char
    if not c then return nil end
    local zero = ns.Format(0)
    local function nz(v)
        local s = ns.Format(v or 0)
        if s ~= zero then return s end
        return nil
    end
    local suffix = "'s travels:"
    local name = ns.PlayerFullName()
    if #name + #suffix > 254 then name = name:sub(1, 254 - #suffix) end
    local lines = { name .. suffix, "On foot: " .. ns.Format(ns.OnFoot(c)) }
    local ran, walked = nz(c.run), nz(c.walk)
    if ran and walked then
        lines[#lines + 1] = "Ran: " .. ran
        lines[#lines + 1] = "Walked: " .. walked
    end
    local extras = { { "Swam: ", c.swim }, { "Glided: ", c.glide }, { "Rode: ", c.mount }, { "As a ghost: ", c.ghost } }
    for _, x in ipairs(extras) do
        local v = nz(x[2])
        if v then lines[#lines + 1] = x[1] .. v end
    end
    return lines
end

function ns.PostReport()
    local report = ns.BuildReport()
    if not report then
        ns.Print("Your totals aren't ready yet.")
        return
    end
    local now = GetTime and GetTime() or 0
    if lastReport and now - lastReport < REPORT_COOLDOWN then
        ns.Print(string.format("You can post another report in %d s.", math.ceil(REPORT_COOLDOWN - (now - lastReport))))
        return
    end
    if not flag("IsInGuild") then
        ns.Print("Not in a guild, so only you see this:")
        for _, line in ipairs(report) do ns.Print(line) end
        return
    end
    local locked = chatLocked()
    for _, line in ipairs(report) do sendGuild(line) end
    lastReport = now
    if locked then
        ns.Print("Report will post to guild when combat ends.")
    else
        ns.Print("Posting your distance report to guild chat.")
    end
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
local groundSpeed, prevGliding -- glide detection: last speed while not falling (nil: assume normal run speed); was the previous sample a glide

function ns.ResetBaseline()
    lastTime = GetTime and GetTime() or 0
    base = nil
    prevSpeed = nil
    groundSpeed = nil
    prevGliding = false
end

function ns.ProcessSample(now)
    local dt = now - (lastTime or now)
    lastTime = now
    -- Loading screens and lag spikes produce huge or non-positive gaps.
    if dt <= 0 or dt > MAX_DT then base = nil; return end
    if excluded() then base = nil; prevSpeed = 0; prevGliding = false; return end

    local speed = readSpeed()
    -- Gliding (Skyborne): the client reports it as falling at a speed well above
    -- the ground speed (a plain jump keeps the ground speed).
    local falling = flag("IsFalling")
    if not falling and speed ~= nil then groundSpeed = speed end
    local gliding = falling and speed ~= nil and speed > (groundSpeed or 7) + 1 and ns.CanGlide()
    -- The sample right after a glide ends still covers glided distance.
    local glideCat = gliding or (prevGliding and not falling)
    prevGliding = gliding and true or false
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
        local cat = category(movingSpeed, glideCat)
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
    ns.Print("  speed on|off|percent|yards|mph|kmh - current speed on the panel, and its format")
    ns.Print("  options | config - open the options window")
    ns.Print("  announce on|off - guild message at each milestone")
    ns.Print("  sound on|off - milestone sound")
    ns.Print("  report - post your distances to guild chat (or Ctrl+click the panel)")
    ns.Print("  reset - erase this character's totals (asks to confirm)")
    ns.Print("  debug - show which APIs are working")
end

local function printSummary()
    local c, s, a = ns.GetCharTotals(), ns.GetSessionTotals(), ns.GetAccountTotals()
    local f = ns.Format
    if c then
        ns.Print(string.format("%s on foot: %s (walked %s, ran %s)", ns.PlayerFullName(),
            f(ns.OnFoot(c)), f(c.walk), f(c.run)))
        if ns.CanGlide() then
            ns.Print(string.format("Swam %s, glided %s, rode %s, as a ghost %s", f(c.swim), f(c.glide), f(c.mount), f(c.ghost)))
        else
            ns.Print(string.format("Swam %s, rode %s, as a ghost %s", f(c.swim), f(c.mount), f(c.ghost)))
        end
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
    ns.Print("Glide: can glide " .. (ns.CanGlide() and "yes" or "no")
        .. ", gliding now " .. (prevGliding and "yes" or "no")
        .. ", ground speed " .. (groundSpeed and string.format("%.1f", groundSpeed) or "n/a"))
    local my = ns.methodYards or {}
    ns.Print("This session: " .. ns.Format(my.position or 0, "yards") .. " by position, "
        .. ns.Format(my.speed or 0, "yards") .. " by speed estimate")
    local lb = ns.lastBlocked
    if lb then
        ns.Print("Last blocked action: " .. lb.func .. " (" .. lb.event .. "), "
            .. math.floor(GetTime() - lb.time + 0.5) .. " s ago")
    else
        ns.Print("Last blocked action: none")
    end
    ns.Print((keyRouteUnavailable and "Guild chat: waits for a panel click (key listener unavailable)"
        or keyModeActive() and "Guild chat: waits for a key press (this guild blocked a timer send)"
        or "Guild chat: sent from a timer")
        .. ((#guildQueue > 0) and (" - " .. #guildQueue .. " waiting") or ""))
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
    elseif cmd == "speed" then
        if arg == "on" or arg == "off" then
            settings.showSpeed = (arg == "on")
            ns.Print(settings.showSpeed and ("Speed display on (" .. tostring(settings.speedFormat) .. ").")
                or "Speed display off.")
        elseif SPEED_FORMATS[arg] then
            settings.speedFormat = arg
            settings.showSpeed = true
            ns.Print("Speed display on (" .. arg .. ").")
        else
            ns.Print("Usage: /howfar speed on|off|percent|yards|mph|kmh")
            return
        end
        uiCall("UI_Refresh")
        uiCall("Options_Refresh")
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
    elseif cmd == "report" then
        ns.PostReport()
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
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")

-- Hidden keyboard frame: a key press (OnKeyDown) is a hardware event, so guild
-- chat the game blocks from a timer is sent from it. Shown only while a message
-- waits (see updateKeyListener); it always propagates keys.
local function createKeyListener()
    local f = CreateFrame("Frame", nil, UIParent)
    f:Hide()
    f:EnableKeyboard(true)
    f:SetScript("OnKeyDown", function() ns.GuildHardwareEvent() end)
    keyListener = f
end

frame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then initDB() end
    elseif event == "PLAYER_LOGIN" then
        initDB() -- harmless if already done; protects against odd load order
        initChar()
        ns.session = { walk = 0, run = 0, swim = 0, glide = 0, mount = 0, ghost = 0 }
        ns.methodYards = { position = 0, speed = 0 }
        ns.ResetBaseline()
        uiCall("UI_Init")
        uiCall("Options_Init") -- Settings entry: must not be registered at file load
        createKeyListener()
    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.ResetBaseline()
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        flushPending()
        scheduleGuild(0)
        updateKeyListener()
    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        updateKeyListener()
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        if arg1 ~= addonName then return end
        local now = GetTime()
        local lb = { event = event, func = usable(arg2) and tostring(arg2) or "?", time = now }
        ns.lastBlocked = lb
        local entry = sendingEntry
        if not entry and lastGuildMsg and lastGuildAt and now - lastGuildAt <= 1 then
            entry = lastGuildMsg
        end
        if entry then
            lb.msg = entry.text
            if entry.handledAttempt ~= entry.attempts then
                entry.handledAttempt = entry.attempts
                if entry.attempts < GUILD_MAX_ATTEMPTS then
                    table.insert(guildQueue, 1, entry)
                    guildNeedsHardware = true
                    local g = currentGuildName()
                    if g and ns.char then ns.char.guildKeyMode = g end
                    noteHeldForKey()
                else
                    ns.Print("Couldn't post to guild chat: " .. tostring(entry.text))
                end
                updateKeyListener()
            end
        end
    end
end)

local acc = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    if #guildQueue > 0 then
        guildAcc = guildAcc + elapsed
        if guildAcc >= GUILD_RETRY_INTERVAL then
            guildAcc = 0
            scheduleGuild(0)
        end
    end
    -- No C_Timer: pump one queued message per spacing from here.
    if #guildQueue > 0 and not hasTimer()
        and (not lastGuildAt or GetTime() - lastGuildAt >= GUILD_SEND_SPACING - 1e-9) then
        pumpGuild(false)
    end
    acc = acc + elapsed
    if acc < SAMPLE_INTERVAL then return end
    acc = 0
    ns.ProcessSample(GetTime())
end)
