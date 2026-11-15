import Foundation
import Models

enum DolbyMediaFormat: String, CaseIterable, Hashable {
    case vision = "Dolby Vision"
    case atmos = "Dolby Atmos"

    var assetName: String { self == .vision ? "dolby-vision" : "dolby-atmos" }
    var aspectRatio: CGFloat { self == .vision ? 634.0 / 95 : 665.0 / 95 }
}

/// A source label is deliberately separate from verified playback output.
/// Never inspect a plot, movie title, remote URL or another selected version.
struct DolbySourceFormat: Equatable, Identifiable {
    enum Evidence { case server, filename }
    let format: DolbyMediaFormat
    let evidence: Evidence
    var id: DolbyMediaFormat { format }

    static func filename(_ name: String) -> [Self] {
        DolbyMediaFormat.allCases.compactMap { format in
            matches(format, in: name) ? Self(format: format, evidence: .filename) : nil
        }
    }

    static func serverFile(_ file: MediaServerFileDetail) -> [Self] {
        let fallback = filename(file.name)
        return DolbyMediaFormat.allCases.compactMap { format in
            let value: String?
            switch format {
            case .vision: value = file.videoRange?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            case .atmos: value = file.audio.isEmpty ? nil : file.audio.joined(separator: " · ")
            }
            // Explicit SDR/AAC metadata takes precedence over a filename tag.
            guard let value else { return fallback.first { $0.format == format } }
            let structuredVision = format == .vision && ["dv", "dovi", "doviwithhdr10", "doviwithhlg", "doviwithsdr"]
                .contains(value.lowercased())
            return structuredVision || matches(format, in: value)
                ? Self(format: format, evidence: .server) : nil
        }
    }

    static func matches(_ format: DolbyMediaFormat, in value: String) -> Bool {
        // Token boundaries avoid DVDRip, Atmosphere and arbitrary substrings.
        let token = format == .vision ? "(?:dolby[ ._-]*vision|dovi|dv)" : "(?:dolby[ ._-]*atmos|atmos)"
        return value.range(of: "(?<![a-z0-9])" + token + "(?![a-z0-9])",
            options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
