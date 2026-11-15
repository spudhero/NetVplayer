import Foundation
import MPVShim
import Testing
@testable import PlayerEngine

@MainActor
@Suite(.serialized)
struct MPVEventPumpTests {
    @MainActor
    private final class Probe {
        var drains = 0
        var remaining = 197
        var replies: Set<UInt64> = []
        var errors = 0
        var duringDrain: (() -> Void)?
    }

    @Test func burstCoalescesAndIdleDoesNotPoll() async throws {
        let probe = Probe()
        let pump = MPVEventPump { probe.drains += 1; return false }
        defer { pump.cancel() }
        for _ in 0..<5_000 { pump.signal() }
        try #require(await wait { probe.drains > 0 })
        #expect(probe.drains == 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.drains == 1)
    }

    @Test func singleNotificationDrainsEveryBoundedBatch() async throws {
        let probe = Probe()
        let pump = MPVEventPump {
            probe.drains += 1
            let count = min(64, probe.remaining)
            probe.remaining -= count
            return count == 64
        }
        defer { pump.cancel() }
        pump.signal()
        try #require(await wait { probe.remaining == 0 })
        #expect(probe.drains == 4)
    }

    @Test func notificationInsideDrainIsNotLost() async throws {
        let probe = Probe()
        let pump = MPVEventPump {
            probe.drains += 1
            if probe.drains == 1 { probe.duringDrain?() }
            return false
        }
        probe.duringDrain = { [weak pump] in pump?.signal() }
        defer { pump.cancel(); probe.duringDrain = nil }
        pump.signal()
        try #require(await wait { probe.drains == 2 })
    }

    @Test func cancellationRejectsQueuedAndLateCallbacks() async throws {
        let probe = Probe()
        let pump = MPVEventPump { probe.drains += 1; return false }
        pump.signal()
        pump.cancel()
        // Mirror foreign C callbacks without sending an UnsafeMutableRawPointer
        // across Swift's actor boundary. The strong pump outlives this worker.
        let pointer = UInt(bitPattern: Unmanaged.passUnretained(pump).toOpaque())
        await Task.detached {
            for _ in 0..<5_000 { mpvEventWakeupCallback(UnsafeMutableRawPointer(bitPattern: pointer)) }
        }.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.drains == 0)
        #expect(pump.snapshot.cancelled)
        #expect(pump.snapshot.signals == 1)
    }

    @Test func foreignThreadCallbacksReachMainActor() async throws {
        let probe = Probe()
        let pump = MPVEventPump { probe.drains += 1; return false }
        defer { pump.cancel() }
        let pointer = UInt(bitPattern: Unmanaged.passUnretained(pump).toOpaque())
        await Task.detached {
            for _ in 0..<2_000 { mpvEventWakeupCallback(UnsafeMutableRawPointer(bitPattern: pointer)) }
        }.value
        try #require(await wait { probe.drains > 0 })
        #expect(pump.snapshot.signals == 2_000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_RUN_EVENT_WAKEUP_INTEGRATION"] == "1"))
    func nativeRepliesAndIdleWakeupComparison() async throws {
        let context = try #require(nv_mpv_create())
        let contextValue = UInt(bitPattern: context)
        let probe = Probe()
        let pump = MPVEventPump {
            guard let context = OpaquePointer(bitPattern: contextValue) else { return false }
            for _ in 0..<64 {
                var event = NVMPVEvent()
                if nv_mpv_wait_event(context, 0, &event) != 0 { probe.errors += 1; return false }
                if event.event_id == 0 { return false }
                if event.event_id == 3 {
                    probe.replies.insert(event.reply_userdata)
                    if event.error < 0 { probe.errors += 1 }
                }
            }
            return true
        }
        defer {
            nv_mpv_set_wakeup_callback(context, nil, nil)
            pump.cancel()
            withExtendedLifetime(pump) { nv_mpv_destroy(context) }
        }
        for (name, value) in [("config", "no"), ("vo", "null"), ("ao", "null"), ("idle", "yes")] {
            try #require(nv_mpv_set_option_string(context, name, value) >= 0)
        }
        try #require(nv_mpv_initialize(context) >= 0)
        try #require(nv_mpv_set_wakeup_callback(context, mpvEventWakeupCallback,
            Unmanaged.passUnretained(pump).toOpaque()) == 0)
        pump.signal()
        for id in UInt64(1)...257 {
            try #require(nv_mpv_get_property_async(context, id, "mpv-version") >= 0)
        }
        try #require(await wait { probe.replies.count == 257 })
        #expect(probe.replies == Set(UInt64(1)...257))
        #expect(probe.errors == 0)

        // Let startup notifications settle, then compare event-reader turns
        // against the previous 20 ms loop over the same idle duration.
        try await Task.sleep(for: .milliseconds(150))
        let before = pump.snapshot
        let nativeStart = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(300))
        let nativeDuration = nativeStart.duration(to: .now)
        let nativeIdleBatches = pump.snapshot.batches - before.batches
        try #require(nv_mpv_set_wakeup_callback(context, nil, nil) == 0)
        pump.cancel()
        let pollingStart = ContinuousClock.now
        let deadline = pollingStart.advanced(by: .milliseconds(300))
        var pollingIdleReads = 0
        while ContinuousClock.now < deadline {
            var event = NVMPVEvent()
            _ = nv_mpv_wait_event(context, 0, &event)
            pollingIdleReads += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(nativeIdleBatches == 0)
        // Timer scheduling can slip under unrelated GUI load. Verify the
        // behavioral difference without asserting the scheduler's precision.
        #expect(pollingIdleReads > nativeIdleBatches)
        let library = String(cString: nv_mpv_loaded_library_path(context))
        print("MPV_EVENT_WAKEUP_EVIDENCE replies=\(probe.replies.count) errors=\(probe.errors) nativeIdleBatches=\(nativeIdleBatches) pollingIdleReads=\(pollingIdleReads) nativeDuration=\(nativeDuration) pollingDuration=\(pollingStart.duration(to: .now)) library=\(library)")
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
