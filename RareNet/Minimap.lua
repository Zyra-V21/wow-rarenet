-- Minimap button (drag around the edge) and Addon Compartment entry.
local _, ns = ...

local ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"
local atan2 = math.atan2 or math.atan
local button

local function place()
  local angle = math.rad(ns.db.settings.minimapAngle)
  local radius = (Minimap:GetWidth() / 2) + 10
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- Right click: a small menu (the game's own context menus when available).
local function openMenu(owner)
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(owner, function(_, root)
      root:CreateTitle("RareNet")
      root:CreateButton("Rare database", function() ns.Database.Open() end)
      root:CreateButton("Live rare list", function() ns.UI.Toggle() end)
      root:CreateButton("Settings", function() ns.Options.Toggle() end)
      root:CreateButton("Test alert", function() ns.Alert.Test() end)
    end)
  else
    ns.Options.Toggle()
  end
end

local function onClick(self, mouse)
  if mouse == "RightButton" then openMenu(self) else ns.UI.Toggle() end
end

local function build()
  button = CreateFrame("Button", "RareNetMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local icon = button:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture(ICON)
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER", 0, 1)
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  button:SetScript("OnClick", onClick)
  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      ns.db.settings.minimapAngle = math.deg(atan2(cy / scale - my, cx / scale - mx))
      place()
    end)
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("RareNet")
    GameTooltip:AddLine("Left-click: rare list", 1, 1, 1)
    GameTooltip:AddLine("Right-click: rare database, settings and more", 1, 1, 1)
    GameTooltip:AddLine("Drag: move", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  place()
end

local Minimap_ = {}
ns.MinimapButton = Minimap_

function Minimap_.Update()
  if not button then return end
  if ns.db.settings.minimapHide then button:Hide() else button:Show() end
end

table.insert(ns.onLoad, function()
  ns.Safe("minimap", function()
    build()
    Minimap_.Update()
  end)
  -- The Addon Compartment (retail minimap menu) may not exist in every client.
  if AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon then
    ns.Safe("compartment", AddonCompartmentFrame.RegisterAddon, AddonCompartmentFrame, {
      text = "RareNet", icon = ICON, notCheckable = true,
      func = function(_, input) onClick(button, input and input.buttonName) end,
    })
  end
end)
