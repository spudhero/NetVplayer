import Foundation
import Models

public struct SubtitleRecognitionSpan: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}
public protocol SubtitleRecognitionService: Sendable {
    var identity: SubtitleTranslatorIdentity { get }
    var kind: SubtitleRecognitionKind { get }
    func recognize(_ payload: SubtitleRecognitionPayload, unit: SubtitleRecognitionUnit,
                   language: String, deadline: TimeInterval) async throws -> [SubtitleRecognitionSpan]
}

/// Recognition checkpoints use the same atomic coverage store as text translation.
/// A JSON [] is a genuinely processed silent/blank unit, never invented dialogue.
@MainActor
public final class SubtitleRecognitionSession {
    public private(set) var coverage: SubtitleTranslationCoverage?
    public private(set) var document: SubtitleDocument?
    public private(set) var generation: UInt64 = 0
    public private(set) var owner: UUID?
    public private(set) var failure: (any Error)?
    public var changed: (@MainActor () -> Void)?
    private var source: SubtitleRecognitionSource?
    private var key: SubtitleTranslationKey?
    private var readSession = PlaybackReadSession()
    private var position = 0.0, speed = 1.0
    private var seeking = false, stopped = true, running = false
    private var operation: Task<[SubtitleRecognitionSpan], Error>?
    private let cache: SubtitleTranslationCache
    private let budget: PlaybackBackgroundBudget
    public init(cache: SubtitleTranslationCache = .shared, budget: PlaybackBackgroundBudget = .shared) { self.cache = cache; self.budget = budget }

    public func bind(owner: UUID, media: String, source: SubtitleRecognitionSource, language: String,
                     service: any SubtitleRecognitionService) async throws {
        cancel(); self.owner = owner; self.source = source; failure = nil; document = nil; coverage = nil
        guard source.kind == service.kind else { throw SubtitleRecognitionError.unsupported }
        let key = SubtitleTranslationKey(media: media, document: try source.cacheDocument(), sourceLanguage: language,
            targetLanguage: "recognition", translator: service.identity)
        self.key = key
        let generation = generation
        let restored = try await cache.load(key: key, total: source.units.count)
        try Task.checkCancellation()
        guard self.owner == owner, self.generation == generation else { throw CancellationError() }
        try Self.validate(restored, source: source)
        coverage = restored; stopped = false; document = try Self.document(restored, source: source); changed?()
    }
    public func cancel() {
        generation &+= 1; stopped = true; operation?.cancel(); readSession.stop(); readSession = PlaybackReadSession()
        changed?()
    }
    public func reset() { cancel(); owner = nil; key = nil; source = nil; coverage = nil; document = nil; failure = nil; changed?() }
    public func update(position: Double, speed: Double, seeking: Bool, discontinuity: Bool = false) {
        guard position.isFinite, speed.isFinite, speed > 0 else { return }
        if discontinuity || (seeking && !self.seeking) || abs(position-self.position) > 3 || speed != self.speed {
            generation &+= 1; operation?.cancel(); readSession.advance()
        }
        self.position = max(0,position); self.speed = speed; self.seeking = seeking
    }
    public func run(service: any SubtitleRecognitionService, requestTimeout: Double = 120) async {
        guard let owner, let key, key.translator == service.identity, let source else { return }
        while running { do { try await Task.sleep(for: .milliseconds(25)) } catch { return } }
        guard !stopped, self.owner == owner, self.key == key, !Task.isCancelled else { return }
        running = true
        defer { running = false; operation = nil; changed?() }
        while !Task.isCancelled, !stopped, self.owner == owner, self.key == key {
            guard let coverage, !coverage.complete else { return }
            if seeking { do { try await Task.sleep(for: .milliseconds(50)) } catch { return }; continue }
            let pending = source.units.filter { coverage.translations[$0.id] == nil }
            guard let unit = pending.first(where: { $0.end > position }) ?? pending.first else { return }
            let generation = generation
            let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, min(120,requestTimeout))
            let readOwner = readSession.makeOwner(mediaIdentity: .init(source: "recognition", account: "local", item: key.media), purpose: .subtitleExtraction, expiry: deadline)
            let budget = budget
            let task = Task {
                try await readOwner.perform {
                    let payload = try await source.payload(for: unit, owner: readOwner)
                    let bytes: Int
                    switch payload { case .bitmap(let data), .audio(let data, _, _, _): bytes = data.count }
                    return try await budget.withRead(owner: readOwner, purpose: .subtitleExtraction, bytes: Int64(bytes)) {
                        try readOwner.check()
                        return try await service.recognize(payload, unit: unit, language: key.sourceLanguage, deadline: deadline)
                    }
                }
            }
            operation = task
            let expiry = Task { do { try await Task.sleep(for: .seconds(max(0,deadline-ProcessInfo.processInfo.systemUptime))); task.cancel() } catch {} }
            do {
                let spans = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                expiry.cancel(); readOwner.cancel(); try Task.checkCancellation()
                guard !stopped, self.owner == owner, self.key == key, self.generation == generation else { continue }
                guard !task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw SubtitleRecognitionError.expired }
                try Self.validate(spans, unit: unit)
                let text = String(decoding: try SubtitleDocument.canonicalEncoder().encode(spans), as: UTF8.self)
                guard text.utf8.count <= 32_768 else { throw SubtitleRecognitionError.limitExceeded }
                let saved = try await cache.merge(key: key, total: source.units.count, translations: [unit.id:text])
                guard !stopped, self.owner == owner, self.key == key, self.generation == generation else { continue }
                self.coverage = saved; document = try Self.document(saved, source: source); failure = nil; changed?()
            } catch {
                expiry.cancel(); readOwner.cancel()
                if Task.isCancelled || stopped || self.owner != owner || self.key != key { return }
                if self.generation != generation { continue }
                failure = error; changed?(); return
            }
        }
    }
    private static func validate(_ spans: [SubtitleRecognitionSpan], unit: SubtitleRecognitionUnit) throws {
        guard spans.count <= 1000, spans.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= unit.inputStart - 0.001
            && $0.end <= unit.inputEnd + 0.1 && $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.text.utf8.count <= 16_384 && !$0.text.contains("\0") }) else { throw SubtitleRecognitionError.invalidResponse }
    }
    private static func validate(_ coverage: SubtitleTranslationCoverage, source: SubtitleRecognitionSource) throws {
        for (id,text) in coverage.translations {
            guard source.units.indices.contains(id), let data=text.data(using:.utf8),
                  let spans=try? JSONDecoder().decode([SubtitleRecognitionSpan].self,from:data) else { throw SubtitleTranslationError.invalidCache }
            do { try validate(spans,unit:source.units[id]) } catch { throw SubtitleTranslationError.invalidCache }
        }
    }
    private static func document(_ coverage: SubtitleTranslationCoverage, source: SubtitleRecognitionSource) throws -> SubtitleDocument? {
        guard coverage.complete else { return nil }
        try validate(coverage,source:source)
        let spans = try source.units.flatMap { unit -> [SubtitleRecognitionSpan] in
            try JSONDecoder().decode([SubtitleRecognitionSpan].self,from:Data(coverage.translations[unit.id]!.utf8))
        }
        let merged = SubtitleRecognitionTimeline.merge(spans, audio: source.kind == .audio)
        return merged.isEmpty ? nil : try SubtitleDocument(cues: merged.enumerated().map { .init(id:$0.offset,start:$0.element.start,end:$0.element.end,text:$0.element.text) })
    }
}

public enum SubtitleRecognitionTimeline {
    /// Merge actual timed overlap; context words can fill omissions in a neighbor.
    /// Equal words at different times remain real repeated speech.
    public static func merge(_ spans: [SubtitleRecognitionSpan], audio: Bool) -> [SubtitleRecognitionSpan] {
        let ordered=spans.enumerated().sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }.map(\.element)
        guard audio else { return ordered }
        var words: [SubtitleRecognitionSpan] = []
        for span in ordered {
            let token=span.text.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
            // Timing evidence is required: never deduplicate equal words just by text.
            let duplicate=words.suffix(8).contains { previous in
                let overlap=min(previous.end,span.end)-max(previous.start,span.start)
                return previous.text.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() == token
                    && overlap > min(previous.end-previous.start,span.end-span.start)*0.5
                    && abs(previous.start-span.start) < 0.4
            }
            if !duplicate { words.append(span) }
        }
        var result: [SubtitleRecognitionSpan] = []
        for span in words {
            if let last=result.last, span.start-last.end < 0.8, span.end-last.start <= 5 {
                result[result.count-1] = .init(start:last.start,end:max(last.end,span.end),text:join(last.text,span.text))
            } else { result.append(span) }
        }
        return result.map { .init(start:$0.start,end:$0.end,text:$0.text.trimmingCharacters(in:.whitespacesAndNewlines)) }
    }
    private static func join(_ left: String, _ right: String) -> String {
        guard let last=left.last, let first=right.first, !last.isWhitespace, !first.isWhitespace,
              first.isLetter || first.isNumber else { return left+right }
        let cjk: (Character) -> Bool = { character in
            character.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
        }
        return left + (cjk(last) || cjk(first) ? "" : " ") + right
    }

}
