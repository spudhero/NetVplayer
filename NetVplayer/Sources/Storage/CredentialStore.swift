import Models
import Foundation
import Security

/// Implementations never include account contents in errors or diagnostics.
public protocol CredentialStore: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ value: String, for key: String) throws
    func remove(_ key: String) throws
}

public enum CredentialStoreError: Error, LocalizedError, Equatable {
    case unavailable(Int32)
    case timedOut
    case invalidData
    case verificationFailed
    case localStorageUnavailable
    case legacyAuthorizationRequired

    public var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.text("无法访问钥匙串。账号暂未安全保存，请解锁钥匙串后重试。")
        case .timedOut: return L10n.text("钥匙串响应超时。请解锁钥匙串后重试。")
        case .invalidData: return L10n.text("账号数据无法读取，原有数据已保留。")
        case .verificationFailed: return L10n.text("账号保存校验失败，原有数据已保留。")
        case .localStorageUnavailable: return L10n.text("无法保存账号。请检查应用数据目录的权限或磁盘空间后重试。")
        case .legacyAuthorizationRequired: return L10n.text("无法自动恢复旧版本的登录。请重新登录对应账号。")
        }
    }
}

public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private static let currentService = "com.netvplayer.app.credentials.v2"
    private static let legacyService = "com.netvplayer.app.credentials.v1"

    private let service: String
    private let legacyServices: [String]
    private let readTimeout: TimeInterval
    private let lock = NSRecursiveLock()

    public init(
        service: String = "com.netvplayer.app.credentials.v2",
        legacyServices: [String]? = nil,
        readTimeout: TimeInterval = 2
    ) {
        self.service = service
        self.legacyServices = legacyServices
            ?? (service == Self.currentService ? [Self.legacyService] : [])
        self.readTimeout = readTimeout
    }

    private func query(_ key: String, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service ?? self.service,
         kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: false]
    }

    public func read(_ key: String) throws -> String? {
        switch try lookup(key, service: service) {
        case .found(let value):
            return value.isEmpty ? nil : value
        case .notFound:
            break
        }

        for legacyService in legacyServices {
            switch try lookup(key, service: legacyService) {
            case .notFound:
                continue
            case .found(let value):
                lock.lock()
                defer { lock.unlock() }
                try writePrimary(value, for: key)
                return value.isEmpty ? nil : value
            }
        }

        return nil
    }

    public func write(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        try writePrimary(value, for: key)
        guard try read(key) == value else { throw CredentialStoreError.verificationFailed }
    }

    private func writePrimary(_ value: String, for key: String) throws {
        let attributes = query(key)
        let data = Data(value.utf8)
        var status = SecItemUpdate(attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = attributes
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.unavailable(status) }
    }

    public func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !legacyServices.isEmpty else {
            let status = SecItemDelete(query(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.unavailable(status)
            }
            return
        }

        // Keep an empty primary item so a deleted legacy value cannot be restored.
        try writePrimary("", for: key)
    }

    private func lookup(_ key: String, service: String) throws -> KeychainLookup {
        let request = KeychainReadRequest(service: service, key: key)
        DispatchQueue.global(qos: .userInitiated).async {
            request.run()
        }
        return try request.wait(timeout: readTimeout)
    }
}

private enum KeychainLookup {
    case found(String)
    case notFound
}

private final class KeychainReadRequest: @unchecked Sendable {
    private let service: String
    private let key: String
    private let completion = DispatchSemaphore(value: 0)
    private let resultLock = NSLock()
    private var result: Swift.Result<KeychainLookup, Error>?

    init(service: String, key: String) {
        self.service = service
        self.key = key
    }

    func run() {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &value)

        let outcome: Swift.Result<KeychainLookup, Error>
        if status == errSecItemNotFound {
            outcome = .success(.notFound)
        } else if status != errSecSuccess {
            outcome = .failure(CredentialStoreError.unavailable(status))
        } else if let data = value as? Data,
                  let string = String(data: data, encoding: .utf8) {
            outcome = .success(.found(string))
        } else {
            outcome = .failure(CredentialStoreError.invalidData)
        }

        resultLock.lock()
        result = outcome
        resultLock.unlock()
        completion.signal()
    }

    func wait(timeout: TimeInterval) throws -> KeychainLookup {
        guard completion.wait(timeout: .now() + timeout) == .success else {
            throw CredentialStoreError.timedOut
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        guard let result else { throw CredentialStoreError.timedOut }
        return try result.get()
    }
}

/// Explicitly injected for isolated preferences and tests; never persists secrets.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func read(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func write(_ value: String, for key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
    public func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
}
