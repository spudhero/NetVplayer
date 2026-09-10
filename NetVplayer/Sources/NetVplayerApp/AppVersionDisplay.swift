import Foundation

/// UI version comes from the same bundle metadata used by feedback and Providers.
enum AppVersionDisplay {
    static func label(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        guard let raw = info?["CFBundleShortVersionString"] as? String else {
            return "开发构建"
        }
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return "开发构建" }
        return version.hasPrefix("v") ? version : "v\(version)"
    }
}
