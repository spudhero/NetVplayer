// DriveEngine/UCFongMiQRLoginClient.swift
// Gated UC FongMi QR-login contract. The private two-scan API is only enabled
// after decrypted fixture evidence provides the QR, polling, and ticket shapes.

import Foundation
import Models

public enum UCFongMiQRLoginKind: String, Codable, Sendable, Equatable {
    case account
    case playback
}

public enum UCFongMiQRLoginStatus: String, Codable, Sendable, Equatable {
    case pending
    case confirmed
    case expired
    case unsupported
}

public enum UCFongMiCredentialMetadataKey {
    public static let namespace = "uc.fongmi.namespace"
    public static let namespaceValue = "uc-fongmi-private-qr"
    public static let kind = "uc.fongmi.kind"
    public static let expiresAt = "uc.fongmi.expiresAt"
    public static let fixtureID = "uc.fongmi.fixtureID"
    public static let evidenceStatus = "uc.fongmi.evidenceStatus"
    public static let scanConfirmURL = "uc.fongmi.scanConfirmURL"
}

public struct UCFongMiQRLoginSession: Codable, Sendable, Equatable {
    public let kind: UCFongMiQRLoginKind
    public let qrURL: String
    public let token: String?
    public let clientID: String?
    public let createdAt: Date
    public let expiresAt: Date?
    public let fixtureID: String
    public let evidenceStatus: ExternalCaptureStatus

    public init(
        kind: UCFongMiQRLoginKind,
        qrURL: String,
        token: String?,
        clientID: String?,
        createdAt: Date,
        expiresAt: Date?,
        fixtureID: String,
        evidenceStatus: ExternalCaptureStatus
    ) {
        self.kind = kind
        self.qrURL = qrURL
        self.token = token
        self.clientID = clientID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.fixtureID = fixtureID
        self.evidenceStatus = evidenceStatus
    }
}

public struct UCFongMiQRLoginResult: Codable, Sendable, Equatable {
    public let kind: UCFongMiQRLoginKind
    public let status: UCFongMiQRLoginStatus
    public let credential: CloudCredential?
    public let message: String?

    public init(
        kind: UCFongMiQRLoginKind,
        status: UCFongMiQRLoginStatus,
        credential: CloudCredential? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.status = status
        self.credential = credential
        self.message = message
    }
}

public struct UCFongMiQRLoginHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public final class UCFongMiQRLoginClient: @unchecked Sendable {
    public static let defaultFixtureID = "fongmi-uuss-uc-login-playback-capture"

    private static let qrURLKeys = ["qrURL", "scanConfirmURL"]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func beginSession(
        kind: UCFongMiQRLoginKind,
        evidence: DrivePlaybackDiagnosticFixture
    ) throws -> UCFongMiQRLoginSession {
        guard evidence.provider.lowercased() == DriveProvider.uc.rawValue else {
            throw DriveEngineError.unsupported("UC FongMi 私有码只适用于 UC provider。")
        }
        guard evidence.sampleStatus == .nativeRewriteReady,
              evidence.admissionDecision.canRegisterNativeCapability else {
            throw missingEvidenceError("当前 fixture 未达到 nativeRewriteReady，缺少生成二维码、轮询扫码、换票据的 HTTPS 明文字段。")
        }
        guard let qrURL = Self.qrURL(from: evidence),
              !qrURL.absoluteString.contains("<redacted>"),
              Self.isBroccoliScanURL(qrURL) else {
            throw missingEvidenceError("nativeRewriteReady fixture 仍缺少可执行的 broccoli.uc.cn 生成二维码 URL。")
        }

        let queryItems = URLComponents(url: qrURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        let createdAt = now()
        return UCFongMiQRLoginSession(
            kind: kind,
            qrURL: qrURL.absoluteString,
            token: values["token"],
            clientID: values["client_id"],
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(120),
            fixtureID: evidence.id,
            evidenceStatus: evidence.sampleStatus
        )
    }

    public func beginSession(
        kind: UCFongMiQRLoginKind,
        qrToken: String,
        clientID: String,
        fixtureID: String = UCFongMiQRLoginClient.defaultFixtureID,
        evidenceStatus: ExternalCaptureStatus = .nativeRewriteReady
    ) throws -> UCFongMiQRLoginSession {
        guard evidenceStatus == .nativeRewriteReady else {
            throw missingEvidenceError("当前 session 不是 nativeRewriteReady 证据生成，不能启用 UC FongMi 私有码。")
        }
        let token = qrToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !clientID.isEmpty else {
            throw missingEvidenceError("生成二维码返回缺少 token 或 client_id。")
        }
        let createdAt = now()
        return UCFongMiQRLoginSession(
            kind: kind,
            qrURL: try Self.scanConfirmURL(token: token, clientID: clientID).absoluteString,
            token: token,
            clientID: clientID,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(120),
            fixtureID: fixtureID,
            evidenceStatus: evidenceStatus
        )
    }

    public func decodePollResponse(
        _ response: UCFongMiQRLoginHTTPResponse,
        for session: UCFongMiQRLoginSession
    ) throws -> UCFongMiQRLoginResult {
        guard session.evidenceStatus == .nativeRewriteReady else {
            throw missingEvidenceError("当前 session 不是 nativeRewriteReady 证据生成，不能解码 UC FongMi 私有码轮询结果。")
        }
        let payload = try Self.decodeJSONDictionary(response.body)
        switch session.kind {
        case .account:
            if let ticket = Self.string(at: ["data", "members", "service_ticket"], in: payload),
               !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return UCFongMiQRLoginResult(
                    kind: session.kind,
                    status: .confirmed,
                    credential: Self.credential(
                        kind: .account,
                        token: ticket,
                        expiresAt: session.expiresAt,
                        fixtureID: session.fixtureID,
                        sampleStatus: session.evidenceStatus,
                        scanConfirmURL: session.qrURL,
                        updatedAt: now()
                    ),
                    message: Self.message(from: payload)
                )
            }
        case .playback:
            if let code = Self.string(at: ["code"], in: payload),
               !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return UCFongMiQRLoginResult(
                    kind: session.kind,
                    status: .confirmed,
                    credential: Self.credential(
                        kind: .playback,
                        token: code,
                        expiresAt: session.expiresAt,
                        fixtureID: session.fixtureID,
                        sampleStatus: session.evidenceStatus,
                        scanConfirmURL: session.qrURL,
                        updatedAt: now()
                    ),
                    message: Self.message(from: payload)
                )
            }
        }

        let message = Self.message(from: payload)
        if Self.isExpiredMessage(message) {
            return UCFongMiQRLoginResult(kind: session.kind, status: .expired, message: message)
        }
        if Self.isPendingMessage(message) {
            return UCFongMiQRLoginResult(kind: session.kind, status: .pending, message: message)
        }
        return UCFongMiQRLoginResult(kind: session.kind, status: .unsupported, message: message)
    }

    public func validate(_ credential: CloudCredential) async throws -> CloudCredential {
        guard Self.isFongMiCredential(credential) else {
            throw DriveEngineError.unsupported("不是 UC FongMi 私有码凭证。")
        }
        guard credential.metadata[UCFongMiCredentialMetadataKey.evidenceStatus] == ExternalCaptureStatus.nativeRewriteReady.rawValue else {
            throw missingEvidenceError("UC FongMi 私有码凭证缺少 nativeRewriteReady 证据，拒绝写入存储。")
        }
        var validated = credential
        validated.updatedAt = now()
        return validated
    }

    public static func credential(
        kind: UCFongMiQRLoginKind,
        token: String,
        expiresAt: Date?,
        fixtureID: String,
        sampleStatus: ExternalCaptureStatus,
        scanConfirmURL: String? = nil,
        updatedAt: Date = Date()
    ) -> CloudCredential {
        var metadata: [String: String] = [
            UCFongMiCredentialMetadataKey.namespace: UCFongMiCredentialMetadataKey.namespaceValue,
            UCFongMiCredentialMetadataKey.kind: kind.rawValue,
            UCFongMiCredentialMetadataKey.fixtureID: fixtureID,
            UCFongMiCredentialMetadataKey.evidenceStatus: sampleStatus.rawValue
        ]
        if let expiresAt {
            metadata[UCFongMiCredentialMetadataKey.expiresAt] = String(Int(expiresAt.timeIntervalSince1970))
        }
        if let scanConfirmURL, !scanConfirmURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata[UCFongMiCredentialMetadataKey.scanConfirmURL] = DrivePlaybackDiagnosticFixture.redactedURL(scanConfirmURL)
        }
        return CloudCredential(
            provider: .uc,
            kind: .shareToken,
            secret: token,
            metadata: metadata,
            updatedAt: updatedAt
        )
    }

    public static func isFongMiCredential(_ credential: CloudCredential) -> Bool {
        credential.provider == .uc
            && credential.kind == .shareToken
            && credential.metadata[UCFongMiCredentialMetadataKey.namespace] == UCFongMiCredentialMetadataKey.namespaceValue
            && credential.metadata[UCFongMiCredentialMetadataKey.kind] != nil
            && !credential.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func qrURL(from evidence: DrivePlaybackDiagnosticFixture) -> URL? {
        for key in qrURLKeys {
            guard let raw = evidence.requestShape[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let url = URL(string: raw) else {
                continue
            }
            return url
        }
        guard let url = URL(string: evidence.redactedURL),
              isBroccoliScanURL(url) else {
            return nil
        }
        return url
    }

    private static func isBroccoliScanURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "broccoli.uc.cn"
            && url.path.contains("/scan_confirm")
    }

    private static func scanConfirmURL(token: String, clientID: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "broccoli.uc.cn"
        components.path = "/apps/ZY5qIZiK/routes/scan_confirm"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "uc_biz_str", value: "S:custom|C:titlebar_fix")
        ]
        guard let url = components.url else {
            throw DriveEngineError.unsupported("UC FongMi 私有码暂不可启用：无法构造 broccoli 扫码 URL。")
        }
        return url
    }

    private static func decodeJSONDictionary(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else {
            throw DriveEngineError.unsupported("UC FongMi 私有码返回为空。")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = json as? [String: Any] else {
            throw DriveEngineError.unsupported("UC FongMi 私有码返回不是 JSON object。")
        }
        return dictionary
    }

    private static func string(at path: [String], in dictionary: [String: Any]) -> String? {
        var current: Any? = dictionary
        for key in path {
            guard let object = current as? [String: Any] else { return nil }
            current = object[key]
        }
        return stringValue(current)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func message(from payload: [String: Any]) -> String? {
        stringValue(payload["message"])
            ?? stringValue(payload["error_info"])
            ?? stringValue(payload["status"])
    }

    private static func isPendingMessage(_ message: String?) -> Bool {
        guard let message else { return true }
        return message.contains("Query result is empty")
            || message.contains("用户未确认授权")
            || message.contains("未确认")
            || message.contains("empty")
    }

    private static func isExpiredMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        let lower = message.lowercased()
        return lower.contains("expired")
            || message.contains("过期")
            || message.contains("失效")
    }

    private func missingEvidenceError(_ reason: String) -> DriveEngineError {
        DriveEngineError.unsupported("UC FongMi 私有码暂不可启用：\(reason)")
    }
}
