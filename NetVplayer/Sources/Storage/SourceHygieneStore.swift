// Storage/SourceHygieneStore.swift
// JSON-backed local source governance rules.

import Foundation
import Models

public final class SourceHygieneStore: @unchecked Sendable {
    public static let shared = SourceHygieneStore()

    private let storage: StorageManager
    private let filename = "source_hygiene_rules.json"
    private let lock = NSLock()
    private var rules: [SourceHygieneRule]

    public init(storage: StorageManager = .shared) {
        self.storage = storage
        self.rules = (try? storage.load([SourceHygieneRule].self, from: filename)) ?? []
    }

    public func loadRules() -> [SourceHygieneRule] {
        lock.lock()
        defer { lock.unlock() }
        return rules
    }

    public func replaceRules(_ rules: [SourceHygieneRule]) throws {
        lock.lock()
        self.rules = rules
        let snapshot = self.rules
        lock.unlock()
        try storage.save(snapshot, to: filename)
    }

    public func addRule(_ rule: SourceHygieneRule) throws {
        lock.lock()
        rules.append(rule)
        let snapshot = rules
        lock.unlock()
        try storage.save(snapshot, to: filename)
    }

    public func clear() throws {
        try replaceRules([])
    }
}
