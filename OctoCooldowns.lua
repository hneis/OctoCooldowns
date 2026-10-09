-- OctoCooldowns 0.2.1
-- Retail-like personal cooldown bars for WoW 1.12 / OctoWoW.
-- Lua 5.0 compatible: no # operator, no select(), old WoW event globals.

local OCD = CreateFrame("Frame", "OctoCooldownsEventFrame", UIParent)
local BOOK = BOOKTYPE_SPELL or "spell"
local DEFAULT_UPDATE_INTERVAL = 0.10
local MIN_UPDATE_INTERVAL = 0.05
local MAX_UPDATE_INTERVAL = 1.00
local GCD_THRESHOLD = 1.80
local updateElapsed = 0
local barFrames = {}
local itemCountCache = {}
local bagCountsDirty = false

local function Chat(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffOctoCooldowns:|r " .. msg)
  end
end

local function Trim(s)
  if not s then return "" end
  s = string.gsub(s, "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  return s
end

local function DefaultBarName(index)
  if index == 1 then return "Main" end
  return "Bar " .. tostring(index)
end

local function NewBar(name, y)
  local t = {}
  t.name = name or "Bar"
  t.locked = false
  t.cols = 4
  t.size = 40
  t.gap = 4
  t.point = "CENTER"
  t.x = 0
  t.y = y or -120
  t.entries = {}
  return t
end

local function EnsureBar(bar, index)
  if not bar.name or bar.name == "" then bar.name = DefaultBarName(index) end
  if bar.locked == nil then bar.locked = false end
  if not bar.cols then bar.cols = 4 end
  if not bar.size then bar.size = 40 end
  if not bar.gap then bar.gap = 4 end
  if not bar.point then bar.point = "CENTER" end
  if bar.x == nil then bar.x = 0 end
  if bar.y == nil then bar.y = -120 - ((index - 1) * 60) end
  if not bar.entries then bar.entries = {} end
end

local function EnsureDB()
  if not OctoCooldownsDB then
    OctoCooldownsDB = { version = 3, active = 1, updateInterval = DEFAULT_UPDATE_INTERVAL, bars = { NewBar("Main", -120) } }
    return
  end

  -- Automatic migration from 0.1.x single-bar database.
  if not OctoCooldownsDB.bars then
    local old = OctoCooldownsDB
    local bar = NewBar("Main", old.y or -120)
    if old.locked ~= nil then bar.locked = old.locked end
    if old.cols then bar.cols = old.cols end
    if old.size then bar.size = old.size end
    if old.gap then bar.gap = old.gap end
    if old.point then bar.point = old.point end
    if old.x ~= nil then bar.x = old.x end
    if old.y ~= nil then bar.y = old.y end
    if old.entries then bar.entries = old.entries end
    OctoCooldownsDB = { version = 3, active = 1, updateInterval = DEFAULT_UPDATE_INTERVAL, bars = { bar } }
    Chat("migrated 0.1 settings to multi-bar format")
  end

  OctoCooldownsDB.version = 3
  if not OctoCooldownsDB.updateInterval then OctoCooldownsDB.updateInterval = DEFAULT_UPDATE_INTERVAL end
  if OctoCooldownsDB.updateInterval < MIN_UPDATE_INTERVAL then OctoCooldownsDB.updateInterval = MIN_UPDATE_INTERVAL end
  if OctoCooldownsDB.updateInterval > MAX_UPDATE_INTERVAL then OctoCooldownsDB.updateInterval = MAX_UPDATE_INTERVAL end
  if not OctoCooldownsDB.bars then OctoCooldownsDB.bars = {} end
  if table.getn(OctoCooldownsDB.bars) == 0 then
    table.insert(OctoCooldownsDB.bars, NewBar("Main", -120))
  end

  local i = 1
  while i <= table.getn(OctoCooldownsDB.bars) do
    EnsureBar(OctoCooldownsDB.bars[i], i)
    i = i + 1
  end

  if not OctoCooldownsDB.active then OctoCooldownsDB.active = 1 end
  if OctoCooldownsDB.active < 1 then OctoCooldownsDB.active = 1 end
  if OctoCooldownsDB.active > table.getn(OctoCooldownsDB.bars) then
    OctoCooldownsDB.active = table.getn(OctoCooldownsDB.bars)
  end
end

local function GetBar(index)
  if not OctoCooldownsDB or not OctoCooldownsDB.bars then return nil end
  return OctoCooldownsDB.bars[index]
end

local function ActiveIndex()
  if not OctoCooldownsDB then return 1 end
  local i = tonumber(OctoCooldownsDB.active) or 1
  if i < 1 then i = 1 end
  if i > table.getn(OctoCooldownsDB.bars) then i = table.getn(OctoCooldownsDB.bars) end
  return i
end

local function FindBarIndex(query)
  query = Trim(query or "")
  if query == "" then return nil end
  local n = tonumber(query)
  if n and n >= 1 and n <= table.getn(OctoCooldownsDB.bars) then return n end
  local wanted = string.lower(query)
  local i = 1
  while i <= table.getn(OctoCooldownsDB.bars) do
    local bar = OctoCooldownsDB.bars[i]
    if string.lower(bar.name or "") == wanted then return i end
    i = i + 1
  end
  return nil
end

local function FindSpellByName(searchName)
  if not searchName or searchName == "" then return nil end
  local wanted = string.lower(searchName)
  local i = 1
  local foundIndex, foundName, foundRank, foundTexture
  while true do
    local name, rank = GetSpellName(i, BOOK)
    if not name then break end
    if string.lower(name) == wanted then
      foundIndex = i
      foundName = name
      foundRank = rank
      foundTexture = GetSpellTexture(i, BOOK)
    end
    i = i + 1
  end
  return foundIndex, foundName, foundRank, foundTexture
end

local function ResolveSpell(entry)
  local slot, name, rank, texture = FindSpellByName(entry.name)
  entry._slot = slot
  if name then entry.name = name end
  entry._rank = rank
  entry._texture = texture
  return slot
end

local function TextureLooksValid(v)
  return type(v) == "string" and string.find(v, "\\") ~= nil
end

local function GetItemMeta(itemID)
  if not itemID then return nil, nil end
  local a,b,c,d,e,f,g,h,i,j,k = GetItemInfo(itemID)
  local name = a
  local texture = nil
  if TextureLooksValid(j) then texture = j
  elseif TextureLooksValid(i) then texture = i
  elseif TextureLooksValid(k) then texture = k
  end
  return name, texture
end

local function RefreshItemCountCache()
  local tracked = {}
  local counts = {}

  if OctoCooldownsDB and OctoCooldownsDB.bars then
    local bi = 1
    while bi <= table.getn(OctoCooldownsDB.bars) do
      local bar = OctoCooldownsDB.bars[bi]
      local ei = 1
      while ei <= table.getn(bar.entries) do
        local e = bar.entries[ei]
        if e.kind == "item" and e.itemID then
          tracked[e.itemID] = true
          counts[e.itemID] = 0
        end
        ei = ei + 1
      end
      bi = bi + 1
    end
  end

  local hasTracked = false
  local trackedID, trackedValue = next(tracked, nil)
  if trackedID then hasTracked = true end
  if not hasTracked then
    itemCountCache = counts
    return
  end

  local bag = 0
  while bag <= 4 do
    local slots = GetContainerNumSlots(bag)
    local slot = 1
    while slot <= slots do
      local link = GetContainerItemLink(bag, slot)
      if link then
        local _, _, id = string.find(link, "item:(%d+)")
        local itemID = tonumber(id)
        if itemID and tracked[itemID] then
          local texture, count = GetContainerItemInfo(bag, slot)
          counts[itemID] = (counts[itemID] or 0) + (count or 1)
        end
      end
      slot = slot + 1
    end
    bag = bag + 1
  end

  itemCountCache = counts
end

local function FindEntryBySpellName(bar, name)
  local i = 1
  while i <= table.getn(bar.entries) do
    local e = bar.entries[i]
    if e.kind == "spell" and e.name == name then return i end
    i = i + 1
  end
  return nil
end

local function FindEntryByItemID(bar, itemID)
  local i = 1
  while i <= table.getn(bar.entries) do
    local e = bar.entries[i]
    if e.kind == "item" and e.itemID == itemID then return i end
    i = i + 1
  end
  return nil
end

local function SavePosition(barIndex)
  local frame = barFrames[barIndex]
  local bar = GetBar(barIndex)
  if not frame or not bar then return end
  local left = frame:GetLeft()
  local bottom = frame:GetBottom()
  if left and bottom then
    bar.point = "BOTTOMLEFT"
    bar.x = left
    bar.y = bottom
  end
end

local function RestorePosition(barIndex)
  local frame = barFrames[barIndex]
  local bar = GetBar(barIndex)
  if not frame or not bar then return end
  frame:ClearAllPoints()
  if bar.point == "BOTTOMLEFT" then
    frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", bar.x or 0, bar.y or 0)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", bar.x or 0, bar.y or -120)
  end
end

local function FormatTime(remain)
  if remain >= 3600 then
    return math.ceil(remain / 3600) .. "h"
  elseif remain >= 60 then
    return math.ceil(remain / 60) .. "m"
  elseif remain >= 10 then
    return tostring(math.ceil(remain))
  elseif remain > 0 then
    local t = math.ceil(remain * 10) / 10
    return string.format("%.1f", t)
  end
  return ""
end

local function CreateIcon(barIndex, index, parent)
  local b = CreateFrame("Button", "OctoCooldownsBar" .. barIndex .. "Icon" .. index, parent)
  b:SetWidth(40)
  b:SetHeight(40)
  b:EnableMouse(true)
  b._barIndex = barIndex
  b._entryIndex = index

  local border = b:CreateTexture(nil, "BACKGROUND")
  border:SetPoint("TOPLEFT", b, "TOPLEFT", -1, 1)
  border:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 1, -1)
  border:SetTexture(0, 0, 0, 1)
  b.border = border

  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints(b)
  b.icon = icon

  local timer = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  timer:SetPoint("CENTER", b, "CENTER", 0, 0)
  timer:SetText("")
  b.timer = timer

  local count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
  count:SetText("")
  b.count = count

  b:SetScript("OnEnter", function()
    local bar = GetBar(this._barIndex)
    local idx = this._entryIndex
    if not bar or not idx then return end
    local entry = bar.entries[idx]
    if not entry then return end
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    if entry.kind == "spell" then
      if entry._slot then
        GameTooltip:SetSpell(entry._slot, BOOK)
      else
        GameTooltip:SetText(entry.name or "Unknown spell")
      end
    else
      if entry.itemID then
        local name = GetItemMeta(entry.itemID)
        GameTooltip:SetText(name or ("Item " .. entry.itemID))
      end
    end
    if not bar.locked then
      GameTooltip:AddLine("Shift + Right Click: remove", 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
  end)

  b:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  b:SetScript("OnMouseUp", function()
    local bar = GetBar(this._barIndex)
    if not bar or bar.locked then return end
    OctoCooldownsDB.active = this._barIndex
    if arg1 == "RightButton" and IsShiftKeyDown() then
      local idx = this._entryIndex
      if idx and bar.entries[idx] then
        local label = bar.entries[idx].name or tostring(bar.entries[idx].itemID)
        table.remove(bar.entries, idx)
        Chat("removed " .. label .. " from [" .. bar.name .. "]")
        OCD:RebuildBar(this._barIndex)
        OCD:RefreshTitles()
      end
    end
  end)

  b:SetScript("OnReceiveDrag", function()
    local bar = GetBar(this._barIndex)
    if bar and not bar.locked then
      OCD:HandleCursorDrop(this._barIndex)
    end
  end)

  return b
end

local function CreateBarFrame(barIndex)
  local main = CreateFrame("Button", "OctoCooldownsBar" .. barIndex, UIParent)
  main:SetPoint("CENTER", UIParent, "CENTER", 0, -120 - ((barIndex - 1) * 60))
  main:SetWidth(180)
  main:SetHeight(55)
  main:SetMovable(true)
  main:EnableMouse(true)
  main:RegisterForDrag("LeftButton")
  main._barIndex = barIndex
  main.icons = {}
  main:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
  })

  local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", main, "TOPLEFT", 7, -5)
  main.title = title

  local drop = CreateFrame("Button", "OctoCooldownsBar" .. barIndex .. "DropZone", main)
  drop:SetWidth(40)
  drop:SetHeight(40)
  drop:EnableMouse(true)
  drop:RegisterForDrag("LeftButton")
  drop._barIndex = barIndex
  local dropTex = drop:CreateTexture(nil, "BACKGROUND")
  dropTex:SetAllPoints(drop)
  dropTex:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  local dropText = drop:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  dropText:SetPoint("CENTER", drop, "CENTER", 0, 0)
  dropText:SetText("+")
  main.drop = drop

  main:SetScript("OnMouseDown", function()
    local bar = GetBar(this._barIndex)
    if bar and not bar.locked then
      OctoCooldownsDB.active = this._barIndex
      OCD:RefreshTitles()
    end
  end)

  main:SetScript("OnDragStart", function()
    local bar = GetBar(this._barIndex)
    if bar and not bar.locked then
      OctoCooldownsDB.active = this._barIndex
      OCD:RefreshTitles()
      this:StartMoving()
    end
  end)

  main:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    SavePosition(this._barIndex)
  end)

  drop:SetScript("OnReceiveDrag", function()
    local bar = GetBar(this._barIndex)
    if bar and not bar.locked then
      OctoCooldownsDB.active = this._barIndex
      OCD:HandleCursorDrop(this._barIndex)
      OCD:RefreshTitles()
    end
  end)

  drop:SetScript("OnMouseUp", function()
    local bar = GetBar(this._barIndex)
    if bar and not bar.locked then
      OctoCooldownsDB.active = this._barIndex
      OCD:HandleCursorDrop(this._barIndex)
      OCD:RefreshTitles()
    end
  end)

  barFrames[barIndex] = main
  return main
end

local function EnsureBarFrame(barIndex)
  local frame = barFrames[barIndex]
  if not frame then frame = CreateBarFrame(barIndex) end
  frame._barIndex = barIndex
  frame.drop._barIndex = barIndex
  return frame
end

function OCD:RefreshTitles()
  if not OctoCooldownsDB then return end
  local active = ActiveIndex()
  local i = 1
  while i <= table.getn(OctoCooldownsDB.bars) do
    local frame = barFrames[i]
    local bar = GetBar(i)
    if frame and bar then
      local mark = ""
      if i == active then mark = " *" end
      frame.title:SetText("OctoCooldowns [" .. i .. ": " .. bar.name .. "]" .. mark .. " - drag to +")
    end
    i = i + 1
  end
end

local function HideUnusedIcons(frame, fromIndex)
  local i = fromIndex
  while i <= table.getn(frame.icons) do
    frame.icons[i]:Hide()
    i = i + 1
  end
end

function OCD:RebuildBar(barIndex)
  local bar = GetBar(barIndex)
  if not bar then return end
  local main = EnsureBarFrame(barIndex)

  local n = table.getn(bar.entries)
  local cols = tonumber(bar.cols) or 4
  local size = tonumber(bar.size) or 40
  local gap = tonumber(bar.gap) or 4
  if cols < 1 then cols = 1 end
  if size < 20 then size = 20 end
  if gap < 0 then gap = 0 end

  local topOffset = bar.locked and 6 or 24
  local totalCells = n + (bar.locked and 0 or 1)
  if totalCells < 1 then totalCells = 1 end
  local rows = math.ceil(totalCells / cols)
  local actualCols = math.min(cols, totalCells)
  local width = 12 + actualCols * size + math.max(0, actualCols - 1) * gap
  local height = topOffset + 6 + rows * size + math.max(0, rows - 1) * gap
  main:SetWidth(width)
  main:SetHeight(height)

  if bar.locked then
    main:SetBackdropColor(0, 0, 0, 0)
    main:SetBackdropBorderColor(0, 0, 0, 0)
    main.title:Hide()
    main.drop:Hide()
  else
    main:SetBackdropColor(0, 0, 0, 0.70)
    main:SetBackdropBorderColor(0.45, 0.75, 1.0, 0.9)
    main.title:Show()
    main.drop:Show()
  end

  local i = 1
  while i <= n do
    local entry = bar.entries[i]
    local b = main.icons[i]
    if not b then
      b = CreateIcon(barIndex, i, main)
      main.icons[i] = b
    end
    b._barIndex = barIndex
    b._entryIndex = i
    b:SetWidth(size)
    b:SetHeight(size)
    b:ClearAllPoints()
    local row = math.floor((i - 1) / cols)
    local col = math.mod(i - 1, cols)
    b:SetPoint("TOPLEFT", main, "TOPLEFT", 6 + col * (size + gap), -topOffset - row * (size + gap))

    if entry.kind == "spell" then
      ResolveSpell(entry)
      b.count:SetText("")
      b._ocdCountText = ""
      if entry._texture then b.icon:SetTexture(entry._texture) else b.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark") end
    else
      local name, texture = GetItemMeta(entry.itemID)
      if name then entry.name = name end
      entry._texture = texture
      local count = itemCountCache[entry.itemID] or 0
      local countText = ""
      if count > 0 then countText = tostring(count) end
      b.count:SetText(countText)
      b._ocdCountText = countText
      if texture then b.icon:SetTexture(texture) else b.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark") end
    end
    b:Show()
    i = i + 1
  end
  HideUnusedIcons(main, n + 1)

  if not bar.locked then
    main.drop:SetWidth(size)
    main.drop:SetHeight(size)
    main.drop:ClearAllPoints()
    local di = n + 1
    local row = math.floor((di - 1) / cols)
    local col = math.mod(di - 1, cols)
    main.drop:SetPoint("TOPLEFT", main, "TOPLEFT", 6 + col * (size + gap), -topOffset - row * (size + gap))
  end

  main:Show()
  self:UpdateBarCooldowns(barIndex)
  self:RefreshTitles()
end

function OCD:RebuildAll(restorePositions)
  if not OctoCooldownsDB then return end
  local n = table.getn(OctoCooldownsDB.bars)
  local i = 1
  while i <= n do
    EnsureBarFrame(i)
    if restorePositions then RestorePosition(i) end
    self:RebuildBar(i)
    i = i + 1
  end
  i = n + 1
  while i <= table.getn(barFrames) do
    if barFrames[i] then barFrames[i]:Hide() end
    i = i + 1
  end
  self:RefreshTitles()
end

function OCD:AddSpellByName(name, barIndex)
  barIndex = barIndex or ActiveIndex()
  local bar = GetBar(barIndex)
  if not bar then return false end
  local slot, realName, rank, texture = FindSpellByName(name)
  if not slot then
    Chat("spell not found in spellbook: " .. tostring(name))
    return false
  end
  if FindEntryBySpellName(bar, realName) then
    Chat(realName .. " is already tracked in [" .. bar.name .. "]")
    return false
  end
  local e = { kind = "spell", name = realName }
  e._slot = slot
  e._rank = rank
  e._texture = texture
  table.insert(bar.entries, e)
  Chat("added spell to [" .. bar.name .. "]: " .. realName)
  self:RebuildBar(barIndex)
  return true
end

function OCD:AddItemByID(itemID, barIndex)
  barIndex = barIndex or ActiveIndex()
  local bar = GetBar(barIndex)
  if not bar then return false end
  itemID = tonumber(itemID)
  if not itemID then
    Chat("invalid item ID")
    return false
  end
  if FindEntryByItemID(bar, itemID) then
    Chat("item " .. itemID .. " is already tracked in [" .. bar.name .. "]")
    return false
  end
  local name, texture = GetItemMeta(itemID)
  local e = { kind = "item", itemID = itemID, name = name or ("Item " .. itemID) }
  e._texture = texture
  table.insert(bar.entries, e)
  Chat("added item to [" .. bar.name .. "]: " .. e.name)
  self:RebuildBar(barIndex)
  self:RefreshItemCounts()
  return true
end

function OCD:HandleCursorDrop(barIndex)
  barIndex = barIndex or ActiveIndex()
  if not GetCursorInfo then
    Chat("GetCursorInfo is unavailable")
    return
  end
  local kind, a, b = GetCursorInfo()
  if kind == "spell" then
    local spellName = GetSpellName(a, b or BOOK)
    if spellName then
      self:AddSpellByName(spellName, barIndex)
      ClearCursor()
    else
      Chat("could not read spell from cursor")
    end
  elseif kind == "item" then
    local itemID = tonumber(a)
    if not itemID and b then
      local _, _, id = string.find(b, "item:(%d+)")
      itemID = tonumber(id)
    end
    if itemID then
      self:AddItemByID(itemID, barIndex)
      ClearCursor()
    else
      Chat("could not read item from cursor")
    end
  else
    Chat("drag a spell from the spellbook or an item from a bag")
  end
end

function OCD:RefreshItemCounts()
  RefreshItemCountCache()
  if not OctoCooldownsDB then return end
  local bi = 1
  while bi <= table.getn(OctoCooldownsDB.bars) do
    local bar = GetBar(bi)
    local main = barFrames[bi]
    if bar and main then
      local ei = 1
      while ei <= table.getn(bar.entries) do
        local e = bar.entries[ei]
        local b = main.icons[ei]
        if e.kind == "item" and b then
          local count = itemCountCache[e.itemID] or 0
          local countText = ""
          if count > 0 then countText = tostring(count) end
          if b._ocdCountText ~= countText then
            b.count:SetText(countText)
            b._ocdCountText = countText
          end
        end
        ei = ei + 1
      end
    end
    bi = bi + 1
  end
end

function OCD:UpdateBarCooldowns(barIndex)
  local bar = GetBar(barIndex)
  local main = barFrames[barIndex]
  if not bar or not main then return end
  local now = GetTime()
  local i = 1
  local n = table.getn(bar.entries)
  while i <= n do
    local e = bar.entries[i]
    local b = main.icons[i]
    if b and b:IsShown() then
      local start, duration, enabled = 0, 0, 1
      if e.kind == "spell" then
        if not e._slot then ResolveSpell(e) end
        if e._slot then
          start, duration, enabled = GetSpellCooldown(e._slot, BOOK)
        end
      elseif e.kind == "item" then
        start, duration, enabled = GetItemCooldown(e.itemID)
      end

      start = start or 0
      duration = duration or 0
      local remain = 0
      if start > 0 and duration > GCD_THRESHOLD then
        remain = (start + duration) - now
      end

      local cooldownActive = false
      local timerText = ""
      if remain > 0.05 then
        cooldownActive = true
        timerText = FormatTime(remain)
      end

      if b._ocdCooldownActive ~= cooldownActive then
        if cooldownActive then
          b.icon:SetVertexColor(0.35, 0.35, 0.35)
        else
          b.icon:SetVertexColor(1, 1, 1)
        end
        b._ocdCooldownActive = cooldownActive
      end
      if b._ocdTimerText ~= timerText then
        b.timer:SetText(timerText)
        b._ocdTimerText = timerText
      end
    end
    i = i + 1
  end
end

function OCD:UpdateCooldowns()
  if not OctoCooldownsDB then return end
  local i = 1
  while i <= table.getn(OctoCooldownsDB.bars) do
    self:UpdateBarCooldowns(i)
    i = i + 1
  end
end

function OCD:SetActive(barIndex, quiet)
  local bar = GetBar(barIndex)
  if not bar then return false end
  OctoCooldownsDB.active = barIndex
  self:RefreshTitles()
  if not quiet then Chat("active bar: [" .. barIndex .. ": " .. bar.name .. "]") end
  return true
end

function OCD:SetLocked(v, barIndex)
  barIndex = barIndex or ActiveIndex()
  local bar = GetBar(barIndex)
  if not bar then return end
  bar.locked = v and true or false
  self:RebuildBar(barIndex)
  if bar.locked then
    Chat("locked [" .. bar.name .. "]")
  else
    Chat("unlocked [" .. bar.name .. "] - drag spells/items to +")
  end
end

function OCD:SetAllLocked(v)
  local i = 1
  while i <= table.getn(OctoCooldownsDB.bars) do
    OctoCooldownsDB.bars[i].locked = v and true or false
    self:RebuildBar(i)
    i = i + 1
  end
  if v then Chat("all bars locked") else Chat("all bars unlocked") end
end

function OCD:CenterBar(barIndex)
  barIndex = barIndex or ActiveIndex()
  local bar = GetBar(barIndex)
  local frame = EnsureBarFrame(barIndex)
  if not bar or not frame then return end

  local cx, cy = frame:GetCenter()
  local px, py = UIParent:GetCenter()
  if not py then py = (UIParent:GetHeight() or 0) / 2 end
  if not cy then cy = py + (bar.y or 0) end

  bar.point = "CENTER"
  bar.x = 0
  bar.y = cy - py
  RestorePosition(barIndex)
  Chat("centered horizontally [" .. bar.name .. "]")
end

function OCD:List(barIndex)
  barIndex = barIndex or ActiveIndex()
  local bar = GetBar(barIndex)
  if not bar then return end
  local n = table.getn(bar.entries)
  Chat("[" .. barIndex .. ": " .. bar.name .. "] " .. n .. " tracked")
  if n == 0 then return end
  local i = 1
  while i <= n do
    local e = bar.entries[i]
    if e.kind == "spell" then
      Chat(i .. ". spell: " .. (e.name or "?"))
    else
      Chat(i .. ". item: " .. (e.name or "?") .. " [" .. tostring(e.itemID) .. "]")
    end
    i = i + 1
  end
end

function OCD:ListBars()
  local active = ActiveIndex()
  local i = 1
  while i <= table.getn(OctoCooldownsDB.bars) do
    local bar = GetBar(i)
    local mark = " "
    if i == active then mark = "*" end
    Chat(mark .. " " .. i .. ". " .. bar.name .. " | " .. table.getn(bar.entries) .. " entries | " .. (bar.locked and "locked" or "unlocked"))
    i = i + 1
  end
end

function OCD:NewBar(name)
  local index = table.getn(OctoCooldownsDB.bars) + 1
  name = Trim(name or "")
  if name == "" then name = DefaultBarName(index) end
  local y = -120 - ((index - 1) * 60)
  table.insert(OctoCooldownsDB.bars, NewBar(name, y))
  OctoCooldownsDB.active = index
  EnsureBarFrame(index)
  RestorePosition(index)
  self:RebuildBar(index)
  self:RefreshTitles()
  Chat("created bar [" .. index .. ": " .. name .. "]")
end

function OCD:DeleteBar(barIndex)
  local n = table.getn(OctoCooldownsDB.bars)
  if n <= 1 then
    Chat("cannot delete the last bar; use /ocd clear or /ocd reset")
    return
  end
  local bar = GetBar(barIndex)
  if not bar then return end
  local name = bar.name
  table.remove(OctoCooldownsDB.bars, barIndex)
  if OctoCooldownsDB.active > table.getn(OctoCooldownsDB.bars) then
    OctoCooldownsDB.active = table.getn(OctoCooldownsDB.bars)
  elseif OctoCooldownsDB.active > barIndex then
    OctoCooldownsDB.active = OctoCooldownsDB.active - 1
  elseif OctoCooldownsDB.active == barIndex then
    OctoCooldownsDB.active = math.min(barIndex, table.getn(OctoCooldownsDB.bars))
  end
  self:RebuildAll(true)
  Chat("deleted bar [" .. name .. "]")
end

function OCD:ResetBar(barIndex)
  barIndex = barIndex or ActiveIndex()
  local old = GetBar(barIndex)
  if not old then return end
  local name = old.name
  OctoCooldownsDB.bars[barIndex] = NewBar(name, -120 - ((barIndex - 1) * 60))
  RestorePosition(barIndex)
  self:RebuildBar(barIndex)
  Chat("reset [" .. name .. "]")
end

local function Help()
  Chat("ACTIVE BAR commands:")
  Chat("/ocd new <name> | bar <n/name> | bars | rename <name> | delbar [n/name]")
  Chat("/ocd center  - center active bar horizontally")
  Chat("/ocd unlock | lock | unlockall | lockall")
  Chat("/ocd add <spell name> | item <itemID>")
  Chat("/ocd remove <number> | move <from> <to>")
  Chat("/ocd cols <1-12> | size <20-80> | gap <0-20>")
  Chat("/ocd update [0.05-1.00]  - cooldown refresh interval; default 0.10")
  Chat("/ocd list | clear | reset | resetall")
  Chat("Unlocked: drag spell/item to that bar's +; Shift+RightClick removes it.")
end

SLASH_OCTOCOOLDOWNS1 = "/ocd"
SLASH_OCTOCOOLDOWNS2 = "/octocd"
SlashCmdList["OCTOCOOLDOWNS"] = function(msg)
  EnsureDB()
  msg = Trim(msg or "")
  if msg == "" then
    local i = ActiveIndex()
    OCD:SetLocked(not GetBar(i).locked, i)
    return
  end

  local _, _, cmd, rest = string.find(msg, "^(%S+)%s*(.-)$")
  cmd = string.lower(cmd or "")
  rest = Trim(rest or "")
  local active = ActiveIndex()
  local bar = GetBar(active)

  if cmd == "lock" then
    OCD:SetLocked(true, active)
  elseif cmd == "unlock" or cmd == "edit" then
    OCD:SetLocked(false, active)
  elseif cmd == "lockall" then
    OCD:SetAllLocked(true)
  elseif cmd == "unlockall" then
    OCD:SetAllLocked(false)
  elseif cmd == "center" then
    OCD:CenterBar(active)
  elseif cmd == "centerall" then
    local i = 1
    while i <= table.getn(OctoCooldownsDB.bars) do
      OCD:CenterBar(i)
      i = i + 1
    end
  elseif cmd == "new" or cmd == "newbar" then
    OCD:NewBar(rest)
  elseif cmd == "bar" or cmd == "select" then
    local i = FindBarIndex(rest)
    if i then OCD:SetActive(i) else Chat("bar not found: " .. rest) end
  elseif cmd == "bars" then
    OCD:ListBars()
  elseif cmd == "rename" then
    if rest == "" then
      Chat("usage: /ocd rename <name>")
    else
      bar.name = rest
      OCD:RefreshTitles()
      Chat("renamed active bar to [" .. rest .. "]")
    end
  elseif cmd == "delbar" or cmd == "deletebar" then
    local i = active
    if rest ~= "" then i = FindBarIndex(rest) end
    if i then OCD:DeleteBar(i) else Chat("bar not found: " .. rest) end
  elseif cmd == "add" then
    if rest == "" then Chat("usage: /ocd add <spell name>") else OCD:AddSpellByName(rest, active) end
  elseif cmd == "item" then
    OCD:AddItemByID(rest, active)
  elseif cmd == "remove" or cmd == "rm" then
    local idx = tonumber(rest)
    if idx and bar.entries[idx] then
      table.remove(bar.entries, idx)
      OCD:RebuildBar(active)
    else
      Chat("usage: /ocd remove <number>")
    end
  elseif cmd == "move" then
    local _, _, a, b = string.find(rest, "^(%d+)%s+(%d+)$")
    a = tonumber(a)
    b = tonumber(b)
    local n = table.getn(bar.entries)
    if a and b and a >= 1 and a <= n and b >= 1 and b <= n then
      local e = table.remove(bar.entries, a)
      table.insert(bar.entries, b, e)
      OCD:RebuildBar(active)
    else
      Chat("usage: /ocd move <from> <to>")
    end
  elseif cmd == "cols" then
    local v = tonumber(rest)
    if v and v >= 1 and v <= 12 then bar.cols = v; OCD:RebuildBar(active) else Chat("cols: 1-12") end
  elseif cmd == "size" then
    local v = tonumber(rest)
    if v and v >= 20 and v <= 80 then bar.size = v; OCD:RebuildBar(active) else Chat("size: 20-80") end
  elseif cmd == "gap" then
    local v = tonumber(rest)
    if v and v >= 0 and v <= 20 then bar.gap = v; OCD:RebuildBar(active) else Chat("gap: 0-20") end
  elseif cmd == "update" then
    if rest == "" then
      Chat("cooldown update interval: " .. tostring(OctoCooldownsDB.updateInterval or DEFAULT_UPDATE_INTERVAL) .. " sec")
    else
      local v = tonumber(rest)
      if v and v >= MIN_UPDATE_INTERVAL and v <= MAX_UPDATE_INTERVAL then
        OctoCooldownsDB.updateInterval = v
        updateElapsed = 0
        Chat("cooldown update interval set to " .. tostring(v) .. " sec")
      else
        Chat("update interval: 0.05-1.00 sec")
      end
    end
  elseif cmd == "list" then
    OCD:List(active)
  elseif cmd == "clear" then
    bar.entries = {}
    bar.locked = false
    OCD:RebuildBar(active)
  elseif cmd == "reset" then
    OCD:ResetBar(active)
  elseif cmd == "resetall" then
    OctoCooldownsDB = { version = 3, active = 1, updateInterval = DEFAULT_UPDATE_INTERVAL, bars = { NewBar("Main", -120) } }
    OCD:RebuildAll(true)
    Chat("all settings reset")
  elseif cmd == "help" then
    Help()
  else
    Help()
  end
end

OCD:RegisterEvent("VARIABLES_LOADED")
OCD:RegisterEvent("PLAYER_ENTERING_WORLD")
OCD:RegisterEvent("SPELLS_CHANGED")
OCD:RegisterEvent("LEARNED_SPELL_IN_TAB")
OCD:RegisterEvent("BAG_UPDATE")

OCD:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    EnsureDB()
    OCD:RebuildAll(true)
    local i = 1
    while i <= table.getn(OctoCooldownsDB.bars) do
      local bar = GetBar(i)
      if table.getn(bar.entries) == 0 then bar.locked = false end
      i = i + 1
    end
    OCD:RebuildAll(false)
    OCD:RefreshItemCounts()
    Chat("loaded. /ocd help")
  elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
    if OctoCooldownsDB then OCD:RebuildAll(false) end
  elseif event == "PLAYER_ENTERING_WORLD" then
    if OctoCooldownsDB then
      OCD:RebuildAll(true)
      OCD:RefreshItemCounts()
    end
  elseif event == "BAG_UPDATE" then
    if OctoCooldownsDB then bagCountsDirty = true end
  end
end)

OCD:SetScript("OnUpdate", function()
  updateElapsed = updateElapsed + (arg1 or 0)
  local interval = DEFAULT_UPDATE_INTERVAL
  if OctoCooldownsDB and OctoCooldownsDB.updateInterval then
    interval = OctoCooldownsDB.updateInterval
  end
  if updateElapsed >= interval then
    updateElapsed = 0
    if bagCountsDirty then
      bagCountsDirty = false
      OCD:RefreshItemCounts()
    end
    OCD:UpdateCooldowns()
  end
end)
