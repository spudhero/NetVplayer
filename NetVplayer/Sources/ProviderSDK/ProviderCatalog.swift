import Foundation

public enum ProviderNetworkStatus: String, Codable, CaseIterable, Sendable {
    case usable
    case networkBlocked = "network-blocked"
    case empty
    case configuration
    case untested
}

public enum ProviderRuntimePackagingStatus: String, Codable, CaseIterable, Sendable {
    case passed
    case pocOnly = "poc-only"
    case hostDependent = "host-dependent"
    case untested
    case notApplicable = "not-applicable"
}

public struct ProviderCatalogRecord: Codable, Sendable {
    public var providerID: String
    public var name: String
    public var runtime: ProviderRuntimeKind
    public var originalAPI: String?
    public var originalExtension: String?
    public var originalJar: String?
    public var originalSpider: String?
    public var capabilities: [ProviderCapability]
    public var dependencies: [String]
    public var license: String?
    public var source: String?
    public var compatibility: ProviderCompatibilityStatus
    public var runnerVerified: Bool?
    public var parserVerified: Bool?
    public var runtimePackaging: ProviderRuntimePackagingStatus
    public var network: ProviderNetworkStatus
    public var playbackVerified: Bool
    public var distributionReady: Bool
    public var reason: String?

    public init(
        providerID: String,
        name: String,
        runtime: ProviderRuntimeKind,
        originalAPI: String? = nil,
        originalExtension: String? = nil,
        originalJar: String? = nil,
        originalSpider: String? = nil,
        capabilities: [ProviderCapability] = [],
        dependencies: [String] = [],
        license: String? = nil,
        source: String? = nil,
        compatibility: ProviderCompatibilityStatus,
        runnerVerified: Bool? = nil,
        parserVerified: Bool? = nil,
        runtimePackaging: ProviderRuntimePackagingStatus = .untested,
        network: ProviderNetworkStatus = .untested,
        playbackVerified: Bool = false,
        distributionReady: Bool = false,
        reason: String? = nil
    ) {
        self.providerID = providerID
        self.name = name
        self.runtime = runtime
        self.originalAPI = originalAPI
        self.originalExtension = originalExtension
        self.originalJar = originalJar
        self.originalSpider = originalSpider
        self.capabilities = capabilities
        self.dependencies = dependencies
        self.license = license
        self.source = source
        self.compatibility = compatibility
        self.runnerVerified = runnerVerified
        self.parserVerified = parserVerified
        self.runtimePackaging = runtimePackaging
        self.network = network
        self.playbackVerified = playbackVerified
        self.distributionReady = distributionReady
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case name, runtime
        case originalAPI = "original_api"
        case originalExtension = "original_ext"
        case originalJar = "original_jar"
        case originalSpider = "original_spider"
        case capabilities, dependencies, license, source, compatibility, network
        case runnerVerified = "runner_verified"
        case parserVerified = "parser_verified"
        case runtimePackaging = "runtime_packaging"
        case playbackVerified = "playback_verified"
        case distributionReady = "distribution_ready"
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        name = try container.decode(String.self, forKey: .name)
        runtime = try container.decode(ProviderRuntimeKind.self, forKey: .runtime)
        originalAPI = try container.decodeIfPresent(String.self, forKey: .originalAPI)
        originalExtension = try container.decodeIfPresent(String.self, forKey: .originalExtension)
        originalJar = try container.decodeIfPresent(String.self, forKey: .originalJar)
        originalSpider = try container.decodeIfPresent(String.self, forKey: .originalSpider)
        capabilities = try container.decodeIfPresent([ProviderCapability].self, forKey: .capabilities) ?? []
        dependencies = try container.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        license = try container.decodeIfPresent(String.self, forKey: .license)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        compatibility = try container.decode(ProviderCompatibilityStatus.self, forKey: .compatibility)
        runnerVerified = try container.decodeIfPresent(Bool.self, forKey: .runnerVerified)
        parserVerified = try container.decodeIfPresent(Bool.self, forKey: .parserVerified)
        runtimePackaging = try container.decodeIfPresent(ProviderRuntimePackagingStatus.self, forKey: .runtimePackaging) ?? .untested
        network = try container.decode(ProviderNetworkStatus.self, forKey: .network)
        playbackVerified = try container.decode(Bool.self, forKey: .playbackVerified)
        distributionReady = try container.decodeIfPresent(Bool.self, forKey: .distributionReady) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}
