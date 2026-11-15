import Foundation
import CryptoKit
import Models
import SpiderEngine
import DriveEngine

/// Replays an observed shared file when a search service is unavailable.
/// The ledger must keep this separate from catalog and category acceptance.
enum DevelopmentAndroidReplayAudit {
    struct Selection: Decodable {
        let vodID: String
        let flag: String
        let fileID: String?
        var episodeIdentitySHA256: String?
        var episodeURLSHA256: String?

        var isValid: Bool {
            guard valid(vodID, maximumBytes: 64 * 1024), valid(flag, maximumBytes: 256) else { return false }
            if let episodeURLSHA256 {
                return fileID == nil && episodeIdentitySHA256 == nil && isHash(episodeURLSHA256)
            }
            return fileID.map { valid($0, maximumBytes: 1024) } == true
                && (episodeIdentitySHA256.map(isHash) ?? true)
        }

        private func isHash(_ value: String) -> Bool {
            value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        }

        /// Use the freshly returned episode so expiring SDK session fields are
        /// never replayed. A missing or ambiguous file must not select another.
        func episodeIndex(in episodes: [Episode]) -> Int? {
            let matches = matchingIndices(in: episodes)
            if episodeIdentitySHA256 != nil {
                // Repeated rows may describe the same observed file. All stable
                // fields must match; only the expiring SDK share token is ignored.
                return identityMatchingIndices(in: episodes).first
            }
            return matches.count == 1 ? matches.first : nil
        }

        func identityMatchingIndices(in episodes: [Episode]) -> [Int] {
            guard let episodeIdentitySHA256 else { return [] }
            return matchingIndices(in: episodes).filter {
                Self.stableIdentitySHA256(for: episodes[$0].url) == episodeIdentitySHA256
            }
        }

        static func stableIdentitySHA256(for id: String) -> String? {
            OriginalAndroidPlaybackIdentity.stableCloudSHA256(for: id)
        }

        func matchingIndices(in episodes: [Episode]) -> [Int] {
            guard isValid else { return [] }
            return episodes.indices.filter { index in
                let id = episodes[index].url
                guard id.utf8.count <= 64 * 1024 else { return false }
                if let episodeURLSHA256 {
                    return DevelopmentAndroidLifecycleDiagnostics.sha256(Data(id.utf8)) == episodeURLSHA256
                }
                if let components = URLComponents(string: id), components.scheme == "netvplayer-drive" {
                    let names = components.queryItems?.map(\.name) ?? []
                    guard Set(names).count == names.count,
                          let reference = DriveFileReference.parse(id), reference.provider == .ali else { return false }
                    return reference.fid == fileID
                }
                guard let object = try? JSONSerialization.jsonObject(with: Data(id.utf8)) as? [String: Any] else { return false }
                if let marker = object["flag"] as? String,
                   ["嘟嘟盘", "阿狸盘", "夸父盘", "优汐盘"].contains(marker), episodeIdentitySHA256 == nil {
                    return false
                }
                let key: String
                switch object["flag"] as? String {
                case "嘟嘟盘": key = "fs_id"
                case "夸父盘", "优汐盘": key = "fid"
                default: key = "file_id"
                }
                return object[key] as? String == fileID
            }
        }

        func episodeKinds(in episodes: [Episode]) -> [String: Int] {
            Dictionary(episodes.map { episode in
                let kind = episode.url.hasPrefix("{") ? "json"
                    : episode.url.hasPrefix("netvplayer-drive:") ? "native_drive" : "other"
                return (kind, 1)
            }, uniquingKeysWith: +)
        }

        private func valid(_ text: String, maximumBytes: Int) -> Bool {
            !text.isEmpty && text.utf8.count <= maximumBytes
                && text.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }
}
