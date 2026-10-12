-- OctoCooldowns 0.9.1
-- Retail-like personal cooldown bars for WoW 1.12 / OctoWoW.
-- Lua 5.0 compatible: no # operator, no select(), old WoW event globals.

local OCD = CreateFrame("Frame", "OctoCooldownsEventFrame", UIParent)
local BOOK = BOOKTYPE_SPELL or "spell"
local DEFAULT_UPDATE_INTERVAL = 0.10
local MIN_UPDATE_INTERVAL = 0.05
local MAX_UPDATE_INTERVAL = 1.00
local GCD_THRESHOLD = 1.80
local REACTIVE_DURATION = 4.00
local REACTIVE_DUPLICATE_WINDOW = 0.50
local AURA_SCAN_INTERVAL = 0.50
local AURA_BURST_MIN_SPACING = 0.05
local TIMER_FONT_PATH = "Fonts\\ARIALN.TTF"
local TIMER_FONT_SIZE = 14
local TIMER_FONT_FLAGS = "OUTLINE"
local TIMER_FONT_RASTER_SIZE = 32
local TIMER_PREVIEW_TEXT = "12.3"
local MODE_MARKER_FONT_SIZE = 8
local updateElapsed = 0
local barFrames = {}
local itemCountCache = {}
local bagCountsDirty = false
local targetSerial = 0
local playerInCombat = false
local reactivePatterns = {}
local enhancedReactiveEventsRegistered = false
local reactiveDebug = false
local reactiveDebugSequence = 0
local entryDrag = nil
local auraScanTooltip = nil
local playerAuraSnapshot = { byName = {}, bySpellID = {}, byTexture = {}, ambiguousTextures = {}, count = 0 }
local auraScanDirty = true
local lastAuraScan = 0
local auraScanNextAt = nil
local auraScanRetries = 0
local auraScanReason = nil
local auraLastEvent = nil
local auraLastEventAt = 0
local auraScanCount = 0
local auraNextSafetyAt = 0
local enhancedReactiveSeen = {
  autoSelf = false,
  autoOther = false,
  spellMissSelf = false,
  spellMissOther = false
}
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

local AURA_NAMES = {
  ["Blade Flurry"] = "bladeflurry",
  ["blade flurry"] = "bladeflurry",
  ["Шквал клинков"] = "bladeflurry",
  ["шквал клинков"] = "bladeflurry",
  ["Ghostly Strike"] = "ghostlystrike",
  ["ghostly strike"] = "ghostlystrike",
  ["Призрачный удар"] = "ghostlystrike",
  ["призрачный удар"] = "ghostlystrike",
  ["Evasion"] = "evasion",
  ["evasion"] = "evasion",
  ["Ускользание"] = "evasion",
  ["ускользание"] = "evasion",
  ["Sprint"] = "sprint",
  ["sprint"] = "sprint",
  ["Спринт"] = "sprint",
  ["спринт"] = "sprint",
  ["Slice and Dice"] = "sliceanddice",
  ["slice and dice"] = "sliceanddice",
  ["Мясорубка"] = "sliceanddice",
  ["мясорубка"] = "sliceanddice",
  ["Remorseless Attacks"] = "remorseless",
  ["remorseless attacks"] = "remorseless",
  ["Remorseless"] = "remorseless",
  ["remorseless"] = "remorseless",
  ["Беспощадные атаки"] = "remorseless",
  ["беспощадные атаки"] = "remorseless",
  ["Беспощадность"] = "remorseless",
  ["беспощадность"] = "remorseless",
  ["Envenom"] = "envenom",
  ["envenom"] = "envenom",
  ["Отравление"] = "envenom",
  ["отравление"] = "envenom",
  ["Relentless Strikes"] = "relentless",
  ["relentless strikes"] = "relentless",
  ["Relentless Strikes Effect"] = "relentless",
  ["relentless strikes effect"] = "relentless",
  ["Неослабевающие удары"] = "relentless",
  ["неослабевающие удары"] = "relentless",
  ["Taste for Blood"] = "tasteforblood",
  ["taste for blood"] = "tasteforblood",
  ["Вкус крови"] = "tasteforblood",
  ["вкус крови"] = "tasteforblood"
}

local AURA_KINDS = {
  bladeflurry = {
    timed = false,
    spellIDs = { [13877] = true },
    names = { ["Blade Flurry"] = true, ["Шквал клинков"] = true },
    texture = "Interface\\Icons\\Ability_Warrior_PunishingBlow"
  },
  ghostlystrike = {
    timed = true,
    spellIDs = { [14278] = true },
    names = { ["Ghostly Strike"] = true, ["Призрачный удар"] = true },
    texture = "Interface\\Icons\\Spell_Shadow_Curse"
  },
  evasion = {
    timed = true,
    spellIDs = { [5277] = true },
    names = { ["Evasion"] = true, ["Ускользание"] = true },
    texture = "Interface\\Icons\\Spell_Shadow_ShadowWard"
  },
  sprint = {
    timed = true,
    spellIDs = { [2983] = true, [8696] = true, [11305] = true },
    names = { ["Sprint"] = true, ["Спринт"] = true },
    texture = "Interface\\Icons\\Ability_Rogue_Sprint"
  },
  sliceanddice = {
    timed = true,
    spellIDs = { [5171] = true, [6774] = true },
    names = { ["Slice and Dice"] = true, ["Мясорубка"] = true },
    texture = "Interface\\Icons\\Ability_Rogue_SliceDice"
  },
  remorseless = {
    timed = true,
    synthetic = true,
    spellIDs = { [14143] = true, [14149] = true },
    names = { ["Remorseless"] = true, ["Беспощадность"] = true },
    texture = "Interface\\Icons\\Ability_FiegnDead",
    displayNames = { enUS = "Remorseless Attacks", ruRU = "Беспощадные атаки" }
  },
  envenom = {
    timed = true,
    spellIDs = { [52531] = true },
    names = { ["Envenom"] = true, ["Отравление"] = true },
    texture = "Interface\\Icons\\INV_Sword_31"
  },
  relentless = {
    timed = true,
    synthetic = true,
    showStacks = true,
    spellIDs = { [14181] = true },
    names = {
      ["Relentless Strikes"] = true,
      ["Relentless Strikes Effect"] = true,
      ["Неослабевающие удары"] = true
    },
    texture = "Interface\\Icons\\Ability_Warrior_DecisiveStrike",
    displayNames = { enUS = "Relentless Strikes", ruRU = "Неослабевающие удары" }
  },
  tasteforblood = {
    timed = true,
    synthetic = true,
    spellIDs = { [52529] = true },
    names = { ["Taste for Blood"] = true, ["Вкус крови"] = true },
    texture = "Interface\\Icons\\Ability_Rogue_HungerforBlood",
    displayNames = { enUS = "Taste for Blood", ruRU = "Вкус крови" }
  }
}

local SYNTHETIC_AURA_ALIASES = {
  ["remorseless"] = "remorseless",
  ["remorseless-attacks"] = "remorseless",
  ["remorselessattacks"] = "remorseless",
  ["relentless"] = "relentless",
  ["relentless-strikes"] = "relentless",
  ["relentlessstrikes"] = "relentless",
  ["tasteforblood"] = "tasteforblood",
  ["taste-for-blood"] = "tasteforblood",
  ["tfb"] = "tasteforblood"
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

local function RefreshPlayerCombatState()
  if type(UnitAffectingCombat) == "function" then
    local value = UnitAffectingCombat("player")
    playerInCombat = value == true or value == 1
  end
  return playerInCombat
end

local function ReactiveKindByName(name)
  if not name then return nil end
  return REACTIVE_NAMES[name] or REACTIVE_NAMES[string.lower(name)]
end

local function IsReactiveEntry(entry)
  return entry and entry.kind == "spell" and (entry.reactive == "riposte" or entry.reactive == "surprise")
end

local function AuraKindByName(name)
  if not name then return nil end
  local kind = AURA_NAMES[name] or AURA_NAMES[string.lower(name)]
  if kind then return kind end
  if type(GetSpellIdForName) == "function" then
    local resolvedID = GetSpellIdForName(name)
    local spellID = tonumber(resolvedID)
    if spellID == 13877 then return "bladeflurry" end
    if spellID == 14278 then return "ghostlystrike" end
    if spellID == 5277 then return "evasion" end
    if spellID == 2983 or spellID == 8696 or spellID == 11305 then return "sprint" end
    if spellID == 5171 or spellID == 6774 then return "sliceanddice" end
    if spellID == 14144 or spellID == 14148 or spellID == 14143 or spellID == 14149 then return "remorseless" end
    if spellID == 52531 then return "envenom" end
    if spellID == 14179 or spellID == 14181 then return "relentless" end
    if spellID == 52529 then return "tasteforblood" end
  end
  return nil
end

local function IsAuraEntry(entry)
  return entry and (entry.kind == "spell" or entry.kind == "aura") and AURA_KINDS[entry.aura] ~= nil
end

local function DefaultAuraMode(kind)
  if kind == "ghostlystrike" then return "combined" end
  return "only"
end

local function DefaultNewEntryAuraMode(kind)
  if kind == "evasion" or kind == "sprint" then return nil end
  return DefaultAuraMode(kind)
end

local function ShouldAutoMigrateAura(kind)
  return kind == "bladeflurry" or kind == "ghostlystrike"
end

local function AuraEntryIsCombined(entry)
  return IsAuraEntry(entry) and entry.auraMode == "combined"
end

local function EntryModeLabel(entry)
  if AuraEntryIsCombined(entry) then return "A/CD", "aura" end
  if IsAuraEntry(entry) then return "A", "aura" end
  if IsReactiveEntry(entry) then return "P", "proc" end
  return "CD", "cooldown"
end

local function AuraModeToken(kind, mode)
  if kind == "ghostlystrike" and mode == "combined" then return "ghostlystrike-combined" end
  return kind
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
  reactivePatterns.whiteParry = CompileGlobalFormat(VSPARRYOTHERSELF)
  reactivePatterns.spellParry = CompileGlobalFormat(SPELLPARRIEDOTHERSELF)
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
  t.timerFontSize = false
  t.procCooldownMode = "red"
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
  if bar.timerFontSize ~= false then
    local timerFontSize = tonumber(bar.timerFontSize)
    if timerFontSize and timerFontSize >= 8 and timerFontSize <= 100 then
      bar.timerFontSize = math.floor(timerFontSize + 0.5)
    else
      bar.timerFontSize = false
    end
  end
  if bar.procCooldownMode ~= "hide" and bar.procCooldownMode ~= "red" then bar.procCooldownMode = "red" end
  if not bar.point then bar.point = "CENTER" end
  if bar.x == nil then bar.x = 0 end
  if bar.y == nil then bar.y = -120 - ((index - 1) * 60) end
  if not bar.entries then bar.entries = {} end
  local i = 1
  while i <= table.getn(bar.entries) do
    local entry = bar.entries[i]
    if entry.kind == "spell" and not entry.texture and entry._texture then entry.texture = entry._texture end
    if entry.kind == "spell" and entry.reactive == nil then
      entry.reactive = ReactiveKindByName(entry.name)
    end
    if entry.kind == "spell" and entry.aura == nil and entry.reactive == nil then
      local auraKind = AuraKindByName(entry.name)
      if ShouldAutoMigrateAura(auraKind) then entry.aura = auraKind end
    end
    if IsAuraEntry(entry) and entry.auraMode ~= "only" and entry.auraMode ~= "combined" then
      entry.auraMode = DefaultAuraMode(entry.aura)
    end
    if entry.hideReadyOutOfCombat ~= true then entry.hideReadyOutOfCombat = false end
    if entry.lastAura and not AURA_KINDS[entry.lastAura] then
      entry.lastAura = nil
      entry.lastAuraMode = nil
      entry.lastHideReadyOutOfCombat = nil
    end
    if entry.lastAura and entry.lastAuraMode ~= "only" and entry.lastAuraMode ~= "combined" then
      entry.lastAuraMode = DefaultAuraMode(entry.lastAura)
    end
    if entry.lastHideReadyOutOfCombat ~= true then entry.lastHideReadyOutOfCombat = false end
    i = i + 1
  end
end

local function EnsureDB()
  if not OctoCooldownsDB then
    OctoCooldownsDB = { version = 13, active = 1, updateInterval = DEFAULT_UPDATE_INTERVAL, bars = { NewBar("Main", -120) } }
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
    OctoCooldownsDB = { version = 13, active = 1, updateInterval = DEFAULT_UPDATE_INTERVAL, bars = { bar } }
    Chat("migrated 0.1 settings to multi-bar format")
  end

  OctoCooldownsDB.version = 13
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

local function CatalogTexture(entry)
  if not entry then return nil end
  if entry.reactive == "riposte" then return "Interface\\Icons\\Ability_Warrior_Challange" end
  if entry.reactive == "surprise" then return "Interface\\Icons\\Ability_Rogue_SurpriseAttack" end
  local auraKind = entry.aura
  if not auraKind then auraKind = AuraKindByName(entry.name) end
  if auraKind and AURA_KINDS[auraKind] then return AURA_KINDS[auraKind].texture end
  return nil
end

local function ResolveSpell(entry)
  if entry.kind == "aura" or entry.synthetic then
    entry._slot = nil
    entry._rank = nil
    entry._available = true
    entry._texture = entry.texture or CatalogTexture(entry)
    if not entry.texture and entry._texture then entry.texture = entry._texture end
    return nil
  end

  if not entry.texture and entry._texture then entry.texture = entry._texture end
  local slot, name, rank, texture = FindSpellByName(entry.name)
  entry._slot = slot
  if name then entry.name = name end
  entry._rank = rank
  entry._available = slot ~= nil
  if texture then entry.texture = texture end
  entry._texture = texture or entry.texture or CatalogTexture(entry)
  return slot
end

local function ResolveBarSpells(bar)
  local i = 1
  while i <= table.getn(bar.entries) do
    local entry = bar.entries[i]
    if entry.kind == "spell" or entry.kind == "aura" then ResolveSpell(entry) end
    i = i + 1
  end
end

local function IsUnavailableSpell(entry)
  return entry and entry.kind == "spell" and not entry.synthetic and entry._available == false
end

local function HasAuraEntries()
  if not OctoCooldownsDB or not OctoCooldownsDB.bars then return false end
  local bi = 1
  while bi <= table.getn(OctoCooldownsDB.bars) do
    local bar = OctoCooldownsDB.bars[bi]
    local ei = 1
    while ei <= table.getn(bar.entries) do
      if IsAuraEntry(bar.entries[ei]) then return true end
      ei = ei + 1
    end
    bi = bi + 1
  end
  return false
end

local function GetAuraScanTooltip()
  if auraScanTooltip then return auraScanTooltip end
  auraScanTooltip = CreateFrame("GameTooltip", "OctoCooldownsAuraScanTooltip", UIParent, "GameTooltipTemplate")
  auraScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
  return auraScanTooltip
end

local function RefreshPlayerAuraSnapshot(force, reason)
  local now = GetTime()
  if not force and auraScanNextAt then return end
  if not force and not auraScanDirty and now - lastAuraScan < AURA_SCAN_INTERVAL then return end
  auraScanDirty = false
  lastAuraScan = now
  auraScanCount = auraScanCount + 1
  auraScanReason = reason or (force and "forced" or "safety")
  auraNextSafetyAt = now + AURA_SCAN_INTERVAL

  local snapshot = { byName = {}, bySpellID = {}, byTexture = {}, ambiguousTextures = {}, count = 0 }
  playerAuraSnapshot = snapshot
  if not HasAuraEntries() or type(GetPlayerBuff) ~= "function" then return end

  local tooltip = GetAuraScanTooltip()
  local visibleSlot = 0
  while visibleSlot < 32 do
    local buffIndex, untilCancelled = GetPlayerBuff(visibleSlot, "HELPFUL")
    if buffIndex and buffIndex >= 0 then
      local texture = nil
      if type(GetPlayerBuffTexture) == "function" then texture = GetPlayerBuffTexture(buffIndex) end
      tooltip:ClearLines()
      tooltip:SetPlayerBuff(buffIndex)
      local line = nil
      if type(getglobal) == "function" then
        line = getglobal("OctoCooldownsAuraScanTooltipTextLeft1")
      elseif _G then
        line = _G["OctoCooldownsAuraScanTooltipTextLeft1"]
      end
      local auraName = nil
      if line and line.GetText then auraName = line:GetText() end
      local remaining = 0
      if type(GetPlayerBuffTimeLeft) == "function" then
        local timeLeft = GetPlayerBuffTimeLeft(buffIndex)
        remaining = tonumber(timeLeft) or 0
      end
      local applications = 0
      if type(GetPlayerBuffApplications) == "function" then
        local applicationCount = GetPlayerBuffApplications(buffIndex)
        applications = tonumber(applicationCount) or 0
      end
      local record = {
        name = auraName,
        texture = texture,
        buffIndex = buffIndex,
        persistent = untilCancelled == 1 or untilCancelled == true,
        remaining = remaining,
        stacks = applications
      }
      if remaining > 0 then record.expiresAt = now + remaining end
      if type(GetPlayerBuffID) == "function" then
        local resolvedID = GetPlayerBuffID(buffIndex)
        local spellID = tonumber(resolvedID)
        if spellID then
          record.spellID = spellID
          snapshot.bySpellID[spellID] = record
        end
      end
      if auraName and auraName ~= "" then snapshot.byName[auraName] = record end
      if texture then
        if snapshot.ambiguousTextures[texture] then
          snapshot.byTexture[texture] = nil
        elseif snapshot.byTexture[texture] and snapshot.byTexture[texture] ~= record then
          snapshot.byTexture[texture] = nil
          snapshot.ambiguousTextures[texture] = true
        else
          snapshot.byTexture[texture] = record
        end
      end
      snapshot.count = snapshot.count + 1
    else
      break
    end
    visibleSlot = visibleSlot + 1
  end

  if type(UnitBuff) == "function" then
    local unitSlot = 1
    while unitSlot <= 32 do
      local texture, stacks, spellID = UnitBuff("player", unitSlot)
      if not texture then break end
      local stackCount = tonumber(stacks) or 0
      spellID = tonumber(spellID)
      if spellID then
        local record = snapshot.bySpellID[spellID]
        if not record then
          record = snapshot.byTexture[texture]
        end
        if not record then
          record = { texture = texture, remaining = 0, stacks = stackCount }
        end
        if not snapshot.bySpellID[spellID] then
          record.spellID = spellID
          snapshot.bySpellID[spellID] = record
        end
        if stackCount > 0 then
          record.stacks = stackCount
        end
      elseif stackCount > 0 and snapshot.byTexture[texture] then
        snapshot.byTexture[texture].stacks = stackCount
      end
      unitSlot = unitSlot + 1
    end
  end
  tooltip:Hide()
end

local function FindAuraEntryState(entry)
  if not IsAuraEntry(entry) then return nil end
  local auraKind = AURA_KINDS[entry.aura]
  if auraKind and auraKind.names then
    local auraName, enabled = next(auraKind.names, nil)
    while auraName do
      if enabled and playerAuraSnapshot.byName[auraName] then return playerAuraSnapshot.byName[auraName] end
      auraName, enabled = next(auraKind.names, auraName)
    end
  end

  if entry.name and playerAuraSnapshot.byName[entry.name] then return playerAuraSnapshot.byName[entry.name] end

  if auraKind and auraKind.spellIDs then
    local spellID, enabled = next(auraKind.spellIDs, nil)
    while spellID do
      if enabled and playerAuraSnapshot.bySpellID[spellID] then return playerAuraSnapshot.bySpellID[spellID] end
      spellID, enabled = next(auraKind.spellIDs, spellID)
    end
  end

  if type(GetSpellIdForName) == "function" and entry.name then
    local resolvedID = GetSpellIdForName(entry.name)
    local spellID = tonumber(resolvedID)
    if spellID and playerAuraSnapshot.bySpellID[spellID] then return playerAuraSnapshot.bySpellID[spellID] end
  end

  if entry._texture and playerAuraSnapshot.byTexture[entry._texture] then
    local record = playerAuraSnapshot.byTexture[entry._texture]
    if not record.name or record.name == entry.name
        or (auraKind and auraKind.names and auraKind.names[record.name]) then
      return record
    end
  end
  return nil
end

local function AuraEntryIsActive(entry)
  return FindAuraEntryState(entry) ~= nil
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

local function ReactiveDebugLog(message)
  if not reactiveDebug then return end
  reactiveDebugSequence = reactiveDebugSequence + 1
  Chat("procdebug #" .. reactiveDebugSequence .. " t=" .. string.format("%.3f", GetTime()) .. " " .. message)
end

local function ScheduleAuraScans(reason)
  local now = GetTime()
  auraScanDirty = true
  auraLastEvent = reason or "unknown"
  auraLastEventAt = now
  local nextAt = math.max(now, lastAuraScan + AURA_BURST_MIN_SPACING)
  if not auraScanNextAt or auraScanNextAt > nextAt then auraScanNextAt = nextAt end
  if auraScanRetries < 3 then auraScanRetries = 3 end
  ReactiveDebugLog("schedule aura scans: " .. auraLastEvent)
end

local function SourceIsEnhanced(source)
  return source == "nampower_auto" or source == "nampower_spell"
end

local function ClearReactiveState(kind, preserveConsumed)
  local state = reactiveState[kind]
  if not state then return false end
  local changed = (state.expires or 0) > 0
  state.expires = 0
  state.triggeredAt = nil
  state.targetGuid = nil
  state.targetName = nil
  state.targetSerial = nil
  state.lastTriggerAt = nil
  state.lastSource = nil
  if not preserveConsumed then
    state.consumedAt = nil
    state.consumedSource = nil
    state.consumedTriggerAt = nil
    state.consumedTriggerSource = nil
  end
  return changed
end

local function ConsumeReactiveState(kind, source)
  local state = reactiveState[kind]
  if not state then return false end
  if (state.expires or 0) <= 0 then return false end
  local triggerAt = state.lastTriggerAt
  local triggerSource = state.lastSource
  local changed = ClearReactiveState(kind, true)
  state.consumedAt = GetTime()
  state.consumedSource = source
  state.consumedTriggerAt = triggerAt
  state.consumedTriggerSource = triggerSource
  ReactiveDebugLog("consume " .. kind .. " source=" .. tostring(source))
  return changed
end

function OCD:ClearReactiveStates(rebuild)
  local changed = ClearReactiveState("riposte")
  if ClearReactiveState("surprise") then changed = true end
  if changed and rebuild and OctoCooldownsDB then self:RebuildAll(false) end
end

local function MergeReactiveTarget(state, targetGuid, targetName, replace)
  local currentGuid = GetUnitGuidCompat("target")
  local currentName = CurrentTargetName()

  if replace then
    state.targetGuid = targetGuid
    state.targetName = targetName
    state.targetSerial = nil
  else
    if not state.targetGuid and targetGuid then state.targetGuid = targetGuid end
    if not state.targetName and targetName then state.targetName = targetName end
  end

  if not state.targetName and state.targetGuid and currentGuid == state.targetGuid then
    state.targetName = currentName
  end
  if (state.targetGuid and currentGuid == state.targetGuid)
      or (not state.targetGuid and state.targetName and currentName == state.targetName) then
    state.targetSerial = targetSerial
  elseif replace and state.targetName and not state.targetGuid then
    state.targetSerial = -1
  end
end

function OCD:ActivateReactive(kind, targetGuid, targetName, source)
  local state = reactiveState[kind]
  if not state then return end
  local now = GetTime()
  targetGuid = NormalizeGuid(targetGuid)
  source = source or "unknown"

  if state.consumedAt and now - state.consumedAt <= REACTIVE_DUPLICATE_WINDOW
      and state.consumedTriggerSource and state.consumedTriggerSource ~= source
      and not (SourceIsEnhanced(state.consumedTriggerSource) and SourceIsEnhanced(source)) then
    ReactiveDebugLog("ignore post-consume duplicate " .. kind .. " source=" .. source)
    return
  end

  local active = (state.expires or 0) > now
  local triggerDelta = now - (state.lastTriggerAt or 0)
  local crossSourceDuplicate = active and state.lastSource and state.lastSource ~= source
    and triggerDelta <= REACTIVE_DUPLICATE_WINDOW
    and not (SourceIsEnhanced(state.lastSource) and SourceIsEnhanced(source))
  if crossSourceDuplicate then
    MergeReactiveTarget(state, targetGuid, targetName, false)
    if SourceIsEnhanced(source) then state.lastSource = source end
    ReactiveDebugLog("dedupe " .. kind .. " source=" .. source .. " delta=" .. string.format("%.3f", triggerDelta))
    return
  end

  state.expires = now + REACTIVE_DURATION
  state.triggeredAt = now
  state.lastTriggerAt = now
  state.lastSource = source
  state.consumedAt = nil
  state.consumedSource = nil
  state.consumedTriggerAt = nil
  state.consumedTriggerSource = nil
  if kind == "surprise" then
    MergeReactiveTarget(state, targetGuid, targetName, true)
  else
    -- Riposte is usable after any parry, but retaining the attacker helps diagnostics.
    MergeReactiveTarget(state, targetGuid, targetName, true)
  end

  ReactiveDebugLog("activate " .. kind .. " source=" .. source .. " target=" .. tostring(state.targetGuid or state.targetName))
  if OctoCooldownsDB then self:RebuildAll(false) end
end

local function ReactiveApiReady(entry)
  if not entry or type(IsUsableSpell) ~= "function" then return nil end
  if not entry._slot then ResolveSpell(entry) end
  if not entry._slot then return nil end
  local usable, noMana = IsUsableSpell(entry._slot, BOOK)
  return LegacyTrue(usable) or LegacyTrue(noMana)
end

local function ReactiveCooldownRemaining(entry, now)
  if not entry then return 0 end
  if not entry._slot then ResolveSpell(entry) end
  if not entry._slot then return 0 end
  local start, duration = GetSpellCooldown(entry._slot, BOOK)
  start = start or 0
  duration = duration or 0
  if start <= 0 or duration <= GCD_THRESHOLD then return 0 end
  local remain = (start + duration) - (now or GetTime())
  if remain > 0.05 then return remain end
  return 0
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
      end
    end
    i = i + 1
  end
end

local function ReactiveEntryIsActive(entry)
  if not IsReactiveEntry(entry) then return false end
  local state = reactiveState[entry.reactive]
  if not state or (state.expires or 0) <= GetTime() then return false end
  return ReactiveTargetMatches(entry.reactive)
end

local function EntryShouldShow(entry, bar)
  if IsUnavailableSpell(entry) then
    if not bar.locked then return true end
    return false
  end
  if IsAuraEntry(entry) then
    if not bar.locked then return true end
    if AuraEntryIsCombined(entry) then
      if AuraEntryIsActive(entry) then return true end
      if ReactiveCooldownRemaining(entry, GetTime()) > 0 then return true end
      if entry.hideReadyOutOfCombat and not playerInCombat then return false end
      return true
    end
    return AuraEntryIsActive(entry)
  end
  if not IsReactiveEntry(entry) then return true end
  if not bar.locked then return true end
  if not ReactiveEntryIsActive(entry) then return false end
  if bar.procCooldownMode == "hide" and ReactiveCooldownRemaining(entry, GetTime()) > 0 then return false end
  return true
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
        if ConsumeReactiveState(entry.reactive, "chat_result") then changed = true end
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

local function FindEntryByAuraKind(bar, auraKind)
  local i = 1
  while i <= table.getn(bar.entries) do
    local entry = bar.entries[i]
    if IsAuraEntry(entry) and entry.aura == auraKind then return i end
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

local function ApplyTimerFont(button, bar, timerText)
  if not button or not button.timer or not button.timer.SetFont then return end
  local fontSize = tonumber(bar.timerFontSize) or TIMER_FONT_SIZE
  if timerText == nil then timerText = button._ocdTimerText end
  if timerText == nil and button.timer.GetText then timerText = button.timer:GetText() end
  if timerText == nil then timerText = "" end

  if button.timer.SetTextHeight then
    button.timer:SetFont(TIMER_FONT_PATH, TIMER_FONT_RASTER_SIZE, TIMER_FONT_FLAGS)
    button.timer:SetText(timerText)
    button.timer:SetTextHeight(fontSize)
  else
    button.timer:SetFont(TIMER_FONT_PATH, fontSize, TIMER_FONT_FLAGS)
    button.timer:SetText(timerText)
  end
end

local function SetTimerText(button, bar, timerText)
  if button._ocdTimerText == timerText then return end
  button._ocdTimerText = timerText
  ApplyTimerFont(button, bar, timerText)
end

local function TimerTextWithPreview(bar, timerText)
  if timerText == "" and not bar.locked then return TIMER_PREVIEW_TEXT end
  return timerText
end

local function UpdateModeMarker(button, entry, bar)
  if not button or not button.modeMarker then return end
  if bar.locked then
    button.modeMarker:Hide()
    return
  end

  local label, mode = EntryModeLabel(entry)
  local iconSize = tonumber(bar.size) or 40
  local timerSize = tonumber(bar.timerFontSize) or TIMER_FONT_SIZE
  local safeTimerHeight = iconSize - (2 * (MODE_MARKER_FONT_SIZE + 2))
  if iconSize < 32 or timerSize > safeTimerHeight then
    button.modeMarker:Hide()
    return
  end
  if button.modeMarker.SetFont then
    button.modeMarker:SetFont(TIMER_FONT_PATH, MODE_MARKER_FONT_SIZE, TIMER_FONT_FLAGS)
  end
  if button.modeMarker.SetWidth then button.modeMarker:SetWidth(math.max(1, iconSize - 2)) end
  if button.modeMarker.SetHeight then button.modeMarker:SetHeight(MODE_MARKER_FONT_SIZE + 2) end
  button.modeMarker:SetText(label)
  if mode == "aura" then
    button.modeMarker:SetTextColor(0.15, 0.85, 1.0)
  elseif mode == "proc" then
    button.modeMarker:SetTextColor(1.0, 0.82, 0.1)
  else
    button.modeMarker:SetTextColor(0.85, 0.85, 0.85)
  end
  button.modeMarker:Show()
end

local function EntriesMatch(a, b)
  if not a or not b then return false end
  if IsAuraEntry(a) and IsAuraEntry(b) and a.aura == b.aura then return true end
  if a.kind ~= b.kind then return false end
  if a.kind == "spell" then return a.name == b.name end
  if a.kind == "aura" then return a.aura == b.aura end
  if a.kind == "item" then return a.itemID == b.itemID end
  return false
end

local function BarWouldDuplicate(bar, replacedIndex, incoming)
  local i = 1
  while i <= table.getn(bar.entries) do
    if i ~= replacedIndex and EntriesMatch(bar.entries[i], incoming) then return true end
    i = i + 1
  end
  return false
end

function OCD:BeginEntryDrag(barIndex, entryIndex, frame)
  local bar = GetBar(barIndex)
  if not bar or bar.locked or not bar.entries[entryIndex] then return end
  entryDrag = {
    sourceBar = barIndex,
    sourceIndex = entryIndex,
    sourceBarRef = bar,
    sourceEntry = bar.entries[entryIndex],
    sourceFrame = frame
  }
  if frame then frame._ocdDragEndedAt = nil end
  if frame and frame.SetAlpha then frame:SetAlpha(0.45) end
end

function OCD:SetEntryDragTarget(kind, barIndex, entryIndex, frame)
  if not entryDrag then return end
  local bar = GetBar(barIndex)
  if not bar or bar.locked then return end
  entryDrag.targetKind = kind
  entryDrag.targetBar = barIndex
  entryDrag.targetIndex = entryIndex
  entryDrag.targetFrame = frame
end

function OCD:ClearEntryDragTarget(frame)
  if not entryDrag or entryDrag.targetFrame ~= frame then return end
  entryDrag.targetKind = nil
  entryDrag.targetBar = nil
  entryDrag.targetIndex = nil
  entryDrag.targetFrame = nil
end

function OCD:FinishEntryDrag()
  local drag = entryDrag
  if not drag then return end
  entryDrag = nil
  if drag.sourceFrame then
    drag.sourceFrame._ocdDragEndedAt = GetTime()
    if drag.sourceFrame.SetAlpha then drag.sourceFrame:SetAlpha(1) end
  end

  local focus = nil
  if type(GetMouseFocus) == "function" then focus = GetMouseFocus() end
  if focus and focus._barIndex then
    if focus._entryIndex then
      drag.targetKind = "entry"
      drag.targetBar = focus._barIndex
      drag.targetIndex = focus._entryIndex
    elseif focus._ocdDropZone then
      drag.targetKind = "end"
      drag.targetBar = focus._barIndex
      drag.targetIndex = nil
    end
  end

  local sourceBar = GetBar(drag.sourceBar)
  local targetBar = GetBar(drag.targetBar)
  local sourceEntry = sourceBar and sourceBar.entries[drag.sourceIndex]
  if not sourceBar or sourceBar ~= drag.sourceBarRef or sourceEntry ~= drag.sourceEntry then return end
  if not targetBar or not sourceEntry or sourceBar.locked or targetBar.locked then return end

  if drag.targetKind == "entry" then
    local targetEntry = targetBar.entries[drag.targetIndex]
    if not targetEntry then return end
    if drag.sourceBar == drag.targetBar and drag.sourceIndex == drag.targetIndex then return end
    if drag.sourceBar ~= drag.targetBar then
      if BarWouldDuplicate(sourceBar, drag.sourceIndex, targetEntry)
          or BarWouldDuplicate(targetBar, drag.targetIndex, sourceEntry) then
        Chat("swap would create a duplicate entry")
        return
      end
    end
    sourceBar.entries[drag.sourceIndex], targetBar.entries[drag.targetIndex] = targetEntry, sourceEntry
    Chat("swapped " .. (sourceEntry.name or tostring(sourceEntry.itemID))
      .. " with " .. (targetEntry.name or tostring(targetEntry.itemID)))
  elseif drag.targetKind == "end" then
    if drag.sourceBar ~= drag.targetBar and BarWouldDuplicate(targetBar, nil, sourceEntry) then
      Chat("target bar already tracks " .. (sourceEntry.name or tostring(sourceEntry.itemID)))
      return
    end
    table.remove(sourceBar.entries, drag.sourceIndex)
    table.insert(targetBar.entries, sourceEntry)
    Chat("moved " .. (sourceEntry.name or tostring(sourceEntry.itemID)) .. " to [" .. targetBar.name .. "]")
  else
    return
  end

  OctoCooldownsDB.active = drag.targetBar
  self:RebuildBar(drag.sourceBar)
  if drag.targetBar ~= drag.sourceBar then self:RebuildBar(drag.targetBar) end
  self:RefreshItemCounts()
  self:RefreshTitles()
end

local function CreateIcon(barIndex, index, parent)
  local b = CreateFrame("Button", "OctoCooldownsBar" .. barIndex .. "Icon" .. index, parent)
  b:SetWidth(40)
  b:SetHeight(40)
  b:EnableMouse(true)
  b:RegisterForDrag("LeftButton")
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

  local timer = b:CreateFontString(nil, "OVERLAY")
  timer:SetFont(TIMER_FONT_PATH, TIMER_FONT_RASTER_SIZE, TIMER_FONT_FLAGS)
  timer:SetTextColor(1, 1, 1)
  timer:SetPoint("CENTER", b, "CENTER", 0, 0)
  timer:SetText("")
  if timer.SetTextHeight then timer:SetTextHeight(TIMER_FONT_SIZE) end
  b.timer = timer

  local count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
  count:SetText("")
  b.count = count

  local modeMarker = b:CreateFontString(nil, "OVERLAY")
  modeMarker:SetFont(TIMER_FONT_PATH, MODE_MARKER_FONT_SIZE, TIMER_FONT_FLAGS)
  modeMarker:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
  if modeMarker.SetJustifyH then modeMarker:SetJustifyH("LEFT") end
  modeMarker:SetText("")
  modeMarker:Hide()
  b.modeMarker = modeMarker

  b:SetScript("OnEnter", function()
    if entryDrag then OCD:SetEntryDragTarget("entry", this._barIndex, this._entryIndex, this) end
  end)

  b:SetScript("OnLeave", function()
    OCD:ClearEntryDragTarget(this)
  end)

  b:SetScript("OnDragStart", function()
    OCD:BeginEntryDrag(this._barIndex, this._entryIndex, this)
  end)

  b:SetScript("OnDragStop", function()
    OCD:FinishEntryDrag()
  end)

  b:SetScript("OnMouseUp", function()
    local bar = GetBar(this._barIndex)
    if not bar or bar.locked then return end
    if this._ocdDragEndedAt then
      local elapsed = GetTime() - this._ocdDragEndedAt
      this._ocdDragEndedAt = nil
      if elapsed < 0.25 then return end
    end
    OctoCooldownsDB.active = this._barIndex
    if arg1 == "LeftButton" and type(IsAltKeyDown) == "function" and IsAltKeyDown() then
      OCD:ToggleEntryAura(this._barIndex, this._entryIndex)
    elseif arg1 == "RightButton" and IsShiftKeyDown() then
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
      if entryDrag then
        OCD:SetEntryDragTarget("entry", this._barIndex, this._entryIndex, this)
        OCD:FinishEntryDrag()
        return
      end
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
  drop._ocdDropZone = true
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
      if entryDrag then
        OCD:SetEntryDragTarget("end", this._barIndex, nil, this)
        OCD:FinishEntryDrag()
        return
      end
      OCD:HandleCursorDrop(this._barIndex)
      OCD:RefreshTitles()
    end
  end)

  drop:SetScript("OnMouseUp", function()
    local bar = GetBar(this._barIndex)
    if bar and not bar.locked then
      OctoCooldownsDB.active = this._barIndex
      if entryDrag then
        OCD:SetEntryDragTarget("end", this._barIndex, nil, this)
        OCD:FinishEntryDrag()
        return
      end
      OCD:HandleCursorDrop(this._barIndex)
      OCD:RefreshTitles()
    end
  end)

  drop:SetScript("OnEnter", function()
    if entryDrag then OCD:SetEntryDragTarget("end", this._barIndex, nil, this) end
  end)

  drop:SetScript("OnLeave", function()
    OCD:ClearEntryDragTarget(this)
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

  ResolveBarSpells(bar)

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
      ApplyTimerFont(b, bar)
      UpdateModeMarker(b, entry, bar)

      if shouldShow then
        displayIndex = displayIndex + 1
        b:SetWidth(size)
        b:SetHeight(size)
        b:ClearAllPoints()
        local row = math.floor((displayIndex - 1) / cols)
        local col = math.mod(displayIndex - 1, cols)
        b:SetPoint("TOPLEFT", main, "TOPLEFT", 6 + col * (size + gap), -topOffset - row * (size + gap))

        if entry.kind == "spell" or entry.kind == "aura" then
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
  local detectedAura = AuraKindByName(realName)
  if detectedAura and FindEntryByAuraKind(bar, detectedAura) then
    Chat("aura " .. detectedAura .. " is already tracked in [" .. bar.name .. "]")
    return false
  end
  local defaultAuraMode = DefaultNewEntryAuraMode(detectedAura)
  if detectedAura and defaultAuraMode then
    e.aura = detectedAura
    e.auraMode = defaultAuraMode
  elseif detectedAura then
    e.aura = false
  end
  e._slot = slot
  e._rank = rank
  e._texture = texture
  e.texture = texture
  table.insert(bar.entries, e)
  local reactiveLabel = ""
  if e.reactive then reactiveLabel = " (reactive: " .. e.reactive .. ")" end
  local auraLabel = ""
  if e.aura then auraLabel = " (aura: " .. e.aura .. "/" .. e.auraMode .. ")" end
  Chat("added spell to [" .. bar.name .. "]: " .. realName .. reactiveLabel .. auraLabel)
  if e.aura then
    auraScanDirty = true
    RefreshPlayerAuraSnapshot(true)
  end
  self:RebuildBar(barIndex)
  return true
end

function OCD:AddSyntheticAura(auraKind, barIndex)
  barIndex = barIndex or ActiveIndex()
  local bar = GetBar(barIndex)
  local auraInfo = AURA_KINDS[auraKind]
  if not bar or not auraInfo or not auraInfo.synthetic then
    Chat("usage: /ocd addbuff remorseless|relentless|tasteforblood")
    return false
  end
  if FindEntryByAuraKind(bar, auraKind) then
    Chat("aura " .. auraKind .. " is already tracked in [" .. bar.name .. "]")
    return false
  end

  local locale = "enUS"
  if type(GetLocale) == "function" then locale = GetLocale() or locale end
  local displayNames = auraInfo.displayNames or {}
  local name = displayNames[locale] or displayNames.enUS or auraKind
  local entry = {
    kind = "aura",
    synthetic = true,
    name = name,
    aura = auraKind,
    auraMode = "only",
    texture = auraInfo.texture,
    _texture = auraInfo.texture,
    _available = true
  }
  table.insert(bar.entries, entry)
  auraScanDirty = true
  RefreshPlayerAuraSnapshot(true)
  self:RebuildBar(barIndex)
  Chat("added aura to [" .. bar.name .. "]: " .. name)
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
  if mode then
    entry.aura = false
    entry.auraMode = nil
    entry.hideReadyOutOfCombat = false
  end
  self:RebuildBar(barIndex)
  if mode then
    Chat("entry " .. entryIndex .. " is reactive: " .. mode)
  else
    Chat("entry " .. entryIndex .. " uses normal cooldown tracking")
  end
  return true
end

function OCD:SetEntryAura(barIndex, entryIndex, mode)
  local bar = GetBar(barIndex)
  local entry = bar and bar.entries[entryIndex]
  if not entry or (entry.kind ~= "spell" and entry.kind ~= "aura") then
    Chat("aura entry must be a tracked spell")
    return false
  end

  mode = string.lower(Trim(mode or ""))
  local auraKind = nil
  local auraMode = nil
  if mode == "bladeflurry" or mode == "blade-flurry" or mode == "blade" then
    auraKind = "bladeflurry"
    auraMode = "only"
  elseif mode == "ghostlystrike" or mode == "ghostly-strike" or mode == "ghostly" then
    auraKind = "ghostlystrike"
    auraMode = "only"
  elseif mode == "ghostlystrike-combined" or mode == "ghostly-combined" or mode == "combined" then
    auraKind = "ghostlystrike"
    auraMode = "combined"
  elseif mode == "evasion" or mode == "evasion-aura" then
    auraKind = "evasion"
    auraMode = "only"
  elseif mode == "sprint" or mode == "sprint-aura" then
    auraKind = "sprint"
    auraMode = "only"
  elseif mode == "sliceanddice" or mode == "slice-and-dice" or mode == "slicedice"
      or mode == "slice" or mode == "snd" then
    auraKind = "sliceanddice"
    auraMode = "only"
  elseif mode == "remorseless" or mode == "remorseless-attacks" then
    auraKind = "remorseless"
    auraMode = "only"
  elseif mode == "envenom" then
    auraKind = "envenom"
    auraMode = "only"
  elseif mode == "relentless" or mode == "relentless-strikes" then
    auraKind = "relentless"
    auraMode = "only"
  elseif mode == "tasteforblood" or mode == "taste-for-blood" or mode == "tfb" then
    auraKind = "tasteforblood"
    auraMode = "only"
  elseif mode == "off" or mode == "none" or mode == "normal" then
    auraKind = false
  else
    Chat("usage: /ocd aura <entry> bladeflurry|ghostlystrike|combined|evasion|sprint|sliceanddice|remorseless|envenom|relentless|tasteforblood|off")
    return false
  end

  if entry.kind == "aura" and (not auraKind or auraKind ~= entry.aura) then
    Chat("synthetic aura entries cannot use normal cooldown mode")
    return false
  end
  if auraKind then
    local existingIndex = FindEntryByAuraKind(bar, auraKind)
    if existingIndex and existingIndex ~= entryIndex then
      Chat("aura " .. auraKind .. " is already tracked in [" .. bar.name .. "]")
      return false
    end
  end

  if not auraKind and IsAuraEntry(entry) then
    entry.lastAura = entry.aura
    entry.lastAuraMode = entry.auraMode or DefaultAuraMode(entry.aura)
    entry.lastHideReadyOutOfCombat = entry.hideReadyOutOfCombat == true
  end
  entry.aura = auraKind
  entry.auraMode = auraMode
  if auraKind ~= "ghostlystrike" or auraMode ~= "combined" then
    entry.hideReadyOutOfCombat = false
  elseif entry.hideReadyOutOfCombat ~= true then
    entry.hideReadyOutOfCombat = false
  end
  if auraKind then
    entry.reactive = false
    entry.lastAura = auraKind
    entry.lastAuraMode = auraMode
    entry.lastHideReadyOutOfCombat = entry.hideReadyOutOfCombat == true
  end
  auraScanDirty = true
  RefreshPlayerAuraSnapshot(true)
  self:RebuildBar(barIndex)
  if auraKind then
    Chat("entry " .. entryIndex .. " tracks aura: " .. auraKind .. "/" .. auraMode)
  else
    Chat("entry " .. entryIndex .. " uses normal cooldown tracking")
  end
  return true
end

function OCD:ToggleEntryAura(barIndex, entryIndex)
  local bar = GetBar(barIndex)
  local entry = bar and bar.entries[entryIndex]
  if not bar or bar.locked or not entry or entry.kind ~= "spell" then return false end

  if IsAuraEntry(entry) then
    return self:SetEntryAura(barIndex, entryIndex, "off")
  end

  local auraKind = entry.lastAura
  if not auraKind or not AURA_KINDS[auraKind] then auraKind = AuraKindByName(entry.name) end
  if not auraKind then
    Chat("aura mode is not supported for " .. tostring(entry.name or "this entry"))
    return false
  end

  local auraMode = entry.lastAuraMode
  if auraMode ~= "only" and auraMode ~= "combined" then auraMode = DefaultAuraMode(auraKind) end
  local restoreHide = entry.lastHideReadyOutOfCombat == true
  local changed = self:SetEntryAura(barIndex, entryIndex, AuraModeToken(auraKind, auraMode))
  if changed and auraKind == "ghostlystrike" and auraMode == "combined" then
    entry.hideReadyOutOfCombat = restoreHide
    entry.lastHideReadyOutOfCombat = restoreHide
    self:RebuildBar(barIndex)
  end
  return changed
end

function OCD:SetEntryOOCReady(barIndex, entryIndex, mode)
  local bar = GetBar(barIndex)
  local entry = bar and bar.entries[entryIndex]
  if not entry or entry.aura ~= "ghostlystrike" or entry.auraMode ~= "combined" then
    Chat("ooc setting requires a combined Ghostly Strike entry")
    return false
  end

  mode = string.lower(Trim(mode or ""))
  if mode == "hide" then
    entry.hideReadyOutOfCombat = true
  elseif mode == "show" then
    entry.hideReadyOutOfCombat = false
  else
    Chat("usage: /ocd ooc <entry> hide|show")
    return false
  end

  entry.lastHideReadyOutOfCombat = entry.hideReadyOutOfCombat
  self:RebuildBar(barIndex)
  Chat("ready Ghostly Strike outside combat: " .. (entry.hideReadyOutOfCombat and "hidden" or "shown"))
  return true
end

function OCD:SetProcCooldownMode(barIndex, mode)
  local bar = GetBar(barIndex)
  if not bar then return false end
  mode = string.lower(Trim(mode or ""))
  if mode == "" then
    Chat("proc cooldown style for [" .. bar.name .. "]: " .. tostring(bar.procCooldownMode or "red"))
    return true
  end
  if mode ~= "red" and mode ~= "hide" then
    Chat("usage: /ocd procstyle red|hide")
    return false
  end
  bar.procCooldownMode = mode
  self:RebuildBar(barIndex)
  Chat("proc cooldown style for [" .. bar.name .. "]: " .. mode)
  return true
end

function OCD:SetTimerFontSize(barIndex, value)
  local bar = GetBar(barIndex)
  if not bar then return false end
  value = string.lower(Trim(value or ""))
  if value == "" then
    Chat("timer font size for [" .. bar.name .. "]: " .. (bar.timerFontSize or "default"))
    return true
  end
  if value == "reset" or value == "default" or value == "auto" then
    bar.timerFontSize = false
    self:RebuildBar(barIndex)
    Chat("timer font size for [" .. bar.name .. "]: default")
    return true
  end

  local fontSize = tonumber(value)
  if not fontSize or fontSize < 8 or fontSize > 100 then
    Chat("timer font size: 8-100 or reset")
    return false
  end
  bar.timerFontSize = math.floor(fontSize + 0.5)
  self:RebuildBar(barIndex)
  Chat("timer font size for [" .. bar.name .. "]: " .. bar.timerFontSize)
  return true
end

function OCD:SetProcDebug(mode)
  mode = string.lower(Trim(mode or "status"))
  if mode == "on" then
    reactiveDebug = true
    Chat("proc debug enabled")
  elseif mode == "off" then
    reactiveDebug = false
    Chat("proc debug disabled")
  elseif mode ~= "status" and mode ~= "" then
    Chat("usage: /ocd procdebug on|off|status")
    return
  end

  if mode == "status" or mode == "" then
    RefreshPlayerAuraSnapshot(true)
    local version = "unavailable"
    if type(GetNampowerVersion) == "function" then
      local ok, major, minor, patch = pcall(GetNampowerVersion)
      if ok then version = tostring(major) .. "." .. tostring(minor) .. "." .. tostring(patch or 0) end
    end
    Chat("proc debug=" .. (reactiveDebug and "on" or "off") .. " Nampower=" .. version)
    if type(GetCVar) == "function" then
      Chat("Nampower CVars: auto=" .. tostring(GetCVar("NP_EnableAutoAttackEvents"))
        .. " miss=" .. tostring(GetCVar("NP_EnableSpellMissEvents"))
        .. " go=" .. tostring(GetCVar("NP_EnableSpellGoEvents"))
        .. " start=" .. tostring(GetCVar("NP_EnableSpellStartEvents"))
        .. " auraCast=" .. tostring(GetCVar("NP_EnableAuraCastEvents")))
    end
    Chat("enhanced seen: autoSelf=" .. tostring(enhancedReactiveSeen.autoSelf)
      .. " autoOther=" .. tostring(enhancedReactiveSeen.autoOther)
      .. " spellSelf=" .. tostring(enhancedReactiveSeen.spellMissSelf)
      .. " spellOther=" .. tostring(enhancedReactiveSeen.spellMissOther))
    local bladeState = playerAuraSnapshot.byName["Blade Flurry"]
      or playerAuraSnapshot.byName["Шквал клинков"] or playerAuraSnapshot.bySpellID[13877]
    local ghostlyState = playerAuraSnapshot.byName["Ghostly Strike"]
      or playerAuraSnapshot.byName["Призрачный удар"] or playerAuraSnapshot.bySpellID[14278]
    local ghostlyRemaining = 0
    if ghostlyState and ghostlyState.expiresAt then
      ghostlyRemaining = math.max(0, ghostlyState.expiresAt - GetTime())
    end
    Chat("player auras=" .. tostring(playerAuraSnapshot.count)
      .. " Blade Flurry=" .. tostring(bladeState ~= nil)
      .. " Ghostly Strike=" .. tostring(ghostlyState ~= nil)
      .. " remain=" .. string.format("%.2f", ghostlyRemaining))
    Chat("aura scheduler: scans=" .. auraScanCount
      .. " lastReason=" .. tostring(auraScanReason)
      .. " lastEvent=" .. tostring(auraLastEvent)
      .. " eventAge=" .. string.format("%.3f", math.max(0, GetTime() - auraLastEventAt))
      .. " retries=" .. auraScanRetries)
    local kinds = { "riposte", "surprise" }
    local i = 1
    while i <= table.getn(kinds) do
      local kind = kinds[i]
      local state = reactiveState[kind]
      local entry = FindReactiveEntry(kind)
      local ready = ReactiveApiReady(entry)
      local cooldown = ReactiveCooldownRemaining(entry, GetTime())
      local remain = math.max(0, (state.expires or 0) - GetTime())
      Chat(kind .. ": remain=" .. string.format("%.2f", remain)
        .. " cooldown=" .. string.format("%.2f", cooldown)
        .. " usable=" .. tostring(ready)
        .. " source=" .. tostring(state.lastSource))
      i = i + 1
    end
  end
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
      if IsUnavailableSpell(e) then
        if b._ocdVisualMode ~= "unavailable" then
          b._ocdVisualMode = "unavailable"
          b._ocdCooldownActive = nil
          b._ocdReactiveVisual = nil
          b._ocdAuraVisual = nil
          b.border:SetTexture(0.5, 0.1, 0.1, 1)
          b.icon:SetVertexColor(0.3, 0.3, 0.3)
        end
        if b._ocdCountText ~= "" then
          b.count:SetText("")
          b._ocdCountText = ""
        end
        SetTimerText(b, bar, TimerTextWithPreview(bar, ""))
      elseif IsAuraEntry(e) then
        local auraState = FindAuraEntryState(e)
        local auraActive = auraState ~= nil
        local auraKind = AURA_KINDS[e.aura]
        local auraRemaining = 0
        if auraState and auraState.expiresAt then
          auraRemaining = math.max(0, auraState.expiresAt - now)
        end
        local cooldownRemaining = 0
        if not auraActive and AuraEntryIsCombined(e) then
          cooldownRemaining = ReactiveCooldownRemaining(e, now)
        end
        local visualState = "inactive"
        if auraActive then
          visualState = "active"
        elseif AuraEntryIsCombined(e) then
          if cooldownRemaining > 0 then visualState = "cooldown" else visualState = "ready" end
        end

        if b._ocdVisualMode ~= "aura" or b._ocdAuraVisual ~= visualState then
          if visualState == "active" then
            b.border:SetTexture(0.15, 0.75, 1.0, 1)
            b.icon:SetVertexColor(1, 1, 1)
          elseif visualState == "cooldown" then
            b.border:SetTexture(0, 0, 0, 1)
            b.icon:SetVertexColor(0.35, 0.35, 0.35)
          elseif visualState == "ready" then
            b.border:SetTexture(0, 0, 0, 1)
            b.icon:SetVertexColor(1, 1, 1)
          else
            b.border:SetTexture(0, 0, 0, 1)
            b.icon:SetVertexColor(0.35, 0.35, 0.35)
          end
          b._ocdVisualMode = "aura"
          b._ocdAuraVisual = visualState
          b._ocdReactiveVisual = nil
          b._ocdCooldownActive = nil
        end
        local timerText = ""
        if auraActive and auraKind and auraKind.timed and auraRemaining > 0 then
          timerText = FormatTime(auraRemaining)
        elseif not auraActive and AuraEntryIsCombined(e) and cooldownRemaining > 0 then
          timerText = FormatTime(cooldownRemaining)
        end
        timerText = TimerTextWithPreview(bar, timerText)
        SetTimerText(b, bar, timerText)
        local countText = ""
        if auraActive and auraKind and auraKind.showStacks then
          local stacks = tonumber(auraState.stacks) or 0
          if stacks > 0 then countText = tostring(stacks) end
        end
        if b._ocdCountText ~= countText then
          b.count:SetText(countText)
          b._ocdCountText = countText
        end
      elseif IsReactiveEntry(e) then
        local state = reactiveState[e.reactive]
        local remain = 0
        if state then remain = (state.expires or 0) - now end
        local reactiveActive = remain > 0.05 and ReactiveTargetMatches(e.reactive)
        local cooldownRemain = ReactiveCooldownRemaining(e, now)
        local visualState = "inactive"
        if reactiveActive then
          if cooldownRemain > 0 then visualState = "cooldown" else visualState = "ready" end
        end
        local timerText = ""
        if reactiveActive then timerText = FormatTime(remain) end
        timerText = TimerTextWithPreview(bar, timerText)

        if b._ocdVisualMode ~= "reactive" or b._ocdReactiveVisual ~= visualState then
          if visualState == "ready" then
            b.border:SetTexture(1.0, 0.82, 0.1, 1)
            b.icon:SetVertexColor(1, 1, 1)
          elseif visualState == "cooldown" then
            b.border:SetTexture(1.0, 0.12, 0.12, 1)
            b.icon:SetVertexColor(0.5, 0.5, 0.5)
          else
            b.border:SetTexture(0, 0, 0, 1)
            b.icon:SetVertexColor(0.35, 0.35, 0.35)
          end
          b._ocdVisualMode = "reactive"
          b._ocdReactiveVisual = visualState
          b._ocdAuraVisual = nil
        end
        SetTimerText(b, bar, timerText)
      else
        if b._ocdVisualMode ~= "cooldown" then
          b._ocdVisualMode = "cooldown"
          b._ocdCooldownActive = nil
          b._ocdTimerText = nil
          b._ocdReactiveVisual = nil
          b._ocdAuraVisual = nil
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
        timerText = TimerTextWithPreview(bar, timerText)

        if b._ocdCooldownActive ~= cooldownActive then
          if cooldownActive then
            b.icon:SetVertexColor(0.35, 0.35, 0.35)
          else
            b.icon:SetVertexColor(1, 1, 1)
          end
          b._ocdCooldownActive = cooldownActive
        end
        SetTimerText(b, bar, timerText)
      end
    end
    i = i + 1
  end
end

function OCD:UpdateCooldowns(forceAuraScan, auraReason)
  if not OctoCooldownsDB then return end
  RefreshPlayerAuraSnapshot(forceAuraScan, auraReason)
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

function OCD:ProcessAuraScanSchedule()
  if not OctoCooldownsDB then return false end
  local now = GetTime()

  if auraScanNextAt and now >= auraScanNextAt then
    local retryNumber = 4 - auraScanRetries
    auraScanNextAt = nil
    auraScanDirty = true
    self:UpdateCooldowns(true, "event:" .. tostring(auraLastEvent) .. ":" .. retryNumber)
    auraScanRetries = auraScanRetries - 1
    if auraScanRetries == 2 then
      auraScanNextAt = now + 0.10
    elseif auraScanRetries == 1 then
      auraScanNextAt = now + 0.20
    end
    return true
  end

  if not auraScanNextAt and now >= auraNextSafetyAt then
    auraNextSafetyAt = now + AURA_SCAN_INTERVAL
    if HasAuraEntries() then
      self:UpdateCooldowns(true, "safety")
      return true
    end
  end
  return false
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
    if e.kind == "spell" or e.kind == "aura" then
      local reactiveLabel = ""
      if e.reactive then reactiveLabel = " [proc: " .. e.reactive .. "]" end
      local auraLabel = ""
      if e.aura then auraLabel = " [aura: " .. e.aura .. "/" .. tostring(e.auraMode or DefaultAuraMode(e.aura)) .. "]" end
      if e.hideReadyOutOfCombat then auraLabel = auraLabel .. " [ooc-ready:hidden]" end
      if IsUnavailableSpell(e) then auraLabel = auraLabel .. " [unavailable]" end
      local entryType = e.kind == "aura" and "aura" or "spell"
      Chat(i .. ". " .. entryType .. ": " .. (e.name or "?") .. reactiveLabel .. auraLabel)
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
      if enhancedReactiveSeen.autoOther then
        ReactiveDebugLog("skip white dodge chat; Nampower auto observed")
      else
        self:ActivateReactive("surprise", TargetGuidForName(values[1]), values[1], "chat_white")
      end
    end
  elseif eventName == "CHAT_MSG_SPELL_SELF_DAMAGE" or eventName == "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF" then
    local values = MatchGlobalFormat(message, reactivePatterns.spellDodge)
    if values then
      if enhancedReactiveSeen.spellMissSelf then
        ReactiveDebugLog("skip spell dodge chat; Nampower spell miss observed")
      else
        self:ActivateReactive("surprise", TargetGuidForName(values[2]), values[2], "chat_spell")
      end
    end
  elseif eventName == "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES"
      or eventName == "CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES" then
    local values = MatchGlobalFormat(message, reactivePatterns.whiteParry)
    if values then
      if enhancedReactiveSeen.autoSelf then
        ReactiveDebugLog("skip white parry chat; Nampower auto observed")
      else
        self:ActivateReactive("riposte", TargetGuidForName(values[1]), values[1], "chat_incoming")
      end
    end
  elseif eventName == "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE"
      or eventName == "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE" then
    local values = MatchGlobalFormat(message, reactivePatterns.spellParry)
    if values then
      if enhancedReactiveSeen.spellMissOther then
        ReactiveDebugLog("skip spell parry chat; Nampower spell miss observed")
      else
        self:ActivateReactive("riposte", TargetGuidForName(values[1]), values[1], "chat_incoming")
      end
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
    if EnableNampowerEvents("NP_EnableSpellMissEvents") then reloadNeeded = true end
    SafeRegisterEvent("SPELL_MISS_SELF")
    SafeRegisterEvent("SPELL_MISS_OTHER")
  end
  if NampowerAtLeast(25) then
    if EnableNampowerEvents("NP_EnableSpellGoEvents") then reloadNeeded = true end
    if EnableNampowerEvents("NP_EnableSpellStartEvents") then reloadNeeded = true end
    SafeRegisterEvent("SPELL_GO_SELF")
    SafeRegisterEvent("SPELL_START_SELF")
  end
  SafeRegisterEvent("BUFF_ADDED_SELF")
  SafeRegisterEvent("BUFF_REMOVED_SELF")
  SafeRegisterEvent("BUFF_UPDATE_DURATION_SELF")
  if NampowerAtLeast(20) then
    if EnableNampowerEvents("NP_EnableAuraCastEvents") then reloadNeeded = true end
    SafeRegisterEvent("AURA_CAST_ON_SELF")
  end

  -- SuperWoW exposes this event; pcall keeps stock 1.12 clients safe.
  SafeRegisterEvent("UNIT_CASTEVENT")
  if reloadNeeded then Chat("enabled Nampower combat events; reload once for enhanced tracking") end
end

local function IsMissInfo(value)
  value = tonumber(value)
  return value and value >= 0 and value <= 11
end

function OCD:HandleEnhancedReactiveEvent(eventName, a1, a2, a3, a4, a5, a6, a7)
  local playerGuid = GetUnitGuidCompat("player")
  ReactiveDebugLog("event " .. eventName .. " args=" .. tostring(a1) .. "," .. tostring(a2)
    .. "," .. tostring(a3) .. "," .. tostring(a4) .. "," .. tostring(a5))

  if eventName == "AUTO_ATTACK_SELF" then
    enhancedReactiveSeen.autoSelf = true
    -- In Nampower AUTO_ATTACK_SELF the player is the attack target.
    local targetGuid = NormalizeGuid(a2)
    if tonumber(a5) == 3 and (not playerGuid or targetGuid == playerGuid) then
      self:ActivateReactive("riposte", NormalizeGuid(a1), nil, "nampower_auto")
    end
  elseif eventName == "AUTO_ATTACK_OTHER" then
    enhancedReactiveSeen.autoOther = true
    -- AUTO_ATTACK_OTHER includes observed units, so verify the player attacker.
    local attackerGuid = NormalizeGuid(a1)
    if playerGuid and attackerGuid == playerGuid and tonumber(a5) == 2 then
      self:ActivateReactive("surprise", NormalizeGuid(a2), nil, "nampower_auto")
    end
  elseif eventName == "SPELL_MISS_SELF" then
    enhancedReactiveSeen.spellMissSelf = true
    local targetGuid = NormalizeGuid(a2)
    local missInfo = a3
    if IsMissInfo(a4) then missInfo = a4 end
    if tonumber(missInfo) == 3 then
      self:ActivateReactive("surprise", targetGuid, nil, "nampower_spell")
    end
  elseif eventName == "SPELL_MISS_OTHER" then
    enhancedReactiveSeen.spellMissOther = true
    local casterGuid = NormalizeGuid(a2)
    local targetGuid = NormalizeGuid(a3)
    if playerGuid and NormalizeGuid(a2) == playerGuid then
      -- Alternate ABI: casterGuid, targetGuid, spellId, missInfo.
      casterGuid = NormalizeGuid(a1)
      targetGuid = NormalizeGuid(a2)
    end
    if playerGuid and targetGuid == playerGuid and tonumber(a4) == 4 then
      self:ActivateReactive("riposte", casterGuid, nil, "nampower_spell")
    end
  elseif eventName == "SPELL_GO_SELF" then
    local kind = ReactiveKindBySpellID(a2)
    if kind and ConsumeReactiveState(kind, "nampower_go") and OctoCooldownsDB then self:RebuildAll(false) end
  elseif eventName == "SPELL_START_SELF" then
    local kind = ReactiveKindBySpellID(a3)
    if kind and ConsumeReactiveState(kind, "nampower_start") and OctoCooldownsDB then self:RebuildAll(false) end
  elseif eventName == "UNIT_CASTEVENT" then
    local caster = NormalizeGuid(a1)
    local action = a3
    local spellID = a4
    if a2 == "START" then action = a2 end
    local fromPlayer = a1 == "player" or (playerGuid and caster == playerGuid)
    if fromPlayer and (action == "START" or action == "CAST") then
      local kind = ReactiveKindBySpellID(spellID)
      if kind and ConsumeReactiveState(kind, "superwow_cast") and OctoCooldownsDB then self:RebuildAll(false) end
    end
  end
end

local function Help()
  Chat("ACTIVE BAR commands:")
  Chat("/ocd new <name> | bar <n/name> | bars | rename <name> | delbar [n/name]")
  Chat("/ocd center  - center active bar horizontally")
  Chat("/ocd unlock | lock | unlockall | lockall")
  Chat("/ocd add <spell name> | item <itemID>")
  Chat("/ocd addbuff remorseless|relentless|tasteforblood")
  Chat("/ocd proc <entry> riposte|surprise|off")
  Chat("/ocd aura <entry> bladeflurry|ghostlystrike|combined|evasion|sprint|sliceanddice|remorseless|envenom|relentless|tasteforblood|off")
  Chat("/ocd ooc <entry> hide|show")
  Chat("/ocd procstyle red|hide")
  Chat("/ocd timerfont <8-100>|reset")
  Chat("/ocd procdebug on|off|status")
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
  elseif cmd == "addbuff" then
    local auraKind = string.lower(Trim(rest or ""))
    auraKind = SYNTHETIC_AURA_ALIASES[auraKind] or auraKind
    OCD:AddSyntheticAura(auraKind, active)
  elseif cmd == "proc" or cmd == "reactive" then
    local _, _, entryIndex, mode = string.find(rest, "^(%d+)%s+(%S+)$")
    if entryIndex and mode then
      OCD:SetEntryReactive(active, tonumber(entryIndex), mode)
    else
      Chat("usage: /ocd proc <entry> riposte|surprise|off")
    end
  elseif cmd == "aura" then
    local _, _, entryIndex, mode = string.find(rest, "^(%d+)%s+(%S+)$")
    if entryIndex and mode then
      OCD:SetEntryAura(active, tonumber(entryIndex), mode)
    else
      Chat("usage: /ocd aura <entry> bladeflurry|ghostlystrike|combined|evasion|sprint|sliceanddice|remorseless|envenom|relentless|tasteforblood|off")
    end
  elseif cmd == "ooc" then
    local _, _, entryIndex, mode = string.find(rest, "^(%d+)%s+(%S+)$")
    if entryIndex and mode then
      OCD:SetEntryOOCReady(active, tonumber(entryIndex), mode)
    else
      Chat("usage: /ocd ooc <entry> hide|show")
    end
  elseif cmd == "procstyle" or cmd == "proc-style" then
    OCD:SetProcCooldownMode(active, rest)
  elseif cmd == "timerfont" or cmd == "fontsize" or cmd == "font" then
    OCD:SetTimerFontSize(active, rest)
  elseif cmd == "procdebug" or cmd == "proc-debug" then
    OCD:SetProcDebug(rest)
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
    OctoCooldownsDB = { version = 13, active = 1, updateInterval = DEFAULT_UPDATE_INTERVAL, bars = { NewBar("Main", -120) } }
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
OCD:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
OCD:RegisterEvent("CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES")
OCD:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE")
OCD:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE")
OCD:RegisterEvent("PLAYER_DEAD")
OCD:RegisterEvent("PLAYER_TARGET_CHANGED")
OCD:RegisterEvent("UNIT_HEALTH")
OCD:RegisterEvent("ACTIONBAR_UPDATE_USABLE")
OCD:RegisterEvent("SPELL_UPDATE_USABLE")
OCD:RegisterEvent("PLAYER_AURAS_CHANGED")
OCD:RegisterEvent("PLAYER_REGEN_DISABLED")
OCD:RegisterEvent("PLAYER_REGEN_ENABLED")

OCD:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    InitializeReactivePatterns()
    EnsureDB()
    RefreshPlayerCombatState()
    OCD:RegisterEnhancedReactiveEvents()
    OCD:ClearReactiveStates(false)
    RefreshPlayerAuraSnapshot(true)
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
    if OctoCooldownsDB then
      auraScanDirty = true
      RefreshPlayerAuraSnapshot(true)
      OCD:RebuildAll(false)
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    if OctoCooldownsDB then
      OCD:ClearReactiveStates(false)
      RefreshPlayerCombatState()
      auraScanDirty = true
      RefreshPlayerAuraSnapshot(true)
      OCD:RebuildAll(true)
      OCD:RefreshItemCounts()
    end
  elseif event == "BAG_UPDATE" then
    if OctoCooldownsDB then bagCountsDirty = true end
  elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
    playerInCombat = event == "PLAYER_REGEN_DISABLED"
    if OctoCooldownsDB then OCD:RebuildAll(false) end
  elseif event == "PLAYER_AURAS_CHANGED" or event == "BUFF_ADDED_SELF" or event == "BUFF_REMOVED_SELF"
      or event == "BUFF_UPDATE_DURATION_SELF" or event == "AURA_CAST_ON_SELF" then
    if OctoCooldownsDB then ScheduleAuraScans(event) end
  elseif event == "UNIT_COMBAT" then
    if arg1 == "player" and arg2 == "PARRY" then OCD:ActivateReactive("riposte", nil, nil, "unit") end
  elseif event == "CHAT_MSG_COMBAT_SELF_MISSES"
      or event == "CHAT_MSG_SPELL_SELF_DAMAGE"
      or event == "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF"
      or event == "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES"
      or event == "CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES"
      or event == "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE"
      or event == "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE" then
    OCD:HandleReactiveCombatMessage(event, arg1)
  elseif event == "AUTO_ATTACK_SELF"
      or event == "AUTO_ATTACK_OTHER"
      or event == "SPELL_MISS_SELF"
      or event == "SPELL_MISS_OTHER"
      or event == "SPELL_GO_SELF"
      or event == "SPELL_START_SELF"
      or event == "UNIT_CASTEVENT" then
    local eventName = event
    local a1, a2, a3, a4, a5, a6, a7 = arg1, arg2, arg3, arg4, arg5, arg6, arg7
    OCD:HandleEnhancedReactiveEvent(eventName, a1, a2, a3, a4, a5, a6, a7)
  elseif event == "PLAYER_DEAD" then
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
  local auraUpdated = OCD:ProcessAuraScanSchedule()
  local interval = DEFAULT_UPDATE_INTERVAL
  if OctoCooldownsDB and OctoCooldownsDB.updateInterval then
    interval = OctoCooldownsDB.updateInterval
  end
  if updateElapsed >= interval then
    updateElapsed = updateElapsed - interval
    if updateElapsed > interval then updateElapsed = interval end
    if bagCountsDirty then
      bagCountsDirty = false
      OCD:RefreshItemCounts()
    end
    if not auraUpdated then OCD:UpdateCooldowns() end
  end
end)
