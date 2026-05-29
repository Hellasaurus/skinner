# Skinner — Project Outline

## Goal

Build a macOS app that parses arbitrary WMP skin files (`.wmz` / extracted directories) and renders them as a functional window, with all interactive elements wired to a media player backend. Phase 1 covers skin parsing and display with console-stub output. Phase 2 wires the skin to an FFmpeg-based player.

---

## Background: WMP Skin Format

Skins are distributed as `.wmz` files (ZIP archives containing a `.wms` file plus image/script assets) or as pre-extracted directories. The `.wms` file is UTF-16 LE encoded XML.

### Document structure

```
THEME
  VIEW  (one per UI mode: main, playlist, video, equalizer…)
    PLAYER        — declares the player object; event handlers attach here
    SUBVIEW       — moveable/hideable panel
    BUTTONGROUP   — cluster of buttons sharing one image set + a color-map PNG
      BUTTONELEMENT  — one logical button within the cluster
    BUTTON        — standalone button (or a predefined type: PLAYBUTTON, MUTEBUTTON…)
    SLIDER / SEEKSLIDER / VOLUMESLIDER / CUSTOMSLIDER
    TEXT          — static or scrolling label, can display player properties
    EFFECTS       — audio visualization host
    VIDEO         — video output region
    PLAYLIST      — playlist display
    EQUALIZERSETTINGS / VIDEOSETTINGS
```

### Attribute value kinds

All element attributes can be one of three flavors:

- **Literal** — `"true"`, `"#ff00ff"`, `"364"`
- **JScript expression** — `jscript:view.width - 166` (arithmetic layout)
- **WMP property binding** — `wmpprop:player.settings.volume` (live player state)
- **WMP enabled binding** — `wmpenabled:player.controls.pause` (conditional enable)

### Transparency

Images use magenta (`#FF00FF`) as a chroma-key transparency color. The `transparencyColor` attribute overrides this per element. Hit testing must exclude these transparent pixels.

### Button clusters

A `BUTTONGROUP` uses a `mappingImage` PNG where each button's region is painted a distinct solid color. Each `BUTTONELEMENT` declares the `mappingColor` it owns. The normal/hover/down images are full-size sprites applied over only the hit region.

### Sprite-strip sliders

`CUSTOMSLIDER` uses a `positionImage` (or `image` containing multiple frames side-by-side) whose pixel brightness encodes thumb position. The slider value is derived from the brightness at the hit point.

---

## Architecture

### Component map

```
SkinLoader
  └─ unzips .wmz or reads a directory
  └─ locates the .wms file and all assets

WMSParser
  └─ decodes UTF-16 XML
  └─ builds SkinModel tree

SkinModel  (pure Swift value types)
  ├─ Theme
  ├─ View         (id, dimensions, script refs, event handlers)
  ├─ Element      (protocol, ambient attributes: id, left, top, width, height,
  │                zIndex, visible, enabled, horizontalAlignment,
  │                verticalAlignment, transparencyColor, passThrough…)
  ├─ Subview      : Element
  ├─ ButtonGroup  : Element  (images, mappingImage, [ButtonElement])
  ├─ Button       : Element  (normal/hover/down/disabled images, sticky, onClick…)
  ├─ Slider       : Element  (min/max, value, thumb images, direction, foreground…)
  ├─ TextLabel    : Element  (value, font, scrolling…)
  ├─ Effects      : Element
  ├─ Video        : Element
  └─ Playlist     : Element

AttributeValue  (enum: literal(String) | jsExpr(String) | wmpProp(String))

LayoutEngine
  └─ evaluates jsExpr attributes at runtime (view.width, view.height arithmetic)
  └─ resolves horizontalAlignment / verticalAlignment anchoring on resize

AssetCache
  └─ loads PNG/GIF from skin directory
  └─ applies magenta-key transparency
  └─ vends NSImage for named assets

SkinViewController  (NSViewController wrapping one VIEW)
  └─ owns the element tree rendered as NSView hierarchy
  └─ reacts to layout changes and player state updates

Element renderers  (NSView subclasses or drawing helpers)
  ├─ ButtonGroupView   — color-map hit testing, per-region hover/press overlays
  ├─ ButtonView        — pixel hit test, normal/hover/down state images
  ├─ SliderView        — sprite-strip or standard slider rendering + drag
  ├─ AnimatedImageView — GIF playback (NSImageView wrapper)
  └─ TextLabelView     — scrolling text, player-property live updates

PlayerController  (protocol)
  ├─ ConsolePlayerController  — Phase 1: all actions print to stdout
  └─ FFmpegPlayerController   — Phase 2: real media playback

PropertyBinder
  └─ maps wmpprop: paths to PlayerController state
  └─ drives live UI updates (seek position, volume, metadata text…)
  └─ routes UI events back to PlayerController
```

### Data flow

```
.wmz file
  ─→ SkinLoader   ─→ asset directory + .wms text
  ─→ WMSParser    ─→ SkinModel (Theme + Views + Elements)
  ─→ LayoutEngine ─→ resolved frames per view.size
  ─→ SkinViewController (one per active VIEW)
       ├─ element renderers draw from AssetCache
       └─ user input ─→ PropertyBinder ─→ PlayerController
                                         └─→ UI state updates
```

---

## Phases

### Phase 1 — Skin loading and display  *(current focus)*

**Scope:**
- `SkinLoader`: unzip `.wmz`, locate `.wms`
- `WMSParser`: parse UTF-16 XML into `SkinModel`
- `AssetCache`: load images, apply magenta transparency
- `LayoutEngine`: evaluate `jscript:` arithmetic expressions; handle alignment anchors
- Renderers for: background/subview, button clusters, simple buttons, sprite-strip sliders, animated GIFs, text labels
- `PlayerWindow` / `SkinViewController` driven by parsed model (not hardcoded)
- `ConsolePlayerController`: every button action, slider move, and state change prints to stdout
- Load any skin from the `skins/` directory at launch (CLI arg or hardcoded path for now)

**Out of scope for Phase 1:**
- Actual media decoding or playback
- JScript evaluation beyond arithmetic layout expressions
- `res://wmploc.dll/…` script resource references (skip or stub)
- Playlist, equalizer, video secondary views (render main view only)
- `wmpenabled:` conditional disabling (treat all controls as enabled)
- Nine-grid scaling / `nineGridMargins`

**Success criterion:** Any arbitrary `.wmz` from the `skins/` collection loads and displays its main view, all buttons respond visually (hover/press states), sliders drag, and every interaction logs to console.

---

### Phase 2 — FFmpeg media backend  *(future)*

- `FFmpegPlayerController` implementing `PlayerController`
- File open dialog wired to player open
- Seek slider and volume slider wired to real playback position / audio volume
- Metadata text (`wmpprop:player.currentMedia.name`, etc.) populated from media tags
- `VIDEO` element renders decoded frames
- Playback state drives button visibility (play vs. pause cluster swap as in Pulsar)

---

## Key challenges

| Challenge | Notes |
|---|---|
| UTF-16 XML | Swift's `XMLParser` needs the data passed with explicit encoding, or pre-converted to UTF-8 |
| JScript arithmetic layout | Need a small expression evaluator for `jscript:view.width - N` style expressions; full JS engine is overkill |
| Color-map hit testing | Must read raw RGBA pixels from `mappingImage` at pointer position; needs per-pixel accuracy |
| Magenta transparency on hit test | Transparent pixels must be excluded from both drawing and mouse hit testing |
| GIF animation | AppKit's `NSImageView` animates GIFs natively; need to manage play/stop lifecycle |
| Multiple views per theme | Pulsar has `mainView`, `plView`, `videoView`; Phase 1 renders only `mainView` |
| `wmpprop:` bindings | Need a KVO-style mechanism to push player state into text labels and slider values |
| Skin variety | Skins use very different subsets of elements; parser must be lenient with unknown attributes |
| Window shape | `titleBar="false"` + magenta transparency = shaped window; uses `NSWindow.backgroundColor = .clear` + `isOpaque = false` + per-pixel hit testing (as in prototype) |

---

## Reference

- WMP Skin Programming Reference: `https://learn.microsoft.com/en-us/windows/win32/wmp/windows-media-player-skins`
- Prototype (hardcoded Pulsar skin): `../test-sandbox/MediaPlayer`
- Skin assets: `skins/` (Pulsar extracted + `windowsmediaplayerskinscollection/` of `.wmz` files)
