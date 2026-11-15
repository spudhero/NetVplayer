import Foundation
import CoreFoundation
import Combine
import Models

/// Numeric facts from the current mpv batch; never infer one quantity from another.
public struct PlaybackStatistics: Equatable, Codable, Sendable {
    public let estimatedOutputFPS: Double?
    public let videoBitsPerSecond: Double?
    public let audioBitsPerSecond: Double?

    init(properties: [String: Data]) {
        estimatedOutputFPS = Self.number(properties["estimated-vf-fps"], maximum: 1_000)
        videoBitsPerSecond = Self.number(properties["video-bitrate"])
        audioBitsPerSecond = Self.number(properties["audio-bitrate"])
    }

    static func number(_ data: Data?, maximum: Double = 1e12) -> Double? {
        guard let data, data.count <= PlaybackDiagnosticsSampler.maximumPropertyBytes,
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue > 0, n.doubleValue <= maximum else { return nil }
        return n.doubleValue
    }

    public static func fps(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0, value <= 1_000 else { return nil }
        return String(format: "%.3f fps", value)
    }

    public static func bitrate(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0, value <= 1e12 else { return nil }
        return value >= 1_000_000 ? String(format: "%.2f Mbit/s", value / 1_000_000)
            : String(format: "%.1f kbit/s", value / 1_000)
    }

    public static func downloadSpeed(_ bytes: Int64?) -> String? {
        guard let bytes, bytes >= 0 else { return nil }
        return bytes >= 1_000_000 ? String(format: "%.2f MB/s", Double(bytes) / 1_000_000)
            : String(format: "%.1f kB/s", Double(bytes) / 1_000)
    }
}

/// Consumers own leases so two panels cannot turn each other's sampling off.
public struct PlaybackStatisticsVisibility {
    private var consumers: Set<UUID> = []
    public private(set) var generation: UInt64 = 0
    public var isVisible: Bool { !consumers.isEmpty }
    public init() {}

    public mutating func setVisible(_ visible: Bool, consumer: UUID) {
        let wasVisible = isVisible
        if visible { consumers.insert(consumer) } else { consumers.remove(consumer) }
        if wasVisible != isVisible { generation &+= 1 }
    }
}

/// Source facts only: no device, current decoder/output, position or packet bitrate.
public struct PlaybackStaticSummary: Equatable, Sendable {
    public let videoCodec: String?
    public let width: Int?
    public let height: Int?
    public let bitDepth: Int?
    public let nominalFPS: Double?
    public let sourceRange: String?
    public let audioCodec: String?
    public let sampleRate: Int?
    public let channels: Int?

    init(_ info: PlaybackDiagnostics) {
        videoCodec = info.video.codec
        width = info.video.width; height = info.video.height
        bitDepth = info.video.bitDepth; nominalFPS = info.video.framesPerSecond
        sourceRange = info.video.transfer == nil && info.video.matrix != "dolbyvision" ? nil : info.video.signalDescription
        audioCodec = info.audio.codec
        sampleRate = info.audio.sourceSampleRate; channels = info.audio.sourceChannelCount
    }

    var hasFacts: Bool { videoCodec != nil || audioCodec != nil || width != nil }
}

enum PlaybackLocalInputSizePolicy {
    /// Counts only the explicitly selected local input file. This does not prove
    /// that the input is a complete movie, so it must never be labeled full media size.
    /// HTTP Content-Length, Range, cache and playlists cannot supply this value.
    static func bytes(spec: PlaySpec, nativeSize: String?) -> Int64? {
        guard let file = spec.userOpenedLocalFile, file.isFileURL,
              file.absoluteString == spec.url, spec.metadata["playback.kind"] != "live",
              spec.liveCatchup == nil, spec.disc == nil, spec.externalAudioURL.isEmpty,
              spec.mpvOptions["start"] == nil, spec.mpvOptions["end"] == nil,
              spec.metadata["bili.cache.videoPath"] == nil,
              ["mkv", "mp4", "mov", "m4v", "avi", "webm", "mp3", "flac", "wav", "m4a", "ogg"]
                .contains(file.pathExtension.lowercased()),
              let nativeSize, let size = Int64(nativeSize), size > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == size else { return nil }
        return size
    }
}

/// Bounded memory, static-only notifications, exact identities and current owner.
@MainActor
public final class PlaybackSummaryStore: ObservableObject {
    @Published public private(set) var revision: UInt64 = 0
    private var values: [PlaybackSummaryIdentity: PlaybackStaticSummary] = [:]
    private var recency: [PlaybackSummaryIdentity] = []
    private var active: (identity: PlaybackSummaryIdentity, mediaID: UUID)?
    public let capacity: Int
    public var count: Int { values.count }

    public init(capacity: Int = 64) { self.capacity = max(1, min(64, capacity)) }
    public func summary(for identity: PlaybackSummaryIdentity) -> PlaybackStaticSummary? { values[identity] }

    func begin(identity: PlaybackSummaryIdentity?, mediaID: UUID) {
        active = identity.map { ($0, mediaID) }
    }

    func receive(_ info: PlaybackDiagnostics) {
        guard let active, active.mediaID == info.mediaID else { return }
        let summary = PlaybackStaticSummary(info)
        guard summary.hasFacts else { return }
        recency.removeAll { $0 == active.identity }
        recency.append(active.identity)
        guard values[active.identity] != summary else { return }
        values[active.identity] = summary
        while recency.count > capacity { values.removeValue(forKey: recency.removeFirst()) }
        revision &+= 1
    }

    func end() { active = nil }
    public func invalidate() {
        active = nil
        guard !values.isEmpty else { return }
        values.removeAll(); recency.removeAll(); revision &+= 1
    }
}
