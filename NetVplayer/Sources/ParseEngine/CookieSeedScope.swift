import Foundation

/// Origin and public-suffix checks for native cookie insertion. This is not a
/// cookie jar or evidence that a particular browser request sent a cookie.
struct CookieSeedScope {
    let exact: Set<String>
    let wildcard: Set<String>
    let exceptions: Set<String>

    init(rules: String) {
        var exact = Set<String>(), wildcard = Set<String>(), exceptions = Set<String>()
        for line in rules.split(separator: "\n") where !line.hasPrefix("//") {
            let rule = String(line)
            if rule.hasPrefix("!") { exceptions.insert(String(rule.dropFirst())) }
            else if rule.hasPrefix("*.") { wildcard.insert(String(rule.dropFirst(2))) }
            else { exact.insert(rule) }
        }
        self.exact = exact; self.wildcard = wildcard; self.exceptions = exceptions
    }

    static let shared: CookieSeedScope? = {
        // Installed applications carry SwiftPM bundles in Contents/Resources.
        let bundle = Bundle.main.url(forResource: "NetVplayer_ParseEngine", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = bundle.url(forResource: "PublicSuffixRules", withExtension: "dat"),
              let rules = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let scope = CookieSeedScope(rules: rules)
        guard scope.exact.contains("com"), scope.exact.contains("github.io"),
              scope.wildcard.contains("ck"), scope.exceptions.contains("www.ck") else { return nil }
        return scope
    }()

    func isPublicSuffix(_ domain: String) -> Bool {
        if exceptions.contains(domain) { return false }
        if exact.contains(domain) || !domain.contains(".") { return true }
        return wildcard.contains(String(domain.split(separator: ".").dropFirst().joined(separator: ".")))
    }

    static func canonicalDomain(_ input: String) -> String? {
        let domain = input.hasPrefix(".") ? String(input.dropFirst()) : input
        guard !domain.isEmpty, !domain.hasSuffix("."),
              !domain.contains(where: { $0.isWhitespace || $0.isASCII && !($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
              let host = URL(string: "https://" + domain)?.host?.lowercased(),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                      && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }), host.count <= 253 else { return nil }
        return host
    }
}
