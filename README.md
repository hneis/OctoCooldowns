# OctoCooldowns

Personal cooldown and reactive ability bars for OctoWoW and Vanilla WoW 1.12.

## Compatibility

- OctoWoW / Vanilla WoW 1.12 (`Interface: 11200`)
- Lua 5.0 and the legacy WoW API
- No dependencies or OmniCC required

## Install With GitAddonsManager

Add this repository using its HTTPS clone URL:

```text
https://github.com/hneis/OctoCooldowns.git
```

GitAddonsManager should clone it to:

```text
<WoW>/Interface/AddOns/OctoCooldowns
```

The final path to the addon manifest must be
`<WoW>/Interface/AddOns/OctoCooldowns/OctoCooldowns.toc`.

If OctoCooldowns was installed manually, remove or rename the old addon folder
before cloning it through GitAddonsManager. Character settings are stored under
WoW's `WTF` directory and are not removed with the addon folder.

## Manual Git Install

Run this command from `<WoW>/Interface/AddOns`:

```bash
git clone https://github.com/hneis/OctoCooldowns.git
```

Use GitAddonsManager or `git pull` to install future updates, then restart the
game or reload the UI.

## Basic Workflow

1. Run `/ocd unlock`.
2. Drag a spell from the spellbook or an item from your bags onto `+`.
3. Drag the panel to position it.
4. Shift-right-click an icon to remove it.
5. Run `/ocd lock` when finished.

While a bar is unlocked, drag one tracked icon onto another to swap them. This
also works between two unlocked bars. Drag an icon onto another bar's `+` to
move it to the end of that bar.

Use `/ocd center` to center the active bar horizontally without changing its
vertical position.

## Multiple Bars

```text
/ocd new Utility        Create a new bar and make it active.
/ocd new Burst          Create another bar.
/ocd bars               Show all bars; * marks the active one.
/ocd bar 1              Select a bar by number.
/ocd bar Utility        Select a bar by exact name.
/ocd rename Defensives  Rename the active bar.
/ocd delbar             Delete the active bar.
/ocd delbar 2           Delete bar 2.
```

Each bar is configured independently. Commands such as `add`, `cols`, `size`,
`gap`, `lock`, `clear`, and `center` affect only the active bar.

## Reactive Abilities

Drag `Riposte` or `Surprise Attack` from the spellbook onto a bar as usual.
Their English and Russian names are recognized automatically.

- In edit mode, reactive abilities remain visible but dimmed.
- In locked mode, they are completely hidden until their condition occurs.
- Riposte appears for 4 seconds after you parry an incoming attack.
- Surprise Attack appears for 4 seconds after your attack is dodged.
- Surprise Attack is shown only while targeting the enemy that dodged.
- Active reactive abilities use a gold border and a countdown with tenths.
- A proc that is still on ability cooldown uses a red border and a dimmed icon.
- Empty locked bars are hidden and mixed bars close gaps left by inactive procs.

Use `/ocd list` to find an entry number. If automatic recognition is not
available for the client locale, configure the spell manually:

```text
/ocd proc <entry> riposte
/ocd proc <entry> surprise
/ocd proc <entry> off
```

Each bar controls how active procs on ability cooldown are displayed:

```text
/ocd procstyle red   Show the proc with a red border until the cooldown ends.
/ocd procstyle hide  Hide it until the cooldown ends.
```

The proc-window timer remains active in either mode. If the ability becomes
ready before the four-second window expires, the icon appears or changes from
red to gold with the remaining proc time.

Nampower and SuperWoW events are used automatically when available. The addon
also supports the standard localized Vanilla 1.12 combat log and does not
require either extension. On older Nampower versions the addon enables the
required event CVars and prints a one-time request to reload the UI.

## Toggle Auras

OctoWoW's `Blade Flurry` can be placed on any bar, including the `Procs` bar.
Its English and Russian (`Шквал клинков`) names are recognized automatically.

- While the bar is locked, the icon is hidden when Blade Flurry is off.
- When Blade Flurry is on, the icon appears at full brightness with a blue
  border.
- While editing, the inactive icon remains visible but dimmed.
- The four-second re-enable cooldown is intentionally not displayed because
  the active toggle can still be disabled immediately.
- The actual player buff is the source of truth, so login, reload, and missed
  events are corrected by aura scanning.

For another locale or a renamed custom spell, configure the tracked entry
manually:

```text
/ocd aura <entry> bladeflurry
/ocd aura <entry> off
```

## Commands

```text
/ocd                     Toggle lock/edit mode on the active bar.
/ocd unlock              Unlock the active bar.
/ocd lock                Lock the active bar.
/ocd unlockall           Unlock all bars.
/ocd lockall             Lock all bars.
/ocd center              Horizontally center the active bar, keeping its Y.
/ocd centerall           Horizontally center all bars, keeping each Y.
/ocd add <name>          Add a spell by exact spellbook name.
/ocd item <itemID>       Add an item by numeric item ID.
/ocd proc <n> <mode>     Set riposte, surprise, or off for spell entry n.
/ocd aura <n> <mode>     Set bladeflurry or off for spell entry n.
/ocd procstyle <mode>     Set red or hide for the active bar.
/ocd procdebug <mode>     Enable, disable, or show proc diagnostics.
/ocd timerfont <8-100>    Set timer font size for the active bar.
/ocd timerfont reset      Restore the default timer font size.
/ocd remove <n>          Remove entry n.
/ocd move <a> <b>        Move entry a to position b.
/ocd cols <1-12>         Set columns for the active bar.
/ocd size <20-80>        Set icon size for the active bar.
/ocd gap <0-20>          Set icon gap for the active bar.
/ocd update              Show the cooldown refresh interval.
/ocd update <0.05-1.00>  Set the cooldown refresh interval in seconds.
/ocd list                List entries in the active bar.
/ocd clear               Clear the active bar.
/ocd reset               Reset the active bar, keeping its name.
/ocd resetall            Delete all bars and settings, then start fresh.
/ocd help                Show in-game help.
```

## Behavior

- Tracked icons remain visible when ready.
- Ready abilities use full brightness.
- Abilities on cooldown are dimmed and show the remaining time.
- Global cooldowns of 1.8 seconds or less are ignored.
- Items show their bag count in the bottom-right corner.
- Item counts update on bag changes rather than every frame.
- Cooldowns are polled every 0.10 seconds by default. Use `/ocd update 0.20`
  for lower overhead.
- Timer font size is configured per bar. For example, select `Procs` and run
  `/ocd timerfont 20`; use `/ocd timerfont reset` to restore the standard
  `ARIALN` size of 14.
- Unlocked bars show `12.3` when no real timer is active, making font-size
  changes immediately visible. The preview disappears when the bar is locked.
- Settings are stored per character in `OctoCooldownsDB`.
- Dragging is the safest way to add localized spell names.

## Changelog

### 0.4.3

- Increased the maximum per-bar timer font size from 40 to 100.

### 0.4.2

- Made timer fonts independent from inherited `NumberFontNormal` rendering.
- Added a `12.3` timer preview while bars are unlocked.
- Made reset reliably restore `ARIALN`, size 14, with an outline.

### 0.4.1

- Added per-bar numeric timer font sizes through `/ocd timerfont`.
- Added reset support that restores the original `NumberFontNormal` font.

### 0.4.0

- Added persistent toggle-aura tracking for OctoWoW Blade Flurry.
- Hide Blade Flurry while off and show it with a blue border while active.
- Detect active state from the actual player buff instead of spell cooldown.
- Added English/Russian automatic recognition and `/ocd aura` overrides.
- Added immediate aura-event updates with periodic scanning as a fallback.

### 0.3.1

- Added per-bar `red` and `hide` behavior for procs during ability cooldowns.
- Added red cooldown borders with dimmed icons and automatic gold transitions.
- Added drag-and-drop swaps within and between unlocked bars.
- Added moving entries to another bar by dropping them onto its `+`.
- Prevented Nampower, `UNIT_COMBAT`, and combat-log duplicates from shifting
  proc timers or resurrecting consumed procs.
- Added support for both known `SPELL_MISS_*` Nampower argument layouts.
- Removed transient `IsUsableSpell` failures and combat exit as proc-clearing
  conditions.
- Added localized incoming-parry fallback and `/ocd procdebug` diagnostics.

### 0.3.0

- Added temporary reactive icons for Riposte and Surprise Attack.
- Added four-second proc countdowns and gold active borders.
- Added target-aware Surprise Attack tracking.
- Added automatic Nampower/SuperWoW integration with a localized Vanilla
  combat-log fallback.
- Added automatic English/Russian spell recognition and `/ocd proc` overrides.
- Added dynamic locked-bar layout with no gaps from inactive reactive entries.

### 0.2.1

- Stopped rescanning item stack counts every 0.10 seconds.
- Scan bags only on `BAG_UPDATE`, login, and tracked item addition.
- Added a configurable cooldown polling interval through `/ocd update`.

### 0.2.0

- Added multiple independent cooldown bars.
- Added per-bar entries, columns, icon size, gap, lock state, and position.
- Added horizontal centering for the active bar.
- Added automatic migration of 0.1.x settings into the first bar.

## License

OctoCooldowns is available under the [MIT License](LICENSE).
