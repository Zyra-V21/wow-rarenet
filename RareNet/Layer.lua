-- Layer detection from creature GUIDs.
--
-- "Creature-0-4621-1-60439-3244-0000420B05" reads as
-- type-0-serverID-mapID-zoneUID-npcID-spawnUID. The zoneUID differs between
-- layers but is only meaningful inside one map (continent) and is reassigned
-- when the server restarts, so a layer key is serverID-mapID-zoneUID and two
-- keys are only compared when they share serverID and mapID.
local _, ns = ...

local Layer = {}
ns.Layer = Layer

local CONFIRMATIONS = 2      -- distinct creatures agreeing on a new zoneUID
local OBSERVATION_TTL = 60   -- seconds a pending observation stays valid

local current                -- { server, map, zone, key }
local candidate              -- { server, map, zone, spawns = {}, seen = t }
local listeners = {}
local lastObserved              -- time a creature last agreed with the current layer

function Layer.Key(server, map, zone)
  return server .. "-" .. map .. "-" .. zone
end

function Layer.ParseGUID(guid)
  if ns.issecret(guid) then ns.Count("guid secret"); return nil end
  if type(guid) ~= "string" then ns.Count("guid missing"); return nil end
  ns.diag.lastGUID = guid
  local kind, _, server, map, zone, npc, spawn = strsplit("-", guid)
  if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
  server, map, zone, npc = tonumber(server), tonumber(map), tonumber(zone), tonumber(npc)
  if not (server and map and zone and npc and spawn) then ns.Count("guid unparsed"); return nil end
  ns.Count("guid parsed")
  return { server = server, map = map, zone = zone, npc = npc, spawn = spawn,
    key = Layer.Key(server, map, zone) }
end

function Layer.OnChange(fn) listeners[#listeners + 1] = fn end

local function setCurrent(info)
  ns.Log("layer " .. info.key)
  local old = current
  current = { server = info.server, map = info.map, zone = info.zone, key = info.key }
  candidate = nil
  for _, fn in ipairs(listeners) do fn(current, old) end
end

-- Feed one creature GUID seen around the player.
function Layer.Observe(info, now)
  if not info then return end
  if current and current.key == info.key then
    candidate = nil
    lastObserved = now
    return
  end
  -- The first reading on a new map is trusted at once; a different zoneUID on
  -- the same map needs confirmation from other creatures first.
  if not current or current.map ~= info.map or current.server ~= info.server then
    setCurrent(info)
    lastObserved = now
    return
  end
  if not candidate or candidate.key ~= info.key or now - candidate.seen > OBSERVATION_TTL then
    candidate = { key = info.key, spawns = {}, count = 0, seen = now }
  end
  if not candidate.spawns[info.spawn] then
    candidate.spawns[info.spawn] = true
    candidate.count = candidate.count + 1
    candidate.seen = now
  end
  if candidate.count >= CONFIRMATIONS then
    setCurrent(info)
    lastObserved = now
  end
end

function Layer.LastObserved() return lastObserved end

function Layer.Current() return current end

-- Whether a layer key is the player's own layer: true, false, or nil when
-- the two cannot be compared (another continent or server).
function Layer.IsMine(key)
  if not current or not key then return nil end
  local server, map = key:match("^(%d+)%-(%d+)%-")
  if tonumber(server) ~= current.server or tonumber(map) ~= current.map then return nil end
  return key == current.key
end

-- Short label for a layer key, e.g. "L60439".
function Layer.Label(key)
  local zone = key and key:match("%-(%d+)$")
  return zone and ("L" .. zone) or "L?"
end

function Layer.Reset()
  current, candidate, lastObserved = nil, nil, nil
end
