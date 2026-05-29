import Foundation

// MARK: - Error

public enum WMSParserError: Error, CustomStringConvertible {
    case encodingFailed
    case parseFailed(String)
    case noThemeElement

    public var description: String {
        switch self {
        case .encodingFailed: return "Could not decode WMS file (tried UTF-16 and UTF-8/Latin-1)"
        case .parseFailed(let msg): return "XML parse error: \(msg)"
        case .noThemeElement: return "No <theme> root element found"
        }
    }
}

// MARK: - Public API

public enum WMSParser {
    public static func parse(contentsOf url: URL) throws -> Theme {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> Theme {
        let xmlData = try normalizeEncoding(data)
        let builder = RawNodeBuilder()
        let xmlParser = XMLParser(data: xmlData)
        xmlParser.delegate = builder
        guard xmlParser.parse() else {
            let msg = xmlParser.parserError?.localizedDescription ?? "unknown error"
            throw WMSParserError.parseFailed(msg)
        }
        guard let root = builder.root, root.tag == "theme" else {
            throw WMSParserError.noThemeElement
        }
        return buildTheme(root)
    }
}

// MARK: - Encoding normalization

private extension WMSParser {
    static func normalizeEncoding(_ data: Data) throws -> Data {
        var str: String

        let hasBOM = data.count >= 2 &&
            ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF))

        if hasBOM {
            guard let s = String(data: data, encoding: .utf16) else {
                throw WMSParserError.encodingFailed
            }
            str = s
        } else {
            guard let s = String(data: data, encoding: .utf8)
                       ?? String(data: data, encoding: .isoLatin1) else {
                throw WMSParserError.encodingFailed
            }
            str = s
        }

        // Strip Unicode BOM if String retained it.
        if str.hasPrefix("\u{FEFF}") { str = String(str.dropFirst()) }

        // Strip XML declaration — encoding will be wrong after conversion to UTF-8.
        if str.hasPrefix("<?xml") {
            if let end = str.range(of: "?>") {
                str = String(str[end.upperBound...])
            }
        }

        // Fix missing whitespace between attributes: `attr="val"next=` → `attr="val" next=`
        // Some WMS files are not strict XML — WMP used a lenient parser.
        // Use negative lookbehind (?<!=) so we only match closing quotes, not opening ones.
        str = str.replacingOccurrences(
            of: #"(?<!=)"([A-Za-z_])"#,
            with: #"" $1"#,
            options: .regularExpression
        )

        return Data(str.utf8)
    }
}

// MARK: - Raw node (internal tree built by XMLParser)

private struct RawNode {
    let tag: String              // lowercased element name
    let attrs: [String: String]  // keys lowercased, values original case
    var children: [RawNode] = []
}

private final class RawNodeBuilder: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var stack: [RawNode] = []
    private(set) var root: RawNode?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String]
    ) {
        var lowered: [String: String] = [:]
        for (k, v) in attributeDict { lowered[k.lowercased()] = v }
        stack.append(RawNode(tag: elementName.lowercased(), attrs: lowered))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard let node = stack.popLast() else { return }
        if stack.isEmpty {
            root = node
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }
}

// MARK: - Attribute accessor helper

private struct Attrs {
    private let d: [String: String]
    init(_ d: [String: String]) { self.d = d }

    func str(_ key: String) -> String? {
        guard let v = d[key], !v.isEmpty else { return nil }
        return v
    }

    func av(_ key: String) -> AttributeValue? {
        str(key).map(AttributeValue.init(_:))
    }

    func bool(_ key: String, default def: Bool = false) -> Bool {
        guard let v = d[key] else { return def }
        return v.lowercased() == "true" || v == "1"
    }

    func boolOpt(_ key: String) -> Bool? {
        d[key].map { $0.lowercased() == "true" || $0 == "1" }
    }

    func int(_ key: String) -> Int? { str(key).flatMap(Int.init) }
}

// MARK: - Theme / View builders

private extension WMSParser {
    static func buildTheme(_ node: RawNode) -> Theme {
        let a = Attrs(node.attrs)
        return Theme(
            id: a.str("id") ?? "",
            title: a.str("title") ?? "",
            author: a.str("author") ?? "",
            views: node.children.filter { $0.tag == "view" }.map(buildView)
        )
    }

    static func buildView(_ node: RawNode) -> SkinView {
        let a = Attrs(node.attrs)
        let playerNode = node.children.first { $0.tag == "player" }
        let elements = node.children
            .filter { $0.tag != "player" }
            .map(buildElement)

        return SkinView(
            id: a.str("id") ?? "",
            width: a.av("width"),
            height: a.av("height"),
            minWidth: a.av("minwidth"),
            minHeight: a.av("minheight"),
            titleBar: a.bool("titlebar", default: true),
            resizable: a.bool("resizable") || a.bool("resizAble") || a.bool("resizable"),
            backgroundColor: a.str("backgroundcolor"),
            scriptFile: a.str("scriptfile"),
            timerInterval: a.int("timerinterval"),
            onLoad: a.str("onload"),
            onClose: a.str("onclose"),
            onKeyPress: a.str("onkeypress"),
            onTimer: a.str("ontimer"),
            player: playerNode.map(buildPlayer),
            elements: elements
        )
    }
}

// MARK: - Element builder (dispatch)

private extension WMSParser {
    static func buildElement(_ node: RawNode) -> SkinElement {
        switch node.tag {
        case "subview":
            return .subview(buildSubview(node))
        case "button", "playbutton", "pausebutton", "stopbutton", "prevbutton", "nextbutton":
            return .button(buildButton(node, kind: .generic))
        case "mutebutton":
            return .button(buildButton(node, kind: .mute))
        case "buttongroup":
            return .buttonGroup(buildButtonGroup(node))
        case "slider":
            return .slider(buildSlider(node, kind: .generic))
        case "customslider":
            return .slider(buildSlider(node, kind: .custom))
        case "seekslider":
            return .slider(buildSlider(node, kind: .seek))
        case "volumeslider":
            return .slider(buildSlider(node, kind: .volume))
        case "balanceslider":
            return .slider(buildSlider(node, kind: .balance))
        case "text":
            return .text(buildText(node))
        case "effects":
            return .effects(buildEffects(node))
        case "video":
            return .video(buildVideo(node))
        case "playlist":
            return .playlist(buildPlaylist(node))
        case "player":
            return .player(buildPlayer(node))
        case "equalizersettings":
            return .equalizerSettings(buildEqualizerSettings(node))
        case "videosettings":
            return .videoSettings(buildVideoSettings(node))
        default:
            return .unknown(
                tagName: node.tag,
                attrs: node.attrs,
                children: node.children.map(buildElement)
            )
        }
    }
}

// MARK: - Per-element builders

private extension WMSParser {

    static func buildBase(_ a: Attrs) -> ElementBase {
        ElementBase(
            id: a.str("id"),
            left: a.av("left"),
            top: a.av("top"),
            width: a.av("width"),
            height: a.av("height"),
            zIndex: a.int("zindex"),
            visible: a.av("visible"),
            enabled: a.av("enabled"),
            transparencyColor: a.str("transparencycolor"),
            passThrough: a.bool("passthrough"),
            horizontalAlignment: a.str("horizontalalignment")
                .flatMap(HorizontalAlignment.init(rawValue:)),
            verticalAlignment: a.str("verticalalignment")
                .flatMap(VerticalAlignment.init(rawValue:)),
            cursor: a.str("cursor"),
            toolTip: a.str("tooltip"),
            tabStop: a.boolOpt("tabstop"),
            onClick: a.str("onclick"),
            onMouseDown: a.str("onmousedown"),
            onMouseUp: a.str("onmouseup"),
            onMouseOver: a.str("onmouseover"),
            onKeyDown: a.str("onkeydown"),
            onKeyUp: a.str("onkeyup")
        )
    }

    static func buildSubview(_ node: RawNode) -> Subview {
        let a = Attrs(node.attrs)
        return Subview(
            base: buildBase(a),
            backgroundImage: a.str("backgroundimage"),
            backgroundColor: a.str("backgroundcolor"),
            backgroundTiled: a.bool("backgroundtiled"),
            onEndMove: a.str("onendmove"),
            children: node.children.map(buildElement)
        )
    }

    static func buildButton(_ node: RawNode, kind: ButtonKind) -> Button {
        let a = Attrs(node.attrs)
        return Button(
            base: buildBase(a),
            kind: kind,
            image: a.str("image"),
            hoverImage: a.str("hoverimage"),
            downImage: a.str("downimage"),
            disabledImage: a.str("disabledimage"),
            hoverDownImage: a.str("hoverdownimage"),
            upToolTip: a.str("uptooltip"),
            downToolTip: a.str("downtooltip"),
            sticky: a.bool("sticky")
        )
    }

    static func buildButtonGroup(_ node: RawNode) -> ButtonGroup {
        let a = Attrs(node.attrs)
        let elements = node.children.compactMap { child -> ButtonElement? in
            buildButtonElement(child)
        }
        return ButtonGroup(
            base: buildBase(a),
            image: a.str("image"),
            hoverImage: a.str("hoverimage"),
            downImage: a.str("downimage"),
            disabledImage: a.str("disabledimage"),
            mappingImage: a.str("mappingimage"),
            elements: elements
        )
    }

    static func buildButtonElement(_ node: RawNode) -> ButtonElement? {
        let kind: ButtonElementKind
        switch node.tag {
        case "playelement":   kind = .play
        case "pauseelement":  kind = .pause
        case "stopelement":   kind = .stop
        case "prevelement":   kind = .prev
        case "nextelement":   kind = .next
        case "buttonelement": kind = .custom
        default: return nil
        }
        let a = Attrs(node.attrs)
        return ButtonElement(
            id: a.str("id"),
            mappingColor: a.str("mappingcolor") ?? "",
            kind: kind,
            upToolTip: a.str("uptooltip"),
            downToolTip: a.str("downtooltip"),
            enabled: a.av("enabled"),
            onClick: a.str("onclick"),
            onMouseOver: a.str("onmouseover"),
            onMouseDown: a.str("onmousedown"),
            onMouseUp: a.str("onmouseup"),
            onKeyDown: a.str("onkeydown"),
            onKeyUp: a.str("onkeyup")
        )
    }

    static func buildSlider(_ node: RawNode, kind: SliderKind) -> Slider {
        let a = Attrs(node.attrs)
        return Slider(
            base: buildBase(a),
            kind: kind,
            min: a.av("min"),
            max: a.av("max"),
            value: a.av("value"),
            valueOnChange: a.str("value_onchange"),
            direction: a.str("direction"),
            thumbImage: a.str("thumbimage"),
            thumbDownImage: a.str("thumbdownimage"),
            foregroundImage: a.str("foregroundimage"),
            image: a.str("image"),
            positionImage: a.str("positionimage"),
            borderSize: a.int("bordersize"),
            slide: a.boolOpt("slide")
        )
    }

    static func buildText(_ node: RawNode) -> TextLabel {
        let a = Attrs(node.attrs)
        // Tolerate the WMS typos: "scrolingDelay" and "scrollingAmmount"
        let delay = a.int("scrollingdelay") ?? a.int("scrolingdelay")
        let amount = a.int("scrollingamount") ?? a.int("scrollingammount")
        return TextLabel(
            base: buildBase(a),
            value: a.av("value"),
            fontSize: a.int("fontsize"),
            fontFace: a.str("fontface"),
            fontStyle: a.str("fontstyle"),
            foregroundColor: a.str("foregroundcolor"),
            hoverForegroundColor: a.str("hoverforegroundcolor"),
            scrolling: a.bool("scrolling"),
            scrollingDelay: delay,
            scrollingAmount: amount,
            justification: a.str("justification"),
            fontSmoothing: a.bool("fontsmoothing")
        )
    }

    static func buildEffects(_ node: RawNode) -> Effects {
        let a = Attrs(node.attrs)
        return Effects(
            base: buildBase(a),
            currentEffectType: a.av("currenteffecttype"),
            currentEffectTypeOnChange: a.str("currenteffecttype_onchange"),
            currentPreset: a.av("currentpreset"),
            currentPresetOnChange: a.str("currentpreset_onchange"),
            windowed: a.bool("windowed", default: true),
            alphaBlend: a.int("alphablend"),
            clippingColor: a.str("clippingcolor")
        )
    }

    static func buildVideo(_ node: RawNode) -> VideoElement {
        let a = Attrs(node.attrs)
        return VideoElement(
            base: buildBase(a),
            onVideoStart: a.str("onvideostart"),
            onVideoEnd: a.str("onvideoend"),
            windowless: a.bool("windowless"),
            fullScreen: a.bool("fullscreen"),
            maintainAspectRatio: a.bool("maintainaspectratio"),
            stretchToFit: a.bool("stretchtofit"),
            shrinkToFit: a.bool("shrinktofit"),
            backgroundColor: a.str("backgroundcolor")
        )
    }

    static func buildPlaylist(_ node: RawNode) -> Playlist {
        let a = Attrs(node.attrs)
        return Playlist(
            base: buildBase(a),
            backgroundColor: a.str("backgroundcolor"),
            foregroundColor: a.str("foregroundcolor") ?? a.str("foregroundcolor"),
            itemPlayingColor: a.str("itemplayingcolor"),
            itemPlayingBackgroundColor: a.str("itemplayingbackgroundcolor"),
            disabledItemColor: a.str("disableditemcolor"),
            allowItemEditing: a.bool("allowitemediting"),
            columnsVisible: a.bool("columnsvisible"),
            dropDownVisible: a.bool("dropdownvisible"),
            playlistItemsVisible: a.bool("playlistitemsvisible"),
            columns: a.str("columns")
        )
    }

    static func buildPlayer(_ node: RawNode) -> Player {
        let a = Attrs(node.attrs)
        let controlsNode = node.children.first { $0.tag == "controls" }
        let controls = controlsNode.map { cn -> PlayerControls in
            let ca = Attrs(cn.attrs)
            return PlayerControls(
                currentPositionOnChange: ca.str("currentposition_onchange")
            )
        }
        return Player(
            playStateOnChange: a.str("playstate_onchange"),
            openStateOnChange: a.str("openstate_onchange"),
            currentPlaylistOnChange: a.str("currentplaylist_onchange"),
            statusOnChange: a.str("status_onchange"),
            controls: controls
        )
    }

    static func buildEqualizerSettings(_ node: RawNode) -> EqualizerSettings {
        let a = Attrs(node.attrs)
        return EqualizerSettings(
            id: a.str("id"),
            enable: a.bool("enable"),
            enableSplineTension: a.bool("enablesplinetension"),
            splineTension: a.int("splinetension")
        )
    }

    static func buildVideoSettings(_ node: RawNode) -> VideoSettings {
        let a = Attrs(node.attrs)
        return VideoSettings(id: a.str("id"), enabled: a.bool("enabled"))
    }
}
