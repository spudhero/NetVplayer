import Foundation
import Testing
import Models
import Storage
@testable import DanmakuEngine

struct DanmakuPlaybackTests {
    @Test func clockFollowsRateAndStopsForPauseBufferAndSeek() {
        var clock = DanmakuPlaybackClock()
        clock.synchronize(position: 10, uptime: 100, rate: 2, playing: true, buffering: false, seeking: false, epoch: "one")
        #expect(clock.position(at: 100.25) == 10.5)
        clock.synchronize(position: 10.5, uptime: 100.25, rate: 2, playing: true, buffering: true, seeking: false, epoch: "one")
        #expect(clock.position(at: 110) == 10.5)
        clock.synchronize(position: 3, uptime: 110, rate: 1, playing: false, buffering: false, seeking: true, epoch: "one")
        #expect(clock.position(at: 111) == 3)
        let before = clock.revision
        clock.synchronize(position: 0, uptime: 112, rate: 1, playing: true, buffering: false, seeking: false, epoch: "two")
        #expect(clock.revision > before)
        #expect(clock.position(at: 113) == 1)
    }

    @Test func wideFastCuesCannotCatchUpToShortCues() {
        var layout = DanmakuLaneLayout()
        let cues = (0..<100).map { index in
            DanmakuCue(id: String(index), timeMs: index * 180, text: index.isMultiple(of: 2) ? "short" : "wide")
        }
        layout.replace(cues: cues)
        for step in 0..<1_400 {
            let time = Double(step) / 60
            let sprites = layout.advance(to: time, width: 800, height: 220, laneHeight: 40, revision: 1) { $0.text == "short" ? 50 : 600 }
            for lane in 0..<3 {
                let row = sprites.filter { $0.lane == lane }.sorted { $0.x(at: time) < $1.x(at: time) }
                for pair in zip(row, row.dropFirst()) {
                    #expect(pair.0.x(at: time) + pair.0.width <= pair.1.x(at: time) + 0.001)
                }
            }
        }
        #expect(layout.droppedCount > 0)
    }

    @Test func seekRebuildsWindowAndDenseBurstIsBounded() {
        var layout = DanmakuLaneLayout()
        layout.replace(cues: (0..<5_000).map { DanmakuCue(id: String($0), timeMs: 1_000, text: "cue") })
        let frame = layout.advance(to: 1, width: 800, height: 600, laneHeight: 40, revision: 1) { _ in 80 }
        #expect(frame.count <= DanmakuLaneLayout.maximumVisible)
        #expect(layout.droppedCount >= 5_000 - DanmakuLaneLayout.maximumVisible)
        #expect(layout.advance(to: 20, width: 800, height: 600, laneHeight: 40, revision: 2) { _ in 80 }.isEmpty)
        #expect(!layout.advance(to: 1, width: 800, height: 600, laneHeight: 40, revision: 3) { _ in 80 }.isEmpty)
    }

    @Test func parserRetainsEarliestCuesWithinBudgetAndRejectsUnsafePayloads() {
        let payload = (0..<6_000).reversed().map { "\($0)|cue" }.joined(separator: "\n")
        let result = DanmakuPayloadParser.parseWithDiagnostic(payload: payload, format: .text)
        #expect(result.cues.count == 5_000)
        #expect(result.cues.last?.timeMs == 4_999_000)
        #expect(result.diagnostic.truncatedCount == 1_000)
        let xml = "<!DOCTYPE i [<!ENTITY e 'bad'>]><i><d p='inf,1,25,0'>&e;</d></i>"
        #expect(DanmakuPayloadParser.parseWithDiagnostic(payload: xml, format: .xml).diagnostic.failureCategory == .invalidXML)
        let huge = String(repeating: "x", count: DanmakuPayloadParser.maximumPayloadBytes + 1)
        #expect(DanmakuPayloadParser.parseWithDiagnostic(payload: huge, format: .text).diagnostic.failureCategory == .payloadTooLarge)
        #expect(DanmakuPayloadParser.parse(payload: "inf|cue", format: .text).first?.timeMs == 0)
    }

    @Test func fileImportCopiesPayloadAndBindingsSeparateEpisodesAndSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = StorageManager(storageDirectory: directory)
        let file = directory.appendingPathComponent("comments.xml")
        try Data("<i><d p='1,1,25,16777215'>hello</d></i>".utf8).write(to: file)
        let engine = DanmakuEngine(storage: storage)
        let match = try engine.importFile(file)
        try FileManager.default.removeItem(at: file)
        #expect(engine.cachedPayload(cacheKey: match.track.cacheKey)?.contains("hello") == true)
        let bindings = DanmakuBindingStore(storage: storage)
        let attachment = DanmakuAttachment(sourceID: "local", trackCacheKey: match.track.cacheKey)
        let first = PlaySpec(url: "play", metadata: ["vod.id": "v", "vod.episodeURL": "e1", "library.sourceFingerprint": "a"], siteKey: "s")
        try bindings.save(attachment, for: first)
        var other = first
        other.metadata["vod.episodeURL"] = "e2"
        #expect(bindings.attachment(for: other) == nil)
        other = first
        other.metadata["library.sourceFingerprint"] = "b"
        #expect(bindings.attachment(for: other) == nil)
        #expect(DanmakuBindingStore(storage: storage).attachment(for: first) == attachment)
    }

    @Test func candidateEnvelopeKeepsSeasonYearAndVersionDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = DanmakuEngine(storage: StorageManager(storageDirectory: directory))
        let source = DanmakuSource(id: "source", name: "Source", apiURL: "https://source.invalid/search")
        let payload = #"{"matches":[{"title":"Same title","season":1,"episode":2,"year":2024,"version":"TV","url":"/one.xml"},{"title":"Same title","season":2,"episode":2,"year":2025,"version":"Director cut","url":"/two.xml"}]}"#
        let matches = try #require(engine.decodeCandidates(payload, source: source, request: .init(title: "Same title")))
        #expect(matches.count == 2)
        #expect(matches[0].id != matches[1].id)
        #expect(matches[1].season == 2)
        #expect(matches[1].year == 2025)
        #expect(matches[1].version == "Director cut")
        #expect(matches[0].track.contentURL == "https://source.invalid/one.xml")
    }
}
