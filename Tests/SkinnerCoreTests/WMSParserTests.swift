import Testing
import Foundation
@testable import SkinnerCore

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Suite("WMSParser — Pulsar (UTF-16 LE, pre-extracted)")
struct WMSParserPulsarTests {

    static let wmsURL = repoRoot
        .appendingPathComponent("skins/Plus! Pulsar/pulsar.wms")

    var theme: Theme {
        get throws { try WMSParser.parse(contentsOf: Self.wmsURL) }
    }

    // MARK: Theme

    @Test func themeID() throws {
        #expect(try theme.id == "mp9_base2")
    }

    @Test func themeHasFourViews() throws {
        #expect(try theme.views.count == 4)
    }

    @Test func viewIDsAreKnown() throws {
        let ids = try theme.views.map(\.id)
        #expect(ids.contains("mainView"))
        #expect(ids.contains("plView"))
        #expect(ids.contains("videoView"))
        #expect(ids.contains("eqView"))
    }

    // MARK: mainView

    var mainView: SkinView {
        get throws { try theme.views.first(where: { $0.id == "mainView" })! }
    }

    @Test func mainViewDimensions() throws {
        let v = try mainView
        #expect(v.width == .literal("364"))
        #expect(v.height == .literal("345"))
    }

    @Test func mainViewTitleBarFalse() throws {
        #expect(try mainView.titleBar == false)
    }

    @Test func mainViewHasPlayer() throws {
        let p = try mainView.player
        #expect(p != nil)
        #expect(p?.playStateOnChange != nil)
    }

    @Test func mainViewPlayerControlsHasBinding() throws {
        let controls = try mainView.player?.controls
        #expect(controls != nil)
        #expect(controls?.currentPositionOnChange?.isEmpty == false)
    }

    @Test func mainViewHasElements() throws {
        #expect(try mainView.elements.count > 5)
    }

    // MARK: Subviews

    @Test func mainBodySubviewParsed() throws {
        let el = try mainView.elements.first {
            if case .subview(let s) = $0, s.base.id == "mainBody" { return true }
            return false
        }
        #expect(el != nil)
        guard case .subview(let body) = el! else { return }
        #expect(body.backgroundImage == "mainback.png")
        #expect(body.base.transparencyColor == "#ff00ff")
    }

    // MARK: ButtonGroups

    @Test func mainButtonsGroupFound() throws {
        let all = try mainView.elements
        let groups = collectButtonGroups(all)
        #expect(groups.count > 0)
    }

    @Test func buttonGroupHasElements() throws {
        let all = try mainView.elements
        let groups = collectButtonGroups(all)
        let anyGroup = groups.first { !$0.elements.isEmpty }
        #expect(anyGroup != nil)
    }

    @Test func pauseElementKind() throws {
        let all = try mainView.elements
        let groups = collectButtonGroups(all)
        let pause = groups.flatMap(\.elements).first { $0.kind == .pause }
        #expect(pause != nil)
    }

    @Test func playElementMappingColor() throws {
        let all = try mainView.elements
        let groups = collectButtonGroups(all)
        let play = groups.flatMap(\.elements).first { $0.kind == .play }
        #expect(play?.mappingColor.isEmpty == false)
    }

    // MARK: CustomSliders

    @Test func volumeSliderParsed() throws {
        let sliders = collectSliders(try mainView.elements)
        let vol = sliders.first { $0.base.id == "volume" }
        #expect(vol != nil)
        #expect(vol?.kind == .custom)
        #expect(vol?.positionImage == "vol_map.png")
        #expect(vol?.value == .wmpProp("player.settings.volume"))
    }

    @Test func seekSliderParsed() throws {
        let sliders = collectSliders(try mainView.elements)
        let seek = sliders.first { $0.base.id == "seekMain" }
        #expect(seek != nil)
        #expect(seek?.kind == .custom)
        #expect(seek?.min == .literal("0"))
    }

    // MARK: TextLabels

    @Test func timeTextParsed() throws {
        let texts = collectTexts(try mainView.elements)
        let time = texts.first { $0.base.id == "time" }
        #expect(time != nil)
        #expect(time?.value == .wmpProp("player.controls.currentPositionString"))
        #expect(time?.scrolling == false)
    }

    @Test func metadataTextScrolling() throws {
        let texts = collectTexts(try mainView.elements)
        let meta = texts.first { $0.base.id == "metadata" }
        #expect(meta != nil)
        #expect(meta?.scrolling == true)
    }

    // MARK: AttributeValue kinds

    @Test func jsExprAttributeParsed() throws {
        let v = try theme.views.first { $0.id == "plView" }!
        let subviews = collectSubviews(v.elements)
        // plcenterBox uses jscript: for width/height
        let box = subviews.first { $0.base.id == "plcenterBox" }
        #expect(box != nil)
        if case .jsExpr(_) = box?.base.width { } else { Issue.record("Expected jsExpr width") }
    }
}

@Suite("WMSParser — Multiple skins (mixed encodings)")
struct WMSParserMultiSkinTests {

    struct SkinCase: CustomTestStringConvertible {
        let name: String
        var testDescription: String { name }
    }

    static let skinDir = repoRoot
        .appendingPathComponent("skins/windowsmediaplayerskinscollection")

    static var skinCases: [SkinCase] {
        let names = ["activate", "9SeriesDefault", "anime", "aoe", "Batman Begins",
                     "Charlies_Angels_Full_Throttle", "Beck", "anemone"]
        return names.map { SkinCase(name: $0) }
    }

    @Test("Parses .wmz without error", arguments: skinCases)
    func parsesWMZ(skin: SkinCase) throws {
        let wmzURL = Self.skinDir.appendingPathComponent("\(skin.name).wmz")
        guard FileManager.default.fileExists(atPath: wmzURL.path) else { return }
        let bundle = try SkinLoader.load(from: wmzURL)
        defer { try? FileManager.default.removeItem(at: bundle.directory) }
        let theme = try WMSParser.parse(contentsOf: bundle.wmsFile)
        #expect(!theme.views.isEmpty)
    }
}

// MARK: - Tree traversal helpers

private func collectButtonGroups(_ elements: [SkinElement]) -> [ButtonGroup] {
    var result: [ButtonGroup] = []
    for el in elements {
        switch el {
        case .buttonGroup(let bg):
            result.append(bg)
        case .subview(let s):
            result += collectButtonGroups(s.children)
        default:
            break
        }
    }
    return result
}

private func collectSliders(_ elements: [SkinElement]) -> [Slider] {
    var result: [Slider] = []
    for el in elements {
        switch el {
        case .slider(let s): result.append(s)
        case .subview(let s): result += collectSliders(s.children)
        default: break
        }
    }
    return result
}

private func collectTexts(_ elements: [SkinElement]) -> [TextLabel] {
    var result: [TextLabel] = []
    for el in elements {
        switch el {
        case .text(let t): result.append(t)
        case .subview(let s): result += collectTexts(s.children)
        default: break
        }
    }
    return result
}

private func collectSubviews(_ elements: [SkinElement]) -> [Subview] {
    var result: [Subview] = []
    for el in elements {
        if case .subview(let s) = el {
            result.append(s)
            result += collectSubviews(s.children)
        }
    }
    return result
}
