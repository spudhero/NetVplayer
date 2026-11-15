import Foundation

/// A short-lived snapshot of the real selection currently requesting SDK comments.
/// Contains no media URL, account, request headers or persisted playback history.
public final class AndroidPlaybackMediaContext: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (owner: UUID, source: String, json: String)?

    public init() {}

    @discardableResult
    public func begin(sourceIdentity: String, title: String, episode: String) -> UUID? {
        guard sourceIdentity.count == 64, sourceIdentity.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 2048, episode.utf8.count <= 2048,
              let data = try? JSONSerialization.data(withJSONObject: [
                "title": title, "artist": episode, "sourceIdentity": sourceIdentity
              ]), let json = String(data: data, encoding: .utf8) else { return nil }
        let owner = UUID()
        lock.lock()
        current = (owner, sourceIdentity, json)
        lock.unlock()
        return owner
    }

    public func end(_ owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if current?.owner == owner { current = nil }
    }

    public func snapshot(expectedSource: String? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let current, expectedSource == nil || expectedSource == current.source else { return nil }
        return current.json
    }
}
