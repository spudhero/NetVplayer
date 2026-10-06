import Testing
@testable import ApplicationCore

struct FullScreenTransitionTests {
    @Test func rapidTogglesCoalesceAndOppositeIntentRunsAfterCompletion() {
        var state = FullScreenTransitionState()
        #expect(state.toggle(actual: false, now: 0) == true)
        #expect(state.toggle(actual: false, now: 0.1) == nil)
        #expect(state.toggle(actual: false, now: 0.2) == nil)
        #expect(state.toggle(actual: false, now: 0.3) == nil)
        #expect(state.completed(actual: true, now: 1) == false)
        #expect(state.completed(actual: false, now: 2) == nil)
        #expect(state.transition == nil)
    }

    @Test func lostCompletionWaitsForLiveResizeAndUsesActualState() {
        var state = FullScreenTransitionState()
        state.began(target: true, now: 0)
        #expect(state.request(false, actual: false, now: 1) == nil)
        #expect(state.recover(actual: true, isLiveResize: false, now: 4.99) == nil)
        #expect(state.recover(actual: true, isLiveResize: true, now: 10) == nil)
        #expect(state.transition?.target == true)
        #expect(state.recover(actual: true, isLiveResize: false, now: 10.1) == false)
        #expect(state.transition?.target == false)
    }

    @Test func failedTransitionReleasesLockAndCloseRejectsLateEvents() {
        var state = FullScreenTransitionState()
        #expect(state.request(true, actual: false, now: 0) == true)
        #expect(state.recover(actual: false, isLiveResize: false, now: 6) == nil)
        #expect(state.transition == nil)
        #expect(state.request(true, actual: false, now: 7) == true)
        state.close()
        #expect(state.completed(actual: true, now: 8) == nil)
        state.began(target: false, now: 9)
        #expect(state.toggle(actual: true, now: 10) == nil)
        #expect(state.transition == nil)
    }
}
