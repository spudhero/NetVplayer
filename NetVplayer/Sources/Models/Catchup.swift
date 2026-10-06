// Models/Catchup.swift
// 回看配置模型

import Foundation

/// 直播回看配置
public struct Catchup: Codable, Sendable {
    public var source: String      // 回看 URL 模板
    public var type: String        // 回看类型 (append/default/flussonic/shift/xc)
    public var days: Int           // 支持回看天数

    public init(source: String = "", type: String = "", days: Int = 0) {
        self.source = source
        self.type = type
        self.days = days
    }

    public func playbackURL(channelURL: String, start: Date, end: Date, timeZone: TimeZone = .current) -> String {
        let duration = max(0, Int(end.timeIntervalSince(start)))
        let utc = Int(start.timeIntervalSince1970)
        let local = Self.format(start, timeZone: timeZone)
        let resolvedSource = Self.fillTemplate(
            source.isEmpty ? channelURL : source,
            channelURL: channelURL,
            utc: utc,
            local: local,
            duration: duration
        )

        switch type.lowercased() {
        case "append":
            if resolvedSource.hasPrefix("?") || resolvedSource.hasPrefix("&") {
                return channelURL + resolvedSource
            }
            return resolvedSource
        case "flussonic":
            let base = channelURL.replacingOccurrences(of: ".m3u8", with: "")
            return "\(base)/timeshift_abs-\(utc).m3u8"
        case "shift":
            let separator = channelURL.contains("?") ? "&" : "?"
            return "\(channelURL)\(separator)utc=\(utc)&duration=\(duration)"
        case "xc":
            let separator = channelURL.contains("?") ? "&" : "?"
            return "\(channelURL)\(separator)timeshift=\(duration)&start=\(local)"
        default:
            return resolvedSource
        }
    }

    private static func fillTemplate(_ template: String, channelURL: String, utc: Int, local: String, duration: Int) -> String {
        template
            .replacingOccurrences(of: "{url}", with: channelURL)
            .replacingOccurrences(of: "{utc}", with: String(utc))
            .replacingOccurrences(of: "{lutc}", with: local)
            .replacingOccurrences(of: "{start}", with: String(utc))
            .replacingOccurrences(of: "{duration}", with: String(duration))
    }

    private static func format(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }
}
