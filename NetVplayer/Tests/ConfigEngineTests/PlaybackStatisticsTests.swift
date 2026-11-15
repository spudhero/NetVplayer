import Foundation
import Combine
import Testing
import Models
import Storage
@testable import PlayerEngine
@testable import NetVplayerApp

@Suite(.serialized)
struct PlaybackStatisticsTests {
    private func data(_ values: [String: Any]) throws -> [String: Data] {
        try values.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
    }
    private func facts(_ owner: UUID, codec: String = "h264") throws -> PlaybackDiagnostics {
        PlaybackDiagnostics(mediaID: owner, properties: try data([
            "current-tracks/video": ["codec": codec],
            "video-dec-params": ["w": 640, "h": 360, "gamma": "bt.709", "pixelformat": "yuv420p"],
            "container-fps": 24, "estimated-vf-fps": 23.98, "video-bitrate": 8_000_000,
            "audio-bitrate": 128_000
        ]))
    }
    private func identity(_ episode: String, scope: String = "source-r1-account1", vod: String = "same-name",
                          line: String = "line1") -> PlaybackSummaryIdentity {
        .init(scope: scope, site: "site1", vod: vod, line: line, episode: episode)
    }

    @Test func unitsAndSourcesNeverSubstitute() throws {
        let stats = PlaybackStatistics(properties: try data([
            "container-fps": 24, "estimated-vf-fps": 48, "video-bitrate": 8_000_000,
            "audio-bitrate": 128_000, "cache-speed": 2_000_000, "file-size": 999_999
        ]))
        #expect(stats.estimatedOutputFPS == 48)
        #expect(stats.videoBitsPerSecond == 8_000_000)
        #expect(PlaybackStatistics.bitrate(stats.videoBitsPerSecond) == "8.00 Mbit/s")
        #expect(PlaybackStatistics.downloadSpeed(2_000_000) == "2.00 MB/s")
        #expect(PlaybackStatistics.downloadSpeed(0) == "0.0 kB/s")
        let missing = PlaybackStatistics(properties: try data(["container-fps": 24, "cache-speed": 8_000_000]))
        #expect(missing.estimatedOutputFPS == nil && missing.videoBitsPerSecond == nil)
    }

    @Test(arguments: ["null", "true", "-1", "0", "1e999", "\"NaN\"", "\"Infinity\"", "NaN", "1e13"])
    func invalidNumbersRemainUnknown(json: String) {
        let stats = PlaybackStatistics(properties: ["estimated-vf-fps": Data(json.utf8), "video-bitrate": Data(json.utf8)])
        #expect(stats.estimatedOutputFPS == nil)
        #expect(stats.videoBitsPerSecond == nil)
    }
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -1, 0])
    func formattersRejectNonfinite(value: Double) {
        #expect(PlaybackStatistics.fps(value) == nil && PlaybackStatistics.bitrate(value) == nil)
    }

    @Test func leasesAndGenerationRejectClosedPanelBatch() {
        var visibility = PlaybackStatisticsVisibility()
        let first = UUID(), second = UUID()
        visibility.setVisible(true, consumer: first)
        let generation = visibility.generation
        visibility.setVisible(true, consumer: second)
        visibility.setVisible(false, consumer: first)
        #expect(visibility.isVisible && visibility.generation == generation)
        visibility.setVisible(false, consumer: second)
        visibility.setVisible(true, consumer: first)
        #expect(visibility.generation != generation)
        var sampler = PlaybackDiagnosticsSampler()
        let owner = UUID()
        let hidden = sampler.begin(owner: owner, now: 0)
        #expect(!hidden.contains { PlaybackDiagnosticsSampler.presentationProperties.contains($0.name) })
        for name in ["audio-params", "audio-out-params", "current-ao", "netvplayer-audio", "video-dec-params", "video-params"] {
            #expect(hidden.contains { $0.name == name })
        }
        sampler.reset()
        let shown = sampler.begin(owner: owner, now: 1, additionalProperties: PlaybackDiagnosticsSampler.presentationProperties,
                                  presentationGeneration: visibility.generation)
        #expect(shown.count == hidden.count + PlaybackDiagnosticsSampler.presentationProperties.count)
        #expect(sampler.presentationGeneration == visibility.generation)
        visibility.setVisible(false, consumer: first)
        #expect(sampler.presentationGeneration != visibility.generation)
    }

    @MainActor @Test func cacheUsesExactMediaIdentityAndOwnerAndPublishesOnlyStaticChanges() throws {
        let store = PlaybackSummaryStore(capacity: 3)
        let a = UUID(), b = UUID()
        let keyA = identity("fileA"), keyB = identity("fileB")
        store.begin(identity: keyA, mediaID: a)
        store.receive(try facts(a))
        let revision = store.revision
        var dynamic = try facts(a)
        dynamic.audio.outputSampleRate = 96_000
        dynamic.display.edrEnabled = true
        dynamic.quality = nil
        store.receive(dynamic)
        #expect(store.revision == revision)
        store.begin(identity: keyB, mediaID: b)
        store.receive(try facts(a, codec: "hevc"))
        #expect(store.summary(for: keyB) == nil)
        store.receive(try facts(b, codec: "av1"))
        #expect(store.summary(for: keyA)?.videoCodec == "h264")
        #expect(store.summary(for: keyB)?.videoCodec == "av1")
        for other in [identity("fileA", scope: "source-r2-account1"), identity("fileA", scope: "source-r1-account2"),
                      identity("fileA", vod: "other-film"), identity("fileA", line: "line2")] {
            #expect(store.summary(for: other) == nil)
        }
        store.end()
        store.receive(try facts(b, codec: "hevc"))
        #expect(store.summary(for: keyB)?.videoCodec == "av1")
        store.invalidate()
        store.receive(try facts(b))
        #expect(store.count == 0)
    }

    @MainActor @Test func cacheEvictsWithinCapacityAndEmptyFactsDoNotBecomeSpeculation() throws {
        let store = PlaybackSummaryStore(capacity: 2)
        let owner = UUID()
        for name in ["a", "b", "a", "c"] {
            store.begin(identity: identity(name), mediaID: owner)
            store.receive(try facts(owner))
        }
        #expect(store.count == 2)
        #expect(store.summary(for: identity("a")) != nil)
        #expect(store.summary(for: identity("b")) == nil)
        store.begin(identity: identity("empty"), mediaID: owner)
        store.receive(.init(mediaID: owner, properties: [:]))
        #expect(store.summary(for: identity("empty")) == nil)
    }

    @Test func localInputSizeRequiresExplicitProvenanceNotRangeOrSegmentLength() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("input.mp4")
        try Data(repeating: 0, count: 512).write(to: file)
        var spec = PlaySpec(url: file.absoluteString, contentLength: 1000)
        #expect(PlaybackLocalInputSizePolicy.bytes(spec: spec, nativeSize: "512") == nil)
        spec.userOpenedLocalFile = file
        #expect(PlaybackLocalInputSizePolicy.bytes(spec: spec, nativeSize: "512") == 512)
        #expect(PlaybackLocalInputSizePolicy.bytes(spec: spec, nativeSize: "1000") == nil)
        for ext in ["m3u8", "m4s", "ts", "part", "mpd"] {
            let segment = folder.appendingPathComponent("segment." + ext)
            try Data(repeating: 0, count: 512).write(to: segment)
            var segmentSpec = spec; segmentSpec.url = segment.absoluteString; segmentSpec.userOpenedLocalFile = segment
            #expect(PlaybackLocalInputSizePolicy.bytes(spec: segmentSpec, nativeSize: "512") == nil)
        }
        spec.metadata["playback.kind"] = "live"
        #expect(PlaybackLocalInputSizePolicy.bytes(spec: spec, nativeSize: "512") == nil)
        spec.metadata = [:]; spec.mpvOptions["end"] = "20"
        #expect(PlaybackLocalInputSizePolicy.bytes(spec: spec, nativeSize: "512") == nil)
        spec.mpvOptions = [:]; spec.url = "https://example.invalid/range.mp4"
        #expect(PlaybackLocalInputSizePolicy.bytes(spec: spec, nativeSize: "512") == nil)
    }

    @MainActor @Test func appDetailUsesExactEpisodeAndInvalidatesSourceRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PlaybackStatisticsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let preferences = UserPreferences(defaults: defaults)
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: directory), userPreferences: preferences, providerRuntimeBootstrap: nil)
        let site = Site(key: "site", name: "Same name", type: 3, api: "fixture-a")
        state.sites = [site]; state.activeSite = site
        state.detailVod = Vod(vodId: "film", siteKey: "site")
        state.selectedPlayFlag = "line"
        state.episodes = [Episode(name: "same", url: "fileA"), Episode(name: "same", url: "fileB")]
        var spec = PlaySpec(url: "https://example.invalid/movie", flag: "line")
        spec.metadata = ["vod.id": "film", "vod.episodeURL": "fileB"]
        state.playerState.currentSpec = spec
        #expect(state.detailSummaryEpisode(vodID: "film")?.url == "fileB")
        let key = try #require(state.playbackSummaryIdentity(vodID: "film", line: "line", episodeURL: "fileB"))
        let owner = UUID()
        let store = state.playerState.playbackSummaries
        store.begin(identity: key, mediaID: owner); store.receive(try facts(owner))
        state.didClearPerformanceCaches()
        #expect(store.count == 0)
        #expect(state.playbackSummaryIdentity(vodID: "film", line: "line", episodeURL: "fileB") != key)
        store.receive(try facts(owner))
        #expect(store.count == 0)
        let revisedKey = state.playbackSummaryIdentity(vodID: "film", line: "line", episodeURL: "fileB")
        try preferences.saveCredential("isolated-account-B", for: "quarkCookie")
        #expect(state.playbackSummaryIdentity(vodID: "film", line: "line", episodeURL: "fileB") != revisedKey)
        spec.metadata["vod.episodeURL"] = "removed-file"
        state.playerState.currentSpec = spec
        #expect(state.detailSummaryEpisode(vodID: "film") == nil)
        state.activeSite = Site(key: "site", name: "Same name", type: 3, api: "fixture-b")
        #expect(state.playbackSummaryIdentity(vodID: "film", line: "line", episodeURL: "fileB") != key)
    }
}
