import CryptoKit
import Foundation

public enum PlaybackCandidateKind: String, Codable, Sendable, CaseIterable {
    case directURL
    case externalURL
    case torrent
    case youtube
    case usenet
    case archive
    case unknown
}

public enum PlaybackCandidateStatus: String, Codable, Sendable {
    case playable
    case unsupported
}

public struct PlaybackCandidate: Codable, Identifiable, Sendable {
    public var id: String
    public var providerKey: String
    public var providerName: String
    public var name: String
    public var description: String
    public var kind: PlaybackCandidateKind
    public var status: PlaybackCandidateStatus
    public var unavailableReason: String
    public var url: String
    public var headers: [String: String]
    public var responseHeaders: [String: String]
    public var format: String
    public var subtitles: [Sub]
    public var bingeGroup: String
    public var metadata: [String: String]

    public init(
        id: String = "",
        providerKey: String,
        providerName: String,
        name: String = "",
        description: String = "",
        kind: PlaybackCandidateKind,
        status: PlaybackCandidateStatus,
        unavailableReason: String = "",
        url: String = "",
        headers: [String: String] = [:],
        responseHeaders: [String: String] = [:],
        format: String = "",
        subtitles: [Sub] = [],
        bingeGroup: String = "",
        metadata: [String: String] = [:]
    ) {
        self.providerKey = providerKey
        self.providerName = providerName
        self.name = name
        self.description = description
        self.kind = kind
        self.status = status
        self.unavailableReason = unavailableReason
        self.url = url
        self.headers = headers
        self.responseHeaders = responseHeaders
        self.format = format
        self.subtitles = subtitles
        self.bingeGroup = bingeGroup
        self.metadata = metadata
        self.id = id.isEmpty
            ? Self.stableID(providerKey: providerKey, kind: kind, url: url, headers: headers, metadata: metadata)
            : id
    }

    public var isPlayable: Bool {
        status == .playable && kind == .directURL && !url.isEmpty
    }

    public var preferenceSignature: String? {
        guard !bingeGroup.isEmpty else { return nil }
        return "\(providerKey)\u{0}\(bingeGroup)"
    }

    private static func stableID(
        providerKey: String,
        kind: PlaybackCandidateKind,
        url: String,
        headers: [String: String],
        metadata: [String: String]
    ) -> String {
        let headerMaterial = headers
            .map { ($0.key.lowercased(), $0.value) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)" }
            .joined(separator: "\n")
        let locator = url.isEmpty ? (metadata["playback.locator"] ?? "") : url
        let material = "\(providerKey)\u{0}\(kind.rawValue)\u{0}\(locator)\u{0}\(headerMaterial)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
