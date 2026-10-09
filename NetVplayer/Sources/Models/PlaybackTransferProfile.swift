import Foundation

public enum PlaybackTransferMedia: String, Sendable, Equatable {
    case video, compressedAudio, wideAudio, live, unknown
    public var isAudio: Bool { self == .compressedAudio || self == .wideAudio }
}

public enum PlaybackTransferConnection: String, Sendable, Equatable {
    case local, http, hls, smb, webdav, alist, seekableResource
}

public enum PlaybackTransferPhase: String, Sendable {
    case startup, playback, seek, preload, preview, sdkDownload
}

public enum PlaybackTransferPreloadLayout: String, Sendable, Equatable {
    case standard, ucOriginal, quarkOriginal, audioOriginal
}

/// Runtime-only facts. No URLs, headers, credentials, or provider wire formats.
public struct PlaybackTransferContext: Sendable, Equatable {
    public var provider: DriveProvider?
    public var connection: PlaybackTransferConnection
    public var media: PlaybackTransferMedia
    public var contentLength: Int64?
    public var isOriginal: Bool

    public init(provider: DriveProvider? = nil, connection: PlaybackTransferConnection = .http,
                media: PlaybackTransferMedia = .unknown, contentLength: Int64? = nil,
                isOriginal: Bool = false) {
        self.provider = provider; self.connection = connection; self.media = media
        self.contentLength = contentLength.flatMap { $0 > 0 ? $0 : nil }
        self.isOriginal = isOriginal
    }
}

/// Shared limits used by the player, relay, and background work. Provider-specific
/// transfer settings remain explicit instead of being inferred from file size.
public struct PlaybackTransferProfile: Sendable, Equatable {
    public static let version = "20261004.1"
    public static let backgroundByteLimit: Int64 = 16 * 1024 * 1024
    public static let pauseBackgroundBelowSeconds: Double = 10
    public static let resumeBackgroundAtSeconds: Double = 15
    public var context: PlaybackTransferContext
    public var initialReadBytes: Int64
    public var steadyReadBytes: Int64
    public var prefetchWindowBytes: Int64
    public var maximumCachedBytes: Int64
    public var maxConcurrentPrefetches: Int
    public var parallelSegmentBytes: Int64
    public var parallelConcurrency: Int
    public var upstreamRequestTimeout: TimeInterval
    public var usesHTTP2Multiplexing: Bool
    public var usesParallelUpstream: Bool
    public var adaptsConcurrency: Bool
    public var preloadLayout: PlaybackTransferPreloadLayout

    public init(context: PlaybackTransferContext,
                initialReadBytes: Int64 = 4 * 1024 * 1024,
                steadyReadBytes: Int64 = 16 * 1024 * 1024,
                prefetchWindowBytes: Int64 = 96 * 1024 * 1024,
                maximumCachedBytes: Int64 = 192 * 1024 * 1024,
                maxConcurrentPrefetches: Int = 2,
                parallelSegmentBytes: Int64 = 5 * 1024 * 1024,
                parallelConcurrency: Int = 1,
                upstreamRequestTimeout: TimeInterval = 8,
                usesHTTP2Multiplexing: Bool = false,
                usesParallelUpstream: Bool = false,
                adaptsConcurrency: Bool = false,
                preloadLayout: PlaybackTransferPreloadLayout = .standard) {
        self.context = context
        self.initialReadBytes = max(1, initialReadBytes)
        self.steadyReadBytes = max(1, steadyReadBytes)
        self.prefetchWindowBytes = max(0, prefetchWindowBytes)
        self.maximumCachedBytes = max(self.initialReadBytes, maximumCachedBytes)
        self.maxConcurrentPrefetches = max(0, maxConcurrentPrefetches)
        self.parallelSegmentBytes = max(1, parallelSegmentBytes)
        self.parallelConcurrency = max(1, parallelConcurrency)
        self.upstreamRequestTimeout = upstreamRequestTimeout.isFinite
            ? max(1, min(upstreamRequestTimeout, 60)) : 8
        self.usesHTTP2Multiplexing = usesHTTP2Multiplexing
        self.usesParallelUpstream = usesParallelUpstream
        self.adaptsConcurrency = adaptsConcurrency
        self.preloadLayout = preloadLayout
    }

    public var diagnosticName: String {
        "\(context.provider?.rawValue ?? "generic")/\(context.connection.rawValue)/\(context.media.rawValue)/\(context.isOriginal ? "original" : "streaming")"
    }

    public static func seekable(context: PlaybackTransferContext) -> Self {
        .init(context: context, initialReadBytes: 512 * 1024,
              steadyReadBytes: context.connection == .smb ? 4 * 1024 * 1024 : 512 * 1024,
              prefetchWindowBytes: 0, maximumCachedBytes: 32 * 1024 * 1024,
              maxConcurrentPrefetches: 0)
    }
}
