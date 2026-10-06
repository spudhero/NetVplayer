import CryptoKit
import Darwin
import Foundation

/// Only used to import existing accounts. Migration never changes legacy items.
public protocol LegacyCredentialReader: Sendable {
    func read(_ key: String) throws -> String?
}

/// Persists accounts independently of the executable's ad-hoc signing identity.
/// The vault and its random key are protected by the current user's file permissions,
/// not by Keychain's per-application access control. Neither belongs in app exports.
public final class LocalCredentialStore: CredentialStore, @unchecked Sendable {
    public static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("NetVplayer/Credentials", isDirectory: true)

    private static let vaultName = "accounts.v1.enc"
    private static let keyName = "encryption.key"
    private static let header = Data("NVPCRED1".utf8)
    private static let maximumBytes = 4 * 1024 * 1024
    // Coordinate different store instances before they open the shared lock file.
    // flock then coordinates access with other processes.
    private static let processLock = NSLock()

    private let directory: URL
    private let legacyReader: (any LegacyCredentialReader)?
    private var legacyResults: [String: Result<String?, Error>] = [:]

    public init(
        directory: URL = LocalCredentialStore.defaultDirectory,
        legacyReader: (any LegacyCredentialReader)? = nil
    ) {
        self.directory = directory
        self.legacyReader = legacyReader
    }

    public func read(_ key: String) throws -> String? {
        try withLockedDirectory { descriptor in
            var values = try loadValues(in: descriptor)
            if let value = values[key] { return value.isEmpty ? nil : value }
            guard let legacyReader else { return nil }

            // Cache failures as well as misses: getters must not repeatedly contact
            // securityd after a legacy account requires authorization.
            let result: Result<String?, Error>
            if let cached = legacyResults[key] {
                result = cached
            } else {
                result = Result { try legacyReader.read(key) }
                legacyResults[key] = result
            }
            guard let value = try result.get() else { return nil }
            values[key] = value
            try persist(values, in: descriptor)
            return value.isEmpty ? nil : value
        }
    }

    public func write(_ value: String, for key: String) throws {
        try withLockedDirectory { descriptor in
            var values = try loadValues(in: descriptor)
            values[key] = value
            try persist(values, in: descriptor)
        }
    }

    public func remove(_ key: String) throws {
        // An encrypted empty entry is a durable logout marker. Deleting the entry
        // would allow the old Keychain account to be imported after a restart.
        try write("", for: key)
    }

    private func withLockedDirectory<T>(_ operation: (Int32) throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        // mkdir handles simultaneous first launches atomically. Foundation's
        // recursive creation can report an error if another instance wins the race.
        try? FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard Darwin.mkdir(directory.path, mode_t(0o700)) == 0 || errno == EEXIST else {
            throw CredentialStoreError.localStorageUnavailable
        }

        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CredentialStoreError.localStorageUnavailable }
        defer { Darwin.close(descriptor) }
        try validate(descriptor, kind: mode_t(S_IFDIR), permissions: 0o700)

        let lockDescriptor = Darwin.openat(
            descriptor, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)
        )
        guard lockDescriptor >= 0 else { throw CredentialStoreError.localStorageUnavailable }
        defer { Darwin.close(lockDescriptor) }
        try validate(lockDescriptor, kind: mode_t(S_IFREG), permissions: 0o600)
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw CredentialStoreError.localStorageUnavailable
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        return try operation(descriptor)
    }

    private func validate(_ descriptor: Int32, kind: mode_t, permissions: mode_t) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == kind,
              metadata.st_uid == Darwin.geteuid(),
              kind != mode_t(S_IFREG) || metadata.st_nlink == 1,
              Darwin.fchmod(descriptor, permissions) == 0 else {
            throw CredentialStoreError.localStorageUnavailable
        }
    }

    private func loadValues(in descriptor: Int32) throws -> [String: String] {
        guard let encrypted = try readFile(Self.vaultName, in: descriptor) else { return [:] }
        guard encrypted.starts(with: Self.header),
              let keyData = try readFile(Self.keyName, in: descriptor), keyData.count == 32 else {
            // Never generate a replacement key for an existing vault.
            throw CredentialStoreError.invalidData
        }
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted.dropFirst(Self.header.count))
            let plaintext = try AES.GCM.open(
                box, using: SymmetricKey(data: keyData), authenticating: Self.header
            )
            return try JSONDecoder().decode([String: String].self, from: plaintext)
        } catch {
            throw CredentialStoreError.invalidData
        }
    }

    private func persist(_ values: [String: String], in descriptor: Int32) throws {
        let keyData: Data
        if let existing = try readFile(Self.keyName, in: descriptor) {
            guard existing.count == 32 else { throw CredentialStoreError.invalidData }
            keyData = existing
        } else {
            keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try createFile(Self.keyName, data: keyData, in: descriptor)
        }

        let plaintext = try JSONEncoder().encode(values)
        let box = try AES.GCM.seal(
            plaintext, using: SymmetricKey(data: keyData), authenticating: Self.header
        )
        guard let combined = box.combined,
              combined.count + Self.header.count <= Self.maximumBytes else {
            throw CredentialStoreError.invalidData
        }
        let temporaryName = ".accounts.\(UUID().uuidString).tmp"
        defer { _ = Darwin.unlinkat(descriptor, temporaryName, 0) }
        try createFile(temporaryName, data: Self.header + combined, in: descriptor)
        guard Darwin.renameat(descriptor, temporaryName, descriptor, Self.vaultName) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw CredentialStoreError.localStorageUnavailable
        }
        guard try loadValues(in: descriptor) == values else {
            throw CredentialStoreError.verificationFailed
        }
    }

    private func readFile(_ name: String, in directoryDescriptor: Int32) throws -> Data? {
        let descriptor = Darwin.openat(directoryDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CredentialStoreError.localStorageUnavailable
        }
        defer { Darwin.close(descriptor) }
        try validate(descriptor, kind: mode_t(S_IFREG), permissions: 0o600)
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw CredentialStoreError.localStorageUnavailable
        }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes else {
            throw CredentialStoreError.invalidData
        }
        var data = Data(count: Int(metadata.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CredentialStoreError.invalidData }
                offset += count
            }
        }
        return data
    }

    private func createFile(_ name: String, data: Data, in directoryDescriptor: Int32) throws {
        let descriptor = Darwin.openat(
            directoryDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)
        )
        guard descriptor >= 0 else { throw CredentialStoreError.localStorageUnavailable }
        defer { Darwin.close(descriptor) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw CredentialStoreError.localStorageUnavailable }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw CredentialStoreError.localStorageUnavailable }
        } catch {
            _ = Darwin.unlinkat(directoryDescriptor, name, 0)
            throw error
        }
    }
}
