-- Alerts: a sound of the player's choice, a big banner at the top of the
-- screen and an optional waypoint to the rare.
local _, ns = ...

local Alert = {}
ns.Alert = Alert

local MEDIA = "Interface\\AddOns\\RareNet\\Media\\"
local FADE = 1.5                 -- seconds the banner takes to fade out

-- RareNet's own sounds first (made for RareNet, see tools/sounds.py), then
-- game sounds as alternatives.
Alert.SOUNDS = {
  { key = "sonar", label = "RareNet sonar", file = MEDIA .. "sonar.ogg" },
  { key = "chime", label = "RareNet chime", file = MEDIA .. "chime.ogg" },
  { key = "horn", label = "RareNet horn", file = MEDIA .. "horn.ogg" },
  { key = "raidwarning", label = "Raid warning", kit = "RAID_WARNING", id = 8959 },
  { key = "readycheck", label = "Ready check", kit = "READY_CHECK", id = 8960 },
  { key = "alarm", label = "Alarm clock", kit = "ALARM_CLOCK_WARNING_3", id = 12889 },
  { key = "none", label = "No sound" },
}

Alert.SIZES = { small = 0.8, medium = 1.0, large = 1.35 }

local function soundByKey(key)
  for _, s in ipairs(Alert.SOUNDS) do if s.key == key then return s end end
  return Alert.SOUNDS[1]
end

function Alert.SoundLabel(key) return soundByKey(key).label end

-- Next sound in the list, for the settings button that cycles through them.
function Alert.NextSound(key)
  for i, s in ipairs(Alert.SOUNDS) do
    if s.key == key then return Alert.SOUNDS[i % #Alert.SOUNDS + 1].key end
  end
  return Alert.SOUNDS[1].key
end

function Alert.PlaySound(key)
  local s = soundByKey(key or ns.db.settings.alertSound)
  local channel = ns.db.settings.soundChannel or "Master"
  if s.file then
    local ok, willPlay = pcall(PlaySoundFile, s.file, channel)
    if ok and willPlay then return true end
    -- A file the client cannot play (e.g. added while the game was running):
    -- fall back to the raid warning sound.
    s = soundByKey("raidwarning")
  end
  if s.kit or s.id then
    local id = (SOUNDKIT and SOUNDKIT[s.kit]) or s.id
    return pcall(PlaySound, id, channel)
  end
  return false
end

-- Banner -----------------------------------------------------------------------

local banner

local function buildBanner()
  banner = CreateFrame("Frame", "RareNetBanner", UIParent)
  banner:SetSize(900, 90)
  banner:SetPoint("TOP", UIParent, "TOP", 0, -110)
  banner:SetFrameStrata("HIGH")
  banner:EnableMouse(false)
  banner.icon = banner:CreateTexture(nil, "OVERLAY")
  banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  banner.title:SetPoint("TOP", 0, 0)
  banner.sub = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  banner.sub:SetPoint("TOP", banner.title, "BOTTOM", 0, -6)
  banner.icon:SetPoint("RIGHT", banner.title, "LEFT", -10, 0)
  banner:Hide()
  banner:SetScript("OnUpdate", function(self, elapsed)
    self.t = self.t + elapsed
    if self.t > self.hold + FADE then
      self:Hide()
    elseif self.t > self.hold then
      self:SetAlpha(1 - (self.t - self.hold) / FADE)
    end
  end)
end

function Alert.Banner(title, sub, color)
  if not banner then buildBanner() end
  local scale = Alert.SIZES[ns.db.settings.bannerSize] or 1
  local font = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
  banner.title:SetFont(font, math.floor(34 * scale), "THICKOUTLINE")
  banner.sub:SetFont(font, math.floor(17 * scale), "OUTLINE")
  banner.title:SetText(title)
  banner.title:SetTextColor(color[1], color[2], color[3])
  banner.sub:SetText(sub)
  local size = math.floor(38 * scale)
  banner.icon:SetSize(size, size)
  if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("VignetteKill") then
    banner.icon:SetAtlas("VignetteKill")
  else
    banner.icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
  end
  banner.t, banner.hold = 0, ns.db.settings.bannerHold or 5
  banner:SetAlpha(1)
  banner:Show()
end

-- Alert ------------------------------------------------------------------------

local function zoneName(uiMap)
  local info = uiMap and uiMap > 0 and C_Map.GetMapInfo(uiMap)
  return info and info.name or "?"
end

local function waypoint(e)
  if not (e.uiMap and e.uiMap > 0 and C_Map.CanSetUserWaypointOnMap(e.uiMap)) then return end
  C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(e.uiMap, e.x or 0, e.y or 0))
  C_SuperTrack.SetSuperTrackedUserWaypoint(true)
end

-- kind is "local" (this client spotted it) or "remote" (another player did).
-- Loud alerts (sound, banner, waypoint) are for rares near you or reported on
-- your layer; everything else is a chat line.
function Alert.Show(e, kind, loud, isTest)
  local s = ns.db.settings
  local where
  if kind == "discovery" then
    where = "First discovery! Nobody had found it yet"
  elseif kind == "local" then
    where = "Rare nearby"
  else
    local mine = ns.Layer.IsMine(e.layer)
    where = mine and "Up on your layer" or ("Up on " .. ns.Layer.Label(e.layer))
  end
  local sub = string.format("%s  -  %s %.0f, %.0f%s", where, zoneName(e.uiMap), (e.x or 0) * 100, (e.y or 0) * 100,
    e.tame and "  -  tameable" or "")
  local who = kind == "remote" and ns.Sightings.Reporters and ns.Sightings.Reporters(e, true)
  ns.print(e.name .. ": " .. sub .. (who and ("  -  " .. who) or ""))
  if not loud then return end
  Alert.PlaySound()
  if s.banner then
    local color = kind == "discovery" and { 0.7, 0.45, 1 } or (kind == "local" and { 1, 0.82, 0.1 } or { 0.3, 1, 0.3 })
    Alert.Banner(e.name, sub, color)
  end
  if s.autoWaypoint and not isTest then waypoint(e) end
end

function Alert.Test()
  Alert.Show({ name = "Taskmaster Whipfang", layer = "0-0-0", uiMap = C_Map.GetBestMapForUnit("player") or 0,
    x = 0.5, y = 0.5, tame = true }, "local", true, true)
end
