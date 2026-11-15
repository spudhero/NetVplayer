import Foundation

/// A disc and a selected playlist have different identities. Neither contains a renewable URL.
public struct DiscSelection: Codable, Equatable, Sendable {
    public var reference: FileResourceReference
    public var playlist: UInt32
    /// libbluray's zero-based angle index.
    public var angle: UInt32
    public init(reference: FileResourceReference, playlist: UInt32, angle: UInt32 = 0) {
        self.reference = reference; self.playlist = playlist; self.angle = angle
    }
    public var locator: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "nvdisc:" + ((try? encoder.encode(self)) ?? Data()).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public init?(locator: String) {
        guard locator.hasPrefix("nvdisc:"), locator.utf8.count < 32768 else { return nil }
        var encoded = String(locator.dropFirst(7)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let value = try? JSONDecoder().decode(Self.self, from: data),
              FileResourceReference(locator: value.reference.locator) != nil, value.playlist <= 99999, value.angle < 255 else { return nil }
        self = value
    }
    public var mediaIdentity: PlaybackMediaIdentity {
        .init(source: "bluray", account: reference.serviceID.uuidString,
              item: reference.path + "|playlist=\(playlist)|angle=\(angle)")
    }
}

public struct DiscChapter: Equatable, Sendable {
    public var seconds: Double
    public var title: String
    public var clip: UInt32
    public init(seconds: Double, title: String = "", clip: UInt32) { self.seconds = seconds; self.title = title; self.clip = clip }
}
public struct DiscClip: Equatable, Sendable {
    public var id: String
    public var start: Double
    public var inTime: Double
    public var outTime: Double
    public var duration: Double { outTime - inTime }
    public init(id: String, start: Double, inTime: Double, outTime: Double) {
        self.id = id; self.start = start; self.inTime = inTime; self.outTime = outTime
    }
}
public struct DiscTitle: Equatable, Sendable, Identifiable {
    public var playlist: UInt32
    public var duration: Double
    public var angles: UInt32
    public var clips: [DiscClip]
    public var chapters: [DiscChapter]
    public var id: UInt32 { playlist }
    public init(playlist: UInt32, duration: Double, angles: UInt32, clips: [DiscClip], chapters: [DiscChapter]) {
        self.playlist = playlist; self.duration = duration; self.angles = angles; self.clips = clips; self.chapters = chapters
    }
    public var displayName: String {
        String(format: "%05u · %02d:%02d:%02d", playlist,
               Int(duration) / 3600, Int(duration) / 60 % 60, Int(duration) % 60)
    }
}
public struct DiscCatalog: Equatable, Sendable {
    public var titles: [DiscTitle]
    /// A suggestion only; all playlists remain available for episodes and obfuscated discs.
    public var suggestedPlaylist: UInt32? { titles.max { $0.duration < $1.duration }?.playlist }
    public init(titles: [DiscTitle]) { self.titles = titles }
}

/// Runtime resources are opaque local aliases. Each segment contains libbluray's
/// selected playitem bytes; mpv EDL makes their independent PTS a continuous clock.
public struct DiscPlayback: Sendable {
    public var selection: DiscSelection
    public var title: DiscTitle
    public var segmentURLs: [String]
    public init(selection: DiscSelection, title: DiscTitle, segmentURLs: [String]) {
        self.selection = selection; self.title = title; self.segmentURLs = segmentURLs
    }
    public func edl(urls: [String]? = nil) -> String {
        let urls = urls ?? segmentURLs
        guard urls.count == title.clips.count else { return "" }
        return "edl://!no_chapters;" + zip(urls, title.clips).map { url, clip in
            // MPEG-TS keeps its disc PTS (often starting at 600 seconds).
            // EDL start is on that source clock even for a cropped playitem.
            "%\(url.utf8.count)%\(url)," + String(format: "%.9f,%.9f", locale: Locale(identifier: "en_US_POSIX"), clip.inTime, clip.duration)
        }.joined(separator: ";")
    }
}

/// Position and duration remain on History's title timeline. Track choices belong
/// to this exact playlist/angle and never leak into another title.
public struct DiscResume: Codable, Equatable, Sendable {
    public var selection: DiscSelection
    public var audioTrackID: String?
    public var subtitleTrackID: String?
    public init(selection: DiscSelection, audioTrackID: String? = nil, subtitleTrackID: String? = nil) {
        self.selection = selection; self.audioTrackID = audioTrackID; self.subtitleTrackID = subtitleTrackID
    }
}

public enum DiscMediaPolicy {
    public static func isISO(_ name: String) -> Bool { (name as NSString).pathExtension.lowercased() == "iso" }
    public static func isBDMV(_ entry: FileEntry) -> Bool { entry.isDirectory && entry.name.caseInsensitiveCompare("BDMV") == .orderedSame }
}
