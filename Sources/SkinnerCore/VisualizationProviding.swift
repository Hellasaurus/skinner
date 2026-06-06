import AppKit

@MainActor
public protocol VisualizationProviding: AnyObject {
    var view: NSView { get }
    func configure(backend: any PlayerBackend, presetPath: URL?)
    func resize(to size: CGSize)
    var currentPresetName: String { get }
    func nextPreset()
    func previousPreset()
}
