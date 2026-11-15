import Foundation
import CryptoKit

/// Declarative compatibility metadata supplied by the verified runtime component.
/// The shell owns URL validation and byte repair; Provider identities stay in its package.
struct AndroidCompatibilityPolicy: Codable, Sendable {
    struct CloudRule: Codable, Sendable {
        struct PlayerFlag: Codable, Sendable {
            let drive: String
            let fileKey: String
        }
        let classes: Set<String>
        let shareHosts: [String: String]
        let playerFlags: [String: PlayerFlag]
    }
    struct MediaRule: Codable, Sendable {
        let key: String
        let api: String
        let className: String
        let path: String
        let queryName: String
        let queryValue: String
    }
    struct BindingIdentity: Codable, Sendable {
        let key: String
        let api: String
        let className: String
        func matches(key: String, api: String, className: String) -> Bool {
            self.key == key && self.api == api && self.className == className
        }
    }
    struct NativePlaybackRule: Codable, Sendable {
        let key: String
        let api: String
        let className: String
        let flag: String
        let legacyPrefix: String
        let idSeparator: String
        let idPartCount: Int
        let idMaxDigits: Int
        let providerID: String
        let minimumVersion: String
        let accountDrives: [String]

        func accepts(flag: String, id: String) -> Bool {
            guard flag == self.flag, !legacyPrefix.isEmpty, idSeparator.count == 1,
                  (1...8).contains(idPartCount), (1...64).contains(idMaxDigits) else { return false }
            let legacy = id.hasPrefix(legacyPrefix)
            let parts = legacy ? [String(id.dropFirst(legacyPrefix.count))]
                : id.components(separatedBy: idSeparator)
            return parts.count == (legacy ? 1 : idPartCount) && parts.allSatisfy { part in
                (1...idMaxDigits).contains(part.utf8.count) && part.utf8.allSatisfy { (48...57).contains($0) }
            }
        }
    }
    let cloud: [CloudRule]
    let media: [MediaRule]
    var preservedNative: [BindingIdentity]? = nil
    var nativePlayback: [NativePlaybackRule]? = nil

    static func decodeBundled(_ data: Data) -> Self? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == "f198970c1934a43cd32169520bc1a80c25e5b0d998e80ef97d458b25bbe1920e" else { return nil }
        return try? PropertyListDecoder().decode(Self.self, from: data)
    }

    static let bundled: Self? = {
        let bundle = Bundle.main.url(forResource: "NetVplayer_SpiderEngine", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = bundle.url(forResource: "AndroidCompatibilityPolicy", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decodeBundled(data)
    }()

    func cloudDrive(api: String, className: String, operation: String, id: String) -> String? {
        guard id.utf8.count <= 65_536, id.rangeOfCharacter(from: .controlCharacters) == nil,
              api.hasPrefix("csp_"), className == "com.github.catvod.spider." + api.dropFirst(4),
              let rule = cloud.first(where: { $0.classes.contains(className) }) else { return nil }
        let drive: String?
        if operation == "detail", let url = URLComponents(string: id),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
           url.path.hasPrefix("/s/") {
            drive = rule.shareHosts[url.host?.lowercased() ?? ""]
        } else if operation == "player",
                  let fields = try? JSONSerialization.jsonObject(with: Data(id.utf8)) as? [String: Any],
                  let marker = fields["flag"] as? String, let flag = rule.playerFlags[marker],
                  let fileID = fields[flag.fileKey] as? String, !fileID.isEmpty {
            drive = flag.drive
        } else { return nil }
        return drive.flatMap { ["baidu", "ali", "quark", "uc"].contains($0) ? $0 : nil }
    }

    func repairsMedia(_ raw: String, key: String, api: String, className: String) -> Bool {
        guard let rule = media.first(where: { $0.key == key && $0.api == api && $0.className == className }),
              let url = URLComponents(string: raw), url.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              let port = url.port, (1...65535).contains(port), ![9978, 9979, 9999].contains(port),
              url.user == nil, url.password == nil, url.fragment == nil, url.path == rule.path else { return false }
        return url.queryItems?.filter { $0.name == rule.queryName }.map(\.value) == [rule.queryValue]
    }
}
