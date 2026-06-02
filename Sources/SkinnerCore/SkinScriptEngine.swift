import JavaScriptCore
import Foundation

// MARK: - ElementScriptState

struct ElementScriptState {
    var visible: Bool?
    var backgroundImage: String?
    var alphaBlend: Int?
    var enabled: Bool?
    var image: String?       // button/element image override (element.image = "foo.png")

    var isEmpty: Bool {
        visible == nil && backgroundImage == nil && alphaBlend == nil
            && enabled == nil && image == nil
    }
}

// MARK: - SkinScriptEngine

/// Loads and evaluates a WMP skin view's JScript at startup, capturing element
/// property overrides that affect initial rendering.
///
/// Phase 1 scope: runs `onLoad` and `onTimer` once synchronously, then exposes
/// the resulting per-element state through `state(for:)`.  All player queries
/// return stopped / no-media values; `moveTo` and `alphaBlendTo` execute
/// immediately (no animation).
@MainActor
final class SkinScriptEngine {

    private let context: JSContext
    private var proxies: [String: JSValue] = [:]

    var onOpenView:  ((String) -> Void)?
    var onCloseView: ((String) -> Void)?

    // IDs used by host stubs — element proxies must not overwrite these.
    private static let hostIds: Set<String> = [
        "view", "player", "theme", "mediacenter", "event", "_prefs", "_EP"
    ]

    // MARK: - Init

    init?(skinView: SkinView, bundle: SkinBundle) {
        guard let scriptFile = skinView.scriptFile, !scriptFile.isEmpty else { return nil }
        guard let ctx = JSContext() else { return nil }
        self.context = ctx

        ctx.exceptionHandler = { _, exc in
            // Skin scripts routinely access WMP internals we don't implement;
            // print and swallow so one bad call doesn't abort the whole script.
            print("[JS] \(exc?.toString() ?? "unknown error")")
        }

        injectConstants(into: ctx)
        injectHostStubs(skinView: skinView, into: ctx)

        // Reserved set = host names + the view's own id (aliased to `view`).
        var reserved = Self.hostIds
        if !skinView.id.isEmpty { reserved.insert(skinView.id) }
        registerElements(skinView.elements, in: ctx, reserved: reserved)

        // Evaluate every local script file listed in scriptFile.
        for name in localScriptNames(from: scriptFile) {
            let url = bundle.assetURL(named: name)
            if let src = loadScript(at: url) {
                ctx.evaluateScript(src)
            } else {
                print("[Skinner] script not found: \(name)")
            }
        }

        // Fire onLoad, then pump the timer up to 256 ticks synchronously.
        // 256 covers frame-sequence intros (Batman Begins needs 155 ticks to
        // complete its 154-frame PNG intro before the main UI becomes visible).
        // Wrap each call in JS try/catch so a mid-handler exception doesn't
        // suppress property writes that already ran before the throw.
        if let handler = skinView.onLoad, !handler.isEmpty {
            ctx.evaluateScript("try { \(handler) } catch(e) {}")
        }
        if let interval = skinView.timerInterval, interval > 0,
           let handler  = skinView.onTimer, !handler.isEmpty {
            for _ in 0 ..< 256 {
                ctx.evaluateScript("try { \(handler) } catch(e) {}")
            }
        }
    }

    // MARK: - Script evaluation

    func evaluate(_ script: String) {
        guard !script.isEmpty else { return }
        context.evaluateScript("try { \(script) } catch(e) {}")
    }

    // MARK: - State readback

    func state(for id: String) -> ElementScriptState? {
        guard let proxy = proxies[id] else { return nil }
        var s = ElementScriptState()
        s.visible         = boolProp(proxy,   "visible")
        s.backgroundImage = stringProp(proxy, "backgroundImage")
        s.alphaBlend      = intProp(proxy,    "alphaBlend")
        s.enabled         = boolProp(proxy,   "enabled")
        s.image           = stringProp(proxy, "image")
        return s.isEmpty ? nil : s
    }

    // MARK: - WMP constants + element prototype

    private func injectConstants(into ctx: JSContext) {
        ctx.evaluateScript("""
        // Open-state constants
        var osUndefined               = 0;
        var osPlaylistChanging        = 1;
        var osPlaylistLocating        = 2;
        var osPlaylistOpening         = 3;
        var osPlaylistOpenNoMedia     = 4;
        var osPlaylistChanged         = 5;
        var osMediaLocating           = 6;
        var osMediaConnecting         = 7;
        var osMediaWaiting            = 8;
        var osMediaOpening            = 9;
        var osMediaOpen               = 13;
        var osBeginCodecAcquisition   = 14;
        var osEndCodecAcquisition     = 15;
        var osBeginLicenseAcquisition = 16;
        var osEndLicenseAcquisition   = 17;
        var osBeginIndividualization  = 18;
        var osEndIndividualization    = 19;
        var osMediaInfoInvalid        = 20;
        var osMediaInfoUnknown        = 21;

        // Play-state constants
        var psUndefined     = 0;
        var psStopped       = 1;
        var psPaused        = 2;
        var psPlaying       = 3;
        var psScanForward   = 4;
        var psScanReverse   = 5;
        var psBuffering     = 6;
        var psWaiting       = 7;
        var psMediaEnded    = 8;
        var psTransitioning = 9;
        var psReady         = 10;
        var psReconnecting  = 11;
        var psLast          = 12;

        // Prototype shared by every element proxy.
        // moveTo / alphaBlendTo execute synchronously (no animation in Phase 1).
        var _EP = {
            moveTo:              function(x, y, ms) { this.left = x; this.top = y; },
            alphaBlendTo:        function(v, ms)    { this.alphaBlend = v; },
            setColumnResizeMode: function(col, mode) {},
            appendItem:          function(text)      {},
            presetTitle:         function(i)         { return ""; },
            presetCount:         0
        };
        """)
    }

    // MARK: - Host stubs

    private func injectHostStubs(skinView: SkinView, into ctx: JSContext) {
        let sizeCtx = LayoutContext(viewWidth: 0, viewHeight: 0)
        let w = Int(sizeCtx.resolve(skinView.width)  ?? 320)
        let h = Int(sizeCtx.resolve(skinView.height) ?? 240)
        let viewId = skinView.id

        // Swift→JS bridges injected first so theme/view stubs can reference them.
        let openBridge: @convention(block) (String) -> Void = { [weak self] id in
            self?.onOpenView?(id)
        }
        ctx.setObject(openBridge, forKeyedSubscript: "_skinnerOpenView" as NSString)

        let closeBridge: @convention(block) (String) -> Void = { [weak self] id in
            self?.onCloseView?(id)
        }
        ctx.setObject(closeBridge, forKeyedSubscript: "_skinnerCloseView" as NSString)

        // view — the current skin view; also aliased by the view's own id.
        // view.close() calls back into Swift so the window manager can close the window.
        ctx.evaluateScript("""
        var view = {
            width: \(w), height: \(h),
            minWidth: \(w), minHeight: \(h),
            timerInterval: 0,
            title: "",
            backgroundImage: "",
            close: function() { _skinnerCloseView('\(viewId)'); }
        };
        """)
        if !skinView.id.isEmpty, isValidJSIdentifier(skinView.id) {
            ctx.evaluateScript("var \(skinView.id) = view;")
        }

        // player — all queries return stopped / no-media values.
        ctx.evaluateScript("""
        var player = {
            playState:  psStopped,
            openState:  osUndefined,
            status:     "",
            URL:        "",
            versionInfo: "12",
            settings: {
                volume: 100, balance: 0, autoStart: false,
                getMode: function(m) { return false; },
                setMode: function(m, v) {}
            },
            controls: {
                isAvailable:     function(cmd) { return false; },
                play:            function() {},
                pause:           function() {},
                stop:            function() {},
                next:            function() {},
                previous:        function() {},
                currentPosition: 0
            },
            currentMedia: {
                name: "", sourceURL: "",
                imageSourceWidth:  0, imageSourceHeight: 0,
                ImageSourceWidth:  0, ImageSourceHeight: 0,
                getItemInfo: function(k) { return ""; },
                getiteminfo: function(k) { return ""; }
            },
            currentPlaylist: {
                name: "", count: 0,
                getItemInfo: function(k) { return ""; },
                getiteminfo: function(k) { return ""; }
            },
            network: { bandwidth: 0, bufferingProgress: 0 },
            dvd:     { isAvailable: function(cmd) { return false; } }
        };
        """)

        // theme — openView/closeView call back into Swift via the bridges above.
        ctx.evaluateScript("""
        var _prefs = {};
        var theme = {
            loadPreference:  function(k) { var v = _prefs[k.toLowerCase()]; return v !== undefined ? v : "--"; },
            loadpreference:  function(k) { var v = _prefs[k.toLowerCase()]; return v !== undefined ? v : "--"; },
            savePreference:  function(k, v) { _prefs[k.toLowerCase()] = String(v); },
            savepreference:  function(k, v) { _prefs[k.toLowerCase()] = String(v); },
            openView:        function(id) { _skinnerOpenView(id); },
            closeView:       function(id) { _skinnerCloseView(id); },
            openDialog:      function(t, f) { return null; },
            currentViewID:   ""
        };
        """)

        ctx.evaluateScript("""
        var mediacenter = {
            effectType: 0, effectPreset: 0,
            videoZoom: 100, videoStretchToFit: true
        };
        var event = { keycode: 0, screenWidth: 1920, screenHeight: 1080 };
        """)

        // WMP system functions normally loaded from res://wmploc.dll — stub them here
        // so skins that call toggleEQ()/togglePL() directly work without the DLL.
        ctx.evaluateScript("""
        function toggleView(viewId, prefKey) {
            var open = theme.loadPreference(prefKey) === 'true';
            if (open) {
                theme.closeView(viewId);
                theme.savePreference(prefKey, 'false');
            } else {
                theme.openView(viewId);
                theme.savePreference(prefKey, 'true');
            }
        }
        function closeView(prefKey) {
            var viewId = prefKey.replace(/Viewer$/i, 'View');
            theme.closeView(viewId);
            theme.savePreference(prefKey, 'false');
        }
        function toggleEQ()    { toggleView('eqView',    'eqViewer'); }
        function togglePL()    { toggleView('plView',    'plViewer'); }
        function toggleVis()   { toggleView('visView',   'visViewer'); }
        function toggleVideo() { toggleView('videoView', 'videoViewer'); }
        """)

        // EQ stub — gives sliders' value_onchange scripts a valid target.
        ctx.evaluateScript("""
        var eq = {
            gainLevel1: 0, gainLevel2: 0, gainLevel3: 0, gainLevel4: 0, gainLevel5: 0,
            gainLevel6: 0, gainLevel7: 0, gainLevel8: 0, gainLevel9: 0, gainLevel10: 0,
            enableSplineTension: false, splineTension: 0,
            presetCount: 0,
            presetTitle:    function(i) { return ""; },
            previousPreset: function()  {},
            nextPreset:     function()  {},
            reset:          function()  {}
        };
        """)
    }

    // MARK: - Element proxy registration

    private func registerElements(_ elements: [SkinElement],
                                   in ctx: JSContext,
                                   reserved: Set<String>) {
        for element in elements {
            switch element {
            case .subview(let sv):
                if let id = sv.base.id { registerProxy(id: id, in: ctx, reserved: reserved) }
                registerElements(sv.children, in: ctx, reserved: reserved)
            case .button(let b):
                if let id = b.base.id { registerProxy(id: id, in: ctx, reserved: reserved) }
            case .buttonGroup(let bg):
                if let id = bg.base.id { registerProxy(id: id, in: ctx, reserved: reserved) }
                for elem in bg.elements {
                    if let id = elem.id { registerProxy(id: id, in: ctx, reserved: reserved) }
                }
            case .slider(let s):
                if let id = s.base.id { registerProxy(id: id, in: ctx, reserved: reserved) }
            case .text(let t):
                if let id = t.base.id { registerProxy(id: id, in: ctx, reserved: reserved) }
            case .effects(let e):
                if let id = e.base.id { registerProxy(id: id, in: ctx, reserved: reserved) }
            case .video(let v):
                if let id = v.base.id { registerProxy(id: id, in: ctx, reserved: reserved) }
            case .playlist(let p):
                if let id = p.base.id { registerProxy(id: id, in: ctx, reserved: reserved) }
            case .unknown(_, _, let children):
                registerElements(children, in: ctx, reserved: reserved)
            case .player, .equalizerSettings, .videoSettings:
                break
            }
        }
    }

    private func registerProxy(id: String, in ctx: JSContext, reserved: Set<String>) {
        guard !id.isEmpty,
              isValidJSIdentifier(id),
              !reserved.contains(id),
              proxies[id] == nil
        else { return }

        guard let proxy = ctx.evaluateScript("Object.create(_EP)") else { return }
        proxies[id] = proxy
        ctx.globalObject?.setValue(proxy, forProperty: id)
    }

    // MARK: - Script loading

    /// Reads a script file, handling UTF-16 LE/BE BOMs and falling back to UTF-8 / Latin-1.
    private func loadScript(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        if data.count >= 2 &&
           ((data[0] == 0xFF && data[1] == 0xFE) ||
            (data[0] == 0xFE && data[1] == 0xFF)) {
            var s = String(data: data, encoding: .utf16) ?? ""
            if s.hasPrefix("\u{FEFF}") { s = String(s.dropFirst()) }
            return s
        }

        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// Splits `"foo.js;res://wmploc.dll/RT_TEXT/#132;"` → `["foo.js"]`.
    private func localScriptNames(from scriptFile: String) -> [String] {
        scriptFile
            .split(separator: ";")
            .map  { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("res://") }
    }

    // MARK: - Helpers

    private func isValidJSIdentifier(_ s: String) -> Bool {
        guard let first = s.first,
              first.isLetter || first == "_" || first == "$" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
    }

    // MARK: - JSValue property readers

    private func boolProp(_ proxy: JSValue, _ key: String) -> Bool? {
        guard let v = proxy.forProperty(key), !v.isUndefined, !v.isNull else { return nil }
        return v.toBool()
    }

    private func stringProp(_ proxy: JSValue, _ key: String) -> String? {
        guard let v = proxy.forProperty(key),
              !v.isUndefined, !v.isNull, v.isString else { return nil }
        let s = v.toString()
        guard let s, !s.isEmpty, s != "undefined" else { return nil }
        return s
    }

    private func intProp(_ proxy: JSValue, _ key: String) -> Int? {
        guard let v = proxy.forProperty(key), !v.isUndefined, !v.isNull else { return nil }
        if v.isNumber { return Int(v.toInt32()) }
        if v.isString, let n = Int(v.toString() ?? "") { return n }
        return nil
    }
}
