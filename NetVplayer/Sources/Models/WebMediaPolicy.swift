import Foundation

/// Per-playback original-host rules and a lease on the current Spider session.
/// nil from the Spider check selects the host's default format check.
public struct WebMediaPolicy: Sendable {
    public let rules: [Rule]
    public let check: (@Sendable (String) async throws -> Bool?)?

    public init(rules: [Rule] = [], check: (@Sendable (String) async throws -> Bool?)? = nil) {
        self.rules = rules
        self.check = check
    }

    /// Frozen eb3.a/fx3.a: first rule matching either host or nested `url` host.
    public func matchingRule(for value: String) -> Rule? {
        guard let parts = URLComponents(string: value), let host = parts.host else { return nil }
        let nested = parts.queryItems?.first { $0.name == "url" }?.value
        let innerHost = nested.flatMap { URLComponents(string: $0)?.host } ?? ""
        let hosts = host.lowercased() + "," + innerHost.lowercased()
        return rules.first { rule in
            rule.hosts.contains { pattern in
                if hosts.contains(pattern) { return true }
                // String.matches requires the whole joined string, including comma.
                guard let regex = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z") else { return false }
                return regex.firstMatch(in: hosts, range: NSRange(hosts.startIndex..., in: hosts)) != nil
            }
        }
    }

    public func scripts(for url: String, click: String) -> [String] {
        var scripts = matchingRule(for: url)?.script ?? []
        if !click.isEmpty && !scripts.contains(click) { scripts.insert(click, at: 0) }
        return scripts.filter { !$0.isEmpty }
    }

    public func accepts(_ url: String) async throws -> Bool {
        if let result = try await check?(url) { return result }
        return try defaultAccepts(url)
    }

    /// Substring passes precede regex passes, exclusions precede inclusions.
    /// This is the frozen host format check; a DOM media tag cannot override it.
    public func defaultAccepts(_ url: String) throws -> Bool {
        let rule = matchingRule(for: url)
        func matches(_ patterns: [String]) throws -> Bool {
            if patterns.contains(where: url.contains) { return true }
            for pattern in patterns {
                let regex = try NSRegularExpression(pattern: pattern)
                if regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil { return true }
            }
            return false
        }
        if try matches(rule?.exclude ?? []) { return false }
        if try matches(rule?.regex ?? []) { return true }
        if ["url=http", "v=http", ".html"].contains(where: url.contains) { return false }
        let pattern = #"https?://[^\s]{12,}\.(?:m3u8|mp4|mkv|flv|mp3|m4a|aac|mpd)(?:\?.*)?|https?://.*?video/tos[^\s]*|rtmp:[^\s]+"#
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
}
