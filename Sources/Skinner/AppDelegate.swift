import AppKit
import SkinnerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: SkinWindow?

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
            let bundle = try SkinLoader.load(from: url)
            let theme  = try WMSParser.parse(contentsOf: bundle.wmsFile)

            guard let view = theme.mainView else {
                showError("Skin has no views.")
                return
            }

            let cache  = AssetCache.build(from: bundle, theme: theme)
            let canvas = SkinCanvasView(skinView: view, cache: cache, bundle: bundle)
            window     = SkinWindow(canvas: canvas)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            print("[Skinner] Load error: \(error)")
            showError(error.localizedDescription)
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
