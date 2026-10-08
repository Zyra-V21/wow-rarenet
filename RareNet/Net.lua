-- Network transport: addon messages over one custom channel (guild as a
-- fallback), a prioritised send queue, per-sender rate limits and dispatch
-- of incoming messages by type.
--
-- Message types (first field), all "|"-separated:
--   S2  sighting, first hand        S2|npc|layer|uiMap|x|y|state|time|tame|name
--   N2  not seen here               N2|npc|layer|time
--   H2  hello, asks for a sync      H2|nonce|digest
--   Y2  sync reply batch            Y2|nonce|entry;entry;...
--   D2  discovered rare (gossip)    D2|npc|uiMap|x|y|tame|level|name
--   Q2  who is online?              Q2|nonce
--   A2  presence answer             A2|nonce|version
--   P1  ping (transport test)       P1|ms
-- x and y travel as 0..1000, times are server time in seconds.
local _, ns = ...

local Net = {}
ns.Net = Net

local CHANNELS = { "RareNetFE", "RareNetFE2", "RareNetFE3" }
local JOIN_DELAY = 8          -- seconds after login, so General/Trade keep slots 1-2
local SEND_INTERVAL = 2       -- seconds between our own messages
local QUEUE_MAX = 30
local GOSSIP_MAX_DELAY = 3    -- random wait before announcing a sighting
local HEARD_WINDOW = 60       -- skip announcing what someone else just did
local PEER_WINDOW = 30 * 60

-- Priorities: lower goes first.
Net.PRIO = { sighting = 1, notseen = 2, hello = 2, presence = 3, sync = 3, gossip = 4 }

-- Per sender and type: at most n messages per window seconds.
local LIMITS = {
  S2 = { 20, 60 }, N2 = { 10, 60 }, H2 = { 1, 600 }, Y2 = { 6, 20 }, D2 = { 5, 60 }, P1 = { 5, 60 },
  Q2 = { 1, 60 }, A2 = { 3, 60 }, L2 = { 10, 60 }, G2 = { 5, 60 },
}

local channelIndex = 0
local channelId
local channelBroken = false
local queue, lastSend = {}, 0
local heard = {}              -- sighting id .. state -> time someone announced it
local pending = {}            -- sighting id -> true while waiting to announce
local recentSent = {}         -- message -> time sent (to recognise our echoes)
local selfNames = {}          -- sender strings that are this client
local rate = {}               -- sender -> type -> { times }
local lastHeard = {}          -- sender -> time of their last message
local peerVersion = {}        -- sender -> addon version they announced
local handlers = {}
Net.status = { transport = "none", lastResult = "-", sent = 0, received = 0, dropped = 0 }

function Net.Handle(kind, fn) handlers[kind] = fn end

function Net.EncodeXY(v) return math.floor((v or 0) * 1000 + 0.5) end

local function clean(name)
  return (name or ""):gsub("[|;,]", ""):sub(1, 40)
end
Net.Clean = clean

local function resultText(result)
  if result == nil then return "nil" end
  if Enum and Enum.SendAddonMessageResult then
    for k, v in pairs(Enum.SendAddonMessageResult) do
      if v == result then return k end
    end
  end
  return tostring(result)
end

local function isSuccess(result)
  return result == nil or result == true or result == 0
end

local function target()
  if channelId and not channelBroken then return "CHANNEL", channelId end
  if IsInGuild() then return "GUILD" end
end

local function rawSend(msg)
  if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
    return false, "lockdown"
  end
  local chatType, chan = target()
  Net.status.transport = chatType and (chatType == "CHANNEL" and CHANNELS[channelIndex] or chatType) or "none"
  if not chatType then return false, "no transport" end
  recentSent[msg] = GetTime()
  local ok, result = pcall(C_ChatInfo.SendAddonMessage, ns.PREFIX, msg, chatType, chan)
  local text = ok and resultText(result) or ("error " .. tostring(result))
  Net.status.lastResult = chatType .. ": " .. text
  if ok and isSuccess(result) then
    Net.status.sent = Net.status.sent + 1
    return true
  end
  if chatType == "CHANNEL" and (not ok or text:find("Invalid")) then
    channelBroken = true
    ns.print("channel messages refused (" .. text .. "), using guild only")
  end
  return false, text
end

-- Queue a message; the queue keeps the most important ones when full.
function Net.Enqueue(msg, prio)
  if #queue >= QUEUE_MAX then
    local worst = 1
    for i, q in ipairs(queue) do if q.prio > queue[worst].prio then worst = i end end
    if queue[worst].prio <= prio then return false end
    table.remove(queue, worst)
  end
  queue[#queue + 1] = { msg = msg, prio = prio, seq = GetTime() }
  return true
end

function Net.QueueLength() return #queue end

-- Called from the frame driver: send at most one queued message per interval.
function Net.Tick(now)
  for msg, t in pairs(recentSent) do
    if now - t > 30 then recentSent[msg] = nil end
  end
  if IsInInstance() then return end
  if #queue == 0 or now - lastSend < SEND_INTERVAL then return end
  local best = 1
  for i, q in ipairs(queue) do
    if q.prio < queue[best].prio or (q.prio == queue[best].prio and q.seq < queue[best].seq) then best = i end
  end
  local item = table.remove(queue, best)
  lastSend = now
  local ok, why = rawSend(item.msg)
  if not ok and why and (why:find("Throttle") or why:lower():find("lockdown")) then
    table.insert(queue, 1, item)   -- refused for now, try again later
  end
end

-- Sightings ------------------------------------------------------------------

function Net.EncodeSighting(r)
  return string.format("S2|%d|%s|%d|%d|%d|%s|%d|%d|%s", r.npc, r.layer, r.uiMap or 0,
    Net.EncodeXY(r.x), Net.EncodeXY(r.y), r.state, r.time, r.tame and 1 or 0, clean(r.name))
end

-- Shared validation of the fields every sighting carries.
function Net.ParseSightingFields(npc, layer, uiMap, x, y, state, time, tame)
  npc, uiMap, x, y, time = tonumber(npc), tonumber(uiMap), tonumber(x), tonumber(y), tonumber(time)
  if not (npc and uiMap and x and y and time) or npc <= 0 then return nil end
  if not (layer and layer:match("^%d+%-%d+%-%d+$")) then return nil end
  if state ~= "A" and state ~= "D" then return nil end
  if x < 0 or x > 1000 or y < 0 or y > 1000 then return nil end
  return { npc = npc, layer = layer, uiMap = uiMap, x = x / 1000, y = y / 1000, state = state, time = time, tame = tame == "1" }
end

function Net.DecodeSighting(fields)
  local r = Net.ParseSightingFields(fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], fields[9])
  if r and fields[10] and fields[10] ~= "" then r.name = fields[10] end
  return r
end

-- Announce a sighting after a short random wait, unless another player
-- announces the same rare and state in the meantime.
function Net.Announce(entry, report, extraDelay)
  local key = entry.id .. report.state
  if pending[entry.id] then return end
  if heard[key] and ns.Now() - heard[key] < HEARD_WINDOW then return end
  pending[entry.id] = true
  C_Timer.After((extraDelay or 0) + math.random() * GOSSIP_MAX_DELAY, function()
    pending[entry.id] = nil
    if heard[key] and ns.Now() - heard[key] < HEARD_WINDOW then return end
    heard[key] = ns.Now()
    Net.Enqueue(Net.EncodeSighting(report), Net.PRIO.sighting)
  end)
end

Net.Handle("S2", function(fields, sender, now)
  local r = Net.DecodeSighting(fields)
  if not r then return false end
  heard[ns.Sightings.Id(r.npc, r.layer) .. r.state] = now
  return ns.Sightings.AddRemote(r, sender, now, "direct") ~= nil
end)

-- Ping -----------------------------------------------------------------------

local pingSentAt
function Net.Ping()
  pingSentAt = GetTime()
  local ok, why = rawSend("P1|" .. math.floor(pingSentAt * 1000))
  ns.print("ping via " .. Net.status.transport .. ": " .. (ok and "accepted" or ("refused, " .. tostring(why)))
    .. " (" .. Net.status.lastResult .. ")")
  ns.Log("ping " .. Net.status.lastResult)
end

-- Receiving ----------------------------------------------------------------

-- Whether a message came from this client. Forever senders look like
-- "First Last", so our own name is learned once from our ping's echo.
local function fromSelf(sender, msg)
  if ns.issecret(sender) or type(sender) ~= "string" then return false end
  if selfNames[sender] then return true end
  local name, realm = UnitFullName("player")
  if name and (sender == name or (realm and sender == name .. "-" .. realm)) then return true end
  local sentAt = not next(selfNames) and not ns.issecret(msg) and msg:sub(1, 3) == "P1|" and recentSent[msg]
  if sentAt and GetTime() - sentAt < 30 then
    selfNames[sender] = true
    ns.Log("learned own sender name: " .. sender)
    return true
  end
  return false
end
Net.FromSelf = fromSelf

local function allowed(sender, kind, now)
  local limit = LIMITS[kind]
  if not limit then return false end
  local bySender = rate[sender]
  if not bySender then bySender = {}; rate[sender] = bySender end
  local log = bySender[kind]
  if not log then log = {}; bySender[kind] = log end
  while log[1] and now - log[1] > limit[2] do table.remove(log, 1) end
  if #log >= limit[1] then return false end
  log[#log + 1] = now
  return true
end

-- Players heard from recently: a rough size of the network.
function Net.Peers(now)
  local n = 0
  for sender, t in pairs(lastHeard) do
    if now - t < PEER_WINDOW then n = n + 1 else lastHeard[sender] = nil end
  end
  return n
end

-- Presence -------------------------------------------------------------------
-- "/rarenet peers" asks who is online. Everyone answers after a random wait;
-- in a big network only a sample answers, so a question never floods.

local PRESENCE_ANSWERS = 25
local lastQuery = -60

local function version()
  local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
  local ok, v = pcall(get, "RareNet", "Version")
  return ok and v or "?"
end
Net.Version = version

function Net.AskPresence(now)
  if now - lastQuery < 30 then return false end
  lastQuery = now
  Net.Enqueue("Q2|" .. math.random(100000, 999999), Net.PRIO.presence)
  return true
end

Net.Handle("Q2", function(fields, sender, now)
  local nonce = fields[2]
  if not nonce or not nonce:match("^%d+$") then return false end
  if math.random() > math.min(1, PRESENCE_ANSWERS / math.max(1, Net.Peers(now))) then return true end
  C_Timer.After(0.5 + math.random() * 4.5, function()
    Net.Enqueue("A2|" .. nonce .. "|" .. clean(version()), Net.PRIO.presence)
  end)
  return true
end)

Net.Handle("A2", function(fields, sender)
  peerVersion[sender] = fields[3]
  return true
end)

-- Recently heard players, newest first: { name, ago, version }.
function Net.PeerList(now)
  local out = {}
  for sender, t in pairs(lastHeard) do
    if now - t < PEER_WINDOW then out[#out + 1] = { name = sender, ago = now - t, version = peerVersion[sender] } end
  end
  table.sort(out, function(a, b) return a.ago < b.ago end)
  return out
end

-- Senders active recently, for the sync election.
function Net.ActivePeers(now, window)
  local out = {}
  for sender, t in pairs(lastHeard) do
    if now - t < window then out[#out + 1] = sender end
  end
  return out
end

function Net.SelfName()
  local name = next(selfNames)
  if name then return name end
  local n, realm = UnitFullName("player")
  return n and (realm and realm ~= "" and (n .. "-" .. realm) or n) or "?"
end

ns.On("CHAT_MSG_ADDON", function(prefix, msg, chatType, sender)
  if ns.issecret(prefix) or prefix ~= ns.PREFIX then return end
  if ns.issecret(msg) or type(msg) ~= "string" or #msg > 255 then return end
  local mine = fromSelf(sender, msg)
  if msg:sub(1, 3) == "P1|" then
    if mine and pingSentAt then
      local line = string.format("ping echo via %s after %d ms", tostring(chatType), math.floor((GetTime() - pingSentAt) * 1000 + 0.5))
      ns.print(line)
      ns.Log(line)
      pingSentAt = nil
    end
    return
  end
  if mine or ns.issecret(sender) then return end
  local now = ns.Now()
  local fields = { strsplit("|", msg) }
  local kind = fields[1]
  local handler = handlers[kind]
  if not handler or ns.db.ignored[sender] or (ns.Sync and ns.Sync.IsPaused(sender, now)) or not allowed(sender, kind, now) then
    Net.status.dropped = Net.status.dropped + 1
    return
  end
  lastHeard[sender] = now
  Net.status.received = Net.status.received + 1
  if handler(fields, sender, now) == false then Net.status.dropped = Net.status.dropped + 1 end
end)

-- Channel management -----------------------------------------------------

function Net.ChannelName()
  return channelId and CHANNELS[channelIndex] or nil
end

-- Members of our channel, as the game lists them for /chatlist. The list
-- arrives as one chat line ("*Owner, Name, @Moderator"), which RareNet turns
-- into clickable player links so the player can whisper anyone in it.

local function playerLink(name)
  return "|Hplayer:" .. name .. "|h[" .. name .. "]|h"
end

local function showMembers(names)
  ns.print(#names .. " players in the RareNet channel (click a name to whisper):")
  for i = 1, #names, 4 do
    local row = {}
    for j = i, math.min(i + 3, #names) do row[#row + 1] = playerLink(names[j]) end
    ns.print("  " .. table.concat(row, "  "))
  end
end

-- The list is also asked for quietly every few minutes, so the "online"
-- count matches /rarenet members. While RareNet is waiting for a list the
-- game's own copy of it is kept out of the chat frames.
local LIST_WINDOW = 2              -- seconds to gather the list lines
local COUNT_EVERY = 180
local listing, listNames, listCallbacks = false, {}, {}
Net.members, Net.membersAt = nil, nil

local function bareName(name)
  return (name or ""):gsub("%-[^%-]*$", "")
end
Net.BareName = bareName

-- Ask the game for the members of our channel; fn(names) gets them.
function Net.RefreshMembers(fn)
  local name = Net.ChannelName()
  if not name then return false end
  if fn then listCallbacks[#listCallbacks + 1] = fn end
  if listing then return true end
  listing, listNames = true, {}
  pcall(ListChannelByName, name)
  C_Timer.After(LIST_WINDOW, function()
    listing = false
    if #listNames > 0 then Net.members, Net.membersAt = listNames, ns.Now() end
    local callbacks = listCallbacks
    listCallbacks = {}
    for _, cb in ipairs(callbacks) do ns.Safe("members", cb, Net.members or {}) end
  end)
  return true
end

function Net.ListMembers()
  if not Net.ChannelName() then ns.print("not in the RareNet channel yet") return end
  -- Only the /chatlist reply is used: C_ChatInfo.GetChannelRosterInfo takes the
  -- channel's position in the channels UI, not its chat number, and listed the
  -- members of some other public channel.
  Net.RefreshMembers(showMembers)
end

-- Players in the channel right now (you included), or nil before the first list.
function Net.Online()
  return Net.members and #Net.members or nil
end

local function ours(channelName)
  local name = Net.ChannelName()
  return name and type(channelName) == "string" and not ns.issecret(channelName) and channelName:find(name, 1, true) ~= nil
end

ns.On("CHAT_MSG_CHANNEL_LIST", function(text, _, _, _, _, _, _, _, channelName)
  if not listing or ns.issecret(text) or not ours(channelName) then return end
  -- Big channels come in several lines: gather them all.
  for entry in text:gmatch("[^,]+") do
    local clean = entry:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^[%*@]+", "")
    if clean ~= "" then listNames[#listNames + 1] = clean end
  end
end)

local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
if addFilter then
  addFilter("CHAT_MSG_CHANNEL_LIST", function(_, _, _, _, _, _, _, _, _, _, channelName)
    return listing and ours(channelName) or false
  end)
end

C_Timer.NewTicker(COUNT_EVERY, function() ns.Safe("member count", Net.RefreshMembers) end)

local joinedListeners = {}
function Net.OnJoined(fn) joinedListeners[#joinedListeners + 1] = fn end

local function joinNext()
  channelIndex = channelIndex + 1
  local name = CHANNELS[channelIndex]
  if not name then
    channelId = nil
    ns.print("no RareNet channel available, using guild only")
    for _, fn in ipairs(joinedListeners) do fn() end
    return
  end
  local ok, err = pcall(JoinTemporaryChannel, name)
  ns.Log("join " .. name .. " -> " .. (ok and "called" or ("error " .. tostring(err))))
  C_Timer.After(3, function()
    local id = GetChannelName(name)
    ns.Log("channel " .. name .. " id=" .. tostring(id))
    if id and id > 0 then
      channelId = id
      Net.status.transport = name
      if ChatFrame_RemoveChannel and DEFAULT_CHAT_FRAME then
        pcall(ChatFrame_RemoveChannel, DEFAULT_CHAT_FRAME, name)
      end
      -- Silent ping: its echo teaches us our own sender name.
      rawSend("P1|" .. math.floor(GetTime() * 1000))
      C_Timer.After(5, function() ns.Safe("member count", Net.RefreshMembers) end)
      for _, fn in ipairs(joinedListeners) do fn() end
    else
      joinNext()
    end
  end)
end

-- Someone owns the channel and locked us out: move to the next one.
ns.On("CHAT_MSG_CHANNEL_NOTICE", function(notice, _, _, _, _, _, _, _, channelName)
  if ns.issecret(notice) or ns.issecret(channelName) then return end
  local name = CHANNELS[channelIndex]
  if not name or not channelName or not channelName:find(name, 1, true) then return end
  if notice == "WRONG_PASSWORD" or notice == "BANNED" or notice == "SUSPENDED" then
    channelId = nil
    pcall(LeaveChannelByName, name)
    joinNext()
  end
end)

local started = false
ns.On("PLAYER_ENTERING_WORLD", function()
  if started then return end
  started = true
  local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, ns.PREFIX)
  ns.Log("prefix " .. (ok and tostring(result) or ("error " .. tostring(result))))
  ns.Log("join scheduled in " .. JOIN_DELAY .. "s")
  C_Timer.After(JOIN_DELAY, function() ns.Safe("joinNext", joinNext) end)
end)
