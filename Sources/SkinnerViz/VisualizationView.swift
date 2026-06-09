import AppKit
import OpenGL.GL3
import CoreVideo
import SkinnerCore

// MARK: - RenderState

/// Holds the state accessed from the CVDisplayLink render thread.
/// @unchecked Sendable — bridge and ring buffer are written on main before the display link
/// starts; thereafter only the render thread writes/reads them while the main thread does not.
private final class RenderState: @unchecked Sendable {
    var bridge: ProjectMBridge?
    let ring    = PCMRingBuffer()
    var cglCtx: CGLContextObj?

    func render() {
        guard let cglCtx, let bridge else { return }
        CGLLockContext(cglCtx)
        CGLSetCurrentContext(cglCtx)
        let samples = ring.read(count: 512)
        bridge.addPCM(samples)
        bridge.renderFrame()
        CGLFlushDrawable(cglCtx)
        CGLUnlockContext(cglCtx)
    }
}

// MARK: - VisualizationView

/// NSOpenGLView that renders projectM visuals driven by a CVDisplayLink.
public final class VisualizationView: NSOpenGLView, VisualizationProviding {

    public var view: NSView { self }

    private let state                          = RenderState()
    nonisolated(unsafe) private var displayLink: CVDisplayLink?
    private var tapToken:                      PCMTapToken?
    private weak var backend: (any PlayerBackend)?
    private var configured   = false
    private var isMigrating  = false

    // MARK: - VisualizationProviding

    public func configure(backend: any PlayerBackend, presetPath: URL?) {
        guard !configured else { return }
        configured   = true
        self.backend = backend

        wantsBestResolutionOpenGLSurface = true

        // NSOpenGLView/NSOpenGLContext are deprecated since macOS 10.14 but functional on 13+.
        let attribs: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADepthSize),
            NSOpenGLPixelFormatAttribute(24),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            0
        ]
        guard let pf  = NSOpenGLPixelFormat(attributes: attribs),
              let ctx = NSOpenGLContext(format: pf, share: nil) else { return }
        openGLContext = ctx
        ctx.makeCurrentContext()
        state.cglCtx = ctx.cglContextObj

        let sz = bounds.isEmpty ? CGSize(width: 200, height: 200) : convertToBacking(bounds.size)
        state.bridge = ProjectMBridge(presetPath: presetPath)
        state.bridge?.resize(width: Int(sz.width), height: Int(sz.height))

        let ring = state.ring
        tapToken = backend.installPCMTap { [ring] samples in
            ring.write(samples)
        }

        startDisplayLink()
    }

    public func resize(to size: CGSize) {
        let px = convertToBacking(size)
        state.bridge?.resize(width: Int(px.width), height: Int(px.height))
    }

    public var currentPresetName: String { state.bridge?.currentPresetName ?? "" }
    public func nextPreset()     { state.bridge?.nextPreset() }
    public func previousPreset() { state.bridge?.previousPreset() }

    /// Stop the display link and mark this view as mid-migration so `viewWillMove(toWindow: nil)`
    /// doesn't perform full teardown when the view is pulled out of the old canvas hierarchy.
    /// Call this before closing the old skin window. The display link restarts automatically
    /// in `viewDidMoveToWindow` when the view lands in the new canvas.
    public func beginMigration() {
        guard configured else { return }
        isMigrating = true
        if let dl = displayLink { CVDisplayLinkStop(dl) }
        displayLink = nil
    }

    // MARK: - Lifecycle

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, !isMigrating else { return }
        if let token = tapToken, let b = backend { b.removePCMTap(token) }
        tapToken = nil
        if let dl = displayLink { CVDisplayLinkStop(dl) }
        displayLink = nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, isMigrating, configured else { return }
        isMigrating = false
        startDisplayLink()
    }

    public override func reshape() {
        super.reshape()
        openGLContext?.makeCurrentContext()
        if !bounds.isEmpty {
            let px = convertToBacking(bounds.size)
            state.bridge?.resize(width: Int(px.width), height: Int(px.height))
        }
    }

    deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
    }

    // MARK: - Display link

    // nonisolated: CVDisplayLink fires the callback on a background thread.
    // Creating the closure inside a @MainActor method injects an executor check in
    // Swift 6, which crashes when the callback runs off-main. Moving the setup to a
    // nonisolated context makes the closure non-isolated so no check is injected.
    // `state` (let) and `displayLink` (nonisolated(unsafe)) are both safe to access here.
    private nonisolated func startDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        displayLink = dl
        let s = state
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, ctx -> CVReturn in
            Unmanaged<RenderState>.fromOpaque(ctx!).takeUnretainedValue().render()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(s).toOpaque())
        CVDisplayLinkStart(dl)
    }
}
