import AppKit
import Foundation
import Testing
@testable import PlayerEngine

@Suite struct PlaybackDisplayTimingTests {
    @Test func modeRatesCannotConfirmMatchingOrQMS() throws {
        for rate in [23.976, 24, 25, 50, 29.97, 59.94, 60, 120] {
            let timing = PlaybackDisplayTiming(configuredRefreshRateHz: rate)
            let info = PlaybackDiagnostics(mediaID: UUID(), properties: ["container-fps": Data("\(rate)".utf8)],
                display: .init(name: "private display", currentEDRHeadroom: 8, timing: timing))
            #expect(info.display.timing?.configuredRefreshRateHz == rate)
            #expect(info.display.timing?.rateMatching == .notEnabled)
            #expect(info.display.timing?.qms == .unverified)
            let exported = info.redactedJSON()
            #expect(!exported.contains("private") && exported.utf8.count < 16_384)
            #expect(try JSONDecoder().decode(PlaybackDiagnostics.self, from: Data(exported.utf8)).display.timing == timing)
        }
        let invalidRates: [Double?] = [nil, 0, -1, .nan, .infinity, 1_001]
        for rate in invalidRates {
            #expect(PlaybackDisplayTiming(configuredRefreshRateHz: rate).configuredRefreshRateHz == nil)
        }
    }

    @Test func previousExportsDecodeWithoutDisplayTiming() throws {
        let old = PlaybackDiagnostics(mediaID: UUID(), properties: [:])
        #expect(try JSONDecoder().decode(PlaybackDiagnostics.self, from: Data(old.redactedJSON().utf8)).display.timing == nil)
    }

    #if DEBUG
    @Test func cadenceTraceIsBoundedAndPreservesUnavailableAndRepeatedFrames() {
        let recorder = MPVCadenceRecorder()
        for i in 0...MPVCadenceRecorder.capacity { recorder.record(flags: i == 0 ? -1 : (i == 1 ? 5 : 1), now: Double(i)) }
        let trace = recorder.snapshot()
        #expect(trace.frames.count == MPVCadenceRecorder.capacity && trace.overflow == 1)
        #expect(trace.frames[0].flags == -1 && trace.frames[1].flags == 5)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_CADENCE_FIXTURE"] != nil))
    @MainActor func nativeCadenceUsesProductionSurfaceAndLeavesDisplayModeAlone() async throws {
        let file = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_CADENCE_FIXTURE"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("av11-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("result")
        let config = folder.appendingPathComponent("config.json")
        let request: [String: Any] = ["outputDirectory": output.path, "cases": [["id": "native-contract_24",
            "url": URL(fileURLWithPath: file).absoluteString, "warmupSeconds": 0, "measurementSeconds": 1]]]
        try JSONSerialization.data(withJSONObject: request).write(to: config)
        try await MPVCadenceProbe.run(configuration: config)
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("native-contract_24.json"))) as? [String: Any])
        #expect(report["completed"] as? Bool == true)
        #expect(report["modeWrites"] as? Int == 0)
        let before = try #require(report["before"] as? NSDictionary)
        #expect(before == report["after"] as? NSDictionary)
        let trace = try #require(report["trace"] as? [String: Any])
        #expect((trace["frames"] as? [Any])?.isEmpty == false && (trace["ticks"] as? [Any])?.isEmpty == false)
        #expect(trace["overflow"] as? Int == 0)
        let samples = try #require(report["samples"] as? [[String: Any]])
        let reading = try #require(samples.last?["reading"] as? [String: Any])
        let diagnostics = try #require(reading["diagnostics"] as? [String: Any])
        #expect((diagnostics["display"] as? [String: Any])?["targetFormat"] as? String == "GL_RGBA8")
        print("AV11 native report: \(output.path)")
        await #expect(throws: (any Error).self) { try await MPVCadenceProbe.run(configuration: config) }
    }
    #endif
}
