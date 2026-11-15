import Foundation

public struct SubtitleTranslationKey: Codable, Hashable, Sendable {
    public let media: String
    public let track: String
    public let sourceLanguage: String
    public let targetLanguage: String
    public let translator: SubtitleTranslatorIdentity
    public let schema: Int
    public init(media: String, document: SubtitleDocument, sourceLanguage: String, targetLanguage: String,
                translator: SubtitleTranslatorIdentity) {
        self.media = media; track = document.fingerprint; self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage; self.translator = translator; schema = 1
    }
    public var digest: String { SubtitleDocument.digest((try? SubtitleDocument.canonicalEncoder().encode(self)) ?? Data()) }
}

public struct SubtitleTranslationCoverage: Codable, Equatable, Sendable {
    public let key: SubtitleTranslationKey
    public let total: Int
    public let translations: [Int: String]
    public var complete: Bool { total > 0 && translations.count == total && (0..<total).allSatisfy { translations[$0] != nil } }
}

/// One writer per process. Each checkpoint is a self-contained, atomic replacement.
public actor SubtitleTranslationCache {
    public static let shared = SubtitleTranslationCache(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NetVplayer/SubtitleTranslations", isDirectory: true))
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func load(key: SubtitleTranslationKey, total: Int) throws -> SubtitleTranslationCoverage {
        for suffix in ["complete", "partial"] {
            let url = path(key, suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 else { throw SubtitleTranslationError.invalidCache }
            let value = try JSONDecoder().decode(SubtitleTranslationCoverage.self, from: Data(contentsOf: url))
            guard value.key == key, value.total == total, Self.valid(value.translations, total: total),
                  suffix != "complete" || value.complete else { throw SubtitleTranslationError.invalidCache }
            return value
        }
        return .init(key: key, total: total, translations: [:])
    }

    public func merge(key: SubtitleTranslationKey, total: Int, translations: [Int: String]) throws -> SubtitleTranslationCoverage {
        guard total > 0, total <= SubtitleDocument.maximumCues, Self.valid(translations, total: total) else { throw SubtitleTranslationError.invalidResponse }
        let previous = try load(key: key, total: total)
        let merged = previous.translations.merging(translations) { existing, _ in existing }
        let value = SubtitleTranslationCoverage(key: key, total: total, translations: merged)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 16 * 1024 * 1024 else { throw SubtitleTranslationError.limitExceeded }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: path(key, value.complete ? "complete" : "partial"), options: [.atomic])
        if value.complete { try? FileManager.default.removeItem(at: path(key, "partial")) }
        return value
    }

    public static func valid(_ values: [Int: String], total: Int) -> Bool {
        values.allSatisfy { id, text in
            (0..<total).contains(id) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && text.utf8.count <= 32_768 && !text.contains("\0")
        }
    }
    private func path(_ key: SubtitleTranslationKey, _ suffix: String) -> URL {
        directory.appendingPathComponent(key.digest + "." + suffix + ".json")
    }
}
