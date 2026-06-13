import Testing
import Foundation
import AppKit
@testable import SkinnerCore

@Suite("Debug render — scratch")
struct DebugRenderTests {
    @Test @MainActor func dumpCFS3() throws {
        let wmzURL = URL(fileURLWithPath: "/Users/daniel/repos/skinner/skins/windowsmediaplayerskinscollection/Combat_Flight_Simulator_3.wmz")
        let bundle = try SkinLoader.load(from: wmzURL)
        let theme = try WMSParser.parse(contentsOf: bundle.wmsFile)
        let view = try #require(theme.mainView)
        let cache = AssetCache.build(from: bundle, theme: theme)
        let canvas = SkinCanvasView(skinView: view, cache: cache, bundle: bundle)
        let dir = URL(fileURLWithPath: "/tmp/cfs3_render")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try canvas.dumpDebugBuffers(to: dir)
        print("dumped to \(dir.path)")
    }

    @Test @MainActor func startupAnimationCFS3() throws {
        let wmzURL = URL(fileURLWithPath: "/Users/daniel/repos/skinner/skins/windowsmediaplayerskinscollection/Combat_Flight_Simulator_3.wmz")
        let bundle = try SkinLoader.load(from: wmzURL)
        let theme = try WMSParser.parse(contentsOf: bundle.wmsFile)
        let view = try #require(theme.mainView)
        let cache = AssetCache.build(from: bundle, theme: theme)
        let canvas = SkinCanvasView(skinView: view, cache: cache, bundle: bundle)
        let dir = URL(fileURLWithPath: "/tmp/cfs3_render")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try canvas.snapshotPNG(to: dir.appendingPathComponent("ready_before_startup.png"))
        canvas.beginStartupAnimation()
        try canvas.snapshotPNG(to: dir.appendingPathComponent("startup_step0.png"))
    }

    @Test @MainActor func clickCFS3() throws {
        let wmzURL = URL(fileURLWithPath: "/Users/daniel/repos/skinner/skins/windowsmediaplayerskinscollection/Combat_Flight_Simulator_3.wmz")
        let bundle = try SkinLoader.load(from: wmzURL)
        let theme = try WMSParser.parse(contentsOf: bundle.wmsFile)
        let view = try #require(theme.mainView)
        let cache = AssetCache.build(from: bundle, theme: theme)
        let canvas = SkinCanvasView(skinView: view, cache: cache, bundle: bundle)
        canvas.debugClick(atViewPoint: CGPoint(x: 291.3, y: 81.65))
    }

    @Test(arguments: [
        "Plus! Professional", "Headspace", "Mandalay", "compact", "cerulean",
        "Vario", "v2_underworld", "circle", "polygon", "Cablemusic",
    ])
    @MainActor func dumpOther(name: String) throws {
        let wmzURL = URL(fileURLWithPath: "/Users/daniel/repos/skinner/skins/windowsmediaplayerskinscollection/\(name).wmz")
        let bundle = try SkinLoader.load(from: wmzURL)
        let theme = try WMSParser.parse(contentsOf: bundle.wmsFile)
        let view = try #require(theme.mainView)
        let cache = AssetCache.build(from: bundle, theme: theme)
        let canvas = SkinCanvasView(skinView: view, cache: cache, bundle: bundle)
        let safe = name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "!", with: "")
        let dir = URL(fileURLWithPath: "/tmp/regress_render")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try canvas.snapshotPNG(to: dir.appendingPathComponent("\(safe).png"))
    }
}
