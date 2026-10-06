import Foundation
import CoreFoundation

public struct PlayerChapter: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let seconds: Double

    public init(id: Int, title: String, seconds: Double) {
        self.id = id
        self.title = title
        self.seconds = seconds
    }
}

/// Container editions are metadata, not alternate files from a media library.
public struct PlayerEdition: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let isDefault: Bool
}

public enum PlayerChapterPolicy {
    public static func chapters(json: String, duration: Double = 0) throws -> [PlayerChapter] {
        guard json.utf8.count <= 1_024 * 1_024,
              let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        var seen = Set<Double>()
        return rows.prefix(256).enumerated().compactMap { index, row in
            guard let number = row["time"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let seconds = number.doubleValue
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1_000,
                  !(duration.isFinite && duration > 0 && seconds >= duration), seen.insert(seconds).inserted else { return nil }
            return PlayerChapter(id: index, title: String((row["title"] as? String ?? "").prefix(256)), seconds: seconds)
        }.sorted { $0.seconds < $1.seconds }
    }

    public static func editions(json: String) throws -> [PlayerEdition] {
        guard json.utf8.count <= 1_024 * 1_024,
              let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return rows.prefix(32).enumerated().map { index, row in
            PlayerEdition(id: index, title: String((row["title"] as? String ?? "").prefix(256)),
                          isDefault: (row["default"] as? Bool) == true)
        }
    }

    public static func current(at position: Double, in chapters: [PlayerChapter]) -> PlayerChapter? {
        guard position.isFinite else { return nil }
        return chapters.last { $0.seconds <= max(0, position) + 0.001 }
    }

    public static func next(at position: Double, in chapters: [PlayerChapter]) -> PlayerChapter? {
        guard position.isFinite else { return nil }
        return chapters.first { $0.seconds > max(0, position) + 0.25 }
    }

    public static func previous(at position: Double, in chapters: [PlayerChapter]) -> PlayerChapter? {
        guard let current = current(at: position, in: chapters),
              let index = chapters.firstIndex(where: { $0.id == current.id }) else { return nil }
        if position - current.seconds > 3 { return current }
        return index > 0 ? chapters[index - 1] : nil
    }
}
