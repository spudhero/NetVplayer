import Foundation

public enum ProviderRuntimeKind: String, Codable, CaseIterable, Sendable {
    case java
    case javaScript = "js"
    case quickJS = "quickjs"
    case python
    case androidDex = "android-dex"
}

public enum ProviderHostCapability: String, Codable, CaseIterable, Sendable {
    case console
    case base64
    case md5
    case url
    case http
    case jsp
    case crypto
    case persistence
    case text
    case module
    case timer
    case localProxy = "local_proxy"
}

public enum ProviderCapability: String, Codable, CaseIterable, Sendable {
    case vod, home, category, search, detail, player, live, epg, proxy, action
}

public enum ProviderCompatibilityStatus: String, Codable, CaseIterable, Sendable {
    case compatible
    case partial
    case needsPort = "needs-port"
    case unsupported
    case blockedLicense = "blocked-license"
}

public enum ProviderReleaseProfile: String, Codable, CaseIterable, Sendable {
    case communityAdhoc = "community-adhoc"
    case developerID = "developer-id"
}

public enum ProviderSourcePolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case userConfiguredOnly = "user-configured-only"
    case userConfiguredCatalog = "user-configured-catalog"
}

public struct ProviderAsset: Codable, Hashable, Sendable {
    public var path: String
    public var sha256: String
    public var executable: Bool

    public init(path: String, sha256: String, executable: Bool = false) {
        self.path = path
        self.sha256 = sha256.lowercased()
        self.executable = executable
    }
}

/// Exact site identities owned by a signed Provider package.
/// Bindings are deliberately exact matches; the shell never evaluates patterns.
public struct ProviderSourceBinding: Codable, Hashable, Sendable {
    public var originalKeys: [String]
    public var originalAPIs: [String]

    public init(originalKeys: [String] = [], originalAPIs: [String] = []) {
        self.originalKeys = originalKeys
        self.originalAPIs = originalAPIs
    }

    enum CodingKeys: String, CodingKey {
        case originalKeys = "original_keys"
        case originalAPIs = "original_apis"
    }
}

public struct ProviderSandboxConfiguration: Codable, Hashable, Sendable {
    public var profileVersion: Int
    public var launcher: String
    public var bundleIdentifier: String
    public var releaseProfile: ProviderReleaseProfile

    public init(
        profileVersion: Int = 2,
        launcher: String,
        bundleIdentifier: String,
        releaseProfile: ProviderReleaseProfile
    ) {
        self.profileVersion = profileVersion
        self.launcher = launcher
        self.bundleIdentifier = bundleIdentifier
        self.releaseProfile = releaseProfile
    }

    enum CodingKeys: String, CodingKey {
        case profileVersion = "profile_version"
        case launcher
        case bundleIdentifier = "bundle_id"
        case releaseProfile = "release_profile"
    }
}

public struct ProviderManifest: Codable, Sendable {
    public var providerID: String
    public var version: String
    public var protocolVersion: Int
    public var shellMinimumVersion: String
    public var shellMaximumVersion: String?
    public var macOSMinimumVersion: String
    public var architectures: [String]
    public var runtime: ProviderRuntimeKind
    public var entrypoint: String
    public var runner: String
    public var runtimeExecutable: String?
    public var sandbox: ProviderSandboxConfiguration?
    public var providerClass: String?
    public var capabilities: [ProviderCapability]
    public var assets: [ProviderAsset]
    public var hostCapabilities: [ProviderHostCapability]
    public var sourceBindings: [ProviderSourceBinding]?
    public var sourcePolicy: ProviderSourcePolicy?
    public var sourceRevision: String?
    public var license: String
    public var status: ProviderCompatibilityStatus
    public var revoked: Bool

    public init(
        providerID: String,
        version: String,
        protocolVersion: Int = 1,
        shellMinimumVersion: String,
        shellMaximumVersion: String? = nil,
        macOSMinimumVersion: String = "14.0",
        architectures: [String],
        runtime: ProviderRuntimeKind,
        entrypoint: String,
        runner: String,
        runtimeExecutable: String? = nil,
        sandbox: ProviderSandboxConfiguration? = nil,
        providerClass: String? = nil,
        capabilities: [ProviderCapability],
        assets: [ProviderAsset],
        hostCapabilities: [ProviderHostCapability] = [],
        sourceBindings: [ProviderSourceBinding]? = nil,
        sourcePolicy: ProviderSourcePolicy? = nil,
        sourceRevision: String? = nil,
        license: String,
        status: ProviderCompatibilityStatus = .compatible,
        revoked: Bool = false
    ) {
        self.providerID = providerID
        self.version = version
        self.protocolVersion = protocolVersion
        self.shellMinimumVersion = shellMinimumVersion
        self.shellMaximumVersion = shellMaximumVersion
        self.macOSMinimumVersion = macOSMinimumVersion
        self.architectures = architectures
        self.runtime = runtime
        self.entrypoint = entrypoint
        self.runner = runner
        self.runtimeExecutable = runtimeExecutable
        self.sandbox = sandbox
        self.providerClass = providerClass
        self.capabilities = capabilities
        self.assets = assets
        self.hostCapabilities = hostCapabilities
        self.sourceBindings = sourceBindings
        self.sourcePolicy = sourcePolicy
        self.sourceRevision = sourceRevision
        self.license = license
        self.status = status
        self.revoked = revoked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        version = try container.decode(String.self, forKey: .version)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        shellMinimumVersion = try container.decode(String.self, forKey: .shellMinimumVersion)
        shellMaximumVersion = try container.decodeIfPresent(String.self, forKey: .shellMaximumVersion)
        macOSMinimumVersion = try container.decode(String.self, forKey: .macOSMinimumVersion)
        architectures = try container.decode([String].self, forKey: .architectures)
        runtime = try container.decode(ProviderRuntimeKind.self, forKey: .runtime)
        entrypoint = try container.decode(String.self, forKey: .entrypoint)
        runner = try container.decode(String.self, forKey: .runner)
        runtimeExecutable = try container.decodeIfPresent(String.self, forKey: .runtimeExecutable)
        sandbox = try container.decodeIfPresent(ProviderSandboxConfiguration.self, forKey: .sandbox)
        providerClass = try container.decodeIfPresent(String.self, forKey: .providerClass)
        capabilities = try container.decode([ProviderCapability].self, forKey: .capabilities)
        assets = try container.decode([ProviderAsset].self, forKey: .assets)
        hostCapabilities = try container.decodeIfPresent(
            [ProviderHostCapability].self,
            forKey: .hostCapabilities
        ) ?? []
        sourceBindings = try container.decodeIfPresent([ProviderSourceBinding].self, forKey: .sourceBindings)
        sourcePolicy = try container.decodeIfPresent(ProviderSourcePolicy.self, forKey: .sourcePolicy)
        sourceRevision = try container.decodeIfPresent(String.self, forKey: .sourceRevision)
        license = try container.decode(String.self, forKey: .license)
        status = try container.decode(ProviderCompatibilityStatus.self, forKey: .status)
        revoked = try container.decode(Bool.self, forKey: .revoked)
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case version
        case protocolVersion = "protocol"
        case shellMinimumVersion = "shell_min_version"
        case shellMaximumVersion = "shell_max_version"
        case macOSMinimumVersion = "macos_min_version"
        case architectures, runtime, entrypoint, runner
        case runtimeExecutable = "runtime_executable"
        case sandbox
        case providerClass = "provider_class"
        case capabilities, assets
        case hostCapabilities = "host_capabilities"
        case sourceBindings = "source_bindings"
        case sourcePolicy = "source_policy"
        case sourceRevision = "source_revision"
        case license, status, revoked
    }
}

public struct SignedProviderManifest: Codable, Sendable {
    public var manifest: ProviderManifest
    public var signature: String

    public init(manifest: ProviderManifest, signature: String) {
        self.manifest = manifest
        self.signature = signature
    }
}
