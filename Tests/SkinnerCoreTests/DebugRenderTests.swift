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

    /// Batman's onViewTimer plays a 154-frame intro then loops mainRuntime through
    /// runtime/loop_f1..30 forever without ever setting view.timerInterval = 0. Cycle
    /// detection in the init pump should stop the replay after one pass through that
    /// idle loop (~186 steps, ~10s) rather than running the full 1024-step cap (~52s).
    @Test @MainActor func startupAnimationBatman() throws {
        let wmzURL = URL(fileURLWithPath: "/Users/daniel/repos/skinner/skins/windowsmediaplayerskinscollection/Batman Begins.wmz")
        let bundle = try SkinLoader.load(from: wmzURL)
        let theme = try WMSParser.parse(contentsOf: bundle.wmsFile)
        let view = try #require(theme.mainView)
        let cache = AssetCache.build(from: bundle, theme: theme)
        let canvas = SkinCanvasView(skinView: view, cache: cache, bundle: bundle)
        let engine = try #require(canvas.debugEngine)
        let total = engine.startupSteps.reduce(0.0) { $0 + $1.duration }
        #expect(engine.startupSteps.count < 300)
        #expect(total < 15)
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

    @Test @MainActor func vizCharliesAngels() throws {
        let wmzURL = URL(fileURLWithPath: "/Users/daniel/repos/skinner/skins/windowsmediaplayerskinscollection/Charlies_Angels_Full_Throttle.wmz")
        let bundle = try SkinLoader.load(from: wmzURL)
        let theme = try WMSParser.parse(contentsOf: bundle.wmsFile)
        let view = try #require(theme.mainView)
        let cache = AssetCache.build(from: bundle, theme: theme)
        print("vis.gif mapData:", cache.mapData["vis.gif"]?.width as Any, cache.mapData["vis.gif"]?.height as Any)
        print("visoutline.gif image:", cache.images["visoutline.gif"]?.size as Any)
        let canvas = SkinCanvasView(skinView: view, cache: cache, bundle: bundle)
        canvas.beginStartupAnimation()
        print("vis visible state:", canvas.engine?.state(for: "vis")?.visible as Any)
        print("vis left/top live:", canvas.engine?.liveNumber(id: "vis", property: "left") as Any,
              canvas.engine?.liveNumber(id: "vis", property: "top") as Any)
        print("hasActiveMoves:", canvas.engine?.hasActiveMoves as Any)
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        print("after pump: vis visible state:", canvas.engine?.state(for: "vis")?.visible as Any)
        print("after pump: vis left/top live:", canvas.engine?.liveNumber(id: "vis", property: "left") as Any,
              canvas.engine?.liveNumber(id: "vis", property: "top") as Any)
        print("hasActiveMoves:", canvas.engine?.hasActiveMoves as Any)
        let dir = URL(fileURLWithPath: "/tmp/charlies_viz")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try canvas.snapshotPNG(to: dir.appendingPathComponent("frame.png"))

        // Click the "Visualizer" toggle button (sidebuttonmap.gif, #0000ff region,
        // bbox center (60, 130.5)), offset by "pos" subview's (200,179).
        canvas.debugClick(atViewPoint: CGPoint(x: 260, y: 309.5))
        print("after ShowVis click: vis visible state:", canvas.engine?.state(for: "vis")?.visible as Any)
        print("vis left/top live:", canvas.engine?.liveNumber(id: "vis", property: "left") as Any,
              canvas.engine?.liveNumber(id: "vis", property: "top") as Any)
        try canvas.snapshotPNG(to: dir.appendingPathComponent("frame_visclicked.png"))
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
