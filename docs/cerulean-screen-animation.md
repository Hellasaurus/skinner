# Cerulean: Screen Animation & EQ/PL/Video Panes

## Overview

Cerulean uses a two-phase animated screen that reveals one of three panes:

| Pane | Constant | Element shown |
|---|---|---|
| Audio controls | `audPane = 1` | `sAud` subview (EQ sliders) |
| Playlist | `plPane = 2` | `pl` (itemsPlaylist) |
| Video | `vidPane = 3` | `vid` (video element) |

State is tracked in `currentPane` (JS global). `SetPane(pane)` shows/hides the right element.

## Two-Phase Animation Sequence

### Opening a pane

**Hop 1 — vertical:** `vScrSmall.moveto(left, 0, 300)` slides the thumbnail up from `top=145` to `top=0`. On `onEndMove="SmallScrEndMove()"`:
- Hides `vScrSmall`
- Makes `vScrLeft`, `vScrMiddle`, `vScrRight` visible
- Calls `HorScreenToggle()`

**Hop 2 — horizontal:** `vScrLeft.moveto(11, top, 150)` + `vScrRight.moveto(150, top, 150)` expand the screen panels. On `onEndMove="ScreenEndMove()"`:
- Calls `SetPane(openingPane)` — shows pane content

### Closing

Reverses the sequence: hop 2 first (collapse: vScrLeft→42, vScrRight→119), then hop 1 (vScrSmall slides down to `top=145`).

### Position constants (JS globals)

```js
var scrUp = 0,    scrDn = 146;        // vScrSmall top: open / closed
var scrLOpened = 11,  scrLClosed = 42;  // vScrLeft left: open / closed
var scrROpened = 150, scrRClosed = 119; // vScrRight left: open / closed
var speedVer = 300, speedHor = 150;
```

## EQ Controls (`sAud` subview)

Four sliders inside `sAud` (visible only when `currentPane == audPane`):

| Element | WMS type | Binding |
|---|---|---|
| `bass` | `<slider>` | `wmpprop:eq.gainLevel1` |
| `treble` | `<slider>` | `wmpprop:eq.gainLevel10` |
| `balance` | `<balanceSlider>` | implicit player balance |
| `volume` | `<volumeSlider>` | implicit player volume |

`AdjustAudio()` interpolates `eq.gainLevel2`–`eq.gainLevel9` between bass and treble values when either slider changes.

A "reset" text link calls `eq.reset()`.

## Known Bugs / Unimplemented Features

### 1. `itemsPlaylist` tag not recognized (playlist pane broken)

`<itemsPlaylist id="pl" ...>` falls through to `.unknown` in `WMSParser.buildElement`. No proxy for `pl` is registered in the JS context. `SetPane(plPane)` references an undefined variable — silently swallowed. **Playlist pane is entirely non-functional.**

**Fix:** add `"itemsplaylist"` as an alias for `"playlist"` in `WMSParser.swift:336`.

### 2. `fireOnEndMoveCallbacks` doesn't drain the chain (pane contents never show)

The two-hop animation requires chaining: Hop 1's `onEndMove` fires `SmallScrEndMove`, which calls `HorScreenToggle`, which sets `vScrLeft._moved = true`. Hop 2's `onEndMove` must then fire `ScreenEndMove` → `SetPane`.

The current loop in `fireOnEndMoveCallbacks` (`:137`) iterates `proxies.values` once. If `vScrLeft` is visited before `vScrSmall`, its `_moved` is false at visit time. After `SmallScrEndMove` sets `_moved = true`, the loop is already done — `ScreenEndMove` never fires, **pane contents never appear.**

**Fix:** drain-queue loop — repeat passes until no new `_moved` flags are found.

### 3. Duplicate attribute handling (wrong initial positions)

`vScrLeft`, `vScrMiddle`, and `vScrRight` have duplicate `left=`/`top=` attributes:

```xml
<subview id="vScrLeft" zIndex="2"
    left="42" top="145"
    left="11" top="0" visible="false"
    ...>
```

`deduplicatedTag` keeps the **first** occurrence. WMP kept the **last** (standard lenient parser behavior). The correct initial position is `(11, 0)` — where these panels sit when the screen is open. With first-occurrence, `vScrLeft` starts at `(42, 145)` and horizontal animation slides it to `(11, 145)` — wrong vertical position.

**Fix:** change `deduplicatedTag` (`:165`) to keep the last occurrence instead of first.

### 4. No timed animation (cosmetic)

`moveto(x, y, ms)` ignores `ms` and moves instantly. The vertical slide and horizontal expand/collapse don't animate — elements jump. The state machine works correctly (once #2 is fixed) but the skin's signature transition effect is absent.

Implementing this requires timer-based position interpolation driven by a `CADisplayLink` or similar.

### 5. `statusText`, `currentPositionText`, `returnButton` not parsed

All three fall to `.unknown` and are not rendered. These are minor — `status`/`metadata` text visibility is JS-controlled regardless, and `returnButton` is a cosmetic WMP compact/expanded toggle.
