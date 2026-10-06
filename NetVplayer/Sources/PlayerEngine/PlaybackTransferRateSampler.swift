import Foundation

/// Samples completed upstream bytes, independently of ordered delivery to the player.
struct PlaybackTransferRateSampler {
    private let baseline: Int64
    private var samples: [(time: TimeInterval, bytes: Int64)]

    init(receivedBytes: Int64, at time: TimeInterval) {
        baseline = receivedBytes
        samples = [(time, receivedBytes)]
    }

    mutating func sample(receivedBytes: Int64, at time: TimeInterval) -> (receivedBytes: Int64, bytesPerSecond: Int64) {
        let total = max(0, receivedBytes - baseline)
        guard let last = samples.last, time > last.time else { return (total, 0) }
        samples.append((time, receivedBytes))
        while samples.count > 2, samples[1].time <= time - 2 {
            samples.removeFirst()
        }
        let first = samples[0]
        let speed = Double(max(0, receivedBytes - first.bytes)) / (time - first.time)
        return (total, Int64(speed))
    }
}
