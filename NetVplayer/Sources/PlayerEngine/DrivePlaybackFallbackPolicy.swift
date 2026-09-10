import Foundation
import Models

public enum DrivePlaybackRouteKind: String, Sendable {
    case original
    case smart
}

public struct DrivePlaybackRouteOption: Identifiable, Sendable {
    public let id: String
    public let kind: DrivePlaybackRouteKind
    public let title: String
    public let detail: String
    public let spec: PlaySpec

    public init(id: String, kind: DrivePlaybackRouteKind, title: String, detail: String, spec: PlaySpec) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.spec = spec
    }
}

public enum DrivePlaybackRoutePolicy {
    public static let selectionIDMetadataKey = "drive.route.selectionID"
    public static let selectionKindMetadataKey = "drive.route.selectionKind"
    public static let transportMetadataKey = "drive.route.transport"
    public static let manualSelectionMetadataKey = "drive.route.manualSelection"
    public static let directPlayerTransport = "direct-player"

    public static func preparedSpec(_ spec: PlaySpec) -> PlaySpec {
        guard let candidate = candidate(for: spec) else { return spec }
        return applying(candidate: candidate, to: spec, manualSelection: isManualSelection(spec))
    }

    public static func options(for spec: PlaySpec) -> [DrivePlaybackRouteOption] {
        guard let plan = spec.drivePlaybackPlan else { return [] }
        var visible = [DrivePlaybackCandidate]()
        if let original = plan.candidates.first(where: { $0.kind == .original }) {
            visible.append(original)
        }
        if let smart = plan.candidates.first(where: { $0.kind != .original }) {
            visible.append(smart)
        }
        return visible.map { candidate in
            let routedSpec = applying(candidate: candidate, to: spec, manualSelection: false)
            let kind = routeKind(for: candidate)
            return DrivePlaybackRouteOption(
                id: candidate.id,
                kind: kind,
                title: title(provider: plan.provider, kind: kind),
                detail: kind == .original ? "原文件 · 本地 Range 代理" : "智能转码 · 兼容播放",
                spec: routedSpec
            )
        }
    }

    public static func title(for spec: PlaySpec) -> String? {
        guard let plan = spec.drivePlaybackPlan,
              let candidate = candidate(for: spec) else {
            return nil
        }
        return title(provider: plan.provider, kind: routeKind(for: candidate))
    }

    public static func candidate(for spec: PlaySpec) -> DrivePlaybackCandidate? {
        guard let plan = spec.drivePlaybackPlan else { return nil }
        if let selectedID = spec.metadata[selectionIDMetadataKey],
           let selected = plan.candidates.first(where: { $0.id == selectedID }) {
            return selected
        }
        if let matchingURL = plan.candidates.first(where: { $0.url == spec.url }) {
            return matchingURL
        }
        return plan.primaryCandidate
    }

    public static func spec(
        for candidate: DrivePlaybackCandidate,
        basedOn spec: PlaySpec,
        manualSelection: Bool
    ) -> PlaySpec {
        applying(candidate: candidate, to: spec, manualSelection: manualSelection)
    }

    public static func isManualSelection(_ spec: PlaySpec) -> Bool {
        spec.metadata[manualSelectionMetadataKey] == "true"
    }

    private static func applying(
        candidate: DrivePlaybackCandidate,
        to spec: PlaySpec,
        manualSelection: Bool
    ) -> PlaySpec {
        guard let plan = spec.drivePlaybackPlan else { return spec }
        var routed = spec
        routed.url = candidate.url
        routed.headers = candidate.headers
        routed.fallbackHeaders = [:]
        routed.mpvOptions = candidate.mpvOptions
        routed.metadata[DrivePlaybackMetadataKey.provider] = plan.provider.rawValue
        routed.metadata[DrivePlaybackMetadataKey.route] = candidate.providerRoute
        routed.metadata[DrivePlaybackMetadataKey.quality] = candidate.quality.value
        routed.metadata[DrivePlaybackMetadataKey.qualityLabel] = candidate.quality.label
        routed.metadata[DrivePlaybackMetadataKey.width] = String(candidate.quality.width)
        routed.metadata[DrivePlaybackMetadataKey.height] = String(candidate.quality.height)
        routed.metadata[selectionIDMetadataKey] = candidate.id
        let kind = routeKind(for: candidate)
        routed.metadata[selectionKindMetadataKey] = kind.rawValue
        routed.metadata[transportMetadataKey] = candidate.transport.rawValue
        routed.metadata[manualSelectionMetadataKey] = manualSelection ? "true" : nil
        if kind == .smart {
            routed.metadata[LiveHLSRelayPolicy.transportMetadataKey] = nil
            routed.mpvOptions.removeValue(forKey: "demuxer-lavf-format")
            routed.mpvOptions.removeValue(forKey: "demuxer-lavf-o")
            routed.mpvOptions.removeValue(forKey: "stream-lavf-o")
        }
        return routed
    }

    private static func routeKind(for candidate: DrivePlaybackCandidate) -> DrivePlaybackRouteKind {
        candidate.kind == .original ? .original : .smart
    }

    private static func title(provider: DriveProvider, kind: DrivePlaybackRouteKind) -> String {
        "\(providerLabel(provider))\(kind == .original ? "原" : "智")"
    }

    private static func providerLabel(_ provider: DriveProvider) -> String {
        switch provider {
        case .quark: return "夸克"
        case .uc: return "UC"
        case .ali: return "阿里"
        case .p115: return "115"
        case .pikpak: return "PikPak"
        default: return provider.displayName
        }
    }
}

public enum DrivePlaybackFallbackPolicy {
    public static func shouldFallbackAfterDirectPlaybackFailure(spec: PlaySpec, message: String) -> Bool {
        guard !DrivePlaybackRoutePolicy.isManualSelection(spec),
              let candidate = DrivePlaybackRoutePolicy.candidate(for: spec),
              candidate.transport != .localRangeProxy,
              nextCandidate(for: spec, after: candidate) != nil else {
            return false
        }
        let lower = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !lower.isEmpty && (
            lower.contains("loading failed")
                || lower.contains("failed to open")
                || lower.contains("http")
                || lower.contains("forbidden")
                || lower.contains("timeout")
        )
    }

    public static func fallbackSpec(for spec: PlaySpec, positionSeconds _: Double) -> PlaySpec? {
        guard !DrivePlaybackRoutePolicy.isManualSelection(spec),
              let candidate = DrivePlaybackRoutePolicy.candidate(for: spec),
              let next = nextCandidate(for: spec, after: candidate) else {
            return nil
        }
        return DrivePlaybackRoutePolicy.spec(for: next, basedOn: spec, manualSelection: false)
    }

    private static func nextCandidate(
        for spec: PlaySpec,
        after candidate: DrivePlaybackCandidate
    ) -> DrivePlaybackCandidate? {
        spec.drivePlaybackPlan?.candidate(after: candidate.id)
    }
}
