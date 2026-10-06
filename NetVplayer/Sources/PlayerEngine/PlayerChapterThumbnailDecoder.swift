import Foundation
import Models
import MPVShim

/// A silent, bounded decoder separate from the playing video. It never seeks the
/// playback context, and only runs while a chapter preview is actually requested.
public final class PlayerChapterThumbnailDecoder: @unchecked Sendable {
    public static let shared = PlayerChapterThumbnailDecoder()
    private let queue = DispatchQueue(label: "com.netvplayer.chapter-thumbnails", qos: .utility)

    public init() {}

    public func imageData(spec: PlaySpec, seconds: Double) async -> Data? {
        guard !Task.isCancelled, !spec.url.isEmpty, spec.drm == nil,
              seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1_000 else { return nil }
        if PlaybackTransferPolicy.profile(for: spec).context.connection != .local {
            do { try await PlaybackBackgroundBudget.shared.waitForBackgroundPermission() }
            catch { return nil }
        }
        let cancellation = PreviewCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let data = Self.decode(spec: spec, seconds: seconds, cancellation: cancellation)
                    continuation.resume(returning: cancellation.isCancelled ? nil : data)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func decode(spec: PlaySpec, seconds: Double, cancellation: PreviewCancellation) -> Data? {
        let network = PlaybackTransferPolicy.profile(for: spec).context.connection != .local
        guard !cancellation.isCancelled, !network || PlaybackBackgroundBudget.shared.permitsBackgroundWork,
              let context = nv_mpv_create() else { return nil }
        defer { nv_mpv_destroy(context) }
        let options = [
            "config": "no", "load-scripts": "no", "ytdl": "no", "terminal": "no",
            "msg-level": "all=no", "vo": "null", "ao": "null", "aid": "no", "sid": "no",
            "pause": "yes", "keep-open": "yes", "hwdec": "no", "vd-lavc-threads": "1",
            "cache": "no", "demuxer-max-bytes": "8MiB", "demuxer-max-back-bytes": "0",
            "network-timeout": "5", "start": String(seconds), "hr-seek": "yes",
            "vf": "scale=320:-2", "screenshot-sw": "yes", "screenshot-format": "png",
            "screenshot-png-compression": "1", "user-agent": PlaybackProxyPolicy.defaultHTTPUserAgent
        ]
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
        while !cancellation.isCancelled, ContinuousClock.now < deadline {
            if network, !PlaybackBackgroundBudget.shared.permitsBackgroundWork { return nil }
            var event = NVMPVEvent()
            guard nv_mpv_wait_event(context, 0.05, &event) >= 0 else { return nil }
            if event.event_id == 7 || event.event_id == 1 { return nil } // END_FILE / SHUTDOWN
            guard event.event_id == 21 else { continue } // PLAYBACK_RESTART: requested frame is ready
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
