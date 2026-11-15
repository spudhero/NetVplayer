#if DEBUG
import Foundation
import Testing
@testable import PlayerEngine

@Suite(.serialized) struct MPVHDRPrototypeTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_HDR_FIXTURES"] != nil))
    func nativeFP16SignalAndSessionContracts() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_HDR_FIXTURES"]))
        try await MPVHDRPrototype.run(folder: folder,output: folder.appendingPathComponent("native-hdr-results.json"))
    }
}
#endif
