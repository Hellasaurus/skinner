import AppKit
import UniformTypeIdentifiers
import SkinnerCore
import SkinnerPlayer

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: SkinWindow?
    private var theme:  Theme?
    private var cache:  AssetCache?
    private var bundle: SkinBundle?
    private var secondaryWindows: [String: SkinWindow] = [:]
    private var player: AVFoundationPlayer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()

        let args = CommandLine.arguments.dropFirst()
        if let skinPath = args.first {
            open(URL(fileURLWithPath: skinPath))
        } else {
            pickSkin()
        }

        // Optional second argument: path to a media file to open immediately.
        if let mediaPath = args.dropFirst().first {
            openMedia(URL(fileURLWithPath: mediaPath))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Skin loading

    private func open(_ url: URL) {
        do {
            let b = try SkinLoader.load(from: url)
            let t = try WMSParser.parse(contentsOf: b.wmsFile)

            guard let view = t.mainView else {
                showError("Skin has no views.")
                return
            }

            let c  = AssetCache.build(from: b, theme: t)
            theme  = t
            cache  = c
            bundle = b

            let p = AVFoundationPlayer()
            player = p

            let canvas = makeCanvas(skinView: view, cache: c, bundle: b)
            let mainId = view.id
            canvas.onCloseView = { [weak self] id in
                if id == mainId { self?.window?.close() }
                else            { self?.closeSecondaryView(id) }
            }
            canvas.setPlayerBackend(p)

            window = SkinWindow(canvas: canvas)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            print("[Skinner] Load error: \(error)")
            showError(error.localizedDescription)
        }
    }

    private func openSecondaryView(_ viewId: String) {
        if let existing = secondaryWindows[viewId] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let skinView = theme?.views.first(where: { $0.id == viewId }),
              let cache, let bundle else { return }
        let canvas = makeCanvas(skinView: skinView, cache: cache, bundle: bundle)
        canvas.onCloseView = { [weak self] id in self?.closeSecondaryView(id) }
        if let player { canvas.setPlayerBackend(player) }
        let win = SkinWindow(canvas: canvas, relativeTo: window)
        secondaryWindows[viewId] = win
        win.makeKeyAndOrderFront(nil)
    }

    private func closeSecondaryView(_ viewId: String) {
        let key = secondaryWindows.keys.first {
            $0 == viewId || viewId.contains($0) || $0.contains(viewId)
        }
        if let key {
            secondaryWindows[key]?.close()
            secondaryWindows[key] = nil
        }
    }

    private func makeCanvas(skinView: SkinView, cache: AssetCache, bundle: SkinBundle) -> SkinCanvasView {
        let canvas = SkinCanvasView(skinView: skinView, cache: cache, bundle: bundle)
        canvas.onOpenView   = { [weak self] id in self?.openSecondaryView(id) }
        canvas.onDroppedURL = { [weak self] url in self?.openMedia(url) }
        return canvas
    }

    // MARK: - Media loading

    private func openMedia(_ url: URL) {
        player?.open(url: url)
    }

    @objc private func pickMediaFromMenu() {
        let panel = NSOpenPanel()
        panel.title               = "Open Media File"
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openMedia(url)
    }

    // MARK: - Skin picker (startup)

    private func pickSkin() {
        let panel = NSOpenPanel()
        panel.title                = "Open WMP Skin"
        panel.allowedContentTypes  = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = true
        panel.canChooseFiles       = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            NSApp.terminate(nil)
            return
        }
        open(url)
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Skinner",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Open Media…",
                                    action: #selector(pickMediaFromMenu),
                                    keyEquivalent: "o"))
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        NSApp.mainMenu = menu
    }

    // MARK: - Error presentation

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText     = "Failed to load skin"
        alert.informativeText  = message
        alert.alertStyle       = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}
