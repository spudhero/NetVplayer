import Foundation
import Models

public enum VodDetailArtworkPolicy {
    /// Detail endpoints may omit artwork already supplied by the catalogue.
    /// Reuse it only for the same opaque content ID and source.
    public static func preservingPoster(in detail: Vod, from previous: Vod?, siteKey: String) -> Vod {
        guard detail.vodPic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !siteKey.isEmpty,
              let previous,
              !detail.vodId.isEmpty, detail.vodId == previous.vodId,
              detail.siteKey.isEmpty || detail.siteKey == siteKey,
              previous.siteKey.isEmpty || previous.siteKey == siteKey,
              !detail.isFolder, !previous.isFolder,
              !previous.vodPic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return detail }
        var result = detail
        result.vodPic = previous.vodPic
        return result
    }
}
