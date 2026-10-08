-- Layer hopping is left to the addons built for it: Layer-Swap (/ls) and
-- Forever Layer Hop (/flh). RareNet only tells them where to go, and only
-- from a click of the player (their requests need a hardware event).
local _, ns = ...

local Hop = {}
ns.Hop = Hop

local function loaded(name)
  return C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(name) or false
end

local function parts(layerKey)
  return layerKey:match("^(%d+)%-(%d+)%-(%d+)$")
end

-- Name of the hopping addon available, or nil.
function Hop.Provider()
  if loaded("LayerSwap") and SlashCmdList.LAYERSWAP then return "Layer-Swap" end
  if loaded("ForeverLayerHop") and SlashCmdList.FOREVERLAYERHOP then return "Forever Layer Hop" end
end

-- Only rares on another layer of this continent are worth a hop.
function Hop.Useful(e)
  return e and e.layer and ns.Layer.IsMine(e.layer) == false
end

-- Line for tooltips about what a right click does.
function Hop.Hint(e)
  if not Hop.Useful(e) then return nil end
  local provider = Hop.Provider()
  if provider then return "Right-click: hop to its layer with " .. provider end
  return "On another layer: Layer-Swap or Forever Layer Hop can take you there"
end

-- Ask the hopping addon to take the player to the rare's layer.
function Hop.To(e)
  if not Hop.Useful(e) then return false end
  local server, _, zone = parts(e.layer)
  local label = ns.Layer.Label(e.layer)
  if loaded("LayerSwap") and SlashCmdList.LAYERSWAP then
    -- Layer-Swap ids are "server-zoneUID" and it shows layers as letters.
    local layers = LayerSwapDB and LayerSwapDB.layers
    local info = layers and layers[server .. "-" .. zone]
    if info and info.letter then
      ns.print(string.format("asking Layer-Swap for layer %s (%s) for %s", info.letter, label, e.name))
      SlashCmdList.LAYERSWAP("swap " .. info.letter)
    else
      ns.print(string.format("Layer-Swap has not seen %s yet: pick it in its panel, or ask for any other layer", label))
      SlashCmdList.LAYERSWAP("")
    end
    return true
  end
  if loaded("ForeverLayerHop") and SlashCmdList.FOREVERLAYERHOP then
    -- Forever Layer Hop lists layers as "Layer N (ID zoneUID)".
    ns.print(string.format("Forever Layer Hop opened: choose the layer with ID %s for %s", zone, e.name))
    SlashCmdList.FOREVERLAYERHOP("")
    return true
  end
  ns.print(string.format("%s is on another layer (%s). Layer-Swap or Forever Layer Hop can move you there.", e.name, label))
  return false
end
