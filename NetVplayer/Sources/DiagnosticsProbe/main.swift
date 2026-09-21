import Foundation
import Diagnostics

// This developer tool is not included in the distributed application bundle.
// It deliberately never starts AppState, loads providers or reads playback history.
guard ProcessInfo.processInfo.environment["NETVPLAYER_SENTRY_DSN"]?.isEmpty == false else {
    fputs("Set NETVPLAYER_SENTRY_DSN to the project's public DSN.\n", stderr)
    exit(78)
}
let name = "NetVplayer.DiagnosticsProbe.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: name) else { exit(70) }
defer { defaults.removePersistentDomain(forName: name) }
let diagnostics = SentryDiagnostics(defaults: defaults, environment: "verification")
diagnostics.start()
if CommandLine.arguments.contains("--crash") {
    fatalError("NetVplayer synthetic crash verification")
}
guard let id = diagnostics.captureVerificationEvent() else {
    fputs("Sentry was not configured; no event was sent.\n", stderr)
    exit(78)
}
diagnostics.stop()
print("Verification event ID: \(id)")
print("Client flush completed. Confirm this event ID in Sentry; this output does not prove receipt.")
