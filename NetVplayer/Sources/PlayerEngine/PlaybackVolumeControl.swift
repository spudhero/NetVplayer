import Foundation

/// HDMI bitstreams bypass sample gain. AVFoundation's private decoded sink
/// supports volume, so compressed source metadata alone must not disable it.
public enum PlaybackVolumeControl: Equatable, Sendable {
    case player
    case receiver
    case checking

    public static func resolve(audio: PlaybackDiagnostics.Audio?, hasPlayback: Bool = true) -> Self {
        guard hasPlayback else { return .player }
        guard let audio, let driver = audio.outputDriver, !driver.isEmpty, driver != "null" else {
            return .checking
        }
        switch audio.mode {
        case .passthrough:
            return driver != "avfoundation" && audio.outputFormat?.hasPrefix("spdif-") == true
                ? .receiver : .checking
        case .pcm, .nativeCompressed: return .player
        case .nativeCompressedPreparing, nil: return .checking
        }
    }
}
