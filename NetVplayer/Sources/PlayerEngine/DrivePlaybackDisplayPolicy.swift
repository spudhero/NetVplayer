import Foundation
import Models
import DriveEngine

public enum DrivePlaybackDisplayPolicy {
    public static func statusText(for spec: PlaySpec) -> String? {
        guard spec.metadata[DrivePlaybackMetadataKey.provider]?.isEmpty == false else {
            return nil
        }
        let route = spec.metadata[DrivePlaybackMetadataKey.route] ?? ""
        let label = (spec.metadata[DrivePlaybackMetadataKey.qualityLabel] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch route {
        case DrivePlaybackRoute.originalDownload, DrivePlaybackRoute.ucOriginalProxy:
            return "原片"
        case DrivePlaybackRoute.ucOpenAPIStreaming:
            let compactLabel = compactQualityLabel(label)
            return compactLabel.isEmpty ? "UC Streaming" : compactLabel
        case DrivePlaybackRoute.personalTranscode, DrivePlaybackRoute.ucSmartPlay:
            let compactLabel = compactQualityLabel(label)
            if compactLabel.localizedCaseInsensitiveContains("4K") {
                return "4K 转码"
            }
            return compactLabel.isEmpty || compactLabel == "转码" ? "转码" : "转码 \(compactLabel)"
        default:
            return nil
        }
    }

    private static func compactQualityLabel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("4k") { return "4K" }
        if lower.contains("2k") { return "2K" }
        if lower.contains("1080") { return "1080P" }
        if lower.contains("720") { return "720P" }
        if lower.contains("540") { return "540P" }
        if lower.contains("480") { return "480P" }
        return label
    }
}
