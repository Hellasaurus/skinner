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
    private var texts:           [RenderedText]   = []
    private var bgOpacity:       [Bool]           = []
    private var bgWidth          = 0
    private var bgHeight         = 0
    private var bgMask:          CGImage?         = nil
    private var lastBgOpacitySignature: [BgOpacitySigEntry]?
    private var lastBgSignatureSize: (w: Int, h: Int) = (0, 0)
    private var opacityMaskCache: [OpacityMaskKey: [Bool]] = [:]
    private let bundle:          SkinBundle?
    private var dragOrigin:      NSPoint?
    private var resizeDragState: (startPt: NSPoint, startFrame: NSRect)?
    private var isResizingFromJS = false
    private var activeSliderIdx: Int?
    private var didFinishInit    = false
    private var pressedTextIdx:  Int?
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
    /// Ref-counted groups of cover NSImageViews that sit above intro GIF NSImageViews.
    /// Each entry is removed when its GIF's one-pass animation completes.
    private var gifCoverGroups: [String: GifCoverGroup] = [:]

    public var onOpenView:   ((String) -> Void)? { didSet { engine?.onOpenView  = onOpenView  } }
    public var onCloseView:  ((String) -> Void)? { didSet { engine?.onCloseView = onCloseView } }
    public var onDroppedURL: ((URL) -> Void)?

    private var playerBackend: (any PlayerBackend)?
    private var timerWorkItem: DispatchWorkItem?
    private var timerDeadline: DispatchTime = .now()
    private var timerLastInterval: Int = 0
    private var moveTimer: Timer?

    /// Set by AppDelegate to provide a visualization view for `<EFFECTS>` elements.
    public var makeVisualizationProvider: (() -> any VisualizationProviding)?
    /// Pre-built provider to reuse across skin swaps. Takes precedence over `makeVisualizationProvider`.
    public var prebuiltVisualizationProvider: (any VisualizationProviding)?
    private var vizProvider:   (any VisualizationProviding)?
    private var vizContainer:  NSView?
    private var vizConfigured  = false
    private var vizCoverInfos: [VizCoverInfo] = []

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
        if let vizProvider, !vizConfigured {
            vizProvider.configure(backend: backend, presetPath: presetSearchPath())
            vizConfigured = true
        }
    }

    private func updateAnimatedSubviewVisibility() {
        let isPlaying = playerBackend?.playState == .playing
        for (id, iv) in animatedSubviews {
            guard let base = animatedSubviewBases[id] else { continue }

            // When JS explicitly clears backgroundImage (sets it to ""), hide the NSImageView.
            if engine?.backgroundImageWasCleared(for: id) == true {
                iv.animates = false
                iv.isHidden = true
                animatedSubviewCurrentImage.removeValue(forKey: id)
                completedOnePassAnimations.remove(id)
                continue
            }

            // Swap image when JS has changed backgroundImage (e.g. idle → playback GIF).
            // Check BEFORE the completion guard so a new image assignment restarts the animation.
            if let newName = engine?.state(for: id)?.backgroundImage?.lowercased(),
               newName != animatedSubviewCurrentImage[id],
               let bundle {
                // A new image assignment clears any prior one-pass completion state.
                completedOnePassAnimations.remove(id)
                startupFallbacksShowing.remove(id)
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
                        let gifIsOpen = newName.contains("open")
                        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self, weak iv] in
                            iv?.animates = false
                            // For non-open animations with a static PNG WMS fallback, show that
                            // PNG persistently after the one-pass GIF completes. This covers
                            // both close GIFs (e.g. HL2 shutter_out_close.gif → show
                            // shutter_out_open_static.png) and pulse/other GIFs.
                            // "Open" GIFs always hide — the WMS PNG is the default closed state
                            // and must not reappear (e.g. HL2 shutter_open.gif).
                            if let self,
                               !gifIsOpen,
                               let wms = self.animatedSubviewWmsBackground[id],
                               !wms.hasSuffix(".gif"),
                               let img = self.cache.images[wms]
                                         ?? self.bundle.flatMap({ NSImage(contentsOf: $0.assetURL(named: wms)) }) {
                                iv?.image    = img
                                iv?.isHidden = false
                                self.startupFallbacksShowing.insert(id)
                            } else {
                                iv?.isHidden = true
                                if interactive {
                                    if isClose { self?.restoreStartupFallbackImages() }
                                    else       { self?.rehideStartupFallbackImages()  }
                                }
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
        engine?.onStartResize = { [weak self] mode in
            guard let self, let win = self.window else { return }
            self.resizeDragState = (startPt: NSEvent.mouseLocation, startFrame: win.frame)
        }
        engine?.onViewResize = { [weak self] w, h in
            guard let self, let win = self.window, w > 0, h > 0 else { return }
            self.isResizingFromJS = true
            win.setContentSize(NSSize(width: w, height: h))
            self.isResizingFromJS = false
        }

        wantsLayer = true
        let lc = LayoutContext(viewWidth: bounds.width, viewHeight: bounds.height)
        // Collection and drawing both use sortedByZIndex + isHidden — same traversal order
        // guarantees the inout index counters in draw() stay in sync with the arrays.
        groups  = collectGroups(in: skinView.elements,  offset: .zero, lc: lc)
        buttons = collectButtons(in: skinView.elements, offset: .zero, lc: lc)
        sliders = collectSliders(in: skinView.elements, offset: .zero, lc: lc)
        texts   = collectTexts(in: skinView.elements,  offset: .zero, lc: lc)
        seedImplicitSubviewSizes(in: skinView.elements)
        buildBgOpacity()
        buildAnimatedSubviews(in: skinView.elements, offset: .zero, lc: lc)
        setupTracking()
        registerForDraggedTypes([.fileURL])
        didFinishInit = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard didFinishInit, newSize.width > 0, newSize.height > 0 else { return }
        // When JS triggers the resize (view.width = X), skip re-entrant JS evaluation here;
        // applyScriptChanges() runs after evaluate() returns and handles the full update.
        if isResizingFromJS { return }
        guard skinView.resizable else { return }
        engine?.updateViewSize(width: newSize.width, height: newSize.height)
        recollect()
        buildBgOpacity()
        setNeedsDisplay(bounds)
    }

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
        if let id, let v = engine?.liveNumber(id: id, property: propName) { return v }
        return resolveCoord(attr, lc: lc) ?? 0
    }

    /// For subviews that have no explicit width/height in the WMS, seed the JS proxy
    /// with the background image's pixel dimensions so sibling jscript: references like
    /// `jscript:visMask.width` resolve correctly (e.g. for the <effects> element in Pulsar).
    private func seedImplicitSubviewSizes(in elements: [SkinElement]) {
        for element in elements {
            guard case .subview(let sv) = element, let id = sv.base.id else { continue }
            if sv.base.width == nil,
               let name = sv.backgroundImage,
               let img = cache.images[name.lowercased()] {
                engine?.evaluate("\(id).width = \(img.size.width)")
            }
            if sv.base.height == nil,
               let name = sv.backgroundImage,
               let img = cache.images[name.lowercased()] {
                engine?.evaluate("\(id).height = \(img.size.height)")
            }
            seedImplicitSubviewSizes(in: sv.children)
        }
    }

    // MARK: - Collection

    private func collectGroups(in elements: [SkinElement],
                                offset: CGPoint,
                                lc: LayoutContext,
                                ancestors: [ElementBase] = []) -> [RenderedGroup] {
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
                                            clipMask: clipMask,
                                            ancestorBases: ancestors))
            case .subview(let sv):
                guard !elementIsHidden(sv.base), !sv.base.passThrough else { continue }
                let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
                let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
                result += collectGroups(in: sv.children, offset: CGPoint(x: sx, y: sy), lc: lc,
                                        ancestors: ancestors + [sv.base])
            default: break
            }
        }
        return result
    }

    /// Traversal order must exactly match `drawElements` so index counters stay in sync.
    private func collectButtons(in elements: [SkinElement],
                                 offset: CGPoint,
                                 lc: LayoutContext,
                                 ancestors: [ElementBase] = [],
                                 parentClipSize: CGSize? = nil) -> [RenderedButton] {
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
                // Final fallback: if the image is missing, inherit the parent subview's
                // explicit clip dimensions so the button remains hittable.
                if w == 0, let pw = parentClipSize?.width,  pw > 0 { w = pw }
                if h == 0, let ph = parentClipSize?.height, ph > 0 { h = ph }
                result.append(RenderedButton(model: b,
                                             frame: CGRect(x: x, y: y, width: w, height: h),
                                             mapData: md,
                                             clipMask: clipMask,
                                             ancestorBases: ancestors))
            case .subview(let sv):
                guard !elementIsHidden(sv.base) else { continue }
                let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
                let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
                let co  = CGPoint(x: sx, y: sy)
                let childAncestors = ancestors + [sv.base]
                let clipW = lc.resolve(sv.base.width)
                let clipH = lc.resolve(sv.base.height)
                let clipSize: CGSize? = (clipW != nil || clipH != nil)
                    ? CGSize(width: clipW ?? 0, height: clipH ?? 0) : nil
                result += collectButtons(in: sv.children.filter { ($0.base?.zIndex ?? 0) < 0 },  offset: co, lc: lc, ancestors: childAncestors, parentClipSize: clipSize)
                result += collectButtons(in: sv.children.filter { ($0.base?.zIndex ?? 0) >= 0 }, offset: co, lc: lc, ancestors: childAncestors, parentClipSize: clipSize)
            default: break
            }
        }
        return result
    }

    /// Traversal order must exactly match `drawElements` so index counters stay in sync.
    private func collectSliders(in elements: [SkinElement],
                                 offset: CGPoint,
                                 lc: LayoutContext,
                                 ancestors: [ElementBase] = []) -> [RenderedSlider] {
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
                    if case .jsExpr = s.base.left { engine?.setLiveNumber(id: id, property: "left", value: rawX) }
                    if case .jsExpr = s.base.top  { engine?.setLiveNumber(id: id, property: "top",  value: rawY) }
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
                                        positionMapData: posMD,
                                        ancestorBases: ancestors)
                rs.value = resolvedSliderValue(s)
                result.append(rs)
            case .subview(let sv):
                guard !elementIsHidden(sv.base) else { continue }
                let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
                let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
                let co  = CGPoint(x: sx, y: sy)
                let childAncestors = ancestors + [sv.base]
                result += collectSliders(in: sv.children.filter { ($0.base?.zIndex ?? 0) < 0 },  offset: co, lc: lc, ancestors: childAncestors)
                result += collectSliders(in: sv.children.filter { ($0.base?.zIndex ?? 0) >= 0 }, offset: co, lc: lc, ancestors: childAncestors)
            default: break
            }
        }
        return result
    }

    private func collectTexts(in elements: [SkinElement],
                               offset: CGPoint,
                               lc: LayoutContext,
                               ancestors: [ElementBase] = []) -> [RenderedText] {
        var result: [RenderedText] = []
        for element in sortedByZIndex(elements) {
            switch element {
            case .text(let t):
                guard !elementIsHidden(t.base),
                      t.base.onClick != nil || t.hoverForegroundColor != nil else { continue }
                let x = (resolveCoord(t.base.left, lc: lc) ?? 0) + offset.x
                let y = (resolveCoord(t.base.top,  lc: lc) ?? 0) + offset.y
                let w =  resolveCoord(t.base.width,  lc: lc) ?? 100
                let h =  resolveCoord(t.base.height, lc: lc) ?? 14
                result.append(RenderedText(model: t, frame: CGRect(x: x, y: y, width: w, height: h),
                                           ancestorBases: ancestors))
            case .subview(let sv):
                guard !elementIsHidden(sv.base), !sv.base.passThrough else { continue }
                let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
                let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
                let co = CGPoint(x: sx, y: sy)
                let childAncestors = ancestors + [sv.base]
                result += collectTexts(in: sv.children.filter { ($0.base?.zIndex ?? 0) < 0 },  offset: co, lc: lc, ancestors: childAncestors)
                result += collectTexts(in: sv.children.filter { ($0.base?.zIndex ?? 0) >= 0 }, offset: co, lc: lc, ancestors: childAncestors)
            default: break
            }
        }
        return result
    }

    // MARK: - Background opacity map

    private func buildBgOpacity() {
        let vw = Int(bounds.width), vh = Int(bounds.height)
        guard vw > 0, vh > 0 else { return }
        let lc = LayoutContext(viewWidth: bounds.width, viewHeight: bounds.height)

        // Most applyScriptChanges() calls (e.g. periodic onTimer ticks driving the
        // visualizer) don't move, hide, or re-image any subview. Skip the full
        // per-pixel rebuild + CGImage mask creation when nothing that affects the
        // map has changed since the last build.
        let signature = bgOpacitySignature(in: skinView.elements, lc: lc, offset: .zero)
        if (vw, vh) == lastBgSignatureSize, signature == lastBgOpacitySignature {
            return
        }
        lastBgSignatureSize = (vw, vh)
        lastBgOpacitySignature = signature

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
            paintMdIntoOpacity(md: md, ox: 0, oy: 0, imageKey: imgName.lowercased(), extraColors: extra)
        }
        paintBgOpacity(in: skinView.elements, lc: lc, offset: .zero)
        bgMask = makeBgMask()
    }

    /// Captures everything that affects `bgOpacity`'s contents for a subview tree:
    /// each visible subview's resolved position and its current background image.
    /// Two signatures comparing equal means `buildBgOpacity` would produce an
    /// identical map, so the rebuild can be skipped.
    private struct BgOpacitySigEntry: Equatable {
        let x: Int
        let y: Int
        let bgImage: String?
    }

    private func bgOpacitySignature(in elements: [SkinElement],
                                     lc: LayoutContext,
                                     offset: CGPoint) -> [BgOpacitySigEntry] {
        var result: [BgOpacitySigEntry] = []
        for element in elements {
            guard case .subview(let sv) = element, !elementIsHidden(sv.base) else { continue }
            let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
            let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
            let bgName = sv.base.id.flatMap { engine?.state(for: $0)?.backgroundImage } ?? sv.backgroundImage
            result.append(BgOpacitySigEntry(x: Int(sx), y: Int(sy), bgImage: bgName))
            result += bgOpacitySignature(in: sv.children, lc: lc, offset: CGPoint(x: sx, y: sy))
        }
        return result
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

    /// Identifies a precomputed per-image opacity mask: an image's pixels combined
    /// with the clipping/transparency colors that exclude additional pixels from
    /// being hittable. Both are static for a given subview, so the mask can be
    /// computed once and reused across every `buildBgOpacity` rebuild.
    private struct OpacityMaskKey: Hashable {
        let imageName: String
        let extraColors: [UInt32]
    }

    /// Returns (computing and caching if needed) a `[Bool]` the same dimensions as
    /// `md`, in the same row order as `md.bytes`, where `true` means the pixel is
    /// opaque, non-magenta, and doesn't match any of `extraColors`. Hoists the
    /// per-pixel `isMagenta`/`colorMatches` checks out of `paintMdIntoOpacity` since
    /// they depend only on the image and its (static) clipping/transparency colors.
    private func opacityMask(for md: MapData, imageKey: String,
                              extraColors: [(UInt8, UInt8, UInt8)]) -> [Bool] {
        let key = OpacityMaskKey(imageName: imageKey,
                                  extraColors: extraColors.map { UInt32($0.0) << 16 | UInt32($0.1) << 8 | UInt32($0.2) })
        if let cached = opacityMaskCache[key] { return cached }
        var mask = [Bool](repeating: false, count: md.width * md.height)
        for px in 0 ..< (md.width * md.height) {
            let i = px * 4
            let r = md.bytes[i], g = md.bytes[i+1], b = md.bytes[i+2], a = md.bytes[i+3]
            guard a > 128, !isMagenta(r, g, b) else { continue }
            if extraColors.contains(where: { colorMatches(r, g, b, $0.0, $0.1, $0.2) }) { continue }
            mask[px] = true
        }
        opacityMaskCache[key] = mask
        return mask
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
                                     imageKey: String,
                                     extraColors: [(UInt8, UInt8, UInt8)]) {
        let destW = dstW > 0 ? dstW : md.width
        let destH = dstH > 0 ? dstH : md.height
        let mask = opacityMask(for: md, imageKey: imageKey, extraColors: extraColors)

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

                guard mask[cgRow * md.width + srcCol] else { continue }
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
                paintMdIntoOpacity(md: md, ox: Int(sx), oy: Int(sy), imageKey: imgName.lowercased(), extraColors: extra)
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
        renderVizCoverImages(lc: lc)
    }

    private func drawElements(_ elements: [SkinElement],
                               offset: CGPoint,
                               lc: LayoutContext,
                               ctx: CGContext,
                               buttonIdx: inout Int,
                               sliderIdx: inout Int,
                               buttonOverride: [RenderedButton]? = nil,
                               sliderOverride: [RenderedSlider]? = nil) {
        let btnArr = buttonOverride ?? buttons
        let slrArr = sliderOverride ?? sliders
        for element in sortedByZIndex(elements) {
            switch element {

            case .subview(let sv):
                guard !elementIsHidden(sv.base, live: true) else { continue }
                var sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
                let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
                // Center horizontally when no explicit left is set and alignment is "center".
                if sv.base.left == nil, sv.base.horizontalAlignment == .center {
                    let elemW = lc.resolve(sv.base.width)
                        ?? sv.backgroundImage.flatMap { cache.images[$0.lowercased()]?.size.width }
                        ?? 0
                    if elemW > 0 { sx = offset.x + (lc.viewWidth - elemW) / 2 }
                }
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
                // Only children with a negative zIndex render behind the parent's background
                // image (e.g. Headspace's vid_bkgd.bmp zIndex="-2" behind head.bmp, or
                // Professional's visMask effects zIndex="-1" under the mask image).
                // Positive-zIndex children always draw above the background regardless of the
                // parent's own zIndex (e.g. Professional's buttons zIndex=1,2 inside a
                // parent with zIndex=15 still appear above s_main_no.png).
                // This split must match collectButtons/collectSliders so index order stays in sync.
                let below = sv.children.filter { ($0.base?.zIndex ?? 0) < 0 }
                let above = sv.children.filter { ($0.base?.zIndex ?? 0) >= 0 }
                drawElements(below, offset: childOffset, lc: lc, ctx: ctx,
                             buttonIdx: &buttonIdx, sliderIdx: &sliderIdx,
                             buttonOverride: buttonOverride, sliderOverride: sliderOverride)
                // Fill backgroundColor before drawing the background image so the image sits on top.
                // Only fill when we have explicit clip dimensions; otherwise size is unknown.
                if let colorStr = sv.backgroundColor,
                   colorStr.lowercased() != "none", !colorStr.isEmpty,
                   let rgb = parseAnyColor(colorStr),
                   let w = clipW, let h = clipH {
                    NSColor(skinRGB: rgb).setFill()
                    NSBezierPath.fill(NSRect(x: sx, y: sy, width: w, height: h))
                }
                if sv.base.id.flatMap({ animatedSubviews[$0] }) == nil {
                    let bgName = sv.base.id.flatMap { engine?.state(for: $0)?.backgroundImage }
                                 ?? sv.backgroundImage
                    if let name = bgName,
                       cache.buttonGroupsByMappingImage[name.lowercased()] == nil,
                       !cache.clipImageNames.contains(name.lowercased()),
                       !promotedGifNames.contains(name.lowercased()),
                       let img  = cache.images[name.lowercased()] {
                        let w: CGFloat
                        if let explicitW = lc.resolve(sv.base.width) {
                            w = explicitW
                        } else if sv.base.horizontalAlignment == .stretch {
                            let rightBound = elements.compactMap { e -> CGFloat? in
                                guard case .subview(let s) = e, s.base.horizontalAlignment == .right else { return nil }
                                return liveCoord(s.base.id, attr: s.base.left, propName: "left", lc: lc) + offset.x
                            }.min() ?? lc.viewWidth
                            w = max(0, rightBound - sx)
                        } else {
                            w = img.size.width
                        }
                        let h: CGFloat
                        if let explicitH = lc.resolve(sv.base.height) {
                            h = explicitH
                        } else if sv.base.verticalAlignment == .stretch {
                            let botBound = elements.compactMap { e -> CGFloat? in
                                guard case .subview(let s) = e, s.base.verticalAlignment == .bottom else { return nil }
                                return liveCoord(s.base.id, attr: s.base.top, propName: "top", lc: lc) + offset.y
                            }.min() ?? lc.viewHeight
                            h = max(0, botBound - sy)
                        } else {
                            h = img.size.height
                        }
                        if sv.backgroundTiled {
                            drawTiledImage(img, in: NSRect(x: sx, y: sy, width: w, height: h), ctx: ctx)
                        } else {
                            img.draw(in: NSRect(x: sx, y: sy, width: w, height: h))
                        }
                    }
                }
                drawElements(above, offset: childOffset, lc: lc, ctx: ctx,
                             buttonIdx: &buttonIdx, sliderIdx: &sliderIdx,
                             buttonOverride: buttonOverride, sliderOverride: sliderOverride)
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
                if !elementIsHidden(b.base, live: true), buttonIdx < btnArr.count {
                    drawButton(btnArr[buttonIdx], ctx: ctx)
                }

            case .slider(let s):
                guard !elementIsHidden(s.base) else { continue }
                defer { sliderIdx += 1 }
                if !elementIsHidden(s.base, live: true), sliderIdx < slrArr.count {
                    drawSlider(slrArr[sliderIdx])
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
                let textIsHovered = texts.contains { abs($0.frame.minX - tx) < 1 && abs($0.frame.minY - ty) < 1 && $0.isHovered }
                drawTextLabel(text, in: NSRect(x: tx, y: ty, width: tw, height: th), label: t, isHovered: textIsHovered)

            default: break
            }
        }
    }

    private func drawTextLabel(_ text: String, in rect: NSRect, label: TextLabel, isHovered: Bool = false) {
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
        let fgColor = (isHovered ? label.hoverForegroundColor : nil) ?? label.foregroundColor ?? "#ffffff"
        let fgRGB = parseAnyColor(fgColor) ?? (0xff, 0xff, 0xff)
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

        if let disName = group.model.disabledImage,
           let disImg  = cache.images[disName.lowercased()] {
            for elem in group.model.elements where !buttonElementIsEnabled(elem) {
                guard let mask = group.assets.masks[elem.mappingColor.lowercased()] else { continue }
                ctx.saveGState()
                if let clip = group.clipMask { ctx.clip(to: cgRect, mask: clip) }
                ctx.clip(to: cgRect, mask: mask)
                disImg.draw(in: rect)
                ctx.restoreGState()
            }
        }
    }

    private func drawButton(_ button: RenderedButton, ctx: CGContext) {
        let jsState = button.model.base.id.flatMap { engine?.state(for: $0) }
        let jsImage = jsState?.image
        let jsDown  = button.model.sticky && (jsState?.down == true)
        let name: String?
        if button.isPressed || jsDown { name = button.model.downImage  ?? jsImage ?? button.model.image }
        else if button.isHovered      { name = button.model.hoverImage ?? jsImage ?? button.model.image }
        else                          { name = jsImage ?? button.model.image }
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

    private func drawTiledImage(_ img: NSImage, in destRect: NSRect, ctx: CGContext) {
        let iw = img.size.width
        let ih = img.size.height
        guard iw > 0, ih > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: destRect)
        var ty = destRect.minY
        while ty < destRect.maxY {
            var tx = destRect.minX
            while tx < destRect.maxX {
                img.draw(in: NSRect(x: tx, y: ty, width: iw, height: ih))
                tx += iw
            }
            ty += ih
        }
        ctx.restoreGState()
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
        // point is in superview coords (non-flipped: y=0 at bottom of view).
        // bgOpacity uses flipped coords (row 0 = visual top), so we must convert.
        let localX = point.x - frame.minX
        let localY = frame.height - (point.y - frame.minY)
        let px = Int(localX), py = Int(localY)
        guard px >= 0, px < bgWidth, py >= 0, py < bgHeight else { return nil }
        guard bgOpacity[py * bgWidth + px] else { return nil }
        // Return self rather than delegating into subviews: all interaction is handled here,
        // and visual subviews (animated GIFs, viz container, cover images) must not receive
        // mouse events. Returning a subview would cause AppKit to call acceptsFirstMouse on
        // it (returning false), so the first click after a window-activation would be eaten.
        return self
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
        print("[Skinner] mouseDown view=\(skinView.id ?? "?") pt=\(pt) buttons=\(buttons.count)")

        // Button groups use pixel-precise mapping-image hit tests and should take
        // priority over sliders when their frames overlap (e.g. STALKER's EQ/PL
        // button group sits on top of the volume slider).  If a click misses all
        // mapped button pixels the group returns nil and the slider below catches it.
        for i in groups.indices.reversed() {
            guard !elementIsHidden(groups[i].model.base, live: true),
                  ancestorsVisible(groups[i].ancestorBases),
                  !ancestorsPassThrough(groups[i].ancestorBases),
                  elementIsEnabled(groups[i].model.base) else { continue }
            if let color = groups[i].colorAt(pt) {
                let elem = groups[i].model.elements.first { $0.mappingColor.lowercased() == color }
                guard buttonElementIsEnabled(elem) else { continue }
                groups[i].pressedColor = color
                setNeedsDisplay(bounds)
                return
            }
        }
        for i in buttons.indices.reversed() {
            guard !elementIsHidden(buttons[i].model.base, live: true),
                  ancestorsVisible(buttons[i].ancestorBases),
                  !ancestorsPassThrough(buttons[i].ancestorBases),
                  elementIsEnabled(buttons[i].model.base) else { continue }
            guard buttons[i].hitTest(pt) else { continue }
            print("[Skinner] mouseDown: hit button[\(i)] id=\(buttons[i].model.base.id ?? "nil") frame=\(buttons[i].frame) onClick='\(buttons[i].model.base.onClick?.prefix(60) ?? "nil")'")
            if let script = buttons[i].model.base.onMouseDown, !script.isEmpty {
                engine?.evaluate(script)
                applyScriptChanges()
                // view.size() fired: switch to resize tracking instead of button press
                if resizeDragState != nil { return }
            }
            buttons[i].isPressed = true
            setNeedsDisplay(bounds)
            return
        }
        for i in sliders.indices.reversed() {
            guard !elementIsHidden(sliders[i].model.base, live: true),
                  ancestorsVisible(sliders[i].ancestorBases),
                  !ancestorsPassThrough(sliders[i].ancestorBases),
                  elementIsEnabled(sliders[i].model.base) else { continue }
            if let norm = sliderNormalizedValue(at: pt, slider: sliders[i]) {
                activeSliderIdx = i
                applySlider(idx: i, normalized: norm, isMouseUp: false)
                return
            }
        }
        for i in texts.indices.reversed() {
            guard !elementIsHidden(texts[i].model.base, live: true),
                  ancestorsVisible(texts[i].ancestorBases),
                  !ancestorsPassThrough(texts[i].ancestorBases),
                  elementIsEnabled(texts[i].model.base) else { continue }
            guard texts[i].frame.contains(pt), texts[i].model.base.onClick != nil else { continue }
            pressedTextIdx = i
            return
        }
        print("[Skinner] mouseDown: no interactive element hit, setting dragOrigin")
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
        if let (startPt, startFrame) = resizeDragState, let win = window {
            let current = NSEvent.mouseLocation
            let lc0 = LayoutContext(viewWidth: 0, viewHeight: 0)
            let minW = lc0.resolve(skinView.minWidth)  ?? startFrame.width
            let minH = lc0.resolve(skinView.minHeight) ?? startFrame.height
            let newWidth  = max(minW, startFrame.width  + (current.x - startPt.x))
            let newHeight = max(minH, startFrame.height - (current.y - startPt.y))
            win.setFrame(NSRect(
                x: startFrame.origin.x,
                y: startFrame.maxY - newHeight,
                width: newWidth,
                height: newHeight
            ), display: true)
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
        if resizeDragState != nil {
            resizeDragState = nil
            return
        }
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
            let button = buttons[i]          // snapshot before firing; action may rebuild buttons
            buttons[i].isPressed = false
            setNeedsDisplay(bounds)
            if button.hitTest(pt) { fireButtonAction(button) }
            return
        }
        if let i = pressedTextIdx {
            pressedTextIdx = nil
            guard texts.indices.contains(i),
                  texts[i].frame.contains(pt),
                  let script = texts[i].model.base.onClick else { return }
            engine?.evaluate(script)
            applyScriptChanges()
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
            let inactive = elementIsHidden(groups[i].model.base, live: true) || !ancestorsVisible(groups[i].ancestorBases) || ancestorsPassThrough(groups[i].ancestorBases) || !elementIsEnabled(groups[i].model.base)
            let h: String? = (!inactive && !groupHitHandled) ? groups[i].colorAt(pt) : nil
            if h != nil { groupHitHandled = true }
            if h != groups[i].hoveredColor { groups[i].hoveredColor = h; changed = true }
        }
        var buttonHitHandled = false
        for i in buttons.indices.reversed() {
            let inactive = elementIsHidden(buttons[i].model.base, live: true) || !ancestorsVisible(buttons[i].ancestorBases) || ancestorsPassThrough(buttons[i].ancestorBases) || !elementIsEnabled(buttons[i].model.base)
            let h = !inactive && !buttonHitHandled && buttons[i].hitTest(pt)
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

    // MARK: - Keyboard

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func keyDown(with event: NSEvent) {
        guard let viz = vizProvider, !viz.view.isHidden else {
            print("[SkinCanvas] keyDown: vizProvider=\(vizProvider == nil ? "nil" : "set"), vizHidden=\(vizProvider?.view.isHidden ?? true) — passing to super")
            super.keyDown(with: event)
            return
        }
        switch event.specialKey {
        case NSEvent.SpecialKey.leftArrow:
            print("[SkinCanvas] left arrow → previousPreset")
            viz.previousPreset()
        case NSEvent.SpecialKey.rightArrow:
            print("[SkinCanvas] right arrow → nextPreset")
            viz.nextPreset()
        default: super.keyDown(with: event)
        }
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
        for i in texts.indices where texts[i].isHovered {
            texts[i].isHovered = false; changed = true
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
        // Toggle sticky `down` before onClick: matches WMP's built-in toggle behavior.
        // Open scripts explicitly set down=true; close scripts omit it, so the pre-toggle
        // correctly reverts to false when no explicit reset is in the script.
        if button.model.sticky, let id = button.model.base.id {
            let cur = engine?.state(for: id)?.down ?? false
            engine?.evaluate("\(id).down = \(cur ? "false" : "true")")
        }
        if let script = button.model.base.onClick {
            print("[Skinner] fireButtonAction onClick='\(script.prefix(80))'")
            engine?.evaluate(script); applyScriptChanges(); return
        }
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
        texts   = collectTexts(in: skinView.elements,  offset: .zero, lc: lc)

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

        // Visualization: find an <EFFECTS> element and position the overlay view.
        // Pass the view's backgroundImage as parentBgImage so top-level effects with
        // negative zIndex (e.g. Gadget) can use it as a view-level cover.
        let lc2 = LayoutContext(viewWidth: bounds.width, viewHeight: bounds.height)
        let viewBgImg   = skinView.backgroundImage.flatMap { cache.images[$0.lowercased()] }
        let viewBgFrame = viewBgImg.map { CGRect(origin: .zero, size: $0.size) }
        if let (fx, frame, covers, ancestorAlpha, maskImageName) = findEffects(
            in: skinView.elements, offset: .zero, lc: lc2,
            parentBgImage: viewBgImg, parentBgFrame: viewBgFrame
        ) {
            updateVisualizationView(for: fx, frame: frame, covers: covers,
                                    ancestorAlpha: ancestorAlpha, maskImageName: maskImageName)
        }
    }

    private func reapplyHover() {
        guard let pt = lastKnownMousePt else { return }
        var groupHitHandled = false
        for i in groups.indices.reversed() {
            let inactive = elementIsHidden(groups[i].model.base, live: true) || !ancestorsVisible(groups[i].ancestorBases) || ancestorsPassThrough(groups[i].ancestorBases) || !elementIsEnabled(groups[i].model.base)
            var h: String? = nil
            if !inactive && !groupHitHandled, let color = groups[i].colorAt(pt) {
                let elem = groups[i].model.elements.first { $0.mappingColor.lowercased() == color }
                if buttonElementIsEnabled(elem) { h = color }
            }
            if h != nil { groupHitHandled = true }
            groups[i].hoveredColor = h
        }
        var buttonHitHandled = false
        for i in buttons.indices.reversed() {
            let inactive = elementIsHidden(buttons[i].model.base, live: true) || !ancestorsVisible(buttons[i].ancestorBases) || ancestorsPassThrough(buttons[i].ancestorBases) || !elementIsEnabled(buttons[i].model.base)
            let h = !inactive && !buttonHitHandled && buttons[i].hitTest(pt)
            if h { buttonHitHandled = true }
            buttons[i].isHovered = h
        }
        for i in texts.indices {
            let inactive = elementIsHidden(texts[i].model.base, live: true) || !ancestorsVisible(texts[i].ancestorBases) || ancestorsPassThrough(texts[i].ancestorBases) || !elementIsEnabled(texts[i].model.base)
            texts[i].isHovered = !inactive && texts[i].frame.contains(pt)
        }
    }

    // MARK: - Visualization

    private func findEffects(in elements: [SkinElement],
                              offset: CGPoint,
                              lc: LayoutContext,
                              parentBgImage: NSImage? = nil,
                              parentBgFrame: CGRect? = nil,
                              parentSubview: Subview? = nil
    ) -> (Effects, CGRect, covers: [(subview: Subview?, bgImage: NSImage, frame: CGRect, drawRect: CGRect)], ancestorAlpha: Int, maskImageName: String?)? {
        for element in elements {
            switch element {
            case .effects(let fx):
                // No visibility check — always find the element so the provider can be
                // created once and its show/hide state tracked dynamically in updateVisualizationView.
                let x = (resolveCoord(fx.base.left,   lc: lc) ?? 0) + offset.x
                let y = (resolveCoord(fx.base.top,    lc: lc) ?? 0) + offset.y
                let w =  resolveCoord(fx.base.width,  lc: lc) ?? bounds.width
                let h =  resolveCoord(fx.base.height, lc: lc) ?? bounds.height
                let vizFrame = CGRect(x: x, y: y, width: w, height: h)
                var topCovers: [(subview: Subview?, bgImage: NSImage, frame: CGRect, drawRect: CGRect)] = []
                // When effects is a direct child of the view (parentSubview == nil), the
                // regular cover-collection in case .subview never runs. Collect covers here:
                // sibling subviews with higher zIndex + the view's own backgroundImage.
                if parentSubview == nil {
                    let fxZIndex = fx.base.zIndex ?? 0
                    // View's backgroundImage sits above negative-zIndex elements in z-order;
                    // since the viz NSView is above all CGContext, add it as a cover.
                    if fxZIndex < 0, let img = parentBgImage, let frm = parentBgFrame {
                        topCovers.append((subview: nil, bgImage: img,
                                          frame: vizFrame.intersection(frm), drawRect: frm))
                    }
                    // Sibling subviews with higher zIndex that have backgroundImages overlapping the viz.
                    for sibling in sortedByZIndex(elements) {
                        guard case .subview(let sib) = sibling,
                              (sib.base.zIndex ?? 0) > fxZIndex,
                              !elementIsHidden(sib.base, live: true) else { continue }
                        let liveBgName = (sib.base.id.flatMap { engine?.state(for: $0)?.backgroundImage }
                                          ?? sib.backgroundImage)?.lowercased()
                        guard let bgName = liveBgName,
                              !promotedGifNames.contains(bgName),
                              cache.buttonGroupsByMappingImage[bgName] == nil,
                              !cache.clipImageNames.contains(bgName),
                              let img = cache.images[bgName] else { continue }
                        let sibX = liveCoord(sib.base.id, attr: sib.base.left, propName: "left", lc: lc) + offset.x
                        let sibY = liveCoord(sib.base.id, attr: sib.base.top,  propName: "top",  lc: lc) + offset.y
                        let sw: CGFloat
                        if let explicitW = lc.resolve(sib.base.width) {
                            sw = explicitW
                        } else if sib.base.horizontalAlignment == .stretch {
                            let rightBound = elements.compactMap { e -> CGFloat? in
                                guard case .subview(let s) = e, s.base.id != sib.base.id,
                                      s.base.horizontalAlignment == .right else { return nil }
                                return liveCoord(s.base.id, attr: s.base.left, propName: "left", lc: lc) + offset.x
                            }.min() ?? lc.viewWidth
                            sw = max(0, rightBound - sibX)
                        } else {
                            sw = img.size.width
                        }
                        let sh: CGFloat
                        if let explicitH = lc.resolve(sib.base.height) {
                            sh = explicitH
                        } else if sib.base.verticalAlignment == .stretch {
                            let botBound = elements.compactMap { e -> CGFloat? in
                                guard case .subview(let s) = e, s.base.id != sib.base.id,
                                      s.base.verticalAlignment == .bottom else { return nil }
                                return liveCoord(s.base.id, attr: s.base.top, propName: "top", lc: lc) + offset.y
                            }.min() ?? lc.viewHeight
                            sh = max(0, botBound - sibY)
                        } else {
                            sh = img.size.height
                        }
                        let sibFrame = CGRect(x: sibX, y: sibY, width: sw, height: sh)
                        guard sibFrame.intersects(vizFrame) else { continue }
                        topCovers.append((subview: sib, bgImage: img,
                                          frame: sibFrame.intersection(vizFrame), drawRect: sibFrame))
                    }
                }
                return (fx, vizFrame, covers: topCovers, ancestorAlpha: 255, maskImageName: nil)
            case .subview(let sv):
                // Recurse regardless of visibility so nested effects elements are found
                // even when their parent starts hidden (e.g. visMask in Pulsar).
                let sx = liveCoord(sv.base.id, attr: sv.base.left, propName: "left", lc: lc) + offset.x
                let sy = liveCoord(sv.base.id, attr: sv.base.top,  propName: "top",  lc: lc) + offset.y
                // Compute this subview's backgroundImage and frame to pass as parent context.
                // Apply stretch alignment when no explicit size is declared (same logic as drawElements).
                let svBgImg = sv.backgroundImage.flatMap { cache.images[$0.lowercased()] }
                let svBgW: CGFloat
                if let explicitW = lc.resolve(sv.base.width) {
                    svBgW = explicitW
                } else if sv.base.horizontalAlignment == .stretch {
                    let rightBound = elements.compactMap { e -> CGFloat? in
                        guard case .subview(let s) = e, s.base.id != sv.base.id,
                              s.base.horizontalAlignment == .right else { return nil }
                        return liveCoord(s.base.id, attr: s.base.left, propName: "left", lc: lc) + offset.x
                    }.min() ?? lc.viewWidth
                    svBgW = max(0, rightBound - sx)
                } else {
                    svBgW = svBgImg?.size.width ?? 0
                }
                let svBgH: CGFloat
                if let explicitH = lc.resolve(sv.base.height) {
                    svBgH = explicitH
                } else if sv.base.verticalAlignment == .stretch {
                    let botBound = elements.compactMap { e -> CGFloat? in
                        guard case .subview(let s) = e, s.base.id != sv.base.id,
                              s.base.verticalAlignment == .bottom else { return nil }
                        return liveCoord(s.base.id, attr: s.base.top, propName: "top", lc: lc) + offset.y
                    }.min() ?? lc.viewHeight
                    svBgH = max(0, botBound - sy)
                } else {
                    svBgH = svBgImg?.size.height ?? 0
                }
                // Seed resolved dimensions so nested jscript: references (e.g. jscript:visFrame.width) resolve.
                if let id = sv.base.id {
                    if svBgW > 0 { engine?.setLiveNumber(id: id, property: "width",  value: svBgW) }
                    if svBgH > 0 { engine?.setLiveNumber(id: id, property: "height", value: svBgH) }
                }
                let svBgFrame = CGRect(x: sx, y: sy, width: svBgW, height: svBgH)
                if var found = findEffects(in: sv.children, offset: CGPoint(x: sx, y: sy), lc: lc,
                                            parentBgImage: svBgImg, parentBgFrame: svBgFrame,
                                            parentSubview: sv) {
                    // If this subview has negative zIndex, its parent's backgroundImage
                    // renders above it in draw(_:) and needs to cover the viz NSView too.
                    // We carry the parent Subview model so we can later identify which of
                    // its children are positive-zIndex and must appear above the cover.
                    if (sv.base.zIndex ?? 0) < 0,
                       let img = parentBgImage, let frm = parentBgFrame,
                       let parentSv = parentSubview {
                        found.covers.append((subview: parentSv, bgImage: img, frame: frm, drawRect: frm))
                    }
                    // If this subview directly contains the effects element, its backgroundImage
                    // needs to be a cover NSImageView above the viz when:
                    //  • effects has negative zIndex → background z-orders above it (e.g. vis_mask_w.png
                    //    in Plus! Professional), OR
                    //  • the subview has transparencyColor → the backgroundImage participates in masking.
                    //    Two sub-cases depending on the transparencyColor:
                    //    - White (#FFFFFF): colored pixels = screen area (show viz), white = background
                    //      (hide viz). Use a CALayer mask so the viz only renders inside the colored region.
                    //      e.g. viz_mask.gif in Elvis, viz_screen.gif in Heart_Butterfly.
                    //    - Magenta/other: transparent holes = screen area (show viz), opaque = frame.
                    //      Use a cover NSImageView above the viz.
                    //      e.g. vis_mask.png in Blinx, VisBG.gif in deepbluesomething.
                    if let img = svBgImg,
                       let directEffect = sv.children.first(where: { if case .effects = $0 { return true }; return false }),
                       (directEffect.base?.zIndex ?? 0) < 0 || sv.base.transparencyColor != nil {
                        let tcIsWhite: Bool
                        if let tc = sv.base.transparencyColor, let rgb = parseAnyColor(tc) {
                            tcIsWhite = rgb.0 > 240 && rgb.1 > 240 && rgb.2 > 240
                        } else {
                            tcIsWhite = false
                        }
                        if tcIsWhite, let bgName = sv.backgroundImage?.lowercased() {
                            found.maskImageName = bgName
                        } else {
                            found.covers.append((subview: sv, bgImage: img, frame: svBgFrame, drawRect: svBgFrame))
                        }
                    }
                    // Collect passThrough sibling subviews with a higher zIndex as overlay covers.
                    // They render above the effects' parent in CGContext but behind NSViews —
                    // adding them here places them correctly above the viz (e.g. over_base.png,
                    // screen_glare.png in Plus! Professional).
                    // Use the live backgroundImage (JS state preferred over WMS attribute) so we
                    // see the correct image at the time the viz is first shown. Skip any sibling
                    // whose live image is already in promotedGifNames — those are managed as
                    // animated NSImageViews and are already above the viz without a separate cover
                    // (e.g. introShutterAnim showing shutter_open2.gif, playback_anim.gif).
                    let effectsParentZIndex = sv.base.zIndex ?? 0
                    for sibling in sortedByZIndex(elements) {
                        guard case .subview(let sib) = sibling,
                              sib.base.id != sv.base.id,
                              (sib.base.zIndex ?? 0) > effectsParentZIndex,
                              !elementIsHidden(sib.base, live: true) else { continue }
                        let liveBgName = (sib.base.id.flatMap { engine?.state(for: $0)?.backgroundImage }
                                          ?? sib.backgroundImage)?.lowercased()
                        guard let bgName = liveBgName,
                              !promotedGifNames.contains(bgName),
                              cache.buttonGroupsByMappingImage[bgName] == nil,
                              !cache.clipImageNames.contains(bgName),
                              let img = cache.images[bgName] else { continue }
                        let sibX = liveCoord(sib.base.id, attr: sib.base.left, propName: "left", lc: lc) + offset.x
                        let sibY = liveCoord(sib.base.id, attr: sib.base.top,  propName: "top",  lc: lc) + offset.y
                        let sw: CGFloat
                        if let explicitW = lc.resolve(sib.base.width) {
                            sw = explicitW
                        } else if sib.base.horizontalAlignment == .stretch {
                            let rightBound = elements.compactMap { e -> CGFloat? in
                                guard case .subview(let s) = e, s.base.id != sib.base.id,
                                      s.base.horizontalAlignment == .right else { return nil }
                                return liveCoord(s.base.id, attr: s.base.left, propName: "left", lc: lc) + offset.x
                            }.min() ?? lc.viewWidth
                            sw = max(0, rightBound - sibX)
                        } else {
                            sw = img.size.width
                        }
                        let sh: CGFloat
                        if let explicitH = lc.resolve(sib.base.height) {
                            sh = explicitH
                        } else if sib.base.verticalAlignment == .stretch {
                            let botBound = elements.compactMap { e -> CGFloat? in
                                guard case .subview(let s) = e, s.base.id != sib.base.id,
                                      s.base.verticalAlignment == .bottom else { return nil }
                                return liveCoord(s.base.id, attr: s.base.top, propName: "top", lc: lc) + offset.y
                            }.min() ?? lc.viewHeight
                            sh = max(0, botBound - sibY)
                        } else {
                            sh = img.size.height
                        }
                        let sibFrame  = CGRect(x: sibX, y: sibY, width: sw, height: sh)
                        let vizFrame  = found.1
                        // Restrict the NSImageView to the viz frame: the portion of the sibling
                        // outside the viz is visible in CGContext and must not be covered by an
                        // NSImageView (that would hide buttons drawn in CGContext in that region).
                        guard sibFrame.intersects(vizFrame) else { continue }
                        let coverFrame = sibFrame.intersection(vizFrame)
                        found.covers.append((subview: sib, bgImage: img,
                                             frame: coverFrame, drawRect: sibFrame))
                    }
                    // Propagate ancestor alpha: viz must be hidden when any ancestor's alpha is 0.
                    found.ancestorAlpha = min(found.ancestorAlpha, effectiveAlpha(for: sv.base))
                    return found
                }
            default: break
            }
        }
        return nil
    }

    private func updateVisualizationView(
        for fx: Effects, frame: CGRect,
        covers: [(subview: Subview?, bgImage: NSImage, frame: CGRect, drawRect: CGRect)],
        ancestorAlpha: Int = 255,
        maskImageName: String? = nil
    ) {
        if vizProvider == nil, let provider = prebuiltVisualizationProvider ?? makeVisualizationProvider?() {
            vizProvider  = provider

            // Detach from the previous canvas hierarchy (skin swap); no-op on first launch.
            provider.view.removeFromSuperview()

            // Wrap the viz in a container for frame/visibility management.
            // NSOpenGLView must NOT be inside a wantsLayer=true container — doing so
            // places it in a layer-backed hierarchy and OpenGL stops rendering.
            let container = NSView(frame: frame)
            addSubview(container, positioned: .above, relativeTo: nil)
            provider.view.frame = CGRect(origin: .zero, size: frame.size)
            container.addSubview(provider.view)
            vizContainer = container

            // Apply a CALayer mask if this skin's effects element nominated one.
            // maskImageName is set for skins where the parent subview's backgroundImage defines
            // the viz viewport via colored pixels (e.g. viz_mask.gif in Elvis, viz_screen.gif in
            // Heart_Butterfly, transparencyColor=#FFFFFF).  Falls back to "vis_mask.gif" for skins
            // that ship that file but use a different cover mechanism (e.g. Plus! Professional).
            // The mask's non-white/non-transparent pixels show the viz; white pixels hide it.
            // NOTE: wantsLayer=true is required for container.layer to be non-nil. NSOpenGLView
            // works correctly in a layer-backed hierarchy when wantsBestResolutionOpenGLSurface=true
            // is set (which configure() does before creating the OpenGL context).
            let resolvedMaskName = maskImageName ?? (cache.mapData["vis_mask.gif"] != nil ? "vis_mask.gif" : nil)
            if let name = resolvedMaskName,
               let md = cache.mapData[name],
               let maskImg = buildVisMaskLayerImage(from: md, targetSize: frame.size) {
                container.wantsLayer = true
                if let layer = container.layer {
                    let maskLayer = CALayer()
                    maskLayer.contents = maskImg
                    maskLayer.frame = CGRect(origin: .zero, size: frame.size)
                    maskLayer.contentsGravity = .resize
                    layer.mask = maskLayer
                }
            }

            if let backend = playerBackend, !vizConfigured {
                provider.configure(backend: backend, presetPath: presetSearchPath())
                vizConfigured = true
            }
            wireVizJSBindings(for: fx, provider: provider)
            // Build a cover NSImageView for each image that must appear above the viz.
            // The image is composited each draw() to include positive-zIndex children
            // (play controls, seek bar, etc.) that otherwise live below all NSViews.
            vizCoverInfos = covers.map { (sv, bgImage, coverFrame, drawRect) in
                let iv = NSImageView(frame: coverFrame)
                iv.image        = bgImage
                iv.imageScaling = .scaleAxesIndependently
                addSubview(iv)
                return VizCoverInfo(subview: sv, bgImage: bgImage, frame: coverFrame,
                                    drawRect: drawRect, imageView: iv)
            }
        }
        vizContainer?.frame = frame
        vizProvider?.view.frame = CGRect(origin: .zero, size: vizContainer?.bounds.size ?? frame.size)
        vizProvider?.resize(to: frame.size)
        if let maskLayer = vizContainer?.layer?.mask {
            maskLayer.frame = CGRect(origin: .zero, size: frame.size)
        }
        for (i, cover) in covers.enumerated() where i < vizCoverInfos.count {
            vizCoverInfos[i].frame           = cover.frame
            vizCoverInfos[i].drawRect        = cover.drawRect
            vizCoverInfos[i].imageView.frame = cover.frame
        }
        if let provider = vizProvider {
            let hidden = elementIsHidden(fx.base, live: true) || ancestorAlpha == 0
            provider.view.isHidden   = hidden
            vizContainer?.isHidden   = hidden
            // Covers are only needed when the viz is live — when hidden, CGContext draws
            // those elements (stone_base, over_base, etc.) correctly at their own z-order.
            for info in vizCoverInfos { info.imageView.isHidden = hidden }
            let combinedAlpha = min(effectiveAlpha(for: fx.base), ancestorAlpha)
            provider.view.alphaValue = hidden ? 0 : CGFloat(combinedAlpha) / 255.0
        }
    }

    /// Builds an RGBA CGImage suitable for use as a `CALayer.mask` contents, where
    /// grey pixels in `md` become opaque (show the viz) and white/transparent/magenta
    /// pixels become alpha=0 (hide the viz). Rows are flipped to match the top-down
    /// coordinate system of macOS NSView backing layers (isGeometryFlipped=true).
    private func buildVisMaskLayerImage(from md: MapData, targetSize: CGSize) -> CGImage? {
        let tw = max(1, Int(targetSize.width))
        let th = max(1, Int(targetSize.height))
        var bytes = [UInt8](repeating: 0, count: tw * th * 4)
        for dstRow in 0 ..< th {
            // Flip rows: CGImage row 0 = visual top (matches isGeometryFlipped=true).
            // MapData row 0 = visual bottom (CGContext order) → mirror to get visual top.
            let srcRow = (dstRow * md.height / th)
            for dstCol in 0 ..< tw {
                let srcCol = min(md.width - 1, dstCol * md.width / tw)
                let si = (srcRow * md.width + srcCol) * 4
                guard si + 3 < md.bytes.count else { continue }
                let r = md.bytes[si], g = md.bytes[si+1], b = md.bytes[si+2], a = md.bytes[si+3]
                let visible = a > 10 && !isMagenta(r, g, b) && !(r > 240 && g > 240 && b > 240)
                let alpha: UInt8 = visible ? 255 : 0
                let di = (dstRow * tw + dstCol) * 4
                bytes[di] = alpha; bytes[di+1] = alpha; bytes[di+2] = alpha; bytes[di+3] = alpha
            }
        }
        guard let space    = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: tw, height: th,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: tw * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// Called at the end of every draw(_:) cycle to update the viz cover NSImageViews.
    /// Each cover composites its background image, the positive-zIndex children of its
    /// subview, and any global groups/buttons/sliders that intersect the cover frame but
    /// live outside the cover subview's child tree (e.g. vol/seek sliders in Pulsar which
    /// are siblings of visMask, not children of any cover subview).
    private func renderVizCoverImages(lc: LayoutContext) {
        guard !vizCoverInfos.isEmpty else { return }
        for info in vizCoverInfos {
            let sv    = info.subview
            let frame = info.frame
            guard frame.width > 0, frame.height > 0 else { continue }
            let composite = NSImage(size: frame.size)
            composite.lockFocusFlipped(true)
            if let imgCtx = NSGraphicsContext.current?.cgContext {
                // Shift canvas-coord drawing into image-local coordinates.
                imgCtx.translateBy(x: -frame.origin.x, y: -frame.origin.y)
                // Draw the background at its canvas rect. For parent covers frame==drawRect;
                // for sibling covers drawRect is the full sibling rect while frame is the
                // intersection with the viz — only the overlapping portion is painted.
                if info.subview?.backgroundTiled == true {
                    drawTiledImage(info.bgImage, in: info.drawRect, ctx: imgCtx)
                } else {
                    info.bgImage.draw(in: info.drawRect)
                }
                // Draw positive-zIndex children of the cover subview (nil for view-level covers).
                let aboveChildren = sv?.children.filter { ($0.base?.zIndex ?? 0) >= 0 } ?? []
                let coverOffset   = CGPoint(x: frame.origin.x, y: frame.origin.y)
                let coverButtons  = collectButtons(in: aboveChildren, offset: coverOffset, lc: lc)
                let coverSliders  = collectSliders(in: aboveChildren, offset: coverOffset, lc: lc)
                var bi = 0
                var si = 0
                drawElements(aboveChildren,
                             offset: coverOffset,
                             lc: lc, ctx: imgCtx,
                             buttonIdx: &bi, sliderIdx: &si,
                             buttonOverride: coverButtons, sliderOverride: coverSliders)
                // Draw global groups/buttons/sliders that intersect the viz cover frame but
                // live outside the cover subview's child tree. Skip any already drawn above.
                let svId = sv?.base.id
                func isOwnedByCover(_ ancestors: [ElementBase]) -> Bool {
                    guard let id = svId else { return false }
                    return ancestors.contains { $0.id == id }
                }
                for group in groups {
                    guard !elementIsHidden(group.model.base, live: true),
                          ancestorsVisible(group.ancestorBases),
                          group.frame.intersects(frame),
                          !isOwnedByCover(group.ancestorBases) else { continue }
                    drawGroup(group, frame: group.frame, ctx: imgCtx)
                }
                for button in buttons {
                    guard !elementIsHidden(button.model.base, live: true),
                          ancestorsVisible(button.ancestorBases),
                          button.frame.intersects(frame),
                          !isOwnedByCover(button.ancestorBases) else { continue }
                    drawButton(button, ctx: imgCtx)
                }
                for slider in sliders {
                    guard !elementIsHidden(slider.model.base, live: true),
                          ancestorsVisible(slider.ancestorBases),
                          slider.frame.intersects(frame),
                          !isOwnedByCover(slider.ancestorBases) else { continue }
                    drawSlider(slider)
                }
            }
            composite.unlockFocus()
            info.imageView.image = composite
        }
    }

    private func wireVizJSBindings(for fx: Effects, provider: any VisualizationProviding) {
        guard let engine, let id = fx.base.id, !id.isEmpty else { return }
        engine.registerObject(
            { [weak provider] in provider?.nextPreset() }     as @convention(block) () -> Void,
            forKey: "_vizNext"
        )
        engine.registerObject(
            { [weak provider] in provider?.previousPreset() } as @convention(block) () -> Void,
            forKey: "_vizPrev"
        )
        engine.registerObject(
            { [weak provider] in provider?.currentPresetName ?? "" } as @convention(block) () -> String,
            forKey: "_vizPresetName"
        )
        engine.evaluate("""
            if (typeof \(id) !== 'undefined') {
                \(id).next = function() { _vizNext(); };
                \(id).previous = function() { _vizPrev(); };
                Object.defineProperty(\(id), 'effectTitle', {
                    get: function() { return _vizPresetName(); },
                    configurable: true
                });
            }
        """)
    }

    private func presetSearchPath() -> URL? {
        let fm = FileManager.default

        // Resolves a top-level symlink inside `url` to its real target, so projectM's C
        // scanner (which doesn't follow symlinks) gets a real directory path. Returns nil
        // if no entry resolves to a real directory (e.g. broken relative symlink after bundle copy).
        func resolveSymlink(_ url: URL) -> URL? {
            guard let items = try? fm.contentsOfDirectory(atPath: url.path) else { return nil }
            for item in items where !item.hasPrefix(".") {
                let child = url.appendingPathComponent(item)
                let resolved = child.resolvingSymlinksInPath()
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
                    if resolved.path != child.path {
                        print("[SkinCanvas] resolved preset symlink: \(child.path) → \(resolved.path)")
                    }
                    return resolved
                }
            }
            print("[SkinCanvas] bundle presets dir has no resolvable content, falling through")
            return nil
        }

        func hasPresets(_ url: URL) -> Bool {
            guard let items = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
            return items.contains { !$0.hasPrefix(".") }
        }

        // 1. Bundled presets in the package/app bundle.
        if let url = Bundle.module.url(forResource: "presets", withExtension: nil,
                                       subdirectory: "projectM"), hasPresets(url),
           let resolved = resolveSymlink(url) {
            return resolved
        }
        if let appResource = Bundle.main.resourceURL?.appendingPathComponent("presets"),
           hasPresets(appResource) {
            return appResource
        }
        if let appResource = Bundle.main.resourceURL?.appendingPathComponent("projectM/presets"),
           hasPresets(appResource) {
            return appResource
        }

        // 2. Repo-local presets during development.
        let bundled = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // SkinnerCore/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("vendor/presets-cream-of-the-crop")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }

        let cwdBundled = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("vendor/presets-cream-of-the-crop")
        if FileManager.default.fileExists(atPath: cwdBundled.path) { return cwdBundled }

        // 3. Homebrew preset paths.
        let arm = URL(fileURLWithPath: "/opt/homebrew/share/projectM/presets")
        if FileManager.default.fileExists(atPath: arm.path) { return arm }
        let intel = URL(fileURLWithPath: "/usr/local/share/projectM/presets")
        if FileManager.default.fileExists(atPath: intel.path) { return intel }
        return nil
    }

    private func rescheduleTimer() {
        timerWorkItem?.cancel()
        timerWorkItem = nil
        guard let ms = engine?.currentTimerInterval, ms > 0 else {
            timerLastInterval = 0
            return
        }
        // Drift-free scheduling: base the next deadline on the last intended fire time so
        // processing overhead doesn't accumulate and slow down animations.  When the interval
        // changes (including from 0), reset from now to avoid firing in the past.
        let deadline: DispatchTime
        if ms != timerLastInterval {
            deadline = .now() + .milliseconds(ms)
        } else {
            deadline = timerDeadline + .milliseconds(ms)
        }
        // Safety: never schedule in the past if we fall more than one interval behind.
        timerDeadline = max(deadline, .now())
        timerLastInterval = ms
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.engine?.fireOnTimer()
            self.applyScriptChanges()
        }
        timerWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: timerDeadline, execute: item)
    }

    private func applyScriptChanges() {
        engine?.fireOnEndMoveCallbacks()
        recollect()
        updateLiveSliders()
        updateAnimatedSubviewVisibility()
        // Rebuild the click-through mask synchronously so the upcoming draw (below)
        // reflects elements' new positions/images. Deferring this to a later runloop
        // turn caused one stale-mask frame to be drawn first, flashing the background
        // through areas a moved/covering element no longer leaves transparent.
        // Cheap in the common (no-op) case via the signature check in buildBgOpacity().
        buildBgOpacity()
        if let bundle {
            let lc = LayoutContext(viewWidth: bounds.width, viewHeight: bounds.height)
            promoteNewGifSubviews(in: skinView.elements, offset: .zero, lc: lc, bundle: bundle)
        }
        setNeedsDisplay(bounds)
        rescheduleTimer()
        // Stamp _t0 for any newly-queued moveTo animations AFTER the setup work above
        // so the animation clock starts from when the timer can first fire, not from
        // when moveTo() was called.
        engine?.stampNewAnimationStartTimes()
        startMoveTimerIfNeeded()
    }

    private func startMoveTimerIfNeeded() {
        guard moveTimer == nil, engine?.hasActiveMoves == true else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.tickMovesStep() }
        }
        RunLoop.main.add(t, forMode: .common)
        moveTimer = t
    }

    private func stopMoveTimer() {
        moveTimer?.invalidate()
        moveTimer = nil
    }

    private func tickMovesStep() {
        guard let engine else { stopMoveTimer(); return }
        let _ = engine.tickMoves()
        engine.fireOnEndMoveCallbacks()
        recollect()
        setNeedsDisplay(bounds)
        if !engine.hasActiveMoves {
            stopMoveTimer()
            updateLiveSliders()
            updateAnimatedSubviewVisibility()
            rescheduleTimer()
            // Rebuild the mask synchronously (before the setNeedsDisplay above is
            // flushed) so the final frame doesn't draw with the pre-animation mask
            // and flash the background through the shutter's new position.
            buildBgOpacity()
        }
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
                        self?.completedOnePassAnimations.insert(id)
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

    /// Tracks NSImageViews that temporarily cover one-pass intro GIF NSImageViews.
    /// All views hide once every associated GIF finishes playing.
    private final class GifCoverGroup {
        var remaining: Int
        var views: [NSImageView] = []
        init(remaining: Int) { self.remaining = remaining }
        @MainActor func oneCompleted() {
            remaining -= 1
            if remaining <= 0 { views.forEach { $0.isHidden = true } }
        }
    }

    /// Associates a cover NSImageView with a set of GIF element IDs.
    /// Reuses an existing group if any ID already has one; otherwise creates a new one.
    private func addGifCover(_ iv: NSImageView, forGifIds ids: [String]) {
        let group: GifCoverGroup
        if let existing = ids.lazy.compactMap({ self.gifCoverGroups[$0] }).first {
            group = existing
        } else {
            group = GifCoverGroup(remaining: ids.count)
            for id in ids { gifCoverGroups[id] = group }
        }
        group.views.append(iv)
    }

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
    /// Returns IDs of one-pass GIF NSImageViews created (visible, with an element ID).
    /// Higher-z siblings and passthrough parents use these IDs to register cover views.
    @discardableResult
    private func buildAnimatedSubviews(in elements: [SkinElement],
                                        offset: CGPoint,
                                        lc: LayoutContext) -> [String] {
        guard let bundle else { return [] }
        var gifNSViewAddedToList = false
        var createdGifIds: [String] = []
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
            let below = sv.children.filter { ($0.base?.zIndex ?? 0) < 0 }
            let above = sv.children.filter { ($0.base?.zIndex ?? 0) >= 0 }

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
                        gifNSViewAddedToList = true
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
                    gifNSViewAddedToList = true
                    if let dur = gifOnePassDuration(raw, excludingLastFrame: true) {
                        let animId = sv.base.id
                        let animIsClose = name.lowercased().contains("close")
                        let animIsOpen  = name.lowercased().contains("open")
                        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self, weak iv] in
                            iv?.animates = false
                            if let self, let id = animId,
                               !animIsClose,
                               let wms = self.animatedSubviewWmsBackground[id],
                               !wms.hasSuffix(".gif"),
                               !animIsOpen,
                               let img = self.cache.images[wms]
                                         ?? self.bundle.flatMap({ NSImage(contentsOf: $0.assetURL(named: wms)) }) {
                                iv?.image    = img
                                iv?.isHidden = false
                                self.startupFallbacksShowing.insert(id)
                            } else {
                                iv?.isHidden = true
                                if let self, let id = animId { self.completedOnePassAnimations.insert(id) }
                            }
                            // Dismiss any covers waiting on this GIF.
                            if let self, let id = animId {
                                self.gifCoverGroups[id]?.oneCompleted()
                                self.gifCoverGroups.removeValue(forKey: id)
                            }
                        }
                        // Track visible one-pass GIFs; higher-z siblings will cover them.
                        if !hidden, let id = sv.base.id { createdGifIds.append(id) }
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
                } else if gifNSViewAddedToList,
                          sv.base.id == nil,
                          let name = bgName,
                          !name.lowercased().hasSuffix(".gif"),
                          !promotedGifNames.contains(name.lowercased()),
                          let img = cache.images[name.lowercased()] {
                    // No-id static overlay that sits above a GIF NSImageView in z-order.
                    // Promote it to its own NSImageView so it renders above the GIF;
                    // CGContext always draws below every NSImageView regardless of zIndex.
                    let w  = lc.resolve(sv.base.width)  ?? img.size.width
                    let h  = lc.resolve(sv.base.height) ?? img.size.height
                    let iv = NSImageView(frame: NSRect(x: x, y: y, width: w, height: h))
                    iv.image        = img
                    iv.animates     = false
                    iv.imageScaling = .scaleAxesIndependently
                    iv.isHidden     = hidden
                    addSubview(iv)
                    promotedGifNames.insert(name.lowercased())
                } else if !hidden, !createdGifIds.isEmpty,
                          let name = bgName,
                          !name.lowercased().hasSuffix(".gif"),
                          !cache.clipImageNames.contains(name.lowercased()),
                          !promotedGifNames.contains(name.lowercased()),
                          let img = cache.images[name.lowercased()] {
                    // This element's z-index is above a one-pass intro GIF. NSImageViews
                    // always render above CGContext, so the GIF would bleed through.
                    // Add a temporary cover NSImageView that hides when the GIF finishes.
                    let w  = lc.resolve(sv.base.width)  ?? img.size.width
                    let h  = lc.resolve(sv.base.height) ?? img.size.height
                    let iv = NSImageView(frame: NSRect(x: x, y: y, width: w, height: h))
                    iv.image        = img
                    iv.animates     = false
                    iv.imageScaling = .scaleAxesIndependently
                    addSubview(iv)
                    addGifCover(iv, forGifIds: createdGifIds)
                }
                // Recurse into visible children; propagate one-pass GIF IDs upward.
                if !hidden {
                    let childGifIds = buildAnimatedSubviews(in: sv.children, offset: co, lc: lc)
                    if !childGifIds.isEmpty {
                        // passthrough parent: its background must sit above child GIF NSImageViews.
                        if sv.base.passThrough,
                           let name = bgName,
                           !name.lowercased().hasSuffix(".gif"),
                           !cache.clipImageNames.contains(name.lowercased()),
                           !promotedGifNames.contains(name.lowercased()),
                           let img = cache.images[name.lowercased()] {
                            let w  = lc.resolve(sv.base.width)  ?? img.size.width
                            let h  = lc.resolve(sv.base.height) ?? img.size.height
                            let iv = NSImageView(frame: NSRect(x: x, y: y, width: w, height: h))
                            iv.image        = img
                            iv.animates     = false
                            iv.imageScaling = .scaleAxesIndependently
                            addSubview(iv)
                            addGifCover(iv, forGifIds: childGifIds)
                        }
                        createdGifIds += childGifIds
                    }
                }
            }
        }
        return createdGifIds
    }

    // MARK: - Visibility

    /// Script state takes precedence over the parsed `visible` attribute.
    private func ancestorsVisible(_ bases: [ElementBase]) -> Bool {
        bases.allSatisfy { !elementIsHidden($0, live: true) }
    }

    private func ancestorsPassThrough(_ bases: [ElementBase]) -> Bool {
        bases.contains { $0.passThrough }
    }

    /// Returns false if the element has `enabled=false` in engine state or the WMS attribute.
    /// Used for hit-testing only — disabled elements are visible but non-interactive.
    private func elementIsEnabled(_ base: ElementBase) -> Bool {
        if let id = base.id, let s = engine?.state(for: id), let en = s.enabled { return en }
        if let en = base.enabled?.boolValue { return en }
        return true
    }

    /// Returns false if a ButtonElement within a group is disabled (JS state or WMS attribute).
    private func buttonElementIsEnabled(_ elem: ButtonElement?) -> Bool {
        guard let elem else { return true }
        if let id = elem.id, let s = engine?.state(for: id), let en = s.enabled { return en }
        if let en = elem.enabled?.boolValue { return en }
        return true
    }

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

// MARK: - VizCoverInfo

private struct VizCoverInfo {
    let subview:   Subview?   // nil for view-level covers (no parent subview)
    let bgImage:   NSImage
    var frame:     CGRect       // NSImageView position; for sibling covers = intersection with viz frame
    var drawRect:  CGRect       // canvas rect at which bgImage is drawn; equals frame for parent covers,
                                // full sibling rect for sibling covers (image drawn offset into intersection)
    let imageView: NSImageView
}

// MARK: - RenderedGroup

private struct RenderedGroup {
    let model:         ButtonGroup
    let assets:        ButtonGroupAssets
    let mapData:       MapData?
    let frame:         CGRect
    let clipMask:      CGImage?
    let ancestorBases: [ElementBase]
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
    let model:         Button
    let frame:         CGRect
    let mapData:       MapData?
    let clipMask:      CGImage?
    let ancestorBases: [ElementBase]
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
    let ancestorBases:   [ElementBase]
    var value:           Double = 0

    var frameIndex: Int { max(0, min(frameCount - 1, Int(value * Double(frameCount - 1)))) }
}

// MARK: - RenderedText

private struct RenderedText {
    let model:         TextLabel
    let frame:         CGRect
    let ancestorBases: [ElementBase]
    var isHovered: Bool = false
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

