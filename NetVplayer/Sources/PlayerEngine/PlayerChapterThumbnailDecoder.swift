import AppKit
import Foundation
import Models
import ProxyServer
import MPVShim

/// A silent, bounded decoder separate from the playing video. It never seeks the
/// playback context, and only runs while a chapter preview is actually requested.
public final class PlayerChapterThumbnailDecoder: @unchecked Sendable {
    public static let shared = PlayerChapterThumbnailDecoder()
    private let queue = DispatchQueue(label: "com.netvplayer.chapter-thumbnails", qos: .utility)

    public init() {}

    /// Live input starts at the current stream position: never seek to VOD time zero.
    /// Shares the chapter decoder's single physical queue and pinned libmpv runtime.
    public func liveImageData(spec: PlaySpec) async -> Data? {
        guard PlaybackBackgroundBudget.shared.permitsOptionalWork else { return nil }
        do {
            return try await PlaybackBackgroundBudget.shared.withRead(purpose: .chapterPreview, bytes: 8 * 1_024 * 1_024) {
                await self.ownedImageData(spec: spec, seconds: nil, usesReadLease: false)
            }
        } catch { return nil }
    }

    public func imageData(spec: PlaySpec, seconds: Double) async -> Data? {
        guard !Task.isCancelled, !spec.url.isEmpty, spec.drm == nil,
              seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1_000 else { return nil }
        let session = spec.readSession ?? PlaybackReadSession()
        let generation = session.generation
        let isNetwork = PlaybackTransferPolicy.profile(for: spec).context.connection != .local
        if isNetwork {
            // Seeking or buffering can defer admission. The media reader's
            // lifetime starts after that wait, while the generation stays fixed.
            let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(4))
            while !PlaybackBackgroundBudget.shared.permitsBackgroundWork {
                guard session.isCurrent(generation), ContinuousClock.now < admissionDeadline else { return nil }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
            }
        }
        let identity = PlaybackMediaIdentity.resolved(for: spec)
            ?? .init(source: "runtime", account: "session", item: session.id.uuidString)
        let lifetime: TimeInterval = isNetwork ? 12 : 8
        let owner = session.makeOwner(mediaIdentity: identity, purpose: .chapterPreview,
            expiry: ProcessInfo.processInfo.systemUptime + lifetime)
        guard !Task.isCancelled, owner.generation == generation, !owner.isCancelled else { return nil }
        let lease = ProxyServer.shared.readLease(for: spec, session: session,
            mediaIdentity: identity, purpose: .chapterPreview, lifetime: lifetime)
        defer { owner.cancel(); lease?.cancel() }
        var prepared = spec
        if let lease { prepared.url = lease.url }
        let input = prepared
        do {
            return try await owner.perform {
                if let lease {
                    return await withTaskCancellationHandler {
                        await self.ownedImageData(spec: input, seconds: seconds, usesReadLease: true)
                    } onCancel: { lease.cancel() }
                }
                if !isNetwork {
                    return await self.ownedImageData(spec: input, seconds: seconds, usesReadLease: false)
                }
                return try await PlaybackBackgroundBudget.shared.withRead(owner: owner, bytes: 8 * 1024 * 1024) {
                    await self.ownedImageData(spec: input, seconds: seconds, usesReadLease: false)
                }
            }
        } catch { return nil }
    }

    private func ownedImageData(spec: PlaySpec, seconds: Double?, usesReadLease: Bool) async -> Data? {
        guard !Task.isCancelled, !spec.url.isEmpty, spec.drm == nil else { return nil }
        let isNetwork = PlaybackTransferPolicy.profile(for: spec).context.connection != .local
        // Leased proxy sources admit each range separately. A foreground
        // request may stall a range without invalidating the entire preview.
        let checksBackgroundPermission = isNetwork && !usesReadLease
        let cancellation = PreviewCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let data = Self.decode(spec: spec, seconds: seconds, cancellation: cancellation,
                        checksBackgroundPermission: checksBackgroundPermission)
                    continuation.resume(returning: cancellation.isCancelled ? nil : data)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func decode(spec: PlaySpec, seconds: Double?, cancellation: PreviewCancellation,
                               checksBackgroundPermission: Bool) -> Data? {
        guard !cancellation.isCancelled, !checksBackgroundPermission || PlaybackBackgroundBudget.shared.permitsBackgroundWork,
              seconds != nil || PlaybackBackgroundBudget.shared.permitsOptionalWork,
              let context = nv_mpv_create() else { return nil }
          let nativeRenderer = nv_mpv_runtime_capabilities(context) & 3 == 3
          let surface = nativeRenderer ? NVMPVThumbnailSurface(width: 320, height: 180) : nil
          defer { surface?.makeCurrent(); nv_mpv_destroy(context); surface?.close() }
          // Preserve the decoded RPU and enhancement layer through the same
          // renderer as playback. A software scale/screenshot would discard it.
          if nativeRenderer && surface == nil { return nil }
          var options = [
            "config": "no", "load-scripts": "no", "ytdl": "no", "terminal": "no",
            "msg-level": "all=no", "vo": "null", "ao": "null", "aid": "no", "sid": "no",
            "pause": "yes", "keep-open": "yes", "hwdec": "no", "vd-lavc-threads": "1",
            "cache": "no", "demuxer-max-bytes": "8MiB", "demuxer-max-back-bytes": "0",
            "network-timeout": "5", "hr-seek": "yes",
            "vf": "scale=320:-2", "screenshot-sw": "yes", "screenshot-format": "png",
            "screenshot-png-compression": "1", "user-agent": PlaybackProxyPolicy.defaultHTTPUserAgent
        ]
            if let seconds { options["start"] = String(seconds) }
          if surface != nil {
              options["vo"] = "libmpv"
              options["hwdec"] = "videotoolbox-copy"
              options["vf"] = ""
              options["osd-level"] = "0"
              for (name, value) in PlaybackColorPolicy.options(source: [:], preference: .init()) {
                  options[name] = value.value
              }
          }
        for (name, value) in options {
            guard nv_mpv_set_option_string(context, name, value) >= 0 else { return nil }
        }
        let transport = PlaybackTransportOptions.resolved(spec.mpvOptions, url: spec.url,
            direct: spec.metadata["network.explicitDirect"] == "true")
        let transportNames: Set<String> = ["http-proxy", "stream-lavf-o", "demuxer-lavf-o",
            "demuxer-lavf-format", "demuxer-lavf-probesize", "demuxer-lavf-analyzeduration"]
        for (name, value) in transport where transportNames.contains(name) && MPVOptionPolicy.accepts(name: name, value: value) {
            guard nv_mpv_set_option_string(context, name, value) >= 0 else { return nil }
        }
        guard !cancellation.isCancelled, nv_mpv_initialize(context) >= 0 else { return nil }
          if let surface {
              surface.makeCurrent()
              guard nv_mpv_create_render_context(context, nil, nil) >= 0 else { return nil }
              // The PNG is tagged sRGB, so use that same destination profile
              // instead of the current display profile or an unprofiled target.
              guard let profile = NSColorSpace.sRGB.iccProfileData,
                    profile.withUnsafeBytes({ nv_mpv_set_render_icc(context, $0.baseAddress, $0.count) }) >= 0 else { return nil }
          }
        for (name, value) in spec.headers {
            guard !name.isEmpty, !value.isEmpty,
                  !name.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }),
                  !value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { continue }
            switch name.lowercased() {
            case "host", "range": continue
            case "user-agent": _ = nv_mpv_set_property_string(context, "user-agent", value)
            case "referer": _ = nv_mpv_set_property_string(context, "referrer", value)
            default: _ = nv_mpv_append_http_header(context, "\(name): \(value)")
            }
        }
        guard !cancellation.isCancelled,
              nv_mpv_command3(context, "loadfile", spec.url, "replace") >= 0 else { return nil }

          let deadline = ContinuousClock.now.advanced(by: .seconds(8))
          var restarted = false
        while !cancellation.isCancelled, ContinuousClock.now < deadline {
              if seconds == nil, !PlaybackBackgroundBudget.shared.permitsOptionalWork { return nil }
              if checksBackgroundPermission, !PlaybackBackgroundBudget.shared.permitsBackgroundWork { return nil }
              if let surface {
                  surface.makeCurrent()
                  guard nv_mpv_render(context, surface.framebuffer, 320, 180, 0) >= 0 else { return nil }
                  let status = nv_mpv_dolby_renderer_status(context)
                  if status.failures > 0 { return nil }
                  if restarted && status.rendered_frames > 0 { return surface.pngData() }
              }
            var event = NVMPVEvent()
            guard nv_mpv_wait_event(context, 0.05, &event) >= 0 else { return nil }
            if event.event_id == 7 || event.event_id == 1 { return nil } // END_FILE / SHUTDOWN
            guard event.event_id == 21 else { continue } // PLAYBACK_RESTART: requested frame is ready
              if surface != nil { restarted = true; continue }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NetVplayer-chapter-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let output = directory.appendingPathComponent("frame.png")
                guard nv_mpv_command3(context, "screenshot-to-file", output.path, "video") >= 0,
                      !cancellation.isCancelled else { return nil }
                let data = try Data(contentsOf: output)
                return data.count <= 2 * 1_024 * 1_024 ? data : nil
            } catch { return nil }
        }
        return nil
    }
}

private final class PreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
