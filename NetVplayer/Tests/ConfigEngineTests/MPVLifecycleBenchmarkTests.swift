import Foundation
import Testing
@testable import PlayerEngine

@MainActor
@Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_RUN_MPV_LIFECYCLE_BENCHMARK"] != "1"))
func testMPVLifecycleBenchmark() async throws {
    let mediaPath = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_MPV_BENCHMARK_MEDIA"])
    let report = try await MPVPlayerEngine.runLifecycleBenchmark(
        mediaURL: URL(fileURLWithPath: mediaPath),
        rounds: 5
    )
    let outputPath = ProcessInfo.processInfo.environment["NETVPLAYER_MPV_BENCHMARK_OUTPUT"]
        ?? "/private/tmp/netvplayer-mpv-lifecycle-benchmark.json"
    let data = try JSONEncoder().encode(report)
    try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    print(String(decoding: data, as: UTF8.self))
}
