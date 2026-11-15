import Foundation
import Models

/// Explicit user choice belongs to one original series, not the volatile URL
/// or mpv numeric track ID. A new source/detail gets fresh defaults.
struct OriginalSubtitleSelection {
    enum Choice: Equatable {
        case disabled
        case track(name: String, language: String, format: String, external: Bool)
    }
    private var scope: [String]?
    private var currentTrackID: String?
    private(set) var choice: Choice?

    mutating func begin(_ spec: PlaySpec) {
        currentTrackID = nil
        let next: [String]? = spec.metadata["android.originalAttachments"] == "true"
            ? [spec.siteKey, spec.metadata["library.sourceFingerprint"] ?? "", spec.metadata["vod.id"] ?? spec.url] : nil
        if next == nil || next != scope { choice = nil }
        scope = next
    }
    mutating func select(_ track: PlayerTrackInfo?) {
        guard scope != nil else { return }
        currentTrackID = track?.id
        choice = track.map { .track(name: $0.name, language: $0.language, format: $0.format, external: $0.isExternal) } ?? .disabled
    }
    func matchingID(in tracks: [PlayerTrackInfo]) -> String? {
        switch choice {
        case .disabled: return "no"
        case let .track(name, language, format, external):
            let candidates = tracks.filter { $0.kind == .subtitle && $0.isExternal == external }
            let exact = candidates.filter { $0.name == name && $0.language == language && $0.format == format }
            if let current = exact.first(where: { $0.id == currentTrackID }) { return current.id }
            if exact.count == 1 { return exact[0].id }
            let languageMatches = candidates.filter { !language.isEmpty && $0.language == language && $0.format == format }
            return languageMatches.count == 1 ? languageMatches[0].id : nil
        case nil: return nil
        }
    }
}
