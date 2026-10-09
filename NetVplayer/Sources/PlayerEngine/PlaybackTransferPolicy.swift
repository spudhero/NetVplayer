import Foundation
import Models
import DriveEngine
import ProxyServer

public enum PlaybackTransferPolicy {
    public static let detectedContainerMetadataKey = "playback.detectedContainer"
    public static func media(for spec: PlaySpec) -> PlaybackTransferMedia {
        if spec.metadata["playback.kind"] == "live" { return .live }
        let reference = DriveFileReference.parse(spec.metadata["vod.episodeURL"] ?? "")
        let format = reference.flatMap { $0.formatType.isEmpty ? nil : $0.formatType } ?? spec.format
        // A renamed .mp3 may be a video. Keep explicit video MIME/type or
        // dimensions from this asset's playback plan ahead of filename hints.
        let declaredVideo = format.lowercased() == "video" || format.lowercased().hasPrefix("video/")
        let videoDimensions = spec.drivePlaybackPlan.map { plan in
            plan.candidates.contains { $0.quality.width > 0 && $0.quality.height > 0 }
        } ?? ((Int(spec.metadata[DrivePlaybackMetadataKey.width] ?? "") ?? 0) > 0
            && (Int(spec.metadata[DrivePlaybackMetadataKey.height] ?? "") ?? 0) > 0)
        if declaredVideo || videoDimensions { return .video }
        let names = [reference?.fileName ?? "", spec.metadata["drive.fileName"] ?? "",
                     spec.metadata["vod.episodeName"] ?? "", URL(string: spec.url)?.lastPathComponent ?? ""]
        let isAudio = names.contains {
            DriveMediaClassifier.isPlayableAudio(name: $0, formatType: format,
                                                  isDirectory: false, isFile: true)
        }
        guard isAudio else { return .video }
        // Container evidence does not prove that an audio-only MP4/MKV has a
        // video track. For conflicting audio extensions use the general media
        // window, without making the file eligible for video-only SDK work.
        if let container = spec.metadata[detectedContainerMetadataKey], ["mov", "matroska"].contains(container) {
            let compatibleAudioExtensions: Set<String> = container == "mov" ? ["m4a", "m4b", "alac"] : ["mka"]
            if !names.contains(where: { compatibleAudioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
                return .unknown
            }
        }
        let wide: Set<String> = ["wav", "wave", "flac", "ape", "alac", "aiff", "aif", "aifc", "caf", "dsf", "dff"]
        let wideFormat = ["wav", "flac", "ape", "alac", "aiff", "pcm", "dsf", "dff"]
            .contains { format.lowercased().contains($0) }
        return wideFormat || names.contains { wide.contains(($0 as NSString).pathExtension.lowercased()) }
            ? .wideAudio : .compressedAudio
    }

    public static func profile(for spec: PlaySpec) -> PlaybackTransferProfile {
        if let profile = spec.transferProfile { return profile }
        if let profile = ProxyServer.shared.seekableResourceTransferProfile(forLocalURL: spec.url) { return profile }
        let provider = spec.drivePlaybackPlan?.provider
            ?? DriveProvider(rawValue: spec.metadata[DrivePlaybackMetadataKey.provider] ?? "")
        let route = spec.metadata[DrivePlaybackMetadataKey.route]
        let original = route == DrivePlaybackRoute.originalDownload || route == DrivePlaybackRoute.ucOriginalProxy
        let url = URL(string: spec.url)
        let connection: PlaybackTransferConnection = url?.isFileURL == true ? .local
            : (url?.pathExtension.lowercased() == "m3u8" || spec.format.lowercased().contains("hls")) ? .hls : .http
        return profile(context: .init(provider: provider, connection: connection,
            media: media(for: spec), contentLength: spec.contentLength
                ?? spec.metadata[DrivePlaybackMetadataKey.size].flatMap(Int64.init), isOriginal: original))
    }

    public static func profile(context: PlaybackTransferContext) -> PlaybackTransferProfile {
        var profile = PlaybackTransferProfile(context: context)
        if [.smb, .webdav, .alist, .seekableResource].contains(context.connection) {
            return .seekable(context: context)
        }
        guard context.isOriginal, context.connection != .local else { return profile }
        if context.media.isAudio {
            let wide = context.media == .wideAudio
            profile.initialReadBytes = 64 * 1024
            profile.steadyReadBytes = 512 * 1024
            profile.prefetchWindowBytes = Int64(wide ? 6 : 2) * 1024 * 1024
            profile.maximumCachedBytes = Int64(wide ? 16 : 8) * 1024 * 1024
            profile.maxConcurrentPrefetches = 1
            profile.preloadLayout = .audioOriginal
            if [.quark, .uc, .baidu, .p115].contains(context.provider) {
                profile.usesParallelUpstream = true
                profile.usesHTTP2Multiplexing = context.provider == .quark || context.provider == .uc
                profile.parallelSegmentBytes = 512 * 1024
                profile.parallelConcurrency = wide && context.provider != .p115 ? 6 : 2
            }
            return profile
        }
        switch context.provider {
        case .ali:
            profile.initialReadBytes = 1024 * 1024; profile.steadyReadBytes = 1024 * 1024
            profile.prefetchWindowBytes = 16 * 1024 * 1024; profile.maximumCachedBytes = 32 * 1024 * 1024
            profile.usesParallelUpstream = true; profile.parallelSegmentBytes = 256 * 1024
            profile.parallelConcurrency = 8
            // This CDN delivers valid 256 KiB ranges in roughly nine seconds.
            // An eight-second deadline repeatedly discards useful responses.
            profile.upstreamRequestTimeout = 15
        case .p115:
            profile.initialReadBytes = 512 * 1024; profile.steadyReadBytes = 512 * 1024
            profile.prefetchWindowBytes = 8 * 1024 * 1024; profile.maximumCachedBytes = 32 * 1024 * 1024
            profile.maxConcurrentPrefetches = 1
            profile.usesParallelUpstream = true; profile.parallelSegmentBytes = 512 * 1024
            profile.parallelConcurrency = 2
        case .uc, .quark, .pikpak:
            profile.initialReadBytes = 4 * 1024 * 1024; profile.steadyReadBytes = 4 * 1024 * 1024
            profile.prefetchWindowBytes = 32 * 1024 * 1024; profile.maximumCachedBytes = 64 * 1024 * 1024
            if context.provider != .pikpak {
                profile.usesParallelUpstream = true; profile.usesHTTP2Multiplexing = true
                profile.parallelSegmentBytes = context.provider == .uc ? 97_280 : 400 * 1024
                profile.parallelConcurrency = context.provider == .uc ? 140 : 60
                profile.preloadLayout = context.provider == .uc ? .ucOriginal : .quarkOriginal
                profile.adaptsConcurrency = true
            }
        case .baidu:
            profile.usesParallelUpstream = true; profile.parallelSegmentBytes = 512 * 1024
            profile.parallelConcurrency = 5
        default: break
        }
        return profile
    }

    static func bufferConfiguration(_ profile: PlaybackTransferProfile) -> RemoteStreamBufferConfiguration {
        .init(initialChunkSize: profile.initialReadBytes, chunkSize: profile.steadyReadBytes,
              prefetchWindowSize: profile.prefetchWindowBytes, maxBytes: profile.maximumCachedBytes,
              maxConcurrentPrefetches: profile.maxConcurrentPrefetches)
    }
}
