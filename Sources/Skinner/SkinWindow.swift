import AppKit
import SkinnerCore

/// A borderless, transparent, shaped window that hosts one `SkinCanvasView`.
final class SkinWindow: NSWindow {

    private(set) var skinCanvas: SkinCanvasView?

    init(canvas: SkinCanvasView) {
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
        center()
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
}
