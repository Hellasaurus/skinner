@preconcurrency import AVFoundation
@preconcurrency import Combine
import Foundation
import SkinnerCore

@MainActor
public final class AVFoundationPlayer: PlayerBackend {

    // MARK: - State (protocol-visible)

    public private(set) var playState: PlayState = .stopped
    public private(set) var openState: OpenState = .undefined

    public var currentPosition: Double { positionSubject.value }

    public var duration: Double {
        guard let item = avPlayer.currentItem, item.duration.isNumeric else { return 0 }
        return item.duration.seconds
    }

    public var volume: Int {
        get { Int(avPlayer.volume * 100) }
        set { avPlayer.volume = Float(newValue.clamped(to: 0...100)) / 100 }
    }

    public var balance: Int {
        get { _balance }
        set { _balance = newValue.clamped(to: -100...100) }
    }
    private var _balance: Int = 0  // stored; applied via AVAudioEngine in Phase 2b

    public var isMuted: Bool {
        get { avPlayer.isMuted }
        set { avPlayer.isMuted = newValue }
    }

    public private(set) var currentItemTitle: String = ""
    public private(set) var currentItemURL:   String = ""

    public var canNext:     Bool { false }
    public var canPrevious: Bool { false }

    // MARK: - Publishers

    private let playStateSubject = CurrentValueSubject<PlayState, Never>(.stopped)
    private let positionSubject  = CurrentValueSubject<Double,    Never>(0)
    private let openStateSubject = CurrentValueSubject<OpenState, Never>(.undefined)

    public var playStatePublisher: AnyPublisher<PlayState, Never> { playStateSubject.eraseToAnyPublisher() }
    public var positionPublisher:  AnyPublisher<Double,    Never> { positionSubject.eraseToAnyPublisher() }
    public var openStatePublisher: AnyPublisher<OpenState, Never> { openStateSubject.eraseToAnyPublisher() }

    // MARK: - Private

    private let avPlayer = AVPlayer()
    private var globalCancellables = Set<AnyCancellable>()
    private var itemCancellables   = Set<AnyCancellable>()
    private var timeObserverToken: Any?

    // MARK: - Init

    public init() {
        setupPlayerObservation()
    }

    // MARK: - Setup

    private func setupPlayerObservation() {
        avPlayer.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.handleTimeControlStatus(status) }
            .store(in: &globalCancellables)

        // 10 ticks/s  →  0.1s resolution
        let interval = CMTime(value: 1, timescale: 10)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated { self?.positionSubject.send(time.seconds) }
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        itemCancellables.removeAll()

        item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak item] status in
                guard let self, let item else { return }
                if status == .readyToPlay {
                    self.set(openState: .mediaOpen)
                    self.loadMetadata(from: item)
                }
            }
            .store(in: &itemCancellables)

        NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.set(playState: .ended) }
            .store(in: &itemCancellables)
    }

    private func loadMetadata(from item: AVPlayerItem) {
        if let urlAsset = item.asset as? AVURLAsset {
            currentItemURL = urlAsset.url.absoluteString
        }
        Task { @MainActor in
            let metadata = (try? await item.asset.load(.commonMetadata)) ?? []
            let titleItems = AVMetadataItem.metadataItems(
                from: metadata, filteredByIdentifier: .commonIdentifierTitle)
            if let title = try? await titleItems.first?.load(.stringValue) {
                self.currentItemTitle = title
            } else if let urlAsset = item.asset as? AVURLAsset {
                self.currentItemTitle = urlAsset.url.deletingPathExtension().lastPathComponent
            }
        }
    }

    // MARK: - State helpers

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            set(playState: .playing)
        case .paused:
            // Only react if we were playing — stop/open set their own states explicitly
            if playState == .playing { set(playState: .paused) }
        case .waitingToPlayAtSpecifiedRate:
            break
        @unknown default:
            break
        }
    }

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
        let item = AVPlayerItem(url: url)
        observeItem(item)
        avPlayer.replaceCurrentItem(with: item)
        set(openState: .undefined)
        set(playState: .stopped)
        positionSubject.send(0)
        currentItemTitle = ""
        currentItemURL   = ""
    }

    public func play() {
        avPlayer.play()
    }

    public func pause() {
        guard playState == .playing else { return }
        avPlayer.pause()
        set(playState: .paused)
    }

    public func stop() {
        avPlayer.pause()
        seek(to: 0)
        set(playState: .stopped)
    }

    public func next()     {}
    public func previous() {}

    public func seek(to position: Double) {
        let time = CMTime(seconds: position, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
