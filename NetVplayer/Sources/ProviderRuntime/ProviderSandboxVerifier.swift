import Foundation
import ProviderSDK
import Security

public enum ProviderSandboxVerificationError: LocalizedError, Equatable, Sendable {
    case unsupportedProfile(Int)
    case invalidBundleIdentifier(String)
    case invalidLauncherLayout(String)
    case invalidInstallLocation(String)
    case invalidStateLocation(String)
    case invalidCodeSignature(String)
    case invalidEntitlements(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProfile(let version):
            return "Provider sandbox profile is not supported: \(version)"
        case .invalidBundleIdentifier(let identifier):
            return "Provider sandbox bundle identifier is invalid: \(identifier)"
        case .invalidLauncherLayout(let path):
            return "Provider sandbox launcher is not inside an app bundle: \(path)"
        case .invalidInstallLocation(let path):
            return "Provider package is outside its sandbox entitlement root: \(path)"
        case .invalidStateLocation(let path):
            return "Provider state is outside its sandbox entitlement root: \(path)"
        case .invalidCodeSignature(let detail):
            return "Provider sandbox launcher signature is invalid: \(detail)"
        case .invalidEntitlements(let detail):
            return "Provider sandbox launcher entitlements are invalid: \(detail)"
        }
    }
}

public enum ProviderSandboxVerifier {
    public static let profileVersion = 2
    private static let supportRelativeRoot = "Library/Application Support/NetVplayer/Providers"
    private static let adHocSignatureFlag: UInt32 = 0x2

    public static func expectedBundleIdentifier(providerID: String) -> String {
        "com.netvplayer.provider.\(providerID)"
    }

    public static func expectedPackageReadPath(providerID: String) -> String {
        "/\(supportRelativeRoot)/\(providerID)/"
    }

    public static func expectedStateWritePath(providerID: String) -> String {
        "/\(supportRelativeRoot)/.state/\(providerID)/"
    }

    public static func verify(
        _ configuration: ProviderSandboxConfiguration,
        providerID: String,
        packageRoot: URL,
        stateDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard configuration.profileVersion == profileVersion else {
            throw ProviderSandboxVerificationError.unsupportedProfile(configuration.profileVersion)
        }
        let expectedIdentifier = expectedBundleIdentifier(providerID: providerID)
        guard configuration.bundleIdentifier == expectedIdentifier else {
            throw ProviderSandboxVerificationError.invalidBundleIdentifier(configuration.bundleIdentifier)
        }

        let launcher = try ProviderManifestVerifier.resolve(
            relativePath: configuration.launcher,
            inside: packageRoot
        )
        let macOSDirectory = launcher.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let bundle = contentsDirectory.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS",
              contentsDirectory.lastPathComponent == "Contents",
              bundle.pathExtension == "app" else {
            throw ProviderSandboxVerificationError.invalidLauncherLayout(configuration.launcher)
        }

        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ProviderSandboxVerificationError.invalidInstallLocation(packageRoot.path)
        }
        let providerRoot = applicationSupport
            .appendingPathComponent("NetVplayer/Providers", isDirectory: true)
            .appendingPathComponent(providerID, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let canonicalPackage = packageRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalPackage.deletingLastPathComponent() == providerRoot else {
            throw ProviderSandboxVerificationError.invalidInstallLocation(packageRoot.path)
        }
        let expectedState = applicationSupport
            .appendingPathComponent("NetVplayer/Providers/.state", isDirectory: true)
            .appendingPathComponent(providerID, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard stateDirectory.standardizedFileURL.resolvingSymlinksInPath() == expectedState else {
            throw ProviderSandboxVerificationError.invalidStateLocation(stateDirectory.path)
        }

        try verifySignatureAndEntitlements(
            bundle: bundle,
            configuration: configuration,
            providerID: providerID
        )
        return launcher
    }

    static func verifySignatureAndEntitlements(
        bundle: URL,
        configuration: ProviderSandboxConfiguration,
        providerID: String
    ) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw ProviderSandboxVerificationError.invalidCodeSignature("SecStaticCodeCreateWithPath=\(createStatus)")
        }
        let validityFlags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures))
        let validityStatus = SecStaticCodeCheckValidity(staticCode, validityFlags, nil)
        guard validityStatus == errSecSuccess else {
            throw ProviderSandboxVerificationError.invalidCodeSignature("SecStaticCodeCheckValidity=\(validityStatus)")
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let information = signingInformation as? [String: Any] else {
            throw ProviderSandboxVerificationError.invalidCodeSignature("SecCodeCopySigningInformation=\(informationStatus)")
        }
        guard information[kSecCodeInfoIdentifier as String] as? String == configuration.bundleIdentifier else {
            throw ProviderSandboxVerificationError.invalidCodeSignature("bundle identifier mismatch")
        }
        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = flags & adHocSignatureFlag != 0
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
        let leafCommonName: String? = {
            guard let leaf = (information[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else {
                return nil
            }
            var value: CFString?
            guard SecCertificateCopyCommonName(leaf, &value) == errSecSuccess else { return nil }
            return value as String?
        }()
        switch configuration.releaseProfile {
        case .communityAdhoc:
            guard isAdHoc, teamIdentifier == nil else {
                throw ProviderSandboxVerificationError.invalidCodeSignature(
                    "community-adhoc requires an ad-hoc signature without a TeamIdentifier"
                )
            }
        case .developerID:
            guard !isAdHoc,
                  let teamIdentifier,
                  !teamIdentifier.isEmpty,
                  leafCommonName?.hasPrefix("Developer ID Application:") == true else {
                throw ProviderSandboxVerificationError.invalidCodeSignature(
                    "developer-id requires a Developer ID Application signature with a TeamIdentifier"
                )
            }
        }
        guard let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            throw ProviderSandboxVerificationError.invalidEntitlements("entitlements are missing")
        }
        guard entitlements["com.apple.security.app-sandbox"] as? Bool == true else {
            throw ProviderSandboxVerificationError.invalidEntitlements("App Sandbox is not enabled")
        }
        guard entitlements["com.apple.security.network.client"] as? Bool == true else {
            throw ProviderSandboxVerificationError.invalidEntitlements("outbound network access is not declared")
        }
        let readOnlyKey = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
        let readWriteKey = "com.apple.security.temporary-exception.files.home-relative-path.read-write"
        guard entitlements[readOnlyKey] as? [String] == [expectedPackageReadPath(providerID: providerID)] else {
            throw ProviderSandboxVerificationError.invalidEntitlements("package read entitlement mismatch")
        }
        guard entitlements[readWriteKey] as? [String] == [expectedStateWritePath(providerID: providerID)] else {
            throw ProviderSandboxVerificationError.invalidEntitlements("state write entitlement mismatch")
        }

        let allowed = Set([
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
            readOnlyKey,
            readWriteKey,
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
        ])
        let unexpected = Set(entitlements.keys).subtracting(allowed).sorted()
        if !unexpected.isEmpty {
            throw ProviderSandboxVerificationError.invalidEntitlements(
                "unexpected entitlements: \(unexpected.joined(separator: ", "))"
            )
        }
    }
}
