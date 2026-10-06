import Foundation
import CryptoKit

public enum SubtitleTextColor: String, Codable, CaseIterable, Sendable {
    case white, yellow, cyan

    public var mpvValue: String {
        switch self {
        case .white: return "#FFFFFFFF"
        case .yellow: return "#FFFFFF00"
        case .cyan: return "#FF00FFFF"
        }
    }

    public var displayName: String {
        switch self {
        case .white: return L10n.text("白色")
        case .yellow: return L10n.text("黄色")
        case .cyan: return L10n.text("青色")
        }
    }
}

public struct SubtitleAppearance: Codable, Equatable, Sendable {
    public var fontName: String
    public var color: SubtitleTextColor
    public var borderWidth: Double
    public var backgroundOpacity: Double
    public var bitmapScale: Double
    public var secondaryPosition: Int

    public init(fontName: String = "PingFang SC", color: SubtitleTextColor = .white,
                borderWidth: Double = 2, backgroundOpacity: Double = 0, bitmapScale: Double = 1, secondaryPosition: Int = 5) {
        self.fontName = ["PingFang SC", "Heiti SC", "Arial"].contains(fontName) ? fontName : "PingFang SC"
        self.color = color
        self.borderWidth = Self.clamp(borderWidth, to: 0...5, fallback: 2)
        self.backgroundOpacity = Self.clamp(backgroundOpacity, to: 0...1, fallback: 0)
        self.secondaryPosition = min(100, max(0, secondaryPosition))
        self.bitmapScale = Self.clamp(bitmapScale, to: 0.5...3, fallback: 1)
    }

    public var normalized: Self {
        Self(fontName: fontName, color: color, borderWidth: borderWidth,
             backgroundOpacity: backgroundOpacity, bitmapScale: bitmapScale, secondaryPosition: secondaryPosition)
    }

    private enum CodingKeys: String, CodingKey { case fontName, color, borderWidth, backgroundOpacity, bitmapScale, secondaryPosition }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fontName: try c.decodeIfPresent(String.self, forKey: .fontName) ?? "PingFang SC",
                  color: try c.decodeIfPresent(SubtitleTextColor.self, forKey: .color) ?? .white,
                  borderWidth: try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 2,
                  backgroundOpacity: try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0,
                  bitmapScale: try c.decodeIfPresent(Double.self, forKey: .bitmapScale) ?? 1,
                  secondaryPosition: try c.decodeIfPresent(Int.self, forKey: .secondaryPosition) ?? 5)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

public enum SubtitleMediaIdentity {
    public static func key(for spec: PlaySpec) -> String? {
        guard spec.metadata["playback.kind"] != "live", spec.metadata["live.channelID"] == nil else { return nil }
        let m = spec.metadata
        let parts: [String]
        if let source = m["library.sourceFingerprint"], !source.isEmpty,
           let id = m["vod.id"], !id.isEmpty, let site = m["vod.siteKey"], !site.isEmpty {
            parts = [source, site, id, m["vod.episodeName"] ?? ""]
        } else if let url = URL(string: spec.url), url.isFileURL {
            parts = ["file", url.standardizedFileURL.path]
        } else {
            return nil
        }
        guard let data = try? JSONEncoder().encode(parts) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func externalIdentifier(for sub: Sub) -> String {
        let data = (try? JSONEncoder().encode([sub.name, sub.lang, sub.format])) ?? Data()
        return "external-name:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func normalizedDelay(_ seconds: Double) -> Double {
        seconds.isFinite ? min(120, max(-120, seconds)) : 0
    }
}

public struct SubtitleDelayRecord: Codable, Equatable, Sendable {
    public var key: String
    public var seconds: Double
    public var secondarySeconds: Double
    public init(key: String, seconds: Double, secondarySeconds: Double = 0) {
        self.key = key
        self.seconds = SubtitleMediaIdentity.normalizedDelay(seconds)
        self.secondarySeconds = SubtitleMediaIdentity.normalizedDelay(secondarySeconds)
    }

    private enum CodingKeys: String, CodingKey { case key, seconds, secondarySeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decode(String.self, forKey: .key), seconds: try c.decode(Double.self, forKey: .seconds),
                  secondarySeconds: try c.decodeIfPresent(Double.self, forKey: .secondarySeconds) ?? 0)
    }

    public static func sanitized(_ records: [Self]) -> [Self] {
        var seen = Set<String>()
        return records.reversed().compactMap { record in
            guard record.key.count == 64, record.key.allSatisfy({ $0.isHexDigit }), seen.insert(record.key).inserted else { return nil }
            let value = Self(key: record.key, seconds: record.seconds, secondarySeconds: record.secondarySeconds)
            return value.seconds == 0 && value.secondarySeconds == 0 ? nil : value
        }.prefix(1000).reversed()
    }
}
