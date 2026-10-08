-- Settings window: alerts, map, list and maintenance, laid out top to bottom.
local _, ns = ...

local Options = {}
ns.Options = Options

local WIDTH = 320
local frame, status
local refreshers = {}
local y                        -- layout cursor while building

local function refreshAll()
  for _, fn in ipairs(refreshers) do fn() end
end

local function heading(label)
  y = y - 10
  local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("TOPLEFT", 16, y)
  fs:SetText(label)
  y = y - 20
end

local function check(label, get, set)
  local cb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", 14, y)
  cb:SetSize(24, 24)
  local text = cb.Text or cb.text
  if type(text) == "table" and text.SetText then text:SetText(label) end
  cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
  refreshers[#refreshers + 1] = function() cb:SetChecked(get()) end
  y = y - 24
end

local function button(label, x, width, onClick)
  local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetPoint("TOPLEFT", x, y)
  b:SetText(label)
  b:SetScript("OnClick", function()
    onClick(b)
    refreshAll()
  end)
  return b
end

-- A row of buttons acting as a radio group over one setting.
local function choice(label, key, values, after)
  local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", 20, y)
  fs:SetText(label)
  y = y - 14
  local width = math.floor((WIDTH - 40) / #values) - 4
  local buttons = {}
  for i, v in ipairs(values) do
    local b = button(v[2], 16 + (i - 1) * (width + 4), width, function()
      ns.db.settings[key] = v[1]
      if after then after() end
    end)
    buttons[#buttons + 1] = { b = b, value = v[1] }
  end
  refreshers[#refreshers + 1] = function()
    for _, x in ipairs(buttons) do
      local text = x.b:GetFontString()
      if text then
        if ns.db.settings[key] == x.value then text:SetTextColor(0.2, 1, 0.2) else text:SetTextColor(1, 0.82, 0) end
      end
    end
  end
  y = y - 26
end

local function refreshMap() ns.Safe("map refresh", ns.Map.Refresh) end

local function build()
  frame = CreateFrame("Frame", "RareNetOptions", UIParent, "BackdropTemplate")
  frame:SetWidth(WIDTH)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  if frame.SetBackdrop then
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    frame:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
  end
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -12)
  title:SetText("RareNet")
  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("TOP", 0, -34)
  y = -50

  local s = function() return ns.db.settings end

  heading("Alerts")
  check("Rares you find", function() return s().localAlerts end, function(v) s().localAlerts = v end)
  check("Rares other players report", function() return s().alerts end, function(v) s().alerts = v end)
  check("Big text at the top of the screen", function() return s().banner end, function(v) s().banner = v end)
  check("Waypoint to the rare", function() return s().autoWaypoint end, function(v) s().autoWaypoint = v end)
  y = y - 4
  local soundButton = button("", 16, 170, function()
    s().alertSound = ns.Alert.NextSound(s().alertSound)
    ns.Alert.PlaySound()
  end)
  refreshers[#refreshers + 1] = function() soundButton:SetText("Sound: " .. ns.Alert.SoundLabel(s().alertSound)) end
  button("Play", 190, 52, function() ns.Alert.PlaySound() end)
  button("Test", 246, 58, function() ns.Alert.Test() end)
  y = y - 28
  choice("Sound channel", "soundChannel", { { "Master", "Master" }, { "SFX", "Effects" } })
  choice("Text size", "bannerSize", { { "small", "Small" }, { "medium", "Medium" }, { "large", "Large" } })

  heading("Map and list")
  check("Live sightings on the world map", function() return s().livePins end, function(v) s().livePins = v; refreshMap() end)
  check("Minimap button", function() return not s().minimapHide end, function(v) s().minimapHide = not v; ns.MinimapButton.Update() end)
  check("Show the rare list", function() return ns.UI.IsShown() end, function(v) ns.UI.Toggle(v) end)
  choice("Known spawns on the map", "pins", { { "all", "All" }, { "tame", "Tameable" }, { "off", "Off" } }, refreshMap)
  choice("Spawn points per rare", "spawnPins", { { "one", "One pin" }, { "all", "All points" } }, refreshMap)
  local OPACITY = { { 0.4, "40%" }, { 0.6, "60%" }, { 0.8, "80%" }, { 1, "100%" } }
  choice("Map icon opacity (live rares stay full)", "pinAlpha", OPACITY, refreshMap)
  choice("Minimap icons", "minimapPins", { { "all", "All" }, { "live", "Live only" }, { "off", "Off" } })
  choice("Minimap icon opacity", "minimapPinAlpha", OPACITY)
  choice("Rare list shows", "filter", { { "all", "All" }, { "tame", "Tameable" }, { "zone", "My zone" } })

  heading("Tools")
  button("Clear sightings", 16, 140, function() ns.Sightings.Clear(); refreshMap() end)
  button("Clear ignore list", 160, 140, function() wipe(ns.db.ignored) end)
  y = y - 26
  button("Players online", 16, 140, function() SlashCmdList.RARENET("peers") end)
  button("Test network", 160, 140, function() ns.Net.Ping() end)
  y = y - 26
  button("Reset positions", 16, 140, function() ns.UI.ResetPosition(); frame:ClearAllPoints(); frame:SetPoint("CENTER") end)
  button("Diagnostics", 160, 140, function() SlashCmdList.RARENET("diag") end)
  y = y - 34

  local note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", 16, y)
  note:SetWidth(WIDTH - 32)
  note:SetJustifyH("LEFT")
  note:SetText("Map pins: white known spawn, gold tameable, blue new in Forever, purple found by RareNet players, radar waves: rare up right now (green your layer, orange another layer, white layer not known yet). Click a pin to keep its spawn points shown, right click for a waypoint.")
  frame:SetHeight(-y + 50)

  local elapsed = 0
  frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 1 then return end
    elapsed = 0
    Options.UpdateStatus()
  end)
  frame:SetScript("OnShow", function()
    refreshAll()
    Options.UpdateStatus()
  end)
  tinsert(UISpecialFrames, "RareNetOptions")   -- Esc closes it
  frame:Hide()
end

function Options.UpdateStatus()
  if not status then return end
  local cur = ns.Layer.Current()
  local known = 0
  for _ in pairs(ns.db.discovered or {}) do known = known + 1 end
  local online = ns.Net.Online()
  status:SetText(string.format("layer %s  |  net %s  |  %s online  |  %d discovered",
    cur and ns.Layer.Label(cur.key) or "?", ns.Net.status.transport, online and tostring(online) or "?", known))
end

function Options.Toggle()
  if not frame then return end
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

table.insert(ns.onLoad, function()
  ns.Safe("options", build)
  -- No entry in the game's Settings panel: registering one at load time
  -- changes when the chat frames get configured and broke another addon's
  -- chat hooks. The minimap button and /rarenet config open this window.
end)
