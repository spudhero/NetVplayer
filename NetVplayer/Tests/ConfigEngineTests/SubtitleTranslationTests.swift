import Foundation
import Testing
import Models
import SubtitleEngine
@preconcurrency import Translation
@testable import NetVplayerApp

@Suite("Text subtitle translation contracts", .serialized)
@MainActor
struct SubtitleTranslationTests {
    private func document(_ texts: [String] = ["Hello, Mira.", "Keep the door open.", "We leave at dawn."]) throws -> SubtitleDocument {
        let source = texts.enumerated().map { index, text in
            "\(index + 1)\n00:00:\(String(format: "%02d", index * 2)),000 --> 00:00:\(String(format: "%02d", index * 2 + 2)),000\n\(text)\n"
        }.joined(separator: "\n")
        return try SubtitleDocument(data: Data(source.utf8), filename: "original.srt")
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-contract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func key(_ document: SubtitleDocument, language: String = "zh-Hans", version: String = "contract-1") -> SubtitleTranslationKey {
        .init(media: "stable-source/account/item", document: document, sourceLanguage: "en", targetLanguage: language,
              translator: .init(service: "contract-only", model: "fixture", version: version))
    }

    @Test func parserPreservesOverlapTimingAndDialogue() throws {
        let source = "[Script Info]\nScriptType: v4.00+\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.23,0:00:04.56,Default,,0,0,0,,{\\i1}Hello, Mira.\\NSecond line\nDialogue: 1,0:00:02.00,0:00:05.00,Default,,0,0,0,,Overlap\nDialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10\n"
        let doc = try SubtitleDocument(data: Data(source.utf8), filename: "source.ass")
        #expect(doc.cues.count == 2)
        #expect(doc.cues[0].start == 1.23 && doc.cues[0].end == 4.56)
        #expect(doc.cues[0].text == "Hello, Mira.\nSecond line")
        #expect(doc.cues[1].start == 2)
        let vtt = "WEBVTT\n\ncue-a\n00:01.000 --> 00:03.500 align:start\n<i>A &amp; B</i>\n"
        let parsed = try SubtitleDocument(data: Data(vtt.utf8), filename: "source.vtt")
        #expect(parsed.cues.first?.text == "A & B")
        #expect(parsed.cues.first?.end == 3.5)
    }

    @Test func stableFingerprintAndKeySeparateAllRelevantIdentity() throws {
        let doc = try document()
        #expect(doc.fingerprint == (try document()).fingerprint)
        #expect(key(doc).digest == key(doc).digest)
        #expect(key(doc).digest != key(doc, language: "ja").digest)
        #expect(key(doc).digest != key(doc, version: "contract-2").digest)
        #expect(key(doc).digest != key(try document(["Different"])).digest)
        let other = SubtitleTranslationKey(media: "another-account/item", document: doc, sourceLanguage: "en", targetLanguage: "zh-Hans", translator: key(doc).translator)
        #expect(other.digest != key(doc).digest)
        #expect(!other.digest.contains("account"))
    }

    @Test func invalidTimesAndOversizedTextAreRejected() throws {
        for value in ["1\n00:00:03,000 --> 00:00:01,000\nwrong\n", "1\n00:70:00,000 --> 00:71:00,000\nwrong\n"] {
            #expect(throws: (any Error).self) { try SubtitleDocument(data: Data(value.utf8), filename: "bad.srt") }
        }
        #expect(throws: (any Error).self) { try document([String(repeating: "x", count: 16_385)]) }
    }

    @Test func plannerSubmitsSmallBatchesImmediatelyAndUsesSpeedDeadline() throws {
        let doc = try document()
        let plan = try #require(SubtitleTranslationPlanner.next(document: doc, covered: [], position: 1, speed: 2, playing: true, now: 100))
        #expect(plan.cues.first?.id == 0)
        #expect(plan.deadline == 100.5)
        #expect(plan.context.isEmpty)
        let next = try #require(SubtitleTranslationPlanner.next(document: doc, covered: [0, 1], position: 3, speed: 1, playing: true, now: 100))
        #expect(next.cues.map(\.id) == [2])
        #expect(next.context.count == 2 && next.deadline == 101)
        #expect(SubtitleTranslationPlanner.next(document: doc, covered: [], position: .nan, speed: 1, playing: true, now: 100) == nil)
        #expect(SubtitleTranslationPlanner.next(document: doc, covered: [], position: 100, speed: 1, playing: true, now: 100) == nil)
        #expect(SubtitleTranslationPlanner.next(document: doc, covered: [], position: 100, speed: 1, playing: false, now: 100, completing: true)?.cues.first?.id == 0)
    }

    @Test func checkpointRestoresPartialThenPromotesOnlyFullCoverage() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document(), key = key(doc)
        let cache = SubtitleTranslationCache(directory: dir)
        let first = try await cache.merge(key: key, total: 3, translations: [0: "你好，米拉。"])
        #expect(!first.complete)
        let restarted = SubtitleTranslationCache(directory: dir)
        #expect(try await restarted.load(key: key, total: 3) == first)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(key.digest + ".partial.json").path))
        let full = try await restarted.merge(key: key, total: 3, translations: [1: "让门开着。", 2: "我们黎明出发。"])
        #expect(full.complete)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(key.digest + ".partial.json").path))
        #expect(try await cache.load(key: key, total: 3) == full)
        #expect(throws: (any Error).self) { try SubtitleExporter.render(document: doc, coverage: first, format: .srt) }
    }

    @Test func corruptCacheAndInvalidProviderIDsNeverBecomeComplete() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document(), key = key(doc), cache = SubtitleTranslationCache(directory: dir)
        await #expect(throws: (any Error).self) { try await cache.merge(key: key, total: 3, translations: [3: "bad"]) }
        await #expect(throws: (any Error).self) { try await cache.merge(key: key, total: 3, translations: [0: "  "]) }
        try Data("broken checkpoint".utf8).write(to: dir.appendingPathComponent(key.digest + ".partial.json"))
        await #expect(throws: (any Error).self) { try await cache.load(key: key, total: 3) }
    }

    @Test func exportRoundTripsSourceTimesAndDoesNotPromotePartialOrExecuteASSCommands() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document(), cache = SubtitleTranslationCache(directory: dir)
        let coverage = try await cache.merge(key: key(doc), total: 3, translations: [0: "你好 <米拉>", 1: "{\\p1}evil", 2: "黎明出发\n第二行"])
        for format in SubtitleExportFormat.allCases {
            for bilingual in [false, true] {
                let data = try SubtitleExporter.render(document: doc, coverage: coverage, format: format, bilingual: bilingual)
                let path = dir.appendingPathComponent("export." + format.rawValue)
                try SubtitleExporter.save(data, to: path)
                let parsed = try SubtitleDocument(data: Data(contentsOf: path), filename: path.lastPathComponent)
                #expect(parsed.cues.map(\.start) == doc.cues.map(\.start))
                #expect(parsed.cues.map(\.end) == doc.cues.map(\.end))
                #expect(parsed.cues.count == 3)
                if bilingual { #expect(parsed.cues[0].text.contains(doc.cues[0].text)) }
                if format == .ass { #expect(!String(decoding: data, as: UTF8.self).contains("{\\p1}")) }
            }
        }
        let original = try SubtitleExporter.render(document: doc, format: .srt)
        #expect(try SubtitleDocument(data: original, filename: "original.srt").cues == doc.cues)
    }

    @Test func completionUsesRealCheckpointsAndRestoredCuesAreNotRetranslated() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document(), key = key(doc), cache = SubtitleTranslationCache(directory: dir)
        _ = try await cache.merge(key: key, total: 3, translations: [0: "saved first"])
        let service = ContractTranslator(identity: key.translator)
        let session = SubtitleTranslationSession(cache: cache, budget: .init())
        try await session.bind(owner: UUID(), document: doc, key: key)
        session.completing = true
        await session.run(service: service)
        #expect(session.coverage?.complete == true)
        #expect(service.requests.flatMap { $0.cues.map(\.id) } == [1, 2])
        #expect(session.translation(at: 0.5) == "saved first")
        session.cancel()
        #expect(session.translation(at: 0.5) == nil)
    }

    @Test func seekDropsNoncooperativeOldResponseAndKeepsConcurrencyOne() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document(), key = key(doc), cache = SubtitleTranslationCache(directory: dir)
        let service = ContractTranslator(identity: key.translator, holdsFirst: true)
        let session = SubtitleTranslationSession(cache: cache, budget: .init())
        try await session.bind(owner: UUID(), document: doc, key: key)
        let runner = Task { await session.run(service: service) }
        try await wait { service.requests.count == 1 }
        session.update(position: 4.5, speed: 1, playing: false, seeking: true)
        service.releaseFirst()
        session.update(position: 4.5, speed: 1, playing: false, seeking: false)
        try await wait { session.coverage?.translations[2] != nil }
        session.cancel(); await runner.value
        #expect(session.coverage?.translations[0] == nil)
        #expect(service.maximumActive == 1)
        #expect(try await cache.load(key: key, total: 3).translations[0] == nil)
    }

    @Test func mediaChangeAndCancellationRejectLateCacheWrites() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document(), key = key(doc), cache = SubtitleTranslationCache(directory: dir)
        let service = ContractTranslator(identity: key.translator, holdsFirst: true)
        let session = SubtitleTranslationSession(cache: cache, budget: .init())
        try await session.bind(owner: UUID(), document: doc, key: key)
        let runner = Task { await session.run(service: service) }
        try await wait { service.requests.count == 1 }
        session.cancel()
        let other = try document(["Another media"])
        try await session.bind(owner: UUID(), document: other, key: self.key(other))
        service.releaseFirst(); await runner.value
        #expect(session.coverage?.translations.isEmpty == true)
        #expect(try await cache.load(key: key, total: 3).translations.isEmpty)
    }

    @Test func deadlineAndSharedBudgetDoNotAcceptExpiredResults() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document(), key = key(doc), cache = SubtitleTranslationCache(directory: dir)
        let budget = PlaybackBackgroundBudget()
        budget.update(session: "foreground", bufferedAhead: 0, isLoading: true, isSeeking: false, isBuffering: true)
        let service = ContractTranslator(identity: key.translator)
        let session = SubtitleTranslationSession(cache: cache, budget: budget)
        try await session.bind(owner: UUID(), document: doc, key: key)
        session.update(position: 1.98, speed: 1, playing: true, seeking: false)
        await session.run(service: service)
        #expect(service.requests.isEmpty)
        #expect(session.coverage?.translations.isEmpty == true)
        #expect(budget.activeBackgroundReads == 0 && budget.reservedBytes == 0)
        #expect(session.failure != nil)
    }

    @Test func noncooperativeResponseAfterDeadlineNeverWritesCache() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document(), key = key(doc), cache = SubtitleTranslationCache(directory: dir)
        let service = ContractTranslator(identity: key.translator, holdsFirst: true)
        let session = SubtitleTranslationSession(cache: cache, budget: .init())
        try await session.bind(owner: UUID(), document: doc, key: key)
        session.update(position: 1.98, speed: 1, playing: true, seeking: false)
        let runner = Task { await session.run(service: service) }
        try await wait { !service.requests.isEmpty }
        try await Task.sleep(for: .milliseconds(90))
        service.releaseFirst(); await runner.value
        #expect(session.failure != nil)
        #expect(try await cache.load(key: key, total: 3).translations.isEmpty)
    }

    @Test func modelOwnerAndLanguageChangesClearDisplayAndExportCoverage() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = SubtitleTranslationModel(session: .init(cache: .init(directory: dir), budget: .init()))
        let spec = PlaySpec(url: "file:///tmp/original.mkv")
        model.bind(spec)
        let data = try SubtitleExporter.render(document: document(), format: .srt)
        model.load(data: data, filename: "source.srt")
        #expect(model.document != nil && model.original != nil)
        model.invalidateLanguages()
        #expect(model.coverage == nil && !model.active)
        model.bind(PlaySpec(url: "file:///tmp/other.mkv"))
        #expect(model.document == nil && model.original == nil && model.coverage == nil)
    }

    @Test func retiredSessionNotificationsCannotRestoreOtherLanguageOrDocumentCoverage() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SubtitleTranslationCache(directory: dir)
        let model = SubtitleTranslationModel(session: .init(cache: cache, budget: .init()))
        let spec = PlaySpec(url: "file:///tmp/original.mkv")
        model.bind(spec)
        let owner = try #require(model.owner), doc = try document()
        model.load(data: try SubtitleExporter.render(document: doc, format: .srt), filename: "source.srt")
        let key = SubtitleTranslationKey(media: PlaybackMediaIdentity.resolved(for: spec)?.cacheKey ?? "session:" + owner.uuidString,
            document: doc, sourceLanguage: model.sourceLanguage, targetLanguage: model.targetLanguage,
            translator: SubtitleTranslationModel.appleIdentity)
        _ = try await cache.merge(key: key, total: 3, translations: [0: "one", 1: "two", 2: "three"])
        try await model.session.bind(owner: owner, document: doc, key: key)
        #expect(model.coverage?.complete == true)
        model.targetLanguage = "ja"; model.invalidateLanguages()
        // A draining request's defer emits another notification after cancellation.
        model.session.cancel()
        #expect(model.coverage == nil)
        model.targetLanguage = "zh-Hans"
        try await model.session.bind(owner: owner, document: doc, key: key)
        #expect(model.coverage?.complete == true)
        model.load(data: try SubtitleExporter.render(document: document(["Another subtitle"]), format: .srt), filename: "other.srt")
        model.session.cancel()
        #expect(model.coverage == nil)
    }

    @Test func completedTranslationIsIdleWhileRemainingUsableAndCanBeEnabledAgain() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = SubtitleTranslationModel(session: .init(cache: .init(directory: dir), budget: .init()))
        model.bind(PlaySpec(url: "file:///tmp/interface-contract.mkv"))
        model.load(data: try SubtitleExporter.render(document: document(), format: .srt), filename: "source.srt")
        model.start(completing: true)
        try await wait { model.active }
        #expect(model.isProcessing)
        let service = ContractTranslator(identity: SubtitleTranslationModel.appleIdentity)
        await model.session.run(service: service)
        #expect(model.coverage?.complete == true)
        #expect(model.active && !model.isProcessing)
        #expect(model.session.translation(at: 0.5) == "contract:Hello, Mira.")

        model.cancel()
        #expect(!model.active && !model.isProcessing)
        #expect(model.coverage?.complete == true)
        #expect(model.session.translation(at: 0.5) == nil)
        model.start(completing: false)
        try await wait { model.active }
        #expect(!model.isProcessing && model.requestID == nil)
        #expect(model.session.translation(at: 0.5) == "contract:Hello, Mira.")
        model.cancel()
    }

    @Test func failedTranslationReleasesBusyControlsAndRetryKeepsTheSessionOwner() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = SubtitleTranslationModel(session: .init(cache: .init(directory: dir), budget: .init()))
        model.bind(PlaySpec(url: "file:///tmp/interface-failure-contract.mkv"))
        model.load(data: try SubtitleExporter.render(document: document(), format: .srt), filename: "source.srt")
        let owner = model.owner
        model.start(completing: true)
        try await wait { model.active }
        await model.session.run(service: InterfaceFailureTranslator())
        #expect(model.session.failure != nil && !model.isProcessing)
        #expect(model.message != nil && model.coverage?.complete == false)
        model.start(completing: true)
        try await wait { model.isProcessing }
        #expect(model.owner == owner && model.session.failure == nil)
        await model.session.run(service: ContractTranslator(identity: SubtitleTranslationModel.appleIdentity))
        #expect(model.coverage?.complete == true && !model.isProcessing)
        model.cancel()
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate())
    }
}

@MainActor
private struct InterfaceFailureTranslator: SubtitleTranslationService {
    let identity = SubtitleTranslationModel.appleIdentity
    func translate(_ request: SubtitleTranslationRequest) async throws -> [Int: String] {
        throw SubtitleTranslationError.invalidResponse
    }
}

/// Synthetic contract provider only; this is not translation-quality evidence.
@MainActor
private final class ContractTranslator: SubtitleTranslationService {
    let identity: SubtitleTranslatorIdentity
    var requests: [SubtitleTranslationRequest] = []
    private let holdsFirst: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var active = 0
    var maximumActive = 0
    init(identity: SubtitleTranslatorIdentity, holdsFirst: Bool = false) { self.identity = identity; self.holdsFirst = holdsFirst }
    func translate(_ request: SubtitleTranslationRequest) async throws -> [Int: String] {
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        requests.append(request)
        if holdsFirst && requests.count == 1 { await withCheckedContinuation { continuation = $0 } }
        return Dictionary(uniqueKeysWithValues: request.cues.map { ($0.id, "contract:" + $0.text) })
    }
    func releaseFirst() { continuation?.resume(); continuation = nil }
}

#if compiler(>=6.2)
/// Opt-in live Apple service test. Requires the macOS 26 SDK, macOS 26 and installed language
/// assets; it neither substitutes responses nor requests a remote provider.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_APPLE_TRANSLATION_FIXTURE"] != nil))
func appleSubtitleNativeCheckpointResumeAndExport() async throws {
    guard #available(macOS 26.0, *) else {
        Issue.record("The explicitly requested installed-session test requires macOS 26")
        return
    }
    let input = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_APPLE_TRANSLATION_FIXTURE"])
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_APPLE_TRANSLATION_OUTPUT"]))
    try #require(!FileManager.default.fileExists(atPath: output.path), "Use a fresh output directory")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let source = Locale.Language(identifier: "en"), target = Locale.Language(identifier: "zh-Hans")
    let availability = await LanguageAvailability().status(from: source, to: target)
    try #require(availability == .installed, "Real language assets must already be installed")
    let systemSession = TranslationSession(installedSource: source, target: target)
    let service = AppleSubtitleTranslationService(session: systemSession)
    let data = try Data(contentsOf: URL(fileURLWithPath: input))
    let doc = try SubtitleDocument(data: data, filename: "corpus.srt")
    let key = SubtitleTranslationKey(media: "authored-native-corpus-v1", document: doc,
        sourceLanguage: "en", targetLanguage: "zh-Hans", translator: service.identity)
    let cache = SubtitleTranslationCache(directory: output.appendingPathComponent("cache"))
    let first = SubtitleTranslationSession(cache: cache, budget: .init())
    try await first.bind(owner: UUID(), document: doc, key: key)
    first.completing = true
    // Avoid reentrant cancellation notifications while keeping deterministic stop
    // immediately after the first genuinely translated checkpoint.
    first.changed = {
        if let coverage = first.coverage, !coverage.translations.isEmpty, !coverage.complete {
            first.changed = nil; first.cancel()
        }
    }
    let start = ProcessInfo.processInfo.systemUptime
    await first.run(service: service)
    let partial = try await cache.load(key: key, total: doc.cues.count)
    try #require(!partial.complete && !partial.translations.isEmpty)
    let partialCount = partial.translations.count
    let restoredCache = SubtitleTranslationCache(directory: output.appendingPathComponent("cache"))
    let resumed = SubtitleTranslationSession(cache: restoredCache, budget: .init())
    try await resumed.bind(owner: UUID(), document: doc, key: key)
    #expect(resumed.coverage == partial)
    resumed.completing = true
    await resumed.run(service: service)
    let full = try #require(resumed.coverage)
    try #require(full.complete, "Native translation must really complete, without a fixture fallback")
    for (id, text) in partial.translations { #expect(full.translations[id] == text) }
    for format in SubtitleExportFormat.allCases {
        for bilingual in [false, true] {
            let data = try SubtitleExporter.render(document: doc, coverage: full, format: format, bilingual: bilingual)
            let url = output.appendingPathComponent(bilingual ? "bilingual." + format.rawValue : "translated." + format.rawValue)
            try SubtitleExporter.save(data, to: url)
            let check = try SubtitleDocument(data: Data(contentsOf: url), filename: url.lastPathComponent)
            #expect(check.cues.map(\.start) == doc.cues.map(\.start))
            #expect(check.cues.map(\.end) == doc.cues.map(\.end))
        }
    }
    let report: [String: Any] = ["service": "Apple on-device, actual installed language assets",
        "source": "en", "target": "zh-Hans", "partialCountBeforeCancellation": partialCount,
        "restoredCount": partialCount, "finalCount": full.translations.count,
        "seconds": ProcessInfo.processInfo.systemUptime - start,
        "osBuild": ProcessInfo.processInfo.operatingSystemVersionString,
        "fixtureFingerprint": doc.fingerprint, "exportsReparsedWithSameTimeline": true]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-run.json"), options: .atomic)
}
#else
// Runtime availability cannot make an initializer visible to an older SDK.
@MainActor
@Test(.disabled("Requires the macOS 26 SDK (Xcode 26+) and installed language assets"))
func appleSubtitleNativeCheckpointResumeAndExport() async throws {}
#endif
