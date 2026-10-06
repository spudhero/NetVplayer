import Testing
import Models
import DriveEngine
@testable import PlayerEngine

struct PlaybackSeekOwnershipTests {
    @Test func lateEventsCannotCompleteAnotherSeekOrAnotherMedia() {
        var activity = PlaybackSeekActivity()
        let first = activity.begin()
        activity.observeSeek(owner: first)
        let second = activity.begin()
        activity.observeSeeking(false, owner: first)
        let acceptedOldRestart = activity.observeRestart(owner: first)
        #expect(!acceptedOldRestart)
        #expect(!activity.isReady(owner: second, pausedForCache: false))
        // An unrelated restart arriving before the new SEEK is not completion.
        let acceptedUnstartedRestart = activity.observeRestart(owner: second)
        #expect(!acceptedUnstartedRestart)
        activity.observeSeek(owner: second)
        let acceptedCurrentRestart = activity.observeRestart(owner: second)
        #expect(acceptedCurrentRestart)
        #expect(!activity.isReady(owner: second, pausedForCache: false))
        activity.observeSeeking(false, owner: second)
        #expect(!activity.isReady(owner: second, pausedForCache: true))
        #expect(activity.isReady(owner: second, pausedForCache: false))
        activity.resetMedia()
        let acceptedRetiredRestart = activity.observeRestart(owner: second)
        #expect(!acceptedRetiredRestart)
        #expect(!activity.isReady(owner: second, pausedForCache: false))
    }

    @Test func keyframeOffsetIsAcceptedOnlyAfterOwnedNativeCompletion() {
        var activity = PlaybackSeekActivity()
        var guardState = PlaybackPostSeekEndGuard()
        guardState.begin(targetSeconds: 120)
        let owner = activity.begin()
        guardState.markPlaybackRestarted()
        #expect(!guardState.canPresentFrame(at: 80))
        activity.observeSeek(owner: owner)
        activity.observeSeeking(false, owner: owner)
        #expect(!activity.isReady(owner: owner, pausedForCache: false))
        activity.observeRestart(owner: owner)
        let ready = activity.isReady(owner: owner, pausedForCache: false)
        #expect(guardState.canPresentFrame(at: 80, confirmedSeek: ready))
        #expect(!guardState.canPresentFrame(at: .nan, confirmedSeek: ready))
        #expect(!guardState.canPresentFrame(at: -1, confirmedSeek: ready))
        // UI readiness does not itself classify an immediate EOF as natural.
        #expect(guardState.isProtecting)
        activity.finish(owner: owner)
        #expect(!activity.isPending)
    }

    @Test func seekingKnownEndUsesExactEvenOnStreamingRoutes() {
        let spec = PlaySpec(url: "https://example.invalid/video.m3u8", metadata: [
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.personalTranscode
        ])
        #expect(MPVSeekModePolicy.commandMode(for: spec, targetSeconds: 99, durationSeconds: 100) == "absolute+keyframes")
        #expect(MPVSeekModePolicy.commandMode(for: spec, targetSeconds: 100, durationSeconds: 100) == "absolute+exact")
        #expect(MPVSeekModePolicy.commandMode(for: spec, targetSeconds: 0, durationSeconds: 0) == "absolute+keyframes")
    }
}
