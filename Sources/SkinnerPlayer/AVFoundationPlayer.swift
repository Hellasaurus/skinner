@preconcurrency import AVFoundation
@preconcurrency import Combine
import Foundation
import SkinnerCore

@MainActor
public final class AVFoundationPlayer: PlayerBackend {

    // MARK: - State (protocol-visible)

    public private(set) var playState: PlayState = .stopped
    public private(set) var openState: OpenState = .undefined

    public var currentPosition: Double {
        guard playerNode.isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid else {
            return _seekPosition
        }
        return _seekPosition + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    public var duration: Double {
        guard let file = currentAudioFile else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    public var volume: Int {
        get { _isMuted ? _preMuteVolume : Int(engine.mainMixerNode.outputVolume * 100) }
        set {
            let v = newValue.clamped(to: 0...100)
            _preMuteVolume = v
            if !_isMuted { engine.mainMixerNode.outputVolume = Float(v) / 100 }
        }
    }

    public var balance: Int {
        get { _balance }
        set { _balance = newValue.clamped(to: -100...100) }
    }
    private var _balance: Int = 0  // stored; not yet applied (deferred)

    public var isMuted: Bool {
        get { _isMuted }
        set {
            _isMuted = newValue
            engine.mainMixerNode.outputVolume = newValue ? 0 : Float(_preMuteVolume) / 100
        }
    }
    private var _isMuted:      Bool = false
    private var _preMuteVolume: Int = 100

    public private(set) var currentItemTitle: String = ""
    public private(set) var currentItemURL:   String = ""

    public var canNext:     Bool { currentIndex < playlist.count - 1 }
    public var canPrevious: Bool { currentIndex > 0 }

    // MARK: - Playlist state

    private var playlist:     [URL] = []
    private var currentIndex: Int   = -1

    // MARK: - Publishers

    private let playStateSubject = CurrentValueSubject<PlayState, Never>(.stopped)
    private let positionSubject  = CurrentValueSubject<Double,    Never>(0)
    private let openStateSubject = CurrentValueSubject<OpenState, Never>(.undefined)

    public var playStatePublisher: AnyPublisher<PlayState, Never> { playStateSubject.eraseToAnyPublisher() }
    public var positionPublisher:  AnyPublisher<Double,    Never> { positionSubject.eraseToAnyPublisher() }
    public var openStatePublisher: AnyPublisher<OpenState, Never> { openStateSubject.eraseToAnyPublisher() }

    // MARK: - Audio engine

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqUnit     = AVAudioUnitEQ(numberOfBands: 10)

    private var currentAudioFile: AVAudioFile?
    private var _seekPosition:    Double = 0
    private var _pausePosition:   Double = 0

    // Incremented on every loadItem; completion handlers ignore stale generations.
    private var loadGeneration: Int = 0

    private var positionTimer: Timer?

    // MARK: - Init

    public init() {
        configureEQBands()
        setupAudioGraph()
    }

    // MARK: - Audio graph

    private func configureEQBands() {
        for (i, freq) in Self.bandFrequencies.enumerated() {
            let band        = eqUnit.bands[i]
            band.filterType = .parametric
            band.frequency  = freq
            band.bandwidth  = 1.0   // 1 octave — matches 10-band spacing
            band.gain       = 0
            band.bypass     = false
        }
        eqUnit.globalGain = 0
    }

    private func setupAudioGraph() {
        engine.attach(playerNode)
        engine.attach(eqUnit)
        engine.connect(playerNode, to: eqUnit,               format: nil)
        engine.connect(eqUnit,     to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 1.0
        try? engine.start()
    }

    // MARK: - Playback helpers

    private func scheduleFrom(_ position: Double) {
        guard let file = currentAudioFile else { return }
        _seekPosition = position
        let generation  = loadGeneration
        let sampleRate  = file.processingFormat.sampleRate
        let startFrame  = AVAudioFramePosition(position * sampleRate)
        let remaining   = file.length - startFrame
        guard remaining > 0 else { return }
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount:    AVAudioFrameCount(remaining),
            at:            nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: Self.makeCompletion(self, generation: generation)
        )
    }

    // nonisolated so the returned closure is not @MainActor-isolated; AVFAudio calls it
    // from its own internal queue, and a @MainActor closure would crash on that thread.
    private nonisolated static func makeCompletion(
        _ player: AVFoundationPlayer,
        generation: Int
    ) -> (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak player] _ in
            Task { @MainActor [weak player] in
                guard let player, player.loadGeneration == generation else { return }
                player.handleItemEnded()
            }
        }
    }

    private func handleItemEnded() {
        stopPositionTimer()
        if canNext {
            currentIndex += 1
            loadItem(at: currentIndex, autoPlay: true)
        } else {
            set(playState: .ended)
        }
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionSubject.send(self?.currentPosition ?? 0) }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
        positionSubject.send(_seekPosition)
    }

    // MARK: - Metadata

    private func loadMetadata(from url: URL) {
        currentItemURL = url.absoluteString
        Task { @MainActor in
            let asset    = AVURLAsset(url: url)
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            let titleItems = AVMetadataItem.metadataItems(
                from: metadata, filteredByIdentifier: .commonIdentifierTitle)
            if let title = try? await titleItems.first?.load(.stringValue), !title.isEmpty {
                self.currentItemTitle = title
            } else {
                self.currentItemTitle = url.deletingPathExtension().lastPathComponent
            }
            self.openStateSubject.send(.mediaOpen)
        }
    }

    // MARK: - State helpers

    private func set(playState new: PlayState) {
        guard playState != new else { return }
        playState = new
        playStateSubject.send(new)
    }

    private func set(openState new: OpenState) {
        guard openState != new else { return }
        openState = new
        openStateSubject.send(new)
    }

    // MARK: - PlayerBackend

    public func open(url: URL) {
        playlist     = [url]
        currentIndex = 0
        loadItem(at: 0, autoPlay: false)
    }

    public func enqueue(_ url: URL) {
        playlist.append(url)
        if currentIndex < 0 {
            currentIndex = 0
            loadItem(at: 0, autoPlay: false)
        }
    }

    public func play() {
        guard currentAudioFile != nil, playState != .playing else { return }
        if !engine.isRunning { try? engine.start() }
        let position = playState == .paused ? _pausePosition : _seekPosition
        playerNode.stop()
        scheduleFrom(position)
        playerNode.play()
        set(playState: .playing)
        startPositionTimer()
    }

    public func pause() {
        guard playState == .playing else { return }
        _pausePosition = currentPosition
        playerNode.stop()
        stopPositionTimer()
        set(playState: .paused)
    }

    public func stop() {
        playerNode.stop()
        _seekPosition  = 0
        _pausePosition = 0
        stopPositionTimer()
        set(playState: .stopped)
    }

    public func next() {
        guard canNext else { return }
        currentIndex += 1
        loadItem(at: currentIndex, autoPlay: true)
    }

    public func previous() {
        guard canPrevious else { return }
        currentIndex -= 1
        loadItem(at: currentIndex, autoPlay: true)
    }

    public func seek(to position: Double) {
        _seekPosition  = position
        _pausePosition = position
        let wasPlaying = playState == .playing
        playerNode.stop()
        scheduleFrom(position)
        if wasPlaying {
            playerNode.play()
        } else {
            positionSubject.send(position)
        }
    }

    private func loadItem(at index: Int, autoPlay: Bool) {
        guard index >= 0, index < playlist.count else { return }
        let url = playlist[index]

        playerNode.stop()
        stopPositionTimer()
        loadGeneration += 1
        _seekPosition    = 0
        _pausePosition   = 0
        currentItemTitle = ""
        currentItemURL   = ""
        currentAudioFile = nil
        set(openState: .undefined)
        set(playState: .stopped)

        guard let file = try? AVAudioFile(forReading: url) else { return }
        currentAudioFile = file
        set(openState: .mediaOpen)
        loadMetadata(from: url)

        if autoPlay {
            if !engine.isRunning { try? engine.start() }
            scheduleFrom(0)
            playerNode.play()
            set(playState: .playing)
            startPositionTimer()
        }
    }

    // MARK: - EQ

    private let eqSubject = PassthroughSubject<Void, Never>()
    public var eqPublisher: AnyPublisher<Void, Never> { eqSubject.eraseToAnyPublisher() }

    public var eqEnabled: Bool {
        get { !eqUnit.bypass }
        set { eqUnit.bypass = !newValue; eqSubject.send() }
    }

    public var eqBands: [EQBand] {
        eqUnit.bands.enumerated().map { i, b in
            EQBand(centerFrequency: Self.bandFrequencies[i], gain: b.gain)
        }
    }

    public func setEQGain(_ gain: Float, band: Int) {
        guard (1...10).contains(band) else { return }
        eqUnit.bands[band - 1].gain = gain.clamped(to: -14...14)
        _currentPresetIndex  = -1
        currentEQPresetTitle = ""
        eqSubject.send()
    }

    public var eqPresetCount: Int { Self.builtInPresets.count }

    public func eqPresetTitle(at index: Int) -> String {
        guard Self.builtInPresets.indices.contains(index) else { return "" }
        return Self.builtInPresets[index].title
    }

    public func applyEQPreset(at index: Int) {
        guard Self.builtInPresets.indices.contains(index) else { return }
        zip(eqUnit.bands, Self.builtInPresets[index].gains).forEach { $0.gain = $1 }
        _currentPresetIndex  = index
        currentEQPresetTitle = Self.builtInPresets[index].title
        eqSubject.send()
    }

    public var currentEQPresetIndex: Int { _currentPresetIndex }
    public private(set) var currentEQPresetTitle: String = ""
    private var _currentPresetIndex: Int = -1

    public func nextEQPreset() {
        let next = _currentPresetIndex + 1
        applyEQPreset(at: next < Self.builtInPresets.count ? next : 0)
    }

    public func previousEQPreset() {
        let prev = _currentPresetIndex - 1
        applyEQPreset(at: prev >= 0 ? prev : Self.builtInPresets.count - 1)
    }

    public func resetEQ() {
        eqUnit.bands.forEach { $0.gain = 0 }
        _currentPresetIndex  = -1
        currentEQPresetTitle = ""
        eqSubject.send()
    }

    static let bandFrequencies: [Float] = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    static let builtInPresets: [(title: String, gains: [Float])] = [
        ("Flat",         [ 0,  0,  0,  0,  0,  0,  0,  0,  0,  0]),
        ("Classical",    [ 0,  0,  0,  0,  0,  0, -3, -3, -3, -4]),
        ("Jazz",         [ 0,  0,  2,  4,  4,  3,  0,  0,  0,  0]),
        ("Pop",          [-1,  0,  2,  4,  4,  4,  2,  0, -1, -1]),
        ("Rock",         [ 5,  4,  2,  1,  0,  0,  2,  3,  5,  5]),
        ("Dance",        [ 5,  4,  1,  0,  0, -2, -3, -2,  0,  0]),
        ("Hip Hop",      [ 5,  4,  2,  3,  0, -1,  0,  0,  2,  2]),
        ("Reggae",       [ 0,  0,  0, -1,  0,  4,  4,  0,  0,  0]),
        ("Electronica",  [ 4,  3,  0, -1, -1,  3,  4,  4,  4,  5]),
        ("Spoken Word",  [-2, -2,  0,  2,  4,  4,  4,  2,  0, -1]),
        ("Treble Boost", [ 0,  0,  0,  0,  0,  2,  3,  4,  5,  6]),
        ("Bass Boost",   [ 6,  5,  4,  2,  0,  0,  0,  0,  0,  0]),
    ]
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
