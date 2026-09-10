import Testing
import Models
import DriveEngine
import PlayerEngine

private func sessionCandidate(
    id: String,
    kind: DrivePlaybackCandidateKind,
    transport: DrivePlaybackTransport,
    refresh: DrivePlaybackRefreshPolicy
) -> DrivePlaybackCandidate {
    DrivePlaybackCandidate(
        id: id,
        providerRoute: kind == .original
            ? DrivePlaybackRoute.originalDownload
            : DrivePlaybackRoute.personalTranscode,
        kind: kind,
        transport: transport,
        url: "https://media.example.test/\(id).\(kind == .original ? "mkv" : "m3u8")",
        quality: DrivePlaybackQuality(
            value: kind == .original ? "Origin" : "FHD",
            label: kind == .original ? "原画" : "1080P"
        ),
        refreshPolicy: refresh,
        expectedSize: 2_460_000_000
    )
}

private func aliSessionPlan() -> DrivePlaybackPlan {
    DrivePlaybackPlan(
        provider: .ali,
        asset: DrivePlaybackAssetIdentity(
            provider: .ali,
            shareID: "ali-share",
            sourceFileID: "ali-file",
            size: 2_460_000_000
        ),
        candidates: [
            sessionCandidate(
                id: "ali:original",
                kind: .original,
                transport: .localRangeProxy,
                refresh: .refreshCredentialAndURLOnce
            ),
            sessionCandidate(
                id: "ali:transcode",
                kind: .transcode,
                transport: .hlsRelay,
                refresh: .refreshCredentialAndURLOnce
            )
        ]
    )
}

@MainActor
private func sessionSpec(
    plan: DrivePlaybackPlan,
    candidate: DrivePlaybackCandidate,
    generation: UInt64,
    manual: Bool = false
) -> PlaySpec {
    var base = PlaySpec(
        url: plan.primaryCandidate?.url ?? candidate.url,
        drivePlaybackPlan: plan,
        drivePlaybackSessionGeneration: generation
    )
    base = DrivePlaybackRoutePolicy.spec(for: candidate, basedOn: base, manualSelection: manual)
    return base
}

@MainActor
@Test func testDrivePlaybackSessionCoalescesDuplicateOriginalFailureDuringAliSwitch() throws {
    let plan = aliSessionPlan()
    let controller = DrivePlaybackSessionController()
    let generation = controller.begin(plan: plan, candidateID: "ali:original")
    let original = sessionSpec(
        plan: plan,
        candidate: try #require(plan.candidates.first),
        generation: generation
    )

    #expect(controller.requestFailure(for: original, message: "本地原片读取超时") == .started(plan.candidates[1]))
    #expect(controller.requestFailure(for: original, message: "mpv loading failed") == .coalesced)

    let transcode = sessionSpec(plan: plan, candidate: plan.candidates[1], generation: generation)
    #expect(controller.confirmStarted(spec: transcode))
}

@MainActor
@Test func testDrivePlaybackSessionRefreshesAli401OnlyOnceThenDegrades() throws {
    let plan = aliSessionPlan()
    let controller = DrivePlaybackSessionController()
    let generation = controller.begin(plan: plan, candidateID: "ali:original")
    let original = sessionSpec(
        plan: plan,
        candidate: try #require(plan.candidates.first),
        generation: generation
    )

    #expect(controller.requestFailure(for: original, message: "HTTP 401: not login") == .started(plan.candidates[0]))
    #expect(controller.requestFailure(for: original, message: "HTTP 401: not login") == .coalesced)
    #expect(controller.requestRefreshFailure(for: original) == .started(plan.candidates[1]))
    #expect(controller.requestRefreshFailure(for: original) == .coalesced)
}

@MainActor
@Test func testDrivePlaybackSessionRejectsOldAndCancelledCallbacks() throws {
    let plan = aliSessionPlan()
    let controller = DrivePlaybackSessionController()
    let oldGeneration = controller.begin(plan: plan, candidateID: "ali:original")
    let oldSpec = sessionSpec(
        plan: plan,
        candidate: try #require(plan.candidates.first),
        generation: oldGeneration
    )
    _ = controller.begin(plan: plan, candidateID: "ali:original")
    #expect(controller.requestFailure(for: oldSpec, message: "timeout") == .stale)

    let activeGeneration = oldGeneration + 1
    let activeSpec = sessionSpec(plan: plan, candidate: plan.candidates[0], generation: activeGeneration)
    controller.cancel()
    #expect(controller.requestFailure(for: activeSpec, message: "timeout") == .stale)
}

@MainActor
@Test func testDrivePlaybackSessionManualSelectionNeverAutoSwitches() throws {
    let plan = aliSessionPlan()
    let controller = DrivePlaybackSessionController()
    let generation = controller.begin(plan: plan, candidateID: "ali:original")
    #expect(controller.requestManualTransition(
        to: "ali:transcode",
        generation: generation
    ) == .started(plan.candidates[1]))

    let manual = sessionSpec(
        plan: plan,
        candidate: plan.candidates[1],
        generation: generation,
        manual: true
    )
    #expect(controller.requestFailure(for: manual, message: "HTTP 410") == .exhausted)
    #expect(controller.requestFailure(for: manual, message: "HTTP 410") == .coalesced)
}

@MainActor
@Test func testDrivePlaybackSessionExhaustionIsDeliveredOnce() throws {
    let candidate = sessionCandidate(
        id: "pikpak:stream",
        kind: .streaming,
        transport: .direct,
        refresh: .none
    )
    let plan = DrivePlaybackPlan(
        provider: .pikpak,
        asset: DrivePlaybackAssetIdentity(provider: .pikpak, sourceFileID: "file"),
        candidates: [candidate]
    )
    let controller = DrivePlaybackSessionController()
    let generation = controller.begin(plan: plan, candidateID: candidate.id)
    let spec = sessionSpec(plan: plan, candidate: candidate, generation: generation)

    #expect(controller.requestFailure(for: spec, message: "failed to open") == .exhausted)
    #expect(controller.requestFailure(for: spec, message: "failed to open") == .coalesced)
}

@MainActor
@Test func testDrivePlaybackSessionSustainedStallMovesToNextCandidate() throws {
    let plan = aliSessionPlan()
    let controller = DrivePlaybackSessionController()
    let generation = controller.begin(plan: plan, candidateID: "ali:original")
    let original = sessionSpec(plan: plan, candidate: plan.candidates[0], generation: generation)

    #expect(controller.requestFailure(for: original, message: "持续卡顿且字节流无进展") == .started(plan.candidates[1]))
}

@MainActor
@Test func testDrivePlaybackSessionConfirmsOnlyCurrentSwitchTarget() {
    let plan = aliSessionPlan()
    let controller = DrivePlaybackSessionController()
    let generation = controller.begin(plan: plan, candidateID: "ali:original")
    let original = sessionSpec(plan: plan, candidate: plan.candidates[0], generation: generation)
    let transcode = sessionSpec(plan: plan, candidate: plan.candidates[1], generation: generation)

    _ = controller.requestFailure(for: original, message: "timeout")
    #expect(!controller.confirmStarted(spec: original))
    #expect(controller.confirmStarted(spec: transcode))
}
