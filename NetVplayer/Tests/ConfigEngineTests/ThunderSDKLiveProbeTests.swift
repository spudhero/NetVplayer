import Foundation
import Testing
import DriveEngine
import Models
import PlayerEngine
import Storage

/// Explicitly enabled local diagnostic. Signed URLs and headers stay in an
/// owner-only file outside the repository; the test prints only numeric status.
@Test func thunderSDKProbeResolvesAuthorizedUCHistoryWhenEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["NETVPLAYER_THUNDER_RESOLVE_PROBE"] == "1" else { return }
    let output = try #require(environment["NETVPLAYER_THUNDER_PROBE_REQUEST"])
    let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NetVplayer")
    let history = try JSONDecoder().decode(
        [History].self, from: Data(contentsOf: support.appendingPathComponent("history.json"))
    )
    let entry = try #require(history.first {
        $0.vodName.contains("仙逆") && $0.driveProvider == DriveProvider.uc.rawValue
    })
    let reference = entry.driveReferenceURL.isEmpty ? entry.episodeUrl : entry.driveReferenceURL
    #expect(reference.hasPrefix("netvplayer-drive://uc/"))
    // Read only the application's UC credential. Never print or copy its value
    // into test output, shell arguments, or another application domain.
    let cookie = try LocalCredentialStore().read(UCShareExtractor.cookieDefaultsKey)
        ?? UserDefaults(suiteName: UserPreferences.stableBundleIdentifier)?
        .string(forKey: UCShareExtractor.cookieDefaultsKey) ?? ""
    #expect(!cookie.isEmpty)
    let extractor = UCShareExtractor(
        cookieProvider: { cookie }, cookieUpdateHandler: { _ in },
        originalPlaybackTokenProvider: { nil }, originalPlaybackTokenUpdateHandler: { _ in },
        tokenProvider: { nil }, tokenUpdateHandler: { _ in },
        fongMiPlaybackTokenProvider: { nil }
    )
    let resolved = try await extractor.fetchResult(url: reference)
    let original = try #require(resolved.drivePlaybackPlan?.candidates.first {
        $0.kind == .original && $0.providerRoute == DrivePlaybackRoute.ucOriginalProxy
    })
    let request: [String: Any] = [
        "url": original.url, "headers": original.headers,
        "expected_size": original.expectedSize,
    ]
    let data = try JSONSerialization.data(withJSONObject: request)
    let destination = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    #expect(FileManager.default.createFile(
        atPath: destination.path, contents: data, attributes: [.posixPermissions: 0o600]
    ))
    print("[THUNDER_PROBE] request_ready expectedBytes=\(original.expectedSize)")
}
