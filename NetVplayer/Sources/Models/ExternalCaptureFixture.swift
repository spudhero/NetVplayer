// Models/ExternalCaptureFixture.swift
// Sanitized capture contracts for JS/Guard native rewrite work.

import Foundation

public enum ExternalCaptureStatus: String, Codable, Sendable, Equatable {
    case pendingCapture = "pending-capture"
    case captured
    case nativeRewriteReady = "native-rewrite-ready"
    case unsupportedRuntime = "unsupported-runtime"
}

public struct ExternalCaptureFixture: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var provider: String
    public var sourceKey: String
    public var catVodMethod: String
    public var status: ExternalCaptureStatus
    public var requestShape: [String: String]
    public var responseFields: [String: String]
    public var httpTraceShape: [String: String]
    public var jsHostGaps: [String]
    public var errorCategory: AppFailureCategory?

    enum CodingKeys: String, CodingKey {
        case id, provider, sourceKey, catVodMethod, method, status
        case requestShape, responseFields, httpTraceShape, jsHostGaps, errorCategory
    }

    public init(
        id: String = UUID().uuidString,
        provider: String,
        sourceKey: String = "",
        catVodMethod: String = "",
        status: ExternalCaptureStatus = .pendingCapture,
        requestShape: [String: String] = [:],
        responseFields: [String: String] = [:],
        httpTraceShape: [String: String] = [:],
        jsHostGaps: [String] = [],
        errorCategory: AppFailureCategory? = nil
    ) {
        self.id = id
        self.provider = provider
        self.sourceKey = sourceKey
        self.catVodMethod = catVodMethod
        self.status = status
        self.requestShape = ExternalReferenceFixture.redactedDictionary(requestShape)
        self.responseFields = ExternalReferenceFixture.redactedDictionary(responseFields)
        self.httpTraceShape = ExternalReferenceFixture.redactedDictionary(httpTraceShape)
        self.jsHostGaps = jsHostGaps
        self.errorCategory = errorCategory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        self.sourceKey = try container.decodeIfPresent(String.self, forKey: .sourceKey) ?? ""
        self.catVodMethod = try container.decodeIfPresent(String.self, forKey: .catVodMethod)
            ?? container.decodeIfPresent(String.self, forKey: .method)
            ?? ""
        self.status = try container.decodeIfPresent(ExternalCaptureStatus.self, forKey: .status) ?? .pendingCapture
        self.requestShape = ExternalReferenceFixture.redactedDictionary(try container.decodeIfPresent([String: String].self, forKey: .requestShape) ?? [:])
        self.responseFields = ExternalReferenceFixture.redactedDictionary(try container.decodeIfPresent([String: String].self, forKey: .responseFields) ?? [:])
        self.httpTraceShape = ExternalReferenceFixture.redactedDictionary(try container.decodeIfPresent([String: String].self, forKey: .httpTraceShape) ?? [:])
        self.jsHostGaps = try container.decodeIfPresent([String].self, forKey: .jsHostGaps) ?? []
        self.errorCategory = try container.decodeIfPresent(AppFailureCategory.self, forKey: .errorCategory)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(sourceKey, forKey: .sourceKey)
        try container.encode(catVodMethod, forKey: .catVodMethod)
        try container.encode(status, forKey: .status)
        try container.encode(requestShape, forKey: .requestShape)
        try container.encode(responseFields, forKey: .responseFields)
        try container.encode(httpTraceShape, forKey: .httpTraceShape)
        try container.encode(jsHostGaps, forKey: .jsHostGaps)
        try container.encodeIfPresent(errorCategory, forKey: .errorCategory)
    }

    public var diagnosticSummary: String {
        [provider, sourceKey, catVodMethod, status.rawValue]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " / ")
    }
}

public struct ExternalCaptureFixtureImportIssue: Codable, Sendable, Equatable {
    public var fixtureID: String
    public var provider: String
    public var field: String
    public var message: String

    public init(fixtureID: String, provider: String, field: String, message: String) {
        self.fixtureID = fixtureID
        self.provider = provider
        self.field = field
        self.message = message
    }
}

public struct ExternalCaptureFixtureImportReport: Sendable, Equatable {
    public var fixtures: [ExternalCaptureFixture]
    public var issues: [ExternalCaptureFixtureImportIssue]
    public var statusCounts: [ExternalCaptureStatus: Int]

    public init(
        fixtures: [ExternalCaptureFixture],
        issues: [ExternalCaptureFixtureImportIssue],
        statusCounts: [ExternalCaptureStatus: Int]
    ) {
        self.fixtures = fixtures
        self.issues = issues
        self.statusCounts = statusCounts
    }

    public var isValid: Bool {
        issues.isEmpty
    }
}

public enum ExternalCaptureFixtureImporter {
    public static func decodeAndValidate(
        data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> ExternalCaptureFixtureImportReport {
        validate(try decoder.decode([ExternalCaptureFixture].self, from: data))
    }

    public static func validate(_ fixtures: [ExternalCaptureFixture]) -> ExternalCaptureFixtureImportReport {
        var issues: [ExternalCaptureFixtureImportIssue] = []
        var statusCounts: [ExternalCaptureStatus: Int] = [:]

        for fixture in fixtures {
            statusCounts[fixture.status, default: 0] += 1
            let provider = fixture.provider.trimmingCharacters(in: .whitespacesAndNewlines)
            let method = fixture.catVodMethod.trimmingCharacters(in: .whitespacesAndNewlines)
            if provider.isEmpty {
                issues.append(issue(fixture, field: "provider", message: "provider 不能为空"))
            }
            if method.isEmpty {
                issues.append(issue(fixture, field: "catVodMethod", message: "CatVod method 不能为空"))
            }

            switch fixture.status {
            case .pendingCapture:
                if fixture.requestShape.isEmpty && fixture.httpTraceShape.isEmpty && fixture.jsHostGaps.isEmpty {
                    issues.append(issue(fixture, field: "requestShape", message: "pending fixture 至少需要请求形状、HTTP trace 或 JS 宿主缺口"))
                }
            case .captured, .nativeRewriteReady:
                if fixture.requestShape.isEmpty && fixture.httpTraceShape.isEmpty {
                    issues.append(issue(fixture, field: "requestShape", message: "captured fixture 需要请求或 HTTP trace 形状"))
                }
                if fixture.responseFields.isEmpty {
                    issues.append(issue(fixture, field: "responseFields", message: "captured fixture 需要响应字段摘要"))
                }
            case .unsupportedRuntime:
                if fixture.jsHostGaps.isEmpty && fixture.errorCategory == nil {
                    issues.append(issue(fixture, field: "jsHostGaps", message: "unsupported runtime 需要宿主缺口或错误类别"))
                }
            }

            let admission = fixture.admissionDecision
            for redactionIssue in admission.redactionIssues {
                issues.append(issue(fixture, field: "redaction", message: redactionIssue))
            }
            if fixture.status == .nativeRewriteReady && !admission.canRegisterNativeCapability {
                let missing = admission.missingSignals.map(\.rawValue).joined(separator: ", ")
                issues.append(issue(fixture, field: "evidence", message: "native-rewrite-ready 缺少升格证据：\(missing)"))
            }
        }

        return ExternalCaptureFixtureImportReport(
            fixtures: fixtures,
            issues: issues,
            statusCounts: statusCounts
        )
    }

    private static func issue(
        _ fixture: ExternalCaptureFixture,
        field: String,
        message: String
    ) -> ExternalCaptureFixtureImportIssue {
        ExternalCaptureFixtureImportIssue(
            fixtureID: fixture.id,
            provider: fixture.provider,
            field: field,
            message: message
        )
    }
}
