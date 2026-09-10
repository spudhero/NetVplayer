import CryptoKit
import Foundation
import ProviderSDK

public enum ProviderVerificationError: LocalizedError, Equatable, Sendable {
    case invalidPublicKey
    case invalidSignature
    case invalidIdentifier
    case invalidVersion(String)
    case incompatibleProtocol(Int)
    case incompatibleShell(String)
    case incompatibleMacOS(String)
    case incompatibleArchitecture(String)
    case revoked
    case blockedLicense
    case androidDexNeedsPort
    case invalidSourceBinding(String)
    case unsafePath(String)
    case missingAsset(String)
    case hashMismatch(String)
    case executableRequired(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey: return "Provider public key is invalid"
        case .invalidSignature: return "Provider manifest signature is invalid"
        case .invalidIdentifier: return "Provider identifier is invalid"
        case .invalidVersion(let value): return "Provider version is invalid: \(value)"
        case .incompatibleProtocol(let value): return "Provider protocol \(value) is not supported"
        case .incompatibleShell(let value): return "Provider is not compatible with shell \(value)"
        case .incompatibleMacOS(let value): return "Provider requires macOS \(value) or newer"
        case .incompatibleArchitecture(let value): return "Provider does not support \(value)"
        case .revoked: return "Provider version has been revoked"
        case .blockedLicense: return "Provider has not passed its license gate"
        case .androidDexNeedsPort: return "Android Dex providers must be ported to a supported helper runtime"
        case .invalidSourceBinding(let value): return "Provider source binding is invalid: \(value)"
        case .unsafePath(let value): return "Provider contains an unsafe path: \(value)"
        case .missingAsset(let value): return "Provider asset is missing: \(value)"
        case .hashMismatch(let value): return "Provider asset hash does not match: \(value)"
        case .executableRequired(let value): return "Provider asset is not executable: \(value)"
        }
    }
}

public struct ProviderManifestVerifier: Sendable {
    public static let providerLicensePath = "LICENSES/PROVIDER.txt"
    public let publicKey: Curve25519.Signing.PublicKey
    public let supportedProtocol: Int
    public let shellVersion: String
    public let architecture: String
    public let operatingSystemVersion: OperatingSystemVersion

    public init(
        publicKeyData: Data,
        supportedProtocol: Int = 1,
        shellVersion: String,
        architecture: String = ProviderManifestVerifier.currentArchitecture,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw ProviderVerificationError.invalidPublicKey
        }
        self.publicKey = key
        self.supportedProtocol = supportedProtocol
        self.shellVersion = shellVersion
        self.architecture = architecture
        self.operatingSystemVersion = operatingSystemVersion
    }

    public func verify(_ document: SignedProviderManifest, packageRoot: URL) throws {
        let manifestData = try JSONEncoder.providerCanonical.encode(document.manifest)
        guard let signature = Data(base64Encoded: document.signature),
              publicKey.isValidSignature(signature, for: manifestData) else {
            throw ProviderVerificationError.invalidSignature
        }
        try verifyCompatibility(document.manifest)
        try verifyAssets(document.manifest.assets, packageRoot: packageRoot)
        try requireDeclaredPaths(document.manifest)
    }

    public func verifyCompatibility(_ manifest: ProviderManifest) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !manifest.providerID.isEmpty,
              manifest.providerID.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw ProviderVerificationError.invalidIdentifier
        }
        guard Self.versionParts(manifest.version) != nil else {
            throw ProviderVerificationError.invalidVersion(manifest.version)
        }
        guard manifest.protocolVersion == supportedProtocol else {
            throw ProviderVerificationError.incompatibleProtocol(manifest.protocolVersion)
        }
        guard Self.compareVersions(shellVersion, manifest.shellMinimumVersion) >= 0,
              manifest.shellMaximumVersion.map({ Self.compareVersions(shellVersion, $0) <= 0 }) ?? true else {
            throw ProviderVerificationError.incompatibleShell(shellVersion)
        }
        guard Self.compareVersions(Self.versionString(operatingSystemVersion), manifest.macOSMinimumVersion) >= 0 else {
            throw ProviderVerificationError.incompatibleMacOS(manifest.macOSMinimumVersion)
        }
        guard manifest.architectures.contains(architecture) || manifest.architectures.contains("universal2") else {
            throw ProviderVerificationError.incompatibleArchitecture(architecture)
        }
        guard !manifest.revoked else { throw ProviderVerificationError.revoked }
        guard manifest.status != .blockedLicense, !manifest.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderVerificationError.blockedLicense
        }
        try validateSourceBindings(manifest.sourceBindings ?? [])
        if manifest.runtime == .androidDex, manifest.status == .compatible {
            throw ProviderVerificationError.androidDexNeedsPort
        }
    }

    private func validateSourceBindings(_ bindings: [ProviderSourceBinding]) throws {
        for binding in bindings {
            let values = binding.originalKeys + binding.originalAPIs
            guard !values.isEmpty else {
                throw ProviderVerificationError.invalidSourceBinding("a binding must contain a key or API")
            }
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.contains("*"),
                      !trimmed.contains("?"),
                      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ProviderVerificationError.invalidSourceBinding(value)
                }
            }
        }
    }

    public func verifyAssets(_ assets: [ProviderAsset], packageRoot: URL) throws {
        for asset in assets {
            let url = try Self.resolve(relativePath: asset.path, inside: packageRoot)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ProviderVerificationError.missingAsset(asset.path)
            }
            guard try Self.sha256(of: url) == asset.sha256.lowercased() else {
                throw ProviderVerificationError.hashMismatch(asset.path)
            }
            if asset.executable, !FileManager.default.isExecutableFile(atPath: url.path) {
                throw ProviderVerificationError.executableRequired(asset.path)
            }
        }
    }

    private func requireDeclaredPaths(_ manifest: ProviderManifest) throws {
        let declared = Set(manifest.assets.map(\.path))
        let required = [manifest.entrypoint, manifest.runner, Self.providerLicensePath]
            + [manifest.runtimeExecutable, manifest.sandbox?.launcher].compactMap({ $0 })
        for path in required {
            guard declared.contains(path) else { throw ProviderVerificationError.missingAsset(path) }
        }
    }

    public static func resolve(relativePath: String, inside root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw ProviderVerificationError.unsafePath(relativePath)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(prefix) else { throw ProviderVerificationError.unsafePath(relativePath) }
        return candidate
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    public static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        guard let left = versionParts(lhs), let right = versionParts(rhs) else { return lhs.compare(rhs).rawValue }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    static func versionParts(_ value: String) -> [Int]? {
        let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let values = core.split(separator: ".").map(String.init)
        guard !values.isEmpty, values.allSatisfy({ Int($0) != nil }) else { return nil }
        return values.compactMap(Int.init)
    }

    static func versionString(_ value: OperatingSystemVersion) -> String {
        "\(value.majorVersion).\(value.minorVersion).\(value.patchVersion)"
    }
}
