-- Peer-to-peer sync and verification.
--
-- * Join sync: a newcomer broadcasts H2 with a digest of what it already
--   has. One responder, elected the same way by every client (lowest hash
--   of name..nonce among recently active peers), answers within a second;
--   the others wait and only fill gaps nobody has sent yet. Hellos arriving
--   while a round is pending join it, rounds are at least 20 s apart, and
--   replies are only accepted inside a round opened by a hello.
-- * Verification: entries expire on their own; witnesses re-announce; a
--   player standing at a reported spot who does not see the rare sends N2.
--   Players whose reports get refuted collect strikes and are ignored.
-- * Discovered rares travel by slow random gossip (D2).
local _, ns = ...

local Sync = {}
ns.Sync = Sync

local HELLO_JITTER = { 3, 6 }    -- seconds after joining the channel
local ROUND_GAP = 20             -- seconds between sync rounds
local ROUND_WINDOW = 15          -- replies accepted this long after a hello
local ELECTED_DELAY = { 0.3, 0.8 }
local FILL_DELAY = { 3, 5 }
local REPLY_MESSAGES = 3         -- per responder and round
local PER_MESSAGE = 5            -- sightings per reply message
local ACTIVE_WINDOW = 10 * 60
local NOTSEEN_RANGE = 30         -- yards
local NOTSEEN_DWELL = 10         -- seconds near the spot before judging
local NOTSEEN_AFTER = 60         -- seconds since the last positive report
local LAYER_FRESH = 120          -- seconds since our layer was last observed
local SEEN_RECENT = 10           -- seconds; seeing the rare this recently vetoes N2
local GOSSIP_EVERY = 5 * 60
local STRIKES = 5               -- refuted single-source reports before a pause
local STRIKE_MEMORY = 30 * 60    -- strikes are forgotten after this
local PAUSE = 30 * 60            -- automatic ignore lasts this long, never saved

local round                      -- { nonce, digests = {}, opened, sent = {} }
local lastRoundAt = -ROUND_GAP
local nearSince = {}             -- entry id -> time we got within range
local notSeenSent = {}           -- entry id .. entry time -> true
local strikes = {}               -- sender -> { n, at }
local paused = {}                -- sender -> time the automatic ignore ends
local lastSeenNpc = {}           -- npc -> time any unit of it was seen
local lastGossip = 0

local function between(range) return range[1] + math.random() * (range[2] - range[1]) end

local function hash(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
  return h
end

function Sync.SawNpc(npc, now) lastSeenNpc[npc] = now end

-- Hello -----------------------------------------------------------------------

local function digest(now)
  local codes = {}
  for _, e in ipairs(ns.Sightings.Live(now)) do
    if not e.cached and #codes < 40 then codes[#codes + 1] = ns.Sightings.Code(e.npc, e.layer, e.state, e.time) end
  end
  return table.concat(codes)
end

function Sync.SendHello()
  local now = ns.Now()
  local nonce = tostring(math.random(100000, 999999))
  ns.Net.Enqueue("H2|" .. nonce .. "|" .. digest(now), ns.Net.PRIO.hello)
  ns.Log("hello " .. nonce)
end

ns.Net.OnJoined(function()
  C_Timer.After(between(HELLO_JITTER), function() ns.Safe("hello", Sync.SendHello) end)
end)

local function inDigests(code)
  if not round then return false end
  for _, d in ipairs(round.digests) do
    if not d[code] then return false end
  end
  return true
end

local function parseDigest(s)
  local set = {}
  for i = 1, #(s or ""), 3 do set[s:sub(i, i + 2)] = true end
  return set
end

-- Entry as it travels in a Y2 batch: npc,layer,uiMap,x,y,state,time,tame
local function encodeEntry(e)
  return string.format("%d,%s,%d,%d,%d,%s,%d,%d", e.npc, e.layer, e.uiMap or 0,
    ns.Net.EncodeXY(e.x), ns.Net.EncodeXY(e.y), e.state, e.time, e.tame and 1 or 0)
end

local function reply()
  if not round then return end
  local now = ns.Now()
  local batch, messages = {}, 0
  local function flush()
    if #batch == 0 then return end
    ns.Net.Enqueue("Y2|" .. round.nonce .. "|" .. table.concat(batch, ";"), ns.Net.PRIO.sync)
    messages = messages + 1
    batch = {}
  end
  local list = ns.Sightings.Live(now)
  table.sort(list, function(a, b) return a.time > b.time end)
  for _, e in ipairs(list) do
    if messages >= REPLY_MESSAGES then break end
    -- Only what we trust and saw or heard first hand; never the logout cache.
    if not e.cached and (e.mine or e.confirmed) then
      local code = ns.Sightings.Code(e.npc, e.layer, e.state, e.time)
      if not inDigests(code) and not round.sent[code] then
        round.sent[code] = true
        batch[#batch + 1] = encodeEntry(e)
        if #batch >= PER_MESSAGE then flush() end
      end
    end
  end
  flush()
  ns.Log(string.format("sync reply %s: %d messages", round.nonce, messages))
end

local function electedResponder(nonce, now)
  local best, bestHash
  local candidates = ns.Net.ActivePeers(now, ACTIVE_WINDOW)
  candidates[#candidates + 1] = ns.Net.SelfName()
  for _, name in ipairs(candidates) do
    local h = hash(name .. nonce)
    if not bestHash or h < bestHash then best, bestHash = name, h end
  end
  return best
end

ns.Net.Handle("H2", function(fields, sender, now)
  local nonce = fields[2]
  if not nonce or not nonce:match("^%d+$") then return false end
  local d = parseDigest(fields[3])
  if round and now - round.opened < ROUND_WINDOW then
    round.digests[#round.digests + 1] = d     -- joins the pending round
    return true
  end
  local startIn = math.max(0, lastRoundAt + ROUND_GAP - now)
  round = { nonce = nonce, digests = { d }, opened = now + startIn, sent = {} }
  lastRoundAt = now + startIn
  local elected = electedResponder(nonce, now) == ns.Net.SelfName()
  local delay = startIn + between(elected and ELECTED_DELAY or FILL_DELAY)
  local thisRound = round
  C_Timer.After(delay, function()
    if round == thisRound then ns.Safe("sync reply", reply) end
  end)
  return true
end)

ns.Net.Handle("Y2", function(fields, sender, now)
  local nonce = fields[2]
  if not round or nonce ~= round.nonce or now - round.opened > ROUND_WINDOW then return false end
  local added = 0
  for item in (fields[3] or ""):gmatch("[^;]+") do
    local p = { strsplit(",", item) }
    local r = ns.Net.ParseSightingFields(p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8])
    if r then
      round.sent[ns.Sightings.Code(r.npc, r.layer, r.state, r.time)] = true   -- heard, do not resend
      if ns.Sightings.AddRemote(r, sender, now, "relay") then added = added + 1 end
    end
  end
  return added > 0
end)

-- Verification -----------------------------------------------------------------

-- Reputation, deliberately forgiving: honest players lose rares that get
-- killed or wander off, so only reports nobody else corroborated count
-- against them, confirmed reports earn credit, strikes fade, and the
-- automatic ignore is temporary and never saved.
local function strike(sender, now)
  local s = strikes[sender]
  if not s or now - s.at > STRIKE_MEMORY then s = { n = 0 }; strikes[sender] = s end
  s.n, s.at = s.n + 1, now
  if s.n >= STRIKES then
    paused[sender] = now + PAUSE
    s.n = 0
    ns.Log("paused " .. sender .. " for " .. PAUSE / 60 .. " min after refuted reports")
  end
end

local function credit(sender)
  local s = strikes[sender]
  if s and s.n > 0 then s.n = s.n - 1 end
end

function Sync.IsPaused(sender, now)
  local untilT = paused[sender]
  if untilT and now < untilT then return true end
  paused[sender] = nil
  return false
end

ns.Sightings.OnUpdate(function(e, _, removed)
  local now = ns.Now()
  if removed then
    if e.firstHandCount == 1 then
      for sender in pairs(e.firstHand) do strike(sender, now) end
    end
  elseif e.firstHandCount >= 2 then
    for sender in pairs(e.firstHand) do credit(sender) end
  end
end)

ns.Net.Handle("N2", function(fields, sender, now)
  local npc, layer, t = tonumber(fields[2]), fields[3], tonumber(fields[4])
  if not (npc and layer and t) or t > now + 120 then return false end
  ns.Sightings.NotSeen(ns.Sightings.Id(npc, layer), sender, t)
  return true
end)

local function distanceYards(uiMap, x1, y1, x2, y2)
  local w, h = C_Map.GetMapWorldSize(uiMap)
  if not w or w == 0 then return nil end
  local dx, dy = (x1 - x2) * w, (y1 - y2) * h
  return math.sqrt(dx * dx + dy * dy)
end

-- Run from the sweep: maybe send N2 for live entries we are standing on.
function Sync.CheckNotSeen(now)
  local cur = ns.Layer.Current()
  if not cur or not ns.Layer.LastObserved() or now - ns.Layer.LastObserved() > LAYER_FRESH then return end
  if GetCVar("nameplateShowEnemies") ~= "1" or IsInInstance() then return end
  local uiMap = C_Map.GetBestMapForUnit("player")
  local pos = uiMap and C_Map.GetPlayerMapPosition(uiMap, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  px, py = ns.plain(px), ns.plain(py)
  if not px then return end
  for _, e in ipairs(ns.Sightings.Live(now)) do
    if e.state == "A" and not e.mine and not e.cached and e.layer == cur.key and e.uiMap == uiMap then
      local d = distanceYards(uiMap, px, py, e.x, e.y)
      if d and d <= NOTSEEN_RANGE then
        nearSince[e.id] = nearSince[e.id] or now
        local key = e.id .. e.time
        if now - nearSince[e.id] >= NOTSEEN_DWELL and now - e.time >= NOTSEEN_AFTER
            and now - (lastSeenNpc[e.npc] or 0) > SEEN_RECENT and not notSeenSent[key] then
          notSeenSent[key] = true
          ns.Net.Enqueue(string.format("N2|%d|%s|%d", e.npc, e.layer, now), ns.Net.PRIO.notseen)
          ns.Log("not seen " .. e.id)
        end
      else
        nearSince[e.id] = nil
      end
    end
  end
end

-- Discovered rares gossip ---------------------------------------------------------

local candidates = {}            -- npc -> { senders = {}, points... } before persisting

function Sync.GossipDiscovered(now)
  if now - lastGossip < GOSSIP_EVERY then return end
  lastGossip = now
  local peers = math.max(1, ns.Net.Peers(now))
  if math.random() > math.min(1, 3 / peers) then return end
  local keys = {}
  for npc in pairs(ns.db.discovered) do keys[#keys + 1] = npc end
  if #keys == 0 then return end
  local npc = keys[math.random(#keys)]
  local d = ns.db.discovered[npc]
  local i = (math.random(math.max(1, #d.points / 3)) - 1) * 3 + 1
  if not d.points[i] then return end
  ns.Net.Enqueue(string.format("D2|%d|%d|%d|%d|%d|%d|%s", npc, d.points[i], math.floor(d.points[i + 1] * 10 + 0.5),
    math.floor(d.points[i + 2] * 10 + 0.5), d.tame and 1 or 0, d.level or 0, ns.Net.Clean(d.name)), ns.Net.PRIO.gossip)
end

ns.Net.Handle("D2", function(fields, sender, now)
  local npc, uiMap, x, y, level = tonumber(fields[2]), tonumber(fields[3]), tonumber(fields[4]), tonumber(fields[5]), tonumber(fields[7])
  if not (npc and uiMap and x and y) or x < 0 or x > 1000 or y < 0 or y > 1000 or ns.Seed[npc] then return false end
  local c = candidates[npc]
  if not c then c = { senders = {} }; candidates[npc] = c end
  c.senders[sender] = true
  local n = 0
  for _ in pairs(c.senders) do n = n + 1 end
  -- Persist only what two different players vouch for.
  if n >= 2 or ns.db.discovered[npc] then
    ns.Map.Learn({ npc = npc, gossip = true, uiMap = uiMap, x = x / 1000, y = y / 1000,
      tame = fields[6] == "1", level = level, name = fields[8] ~= "" and fields[8] or nil })
  end
  return true
end)

function Sync.Strikes() return strikes end
