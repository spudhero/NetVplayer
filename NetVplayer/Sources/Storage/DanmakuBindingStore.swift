import Foundation
import CryptoKit
import Models

public final class DanmakuBindingStore: @unchecked Sendable {
    public static let shared = DanmakuBindingStore()
    private struct Entry: Codable { var key: String; var attachment: DanmakuAttachment; var updatedAt: Date }
    private let storage: StorageManager
    private let lock = NSLock()
    private var entries: [Entry]
    private let filename = "danmaku_bindings_v1.json"

    public init(storage: StorageManager = .shared) {
        self.storage = storage
        entries = (try? storage.loadBounded([Entry].self, from: "danmaku_bindings_v1.json", maximumBytes: 1_048_576)) ?? []
        entries = Array(entries.sorted { $0.updatedAt > $1.updatedAt }.prefix(512))
    }

    public static func key(for spec: PlaySpec) -> String? {
        guard let vodID = spec.metadata["vod.id"], !vodID.isEmpty,
              let episode = spec.metadata["vod.episodeURL"], !episode.isEmpty else { return nil }
        let episodeKey = HistoryPersistencePolicy.episodeKey(siteKey: spec.siteKey, vodId: vodID, vodFlag: spec.flag, episodeURL: episode)
        let material = [spec.metadata["library.sourceFingerprint"] ?? "", spec.siteKey, vodID, spec.flag, episodeKey]
        let data = (try? JSONEncoder().encode(material)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func attachment(for spec: PlaySpec) -> DanmakuAttachment? {
        guard let key = Self.key(for: spec) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.key == key }?.attachment
    }

    public func save(_ attachment: DanmakuAttachment?, for spec: PlaySpec) throws {
        guard let key = Self.key(for: spec) else { return }
        lock.lock(); defer { lock.unlock() }
        var next = entries.filter { $0.key != key }
        if let attachment { next.insert(Entry(key: key, attachment: attachment, updatedAt: Date()), at: 0) }
        next = Array(next.prefix(512))
        try storage.save(next, to: filename)
        entries = next
    }
}
