import AppKit
import SkinnerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: SkinWindow?
    private var theme:  Theme?
    private var cache:  AssetCache?
    private var bundle: SkinBundle?
    private var secondaryWindows: [String: SkinWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accept a skin path from the command line, e.g.:
        //   swift run Skinner path/to/skin.wmz
        // Falls back to an NSOpenPanel when no argument is given.
        if let path = CommandLine.arguments.dropFirst().first {
            open(URL(fileURLWithPath: path))
        } else {
            pickFile()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Loading

    private func open(_ url: URL) {
        do {
            let b = try SkinLoader.load(from: url)
            let t = try WMSParser.parse(contentsOf: b.wmsFile)

            guard let view = t.mainView else {
                showError("Skin has no views.")
                return
            }

            let c      = AssetCache.build(from: b, theme: t)
            theme      = t
            cache      = c
            bundle     = b

            let canvas = SkinCanvasView(skinView: view, cache: c, bundle: b)
            canvas.onOpenView  = { [weak self] id in self?.openSecondaryView(id) }
            let mainId = view.id
            canvas.onCloseView = { [weak self] id in
                if id == mainId { self?.window?.close() }
                else            { self?.closeSecondaryView(id) }
            }
            window     = SkinWindow(canvas: canvas)
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
        let canvas = SkinCanvasView(skinView: skinView, cache: cache, bundle: bundle)
        canvas.onOpenView  = { [weak self] id in self?.openSecondaryView(id) }
        canvas.onCloseView = { [weak self] id in self?.closeSecondaryView(id) }
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

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title             = "Open WMP Skin"
        panel.allowedContentTypes = []          // accept anything; we validate by extension
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

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText     = "Failed to load skin"
        alert.informativeText  = message
        alert.alertStyle       = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}
