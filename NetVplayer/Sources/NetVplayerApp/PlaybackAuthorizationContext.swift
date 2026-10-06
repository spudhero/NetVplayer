import Foundation
import Models

struct PlaybackAuthorizationOrigin: Equatable, Sendable {
    let generation: UInt64
    let detailGeneration: UInt64
    let sourceFingerprint: String
    let siteKey: String
    let vodID: String
    let flag: String
}

struct PlaybackAuthorizationResume: Sendable {
    let id = UUID()
    let origin: PlaybackAuthorizationOrigin
    let episode: Episode
    let resumePosition: Int64?
    let resumeDuration: Int64?
    let automaticSelection: Bool
    let restartFromBeginning: Bool
}

struct CloudAuthRequest: Identifiable, Equatable {
    let id = UUID()
    let provider: DriveProvider
    let pendingEpisodeURL: String?
    let resume: PlaybackAuthorizationResume?

    init(provider: DriveProvider, pendingEpisodeURL: String? = nil, resume: PlaybackAuthorizationResume? = nil) {
        self.provider = provider
        self.pendingEpisodeURL = pendingEpisodeURL
        self.resume = resume
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
