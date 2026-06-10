import Foundation

// MARK: - Theme

public struct Theme: Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var views: [SkinView]
}

public extension Theme {
    /// The view most likely to be the primary player UI.
    ///
    /// Priority:
    /// 1. First view whose `id` contains "main" (case-insensitive) — covers `mainView`, `mainBox`, `mainModule`, etc.
    /// 2. First view that has a resolvable literal width **and** height — handles skins whose main view has no id.
    /// 3. `views.first` — last resort.
    var mainView: SkinView? {
        if let v = views.first(where: { $0.id.lowercased().contains("main") }) { return v }
        let lc = LayoutContext(viewWidth: 0, viewHeight: 0)
        if let v = views.first(where: { lc.resolve($0.width) != nil && lc.resolve($0.height) != nil }) { return v }
        return views.first
    }

    var eqView:    SkinView? { views.first { $0.id.lowercased().contains("eq") } }
    var plView:    SkinView? { views.first { $0.id.lowercased().contains("pl") } }
    var visView:   SkinView? { views.first { $0.id.lowercased().contains("vis") } }
    var videoView: SkinView? { views.first { $0.id.lowercased().contains("vid") && !$0.id.lowercased().contains("prev") } }
}

// MARK: - SkinView

public struct SkinView: Sendable {
    public var id: String
    public var width: AttributeValue?
    public var height: AttributeValue?
    public var minWidth: AttributeValue?
    public var minHeight: AttributeValue?
    public var titleBar: Bool
    public var resizable: Bool
    public var backgroundColor: String?
    public var backgroundImage: String?
    public var clippingColor: String?
    public var transparencyColor: String?
    public var scriptFile: String?
    public var timerInterval: Int?
    public var onLoad: String?
    public var onClose: String?
    public var onKeyPress: String?
    public var onTimer: String?
    /// The `<player>` declaration — pulled out of `elements` for convenient access.
    public var player: Player?
    public var elements: [SkinElement]
}

// MARK: - Alignment

public enum HorizontalAlignment: String, Sendable, CaseIterable {
    case left, right, stretch, center
}

public enum VerticalAlignment: String, Sendable, CaseIterable {
    case top, bottom, stretch, center
}

// MARK: - ElementBase

/// Ambient attributes shared by every visible element.
public struct ElementBase: Sendable {
    public var id: String?
    public var left: AttributeValue?
    public var top: AttributeValue?
    public var width: AttributeValue?
    public var height: AttributeValue?
    public var zIndex: Int?
    public var alphaBlend: Int?
    public var visible: AttributeValue?
    public var enabled: AttributeValue?
    public var transparencyColor: String?
    public var passThrough: Bool
    public var horizontalAlignment: HorizontalAlignment?
    public var verticalAlignment: VerticalAlignment?
    public var cursor: String?
    public var toolTip: String?
    public var tabStop: Bool?
    public var onClick: String?
    public var onMouseDown: String?
    public var onMouseUp: String?
    public var onMouseOver: String?
    public var onMouseOut: String?
    public var onKeyDown: String?
    public var onKeyUp: String?
}

// MARK: - Subview

public struct Subview: Sendable {
    public var base: ElementBase
    public var backgroundImage: String?
    public var backgroundColor: String?
    public var backgroundTiled: Bool
    public var clippingColor: String?
    public var onEndMove: String?
    public var children: [SkinElement]
}

// MARK: - Button

public enum ButtonKind: Sendable {
    case generic
    case mute
}

public struct Button: Sendable {
    public var base: ElementBase
    public var kind: ButtonKind
    public var image: String?
    public var hoverImage: String?
    public var downImage: String?
    public var disabledImage: String?
    public var hoverDownImage: String?
    public var upToolTip: String?
    public var downToolTip: String?
    public var sticky: Bool
    public var clippingImage: String?
    public var clippingColor: String?
}

// MARK: - ButtonElement

public enum ButtonElementKind: Sendable {
    case play, pause, stop, prev, next, custom
}

public struct ButtonElement: Sendable {
    public var id: String?
    public var mappingColor: String
    public var kind: ButtonElementKind
    public var upToolTip: String?
    public var downToolTip: String?
    public var enabled: AttributeValue?
    public var onClick: String?
    public var onMouseOver: String?
    public var onMouseDown: String?
    public var onMouseUp: String?
    public var onKeyDown: String?
    public var onKeyUp: String?
}

// MARK: - ButtonGroup

public struct ButtonGroup: Sendable {
    public var base: ElementBase
    public var image: String?
    public var hoverImage: String?
    public var downImage: String?
    public var disabledImage: String?
    public var mappingImage: String?
    public var clippingImage: String?
    public var clippingColor: String?
    public var elements: [ButtonElement]
}

// MARK: - Slider

public enum SliderKind: Sendable {
    case generic
    case seek       // implicitly bound to player.controls.currentPosition
    case volume     // implicitly bound to player.settings.volume
    case balance    // implicitly bound to player.settings.balance
    case custom     // sprite-strip: positionImage brightness encodes value
}

public struct Slider: Sendable {
    public var base: ElementBase
    public var kind: SliderKind
    public var min: AttributeValue?
    public var max: AttributeValue?
    public var value: AttributeValue?
    public var valueOnChange: String?
    public var direction: String?
    public var thumbImage: String?
    public var thumbDownImage: String?
    public var backgroundImage: String? // static track backdrop
    public var foregroundImage: String? // fill/progress track
    public var image: String?           // CustomSlider background
    public var positionImage: String?   // CustomSlider brightness-encoded map
    public var borderSize: Int?
    public var slide: Bool?
    public var tiled: Bool
}

// MARK: - TextLabel

public struct TextLabel: Sendable {
    public var base: ElementBase
    public var value: AttributeValue?
    public var fontSize: Int?
    public var fontFace: String?
    public var fontStyle: String?
    public var foregroundColor: String?
    public var hoverForegroundColor: String?
    public var scrolling: Bool
    public var scrollingDelay: Int?
    public var scrollingAmount: Int?
    public var justification: String?
    public var fontSmoothing: Bool
}

// MARK: - Effects

public struct Effects: Sendable {
    public var base: ElementBase
    public var currentEffectType: AttributeValue?
    public var currentEffectTypeOnChange: String?
    public var currentPreset: AttributeValue?
    public var currentPresetOnChange: String?
    public var windowed: Bool
    public var alphaBlend: Int?
    public var clippingColor: String?
    public var clippingImage: String?
}

// MARK: - Video

public struct VideoElement: Sendable {
    public var base: ElementBase
    public var onVideoStart: String?
    public var onVideoEnd: String?
    public var windowless: Bool
    public var fullScreen: Bool
    public var maintainAspectRatio: Bool
    public var stretchToFit: Bool
    public var shrinkToFit: Bool
    public var backgroundColor: String?
}

// MARK: - Playlist

public struct Playlist: Sendable {
    public var base: ElementBase
    public var backgroundColor: String?
    public var foregroundColor: String?
    public var itemPlayingColor: String?
    public var itemPlayingBackgroundColor: String?
    public var disabledItemColor: String?
    public var allowItemEditing: Bool
    public var columnsVisible: Bool
    public var dropDownVisible: Bool
    public var playlistItemsVisible: Bool
    public var columns: String?
}

// MARK: - Player

public struct PlayerControls: Sendable {
    public var currentPositionOnChange: String?
}

public struct Player: Sendable {
    public var playStateOnChange: String?
    public var openStateOnChange: String?
    public var currentPlaylistOnChange: String?
    public var statusOnChange: String?
    public var controls: PlayerControls?
}

// MARK: - EqualizerSettings

public struct EqualizerSettings: Sendable {
    public var id: String?
    public var enable: Bool
    public var enableSplineTension: Bool
    public var splineTension: Int?
}

// MARK: - VideoSettings

public struct VideoSettings: Sendable {
    public var id: String?
    public var enabled: Bool
}

// MARK: - SkinElement

public indirect enum SkinElement: Sendable {
    case subview(Subview)
    case button(Button)
    case buttonGroup(ButtonGroup)
    case slider(Slider)
    case text(TextLabel)
    case effects(Effects)
    case video(VideoElement)
    case playlist(Playlist)
    case player(Player)
    case equalizerSettings(EqualizerSettings)
    case videoSettings(VideoSettings)
    case unknown(tagName: String, attrs: [String: String], children: [SkinElement])
}

// MARK: - Convenience accessors on SkinElement

public extension SkinElement {
    var base: ElementBase? {
        switch self {
        case .subview(let s): return s.base
        case .button(let b): return b.base
        case .buttonGroup(let bg): return bg.base
        case .slider(let s): return s.base
        case .text(let t): return t.base
        case .effects(let e): return e.base
        case .video(let v): return v.base
        case .playlist(let p): return p.base
        case .player, .equalizerSettings, .videoSettings, .unknown: return nil
        }
    }
}
