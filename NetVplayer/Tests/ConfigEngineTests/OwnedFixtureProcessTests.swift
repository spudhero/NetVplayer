import Darwin
import Foundation
import Testing

@Suite("Owned fixture process termination", .serialized)
struct OwnedFixtureProcessTests {
    @Test func cooperativeChildExitsWithinGraceAndRepeatedStopIsSafe() throws {
        let process = try readyChild(ignoreTermination: false)
        defer { stopOwnedFixtureProcess(process) }
        #expect(stopOwnedFixtureProcess(process))
        #expect(!process.isRunning)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        #expect(stopOwnedFixtureProcess(process))
    }

    @Test func ignoredTerminationEscalatesOnlyTheOwnedChildAndReturnsWithinDeadline() throws {
        let process = try readyChild(ignoreTermination: true)
        let neighbour = try readyChild(ignoreTermination: false)
        defer { stopOwnedFixtureProcess(process) }
        defer { stopOwnedFixtureProcess(neighbour) }
        let start = ContinuousClock.now
        #expect(stopOwnedFixtureProcess(process, gracePeriod: 0.2))
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        #expect(neighbour.isRunning)
    }

    @Test func unstartedProcessNeedsNoTermination() {
        #expect(stopOwnedFixtureProcess(Process()))
    }

    private func readyChild(ignoreTermination: Bool) throws -> Process {
        let process = Process(), output = Pipe()
        let ready = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            if !handle.availableData.isEmpty { ready.signal() }
        }
        defer { output.fileHandleForReading.readabilityHandler = nil }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let handler = ignoreTermination ? "signal.SIG_IGN" : "lambda *_: sys.exit(0)"
        process.arguments = ["-u", "-c", """
        import signal, sys, time
        signal.signal(signal.SIGTERM, \(handler))
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
        print('ready', flush=True)
        time.sleep(30)
        """]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard ready.wait(timeout: .now() + 5) == .success else {
            stopOwnedFixtureProcess(process)
            throw URLError(.timedOut)
        }
        return process
    }
}
