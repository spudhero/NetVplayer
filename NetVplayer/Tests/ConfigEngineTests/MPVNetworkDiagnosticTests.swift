import Testing
import Models
import DriveEngine
@testable import PlayerEngine

@MainActor
@Test(arguments: [401, 403, 410])
func testMPVHTTPFailurePreservesStatusForUCLinkRefresh(status: Int) throws {
    let plan = try #require(UCDrivePlaybackAdapter().playbackPlan(
        primaryURL: "https://video-play-c-zb.drive.uc.cn/media.m3u8?token=private",
        primaryHeaders: [:],
        primaryMetadata: [
            DrivePlaybackMetadataKey.provider: DriveProvider.uc.rawValue,
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.personalTranscode,
            DrivePlaybackMetadataKey.fid: "fixture-file"
        ]
    ))
    let candidate = try #require(plan.primaryCandidate)
    let controller = DrivePlaybackSessionController()
    let generation = controller.begin(plan: plan, candidateID: candidate.id)
    let spec = DrivePlaybackRoutePolicy.spec(
        for: candidate,
        basedOn: PlaySpec(url: candidate.url, drivePlaybackPlan: plan, drivePlaybackSessionGeneration: generation),
        manualSelection: false
    )
    let message = try #require(MPVPlayerEngine.diagnosticMessage(
        forMPVLog: "http: HTTP error \(status) Forbidden https://private.example/?token=secret",
        currentSpec: spec
    ))
    #expect(message.contains(String(status)))
    #expect(!message.contains("private"))
    #expect(!message.contains("secret"))
    #expect(controller.requestFailure(for: spec, message: message) == .started(candidate))
    #expect(MPVPlayerEngine.failureDiagnosticMeasurements(for: message) == ["failureKind": 3, "status": status])
}

@Test func testMPVHTTPFailureDoesNotInferStatusFromPrivateURLsOrSuccessfulResponses() {
    for text in [
        "Failed to open https://private.example/HTTP error 403",
        "Cookie: HTTP error 401",
        "HTTP error 4030 invalid",
        "HTTP error 200 OK"
    ] {
        #expect(MPVPlayerEngine.httpFailureStatus(forMPVLog: text) == nil)
    }
    #expect(MPVPlayerEngine.httpFailureStatus(forMPVLog: "  HTTP error 503 Service Unavailable\n") == 503)
}

@MainActor
@Test func testMPVQueuedFailureDoesNotAttachToReplacementLoad() async {
    let engine = MPVPlayerEngine(videoSurface: .vod)
    let state = PlayerState()
    engine.playerState = state
    defer { engine.stop() }
    var original = PlaySpec(url: "https://media.example.test/same.m3u8")
    original.metadata[DrivePlaybackSessionController.attemptMetadataKey] = "1"
    await engine.play(spec: original) // No view is attached, so no media request is made.
    var callbacks = 0
    engine.playbackFailureHandler = { _, _ in callbacks += 1 }
    engine.reportUnavailableVideoSurface(.vod)

    var replacement = original
    replacement.metadata[DrivePlaybackSessionController.attemptMetadataKey] = "2"
    state.currentSpec = replacement
    state.errorMessage = nil
    state.isPlaying = true
    try? await Task.sleep(for: .milliseconds(20))
    #expect(callbacks == 0)
    #expect(state.errorMessage == nil)
    #expect(state.isPlaying)
}

@Test func testMPVNetworkDiagnosticOmitsAddressesAndCredentials() {
    let request = """
    https: request: GET /private/movie?token=secret HTTP/1.1
    Host: private.example
    Referer: https://private.example/account
    Referer: https://private.example/account
    User-Agent: private-agent
    Cookie: private-cookie
    Authorization: Bearer private-token
    """
    let diagnostic = MPVPlayerEngine.networkDiagnostic(request) ?? ""
    #expect(diagnostic.hasPrefix("method=GET target="))
    #expect(diagnostic.components(separatedBy: "referer=").count == 3)
    for secret in ["private", "secret", "Cookie", "Authorization", "https://", "/movie"] {
        #expect(!diagnostic.contains(secret))
    }
    #expect(MPVPlayerEngine.networkDiagnostic("https: header='HTTP/1.1 403 Forbidden'") == "https: header='HTTP/1.1 403")
    #expect(MPVPlayerEngine.networkDiagnostic("https: header='Set-Cookie: secret'") == nil)
    #expect(MPVPlayerEngine.networkDiagnostic("Cookie: secret") == nil)
    #expect(MPVPlayerEngine.networkDiagnostic("Authorization: Bearer secret") == nil)
    #expect(MPVPlayerEngine.networkDiagnostic("User-Agent: private-agent")?.hasPrefix("header user-agent=") == true)
}

@Test func testMPVEndDiagnosticsCapturesByteOffsetsAndProgressFromLastSeek() {
    var diagnostics = MPVTransportDiagnostics(loadedAt: 100, positionMs: 0)
    diagnostics.seek(to: 338_600)
    diagnostics.observe(prefix: "ffmpeg", text: "http: Stream ends prematurely at 3331, should be 4982", now: 104)
    #expect(diagnostics.summary(positionMs: 1_025_000, now: 106) ==
        "loadAgeMs=6000 requestedPositionMs=338600 advanceMs=686400 transportEvents=1 "
        + "lastTransportEvent=short-response eventAgeMs=2000 offset=3331 expectedOffset=4982")
    diagnostics.observe(prefix: "ffmpeg", text: "https: Unexpected offset: expected 4444, got 3331", now: 107)
    #expect(diagnostics.summary(positionMs: 1_025_000, now: 108).hasSuffix(
        "lastTransportEvent=offset-mismatch eventAgeMs=1000 offset=3331 expectedOffset=4444"))
}

@Test func testMPVEndDiagnosticsKeepsOnlyKnownFieldsFromNetworkWarnings() {
    var diagnostics = MPVTransportDiagnostics(loadedAt: 100, positionMs: 0)
    diagnostics.observe(prefix: "ffmpeg", text: "http: Will reconnect at 0 in 0 second(s), error=Connection timed out.", now: 104)
    #expect(diagnostics.summary(positionMs: 1000, now: 105).hasSuffix(
        "lastTransportEvent=timeout eventAgeMs=1000 offset=0"))
    diagnostics.observe(prefix: "ffmpeg", text: "http: Authorization: Bearer private-token", now: 105)
    diagnostics.observe(prefix: "ffmpeg", text: "http: HTTP error 500 https://private.example/?token=secret", now: 106)
    diagnostics.observe(prefix: "demux", text: "http: Stream ends prematurely at 1, should be 2", now: 107)
    #expect(diagnostics.summary(positionMs: 2000, now: 108).contains("transportEvents=1 "))
    diagnostics.observe(prefix: "ffmpeg", text: "http: Will reconnect at 20 in 0 second(s), error=Secret cookie.", now: 109)
    #expect(diagnostics.summary(positionMs: 2000, now: 110) ==
        "loadAgeMs=10000 requestedPositionMs=0 advanceMs=2000 transportEvents=2 "
        + "lastTransportEvent=reconnect eventAgeMs=1000 offset=20")
}
