import Foundation
import Models
import Storage

public extension PlaybackDialogueStrength {
    var description: String {
        switch self {
        case .off: L10n.text("关闭")
        case .light: L10n.text("轻度")
        case .medium: L10n.text("中度")
        case .strong: L10n.text("较强")
        }
    }
}

public enum PlaybackDialogueStatus: String, Codable, Sendable {
    case off, checking, applying, center, stereo, unsupportedLayout, passthrough, sourceFilters, failed, restorationFailed
    public var description: String {
        switch self {
        case .off: L10n.text("已关闭，使用原音频处理")
        case .checking: L10n.text("等待确认当前音轨与 PCM 输出")
        case .applying: L10n.text("正在切换对白处理…")
        case .center: L10n.text("中央声道优先：降低其它声道，保留中央声道")
        case .stereo: L10n.text("立体声均衡与动态压缩")
        case .unsupportedLayout: L10n.text("当前声道布局未验证，保留偏好并使用原音频")
        case .passthrough: L10n.text("压缩直通与对白处理互斥；已保留偏好，当前不处理")
        case .sourceFilters: L10n.text("片源已有音频滤镜，保留原处理与对白偏好")
        case .failed: L10n.text("对白处理未能生效，已恢复原音频；可关闭后重试")
        case .restorationFailed: L10n.text("音频处理恢复失败，已暂停。请关闭对白处理后重试，或重新打开媒体。")
        }
    }
}

public struct PlaybackDialogueAssessment: Equatable, Codable, Sendable {
    public var requested: PlaybackDialogueStrength
    public var status: PlaybackDialogueStatus
    /// A successful write alone is not evidence that mpv retained the graph.
    public var filterConfirmed: Bool
}

struct PlaybackDialoguePlan: Equatable, Sendable {
    var strength: PlaybackDialogueStrength
    var status: PlaybackDialogueStatus
    var graph: String = ""
    var filter: String { graph.isEmpty ? "" : "@netvplayer-dialogue:lavfi=[\(graph)]" }
}

enum PlaybackDialoguePolicy {
    static let label = "netvplayer-dialogue"
    static let limiter = "alimiter=limit=0.95:attack=5:release=80:level=0:latency=1"

    static func resolve(strength: PlaybackDialogueStrength, audio: PlaybackDiagnostics.Audio,
                        passthroughRequested: Bool = false, sourceFilters: Bool = false) -> PlaybackDialoguePlan {
        func bypass(_ status: PlaybackDialogueStatus) -> PlaybackDialoguePlan { .init(strength: strength, status: status) }
        guard strength != .off else { return bypass(.off) }
        guard !passthroughRequested, audio.mode != .passthrough else { return bypass(.passthrough) }
        guard !sourceFilters else { return bypass(.sourceFilters) }
        guard audio.mode == .pcm, audio.inputChannelCount != nil else { return bypass(.checking) }
        let level: Int = strength == .light ? 1 : (strength == .medium ? 2 : 3)
        let layouts: [(String, [String])] = [
            ("5.1", ["FL", "FR", "FC", "LFE", "BL", "BR"]),
            ("5.1(side)", ["FL", "FR", "FC", "LFE", "SL", "SR"]),
            ("7.1", ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"])
        ]
        // Accept named positions, never infer a centre from channel count alone.
        if let (layout, channels) = layouts.first(where: {
            $0.1.count == audio.inputChannelCount &&
            (audio.inputChannels == $0.1.map { $0.lowercased() }.joined(separator: "-") ||
             audio.inputChannels == $0.0)
        }) {
            let gain = String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), pow(10, -Double(level * 2) / 20))
            let mapping = channels.map { "\($0)=\($0 == "FC" ? "1" : gain)*\($0)" }.joined(separator: "|")
            return .init(strength: strength, status: .center, graph: "pan=\(layout)|\(mapping),\(limiter)")
        }
        guard audio.inputChannelCount == 2, ["stereo", "fl-fr"].contains(audio.inputChannels ?? "") else {
            return bypass(.unsupportedLayout)
        }
        let gain = ["1.5", "3", "4.5"][level - 1]
        let threshold = ["0.35", "0.25", "0.18"][level - 1]
        let ratio = ["1.5", "2", "3"][level - 1]
        let graph = "volume=-\(gain)dB,equalizer=f=1800:t=q:w=0.7:g=\(gain),"
            + "acompressor=threshold=\(threshold):ratio=\(ratio):attack=10:release=150:knee=2.828427:makeup=1:link=maximum:detection=rms,"
            + limiter
        return .init(strength: strength, status: .stereo, graph: graph)
    }

    static func confirms(_ plan: PlaybackDialoguePlan, property: Data?) -> Bool {
        guard let property, property.count <= PlaybackDiagnosticsSampler.maximumPropertyBytes,
              let filters = try? JSONSerialization.jsonObject(with: property) as? [[String: Any]] else { return false }
        let owned = filters.filter { $0["label"] as? String == label }
        if plan.graph.isEmpty { return owned.isEmpty }
        guard owned.count == 1, let filter = owned.first,
              filter["name"] as? String == "lavfi", filter["enabled"] as? Bool != false,
              let params = filter["params"] as? [String: Any] else { return false }
        return params["graph"] as? String == plan.graph
    }

    static func hasPassthroughRequest(_ data: Data?) -> Bool {
        guard let data, let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return true }
        if let list = value as? [String] { return !list.isEmpty }
        if let text = value as? String { return !text.isEmpty }
        return true
    }
}
