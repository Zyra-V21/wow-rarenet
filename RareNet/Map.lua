-- World map: pins for known rare spawns (seed data), rares discovered by the
-- network, and live sightings; hovering a pin shows a tooltip and a rotating
-- 3D preview of the rare.
local _, ns = ...

local Map = {}
ns.Map = Map

local TEMPLATE = "RareNetPinTemplate"
local MERGE = 2.5                 -- map percent; closer discovered points collapse
local ZONE_TYPE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3


-- Coordinates of a point of fromMap on toMap (0..1), or nil when toMap does
-- not contain fromMap (e.g. a zone of another continent).
local function translate(fromMap, x, y, toMap)
  if fromMap == toMap then return x, y end
  local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(fromMap, toMap)
  if not minX or maxX == minX then return nil end
  return minX + x * (maxX - minX), minY + y * (maxY - minY)
end
Map.Translate = translate

-- One rare, one map: either a pin per spawn point ("all"), or one pin on the
-- most central point plus faint dots on the others ("one"), which light up
-- while the pin is hovered.
local function addPoints(out, kind, npc, points, mapID, mode)
  local here = {}
  for i = 1, #points, 3 do
    if points[i] == mapID then here[#here + 1] = { points[i + 1] / 100, points[i + 2] / 100 } end
  end
  if #here == 0 then return end
  if mode == "all" or #here == 1 then
    for _, p in ipairs(here) do
      out[#out + 1] = { kind = kind, npc = npc, uiMap = mapID, x = p[1], y = p[2], spawns = #here }
    end
    return
  end
  local best, bestSum
  for i, a in ipairs(here) do
    local sum = 0
    for _, b in ipairs(here) do sum = sum + (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 end
    if not bestSum or sum < bestSum then best, bestSum = i, sum end
  end
  out[#out + 1] = { kind = kind, npc = npc, uiMap = mapID, x = here[best][1], y = here[best][2], spawns = #here, dots = true }
  for i, p in ipairs(here) do
    if i ~= best then out[#out + 1] = { kind = "dot", npc = npc, uiMap = mapID, x = p[1], y = p[2] } end
  end
end

-- Every pin to draw on one map.
function Map.PinsFor(mapID, now)
  local s = ns.db.settings
  local out = {}
  local info = C_Map.GetMapInfo(mapID)
  -- Known spawns only on zone maps: on a continent they would be a carpet.
  if s.pins ~= "off" and info and info.mapType == ZONE_TYPE then
    local mode = s.spawnPins
    for npc, seed in pairs(ns.Seed) do
      if s.pins ~= "tame" or seed[3] > 0 then addPoints(out, "seed", npc, seed[5], mapID, mode) end
    end
    for npc, d in pairs(ns.db.discovered) do
      if s.pins ~= "tame" or d.tame then addPoints(out, "discovered", npc, d.points, mapID, mode) end
    end
  end
  if s.livePins then
    for _, e in ipairs(ns.Sightings.Live(now)) do
      local x, y = translate(e.uiMap, e.x, e.y, mapID)
      if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
        out[#out + 1] = { kind = "live", npc = e.npc, entry = e, uiMap = e.uiMap, x = x, y = y, zoneX = e.x, zoneY = e.y }
      end
    end
  end
  return out
end

-- Community database: rares missing from the seed (new Forever content),
-- learned from our own sightings and from confirmed reports.
local DISCOVERED_MAX = 500
local DISCOVERED_EXPIRE = 30 * 24 * 3600

-- Persist only rares seen by this client, vouched by two first-hand
-- witnesses, or already vetted by gossip from two players.
function Map.Learn(e)
  if ns.Seed[e.npc] or not e.uiMap or e.uiMap == 0 then return end
  if not (e.mine or e.gossip or (e.firstHandCount or 0) >= 2) then return end
  local d = ns.db.discovered[e.npc]
  if not d then
    local n = 0
    for _ in pairs(ns.db.discovered) do n = n + 1 end
    if n >= DISCOVERED_MAX then return end
    d = { name = e.name, level = e.level, tame = e.tame, points = {} }
    ns.db.discovered[e.npc] = d
    ns.Log("discovered new rare " .. e.npc .. " " .. tostring(e.name))
  end
  d.seen = ns.Now()
  if e.name and e.name:sub(1, 1) ~= "#" then d.name = e.name end
  d.tame = d.tame or e.tame
  local x, y = e.x * 100, e.y * 100
  for i = 1, #d.points, 3 do
    if d.points[i] == e.uiMap and (d.points[i + 1] - x) ^ 2 + (d.points[i + 2] - y) ^ 2 <= MERGE ^ 2 then return end
  end
  local p = d.points
  p[#p + 1], p[#p + 2], p[#p + 3] = e.uiMap, math.floor(x * 10 + 0.5) / 10, math.floor(y * 10 + 0.5) / 10
end

local function nameOf(npc)
  local seed = ns.Seed[npc]
  if seed then return seed[1], seed[2], seed[3] > 0, seed[4] end
  local d = ns.db.discovered[npc]
  if d then return d.name or ("#" .. npc), d.level, d.tame, 0 end
  return "#" .. npc
end

-- Preview -------------------------------------------------------------------

local preview
local function buildPreview()
  preview = CreateFrame("Frame", "RareNetPreview", UIParent, "BackdropTemplate")
  preview:SetSize(170, 170)
  preview:SetFrameStrata("TOOLTIP")
  if preview.SetBackdrop then
    preview:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    preview:SetBackdropColor(0.05, 0.05, 0.08, 0.92)
  end
  preview.model = CreateFrame("PlayerModel", nil, preview)
  preview.model:SetPoint("TOPLEFT", 4, -4)
  preview.model:SetPoint("BOTTOMRIGHT", -4, 4)
  preview.facing = 0
  preview:SetScript("OnUpdate", function(self, elapsed)
    self.facing = self.facing + elapsed * 0.8
    self.model:SetFacing(self.facing)
  end)
  preview:Hide()
end

-- 3D models of rares. The first model set right after its frame is shown
-- often stays black, and a creature the client has not cached yet draws
-- nothing until it arrives: set it again once a frame later, and a few more
-- times while no model file is loaded.
local MODEL_RETRIES = { 0.6, 1.5, 3 }

local function applyModel(m)
  m:ClearModel()
  local ok = m.display and m.display > 0 and pcall(m.SetDisplayInfo, m, m.display)
  if not ok then pcall(m.SetCreature, m, m.npc) end
  pcall(m.SetCamDistanceScale, m, m.scale or 1)
end

local function hasModel(m)
  local ok, id = pcall(m.GetModelFileID, m)
  return ok and id ~= nil and id ~= 0
end

function Map.ShowModel(m, npc, display, scale)
  if m.npc == npc and m:IsVisible() then return end   -- already showing it
  m.npc, m.display, m.scale = npc, display, scale
  applyModel(m)
  local function still() return m.npc == npc and m:IsVisible() end
  C_Timer.After(0.1, function() if still() then applyModel(m) end end)
  for _, delay in ipairs(MODEL_RETRIES) do
    C_Timer.After(delay, function() if still() and not hasModel(m) then applyModel(m) end end)
  end
end

function Map.ClearModel(m)
  m.npc = nil
  m:ClearModel()
end

function Map.ShowPreview(npc, anchor)
  if not preview then buildPreview() end
  local _, _, _, display = nameOf(npc)
  preview:ClearAllPoints()
  preview:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  preview:Show()
  local m = preview.model
  -- Display IDs do not need the creature cache; the NPC id is the fallback.
  Map.ShowModel(m, npc, display, 1.3)
  pcall(m.SetPortraitZoom, m, 0)
end

function Map.HidePreview()
  if preview then
    Map.ClearModel(preview.model)
    preview:Hide()
  end
end

-- Pins ----------------------------------------------------------------------

-- Pins are three layers drawn for RareNet (tools/pins.py): a dark disc for
-- contrast, a ring coloured by kind, and a white skull.
local MEDIA = "Interface\\AddOns\\RareNet\\Media\\"
Map.DISC, Map.RING, Map.SKULL, Map.DOT = MEDIA .. "pin_disc", MEDIA .. "pin_ring", MEDIA .. "pin_skull", MEDIA .. "pin_dot"

local COLORS = {
  seed = { 0.9, 0.9, 0.9 }, tame = { 1, 0.8, 0.1 }, discovered = { 0.7, 0.4, 1 }, new = { 0.55, 0.8, 1 },
  mine = { 0.2, 1, 0.2 }, other = { 1, 0.45, 0.1 }, unknown = { 1, 1, 1 },
}
Map.COLORS = COLORS

-- Colour and size of a pin.
function Map.PinStyle(data)
  local _, _, tame = nameOf(data.npc)
  local base = tame and COLORS.tame or (ns.SeedSource[data.npc] and COLORS.new or COLORS.seed)
  if data.kind == "dot" then return base, 11 end
  if data.kind == "live" then
    local mine = ns.Layer.IsMine(data.entry.layer)
    return mine == true and COLORS.mine or (mine == false and COLORS.other or COLORS.unknown), 24
  end
  if data.kind == "discovered" then return tame and COLORS.tame or COLORS.discovered, 20 end
  return base, 18
end

-- Dress a frame holding Disc, Ring and Icon textures as a pin: a skull in a
-- coloured ring, or for a spawn dot a coloured dot on the dark disc.
function Map.Dress(frame, color, dot)
  frame.Disc:SetTexture(Map.DISC)
  frame.Ring:SetTexture(Map.RING)
  frame.Ring:SetVertexColor(color[1], color[2], color[3])
  frame.Ring:SetShown(not dot)
  frame.Icon:SetTexture(dot and Map.DOT or Map.SKULL)
  if dot then frame.Icon:SetVertexColor(color[1], color[2], color[3]) else frame.Icon:SetVertexColor(1, 1, 1) end
end

-- Live sightings send out radar waves: two thin rings that grow and fade
-- one after the other, then a short pause. Discreet, but they catch the eye
-- among the known spawns.
local WAVE_TIME, WAVE_GAP, WAVE_REACH = 2, 0.8, 4.5   -- reach: final size in pin sizes
Map.WAVE = MEDIA .. "pin_wave"

local function addWave(frame, delay)
  local t = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
  t:SetTexture(Map.WAVE)
  t:SetPoint("CENTER")
  t:SetAlpha(0)
  local group = t:CreateAnimationGroup()
  group:SetLooping("REPEAT")
  -- The texture is sized to the end of the wave and grows from the pin, so
  -- the ring keeps its full thickness where it is easiest to see.
  local grow = group:CreateAnimation("Scale")
  local from = 1 / WAVE_REACH
  if grow.SetScaleFrom then grow:SetScaleFrom(from, from); grow:SetScaleTo(1, 1) else grow:SetScale(1, 1) end
  if grow.SetSmoothing then grow:SetSmoothing("OUT") end
  local fade = group:CreateAnimation("Alpha")
  fade:SetFromAlpha(1)
  fade:SetToAlpha(0)
  if fade.SetSmoothing then fade:SetSmoothing("IN") end   -- stays bright, fades at the end
  for _, a in ipairs({ grow, fade }) do
    a:SetDuration(WAVE_TIME)
    a:SetStartDelay(delay)
    a:SetEndDelay(WAVE_GAP - delay)
  end
  return { tex = t, anim = group }
end

-- Only a rare that is up right now sends waves: not corpses, not sightings
-- from before logout that still wait to be checked.
function Map.Pulses(e)
  return e ~= nil and e.state ~= "D" and not e.cached
end

function Map.AddPulse(frame)
  frame.Waves = { addWave(frame, 0), addWave(frame, WAVE_GAP) }
end

function Map.SetPulse(frame, color, size)
  if not frame.Waves then return end
  for _, w in ipairs(frame.Waves) do
    if color then
      w.tex:SetVertexColor(color[1], color[2], color[3])
      w.tex:SetSize(size * WAVE_REACH, size * WAVE_REACH)
      w.tex:Show()
      if not w.anim:IsPlaying() then w.anim:Play() end
    else
      w.anim:Stop()
      w.tex:Hide()
    end
  end
end

local selected                    -- rare whose spawn points stay lit (click)

RareNetPinMixin = CreateFromMixins(MapCanvasPinMixin)

function RareNetPinMixin:OnLoad()
  self:SetScalingLimits(1, 1.0, 1.4)
  self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
  Map.AddPulse(self)
end

-- These call protected setters; an addon pin running them in combat taints
-- the world map (same workaround as HereBeDragons-Pins).
function RareNetPinMixin:SetPassThroughButtons() end
function RareNetPinMixin:CheckMouseButtonPassthrough() end

local DOT_ALPHA, DOT_LIT_ALPHA, DOT_LIT_SIZE = 0.65, 1, 14
local SELECTED_SCALE = 1.25

-- Size and alpha of a pin from its kind, hover and selection.
-- Known spawns follow the opacity setting; live sightings and the rare
-- being hovered or selected are always drawn in full.
local function look(pin, lit)
  local d = pin.data
  if not d then return end
  local fade = ns.db.settings.pinAlpha or 1
  if d.kind == "dot" then
    pin:SetAlpha(lit and DOT_LIT_ALPHA or DOT_ALPHA * fade)
    local size = lit and DOT_LIT_SIZE or pin.baseSize
    pin:SetSize(size, size)
  else
    local chosen = d.npc == selected
    pin:SetAlpha((lit or chosen or d.kind == "live") and 1 or fade)
    local size = chosen and pin.baseSize * SELECTED_SCALE or pin.baseSize
    pin:SetSize(size, size)
  end
end

function RareNetPinMixin:OnAcquired(data)
  self.data = data
  local live = data.kind == "live"
  -- Live sightings draw above every known spawn (SetPosition applies it).
  self:UseFrameLevelType(live and "PIN_FRAME_LEVEL_VIGNETTE" or "PIN_FRAME_LEVEL_AREA_POI")
  self:SetPosition(data.x, data.y)
  local color, size = Map.PinStyle(data)
  Map.SetPulse(self, Map.Pulses(data.entry) and color, size)
  self.baseSize = size
  local dot = data.kind == "dot"
  Map.Dress(self, color, dot)
  -- Dots are only there to be seen: they never take the mouse from pins below.
  self:SetMouseClickEnabled(not dot)
  self:SetMouseMotionEnabled(not dot)
  self:SetAlpha(1)
  look(self, data.npc == selected)
end

-- Light up (or dim again) the other spawn points of a rare. A selected rare
-- stays lit whatever the mouse does.
function Map.HighlightSpawns(map, npc, on)
  if not (map and map.EnumeratePinsByTemplate) then return end
  for pin in map:EnumeratePinsByTemplate(TEMPLATE) do
    local d = pin.data
    if d and d.npc == npc then look(pin, on or npc == selected) end
  end
end

-- Click on a rare: keep its spawn points shown; click it again (or another
-- rare) to change that.
function Map.Select(map, npc)
  local previous = selected
  selected = (selected ~= npc) and npc or nil
  if previous then Map.HighlightSpawns(map, previous, false) end
  if selected then Map.HighlightSpawns(map, selected, true) end
  return selected
end

function Map.Selected() return selected end

function RareNetPinMixin:OnMouseEnter()
  local d = self.data
  local name, level, tame = nameOf(d.npc)
  local tip = GameTooltip
  tip:SetOwner(self, "ANCHOR_RIGHT")
  tip:AddLine(name, 1, 0.82, 0)
  if level and level > 0 then tip:AddLine("Level " .. level, 1, 1, 1) end
  if tame then tip:AddLine("Tameable", 1, 0.8, 0.1) end
  local hopHint
  if d.kind == "live" then
    local e = d.entry
    local mine = ns.Layer.IsMine(e.layer)
    tip:AddLine(string.format("%s on %s, %ds ago", e.state == "D" and "Dead" or "Up",
      mine and "your layer" or ns.Layer.Label(e.layer), ns.Now() - e.time), mine and 0.2 or 1, 1, mine and 0.2 or 0.6)
    if not e.confirmed then tip:AddLine("Unconfirmed report", 0.6, 0.6, 0.6) end
    local who = ns.Sightings.Reporters(e)
    if who then tip:AddLine((who:gsub("^%l", string.upper)), 0.7, 0.7, 0.7) end
    hopHint = ns.Hop.Hint(e)
  elseif d.kind == "discovered" then
    tip:AddLine("Discovered by RareNet players", 0.7, 0.4, 1)
  elseif (d.spawns or 1) > 1 and ns.db.settings.spawnPins ~= "all" then
    tip:AddLine(d.spawns .. " spawn points", 0.7, 0.7, 0.7)
  elseif (d.spawns or 1) > 1 then
    tip:AddLine("One of " .. d.spawns .. " spawn points", 0.7, 0.7, 0.7)
  else
    tip:AddLine("Known spawn point", 0.7, 0.7, 0.7)
  end
  -- Respawn timer after a death: on that layer for a live pin, else the
  -- player's layer (or the newest death).
  local live = d.kind == "live" and d.entry or nil
  if not live or live.state == "D" then
    local respawn = ns.Database.RespawnStatus(d.npc, ns.Now(), live and live.layer or nil)
    if respawn then tip:AddLine(respawn, 1, 0.47, 0.27) end
  end
  local pin = self
  local loot = ns.Database.TopLoot(d.npc, 3, function()
    -- Item names arrive later: redraw while the tooltip is still ours.
    if GameTooltip:IsOwned(pin) then pin:OnMouseEnter() end
  end)
  if #loot > 0 then
    tip:AddLine("Drops:", 1, 0.82, 0)
    for _, l in ipairs(loot) do
      local r, g, b = ns.Database.QualityColor(l.quality)
      tip:AddLine("  " .. l.text, r, g, b)
    end
  end
  if d.dots then
    tip:AddLine(d.npc == selected and "Click: hide spawn points" or "Click: keep spawn points shown", 0.5, 0.5, 0.5)
  end
  if hopHint and hopHint:find("^Right%-click") then
    tip:AddLine(hopHint, 0.5, 0.5, 0.5)
  else
    if hopHint then tip:AddLine(hopHint, 0.5, 0.5, 0.5) end
    tip:AddLine("Right-click: waypoint", 0.5, 0.5, 0.5)
  end
  tip:AddLine("Shift-click: details and loot", 0.5, 0.5, 0.5)
  tip:Show()
  Map.ShowPreview(d.npc, tip)
  Map.HighlightSpawns(self.GetMap and self:GetMap(), d.npc, true)
end

function RareNetPinMixin:OnMouseLeave()
  GameTooltip:Hide()
  Map.HidePreview()
  if self.data then Map.HighlightSpawns(self.GetMap and self:GetMap(), self.data.npc, false) end
end

local function waypointTo(d)
  local uiMap, x, y = d.uiMap, d.zoneX or d.x, d.zoneY or d.y
  if uiMap and C_Map.CanSetUserWaypointOnMap(uiMap) then
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMap, x, y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
  end
end

-- Called by the map canvas on a click inside the pin.
-- Left: select (keep spawn points shown). Shift-left: details. Right: hop to
-- a live rare on another layer, otherwise waypoint.
function RareNetPinMixin:OnMouseClickAction(button)
  local d = self.data
  if button == "LeftButton" and IsShiftKeyDown() then
    ns.Database.Open(d.npc)
  elseif button == "LeftButton" then
    Map.Select(self.GetMap and self:GetMap(), d.npc)
    if GameTooltip:IsOwned(self) then self:OnMouseEnter() end
  elseif button == "RightButton" then
    if not (d.kind == "live" and ns.Hop.Provider() and ns.Hop.To(d.entry)) then waypointTo(d) end
  end
end

-- Data provider ---------------------------------------------------------------

local provider = CreateFromMixins(MapCanvasDataProviderMixin)

function provider:RemoveAllData()
  self:GetMap():RemoveAllPinsByTemplate(TEMPLATE)
end

function provider:RefreshAllData()
  self:RemoveAllData()
  local map = self:GetMap()
  local mapID = map:GetMapID()
  if not mapID then return end
  -- A selection belongs to the map it was made on.
  if mapID ~= self.lastMapID then selected = nil end
  self.lastMapID = mapID
  for _, data in ipairs(Map.PinsFor(mapID, ns.Now())) do
    map:AcquirePin(TEMPLATE, data)
  end
end

Map.provider = provider

function Map.Refresh()
  if provider:GetMap() and WorldMapFrame and WorldMapFrame:IsShown() then provider:RefreshAllData() end
end

local installed = false
local function install()
  if installed or not WorldMapFrame then return end
  installed = true
  WorldMapFrame:AddDataProvider(provider)
end

ns.On("PLAYER_LOGIN", function() ns.Safe("map install", install) end)
ns.On("ADDON_LOADED", function(name)
  if name == "Blizzard_WorldMap" then ns.Safe("map install", install) end
end)

-- Sightings expire without an update: redraw the open map when the set of
-- live sightings changed.
local drawnLive = -1
C_Timer.NewTicker(5, function()
  if not (WorldMapFrame and WorldMapFrame:IsShown() and ns.db) then return end
  local n = #ns.Sightings.Live(ns.Now())
  if n ~= drawnLive then
    drawnLive = n
    ns.Safe("map refresh", Map.Refresh)
  end
end)

-- New or changed sightings: learn new rares, redraw at most once a second.
local refreshPending = false
ns.Sightings.OnUpdate(function(e)
  if ns.db then Map.Learn(e) end
  if refreshPending then return end
  refreshPending = true
  C_Timer.After(1, function()
    refreshPending = false
    ns.Safe("map refresh", Map.Refresh)
  end)
end)

table.insert(ns.onLoad, function(db)
  db.discovered = db.discovered or {}
  local now = ns.Now()
  for npc, d in pairs(db.discovered) do
    d.seen = d.seen or now
    if now - d.seen > DISCOVERED_EXPIRE then db.discovered[npc] = nil end
  end
end)
