-- Rare database: every rare RareNet knows, with search and filters, a 3D
-- preview, spawn points, live status, what it drops and how to fight it. Built on the game's
-- own panel, search box and dropdown templates so it looks like the rest of
-- the UI. Opened from the minimap menu, /rarenet db, or shift-click on a map
-- pin or on the live list.
local _, ns = ...

local Database = {}
ns.Database = Database

local ROWS, ROW_H = 13, 34
local LOOT_ROWS, LOOT_H = 11, 24
local ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"
local TAME_ICON = "Interface\\Icons\\Ability_Hunter_BeastTaming"
local QUALITY = {                -- fallback colours when the client has none
  [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 },
  [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 },
}

local frame
local selected                   -- npc id
local detailMap                  -- zone the detail pane talks about
local scroll = 0
local view = "drops"             -- what the lower half shows: "drops" or "fight"
local pendingItems = {}          -- cancel callbacks of item and spell loads in flight
local list = {}                  -- filtered and sorted npc ids
local filter = {                 -- current search and filters
  text = "", zone = nil, tame = false, new = false, loot = false, live = false, level = false, undiscovered = false,
  sort = "level",
}

-- Data ------------------------------------------------------------------------------

local function zoneName(uiMap)
  if not uiMap then return "Location unknown" end
  local info = C_Map.GetMapInfo(uiMap)
  return info and info.name or ("Map " .. tostring(uiMap))
end

local function continentOf(uiMap)
  local info = uiMap and C_Map.GetMapInfo(uiMap)
  local parent = info and info.parentMapID and C_Map.GetMapInfo(info.parentMapID)
  return parent and parent.name or "Other"
end

local function rareInfo(npc)
  local seed = ns.Seed[npc]
  if seed then return seed[1], seed[2], seed[3] > 0, seed[4], seed[5] end
  local d = ns.db.discovered and ns.db.discovered[npc]
  if d then return d.name or ("#" .. npc), d.level, d.tame, 0, d.points end
  local u = ns.Undiscovered and ns.Undiscovered[npc]
  if u then return u[1], nil, false, 0, {} end
  return "#" .. npc, nil, false, 0, {}
end

-- Long names drop to a smaller font instead of being cut.
local function fitName(fs)
  fs:SetFontObject("GameFontNormalHuge")
  local textW, boxW = fs:GetStringWidth(), fs:GetWidth()
  if type(textW) == "number" and type(boxW) == "number" and boxW > 0 and textW > boxW then
    fs:SetFontObject("GameFontNormalLarge")
  end
end

-- Known to exist, but nobody has found it yet (neither our data nor players).
local function isUndiscovered(npc)
  return ns.Undiscovered and ns.Undiscovered[npc] ~= nil and not ns.Seed[npc]
    and not (ns.db.discovered and ns.db.discovered[npc])
end
Database.IsUndiscovered = isUndiscovered
Database.RareInfo = rareInfo

local function allRares()
  local out, seen = {}, {}
  local function add(npc) if not seen[npc] then seen[npc] = true; out[#out + 1] = npc end end
  for npc in pairs(ns.Seed) do add(npc) end
  for npc in pairs(ns.db.discovered or {}) do add(npc) end
  for npc in pairs(ns.Undiscovered or {}) do add(npc) end
  return out
end

local function mapsOf(npc)
  local _, _, _, _, points = rareInfo(npc)
  local maps, seen = {}, {}
  for i = 1, #points, 3 do
    if not seen[points[i]] then seen[points[i]] = true; maps[#maps + 1] = points[i] end
  end
  return maps, seen
end

-- Main zone of a rare: the zone filter, else the player's zone, else its first.
local function mainMap(npc)
  local maps, has = mapsOf(npc)
  if filter.zone and has[filter.zone] then return filter.zone end
  local here = C_Map.GetBestMapForUnit("player")
  if here and has[here] then return here end
  return maps[1]
end

-- Live sighting of a rare, the freshest one.
local function liveOf(npc)
  local best
  for _, e in ipairs(ns.Sightings.Live(ns.Now())) do
    if e.npc == npc and (not best or e.time > best.time) then best = e end
  end
  return best
end

-- Loot as { itemID, chance (percent or nil), quality } best first.
function Database.LootOf(npc)
  local raw = ns.Loot and ns.Loot[npc]
  local out = {}
  if not raw then return out end
  for i = 1, #raw, 3 do
    out[#out + 1] = { id = raw[i], chance = raw[i + 1] > 0 and raw[i + 1] / 10 or nil, quality = raw[i + 2] }
  end
  return out
end

local function hasForeverLoot(npc)
  if ns.ForeverDrops and ns.ForeverDrops[npc] then return true end
  local kills = ns.Drops.Of(npc)
  return kills > 0
end

local function chanceText(c)
  if not c then return "?" end
  if c >= 10 then return string.format("%.0f%%", c) end
  return string.format("%.1f%%", c)
end
Database.ChanceText = chanceText

local function qualityColor(q)
  if C_Item and C_Item.GetItemQualityColor then
    local ok, r, g, b = pcall(C_Item.GetItemQualityColor, q)
    if ok and r then return r, g, b end
  end
  local c = QUALITY[q] or QUALITY[1]
  return c[1], c[2], c[3]
end
Database.QualityColor = qualityColor

-- Colour of a level relative to the player, like the game's con colours.
local function levelColor(level)
  if not level or level <= 0 then return 0.7, 0.7, 0.7 end
  if GetCreatureDifficultyColor then
    local ok, c = pcall(GetCreatureDifficultyColor, level)
    if ok and c and c.r then return c.r, c.g, c.b end
  end
  local diff = level - (UnitLevel("player") or level)
  if diff >= 5 then return 1, 0.1, 0.1 elseif diff >= 3 then return 1, 0.5, 0.25
  elseif diff >= -2 then return 1, 1, 0 elseif diff >= -6 then return 0.25, 0.75, 0.25 end
  return 0.5, 0.5, 0.5
end

-- Name of an item now if cached, and a callback once the client has it.
-- Returns a cancel function for loads in flight.
function Database.LoadItem(id, done)
  local name = C_Item.GetItemInfo(id)
  if name then done(name, true) return nil end
  if Item and Item.CreateFromItemID then
    local item = Item:CreateFromItemID(id)
    if item:IsItemEmpty() then done(nil, false) return nil end
    return item:ContinueWithCancelOnItemLoad(function()
      local ok = not item:IsItemEmpty() and item:GetItemName()
      done(ok or nil, ok and true or false)
    end)
  end
  done(nil, false)
end

-- A spell's name and icon from the client, or nil until it has loaded (then
-- `done(name)` runs; the returned function cancels the wait).
function Database.LoadSpell(id, done)
  local name, icon
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(id)
    if info then name, icon = info.name, info.iconID end
  elseif GetSpellInfo then
    local n, _, i = GetSpellInfo(id)
    name, icon = n, i
  end
  if name then done(name, icon) return nil end
  if Spell and Spell.CreateFromSpellID then
    local spell = Spell:CreateFromSpellID(id)
    if spell:IsSpellEmpty() then return nil end
    return spell:ContinueWithCancelOnSpellLoad(function()
      done(spell:GetSpellName(), spell:GetSpellTexture())
    end)
  end
end

-- "45 minutes", "1 hour", "1.5 hours", "8 hours" (to the half hour).
local function hoursText(secs)
  if secs < 3600 then return string.format("%d minutes", math.floor(secs / 60 + 0.5)) end
  local h = math.floor(secs / 1800 + 0.5) / 2
  if h == 1 then return "1 hour" end
  return (h % 1 == 0 and string.format("%d", h) or string.format("%.1f", h)) .. " hours"
end
Database.HoursText = hoursText

-- How to find and fight a rare (RareNet/Tactics.lua): Forever's rank and tip
-- first, then the classic data, each line marked as such.
-- Returns rank (or nil), whether the rank is Forever's, the tip, and entries
-- for the rows: headers, spells ({ spell, right }) and plain lines ({ text }).
function Database.TacticsOf(npc)
  local t = ns.Tactics and ns.Tactics[npc]
  if not t then return nil, false, nil, {} end
  local rank, fromForever, tip, spells, flee, help, adds, respawnMin, respawnMax =
    t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9]
  local entries = {}
  if rank and rank:find("lite") then
    entries[#entries + 1] = { text = "Elite: far tougher than a normal mob of its level. Come with others unless you outlevel it." }
  end
  local classic = {}
  for i = 1, #spells, 2 do
    local id, below = spells[i], spells[i + 1]
    -- spells this client does not have would only show as a number
    local known = not (C_Spell and C_Spell.DoesSpellExist) or C_Spell.DoesSpellExist(id)
    if known then classic[#classic + 1] = { spell = id, right = below > 0 and ("below " .. below .. "% health") or "" } end
  end
  if flee > 0 then classic[#classic + 1] = { text = "Flees at " .. flee .. "% health: finish it fast or slow it." } end
  if help > 0 then classic[#classic + 1] = { text = "Calls for help at " .. help .. "% health: pull it away from others." } end
  for _, add in ipairs(adds) do classic[#classic + 1] = { text = "Summons " .. add .. "." } end
  if respawnMin > 0 then
    local span = respawnMax > respawnMin and (hoursText(respawnMin) .. " to " .. hoursText(respawnMax)) or hoursText(respawnMin)
    classic[#classic + 1] = { text = "Respawns after " .. span .. "." }
  end
  if #classic > 0 then
    entries[#entries + 1] = { header = (tip or fromForever) and "Classic data (may differ in Forever)" or "Classic data", grey = true }
    for _, e in ipairs(classic) do entries[#entries + 1] = e end
  end
  return rank, fromForever, tip, entries
end

local function cancelLoads()
  for _, cancel in ipairs(pendingItems) do pcall(cancel) end
  wipe(pendingItems)
end

-- Every item a rare may drop, from all sources.
local function itemIdsOf(npc)
  local ids = {}
  local _, seen = ns.Drops.Of(npc)
  for _, it in ipairs(seen) do ids[#ids + 1] = it.id end
  local listed = ns.ForeverDrops and ns.ForeverDrops[npc]
  if listed then for i = 1, #listed, 2 do ids[#ids + 1] = listed[i] end end
  for _, it in ipairs(Database.LootOf(npc)) do ids[#ids + 1] = it.id end
  return ids
end

-- Search matches the rare's name, its zone, or the name of anything it
-- drops (items the client has cached).
local function matchesSearch(npc, text)
  if text == "" then return true end
  local name = rareInfo(npc)
  if name:lower():find(text, 1, true) then return true end
  for _, m in ipairs((mapsOf(npc))) do
    if zoneName(m):lower():find(text, 1, true) then return true end
  end
  for _, id in ipairs(itemIdsOf(npc)) do
    local itemName = C_Item.GetItemInfo(id)
    if itemName and itemName:lower():find(text, 1, true) then return true end
  end
  return false
end

function Database.Filter() return filter end

-- Rebuild the visible list from the search and filters.
function Database.Rebuild()
  wipe(list)
  local myLevel = UnitLevel("player") or 0
  local text = (filter.text or ""):lower()
  for _, npc in ipairs(allRares()) do
    local _, level, tame = rareInfo(npc)
    local _, has = mapsOf(npc)
    local ok = (not filter.zone or has[filter.zone])
      and (not filter.tame or tame)
      and (not filter.new or ns.SeedSource[npc] ~= nil)
      and (not filter.loot or hasForeverLoot(npc))
      and (not filter.live or liveOf(npc) ~= nil)
      and (not filter.level or (level and level > 0 and math.abs(level - myLevel) <= 5))
      and (not filter.undiscovered or isUndiscovered(npc))
      and matchesSearch(npc, text)
    if ok then list[#list + 1] = npc end
  end
  table.sort(list, function(a, b)
    local na, la = rareInfo(a)
    local nb, lb = rareInfo(b)
    if filter.sort == "name" then return na < nb end
    if filter.sort == "zone" then
      local za, zb = zoneName(mainMap(a)), zoneName(mainMap(b))
      if za ~= zb then return za < zb end
    end
    if (la or 0) ~= (lb or 0) then return (la or 0) < (lb or 0) end
    return na < nb
  end)
  return list
end

-- Zones with rares, grouped by continent, for the zone dropdown.
local function zonesByContinent()
  local zones = {}
  for _, npc in ipairs(allRares()) do
    for _, m in ipairs((mapsOf(npc))) do zones[m] = true end
  end
  local groups, order = {}, {}
  for m in pairs(zones) do
    local c = continentOf(m)
    if not groups[c] then groups[c] = {}; order[#order + 1] = c end
    groups[c][#groups[c] + 1] = m
  end
  table.sort(order)
  for _, c in ipairs(order) do table.sort(groups[c], function(a, b) return zoneName(a) < zoneName(b) end) end
  return order, groups
end

-- Spawn point of this rare closest to the player on the given map.
local function nearestSpawn(points, uiMap)
  local pos = C_Map.GetPlayerMapPosition(uiMap, "player")
  local px, py = 0.5, 0.5
  if pos then px, py = pos:GetXY() end
  local best, bestD
  for i = 1, #points, 3 do
    if points[i] == uiMap then
      local x, y = points[i + 1] / 100, points[i + 2] / 100
      local d = (x - px) ^ 2 + (y - py) ^ 2
      if not bestD or d < bestD then best, bestD = { x = x, y = y }, d end
    end
  end
  return best
end

-- Detail pane ---------------------------------------------------------------------------

local refresh

local function setSkull(tex, npc, tame)
  if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("VignetteKill") then
    tex:SetAtlas("VignetteKill")
  else
    tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
  end
  if tame then tex:SetVertexColor(1, 0.8, 0.1)
  elseif ns.SeedSource[npc] then tex:SetVertexColor(0.55, 0.8, 1)
  else tex:SetVertexColor(1, 1, 1) end
end

local function lootEntries(npc)
  local entries, known = {}, {}
  local kills, seen = ns.Drops.Of(npc)
  if #seen > 0 then
    entries[#entries + 1] = { header = string.format("Seen by RareNet players  (%d looted kill%s)", kills, kills == 1 and "" or "s") }
    for _, it in ipairs(seen) do
      known[it.id] = true
      local who = it.mine and "you" or (it.players >= 2 and (it.players .. " players") or "1 player")
      entries[#entries + 1] = { id = it.id, right = string.format("%d/%d", it.count, kills), note = who }
    end
  end
  local listed = ns.ForeverDrops and ns.ForeverDrops[npc]
  if listed then
    local rows = {}
    for i = 1, #listed, 2 do
      if not known[listed[i]] then rows[#rows + 1] = { id = listed[i], quality = listed[i + 1], right = "Forever" } end
      known[listed[i]] = true
    end
    if #rows > 0 then
      entries[#entries + 1] = { header = "Known Forever drops  (data: ForeverChanges)", credit = true }
      for _, r in ipairs(rows) do entries[#entries + 1] = r end
    end
  end
  local classic = {}
  for _, it in ipairs(Database.LootOf(npc)) do
    if not known[it.id] then classic[#classic + 1] = { id = it.id, quality = it.quality, right = chanceText(it.chance), grey = true } end
  end
  if #classic > 0 then
    entries[#entries + 1] = { header = "Classic drop table", grey = true }
    for _, r in ipairs(classic) do entries[#entries + 1] = r end
  end
  return entries
end

local function showDetail()
  local d = frame.detail
  cancelLoads()
  if not selected then
    d:Hide()
    frame.empty:Show()
    return
  end
  frame.empty:Hide()
  d:Show()
  local name, level, tame, display, points = rareInfo(selected)
  detailMap = mainMap(selected)
  d.name:SetText(name)
  fitName(d.name)
  C_Timer.After(0, function() fitName(d.name) end)   -- widths are only known once laid out
  local lr, lg, lb = levelColor(level)
  d.level:SetText(level and level > 0 and ("Level " .. level) or "Level ?")
  d.level:SetTextColor(lr, lg, lb)
  local spawns = 0
  for i = 1, #points, 3 do if points[i] == detailMap then spawns = spawns + 1 end end
  local tags = {}
  local u = ns.Undiscovered and ns.Undiscovered[selected]
  if isUndiscovered(selected) then
    tags[#tags + 1] = "|cffb38cffUndiscovered|r"
  elseif ns.SeedSource[selected] or u then
    tags[#tags + 1] = "|cff8cccffNew in Forever|r"
  end
  if u and u[2] then tags[#tags + 1] = "Elite" end
  if u and u[3] ~= "" then tags[#tags + 1] = u[3] end
  if u and u[4] and not tame then tags[#tags + 1] = "|cffffcc00Likely tameable|r" end
  if tame then tags[#tags + 1] = "|cffffcc00Tameable|r" end
  local rank, rankForever, tip, fight = Database.TacticsOf(selected)
  if rank and not (u and u[2]) then tags[#tags + 1] = rankForever and ("|cff8cccff" .. rank .. "|r") or rank end
  d.tags:SetText(table.concat(tags, "   "))
  if isUndiscovered(selected) then
    d.zone:SetText("|cffb38cffNobody has found it yet. Be the first: RareNet will tell everyone.|r")
  else
    d.zone:SetText(string.format("%s  -  %d spawn point%s", zoneName(detailMap), spawns, spawns == 1 and "" or "s"))
  end
  local live = liveOf(selected)
  if live then
    local mine = ns.Layer.IsMine(live.layer)
    d.live:SetText(string.format("%s %s, %ds ago", live.state == "D" and "|cffff4444Dead|r" or "|cff33ff33Up|r",
      mine and "on your layer" or ("on " .. ns.Layer.Label(live.layer)), ns.Now() - live.time))
  else
    d.live:SetText("|cff888888No live sighting|r")
  end
  d.source:SetText(ns.SeedSource[selected] and ("|cff8cccffSpawn data: " .. ns.SeedSource[selected] .. "|r") or "")
  ns.Map.ShowModel(d.model, selected, display, 1.25)

  local entries, rows = lootEntries(selected), LOOT_ROWS
  d.tabDrops:SetSelected(view == "drops")
  d.tabFight:SetSelected(view == "fight")
  d.tip:SetText("")
  d.listTop:ClearAllPoints()
  d.listTop:SetPoint("TOPLEFT", d.tabDrops, "BOTTOMLEFT", 0, -2)
  if view == "fight" then
    entries = fight
    if tip then
      d.tip:SetText("|cff8cccffIn Forever:|r " .. tip)
      d.listTop:ClearAllPoints()
      d.listTop:SetPoint("TOPLEFT", d.tip, "BOTTOMLEFT", 0, -4)
      rows = LOOT_ROWS - math.ceil((d.tip:GetStringHeight() + 6) / LOOT_H)
    end
    d.noLoot:SetText("Nothing known about how it fights yet.")
    d.noLoot:SetShown(#entries == 0 and not tip)
  else
    d.noLoot:SetText("No loot data yet. Loot it and RareNet will learn it.")
    d.noLoot:SetShown(#entries == 0)
  end
  for i, row in ipairs(d.loot) do
    local it = i <= rows and entries[i] or nil
    row.item = it and it.id and it or nil
    row.spell = it and it.spell or nil
    -- names sit next to the icon and stay on one line, except plain lines
    row.name:SetWidth(210)
    row.name:SetWordWrap(false)
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    if not it then
      row:Hide()
    elseif it.header then
      row.icon:Hide()
      row.border:Hide()
      row.right:SetText("")
      row.note:SetText("")
      row.name:SetFontObject("GameFontNormalSmall")
      row.name:SetText(it.header)
      if it.grey then row.name:SetTextColor(0.6, 0.6, 0.6)
      elseif it.credit then row.name:SetTextColor(0.55, 0.8, 1)
      else row.name:SetTextColor(1, 0.82, 0) end
      row.line:Show()
      row:Show()
    elseif it.text then
      -- a plain line (fight view)
      row.line:Hide()
      row.icon:Hide()
      row.border:Hide()
      row.right:SetText("")
      row.note:SetText("")
      row.name:SetFontObject("GameFontHighlightSmall")
      row.name:SetTextColor(0.85, 0.85, 0.85)
      row.name:SetWidth(326)
      row.name:SetWordWrap(true)
      row.name:ClearAllPoints()
      row.name:SetPoint("LEFT", row, "LEFT", 2, 0)
      row.name:SetText(it.text)
      row:Show()
    elseif it.spell then
      row.line:Hide()
      row.icon:Show()
      row.border:Show()
      row.border:SetVertexColor(0.6, 0.6, 0.6)
      row.icon:SetDesaturated(false)
      row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
      row.name:SetFontObject("GameFontHighlightSmall")
      row.name:SetTextColor(1, 1, 1)
      row.name:SetText("Spell #" .. it.spell)
      row.right:SetText(it.right or "")
      row.note:SetText("")
      local cancel = Database.LoadSpell(it.spell, function(spellName, icon)
        if row.spell ~= it.spell then return end
        row.name:SetText(spellName or ("Spell #" .. it.spell))
        if icon then row.icon:SetTexture(icon) end
      end)
      if cancel then pendingItems[#pendingItems + 1] = cancel end
      row:Show()
    else
      row.line:Hide()
      row.icon:Show()
      row.border:Show()
      row.name:SetFontObject("GameFontHighlightSmall")
      local icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(it.id)
      row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.icon:SetDesaturated(it.grey or false)
      local quality = it.quality
      if not quality and C_Item.GetItemQualityByID then quality = C_Item.GetItemQualityByID(it.id) end
      local r, g, b = qualityColor(quality or 1)
      row.border:SetVertexColor(r, g, b)
      if it.grey then r, g, b = r * 0.65, g * 0.65, b * 0.65 end
      row.name:SetTextColor(r, g, b)
      row.name:SetText("Item #" .. it.id)
      row.right:SetText(it.right or "")
      row.note:SetText(it.note or "")
      local cancel = Database.LoadItem(it.id, function(itemName, found)
        if row.item ~= it then return end
        if found then row.name:SetText(itemName) else row.name:SetTextColor(0.5, 0.5, 0.5) end
      end)
      if cancel then pendingItems[#pendingItems + 1] = cancel end
      row:Show()
    end
  end
end

refresh = function()
  if not frame or not frame:IsShown() then return end
  Database.Rebuild()
  scroll = math.max(0, math.min(scroll, #list - ROWS))
  frame.count:SetText(#list .. (#list == 1 and " rare" or " rares"))
  for i, row in ipairs(frame.rows) do
    local npc = list[i + scroll]
    row.npc = npc
    if npc then
      local name, level, tame = rareInfo(npc)
      setSkull(row.skull, npc, tame)
      row.name:SetText(name)
      if npc == selected then row.name:SetTextColor(1, 1, 1) else row.name:SetTextColor(1, 0.82, 0) end
      local lr, lg, lb = levelColor(level)
      row.level:SetText(level and level > 0 and level or "?")
      row.level:SetTextColor(lr, lg, lb)
      row.zone:SetText(zoneName(mainMap(npc)))
      row.newTag:SetShown(ns.SeedSource[npc] ~= nil or isUndiscovered(npc))
      row.newTag:SetText(isUndiscovered(npc) and "|cffb38cffUNFOUND|r" or "|cff8cccffNEW|r")
      row.tame:SetShown(tame or false)
      local live = liveOf(npc)
      if live then
        local mine = ns.Layer.IsMine(live.layer)
        row.status:SetText(live.state == "D" and "|cffff4444dead|r" or (mine and "|cff33ff33up|r" or "|cffff9933live|r"))
      else
        row.status:SetText("")
      end
      row.selected:SetShown(npc == selected)
      row:Show()
    else
      row:Hide()
    end
  end
  frame.zoneDropdown:GenerateMenu()
  showDetail()
end
Database.Refresh = refresh

-- Window ----------------------------------------------------------------------------------

local function rareRow(parent, i)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(286, ROW_H)
  row:SetPoint("TOPLEFT", 6, -6 - (i - 1) * ROW_H)
  local stripe = row:CreateTexture(nil, "BACKGROUND")
  stripe:SetAllPoints()
  stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
  row.selected = row:CreateTexture(nil, "BACKGROUND", nil, 1)
  row.selected:SetAllPoints()
  row.selected:SetColorTexture(1, 0.82, 0, 0.15)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row.skull = row:CreateTexture(nil, "ARTWORK")
  row.skull:SetSize(22, 22)
  row.skull:SetPoint("LEFT", 4, 0)
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.name:SetPoint("TOPLEFT", row.skull, "TOPRIGHT", 6, 3)
  row.name:SetWidth(180)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)
  row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.zone:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
  row.level = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.level:SetPoint("TOPRIGHT", -6, -4)
  row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.status:SetPoint("BOTTOMRIGHT", -6, 4)
  row.tame = row:CreateTexture(nil, "ARTWORK")
  row.tame:SetSize(14, 14)
  row.tame:SetTexture(TAME_ICON)
  row.tame:SetPoint("RIGHT", row.level, "LEFT", -6, 0)
  row.newTag = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.newTag:SetText("|cff8cccffNEW|r")
  row.newTag:SetPoint("RIGHT", row.status, "LEFT", -6, 0)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function(self, button)
    if button == "RightButton" and self.npc then
      local _, _, _, _, points = rareInfo(self.npc)
      local m = mainMap(self.npc)
      local p = m and nearestSpawn(points, m)
      if p and C_Map.CanSetUserWaypointOnMap(m) then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(m, p.x, p.y))
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
      end
      return
    end
    selected = self.npc
    refresh()
  end)
  return row
end

local function lootRow(parent, anchor, i)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(330, LOOT_H)
  row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4 - (i - 1) * LOOT_H)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(20, 20)
  row.icon:SetPoint("LEFT", 2, 0)
  row.border = row:CreateTexture(nil, "OVERLAY")
  row.border:SetTexture("Interface\\Common\\WhiteIconFrame")
  row.border:SetAllPoints(row.icon)
  row.line = row:CreateTexture(nil, "ARTWORK")
  row.line:SetHeight(1)
  row.line:SetPoint("BOTTOMLEFT", 0, 2)
  row.line:SetPoint("BOTTOMRIGHT", 0, 2)
  row.line:SetColorTexture(1, 0.82, 0, 0.25)
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetWidth(210)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)
  row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.right:SetPoint("TOPRIGHT", -2, -2)
  row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.note:SetPoint("BOTTOMRIGHT", -2, 2)
  row:SetScript("OnEnter", function(self)
    if self.item then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(self.item.id)
      GameTooltip:Show()
    elseif self.spell then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetSpellByID(self.spell)
      GameTooltip:Show()
    end
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:SetScript("OnClick", function(self)
    if not self.item then return end
    -- Shift (chat link) and ctrl (dressing room) follow the player's own bindings.
    local _, link = C_Item.GetItemInfo(self.item.id)
    if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end
  end)
  return row
end

local function setupDropdowns()
  -- Zone: all, here, or a zone by continent.
  frame.zoneDropdown:SetupMenu(function(_, root)
    root:CreateRadio("All zones", function() return filter.zone == nil end, function()
      filter.zone = nil; scroll = 0; refresh()
    end)
    root:CreateRadio("Current zone", function() return filter.zone ~= nil and filter.zone == C_Map.GetBestMapForUnit("player") end,
      function() filter.zone = C_Map.GetBestMapForUnit("player"); scroll = 0; refresh() end)
    local order, groups = zonesByContinent()
    for _, continent in ipairs(order) do
      local sub = root:CreateButton(continent)
      for _, m in ipairs(groups[continent]) do
        sub:CreateRadio(zoneName(m), function() return filter.zone == m end, function()
          filter.zone = m; scroll = 0; refresh()
        end)
      end
    end
  end)
  frame.zoneDropdown:SetSelectionText(function()
    return filter.zone and zoneName(filter.zone) or "All zones"
  end)
  -- Filters and sort.
  frame.filterDropdown:SetupMenu(function(_, root)
    local function flag(label, key)
      root:CreateCheckbox(label, function() return filter[key] end, function() filter[key] = not filter[key]; scroll = 0; refresh() end)
    end
    flag("Tameable only", "tame")
    flag("New in Forever only", "new")
    flag("With Forever loot", "loot")
    flag("Seen alive or dead now", "live")
    flag("Near my level (5 levels)", "level")
    flag("Undiscovered: be the first to find them", "undiscovered")
    root:CreateDivider()
    root:CreateTitle("Sort by")
    for _, s in ipairs({ { "level", "Level" }, { "name", "Name" }, { "zone", "Zone" } }) do
      root:CreateRadio(s[2], function() return filter.sort == s[1] end, function() filter.sort = s[1]; refresh() end)
    end
  end)
  if frame.filterDropdown.SetIsDefaultCallback then
    frame.filterDropdown:SetIsDefaultCallback(function()
      return not (filter.tame or filter.new or filter.loot or filter.live or filter.level or filter.undiscovered) and filter.sort == "level"
    end)
    frame.filterDropdown:SetDefaultCallback(function()
      filter.tame, filter.new, filter.loot, filter.live, filter.level, filter.undiscovered, filter.sort = false, false, false, false, false, false, "level"
      refresh()
    end)
  end
end

local function build()
  frame = CreateFrame("Frame", "RareNetDatabase", UIParent, "ButtonFrameTemplate")
  frame:SetSize(720, 600)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetToplevel(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  if frame.SetTitle then frame:SetTitle("RareNet: Rare Database") end
  if frame.SetPortraitToAsset then frame:SetPortraitToAsset(ICON) end
  if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(frame) end

  -- Top bar: search, zone and filters.
  frame.search = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
  frame.search:SetSize(190, 20)
  frame.search:SetPoint("TOPLEFT", 70, -32)
  if type(frame.search.Instructions) == "table" then frame.search.Instructions:SetText("Rare, zone or item") end
  frame.search:HookScript("OnTextChanged", function(self)
    filter.text = self:GetText() or ""
    scroll = 0
    refresh()
  end)
  frame.zoneDropdown = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
  frame.zoneDropdown:SetWidth(170)
  frame.zoneDropdown:SetPoint("LEFT", frame.search, "RIGHT", 12, 0)
  frame.filterDropdown = CreateFrame("DropdownButton", nil, frame, "WowStyle1FilterDropdownTemplate")
  frame.filterDropdown:SetPoint("LEFT", frame.zoneDropdown, "RIGHT", 10, 0)
  frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.count:SetPoint("TOPRIGHT", -14, -38)

  -- Left: the list, in an inset.
  local inset = type(frame.Inset) == "table" and frame.Inset or CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
  inset:ClearAllPoints()
  inset:SetPoint("TOPLEFT", 10, -62)
  inset:SetPoint("BOTTOMLEFT", 10, 10)
  inset:SetWidth(298)
  frame.rows = {}
  for i = 1, ROWS do frame.rows[i] = rareRow(inset, i) end
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta) scroll = math.max(0, scroll - delta * 2); refresh() end)

  -- Right: the selected rare.
  frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  frame.empty:SetPoint("CENTER", 150, 0)
  frame.empty:SetText("Pick a rare on the left")
  local d = CreateFrame("Frame", nil, frame)
  d:SetPoint("TOPLEFT", inset, "TOPRIGHT", 12, 0)
  d:SetPoint("BOTTOMRIGHT", -12, 10)
  frame.detail = d
  local stage = CreateFrame("Frame", nil, d, "InsetFrameTemplate")
  stage:SetSize(150, 150)
  stage:SetPoint("TOPRIGHT", 0, 0)
  local shade = stage:CreateTexture(nil, "BACKGROUND", nil, 2)
  shade:SetPoint("TOPLEFT", 3, -3)
  shade:SetPoint("BOTTOMRIGHT", -3, 3)
  shade:SetColorTexture(0.02, 0.03, 0.05, 0.9)
  d.model = CreateFrame("PlayerModel", nil, stage)
  d.model:SetPoint("TOPLEFT", 4, -4)
  d.model:SetPoint("BOTTOMRIGHT", -4, 4)
  d.facing = 0
  d:SetScript("OnUpdate", function(_, dt)
    d.facing = d.facing + dt * 0.7
    d.model:SetFacing(d.facing)
  end)
  d:SetScript("OnHide", function() ns.Map.ClearModel(d.model); cancelLoads() end)
  d.name = d:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  d.name:SetPoint("TOPLEFT", 0, -2)
  d.name:SetPoint("RIGHT", stage, "LEFT", -8, 0)
  d.name:SetJustifyH("LEFT")
  d.name:SetWordWrap(false)
  d.level = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  d.level:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, -6)
  d.tags = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  -- Text stops at the model stage and wraps instead of running under it.
  local function line(fs, anchor, gap)
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, gap)
    fs:SetPoint("RIGHT", stage, "LEFT", -8, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
  end
  line(d.tags, d.level, -4)
  d.zone = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  line(d.zone, d.tags, -4)
  d.live = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  line(d.live, d.zone, -4)
  d.source = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  line(d.source, d.live, -4)
  local wp = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
  wp:SetSize(110, 22)
  wp:SetPoint("TOPLEFT", 0, -164)
  wp:SetText("Waypoint")
  wp:SetScript("OnClick", function()
    if not selected or not detailMap then return end
    local _, _, _, _, points = rareInfo(selected)
    local p = nearestSpawn(points, detailMap)
    if p and C_Map.CanSetUserWaypointOnMap(detailMap) then
      C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(detailMap, p.x, p.y))
      C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end
  end)
  local mapButton = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
  mapButton:SetSize(110, 22)
  mapButton:SetPoint("LEFT", wp, "RIGHT", 6, 0)
  mapButton:SetText("Show on map")
  mapButton:SetScript("OnClick", function() Database.ShowOnMap() end)
  -- Lower half: two tabs, what it drops and how to fight it.
  local function tab(label, which)
    local b = CreateFrame("Button", nil, d)
    b:SetSize(10, 22)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    b.text:SetPoint("LEFT")
    b.text:SetText(label)
    b:SetWidth(b.text:GetStringWidth() + 4)
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    function b:SetSelected(on)
      if on then self.text:SetTextColor(1, 0.82, 0) else self.text:SetTextColor(0.55, 0.55, 0.55) end
    end
    b:SetScript("OnClick", function() view = which; showDetail() end)
    return b
  end
  d.tabDrops = tab("Drops", "drops")
  d.tabDrops:SetPoint("TOPLEFT", 0, -196)
  d.tabFight = tab("How to fight it", "fight")
  d.tabFight:SetPoint("LEFT", d.tabDrops, "RIGHT", 16, 0)
  d.tip = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  d.tip:SetPoint("TOPLEFT", d.tabDrops, "BOTTOMLEFT", 0, -6)
  d.tip:SetWidth(330)
  d.tip:SetJustifyH("LEFT")
  d.tip:SetWordWrap(true)
  d.listTop = CreateFrame("Frame", nil, d)
  d.listTop:SetSize(330, 1)
  d.noLoot = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  d.noLoot:SetPoint("TOPLEFT", d.listTop, "BOTTOMLEFT", 0, -8)
  d.noLoot:SetWidth(330)
  d.noLoot:SetJustifyH("LEFT")
  d.loot = {}
  for i = 1, LOOT_ROWS do d.loot[i] = lootRow(d, d.listTop, i) end

  setupDropdowns()
  frame:SetScript("OnShow", function() refresh() end)
  tinsert(UISpecialFrames, "RareNetDatabase")   -- Esc closes it
  frame:Hide()
end

-- Opening the world map is blocked in combat for addons; it would also taint
-- the map, so wait until combat ends.
function Database.ShowOnMap()
  local m = detailMap or filter.zone
  if not m then return false end
  if InCombatLockdown() then
    ns.print("the map opens after combat")
    return false
  end
  if WorldMapFrame and WorldMapFrame:IsShown() then
    WorldMapFrame:SetMapID(m)
  elseif OpenWorldMap then
    OpenWorldMap(m)
  end
  return true
end

-- Search programmatically (also used by the search box).
function Database.Search(text)
  filter.text = text or ""
  if frame and frame.search and frame.search.SetText then frame.search:SetText(filter.text) end
  scroll = 0
  refresh()
end

-- Open the window, optionally on one rare.
function Database.Open(npc)
  if not frame then return end
  if npc then
    selected = npc
    -- Make sure the rare is in the list: clear what would hide it.
    Database.Rebuild()
    local visible = false
    for _, n in ipairs(list) do if n == npc then visible = true end end
    if not visible then
      filter.text, filter.tame, filter.new, filter.loot, filter.live, filter.level = "", false, false, false, false, false
      local _, has = mapsOf(npc)
      if filter.zone and not has[filter.zone] then filter.zone = nil end
      if frame.search and frame.search.SetText then frame.search:SetText("") end
      Database.Rebuild()
    end
    for i, n in ipairs(list) do if n == npc then scroll = math.max(0, i - ROWS) end end
    detailMap = mainMap(npc)
  elseif not selected and filter.zone == nil then
    local here = C_Map.GetBestMapForUnit("player")
    for _, npc2 in ipairs(allRares()) do
      local _, has = mapsOf(npc2)
      if has[here] then filter.zone = here break end
    end
  end
  frame:Show()
  frame:Raise()
  refresh()
end

function Database.Toggle()
  if frame and frame:IsShown() then frame:Hide() else Database.Open() end
end

function Database.Selected()
  return selected, detailMap and { uiMap = detailMap, name = zoneName(detailMap) }
end

-- Top drops for tooltips: { text, quality } using what the client has cached.
function Database.TopLoot(npc, n, onLoaded)
  local out = {}
  local function add(id, text, quality)
    if #out >= n then return end
    local name = C_Item.GetItemInfo(id)
    if not name then Database.LoadItem(id, function(_, found) if found and onLoaded then onLoaded() end end) end
    if not quality and C_Item.GetItemQualityByID then quality = C_Item.GetItemQualityByID(id) end
    out[#out + 1] = { text = (name or ("Item #" .. id)) .. "  " .. text, quality = quality or 1 }
  end
  local kills, seen = ns.Drops.Of(npc)
  local known = {}
  for _, it in ipairs(seen) do
    known[it.id] = true
    add(it.id, string.format("%d/%d", it.count, kills))
  end
  local listed = ns.ForeverDrops and ns.ForeverDrops[npc]
  if listed then
    for i = 1, #listed, 2 do
      if not known[listed[i]] then add(listed[i], "", listed[i + 1]); known[listed[i]] = true end
    end
  end
  for _, it in ipairs(Database.LootOf(npc)) do
    if not known[it.id] then add(it.id, chanceText(it.chance), it.quality) end
  end
  return out
end

table.insert(ns.onLoad, function() ns.Safe("database", build) end)
