-- Core: event dispatch, saved settings and small helpers shared by all modules.
local ADDON, ns = ...

ns.PREFIX = "RareNet"

-- Forever rares (spawns and loot from ForeverChanges, used with permission)
-- join the seed list: new rares are added, classic ones gain Forever spawns.
ns.SeedSource = {}
do
  local MERGE = 2.5
  for npc, r in pairs(ns.ForeverRares or {}) do
    local name, level, tame, uiMap, coords = r[1], r[2], r[3], r[4], r[5]
    local seed = ns.Seed[npc]
    if not seed then
      seed = { name, level, tame and 1 or 0, 0, {} }
      ns.Seed[npc] = seed
      ns.SeedSource[npc] = (ns.CuratedRares and ns.CuratedRares[npc]) and "RareNet research" or "ForeverChanges"
    else
      -- Forever's name and level win over the classic ones
      if name and name ~= "" then seed[1] = name end
      if level and level > 0 then seed[2] = level end
      if tame and seed[3] == 0 then seed[3] = 1 end
    end
    local points = seed[5]
    for i = 1, #coords, 2 do
      local x, y, near = coords[i], coords[i + 1], false
      for j = 1, #points, 3 do
        if points[j] == uiMap and (points[j + 1] - x) ^ 2 + (points[j + 2] - y) ^ 2 <= MERGE ^ 2 then near = true end
      end
      if not near and uiMap > 0 then
        points[#points + 1], points[#points + 2], points[#points + 3] = uiMap, x, y
      end
    end
  end
end
ns.VERSION = 1
ns.onLoad = {}

local issecret = issecretvalue or function() return false end
ns.issecret = issecret

-- A value we can safely compare or store, or nil when it is secret.
function ns.plain(v)
  if issecret(v) then return nil end
  return v
end

function ns.print(msg)
  print("|cff33ccff[RareNet]|r " .. msg)
end

local frame = CreateFrame("Frame")
local handlers = {}

-- Several modules can listen to the same event.
function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    frame:RegisterEvent(event)
  end
  table.insert(handlers[event], fn)
end

-- Diagnostics kept in memory and copied to the saved variables, so a
-- /reload leaves them on disk for offline debugging.
ns.diag = { counters = {}, errors = {}, log = {} }

function ns.Count(key)
  ns.diag.counters[key] = (ns.diag.counters[key] or 0) + 1
end

function ns.Log(line)
  local log = ns.diag.log
  log[#log + 1] = date("%H:%M:%S") .. " " .. line
  if #log > 50 then table.remove(log, 1) end
end

-- Run fn, recording any error instead of breaking the caller.
function ns.Safe(where, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    local errors = ns.diag.errors
    if #errors < 30 then errors[#errors + 1] = date("%H:%M:%S") .. " " .. where .. ": " .. tostring(err) end
  end
  return ok
end

frame:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event]) do ns.Safe(event, fn, ...) end
end)

ns.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  RareNetDB = RareNetDB or {}
  local db = RareNetDB
  db.settings = db.settings or {}
  local s = db.settings
  if s.filter == nil then s.filter = "all" end      -- all / tame / zone
  if s.alerts == nil then s.alerts = true end
  if s.sound == nil then s.sound = true end
  if s.localAlerts == nil then s.localAlerts = true end
  if s.alertSound == nil then s.alertSound = (s.sound == false) and "none" or "sonar" end
  if s.soundChannel == nil then s.soundChannel = "Master" end
  if s.banner == nil then s.banner = (s.raidWarning ~= false) end
  if s.bannerSize == nil then s.bannerSize = "medium" end
  if s.bannerHold == nil then s.bannerHold = 5 end
  if s.autoWaypoint == nil then s.autoWaypoint = true end
  if s.spawnPins == nil then s.spawnPins = "one" end      -- one / all
  if s.minimapPins == nil then s.minimapPins = "all" end  -- all / live / off
  if s.pinAlpha == nil then s.pinAlpha = 1 end            -- known spawn icons on the map
  if s.minimapPinAlpha == nil then s.minimapPinAlpha = 1 end
  if s.raidWarning == nil then s.raidWarning = true end
  if s.pins == nil then s.pins = "all" end         -- all / tame / off
  if s.livePins == nil then s.livePins = true end
  if s.minimapHide == nil then s.minimapHide = false end
  if s.minimapAngle == nil then s.minimapAngle = 225 end
  db.ignored = db.ignored or {}
  db.diag = ns.diag
  ns.db = db
  for _, fn in ipairs(ns.onLoad) do fn(db) end
  local restored = ns.Sightings.Restore(db, ns.Now())
  if restored > 0 then ns.Log("restored " .. restored .. " cached sightings") end
end)

ns.On("PLAYER_LOGOUT", function()
  if ns.db then ns.Sightings.Save(ns.db, ns.Now()) end
end)

-- When Blizzard blocks a protected action and blames us, keep which one.
local function blocked(kind)
  return function(addon, func)
    if addon ~= ADDON then return end
    local line = date("%H:%M:%S") .. " " .. kind .. ": " .. tostring(func)
    local errors = ns.diag.errors
    if #errors < 30 then errors[#errors + 1] = line end
    ns.Log(line)
  end
end
ns.On("ADDON_ACTION_BLOCKED", blocked("blocked"))
ns.On("ADDON_ACTION_FORBIDDEN", blocked("forbidden"))

-- Wall clock shared by all clients (seconds), used to age sightings.
function ns.Now()
  return GetServerTime()
end
