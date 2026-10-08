-- Scanner: reads creatures around the player (nameplates, target,
-- mouseover), keeps the layer up to date and reports rares it sees.
local _, ns = ...

local Scan = {}
ns.Scan = Scan

local RARE = { rare = true, rareelite = true }
local REANNOUNCE = 240        -- seconds before an unchanged rare is announced again: with
                              -- jitter and queue it still lands inside the 5 min a lone report lives
local REANNOUNCE_JITTER = 30  -- spread re-announcements of many witnesses
local SWEEP = 2               -- seconds between nameplate sweeps
local lastAnnounce = {}       -- sighting id -> time

local function playerPos()
  local uiMap = C_Map.GetBestMapForUnit("player")
  if not uiMap then return 0, 0, 0 end
  local pos = C_Map.GetPlayerMapPosition(uiMap, "player")
  if not pos then return uiMap, 0, 0 end
  local x, y = pos:GetXY()
  return uiMap, ns.plain(x) or 0, ns.plain(y) or 0
end

function Scan.Unit(unit)
  if not ns.plain(UnitExists(unit)) then return end
  ns.Count("units scanned")
  local okGUID, guid = pcall(UnitGUID, unit)
  local info = okGUID and ns.Layer.ParseGUID(guid)
  if not info then return end
  local controlled = UnitPlayerControlled(unit)
  if ns.issecret(controlled) or controlled then return end
  local now = ns.Now()
  ns.Layer.Observe(info, now)
  ns.Sync.SawNpc(info.npc, now)

  local class = ns.plain(UnitClassification(unit))
  if not RARE[class] and not (ns.Seed and ns.Seed[info.npc]) and not (ns.Undiscovered and ns.Undiscovered[info.npc]) then return end
  local uiMap, x, y = playerPos()
  local family = ns.plain(UnitCreatureFamily(unit))
  local report = {
    npc = info.npc, layer = info.key, uiMap = uiMap, x = x, y = y,
    state = ns.plain(UnitIsDead(unit)) and "D" or "A", time = now,
    name = ns.plain(UnitName(unit)), level = ns.plain(UnitLevel(unit)),
    -- Beasts with a pet family are (almost always) tameable by hunters.
    tame = family ~= nil,
  }
  local entry, changed = ns.Sightings.AddLocal(report)
  if changed then
    lastAnnounce[entry.id] = now
    ns.Net.Announce(entry, report)
  elseif now - (lastAnnounce[entry.id] or 0) > REANNOUNCE then
    lastAnnounce[entry.id] = now
    ns.Net.Announce(entry, report, math.random() * REANNOUNCE_JITTER)
  end
end

local function sweep()
  ns.Count("sweeps")
  if IsInInstance() then return end
  for i = 1, 40 do
    local unit = "nameplate" .. i
    if ns.plain(UnitExists(unit)) then Scan.Unit(unit) end
  end
  Scan.Unit("target")
end

ns.On("NAME_PLATE_UNIT_ADDED", function(unit)
  if not ns.issecret(unit) and not IsInInstance() then Scan.Unit(unit) end
end)
ns.On("PLAYER_TARGET_CHANGED", function()
  if not IsInInstance() then Scan.Unit("target") end
end)
ns.On("UPDATE_MOUSEOVER_UNIT", function()
  if not IsInInstance() then Scan.Unit("mouseover") end
end)

Scan.sweepEvery = SWEEP
Scan.Sweep = sweep

-- Layer prompts --------------------------------------------------------------
-- Without enemy nameplates the scanner only sees what the player targets or
-- mouses over, so ask once to turn them on, and nudge the player whenever
-- the layer is unknown.
local HINT_AFTER = 15         -- seconds in the open world without a layer
local enteredAt, hinted = 0, false

-- Our own small dialog: Blizzard's StaticPopup frames are shared with
-- protected game dialogs, and an addon showing one can get them blocked.
local askFrame
local function askNameplates()
  if not askFrame then
    askFrame = CreateFrame("Frame", "RareNetAskFrame", UIParent, "BackdropTemplate")
    askFrame:SetSize(360, 110)
    askFrame:SetPoint("TOP", UIParent, "TOP", 0, -160)
    askFrame:SetFrameStrata("DIALOG")
    if askFrame.SetBackdrop then
      askFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 } })
      askFrame:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
    end
    local text = askFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOP", 0, -16)
    text:SetWidth(330)
    text:SetText("RareNet sees rares and your layer through enemy nameplates.\nTurn enemy nameplates on?")
    local yes = CreateFrame("Button", nil, askFrame, "UIPanelButtonTemplate")
    yes:SetSize(110, 24)
    yes:SetPoint("BOTTOMRIGHT", askFrame, "BOTTOM", -6, 14)
    yes:SetText(YES or "Yes")
    yes:SetScript("OnClick", function()
      if not InCombatLockdown() then SetCVar("nameplateShowEnemies", "1") end
      askFrame:Hide()
    end)
    local no = CreateFrame("Button", nil, askFrame, "UIPanelButtonTemplate")
    no:SetSize(110, 24)
    no:SetPoint("BOTTOMLEFT", askFrame, "BOTTOM", 6, 14)
    no:SetText(NO or "No")
    no:SetScript("OnClick", function() askFrame:Hide() end)
    Scan.askYes = yes
  end
  askFrame:Show()
end
Scan.AskNameplates = askNameplates

ns.On("PLAYER_ENTERING_WORLD", function()
  -- A loading screen can mean another continent or a different layer.
  ns.Layer.Reset()
  enteredAt, hinted = GetTime(), false
end)

function Scan.CheckPrompts()
  if IsInInstance() or ns.Layer.Current() then return end
  local db = ns.db
  if db and not db.settings.askedNameplates and GetCVar("nameplateShowEnemies") ~= "1" and not InCombatLockdown() then
    db.settings.askedNameplates = true
    askNameplates()
  end
  if not hinted and GetTime() - enteredAt > HINT_AFTER then
    hinted = true
    ns.print("target or mouse over any mob to detect your layer")
  end
end
