// Models/ExternalEvidenceAdmission.swift
// Evidence gates for promoting external captures into native playback/provider code.

import Foundation

public enum ExternalEvidenceSignal: String, Codable, Sendable, Equatable, CaseIterable {
    case catVodInputOutput = "catvod-input-output"
    case httpTrace = "http-trace"
    case requestShape = "request-shape"
    case responseFields = "response-fields"
    case errorCategory = "error-category"
    case hostPathShape = "host-path-shape"
    case redactedArtifact = "redacted-artifact"
}

public struct ExternalEvidenceAdmissionDecision: Codable, Sendable, Equatable {
    public var status: ExternalCaptureStatus
    public var canDisplayDiagnostic: Bool
    public var canAnalyze: Bool
    public var canRegisterNativeCapability: Bool
    public var requiredSignals: [ExternalEvidenceSignal]
    public var missingSignals: [ExternalEvidenceSignal]
    public var redactionIssues: [String]
    public var reason: String

    public init(
        status: ExternalCaptureStatus,
        canDisplayDiagnostic: Bool,
        canAnalyze: Bool,
        canRegisterNativeCapability: Bool,
        requiredSignals: [ExternalEvidenceSignal],
        missingSignals: [ExternalEvidenceSignal],
        redactionIssues: [String],
        reason: String
    ) {
        self.status = status
        self.canDisplayDiagnostic = canDisplayDiagnostic
        self.canAnalyze = canAnalyze
        self.canRegisterNativeCapability = canRegisterNativeCapability
        self.requiredSignals = requiredSignals
        self.missingSignals = missingSignals
        self.redactionIssues = redactionIssues
        self.reason = reason
    }
}

public struct ExternalEvidenceAdmissionPolicy: Codable, Sendable, Equatable {
    public var capturedSignals: [ExternalEvidenceSignal]
    public var nativeRewriteSignals: [ExternalEvidenceSignal]

    public init(
        capturedSignals: [ExternalEvidenceSignal] = [
            .requestShape,
            .responseFields,
            .redactedArtifact
        ],
        nativeRewriteSignals: [ExternalEvidenceSignal] = [
            .catVodInputOutput,
            .httpTrace,
            .requestShape,
            .responseFields,
            .errorCategory,
            .hostPathShape,
            .redactedArtifact
        ]
    ) {
        self.capturedSignals = capturedSignals
        self.nativeRewriteSignals = nativeRewriteSignals
    }

    public static let standard = ExternalEvidenceAdmissionPolicy()

    public func evaluate(
        status: ExternalCaptureStatus,
        availableSignals: Set<ExternalEvidenceSignal>,
        redactionIssues: [String] = []
    ) -> ExternalEvidenceAdmissionDecision {
        let required = requiredSignals(for: status)
        let missing = required.filter { !availableSignals.contains($0) }
        let isRedacted = redactionIssues.isEmpty

        let canAnalyze = (status == .captured || status == .nativeRewriteReady)
            && missing.filter { $0 != .redactedArtifact }.isEmpty
            && isRedacted
        let canRegister = status == .nativeRewriteReady
            && missing.isEmpty
            && isRedacted

        return ExternalEvidenceAdmissionDecision(
            status: status,
            canDisplayDiagnostic: true,
            canAnalyze: canAnalyze,
            canRegisterNativeCapability: canRegister,
            requiredSignals: required,
            missingSignals: missing,
            redactionIssues: redactionIssues,
            reason: reason(
                status: status,
                missingSignals: missing,
                redactionIssues: redactionIssues,
                canRegister: canRegister,
                canAnalyze: canAnalyze
            )
        )
    }

    public func evaluate(fixture: ExternalCaptureFixture) -> ExternalEvidenceAdmissionDecision {
        evaluate(
            status: fixture.status,
            availableSignals: fixture.evidenceSignals,
            redactionIssues: ExternalEvidenceRedactionAudit.issues(in: [
                fixture.requestShape,
                fixture.responseFields,
                fixture.httpTraceShape
            ])
        )
    }

    private func requiredSignals(for status: ExternalCaptureStatus) -> [ExternalEvidenceSignal] {
        switch status {
        case .pendingCapture:
            return []
        case .captured:
            return capturedSignals
        case .nativeRewriteReady:
            return nativeRewriteSignals
        case .unsupportedRuntime:
            return [.redactedArtifact]
        }
    }

    private func reason(
        status: ExternalCaptureStatus,
        missingSignals: [ExternalEvidenceSignal],
        redactionIssues: [String],
        canRegister: Bool,
        canAnalyze: Bool
    ) -> String {
        if !redactionIssues.isEmpty {
            return "样本包含未脱敏敏感字段，不能分析或注册原生能力"
        }
        if canRegister {
            return "证据完整，可升格为 Swift 原生 provider 或播放能力"
        }
        if canAnalyze {
            return "样本可分析，但尚未允许注册原生能力"
        }
        if status == .pendingCapture {
            return "等待真实抓包；只能展示待抓包诊断"
        }
        if status == .unsupportedRuntime {
            return "依赖不引入的运行时；只能展示不可用边界"
        }
        if !missingSignals.isEmpty {
            let missing = missingSignals.map(\.rawValue).joined(separator: ", ")
            return "样本缺少升格证据：\(missing)"
        }
        return "样本只能展示诊断"
    }
}

public enum ExternalEvidenceRedactionAudit {
    public static func issues(in dictionaries: [[String: String]]) -> [String] {
        dictionaries.flatMap { dictionary in
            dictionary.compactMap { key, value in
                issue(forKey: key, value: value)
            }
        }
    }

    private static func issue(forKey key: String, value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "<redacted>" else { return nil }
        if isLocalPath(trimmed) {
            return "\(key): local path must be redacted"
        }
        if containsUnredactedAuthorization(trimmed) {
            return "\(key): authorization must be redacted"
        }
        if containsUnredactedSensitiveQuery(trimmed) {
            return "\(key): signed query must be redacted"
        }
        return nil
    }

    private static func isLocalPath(_ value: String) -> Bool {
        value.hasPrefix("file://")
            || value.hasPrefix("/Users/")
            || value.hasPrefix("/private/")
            || value.hasPrefix("/var/")
    }

    private static func containsUnredactedAuthorization(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard lower.contains("authorization") || lower.contains("bearer ") || lower.contains("cookie:") else {
            return false
        }
        return !lower.contains("<redacted>")
    }

    private static func containsUnredactedSensitiveQuery(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), let items = components.queryItems else {
            return false
        }
        return items.contains { item in
            guard isSensitiveQueryName(item.name) else { return false }
            let itemValue = item.value ?? ""
            return itemValue != "<redacted>" && !itemValue.isEmpty
        }
    }

    private static func isSensitiveQueryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "ut"
            || lower.contains("token")
            || lower.contains("auth_key")
            || lower.contains("signature")
            || lower.contains("authorization")
            || lower.contains("cookie")
            || lower.contains("ossaccesskeyid")
            || lower.contains("secret")
    }
}

public extension ExternalCaptureFixture {
    var evidenceSignals: Set<ExternalEvidenceSignal> {
        var signals: Set<ExternalEvidenceSignal> = [.redactedArtifact]
        if !requestShape.isEmpty {
            signals.insert(.requestShape)
        }
        if !responseFields.isEmpty {
            signals.insert(.responseFields)
        }
        if !httpTraceShape.isEmpty {
            signals.insert(.httpTrace)
        }
        if errorCategory != nil {
            signals.insert(.errorCategory)
        }
        if hasHostPathShape {
            signals.insert(.hostPathShape)
        }
        if !catVodMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !requestShape.isEmpty,
           !responseFields.isEmpty {
            signals.insert(.catVodInputOutput)
        }
        return signals
    }

    var admissionDecision: ExternalEvidenceAdmissionDecision {
        ExternalEvidenceAdmissionPolicy.standard.evaluate(fixture: self)
    }

    private var hasHostPathShape: Bool {
        let combined = requestShape.merging(httpTraceShape) { current, _ in current }
        let keys = Set(combined.keys.map { $0.lowercased() })
        let values = Set(combined.values.map { $0.lowercased() })
        let hasHost = keys.contains { $0.contains("host") } || values.contains { $0.contains("host") }
        let hasPath = keys.contains { $0.contains("path") } || values.contains { $0.contains("path") }
        return hasHost && hasPath
    }
}

public extension ExternalCaptureStatus {
    var canDisplayDiagnostic: Bool {
        true
    }

    var canAnalyzeCapturedEvidence: Bool {
        self == .captured || self == .nativeRewriteReady
    }

    var canRegisterNativePlaybackCapability: Bool {
        self == .nativeRewriteReady
    }
}
