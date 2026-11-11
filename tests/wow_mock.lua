-- Mocked WoW API for offline testing. All state lives in the global MOCK table.
-- Test-only helpers: FireEvent, TickFrames, Sync.

MOCK = {
  time = 1000,
  name = "Tester", surname = nil, realm = nil,
  unitPositionExists = true,
  unitPos = nil,            -- {x=, y=, instanceID=} or nil
  mapID = 1,
  mapPos = nil,             -- {x=, y=} (0..1) or nil
  mapWorldSize = { 4000, 2600 },
  speed = 0,
  secretSpeed = false,
  mounted = false, swimming = false, flying = false, falling = false,
  race = { "Human", "Human", 1 },   -- UnitRace returns these (raceName, raceFile, raceID)
  taxi = false, dead = false, ghost = false, inCombat = false,
  chat = {},
  frames = {},
  fontStrings = {},
  tooltip = {},             -- lines added to GameTooltip
  inGuild = true,
  chatLockdown = false,
  sounds = {},              -- {id=, channel=} per PlaySound
  sent = {},                -- {msg=, chatType=} per C_ChatInfo.SendChatMessage
}

-- Secret value sentinel: any arithmetic/comparison/concat/length use throws.
local function secretError() error("attempt to use secret value", 2) end
MOCK.SECRET = setmetatable({}, {
  __add = secretError, __sub = secretError, __mul = secretError, __div = secretError,
  __lt = secretError, __le = secretError, __unm = secretError,
  __concat = secretError, __len = secretError,
})
function issecretvalue(v) return v == MOCK.SECRET end

-- A real secret number still reports type "number", so a type() check alone
-- must not be enough to reject it: the addon has to call issecretvalue().
local rawtype = type
type = function(v)
  if rawequal(v, MOCK.SECRET) then return "number" end
  return rawtype(v)
end

-- Generic frame stub -------------------------------------------------------
local frameMethods = {}
local frameMT = {
  __index = function(_, k) return frameMethods[k] or function() end end,
}

function frameMethods.SetScript(self, name, fn) self._scripts[name] = fn end
function frameMethods.GetScript(self, name) return self._scripts[name] end
function frameMethods.RegisterEvent(self, ev) self._events[ev] = true end
function frameMethods.UnregisterEvent(self, ev) self._events[ev] = nil end
-- Show/Hide fire OnShow/OnHide on a real state change, like the game does.
function frameMethods.Show(self)
  local was = self._shown
  self._shown = true
  if not was and self._scripts.OnShow then self._scripts.OnShow(self) end
end
function frameMethods.Hide(self)
  local was = self._shown
  self._shown = false
  if was and self._scripts.OnHide then self._scripts.OnHide(self) end
end
function frameMethods.IsShown(self) return self._shown end
function frameMethods.SetShown(self, v) if v then self:Show() else self:Hide() end end
-- Widget state: check buttons, edit boxes / buttons, enabled flag.
function frameMethods.SetChecked(self, v) self._checked = v and true or false end
function frameMethods.GetChecked(self) return self._checked end
function frameMethods.SetText(self, t) self._text = t end
function frameMethods.GetText(self) return self._text end
function frameMethods.Enable(self) self._enabled = true end
function frameMethods.Disable(self) self._enabled = false end
function frameMethods.SetEnabled(self, v) self._enabled = v and true or false end
function frameMethods.IsEnabled(self) return self._enabled ~= false end
function frameMethods.SetFocus(self) self._focus = true end
function frameMethods.ClearFocus(self)
  if self._focus then
    self._focus = false
    if self._scripts.OnEditFocusLost then self._scripts.OnEditFocusLost(self) end
  end
end
-- Test helper: a user click. Check buttons toggle first (as in the game);
-- disabled buttons ignore clicks.
function frameMethods.Click(self)
  if self._enabled == false then return end
  if self._type == "CheckButton" then self._checked = not self._checked end
  if self._scripts.OnClick then self._scripts.OnClick(self, "LeftButton") end
end
function frameMethods.SetPoint(self, point, rel, relPoint, x, y)
  if type(rel) ~= "table" and rel ~= nil then x, y = relPoint, x; relPoint = rel; rel = nil end
  self._point = { point, rel, relPoint or point, x or 0, y or 0 }
end
function frameMethods.ClearAllPoints(self) self._point = nil end
function frameMethods.GetPoint(self)
  local p = self._point or { "CENTER", nil, "CENTER", 0, 0 }
  return p[1], p[2], p[3], p[4], p[5]
end
function frameMethods.SetBackdrop(self) end
function frameMethods.CreateFontString(self)
  local fs = setmetatable({ _text = "" }, frameMT)
  fs.SetText = function(s, t) s._text = t end
  fs.GetText = function(s) return s._text end
  MOCK.fontStrings[#MOCK.fontStrings + 1] = fs
  return fs
end

function CreateFrame(frameType, name, parent, template)
  local f = setmetatable({ _scripts = {}, _events = {}, _shown = true, _name = name,
    _type = frameType, _checked = false, _text = "", _enabled = true }, frameMT)
  if name then _G[name] = f end
  MOCK.frames[#MOCK.frames + 1] = f
  return f
end

UIParent = setmetatable({ _scripts = {}, _events = {} }, frameMT)
BackdropTemplateMixin = {}

DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) MOCK.chat[#MOCK.chat + 1] = msg end }

GameTooltip = setmetatable({ _scripts = {}, _events = {} }, frameMT)
function GameTooltip.SetOwner(self, owner) self._owner = owner end
function GameTooltip.GetOwner(self) return self._owner end
function GameTooltip.ClearLines() MOCK.tooltip = {} end
function GameTooltip.AddLine(_, text) MOCK.tooltip[#MOCK.tooltip + 1] = tostring(text) end
function GameTooltip.AddDoubleLine(_, l, r) MOCK.tooltip[#MOCK.tooltip + 1] = tostring(l) .. "\t" .. tostring(r) end

SlashCmdList = {}

-- Options-window support ---------------------------------------------------
UISpecialFrames = {}
StaticPopupDialogs = {}
MOCK.popups = {}            -- names passed to StaticPopup_Show
function StaticPopup_Show(name) MOCK.popups[#MOCK.popups + 1] = name end
SettingsPanel = setmetatable({ _scripts = {}, _events = {}, _shown = true }, frameMT)
MOCK.hiddenPanels = {}      -- frames passed to HideUIPanel
function HideUIPanel(f)
  MOCK.hiddenPanels[#MOCK.hiddenPanels + 1] = f
  if f then f._shown = false end
end
-- Settings mock: records registrations. To run without it, set `Settings = nil`
-- before the addon loads (Env(setup=...)).
MOCK.settingsCategories = {}  -- created by RegisterCanvasLayoutCategory
MOCK.settingsRegistered = {}  -- passed to RegisterAddOnCategory
Settings = {
  RegisterCanvasLayoutCategory = function(panel, name)
    local cat = { panel = panel, name = name }
    cat.GetID = function() return 77 end
    MOCK.settingsCategories[#MOCK.settingsCategories + 1] = cat
    return cat
  end,
  RegisterAddOnCategory = function(cat)
    MOCK.settingsRegistered[#MOCK.settingsRegistered + 1] = cat
  end,
}

-- Time / date --------------------------------------------------------------
function GetTime() return MOCK.time end
time = os.time
date = os.date

-- Unit state ---------------------------------------------------------------
function UnitName() return MOCK.name, MOCK.surname end
function UnitNameUnmodified() return MOCK.name, MOCK.surname end
function GetNormalizedRealmName() return MOCK.realm end
function GetRealmName() return MOCK.realm end
function InCombatLockdown() return MOCK.inCombat end
function UnitOnTaxi() return MOCK.taxi end
function UnitInVehicle() return false end
function UnitIsDead() return MOCK.dead end
function UnitIsGhost() return MOCK.ghost end
function IsSwimming() return MOCK.swimming end
function IsMounted() return MOCK.mounted end
function IsFlying() return MOCK.flying end
function IsFalling() return MOCK.falling end
function UnitRace() return MOCK.race[1], MOCK.race[2], MOCK.race[3] end
function IsInGuild() return MOCK.inGuild end

SOUNDKIT = { LEVEL_UP = 888 }
function PlaySound(id, channel) MOCK.sounds[#MOCK.sounds + 1] = { id = id, channel = channel } end

C_ChatInfo = {
  SendChatMessage = function(msg, chatType) MOCK.sent[#MOCK.sent + 1] = { msg = msg, chatType = chatType } end,
  InChatMessagingLockdown = function() return MOCK.chatLockdown end,
}

function GetUnitSpeed()
  if MOCK.secretSpeed then
    return MOCK.SECRET, MOCK.SECRET, MOCK.SECRET, MOCK.SECRET
  end
  return MOCK.speed, 7, 7, 4.7
end

-- UnitPosition returns y, x, z, instanceID (nothing useful in instances).
local realUnitPosition = function()
  local p = MOCK.unitPos
  if not p then return nil end
  return p.y, p.x, 0, p.instanceID
end
UnitPosition = realUnitPosition

C_Map = {
  GetBestMapForUnit = function() return MOCK.mapID end,
  GetPlayerMapPosition = function()
    local p = MOCK.mapPos
    if not p then return nil end
    return { x = p.x, y = p.y, GetXY = function(self) return self.x, self.y end }
  end,
  GetMapWorldSize = function()
    local s = MOCK.mapWorldSize
    return s[1], s[2]
  end,
}

-- Test helpers -------------------------------------------------------------
-- Honour MOCK.unitPositionExists (UnitPosition is a global that may be absent).
function Sync()
  UnitPosition = MOCK.unitPositionExists and realUnitPosition or nil
end

function FireEvent(event, ...)
  Sync()
  for _, f in ipairs(MOCK.frames) do
    if f._events[event] and f._scripts.OnEvent then f._scripts.OnEvent(f, event, ...) end
  end
end

-- Run every frame's OnUpdate once with the given elapsed time.
function TickFrames(elapsed)
  Sync()
  for _, f in ipairs(MOCK.frames) do
    if f._scripts.OnUpdate then f._scripts.OnUpdate(f, elapsed) end
  end
end
