import AppKit
import Foundation
import DriveEngine
import Models
import Networking

struct CloudAuthP115QRCodeSession: Equatable, Sendable {
    let uid: String
    let time: String
    let sign: String
    let qrURL: URL
    let qrImageData: Data
}

enum CloudAuthP115QRCodePollResult {
    case waiting
    case scanned
    case credential(CloudCredential)
}

enum CloudAuthP115QRCodeLoginError: LocalizedError, Equatable {
    case invalidResponse
    case missingQRCode
    case expired
    case cancelled
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "115 扫码接口返回了无法识别的数据，请刷新二维码重试。"
        case .missingQRCode:
            return "115 登录二维码生成失败，请刷新重试。"
        case .expired:
            return "115 登录二维码已过期，请刷新后重新扫码。"
        case .cancelled:
            return "已在 115生活 App 中取消登录，请刷新后重试。"
        case .rejected(let message):
            return message.isEmpty ? "115 扫码登录失败，请刷新后重试。" : message
        }
    }
}

struct CloudAuthP115QRCodeLoginClient {
    static let tokenURL = URL(string: "https://qrcodeapi.115.com/api/1.0/web/1.0/token/")!
    static let statusBaseURL = URL(string: "https://qrcodeapi.115.com/get/status/")!
    static let resultURL = URL(string: "https://qrcodeapi.115.com/app/1.0/alipaymini/1.0/login/qrcode/")!

    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func beginSession() async throws -> CloudAuthP115QRCodeSession {
        let response = try await httpClient.get(
            url: Self.tokenURL.absoluteString,
            headers: Self.headers,
            timeout: 12,
            allowsProxyFallback: false,
            redactsURLInLogs: true
        )
        let data = try Self.responseData(from: response)
        guard let uid = Self.stringValue(data["uid"]), !uid.isEmpty,
              let time = Self.stringValue(data["time"]), !time.isEmpty,
              let sign = Self.stringValue(data["sign"]), !sign.isEmpty else {
            throw CloudAuthP115QRCodeLoginError.invalidResponse
        }

        let qrURL = Self.qrURL(uid: uid)
        guard let qrImageData = CloudAuthQRCodeImageFactory.imageData(from: qrURL.absoluteString) else {
            throw CloudAuthP115QRCodeLoginError.missingQRCode
        }
        return CloudAuthP115QRCodeSession(uid: uid, time: time, sign: sign, qrURL: qrURL, qrImageData: qrImageData)
    }

    func poll(_ session: CloudAuthP115QRCodeSession) async throws -> CloudAuthP115QRCodePollResult {
        let response = try await httpClient.get(
            url: Self.statusURL(for: session).absoluteString,
            headers: Self.headers,
            timeout: 12,
            allowsProxyFallback: false,
            redactsURLInLogs: true
        )
        let data = try Self.responseData(from: response)
        guard let status = Self.intValue(data["status"]) else {
            throw CloudAuthP115QRCodeLoginError.invalidResponse
        }

        switch status {
        case 0:
            return .waiting
        case 1:
            return .scanned
        case 2:
            return .credential(try await exchangeCredential(uid: session.uid))
        case -1:
            throw CloudAuthP115QRCodeLoginError.expired
        case -2:
            throw CloudAuthP115QRCodeLoginError.cancelled
        default:
            throw CloudAuthP115QRCodeLoginError.invalidResponse
        }
    }

    static func qrURL(uid: String) -> URL {
        URL(string: "https://115.com/scan/dg-\(uid)")!
    }

    static func statusURL(for session: CloudAuthP115QRCodeSession) -> URL {
        var components = URLComponents(url: statusBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "sign", value: session.sign),
            URLQueryItem(name: "time", value: session.time),
            URLQueryItem(name: "uid", value: session.uid)
        ]
        return components.url!
    }

    static func cookieString(from object: [String: Any]) -> String? {
        let preferredNames = ["UID", "CID", "SEID"]
        var values: [String: String] = [:]
        for (name, rawValue) in object {
            guard let value = stringValue(rawValue), !value.isEmpty else { continue }
            values[name.uppercased()] = value
        }
        guard preferredNames.allSatisfy({ values[$0]?.isEmpty == false }) else { return nil }

        let remainingNames = values.keys.filter { !preferredNames.contains($0) }.sorted()
        return (preferredNames + remainingNames)
            .compactMap { name in values[name].map { "\(name)=\($0)" } }
            .joined(separator: "; ")
    }

    private func exchangeCredential(uid: String) async throws -> CloudCredential {
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "account", value: uid)]
        let response = try await httpClient.post(
            url: Self.resultURL.absoluteString,
            headers: Self.formHeaders,
            body: Data((form.percentEncodedQuery ?? "").utf8),
            timeout: 12,
            handlesCookies: false
        )
        let data = try Self.responseData(from: response)
        let cookie: String?
        if let object = data["cookie"] as? [String: Any] {
            cookie = Self.cookieString(from: object)
        } else if let rawCookie = data["cookie"] as? String,
                  CloudAuthCookieFormatter.containsLikelyAuthCookie(rawCookie, provider: .p115) {
            cookie = rawCookie
        } else {
            cookie = nil
        }
        guard let cookie else {
            throw CloudAuthP115QRCodeLoginError.invalidResponse
        }
        return .cookie(provider: .p115, value: cookie)
    }

    private static func responseData(from response: HTTPResponse) throws -> [String: Any] {
        guard (200..<300).contains(response.statusCode),
              let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw CloudAuthP115QRCodeLoginError.invalidResponse
        }
        if let state = payload["state"] as? Bool, !state {
            let message = stringValue(payload["message"])
                ?? stringValue(payload["msg"])
                ?? ""
            throw CloudAuthP115QRCodeLoginError.rejected(message)
        }
        return payload["data"] as? [String: Any] ?? payload
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static let headers = [
        "Accept": "application/json, text/plain, */*",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    ]

    private static let formHeaders = [
        "Accept": "application/json, text/plain, */*",
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": headers["User-Agent"]!
    ]
}
