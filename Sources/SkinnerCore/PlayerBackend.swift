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
}
