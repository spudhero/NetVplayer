import Foundation
import Models

public enum MediaTelevisionMerge {
    /// The user selects the aliases and one confirmed show; no fuzzy title inference is persisted.
    public static func corrections(records: [MediaRecord], target: MediaRecord) throws -> [MediaManualCorrection] {
        let metadata = target.metadata
        guard metadata.kind == .television, target.candidates.isEmpty,
              metadata.tmdbID?.isEmpty == false || metadata.doubanID?.isEmpty == false,
              let libraryID = target.reference.libraryID, !records.isEmpty,
              records.allSatisfy({ $0.metadata.kind == .television && $0.reference.libraryID == libraryID && $0.reference.serviceID == target.reference.serviceID }) else {
            throw FileServiceError.invalidConfiguration("请选择同一媒体库的剧集，以及已确认的影视资料")
        }
        var common = metadata; common.season = nil; common.episode = nil
        let title = common.showTitle ?? common.title ?? target.entry.name
        common.title = title; common.showTitle = title
        let source: MetadataSource = common.tmdbID != nil ? .tmdb : .douban
        return records.map { record in
            // Keep per-file season/episode corrections; show-level data stays refreshable online.
            let fields = MediaMetadata(title: title, originalTitle: common.originalTitle, year: common.year,
                kind: .television, showTitle: title, season: record.correction?.fields.season,
                episode: record.correction?.fields.episode, tmdbID: common.tmdbID, doubanID: common.doubanID)
            return .init(reference: record.reference, fields: fields, selectedCandidate: .init(source: source, metadata: common))
        }
    }
}
