import Models
import Storage

/// Load off the main thread; rendering a settings row must never wait for the
/// credential lock while SwiftUI holds its own update lock.
struct CloudAccountSettingsSnapshot: Sendable {
    let values: [String: String]
    let statuses: [DriveProvider: CloudAccountStatus]

    init(preferences: UserPreferences) {
        let keys = ["quarkCookie", "ucCookie", "baiduCookie", "aliRefreshToken", "aliAccessToken",
                    "aliOpenToken", "p115Cookie", "p115AccessToken", "pikpakAccessToken", "pikpakRefreshToken"]
        var values = Dictionary(uniqueKeysWithValues: keys.map { ($0, preferences.credential($0)) })
        values["aliDefaultDriveID"] = preferences.aliDefaultDriveID
        values["pikpakDeviceID"] = preferences.pikpakDeviceID
        self.values = values
        let providers: [DriveProvider] = [.quark, .uc, .baidu, .ali, .p115, .pikpak]
        statuses = Dictionary(uniqueKeysWithValues: providers.map { ($0, preferences.cloudAccountStatus(for: $0)) })
    }
}
