-- UI: a movable list of live sightings, alerts and slash commands.
local _, ns = ...

local ROWS = 10
local frame, rows, header
local shown = {}              -- row index -> entry
local lastSweep = 0

local function zoneName(uiMap)
  local info = uiMap and uiMap > 0 and C_Map.GetMapInfo(uiMap)
  return info and info.name or "?"
end

local function age(seconds)
  if seconds < 60 then return seconds .. "s" end
  return math.floor(seconds / 60) .. "m"
end

local function passesFilter(e)
  local f = ns.db.settings.filter
  if f == "tame" then return e.tame end
  if f == "zone" then return e.uiMap == C_Map.GetBestMapForUnit("player") end
  return true
end

local function layerText(e)
  local mine = ns.Layer.IsMine(e.layer)
  local color = mine == true and "|cff33ff33" or (mine == false and "|cffff9933" or "|cff999999")
  return color .. ns.Layer.Label(e.layer) .. "|r"
end

local function setWaypoint(e)
  if not (e and e.uiMap and e.uiMap > 0 and C_Map.CanSetUserWaypointOnMap(e.uiMap)) then return end
  C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(e.uiMap, e.x, e.y))
  C_SuperTrack.SetSuperTrackedUserWaypoint(true)
  ns.print(string.format("waypoint: %s, %s %.0f,%.0f", e.name, zoneName(e.uiMap), e.x * 100, e.y * 100))
end

local function build()
  frame = CreateFrame("Frame", "RareNetFrame", UIParent, "BackdropTemplate")
  frame:SetSize(430, 34 + ROWS * 16)
  frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -220, -200)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  if frame.SetBackdrop then
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    frame:SetBackdropColor(0, 0, 0, 0.6)
  end
  header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  header:SetPoint("TOPLEFT", 8, -6)
  header:SetJustifyH("LEFT")
  rows = {}
  for i = 1, ROWS do
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(414, 16)
    b:SetPoint("TOPLEFT", 8, -10 - i * 16)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetAllPoints()
    b.text:SetJustifyH("LEFT")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(_, button)
      if button == "LeftButton" and IsShiftKeyDown() then
        if shown[i] then ns.Database.Open(shown[i].npc) end
      elseif button == "RightButton" then
        ns.Hop.To(shown[i])
      else
        setWaypoint(shown[i])
      end
    end)
    b:SetScript("OnEnter", function(self)
      local e = shown[i]
      if not e then return end
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:AddLine(e.name, 1, 0.82, 0)
      local who = ns.Sightings.Reporters(e)
      if who then GameTooltip:AddLine((who:gsub("^%l", string.upper)), 0.7, 0.7, 0.7) end
      GameTooltip:AddLine("Left-click: waypoint    Shift-click: details and loot", 0.8, 0.8, 0.8)
      local hint = ns.Hop.Hint(e)
      if hint then GameTooltip:AddLine(hint, 0.4, 0.8, 1) end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = b
  end
  frame:Hide()
end

local function refresh(now)
  if not frame or not frame:IsShown() then return end
  local list = {}
  for _, e in ipairs(ns.Sightings.Live(now)) do
    if passesFilter(e) then list[#list + 1] = e end
  end
  -- Own layer first, then same continent, then by freshness.
  local function rank(e)
    local mine = ns.Layer.IsMine(e.layer)
    return mine == true and 0 or (mine == false and 1 or 2)
  end
  table.sort(list, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    return a.time > b.time
  end)
  local cur = ns.Layer.Current()
  local online = ns.Net.Online()
  header:SetText(string.format("RareNet  |  you: %s  |  net: %s  |  %s online  |  filter: %s",
    cur and ns.Layer.Label(cur.key) or "|cffffcc00L? target any mob|r", ns.Net.status.transport,
    online and tostring(online) or "?", ns.db.settings.filter))
  for i, b in ipairs(rows) do
    local e = list[i]
    shown[i] = e
    if e then
      b.text:SetText(string.format("%s %s%s%s  %s %.0f,%.0f  %s  %s%s",
        layerText(e), e.cached and "|cff888888~|r" or (e.doubtful and "|cffff4444??|r" or (e.confirmed and "" or "|cffaaaaaa?|r")), e.name,
        e.level and (" (" .. e.level .. ")") or "",
        zoneName(e.uiMap), (e.x or 0) * 100, (e.y or 0) * 100, age(now - e.time),
        e.state == "D" and "|cffff4444dead|r" or "|cff33ff33up|r", e.tame and "  |cffffcc00tame|r" or ""))
      b:Show()
    else
      b:Hide()
    end
  end
end

local LOCAL_ALERT_EVERY = 300     -- seconds between "rare nearby" alerts for one rare
local lastLocalAlert = {}

-- Rares this client spots itself, like a rare scanner would.
ns.Sightings.OnUpdate(function(e, isNew, removed)
  if removed or not e.mine or e.state ~= "A" or not ns.db or not ns.db.settings.localAlerts then return end
  local now = ns.Now()
  if now - (lastLocalAlert[e.npc] or 0) < LOCAL_ALERT_EVERY then return end
  lastLocalAlert[e.npc] = now
  -- A rare nobody had located: this player is the first RareNet scout to see it.
  local first = ns.Undiscovered and ns.Undiscovered[e.npc] and not (ns.db.discovered and ns.db.discovered[e.npc])
  ns.Alert.Show(e, first and "discovery" or "local", true)
end)

-- New rares reported by others on this continent: loud only on your layer.
-- Only fresh news alerts (an old sighting passed on by a sync is about to
-- expire), and one rare on one layer alerts once in a while: a lone witness
-- re-announces it every few minutes, and that is not news.
local REMOTE_FRESH = 120
local REMOTE_ALERT_EVERY = 15 * 60
local lastRemoteAlert = {}
ns.Sightings.OnUpdate(function(e, isNew, removed)
  if removed or e.mine or e.cached or e.doubtful or e.state ~= "A" or not ns.db or not ns.db.settings.alerts then return end
  if not (isNew or e.respawned) then return end
  if not (e.known or e.confirmed) or not passesFilter(e) then return end
  local now = ns.Now()
  if e.respawned then lastRemoteAlert[e.id] = nil end
  if now - e.time > REMOTE_FRESH then return end
  if now - (lastRemoteAlert[e.id] or 0) < REMOTE_ALERT_EVERY then return end
  local mine = ns.Layer.IsMine(e.layer)
  if mine == nil then return end
  lastRemoteAlert[e.id] = now
  ns.Alert.Show(e, "remote", mine)
end)

ns.Layer.OnChange(function(cur, old)
  if old and old.map == cur.map and old.server == cur.server then
    ns.print("layer changed: " .. ns.Layer.Label(old.key) .. " -> " .. ns.Layer.Label(cur.key))
  end
end)

-- One driver for timers: send queue, sweeps and the list.
local ticker = 0
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, elapsed)
  ticker = ticker + elapsed
  if ticker < 0.5 then return end
  ticker = 0
  local now = ns.Now()
  ns.Safe("send", ns.Net.Tick, GetTime())
  if GetTime() - lastSweep >= ns.Scan.sweepEvery then
    lastSweep = GetTime()
    ns.Safe("sweep", ns.Scan.Sweep)
    ns.Safe("prompts", ns.Scan.CheckPrompts)
    ns.Safe("notseen", ns.Sync.CheckNotSeen, now)
    ns.Safe("gossip", ns.Sync.GossipDiscovered, now)
    ns.Safe("loot gossip", ns.Drops.Gossip, now)
  end
  ns.Safe("refresh", refresh, now)
end)

table.insert(ns.onLoad, function(db)
  build()
  if db.settings.shown then frame:Show() end
end)

ns.UI = {}

function ns.UI.IsShown() return frame and frame:IsShown() or false end

function ns.UI.Toggle(show)
  if not frame then return end
  if show == nil then show = not frame:IsShown() end
  if show then frame:Show() else frame:Hide() end
  ns.db.settings.shown = frame:IsShown()
end

function ns.UI.ResetPosition()
  if not frame then return end
  frame:ClearAllPoints()
  frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -220, -200)
end

local function diag()
  local s = ns.Net.status
  local cur = ns.Layer.Current()
  ns.print(string.format("layer %s (map %s) | transport %s | last send %s | sent %d received %d dropped %d | guild %s",
    cur and ns.Layer.Label(cur.key) or "unknown", cur and cur.map or "-", s.transport, s.lastResult,
    s.sent, s.received, s.dropped, tostring(IsInGuild())))
  local c = {}
  for k, v in pairs(ns.diag.counters) do c[#c + 1] = k .. "=" .. v end
  table.sort(c)
  ns.print("counters: " .. (#c > 0 and table.concat(c, ", ") or "none"))
  ns.print("last GUID: " .. tostring(ns.diag.lastGUID))
  for i = math.max(1, #ns.diag.log - 5), #ns.diag.log do ns.print("log: " .. ns.diag.log[i]) end
  for i = 1, math.min(3, #ns.diag.errors) do ns.print("|cffff4444error:|r " .. ns.diag.errors[i]) end
end

SLASH_RARENET1 = "/rarenet"
SlashCmdList.RARENET = function(msg)
  local cmd, rest = (msg or ""):lower():match("^(%S*)%s*(.*)$")
  if cmd == "" then
    ns.UI.Toggle()
  elseif cmd == "config" or cmd == "options" then
    ns.Options.Toggle()
  elseif cmd == "all" or cmd == "tame" or cmd == "zone" then
    ns.db.settings.filter = cmd
    ns.print("filter: " .. cmd)
  elseif cmd == "alerts" then
    ns.db.settings.alerts = not ns.db.settings.alerts
    ns.print("alerts " .. (ns.db.settings.alerts and "on" or "off"))
  elseif cmd == "diag" then
    diag()
  elseif cmd == "db" or cmd == "rares" then
    ns.Database.Toggle()
  elseif cmd == "test" then
    ns.Alert.Test()
  elseif cmd == "ping" then
    ns.Net.Ping()
  elseif cmd == "members" or cmd == "who" then
    ns.Net.ListMembers()
  elseif cmd == "peers" then
    local asked = ns.Net.AskPresence(ns.Now())
    ns.print(asked and "asking who is online..." or "asked recently, showing what is known")
    ns.Net.RefreshMembers()
    C_Timer.After(asked and 7 or 2.5, function()
      local list = ns.Net.PeerList(ns.Now())
      ns.print(#list .. " other RareNet players answered or were heard in the last 30 min (you are "
        .. ns.Net.SelfName() .. ", v" .. ns.Net.Version() .. ")")
      local heard = {}
      for i, p in ipairs(list) do
        heard[ns.Net.BareName(p.name)] = true
        if i <= 20 then
          ns.print(string.format("  %s  %s ago%s", p.name, p.ago < 60 and (p.ago .. "s") or (math.floor(p.ago / 60) .. "m"),
            p.version and ("  v" .. p.version) or ""))
        end
      end
      -- In the channel but silent: in a dungeon (RareNet sends nothing
      -- there), on a version older than 0.3.2, or RareNet turned off.
      local me = ns.Net.BareName(ns.Net.SelfName())
      local silent = {}
      for _, name in ipairs(ns.Net.members or {}) do
        local bare = ns.Net.BareName(name)
        if bare ~= me and not heard[bare] then silent[#silent + 1] = name end
      end
      if #silent > 0 then
        ns.print(#silent .. " more in the channel did not answer (in a dungeon, an old RareNet, or RareNet off): "
          .. table.concat(silent, ", "))
      end
    end)
  elseif cmd == "ignore" and rest ~= "" then
    local name = (msg:match("^%S+%s+(.+)$"))
    ns.db.ignored[name] = true
    ns.print("ignoring reports from " .. name)
  else
    ns.print("/rarenet: show or hide | db | config | all, tame, zone: filter | alerts | test | diag | ping | peers | members | ignore <Name-Realm>")
  end
end
