// DriveEngine/QuarkTVDriver.swift
// Quark TV QR-login driver based on AList's quark_uc_tv flow.

import CryptoKit
import Foundation
import Models
import Networking

public struct QuarkTVQRCodeSession: Equatable, Sendable {
    public let provider: DriveProvider
    public let qrData: String
    public let queryToken: String
    public let deviceID: String

    public init(provider: DriveProvider = .quark, qrData: String, queryToken: String, deviceID: String) {
        self.provider = provider
        self.qrData = qrData
        self.queryToken = queryToken
        self.deviceID = deviceID
    }
}

public final class QuarkTVDriver: @unchecked Sendable {
    public let provider: DriveProvider

    private let httpClient: HTTPClient
    private let profile: TVDriveProfile

    public init(provider: DriveProvider = .quark, httpClient: HTTPClient = .shared) {
        self.provider = provider
        self.httpClient = httpClient
        self.profile = TVDriveProfile(provider: provider)
    }

    public func beginQRCodeSession(deviceID existingDeviceID: String? = nil) async throws -> QuarkTVQRCodeSession {
        let deviceID = existingDeviceID?.isEmpty == false ? existingDeviceID! : Self.md5Hex(UUID().uuidString + String(Date().timeIntervalSince1970))
        let json = try await requestOpenAPI(
            path: "/oauth/authorize",
            method: .get,
            deviceID: deviceID,
            accessToken: "",
            query: [
                "auth_type": "code",
                "client_id": profile.clientID,
                "scope": "netdisk",
                "qrcode": "1",
                "qr_width": "460",
                "qr_height": "460"
            ]
        )

        guard let qrData = Self.stringValue(json["qr_data"]), !qrData.isEmpty,
              let queryToken = Self.stringValue(json["query_token"]), !queryToken.isEmpty else {
            throw DriveEngineError.api(provider: provider, statusCode: 200, code: nil, message: "扫码二维码响应结构异常")
        }

        return QuarkTVQRCodeSession(provider: provider, qrData: qrData, queryToken: queryToken, deviceID: deviceID)
    }

    public func pollQRCodeSession(_ session: QuarkTVQRCodeSession) async throws -> CloudCredential? {
        let json = try await requestOpenAPI(
            path: "/oauth/code",
            method: .get,
            deviceID: session.deviceID,
            accessToken: "",
            query: [
                "client_id": profile.clientID,
                "scope": "netdisk",
                "query_token": session.queryToken
            ]
        )

        guard let code = Self.stringValue(json["code"]), !code.isEmpty else {
            return nil
        }
        return try await exchangeToken(code: code, deviceID: session.deviceID, queryToken: session.queryToken, isRefresh: false)
    }

    public func validate(_ credential: CloudCredential, reference _: DriveFileReference?) async throws -> CloudCredential {
        guard credential.provider == provider else {
            throw DriveEngineError.unsupported("QuarkTVDriver 当前实例只支持\(provider.displayName)。")
        }
        guard let deviceID = credential.deviceID,
              let accessToken = credential.accessToken,
              !deviceID.isEmpty,
              !accessToken.isEmpty else {
            throw DriveEngineError.loginRequired(provider)
        }

        do {
            _ = try await requestOpenAPI(
                path: "/user",
                method: .get,
                deviceID: deviceID,
                accessToken: accessToken,
                query: ["method": "user_info"]
            )
            var validated = credential
            validated.updatedAt = Date()
            return validated
        } catch {
            if let refreshToken = credential.refreshToken, !refreshToken.isEmpty {
                let refreshed = try await exchangeToken(code: refreshToken, deviceID: deviceID, queryToken: credential.queryToken, isRefresh: true)
                _ = try await requestOpenAPI(
                    path: "/user",
                    method: .get,
                    deviceID: deviceID,
                    accessToken: refreshed.accessToken ?? "",
                    query: ["method": "user_info"]
                )
                return refreshed
            }
            throw error
        }
    }

    public func link(reference: DriveFileReference, credential: CloudCredential) async throws -> CloudDriveLink {
        let validated = try await validate(credential, reference: reference)
        let json = try await requestOpenAPI(
            path: "/file",
            method: .get,
            deviceID: validated.deviceID ?? "",
            accessToken: validated.accessToken ?? "",
            query: [
                "method": "download",
                "group_by": "source",
                "fid": reference.fid,
                "resolution": "4k,2k,super,high,normal,low",
                "support": "dolby_vision"
            ]
        )

        guard let data = json["data"] as? [String: Any],
              let downloadURL = Self.stringValue(data["download_url"]),
              !downloadURL.isEmpty else {
            throw DriveEngineError.noDownloadURL(reference.fileName)
        }
        return CloudDriveLink(
            url: downloadURL,
            headers: profile.playbackHeaders(),
            metadata: [
                DrivePlaybackMetadataKey.provider: provider.rawValue,
                DrivePlaybackMetadataKey.fid: reference.fid,
                DrivePlaybackMetadataKey.fileName: reference.fileName,
                DrivePlaybackMetadataKey.route: provider == .uc ? DrivePlaybackRoute.ucOriginalProxy : ""
            ].filter { !$0.value.isEmpty },
            updatedCredential: validated
        )
    }

    public func streamingLink(
        reference: DriveFileReference,
        credential: CloudCredential,
        expectedSize: Int64? = nil
    ) async throws -> CloudDriveLink {
        guard provider == .uc else {
            throw DriveEngineError.unsupported("\(provider.displayName) TV OpenAPI streaming 目前只用于 UC 优汐智路线。")
        }
        let validated = try await validate(credential, reference: reference)
        let json = try await requestOpenAPI(
            path: "/file",
            method: .get,
            deviceID: validated.deviceID ?? "",
            accessToken: validated.accessToken ?? "",
            query: [
                "method": "streaming",
                "fid": reference.fid,
                "resolution": "low,normal,high,super,2k,4k",
                "support": "dolby_vision",
                "group_by": "source"
            ]
        )

        guard let data = json["data"] as? [String: Any],
              let selection = Self.bestOpenAPIStreamingSelection(in: data) else {
            throw DriveEngineError.noDownloadURL(reference.fileName)
        }

        var metadata: [String: String] = [
            DrivePlaybackMetadataKey.provider: provider.rawValue,
            DrivePlaybackMetadataKey.fid: reference.fid,
            DrivePlaybackMetadataKey.fileName: reference.fileName,
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.ucOpenAPIStreaming,
            DrivePlaybackMetadataKey.selectedReason: selection.reason,
            DrivePlaybackMetadataKey.candidateSummary: selection.candidateSummary
        ]
        if !selection.resolution.isEmpty {
            metadata[DrivePlaybackMetadataKey.quality] = selection.resolution
            metadata[DrivePlaybackMetadataKey.qualityLabel] = Self.streamingQualityLabel(for: selection.resolution)
        }
        let selectedSize = (selection.size ?? 0) > 0 ? selection.size : expectedSize
        if let size = selectedSize, size > 0 {
            metadata[DrivePlaybackMetadataKey.size] = String(size)
        }
        if let width = selection.width, width > 0 {
            metadata[DrivePlaybackMetadataKey.width] = String(width)
        }
        if let height = selection.height, height > 0 {
            metadata[DrivePlaybackMetadataKey.height] = String(height)
        }

        return CloudDriveLink(
            url: selection.url,
            headers: [:],
            metadata: metadata.filter { !$0.value.isEmpty },
            updatedCredential: validated
        )
    }
}

private extension QuarkTVDriver {
    struct TVDriveProfile: Sendable {
        let provider: DriveProvider
        let apiBase: String
        let codeAPIBase: String
        let clientID: String
        let signKey: String
        let appVersion: String
        let channel: String
        let userAgent = "Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1"

        init(provider: DriveProvider) {
            self.provider = provider
            switch provider {
            case .uc:
                apiBase = "https://open-api-drive.uc.cn"
                codeAPIBase = "http://api.extscreen.com/ucdrive"
                clientID = "5acf882d27b74502b7040b0c65519aa7"
                signKey = "l3srvtd7p42l0d0x1u8d7yc8ye9kki4d"
                appVersion = "1.6.8"
                channel = "UCTVOFFICIALWEB"
            default:
                apiBase = "https://open-api-drive.quark.cn"
                codeAPIBase = "http://api.extscreen.com/quarkdrive"
                clientID = "d3194e61504e493eb6222857bccfed94"
                signKey = "kw2dvtd7p4t3pjl2d9ed9yc8yej8kw2d"
                appVersion = "1.5.6"
                channel = "CP"
            }
        }

        func playbackHeaders() -> [String: String] {
            [
                "User-Agent": userAgent,
                "Referer": provider == .uc ? "https://drive.uc.cn/" : "https://pan.quark.cn"
            ]
        }
    }

    struct OpenAPIStreamingSelection {
        let url: String
        let resolution: String
        let reason: String
        let candidateSummary: String
        let width: Int?
        let height: Int?
        let size: Int64?
    }

    struct OpenAPIStreamingCandidate {
        let url: String
        let resolution: String
        let transStatus: String
        let accessable: Int?
        let width: Int?
        let height: Int?
        let size: Int64?
        let host: String

        var reason: String {
            let value = resolution.isEmpty ? "unknown" : resolution
            return "openapi-streaming:resolution:\(value)"
        }
    }

    static func bestOpenAPIStreamingSelection(in data: [String: Any]) -> OpenAPIStreamingSelection? {
        let candidates = openAPIStreamingCandidates(in: data)
        guard !candidates.isEmpty else { return nil }
        let preferredResolutions = ["4k", "2k", "super", "high", "normal", "low"]
        let selected = preferredResolutions.compactMap { preferred in
            candidates.first { $0.resolution.caseInsensitiveCompare(preferred) == .orderedSame }
        }.first ?? candidates[0]
        return OpenAPIStreamingSelection(
            url: selected.url,
            resolution: selected.resolution,
            reason: selected.reason,
            candidateSummary: openAPIStreamingCandidateSummary(
                candidates: candidates,
                selected: selected,
                defaultResolution: stringValue(data["default_resolution"])
            ),
            width: selected.width,
            height: selected.height,
            size: selected.size
        )
    }

    static func openAPIStreamingCandidates(in data: [String: Any]) -> [OpenAPIStreamingCandidate] {
        guard let rawItems = data["video_info"] as? [[String: Any]] else {
            return []
        }
        return rawItems.compactMap { raw in
            guard let url = stringValue(raw["url"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else {
                return nil
            }
            let transStatus = stringValue(raw["trans_status"]) ?? ""
            if !transStatus.isEmpty && transStatus.caseInsensitiveCompare("success") != .orderedSame {
                return nil
            }
            let accessable = intValue(raw["accessable"]) ?? intValue(raw["accessible"])
            if accessable == 0 {
                return nil
            }
            return OpenAPIStreamingCandidate(
                url: url,
                resolution: stringValue(raw["resolution"]) ?? "",
                transStatus: transStatus,
                accessable: accessable,
                width: intValue(raw["width"]),
                height: intValue(raw["height"]),
                size: int64Value(raw["size"]),
                host: URL(string: url)?.host ?? "-"
            )
        }
    }

    static func openAPIStreamingCandidateSummary(
        candidates: [OpenAPIStreamingCandidate],
        selected: OpenAPIStreamingCandidate,
        defaultResolution: String?
    ) -> String {
        var parts: [String] = []
        if let defaultResolution, !defaultResolution.isEmpty {
            parts.append("default=\(defaultResolution)")
        }
        parts.append(contentsOf: candidates.prefix(6).map { candidate in
            let resolution = candidate.resolution.isEmpty ? "-" : candidate.resolution
            let status = candidate.transStatus.isEmpty ? "-" : candidate.transStatus
            let access = candidate.accessable.map(String.init) ?? "-"
            let size = candidate.size.map(String.init) ?? "-"
            return "res=\(resolution) status=\(status) accessable=\(access) size=\(size) host=\(candidate.host)"
        })
        parts.append("selected=\(selected.reason) host=\(selected.host)")
        return parts.joined(separator: " | ")
    }

    static func streamingQualityLabel(for resolution: String) -> String {
        switch resolution.lowercased() {
        case "4k":
            return "4K"
        case "2k":
            return "2K"
        case "super":
            return "超清"
        case "high":
            return "高清"
        case "normal":
            return "标清"
        case "low":
            return "流畅"
        default:
            return resolution
        }
    }

    func requestOpenAPI(
        path: String,
        method: HTTPMethod,
        deviceID: String,
        accessToken: String,
        query: [String: String]
    ) async throws -> [String: Any] {
        let (timestamp, xPanToken, reqID) = Self.requestSignature(
            method: method.rawValue,
            path: path,
            signKey: profile.signKey,
            deviceID: deviceID
        )
        var allQuery: [String: String] = [
            "req_id": reqID,
            "access_token": accessToken,
            "app_ver": profile.appVersion,
            "device_id": deviceID,
            "device_brand": "Xiaomi",
            "platform": "tv",
            "device_name": "M2004J7AC",
            "device_model": "M2004J7AC",
            "build_device": "M2004J7AC",
            "build_product": "M2004J7AC",
            "device_gpu": "Adreno (TM) 550",
            "activity_rect": "{}",
            "channel": profile.channel
        ]
        query.forEach { allQuery[$0.key] = $0.value }

        let url = Self.url(base: profile.apiBase, path: path, query: allQuery)
        let headers = [
            "Accept": "application/json, text/plain, */*",
            "User-Agent": profile.userAgent,
            "x-pan-tm": timestamp,
            "x-pan-token": xPanToken,
            "x-pan-client-id": profile.clientID
        ]
        let response = try await httpClient.request(url: url, method: method, headers: headers, timeout: 20)
        return try decodeOpenAPIResponse(response)
    }

    func exchangeToken(code: String, deviceID: String, queryToken: String?, isRefresh: Bool) async throws -> CloudCredential {
        let (_, _, reqID) = Self.requestSignature(method: "POST", path: "/token", signKey: profile.signKey, deviceID: deviceID)
        var body: [String: String] = [
            "req_id": reqID,
            "app_ver": profile.appVersion,
            "device_id": deviceID,
            "device_brand": "Xiaomi",
            "platform": "tv",
            "device_name": "M2004J7AC",
            "device_model": "M2004J7AC",
            "build_device": "M2004J7AC",
            "build_product": "M2004J7AC",
            "device_gpu": "Adreno (TM) 550",
            "activity_rect": "{}",
            "channel": profile.channel
        ]
        if isRefresh {
            body["refresh_token"] = code
        } else {
            body["code"] = code
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await httpClient.post(
            url: profile.codeAPIBase + "/token",
            headers: ["Content-Type": "application/json"],
            body: data,
            timeout: 20
        )
        let json = try decodeTokenResponse(response)
        guard let dataJSON = json["data"] as? [String: Any],
              let refreshToken = Self.stringValue(dataJSON["refresh_token"]), !refreshToken.isEmpty,
              let accessToken = Self.stringValue(dataJSON["access_token"]), !accessToken.isEmpty else {
            throw DriveEngineError.api(provider: provider, statusCode: response.statusCode, code: nil, message: "refresh token is empty")
        }
        return .token(
            provider: provider,
            refreshToken: refreshToken,
            accessToken: accessToken,
            deviceID: deviceID,
            queryToken: queryToken
        )
    }

    func decodeOpenAPIResponse(_ response: HTTPResponse) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] else {
            throw DriveEngineError.api(provider: provider, statusCode: response.statusCode, code: nil, message: "响应不是 JSON")
        }
        let errno = Self.intValue(json["errno"]) ?? 0
        let status = Self.intValue(json["status"]) ?? 0
        if !(200..<300).contains(response.statusCode) || status >= 400 || errno != 0 {
            let message = Self.stringValue(json["error_info"]) ?? Self.stringValue(json["message"]) ?? response.text
            throw DriveEngineError.api(provider: provider, statusCode: response.statusCode, code: errno, message: message)
        }
        return json
    }

    func decodeTokenResponse(_ response: HTTPResponse) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] else {
            throw DriveEngineError.api(provider: provider, statusCode: response.statusCode, code: nil, message: "响应不是 JSON")
        }
        let code = Self.intValue(json["code"]) ?? response.statusCode
        if !(200..<300).contains(response.statusCode) || code != 200 {
            let message = Self.stringValue(json["message"]) ?? response.text
            throw DriveEngineError.api(provider: provider, statusCode: response.statusCode, code: code, message: message)
        }
        return json
    }

    static func requestSignature(method: String, path: String, signKey: String, deviceID: String) -> (String, String, String) {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let reqID = md5Hex(deviceID + timestamp)
        let tokenData = "\(method)&\(path)&\(timestamp)&\(signKey)"
        let digest = SHA256.hash(data: Data(tokenData.utf8))
        let token = digest.map { String(format: "%02x", $0) }.joined()
        return (timestamp, token, reqID)
    }

    static func md5Hex(_ value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func url(base: String, path: String, query: [String: String]) -> String {
        var components = URLComponents(string: base + path)
        components?.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components?.url?.absoluteString ?? base + path
    }

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func int64Value(_ value: Any?) -> Int64? {
        if let int64 = value as? Int64 { return int64 }
        if let int = value as? Int { return Int64(int) }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}
