import Foundation
import CryptoKit

/// Runtime-only identity. Never serialize URLs, account material or these keys.
public struct PlaybackSummaryIdentity: Hashable, Sendable {
    private let digest: String

    public init(scope: String, site: String, vod: String, line: String, episode: String) {
        // Array encoding preserves field boundaries even for untrusted source IDs.
        let data = (try? JSONEncoder().encode([scope, site, vod, line, episode])) ?? Data()
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
