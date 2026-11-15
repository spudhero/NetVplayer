import Foundation

public struct SubtitleTranslatorIdentity: Codable, Hashable, Sendable {
    public let service: String
    public let model: String
    public let version: String
    public init(service: String, model: String, version: String) {
        self.service = service; self.model = model; self.version = version
    }
}

public struct SubtitleTranslationRequest: Sendable {
    public let cues: [SubtitleCue]
    public let context: [SubtitleCue]
    public let sourceLanguage: String
    public let targetLanguage: String
    /// Monotonic wall-clock deadline, independent of system date changes.
    public let deadline: TimeInterval
}

@MainActor
public protocol SubtitleTranslationService: Sendable {
    var identity: SubtitleTranslatorIdentity { get }
    func translate(_ request: SubtitleTranslationRequest) async throws -> [Int: String]
}

public struct SubtitleTranslationPlan: Sendable {
    public let cues: [SubtitleCue]
    public let context: [SubtitleCue]
    public let deadline: TimeInterval
}

public enum SubtitleTranslationPlanner {
    /// Submit immediately: count and byte limits are caps, never batching thresholds.
    public static func next(document: SubtitleDocument, covered: Set<Int>, position: Double,
                            speed: Double, playing: Bool, now: TimeInterval,
                            completing: Bool = false) -> SubtitleTranslationPlan? {
        guard position.isFinite, speed.isFinite, speed > 0, now.isFinite else { return nil }
        let pending = document.cues.filter { !covered.contains($0.id) }
        // Current/future cues first; an explicit completion pass fills earlier gaps.
        let first = pending.first { $0.end > position } ?? (completing ? pending.first : nil)
        guard let first else { return nil }
        var cues: [SubtitleCue] = [], bytes = 0
        for cue in pending where cue.start >= first.start {
            guard completing || cue.start <= position + 45 else { break }
            guard cues.count < 8, bytes + cue.text.utf8.count <= 16_384,
                  cues.isEmpty || cue.start - first.start <= 15 else { break }
            cues.append(cue); bytes += cue.text.utf8.count
        }
        guard !cues.isEmpty else { return nil }
        let context = document.cues.filter { $0.id < first.id }.suffix(3)
        let usefulUntil = first.start > position ? first.start : first.end
        let timeout = completing || !playing ? 20 : min(20, max(0.05, (usefulUntil - position) / speed))
        return .init(cues: cues, context: Array(context), deadline: now + timeout)
    }
}
