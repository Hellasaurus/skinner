import Combine
import Foundation

public enum PlayState: Int, Sendable {
    case undefined = 0
    case stopped   = 1
    case paused    = 2
    case playing   = 3
    case ended     = 8
}

public enum OpenState: Int, Sendable {
    case undefined  = 0
    case mediaOpen  = 13
}

// MARK: - EQ

public struct EQBand: Sendable {
    public let centerFrequency: Float   // Hz
    public var gain: Float              // dB, –14…+14
    public init(centerFrequency: Float, gain: Float) {
        self.centerFrequency = centerFrequency
        self.gain = gain
    }
}

// MARK: - PlayerBackend

@MainActor
public protocol PlayerBackend: AnyObject {
    var playState: PlayState { get }
    var openState: OpenState { get }
    var currentPosition: Double { get }   // seconds
    var duration: Double { get }
    var volume: Int { get set }           // 0–100
    var balance: Int { get set }          // -100–100
    var isMuted: Bool { get set }
    var currentItemTitle: String { get }
    var currentItemURL: String { get }
    var canNext: Bool { get }
    var canPrevious: Bool { get }

    var playStatePublisher: AnyPublisher<PlayState, Never> { get }
    var positionPublisher:  AnyPublisher<Double, Never> { get }
    var openStatePublisher: AnyPublisher<OpenState, Never> { get }

    func open(url: URL)
    func play()
    func pause()
    func stop()
    func next()
    func previous()
    func seek(to position: Double)

    // EQ
    var eqEnabled: Bool { get set }
    var eqBands: [EQBand] { get }              // 10 elements; index 0–9 = band 1–10
    func setEQGain(_ gain: Float, band: Int)   // band: 1–10

    var eqPresetCount: Int { get }
    func eqPresetTitle(at index: Int) -> String
    func applyEQPreset(at index: Int)
    var currentEQPresetIndex: Int { get }   // -1 when no preset is active (custom/flat)
    var currentEQPresetTitle: String { get }
    func nextEQPreset()
    func previousEQPreset()
    func resetEQ()

    var eqPublisher: AnyPublisher<Void, Never> { get }

    // PCM tap — handler is called on the audio render thread, must be @Sendable
    @discardableResult
    func installPCMTap(handler: @escaping @Sendable ([Float]) -> Void) -> PCMTapToken
    func removePCMTap(_ token: PCMTapToken)

    // Playlist
    var playlistCount: Int { get }
    var currentPlaylistIndex: Int { get }
    func playlistItemTitle(at index: Int) -> String
    func playlistItemURL(at index: Int) -> String
    func playlistItemDuration(at index: Int) -> Double  // seconds
    func playlistPlay(at index: Int)
    func playlistAdd(url: URL)
    func playlistClear()
    var playlistPublisher: AnyPublisher<Void, Never> { get }
}

public typealias PCMTapToken = AnyObject
