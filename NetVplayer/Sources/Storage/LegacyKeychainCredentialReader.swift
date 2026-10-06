import Foundation
import Security

/// Best-effort, read-only migration from the old file-based Keychain.
/// An inaccessible account is left intact and recovered by signing in again.
public struct LegacyKeychainCredentialReader: LegacyCredentialReader {
    private static let interactionLock = NSLock()
    private let services: [String]

    public init(services: [String] = [
        "com.netvplayer.app.credentials.v2", "com.netvplayer.app.credentials.v1"
    ]) {
        self.services = services
    }

    public func read(_ key: String) throws -> String? {
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }

        // kSecUseAuthenticationUIFail alone doesn't suppress the file-based
        // Keychain's ACL dialogs. Disable legacy UI for the entire synchronous
        // operation and restore the previous setting before leaving this scope.
        var wasAllowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw CredentialStoreError.legacyAuthorizationRequired
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }

        for service in services {
            let attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(attributes as CFDictionary, &item)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else {
                throw CredentialStoreError.legacyAuthorizationRequired
            }
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.invalidData
            }
            // A v2 empty value records logout and must stop v1 fallback.
            return value
        }
        return nil
    }
}
