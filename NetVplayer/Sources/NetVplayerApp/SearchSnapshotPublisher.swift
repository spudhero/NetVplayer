import Foundation
import ApplicationCore

/// First output and first useful output are immediate. A real trailing timer flushes later changes.
@MainActor
final class SearchSnapshotPublisher {
    private let interval: Duration
    private let publish: (ContentSearchState) -> Void
    private var pending: ContentSearchState?
    private var timer: Task<Void, Never>?
    private var published = false
    private var publishedUseful = false

    init(interval: Duration = .milliseconds(120), publish: @escaping (ContentSearchState) -> Void) {
        self.interval = interval
        self.publish = publish
    }

    func submit(_ state: ContentSearchState) {
        pending = state
        let useful = state.results.contains { !$0.vods.isEmpty }
        if !published || (!publishedUseful && useful) {
            publishedUseful = useful
            flush()
        } else if timer == nil {
            timer = Task { @MainActor [weak self, interval] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    func flush() {
        timer?.cancel(); timer = nil
        guard let state = pending else { return }
        pending = nil
        published = true
        publish(state)
    }

    func cancel() {
        timer?.cancel(); timer = nil; pending = nil
    }
}
