// DriveEngine/DriveSearchGroupingPolicy.swift
// Classifies search results by drive provider and stable reference metadata.

import Foundation
import Models

public enum DriveSearchValidity: String, Codable, Sendable, Equatable {
    case available
    case requiresAuth
    case suspectedInvalid
    case unknown

    public var displayName: String {
        switch self {
        case .available: return "可用"
        case .requiresAuth: return "需要登录"
        case .suspectedInvalid: return "疑似失效"
        case .unknown: return "未知"
        }
    }
}

public struct DriveSearchDescriptor: Codable, Sendable, Equatable {
    public var provider: DriveProvider
    public var shareURL: String
    public var fileID: String
    public var resourceID: String
    public var requiresAuth: Bool
    public var validity: DriveSearchValidity
    public var sourceName: String
    public var referenceURL: String

    public init(
        provider: DriveProvider = .unknown,
        shareURL: String = "",
        fileID: String = "",
        resourceID: String = "",
        requiresAuth: Bool = false,
        validity: DriveSearchValidity = .unknown,
        sourceName: String = "",
        referenceURL: String = ""
    ) {
        self.provider = provider
        self.shareURL = shareURL
        self.fileID = fileID
        self.resourceID = resourceID
        self.requiresAuth = requiresAuth
        self.validity = validity
        self.sourceName = sourceName
        self.referenceURL = referenceURL
    }

    public static func infer(from vod: Vod, sourceName: String = "") -> DriveSearchDescriptor {
        let candidates = [
            vod.vodId,
            vod.vodPlayUrl,
            vod.vodRemarks,
            vod.vodContent
        ].filter { !$0.isEmpty }

        for candidate in candidates {
            if let reference = DriveFileReference.parse(candidate) {
                return DriveSearchDescriptor(
                    provider: reference.provider,
                    shareURL: reference.shareURL,
                    fileID: reference.personalFileID.isEmpty ? reference.fid : reference.personalFileID,
                    resourceID: reference.pwdID,
                    requiresAuth: requiresAuth(provider: reference.provider),
                    validity: requiresAuth(provider: reference.provider) ? .requiresAuth : .available,
                    sourceName: sourceName.isEmpty ? vod.siteKey : sourceName,
                    referenceURL: reference.encodedURL
                )
            }
        }

        let joined = candidates.joined(separator: " ")
        let provider = DriveFileReference.provider(for: joined)
        guard provider != .unknown else {
            return DriveSearchDescriptor(
                provider: .unknown,
                validity: .unknown,
                sourceName: sourceName.isEmpty ? vod.siteKey : sourceName
            )
        }

        let lower = joined.lowercased()
        let suspectedInvalid = lower.contains("失效")
            || lower.contains("取消")
            || lower.contains("invalid")
            || lower.contains("expired")
            || lower.contains("not found")
        let authRequired = requiresAuth(provider: provider)
        return DriveSearchDescriptor(
            provider: provider,
            shareURL: firstURL(in: joined),
            fileID: "",
            resourceID: "",
            requiresAuth: authRequired,
            validity: suspectedInvalid ? .suspectedInvalid : (authRequired ? .requiresAuth : .unknown),
            sourceName: sourceName.isEmpty ? vod.siteKey : sourceName,
            referenceURL: ""
        )
    }

    private static func requiresAuth(provider: DriveProvider) -> Bool {
        switch provider {
        case .quark, .uc, .ali, .p115, .pikpak:
            return true
        default:
            return false
        }
    }

    private static func firstURL(in text: String) -> String {
        let pattern = #"https?://[^\s#$,，]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            return ""
        }
        return String(text[range])
    }
}

public struct DriveSearchVodGroup: Sendable, Identifiable {
    public var provider: DriveProvider
    public var title: String
    public var validity: DriveSearchValidity
    public var vods: [Vod]

    public var id: String { provider.rawValue }

    public init(provider: DriveProvider, title: String, validity: DriveSearchValidity, vods: [Vod]) {
        self.provider = provider
        self.title = title
        self.validity = validity
        self.vods = vods
    }
}

public enum DriveSearchGroupingPolicy {
    private static let providerOrder: [DriveProvider] = [.quark, .uc, .ali, .p115, .pikpak, .unknown]

    public static func groups(for vods: [Vod], sourceName: String = "") -> [DriveSearchVodGroup] {
        let grouped = Dictionary(grouping: vods) { vod in
            DriveSearchDescriptor.infer(from: vod, sourceName: sourceName).provider
        }
        return grouped.map { provider, items in
            let descriptors = items.map { DriveSearchDescriptor.infer(from: $0, sourceName: sourceName) }
            return DriveSearchVodGroup(
                provider: provider,
                title: provider == .unknown ? "其它" : provider.displayName,
                validity: summarizedValidity(descriptors),
                vods: items
            )
        }
        .sorted { lhs, rhs in
            orderIndex(lhs.provider) < orderIndex(rhs.provider)
        }
    }

    private static func orderIndex(_ provider: DriveProvider) -> Int {
        providerOrder.firstIndex(of: provider) ?? providerOrder.count
    }

    private static func summarizedValidity(_ descriptors: [DriveSearchDescriptor]) -> DriveSearchValidity {
        if descriptors.contains(where: { $0.validity == .available }) { return .available }
        if descriptors.contains(where: { $0.validity == .requiresAuth }) { return .requiresAuth }
        if descriptors.contains(where: { $0.validity == .suspectedInvalid }) { return .suspectedInvalid }
        return .unknown
    }
}
