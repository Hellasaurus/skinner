import AppKit
import SkinnerCore

/// A borderless, transparent, shaped window that hosts one `SkinCanvasView`.
final class SkinWindow: NSWindow {

    private(set) var skinCanvas: SkinCanvasView?

    init(canvas: SkinCanvasView, relativeTo parent: NSWindow? = nil) {
        let frame = canvas.frame
        super.init(
            contentRect: frame,
            styleMask:   .borderless,
            backing:     .buffered,
            defer:       false
        )
        isOpaque                = false
        backgroundColor         = .clear
        hasShadow               = true
        isReleasedWhenClosed    = false
        acceptsMouseMovedEvents = true
        collectionBehavior      = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView  = canvas
        skinCanvas   = canvas

        if let parent {
            let pf = parent.frame
            setFrameOrigin(NSPoint(x: pf.maxX + 8, y: pf.minY))
        } else {
            center()
        }
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
}
