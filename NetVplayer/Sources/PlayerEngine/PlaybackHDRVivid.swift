import Foundation

/// Current decoded-frame facts reported after the render submission succeeds.
/// A stream title, container tag or an earlier frame cannot activate this state.
public struct PlaybackHDRVivid: Equatable, Codable, Sendable {
    public let renderer: DolbyRendererObservation
    public var dynamicMappingApplied: Bool {
        !renderer.failed && renderer.frameFlags & 32 != 0 && renderer.capabilities & 16 != 0
    }
    public var usingBaseSignal: Bool { !dynamicMappingApplied }

    static func assess(renderer: DolbyRendererObservation?) -> Self? {
        guard let renderer, !renderer.failed, renderer.frameFlags & 16 != 0 else { return nil }
        return .init(renderer: renderer)
    }
}
