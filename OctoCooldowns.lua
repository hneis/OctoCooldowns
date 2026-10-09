-- OctoCooldowns 0.3.0
-- Retail-like personal cooldown bars for WoW 1.12 / OctoWoW.
-- Lua 5.0 compatible: no # operator, no select(), old WoW event globals.

local OCD = CreateFrame("Frame", "OctoCooldownsEventFrame", UIParent)
local BOOK = BOOKTYPE_SPELL or "spell"
local DEFAULT_UPDATE_INTERVAL = 0.10
local MIN_UPDATE_INTERVAL = 0.05
local MAX_UPDATE_INTERVAL = 1.00
local GCD_THRESHOLD = 1.80
local REACTIVE_DURATION = 4.00
local updateElapsed = 0
local barFrames = {}
local itemCountCache = {}
local bagCountsDirty = false
local targetSerial = 0
local reactivePatterns = {}
local enhancedReactiveEventsRegistered = false
local reactiveState = {
  riposte = { expires = 0 },
  surprise = { expires = 0 }
}

local REACTIVE_NAMES = {
  ["Riposte"] = "riposte",
  ["riposte"] = "riposte",
  ["Ответный удар"] = "riposte",
  ["ответный удар"] = "riposte",
  ["Surprise Attack"] = "surprise",
  ["surprise attack"] = "surprise",
  ["Неожиданная атака"] = "surprise",
  ["неожиданная атака"] = "surprise",
  ["Внезапное нападение"] = "surprise",
  ["внезапное нападение"] = "surprise"
}

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

local function ReactiveKindByName(name)
  if not name then return nil end
  return REACTIVE_NAMES[name] or REACTIVE_NAMES[string.lower(name)]
end

local function IsReactiveEntry(entry)
  return entry and entry.kind == "spell" and (entry.reactive == "riposte" or entry.reactive == "surprise")
end

local PATTERN_MAGIC = {
  ["("] = true, [")"] = true, ["."] = true, ["%"] = true,
  ["+"] = true, ["-"] = true, ["*"] = true, ["?"] = true,
  ["["] = true, ["]"] = true, ["^"] = true, ["$"] = true
}

local function CompileGlobalFormat(template)
  if type(template) ~= "string" or template == "" then return nil end
  local out = "^"
  local slots = {}
  local nextSlot = 1
  local i = 1
  local n = string.len(template)

  while i <= n do
    local c = string.sub(template, i, i)
    if c == "%" then
      local rest = string.sub(template, i)
      local _, tokenEnd, position, kind = string.find(rest, "^%%(%d+)%$([sdf])")
      local slot = nil
      if tokenEnd then
        slot = tonumber(position)
      else
        _, tokenEnd, position, kind = string.find(rest, "^%%(%d+)([sdf])")
        if tokenEnd then
          slot = tonumber(position)
        else
          _, tokenEnd, kind = string.find(rest, "^%%([sdf])")
        end
        if tokenEnd then
          if not slot then
            slot = nextSlot
            nextSlot = nextSlot + 1
          end
        end
      end

      if tokenEnd then
        table.insert(slots, slot)
        if kind == "s" then
          out = out .. "(.-)"
        elseif kind == "d" then
          out = out .. "(%d+)"
        else
          out = out .. "([%d%.]+)"
        end
        i = i + tokenEnd
      elseif string.sub(template, i + 1, i + 1) == "%" then
        out = out .. "%%"
        i = i + 2
      else
        out = out .. "%%"
        i = i + 1
      end
    else
      if PATTERN_MAGIC[c] then out = out .. "%" end
      out = out .. c
      i = i + 1
    end
  end

  return { pattern = out .. "$", slots = slots }
end

local function MatchGlobalFormat(message, compiled)
  if not message or not compiled then return nil end
  local startPos, endPos, a, b, c, d, e, f = string.find(message, compiled.pattern)
  if not startPos then return nil end
  local captures = { a, b, c, d, e, f }
  local values = {}
  local i = 1
  while i <= table.getn(compiled.slots) do
    values[compiled.slots[i]] = captures[i]
    i = i + 1
  end
  return values
end

local function InitializeReactivePatterns()
  reactivePatterns.whiteDodge = CompileGlobalFormat(VSDODGESELFOTHER)
  reactivePatterns.spellDodge = CompileGlobalFormat(SPELLDODGEDSELFOTHER)
  reactivePatterns.spellResults = {}

  local function AddResultPattern(template)
    local compiled = CompileGlobalFormat(template)
    if compiled then table.insert(reactivePatterns.spellResults, compiled) end
  end

  AddResultPattern(SPELLLOGSELFOTHER)
  AddResultPattern(SPELLLOGCRITSELFOTHER)
  AddResultPattern(SPELLLOGSCHOOLSELFOTHER)
  AddResultPattern(SPELLLOGCRITSCHOOLSELFOTHER)
  AddResultPattern(SPELLLOGABSORBSELFOTHER)
  AddResultPattern(SPELLMISSSELFOTHER)
  AddResultPattern(SPELLDODGEDSELFOTHER)
  AddResultPattern(SPELLPARRIEDSELFOTHER)
  AddResultPattern(SPELLBLOCKEDSELFOTHER)
  AddResultPattern(SPELLRESISTSELFOTHER)
  AddResultPattern(SPELLIMMUNESELFOTHER)
  AddResultPattern(SPELLEVADEDSELFOTHER)
  AddResultPattern(SPELLDEFLECTEDSELFOTHER)
  AddResultPattern(SPELLREFLECTSELFOTHER)
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
  local i = 1
  while i <= table.getn(bar.entries) do
    local entry = bar.entries[i]
    if entry.kind == "spell" and entry.reactive == nil then
      entry.reactive = ReactiveKindByName(entry.name)
    end
    i = i + 1
  end
end

local function EnsureDB()
  if not OctoCooldownsDB then
    OctoCooldownsDB = { version = 4, active = 1, updateInterval = DEFAULT_UPDATE_INTERVAL, bars = { NewBar("Main", -120) } }
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
    OctoCooldownsDB = { version = 4, active = 1, updateInterval = DEFAULT_UPDATE_INTERVAL, bars = { bar } }
    Chat("migrated 0.1 settings to multi-bar format")
  end

  OctoCooldownsDB.version = 4
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

local function LegacyTrue(value)
  return value == true or value == 1
end

local function NormalizeGuid(guid)
  if guid == nil then return nil end
  return tostring(guid)
end

local function GetUnitGuidCompat(unit)
  if type(GetUnitGUID) == "function" then
    local guid = GetUnitGUID(unit)
    if guid then return NormalizeGuid(guid) end
  end
  if type(UnitExists) == "function" then
    local exists, guid = UnitExists(unit)
    if exists and guid then return NormalizeGuid(guid) end
    if exists and exists ~= true and exists ~= 1 then return NormalizeGuid(exists) end
  end
  return nil
end

local function CurrentTargetName()
  if type(UnitExists) == "function" and not UnitExists("target") then return nil end
  if type(UnitName) ~= "function" then return nil end
  return UnitName("target")
end

local function ReactiveTargetMatches(kind)
  if kind ~= "surprise" then return true end
  local state = reactiveState.surprise
  if not state.targetGuid and not state.targetName then return true end

  local currentGuid = GetUnitGuidCompat("target")
  if state.targetGuid and currentGuid then
    return state.targetGuid == currentGuid
  end

  local currentName = CurrentTargetName()
  if state.targetName and currentName then
    if state.targetName ~= currentName then return false end
    if state.targetSerial then return state.targetSerial == targetSerial end
    return true
  end

  if not currentGuid and not currentName then return false end
  return true
end

local function ClearReactiveState(kind)
  local state = reactiveState[kind]
  if not state then return false end
  local changed = (state.expires or 0) > 0
  state.expires = 0
  state.triggeredAt = nil
  state.targetGuid = nil
  state.targetName = nil
  state.targetSerial = nil
  state.apiReadySeen = nil
  state.hiddenByApi = nil
  return changed
end

function OCD:ClearReactiveStates(rebuild)
  local changed = ClearReactiveState("riposte")
  if ClearReactiveState("surprise") then changed = true end
  if changed and rebuild and OctoCooldownsDB then self:RebuildAll(false) end
end

function OCD:ActivateReactive(kind, targetGuid, targetName)
  local state = reactiveState[kind]
  if not state then return end
  local now = GetTime()
  targetGuid = NormalizeGuid(targetGuid)

  local duplicateTarget = kind ~= "surprise"
  if kind == "surprise" then
    if state.targetGuid and targetGuid and state.targetGuid == targetGuid then
      duplicateTarget = true
    elseif state.targetName and targetName and state.targetName == targetName then
      if not state.targetSerial or state.targetSerial == targetSerial then duplicateTarget = true end
    elseif not state.targetGuid and not state.targetName and not targetGuid and not targetName then
      duplicateTarget = true
    else
      local currentGuid = GetUnitGuidCompat("target")
      local currentName = CurrentTargetName()
      if state.targetGuid and currentGuid == state.targetGuid and targetName and currentName == targetName then
        duplicateTarget = true
      end
    end
  end

  if duplicateTarget and not state.hiddenByApi and state.triggeredAt and now - state.triggeredAt < 0.25 then
    if not state.targetGuid and targetGuid then state.targetGuid = targetGuid end
    if not state.targetName and targetName then state.targetName = targetName end
    return
  end

  state.expires = now + REACTIVE_DURATION
  state.triggeredAt = now
  state.apiReadySeen = nil
  state.hiddenByApi = nil
  if kind == "surprise" then
    state.targetGuid = targetGuid
    state.targetName = targetName
    local currentGuid = GetUnitGuidCompat("target")
    local currentName = CurrentTargetName()
    if not state.targetName and targetGuid and currentGuid == targetGuid then
      state.targetName = currentName
    end
    if (targetGuid and currentGuid == targetGuid) or (targetName and currentName == targetName) then
      state.targetSerial = targetSerial
    elseif targetName and not targetGuid then
      -- A late vanilla message cannot be tied safely after the target changed.
      state.targetSerial = -1
    end
  else
    state.targetGuid = nil
    state.targetName = nil
    state.targetSerial = nil
  end

  if OctoCooldownsDB then self:RebuildAll(false) end
end

local function ReactiveApiReady(entry)
  if not entry or type(IsUsableSpell) ~= "function" then return nil end
  if not entry._slot then ResolveSpell(entry) end
  if not entry._slot then return nil end
  local usable, noMana = IsUsableSpell(entry._slot, BOOK)
  return LegacyTrue(usable) or LegacyTrue(noMana)
end

local function FindReactiveEntry(kind)
  if not OctoCooldownsDB or not OctoCooldownsDB.bars then return nil end
  local bi = 1
  while bi <= table.getn(OctoCooldownsDB.bars) do
    local bar = OctoCooldownsDB.bars[bi]
    local ei = 1
    while ei <= table.getn(bar.entries) do
      local entry = bar.entries[ei]
      if entry.reactive == kind then return entry end
      ei = ei + 1
    end
    bi = bi + 1
  end
  return nil
end

function OCD:ProbeReactiveStates()
  local now = GetTime()
  local kinds = { "riposte", "surprise" }
  local i = 1
  while i <= table.getn(kinds) do
    local kind = kinds[i]
    local state = reactiveState[kind]
    if (state.expires or 0) > 0 then
      if state.expires <= now then
        ClearReactiveState(kind)
      else
        local entry = FindReactiveEntry(kind)
        local ready = ReactiveApiReady(entry)
        if ready == true then
          state.apiReadySeen = true
          state.hiddenByApi = nil
        elseif ready == false and state.apiReadySeen then
          state.hiddenByApi = true
        end
      end
    end
    i = i + 1
  end
end

local function ReactiveEntryIsActive(entry)
  if not IsReactiveEntry(entry) then return false end
  local state = reactiveState[entry.reactive]
  if not state or (state.expires or 0) <= GetTime() then return false end
  if state.hiddenByApi then return false end
  return ReactiveTargetMatches(entry.reactive)
end

local function EntryShouldShow(entry, bar)
  if not IsReactiveEntry(entry) then return true end
  if not bar.locked then return true end
  return ReactiveEntryIsActive(entry)
end

local function BuildBarLayoutKey(bar)
  local key = bar.locked and "L" or "U"
  local i = 1
  while i <= table.getn(bar.entries) do
    key = key .. (EntryShouldShow(bar.entries[i], bar) and "1" or "0")
    i = i + 1
  end
  return key
end

local function ReactiveKindBySpellID(spellID)
  if not spellID or type(GetSpellIdForName) ~= "function" or not OctoCooldownsDB then return nil end
  local bi = 1
  while bi <= table.getn(OctoCooldownsDB.bars) do
    local bar = OctoCooldownsDB.bars[bi]
    local ei = 1
    while ei <= table.getn(bar.entries) do
      local entry = bar.entries[ei]
      if IsReactiveEntry(entry) then
        local entryID = GetSpellIdForName(entry.name)
        if entryID and tonumber(entryID) == tonumber(spellID) then return entry.reactive end
      end
      ei = ei + 1
    end
    bi = bi + 1
  end
  return nil
end

function OCD:ClearReactiveFromSpellMessage(message)
  if not message or not OctoCooldownsDB then return end
  local spellName = nil
  local patterns = reactivePatterns.spellResults or {}
  local patternIndex = 1
  while patternIndex <= table.getn(patterns) do
    local values = MatchGlobalFormat(message, patterns[patternIndex])
    if values and values[1] then
      spellName = values[1]
      break
    end
    patternIndex = patternIndex + 1
  end
  if not spellName then return end

  local changed = false
  local bi = 1
  while bi <= table.getn(OctoCooldownsDB.bars) do
    local bar = OctoCooldownsDB.bars[bi]
    local ei = 1
    while ei <= table.getn(bar.entries) do
      local entry = bar.entries[ei]
      if IsReactiveEntry(entry) and entry.name == spellName then
        if ClearReactiveState(entry.reactive) then changed = true end
      end
      ei = ei + 1
    end
    bi = bi + 1
  end
  if changed then self:RebuildAll(false) end
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
    if entry.reactive == "riposte" then
      GameTooltip:AddLine("Reactive: show for 4 sec after you parry", 1.0, 0.82, 0.1)
    elseif entry.reactive == "surprise" then
      GameTooltip:AddLine("Reactive: show for 4 sec after your target dodges", 1.0, 0.82, 0.1)
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

  local visibleCount = 0
  local countIndex = 1
  while countIndex <= n do
    if EntryShouldShow(bar.entries[countIndex], bar) then visibleCount = visibleCount + 1 end
    countIndex = countIndex + 1
  end

  main._ocdLayoutKey = BuildBarLayoutKey(bar)
  if bar.locked and visibleCount == 0 then
    HideUnusedIcons(main, 1)
    main.title:Hide()
    main.drop:Hide()
    main:Hide()
    return
  end

  local topOffset = bar.locked and 6 or 24
  local totalCells = visibleCount + (bar.locked and 0 or 1)
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
  local displayIndex = 0
  while i <= n do
    local entry = bar.entries[i]
    local b = main.icons[i]
    local shouldShow = EntryShouldShow(entry, bar)
    if shouldShow and not b then
      b = CreateIcon(barIndex, i, main)
      main.icons[i] = b
    end
    if b then
      b._barIndex = barIndex
      b._entryIndex = i
      if b._ocdEntry ~= entry then
        b._ocdEntry = entry
        b._ocdCooldownActive = nil
        b._ocdTimerText = nil
        b._ocdVisualMode = nil
        b.border:SetTexture(0, 0, 0, 1)
      end

      if shouldShow then
        displayIndex = displayIndex + 1
        b:SetWidth(size)
        b:SetHeight(size)
        b:ClearAllPoints()
        local row = math.floor((displayIndex - 1) / cols)
        local col = math.mod(displayIndex - 1, cols)
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
      else
        b:Hide()
      end
    end
    i = i + 1
  end
  HideUnusedIcons(main, n + 1)

  if not bar.locked then
    main.drop:SetWidth(size)
    main.drop:SetHeight(size)
    main.drop:ClearAllPoints()
    local di = visibleCount + 1
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
  e.reactive = ReactiveKindByName(realName)
  e._slot = slot
  e._rank = rank
  e._texture = texture
  table.insert(bar.entries, e)
  local reactiveLabel = ""
  if e.reactive then reactiveLabel = " (reactive: " .. e.reactive .. ")" end
  Chat("added spell to [" .. bar.name .. "]: " .. realName .. reactiveLabel)
  self:RebuildBar(barIndex)
  return true
end

function OCD:SetEntryReactive(barIndex, entryIndex, mode)
  local bar = GetBar(barIndex)
  local entry = bar and bar.entries[entryIndex]
  if not entry or entry.kind ~= "spell" then
    Chat("proc entry must be a tracked spell")
    return false
  end

  mode = string.lower(Trim(mode or ""))
  if mode == "parry" then mode = "riposte" end
  if mode == "dodge" then mode = "surprise" end
  if mode == "off" or mode == "none" or mode == "normal" then mode = false end
  if mode ~= false and mode ~= "riposte" and mode ~= "surprise" then
    Chat("usage: /ocd proc <entry> riposte|surprise|off")
    return false
  end

  entry.reactive = mode
  self:RebuildBar(barIndex)
  if mode then
    Chat("entry " .. entryIndex .. " is reactive: " .. mode)
  else
    Chat("entry " .. entryIndex .. " uses normal cooldown tracking")
  end
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
      if IsReactiveEntry(e) then
        local state = reactiveState[e.reactive]
        local remain = 0
        if state then remain = (state.expires or 0) - now end
        local reactiveActive = remain > 0.05 and ReactiveTargetMatches(e.reactive) and not state.hiddenByApi
        local timerText = ""
        if reactiveActive then timerText = FormatTime(remain) end

        if b._ocdVisualMode ~= "reactive" or b._ocdReactiveActive ~= reactiveActive then
          if reactiveActive then
            b.border:SetTexture(1.0, 0.82, 0.1, 1)
            b.icon:SetVertexColor(1, 1, 1)
          else
            b.border:SetTexture(0, 0, 0, 1)
            b.icon:SetVertexColor(0.35, 0.35, 0.35)
          end
          b._ocdVisualMode = "reactive"
          b._ocdReactiveActive = reactiveActive
        end
        if b._ocdTimerText ~= timerText then
          b.timer:SetText(timerText)
          b._ocdTimerText = timerText
        end
      else
        if b._ocdVisualMode ~= "cooldown" then
          b._ocdVisualMode = "cooldown"
          b._ocdCooldownActive = nil
          b._ocdTimerText = nil
          b._ocdReactiveActive = nil
          b.border:SetTexture(0, 0, 0, 1)
        end

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
    end
    i = i + 1
  end
end

function OCD:UpdateCooldowns()
  if not OctoCooldownsDB then return end
  self:ProbeReactiveStates()
  local layoutIndex = 1
  while layoutIndex <= table.getn(OctoCooldownsDB.bars) do
    local frame = barFrames[layoutIndex]
    local bar = GetBar(layoutIndex)
    local layoutKey = BuildBarLayoutKey(bar)
    if frame and frame._ocdLayoutKey ~= layoutKey then self:RebuildBar(layoutIndex) end
    layoutIndex = layoutIndex + 1
  end
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
      local reactiveLabel = ""
      if e.reactive then reactiveLabel = " [proc: " .. e.reactive .. "]" end
      Chat(i .. ". spell: " .. (e.name or "?") .. reactiveLabel)
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

local function TargetGuidForName(name)
  if name and CurrentTargetName() == name then return GetUnitGuidCompat("target") end
  return nil
end

function OCD:HandleReactiveCombatMessage(eventName, message)
  if not message then return end

  if eventName == "CHAT_MSG_SPELL_SELF_DAMAGE" or eventName == "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF" then
    self:ClearReactiveFromSpellMessage(message)
  end

  if eventName == "CHAT_MSG_COMBAT_SELF_MISSES" then
    local values = MatchGlobalFormat(message, reactivePatterns.whiteDodge)
    if values then
      self:ActivateReactive("surprise", TargetGuidForName(values[1]), values[1])
    end
  elseif eventName == "CHAT_MSG_SPELL_SELF_DAMAGE" or eventName == "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF" then
    local values = MatchGlobalFormat(message, reactivePatterns.spellDodge)
    if values then
      self:ActivateReactive("surprise", TargetGuidForName(values[2]), values[2])
    end
  end
end

local function NampowerAtLeast(requiredMinor)
  if type(GetNampowerVersion) ~= "function" then return false end
  local ok, major, minor = pcall(GetNampowerVersion)
  if not ok then return false end
  major = tonumber(major) or 0
  minor = tonumber(minor) or 0
  return major > 2 or (major == 2 and minor >= requiredMinor)
end

local function SafeRegisterEvent(eventName)
  pcall(function() OCD:RegisterEvent(eventName) end)
end

local function EnableNampowerEvents(cvarName)
  if type(SetCVar) ~= "function" then return false end
  if type(GetCVar) == "function" and tostring(GetCVar(cvarName)) == "1" then return false end
  local ok = pcall(SetCVar, cvarName, "1")
  return ok
end

function OCD:RegisterEnhancedReactiveEvents()
  if enhancedReactiveEventsRegistered then return end
  enhancedReactiveEventsRegistered = true

  local reloadNeeded = false
  if NampowerAtLeast(24) then
    if EnableNampowerEvents("NP_EnableAutoAttackEvents") then reloadNeeded = true end
    SafeRegisterEvent("AUTO_ATTACK_SELF")
    SafeRegisterEvent("AUTO_ATTACK_OTHER")
  end
  if NampowerAtLeast(31) then
    SafeRegisterEvent("SPELL_MISS_SELF")
    SafeRegisterEvent("SPELL_MISS_OTHER")
  end
  if NampowerAtLeast(25) then
    if EnableNampowerEvents("NP_EnableSpellGoEvents") then reloadNeeded = true end
    if EnableNampowerEvents("NP_EnableSpellStartEvents") then reloadNeeded = true end
    SafeRegisterEvent("SPELL_GO_SELF")
    SafeRegisterEvent("SPELL_START_SELF")
  end

  -- SuperWoW exposes this event; pcall keeps stock 1.12 clients safe.
  SafeRegisterEvent("UNIT_CASTEVENT")
  if reloadNeeded then Chat("enabled Nampower combat events; reload once for enhanced tracking") end
end

function OCD:HandleEnhancedReactiveEvent(eventName, a1, a2, a3, a4, a5)
  local playerGuid = GetUnitGuidCompat("player")

  if eventName == "AUTO_ATTACK_SELF" then
    -- In Nampower AUTO_ATTACK_SELF the player is the attack target.
    local targetGuid = NormalizeGuid(a2)
    if tonumber(a5) == 3 and (not playerGuid or targetGuid == playerGuid) then
      self:ActivateReactive("riposte")
    end
  elseif eventName == "AUTO_ATTACK_OTHER" then
    -- AUTO_ATTACK_OTHER includes observed units, so verify the player attacker.
    local attackerGuid = NormalizeGuid(a1)
    if playerGuid and attackerGuid == playerGuid and tonumber(a5) == 2 then
      self:ActivateReactive("surprise", NormalizeGuid(a2), nil)
    end
  elseif eventName == "SPELL_MISS_SELF" then
    -- Nampower: spellId, targetGuid, missInfo.
    if tonumber(a3) == 3 then self:ActivateReactive("surprise", NormalizeGuid(a2), nil) end
  elseif eventName == "SPELL_MISS_OTHER" then
    -- Nampower: spellId, casterGuid, targetGuid, missInfo.
    local targetGuid = NormalizeGuid(a3)
    if playerGuid and targetGuid == playerGuid and tonumber(a4) == 4 then
      self:ActivateReactive("riposte")
    end
  elseif eventName == "SPELL_GO_SELF" then
    local kind = ReactiveKindBySpellID(a2)
    if kind and ClearReactiveState(kind) and OctoCooldownsDB then self:RebuildAll(false) end
  elseif eventName == "SPELL_START_SELF" then
    local kind = ReactiveKindBySpellID(a3)
    if kind and ClearReactiveState(kind) and OctoCooldownsDB then self:RebuildAll(false) end
  elseif eventName == "UNIT_CASTEVENT" then
    local caster = NormalizeGuid(a1)
    local action = a3
    local spellID = a4
    if a2 == "START" then action = a2 end
    local fromPlayer = a1 == "player" or (playerGuid and caster == playerGuid)
    if fromPlayer and (action == "START" or action == "CAST") then
      local kind = ReactiveKindBySpellID(spellID)
      if kind and ClearReactiveState(kind) and OctoCooldownsDB then self:RebuildAll(false) end
    end
  end
end

local function Help()
  Chat("ACTIVE BAR commands:")
  Chat("/ocd new <name> | bar <n/name> | bars | rename <name> | delbar [n/name]")
  Chat("/ocd center  - center active bar horizontally")
  Chat("/ocd unlock | lock | unlockall | lockall")
  Chat("/ocd add <spell name> | item <itemID>")
  Chat("/ocd proc <entry> riposte|surprise|off")
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
  elseif cmd == "proc" or cmd == "reactive" then
    local _, _, entryIndex, mode = string.find(rest, "^(%d+)%s+(%S+)$")
    if entryIndex and mode then
      OCD:SetEntryReactive(active, tonumber(entryIndex), mode)
    else
      Chat("usage: /ocd proc <entry> riposte|surprise|off")
    end
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
    OctoCooldownsDB = { version = 4, active = 1, updateInterval = DEFAULT_UPDATE_INTERVAL, bars = { NewBar("Main", -120) } }
    OCD:ClearReactiveStates(false)
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
OCD:RegisterEvent("UNIT_COMBAT")
OCD:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
OCD:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
OCD:RegisterEvent("CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF")
OCD:RegisterEvent("PLAYER_DEAD")
OCD:RegisterEvent("PLAYER_REGEN_ENABLED")
OCD:RegisterEvent("PLAYER_TARGET_CHANGED")
OCD:RegisterEvent("UNIT_HEALTH")
OCD:RegisterEvent("ACTIONBAR_UPDATE_USABLE")
OCD:RegisterEvent("SPELL_UPDATE_USABLE")

OCD:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    InitializeReactivePatterns()
    EnsureDB()
    OCD:RegisterEnhancedReactiveEvents()
    OCD:ClearReactiveStates(false)
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
      OCD:ClearReactiveStates(false)
      OCD:RebuildAll(true)
      OCD:RefreshItemCounts()
    end
  elseif event == "BAG_UPDATE" then
    if OctoCooldownsDB then bagCountsDirty = true end
  elseif event == "UNIT_COMBAT" then
    if arg1 == "player" and arg2 == "PARRY" then OCD:ActivateReactive("riposte") end
  elseif event == "CHAT_MSG_COMBAT_SELF_MISSES"
      or event == "CHAT_MSG_SPELL_SELF_DAMAGE"
      or event == "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF" then
    OCD:HandleReactiveCombatMessage(event, arg1)
  elseif event == "AUTO_ATTACK_SELF"
      or event == "AUTO_ATTACK_OTHER"
      or event == "SPELL_MISS_SELF"
      or event == "SPELL_MISS_OTHER"
      or event == "SPELL_GO_SELF"
      or event == "SPELL_START_SELF"
      or event == "UNIT_CASTEVENT" then
    local eventName = event
    local a1, a2, a3, a4, a5 = arg1, arg2, arg3, arg4, arg5
    OCD:HandleEnhancedReactiveEvent(eventName, a1, a2, a3, a4, a5)
  elseif event == "PLAYER_DEAD" or event == "PLAYER_REGEN_ENABLED" then
    OCD:ClearReactiveStates(true)
  elseif event == "PLAYER_TARGET_CHANGED" then
    targetSerial = targetSerial + 1
    if OctoCooldownsDB then OCD:RebuildAll(false) end
  elseif event == "UNIT_HEALTH" then
    if arg1 == "target" and type(UnitIsDeadOrGhost) == "function" and UnitIsDeadOrGhost("target") then
      if ClearReactiveState("surprise") and OctoCooldownsDB then OCD:RebuildAll(false) end
    end
  elseif event == "ACTIONBAR_UPDATE_USABLE" or event == "SPELL_UPDATE_USABLE" then
    if OctoCooldownsDB then OCD:UpdateCooldowns() end
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
