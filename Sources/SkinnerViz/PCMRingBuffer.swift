/// SPSC lock-free ring buffer for visualization PCM data.
/// The audio thread writes; the render thread reads.
/// Occasional torn reads at wrap boundaries are acceptable for visualization purposes.
final class PCMRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var storage:   [Float]
    private var writeHead = 0
    private var readHead  = 0

    init(capacity: Int = 8192) {
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    func write(_ samples: [Float]) {
        for s in samples {
            storage[writeHead] = s
            writeHead = (writeHead + 1) % capacity
        }
    }

    func read(count: Int) -> [Float] {
        let result = (0 ..< count).map { storage[(readHead + $0) % capacity] }
        readHead = (readHead + count) % capacity
        return result
    }
}
