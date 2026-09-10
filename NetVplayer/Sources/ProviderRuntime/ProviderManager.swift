import Foundation
import Models
import ProviderSDK

public enum ProviderManagerError: LocalizedError, Sendable {
    case providerMismatch
    case handshakeFailed
    case initializationFailed
    case missingProxyPayload
    case restartLimitExceeded
    case sourcePolicyMismatch

    public var errorDescription: String? {
        switch self {
        case .providerMismatch: return "Provider request does not match the installed package"
        case .handshakeFailed: return "Provider handshake failed"
        case .initializationFailed: return "Provider initialization failed"
        case .missingProxyPayload: return "Provider proxy response did not contain a proxy payload"
        case .restartLimitExceeded: return "Provider restart limit was exceeded"
        case .sourcePolicyMismatch: return "Provider source policy is not allowed by this app build"
        }
    }
}

public actor ProviderManager {
    private let store: ProviderPackageStore
    private let httpSession: URLSession?
    private let maximumHTTPResponseBytes: Int
    private var sessions: [String: ProviderProcessClient] = [:]
    private var initializedSites: [String: Data] = [:]
    private var launches: [String: [Date]] = [:]

    public init(
        store: ProviderPackageStore,
        httpSession: URLSession? = nil,
        maximumHTTPResponseBytes: Int = 32 * 1024 * 1024
    ) {
        self.store = store
        self.httpSession = httpSession
        self.maximumHTTPResponseBytes = maximumHTTPResponseBytes
    }

    @discardableResult
    public func install(packageDirectory: URL, document: SignedProviderManifest) async throws -> URL {
        let installed = try await store.install(packageDirectory: packageDirectory, document: document)
        let stateDirectory = try await store.stateDirectory(providerID: document.manifest.providerID)
        let command = try ProviderCommandBuilder.command(
            manifest: document.manifest,
            packageRoot: installed,
            stateDirectoryURL: stateDirectory
        )
        let client = ProviderProcessClient(
            command: command,
            httpSession: httpSession,
            maximumHTTPResponseBytes: maximumHTTPResponseBytes
        )
        do {
            let handshake = ProviderRequest(
                providerID: document.manifest.providerID,
                operation: .handshake,
                arguments: ["protocol": .number(Double(document.manifest.protocolVersion))]
            )
            let response = try await client.request(
                handshake,
                timeout: Self.handshakeTimeout(for: document.manifest.runtime)
            )
            try validateHandshake(
                response,
                providerID: document.manifest.providerID,
                protocolVersion: document.manifest.protocolVersion,
                hostCapabilities: document.manifest.hostCapabilities
            )
            try await store.activate(providerID: document.manifest.providerID, version: document.manifest.version)
            if let old = sessions.updateValue(client, forKey: document.manifest.providerID) {
                await old.stop()
            }
            initializedSites.removeValue(forKey: document.manifest.providerID)
            launches[document.manifest.providerID] = []
            return installed
        } catch {
            await client.stop(graceful: false)
            throw error
        }
    }

    @discardableResult
    public func install(
        release: VerifiedProviderRelease,
        using distribution: ProviderDistributionClient,
        allowedSourcePolicies: Set<ProviderSourcePolicy>? = nil,
        progress: @escaping ProviderInstallProgressHandler = { _ in }
    ) async throws -> URL {
        let downloaded = try await distribution.downloadAndExtract(release, progress: progress)
        do {
            await progress(ProviderInstallProgress(
                providerID: release.providerID,
                version: release.version,
                phase: .verifyingPackage
            ))
            let document = try await store.loadManifest(packageRoot: downloaded.rootURL)
            guard document.manifest.providerID == release.providerID,
                  document.manifest.version == release.version else {
                throw ProviderDistributionError.manifestMismatch
            }
            if let allowedSourcePolicies {
                guard let sourcePolicy = document.manifest.sourcePolicy,
                      allowedSourcePolicies.contains(sourcePolicy) else {
                    throw ProviderManagerError.sourcePolicyMismatch
                }
            }
            await progress(ProviderInstallProgress(
                providerID: release.providerID,
                version: release.version,
                phase: .launching
            ))
            let installed = try await install(packageDirectory: downloaded.rootURL, document: document)
            await distribution.removeTemporaryPackage(downloaded)
            await progress(ProviderInstallProgress(
                providerID: release.providerID,
                version: release.version,
                phase: .completed
            ))
            return installed
        } catch {
            await distribution.removeTemporaryPackage(downloaded)
            throw error
        }
    }

    public func request(_ request: ProviderRequest, timeout: Duration = .seconds(15)) async throws -> ProviderResponse {
        let client = try await session(providerID: request.providerID)
        do {
            return try await client.request(request, timeout: timeout)
        } catch let error as ProviderProcessError {
            switch error {
            case .terminated, .notRunning:
                sessions.removeValue(forKey: request.providerID)
                initializedSites.removeValue(forKey: request.providerID)
                guard request.operation != .action, request.operation != .cancel,
                      request.operation != .shutdown, request.operation != .destroy else {
                    throw error
                }
                let replacement = try await session(providerID: request.providerID)
                if request.operation != .initialize, let site = request.site {
                    try await initialize(providerID: request.providerID, site: site)
                }
                return try await replacement.request(request, timeout: timeout)
            case .timedOut, .invalidResponse, .writeFailed:
                await client.stop(graceful: false)
                sessions.removeValue(forKey: request.providerID)
                initializedSites.removeValue(forKey: request.providerID)
                throw error
            default:
                throw error
            }
        }
    }

    public func initialize(providerID: String, site: Site) async throws {
        let configuration = try JSONEncoder.providerCanonical.encode(site)
        if initializedSites[providerID] == configuration,
           let client = sessions[providerID], await client.isRunning {
            return
        }
        let response = try await request(
            ProviderRequest(
                providerID: providerID,
                operation: .initialize,
                site: site,
                arguments: ["extend": .string(site.ext)]
            ),
            timeout: .seconds(max(site.timeout, 1))
        )
        guard response.ok else { throw response.error ?? ProviderManagerError.initializationFailed }
        initializedSites[providerID] = configuration
    }

    public func health(providerID: String) async throws -> ProviderResponse {
        try await request(ProviderRequest(providerID: providerID, operation: .health), timeout: .seconds(3))
    }

    public func proxy(
        providerID: String,
        site: Site,
        parameters: [String: String],
        maximumBodyBytes: Int = ProviderProxyResponseAdapter.defaultMaximumBodyBytes
    ) async throws -> ProxyResponse {
        try await initialize(providerID: providerID, site: site)
        let response = try await request(
            ProviderRequest(
                providerID: providerID,
                operation: .proxy,
                site: site,
                arguments: ["parameters": .object(parameters)]
            ),
            timeout: .seconds(max(site.timeout, 1))
        )
        guard response.ok else {
            throw response.error ?? ProviderManagerError.missingProxyPayload
        }
        guard let payload = response.proxy else {
            throw ProviderManagerError.missingProxyPayload
        }
        return try ProviderProxyResponseAdapter.response(
            from: payload,
            maximumBodyBytes: maximumBodyBytes
        )
    }

    public func shutdown(providerID: String) async {
        guard let client = sessions.removeValue(forKey: providerID) else { return }
        initializedSites.removeValue(forKey: providerID)
        await client.stop()
    }

    public func shutdownAll() async {
        let active = sessions.values
        sessions.removeAll()
        initializedSites.removeAll()
        for client in active { await client.stop() }
    }

    /// Returns active packages that still pass signature, compatibility, and
    /// asset verification. Invalid entries are skipped so startup can continue.
    public func activeManifests() async -> [SignedProviderManifest] {
        let providerIDs = await store.installedProviderIDs()
        var documents: [SignedProviderManifest] = []
        for providerID in providerIDs {
            guard let (_, document) = try? await store.activePackage(providerID: providerID) else {
                continue
            }
            documents.append(document)
        }
        return documents.sorted {
            $0.manifest.providerID < $1.manifest.providerID
        }
    }

    public func rollback(providerID: String) async throws {
        if let client = sessions.removeValue(forKey: providerID) { await client.stop(graceful: false) }
        initializedSites.removeValue(forKey: providerID)
        _ = try await store.rollback(providerID: providerID)
        _ = try await session(providerID: providerID)
    }

    private func session(providerID: String) async throws -> ProviderProcessClient {
        if let existing = sessions[providerID], await existing.isRunning { return existing }
        try permitLaunch(providerID: providerID)
        let (root, document) = try await store.activePackage(providerID: providerID)
        guard document.manifest.providerID == providerID else { throw ProviderManagerError.providerMismatch }
        let stateDirectory = try await store.stateDirectory(providerID: providerID)
        let command = try ProviderCommandBuilder.command(
            manifest: document.manifest,
            packageRoot: root,
            stateDirectoryURL: stateDirectory
        )
        let client = ProviderProcessClient(
            command: command,
            httpSession: httpSession,
            maximumHTTPResponseBytes: maximumHTTPResponseBytes
        )
        let response = try await client.request(
            ProviderRequest(providerID: providerID, operation: .handshake),
            timeout: Self.handshakeTimeout(for: document.manifest.runtime)
        )
        try validateHandshake(
            response,
            providerID: providerID,
            protocolVersion: document.manifest.protocolVersion,
            hostCapabilities: document.manifest.hostCapabilities
        )
        sessions[providerID] = client
        return client
    }

    static func handshakeTimeout(for runtime: ProviderRuntimeKind) -> Duration {
        runtime == .java ? .seconds(15) : .seconds(5)
    }

    private func validateHandshake(
        _ response: ProviderResponse,
        providerID: String,
        protocolVersion: Int,
        hostCapabilities: [ProviderHostCapability]
    ) throws {
        guard response.ok,
              case .object(let result) = response.result,
              result["provider_id"] == .string(providerID),
              result["protocol"] == .number(Double(protocolVersion)) else {
            throw ProviderManagerError.handshakeFailed
        }
        guard hostCapabilities.allSatisfy({ capability in
            guard case .array(let values) = result["capabilities"] else { return false }
            return values.contains(.string(capability.rawValue))
        }) else {
            throw ProviderManagerError.handshakeFailed
        }
    }

    private func permitLaunch(providerID: String) throws {
        let cutoff = Date().addingTimeInterval(-60)
        var recent = launches[providerID, default: []].filter { $0 >= cutoff }
        guard recent.count < 3 else { throw ProviderManagerError.restartLimitExceeded }
        recent.append(Date())
        launches[providerID] = recent
    }
}
