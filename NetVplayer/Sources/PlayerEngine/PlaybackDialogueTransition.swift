import Foundation

/// A bounded, cancellable dip around a filter rebuild. This never writes the
/// user's volume/mute preference. Shared by production and native PCM tests.
enum PlaybackDialogueTransition {
    nonisolated static func run(initialGain: Double, playing: Bool,
                    setGain: @Sendable (Double) -> Void,
                    setFilter: @MainActor @Sendable () async -> Bool) async throws -> Bool {
        if playing {
            for step in 1...64 {
                try Task.checkCancellation()
                // mpv 0.41 applies (volume / 100)^3. Ramp the resulting
                // amplitude, with enough time between levels for AO blocks.
                setGain(initialGain * pow(1 - Double(step) / 64, 1.0 / 3.0))
                try await Task.sleep(for: .milliseconds(10))
            }
            // Allow the ordinary shared AO queue to consume the fade. This is a
            // conservative software interval, not a hardware latency guarantee.
            try await Task.sleep(for: .milliseconds(350))
        }
        try Task.checkCancellation()
        let accepted = await setFilter()
        try Task.checkCancellation()
        if playing {
            try await Task.sleep(for: .milliseconds(50))
            for step in 1...64 {
                try Task.checkCancellation()
                setGain(pow(Double(step) / 64, 1.0 / 3.0))
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        return accepted
    }
}
