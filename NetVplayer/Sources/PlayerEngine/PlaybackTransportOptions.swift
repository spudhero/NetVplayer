import Foundation
import Networking

/// Configure both mpv and its FFmpeg protocols. An empty mpv proxy alone can
/// otherwise leave FFmpeg's environment fallback active.
public enum PlaybackTransportOptions {
    public static func resolved(_ options: [String: String], url: String, direct: Bool) -> [String: String] {
        var result = options
        let parsed = URL(string: url)
        let local = parsed.map { $0.isFileURL || HTTPRedirectPolicy.isLoopback($0) } ?? false
        let proxy = direct || local ? "" : options["http-proxy"]
        guard let proxy else { return result } // Preserve the automatic policy when unresolved.
        result["http-proxy"] = proxy
        for key in ["stream-lavf-o", "demuxer-lavf-o"] {
            let retained = (options[key] ?? "").split(separator: ",")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("http_proxy=") }
            result[key] = (retained.map(String.init) + ["http_proxy=" + proxy.replacingOccurrences(of: ",", with: "%2C")]).joined(separator: ",")
        }
        return result
    }
}
