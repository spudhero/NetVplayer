import Foundation
import Network

public enum ProviderIntegrationMode: String, Codable, CaseIterable, Sendable {
    case configOnly = "config-only"
    case provider
    case userOwnedBackend = "user-owned-backend"
}

public enum ProviderBackendKind: String, Codable, CaseIterable, Sendable {
    case webdav
    case alist
    case openList = "openlist"
    case tvboxCompatible = "tvbox-compatible"
}

public enum ProviderBackendRedirectPolicy: String, Codable, Hashable, Sendable {
    case sameOriginOnly = "same-origin-only"
}

public enum ProviderEndpointScope: String, Codable, Hashable, Sendable {
    case publicInternet = "public-internet"
    case localNetwork = "local-network"
}

public struct ProviderBackendPermissions: Codable, Hashable, Sendable {
    public var allowsInsecureHTTP: Bool
    public var allowsLocalNetwork: Bool
    public var allowsCredentialForwarding: Bool
    public var redirectPolicy: ProviderBackendRedirectPolicy

    public init(
        allowsInsecureHTTP: Bool = false,
        allowsLocalNetwork: Bool = false,
        allowsCredentialForwarding: Bool = false,
        redirectPolicy: ProviderBackendRedirectPolicy = .sameOriginOnly
    ) {
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.allowsLocalNetwork = allowsLocalNetwork
        self.allowsCredentialForwarding = allowsCredentialForwarding
        self.redirectPolicy = redirectPolicy
    }

    public static let secureDefault = ProviderBackendPermissions()

    enum CodingKeys: String, CodingKey {
        case allowsInsecureHTTP = "allow_insecure_http"
        case allowsLocalNetwork = "allow_local_network"
        case allowsCredentialForwarding = "allow_credential_forwarding"
        case redirectPolicy = "redirect_policy"
    }
}

public enum ProviderSourceDescriptorValidationError: Error, Equatable, Sendable {
    case invalidProviderID
    case emptyName
    case backendKindRequired
    case backendKindNotAllowed
    case backendPermissionsNotAllowed
    case endpointRequired
    case endpointNotAllowed
    case endpointSchemeNotAllowed(String)
    case endpointContainsCredentials
    case endpointHostRequired
    case invalidCredentialReference
    case credentialPermissionMismatch
    case forbiddenConfigurationField(String)
}

public struct ProviderSourceDescriptor: Codable, Hashable, Sendable {
    public var providerID: String
    public var name: String
    public var integrationMode: ProviderIntegrationMode
    public var backendKind: ProviderBackendKind?
    public var endpointReference: String?
    public var credentialReference: String?
    public var backendPermissions: ProviderBackendPermissions?
    public var capabilities: [ProviderCapability]

    public init(
        providerID: String,
        name: String,
        integrationMode: ProviderIntegrationMode,
        backendKind: ProviderBackendKind? = nil,
        endpointReference: String? = nil,
        credentialReference: String? = nil,
        backendPermissions: ProviderBackendPermissions? = nil,
        capabilities: [ProviderCapability] = []
    ) {
        self.providerID = providerID
        self.name = name
        self.integrationMode = integrationMode
        self.backendKind = backendKind
        self.endpointReference = endpointReference
        self.credentialReference = credentialReference
        self.backendPermissions = backendPermissions
        self.capabilities = capabilities
    }

    public func validated() throws -> Self {
        try validate()
        return self
    }

    public func validate() throws {
        guard providerID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw ProviderSourceDescriptorValidationError.invalidProviderID
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderSourceDescriptorValidationError.emptyName
        }

        switch integrationMode {
        case .provider, .configOnly:
            guard backendKind == nil else {
                throw ProviderSourceDescriptorValidationError.backendKindNotAllowed
            }
            guard endpointReference == nil else {
                throw ProviderSourceDescriptorValidationError.endpointNotAllowed
            }
            guard backendPermissions == nil else {
                throw ProviderSourceDescriptorValidationError.backendPermissionsNotAllowed
            }
        case .userOwnedBackend:
            guard backendKind != nil else {
                throw ProviderSourceDescriptorValidationError.backendKindRequired
            }
            guard let endpointReference, !endpointReference.isEmpty else {
                throw ProviderSourceDescriptorValidationError.endpointRequired
            }
            try Self.validateUserOwnedEndpoint(endpointReference)
            let allowsCredentials = effectiveBackendPermissions.allowsCredentialForwarding
            if let credentialReference {
                guard Self.isKeychainReference(credentialReference) else {
                    throw ProviderSourceDescriptorValidationError.invalidCredentialReference
                }
                guard allowsCredentials else {
                    throw ProviderSourceDescriptorValidationError.credentialPermissionMismatch
                }
            } else if allowsCredentials {
                throw ProviderSourceDescriptorValidationError.credentialPermissionMismatch
            }
        }
    }

    public var effectiveBackendPermissions: ProviderBackendPermissions {
        backendPermissions ?? .secureDefault
    }

    public var endpointScope: ProviderEndpointScope? {
        guard let endpointReference,
              let host = URL(string: endpointReference)?.host?.lowercased() else { return nil }
        if host == "localhost" || host.hasSuffix(".local") {
            return .localNetwork
        }
        if let address = IPv4Address(host) {
            let octets = [UInt8](address.rawValue)
            if octets[0] == 10 || octets[0] == 127 || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 172 && (16...31).contains(octets[1])) {
                return .localNetwork
            }
        }
        if let address = IPv6Address(host) {
            let bytes = [UInt8](address.rawValue)
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isUniqueLocal = bytes[0] & 0xfe == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            if isLoopback || isUniqueLocal || isLinkLocal {
                return .localNetwork
            }
        }
        return .publicInternet
    }

    public static func validateConfiguration(_ value: ProviderJSONValue) throws {
        try validateConfiguration(value, path: "$")
    }

    public static func validateConfiguration(data: Data) throws {
        let value = try JSONDecoder().decode(ProviderJSONValue.self, from: data)
        try validateConfiguration(value)
    }

    private static func validateUserOwnedEndpoint(_ endpoint: String) throws {
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased() else {
            throw ProviderSourceDescriptorValidationError.endpointSchemeNotAllowed("")
        }
        guard scheme == "http" || scheme == "https" else {
            throw ProviderSourceDescriptorValidationError.endpointSchemeNotAllowed(scheme)
        }
        guard url.host != nil else {
            throw ProviderSourceDescriptorValidationError.endpointHostRequired
        }
        guard url.user == nil && url.password == nil else {
            throw ProviderSourceDescriptorValidationError.endpointContainsCredentials
        }
    }

    private static func isKeychainReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value,
              trimmed.hasPrefix("keychain:"),
              trimmed.count > "keychain:".count else { return false }
        return !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validateConfiguration(_ value: ProviderJSONValue, path: String) throws {
        switch value {
        case .null, .bool, .number:
            return
        case .string:
            return
        case .array(let values):
            for (index, value) in values.enumerated() {
                try validateConfiguration(value, path: "\(path)[\(index)]")
            }
        case .object(let values):
            for (key, value) in values {
                let normalizedKey = normalizeConfigurationKey(key)
                let fieldPath = path == "$" ? key : "\(path).\(key)"
                if forbiddenConfigurationKeys.contains(normalizedKey) {
                    throw ProviderSourceDescriptorValidationError.forbiddenConfigurationField(fieldPath)
                }
                if normalizedKey == "api", isExecutableReference(value) {
                    throw ProviderSourceDescriptorValidationError.forbiddenConfigurationField(fieldPath)
                }
                try validateConfiguration(value, path: fieldPath)
            }
        }
    }

    private static let forbiddenConfigurationKeys: Set<String> = [
        "dex",
        "dependencies",
        "dynamicdependency",
        "dynamicimport",
        "ext",
        "jar",
        "loader",
        "pyloader",
        "pythonloader",
        "remoteimport",
        "runtimeexecutable",
        "script",
        "spider"
    ]

    private static func normalizeConfigurationKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func isExecutableReference(_ value: ProviderJSONValue) -> Bool {
        guard case .string(let string) = value else { return false }
        let normalized = string.lowercased()
        let executableMarkers = [
            ".dex", ".dylib", ".jar", ".js", ".mjs", ".py", ".so",
            "csp_pyproxy", "pyloader", "quickjs"
        ]
        return executableMarkers.contains { normalized.contains($0) }
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case name
        case integrationMode = "integration_mode"
        case backendKind = "backend_kind"
        case endpointReference = "endpoint_ref"
        case credentialReference = "credential_ref"
        case backendPermissions = "backend_permissions"
        case capabilities
    }
}
