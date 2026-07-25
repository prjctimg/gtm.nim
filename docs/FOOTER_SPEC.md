# Footer Module Styling Spec

Visual and structural reference for implementing footer modules in the `StatusBarComp` widget. An agent should follow these rules to produce modules that match the existing look.

---

## 1. Layout Model

The footer is a **single terminal row** (`statusBarHeight = 1`) rendered at the absolute bottom of the screen (`y = h - 1`). It is split into two independent regions:

| Region | Origin | Direction | Purpose |
|--------|--------|-----------|---------|
| **Left** | `leftX = 1` | Advances rightward | Contextual elements (key display, filter, feedback, select badge, elapsed time) |
| **Right** | `rightX = w - 1` | Advances leftward | Modular status pills (play state, volume, backend, etc.) |

The two regions never overlap — if the left side grows too wide, right-side modules are skipped (they simply don't render when `rightX` is too small).

The background of the entire row is `theme.mantle`.

---

## 2. The `addMod` Pattern

Every right-side module is rendered through the `addMod` template. This is the **single pattern** an agent must follow:

```
template addMod(text: string, col: Color, bgCol: Color) =
  if rightX > text.runeLen + 2:
    rightX -= text.runeLen + 1
    fillBg(ctx.tb, rightX, 0, rightX + text.runeLen, 0, bgCol)
    ctx.tb.setBackgroundColor(bgCol)
    writeStr(ctx.tb, rightX, 0, text, col)
    ctx.tb.setBackgroundColor(bgNone)
```

### Algorithm, step by step

1. **Bounds check**: Only render if `rightX > text.runeLen + 2` (need room for the pill plus at least 2 chars of slack).
2. **Position**: `rightX` is decremented by `text.runeLen + 1`. The `+1` creates a **1-character gap** between adjacent pills.
3. **Background**: A filled rectangle from `(rightX, 0)` to `(rightX + text.runeLen, 0)` in `bgCol`.
4. **Foreground**: The text string is written at `(rightX, 0)` in `col`.
5. **Reset**: Background color is reset to `bgNone` so subsequent drawing isn't affected.

### Critical details

- **Pills are self-contained**: each pill carries its own background. There are no shared borders, separators, or dividers between modules.
- **1-char spacing**: the gap between pills is exactly 1 terminal cell. This comes from the `+1` in the position decrement.
- **No trailing space in text**: the text string itself starts with a leading space (for internal padding) but has no trailing space.
- **Right-to-left stacking**: the first module rendered in the list appears closest to the right edge; subsequent modules stack leftward.

---

## 3. Color Semantics

Colors are drawn from the Catppuccin-inspired theme palette. Each module type has a **semantic color role**:

### Neutral / Informational

| Role | Foreground | Background | Used by |
|------|-----------|------------|---------|
| Passive info | `theme.text` | `theme.surface2` | Date, Time |
| Input state | `theme.text` | `theme.surface0` | Filter text |
| Transient msg | `theme.text` | `theme.surface1` | Feedback message |
| Decorative | `theme.base` | `theme.surface2` | Key display, Play/Pause (stopped) |

### Accent / Functional

| Role | Foreground | Background | Used by |
|------|-----------|------------|---------|
| Volume | `theme.base` | `theme.teal` | Volume percentage |
| Audio backend | `theme.base` | `theme.mauve` | Backend label (ALSA, etc.) |
| Queue position | `theme.base` | `theme.sapphire` | Queue count (pos/total) |
| Track info | `theme.base` | `theme.sky` | Elapsed time, Next track |
| EQ preset | `theme.base` | `theme.teal` | Equalizer preset name |
| Playlist | `theme.base` | `theme.sky` | Current playlist name |

### Status / Action

| Role | Foreground | Background | Used by |
|------|-----------|------------|---------|
| Active / Playing | `theme.base` | `theme.green` | Play icon, Repeat-all |
| Paused / Stopped | `theme.base` | `theme.surface2` | Pause/stop icon |
| Selection | `theme.base` | `theme.peach` | Select count badge, Shuffle, Sleep timer |
| Repeat-one | `theme.base` | `theme.blue` | Repeat-one icon |

### Pattern summary

- **`theme.base` fg** is used for all accent/status pills (high contrast on colored backgrounds).
- **`theme.text` fg** is used only on neutral surface backgrounds.
- Background colors encode **semantic category**, not just aesthetics.

---

## 4. Pill Construction Rules

When implementing a new module, follow these construction rules:

### Text format

```
" <content>"
```

- **Leading space**: every pill's text starts with a single space character. This creates internal padding within the colored background.
- **No trailing space**: the background ends exactly at the last character of the content.
- **Icons are inline**: Unicode icon characters are embedded directly in the string (e.g., `" " & ic.play`).

### Overflow handling

- If `rightX` is too small to fit the pill, the module is **silently skipped** — no truncation, no partial rendering. The `if rightX > text.runeLen + 2` guard handles this.
- For modules with dynamic-length text (like `fmNextTrack`), explicit truncation is applied before calling `addMod`:

```nim
let maxLen = (rightX - 15) div 2
let truncd = if nextTitle.runeLen > maxLen: nextTitle.substr(0, maxLen - 2) & ".." else: nextTitle
addMod(" " & ic.nextTrack & " " & truncd, theme.base, theme.sky)
```

### Spacing between pills

- Exactly **1 terminal cell** between adjacent pills.
- This is automatic from the `addMod` position math — no extra spacing code is needed.

---

## 5. Conditional Visibility Rules

Most modules have **prerequisites** before they render. An agent must respect these conditions:

| Module | Condition |
|--------|-----------|
| `fmSleepTimer` | `state.sleepTimerRemaining > 0` |
| `fmSelectCount` | `state.selectedIndices.len > 0` |
| `fmNextTrack` | `state.playbackQueue.len > 0` AND next track has a non-empty title |
| `fmQueueCount` | `state.playbackQueue.len > 0` |
| `fmEqPreset` | `state.eqPreset.len > 0` |
| `fmCurrentPlaylist` | `state.playlistContentsIdx >= 0` and within valid range |
| `fmRepeatShuffle` | Repeat icon: `state.repeatMode > 0`. Shuffle icon: `state.shuffleEnabled` |
| `fmPlayStatus` | Always rendered (no condition) |
| `fmVolume` | Always rendered (no condition) |
| `fmBackend` | Always rendered (no condition) |
| `fmTime` | Always rendered (no condition) |
| `fmDate` | Always rendered (no condition) |

When a module's condition is not met, it is simply omitted — no placeholder or empty space is left behind.

---

## 6. Preset System

Modules are grouped into **presets**. The active preset determines which subset of modules appears in the right-side footer.

### FooterModule enum

```nim
type FooterModule* = enum
  fmPlayStatus, fmVolume, fmBackend, fmNextTrack, fmSelectCount,
  fmTime, fmDate, fmRepeatShuffle, fmSleepTimer, fmElapsedTime,
  fmQueueCount, fmEqPreset, fmCurrentPlaylist
```

Note: `fmElapsedTime` is defined but unused in any preset or rendering code.

### FooterPresetName enum

```nim
type FooterPresetName* = enum
  fpnMinimal, fpnCompact, fpnFull, fpnInfo, fpnNavigator,
  fpnDebug, fpnMusic, fpnClock
```

### Preset → Module mapping

| Preset | Modules |
|--------|---------|
| `fpnMinimal` | PlayStatus |
| `fpnCompact` | PlayStatus, Time, Backend, QueueCount, EqPreset |
| `fpnFull` | PlayStatus, Volume, Backend, NextTrack, SelectCount, Time, Date, RepeatShuffle, SleepTimer, QueueCount, EqPreset, CurrentPlaylist |
| `fpnInfo` | PlayStatus, NextTrack, Volume, Backend, QueueCount |
| `fpnNavigator` | PlayStatus, RepeatShuffle, SelectCount, Time, Date |
| `fpnDebug` | PlayStatus, Time, Date, SleepTimer, Backend, Volume, QueueCount, EqPreset |
| `fpnMusic` | PlayStatus, NextTrack, RepeatShuffle, Volume, QueueCount, EqPreset |
| `fpnClock` | PlayStatus, Time, Date |

### Module render order (right-to-left)

Modules are always rendered in this fixed order regardless of preset. A module only renders if it is in the active preset's set:

1. `fmDate` — closest to right edge
2. `fmSleepTimer`
3. `fmTime`
4. `fmRepeatShuffle`
5. `fmSelectCount`
6. `fmNextTrack`
7. `fmBackend`
8. `fmVolume`
9. `fmPlayStatus`
10. `fmQueueCount`
11. `fmEqPreset`
12. `fmCurrentPlaylist` — furthest from right edge

---

## 7. Adding a New Module

Step-by-step checklist for an agent adding a new footer module:

### Step 1: Add enum value

In `src/state.nim`, add the new value to `FooterModule`:

```nim
FooterModule* = enum
  fmPlayStatus, fmVolume, ..., fmCurrentPlaylist,
  fmYourNewModule    # <-- add here
```

### Step 2: Add to presets

In `src/state.nim`, add the module to whichever presets should display it in `FooterPresets`:

```nim
fpnCompact: {fmPlayStatus, fmTime, fmBackend, fmQueueCount, fmEqPreset, fmYourNewModule},
```

### Step 3: Add rendering code

In `src/ui.nim`, inside `StatusBarComp.render`, add a rendering block following the `addMod` pattern:

```nim
if fmYourNewModule in activeModules:
  addMod(" " & yourContent, theme.yourFg, theme.yourBg)
```

Place it at the correct position in the render-order list (see Section 6).

### Step 4: Add state fields (if needed)

If the module requires dynamic data, add the relevant field(s) to `AppState` in `src/state.nim`.

### Step 5: Add conditional visibility (if needed)

If the module should only appear under certain conditions, wrap the `addMod` call in an `if` guard:

```nim
if fmYourNewModule in activeModules and state.someCondition:
  addMod(" " & yourContent, theme.yourFg, theme.yourBg)
```

---

## 8. Left-Side Elements

Left-side elements follow a different pattern than right-side modules. They use `writeStrBg` (foreground + background) and advance `leftX` rightward:

```nim
writeStrBg(ctx.tb, leftX, 0, text, fgColor, bgColor)
leftX += text.runeLen
```

| Element | Text format | fg | bg |
|---------|------------|----|----|
| Key display | `" [keyName] "` | `theme.base` | `theme.surface2` |
| Filter | `"Filter: <text>"` | `theme.text` | `theme.surface0` |
| Feedback | `" message "` | `theme.text` | `theme.surface1` |
| Select badge | `" [SELECT] "` | `theme.base` | `theme.peach` |
| Elapsed time | `" MM:SS "` | `theme.base` | `theme.sky` |

Left-side elements are context-dependent (only shown when relevant) and take priority — they claim space first, and right-side modules fill what remains.
