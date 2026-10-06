import Foundation
import Models

/// NAS preloads use the same bounded cache as playback. The original SMB read
/// sizes and pipeline remain unchanged; cached head bytes do not require a second
/// network round trip when the next item is opened.
actor SeekableResourceBuffer {
    private struct Key: Hashable { let id: String; let range: Range<Int64> }
    private struct Cached { let key: Key; let data: Data; var accessed: UInt64 }
    private struct Pending { let identity: UUID; let read: PlaybackSharedRead<Data> }
    private var cached: [Key: Cached] = [:]
    private var pending: [Key: Pending] = [:]
    private var closed: Set<String> = []
    private var clock: UInt64 = 0
    private var delivered: [String: Int64] = [:]
    private var received: [String: Int64] = [:]
    private let maximumBytes: Int64

    init(maximumBytes: Int64 = 32 * 1024 * 1024) { self.maximumBytes = max(1, maximumBytes) }

    func read(id: String, range: Range<Int64>, resource: SeekableResource,
              phase: PlaybackTransferPhase = .playback) async throws -> Data {
        try Task.checkCancellation()
        guard !closed.contains(id), range.lowerBound >= 0, range.upperBound <= resource.size else { throw CancellationError() }
        if range.isEmpty { return Data() }
        clock &+= 1
        if let key = cached.keys.first(where: { $0.id == id && $0.range.lowerBound <= range.lowerBound && $0.range.upperBound >= range.upperBound }),
           var item = cached[key] {
            item.accessed = clock; cached[key] = item
            let data = item.data.subdata(in: Int(range.lowerBound - key.range.lowerBound)..<Int(range.upperBound - key.range.lowerBound))
            if phase != .preload { delivered[id, default: 0] += Int64(data.count) }
            return data
        }
        let key = Key(id: id, range: range)
        let entry: Pending
        if let existing = pending[key], !existing.read.isCancelled { entry = existing }
        else {
            entry = Pending(identity: UUID(), read: PlaybackSharedRead(task: Task { try await resource.read(range) }))
            pending[key] = entry
        }
        do {
            let data = try await entry.read.value(phase: phase)
            try Task.checkCancellation()
            guard !closed.contains(id) else { throw CancellationError() }
            guard Int64(data.count) == range.upperBound - range.lowerBound else {
                throw ProxyServerError.emptyUpstreamResponse("bytes=\(range.lowerBound)-\(range.upperBound - 1)")
            }
            if pending[key]?.identity == entry.identity {
                pending.removeValue(forKey: key)
                received[id, default: 0] += Int64(data.count)
                if Int64(data.count) <= maximumBytes {
                    cached[key] = Cached(key: key, data: data, accessed: clock)
                    while totalCachedBytes > maximumBytes,
                          let oldest = cached.values.min(by: { $0.accessed < $1.accessed }) {
                        cached.removeValue(forKey: oldest.key)
                    }
                }
            }
            if phase != .preload { delivered[id, default: 0] += Int64(data.count) }
            return data
        } catch {
            if pending[key]?.identity == entry.identity, !entry.read.hasForegroundReaders {
                pending.removeValue(forKey: key)
            }
            throw error
        }
    }

    var totalCachedBytes: Int64 { cached.values.reduce(0) { $0 + Int64($1.data.count) } }

    func snapshot(id: String) -> RemoteStreamBufferSnapshot {
        .init(chunkRanges: cached.keys.filter { $0.id == id }.map { .init(start: $0.range.lowerBound, end: $0.range.upperBound - 1) }.sorted { $0.start < $1.start },
              inFlightRanges: pending.keys.filter { $0.id == id }.map { .init(start: $0.range.lowerBound, end: $0.range.upperBound - 1) },
              cachedBytes: cached.values.filter { $0.key.id == id }.reduce(0) { $0 + Int64($1.data.count) },
              deliveredBytes: delivered[id, default: 0], receivedBytes: received[id, default: 0])
    }

    func close(id: String) {
        closed.insert(id)
        for (key, entry) in pending where key.id == id { entry.read.cancel() }
        pending = pending.filter { $0.key.id != id }
        cached = cached.filter { $0.key.id != id }
        delivered.removeValue(forKey: id); received.removeValue(forKey: id)
    }
}
