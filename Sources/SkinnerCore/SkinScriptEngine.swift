import AppKit
import JavaScriptCore
import Foundation
import UniformTypeIdentifiers
@preconcurrency import Combine

// MARK: - SkinPreferences

/// Shared `theme.savePreference`/`loadPreference` store for one skin session.
/// WMP skins use these to relay state (e.g. a color-scheme choice made in the main
/// view) to other views' periodic `onTimer` polls — each view runs its own
/// `SkinScriptEngine`/JSContext, so the store must be shared by reference across them.
public final class SkinPreferences {
    private var values: [String: String] = [:]

    public init() {}

    func load(_ key: String) -> String {
        values[key.lowercased()] ?? "--"
    }

    func save(_ key: String, _ value: String) {
        values[key.lowercased()] = value
    }
}

// MARK: - ElementScriptState

struct ElementScriptState: Equatable {
    var visible: Bool?
    var backgroundImage: String?
    var alphaBlend: Int?
    var enabled: Bool?
    var image: String?       // button/element image override (element.image = "foo.png")
    var hoverImage: String?  // buttongroup/button hoverImage override
    var downImage: String?   // buttongroup/button downImage override
    var disabledImage: String? // buttongroup disabledImage override
    var value: String?       // text element value set via JS (e.g. metadata.value = ...)
    var down: Bool?          // sticky button toggle state (element.down = true/false/"true"/"false")
    var foregroundColor: String? // text element foregroundColor set via JS
    var foregroundImage: String? // slider foregroundImage override (e.g. toggleTexture color swaps)
    var zIndex: Int?         // draw-order override (element.zindex = N), e.g. raising a subview above its parent's background

    var isEmpty: Bool {
        visible == nil && backgroundImage == nil && alphaBlend == nil
            && enabled == nil && image == nil && hoverImage == nil && downImage == nil
            && disabledImage == nil && value == nil && down == nil && foregroundColor == nil
            && foregroundImage == nil && zIndex == nil
    }
}

/// One frame of the skin's real-time startup sequence: the per-element state that
/// was in effect just before an `onTimer` tick fired during the init pump, plus how
/// long (in seconds) that state should be shown before advancing to the next step
/// (or, for the last step, before the converged/final state takes over).
struct StartupAnimationStep {
    let states: [String: ElementScriptState]
    let duration: TimeInterval
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
    // Caches state(for:) results between script evaluations. Drawing/animation ticks
    // call state(for:) several times per element per frame; each lookup crosses the
    // JSC bridge ~7x, which dominated draw() time during 60fps moveTo animations.
    // Invalidated whenever skin script runs (the only thing that can change these props).
    private var stateCache: [String: ElementScriptState?] = [:]
    private let bundleDirectory: URL
    private var soundCache: [String: NSSound] = [:]
    private let preferences: SkinPreferences

    // Captured during the init pump: each step is a (states, duration) snapshot of an
    // onTimer tick's "before" state, used to replay the skin's real-time startup
    // animation (e.g. CFS3's intro gif → shutter-open gif → ready) in the live app.
    private(set) var startupSteps: [StartupAnimationStep] = []
    // When set, state(for:) returns this snapshot instead of the converged live state —
    // used by SkinCanvasView to render a startup-animation step. nil = converged state.
    private var stateOverride: [String: ElementScriptState]?

    var onOpenView:    ((String) -> Void)?
    var onCloseView:   ((String) -> Void)?
    var onStateChanged: (() -> Void)?
    var onStartResize: ((String) -> Void)?
    var onViewResize:  ((CGFloat, CGFloat) -> Void)?

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
        "view", "player", "theme", "mediacenter", "event", "_EP"
    ]

    // MARK: - Init

    init?(skinView: SkinView, bundle: SkinBundle, preferences: SkinPreferences = SkinPreferences()) {
        // Some skins reference a script's functions via inline `JScript:` handlers
        // without ever declaring scriptFile on <VIEW>. WMP falls back to a .js file
        // matching the .wms file's base name in that case — do the same.
        let declaredScriptFile = skinView.scriptFile.flatMap { $0.isEmpty ? nil : $0 }
        guard let scriptFile = declaredScriptFile ?? Self.defaultScriptFile(bundle: bundle) else { return nil }
        guard let ctx = JSContext() else { return nil }
        self.context = ctx
        self.bundleDirectory = bundle.directory
        self.playerCallbacks = skinView.player
        self.onTimerHandler = skinView.onTimer
        self.preferences = preferences

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
            var stepDuration = TimeInterval(interval) / 1000.0
            var seenStates: [[String: ElementScriptState]] = []
            for _ in 0 ..< 1024 {
                let snapshot = snapshotElementStates()
                // Cycle detection: once a tick's state matches one already replayed, every
                // following tick will repeat the same cycle (e.g. Batman's onViewTimer never
                // sets view.timerInterval = 0 — once its 154-frame intro ends it just loops
                // mainRuntime through runtime/loop_f1..30 forever; plView's checkBluePL
                // converges to one repeated state after its first tick). The live Timer
                // (rescheduleTimer) continues that cycle in real time after the replay
                // converges, so stop here rather than replaying it for up to 1024 steps
                // (e.g. ~52s for Batman, ~17min for a 1s poller).
                if seenStates.contains(snapshot) { break }
                seenStates.append(snapshot)
                startupSteps.append(StartupAnimationStep(states: snapshot, duration: stepDuration))
                ctx.evaluateScript("try { \(handler) } catch(e) {}")
                guard let ti = ctx.evaluateScript("view.timerInterval"), ti.isNumber else { break }
                let newInterval = ti.toInt32()
                if newInterval == 0 { break }
                stepDuration = TimeInterval(newInterval) / 1000.0
            }
            // A single step means the state never changed — no real animation to replay.
            if startupSteps.count <= 1 { startupSteps.removeAll() }
        }
        // Allow runtime moveTo calls to animate; init-time moves were already instant.
        ctx.evaluateScript("_skinnerInitializing = false")
        // Fire any pending onEndMove callbacks so elements whose visibility/enabled
        // state is set by an onEndMove handler (e.g. hideTopBaseButtons) reflect the
        // correct initial state before SkinCanvasView first collects hittable elements.
        fireOnEndMoveCallbacks()
    }

    // MARK: - Script evaluation

    func evaluate(_ script: String) {
        guard !script.isEmpty else { return }
        invalidateStateCache()
        context.evaluateScript("try { \(script) } catch(e) {}")
    }

    /// Registers a Swift block as a global JS function or object.
    func registerObject(_ object: Any, forKey key: String) {
        context.setObject(object, forKeyedSubscript: key as NSString)
    }

    /// Fires the `onEndMove` callback for every proxy whose `_moved` flag was set
    /// by a `moveTo` call during the preceding `evaluate()`.  Must be called after
    /// the script fully completes so state variables (e.g. `eqIsOpen`) are already
    /// in their final toggled state when `onEndMove` reads them.
    func fireOnEndMoveCallbacks() {
        // Drain loop: a callback (e.g. SmallScrEndMove) may call moveto() on other
        // elements, setting their _moved flag. Repeat passes until no new flags appear.
        var fired = true
        while fired {
            fired = false
            for proxy in proxies.values {
                guard let moved = proxy.forProperty("_moved"), moved.toBool() else { continue }
                proxy.setValue(false, forProperty: "_moved")
                fired = true
                if let s = proxy.forProperty("_onEndMove"),
                   let script = s.toString(), !script.isEmpty, script != "undefined" {
                    invalidateStateCache()
                    context.evaluateScript("try { \(script) } catch(e) {}")
                }
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

    /// True when any proxy has an in-flight timed moveTo animation.
    var hasActiveMoves: Bool {
        proxies.values.contains { $0.forProperty("_animating")?.toBool() == true }
    }

    /// Stamps `_t0` with the current time for any proxy whose animation has not yet
    /// received a start time (_t0 == -1).  Called from applyScriptChanges() so the
    /// animation clock begins AFTER the expensive setup work (buildBgOpacity, jscript:
    /// evaluations) rather than when moveTo() was called in JS — which could be
    /// 50–150 ms earlier on complex skins, consuming the full 120 ms budget before
    /// the first timer tick fires.  Already-running animations (t0 > 0) are untouched.
    func stampNewAnimationStartTimes() {
        let nowMs = Date().timeIntervalSince1970 * 1000
        for proxy in proxies.values {
            guard proxy.forProperty("_animating")?.toBool() == true else { continue }
            guard let t0 = proxy.forProperty("_t0")?.toDouble(), t0 < 0 else { continue }
            proxy.setValue(nowMs, forProperty: "_t0")
        }
    }

    /// Advances all in-flight timed moveTo animations one step.
    /// Completed moves are marked _moved=true so the caller can then call
    /// fireOnEndMoveCallbacks() to chain into the next hop.
    /// Returns true if any moves are still in progress after this tick.
    func tickMoves() -> Bool {
        let nowMs = Date().timeIntervalSince1970 * 1000
        for proxy in proxies.values {
            guard proxy.forProperty("_animating")?.toBool() == true else { continue }
            guard let t0 = proxy.forProperty("_t0")?.toDouble(), t0 >= 0,
                  let durMs = proxy.forProperty("_ms")?.toDouble(), durMs > 0,
                  let sx = proxy.forProperty("_sx")?.toDouble(),
                  let sy = proxy.forProperty("_sy")?.toDouble(),
                  let tx = proxy.forProperty("_tx")?.toDouble(),
                  let ty = proxy.forProperty("_ty")?.toDouble() else {
                // _t0 < 0 means stampNewAnimationStartTimes hasn't run yet; skip this tick.
                // Any other guard failure signals a corrupt proxy — cancel the animation.
                if proxy.forProperty("_t0")?.toDouble() ?? 0 >= 0 {
                    proxy.setValue(false, forProperty: "_animating")
                }
                continue
            }
            let t = min((nowMs - t0) / durMs, 1.0)
            proxy.setValue(sx + (tx - sx) * t, forProperty: "left")
            proxy.setValue(sy + (ty - sy) * t, forProperty: "top")
            if t >= 1.0 {
                proxy.setValue(false, forProperty: "_animating")
                proxy.setValue(true,  forProperty: "_moved")
            }
        }
        return hasActiveMoves
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

    /// Direct read of `id.<property>` (e.g. an element's live `left`/`top`) without
    /// compiling/evaluating a wrapper script. `left`/`top` are plain stored properties
    /// on the proxy (seeded in registerProxy, updated by moveTo/tickMoves), so a
    /// property lookup is equivalent to `evaluateNumber("\(id).\(property)")` but
    /// orders of magnitude cheaper — this is called for every element on every
    /// recollect(), including every 60fps animation tick.
    func liveNumber(id: String, property: String) -> CGFloat? {
        guard let v = proxies[id]?.forProperty(property), v.isNumber else { return nil }
        let d = v.toDouble()
        return d.isNaN ? nil : CGFloat(d)
    }

    /// Direct write of `id.<property> = value` without compiling/evaluating a wrapper
    /// script — the write counterpart to `liveNumber`. Used to propagate computed
    /// positions/sizes back to proxies (e.g. for sibling jscript: references) during
    /// recollect() without paying per-call JS compilation cost.
    func setLiveNumber(id: String, property: String, value: CGFloat) {
        proxies[id]?.setValue(Double(value), forProperty: property)
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

    /// Updates `view.width` and `view.height` in the JS context after a window resize.
    /// Writes the backing variables directly to avoid triggering the view.width setter
    /// (which would fire the onViewResize callback and cause a resize loop).
    func updateViewSize(width: CGFloat, height: CGFloat) {
        context.evaluateScript("_viewWidth = \(Int(width)); _viewHeight = \(Int(height));")
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
        if let override = stateOverride { return override[id] }
        if let cached = stateCache[id] { return cached }
        guard let proxy = proxies[id] else {
            stateCache[id] = .some(nil)
            return nil
        }
        var s = ElementScriptState()
        s.visible         = boolProp(proxy,   "visible")
        s.backgroundImage = stringProp(proxy, "backgroundImage")
        s.alphaBlend      = intProp(proxy,    "alphaBlend")
        s.enabled         = boolProp(proxy,   "enabled")
        s.image           = stringProp(proxy, "image")
        s.hoverImage      = stringProp(proxy, "hoverImage")
        s.downImage       = stringProp(proxy, "downImage")
        s.disabledImage   = stringProp(proxy, "disabledImage")
        s.value           = stringProp(proxy, "value")
        s.down            = boolProp(proxy,   "down")
        s.foregroundColor = stringProp(proxy, "foregroundColor")
        s.foregroundImage = stringProp(proxy, "foregroundImage")
        s.zIndex          = intProp(proxy,    "zindex")
        let result: ElementScriptState? = s.isEmpty ? nil : s
        stateCache[id] = .some(result)
        return result
    }

    private func invalidateStateCache() {
        stateCache.removeAll()
    }

    /// Snapshots state(for:) across every registered element, for capture into a
    /// StartupAnimationStep. Must run with stateOverride == nil (only called from
    /// the init pump, before any override is installed).
    private func snapshotElementStates() -> [String: ElementScriptState] {
        invalidateStateCache()
        var result: [String: ElementScriptState] = [:]
        for id in proxies.keys {
            if let s = state(for: id) { result[id] = s }
        }
        return result
    }

    /// Overrides state(for:) to replay a captured startup-animation step (or, when
    /// nil, restore the converged live state). See `startupSteps`.
    func setStartupOverride(_ states: [String: ElementScriptState]?) {
        stateOverride = states
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

        // True during the synchronous onLoad/onTimer init pump so moveTo is instant.
        // Cleared before runtime so user-triggered moveTo calls animate.
        var _skinnerInitializing = true;

        // Prototype shared by every element proxy.
        // During init (_skinnerInitializing) or when ms<=0: moves are instant and
        // _moved is set immediately so fireOnEndMoveCallbacks() handles them.
        // At runtime with ms>0: _animating is set and Swift drives interpolation via
        // tickMoves(), firing _moved/onEndMove when each move completes.
        var _EP = {
            moveTo: function(x, y, ms) {
                if (!ms || ms <= 0 || _skinnerInitializing) {
                    this.left = x; this.top = y; this._moved = true;
                } else {
                    this._sx = this.left || 0; this._sy = this.top || 0;
                    this._tx = x; this._ty = y; this._ms = ms;
                    this._t0 = -1;
                    this._animating = true;
                }
            },
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
            print("[Skinner] _skinnerCloseView('\(id)') fired; onCloseView=\(self?.onCloseView != nil)")
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
                    self?.evaluate("controlStatus = false; (typeof checkRemoteViewStatus==='function')&&checkRemoteViewStatus(); (typeof checkViewStatus==='function')&&checkViewStatus()")
                }
            }
        }
        ctx.setObject(prefChangeBridge, forKeyedSubscript: "_skinnerOnPrefChange" as NSString)

        let loadPrefBridge: @convention(block) (String) -> String = { [weak self] key in
            MainActor.assumeIsolated { self?.preferences.load(key) ?? "--" }
        }
        ctx.setObject(loadPrefBridge, forKeyedSubscript: "_skinnerLoadPref" as NSString)

        let savePrefBridge: @convention(block) (String, String) -> Void = { [weak self] key, value in
            MainActor.assumeIsolated { self?.preferences.save(key, value) }
        }
        ctx.setObject(savePrefBridge, forKeyedSubscript: "_skinnerSavePref" as NSString)

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

        let startResizeBridge: @convention(block) (String) -> Void = { [weak self] mode in
            self?.onStartResize?(mode)
        }
        ctx.setObject(startResizeBridge, forKeyedSubscript: "_skinnerStartResize" as NSString)

        let viewSizeBridge: @convention(block) (Double, Double) -> Void = { [weak self] w, h in
            self?.onViewResize?(CGFloat(w), CGFloat(h))
        }
        ctx.setObject(viewSizeBridge, forKeyedSubscript: "_skinnerSetViewSize" as NSString)

        let playSoundBridge: @convention(block) (String) -> Void = { [weak self] filename in
            guard let self else { return }
            // Don't play real audio when running under `swift test` — skins click
            // buttons that trigger onClick sounds, which would otherwise play over
            // the system audio output during a headless test run.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            let lower = filename.lowercased()
            let master: NSSound
            if let cached = self.soundCache[lower] {
                master = cached
            } else {
                let url = self.bundleDirectory.appendingPathComponent(filename)
                guard let loaded = NSSound(contentsOf: url, byReference: false) else { return }
                self.soundCache[lower] = loaded
                master = loaded
            }
            // Copy so concurrent/overlapping plays each have their own playback state.
            (master.copy() as? NSSound)?.play()
        }
        ctx.setObject(playSoundBridge, forKeyedSubscript: "_skinnerPlaySound" as NSString)

        // view — the current skin view; also aliased by the view's own id.
        // view.close() calls back into Swift so the window manager can close the window.
        let timerInterval = skinView.timerInterval ?? 0
        let minW = Int(sizeCtx.resolve(skinView.minWidth)  ?? CGFloat(w))
        let minH = Int(sizeCtx.resolve(skinView.minHeight) ?? CGFloat(h))
        ctx.evaluateScript("""
        var _viewTimerInterval = \(timerInterval);
        var _viewWidth  = \(w);
        var _viewHeight = \(h);
        var view = {
            get width()  { return _viewWidth;  },
            set width(v) { if (v !== _viewWidth)  { _viewWidth  = v; _skinnerSetViewSize(v, _viewHeight); } },
            get height() { return _viewHeight; },
            set height(v){ if (v !== _viewHeight) { _viewHeight = v; _skinnerSetViewSize(_viewWidth, v);  } },
            minWidth: \(minW), minHeight: \(minH),
            get timerInterval()  { return _viewTimerInterval; },
            set timerInterval(v) { _viewTimerInterval = v; },
            get TimerInterval()  { return _viewTimerInterval; },
            set TimerInterval(v) { _viewTimerInterval = v; },
            title: "",
            backgroundImage: "",
            close:               function() { _skinnerCloseView('\(viewId)'); },
            minimize:            function() {},
            returnToMediaCenter: function() {},
            size:                function(mode) { _skinnerStartResize(mode); }
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
        var theme = {
            loadPreference:  function(k) { return _skinnerLoadPref(String(k)); },
            loadpreference:  function(k) { return _skinnerLoadPref(String(k)); },
            savePreference:  function(k, v) { var sv=String(v); _skinnerSavePref(String(k), sv); _skinnerOnPrefChange(String(k).toLowerCase(), sv); },
            savepreference:  function(k, v) { var sv=String(v); _skinnerSavePref(String(k), sv); _skinnerOnPrefChange(String(k).toLowerCase(), sv); },
            loadString:      function(res) { return ""; },
            loadstring:      function(res) { return ""; },
            openView:        function(id) { _skinnerOpenView(id); },
            closeView:       function(id) { _skinnerCloseView(id); },
            openDialog:      function(t, f) { return _skinnerOpenDialog(t, f) || null; },
            playSound:       function(f) { _skinnerPlaySound(String(f)); },
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
                if let id = b.base.id { registerProxy(id: id, base: b.base, onEndMove: b.onEndMove, in: ctx, reserved: reserved) }
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
            // WMS elements with no `visible` attribute are visible by default. Seed the
            // proxy's `visible` to `true` in that case so JS reads like `!mainIntro.visible`
            // (CFS3's mainTimer) see `true`/`false` instead of `undefined` (where `!undefined`
            // is `true`, sending the script down the wrong branch). Elements with a dynamic
            // `visible` (wmpenabled:/jscript:) are left unset so elementIsHidden() falls
            // through to evaluating the WMS binding live instead of this static seed.
            if let vis = b.visible {
                if let bv = vis.boolValue { proxy.setValue(bv, forProperty: "visible") }
            } else {
                proxy.setValue(true, forProperty: "visible")
            }
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

        // Playlist
        let getPlaylistCount: @convention(block) () -> Int = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.playlistCount ?? 0 }
        }
        let getPlaylistIndex: @convention(block) () -> Int = { [weak self] in
            MainActor.assumeIsolated { self?.playerBackend?.currentPlaylistIndex ?? -1 }
        }
        let getPlaylistItemTitle: @convention(block) (Int) -> String = { [weak self] i in
            MainActor.assumeIsolated { self?.playerBackend?.playlistItemTitle(at: i) ?? "" }
        }
        let getPlaylistItemURL: @convention(block) (Int) -> String = { [weak self] i in
            MainActor.assumeIsolated { self?.playerBackend?.playlistItemURL(at: i) ?? "" }
        }
        let getPlaylistItemDuration: @convention(block) (Int) -> Double = { [weak self] i in
            MainActor.assumeIsolated { self?.playerBackend?.playlistItemDuration(at: i) ?? 0 }
        }
        let playlistPlayAt: @convention(block) (Int) -> Void = { [weak self] i in
            MainActor.assumeIsolated { self?.playerBackend?.playlistPlay(at: i) }
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
            ("_skinnerGetPlaylistCount",       getPlaylistCount),
            ("_skinnerGetPlaylistIndex",       getPlaylistIndex),
            ("_skinnerGetPlaylistItemTitle",   getPlaylistItemTitle),
            ("_skinnerGetPlaylistItemURL",     getPlaylistItemURL),
            ("_skinnerGetPlaylistItemDuration",getPlaylistItemDuration),
            ("_skinnerPlaylistPlayAt",         playlistPlayAt),
        ] { context.setObject(val, forKeyedSubscript: name) }

        context.evaluateScript("""
        Object.defineProperty(player, 'playState', { get: function() { return _skinnerGetPlayState(); }, configurable: true });
        Object.defineProperty(player, 'openState', { get: function() { return _skinnerGetOpenState(); }, configurable: true });
        Object.defineProperty(player, 'URL', { get: function() { return _skinnerGetURL(); }, set: function(v) { _skinnerOpenURL(v); }, configurable: true });
        Object.defineProperty(player.currentPlaylist, 'count', {
            get: function() { return _skinnerGetPlaylistCount(); },
            configurable: true
        });
        Object.defineProperty(player.currentPlaylist, 'Count', {
            get: function() { return _skinnerGetPlaylistCount(); },
            configurable: true
        });
        player.currentPlaylist.item = function(i) {
            var idx = i;
            return {
                getItemInfo: function(k) {
                    var key = k.toLowerCase();
                    if (key === 'title' || key === 'name') return _skinnerGetPlaylistItemTitle(idx);
                    if (key === 'sourceurl' || key === 'url') return _skinnerGetPlaylistItemURL(idx);
                    if (key === 'duration') return String(_skinnerGetPlaylistItemDuration(idx));
                    return '';
                },
                getiteminfo: function(k) { return this.getItemInfo(k); },
                sourceURL:   _skinnerGetPlaylistItemURL(idx),
                name:        _skinnerGetPlaylistItemTitle(idx),
                duration:    _skinnerGetPlaylistItemDuration(idx)
            };
        };
        player.currentPlaylist.getItemInfo = function(k) { return ''; };
        player.currentPlaylist.getiteminfo = function(k) { return ''; };

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
        Object.defineProperty(player.controls, 'currentposition', {
            get: function()  { return _skinnerGetPosition(); },
            set: function(v) { _skinnerSeekTo(v);            },
            configurable: true
        });
        Object.defineProperty(player.controls, 'currentPositionString', {
            get: function()  { return _skinnerGetPositionString(); },
            configurable: true
        });
        Object.defineProperty(player.controls, 'currentpositionstring', {
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

        // Fire initial state callbacks so the skin's JS state machine reflects the current
        // backend state immediately. Without this, if music was already playing when the skin
        // loaded, playStateOnChange never fires (no state change occurs), and variables like
        // visMark stay in their onLoad-only initial values instead of adjusting for "playing".
        if let script = playerCallbacks?.playStateOnChange, !script.isEmpty { evaluate(script) }
        if let script = playerCallbacks?.openStateOnChange,  !script.isEmpty { evaluate(script) }

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

        backend.playlistPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if let script = self.playerCallbacks?.currentPlaylistOnChange { self.evaluate(script) }
                self.onStateChanged?()
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

    /// Looks for a `.js` file in the bundle directory whose base name matches the
    /// `.wms` file's base name, case-insensitively (e.g. "Charlies Angels.wms" →
    /// "charlies Angels.js"). Returns nil if no such file exists.
    private static func defaultScriptFile(bundle: SkinBundle) -> String? {
        let wantedBase = bundle.wmsFile.deletingPathExtension().lastPathComponent.lowercased()
        let entries = try? FileManager.default.contentsOfDirectory(atPath: bundle.directory.path)
        return entries?.first {
            $0.lowercased() == "\(wantedBase).js"
        }
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

    /// Reads a boolean property that scripts may set as either a real boolean or the
    /// strings "true"/"false" (e.g. `cover.visible="false"`). `toBool()` is not used
    /// directly because non-empty strings (including "false") are truthy in JS.
    private func boolProp(_ proxy: JSValue, _ key: String) -> Bool? {
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
