import Foundation
import ProviderRuntime
import ProviderSDK

public enum ProviderRuntimeBootstrapError: LocalizedError, Equatable, Sendable {
    case distributionNotConfigured
    case invalidIndexURL
    case releaseNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .distributionNotConfigured:
            return "Provider distribution is not configured for this app build"
        case .invalidIndexURL:
            return "Provider distribution index URL is invalid"
        case .releaseNotFound(let value):
            return "Provider release was not found: \(value)"
        }
    }
}

public struct ProviderRuntimeSyncFailure: Equatable, Sendable {
    public let release: ProviderVersionReference
    public let message: String

    public init(release: ProviderVersionReference, message: String) {
        self.release = release
        self.message = message
    }
}

public struct ProviderRuntimeSyncResult: Sendable {
    public let catalog: [ProviderRelease]
    public let installed: [SignedProviderManifest]
    public let installedOrUpdated: [ProviderVersionReference]
    public let failures: [ProviderRuntimeSyncFailure]

    public init(
        catalog: [ProviderRelease],
        installed: [SignedProviderManifest],
        installedOrUpdated: [ProviderVersionReference],
        failures: [ProviderRuntimeSyncFailure]
    ) {
        self.catalog = catalog
        self.installed = installed
        self.installedOrUpdated = installedOrUpdated
        self.failures = failures
    }
}

/// Owns the shell-side startup lifecycle for installed signed Provider packages.
/// Startup restores verified local packages before checking the signed catalog
/// for newer compatible support packages.
public actor ProviderRuntimeBootstrap {
    public let manager: ProviderManager
    private let distribution: ProviderDistributionClient?
    private let distributionVerifier: ProviderDistributionIndexVerifier?
    private let distributionIndexURL: URL?
    private let allowedSourcePolicies: Set<ProviderSourcePolicy>?

    public init(
        manager: ProviderManager,
        distribution: ProviderDistributionClient? = nil,
        distributionVerifier: ProviderDistributionIndexVerifier? = nil,
        distributionIndexURL: URL? = nil,
        allowedSourcePolicies: Set<ProviderSourcePolicy>? = [
            .userConfiguredOnly,
            .userConfiguredCatalog,
        ]
    ) {
        self.manager = manager
        self.distribution = distribution
        self.distributionVerifier = distributionVerifier
        self.distributionIndexURL = distributionIndexURL
        self.allowedSourcePolicies = allowedSourcePolicies
    }

    /// Creates the production bootstrap only when the app bundle contains both
    /// pinned trust keys. Missing trust configuration fails closed.
    public static func makeDefault(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        shellVersion: String? = nil
    ) -> ProviderRuntimeBootstrap? {
        guard let trust = try? ProviderTrustConfiguration.load(bundle: bundle),
              let version = shellVersion
                ?? bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first,
              let verifier = try? trust.manifestVerifier(shellVersion: version) else {
            return nil
        }

        let root = applicationSupport.appendingPathComponent(
            "NetVplayer/Providers",
            isDirectory: true
        )
        let store = ProviderPackageStore(rootURL: root, verifier: verifier)
        let indexURL = (bundle.infoDictionary?["NetVplayerProviderDistributionIndexURL"] as? String)
            .flatMap(URL.init(string:))
        return ProviderRuntimeBootstrap(
            manager: ProviderManager(store: store),
            distribution: ProviderDistributionClient(),
            distributionVerifier: try? trust.distributionVerifier(),
            distributionIndexURL: indexURL
        )
    }

    /// Re-registers exact source identities from active, verified packages.
    /// Provider processes are launched lazily by the first operation.
    public func registerInstalledProviders() async {
        let documents = await installedManifests()
        for document in documents {
            await SpiderReplacementRegistry.shared.registerRemote(
                manifest: document.manifest,
                manager: manager
            )
        }
    }

    public func installedManifests() async -> [SignedProviderManifest] {
        let documents = await manager.activeManifests()
        guard let allowedSourcePolicies else { return documents }
        return documents.filter {
            guard let sourcePolicy = $0.manifest.sourcePolicy else { return false }
            return allowedSourcePolicies.contains(sourcePolicy)
        }
    }

    public func fetchCatalog() async throws -> [VerifiedProviderRelease] {
        guard let distribution, let distributionVerifier else {
            throw ProviderRuntimeBootstrapError.distributionNotConfigured
        }
        guard let distributionIndexURL else {
            throw ProviderRuntimeBootstrapError.invalidIndexURL
        }
        return try await distribution.fetchIndex(from: distributionIndexURL, verifier: distributionVerifier)
    }

    /// Restores offline packages, then installs the newest compatible release
    /// for every Provider declared by the signed distribution index.
    public func synchronizeAvailableProviders(
        progress: @escaping ProviderInstallProgressHandler = { _ in }
    ) async throws -> ProviderRuntimeSyncResult {
        guard let distribution else {
            throw ProviderRuntimeBootstrapError.distributionNotConfigured
        }

        await registerInstalledProviders()
        var activeDocuments = await installedManifests()
        await progress(ProviderInstallProgress(
            providerID: "providers",
            version: "latest",
            phase: .fetchingCatalog
        ))

        let catalog = try await fetchCatalog()
        var latestByProvider: [String: VerifiedProviderRelease] = [:]
        for release in catalog {
            if let current = latestByProvider[release.providerID],
               ProviderManifestVerifier.compareVersions(current.version, release.version) >= 0 {
                continue
            }
            latestByProvider[release.providerID] = release
        }

        var activeVersions = Dictionary(uniqueKeysWithValues: activeDocuments.map {
            ($0.manifest.providerID, $0.manifest.version)
        })
        var installedOrUpdated: [ProviderVersionReference] = []
        var failures: [ProviderRuntimeSyncFailure] = []

        for release in latestByProvider.values.sorted(by: {
            if $0.providerID == $1.providerID {
                return ProviderManifestVerifier.compareVersions($0.version, $1.version) < 0
            }
            return $0.providerID < $1.providerID
        }) {
            if let activeVersion = activeVersions[release.providerID],
               ProviderManifestVerifier.compareVersions(activeVersion, release.version) >= 0 {
                continue
            }

            let reference = ProviderVersionReference(
                providerID: release.providerID,
                version: release.version
            )
            do {
                _ = try await manager.install(
                    release: release,
                    using: distribution,
                    allowedSourcePolicies: allowedSourcePolicies,
                    progress: progress
                )
                activeVersions[release.providerID] = release.version
                installedOrUpdated.append(reference)
            } catch {
                failures.append(ProviderRuntimeSyncFailure(
                    release: reference,
                    message: error.localizedDescription
                ))
            }
        }

        await registerInstalledProviders()
        activeDocuments = await installedManifests()
        return ProviderRuntimeSyncResult(
            catalog: catalog.map(\.release),
            installed: activeDocuments,
            installedOrUpdated: installedOrUpdated,
            failures: failures
        )
    }

    public func install(
        providerID: String,
        version: String? = nil,
        progress: @escaping ProviderInstallProgressHandler = { _ in }
    ) async throws {
        guard let distribution else {
            throw ProviderRuntimeBootstrapError.distributionNotConfigured
        }
        await progress(ProviderInstallProgress(
            providerID: providerID,
            version: version ?? "latest",
            phase: .fetchingCatalog
        ))
        let releases = try await fetchCatalog()
        let matching = releases
            .filter { $0.providerID == providerID }
            .filter { version == nil || $0.version == version }
            .sorted { ProviderManifestVerifier.compareVersions($0.version, $1.version) > 0 }
        guard let release = matching.first else {
            let identity = version.map { "\(providerID)@\($0)" } ?? providerID
            throw ProviderRuntimeBootstrapError.releaseNotFound(identity)
        }
        _ = try await manager.install(
            release: release,
            using: distribution,
            allowedSourcePolicies: allowedSourcePolicies,
            progress: progress
        )
        await registerInstalledProviders()
    }

    public func shutdown() async {
        await manager.shutdownAll()
    }
}
