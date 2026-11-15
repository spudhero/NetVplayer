import Foundation

/// Server declarations, bound to the provider session that read the channel list.
public struct XtreamArchiveChannel: Sendable, Equatable {
    public let enabled: Bool
    public let days: Int
    public let timeZone: String?
    public let session: UUID
    public let credentialIdentity: String

    public init(enabled: Bool, days: Int, timeZone: String?, session: UUID, credentialIdentity: String) {
        self.enabled = enabled; self.days = days; self.timeZone = timeZone
        self.session = session; self.credentialIdentity = credentialIdentity
    }
}

/// Only the historical endpoint can supply this evidence. Never inferred from short EPG.
public struct XtreamProgrammeArchive: Sendable, Equatable {
    public let resource: String
    public let scope: String
    public let session: UUID
    public let hasArchive: Bool

    public init(resource: String, scope: String, session: UUID, hasArchive: Bool) {
        self.resource = resource; self.scope = scope; self.session = session; self.hasArchive = hasArchive
    }
}

public extension XtreamCredentials {
    /// Process-local salted identity; no password or reusable credential hash in saved data.
    func runtimeIdentity(configuration: XtreamConfiguration) -> String {
        let parts = [XtreamArchivePolicy.identitySalt, configuration.id.uuidString, configuration.server, username, password]
        let encoded = (try? JSONEncoder().encode(parts)) ?? Data()
        return StableFingerprint.sha256Prefix(encoded.base64EncodedString(), length: 64)
    }
}

public enum XtreamArchivePolicy {
    fileprivate static let identitySalt = UUID().uuidString

    /// DateFormatter alone can silently choose a repeated time or normalize a missing time.
    public static func instant(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = formatter(timeZone, format: "yyyy-MM-dd HH:mm:ss")
        guard text.utf8.count == 19, let approximate = formatter.date(from: text),
              formatter.string(from: approximate) == text else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: approximate)
        let before = approximate.addingTimeInterval(-2 * 86_400)
        let first = calendar.nextDate(after: before, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.nextDate(after: before, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last)
        guard let first, first == last, formatter.string(from: first) == text else { return nil }
        return first
    }

    public static func availability(channel: Channel, programme: EpgItem?, now: Date = Date(), offset: Double = 0) -> LiveCatchupAvailability {
        guard let programme else { return .unavailable(.missingProgramme) }
        let duration = programme.end.timeIntervalSince(programme.start)
        guard duration.isFinite, duration >= 1, duration <= 2 * 86_400,
              programme.start.timeIntervalSince1970.isFinite, abs(programme.start.timeIntervalSince1970) < 1e12,
              offset.isFinite, offset >= 0, offset < duration else { return .unavailable(.invalidProgramme) }
        guard programme.start <= now else { return .unavailable(.future) }
        guard programme.end <= now else { return .unavailable(.onAir) }
        guard let capability = channel.xtreamArchive, capability.enabled, capability.days > 0 else { return .unavailable(.noArchive) }
        guard let raw = channel.currentUrl, let resource = try? XtreamResource(raw), resource.kind == "live",
              let proof = programme.xtreamArchive, let original = try? XtreamResource(proof.resource),
              original.accountID == resource.accountID, original.streamID == resource.streamID,
              proof.session == capability.session else { return .unavailable(.archiveUnconfirmed) }
        guard proof.hasArchive else { return .unavailable(.noArchive) }
        guard programme.start >= now.addingTimeInterval(-Double(capability.days) * 86_400) else { return .unavailable(.expired) }
        guard let name = capability.timeZone, let zone = TimeZone(identifier: name) else { return .unavailable(.serverTimeZoneUnknown) }
        let target = programme.start.addingTimeInterval(floor(offset))
        let local = formatter(zone, format: "yyyy-MM-dd HH:mm").string(from: target) + ":00"
        guard let routeStart = instant(local, timeZone: zone), routeStart <= target,
              target.timeIntervalSince(routeStart) < 60 else { return .unavailable(.ambiguousArchiveTime) }
        return .available(.init(url: raw, mediaStartOffset: routeStart.timeIntervalSince(programme.start),
            initialPosition: target.timeIntervalSince(routeStart), supportsRequestSeek: true))
    }

    public static func routeStart(_ date: Date, timeZone: TimeZone) -> String {
        formatter(timeZone, format: "yyyy-MM-dd:HH-mm").string(from: date)
    }

    private static func formatter(_ zone: TimeZone, format: String) -> DateFormatter {
        let value = DateFormatter(); value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = zone
        value.dateFormat = format; value.isLenient = false
        return value
    }
}
