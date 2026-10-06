// WebHomeEngine/WebHomeScopedCacheStore.swift

import Foundation
import Models
import Storage

public final class WebHomeScopedCacheStore: @unchecked Sendable {
    private let storage: StorageManager
    private let filename = "webhome_cache.json"
    private let maxKeyLength = 120
    private let maxValueLength = 512_000
    private let lock = NSLock()
    private var cache: [String: JSONDynamicValue]

    public init(storage: StorageManager = .shared) {
        self.storage = storage
        self.cache = (try? storage.load([String: JSONDynamicValue].self, from: filename)) ?? [:]
    }

    public func value(for key: String) -> JSONDynamicValue? {
        lock.lock()
        defer { lock.unlock() }
        return cache[normalizedKey(key)]
    }

    public var keyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public func set(_ value: JSONDynamicValue, for key: String) throws {
        let normalized = normalizedKey(key)
        let safeValue = clamped(value)
        lock.lock()
        cache[normalized] = safeValue
        let snapshot = cache
        lock.unlock()
        try storage.save(snapshot, to: filename)
    }

    public func delete(key: String) throws {
        lock.lock()
        cache.removeValue(forKey: normalizedKey(key))
        let snapshot = cache
        lock.unlock()
        try storage.save(snapshot, to: filename)
    }

    private func normalizedKey(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return String((result.isEmpty ? "key" : result).prefix(maxKeyLength))
    }

    private func clamped(_ value: JSONDynamicValue) -> JSONDynamicValue {
        guard let data = try? JSONEncoder().encode(value), data.count > maxValueLength else {
            return value
        }
        return .string(String(value.stringValue.prefix(maxValueLength)))
    }
}
