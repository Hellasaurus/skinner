import AppKit

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

    private var groups:    [RenderedGroup]  = []
    private var buttons:   [RenderedButton] = []
    private var sliders:   [RenderedSlider] = []
    private var bgOpacity: [Bool]           = []
    private var bgWidth    = 0
    private var bgHeight   = 0
    private let bundle: SkinBundle?
    private var dragOrigin: NSPoint?
    private var engine: SkinScriptEngine?
    private var animatedSubviews: [String: NSImageView] = [:]   // element id → NSImageView

    public var onOpenView:  ((String) -> Void)? { didSet { engine?.onOpenView  = onOpenView  } }
    public var onCloseView: ((String) -> Void)? { didSet { engine?.onCloseView = onCloseView } }

    public override var isFlipped: Bool { true }

    // MARK: - Init

    public init(skinView: SkinView, cache: AssetCache, bundle: SkinBundle? = nil) {
        self.skinView = skinView
        self.cache    = cache
        self.bundle   = bundle                 // stored before super.init (let property)

        let sizeCtx = LayoutContext(viewWidth: 0, viewHeight: 0)
        let w = sizeCtx.resolve(skinView.width)  ?? 320
        let h = sizeCtx.resolve(skinView.height) ?? 240
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
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

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
                let sx = (lc.resolve(sv.base.left) ?? 0) + offset.x
                let sy = (lc.resolve(sv.base.top)  ?? 0) + offset.y
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
                let x  = (lc.resolve(b.base.left) ?? 0) + offset.x
                let y  = (lc.resolve(b.base.top)  ?? 0) + offset.y
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
                let sx = (lc.resolve(sv.base.left) ?? 0) + offset.x
                let sy = (lc.resolve(sv.base.top)  ?? 0) + offset.y
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
                let x    = (lc.resolve(s.base.left) ?? 0) + offset.x
                let y    = (lc.resolve(s.base.top)  ?? 0) + offset.y
                let posMD = s.positionImage.flatMap { cache.mapData[$0.lowercased()] }
                var w    = lc.resolve(s.base.width)  ?? CGFloat(posMD?.width  ?? 0)
                var h    = lc.resolve(s.base.height) ?? CGFloat(posMD?.height ?? 0)
                var fc   = 1
                if let n = s.image, let img = cache.images[n.lowercased()],
                   let pd = posMD, pd.width > 0 {
                    fc = max(1, Int(img.size.width) / pd.width)
                    if w == 0 { w = CGFloat(pd.width)  }
                    if h == 0 { h = CGFloat(pd.height) }
                }
                var rs = RenderedSlider(model: s,
                                        frame: CGRect(x: x, y: y, width: w, height: h),
                                        frameCount: fc)
                rs.value = resolvedSliderValue(s)
                result.append(rs)
            case .subview(let sv):
                guard !elementIsHidden(sv.base) else { continue }
                let sx = (lc.resolve(sv.base.left) ?? 0) + offset.x
                let sy = (lc.resolve(sv.base.top)  ?? 0) + offset.y
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
        guard let info = firstSubviewBgInfo(in: skinView.elements),
              let md   = cache.mapData[info.name.lowercased()]
        else { return }
        bgWidth  = md.width
        bgHeight = md.height
        let extraColors = info.transparentColors
        bgOpacity = (0 ..< md.width * md.height).map { i in
            let o = i * 4
            let r = md.bytes[o], g = md.bytes[o + 1], b = md.bytes[o + 2]
            guard md.bytes[o + 3] > 128, !isMagenta(r, g, b) else { return false }
            if extraColors.contains(where: { colorMatches(r, g, b, $0.0, $0.1, $0.2) }) { return false }
            return true
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
                guard !elementIsHidden(sv.base) else { continue }
                let sx = (lc.resolve(sv.base.left) ?? 0) + offset.x
                let sy = (lc.resolve(sv.base.top)  ?? 0) + offset.y
                let svZ = sv.base.zIndex ?? 0
                let childOffset = CGPoint(x: sx, y: sy)
                // Only children with an *explicitly set* zIndex lower than the parent's go
                // behind the background image.  Children with no zIndex (defaulting to 0)
                // always draw above the background — they are the normal case.
                let below = sv.children.filter { $0.base?.zIndex != nil && ($0.base?.zIndex ?? 0) < svZ }
                let above = sv.children.filter { $0.base?.zIndex == nil || ($0.base?.zIndex ?? 0) >= svZ }
                let alpha = effectiveAlpha(for: sv.base)
                let needsAlpha = alpha < 255
                if needsAlpha {
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(alpha) / 255.0)
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                }
                drawElements(below, offset: childOffset, lc: lc, ctx: ctx,
                             buttonIdx: &buttonIdx, sliderIdx: &sliderIdx)
                // Skip if an animated NSImageView is handling this element.
                if sv.base.id.flatMap({ animatedSubviews[$0] }) == nil {
                    let bgName = sv.base.id.flatMap { engine?.state(for: $0)?.backgroundImage }
                                 ?? sv.backgroundImage
                    if let name = bgName,
                       cache.buttonGroupsByMappingImage[name.lowercased()] == nil,
                       !cache.clipImageNames.contains(name.lowercased()),
                       let img  = cache.images[name.lowercased()] {
                        let w = lc.resolve(sv.base.width)  ?? img.size.width
                        let h = lc.resolve(sv.base.height) ?? img.size.height
                        img.draw(in: NSRect(x: sx, y: sy, width: w, height: h))
                    }
                }
                drawElements(above, offset: childOffset, lc: lc, ctx: ctx,
                             buttonIdx: &buttonIdx, sliderIdx: &sliderIdx)
                if needsAlpha {
                    ctx.endTransparencyLayer()
                    ctx.restoreGState()
                }

            case .buttonGroup(let bg):
                guard !elementIsHidden(bg.base) else { continue }
                if let rg = groups.first(where: { $0.model.mappingImage == bg.mappingImage }) {
                    drawGroup(rg, ctx: ctx)
                }

            case .button(let b):
                guard !elementIsHidden(b.base) else { continue }
                if buttonIdx < buttons.count {
                    drawButton(buttons[buttonIdx], ctx: ctx)
                    buttonIdx += 1
                }

            case .slider(let s):
                guard !elementIsHidden(s.base) else { continue }
                if sliderIdx < sliders.count {
                    drawSlider(sliders[sliderIdx])
                    sliderIdx += 1
                }

            case .playlist(let p):
                guard !elementIsHidden(p.base) else { continue }
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

            default: break
            }
        }
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

    private func drawGroup(_ group: RenderedGroup, ctx: CGContext) {
        guard let imgName = group.model.image,
              let normal  = cache.images[imgName.lowercased()]
        else { return }

        let rect   = group.frame
        let cgRect = CGRect(origin: rect.origin, size: rect.size)

        ctx.saveGState()
        if let clip = group.clipMask { ctx.clip(to: cgRect, mask: clip) }
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
        if let clip = button.clipMask {
            ctx.saveGState()
            ctx.clip(to: button.frame, mask: clip)
            img.draw(in: button.frame)
            ctx.restoreGState()
        } else {
            img.draw(in: button.frame)
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

    private func drawStandardSlider(_ slider: RenderedSlider) {
        let frame = slider.frame

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
        let vertical = slider.model.direction?.lowercased() == "vertical"

        let thumbRect: NSRect
        if vertical {
            let travel = max(0, frame.height - thumbH - border * 2)
            let thumbY = frame.minY + border + (1 - v) * travel
            let thumbX = frame.minX + (frame.width - thumbW) / 2
            thumbRect = NSRect(x: thumbX, y: thumbY, width: thumbW, height: thumbH)
        } else {
            let travel = max(0, frame.width - thumbW - border * 2)
            let thumbX = frame.minX + border + v * travel
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
        let px = Int(point.x)
        let py = bgHeight - 1 - Int(point.y)  // superview is non-flipped; row 0 is top of image
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
        for i in groups.indices {
            if let color = groups[i].colorAt(pt) {
                groups[i].pressedColor = color
                setNeedsDisplay(bounds)
                return
            }
        }
        for i in buttons.indices where buttons[i].hitTest(pt) {
            buttons[i].isPressed = true
            setNeedsDisplay(bounds)
            return
        }
        dragOrigin = NSEvent.mouseLocation
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let win = window else { return }
        let current = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(
            x: win.frame.origin.x + current.x - origin.x,
            y: win.frame.origin.y + current.y - origin.y
        ))
        dragOrigin = current
    }

    public override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        let pt = convert(event.locationInWindow, from: nil)
        for i in groups.indices {
            if let pressed = groups[i].pressedColor {
                if groups[i].colorAt(pt) == pressed { fireGroupAction(groups[i], colorKey: pressed) }
                groups[i].pressedColor = nil
                setNeedsDisplay(bounds)
                return
            }
        }
        for i in buttons.indices where buttons[i].isPressed {
            if buttons[i].hitTest(pt) { fireButtonAction(buttons[i]) }
            buttons[i].isPressed = false
            setNeedsDisplay(bounds)
            return
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        var changed = false
        for i in groups.indices {
            let h = groups[i].colorAt(pt)
            if h != groups[i].hoveredColor { groups[i].hoveredColor = h; changed = true }
        }
        for i in buttons.indices {
            let h = buttons[i].hitTest(pt)
            if h != buttons[i].isHovered { buttons[i].isHovered = h; changed = true }
        }
        if changed { setNeedsDisplay(bounds) }
    }

    public override func mouseExited(with event: NSEvent) {
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
        let elem  = group.model.elements.first { $0.mappingColor.lowercased() == colorKey }
        let label = elem?.id ?? colorKey
        if let script = elem?.onClick { engine?.evaluate(script) }
        else { print("[ACTION] \(group.model.base.id ?? "buttongroup") / \(label)") }
    }

    private func fireButtonAction(_ button: RenderedButton) {
        let label: String
        switch button.model.kind {
        case .mute:    label = "mute"
        case .generic: label = button.model.base.id ?? button.model.base.onClick ?? button.model.image ?? "?"
        }
        if let script = button.model.base.onClick { engine?.evaluate(script) }
        else { print("[ACTION] button / \(label)") }
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
            guard !elementIsHidden(sv.base) else { continue }
            let x = (lc.resolve(sv.base.left) ?? 0) + offset.x
            let y = (lc.resolve(sv.base.top)  ?? 0) + offset.y
            let co = CGPoint(x: x, y: y)

            let bgName = sv.base.id.flatMap { engine?.state(for: $0)?.backgroundImage }
                         ?? sv.backgroundImage
            let svZ = sv.base.zIndex ?? 0
            let below = sv.children.filter { ($0.base?.zIndex ?? 0) < svZ }
            let above = sv.children.filter { ($0.base?.zIndex ?? 0) >= svZ }

            // Check if any below-children are GIF subviews (will become NSImageViews).
            // If so, this element's background must also be an NSImageView added after
            // them, since CGContext is always behind all NSImageViews.
            let hasGifBelow = below.contains { child in
                guard case .subview(let csv) = child else { return false }
                let cn = (csv.base.id.flatMap { engine?.state(for: $0)?.backgroundImage }
                          ?? csv.backgroundImage) ?? ""
                return cn.lowercased().hasSuffix(".gif") && !cache.clipImageNames.contains(cn.lowercased())
            }

            if hasGifBelow {
                buildAnimatedSubviews(in: below, offset: co, lc: lc)
                // Add this element's background as an NSImageView so it sits above the GIF below-children.
                if let name = bgName,
                   !cache.clipImageNames.contains(name.lowercased()),
                   let img = NSImage(contentsOf: bundle.assetURL(named: name)) {
                    // Use the pixel-accurate size from the asset cache rather than img.size,
                    // which may be DPI-adjusted (e.g. screen_cover.png has a 300 DPI pHYs chunk).
                    let cachedSize = cache.images[name.lowercased()]?.size
                    let w  = lc.resolve(sv.base.width)  ?? cachedSize?.width  ?? img.size.width
                    let h  = lc.resolve(sv.base.height) ?? cachedSize?.height ?? img.size.height
                    let iv = NSImageView(frame: NSRect(x: x, y: y, width: w, height: h))
                    iv.image        = img
                    iv.animates     = name.lowercased().hasSuffix(".gif")
                    iv.imageScaling = .scaleAxesIndependently
                    addSubview(iv)
                    if let id = sv.base.id { animatedSubviews[id] = iv }
                }
                buildAnimatedSubviews(in: above, offset: co, lc: lc)
            } else {
                if let name = bgName, name.lowercased().hasSuffix(".gif"),
                   !cache.clipImageNames.contains(name.lowercased()),
                   let img  = NSImage(contentsOf: bundle.assetURL(named: name)),
                   gifIsAnimated(img) {
                    let w  = lc.resolve(sv.base.width)  ?? img.size.width
                    let h  = lc.resolve(sv.base.height) ?? img.size.height
                    let iv = NSImageView(frame: NSRect(x: x, y: y, width: w, height: h))
                    iv.image        = img
                    iv.animates     = true
                    iv.imageScaling = .scaleAxesIndependently
                    addSubview(iv)
                    if let id = sv.base.id { animatedSubviews[id] = iv }
                }
                // Recurse after adding this element so children (added later) sit on top.
                buildAnimatedSubviews(in: sv.children, offset: co, lc: lc)
            }
        }
    }

    // MARK: - Visibility

    /// Script state takes precedence over the parsed `visible` attribute.
    /// `alphaBlend == 0` is treated as hidden (WMP skins use it to fade-out elements).
    private func elementIsHidden(_ base: ElementBase) -> Bool {
        if let id = base.id, let s = engine?.state(for: id) {
            if let vis   = s.visible    { return !vis }
            if let alpha = s.alphaBlend, alpha == 0 { return true }
        }
        if let alpha = base.alphaBlend, alpha == 0 { return true }
        guard case .literal(let str) = base.visible else { return false }
        return str.lowercased() == "false" || str == "0"
    }

    /// Returns the effective 0–255 alpha for a subview, checking script state first.
    private func effectiveAlpha(for base: ElementBase) -> Int {
        if let id = base.id, let s = engine?.state(for: id), let a = s.alphaBlend { return a }
        return base.alphaBlend ?? 255
    }

    private func firstSubviewBgInfo(
        in elements: [SkinElement]
    ) -> (name: String, transparentColors: [(UInt8, UInt8, UInt8)])? {
        for element in elements {
            if case .subview(let sv) = element, !elementIsHidden(sv.base) {
                if let img = sv.backgroundImage {
                    let colors = [sv.clippingColor, sv.base.transparencyColor]
                        .compactMap { $0.flatMap(parseAnyColor) }
                    return (img, colors)
                }
                if let info = firstSubviewBgInfo(in: sv.children) { return info }
            }
        }
        return nil
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
    let model:      Slider
    let frame:      CGRect
    let frameCount: Int
    var value:      Double = 0

    var frameIndex: Int { max(0, min(frameCount - 1, Int(value * Double(frameCount - 1)))) }
}

// MARK: - File-local helpers

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

