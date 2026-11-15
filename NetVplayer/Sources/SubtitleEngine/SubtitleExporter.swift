import Foundation

public enum SubtitleExportFormat: String, CaseIterable, Sendable { case srt, ass }

public enum SubtitleExporter {
    /// Translated and bilingual artifacts require full coverage. Originals remain exportable.
    public static func render(document: SubtitleDocument, coverage: SubtitleTranslationCoverage? = nil,
                              format: SubtitleExportFormat, bilingual: Bool = false) throws -> Data {
        if let coverage {
            guard coverage.key.track == document.fingerprint, coverage.total == document.cues.count,
                  coverage.complete, SubtitleTranslationCache.valid(coverage.translations, total: coverage.total) else { throw SubtitleTranslationError.incomplete }
        } else if bilingual { throw SubtitleTranslationError.incomplete }
        var result = format == .ass ? "[Script Info]\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,30,30,35,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" : ""
        for cue in document.cues {
            let precision = format == .ass ? 100.0 : 1000.0
            guard (cue.end * precision).rounded() > (cue.start * precision).rounded() else {
                throw SubtitleTranslationError.invalidDocument
            }
            let translated = coverage?.translations[cue.id]
            let text = translated.map { bilingual ? $0 + "\n" + cue.text : $0 } ?? cue.text
            let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if format == .srt {
                let safe = lines.joined(separator: "\n").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                result += "\(cue.id + 1)\n\(stamp(cue.start, ass: false)) --> \(stamp(cue.end, ass: false))\n\(safe)\n\n"
            } else {
                // Neutralize ASS override/drawing syntax in untrusted translated dialogue.
                let safe = lines.map { $0.replacingOccurrences(of: "\\", with: "＼").replacingOccurrences(of: "{", with: "｛").replacingOccurrences(of: "}", with: "｝") }.joined(separator: "\\N")
                result += "Dialogue: 0,\(stamp(cue.start, ass: true)),\(stamp(cue.end, ass: true)),Default,,0,0,0,,\(safe)\n"
            }
        }
        return Data(result.utf8)
    }

    public static func save(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw SubtitleTranslationError.invalidDocument }
        try data.write(to: url, options: .atomic)
    }

    private static func stamp(_ seconds: Double, ass: Bool) -> String {
        let scale = ass ? 100 : 1000
        let ticks = Int((seconds * Double(scale)).rounded())
        return String(format: ass ? "%d:%02d:%02d.%02d" : "%02d:%02d:%02d,%03d",
                      ticks / (3600 * scale), ticks / (60 * scale) % 60, ticks / scale % 60, ticks % scale)
    }
}
