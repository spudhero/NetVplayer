import Foundation
import ProviderSDK

public enum ProviderPackageStoreError: LocalizedError, Equatable, Sendable {
    case manifestMissing
    case noActiveVersion(String)
    case noPreviousVersion(String)
    case versionCollision(String)
    case invalidProviderIdentifier(String)
    case unsafeStateDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing: return "signed-manifest.json is missing"
        case .noActiveVersion(let id): return "No active Provider version for \(id)"
        case .noPreviousVersion(let id): return "No previous Provider version for \(id)"
        case .versionCollision(let id): return "Provider version already exists with a different manifest: \(id)"
        case .invalidProviderIdentifier(let id): return "Invalid Provider identifier: \(id)"
        case .unsafeStateDirectory(let path): return "Provider state directory is unsafe: \(path)"
        }
    }
}

public actor ProviderPackageStore {
    public let rootURL: URL
    private let verifier: ProviderManifestVerifier
    private let fileManager: FileManager

    public init(rootURL: URL, verifier: ProviderManifestVerifier, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.verifier = verifier
        self.fileManager = fileManager
    }

    @discardableResult
    public func install(packageDirectory: URL, document: SignedProviderManifest) throws -> URL {
        try verifier.verify(document, packageRoot: packageDirectory)
        let providerRoot = rootURL.appendingPathComponent(document.manifest.providerID, isDirectory: true)
        let destination = providerRoot.appendingPathComponent(document.manifest.version, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            let installed = try loadManifest(packageRoot: destination)
            guard try JSONEncoder.providerCanonical.encode(installed) == JSONEncoder.providerCanonical.encode(document) else {
                throw ProviderPackageStoreError.versionCollision(document.manifest.providerID)
            }
            try verifier.verify(installed, packageRoot: destination)
            return destination
        }

        try fileManager.createDirectory(at: providerRoot, withIntermediateDirectories: true)
        let staging = providerRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for asset in document.manifest.assets {
                let source = try ProviderManifestVerifier.resolve(relativePath: asset.path, inside: packageDirectory)
                let target = try ProviderManifestVerifier.resolve(relativePath: asset.path, inside: staging)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: target)
                if asset.executable {
                    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                }
            }
            let manifestData = try JSONEncoder.providerCanonical.encode(document)
            try manifestData.write(to: staging.appendingPathComponent("signed-manifest.json"), options: .atomic)
            try verifier.verify(document, packageRoot: staging)
            try fileManager.moveItem(at: staging, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func activate(providerID: String, version: String) throws {
        let providerRoot = rootURL.appendingPathComponent(providerID, isDirectory: true)
        let versionRoot = providerRoot.appendingPathComponent(version, isDirectory: true)
        guard fileManager.fileExists(atPath: versionRoot.path) else {
            throw ProviderPackageStoreError.noActiveVersion(providerID)
        }
        let activeURL = providerRoot.appendingPathComponent("active-version")
        let previousURL = providerRoot.appendingPathComponent("previous-version")
        if let current = try? String(contentsOf: activeURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty, current != version {
            try Data(current.utf8).write(to: previousURL, options: .atomic)
        }
        try Data(version.utf8).write(to: activeURL, options: .atomic)
    }

    public func rollback(providerID: String) throws -> URL {
        let providerRoot = rootURL.appendingPathComponent(providerID, isDirectory: true)
        let previousURL = providerRoot.appendingPathComponent("previous-version")
        guard let version = try? String(contentsOf: previousURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            throw ProviderPackageStoreError.noPreviousVersion(providerID)
        }
        try activate(providerID: providerID, version: version)
        return providerRoot.appendingPathComponent(version, isDirectory: true)
    }

    public func activePackage(providerID: String) throws -> (URL, SignedProviderManifest) {
        let providerRoot = rootURL.appendingPathComponent(providerID, isDirectory: true)
        let marker = providerRoot.appendingPathComponent("active-version")
        guard let version = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            throw ProviderPackageStoreError.noActiveVersion(providerID)
        }
        let package = providerRoot.appendingPathComponent(version, isDirectory: true)
        let document = try loadManifest(packageRoot: package)
        try verifier.verify(document, packageRoot: package)
        return (package, document)
    }

    public func loadManifest(packageRoot: URL) throws -> SignedProviderManifest {
        let url = packageRoot.appendingPathComponent("signed-manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { throw ProviderPackageStoreError.manifestMissing }
        return try JSONDecoder().decode(SignedProviderManifest.self, from: Data(contentsOf: url))
    }

    public func stateDirectory(providerID: String) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !providerID.isEmpty, providerID.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw ProviderPackageStoreError.invalidProviderIdentifier(providerID)
        }
        let stateRoot = rootURL.appendingPathComponent(".state", isDirectory: true)
        let providerState = stateRoot.appendingPathComponent(providerID, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try preparePrivateStateDirectory(stateRoot)
        try preparePrivateStateDirectory(providerState)
        return providerState
    }

    private func preparePrivateStateDirectory(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ProviderPackageStoreError.unsafeStateDirectory(directory.path)
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Returns provider IDs with an installed version directory. Corrupt or inactive
    /// versions are filtered by `activePackage(providerID:)` at the manager boundary.
    public func installedProviderIDs() -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return url.lastPathComponent
        }.sorted()
    }
}
