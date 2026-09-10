import Foundation

public struct ProviderRelease: Codable, Hashable, Sendable {
    public var providerID: String
    public var version: String
    public var architectures: [String]
    public var archiveURL: URL
    public var archiveSHA256: String

    public init(
        providerID: String,
        version: String,
        architectures: [String],
        archiveURL: URL,
        archiveSHA256: String
    ) {
        self.providerID = providerID
        self.version = version
        self.architectures = architectures
        self.archiveURL = archiveURL
        self.archiveSHA256 = archiveSHA256.lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case version, architectures
        case archiveURL = "archive_url"
        case archiveSHA256 = "archive_sha256"
    }
}

public struct ProviderVersionReference: Codable, Hashable, Sendable {
    public var providerID: String
    public var version: String

    public init(providerID: String, version: String) {
        self.providerID = providerID
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case version
    }
}

public struct ProviderDistributionIndex: Codable, Sendable {
    public var protocolVersion: Int
    public var generatedAt: Date
    public var releases: [ProviderRelease]
    public var revoked: [ProviderVersionReference]

    public init(
        protocolVersion: Int = 2,
        generatedAt: Date,
        releases: [ProviderRelease],
        revoked: [ProviderVersionReference] = []
    ) {
        self.protocolVersion = protocolVersion
        self.generatedAt = generatedAt
        self.releases = releases
        self.revoked = revoked
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case generatedAt = "generated_at"
        case releases, revoked
    }
}

public struct SignedProviderDistributionIndex: Codable, Sendable {
    public var index: ProviderDistributionIndex
    public var signature: String

    public init(index: ProviderDistributionIndex, signature: String) {
        self.index = index
        self.signature = signature
    }
}
