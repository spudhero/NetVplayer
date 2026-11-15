import Foundation

/// A player result's direct attachment. Configuration search APIs use a
/// separate field and never substitute for an unavailable provider attachment.
public struct ProviderDanmaku: Codable, Equatable, Sendable {
    public var name: String
    public var url: String

    public init(name: String = "", url: String) { self.name = name; self.url = url }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    public static func decodeList(from decoder: Decoder) throws -> [ProviderDanmaku] {
        let value = try decoder.singleValueContainer()
        if let items = try? value.decode([ProviderDanmaku].self) { return items.filter { !$0.url.isEmpty } }
        let string = try value.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if string.isEmpty { return [] }
        if let bytes = string.data(using: .utf8), let items = try? JSONDecoder().decode([ProviderDanmaku].self, from: bytes) {
            return items.filter { !$0.url.isEmpty }
        }
        return [ProviderDanmaku(name: string, url: string)]
    }
}
