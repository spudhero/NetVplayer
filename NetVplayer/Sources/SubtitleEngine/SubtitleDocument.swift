import Foundation
import CryptoKit

public enum SubtitleTranslationError: Error, Sendable {
    case invalidDocument, limitExceeded, invalidResponse, incomplete, invalidCache, expired
}

public struct SubtitleCue: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let text: String
}

/// Plain dialogue on the source timeline. Styling and drawings are not translated.
public struct SubtitleDocument: Sendable, Equatable {
    public let cues: [SubtitleCue]
    public let fingerprint: String
    public static let maximumCues = 30_000

    public init(data: Data, filename: String) throws {
        let files = try SubtitleArchive.unpack(data, filename: filename)
        guard files.count == 1, let file = files.first,
              let decoded = String(data: file.data, encoding: .utf8) else { throw SubtitleTranslationError.invalidDocument }
        let source = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let rows: [(Double, Double, String)]
        switch file.format {
        case "ass", "ssa": rows = try Self.ass(source)
        case "srt", "vtt": rows = try Self.timedText(source)
        default: throw SubtitleTranslationError.invalidDocument
        }
        try self.init(rows: rows)
    }

    public init(cues: [SubtitleCue]) throws {
        try self.init(rows: cues.map { ($0.start, $0.end, $0.text) })
    }

    private init(rows: [(Double, Double, String)]) throws {
        guard !rows.isEmpty, rows.count <= Self.maximumCues,
              rows.reduce(0, { $0 + $1.2.utf8.count }) <= SubtitleArchive.maximumFileBytes else { throw SubtitleTranslationError.limitExceeded }
        var cues: [SubtitleCue] = []
        // Stable tie ordering also preserves overlapping dialogue.
        for (_, row) in rows.enumerated().sorted(by: { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }) {
            guard row.0.isFinite, row.1.isFinite, row.0 >= 0, row.1 > row.0, row.1 <= 7 * 86400,
                  !row.2.isEmpty, row.2.utf8.count <= 16_384 else { throw SubtitleTranslationError.invalidDocument }
            cues.append(.init(id: cues.count, start: row.0, end: row.1, text: row.2))
        }
        self.cues = cues
        fingerprint = Self.digest(try Self.canonicalEncoder().encode(cues))
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func canonicalEncoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }

    private static func time(_ raw: String) throws -> Double {
        let parts = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!), seconds >= 0, seconds < 60,
              let minutes = Double(parts[parts.count - 2]), minutes >= 0, minutes < 60 else { throw SubtitleTranslationError.invalidDocument }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let hours, hours >= 0, hours.isFinite else { throw SubtitleTranslationError.invalidDocument }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func timedText(_ source: String) throws -> [(Double, Double, String)] {
        let lines = source.components(separatedBy: "\n")
        var rows: [(Double, Double, String)] = [], i = 0
        while i < lines.count {
            let line = lines[i]; i += 1
            guard line.contains("-->") else { continue }
            let times = line.components(separatedBy: "-->")
            guard times.count == 2, let end = times[1].split(whereSeparator: { $0.isWhitespace }).first else { throw SubtitleTranslationError.invalidDocument }
            var text: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { text.append(lines[i]); i += 1 }
            let plain = clean(text.joined(separator: "\n"), ass: false)
            guard !plain.isEmpty else { throw SubtitleTranslationError.invalidDocument }
            rows.append((try time(times[0]), try time(String(end)), plain))
        }
        return rows
    }

    private static func ass(_ source: String) throws -> [(Double, Double, String)] {
        var events = false, format: [String] = [], rows: [(Double, Double, String)] = []
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { events = line.lowercased() == "[events]"; continue }
            guard events else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.lowercased().hasPrefix("dialogue:") {
                guard format.last == "text", Set(format).count == format.count,
                      let start = format.firstIndex(of: "start"), let end = format.firstIndex(of: "end") else { throw SubtitleTranslationError.invalidDocument }
                let values = line.dropFirst(9).split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false).map(String.init)
                guard values.count == format.count else { throw SubtitleTranslationError.invalidDocument }
                // Vector drawings have no text source; do not send drawing commands to a translator.
                if values.last!.range(of: #"\\p[1-9]"#, options: .regularExpression) != nil { continue }
                let plain = clean(values.last!, ass: true)
                if !plain.isEmpty { rows.append((try time(values[start]), try time(values[end]), plain)) }
            }
        }
        return rows
    }

    private static func clean(_ text: String, ass: Bool) -> String {
        var text = text
        if ass {
            text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
        } else {
            text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
                text = text.replacingOccurrences(of: entity, with: value)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
