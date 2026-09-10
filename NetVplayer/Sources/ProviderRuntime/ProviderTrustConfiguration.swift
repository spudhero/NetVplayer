import Foundation

public enum ProviderTrustConfigurationError: LocalizedError, Equatable, Sendable {
    case missingKey(String)
    case invalidKey(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let name): return "Provider trust key is missing: \(name)"
        case .invalidKey(let name): return "Provider trust key is invalid: \(name)"
        }
    }
}

public struct ProviderTrustConfiguration: Sendable {
    public static let manifestKeyName = "NetVplayerProviderManifestEd25519PublicKey"
    public static let distributionKeyName = "NetVplayerProviderDistributionEd25519PublicKey"

    public let manifestPublicKey: Data
    public let distributionPublicKey: Data

    public init(manifestPublicKey: Data, distributionPublicKey: Data) throws {
        guard manifestPublicKey.count == 32 else {
            throw ProviderTrustConfigurationError.invalidKey(Self.manifestKeyName)
        }
        guard distributionPublicKey.count == 32 else {
            throw ProviderTrustConfigurationError.invalidKey(Self.distributionKeyName)
        }
        self.manifestPublicKey = manifestPublicKey
        self.distributionPublicKey = distributionPublicKey
    }

    public static func load(bundle: Bundle = .main) throws -> ProviderTrustConfiguration {
        try load(infoDictionary: bundle.infoDictionary ?? [:])
    }

    public static func load(infoDictionary: [String: Any]) throws -> ProviderTrustConfiguration {
        let manifest = try key(named: manifestKeyName, in: infoDictionary)
        let distribution = try key(named: distributionKeyName, in: infoDictionary)
        return try ProviderTrustConfiguration(
            manifestPublicKey: manifest,
            distributionPublicKey: distribution
        )
    }

    public func manifestVerifier(shellVersion: String) throws -> ProviderManifestVerifier {
        try ProviderManifestVerifier(publicKeyData: manifestPublicKey, shellVersion: shellVersion)
    }

    public func distributionVerifier() throws -> ProviderDistributionIndexVerifier {
        try ProviderDistributionIndexVerifier(publicKeyData: distributionPublicKey)
    }

    private static func key(named name: String, in values: [String: Any]) throws -> Data {
        guard let encoded = values[name] as? String, !encoded.isEmpty else {
            throw ProviderTrustConfigurationError.missingKey(name)
        }
        guard let data = Data(base64Encoded: encoded), data.count == 32 else {
            throw ProviderTrustConfigurationError.invalidKey(name)
        }
        return data
    }
}
