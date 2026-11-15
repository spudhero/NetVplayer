import Foundation

/// Evidence from the active TrueHD decoder, scoped to its current seek/stream.
/// Decoder output is distinct from physical speaker delivery and listening tests.
public struct ObjectAudioObservation: Equatable, Codable, Sendable {
    public let mode: Int
    public let sampleRate: Int
    public let presentation: Int
    public let elements: Int
    public let hasObjects: Bool
    public let metadataSeen: Bool
    public let frames: Int64
    public let objectBlocks: Int64
    public let metadataUpdates: Int64
    public let fallbackBlocks: Int64
    public let decodeErrors: Int64
    public let syncErrors: Int64
    public let metadataErrors: Int64
    public let binauralFrames: Int64
    public let trackingRequested: Bool
    public let trackingActive: Bool
    public let poses: Int64
    public let poseAge: Double

    public var hasRenderedObjects: Bool {
        hasObjects && metadataSeen && presentation == 3 && objectBlocks > 0 && metadataUpdates > 0
    }
    public var hasFallback: Bool { fallbackBlocks > 0 || decodeErrors > 0 || syncErrors > 0 || metadataErrors > 0 }
    public var isBinaural: Bool { mode >= 2 && binauralFrames > 0 }
    public var hasLiveTracking: Bool {
        mode == 3 && trackingRequested && trackingActive && poses > 0 && poseAge >= 0 && poseAge < 0.5
    }

    init?(_ object: [String: Any]) {
        func count(_ key: String) -> Int64? { (object[key] as? Int64).flatMap { $0 >= 0 ? $0 : nil } }
        guard let mode = object["mode"] as? Int, (1...3).contains(mode),
              let rate = object["samplerate"] as? Int, (8_000...192_000).contains(rate),
              let presentation = object["presentation"] as? Int, (0...3).contains(presentation),
              let elements = object["elements"] as? Int, (1...16).contains(elements),
              let hasObjects = object["has-objects"] as? Bool, let metadataSeen = object["metadata-seen"] as? Bool,
              let frames = count("frames"), let blocks = count("object-blocks"), let updates = count("metadata-updates"),
              let fallback = count("fallback-blocks"), let decode = count("decode-errors"),
              let sync = count("sync-errors"), let metadata = count("metadata-errors"),
              let binaural = count("binaural-frames"), let poses = count("poses"),
              let requested = object["tracking-requested"] as? Bool, let active = object["tracking-active"] as? Bool,
              let age = object["pose-age"] as? Double, age.isFinite else { return nil }
        self.mode = mode; sampleRate = rate; self.presentation = presentation; self.elements = elements
        self.hasObjects = hasObjects; self.metadataSeen = metadataSeen; self.frames = frames
        objectBlocks = blocks; metadataUpdates = updates; fallbackBlocks = fallback
        decodeErrors = decode; syncErrors = sync; metadataErrors = metadata; binauralFrames = binaural
        trackingRequested = requested; trackingActive = active; self.poses = poses; poseAge = age
    }
}
