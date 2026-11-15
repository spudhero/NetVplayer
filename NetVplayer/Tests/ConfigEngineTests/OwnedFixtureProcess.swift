import Darwin
import Foundation

/// Stops only the child represented by this fixture's Process, without pumping a nested run loop.
@discardableResult
func stopOwnedFixtureProcess(_ process: Process, gracePeriod: TimeInterval = 1) -> Bool {
    precondition(gracePeriod > 0)
    guard process.isRunning else { return true }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    process.terminate()
    if exited.wait(timeout: .now() + gracePeriod) == .success { return true }
    guard process.isRunning else { return true }
    guard kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH else { return false }
    return exited.wait(timeout: .now() + gracePeriod) == .success || !process.isRunning
}
