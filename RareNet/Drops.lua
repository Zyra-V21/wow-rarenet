-- Community loot: what rares really drop in Forever, learned from players'
-- loot windows and shared over the RareNet network.
--
-- A corpse (zoneUID:spawnUID) counts as one looted kill, whoever reports it
-- and however often. Only the first loot window of a corpse is kill loot:
-- skinning, gathering and pick pocketing open the same corpse again.
--
-- Messages:
--   L2|npc|corpse|time|item.item.item   first hand (the sender looted it)
--   G2|npc|corpse|time|item.item.item   relayed by gossip (not a witness)
local _, ns = ...

local Drops = {}
ns.Drops = Drops

local CORPSE_MAX = 2000           -- corpses remembered for de-duplication
local PER_SENDER_DAY = 3          -- corpses of one rare one player may report per day
local GOSSIP_EVERY = 5 * 60
local GOSSIP_MAX_AGE = 14 * 24 * 3600
local GATHER_WINDOW = 4           -- seconds after a gathering cast to ignore loot
-- Skinning, herb gathering, mining (all ranks) and pick pocket.
local GATHER_SPELLS = {
  [8613] = true, [8617] = true, [8618] = true, [10768] = true,
  [2366] = true, [2368] = true, [3570] = true, [11993] = true,
  [2575] = true, [2576] = true, [3564] = true, [10248] = true,
  [921] = true,
}

local store                       -- db.drops: corpses, order
local baked = {}                  -- corpse ids already counted in ForeverLoot (shipped data)
local witnesses                   -- db.dropWitnesses: npc -> item -> sender set (never baked)
local senderDay = {}              -- sender .. npc -> { times }
local lastGatherCast = -100
local lastGossip = 0

local function isRare(npc)
  return ns.Seed[npc] ~= nil or (ns.db.discovered and ns.db.discovered[npc] ~= nil)
    or (ns.Undiscovered and ns.Undiscovered[npc] ~= nil)
end

local function validItem(id)
  if not id or id <= 0 then return false end
  if C_Item and C_Item.GetItemInfoInstant then
    local ok, itemID = pcall(C_Item.GetItemInfoInstant, id)
    return ok and itemID ~= nil
  end
  return true
end

local function forget(corpseId)
  store.corpses[corpseId] = nil
end

-- Record a corpse (or merge more items into one already known).
-- sender is nil for our own loot. Returns true when something new was added.
local function addCorpse(npc, corpseId, t, items, sender, relayed)
  if baked[corpseId] then return false end
  local c = store.corpses[corpseId]
  local added = false
  if not c then
    c = { npc = npc, t = t, items = {}, mine = sender == nil }
    store.corpses[corpseId] = c
    store.order[#store.order + 1] = corpseId
    while #store.order > CORPSE_MAX do forget(table.remove(store.order, 1)) end
    added = true
  end
  if sender == nil then c.mine = true end
  for _, id in ipairs(items) do
    if not c.items[id] then
      c.items[id] = true
      added = true
    end
    if sender and not relayed then
      witnesses[npc] = witnesses[npc] or {}
      witnesses[npc][id] = witnesses[npc][id] or {}
      witnesses[npc][id][sender] = true
    end
  end
  return added
end
Drops.AddCorpse = addCorpse

-- Loot window -----------------------------------------------------------------

local looting = false             -- one snapshot per loot session

local function snapshot()
  if looting then return end
  looting = true
  if GetTime() - lastGatherCast < GATHER_WINDOW or (IsStealthed and IsStealthed()) then return end
  if IsInInstance() then return end
  local perCorpse = {}
  local n = GetNumLootItems() or 0
  for slot = 1, n do
    local _, _, _, _, _, _, isQuestItem = GetLootSlotInfo(slot)
    local link = GetLootSlotLink(slot)
    local itemID = link and not ns.issecret(link) and tonumber(link:match("item:(%d+)"))
    local sources = { GetLootSourceInfo(slot) }
    for i = 1, #sources, 2 do
      local info = ns.Layer.ParseGUID(sources[i])
      if info and isRare(info.npc) then
        local id = info.zone .. ":" .. info.spawn
        local c = perCorpse[id]
        if not c then c = { npc = info.npc, items = {} }; perCorpse[id] = c end
        if itemID and not isQuestItem and validItem(itemID) then c.items[#c.items + 1] = itemID end
      end
    end
  end
  for corpseId, c in pairs(perCorpse) do
    -- Only the first loot window of a corpse is kill loot.
    if not store.corpses[corpseId] and not baked[corpseId] then
      local now = ns.Now()
      addCorpse(c.npc, corpseId, now, c.items, nil, false)
      ns.Log(string.format("looted %s: %d items", corpseId, #c.items))
      local ids = {}
      for _, id in ipairs(c.items) do ids[#ids + 1] = tostring(id) end
      ns.Net.Enqueue(string.format("L2|%d|%s|%d|%s", c.npc, corpseId, now, table.concat(ids, ".")), ns.Net.PRIO.sighting)
      if ns.Database and ns.Database.Refresh then ns.Safe("db refresh", ns.Database.Refresh) end
    end
  end
end

ns.On("LOOT_READY", function() ns.Safe("loot", snapshot) end)
ns.On("LOOT_OPENED", function() ns.Safe("loot", snapshot) end)
ns.On("LOOT_CLOSED", function() looting = false end)
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
  if unit == "player" and not ns.issecret(spellID) and GATHER_SPELLS[spellID] then lastGatherCast = GetTime() end
end)

-- Network -------------------------------------------------------------------------

local function parseRecord(fields)
  local npc, corpse, t = tonumber(fields[2]), fields[3], tonumber(fields[4])
  if not (npc and t and corpse and corpse:match("^%d+:%x+$")) then return nil end
  local items = {}
  for id in (fields[5] or ""):gmatch("%d+") do
    id = tonumber(id)
    if validItem(id) and #items < 30 then items[#items + 1] = id end
  end
  return npc, corpse, t, items
end

-- Accept a remote record if it passes the per-sender, per-rare daily limit.
local function receive(fields, sender, now, relayed)
  local npc, corpse, t, items = parseRecord(fields)
  if not npc or not isRare(npc) or t > now + 120 then return false end
  if relayed and now - t > GOSSIP_MAX_AGE then return false end
  if not store.corpses[corpse] then
    local key = sender .. "@" .. npc
    local log = senderDay[key] or {}
    senderDay[key] = log
    while log[1] and now - log[1] > 86400 do table.remove(log, 1) end
    if #log >= PER_SENDER_DAY then return false end
    log[#log + 1] = now
  end
  addCorpse(npc, corpse, t, items, sender, relayed)
  return true
end

ns.Net.Handle("L2", function(fields, sender, now) return receive(fields, sender, now, false) end)
ns.Net.Handle("G2", function(fields, sender, now) return receive(fields, sender, now, true) end)

-- Every few minutes one random recent corpse is passed on, so players who
-- were offline learn it too.
function Drops.Gossip(now)
  if now - lastGossip < GOSSIP_EVERY or #store.order == 0 then return end
  lastGossip = now
  if math.random() > math.min(1, 3 / math.max(1, ns.Net.Peers(now))) then return end
  local id = store.order[math.random(#store.order)]
  local c = store.corpses[id]
  if not c or not c.npc or now - c.t > GOSSIP_MAX_AGE then return end
  local ids = {}
  for item in pairs(c.items) do ids[#ids + 1] = tostring(item) end
  ns.Net.Enqueue(string.format("G2|%d|%s|%d|%s", c.npc, id, c.t, table.concat(ids, ".")), ns.Net.PRIO.gossip)
end

-- Reading ----------------------------------------------------------------------------

-- Community drops of a rare: looted kills and { id, count, players, mine }
-- best first. Data shipped with the addon (ForeverLoot) is added in; corpses
-- it already counts are skipped.
function Drops.Of(npc)
  local shipped = ns.ForeverLoot and ns.ForeverLoot[npc]
  local kills = shipped and shipped[1] or 0
  local counts, mine = {}, {}
  if shipped then
    for i = 2, #shipped, 2 do counts[shipped[i]] = (counts[shipped[i]] or 0) + shipped[i + 1] end
  end
  if store then
    for _, c in pairs(store.corpses) do
      if c.npc == npc then
        kills = kills + 1
        for id in pairs(c.items) do
          counts[id] = (counts[id] or 0) + 1
          if c.mine then mine[id] = true end
        end
      end
    end
  end
  local out = {}
  for id, n in pairs(counts) do
    local w = witnesses and witnesses[npc] and witnesses[npc][id]
    local players = 0
    if w then for _ in pairs(w) do players = players + 1 end end
    out[#out + 1] = { id = id, count = n, players = players, mine = mine[id] or false }
  end
  table.sort(out, function(x, y)
    if x.count ~= y.count then return x.count > y.count end
    return x.id < y.id
  end)
  return kills, out
end

table.insert(ns.onLoad, function(db)
  db.drops = db.drops or {}
  store = db.drops
  store.corpses = store.corpses or {}
  store.order = store.order or {}
  store.agg = nil
  db.dropWitnesses = db.dropWitnesses or {}
  witnesses = db.dropWitnesses
  -- Corpses already counted in the data shipped with the addon must not be
  -- counted again when someone gossips them.
  for _, id in ipairs(ns.ForeverLootCorpses or {}) do
    baked[id] = true
    store.corpses[id] = nil
  end
end)
