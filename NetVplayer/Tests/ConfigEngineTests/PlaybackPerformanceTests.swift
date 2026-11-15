import Foundation
import Testing
@testable import PlayerEngine

#if DEBUG
@Suite struct PlaybackPerformanceTests {
    @Test func firstFrameRequiresSuccessfulFreshPresentationFacts() {
        var frames = MPVPerformanceFrames(loadUptime: 10)
        frames.record(flags: -1, width: 3840, height: 2160, now: 11)
        frames.record(flags: 0, width: 3840, height: 2160, now: 12)
        frames.record(flags: 3, width: 3840, height: 2160, now: 13)
        frames.record(flags: 5, width: 3840, height: 2160, now: 14)
        #expect(frames.firstFrameUptime == nil)
        #expect(frames.freshFrames == 0)
        frames.record(flags: 1, width: 3840, height: 2160, now: 15)
        frames.record(flags: 9, width: 3840, height: 2160, now: 16)
        #expect(frames.firstFrameUptime == 15)
        #expect(frames.lastFrameUptime == 16)
        #expect(frames.freshFrames == 2)
        #expect(frames.redraws == 2)
        #expect(frames.unavailable == 1)
    }

    @Test func performancePropertiesDoNotInventAvailableMetricsOrExportNames() throws {
        let raw: [String: Any] = ["time-pos": 12.5, "pause": false, "paused-for-cache": true,
            "speed": 1.0, "vo-passes": ["fresh": [["avg": 1_000_000], ["avg": 2_000_000]]]]
        let data = try raw.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
        var info = PlaybackDiagnostics(mediaID: UUID(), properties: [:], display: .init(name: "Private Screen"))
        info.audio.deviceName = "Private Speaker"
        let reading = MPVPerformanceReading(info: info, properties: data, now: 99)
        #expect(reading.position == 12.5)
        #expect(reading.paused == false)
        #expect(reading.pausedForCache == true)
        #expect(reading.gpuPassAverageMilliseconds == 3)
        #expect(reading.videoBitsPerSecond == nil)
        #expect(!String(decoding: try JSONEncoder().encode(reading), as: UTF8.self).contains("Private"))
        let malformed = MPVPerformanceReading(info: info, properties: ["speed": Data("true".utf8), "pause": Data("0".utf8)], now: 100)
        #expect(malformed.speed == nil)
        #expect(malformed.paused == nil)
        #expect(malformed.gpuPassAverageMilliseconds == nil)
    }

    @Test func subsecondSupplyStallsRemainVisibleBetweenDiagnosticSamples() {
        var frames = MPVPerformanceFrames(loadUptime: 1)
        frames.cache(paused: true, now: 5)
        frames.cache(paused: true, now: 5.01)
        #expect(frames.snapshot(now: 5.1).cachePauseSeconds > 0.09)
        frames.cache(paused: false, now: 5.2)
        frames.cache(paused: false, now: 5.3)
        #expect(frames.cachePauseCount == 1)
        #expect(abs(frames.cachePauseSeconds - 0.2) < 0.0001)
        #expect(frames.snapshot(now: 6).cachePauseSeconds == frames.cachePauseSeconds)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_PERFORMANCE_FIXTURE"] != nil))
    @MainActor func nativePerformanceRecorderUsesOrdinarySDRAndFreshFrames() async throws {
        guard let file = ProcessInfo.processInfo.environment["NETVPLAYER_AV_PERFORMANCE_FIXTURE"] else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("av05-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("result")
        let config = folder.appendingPathComponent("config.json")
        let request: [String: Any] = ["outputDirectory": output.path, "cases": [[
            "id": "native-contract", "url": URL(fileURLWithPath: file).absoluteString,
            "warmupSeconds": 0, "measurementSeconds": 1, "purpose": "compatibility", "renderAt4K": true]]]
        try JSONSerialization.data(withJSONObject: request).write(to: config)
        try await MPVPerformanceProbe.run(configuration: config)
        let reports = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("cases.json"))) as? [[String: Any]])
        #expect(reports.first?["completed"] as? Bool == true)
        let frames = try #require(reports.first?["frames"] as? [String: Any])
        #expect((frames["freshFrames"] as? Int ?? 0) > 0)
        #expect(frames["width"] as? Int == 3840)
        #expect(frames["height"] as? Int == 2160)
        #expect((frames["firstFrameUptime"] as? Double ?? 0) > (frames["loadUptime"] as? Double ?? 0))
        let info = try #require(reports.first?["diagnostics"] as? [String: Any])
        #expect((info["display"] as? [String: Any])?["targetFormat"] as? String == "GL_RGBA8")
        print("AV05 native recorder report: \(folder.path)")
    }
}
#endif
