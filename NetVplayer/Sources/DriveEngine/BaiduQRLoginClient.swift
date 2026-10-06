import Foundation
import Networking

public struct BaiduQRCodeSession: Sendable {
    public let sign: String
    public let gid: String
    public let callback: String
    public let qrImageData: Data

    public init(sign: String, gid: String, callback: String, qrImageData: Data) {
        self.sign = sign
        self.gid = gid
        self.callback = callback
        self.qrImageData = qrImageData
    }
}

public struct BaiduQRLoginClient: Sendable {
    private static let passportBase = "https://passport.baidu.com"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    public func beginSession() async throws -> BaiduQRCodeSession {
        let gid = UUID().uuidString.uppercased()
        let callback = Self.callbackName()
        let now = Self.milliseconds()
        var components = URLComponents(string: "\(Self.passportBase)/v2/api/getqrcode")!
        components.queryItems = [
            URLQueryItem(name: "lp", value: "pc"),
            URLQueryItem(name: "qrloginfrom", value: "pc"),
            URLQueryItem(name: "gid", value: gid),
            URLQueryItem(name: "callback", value: callback),
            URLQueryItem(name: "apiver", value: "v3"),
            URLQueryItem(name: "tt", value: now),
            URLQueryItem(name: "tpl", value: "netdisk"),
            URLQueryItem(name: "logPage", value: "traceId:pc_loginv5_\(Self.seconds()),logPage:loginv5"),
            URLQueryItem(name: "_", value: now)
        ]
        let response = try await httpClient.get(
            url: components.url!.absoluteString,
            headers: Self.requestHeaders,
            timeout: 20,
            allowsProxyFallback: true,
            redactsURLInLogs: true
        )
        guard (200..<300).contains(response.statusCode),
              let object = Self.jsonpObject(response.text),
              Self.intValue(object["errno"]) == 0,
              let sign = object["sign"] as? String,
              !sign.isEmpty,
              let imageValue = object["imgurl"] as? String,
              let imageURL = Self.qrImageURL(from: imageValue) else {
            throw DriveEngineError.api(provider: .baidu, statusCode: response.statusCode, code: nil, message: "百度登录二维码生成失败")
        }
        let imageResponse = try await httpClient.get(
            url: imageURL.absoluteString,
            headers: Self.requestHeaders,
            timeout: 20,
            allowsProxyFallback: true,
            redactsURLInLogs: true
        )
        guard (200..<300).contains(imageResponse.statusCode),
              !imageResponse.data.isEmpty,
              Self.header(named: "Content-Type", in: imageResponse.headers)?.lowercased().hasPrefix("image/") == true else {
            throw DriveEngineError.api(provider: .baidu, statusCode: imageResponse.statusCode, code: nil, message: "百度登录二维码下载失败")
        }
        return BaiduQRCodeSession(sign: sign, gid: gid, callback: callback, qrImageData: imageResponse.data)
    }

    public func poll(_ session: BaiduQRCodeSession) async throws -> CloudCredential? {
        let now = Self.milliseconds()
        let callback = Self.callbackName()
        var components = URLComponents(string: "\(Self.passportBase)/channel/unicast")!
        components.queryItems = [
            URLQueryItem(name: "channel_id", value: session.sign),
            URLQueryItem(name: "gid", value: session.gid),
            URLQueryItem(name: "tpl", value: "netdisk"),
            URLQueryItem(name: "_sdkFrom", value: "1"),
            URLQueryItem(name: "callback", value: callback),
            URLQueryItem(name: "apiver", value: "v3"),
            URLQueryItem(name: "tt", value: now),
            URLQueryItem(name: "_", value: now)
        ]
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "Referer", value: "https://pan.baidu.com/"),
            URLQueryItem(name: "User-Agent", value: Self.userAgent)
        ]
        let response = try await httpClient.post(
            url: components.url!.absoluteString,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "Referer": "https://pan.baidu.com/",
                "User-Agent": Self.userAgent
            ],
            body: Data((form.percentEncodedQuery ?? "").utf8),
            timeout: 20
        )
        guard (200..<300).contains(response.statusCode), let object = Self.jsonpObject(response.text) else {
            throw DriveEngineError.api(provider: .baidu, statusCode: response.statusCode, code: nil, message: "百度扫码状态读取失败")
        }
        let errno = Self.intValue(object["errno"])
        if errno == 1 { return nil }
        guard errno == 0 else {
            throw DriveEngineError.api(provider: .baidu, statusCode: response.statusCode, code: errno, message: "百度登录二维码已失效，请刷新")
        }
        let channel: [String: Any]?
        if let value = object["channel_v"] as? [String: Any] {
            channel = value
        } else if let text = object["channel_v"] as? String,
                  let data = text.data(using: .utf8) {
            channel = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else {
            channel = nil
        }
        guard let channel else { return nil }
        let status = Self.intValue(channel["status"])
        if status == 1 { return nil }
        guard status == 0,
              let exchangeToken = channel["v"] as? String,
              !exchangeToken.isEmpty else { return nil }
        return try await exchange(exchangeToken: exchangeToken, session: session)
    }

    private func exchange(exchangeToken: String, session: BaiduQRCodeSession) async throws -> CloudCredential {
        let now = Self.milliseconds()
        var components = URLComponents(string: "\(Self.passportBase)/v3/login/main/qrbdusslogin")!
        components.queryItems = [
            URLQueryItem(name: "v", value: now),
            URLQueryItem(name: "bduss", value: exchangeToken),
            URLQueryItem(name: "u", value: "https://pan.baidu.com/disk/home"),
            URLQueryItem(name: "loginVersion", value: "v5"),
            URLQueryItem(name: "qrcode", value: "1"),
            URLQueryItem(name: "tpl", value: "netdisk"),
            URLQueryItem(name: "maskId", value: ""),
            URLQueryItem(name: "fileId", value: ""),
            URLQueryItem(name: "apiver", value: "v3"),
            URLQueryItem(name: "tt", value: now),
            URLQueryItem(name: "traceid", value: ""),
            URLQueryItem(name: "time", value: Self.seconds()),
            URLQueryItem(name: "alg", value: "v3"),
            URLQueryItem(name: "elapsed", value: "17"),
            URLQueryItem(name: "callback", value: Self.callbackName())
        ]
        let response = try await httpClient.get(
            url: components.url!.absoluteString,
            headers: Self.requestHeaders,
            timeout: 20,
            allowsProxyFallback: true,
            redactsURLInLogs: true
        )
        guard (200..<300).contains(response.statusCode) else {
            throw DriveEngineError.api(provider: .baidu, statusCode: response.statusCode, code: nil, message: "百度扫码登录交换失败")
        }

        var cookies = Self.cookiePairs(httpClient.cookieHeader(for: "https://pan.baidu.com/") ?? "")
        for (name, jsonKey) in [("BDUSS", "bduss"), ("PTOKEN", "ptoken"), ("STOKEN", "stoken")] {
            if let value = Self.javascriptStringValue(named: jsonKey, in: response.text), !value.isEmpty {
                cookies[name] = value
            }
        }
        guard cookies.keys.contains(where: { $0.caseInsensitiveCompare("BDUSS") == .orderedSame }) else {
            throw DriveEngineError.api(provider: .baidu, statusCode: response.statusCode, code: nil, message: "百度扫码已确认，但响应缺少登录会话")
        }
        let cookie = cookies.keys.sorted().map { "\($0)=\(cookies[$0]!)" }.joined(separator: "; ")
        return try await BaiduDriveClient(httpClient: httpClient).validate(.cookie(provider: .baidu, value: cookie))
    }

    static func jsonpObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    static func javascriptStringValue(named name: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?i)\\?[\"']"# + escaped + #"\\?[\"']\s*:\s*\\?[\"']([^\"']+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\\""#, with: #"""#)
    }

    private static func cookiePairs(_ cookie: String) -> [String: String] {
        var result: [String: String] = [:]
        for item in cookie.split(separator: ";") {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            result[name] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func qrImageURL(from value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let resolved: URL?
        if value.hasPrefix("//") {
            resolved = URL(string: "https:\(value)")
        } else if URLComponents(string: value)?.scheme != nil {
            resolved = URL(string: value)
        } else if value.lowercased().hasPrefix("passport.baidu.com/") {
            resolved = URL(string: "https://\(value)")
        } else {
            resolved = URL(string: value, relativeTo: URL(string: "\(passportBase)/"))?.absoluteURL
        }

        guard resolved?.scheme?.lowercased() == "https",
              resolved?.host?.lowercased() == "passport.baidu.com" else { return nil }
        return resolved
    }

    private static func header(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static var requestHeaders: [String: String] {
        [
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Referer": "https://pan.baidu.com/",
            "User-Agent": userAgent
        ]
    }

    private static func callbackName() -> String {
        "bd__cbs__\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased())"
    }

    private static func milliseconds() -> String {
        String(Int64(Date().timeIntervalSince1970 * 1_000))
    }

    private static func seconds() -> String {
        String(Int64(Date().timeIntervalSince1970))
    }
}
