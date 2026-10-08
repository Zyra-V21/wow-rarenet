local M = dofile(ROOT .. "tests/wow.lua")

local ns = {}
for _, file in ipairs({ "Seed", "Loot", "ForeverLoot", "ForeverRares", "Tactics", "Core", "Layer", "Sightings", "Net", "Sync", "Drops", "Scan", "Alert", "UI", "Hop", "Map", "Database", "Minimap", "MinimapPins", "Options" }) do
  local chunk = assert(loadfile(ROOT .. "RareNet/" .. file .. ".lua"))
  chunk("RareNet", ns)
end

local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error("FAIL " .. name .. ": " .. tostring(err), 0) end
  passed = passed + 1
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

local LAYER = "4621-1-60439"
local function guid(map, zone, npc, spawn) return string.format("Creature-0-4621-%d-%d-%d-%s", map, zone, npc, spawn) end
local function decode(msg) return ns.Net.DecodeSighting({ strsplit("|", msg) }) end
local function sent(kind)
  local out = {}
  for _, s in ipairs(M.sent) do if s.msg:sub(1, #kind) == kind then out[#out + 1] = s end end
  return out
end
local function receive(msg, sender) M.fire("CHAT_MSG_ADDON", "RareNet", msg, "CHANNEL", sender) end
local function report(npc, extra)
  local r = { npc = npc, layer = LAYER, uiMap = 1413, x = 0.5, y = 0.5, state = "A", time = GetServerTime() }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

M.fire("ADDON_LOADED", "RareNet")
M.fire("PLAYER_LOGIN")
M.fire("PLAYER_ENTERING_WORLD")
M.step(20)  -- join delay, channel check, silent ping, hello

test("GUID parsing", function()
  local i = ns.Layer.ParseGUID("Creature-0-4621-1-60439-3244-0000420B05")
  eq(i.server, 4621); eq(i.map, 1); eq(i.zone, 60439); eq(i.npc, 3244); eq(i.key, LAYER)
  eq(ns.Layer.ParseGUID("Player-4621-0ABC"), nil)
  eq(ns.Layer.ParseGUID(M.SECRET), nil)
  eq(ns.Layer.ParseGUID("Creature-0-x-1-2-3-4"), nil)
end)

test("joins the channel, pings and says hello", function()
  eq(ns.Net.status.transport, "RareNetFE")
  eq(#sent("P1|"), 1)
  eq(#sent("H2|"), 1)
  eq(sent("H2|")[1].chatType, "CHANNEL")
end)

test("layer detection needs two creatures to change", function()
  ns.Layer.Reset()
  ns.Layer.Observe(ns.Layer.ParseGUID(guid(1, 100, 3244, "A1")), 0)
  eq(ns.Layer.Current().zone, 100)
  ns.Layer.Observe(ns.Layer.ParseGUID(guid(1, 200, 3244, "B1")), 1)
  eq(ns.Layer.Current().zone, 100, "one stray creature must not switch")
  ns.Layer.Observe(ns.Layer.ParseGUID(guid(1, 200, 3244, "B1")), 2)
  eq(ns.Layer.Current().zone, 100, "the same creature twice must not switch")
  ns.Layer.Observe(ns.Layer.ParseGUID(guid(1, 200, 3245, "B2")), 3)
  eq(ns.Layer.Current().zone, 200)
  ns.Layer.Observe(ns.Layer.ParseGUID(guid(0, 300, 1, "C1")), 4)
  eq(ns.Layer.Current().map, 0, "a new continent is trusted at once")
  eq(ns.Layer.IsMine("4621-1-200"), nil, "other continent is not comparable")
  eq(ns.Layer.IsMine("4621-0-300"), true)
  eq(ns.Layer.IsMine("4621-0-301"), false)
end)

test("sighting wire format round trip and validation", function()
  local r = report(3244, { uiMap = 1413, x = 0.4521, y = 0.3, tame = true, name = "Rare|Bad;,x" })
  local d = decode(ns.Net.EncodeSighting(r))
  eq(d.npc, 3244); eq(d.layer, LAYER); eq(d.x, 0.452); eq(d.state, "A"); eq(d.tame, true); eq(d.name, "RareBadx")
  eq(decode("S2|1|bad|1|1|1|A|1|0|x"), nil)
  eq(decode("S2|1|1-1-1|1|1|1|Z|1|0|x"), nil)
  eq(decode("S2|1|1-1-1|1|1001|1|A|1|0|x"), nil)
end)

test("a rare on a nameplate is reported once, then its death", function()
  ns.Layer.Reset()
  M.units.nameplate1 = { guid = guid(1, 60439, 5807, "R1"), name = "The Rake", level = 10, class = "rare", family = "Cat" }
  M.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
  M.step(8)
  local s = sent("S2|")
  eq(#s, 1, "one sighting message")
  local d = decode(s[1].msg)
  eq(d.npc, 5807); eq(d.layer, LAYER); eq(d.tame, true); eq(d.uiMap, 1413)
  M.step(30)
  eq(#sent("S2|"), 1, "no repeats while nothing changes")
  M.units.nameplate1.dead = true
  M.step(8)
  eq(#sent("S2|"), 2, "death is announced")
  eq(decode(sent("S2|")[2].msg).state, "D")
  M.units.nameplate1 = nil
end)

test("a rare spotted by this client raises a local alert once", function()
  M.sound = nil
  M.units.nameplate5 = { guid = guid(1, 60439, 5812, "L1"), name = "Local Rare", level = 20, class = "rare" }
  M.fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
  eq(M.sound ~= nil, true, "sound on first sight")
  M.sound = nil
  M.step(5)
  eq(M.sound, nil, "no repeat while it stays in view")
  ns.db.settings.localAlerts = false
  M.units.nameplate5 = { guid = guid(1, 60439, 5813, "L2"), name = "Quiet Rare", level = 20, class = "rare" }
  M.fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
  eq(M.sound, nil, "setting off")
  ns.db.settings.localAlerts = true
  M.units.nameplate5 = nil
  M.step(10)  -- let the announcements of these sightings go out
end)

test("alerts: chosen sound, banner, waypoint, test mode", function()
  eq(ns.db.settings.alertSound, "sonar")
  M.waypoint = nil
  ns.Alert.Show({ name = "Banner Rare", layer = LAYER, uiMap = 1413, x = 0.3, y = 0.4 }, "local", true)
  eq(M.sound, "Interface\\AddOns\\RareNet\\Media\\sonar.ogg"); eq(M.soundChannel, "Master")
  eq(M.waypoint.m, 1413); eq(M.waypoint.x, 0.3)
  M.waypoint = nil
  ns.Alert.Test()
  eq(M.waypoint, nil, "a test never moves your waypoint")
  ns.db.settings.alertSound = ns.Alert.NextSound("horn")
  eq(ns.db.settings.alertSound, "raidwarning")
  ns.Alert.PlaySound()
  eq(M.sound, 8959)
  ns.db.settings.alertSound = "sonar"
  M.badSoundFile = true
  ns.Alert.PlaySound()
  eq(M.sound, 8959, "unplayable file falls back to the raid warning")
  M.badSoundFile = nil
  ns.db.settings.alertSound = "none"
  M.sound = nil
  ns.Alert.PlaySound()
  eq(M.sound, nil)
  ns.db.settings.alertSound = "sonar"
  M.step(8)
end)

test("someone else announcing first suppresses ours", function()
  M.units.target = { guid = guid(1, 60439, 5808, "R2"), name = "Other Rare", level = 12, class = "rareelite" }
  M.fire("PLAYER_TARGET_CHANGED")
  local before = #sent("S2|")
  receive(ns.Net.EncodeSighting(report(5808, { layer = LAYER })), "Alice Smith")
  M.step(8)
  eq(#sent("S2|"), before, "suppressed")
  M.units.target = nil
end)

test("trust: two first-hand witnesses or two relays confirm", function()
  local r = report(999001, { name = "New Forever Rare" })
  receive(ns.Net.EncodeSighting(r), "Bob Brown")
  local e = ns.Sightings.Get("999001@" .. LAYER)
  eq(e.confirmed, false); eq(e.known, false); eq(e.name, "New Forever Rare")
  receive(ns.Net.EncodeSighting(r), "Bob Brown")
  eq(e.confirmed, false, "same sender twice does not confirm")
  receive(ns.Net.EncodeSighting(r), "Carol White")
  eq(e.confirmed, true); eq(e.firstHandCount, 2)
  local e2 = ns.Sightings.AddRemote(report(999002), "Relay One", GetServerTime(), "relay")
  eq(e2.confirmed, false); eq(e2.firstHandCount, 0)
  ns.Sightings.AddRemote(report(999002), "Relay Two", GetServerTime(), "relay")
  eq(e2.confirmed, true, "two responders vouch")
  local entry, why = ns.Sightings.AddRemote(report(1, { time = GetServerTime() + 1000 }), "X", GetServerTime())
  eq(why, "future")
  entry, why = ns.Sightings.AddRemote(report(1, { time = GetServerTime() - 3600 }), "X", GetServerTime())
  eq(why, "stale")
end)

test("per-sender rate limits drop floods", function()
  local before = ns.Net.status.dropped
  for i = 1, 25 do receive(ns.Net.EncodeSighting(report(100000 + i)), "Spammer Guy") end
  eq(ns.Net.status.dropped - before, 5, "20 per minute accepted")
  receive("H2|123|", "Spammer Guy")
  receive("H2|124|", "Spammer Guy")
  eq(ns.Net.status.dropped - before, 6, "one hello per 10 min")
end)

test("own echoes are ignored under the Forever name format", function()
  SlashCmdList.RARENET("ping")
  receive(sent("P1|")[#sent("P1|")].msg, "Rocio Aguirre")
  M.units.nameplate3 = { guid = guid(1, 60439, 5811, "R9"), name = "Echo Rare", level = 15, class = "rare" }
  M.fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
  M.step(8)
  local mine = sent("S2|")[#sent("S2|")].msg
  local e = ns.Sightings.Get("5811@" .. LAYER)
  receive(mine, "Rocio Aguirre")
  eq(e.voucherCount, 0, "own echo ignored")
  receive(mine, "Ana Lopez")
  eq(e.voucherCount, 1, "others count")
  M.units.nameplate3 = nil
end)

test("alert for a new known rare on my layer, not for another continent", function()
  M.sound = nil
  ns.Layer.Reset()
  ns.Layer.Observe(ns.Layer.ParseGUID(guid(1, 60439, 3244, "Z1")), GetServerTime())
  receive(ns.Net.EncodeSighting(report(5809)), "Dave Green")
  eq(M.sound ~= nil, true, "sound")
  M.sound = nil
  receive(ns.Net.EncodeSighting(report(5810, { layer = "4621-0-1" })), "Dave Green")
  eq(M.sound, nil, "no sound for another continent")
end)

test("not-seen reports: doubtful, then removed, and strikes ignore liars", function()
  local function fake(npc, liar)
    receive(ns.Net.EncodeSighting(report(npc, { time = GetServerTime() - 100 })), liar)
    return "" .. npc .. "@" .. LAYER
  end
  for i = 1, 5 do
    local id = fake(700000 + i, "Troll Face")
    eq(ns.Sightings.NotSeen(id, "Honest A", GetServerTime() - 200), nil, "negatives older than the report do not count")
    eq(ns.Sightings.NotSeen(id, "Honest A", GetServerTime()), "doubtful")
    receive(string.format("N2|%d|%s|%d", 700000 + i, LAYER, GetServerTime()), "Honest B")
    eq(ns.Sightings.Get(id), nil, "removed after two negatives")
  end
  eq(ns.db.ignored["Troll Face"], nil, "never written to the saved ignore list")
  eq(ns.Sync.IsPaused("Troll Face", GetServerTime()), true, "paused for a while")
  local before = ns.Net.status.dropped
  receive(ns.Net.EncodeSighting(report(700010)), "Troll Face")
  eq(ns.Net.status.dropped, before + 1, "dropped while paused")
  eq(ns.Sync.IsPaused("Troll Face", GetServerTime() + 1801), false, "and forgiven later")
  -- An honest player whose single-source report vanished once is not paused.
  local lost = fake(700011, "Unlucky Hunter")
  ns.Sightings.NotSeen(lost, "Honest A", GetServerTime())
  ns.Sightings.NotSeen(lost, "Honest B", GetServerTime())
  eq(ns.Sync.IsPaused("Unlucky Hunter", GetServerTime()), false)
  -- Corroborated reports are never struck.
  local both = fake(700012, "Witness One")
  receive(ns.Net.EncodeSighting(report(700012, { time = GetServerTime() - 100 })), "Witness Two")
  ns.Sightings.NotSeen(both, "Honest A", GetServerTime())
  ns.Sightings.NotSeen(both, "Honest B", GetServerTime())
  eq(ns.Sightings.Get(both) ~= nil, true, "two witnesses outweigh two negatives")
  -- Patrolling rares (Vultros has many spawn points) are never deleted.
  local patrol = fake(462, "Patrol Watcher")
  ns.Sightings.NotSeen(patrol, "Honest A", GetServerTime())
  ns.Sightings.NotSeen(patrol, "Honest B", GetServerTime())
  eq(ns.Sightings.Get(patrol).doubtful, true, "only doubtful")
  -- A fresh positive outdates negatives.
  local id = fake(700020, "Real Witness")
  ns.Sightings.NotSeen(id, "Honest A", GetServerTime())
  receive(ns.Net.EncodeSighting(report(700020, { time = GetServerTime() + 1 })), "Other Witness")
  eq(ns.Sightings.Get(id).doubtful, false)
end)

test("standing on a reported spot without seeing it sends one N2", function()
  ns.Layer.Reset()
  ns.Layer.Observe(ns.Layer.ParseGUID(guid(1, 60439, 3244, "Z2")), GetServerTime())
  M.cvars.nameplateShowEnemies = "1"
  receive(ns.Net.EncodeSighting(report(700030, { x = 0.452, y = 0.317, time = GetServerTime() - 120 })), "Far Away")
  local before = #sent("N2|")
  M.step(14)
  ns.Layer.Observe(ns.Layer.ParseGUID(guid(1, 60439, 3244, "Z2")), GetServerTime())
  M.step(14)
  eq(#sent("N2|"), before + 1, "one not-seen report")
  M.step(20)
  eq(#sent("N2|"), before + 1, "only once")
end)

test("sync: newcomer hello gets one reply with what it lacks", function()
  ns.Sightings.Clear()
  local now = GetServerTime()
  ns.Sightings.AddLocal(report(800001, { time = now - 30 }))
  ns.Sightings.AddLocal(report(800002, { time = now - 20 }))
  local known = ns.Sightings.Code(800002, LAYER, "A", now - 20)
  local before = #sent("Y2|")
  receive("H2|555|" .. known, "New Player")
  M.step(30)
  local replies = sent("Y2|")
  eq(#replies, before + 1, "one reply message")
  local body = replies[#replies].msg
  assert(body:find("^Y2|555|800001,"), "contains the missing entry: " .. body)
  assert(not body:find("800002"), "skips what the newcomer has")
end)

test("sync: replies only inside a round, relays are not first hand", function()
  local stray = string.format("Y2|999|%d,%s,1413,500,500,A,%d,0", 800100, LAYER, GetServerTime())
  receive(stray, "Spoofer Guy")
  eq(ns.Sightings.Get("800100@" .. LAYER), nil, "no round, no reply accepted")
  receive("H2|777|", "Another Newcomer")
  receive(string.format("Y2|777|%d,%s,1413,500,500,A,%d,0", 800101, LAYER, GetServerTime()), "Responder One")
  local e = ns.Sightings.Get("800101@" .. LAYER)
  eq(e.confirmed, false); eq(e.firstHandCount, 0)
  M.step(30)
end)

test("logout cache is restored as to-verify and never sent", function()
  ns.Sightings.Clear()
  local now = GetServerTime()
  ns.Sightings.AddLocal(report(800200, { time = now - 10 }))
  ns.Sightings.Save(ns.db, now)
  ns.Sightings.Clear()
  eq(ns.Sightings.Restore(ns.db, now + 60), 1)
  local e = ns.Sightings.Get("800200@" .. LAYER)
  eq(e.cached, true); eq(e.confirmed, false)
  local before = #sent("Y2|")
  M.step(25)
  receive("H2|888|", "Third Newcomer")
  M.step(30)
  eq(#sent("Y2|"), before, "cached entries are not offered")
  ns.Sightings.Save(ns.db, now)
  eq(ns.Sightings.Restore(ns.db, now + 3600), 0, "old cache dropped")
end)

test("community database: only vetted rares are persisted", function()
  local now = GetServerTime()
  receive(ns.Net.EncodeSighting(report(990010, { name = "Rumour" })), "Lone Voice")
  eq(ns.db.discovered[990010], nil, "one remote witness is not enough")
  receive(ns.Net.EncodeSighting(report(990010, { name = "Rumour" })), "Second Voice")
  eq(ns.db.discovered[990010] ~= nil, true, "two first-hand witnesses")
  ns.Sightings.AddLocal(report(990001, { uiMap = 1413, x = 0.31, y = 0.62, name = "Skyborne Terror", tame = true }))
  local d = ns.db.discovered[990001]
  eq(d.name, "Skyborne Terror"); eq(#d.points, 3)
  receive("D2|990020|1413|500|500|0|30|Gossip Rare", "G One")
  eq(ns.db.discovered[990020], nil, "one gossip is not enough")
  receive("D2|990020|1413|500|500|0|30|Gossip Rare", "G Two")
  eq(ns.db.discovered[990020].name, "Gossip Rare")
end)

test("map pins: known spawns on zones, live sightings everywhere", function()
  ns.Sightings.Clear()
  local rake = false
  for _, p in ipairs(ns.Map.PinsFor(1412, GetServerTime())) do if p.npc == 5807 and p.kind == "seed" then rake = true end end
  eq(rake, true, "The Rake in Mulgore")
  ns.db.settings.pins = "tame"
  for _, p in ipairs(ns.Map.PinsFor(1412, GetServerTime())) do
    if p.kind == "seed" then assert(ns.Seed[p.npc][3] > 0, "only tameable") end
  end
  ns.db.settings.pins = "all"
  eq(#ns.Map.PinsFor(1414, GetServerTime()), 0, "no seed carpet on the continent")
  ns.Sightings.AddLocal(report(5807, { uiMap = 1412 }))
  local cont = ns.Map.PinsFor(1414, GetServerTime())
  eq(#cont, 1); eq(cont[1].x, 0.45); eq(cont[1].y, 0.7)
  M.step(2)
  assert(M.provider and #M.acquired > 0, "pins acquired")
end)

test("refused channel messages fall back to the guild", function()
  M.channelResult = 4
  M.guild = true
  ns.Net.Enqueue("S2|x", 1)
  M.step(3)
  ns.Net.Enqueue("S2|y", 1)
  M.step(3)
  eq(M.sent[#M.sent].chatType, "GUILD")
  M.channelResult = 0
end)

test("a locked channel moves to the next name", function()
  M.fire("CHAT_MSG_CHANNEL_NOTICE", "WRONG_PASSWORD", "", "", "", "", "", "", "", "RareNetFE")
  M.step(4)
  eq(GetChannelName("RareNetFE2"), 5)
end)

test("asks once for nameplates and hints when the layer is unknown", function()
  M.cvars.nameplateShowEnemies = "0"
  ns.db.settings.askedNameplates = false
  M.fire("PLAYER_ENTERING_WORLD")
  eq(ns.Layer.Current(), nil)
  M.printed = {}
  M.step(20)
  assert(ns.Scan.askYes, "own dialog shown")
  ns.Scan.askYes.scripts.OnClick()
  eq(M.cvars.nameplateShowEnemies, "1")
  local yes = ns.Scan.askYes
  ns.Scan.askYes = nil
  M.fire("PLAYER_ENTERING_WORLD")
  M.step(20)
  eq(ns.Scan.askYes, nil, "asked only once")
  ns.Scan.askYes = yes
end)

test("blocked actions blamed on RareNet are recorded", function()
  local n = #ns.diag.errors
  M.fire("ADDON_ACTION_BLOCKED", "RareNet", "SomeProtectedFunction()")
  M.fire("ADDON_ACTION_BLOCKED", "OtherAddon", "Whatever()")
  eq(#ns.diag.errors, n + 1)
  assert(ns.diag.errors[#ns.diag.errors]:find("SomeProtectedFunction"))
  table.remove(ns.diag.errors)
end)

test("presence: who is online", function()
  local before = #sent("Q2|")
  M.printed = {}
  SlashCmdList.RARENET("peers")
  M.step(3)
  eq(#sent("Q2|"), before + 1, "question sent")
  receive("A2|123|0.3.1", "Peer One")
  receive("Q2|456", "Peer Two")
  M.step(8)
  local answers = sent("A2|456|")
  eq(#answers, 1, "we answer others")
  local listed = false
  for _, line in ipairs(M.printed) do if line:find("Peer One") and line:find("v0.3.1") then listed = true end end
  eq(listed, true, "peer listed with version")
  receive("Q2|457", "Peer Two")
  eq(ns.Net.status.dropped > 0, true)
end)

test("channel members are listed as clickable names", function()
  ns.Net.ListMembers()
  M.printed = {}
  M.fire("CHAT_MSG_CHANNEL_LIST", "*Brave Bull, Rocio Aguirre", "", "", "", "", "", "", "", "8. RareNetFE2")
  M.fire("CHAT_MSG_CHANNEL_LIST", "@Some Mod", "", "", "", "", "", "", "", "8. RareNetFE2")
  M.step(3)
  local all = table.concat(M.printed, "\n")
  eq(ns.Net.Online(), 3, "online count from the same list")
  assert(all:find("3 players"), all)
  assert(all:find("|Hplayer:Brave Bull|h%[Brave Bull%]|h"), all)
  assert(all:find("|Hplayer:Some Mod|h"), all)
  M.printed = {}
  M.fire("CHAT_MSG_CHANNEL_LIST", "*Other, People", "", "", "", "", "", "", "", "1. General")
  M.step(3)
  eq(#M.printed, 0, "other channels and unrequested lists are ignored")
  eq(ns.Net.Online(), 3)
end)

test("hopping goes through Layer-Swap or Forever Layer Hop", function()
  ns.Layer.Reset()
  ns.Layer.Observe(ns.Layer.ParseGUID(guid(1, 60439, 3244, "H1")), GetServerTime())
  local other = { name = "Far Rare", layer = "4621-1-55555" }
  local mine = { name = "Near Rare", layer = LAYER }
  eq(ns.Hop.Useful(mine), false); eq(ns.Hop.Useful(other), true)
  local calls = {}
  M.addons = { LayerSwap = true }
  SlashCmdList.LAYERSWAP = function(msg) calls[#calls + 1] = "ls:" .. msg end
  SlashCmdList.FOREVERLAYERHOP = function(msg) calls[#calls + 1] = "flh:" .. msg end
  LayerSwapDB = { layers = { ["4621-55555"] = { letter = "C" } } }
  eq(ns.Hop.Hint(other), "Right-click: hop to its layer with Layer-Swap")
  ns.Hop.To(other)
  eq(calls[1], "ls:swap C")
  LayerSwapDB = { layers = {} }
  ns.Hop.To(other)
  eq(calls[2], "ls:", "unknown layer opens the panel")
  M.addons = { ForeverLayerHop = true }
  ns.Hop.To(other)
  eq(calls[3], "flh:")
  M.addons = {}
  eq(ns.Hop.To(other), false)
  eq(ns.Hop.To(mine), false)
  eq(#calls, 3)
end)

test("rare database: zones, loot, map button and shift-clicks", function()
  local loot = ns.Database.LootOf(5807)
  eq(loot[1].id, 17922); eq(loot[1].chance, 100); eq(loot[1].quality, 2)
  eq(ns.Database.ChanceText(0.3), "0.3%"); eq(ns.Database.ChanceText(nil), "?")
  local top = ns.Database.TopLoot(5807, 3)
  eq(#top, 3); eq(top[1].text, "Lionfur Armor  100%")
  ns.Database.Open(5807)
  local npc, zone = ns.Database.Selected()
  eq(npc, 5807); eq(zone.uiMap, 1412)
  M.combat = true
  eq(ns.Database.ShowOnMap(), false, "no map in combat")
  M.combat = false
  WorldMapFrame.shown = false
  eq(ns.Database.ShowOnMap(), true); eq(M.openedMap, 1412)
  WorldMapFrame.shown = true
  -- Shift-click on a map pin opens the database on that rare, not a waypoint.
  local pin = CreateFromMixins(RareNetPinMixin)
  pin.data = { kind = "seed", npc = 462, uiMap = 1436, x = 0.5, y = 0.43 }
  M.waypoint = nil
  M.shift = true
  pin:OnMouseClickAction("LeftButton")
  M.shift = false
  eq(ns.Database.Selected(), 462); eq(M.waypoint, nil)
  -- The minimap menu offers the database.
  local mb = RareNetMinimapButton
  M.menu = nil
  mb.scripts.OnClick(mb, "RightButton")
  assert(M.menu and M.menu["Rare database"], "menu built")
  M.menu["Rare database"]()
  SlashCmdList.RARENET("db")
  ns.Database.Refresh()
  eq(#ns.diag.errors, 0, table.concat(ns.diag.errors, " || "))
end)

test("community loot: capture, dedupe, gathering, sharing and limits", function()
  local rigger = function(spawn) return string.format("Creature-0-6782-1-25081-5931-%s", spawn) end
  local function lootWindow(slots)
    M.loot = slots
    M.fire("LOOT_READY", false)
    M.fire("LOOT_OPENED", false)
    M.fire("LOOT_CLOSED")
  end
  local before = #sent("L2|")
  lootWindow({
    { link = "|Hitem:21000|h[Foreman's Helm]|h", sources = { rigger("0000AAAA01"), 1 } },
    { link = "|Hitem:2592|h[Wool Cloth]|h", sources = { rigger("0000AAAA01"), 2 } },
    { link = nil, sources = { rigger("0000AAAA01"), 0 } },
    { link = "|Hitem:5000|h[Quest Thing]|h", quest = true, sources = { rigger("0000AAAA01"), 1 } },
  })
  local kills, items = ns.Drops.Of(5931)
  eq(kills, 1); eq(#items, 2, "quest items left out")
  eq(items[1].mine, true)
  M.step(3)
  eq(#sent("L2|"), before + 1, "shared")
  assert(sent("L2|")[#sent("L2|")].msg:find("^L2|5931|25081:0000AAAA01|%d+|"), "record format")
  -- Reopening the corpse, or skinning it, adds nothing.
  lootWindow({ { link = "|Hitem:2934|h[Ruined Leather]|h", sources = { rigger("0000AAAA01"), 1 } } })
  eq((ns.Drops.Of(5931)), 1)
  -- Skinning a corpse we did not loot is not kill loot either.
  M.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 8613)
  lootWindow({ { link = "|Hitem:2934|h[Ruined Leather]|h", sources = { rigger("0000BBBB02"), 1 } } })
  eq((ns.Drops.Of(5931)), 1, "gathering ignored")
  M.step(5)
  -- Pick pocketing in stealth is ignored.
  M.stealth = true
  lootWindow({ { link = "|Hitem:5432|h[Coin]|h", sources = { rigger("0000CCCC03"), 1 } } })
  M.stealth = false
  eq((ns.Drops.Of(5931)), 1, "stealth ignored")
  -- Area loot: two corpses, one rare and one not.
  lootWindow({
    { link = "|Hitem:21000|h[Foreman's Helm]|h", sources = { rigger("0000DDDD04"), 1, "Creature-0-6782-1-25081-3244-0000EEEE05", 1 } },
  })
  eq((ns.Drops.Of(5931)), 2)
  eq(select(1, ns.Drops.Of(3244)), 0, "non-rare corpses are not recorded")
  -- Other players: the same corpse from two players counts once; witnesses add up.
  local now = GetServerTime()
  receive(string.format("L2|5931|25081:0000FFFF06|%d|21000.2592", now), "Ana Lopez")
  receive(string.format("L2|5931|25081:0000FFFF06|%d|21000", now), "Bob Brown")
  local k, list = ns.Drops.Of(5931)
  eq(k, 3)
  for _, it in ipairs(list) do if it.id == 21000 then eq(it.count, 3); eq(it.players, 2) end end
  -- Per player, per rare and per day: three corpses at most.
  for i = 1, 4 do receive(string.format("L2|5931|25081:000011110%d|%d|2592", i, now), "Spammy Sam") end
  eq((ns.Drops.Of(5931)), 6, "fourth corpse refused")
  -- Relayed records do not make witnesses; bogus items are dropped.
  receive(string.format("G2|5931|25081:0000ABCD07|%d|21000.999999", now), "Gossip Gil")
  local k2, list2 = ns.Drops.Of(5931)
  eq(k2, 7)
  for _, it in ipairs(list2) do
    assert(it.id ~= 999999, "unknown item refused")
    if it.id == 21000 then eq(it.players, 2) end
  end
  -- The database shows the Forever drops first.
  local top = ns.Database.TopLoot(5931, 2)
  assert(top[1].text:find("^Item #21000  %d+/7") or top[1].text:find("/7"), top[1].text)
  M.loot = {}
  M.step(10)
end)

test("database search and filters", function()
  local f = ns.Database.Filter()
  local function has(npc)
    for _, n in ipairs(ns.Database.Rebuild()) do if n == npc then return true end end
    return false
  end
  f.zone = nil
  f.text = "rake"; eq(has(5807), true, "by rare name"); eq(has(462), false)
  f.text = "lionfur"; eq(has(5807), true, "by item name")
  f.text = ""
  f.tame = true; eq(has(256492), true); eq(has(5931), false, "Foreman Rigger is not tameable"); f.tame = false
  f.new = true; eq(has(256492), true); eq(has(5807), false, "classic rare hidden"); f.new = false
  f.loot = true; eq(has(5931), true, "has Forever loot"); f.loot = false
  f.zone = 1442; eq(has(5931), true); eq(has(5807), false); f.zone = nil
  f.sort = "name"
  local l = ns.Database.Rebuild()
  local a, b = ns.Database.RareInfo(l[1]), ns.Database.RareInfo(l[2])
  eq(a <= b, true, "sorted by name")
  f.sort = "level"
  -- Opening on a rare clears filters that would hide it.
  f.new = true
  ns.Database.Open(5807)
  eq(f.new, false); eq(ns.Database.Selected(), 5807)
  eq(#ns.diag.errors, 0, table.concat(ns.diag.errors, " || "))
end)

test("minimap icons: offsets, rotation, range and live edge", function()
  -- 100 yards east, no rotation: straight right.
  local x, y = ns.MinimapPins.Offset(100, 0, 0.3, false, nil)
  eq(x, 30); eq(y, 0)
  -- 100 yards south: down.
  x, y = ns.MinimapPins.Offset(0, 100, 0.3, false, nil)
  eq(y, -30)
  -- Facing west (pi/2) with a rotating minimap: a point to the west is up.
  x, y = ns.MinimapPins.Offset(-100, 0, 0.3, true, math.pi / 2)
  eq(math.floor(y + 0.5), 30); eq(math.floor(math.abs(x) + 0.5), 0)
  ns.Sightings.Clear()
  ns.db.settings.minimapPins = "live"
  -- Player at 0.452, 0.317 of a 3000 x 2000 yard map: 30 yards away is inside.
  ns.Sightings.AddLocal({ npc = 5807, layer = LAYER, uiMap = 1413, x = 0.462, y = 0.317, state = "A", time = GetServerTime() })
  ns.Sightings.AddLocal({ npc = 5808, layer = LAYER, uiMap = 1413, x = 0.95, y = 0.9, state = "A", time = GetServerTime() })
  ns.MinimapPins.Update()
  eq(ns.MinimapPins.Count(), 2, "near one inside, far one on the edge")
  ns.db.settings.minimapPins = "off"
  ns.MinimapPins.Update()
  eq(ns.MinimapPins.Count(), 0)
  ns.db.settings.minimapPins = "all"
  ns.Sightings.Clear()
  M.step(10)
  eq(#ns.diag.errors, 0, table.concat(ns.diag.errors, " || "))
end)

test("undiscovered rares: listed, detected by id, first discovery alert", function()
  eq(ns.Database.IsUndiscovered(263141), true, "Scaldaron is unfound")
  local f = ns.Database.Filter()
  f.undiscovered = true
  local l = ns.Database.Rebuild()
  local found = false
  for _, n in ipairs(l) do if n == 263141 then found = true end end
  eq(found, true); eq(#l, 21)
  f.undiscovered = false
  -- Seen for the first time: detected by id even if not classified rare, special alert, learned.
  M.printed = {}
  M.units.nameplate6 = { guid = guid(1, 60439, 263141, "U1"), name = "Scaldaron", level = 50, class = "elite" }
  M.fire("NAME_PLATE_UNIT_ADDED", "nameplate6")
  local said = table.concat(M.printed, "\n")
  assert(said:find("First discovery"), said)
  eq(ns.db.discovered[263141] ~= nil, true, "now part of the community database")
  eq(ns.Database.IsUndiscovered(263141), false)
  M.units.nameplate6 = nil
  M.step(10)
end)

test("one pin per rare with faint dots that light up on hover", function()
  ns.Sightings.Clear()
  local function count(mapID)
    local seeds, dots = 0, 0
    for _, p in ipairs(ns.Map.PinsFor(mapID, GetServerTime())) do
      if p.npc == 5931 then
        if p.kind == "seed" then seeds = seeds + 1 elseif p.kind == "dot" then dots = dots + 1 end
      end
    end
    return seeds, dots
  end
  eq(ns.db.settings.spawnPins, "one")
  local seeds, dots = count(1442)
  eq(seeds, 1, "one pin"); eq(dots > 0, true, "other points as dots")
  ns.db.settings.spawnPins = "all"
  local all = count(1442)
  eq(all, seeds + dots, "all points as pins")
  ns.db.settings.spawnPins = "one"
  -- Hover lights up only that rare's dots.
  local function fakePin(data)
    return { data = data, baseSize = 11, alpha = 0.65, SetAlpha = function(self, a) self.alpha = a end, SetSize = function() end }
  end
  local mine, other = fakePin({ kind = "dot", npc = 5931 }), fakePin({ kind = "dot", npc = 462 })
  local map = { EnumeratePinsByTemplate = function() local i, list = 0, { mine, other }
    return function() i = i + 1; return list[i] end end }
  ns.Map.HighlightSpawns(map, 5931, true)
  eq(mine.alpha, 1); eq(other.alpha, 0.65)
  ns.Map.HighlightSpawns(map, 5931, false)
  eq(mine.alpha, 0.65)
  -- Click keeps them lit until the rare is clicked again or another one is.
  ns.Map.Select(map, 5931)
  ns.Map.HighlightSpawns(map, 5931, false)            -- mouse leaves
  eq(mine.alpha, 1, "selected rare stays lit")
  ns.Map.Select(map, 462)
  eq(mine.alpha, 0.65); eq(other.alpha, 1, "selection moves")
  ns.Map.Select(map, 462)
  eq(other.alpha, 0.65); eq(ns.Map.Selected(), nil, "click again deselects")
end)

test("Forever rares from ForeverChanges join the seed with credit", function()
  local fern = ns.Seed[256492]
  eq(fern[1], "Fernfeather"); eq(fern[3] > 0, true, "tameable")
  eq(ns.SeedSource[256492], "ForeverChanges")
  eq(ns.SeedSource[5931], nil, "classic rares keep their source")
  local onStonetalon = false
  for i = 1, #ns.Seed[5931][5], 3 do if ns.Seed[5931][5][i] == 1442 then onStonetalon = true end end
  eq(onStonetalon, true, "Foreman Rigger gains Forever spawn points")
  local found = false
  for _, l in ipairs(ns.Database.TopLoot(5931, 6)) do if l.text:find("284400") then found = true end end
  eq(found, true, "Foreman's Helm listed")
  ns.Database.Open(256492)
  eq(ns.Database.Selected(), 256492)
  eq(#ns.diag.errors, 0, table.concat(ns.diag.errors, " || "))
end)

test("pins, preview, minimap, settings and slash commands do not error", function()
  local pin = CreateFromMixins(RareNetPinMixin)
  for _, k in ipairs({ "Icon", "Ring", "Disc" }) do pin[k] = setmetatable({}, { __index = function() return function() end end }) end
  pin.SetPosition = function(self, x, y) self.px = x end
  pin.SetSize = function() end
  pin.SetMouseClickEnabled = function() end
  pin.SetMouseMotionEnabled = function() end
  pin.SetAlpha = function() end
  pin.CreateTexture = function() return setmetatable({}, { __index = function(t, k)
    if k == "CreateAnimationGroup" then
      return function() return setmetatable({}, { __index = function() return function()
        return setmetatable({}, { __index = function() return function() end end }) end end }) end
    end
    return function() end
  end }) end
  pin:OnLoad()
  pin:OnAcquired({ kind = "seed", npc = 5807, uiMap = 1412, x = 0.5, y = 0.27 })
  eq(pin.px, 0.5)
  eq(pin.levelType, "PIN_FRAME_LEVEL_AREA_POI")
  pin:OnAcquired({ kind = "live", npc = 5807, uiMap = 1412, x = 0.5, y = 0.27,
    entry = { npc = 5807, layer = "1-1-611", state = "A", time = GetServerTime() } })
  eq(pin.levelType, "PIN_FRAME_LEVEL_VIGNETTE", "live sightings on top")
  pin:OnAcquired({ kind = "seed", npc = 5807, uiMap = 1412, x = 0.5, y = 0.27 })
  pin:OnMouseEnter()
  pin:OnMouseClickAction("LeftButton")
  eq(ns.Map.Selected(), 5807, "left click selects")
  pin:OnMouseClickAction("LeftButton")
  eq(ns.Map.Selected(), nil, "and again deselects")
  pin:OnMouseClickAction("RightButton")
  eq(M.waypoint.m, 1412, "right click sets the waypoint")
  pin:OnMouseLeave()
  ns.Options.Toggle()
  ns.Options.UpdateStatus()
  for _, cmd in ipairs({ "", "config", "tame", "all", "alerts", "alerts", "diag", "ignore Some One" }) do SlashCmdList.RARENET(cmd) end
  eq(ns.db.ignored["Some One"], true)
  ns.db.settings.minimapHide = true
  ns.MinimapButton.Update()
  M.step(3)
  eq(#ns.diag.errors, 0, "no runtime errors: " .. table.concat(ns.diag.errors, " || "))
end)

test("a lone witness re-announcing a rare alerts once and is named", function()
  ns.Layer.Reset()
  ns.Layer.Observe(ns.Layer.ParseGUID(guid(1, 60439, 3244, "W1")), GetServerTime())
  ns.Sightings.Clear()
  local function alerts()
    local n = 0
    for _, line in ipairs(M.printed) do if line:find("Dishu Test") then n = n + 1 end end
    return n
  end
  M.printed = {}
  receive(ns.Net.EncodeSighting(report(5865, { name = "Dishu Test" })), "Lone Hunter")
  eq(alerts(), 1, "first report alerts")
  assert(table.concat(M.printed, "\n"):find("seen by |Hplayer:Lone Hunter|h"), table.concat(M.printed, "\n"))
  -- It expires (5 min for a lone report) and comes back with the next re-announcement.
  ns.Sightings.Clear()
  M.step(300)
  receive(ns.Net.EncodeSighting(report(5865, { name = "Dishu Test" })), "Lone Hunter")
  eq(alerts(), 1, "the same rare on the same layer does not alert again")
  -- Old news passed on by a sync does not alert at all.
  receive(ns.Net.EncodeSighting(report(5807, { name = "Old Rake", time = GetServerTime() - 280 })), "Syncer")
  local old = 0
  for _, line in ipairs(M.printed) do if line:find("Old Rake") then old = old + 1 end end
  eq(old, 0, "stale sightings stay quiet")
  local r = ns.Sightings.AddRemote(report(5808, { time = GetServerTime() - 420 }), "Syncer", GetServerTime(), "relay")
  eq(r, nil, "a new entry already past its lifetime is not created")
  -- Killed and up again on the same layer: that is news.
  receive(ns.Net.EncodeSighting(report(5865, { name = "Dishu Test", state = "D" })), "Lone Hunter")
  M.step(5)
  receive(ns.Net.EncodeSighting(report(5865, { name = "Dishu Test" })), "Other Hunter")
  eq(alerts(), 2, "a respawn alerts again")
  ns.Sightings.Clear()
end)

test("how to fight a rare: Forever first, then the classic data", function()
  -- Heartrazor: Forever's rank and tip, the classic spell under a Forever warning.
  local rank, fromForever, tip, entries = ns.Database.TacticsOf(5934)
  eq(rank, "Rare elite"); eq(fromForever, true)
  assert(tip and tip:find("poison"), "Forever tip")
  local header, spell
  for _, e in ipairs(entries) do
    if e.header then header = e.header end
    if e.spell then spell = e.spell end
  end
  eq(header, "Classic data (may differ in Forever)")
  eq(spell, 8256, "Lethal Toxin from the classic spell list")
  -- Humar: Forever already says how long his respawn is, so the classic timer stays out.
  local _, _, _, humar = ns.Database.TacticsOf(5828)
  for _, e in ipairs(humar) do assert(not (e.text and e.text:find("Respawns")), "no classic respawn for Humar") end
  -- Brack, classic only: flees at 15%, classic rank, plain classic header.
  local brank, bforever, btip, brack = ns.Database.TacticsOf(520)
  eq(brank, "Rare"); eq(bforever, false); eq(btip, nil)
  local flees
  for _, e in ipairs(brack) do
    if e.header then eq(e.header, "Classic data") end
    if e.text and e.text:find("Flees at 15%%") then flees = true end
  end
  eq(flees, true)
  eq(ns.Database.HoursText(5400), "1.5 hours"); eq(ns.Database.HoursText(9000), "2.5 hours")
  eq(ns.Database.HoursText(3600), "1 hour"); eq(ns.Database.HoursText(2700), "45 minutes")
  -- Forever's name and level win: the Outrunners as Forever lists them.
  local name, level = ns.Database.RareInfo(5797)
  eq(name, "The Alliance Outrunners"); eq(level, 24)
  -- The window shows it without errors, on both tabs.
  ns.Database.Open(5934)
  local d = RareNetDatabase.detail
  d.tabFight.scripts.OnClick()
  local spellRow
  for _, row in ipairs(d.loot) do if rawget(row, "spell") then spellRow = row end end
  eq(spellRow and rawget(spellRow, "spell"), 8256, "the fight tab lists the spell")
  d.tabDrops.scripts.OnClick()
  for _, row in ipairs(d.loot) do eq(rawget(row, "spell"), nil, "the drops tab has no spells") end
end)

print = function(...) io.write(table.concat({ ... }, " "), "\n") end
print(passed .. " tests passed")
