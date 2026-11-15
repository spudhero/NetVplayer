#if DEBUG
import Foundation
import Testing
@testable import PlayerEngine

@Suite(.serialized) struct MPVVideoOutputTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_OUTPUT_FIXTURES"] != nil))
    func ordinaryRendererPolicySessionAndDisplayLifecycle() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_OUTPUT_FIXTURES"]))
        // XCTest's unbundled helper does not acquire current EDR headroom on
        // every macOS host. It must retain the ordinary policy/fallback contract;
        // the packaged probe separately requires actual EDR and pixel references.
        try await MPVVideoOutputProbe.run(folder: folder, output: folder.appendingPathComponent("native-output-results.json"), requireProductHDR: false)
    }
}
#endif
