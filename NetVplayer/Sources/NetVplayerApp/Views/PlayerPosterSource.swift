import Foundation
import Models

enum PlayerPosterSource {
    static func resolve(episode: Episode?, detail: Vod?, spec: PlaySpec?) -> String {
        [episode?.artwork, detail?.vodPic, spec?.metadata["vod.pic"], spec?.artwork, spec?.audioFallbackArtwork]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != PlaybackArtworkLoader.placeholderSource } ?? ""
    }
}
