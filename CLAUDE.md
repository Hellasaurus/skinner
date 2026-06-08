# Skinner — Codebase Guide

WMP skin parser and renderer for macOS. Reads `.wmz`/`.wms` skin files, renders them as native AppKit windows.

## Package targets

| Target | Role |
|---|---|
| `SkinnerCore` | Library — all parsing, rendering, interaction logic |
| `Skinner` | App — `AppDelegate`, `SkinWindow`, `main.swift` |
| `SkinnerPlayer` | `AVFoundationPlayer` — `PlayerBackend` impl via AVFoundation |
| `SkinnerViz` | projectM visualization bridge (`VisualizationView`, `ProjectMBridge`) |

## Data flow

```
.wmz file
  → SkinLoader (extracts, detects encoding)
  → WMSParser  (XML → Theme)
  → AssetCache.build(from:theme:)   (loads all images once)
  → SkinCanvasView(skinView:cache:bundle:)
```

`Theme` contains `[SkinView]`; `Theme.mainView` picks the primary window view. `SkinView.elements` is a tree of `SkinElement` (enum with cases: `.subview`, `.button`, `.buttonGroup`, `.slider`, `.text`, `.effects`, `.playlist`, `.video`, `.player`, …).

## Key files

### `SkinModel.swift`
All model types: `Theme`, `SkinView`, `ElementBase`, `Button`, `ButtonGroup`, `Slider`, `TextLabel`, `Effects`, `Subview`, `SkinElement`. `ElementBase` carries the shared attributes every visible element has (id, left, top, width, height, zIndex, visible, alphaBlend, onClick, passThrough, …).

### `AssetCache.swift`
Loaded once at skin-open. Three main dictionaries:
- `images: [String: NSImage]` — magenta-cleaned images, keyed by lowercased filename
- `mapData: [String: MapData]` — raw RGBA bytes for pixel-level hit testing
- `buttonGroupsByMappingImage: [String: ButtonGroupAssets]` — pre-built CGImage masks per button group mapping image

`mapData` stores pixels in CGContext order (row 0 = visual bottom). `images` also loads every image file in the bundle directory (not just WMS-declared ones) so JS-assigned backgroundImages work.

### `SkinCanvasView.swift` (2400 lines — the core)
`NSView` subclass that owns rendering and interaction. Key internals:

**Collected render arrays** (rebuilt by `recollect()` after any JS change):
- `buttons: [RenderedButton]` — frame + mapData for pixel-accurate hit testing
- `groups: [RenderedGroup]` — ButtonGroup with mapping-image color lookup
- `sliders: [RenderedSlider]` — frame, value, frameCount
- `texts: [RenderedText]` — frame, hover state

**Click-through mask** (`buildBgOpacity()`):
- `bgOpacity: [Bool]` — flipped view coords (row 0 = visual top), true = hittable
- Populated by walking subview background images through `paintMdIntoOpacity`
- Converted to `bgMask: CGImage` for `ctx.clip(to:mask:)` during draw
- `hitTest(_:)` returns `self` if `bgOpacity[py * bgWidth + px]`, else `nil` (click-through)
- **Always returns `self`, never a subview** — prevents NSImageView overlays eating clicks

**Mouse event flow:**
1. `hitTest` — pixel-level pass/fail via `bgOpacity`
2. `mouseDown` — groups (reversed z) → buttons (reversed z) → sliders → texts → drag
3. `mouseUp` — fires action on release if still over element; sliders commit value
4. `mouseMoved` — updates `hoveredColor` on groups, `isHovered` on buttons/texts via `reapplyHover()`

**Animated GIF subviews** (`animatedSubviews: [String: NSImageView]`):
- GIF backgroundImages get their own `NSImageView` (animates=true) added as actual subviews
- `promotedGifNames: Set<String>` — filenames managed by NSImageViews; CGContext skips these
- All NSImageViews sit above all CGContext drawing, regardless of zIndex
- One-pass GIFs: timed via `gifOnePassDuration`; tracked in `completedOnePassAnimations`
- JS-assigned GIFs created on demand in `promoteNewGifSubviews` (called from `applyScriptChanges`)

**Visualization (`<EFFECTS>` element):**
- `vizProvider` wraps projectM view; `vizContainer: NSView` is the NSView host
- `vizCoverInfos: [VizCoverInfo]` — NSImageViews that composite CGContext elements above the viz NSView
- `findEffects()` walks the element tree to find `<EFFECTS>` and collect sibling covers
- `renderVizCoverImages()` redraws covers each `draw()` cycle

**JS interaction (`applyScriptChanges()`):**
- Called after every user action that runs a JS script
- Calls `recollect()` → `updateLiveSliders()` → `updateAnimatedSubviewVisibility()` → `buildBgOpacity()` → `setNeedsDisplay`

**Z-ordering:**
- `sortedByZIndex()` sorts elements ascending before drawing and collecting
- Children with `zIndex < 0` draw before the parent's background image; `zIndex >= 0` draw after
- This split must stay in sync between `drawElements` and `collectButtons`/`collectSliders`

### `SkinScriptEngine.swift`
JavaScriptCore-based JScript runner. Injects element proxies (one JSValue per element id) that capture property assignments into `ElementScriptState`. `state(for: id)` returns the captured state. Stubs out WMP-specific APIs (`player`, `view`, `theme`, `mediacenter`). `evaluate(_:)` runs arbitrary JS; `evaluateNumber` / `evaluateWmpEnabled` for typed queries.

### `WMSParser.swift`
SAX-style XML parser. Handles UTF-16 encoding. Converts raw attribute strings into `AttributeValue` (`.literal`, `.wmpProp`, `.jsExpr`, `.wmpEnabled`).

### `AttributeValue.swift`
Enum for attribute value kinds. `LayoutContext.resolve(_:)` turns a literal AttributeValue into a CGFloat; wmpprop/jsExpr must go through `SkinScriptEngine`.

### `LayoutContext.swift`
Resolves `AttributeValue` to pixel values given view width/height. Used everywhere layout math happens.

## Coordinate system

- `SkinCanvasView.isFlipped = true` — NSView y=0 is at the visual top (matches WMS layout)
- `MapData` stores rows in CGContext order: row 0 = visual bottom
- `bgOpacity` uses flipped view order: row 0 = visual top
- Conversions between the two appear in `paintMdIntoOpacity` and `hitTest`

## Hit testing architecture

`hitTest` is overridden to:
1. Check `bgOpacity` for the pixel under the cursor (transparent pixels return `nil` = click-through)
2. Always return `self` on a hit — never a child NSImageView

This means NSImageView overlays (animated GIFs, viz covers) never receive mouse events. The NSTrackingArea on `self` delivers `mouseMoved` directly.

## Common debugging entry points

- Hover not working → check `reapplyHover()` at :1520, `ancestorsPassThrough`, `elementIsHidden`
- Button not firing → check `fireButtonAction` / `fireGroupAction`, `buttonIdx` sync in `drawElements`
- Click-through wrong region → `buildBgOpacity` at :515, `paintMdIntoOpacity` at :566
- GIF not animating → `buildAnimatedSubviews` at :2083, `promotedGifNames`
- Viz z-order issue → `vizCoverInfos`, `renderVizCoverImages` at :1802, `findEffects` at :1544
- JS property not taking effect → `ElementScriptState`, `SkinScriptEngine.state(for:)`, `recollect()`
- Slider value not updating → `updateLiveSliders` at :178, `applySlider` at :1317

## Test skins

Primary: `skins/windowsmediaplayerskinscollection/Plus! Pulsar/` — most complex, exercises nearly all features.
