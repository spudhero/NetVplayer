import Foundation

public struct XtreamConfiguration: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var server: String
    public var allowsHTTP: Bool
    public var url: String { "netvplayer-xtream://" + id.uuidString.lowercased() }

    public init(id: UUID = UUID(), name: String, server: String, allowsHTTP: Bool = false) throws {
        guard var components = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https" || (allowsHTTP && components.scheme == "http"),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw XtreamError.invalidServer }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !components.path.isEmpty { components.path = "/" + components.path }
        self.id = id; self.name = name.isEmpty ? "Xtream" : name
        self.server = components.string ?? server
        self.allowsHTTP = allowsHTTP
    }

    public func validated() throws -> Self { try Self(id: id, name: name, server: server, allowsHTTP: allowsHTTP) }
    public func site() throws -> Site {
        _ = try validated()
        return Site(key: url, name: name, type: 3, api: url, ext: String(decoding: try JSONEncoder().encode(self), as: UTF8.self), timeout: 30)
    }
}

public struct XtreamCredentials: Codable, Sendable {
    public let username: String
    public let password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
}

public enum XtreamError: Error, LocalizedError, Sendable, Equatable {
    case invalidServer, authorizationRequired, inactiveAccount, malformedResponse, invalidReference, requestFailed
    public var errorDescription: String? {
        switch self {
        case .invalidServer: L10n.text("Xtream 服务器地址无效。请填写不含账号和参数的 HTTPS 地址。")
        case .authorizationRequired: L10n.text("请在内容来源中重新填写影视与直播账号（Xtream）。")
        case .inactiveAccount: L10n.text("Xtream 账号已过期或被停用。")
        case .malformedResponse: L10n.text("Xtream 服务器返回了不支持的数据格式。")
        case .invalidReference: L10n.text("Xtream 资源引用无效，请刷新目录。")
        case .requestFailed: L10n.text("无法连接 Xtream 服务器，请检查地址、账号和网络。")
        }
    }
}

/// Canonical resource identity. Contains no endpoint, account or playback URL.
public struct XtreamResource: Sendable, Equatable {
    public let accountID: UUID
    public let kind: String
    public let streamID: String
    public let format: String
    public var encoded: String { "xtr1.\(accountID.uuidString.lowercased()).\(kind).\(streamID).\(format)" }
    public init(accountID: UUID, kind: String, streamID: String, format: String) throws {
        guard ["movie", "series", "live"].contains(kind),
              !streamID.isEmpty, streamID.utf8.count <= 32, streamID.allSatisfy({ $0.isASCII && $0.isNumber }),
              ["mp4", "mkv", "m3u8", "ts", "avi", "mov", "webm"].contains(format) else { throw XtreamError.invalidReference }
        self.accountID = accountID; self.kind = kind; self.streamID = streamID; self.format = format
    }
    public init(_ encoded: String) throws {
        let parts = encoded.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "xtr1", let id = UUID(uuidString: parts[1]) else { throw XtreamError.invalidReference }
        try self.init(accountID: id, kind: parts[2], streamID: parts[3], format: parts[4])
        guard self.encoded == encoded else { throw XtreamError.invalidReference }
    }
}

public enum PlaybackFlagPresentation {
    private static let xtreamSeasonPrefix = "xtream-season:"

    public static func xtreamSeasonID(_ season: String) -> String {
        xtreamSeasonPrefix + season
    }

    public static func title(_ stableID: String, language: String? = nil) -> String {
        if stableID.hasPrefix(xtreamSeasonPrefix) {
            return L10n.text(
                "第 {0} 季",
                [String(stableID.dropFirst(xtreamSeasonPrefix.count))],
                language: language
            )
        }
        return DriveProvider.localizedFlagName(stableID, language: language)
    }
}

public enum XtreamLogRedaction {
    public static func redact(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)https?://[^\s]+"#) else {
            return text
        }
        let result = NSMutableString(string: text)
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches.reversed() {
            let token = result.substring(with: match.range)
            result.replaceCharacters(in: match.range, with: redactURLToken(token))
        }
        return result as String
    }

    private static func redactURLToken(_ token: String) -> String {
        guard var components = URLComponents(string: token),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            return token
        }
        var segments = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        let kinds: Set<String> = ["movie", "series", "live"]
        guard let kindIndex = segments.indices.reversed().first(where: { index in
            guard index + 3 < segments.count else { return false }
            let decoded = segments[index].removingPercentEncoding ?? segments[index]
            return kinds.contains(decoded.lowercased())
        }) else { return token }
        segments[kindIndex + 1] = "%3Caccount%3E"
        segments[kindIndex + 2] = "%3Csecret%3E"
        components.percentEncodedPath = segments.joined(separator: "/")
        return (components.string ?? token)
            .replacingOccurrences(of: "%3Caccount%3E", with: "<account>")
            .replacingOccurrences(of: "%3Csecret%3E", with: "<secret>")
    }
}
