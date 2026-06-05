import AppKit
import JavaScriptCore
import Foundation
import UniformTypeIdentifiers
@preconcurrency import Combine

// MARK: - ElementScriptState

struct ElementScriptState {
    var visible: Bool?
    var backgroundImage: String?
    var alphaBlend: Int?
    var enabled: Bool?
    var image: String?       // button/element image override (element.image = "foo.png")
    var value: String?       // text element value set via JS (e.g. metadata.value = ...)
    var down: Bool?          // sticky button toggle state (element.down = true/false/"true"/"false")

    var isEmpty: Bool {
        visible == nil && backgroundImage == nil && alphaBlend == nil
            && enabled == nil && image == nil && value == nil && down == nil
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

    var onOpenView:    ((String) -> Void)?
    var onCloseView:   ((String) -> Void)?
    var onStateChanged: (() -> Void)?

    // Stored once at init time; JS callbacks fire these scripts when backend state changes.
    private let playerCallbacks: Player?
    private let onTimerHandler: String?
    private var backendCancellables = Set<AnyCancellable>()

    var playerBackend: (any PlayerBackend)? {
        didSet {
            backendCancellables.removeAll()
            guard let backend = playerBackend else { return }
            rewirePlayer(backend)
            subscribeToBackend(backend)
        }
    }

    // IDs used by host stubs — element proxies must not overwrite these.
    private static let hostIds: Set<String> = [
        "view", "player", "theme", "mediacenter", "event", "_prefs", "_EP"
    ]

    // MARK: - Init

    init?(skinView: SkinView, bundle: SkinBundle) {
        guard let scriptFile = skinView.scriptFile, !scriptFile.isEmpty else { return nil }
        guard let ctx = JSContext() else { return nil }
        self.context = ctx
        self.playerCallbacks = skinView.player
        self.onTimerHandler = skinView.onTimer

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

        // Fire onLoad, then pump the timer synchronously to fast-forward past intro animations.
        // Stop early when the skin sets view.timerInterval = 0 (its "animation done" signal).
        // Cap at 1024 ticks to handle long intros (Alienware Invader uses 569 frames;
        // Batman Begins needs 155). Wrap each call in JS try/catch so a mid-handler
        // exception doesn't suppress property writes that already ran before the throw.
        if let handler = skinView.onLoad, !handler.isEmpty {
            ctx.evaluateScript("try { \(handler) } catch(e) {}")
        }
        if let interval = skinView.timerInterval, interval > 0,
           let handler  = skinView.onTimer, !handler.isEmpty {
            for _ in 0 ..< 1024 {
                ctx.evaluateScript("try { \(handler) } catch(e) {}")
                if let ti = ctx.evaluateScript("view.timerInterval"),
                   ti.isNumber, ti.toInt32() == 0 { break }
            }
        }
        // Fire any pending onEndMove callbacks so elements whose visibility/enabled
        // state is set by an onEndMove handler (e.g. hideTopBaseButtons) reflect the
        // correct initial state before SkinCanvasView first collects hittable elements.
        fireOnEndMoveCallbacks()
    }

    // MARK: - Script evaluation

    func evaluate(_ script: String) {
        guard !script.isEmpty else { return }
        context.evaluateScript("try { \(script) } catch(e) {}")
    }

    /// Fires the `onEndMove` callback for every proxy whose `_moved` flag was set
    /// by a `moveTo` call during the preceding `evaluate()`.  Must be called after
    /// the script fully completes so state variables (e.g. `eqIsOpen`) are already
    /// in their final toggled state when `onEndMove` reads them.
    func fireOnEndMoveCallbacks() {
        for proxy in proxies.values {
            guard let moved = proxy.forProperty("_moved"), moved.toBool() else { continue }
            proxy.setValue(false, forProperty: "_moved")
            if let s = proxy.forProperty("_onEndMove"),
               let script = s.toString(), !script.isEmpty, script != "undefined" {
                context.evaluateScript("try { \(script) } catch(e) {}")
            }
        }
    }

    /// Reads the current value of `view.timerInterval` from JS.
    /// Returns the interval in milliseconds, or nil if it is 0 / non-numeric.
    var currentTimerInterval: Int? {
        guard let v = context.evaluateScript("view.timerInterval"),
              v.isNumber else { return nil }
        let i = Int(v.toInt32())
        return i > 0 ? i : nil
    }

    /// Fires the view's `onTimer` handler once.  No-op if the skin has no onTimer.
    func fireOnTimer() {
        guard let handler = onTimerHandler, !handler.isEmpty else { return }
        evaluate(handler)
    }

    /// Evaluates a JS expression and returns its value as a CGFloat, or nil if the
    /// expression throws, is not a number, or is NaN. Used to resolve `jscript:`
    /// layout attributes (e.g. `iVolumeSmallLeft`) against the live global scope.
    /// Evaluates a `wmpenabled:` binding and returns whether the element should be enabled/visible.
    func evaluateWmpEnabled(_ expr: String) -> Bool {
        let lower = expr.lowercased()
        if lower.hasPrefix("player.controls.") {
            let method = String(expr.dropFirst("player.controls.".count))
            let safe   = method.replacingOccurrences(of: "'", with: "\\'")
            let result = context.evaluateScript("player.controls.isAvailable('\(safe)')")
            return result?.toBool() ?? false
        }
        guard !expr.isEmpty else { return false }
        let result = context.evaluateScript(
            "(function(){try{return !!((\(expr)));}catch(e){return false;}})()")
        return result?.toBool() ?? false
    }

    func evaluateNumber(_ expr: String) -> CGFloat? {
        guard !expr.isEmpty else { return nil }
        // WMS JScript attribute values often end with ";".  Wrapping as `(EXPR;)` causes
        // a SyntaxError in JavaScriptCore, so strip any trailing semicolons first.
        var cleanExpr = expr.trimmingCharacters(in: .whitespaces)
        while cleanExpr.hasSuffix(";") { cleanExpr = String(cleanExpr.dropLast()) }
        guard !cleanExpr.isEmpty else { return nil }
        let js = "(function(){ try { var _r=(\(cleanExpr)); return (typeof _r==='number'&&!isNaN(_r))?_r:NaN; } catch(e){ return NaN; } })()"
        guard let result = context.evaluateScript(js), result.isNumber else { return nil }
        let v = result.toDouble()
        return v.isNaN ? nil : CGFloat(v)
    }

    /// Evaluates a JS expression and returns the result as a String, or nil on error.
    func evaluateString(_ expr: String) -> String? {
        guard !expr.isEmpty else { return nil }
        var clean = expr.trimmingCharacters(in: .whitespaces)
        while clean.hasSuffix(";") { clean = String(clean.dropLast()) }
        guard !clean.isEmpty else { return nil }
        let js = "(function(){ try { var _r=(\(clean)); return (_r===null||_r===undefined)?null:String(_r); } catch(e){ return null; } })()"
        guard let result = context.evaluateScript(js), !result.isNull, !result.isUndefined else { return nil }
        return result.toString()
    }

    /// Resolves an `AttributeValue` to a displayable string against the live JS context.
    func resolveText(_ av: AttributeValue?) -> String {
        guard let av else { return "" }
        switch av {
        case .literal(let s):    return s
        case .jsExpr(let expr):  return evaluateString(expr) ?? ""
        case .wmpProp(let expr): return evaluateString(expr) ?? ""
        case .wmpEnabled:        return ""
        }
    }

    // MARK: - State readback

    /// Returns true when JS explicitly set `element.backgroundImage = ""` — as opposed to
    /// the property simply never having been written.  Used to hide NSImageViews whose
    /// dynamic GIF was cleared by script (e.g. `centerShutterSub.backgroundImage = ""`).
    func backgroundImageWasCleared(for id: String) -> Bool {
        guard let proxy = proxies[id],
              let v = proxy.forProperty("backgroundImage"),
              !v.isUndefined, !v.isNull, v.isString else { return false }
        let s = v.toString() ?? ""
        return s.isEmpty
    }

    func state(for id: String) -> ElementScriptState? {
        guard let proxy = proxies[id] else { return nil }
        var s = ElementScriptState()
        s.visible         = boolProp(proxy,   "visible")
        s.backgroundImage = stringProp(proxy, "backgroundImage")
        s.alphaBlend      = intProp(proxy,    "alphaBlend")
        s.enabled         = boolProp(proxy,   "enabled")
        s.image           = stringProp(proxy, "image")
        s.value           = stringProp(proxy, "value")
        s.down            = downProp(proxy,   "down")
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
        // moveTo / alphaBlendTo execute synchronously (no animation).
        // onEndMove is NOT fired here — it must fire after the calling script fully
        // completes (so state toggles like eqIsOpen have already been applied).
        // _moved is set as a deferred marker; Swift calls fireOnEndMoveCallbacks()
        // after evaluate() returns.
        var _EP = {
            moveTo: function(x, y, ms) { this.left = x; this.top = y; this._moved = true; },
            alphaBlendTo:        function(v, ms)    { this.alphaBlend = v; },
            setColumnResizeMode: function(col, mode) {},
            appendItem:          function(text)      {},
            presetTitle:         function(i)         { return ""; },
            presetCount:         0
        };
        _EP.moveto       = _EP.moveTo;
        _EP.alphablendto = _EP.alphaBlendTo;
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

        let prefChangeBridge: @convention(block) (String, String) -> Void = { [weak self] key, value in
            MainActor.assumeIsolated {
                if key == "exitview" && value == "true" { self?.onCloseView?(viewId) }
                // WMP preference-relay: buttons call theme.savePreference('remoteCallPl','true') etc.
                // The real player's controlView timer would poll these, but we don't run that view.
                // Instead, call checkRemoteViewStatus() directly — it's defined in the same .js file
                // that mainView loads, so it's available in this context.
                if key.hasPrefix("remotecall") && value == "true" {
                    // controlView normally relays these via its own 100ms timer, where
                    // controlStatus is already false.  Since we call checkRemoteViewStatus()
                    // directly from the pref-change bridge (no timer), force controlStatus
                    // false so the function enters the remote-call processing branch instead
                    // of the player-state-sync branch it takes on the very first invocation.
                    self?.evaluate("controlStatus = false; (typeof checkRemoteViewStatus==='function')&&checkRemoteViewStatus()")
                }
            }
        }
        ctx.setObject(prefChangeBridge, forKeyedSubscript: "_skinnerOnPrefChange" as NSString)

        let openDialogBridge: @convention(block) (String, String) -> String = { _, _ in
            MainActor.assumeIsolated {
                let panel = NSOpenPanel()
                panel.title                = "Open Media File"
                panel.allowedContentTypes  = [.audio, .movie]
                panel.allowsOtherFileTypes = true
                guard panel.runModal() == .OK, let url = panel.url else { return "" }
                return url.absoluteString
            }
        }
        ctx.setObject(openDialogBridge, forKeyedSubscript: "_skinnerOpenDialog" as NSString)

        // view — the current skin view; also aliased by the view's own id.
        // view.close() calls back into Swift so the window manager can close the window.
        let timerInterval = skinView.timerInterval ?? 0
        ctx.evaluateScript("""
        var view = {
            width: \(w), height: \(h),
            minWidth: \(w), minHeight: \(h),
            timerInterval: \(timerInterval),
            title: "",
            backgroundImage: "",
            close:               function() { _skinnerCloseView('\(viewId)'); },
            minimize:            function() {},
            returnToMediaCenter: function() {}
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
                currentPosition:       0,
                currentPositionString: "0:00"
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
            savePreference:  function(k, v) { var lk=k.toLowerCase(), sv=String(v); _prefs[lk]=sv; _skinnerOnPrefChange(lk,sv); },
            savepreference:  function(k, v) { var lk=k.toLowerCase(), sv=String(v); _prefs[lk]=sv; _skinnerOnPrefChange(lk,sv); },
            loadString:      function(res) { return ""; },
            loadstring:      function(res) { return ""; },
            openView:        function(id) { _skinnerOpenView(id); },
            closeView:       function(id) { _skinnerCloseView(id); },
            openDialog:      function(t, f) { return _skinnerOpenDialog(t, f) || null; },
            playSound:       function(f) {},
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

        // EQ stub — properties are later replaced by live getters/setters in rewirePlayer.
        ctx.evaluateScript("""
        var eq = {
            gainLevel1: 0, gainLevel2: 0, gainLevel3: 0, gainLevel4: 0, gainLevel5: 0,
            gainLevel6: 0, gainLevel7: 0, gainLevel8: 0, gainLevel9: 0, gainLevel10: 0,
            enableSplineTension: false, splineTension: 0,
            enabled: true,
            presetCount: 0,
            currentPresetTitle: "",
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
                if let id = sv.base.id { registerProxy(id: id, base: sv.base, onEndMove: sv.onEndMove, in: ctx, reserved: reserved) }
                registerElements(sv.children, in: ctx, reserved: reserved)
            case .button(let b):
                if let id = b.base.id { registerProxy(id: id, base: b.base, in: ctx, reserved: reserved) }
            case .buttonGroup(let bg):
                if let id = bg.base.id { registerProxy(id: id, base: bg.base, in: ctx, reserved: reserved) }
                for elem in bg.elements {
                    if let id = elem.id { registerProxy(id: id, base: nil, in: ctx, reserved: reserved) }
                }
            case .slider(let s):
                if let id = s.base.id { registerProxy(id: id, base: s.base, valueOnChange: s.valueOnChange, in: ctx, reserved: reserved) }
            case .text(let t):
                if let id = t.base.id { registerProxy(id: id, base: t.base, in: ctx, reserved: reserved) }
            case .effects(let e):
                if let id = e.base.id { registerProxy(id: id, base: e.base, in: ctx, reserved: reserved) }
            case .video(let v):
                if let id = v.base.id { registerProxy(id: id, base: v.base, in: ctx, reserved: reserved) }
            case .playlist(let p):
                if let id = p.base.id { registerProxy(id: id, base: p.base, in: ctx, reserved: reserved) }
            case .unknown(_, _, let children):
                registerElements(children, in: ctx, reserved: reserved)
            case .player, .equalizerSettings, .videoSettings:
                break
            }
        }
    }

    private func registerProxy(id: String, base: ElementBase?, onEndMove: String? = nil,
                               valueOnChange: String? = nil, in ctx: JSContext, reserved: Set<String>) {
        guard !id.isEmpty,
              isValidJSIdentifier(id),
              !reserved.contains(id),
              proxies[id] == nil
        else { return }

        guard let proxy = ctx.evaluateScript("Object.create(_EP)") else { return }

        // Seed literal layout properties so sibling-reference JScript expressions
        // (e.g. "view.width - svStub.width - svMain.left") resolve correctly before
        // any onLoad script runs and potentially overwrites them.
        if let b = base {
            if case .literal(let s) = b.left,   let v = Double(s) { proxy.setValue(v,   forProperty: "left") }
            if case .literal(let s) = b.top,    let v = Double(s) { proxy.setValue(v,   forProperty: "top") }
            if case .literal(let s) = b.width,  let v = Double(s) { proxy.setValue(v,   forProperty: "width") }
            if case .literal(let s) = b.height, let v = Double(s) { proxy.setValue(v,   forProperty: "height") }
            if let vis = b.visible, let bv = vis.boolValue        { proxy.setValue(bv,  forProperty: "visible") }
            if let alpha = b.alphaBlend { proxy.setValue(alpha, forProperty: "alphaBlend") }
        }
        if let script = onEndMove, !script.isEmpty { proxy.setValue(script, forProperty: "_onEndMove") }

        proxies[id] = proxy
        ctx.globalObject?.setValue(proxy, forProperty: id)

        // Install a value getter/setter so JS assignments like `seek.value = X` fire
        // the element's value_onchange callback (e.g. DrawTimeNormalView), matching WMP behaviour.
        if let voc = valueOnChange, !voc.isEmpty {
            let cbName = "__voc_\(id)"
            ctx.evaluateScript("function \(cbName)(value) { \(voc) }")
            ctx.evaluateScript("""
            (function(p) {
                var _v = 0;
                Object.defineProperty(p, 'value', {
                    get: function() { return _v; },
                    set: function(v) { _v = v; value = v; \(cbName)(v); },
                    configurable: true
                });
            })(\(id));
            """)
        }
    }

    // MARK: - Live backend wiring

    private func rewirePlayer(_ backend: any PlayerBackend) {
        // Inject Swift closures as _skinner* globals, then rewire the JS player object.
        // All blocks are called synchronously from the main thread (JSContext has no threading here),
        // so MainActor.assumeIsolated is safe.

        let getPlayState: @convention(block) () -> Int = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.playState.rawValue ?? PlayState.stopped.rawValue }
        }
        let getOpenState: @convention(block) () -> Int = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.openState.rawValue ?? OpenState.undefined.rawValue }
        }
        let getURL: @convention(block) () -> String = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.currentItemURL ?? "" }
        }
        let getPosition: @convention(block) () -> Double = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.currentPosition ?? 0 }
        }
        let getPositionString: @convention(block) () -> String = { [weak self] in
            MainActor.assumeIsolated {
                let pos = Int(self?.playerBackend?.currentPosition ?? 0)
                return "\(pos / 60):\(String(format: "%02d", pos % 60))"
            }
        }
        let getDuration: @convention(block) () -> Double = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.duration ?? 0 }
        }
        let getVolume: @convention(block) () -> Int = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.volume ?? 100 }
        }
        let getBalance: @convention(block) () -> Int = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.balance ?? 0 }
        }
        let getMute: @convention(block) () -> Bool = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.isMuted ?? false }
        }
        let getMediaName: @convention(block) () -> String = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.currentItemTitle ?? "" }
        }
        let getItemInfo: @convention(block) (String) -> String = { [weak self] key in
            MainActor.assumeIsolated {
                guard let b = self?.playerBackend else { return "" }
                switch key.lowercased() {
                case "title", "name":   return b.currentItemTitle
                case "sourceurl", "url": return b.currentItemURL
                case "duration":        return String(b.duration)
                default:                return ""
                }
            }
        }
        let isAvailable: @convention(block) (String) -> Bool = { [weak self] cmd in
            MainActor.assumeIsolated {
                guard let b = self?.playerBackend else { return false }
                switch cmd.lowercased() {
                case "play":     return b.openState == .mediaOpen && b.playState != .playing
                case "pause":    return b.playState == .playing
                case "stop":     return b.playState == .playing || b.playState == .paused
                case "next":     return b.canNext
                case "previous": return b.canPrevious
                default:         return false
                }
            }
        }
        let doPlay: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.play() }
        }
        let doPause: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.pause() }
        }
        let doStop: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.stop() }
        }
        let doNext: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.next() }
        }
        let doPrevious: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.previous() }
        }
        let seekTo: @convention(block) (Double) -> Void = { [weak self] pos in
            MainActor.assumeIsolated { self?.playerBackend?.seek(to: pos) }
        }
        let setVolume: @convention(block) (Double) -> Void = { [weak self] v in
            MainActor.assumeIsolated { self?.playerBackend?.volume = Int(v) }
        }
        let setBalance: @convention(block) (Double) -> Void = { [weak self] v in
            MainActor.assumeIsolated { self?.playerBackend?.balance = Int(v) }
        }
        // Skins pass mute as a string (e.g. player.settings.mute='false') — JS coerces
        // non-empty strings to true, so inspect the raw JSValue to handle 'false'/'0' correctly.
        let setMute: @convention(block) (JSValue) -> Void = { [weak self] v in
            MainActor.assumeIsolated {
                let muted: Bool
                if v.isString {
                    let s = v.toString() ?? ""
                    muted = s != "false" && s != "0" && !s.isEmpty
                } else {
                    muted = v.toBool()
                }
                self?.playerBackend?.isMuted = muted
            }
        }
        let openURL: @convention(block) (String) -> Void = { [weak self] urlStr in
            MainActor.assumeIsolated {
                guard let url = URL(string: urlStr) else { return }
                self?.playerBackend?.open(url: url)
            }
        }

        // EQ
        let getEQEnabled: @convention(block) () -> Bool = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.eqEnabled ?? false }
        }
        let setEQEnabled: @convention(block) (Bool) -> Void = { [weak self] v in
            MainActor.assumeIsolated { self?.playerBackend?.eqEnabled = v }
        }
        let getEQGain: @convention(block) (Int) -> Double = { [weak self] band in
            MainActor.assumeIsolated {
                let b = max(1, min(10, band))
                return Double(self?.playerBackend?.eqBands[b - 1].gain ?? 0)
            }
        }
        let setEQGain: @convention(block) (Int, Double) -> Void = { [weak self] band, gain in
            MainActor.assumeIsolated { self?.playerBackend?.setEQGain(Float(gain), band: band) }
        }
        let getEQPresetCount: @convention(block) () -> Int = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.eqPresetCount ?? 0 }
        }
        let getEQPresetTitleAt: @convention(block) (Int) -> String = { [weak self] i in
            MainActor.assumeIsolated { self?.playerBackend?.eqPresetTitle(at: i) ?? "" }
        }
        let eqNextPreset: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.nextEQPreset() }
        }
        let eqPrevPreset: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.previousEQPreset() }
        }
        let eqReset: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.resetEQ() }
        }
        let getEQCurrentPreset: @convention(block) () -> Int = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.currentEQPresetIndex ?? -1 }
        }
        let getEQPresetTitle: @convention(block) () -> String = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.currentEQPresetTitle ?? "" }
        }

        for (name, val): (NSString, Any) in [
            ("_skinnerGetPlayState",      getPlayState),    ("_skinnerGetOpenState",  getOpenState),
            ("_skinnerGetURL",            getURL),          ("_skinnerGetPosition",   getPosition),
            ("_skinnerGetPositionString", getPositionString),
            ("_skinnerGetDuration",  getDuration),  ("_skinnerGetVolume",    getVolume),
            ("_skinnerGetBalance",   getBalance),   ("_skinnerGetMute",      getMute),
            ("_skinnerGetMediaName", getMediaName), ("_skinnerGetItemInfo",  getItemInfo),
            ("_skinnerIsAvailable",  isAvailable),
            ("_skinnerPlay",         doPlay),       ("_skinnerPause",        doPause),
            ("_skinnerStop",         doStop),       ("_skinnerNext",         doNext),
            ("_skinnerPrevious",     doPrevious),   ("_skinnerSeekTo",       seekTo),
            ("_skinnerSetVolume",    setVolume),    ("_skinnerSetBalance",   setBalance),
            ("_skinnerSetMute",      setMute),      ("_skinnerOpenURL",      openURL),
            ("_skinnerGetEQEnabled",      getEQEnabled),   ("_skinnerSetEQEnabled",    setEQEnabled),
            ("_skinnerGetEQGain",         getEQGain),      ("_skinnerSetEQGain",       setEQGain),
            ("_skinnerGetEQPresetCount",   getEQPresetCount),
            ("_skinnerGetEQCurrentPreset", getEQCurrentPreset),
            ("_skinnerGetEQPresetTitleAt", getEQPresetTitleAt),
            ("_skinnerEQNextPreset",       eqNextPreset),   ("_skinnerEQPrevPreset",    eqPrevPreset),
            ("_skinnerEQReset",            eqReset),        ("_skinnerGetEQPresetTitle",getEQPresetTitle),
        ] { context.setObject(val, forKeyedSubscript: name) }

        context.evaluateScript("""
        Object.defineProperty(player, 'playState', { get: function() { return _skinnerGetPlayState(); }, configurable: true });
        Object.defineProperty(player, 'openState', { get: function() { return _skinnerGetOpenState(); }, configurable: true });
        Object.defineProperty(player, 'URL', { get: function() { return _skinnerGetURL(); }, set: function(v) { _skinnerOpenURL(v); }, configurable: true });
        Object.defineProperty(player.currentPlaylist, 'count', {
            get: function() { return _skinnerGetOpenState() == osMediaOpen ? 1 : 0; },
            configurable: true
        });

        player.controls.play        = function()     { _skinnerPlay();             };
        player.controls.pause       = function()     { _skinnerPause();            };
        player.controls.stop        = function()     { _skinnerStop();             };
        player.controls.next        = function()     { _skinnerNext();             };
        player.controls.previous    = function()     { _skinnerPrevious();         };
        player.controls.isAvailable = function(cmd)  { return _skinnerIsAvailable(cmd); };
        Object.defineProperty(player.controls, 'currentPosition', {
            get: function()  { return _skinnerGetPosition(); },
            set: function(v) { _skinnerSeekTo(v);            },
            configurable: true
        });
        Object.defineProperty(player.controls, 'currentPositionString', {
            get: function()  { return _skinnerGetPositionString(); },
            configurable: true
        });

        Object.defineProperty(player.settings, 'volume', {
            get: function()  { return _skinnerGetVolume(); },
            set: function(v) { _skinnerSetVolume(v);       },
            configurable: true
        });
        Object.defineProperty(player.settings, 'balance', {
            get: function()  { return _skinnerGetBalance(); },
            set: function(v) { _skinnerSetBalance(v);        },
            configurable: true
        });
        Object.defineProperty(player.settings, 'mute', {
            get: function()  { return _skinnerGetMute(); },
            set: function(v) { _skinnerSetMute(v);       },
            configurable: true
        });

        Object.defineProperty(player.currentMedia, 'name',      { get: function() { return _skinnerGetMediaName(); }, configurable: true });
        Object.defineProperty(player.currentMedia, 'sourceURL', { get: function() { return _skinnerGetURL();       }, configurable: true });
        Object.defineProperty(player.currentMedia, 'duration',  { get: function() { return _skinnerGetDuration();  }, configurable: true });
        player.currentMedia.getItemInfo = function(k) { return _skinnerGetItemInfo(k); };
        player.currentMedia.getiteminfo = function(k) { return _skinnerGetItemInfo(k); };
        player.currentmedia = player.currentMedia;
        """)

        // Wire the eq object's band gains and preset methods to the live backend.
        context.evaluateScript("""
        (function() {
            for (var _b = 1; _b <= 10; _b++) {
                (function(band) {
                    Object.defineProperty(eq, 'gainLevel' + band, {
                        get: function()  { return _skinnerGetEQGain(band); },
                        set: function(v) { _skinnerSetEQGain(band, v); },
                        configurable: true
                    });
                })(_b);
            }
            Object.defineProperty(eq, 'enabled', {
                get: function()  { return _skinnerGetEQEnabled(); },
                set: function(v) { _skinnerSetEQEnabled(v); },
                configurable: true
            });
            Object.defineProperty(eq, 'currentPreset', {
                get: function() { return _skinnerGetEQCurrentPreset(); },
                configurable: true
            });
            Object.defineProperty(eq, 'currentPresetTitle', {
                get: function() { return _skinnerGetEQPresetTitle(); },
                configurable: true
            });
            eq.presetCount    = _skinnerGetEQPresetCount();
            eq.presetTitle    = function(i) { return _skinnerGetEQPresetTitleAt(i); };
            eq.nextPreset     = function()  { _skinnerEQNextPreset(); };
            eq.previousPreset = function()  { _skinnerEQPrevPreset(); };
            eq.reset          = function()  { _skinnerEQReset(); };
        })();
        """)
    }

    private func subscribeToBackend(_ backend: any PlayerBackend) {
        backend.playStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if let script = self.playerCallbacks?.playStateOnChange { self.evaluate(script) }
                // status_onChange fires whenever playback state (and thus player.status) changes.
                if let script = self.playerCallbacks?.statusOnChange { self.evaluate(script) }
                self.onStateChanged?()
            }
            .store(in: &backendCancellables)

        backend.openStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if let script = self.playerCallbacks?.openStateOnChange { self.evaluate(script) }
                if let script = self.playerCallbacks?.statusOnChange { self.evaluate(script) }
                // currentPlaylist_onChange fires when new media has been opened and is ready.
                if self.playerBackend?.openState == .mediaOpen {
                    if let script = self.playerCallbacks?.currentPlaylistOnChange { self.evaluate(script) }
                }
                self.onStateChanged?()
            }
            .store(in: &backendCancellables)

        backend.positionPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if let script = self.playerCallbacks?.controls?.currentPositionOnChange { self.evaluate(script) }
                self.onStateChanged?()
            }
            .store(in: &backendCancellables)

        backend.eqPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.onStateChanged?()
            }
            .store(in: &backendCancellables)
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

    /// Reads a `down` property that may be a boolean or the strings "true"/"false".
    /// `toBool()` is not used because non-empty strings (including "false") are truthy in JS.
    private func downProp(_ proxy: JSValue, _ key: String) -> Bool? {
        guard let v = proxy.forProperty(key), !v.isUndefined, !v.isNull else { return nil }
        if v.isBoolean { return v.toBool() }
        if v.isString {
            switch v.toString()?.lowercased() {
            case "true":  return true
            case "false": return false
            default:      return nil
            }
        }
        return nil
    }
}
