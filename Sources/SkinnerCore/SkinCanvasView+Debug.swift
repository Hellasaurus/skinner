import AppKit

// MARK: - Debug interaction + buffer dumps

/// Debug-only entry points: synthetic mouse events (drive the view without `cliclick`)
/// and buffer dumps (inspect rendered frame, click-through mask, mapData, button-group
/// masks, clip masks).
extension SkinCanvasView {

    /// The skin's JS engine, for inspecting captured startup-animation steps etc.
    var debugEngine: SkinScriptEngine? { engine }

    /// Synthesizes a left click (down + up) at `point` in this view's coordinate space
    /// (top-left origin, matches `isFlipped` / WMS layout coords).
    public func debugClick(atViewPoint point: CGPoint) {
        let windowPoint = convert(point, to: nil)
        let windowNumber = window?.windowNumber ?? 0
        let now = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
                                             modifierFlags: [], timestamp: now,
                                             windowNumber: windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint,
                                           modifierFlags: [], timestamp: now,
                                           windowNumber: windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 0)
        else { return }
        mouseDown(with: down)
        mouseUp(with: up)
    }

    /// Synthesizes a mouse-moved event at `point` in this view's coordinate space, to
    /// drive hover state (button/group highlight) without moving the real cursor.
    public func debugMove(atViewPoint point: CGPoint) {
        let windowPoint = convert(point, to: nil)
        guard let move = NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window?.windowNumber ?? 0, context: nil,
                                             eventNumber: 0, clickCount: 0, pressure: 0)
        else { return }
        mouseMoved(with: move)
    }

    /// Synthesizes a mouse-down-drag-up sequence from `from` to `to` in this view's
    /// coordinate space, interpolated over `steps` intermediate `mouseDragged` events.
    /// Drives real slider-drag codepaths (`activeSliderIdx`, `mouseDragged`) that
    /// `debugClick` (down+up with no drag in between) can't reach.
    public func debugDrag(from: CGPoint, to: CGPoint, steps: Int) {
        let windowNumber = window?.windowNumber ?? 0
        func event(_ type: NSEvent.EventType, _ p: CGPoint, _ pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: convert(p, to: nil),
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: pressure)
        }
        if let down = event(.leftMouseDown, from, 1) { mouseDown(with: down) }
        let steps = max(1, steps)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            if let move = event(.leftMouseDragged, p, 1) { mouseDragged(with: move) }
        }
        if let up = event(.leftMouseUp, to, 0) { mouseUp(with: up) }
    }

    /// Renders the current frame via `draw(_:)`. Captures CGContext output only —
    /// composited `NSImageView` subviews (animated GIFs, viz covers) are not included.
    /// Uses `lockFocus` rather than `cacheDisplay` so this works for layer-backed
    /// views with no window (e.g. in `swift test`).
    public func currentFrameImage() -> CGImage? {
        let image = NSImage(size: bounds.size)
        image.lockFocusFlipped(isFlipped)
        draw(bounds)
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Renders the current frame to a PNG at `url`. See `currentFrameImage()`.
    public func snapshotPNG(to url: URL) throws {
        guard let cg = currentFrameImage() else { throw ImageDebugIO.DebugIOError.noCGImage }
        try ImageDebugIO.writePNG(cg, to: url)
    }

    /// Dumps the current frame, click-through mask, and every cached mapData/button-group/
    /// clip-mask buffer to `directory` as PNGs, for inspecting transparency, hit regions,
    /// and layering.
    public func dumpDebugBuffers(to directory: URL) throws {
        try snapshotPNG(to: directory.appendingPathComponent("frame.png"))
        if let bgMask {
            try ImageDebugIO.writePNG(bgMask, to: directory.appendingPathComponent("bgmask.png"))
        }
        try cache.dumpDebugImages(to: directory)
    }
}
