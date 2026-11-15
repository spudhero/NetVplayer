import Foundation

/// Native callbacks only signal this source. Event reads and playback commands
/// remain serialized on MainActor, including the old-event drain before a seek.
final class MPVEventPump: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var signals: Int
        var batches: Int
        var cancelled: Bool
    }

    private let source: DispatchSourceUserDataAdd
    private let lock = NSLock()
    private var state = Snapshot(signals: 0, batches: 0, cancelled: false)

    /// Return true when a full batch needs another turn on the main queue.
    init(drain: @escaping @MainActor @Sendable () -> Bool) {
        source = DispatchSource.makeUserDataAddSource(queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.beginBatch() else { return }
            let more = MainActor.assumeIsolated { drain() }
            if more { self.signal() }
        }
        source.resume()
    }

    func signal() {
        lock.withLock {
            guard !state.cancelled else { return }
            state.signals &+= 1
            source.add(data: 1)
        }
    }

    func cancel() {
        lock.withLock {
            guard !state.cancelled else { return }
            state.cancelled = true
            source.cancel()
        }
    }

    var snapshot: Snapshot { lock.withLock { state } }

    private func beginBatch() -> Bool {
        lock.withLock {
            guard !state.cancelled else { return false }
            state.batches &+= 1
            return true
        }
    }

    deinit { source.cancel() }
}

// The engine retains the pump until native destruction finishes. Neither mpv
// APIs nor engine/UI state may be accessed from this arbitrary callback thread.
let mpvEventWakeupCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
    guard let pointer else { return }
    Unmanaged<MPVEventPump>.fromOpaque(pointer).takeUnretainedValue().signal()
}
