import Foundation
import Models

/// Uses NetVplayer's existing Catchup renderer, including its calendar-string {lutc} semantics.
public enum LiveCatchupPolicy {
    public static func availability(channel: Channel, programme: EpgItem?, now: Date = Date(),
                                    timeZone: TimeZone?, offset: Double = 0,
                                    nativeResume: Bool = false) -> LiveCatchupAvailability {
        if channel.currentUrl.flatMap({ try? XtreamResource($0) })?.kind == "live" {
            return XtreamArchivePolicy.availability(channel: channel, programme: programme, now: now, offset: offset)
        }
        guard let programme else { return .unavailable(.missingProgramme) }
        let duration = programme.end.timeIntervalSince(programme.start)
        guard duration.isFinite, duration >= 1,
              programme.start.timeIntervalSince1970.isFinite,
              programme.end.timeIntervalSince1970.isFinite else { return .unavailable(.invalidProgramme) }
        guard programme.start <= now else { return .unavailable(.future) }
        guard programme.end <= now else { return .unavailable(.onAir) }
        guard let catchup = channel.catchup else { return .unavailable(.unsupported) }
        guard catchup.days >= 0 else { return .unavailable(.invalidTemplate) }
        // Zero means unspecified retention, not a promise that the server keeps any particular day.
        if catchup.days > 0, programme.start < now.addingTimeInterval(-Double(catchup.days) * 86_400) {
            return .unavailable(.expired)
        }
        let type = catchup.type.lowercased()
        guard ["", "default", "append", "flussonic", "shift", "xc"].contains(type) else {
            return .unavailable(["none", "off"].contains(type) ? .unsupported : .unsupportedType)
        }
        guard let channelURL = channel.currentUrl, validHTTPURL(channelURL),
              catchup.source.utf8.count <= 16_384 else { return .unavailable(.invalidTemplate) }
        let generated = ["flussonic", "shift", "xc"].contains(type)
        guard generated || !catchup.source.isEmpty else { return .unavailable(.invalidTemplate) }
        // Inspect the template before substituting {url}; braces in credentials cannot become tokens.
        var remainder = catchup.source
        for token in ["{url}", "{utc}", "{lutc}", "{start}", "{duration}"] {
            remainder = remainder.replacingOccurrences(of: token, with: "")
        }
        guard !remainder.contains("{"), !remainder.contains("}") else { return .unavailable(.unknownPlaceholder) }
        let needsTimeZone = type == "xc" || (!generated && catchup.source.contains("{lutc}"))
        guard !needsTimeZone || timeZone != nil else { return .unavailable(.missingTimeZone) }
        let requestSeek = generated || ["{utc}", "{lutc}", "{start}"].contains { catchup.source.contains($0) }
        guard offset.isFinite, offset >= 0, offset < duration else { return .unavailable(.invalidProgramme) }
        // Existing address formats have whole-second precision. Keep mapping at that same precision.
        let mediaOffset = requestSeek ? floor(offset) : 0
        let url = catchup.playbackURL(channelURL: channelURL,
            start: programme.start.addingTimeInterval(mediaOffset), end: programme.end,
            timeZone: timeZone ?? TimeZone(secondsFromGMT: 0)!)
        guard validHTTPURL(url), url != channelURL, !url.contains("{"), !url.contains("}") else { return .unavailable(.invalidTemplate) }
        return .available(.init(url: url, mediaStartOffset: mediaOffset,
                                initialPosition: !requestSeek && nativeResume && offset > 0 ? offset : nil,
                                supportsRequestSeek: requestSeek))
    }

    public static func seek(context: LiveCatchupContext, target: Double, nativeSeekable: Bool?,
                            mediaDuration: Double) -> LiveCatchupSeekAction {
        guard target.isFinite else { return .unsupported }
        let position = min(context.duration, max(0, target))
        if position >= context.duration { return .finish }
        let mediaPosition = position - context.mediaStartOffset
        if nativeSeekable == true, mediaDuration.isFinite, mediaDuration > 0,
           mediaPosition >= 0, mediaPosition < mediaDuration {
            return .native(mediaPosition: mediaPosition)
        }
        if context.supportsRequestSeek { return .request(programmePosition: position) }
        return .unsupported
    }

    public static func sourceFingerprint(_ live: Live?) -> String {
        guard var live else { return "" }
        live.groups = []; live.isSelected = false
        return fingerprint(live)
    }

    public static func channelFingerprint(_ value: Channel) -> String {
        var channel = value
        channel.currentUrlIndex = 0
        return fingerprint(channel) + (channel.xtreamArchive?.session.uuidString ?? "")
    }

    private static func fingerprint<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return StableFingerprint.sha256Prefix(String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "", length: 64)
    }

    private static func validHTTPURL(_ value: String) -> Bool {
        guard value.utf8.count <= 16_384, !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.fragment == nil else { return false }
        return true
    }
}
