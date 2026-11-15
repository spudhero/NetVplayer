import Foundation
import Models

/// Reads persisted production history; never manufactures a resume position.
enum DevelopmentAndroidHistoryAudit {
    static func matchingHistory(_ items: [History], siteKey: String, vodID: String,
                                detailRequestID: String, flag: String, episodeURL: String,
                                sourceFingerprint: String) -> History? {
        guard !sourceFingerprint.isEmpty,
              let expectedIdentity = OriginalAndroidPlaybackIdentity.episodeSHA256(for: episodeURL) else { return nil }
        let matches = items.filter { item in
            let sameEpisode: Bool
            if let identity = item.originalEpisodeIdentitySHA256 {
                sameEpisode = identity == expectedIdentity
            } else if !item.episodeUrl.isEmpty {
                sameEpisode = OriginalAndroidPlaybackIdentity.episodeSHA256(for: item.episodeUrl) == expectedIdentity
            } else {
                // Remote locators are deliberately removed from persisted history.
                // Its existing episode key still binds the original file, line and VOD.
                sameEpisode = item.episodeKey == HistoryPersistencePolicy.episodeKey(
                    siteKey: siteKey, vodId: vodID, vodFlag: flag, episodeURL: episodeURL)
            }
            return item.siteKey == siteKey && item.vodId == vodID
                && (item.originalDetailRequestID ?? item.vodId) == detailRequestID
                && item.vodFlag == flag && sameEpisode
                && item.sourceFingerprint == sourceFingerprint && item.position > 0
                && item.duration > item.position && item.speed == 1 && item.magnet == nil
        }
        return matches.count == 1 ? matches.first : nil
    }
}
