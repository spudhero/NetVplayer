import CryptoKit
import Foundation
import ProviderSDK

public enum ProviderDistributionError: LocalizedError, Equatable, Sendable {
    case invalidIndexSignature
    case incompatibleProtocol(Int)
    case insecureURL
    case invalidArchiveHash
    case revoked
    case httpStatus(Int)
    case responseTooLarge
    case extractionFailed(Int32)
    case manifestMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidIndexSignature: return "Provider distribution index signature is invalid"
        case .incompatibleProtocol(let value): return "Provider distribution protocol \(value) is not supported"
        case .insecureURL: return "Provider archives must use HTTPS"
        case .invalidArchiveHash: return "Provider archive hash is invalid"
        case .revoked: return "Provider release has been revoked"
        case .httpStatus(let value): return "Provider archive download returned HTTP \(value)"
        case .responseTooLarge: return "Provider archive exceeds the configured size limit"
        case .extractionFailed(let value): return "Provider archive extraction failed with status \(value)"
        case .manifestMismatch: return "Provider archive manifest does not match the signed release index"
        }
    }
}

public struct VerifiedProviderRelease: Sendable {
    public let providerID: String
    public let version: String
    public let architectures: [String]
    public let archiveURL: URL
    public let archiveSHA256: String

    fileprivate init(_ release: ProviderRelease) {
        providerID = release.providerID
        version = release.version
        architectures = release.architectures
        archiveURL = release.archiveURL
        archiveSHA256 = release.archiveSHA256
    }

    public var release: ProviderRelease {
        ProviderRelease(
            providerID: providerID,
            version: version,
            architectures: architectures,
            archiveURL: archiveURL,
            archiveSHA256: archiveSHA256
        )
    }
}

public struct DownloadedProviderPackage: Sendable {
    public let rootURL: URL
    let temporaryRootURL: URL
}

public enum ProviderInstallPhase: String, Sendable {
    case fetchingCatalog
    case downloading
    case verifyingArchive
    case extracting
    case verifyingPackage
    case launching
    case completed
}

public struct ProviderInstallProgress: Equatable, Sendable {
    public let providerID: String
    public let version: String
    public let phase: ProviderInstallPhase
    public let receivedBytes: Int64
    public let expectedBytes: Int64?

    public init(
        providerID: String,
        version: String,
        phase: ProviderInstallPhase,
        receivedBytes: Int64 = 0,
        expectedBytes: Int64? = nil
    ) {
        self.providerID = providerID
        self.version = version
        self.phase = phase
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }

    public var fractionCompleted: Double? {
        guard phase == .downloading, let expectedBytes, expectedBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
    }
}

public typealias ProviderInstallProgressHandler = @Sendable (ProviderInstallProgress) async -> Void

private final class ProviderDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let providerID: String
    private let version: String
    private let maximumBytes: Int64
    private let progress: ProviderInstallProgressHandler
    private let lock = NSLock()
    private var limitExceeded = false
    private var progressTail: Task<Void, Never>?

    init(
        providerID: String,
        version: String,
        maximumBytes: Int64,
        progress: @escaping ProviderInstallProgressHandler
    ) {
        self.providerID = providerID
        self.version = version
        self.maximumBytes = maximumBytes
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        guard totalBytesWritten <= maximumBytes,
              expected.map({ $0 <= maximumBytes }) ?? true else {
            lock.lock()
            limitExceeded = true
            lock.unlock()
            downloadTask.cancel()
            return
        }
        enqueue(ProviderInstallProgress(
            providerID: providerID,
            version: version,
            phase: .downloading,
            receivedBytes: totalBytesWritten,
            expectedBytes: expected
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func exceededLimit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return limitExceeded
    }

    func drain() async {
        let tail = lock.withLock { progressTail }
        await tail?.value
    }

    private func enqueue(_ value: ProviderInstallProgress) {
        lock.lock()
        let previous = progressTail
        progressTail = Task { [progress] in
            await previous?.value
            await progress(value)
        }
        lock.unlock()
    }
}

public struct ProviderDistributionIndexVerifier: Sendable {
    private let publicKey: Curve25519.Signing.PublicKey
    public let supportedProtocol: Int
    public let architecture: String

    public init(
        publicKeyData: Data,
        supportedProtocol: Int = 2,
        architecture: String = ProviderManifestVerifier.currentArchitecture
    ) throws {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw ProviderVerificationError.invalidPublicKey
        }
        publicKey = key
        self.supportedProtocol = supportedProtocol
        self.architecture = architecture
    }

    public func verify(_ document: SignedProviderDistributionIndex) throws -> [VerifiedProviderRelease] {
        let data = try JSONEncoder.providerCanonical.encode(document.index)
        guard let signature = Data(base64Encoded: document.signature),
              publicKey.isValidSignature(signature, for: data) else {
            throw ProviderDistributionError.invalidIndexSignature
        }
        guard document.index.protocolVersion == supportedProtocol else {
            throw ProviderDistributionError.incompatibleProtocol(document.index.protocolVersion)
        }
        let revoked = Set(document.index.revoked)
        var architectureClaims: [ProviderVersionReference: Set<String>] = [:]
        var selected: [VerifiedProviderRelease] = []
        for release in document.index.releases {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard !release.providerID.isEmpty,
                  release.providerID.rangeOfCharacter(from: allowed.inverted) == nil else {
                throw ProviderVerificationError.invalidIdentifier
            }
            guard ProviderManifestVerifier.versionParts(release.version) != nil else {
                throw ProviderVerificationError.invalidVersion(release.version)
            }
            let identity = ProviderVersionReference(providerID: release.providerID, version: release.version)
            let declared = Set(release.architectures)
            let allowedArchitectures = Set(["arm64", "x86_64", "universal2"])
            guard !declared.isEmpty,
                  declared.count == release.architectures.count,
                  declared.isSubset(of: allowedArchitectures),
                  !(declared.contains("universal2") && declared.count != 1) else {
                throw ProviderDistributionError.manifestMismatch
            }
            let effective = declared.contains("universal2") ? Set(["arm64", "x86_64"]) : declared
            let previous = architectureClaims[identity, default: []]
            guard previous.isDisjoint(with: effective) else {
                throw ProviderDistributionError.manifestMismatch
            }
            architectureClaims[identity] = previous.union(effective)
            guard release.archiveURL.scheme?.lowercased() == "https" else {
                throw ProviderDistributionError.insecureURL
            }
            guard release.archiveSHA256.count == 64,
                  release.archiveSHA256.allSatisfy({ $0.isHexDigit }) else {
                throw ProviderDistributionError.invalidArchiveHash
            }
            guard !revoked.contains(identity) else {
                throw ProviderDistributionError.revoked
            }
            if effective.contains(architecture) {
                selected.append(VerifiedProviderRelease(release))
            }
        }
        return selected
    }
}

public actor ProviderDistributionClient {
    private static let maximumIndexBytes: Int64 = 8 * 1024 * 1024
    private let session: URLSession
    private let fileManager: FileManager
    private let maximumArchiveBytes: Int64

    public init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        maximumArchiveBytes: Int64 = 512 * 1024 * 1024
    ) {
        self.session = session
        self.fileManager = fileManager
        self.maximumArchiveBytes = maximumArchiveBytes
    }

    /// Fetches and verifies the signed release index. The caller supplies the
    /// pinned distribution key; an index URL is never accepted from a Provider
    /// package or request payload.
    public func fetchIndex(
        from url: URL,
        verifier: ProviderDistributionIndexVerifier
    ) async throws -> [VerifiedProviderRelease] {
        guard url.scheme?.lowercased() == "https" else {
            throw ProviderDistributionError.insecureURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderDistributionError.httpStatus(0)
        }
        guard (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https" else {
            throw ProviderDistributionError.httpStatus(http.statusCode)
        }
        guard Int64(data.count) <= Self.maximumIndexBytes else {
            throw ProviderDistributionError.responseTooLarge
        }
        let document = try JSONDecoder().decode(SignedProviderDistributionIndex.self, from: data)
        return try verifier.verify(document)
    }

    public func downloadAndExtract(
        _ release: VerifiedProviderRelease,
        progress: @escaping ProviderInstallProgressHandler = { _ in }
    ) async throws -> DownloadedProviderPackage {
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("netvplayer-provider-\(UUID().uuidString)", isDirectory: true)
        let archive = temporaryRoot.appendingPathComponent("package.zip")
        let package = temporaryRoot.appendingPathComponent("package", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        do {
            await progress(ProviderInstallProgress(
                providerID: release.providerID,
                version: release.version,
                phase: .downloading
            ))
            let delegate = ProviderDownloadProgressDelegate(
                providerID: release.providerID,
                version: release.version,
                maximumBytes: maximumArchiveBytes,
                progress: progress
            )
            let downloaded: URL
            let response: URLResponse
            do {
                (downloaded, response) = try await session.download(
                    from: release.archiveURL,
                    delegate: delegate
                )
            } catch {
                await delegate.drain()
                if delegate.exceededLimit() {
                    throw ProviderDistributionError.responseTooLarge
                }
                throw error
            }
            defer { try? fileManager.removeItem(at: downloaded) }
            await delegate.drain()
            guard let http = response as? HTTPURLResponse else { throw ProviderDistributionError.httpStatus(0) }
            guard (200..<300).contains(http.statusCode) else { throw ProviderDistributionError.httpStatus(http.statusCode) }
            guard http.url?.scheme?.lowercased() == "https" else { throw ProviderDistributionError.insecureURL }
            if response.expectedContentLength > maximumArchiveBytes { throw ProviderDistributionError.responseTooLarge }

            let expectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            let attributes = try fileManager.attributesOfItem(atPath: downloaded.path)
            let receivedBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard receivedBytes <= maximumArchiveBytes else {
                throw ProviderDistributionError.responseTooLarge
            }
            try fileManager.copyItem(at: downloaded, to: archive)
            await progress(ProviderInstallProgress(
                providerID: release.providerID,
                version: release.version,
                phase: .downloading,
                receivedBytes: receivedBytes,
                expectedBytes: expectedBytes
            ))
            await progress(ProviderInstallProgress(
                providerID: release.providerID,
                version: release.version,
                phase: .verifyingArchive,
                receivedBytes: receivedBytes,
                expectedBytes: expectedBytes
            ))
            guard try ProviderManifestVerifier.sha256(of: archive) == release.archiveSHA256 else {
                throw ProviderDistributionError.invalidArchiveHash
            }

            await progress(ProviderInstallProgress(
                providerID: release.providerID,
                version: release.version,
                phase: .extracting,
                receivedBytes: receivedBytes,
                expectedBytes: expectedBytes
            ))
            try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, package.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ProviderDistributionError.extractionFailed(process.terminationStatus)
            }
            return DownloadedProviderPackage(rootURL: package, temporaryRootURL: temporaryRoot)
        } catch {
            try? fileManager.removeItem(at: temporaryRoot)
            throw error
        }
    }

    public func removeTemporaryPackage(_ package: DownloadedProviderPackage) {
        try? fileManager.removeItem(at: package.temporaryRootURL)
    }
}
