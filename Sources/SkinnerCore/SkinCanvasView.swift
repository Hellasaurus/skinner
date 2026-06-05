import AppKit
import ImageIO

// MARK: - SkinCanvasView

/// An `NSView` that renders one `SkinView` from a parsed `Theme` using pre-loaded `AssetCache` data.
///
/// Phase 1 scope:
///   - Draws subview background images, button groups, simple buttons, and custom sliders.
///   - Honours z-index ordering and `visible="false"`.
///   - Shapes the window by blanking clicks on transparent (magenta) pixels.
///   - Fires console-only actions on interaction; no media playback.
///
/// Animated GIF subviews (intro shutters, playback animations) are rendered via `NSImageView`
/// overlays so they play at their native frame rate independently of the draw cycle.
public final class SkinCanvasView: NSView {

    private let skinView: SkinView
    private let cache:    AssetCache

    private var groups:          [RenderedGroup]  = []
    private var buttons:         [RenderedButton] = []
    private var sliders:         [RenderedSlider] = []
    private var bgOpacity:       [Bool]           = []
    private var bgWidth          = 0
    private var bgHeight         = 0
    private var bgMask:          CGImage?         = nil
    private let bundle:          SkinBundle?
    private var dragOrigin:      NSPoint?
    private var activeSliderIdx: Int?
    private var lastKnownMousePt: NSPoint?
    private var engine: SkinScriptEngine?
    private var animatedSubviews:              [String: NSImageView]            = [:]
    private var animatedSubviewBases:          [String: ElementBase]            = [:]
    private var animatedSubviewCurrentImage:   [String: String]                 = [:]
    private var animatedSubviewTransparency:   [String: [(UInt8, UInt8, UInt8)]] = [:]
    private var animatedSubviewWmsBackground:  [String: String]                  = [:]
    private var completedOnePassAnimations:    Set<String>                       = []
    /// IDs promoted at runtime by JS (e.g. mainShutter). These are interactive toggle elements.
    private var interactiveAnimatedSubviews:  Set<String>                       = []
    /// Lowercased image names whose drawing is handled by an NSImageView (including id-less
    /// GIF subviews). CGContext must not draw these, or the static first frame would cover
    /// the animated NSImageView and any elements drawn beneath it (e.g. the time text).
    private var promotedGifNames:             Set<String>                       = []
    /// Startup-animation IDs currently showing their WMS static fallback background
    /// (e.g. introShutterAnim showing shutter_close_static.gif after a close animation).
    private var startupFallbacksShowing:      Set<String>                       = []

    public var onOpenView:   ((String) -> Void)? { didSet { engine?.onOpenView  = onOpenView  } }
    public var onCloseView:  ((String) -> Void)? { didSet { engine?.onCloseView = onCloseView } }
    public var onDroppedURL: ((URL) -> Void)?

    private var playerBackend: (any PlayerBackend)?

    public func setPlayerBackend(_ backend: any PlayerBackend) {
        playerBackend = backend
        engine?.onStateChanged = { [weak self] in
            guard let self else { return }
            self.updateLiveSliders()
            self.updateAnimatedSubviewVisibility()
            self.recollect()
            self.setNeedsDisplay(self.bounds)
        }
        engine?.playerBackend = backend
    }

    private func updateAnimatedSubviewVisibility() {
        let isPlaying = playerBackend?.playState == .playing
        for (id, iv) in animatedSubviews {
            guard let base = animatedSubviewBases[id] else { continue }

            // Swap image when JS has changed backgroundImage (e.g. idle → playback GIF).
            // Check BEFORE the completion guard so a new image assignment restarts the animation.
            if let newName = engine?.state(for: id)?.backgroundImage?.lowercased(),
               newName != animatedSubviewCurrentImage[id],
               let bundle {
                // A new image assignment clears any prior one-pass completion state.
                completedOnePassAnimations.remove(id)
                let extra = animatedSubviewTransparency[id] ?? []
                let url   = bundle.assetURL(named: newName)
                let img: NSImage?
                var rawGif: NSImage? = nil
                if newName.hasSuffix(".gif"),
                   let raw = NSImage(contentsOf: url), gifIsAnimated(raw) {
                    img = loadGifMagentaFree(url: url, extraTransparent: extra) ?? raw
                    rawGif = raw
                } else {
                    img = cache.images[newName] ?? NSImage(contentsOf: url)
                }
                if let img {
                    iv.image    = img
                    iv.animates = newName.hasSuffix(".gif")
                    iv.isHidden = false
                    animatedSubviewCurrentImage[id] = newName
                    if let raw = rawGif, iv.animates, let dur = gifOnePassDuration(raw, excludingLastFrame: true) {
                        let interactive = interactiveAnimatedSubviews.contains(id)
                        let isClose = newName.contains("close")
                        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self, weak iv] in
                            iv?.animates = false
                            iv?.isHidden = true
                            if interactive {
                                // Show/hide the static fallback on overlapping startup elements
                                // (e.g. introShutterAnim shows shutter_close_static.gif to cover flag_extra).
                                if isClose { self?.restoreStartupFallbackImages() }
                                else       { self?.rehideStartupFallbackImages()  }
                            } else {
                                self?.completedOnePassAnimations.insert(id)
                            }
                        }
                    }
                }
            }

            // One-pass animations that have finished playing must stay hidden.
            if completedOnePassAnimations.contains(id) {
                iv.isHidden = true
                continue
            }

            // Subviews declared visible="false" in the WMS are playback-state animations.
            // Show them when playing; the skin JS doesn't reliably toggle them due to
            // visMark initialization ordering (e.g. Pulsar's playbackAnim/visMark=4 issue).
            let initiallyHidden: Bool
            if case .literal(let v) = base.visible {
                initiallyHidden = v.lowercased() == "false" || v == "0"
            } else {
                initiallyHidden = false
            }
            if initiallyHidden && playerBackend != nil {
                iv.isHidden = !isPlaying
            } else {
                iv.isHidden = elementIsHidden(base, live: true)
            }
        }
    }

    private func updateLiveSliders() {
        guard let backend = playerBackend else { return }
        let dur = backend.duration
        for i in sliders.indices {
            // Don't override display position of the actively-dragged slider.
            if i == activeSliderIdx { continue }
            switch sliders[i].model.kind {
            case .seek:
                sliders[i].value = dur > 0 ? min(1, max(0, backend.currentPosition / dur)) : 0
            case .volume:
                sliders[i].value = Double(backend.volume) / 100.0
            case .balance:
                sliders[i].value = (Double(backend.balance) + 100.0) / 200.0
            case .custom:
                guard let eng = engine else { break }
                let minV = resolveSliderBound(sliders[i].model.min) ?? 0
                let maxV = resolveSliderBound(sliders[i].model.max) ?? 100
                guard maxV > minV else { break }
                // wmpprop/jsExpr value binding takes precedence (e.g. volume = player.settings.volume)
                var raw: Double? = nil
                switch sliders[i].model.value {
                case .wmpProp(let expr): raw = eng.evaluateNumber(expr).map(Double.init)
                case .jsExpr(let expr):  raw = eng.evaluateNumber(expr).map(Double.init)
                default: break
                }
                // Fallback: read JS proxy .value set by script (e.g. seekMain.value = currentPosition)
                if raw == nil, let id = sliders[i].model.base.id {
                    raw = eng.evaluateNumber("\(id).value").map(Double.init)
                }
                if let rv = raw {
                    sliders[i].value = min(1, max(0, (rv - minV) / (maxV - minV)))
                }
            case .generic:
                // Generic <slider> elements may carry wmpprop/jsExpr value bindings (e.g. EQ band sliders).
                // Only update when such a binding is present; otherwise preserve the drag position.
                guard let eng = engine else { break }
                var raw: Double? = nil
                switch sliders[i].model.value {
                case .wmpProp(let expr): raw = eng.evaluateNumber(expr).map(Double.init)
                case .jsExpr(let expr):  raw = eng.evaluateNumber(expr).map(Double.init)
                default: break
                }
                if let rv = raw {
                    let minV = resolveSliderBound(sliders[i].model.min) ?? 0
                    let maxV = resolveSliderBound(sliders[i].model.max) ?? 100
                    guard maxV > minV else { break }
                    sliders[i].value = min(1, max(0, (rv - minV) / (maxV - minV)))
                }
            }
        }
    }

    /// Resolves a slider min/max attribute to a Double, supporting literal, jsExpr, and wmpprop.
    private func resolveSliderBound(_ av: AttributeValue?) -> Double? {
        guard let av else { return nil }
        let lc = LayoutContext(viewWidth: bounds.width, viewHeight: bounds.height)
        if let v = lc.resolve(av) { return Double(v) }
        if case .jsExpr(let expr) = av, let v = engine?.evaluateNumber(expr) { return Double(v) }
        if case .wmpProp(let expr) = av, let v = engine?.evaluateNumber(expr) { return Double(v) }
        return nil
    }

    public override var isFlipped: Bool { true }

    // MARK: - Init

    public init(skinView: SkinView, cache: AssetCache, bundle: SkinBundle? = nil) {
        self.skinView = skinView
        self.cache    = cache
        self.bundle   = bundle                 // stored before super.init (let property)

        let sizeCtx = LayoutContext(viewWidth: 0, viewHeight: 0)
        let bgImg = skinView.backgroundImage.flatMap { cache.images[$0.lowercased()] }
        let w = sizeCtx.resolve(skinView.width)  ?? bgImg?.size.width  ?? 320
        let h = sizeCtx.resolve(skinView.height) ?? bgImg?.size.height ?? 240
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))

        engine = bundle.flatMap { SkinScriptEngine(skinView: skinView, bundle: $0) }

        wantsLayer = true
        let lc = LayoutContext(viewWidth: bounds.width, viewHeight: bounds.height)
        // Collection and drawing both use sortedByZIndex + isHidden — same traversal order
        // guarantees the inout index counters in draw() stay in sync with the arrays.
        groups  = collectGroups(in: skinView.elements,  offset: .zero, lc: lc)
        buttons = collectButtons(in: skinView.elements, offset: .zero, lc: lc)
        sliders = collectSliders(in: skinView.elements, offset: .zero, lc: lc)
        buildBgOpacity()
        buildAnimatedSubviews(in: skinView.elements, offset: .zero, lc: lc)
        setupTracking()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout helpers

    /// Resolves a layout coordinate attribute. Falls back to evaluating the JS
    /// expression in the live engine when `LayoutContext` alone can't resolve it
    /// (e.g. bare global variable names like `iVolumeSmallLeft`).
    private func resolveCoord(_ av: AttributeValue?, lc: LayoutContext) -> CGFloat? {
        guard let av else { return nil }
        if let v = lc.resolve(av) { return v }
        if case .jsExpr(let expr) = av { return engine?.evaluateNumber(expr) }
        return nil
    }

    /// Resolves a layout coordinate for a named element, preferring the JS proxy's
    /// live value (updated by moveTo / direct assignment) over the static WMS expression.
    /// This is necessary because skins call `element.left = newPos` to reposition subviews
    /// at runtime, but the WMS attribute still holds the original expression.
    private func liveCoord(_ id: String?, attr: AttributeValue?, propName: String, lc: LayoutContext) -> CGFloat {
        if let id, let v = engine?.evaluateNumber("\(id).\(propName)") { return v }
        return resolveCoord(attr, lc: lc) ?? 0
    }

    // MARK: - Collection

    private func collectGroups(in elements: [SkinElement],
                                offset: CGPoint,
                                lc: LayoutContext) -> [RenderedGroup] {
        var result: [RenderedGroup] = []
        for element in sortedByZIndex(elements) {
            switch element {
            case .buttonGroup(let bg):
                guard !elementIsHidden(bg.base) else { continue }
                let x = (lc.resolve(bg.base.left)   ?? 0) + offset.x
                let y = (lc.resolve(bg.base.top)    ?? 0) + offset.y
                var w =  lc.resolve(bg.base.width)  ?? 0
                var h =  lc.resolve(bg.base.height) ?? 0
                if (w == 0 || h == 0), let n = bg.image, let img = cache.images[n.lowercased()] {
                    if w == 0 { w = img.size.width  }
                    if h == 0 { h = img.size.height }
                }
                let assets   = cache.buttonGroupAssets(forMappingImage: bg.mappingImage)
                               ?? ButtonGroupAssets(groupID: bg.base.id, fullMask: nil, masks: [:])
                let mapData  = bg.mappingImage.flatMap { cache.mapData[$0.lowercased()] }
                let clipMask = bg.clippingImage.flatMap { cache.clipMasks[$0.lowercased()] }
                result.append(RenderedGroup(model: bg, assets: assets, mapData: mapData,
                                            frame: CGRect(x: x, y: y, width: w, height: h),
                                            clipMask: clipMask))
            case .subview(let sv):
                guard !elementIsHidden(sv.base) else { continue }
                let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
                let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
                result += collectGroups(in: sv.children, offset: CGPoint(x: sx, y: sy), lc: lc)
            default: break
            }
        }
        return result
    }

    /// Traversal order must exactly match `drawElements` so index counters stay in sync.
    private func collectButtons(in elements: [SkinElement],
                                 offset: CGPoint,
                                 lc: LayoutContext) -> [RenderedButton] {
        var result: [RenderedButton] = []
        for element in sortedByZIndex(elements) {
            switch element {
            case .button(let b):
                guard !elementIsHidden(b.base) else { continue }
                let x = liveCoord(b.base.id, attr: b.base.left, propName: "left", lc: lc) + offset.x
                let y = liveCoord(b.base.id, attr: b.base.top,  propName: "top",  lc: lc) + offset.y
                let md       = b.image.flatMap { cache.mapData[$0.lowercased()] }
                let clipMask = b.clippingImage.flatMap { cache.clipMasks[$0.lowercased()] }
                var w  = lc.resolve(b.base.width)  ?? CGFloat(md?.width  ?? 0)
                var h  = lc.resolve(b.base.height) ?? CGFloat(md?.height ?? 0)
                if w == 0, let d = md { w = CGFloat(d.width)  }
                if h == 0, let d = md { h = CGFloat(d.height) }
                // Fallback to image pixel size for buttons that have no explicit
                // dimensions and no mapping image (e.g. close buttons in subviews).
                let imgName = b.image ?? b.hoverImage ?? b.downImage
                if w == 0, let n = imgName, let img = cache.images[n.lowercased()] { w = img.size.width  }
                if h == 0, let n = imgName, let img = cache.images[n.lowercased()] { h = img.size.height }
                result.append(RenderedButton(model: b,
                                             frame: CGRect(x: x, y: y, width: w, height: h),
                                             mapData: md,
                                             clipMask: clipMask))
            case .subview(let sv):
                guard !elementIsHidden(sv.base) else { continue }
                let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
                let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
                let svZ = sv.base.zIndex ?? 0
                let co  = CGPoint(x: sx, y: sy)
                result += collectButtons(in: sv.children.filter { $0.base?.zIndex != nil && ($0.base?.zIndex ?? 0) < svZ }, offset: co, lc: lc)
                result += collectButtons(in: sv.children.filter { $0.base?.zIndex == nil || ($0.base?.zIndex ?? 0) >= svZ }, offset: co, lc: lc)
            default: break
            }
        }
        return result
    }

    /// Traversal order must exactly match `drawElements` so index counters stay in sync.
    private func collectSliders(in elements: [SkinElement],
                                 offset: CGPoint,
                                 lc: LayoutContext) -> [RenderedSlider] {
        var result: [RenderedSlider] = []
        for element in sortedByZIndex(elements) {
            switch element {
            case .slider(let s):
                guard !elementIsHidden(s.base) else { continue }
                // Use engine-aware resolveCoord so jscript: expressions evaluate correctly.
                let rawX = resolveCoord(s.base.left, lc: lc) ?? 0
                let rawY = resolveCoord(s.base.top,  lc: lc) ?? 0
                // Propagate computed positions back to JS proxies so sibling-reference
                // jscript expressions (e.g. eq2.left = jscript:eq1.left+15) resolve correctly
                // when subsequent sliders in the same parent are processed.
                if let id = s.base.id {
                    if case .jsExpr = s.base.left { engine?.evaluate("\(id).left = \(rawX)") }
                    if case .jsExpr = s.base.top  { engine?.evaluate("\(id).top  = \(rawY)") }
                }
                let x = rawX + offset.x
                let y = rawY + offset.y
                let posMD = s.positionImage.flatMap { cache.mapData[$0.lowercased()] }
                var w    = resolveCoord(s.base.width,  lc: lc) ?? CGFloat(posMD?.width  ?? 0)
                var h    = resolveCoord(s.base.height, lc: lc) ?? CGFloat(posMD?.height ?? 0)
                var fc   = 1
                if let n = s.image, let img = cache.images[n.lowercased()],
                   let pd = posMD, pd.width > 0 {
                    fc = max(1, Int(img.size.width) / pd.width)
                    if w == 0 { w = CGFloat(pd.width)  }
                    if h == 0 { h = CGFloat(pd.height) }
                }
                // Fall back to track image dimensions for any still-missing axis.
                if w == 0 || h == 0 {
                    let trackImg = (s.backgroundImage ?? s.foregroundImage)
                        .flatMap { cache.images[$0.lowercased()] }
                    if w == 0 { w = trackImg?.size.width  ?? 0 }
                    if h == 0 { h = trackImg?.size.height ?? 0 }
                }
                if w == 0 || h == 0, let n = s.thumbImage, let img = cache.images[n.lowercased()] {
                    if w == 0 { w = img.size.width  }
                    if h == 0 { h = img.size.height }
                }
                var rs = RenderedSlider(model: s,
                                        frame: CGRect(x: x, y: y, width: w, height: h),
                                        frameCount: fc,
                                        positionMapData: posMD)
                rs.value = resolvedSliderValue(s)
                result.append(rs)
            case .subview(let sv):
                guard !elementIsHidden(sv.base) else { continue }
                let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
                let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
                let svZ = sv.base.zIndex ?? 0
                let co  = CGPoint(x: sx, y: sy)
                result += collectSliders(in: sv.children.filter { $0.base?.zIndex != nil && ($0.base?.zIndex ?? 0) < svZ }, offset: co, lc: lc)
                result += collectSliders(in: sv.children.filter { $0.base?.zIndex == nil || ($0.base?.zIndex ?? 0) >= svZ }, offset: co, lc: lc)
            default: break
            }
        }
        return result
    }

    // MARK: - Background opacity map

    private func buildBgOpacity() {
        let vw = Int(bounds.width), vh = Int(bounds.height)
        guard vw > 0, vh > 0 else { return }
        bgWidth  = vw
        bgHeight = vh
        bgOpacity = Array(repeating: false, count: vw * vh)
        // Paint view-level background image at its natural pixel size.
        // The declared view width/height may exceed the image (e.g. Tomb Raider 2), but
        // WMP always draws background images unscaled — the view size sets the window region.
        if let imgName = skinView.backgroundImage,
           let md = cache.mapData[imgName.lowercased()] {
            let extra: [(UInt8, UInt8, UInt8)] = [skinView.clippingColor, skinView.transparencyColor]
                .compactMap { $0.flatMap(parseAnyColor) }
            paintMdIntoOpacity(md: md, ox: 0, oy: 0, extraColors: extra)
        }
        let lc = LayoutContext(viewWidth: bounds.width, viewHeight: bounds.height)
        paintBgOpacity(in: skinView.elements, lc: lc, offset: .zero)
        bgMask = makeBgMask()
    }

    /// Converts the boolean `bgOpacity` map into a CGImage mask suitable for
    /// `CGContext.clip(to:mask:)`.  bgOpacity uses flipped coords (row 0 = visual
    /// top); the mask is consumed in a flipped CGContext (isFlipped=true) where row 0
    /// also lands at the visual top, so no row mirroring is needed.
    private func makeBgMask() -> CGImage? {
        guard bgWidth > 0, bgHeight > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: bgWidth * bgHeight)
        for i in 0 ..< bgWidth * bgHeight {
            bytes[i] = bgOpacity[i] ? 255 : 0
        }
        guard let space    = CGColorSpace(name: CGColorSpace.linearGray),
              let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { return nil }
        return CGImage(width: bgWidth, height: bgHeight,
                       bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: bgWidth,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// Paints one image's non-transparent pixels into the composite opacity map.
    ///
    /// `dstW`/`dstH` let the caller specify the destination size when the image will
    /// be drawn scaled (e.g. a view background drawn with `img.draw(in: bounds)`).
    /// Defaults to the MapData's own pixel dimensions (no scaling).
    ///
    /// Row order: MapData stores rows in CGContext order (row 0 = visual bottom).
    /// bgOpacity uses flipped view order (row 0 = visual top). The two are mirrored here.
    private func paintMdIntoOpacity(md: MapData, ox: Int, oy: Int,
                                     dstW: Int = 0, dstH: Int = 0,
                                     extraColors: [(UInt8, UInt8, UInt8)]) {
        let destW = dstW > 0 ? dstW : md.width
        let destH = dstH > 0 ? dstH : md.height

        for viewRow in 0 ..< destH {
            let vy = oy + viewRow
            guard vy >= 0, vy < bgHeight else { continue }
            // viewRow 0 = visual top; CGContext row 0 = visual bottom → mirror
            let srcVisRow = min(md.height - 1, viewRow * md.height / destH)
            let cgRow     = md.height - 1 - srcVisRow

            for viewCol in 0 ..< destW {
                let vx = ox + viewCol
                guard vx >= 0, vx < bgWidth else { continue }
                let srcCol = min(md.width - 1, viewCol * md.width / destW)

                let i = (cgRow * md.width + srcCol) * 4
                let r = md.bytes[i], g = md.bytes[i+1], b = md.bytes[i+2], a = md.bytes[i+3]
                guard a > 128, !isMagenta(r, g, b) else { continue }
                if extraColors.contains(where: { colorMatches(r, g, b, $0.0, $0.1, $0.2) }) { continue }
                bgOpacity[vy * bgWidth + vx] = true
            }
        }
    }

    /// Recursively paints every subview's background image into the composite opacity
    /// map. MapData rows are in CGContext order (row 0 = visual bottom); flipped view
    /// coords use row 0 = visual top, so each row index is mirrored when stored.
    private func paintBgOpacity(in elements: [SkinElement],
                                 lc: LayoutContext,
                                 offset: CGPoint) {
        for element in elements {
            guard case .subview(let sv) = element, !elementIsHidden(sv.base) else { continue }
            let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
            let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
            let bgName = sv.base.id.flatMap { engine?.state(for: $0)?.backgroundImage }
                         ?? sv.backgroundImage
            if let imgName = bgName,
               let md = cache.mapData[imgName.lowercased()] {
                let extra: [(UInt8, UInt8, UInt8)] = [sv.clippingColor, sv.base.transparencyColor]
                    .compactMap { $0.flatMap(parseAnyColor) }
                paintMdIntoOpacity(md: md, ox: Int(sx), oy: Int(sy), extraColors: extra)
            } else if let colorStr = sv.backgroundColor,
                      !colorStr.isEmpty, colorStr.lowercased() != "none",
                      let w = lc.resolve(sv.base.width).map(Int.init),
                      let h = lc.resolve(sv.base.height).map(Int.init),
                      w > 0, h > 0 {
                // Solid-color subview interiors (no background image) are visually opaque
                // and must be hittable — e.g. the EQ drawer in Headspace whose inner area
                // is filled via backgroundColor rather than an image.
                let ox = Int(sx), oy = Int(sy)
                for row in 0 ..< h {
                    let vy = oy + row
                    guard vy >= 0, vy < bgHeight else { continue }
                    for col in 0 ..< w {
                        let vx = ox + col
                        guard vx >= 0, vx < bgWidth else { continue }
                        bgOpacity[vy * bgWidth + vx] = true
                    }
                }
            }
            paintBgOpacity(in: sv.children, lc: lc, offset: CGPoint(x: sx, y: sy))
        }
    }

    private func setupTracking() {
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        ))
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let lc  = LayoutContext(viewWidth: bounds.width, viewHeight: bounds.height)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let name = skinView.backgroundImage, let img = cache.images[name.lowercased()] {
            // Draw at natural pixel size — view width/height may exceed the image (e.g. Tomb Raider 2).
            let imgRect = NSRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
            if let mask = bgMask {
                ctx.saveGState()
                // Clip to full bounds so the mask CGImage (view-size) is not scaled.
                // Pixels outside imgRect are never drawn, so the wider clip is harmless.
                ctx.clip(to: bounds, mask: mask)
                img.draw(in: imgRect)
                ctx.restoreGState()
            } else {
                img.draw(in: imgRect)
            }
        }
        var bi = 0
        var si = 0
        drawElements(skinView.elements, offset: .zero, lc: lc, ctx: ctx,
                     buttonIdx: &bi, sliderIdx: &si)
    }

    private func drawElements(_ elements: [SkinElement],
                               offset: CGPoint,
                               lc: LayoutContext,
                               ctx: CGContext,
                               buttonIdx: inout Int,
                               sliderIdx: inout Int) {
        for element in sortedByZIndex(elements) {
            switch element {

            case .subview(let sv):
                guard !elementIsHidden(sv.base, live: true) else { continue }
                let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
                let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
                let childOffset = CGPoint(x: sx, y: sy)
                let alpha = effectiveAlpha(for: sv.base)
                let needsAlpha = alpha < 255
                // Clip children to the subview's declared bounds when both dimensions are
                // literal values.  This implements the sprite-font viewport: a narrow parent
                // subview (e.g. width=11) wrapping a full sprite-sheet button (width=110)
                // shows only one digit-column at a time.  JS scrolls the button's left
                // position to select the displayed digit.  Subviews with JS-computed sizes
                // (jscript:…) resolve to nil and are not clipped.
                let clipW = lc.resolve(sv.base.width)
                let clipH = lc.resolve(sv.base.height)
                let needsClip = clipW != nil && clipH != nil
                let needsGState = needsClip || needsAlpha
                if needsGState { ctx.saveGState() }
                if needsClip {
                    ctx.clip(to: CGRect(x: sx, y: sy, width: clipW!, height: clipH!))
                }
                if needsAlpha {
                    ctx.setAlpha(CGFloat(alpha) / 255.0)
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                }
                // Fill backgroundColor before drawing the background image so the image sits on top.
                // Only fill when we have explicit clip dimensions; otherwise size is unknown.
                if let colorStr = sv.backgroundColor,
                   colorStr.lowercased() != "none", !colorStr.isEmpty,
                   let rgb = parseAnyColor(colorStr),
                   let w = clipW, let h = clipH {
                    NSColor(skinRGB: rgb).setFill()
                    NSBezierPath.fill(NSRect(x: sx, y: sy, width: w, height: h))
                }
                // A subview's backgroundImage is always its background — draw it before all
                // children regardless of their zIndex values.  Child zIndex governs stacking
                // among siblings, not relative to the parent container's own background.
                if sv.base.id.flatMap({ animatedSubviews[$0] }) == nil {
                    let bgName = sv.base.id.flatMap { engine?.state(for: $0)?.backgroundImage }
                                 ?? sv.backgroundImage
                    if let name = bgName,
                       cache.buttonGroupsByMappingImage[name.lowercased()] == nil,
                       !cache.clipImageNames.contains(name.lowercased()),
                       // Also skip GIFs promoted to NSImageViews that have no id (e.g. intro
                       // animations). Drawing their static first frame from cache would cover
                       // any elements beneath them (e.g. the time text) permanently.
                       !promotedGifNames.contains(name.lowercased()),
                       let img  = cache.images[name.lowercased()] {
                        let w = lc.resolve(sv.base.width)  ?? img.size.width
                        let h = lc.resolve(sv.base.height) ?? img.size.height
                        img.draw(in: NSRect(x: sx, y: sy, width: w, height: h))
                    }
                }
                drawElements(sv.children, offset: childOffset, lc: lc, ctx: ctx,
                             buttonIdx: &buttonIdx, sliderIdx: &sliderIdx)
                if needsAlpha { ctx.endTransparencyLayer() }
                if needsGState { ctx.restoreGState() }

            case .buttonGroup(let bg):
                guard !elementIsHidden(bg.base, live: true) else { continue }
                if let rg = groups.first(where: { $0.model.mappingImage == bg.mappingImage }) {
                    // Recompute position from the live offset so groups inside JS-moved
                    // subviews draw at the correct position rather than their stale init frame.
                    let x = (lc.resolve(bg.base.left) ?? 0) + offset.x
                    let y = (lc.resolve(bg.base.top)  ?? 0) + offset.y
                    var w = lc.resolve(bg.base.width)  ?? 0
                    var h = lc.resolve(bg.base.height) ?? 0
                    if (w == 0 || h == 0), let n = bg.image, let img = cache.images[n.lowercased()] {
                        if w == 0 { w = img.size.width  }
                        if h == 0 { h = img.size.height }
                    }
                    drawGroup(rg, frame: CGRect(x: x, y: y, width: w, height: h), ctx: ctx)
                }

            case .button(let b):
                // Advance the counter whenever the button was collected (static check),
                // even if it's dynamically hidden now — keeps the index in sync.
                guard !elementIsHidden(b.base) else { continue }
                defer { buttonIdx += 1 }
                if !elementIsHidden(b.base, live: true), buttonIdx < buttons.count {
                    drawButton(buttons[buttonIdx], ctx: ctx)
                }

            case .slider(let s):
                guard !elementIsHidden(s.base) else { continue }
                defer { sliderIdx += 1 }
                if !elementIsHidden(s.base, live: true), sliderIdx < sliders.count {
                    drawSlider(sliders[sliderIdx])
                }

            case .playlist(let p):
                guard !elementIsHidden(p.base, live: true) else { continue }
                let x = (lc.resolve(p.base.left) ?? 0) + offset.x
                let y = (lc.resolve(p.base.top)  ?? 0) + offset.y
                // Only fall back to full view dimensions when there is no attribute at all.
                // If the attribute exists but can't be resolved (e.g. jscript:someProxy.width),
                // skip drawing rather than covering the entire view.
                let w: CGFloat
                let h: CGFloat
                if let rw = lc.resolve(p.base.width)        { w = rw }
                else if p.base.width == nil                  { w = lc.viewWidth }
                else                                         { continue }
                if let rh = lc.resolve(p.base.height)       { h = rh }
                else if p.base.height == nil                 { h = lc.viewHeight }
                else                                         { continue }
                let rect = NSRect(x: x, y: y, width: w, height: h)
                let bg = parseAnyColor(p.backgroundColor ?? "#1a1a2e") ?? (0x1a, 0x1a, 0x2e)
                NSColor(skinRGB: bg).setFill()
                NSBezierPath.fill(rect)
                let fg = parseAnyColor(p.foregroundColor ?? "#cccccc") ?? (0xcc, 0xcc, 0xcc)
                drawCenteredText("Playlist", in: rect, color: NSColor(skinRGB: fg))

            case .text(let t):
                guard !elementIsHidden(t.base, live: true) else { continue }
                let tx = (resolveCoord(t.base.left,   lc: lc) ?? 0) + offset.x
                let ty = (resolveCoord(t.base.top,    lc: lc) ?? 0) + offset.y
                let tw =  resolveCoord(t.base.width,  lc: lc) ?? 100
                let th =  resolveCoord(t.base.height, lc: lc) ?? 14
                // wmpprop:/jsExpr: bindings are always evaluated live so they reflect
                // current playback state (e.g. time position string) rather than a stale
                // JS proxy value set during a previous player state change (e.g. "00:00"
                // written by onChangePlayerState when stopped). For literal/absent value
                // attributes, JS proxy state is the authoritative source (e.g. metadata
                // text set by updateMetadata).
                let text: String
                switch t.value {
                case .wmpProp, .jsExpr:
                    text = engine?.resolveText(t.value) ?? ""
                default:
                    let scriptValue = t.base.id.flatMap { engine?.state(for: $0)?.value }
                    text = scriptValue ?? engine?.resolveText(t.value) ?? t.value?.literalString ?? ""
                }
                guard !text.isEmpty else { continue }
                drawTextLabel(text, in: NSRect(x: tx, y: ty, width: tw, height: th), label: t)

            default: break
            }
        }
    }

    private func drawTextLabel(_ text: String, in rect: NSRect, label: TextLabel) {
        let pointSize = CGFloat(label.fontSize ?? 10)
        let isBold   = label.fontStyle?.lowercased().contains("bold")   ?? false
        let isItalic = label.fontStyle?.lowercased().contains("italic") ?? false
        let font: NSFont
        if let face = label.fontFace {
            var descriptor = NSFontDescriptor(fontAttributes: [.family: face])
            var traits: NSFontDescriptor.SymbolicTraits = []
            if isBold   { traits.insert(.bold) }
            if isItalic { traits.insert(.italic) }
            if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits) }
            font = NSFont(descriptor: descriptor, size: pointSize) ?? NSFont.systemFont(ofSize: pointSize)
        } else {
            font = NSFont.systemFont(ofSize: pointSize)
        }
        let fgRGB = parseAnyColor(label.foregroundColor ?? "#ffffff") ?? (0xff, 0xff, 0xff)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        switch label.justification?.lowercased() {
        case "center": paragraphStyle.alignment = .center
        case "right":  paragraphStyle.alignment = .right
        default:       paragraphStyle.alignment = .left
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(skinRGB: fgRGB),
            .font: font,
            .paragraphStyle: paragraphStyle,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textH = attrStr.boundingRect(with: NSSize(width: rect.width, height: .infinity),
                                         options: .usesLineFragmentOrigin).height
        let drawRect = NSRect(x: rect.minX,
                              y: rect.minY + max(0, (rect.height - textH) / 2),
                              width: rect.width,
                              height: rect.height)
        attrStr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawCenteredText(_ text: String, in rect: NSRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pt   = NSPoint(x: rect.midX - size.width / 2,
                           y: rect.midY - size.height / 2)
        (text as NSString).draw(at: pt, withAttributes: attrs)
    }

    // MARK: - Per-element drawing

    private func drawGroup(_ group: RenderedGroup, frame: CGRect, ctx: CGContext) {
        guard let imgName = group.model.image,
              let normal  = cache.images[imgName.lowercased()]
        else { return }

        let rect   = frame
        let cgRect = CGRect(origin: rect.origin, size: rect.size)

        ctx.saveGState()
        if let clip = group.clipMask {
            ctx.clip(to: cgRect, mask: clip)
        } else if let full = group.assets.fullMask {
            ctx.clip(to: cgRect, mask: full)
        }
        normal.draw(in: rect)
        ctx.restoreGState()

        if let key  = group.hoveredColor,
           let name = group.model.hoverImage,
           let img  = cache.images[name.lowercased()],
           let mask = group.assets.masks[key] {
            ctx.saveGState()
            if let clip = group.clipMask { ctx.clip(to: cgRect, mask: clip) }
            ctx.clip(to: cgRect, mask: mask)
            img.draw(in: rect)
            ctx.restoreGState()
        }

        if let key  = group.pressedColor,
           let name = group.model.downImage,
           let img  = cache.images[name.lowercased()],
           let mask = group.assets.masks[key] {
            ctx.saveGState()
            if let clip = group.clipMask { ctx.clip(to: cgRect, mask: clip) }
            ctx.clip(to: cgRect, mask: mask)
            img.draw(in: rect)
            ctx.restoreGState()
        }
    }

    private func drawButton(_ button: RenderedButton, ctx: CGContext) {
        let name: String?
        if button.isPressed      { name = button.model.downImage  ?? button.model.image }
        else if button.isHovered { name = button.model.hoverImage ?? button.model.image }
        else                     { name = button.model.image }
        guard let n = name, let img = cache.images[n.lowercased()] else { return }
        // Draw at natural pixel size from the button origin.  The declared button
        // width/height defines the interaction area; the parent subview's clip rect
        // (set in drawElements) acts as the viewport — this is how sprite-font digit
        // buttons work: a wide sprite sheet is scrolled behind a narrow clip window.
        let drawRect = NSRect(x: button.frame.minX, y: button.frame.minY,
                              width: img.size.width, height: img.size.height)
        if let clip = button.clipMask {
            ctx.saveGState()
            ctx.clip(to: drawRect, mask: clip)
            img.draw(in: drawRect)
            ctx.restoreGState()
        } else {
            img.draw(in: drawRect)
        }
    }

    private func drawSlider(_ slider: RenderedSlider) {
        if slider.model.positionImage != nil {
            drawSpriteSlider(slider)
        } else if slider.model.thumbImage != nil {
            drawStandardSlider(slider)
        } else if let name = slider.model.image, let img = cache.images[name.lowercased()] {
            img.draw(in: slider.frame)
        }
    }

    private func drawSpriteSlider(_ slider: RenderedSlider) {
        guard let name = slider.model.image,
              let img  = cache.images[name.lowercased()]
        else { return }

        if slider.frameCount <= 1 {
            img.draw(in: slider.frame)
        } else {
            let fw   = Int(img.size.width) / slider.frameCount
            let fh   = Int(img.size.height)
            let src  = NSRect(x: CGFloat(slider.frameIndex * fw), y: 0,
                              width: CGFloat(fw), height: CGFloat(fh))
            let dest = NSRect(origin: slider.frame.origin,
                              size:   CGSize(width: fw, height: fh))
            img.draw(in: dest, from: src, operation: .sourceOver, fraction: 1.0,
                     respectFlipped: true, hints: nil)
        }
    }

    /// Draws a slider track image using 3-slice (end-cap) rendering when tiled=true.
    /// Cap size = half the image's minor dimension. The middle section is a single center
    /// pixel (row for vertical, column for horizontal) stretched to fill, matching WMP behaviour.
    private func drawSliderTrackImage(_ img: NSImage, in frame: NSRect, isVertical: Bool, tiled: Bool) {
        let iw = img.size.width, ih = img.size.height
        guard tiled else { img.draw(in: frame); return }
        // NSImage y=0 is at the image visual-bottom; with respectFlipped:true in a flipped
        // view the mapping is: NSImage y=ih-1 → dest top, NSImage y=0 → dest bottom.
        if isVertical {
            let cap = (iw / 2).rounded(.down)
            guard cap > 0, ih > 2 * cap, frame.height > 2 * cap else { img.draw(in: frame); return }
            // Single center row of the middle section (NSImage y = (ih-1)/2 rounded down)
            let midY = ((ih - 1) / 2).rounded(.down)
            img.draw(in: NSRect(x: frame.minX, y: frame.minY, width: iw, height: cap),
                     from: NSRect(x: 0, y: ih - cap, width: iw, height: cap),
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            img.draw(in: NSRect(x: frame.minX, y: frame.minY + cap, width: iw, height: frame.height - 2 * cap),
                     from: NSRect(x: 0, y: midY, width: iw, height: 1),
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            img.draw(in: NSRect(x: frame.minX, y: frame.maxY - cap, width: iw, height: cap),
                     from: NSRect(x: 0, y: 0, width: iw, height: cap),
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let cap = (ih / 2).rounded(.down)
            guard cap > 0, iw > 2 * cap, frame.width > 2 * cap else { img.draw(in: frame); return }
            let midX = ((iw - 1) / 2).rounded(.down)
            img.draw(in: NSRect(x: frame.minX, y: frame.minY, width: cap, height: ih),
                     from: NSRect(x: 0, y: 0, width: cap, height: ih),
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            img.draw(in: NSRect(x: frame.minX + cap, y: frame.minY, width: frame.width - 2 * cap, height: ih),
                     from: NSRect(x: midX, y: 0, width: 1, height: ih),
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            img.draw(in: NSRect(x: frame.maxX - cap, y: frame.minY, width: cap, height: ih),
                     from: NSRect(x: iw - cap, y: 0, width: cap, height: ih),
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func drawStandardSlider(_ slider: RenderedSlider) {
        let frame = slider.frame
        let isVertical = slider.model.direction?.lowercased() == "vertical"

        if let bgName = slider.model.backgroundImage,
           let bg = cache.images[bgName.lowercased()] {
            drawSliderTrackImage(bg, in: frame, isVertical: isVertical, tiled: slider.model.tiled)
        }
        if let trackName = slider.model.foregroundImage,
           let track = cache.images[trackName.lowercased()] {
            track.draw(in: frame)
        }

        guard let thumbName = slider.model.thumbImage,
              let thumb = cache.images[thumbName.lowercased()] else { return }

        let thumbW  = thumb.size.width
        let thumbH  = thumb.size.height
        let border  = CGFloat(slider.model.borderSize ?? 0)
        let v       = slider.value

        // borderSize is the distance from each edge to the thumb's CENTER at the extremes.
        // The thumb image can slightly clip at the edges; clamp to stay within the frame.
        let thumbRect: NSRect
        if isVertical {
            let travel = max(0, frame.height - border * 2)
            let rawY   = frame.minY + border + (1 - v) * travel - thumbH / 2
            let thumbY = max(frame.minY, min(frame.maxY - thumbH, rawY))
            let thumbX = frame.minX + (frame.width - thumbW) / 2
            thumbRect = NSRect(x: thumbX, y: thumbY, width: thumbW, height: thumbH)
        } else {
            let travel = max(0, frame.width  - border * 2)
            let rawX   = frame.minX + border + v * travel - thumbW / 2
            let thumbX = max(frame.minX, min(frame.maxX - thumbW, rawX))
            let thumbY = frame.minY + (frame.height - thumbH) / 2
            thumbRect = NSRect(x: thumbX, y: thumbY, width: thumbW, height: thumbH)
        }
        thumb.draw(in: thumbRect)
    }

    private func resolvedSliderValue(_ s: Slider) -> Double {
        let minV = s.min?.doubleValue ?? 0
        let maxV = s.max?.doubleValue ?? 1
        let rawV = s.value?.doubleValue   // nil for wmpprop: bindings → default center
        let v    = rawV ?? ((minV + maxV) / 2)
        guard maxV > minV else { return 0 }
        return min(1, max(0, (v - minV) / (maxV - minV)))
    }

    // MARK: - Hit testing

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard bgWidth > 0 else { return super.hitTest(point) }
        // point arrives in flipped view coords (y=0 at top); composite map uses same convention.
        let px = Int(point.x), py = Int(point.y)
        guard px >= 0, px < bgWidth, py >= 0, py < bgHeight else { return nil }
        guard bgOpacity[py * bgWidth + px] else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Tracking areas

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        setupTracking()
    }

    // MARK: - Mouse events

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        for i in sliders.indices.reversed() {
            guard !elementIsHidden(sliders[i].model.base, live: true) else { continue }
            if let norm = sliderNormalizedValue(at: pt, slider: sliders[i]) {
                activeSliderIdx = i
                applySlider(idx: i, normalized: norm, isMouseUp: false)
                return
            }
        }
        for i in groups.indices.reversed() {
            guard !elementIsHidden(groups[i].model.base, live: true) else { continue }
            if let color = groups[i].colorAt(pt) {
                groups[i].pressedColor = color
                setNeedsDisplay(bounds)
                return
            }
        }
        for i in buttons.indices.reversed() {
            guard !elementIsHidden(buttons[i].model.base, live: true) else { continue }
            guard buttons[i].hitTest(pt) else { continue }
            buttons[i].isPressed = true
            setNeedsDisplay(bounds)
            return
        }
        dragOrigin = NSEvent.mouseLocation
    }

    public override func mouseDragged(with event: NSEvent) {
        if let i = activeSliderIdx {
            let pt = convert(event.locationInWindow, from: nil)
            // Clamp to the slider frame so dragging slightly outside still works.
            let clamped = CGPoint(
                x: min(max(pt.x, sliders[i].frame.minX), sliders[i].frame.maxX - 1),
                y: min(max(pt.y, sliders[i].frame.minY), sliders[i].frame.maxY - 1)
            )
            if let norm = sliderNormalizedValue(at: clamped, slider: sliders[i]) {
                applySlider(idx: i, normalized: norm, isMouseUp: false)
            }
            return
        }
        guard let origin = dragOrigin, let win = window else { return }
        let current = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(
            x: win.frame.origin.x + current.x - origin.x,
            y: win.frame.origin.y + current.y - origin.y
        ))
        dragOrigin = current
    }

    public override func mouseUp(with event: NSEvent) {
        if let i = activeSliderIdx {
            let pt = convert(event.locationInWindow, from: nil)
            let clamped = CGPoint(
                x: min(max(pt.x, sliders[i].frame.minX), sliders[i].frame.maxX - 1),
                y: min(max(pt.y, sliders[i].frame.minY), sliders[i].frame.maxY - 1)
            )
            if let norm = sliderNormalizedValue(at: clamped, slider: sliders[i]) {
                applySlider(idx: i, normalized: norm, isMouseUp: true)
            } else {
                applySlider(idx: i, normalized: sliders[i].value, isMouseUp: true)
            }
            activeSliderIdx = nil
            return
        }
        defer { dragOrigin = nil }
        let pt = convert(event.locationInWindow, from: nil)
        for i in groups.indices {
            guard let pressed = groups[i].pressedColor else { continue }
            let group = groups[i]           // snapshot before firing; action may rebuild groups
            groups[i].pressedColor = nil
            setNeedsDisplay(bounds)
            if group.colorAt(pt) == pressed { fireGroupAction(group, colorKey: pressed) }
            return
        }
        for i in buttons.indices.reversed() {
            guard buttons[i].isPressed else { continue }
            if buttons[i].hitTest(pt) { fireButtonAction(buttons[i]) }
            buttons[i].isPressed = false
            setNeedsDisplay(bounds)
            return
        }
    }

    // MARK: - Slider interaction

    /// Returns a normalized 0–1 value for a click at `pt` on a CustomSlider (positionImage),
    /// or a position-fraction for a standard slider. Returns nil if the point doesn't hit.
    private func sliderNormalizedValue(at pt: CGPoint, slider: RenderedSlider) -> Double? {
        guard slider.frame.contains(pt) else { return nil }
        let lx = Int(pt.x - slider.frame.minX)
        let ly = Int(pt.y - slider.frame.minY)

        if let md = slider.positionMapData {
            guard lx >= 0, lx < md.width, ly >= 0, ly < md.height else { return nil }
            let i = (ly * md.width + lx) * 4
            guard i + 3 < md.bytes.count else { return nil }
            let r = md.bytes[i], g = md.bytes[i+1], b = md.bytes[i+2], a = md.bytes[i+3]
            guard a > 128, !isMagenta(r, g, b) else { return nil }
            return Double(r) / 255.0
        }

        // Standard (thumb) slider: map cursor position along the track.
        // borderSize is the thumb-center-to-edge distance, so travel = dimension - 2*border.
        let border = CGFloat(slider.model.borderSize ?? 0)
        let vertical = slider.model.direction?.lowercased() == "vertical"
        if vertical {
            let travel = max(1, slider.frame.height - border * 2)
            return min(1, max(0, 1 - (CGFloat(ly) - border) / travel))
        } else {
            let travel = max(1, slider.frame.width - border * 2)
            return min(1, max(0, (CGFloat(lx) - border) / travel))
        }
    }

    /// Updates slider display, injects `value` into JS, fires value_onchange continuously
    /// and onmouseup at release.
    private func applySlider(idx: Int, normalized: Double, isMouseUp: Bool) {
        sliders[idx].value = normalized
        let slider = sliders[idx]
        let minV   = resolveSliderBound(slider.model.min) ?? 0
        let maxV   = resolveSliderBound(slider.model.max) ?? 100
        let raw    = minV + normalized * (maxV - minV)

        if let id = slider.model.base.id {
            engine?.evaluate("\(id).value = \(raw)")
        }
        if let script = slider.model.valueOnChange, !script.isEmpty {
            engine?.evaluate("value = \(raw); \(script)")
        }
        if isMouseUp, let script = slider.model.base.onMouseUp, !script.isEmpty {
            engine?.evaluate(script)
        }

        // Direct backend calls for standard kinds — fallback for skins without JS scripts,
        // and guarantees correct behavior regardless of whether the skin script fires.
        if let backend = playerBackend {
            switch slider.model.kind {
            case .seek:
                // Only seek on release; continuous seeking during drag is choppy with AVFoundation.
                if isMouseUp { backend.seek(to: raw) }
            case .volume:
                backend.volume = max(0, min(100, Int(raw.rounded())))
            case .balance:
                backend.balance = max(-100, min(100, Int(raw.rounded())))
            default: break
            }
        }

        applyScriptChanges()
    }

    public override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        lastKnownMousePt = pt
        var changed = false
        var groupHitHandled = false
        for i in groups.indices.reversed() {
            let hidden = elementIsHidden(groups[i].model.base, live: true)
            let h: String? = (!hidden && !groupHitHandled) ? groups[i].colorAt(pt) : nil
            if h != nil { groupHitHandled = true }
            if h != groups[i].hoveredColor { groups[i].hoveredColor = h; changed = true }
        }
        var buttonHitHandled = false
        for i in buttons.indices.reversed() {
            let hidden = elementIsHidden(buttons[i].model.base, live: true)
            let h = !hidden && !buttonHitHandled && buttons[i].hitTest(pt)
            if h { buttonHitHandled = true }
            if h != buttons[i].isHovered {
                buttons[i].isHovered = h
                changed = true
                if h, let script = buttons[i].model.base.onMouseOver { engine?.evaluate(script) }
                else if !h, let script = buttons[i].model.base.onMouseOut { engine?.evaluate(script) }
            }
        }
        if changed { setNeedsDisplay(bounds) }
    }

    // MARK: - Drag and drop

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: opts) else {
            return []
        }
        return .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
                .readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
              let url = urls.first else { return false }
        onDroppedURL?(url)
        return true
    }

    public override func mouseExited(with event: NSEvent) {
        lastKnownMousePt = nil
        var changed = false
        for i in groups.indices where groups[i].hoveredColor != nil || groups[i].pressedColor != nil {
            groups[i].hoveredColor = nil; groups[i].pressedColor = nil; changed = true
        }
        for i in buttons.indices where buttons[i].isHovered || buttons[i].isPressed {
            buttons[i].isHovered = false; buttons[i].isPressed = false; changed = true
        }
        if changed { setNeedsDisplay(bounds) }
    }

    // MARK: - Actions

    private func fireGroupAction(_ group: RenderedGroup, colorKey: String) {
        let elem = group.model.elements.first { $0.mappingColor.lowercased() == colorKey }
        if let script = elem?.onClick { engine?.evaluate(script); applyScriptChanges(); return }
        if let backend = playerBackend {
            switch elem?.kind {
            case .play:   backend.play()
            case .pause:  backend.pause()
            case .stop:   backend.stop()
            case .next:   backend.next()
            case .prev:   backend.previous()
            case .custom, nil:
                print("[ACTION] \(group.model.base.id ?? "buttongroup") / \(elem?.id ?? colorKey)")
            }
        } else {
            print("[ACTION] \(group.model.base.id ?? "buttongroup") / \(elem?.id ?? colorKey)")
        }
    }

    private func fireButtonAction(_ button: RenderedButton) {
        if let script = button.model.base.onClick { engine?.evaluate(script); applyScriptChanges(); return }
        switch button.model.kind {
        case .mute:    playerBackend?.isMuted.toggle()
        case .generic: print("[ACTION] button / \(button.model.base.id ?? button.model.image ?? "?")")
        }
    }

    /// Rebuilds hit-test frames for groups, buttons, and sliders using live JS state.
    /// Must be called whenever JS changes element positions (moveTo, direct property write).
    private func recollect() {
        let lc = LayoutContext(viewWidth: bounds.width, viewHeight: bounds.height)

        // Snapshot interactive state before rebuilding so a position-tick recollect
        // between mouseDown and mouseUp doesn't swallow button clicks or lose hover.
        let savedSliderValues  = sliders.map { $0.value }
        let savedGroupCount    = groups.count
        let savedGroupPressed  = groups.enumerated().compactMap { (i, g) -> (Int, String)? in
            guard let p = g.pressedColor else { return nil }
            return (i, p)
        }
        let savedButtonPressed = Set(buttons.compactMap { b -> String? in
            b.isPressed ? b.model.base.id : nil
        })

        groups  = collectGroups(in: skinView.elements,  offset: .zero, lc: lc)
        buttons = collectButtons(in: skinView.elements, offset: .zero, lc: lc)
        sliders = collectSliders(in: skinView.elements, offset: .zero, lc: lc)

        for i in sliders.indices where i < savedSliderValues.count {
            sliders[i].value = savedSliderValues[i]
        }
        // Only restore per-index pressed state when the group list is structurally identical
        // (position-tick recollect). If the count changed (color scheme swap, visibility toggle)
        // the indices no longer correspond and we leave pressedColor nil on all groups.
        if groups.count == savedGroupCount {
            for (i, p) in savedGroupPressed {
                groups[i].pressedColor = p
            }
        }
        for i in buttons.indices {
            if let id = buttons[i].model.base.id, savedButtonPressed.contains(id) {
                buttons[i].isPressed = true
            }
        }

        reapplyHover()
    }

    private func reapplyHover() {
        guard let pt = lastKnownMousePt else { return }
        var groupHitHandled = false
        for i in groups.indices.reversed() {
            let hidden = elementIsHidden(groups[i].model.base, live: true)
            let h: String? = (!hidden && !groupHitHandled) ? groups[i].colorAt(pt) : nil
            if h != nil { groupHitHandled = true }
            groups[i].hoveredColor = h
        }
        var buttonHitHandled = false
        for i in buttons.indices.reversed() {
            let hidden = elementIsHidden(buttons[i].model.base, live: true)
            let h = !hidden && !buttonHitHandled && buttons[i].hitTest(pt)
            if h { buttonHitHandled = true }
            buttons[i].isHovered = h
        }
    }

    private func applyScriptChanges() {
        engine?.fireOnEndMoveCallbacks()
        recollect()
        updateLiveSliders()
        updateAnimatedSubviewVisibility()
        // Rebuild the click-through mask so elements moved by JS (e.g. sEqEar sliding open)
        // register as clickable at their new positions.
        buildBgOpacity()
        if let bundle {
            let lc = LayoutContext(viewWidth: bounds.width, viewHeight: bounds.height)
            promoteNewGifSubviews(in: skinView.elements, offset: .zero, lc: lc, bundle: bundle)
        }
        setNeedsDisplay(bounds)
    }

    /// Scans the element tree for subviews that have been dynamically assigned a GIF background
    /// by JS (e.g. via `mainShutter.backgroundImage = "shutter_open2.gif"`) but don't yet have
    /// an NSImageView. Creates one on demand so the animation plays correctly.
    /// Called only from applyScriptChanges (user interactions), not on every position tick.
    private func promoteNewGifSubviews(in elements: [SkinElement],
                                        offset: CGPoint,
                                        lc: LayoutContext,
                                        bundle: SkinBundle) {
        for element in sortedByZIndex(elements) {
            guard case .subview(let sv) = element else { continue }
            let x = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
            let y = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
            let co = CGPoint(x: x, y: y)

            if let id = sv.base.id,
               animatedSubviews[id] == nil,
               !completedOnePassAnimations.contains(id),
               let newName = engine?.state(for: id)?.backgroundImage?.lowercased(),
               newName.hasSuffix(".gif"),
               !cache.clipImageNames.contains(newName),
               let raw = NSImage(contentsOf: bundle.assetURL(named: newName)),
               gifIsAnimated(raw) {
                let extra: [(UInt8, UInt8, UInt8)] = [sv.clippingColor, sv.base.transparencyColor]
                    .compactMap { $0.flatMap(parseAnyColor) }
                let img = loadGifMagentaFree(url: bundle.assetURL(named: newName),
                                              extraTransparent: extra) ?? raw
                let w = lc.resolve(sv.base.width)  ?? img.size.width
                let h = lc.resolve(sv.base.height) ?? img.size.height
                let iv = NSImageView(frame: NSRect(x: x, y: y, width: w, height: h))
                iv.image        = img
                iv.animates     = true
                iv.imageScaling = .scaleAxesIndependently
                iv.isHidden     = elementIsHidden(sv.base, live: true)
                addSubview(iv)
                if let dur = gifOnePassDuration(raw, excludingLastFrame: true) {
                    let isClose = newName.contains("close")
                    DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self, weak iv] in
                        iv?.animates = false
                        iv?.isHidden = true
                        if isClose { self?.restoreStartupFallbackImages() }
                        else       { self?.rehideStartupFallbackImages()  }
                    }
                }
                animatedSubviews[id]            = iv
                animatedSubviewBases[id]        = sv.base
                animatedSubviewCurrentImage[id] = newName
                animatedSubviewTransparency[id] = extra
                interactiveAnimatedSubviews.insert(id)
            }

            promoteNewGifSubviews(in: sv.children, offset: co, lc: lc, bundle: bundle)
        }
    }

    /// After a close animation on an interactive element, find completed startup animations
    /// whose WMS backgroundImage differs from their animated GIF and show them statically.
    /// This lets e.g. introShutterAnim display shutter_close_static.gif to cover flag_extra.
    private func restoreStartupFallbackImages() {
        guard let bundle else { return }
        for id in Array(completedOnePassAnimations) {
            guard let iv  = animatedSubviews[id],
                  let wms = animatedSubviewWmsBackground[id],
                  let img = cache.images[wms]
                            ?? NSImage(contentsOf: bundle.assetURL(named: wms))
            else { continue }
            iv.image    = img
            iv.animates = false
            iv.isHidden = false
            completedOnePassAnimations.remove(id)
            startupFallbacksShowing.insert(id)
        }
    }

    /// After an open animation on an interactive element, hide any startup animations
    /// that were showing their WMS static fallback.
    private func rehideStartupFallbackImages() {
        for id in startupFallbacksShowing {
            guard let iv = animatedSubviews[id] else { continue }
            iv.isHidden = true
            completedOnePassAnimations.insert(id)
        }
        startupFallbacksShowing.removeAll()
    }

    // MARK: - Animated GIF subviews

    /// Walks the element tree and creates an `NSImageView` (animates=true) for every
    /// subview whose effective background image is a GIF file.  Views are added in
    /// ascending z-order so higher-z elements appear on top.
    ///
    /// GIFs are loaded directly from disk (not from the flattened single-frame cache)
    /// so NSImageView receives the full multi-frame image and can animate it.
    ///
    /// When a subview has children whose z-index is lower than the subview's own z-index
    /// (e.g. XBOX screenCover/intro_anim), those children are added first, then the
    /// parent's background is added as an NSImageView so it sits above them.  This is
    /// necessary because CGContext drawing (draw()) is always behind every NSImageView.
    private func buildAnimatedSubviews(in elements: [SkinElement],
                                        offset: CGPoint,
                                        lc: LayoutContext) {
        guard let bundle else { return }
        for element in sortedByZIndex(elements) {
            guard case .subview(let sv) = element else { continue }
            let hidden = elementIsHidden(sv.base)
            // Skip children of statically-hidden subviews (they can't be independently visible).
            // But still try to create an NSImageView for this element itself — it may become
            // visible later when JS changes its state (e.g. playbackAnim starts hidden).
            let x = (resolveCoord(sv.base.left, lc: lc) ?? 0) + offset.x
            let y = (resolveCoord(sv.base.top,  lc: lc) ?? 0) + offset.y
            let co = CGPoint(x: x, y: y)

            let bgName = sv.base.id.flatMap { engine?.state(for: $0)?.backgroundImage }
                         ?? sv.backgroundImage
            let svZ = sv.base.zIndex ?? 0
            let below = sv.children.filter { ($0.base?.zIndex ?? 0) < svZ }
            let above = sv.children.filter { ($0.base?.zIndex ?? 0) >= svZ }

            // Check if any below-children are GIF subviews (will become NSImageViews).
            // If so, this element's background must also be an NSImageView added after
            // them, since CGContext is always behind all NSImageViews.
            let hasGifBelow = !hidden && below.contains { child in
                guard case .subview(let csv) = child else { return false }
                let cn = (csv.base.id.flatMap { engine?.state(for: $0)?.backgroundImage }
                          ?? csv.backgroundImage) ?? ""
                return cn.lowercased().hasSuffix(".gif") && !cache.clipImageNames.contains(cn.lowercased())
            }

            if hasGifBelow {
                buildAnimatedSubviews(in: below, offset: co, lc: lc)
                // Add this element's background as an NSImageView so it sits above the GIF below-children.
                if let name = bgName,
                   !cache.clipImageNames.contains(name.lowercased()) {
                    let lower = name.lowercased()
                    let extra: [(UInt8, UInt8, UInt8)] = [sv.clippingColor, sv.base.transparencyColor]
                        .compactMap { $0.flatMap(parseAnyColor) }
                    let img: NSImage?
                    var rawGif: NSImage? = nil
                    if lower.hasSuffix(".gif"),
                       let raw = NSImage(contentsOf: bundle.assetURL(named: name)),
                       gifIsAnimated(raw) {
                        img = loadGifMagentaFree(url: bundle.assetURL(named: name),
                                                  extraTransparent: extra) ?? raw
                        rawGif = raw
                    } else {
                        img = cache.images[lower] ?? NSImage(contentsOf: bundle.assetURL(named: name))
                    }
                    if let img {
                        // Use pixel-accurate size from the asset cache (img.size may be DPI-adjusted).
                        let cachedSize = cache.images[lower]?.size
                        let w  = lc.resolve(sv.base.width)  ?? cachedSize?.width  ?? img.size.width
                        let h  = lc.resolve(sv.base.height) ?? cachedSize?.height ?? img.size.height
                        let iv = NSImageView(frame: NSRect(x: x, y: y, width: w, height: h))
                        iv.image        = img
                        iv.animates     = lower.hasSuffix(".gif")
                        iv.imageScaling = .scaleAxesIndependently
                        iv.isHidden     = hidden
                        addSubview(iv)
                        if let raw = rawGif, let dur = gifOnePassDuration(raw, excludingLastFrame: true) {
                            let animId = sv.base.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self, weak iv] in
                                iv?.animates = false
                                iv?.isHidden = true
                                if let id = animId { self?.completedOnePassAnimations.insert(id) }
                            }
                        }
                        promotedGifNames.insert(lower)
                        if let id = sv.base.id {
                            animatedSubviews[id]            = iv
                            animatedSubviewBases[id]        = sv.base
                            animatedSubviewCurrentImage[id] = lower
                            animatedSubviewTransparency[id] = extra
                            if let wms = sv.backgroundImage?.lowercased(), wms != lower {
                                animatedSubviewWmsBackground[id] = wms
                            }
                        }
                    }
                }
                buildAnimatedSubviews(in: above, offset: co, lc: lc)
            } else {
                if let name = bgName, name.lowercased().hasSuffix(".gif"),
                   !cache.clipImageNames.contains(name.lowercased()),
                   let raw  = NSImage(contentsOf: bundle.assetURL(named: name)),
                   gifIsAnimated(raw) {
                    let extra: [(UInt8, UInt8, UInt8)] = [sv.clippingColor, sv.base.transparencyColor]
                        .compactMap { $0.flatMap(parseAnyColor) }
                    let img = loadGifMagentaFree(url: bundle.assetURL(named: name),
                                                  extraTransparent: extra) ?? raw
                    let w  = lc.resolve(sv.base.width)  ?? img.size.width
                    let h  = lc.resolve(sv.base.height) ?? img.size.height
                    let iv = NSImageView(frame: NSRect(x: x, y: y, width: w, height: h))
                    iv.image        = img
                    iv.animates     = true
                    iv.imageScaling = .scaleAxesIndependently
                    iv.isHidden     = hidden
                    addSubview(iv)
                    if let dur = gifOnePassDuration(raw, excludingLastFrame: true) {
                        let animId = sv.base.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self, weak iv] in
                            iv?.animates = false
                            iv?.isHidden = true
                            if let id = animId { self?.completedOnePassAnimations.insert(id) }
                        }
                    }
                    promotedGifNames.insert(name.lowercased())
                    if let id = sv.base.id {
                        animatedSubviews[id]            = iv
                        animatedSubviewBases[id]        = sv.base
                        animatedSubviewCurrentImage[id] = name.lowercased()
                        animatedSubviewTransparency[id] = extra
                        let nameLower = name.lowercased()
                        if let wms = sv.backgroundImage?.lowercased(), wms != nameLower {
                            animatedSubviewWmsBackground[id] = wms
                        }
                    }
                }
                // Only recurse into children of visible subviews.
                if !hidden { buildAnimatedSubviews(in: sv.children, offset: co, lc: lc) }
            }
        }
    }

    // MARK: - Visibility

    /// Script state takes precedence over the parsed `visible` attribute.
    /// `alphaBlend == 0` is treated as hidden (WMP skins use it to fade-out elements).
    /// Pass `live: true` during draw to evaluate `wmpenabled:` bindings against current player state.
    private func elementIsHidden(_ base: ElementBase, live: Bool = false) -> Bool {
        if let id = base.id, let s = engine?.state(for: id) {
            if let vis   = s.visible    { return !vis }
            if let alpha = s.alphaBlend, alpha == 0 { return true }
        }
        if let alpha = base.alphaBlend, alpha == 0 { return true }
        switch base.visible {
        case .literal(let str):
            return str.lowercased() == "false" || str == "0"
        case .wmpEnabled(let expr):
            return live ? !(engine?.evaluateWmpEnabled(expr) ?? false) : false
        default:
            return false
        }
    }

    /// Returns the effective 0–255 alpha for a subview, checking script state first.
    private func effectiveAlpha(for base: ElementBase) -> Int {
        if let id = base.id, let s = engine?.state(for: id), let a = s.alphaBlend { return a }
        return base.alphaBlend ?? 255
    }

}

// MARK: - RenderedGroup

private struct RenderedGroup {
    let model:    ButtonGroup
    let assets:   ButtonGroupAssets
    let mapData:  MapData?
    let frame:    CGRect
    let clipMask: CGImage?
    var hoveredColor: String? = nil
    var pressedColor: String? = nil

    func colorAt(_ pt: CGPoint) -> String? {
        guard let md = mapData else { return nil }
        let x = Int(pt.x - frame.minX)
        let y = Int(pt.y - frame.minY)
        guard x >= 0, x < md.width, y >= 0, y < md.height else { return nil }
        let base = (y * md.width + x) * 4
        guard base + 3 < md.bytes.count else { return nil }
        let r = md.bytes[base], g = md.bytes[base + 1],
            b = md.bytes[base + 2], a = md.bytes[base + 3]
        guard a > 128, !isMagenta(r, g, b) else { return nil }
        for elem in model.elements {
            if let (cr, cg, cb) = parseHexColor(elem.mappingColor),
               colorMatches(r, g, b, cr, cg, cb) {
                return elem.mappingColor.lowercased()
            }
        }
        return nil
    }
}

// MARK: - RenderedButton

private struct RenderedButton {
    let model:    Button
    let frame:    CGRect
    let mapData:  MapData?
    let clipMask: CGImage?
    var isHovered = false
    var isPressed = false

    func hitTest(_ pt: CGPoint) -> Bool {
        guard let md = mapData else { return frame.contains(pt) }
        let x = Int(pt.x - frame.minX)
        let y = Int(pt.y - frame.minY)
        guard x >= 0, x < md.width, y >= 0, y < md.height else { return false }
        let base = (y * md.width + x) * 4
        guard base + 3 < md.bytes.count else { return false }
        return md.bytes[base + 3] > 128 && !isMagenta(md.bytes[base], md.bytes[base + 1], md.bytes[base + 2])
    }
}

// MARK: - RenderedSlider

private struct RenderedSlider {
    let model:           Slider
    let frame:           CGRect
    let frameCount:      Int
    let positionMapData: MapData?
    var value:           Double = 0

    var frameIndex: Int { max(0, min(frameCount - 1, Int(value * Double(frameCount - 1)))) }
}

// MARK: - File-local helpers

/// Decodes every frame of an animated GIF, strips magenta (and any extra transparent
/// colours) from each frame via a CGContext pixel pass, then re-encodes as a new animated
/// GIF in memory.  Returns nil for single-frame images or on decode/encode failure.
private func loadGifMagentaFree(url: URL,
                                  extraTransparent: [(UInt8, UInt8, UInt8)] = []) -> NSImage? {
    guard let raw = NSImage(contentsOf: url),
          let rep = raw.representations.first as? NSBitmapImageRep,
          let n   = rep.value(forProperty: .frameCount) as? Int, n > 1
    else { return nil }

    let destData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        destData, "com.compuserve.gif" as CFString, n, nil) else { return nil }

    let fileProps: NSDictionary = [
        kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]
    ]
    CGImageDestinationSetProperties(dest, fileProps)

    for i in 0 ..< n {
        rep.setProperty(.currentFrame, withValue: NSNumber(value: i))
        let delay = (rep.value(forProperty: .currentFrameDuration) as? Double) ?? 0.1
        guard let cg  = rep.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = makeBitmapContext(width: cg.width, height: cg.height)
        else { continue }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let ptr = ctx.data else { continue }
        let pixels = ptr.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
        for j in 0 ..< cg.width * cg.height {
            let o = j * 4
            let r = pixels[o], g = pixels[o + 1], b = pixels[o + 2]
            if isMagenta(r, g, b) ||
               extraTransparent.contains(where: { colorMatches(r, g, b, $0.0, $0.1, $0.2) }) {
                pixels[o] = 0; pixels[o + 1] = 0; pixels[o + 2] = 0; pixels[o + 3] = 0
            }
        }
        guard let clean = ctx.makeImage() else { continue }
        let fProps: NSDictionary = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]
        ]
        CGImageDestinationAddImage(dest, clean, fProps)
    }
    guard CGImageDestinationFinalize(dest) else { return nil }
    return NSImage(data: destData as Data)
}

/// Returns the total single-pass duration (seconds) for GIFs that should play once,
/// or nil for GIFs that loop forever.  GIFs without a Netscape loop extension play
/// once by definition; those with loop-count 0 loop forever.
private func gifOnePassDuration(_ img: NSImage, excludingLastFrame: Bool = false) -> Double? {
    guard let rep = img.representations.first as? NSBitmapImageRep,
          let n   = rep.value(forProperty: .frameCount) as? Int, n > 1
    else { return nil }
    if let loop = rep.value(forProperty: .loopCount) as? Int, loop == 0 { return nil }
    var total: Double = 0
    let limit = excludingLastFrame ? n - 1 : n
    for i in 0 ..< limit {
        rep.setProperty(.currentFrame, withValue: NSNumber(value: i))
        total += (rep.value(forProperty: .currentFrameDuration) as? Double) ?? 0.1
    }
    return total
}

/// Returns true if the NSImage has more than one frame (i.e. is a real animated GIF).
/// Single-frame GIFs used as shape masks return false and should be drawn by CGContext.
private func gifIsAnimated(_ img: NSImage) -> Bool {
    guard let rep = img.representations.first as? NSBitmapImageRep,
          let count = rep.value(forProperty: .frameCount) as? Int
    else { return false }
    return count > 1
}

/// Stable sort by z-index ascending (no z-index → 0, document order preserved for ties).
private func sortedByZIndex(_ elements: [SkinElement]) -> [SkinElement] {
    elements.sorted { ($0.base?.zIndex ?? 0) < ($1.base?.zIndex ?? 0) }
}

private extension NSColor {
    convenience init(skinRGB: (UInt8, UInt8, UInt8)) {
        self.init(red:   CGFloat(skinRGB.0) / 255,
                  green: CGFloat(skinRGB.1) / 255,
                  blue:  CGFloat(skinRGB.2) / 255,
                  alpha: 1)
    }
}

