-- Rare icons on the minimap: live sightings (kept on the edge, pointing the
-- way, when out of range) and known spawn points within range.
local _, ns = ...

local MinimapPins = {}
ns.MinimapPins = MinimapPins

local MAX_PINS = 40
local UPDATE_EVERY = 0.1
-- Minimap diameter in yards for each zoom level (outdoors and indoors), as
-- used by the default UI and by the common minimap pin libraries.
local DIAMETER_OUT = { [0] = 466.667, 400, 333.333, 266.667, 200, 133.333 }
local DIAMETER_IN = { [0] = 300, 240, 180, 120, 80, 50 }

local pins = {}
local elapsed = 0

-- Offset in minimap pixels of a point dx yards east and dy yards south of the
-- player. With a rotating minimap the world turns so that facing is up.
function MinimapPins.Offset(dx, dy, yardsToPixels, rotate, facing)
  local x, y = dx, -dy                       -- east, north
  if rotate and facing then
    local c, s = math.cos(facing), math.sin(facing)
    x, y = x * c + y * s, -x * s + y * c
  end
  return x * yardsToPixels, y * yardsToPixels
end

local function pinFrame(i)
  local b = pins[i]
  if b then return b end
  b = CreateFrame("Button", nil, Minimap)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(Minimap:GetFrameLevel() + 6)
  b.Disc = b:CreateTexture(nil, "BACKGROUND")
  b.Ring = b:CreateTexture(nil, "BORDER")
  b.Icon = b:CreateTexture(nil, "ARTWORK")
  for _, t in ipairs({ b.Disc, b.Ring, b.Icon }) do t:SetAllPoints() end
  ns.Map.AddPulse(b)
  b:SetScript("OnEnter", function(self)
    local d = self.data
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    local name, level, tame = ns.Database.RareInfo(d.npc)
    GameTooltip:AddLine(name, 1, 0.82, 0)
    if level and level > 0 then GameTooltip:AddLine("Level " .. level, 1, 1, 1) end
    if tame then GameTooltip:AddLine("Tameable", 1, 0.8, 0.1) end
    if d.entry then
      local mine = ns.Layer.IsMine(d.entry.layer)
      GameTooltip:AddLine(string.format("%s on %s, %ds ago", d.entry.state == "D" and "Dead" or "Up",
        mine and "your layer" or ns.Layer.Label(d.entry.layer), ns.Now() - d.entry.time), 0.4, 1, 0.4)
    else
      GameTooltip:AddLine("Known spawn point", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  pins[i] = b
  return b
end

-- Points to show for the player's current zone.
function MinimapPins.Points(uiMap, now)
  local mode = ns.db.settings.minimapPins
  local out = {}
  if mode == "off" or not uiMap then return out end
  for _, e in ipairs(ns.Sightings.Live(now)) do
    if e.uiMap == uiMap then out[#out + 1] = { npc = e.npc, x = e.x, y = e.y, entry = e } end
  end
  if mode == "all" then
    for npc, seed in pairs(ns.Seed) do
      local points = seed[5]
      for i = 1, #points, 3 do
        if points[i] == uiMap then out[#out + 1] = { npc = npc, x = points[i + 1] / 100, y = points[i + 2] / 100 } end
      end
    end
  end
  return out
end

local function hideFrom(n)
  for i = n, #pins do pins[i]:Hide(); pins[i].data = nil; pins[i].pulseColor = nil end
end

function MinimapPins.Update()
  if not ns.db or IsInInstance() then hideFrom(1) return end
  local uiMap = C_Map.GetBestMapForUnit("player")
  local pos = uiMap and C_Map.GetPlayerMapPosition(uiMap, "player")
  if not pos then hideFrom(1) return end
  local w, h = C_Map.GetMapWorldSize(uiMap)   -- not "uiMap and ...": that keeps only w
  if not (w and h and w > 0 and h > 0) then hideFrom(1) return end
  local px, py = pos:GetXY()
  px, py = ns.plain(px), ns.plain(py)
  if not px then hideFrom(1) return end
  local zoom = Minimap:GetZoom() or 0
  local indoors = IsIndoors and IsIndoors()
  local diameter = (indoors and DIAMETER_IN or DIAMETER_OUT)[zoom] or DIAMETER_OUT[0]
  local radiusPx = Minimap:GetWidth() / 2
  local yardsToPixels = radiusPx / (diameter / 2)
  local rotate = GetCVar("rotateMinimap") == "1"
  local facing = rotate and GetPlayerFacing and ns.plain(GetPlayerFacing()) or nil
  local n = 0
  for _, p in ipairs(MinimapPins.Points(uiMap, ns.Now())) do
    if n >= MAX_PINS then break end
    local ox, oy = MinimapPins.Offset((p.x - px) * w, (p.y - py) * h, yardsToPixels, rotate, facing)
    local dist = math.sqrt(ox * ox + oy * oy)
    local limit = radiusPx - 6
    local show = dist <= limit
    local inRange = show
    if not show and p.entry then
      -- Live rares out of range stay on the edge, pointing the way.
      ox, oy = ox / dist * limit, oy / dist * limit
      show = true
    end
    if show then
      n = n + 1
      local b = pinFrame(n)
      b.data = p
      local color, size
      if p.entry then
        color, size = ns.Map.PinStyle({ kind = "live", npc = p.npc, entry = p.entry })
        size = 18
      else
        color = ns.Map.PinStyle({ kind = "seed", npc = p.npc })
        size = 14
      end
      if b.color ~= color then            -- re-dress only when the kind changes
        ns.Map.Dress(b, color, false)
        b.color = color
      end
      b:SetSize(size, size)
      -- Waves only inside the minimap: on its edge they would spill outside.
      local pulse = inRange and ns.Map.Pulses(p.entry) and color or false
      if b.pulseColor ~= pulse then
        ns.Map.SetPulse(b, pulse, size * 0.6)
        b.pulseColor = pulse
      end
      b:SetFrameLevel(Minimap:GetFrameLevel() + (p.entry and 8 or 6))
      b:SetAlpha(p.entry and 1 or (ns.db.settings.minimapPinAlpha or 1))
      b:ClearAllPoints()
      b:SetPoint("CENTER", Minimap, "CENTER", ox, oy)
      b:Show()
    end
  end
  hideFrom(n + 1)
end

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, dt)
  elapsed = elapsed + dt
  if elapsed < UPDATE_EVERY then return end
  elapsed = 0
  ns.Safe("minimap pins", MinimapPins.Update)
end)

function MinimapPins.Count()
  local n = 0
  for _, b in ipairs(pins) do if b.data and b:IsShown() then n = n + 1 end end
  return n
end
