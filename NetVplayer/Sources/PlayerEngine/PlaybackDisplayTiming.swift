import Foundation
import Models

/// Public display-mode facts, not physical scanout or HDMI negotiation evidence.
public struct PlaybackDisplayTiming: Equatable, Codable, Sendable {
    public enum RateMatching: String, Codable, Sendable {
        case notEnabled
        public var description: String { L10n.text("应用未切换系统刷新率") }
    }
    public enum QMS: String, Codable, Sendable {
        case unverified
        public var description: String { L10n.text("QMS 完整链路未验证") }
    }
    public let configuredRefreshRateHz: Double?
    public let rateMatching: RateMatching
    public let qms: QMS

    public init(configuredRefreshRateHz: Double?) {
        self.configuredRefreshRateHz = configuredRefreshRateHz.flatMap {
            $0.isFinite && $0 > 0 && $0 <= 1_000 ? $0 : nil
        }
        rateMatching = .notEnabled
        qms = .unverified
    }
}
