import Testing
import Foundation
import AppKit
@testable import SkinnerCore

/// Synthetic-skin snapshot tests: render a minimal hand-built skin and compare the
/// resulting frame against a checked-in golden PNG.
///
/// To (re)generate a golden after an intentional rendering change, run once with
/// `SKINNER_RECORD_GOLDENS=1` set, then commit the updated `golden_frame.png`.
@Suite("Snapshot — synthetic skins")
struct SnapshotTests {

    private static let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/SyntheticSkins")

    @Test @MainActor func transparencyFrameMatchesGolden() throws {
        let fixtureDir = Self.fixturesRoot.appendingPathComponent("transparency")
        let bundle = try SkinLoader.load(from: fixtureDir)
        let theme = try WMSParser.parse(contentsOf: bundle.wmsFile)
        let view = try #require(theme.mainView)
        let cache = AssetCache.build(from: bundle, theme: theme)
        let canvas = SkinCanvasView(skinView: view, cache: cache, bundle: bundle)

        let goldenURL = fixtureDir.appendingPathComponent("golden/golden_frame.png")

        if ProcessInfo.processInfo.environment["SKINNER_RECORD_GOLDENS"] != nil {
            try canvas.snapshotPNG(to: goldenURL)
            return
        }

        let rendered = try #require(canvas.currentFrameImage())

        let golden = try #require(NSImage(contentsOf: goldenURL)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))

        let diff = compareImages(rendered, golden, tolerance: 0)
        #expect(diff.matches, "Rendered frame differs from golden_frame.png: \(diff)")
    }
}
