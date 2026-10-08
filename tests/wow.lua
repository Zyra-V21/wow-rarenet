-- Minimal WoW API mock: a fake clock, timers, frames and the unit/chat calls RareNet uses.
local M = { clock = 1000, server = 1700000000, timers = {}, frames = {}, units = {}, sent = {}, printed = {} }
WOW = M

local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
M.SECRET = SECRET
function issecretvalue(v) return v == SECRET end

-- A seeded random generator: every run takes the same random waits, so a
-- failure can be reproduced (fengari's own is unseeded).
local seed = tonumber(os.getenv and os.getenv("RARENET_SEED") or nil) or 20261008
function math.randomseed(s) seed = s end
function math.random(m, n)
  seed = (seed * 1103515245 + 12345) % 2147483648
  local r = seed / 2147483648
  if not m then return r end
  if not n then m, n = 1, m end
  return m + math.floor(r * (n - m + 1))
end

function GetTime() return M.clock end
function GetServerTime() return math.floor(M.server) end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function date() return "12:00:00" end
function print(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end M.printed[#M.printed + 1] = table.concat(t, " ") end
function strsplit(sep, s)
  local out, start = {}, 1
  while true do
    local i = s:find(sep, start, true)
    if not i then out[#out + 1] = s:sub(start); break end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
  return table.unpack(out)
end
function Ambiguate(n) return (n:gsub("%-.*", "")) end
C_Timer = { After = function(d, f) M.timers[#M.timers + 1] = { M.clock + d, f } end,
  NewTicker = function(d, f) local t = { Cancel = function() end } return t end }

-- Sizes are numbers in the client: layout code adds them up.
local SIZES = { GetStringWidth = true, GetStringHeight = true, GetWidth = true, GetHeight = true }
local function stub()
  return setmetatable({}, { __index = function(t, k)
    if SIZES[k] then return function() return 0 end end
    return function(self, ...) return stub() end
  end })
end
function CreateFrame(kind, name)
  local f = { scripts = {}, events = {}, shown = true }
  function f:RegisterEvent(e) self.events[e] = true end
  function f:SetScript(n, fn) self.scripts[n] = fn end
  function f:Show() self.shown = true end
  function f:Hide() self.shown = false end
  function f:IsShown() return self.shown end
  setmetatable(f, { __index = function(t, k) return function() return stub() end end })
  M.frames[#M.frames + 1] = f
  if name then _G[name] = f end
  return f
end
UIParent = stub()

function M.fire(event, ...)
  for _, f in ipairs(M.frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
function M.step(seconds)
  local target = M.clock + seconds
  while M.clock < target - 1e-9 do
    M.clock = M.clock + 0.1
    M.server = M.server + 0.1
    table.sort(M.timers, function(a, b) return a[1] < b[1] end)
    while M.timers[1] and M.timers[1][1] <= M.clock do table.remove(M.timers, 1)[2]() end
    for _, f in ipairs(M.frames) do if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 0.1) end end
  end
end

-- Units: M.units[token] = { guid, name, level, class, dead, family, controlled }
local function u(t) return M.units[t] end
function UnitExists(t) return u(t) ~= nil end
function UnitGUID(t) return u(t) and u(t).guid end
function UnitName(t) if t == "player" then return "Me", nil end return u(t) and u(t).name end
function UnitFullName(t) return "Me", "Realm" end
function UnitLevel(t) return u(t) and u(t).level end
function UnitClassification(t) return u(t) and u(t).class or "normal" end
function UnitIsDead(t) return u(t) and u(t).dead or false end
function UnitCreatureFamily(t) return u(t) and u(t).family end
function UnitPlayerControlled(t) return u(t) and u(t).controlled or false end
function UnitCanAttack() return true end
function IsInInstance() return M.inInstance or false end
function IsInGuild() return M.guild or false end

C_Map = {
  GetBestMapForUnit = function() return 1413 end,
  GetPlayerMapPosition = function() return { GetXY = function() return 0.452, 0.317 end } end,
  GetMapInfo = function(id) return { name = id == 1413 and "The Barrens" or ("Map" .. id), mapType = (id == 1414) and 2 or 3 } end,
  -- Mulgore (1412) and The Barrens (1413) inside Kalimdor (1414)
  GetMapRectOnMap = function(from, to)
    if to ~= 1414 then return nil end
    if from == 1412 then return 0.4, 0.5, 0.6, 0.8 end
    if from == 1413 then return 0.5, 0.6, 0.4, 0.7 end
  end,
  CanSetUserWaypointOnMap = function() return true end,
  GetMapWorldSize = function() return 3000, 2000 end,
  SetUserWaypoint = function(p) M.waypoint = p end,
}
UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { m = m, x = x, y = y } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
M.channels = {}
M.channelResult = 0
function JoinTemporaryChannel(name) if not M.blockedChannels or not M.blockedChannels[name] then M.channels[name] = 5 end end
function GetChannelName(name) return M.channels[name] or 0 end
function LeaveChannelByName(name) M.channels[name] = nil end
C_ChatInfo = {
  RegisterAddonMessagePrefix = function() return true end,
  InChatMessagingLockdown = function() return false end,
  SendAddonMessage = function(prefix, msg, chatType, target)
    M.sent[#M.sent + 1] = { prefix = prefix, msg = msg, chatType = chatType, target = target }
    if chatType == "CHANNEL" then return M.channelResult end
    return 0
  end,
}
Enum = { UIMapType = { Continent = 2, Zone = 3 }, SendAddonMessageResult = { Success = 0, InvalidChatType = 4, InvalidChannel = 7, AddonMessageThrottle = 3 } }
function PlaySound(id, channel) M.sound = id; M.soundChannel = channel end
function PlaySoundFile(f, channel) M.sound = f; M.soundChannel = channel; return not M.badSoundFile end
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
SlashCmdList = {}

-- Loot window: M.loot = { { link = "...", quest = false, sources = { guid, qty, ... } }, ... }
M.loot = {}
function GetNumLootItems() return #M.loot end
function GetLootSlotInfo(i) local l = M.loot[i]; return nil, nil, 1, nil, 1, false, l and l.quest or false end
function GetLootSlotLink(i) return M.loot[i] and M.loot[i].link end
function GetLootSourceInfo(i) return table.unpack(M.loot[i] and M.loot[i].sources or {}) end
function IsStealthed() return M.stealth or false end

M.itemNames = { [17922] = "Lionfur Armor", [4814] = "Discolored Fang" }
C_Item = {
  GetItemInfo = function(id) local n = M.itemNames[id]; if n then return n, "|Hitem:" .. id .. "|h[" .. n .. "]|h" end end,
  GetItemIconByID = function() return 134400 end,
  GetItemQualityColor = function(q) return 1, 1, 1 end,
  GetItemInfoInstant = function(id) if id and id < 900000 then return id end end,
  GetItemQualityByID = function(id) return 2 end,
}
function HandleModifiedItemClick(link) M.modifiedLink = link; return true end
function IsShiftKeyDown() return M.shift or false end
function OpenWorldMap(id) M.openedMap = id end
MenuUtil = { CreateContextMenu = function(owner, gen)
  local root = { items = {} }
  function root:CreateTitle(t) end
  function root:CreateButton(t, fn) self.items[t] = fn end
  gen(owner, root)
  M.menu = root.items
end }
M.addons = {}
C_AddOns = { IsAddOnLoaded = function(name) return M.addons[name] or false end,
  GetAddOnMetadata = function(name, key) return key == "Version" and "0.3.2" or nil end }

-- Map, minimap and settings bits
function CreateFromMixins(...)
  local t = {}
  for i = 1, select("#", ...) do for k, v in pairs((select(i, ...))) do t[k] = v end end
  return t
end
MapCanvasPinMixin = { UseFrameLevelType = function(self, t) self.levelType = t end, SetScalingLimits = function() end }
MapCanvasDataProviderMixin = { GetMap = function(self) return self.map end }
M.acquired = {}
M.fakeMap = {
  mapID = 1412,
  GetMapID = function(self) return self.mapID end,
  RemoveAllPinsByTemplate = function() M.acquired = {} end,
  AcquirePin = function(_, template, data) M.acquired[#M.acquired + 1] = data end,
}
WorldMapFrame = {
  shown = true,
  AddDataProvider = function(self, p) p.map = M.fakeMap; M.provider = p end,
  IsShown = function(self) return self.shown end,
}
Minimap = setmetatable({ GetWidth = function() return 140 end, GetZoom = function() return 0 end, GetFrameLevel = function() return 1 end, GetCenter = function() return 100, 100 end,
  GetEffectiveScale = function() return 1 end }, { __index = function() return function() return stub() end end })
function GetCursorPosition() return 0, 0 end
GameTooltip = stub()
UISpecialFrames = {}
function tinsert(t, v) table.insert(t, v) end
C_Texture = { GetAtlasInfo = function(a) return a == "VignetteKill" and {} or nil end }
M.cvars = { nameplateShowEnemies = "0" }
function GetCVar(k) return M.cvars[k] end
function SetCVar(k, v) M.cvars[k] = v end
function InCombatLockdown() return M.combat or false end
function StaticPopup_Show(name) M.popup = name end
return M
