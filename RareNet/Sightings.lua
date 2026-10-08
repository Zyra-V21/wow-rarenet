-- Sightings: one entry per rare and layer.
--
-- Trust model: only first-hand reports make an entry trustworthy. A report
-- is "direct" when the sender saw the rare, "relay" when it arrives in a
-- sync reply on behalf of someone else, "local" when this client saw it.
-- An entry is confirmed when it is ours or two distinct players vouch for
-- it (direct senders or relaying responders). Relaying never refreshes an
-- entry: its time is always the original observation time.
local _, ns = ...

local Sightings = {}
ns.Sightings = Sightings

local ALIVE_TTL = 15 * 60
local DEAD_TTL = 10 * 60
local UNCONFIRMED_TTL = 6.5 * 60  -- above the re-announce interval, so a lone witness keeps it alive
local CACHE_VALID = 10 * 60     -- a logout cache older than this is dropped
local FUTURE_SKEW = 120

local entries = {}              -- id -> entry
local listeners = {}

function Sightings.Id(npc, layer) return npc .. "@" .. layer end

function Sightings.OnUpdate(fn) listeners[#listeners + 1] = fn end

local function notify(entry, isNew, removed)
  for _, fn in ipairs(listeners) do fn(entry, isNew, removed) end
end

local function seedInfo(npc)
  local seed = ns.Seed and ns.Seed[npc]
  if seed then return seed[1], seed[2], seed[3] end
end

local function count(set)
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

local function refreshTrust(e)
  e.voucherCount = count(e.vouchers)
  e.firstHandCount = count(e.firstHand)
  e.confirmed = e.mine or e.voucherCount >= 2
end

local function newEntry(report)
  local seedName, seedLevel, seedFamily = seedInfo(report.npc)
  local d = ns.db and ns.db.discovered and ns.db.discovered[report.npc]
  return {
    id = Sightings.Id(report.npc, report.layer), npc = report.npc, layer = report.layer,
    name = report.name or seedName or (d and d.name) or ("#" .. report.npc),
    level = report.level or seedLevel or (d and d.level),
    tame = (seedFamily or 0) > 0 or (d and d.tame) or false,
    known = seedName ~= nil, time = 0, confirmed = false, doubtful = false,
    vouchers = {}, firstHand = {}, negatives = {},
    voucherCount = 0, firstHandCount = 0,
  }
end

-- Merge one report. kind is "local", "direct" or "relay".
local function merge(report, sender, kind)
  local id = Sightings.Id(report.npc, report.layer)
  local e = entries[id]
  local isNew = not e
  if not e then
    e = newEntry(report)
    entries[id] = e
  end
  local changed = isNew or e.state ~= report.state or e.cached
  local wasDead = e.state == "D"
  if report.time >= e.time then
    -- A newer positive report outdates every negative sent before it.
    for who, t in pairs(e.negatives) do
      if t < report.time then e.negatives[who] = nil end
    end
    e.time, e.state = report.time, report.state
    if report.uiMap and report.uiMap > 0 then e.uiMap, e.x, e.y = report.uiMap, report.x, report.y end
  end
  if report.tame then e.tame = true end
  if report.name and e.name:sub(1, 1) == "#" then e.name = report.name end
  e.cached = false
  local wasConfirmed = e.confirmed
  if kind == "local" then
    e.mine = true
  elseif sender then
    e.vouchers[sender] = true
    if kind == "direct" then e.firstHand[sender] = true end
    e.via = e.via or sender            -- first player who passed it on
  end
  refreshTrust(e)
  e.doubtful = next(e.negatives) ~= nil
  if e.confirmed and not wasConfirmed then changed = true end
  -- Up again after a recorded death: a respawn, news like a new sighting.
  e.respawned = wasDead and e.state == "A"
  if changed then notify(e, isNew) end
  e.respawned = nil
  return e, changed
end

function Sightings.AddLocal(report)
  return merge(report, nil, "local")
end

-- Validate and merge a report from another player.
function Sightings.AddRemote(report, sender, now, kind)
  if not sender or sender == "" then return nil, "no sender" end
  if ns.db and ns.db.ignored[sender] then return nil, "ignored" end
  if report.time > now + FUTURE_SKEW then return nil, "future" end
  if now - report.time > ALIVE_TTL then return nil, "stale" end
  -- A new entry starts unconfirmed: one older than that lifetime would be
  -- created, alerted and dropped at once (old news passed on by a sync).
  if not entries[Sightings.Id(report.npc, report.layer)] and now - report.time > UNCONFIRMED_TTL then
    return nil, "expired"
  end
  return merge(report, sender, kind or "direct")
end

-- Negative evidence: sender stood next to the reported spot and did not see
-- the rare. Negatives only count when sent after the last positive; enough
-- of them (more than the first-hand witnesses, and at least two) delete it.
function Sightings.NotSeen(id, sender, t)
  local e = entries[id]
  if not e or e.mine or t <= e.time then return nil end
  if ns.db and ns.db.ignored[sender] then return nil end
  e.negatives[sender] = t
  local n = count(e.negatives)
  -- Rares with several known spawn points patrol: being absent from one
  -- spot proves little, so negatives only make them doubtful.
  local seed = ns.Seed and ns.Seed[e.npc]
  local patrols = seed and seed[5] and #seed[5] > 9
  if n >= 2 and n > e.firstHandCount and not patrols then
    entries[id] = nil
    notify(e, false, true)
    return "removed"
  end
  e.doubtful = true
  notify(e, false)
  return "doubtful"
end

function Sightings.Get(id) return entries[id] end

-- Who reported an entry, for alerts and tooltips: "seen by A, B" for players
-- who saw it themselves, "via C" when it only arrived relayed.
function Sightings.Reporters(e, link)
  local function show(name) return link and ("|Hplayer:" .. name .. "|h[" .. name .. "]|h") or name end
  local names = {}
  for who in pairs(e.firstHand or {}) do names[#names + 1] = who end
  table.sort(names)
  if #names > 0 then
    local list = {}
    for i = 1, math.min(3, #names) do list[i] = show(names[i]) end
    return "seen by " .. table.concat(list, ", ") .. (#names > 3 and (" +" .. (#names - 3)) or "")
  end
  if e.via then return "via " .. show(e.via) end
  return nil
end

local function ttl(e)
  if e.state == "D" then return DEAD_TTL end
  if not e.confirmed then return UNCONFIRMED_TTL end
  return ALIVE_TTL
end

-- Drop expired entries; returns the live ones.
function Sightings.Live(now)
  local out = {}
  for id, e in pairs(entries) do
    if now - e.time > ttl(e) then
      entries[id] = nil
    else
      out[#out + 1] = e
    end
  end
  return out
end

-- Short code of what an entry says (rare, layer, state, minute), used in
-- sync digests so a change of state travels again.
function Sightings.Code(npc, layer, state, time)
  local s = npc .. "@" .. layer .. state .. math.floor(time / 60)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 262144 end
  local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local a, b, c = math.floor(h / 4096) + 1, math.floor(h / 64) % 64 + 1, h % 64 + 1
  return A:sub(a, a) .. A:sub(b, b) .. A:sub(c, c)
end

function Sightings.Clear()
  wipe(entries)
end

-- Logout cache: kept for a short while and shown as "to verify"; it never
-- counts as a report and is never sent to other players.
function Sightings.Save(db, now)
  local list = {}
  for _, e in pairs(entries) do
    if not e.cached and now - e.time <= ttl(e) then
      list[#list + 1] = { e.npc, e.layer, e.uiMap or 0, e.x or 0, e.y or 0, e.state, e.time, e.tame and 1 or 0, e.name }
    end
  end
  db.cache = { saved = now, entries = list }
end

function Sightings.Restore(db, now)
  local c = db.cache
  db.cache = nil
  if not c or not c.saved or now - c.saved > CACHE_VALID then return 0 end
  local n = 0
  for _, r in ipairs(c.entries or {}) do
    local report = { npc = r[1], layer = r[2], uiMap = r[3], x = r[4], y = r[5], state = r[6], time = r[7], tame = r[8] == 1, name = r[9] }
    if now - report.time <= ALIVE_TTL then
      local e = newEntry(report)
      e.time, e.state, e.uiMap, e.x, e.y = report.time, report.state, report.uiMap, report.x, report.y
      e.cached = true
      entries[e.id] = e
      n = n + 1
    end
  end
  return n
end
