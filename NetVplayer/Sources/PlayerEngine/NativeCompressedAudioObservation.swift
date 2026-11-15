import Foundation

/// Facts from the active AVSampleBufferAudioRenderer. Acceptance and preserved
/// JOC data do not, by themselves, prove a receiver's mode or head tracking.
public struct NativeCompressedAudioObservation: Equatable, Codable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public var rendererState: Int
    public var joc: Bool
    public var spatialAllowed: Bool
    /// Read back from AVSampleBufferAudioRenderer, independent of UI preference.
    public var rendererMuted: Bool?
    public var rendererVolume: Double?
    public var packets: Int64
    public var payloadBytes: Int64
    public var generation: Int64
    public var isRendering: Bool { rendererState == 1 && packets > 0 && payloadBytes > 0 }

    init?(_ object: [String: Any]) {
        guard let rate = object["samplerate"] as? Int, (8_000...192_000).contains(rate),
              let channels = object["channels"] as? Int, (1...32).contains(channels),
              let state = object["renderer-state"] as? Int, (0...2).contains(state),
              let packets = object["packets"] as? Int64, packets >= 0,
              let bytes = object["payload-bytes"] as? Int64, bytes >= 0,
              let generation = object["generation"] as? Int64, generation >= 0,
              let joc = object["joc"] as? Bool, let spatial = object["spatial-allowed"] as? Bool else { return nil }
        self.sampleRate = rate; self.channels = channels; self.rendererState = state
        self.packets = packets; self.payloadBytes = bytes; self.generation = generation
        self.joc = joc; self.spatialAllowed = spatial
        self.rendererMuted = object["renderer-muted"] as? Bool
        self.rendererVolume = (object["renderer-volume"] as? Double)
            .flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
    }
}
