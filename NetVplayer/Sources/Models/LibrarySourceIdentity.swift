import Foundation
import CryptoKit

/// Only the digest is persisted; configuration URLs and provider credentials are not identity fields on disk.
public enum LibrarySourceIdentity {
    public static func fingerprint(configurationURL: String, site: Site) -> String {
        guard !configurationURL.isEmpty else { return "" }
        let material = [configurationURL, site.key, String(site.type), site.api, canonicalJSON(site.ext)]
        let bytes = (try? JSONEncoder().encode(material)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func key(source: String, siteKey: String, vodID: String) -> String {
        guard !source.isEmpty else { return "\(siteKey)_\(vodID)" }
        let data = (try? JSONEncoder().encode([source, siteKey, vodID])) ?? Data()
        return "vod:v2:" + data.base64EncodedString()
    }

    public static func components(of key: String) -> (source: String, siteKey: String, vodID: String)? {
        guard key.hasPrefix("vod:v2:"),
              let data = Data(base64Encoded: String(key.dropFirst(7))),
              let parts = try? JSONDecoder().decode([String].self, from: data), parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// A legacy favorite has no separate site field. Resolve underscores only against known sites.
    public static func legacyIdentity(key: String, sites: [Site]) -> (siteKey: String, vodID: String)? {
        let candidates = sites.filter { key.hasPrefix($0.key + "_") }
        guard candidates.count == 1, let site = candidates.first else { return nil }
        return (site.key, String(key.dropFirst(site.key.count + 1)))
    }

    private static func canonicalJSON(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let result = String(data: canonical, encoding: .utf8) else { return value }
        return result
    }
}
