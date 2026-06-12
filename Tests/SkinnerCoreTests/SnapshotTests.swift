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
        try renderAndCompare(fixture: "transparency")
    }

    /// Regression test for the view-level `clippingColor` mask (`makeBgMask` +
    /// `ctx.clip(to:mask:)` in `draw(_:)`). The fixture's background image is red on
    /// top (the declared `clippingColor`, must be clipped to transparent) and green on
    /// the bottom (must remain visible). `ctx.clip(to:mask:)` mirrors the mask
    /// vertically relative to the destination in this `isFlipped` view, so if
    /// `makeBgMask` ever drops its compensating row-flip again, the red half renders
    /// instead of being clipped (and the green half vanishes).
    @Test @MainActor func viewClippingColorFrameMatchesGolden() throws {
        try renderAndCompare(fixture: "viewclip")
    }

    /// Regression test for buttongroup mapping masks (`makeGrayMask` /
    /// `buildGroupAssets.fullMask`). The fixture's mapping image marks the top half as
    /// a button region (`#00ff00`, matches the `<playelement>`'s `mappingColor`) and
    /// the bottom half as magenta (excluded). The group's display image is blue on top
    /// and yellow on bottom, so the fullMask must keep the blue top and clip the yellow
    /// bottom. Same vertical-mirroring hazard as `viewClippingColorFrameMatchesGolden`.
    @Test @MainActor func groupMaskFrameMatchesGolden() throws {
        try renderAndCompare(fixture: "groupmask")
    }

    @MainActor
    private func renderAndCompare(fixture: String) throws {
        let fixtureDir = Self.fixturesRoot.appendingPathComponent(fixture)
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
        #expect(diff.matches, "Rendered frame for '\(fixture)' differs from golden_frame.png: \(diff)")
    }
}
