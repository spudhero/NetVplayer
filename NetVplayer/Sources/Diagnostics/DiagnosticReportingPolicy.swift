import Foundation

public enum DiagnosticReportingConfiguration {
    public static let preferenceKey = "netvplayer.automaticDiagnosticsEnabled"
    public static let dsnInfoKey = "NetVplayerSentryDSN"
    public static let tracesSampleRate = 0.05

    public static func dsn(environment: [String: String], info: [String: Any]) -> String? {
        let value = (environment["NETVPLAYER_SENTRY_DSN"] ?? info[dsnInfoKey] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value), url.scheme == "https",
              let host = url.host, host.hasSuffix(".ingest.sentry.io") || host.hasSuffix(".ingest.us.sentry.io") || host.hasSuffix(".ingest.de.sentry.io"),
              url.password == nil, url.query == nil, url.fragment == nil,
              let key = url.user, !key.isEmpty,
              key.allSatisfy({ $0.isHexDigit }),
              url.path.dropFirst().allSatisfy({ $0.isNumber }), url.path.count > 1 else { return nil }
        return value
    }
}

/// Business errors are deduplicated per kind for five minutes and capped at 30 per day.
/// The persisted budget survives application restarts and preference toggles.
public final class DiagnosticEventBudget {
    private let defaults: UserDefaults
    private let dailyLimit: Int
    private let minimumInterval: TimeInterval
    private var lastSent: [String: TimeInterval] = [:]

    public init(defaults: UserDefaults, dailyLimit: Int = 30, minimumInterval: TimeInterval = 300) {
        self.defaults = defaults
        self.dailyLimit = dailyLimit
        self.minimumInterval = minimumInterval
    }

    // Called only while the reporter holds its lock.
    public func admit(code: String, now: Date = Date()) -> Bool {
        let seconds = now.timeIntervalSince1970
        if let last = lastSent[code], seconds - last < minimumInterval { return false }
        let day = Int(seconds / 86_400)
        let storedDay = defaults.integer(forKey: "netvplayer.diagnostics.budgetDay")
        let count = day == storedDay ? defaults.integer(forKey: "netvplayer.diagnostics.budgetCount") : 0
        guard count < dailyLimit else { return false }
        defaults.set(day, forKey: "netvplayer.diagnostics.budgetDay")
        defaults.set(count + 1, forKey: "netvplayer.diagnostics.budgetCount")
        lastSent[code] = seconds
        return true
    }
}
