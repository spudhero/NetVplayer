import Foundation
import Models
import Storage

/// Captures the saved account before a playback request starts. Environment-only
/// credentials and responses from a replaced account must not update that account.
public struct CloudDirectoryCredentialRefresh: Sendable {
    private let preferences: UserPreferences
    private let snapshot: CloudDirectoryAccountSnapshot
    private let originalOpenToken: String?

    public init?(original: CloudCredential, preferences: UserPreferences = .shared) {
        guard let snapshot = try? preferences.cloudDirectoryAccount(original.provider),
              Self.matches(original, snapshot: snapshot, preferences: preferences) else { return nil }
        self.preferences = preferences
        self.snapshot = snapshot
        self.originalOpenToken = original.provider == .ali ? Self.normalized(original.metadata["open_token"]) : nil
    }

    /// Custom playback handlers remain responsible for their own persistence.
    /// This default path deliberately ignores a stale response instead of changing accounts.
    @discardableResult
    public func save(_ updated: CloudCredential) -> Bool {
        guard updated.provider == snapshot.binding.provider else { return false }
        var values = snapshot.values
        var openToken: String?
        switch updated.provider {
        case .quark, .uc:
            guard updated.kind == .cookie, !Self.normalized(updated.secret).isEmpty else { return false }
            values[updated.provider.rawValue + "Cookie"] = Self.normalized(updated.secret)
        case .p115:
            guard updated.kind == .cookie, !Self.normalized(updated.secret).isEmpty else { return false }
            values["p115Cookie"] = Self.normalized(updated.secret)
            if let token = updated.metadata["access_token"] { values["p115AccessToken"] = Self.normalized(token) }
        case .ali:
            guard updated.kind == .refreshToken || updated.kind == .accessToken || updated.kind == .cookie else { return false }
            values["aliRefreshToken"] = Self.normalized(updated.refreshToken)
            values["aliAccessToken"] = Self.normalized(updated.accessToken)
            guard values["aliRefreshToken"]?.isEmpty == false || values["aliAccessToken"]?.isEmpty == false else { return false }
            for (metadataKey, preferenceKey) in Self.aliMetadataKeys {
                values[preferenceKey] = Self.normalized(updated.metadata[metadataKey])
            }
            openToken = Self.normalized(updated.metadata["open_token"])
        default:
            return false
        }
        do {
            try preferences.refreshCloudDirectoryAccount(snapshot, values: values, aliOpenToken: openToken,
                                                         expectedAliOpenToken: originalOpenToken)
            return true
        } catch {
            return false
        }
    }

    private static let aliMetadataKeys = [
        ("default_drive_id", "aliDefaultDriveID"),
        ("ali_auth_domain", "aliAuthDomain"),
        ("user_id", "aliUserID")
    ]

    private static func matches(_ original: CloudCredential, snapshot: CloudDirectoryAccountSnapshot,
                                preferences: UserPreferences) -> Bool {
        let values = snapshot.values
        switch original.provider {
        case .quark, .uc:
            return original.kind == .cookie
                && normalized(original.secret) == values[original.provider.rawValue + "Cookie"]
        case .p115:
            return original.kind == .cookie && normalized(original.secret) == values["p115Cookie"]
                && normalized(original.metadata["access_token"]) == values["p115AccessToken"]
        case .ali:
            return normalized(original.refreshToken) == values["aliRefreshToken"]
                && normalized(original.accessToken) == values["aliAccessToken"]
                && normalized(original.metadata["open_token"]) == normalized(preferences.aliOpenToken)
                && aliMetadataKeys.allSatisfy { normalized(original.metadata[$0.0]) == values[$0.1] }
        default:
            return false
        }
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
