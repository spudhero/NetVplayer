// DriveEngine/DrivePlaybackDiagnosticFixture.swift
// Red-line fixture schema for unverifiable cloud-drive playback/provider captures.

import Foundation
import Models

public struct DrivePlaybackDiagnosticFixture: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var provider: String
    public var scenario: String
    public var route: String
    public var qualityRank: Int?
    public var selectedReason: String
    public var candidateSummary: String
    public var sampleStatus: ExternalCaptureStatus
    public var requestShape: [String: String]
    public var responseFields: [String: String]
    public var httpTraceShape: [String: String]
    public var errorCategory: AppFailureCategory?
    public var redactedURL: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, provider, scenario, route, qualityRank, selectedReason, candidateSummary
        case sampleStatus, captureStatus
        case requestShape, responseFields, httpTraceShape, errorCategory, redactedURL, createdAt
    }

    public var evidenceSignals: Set<ExternalEvidenceSignal> {
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
        if !route.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !selectedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !requestShape.isEmpty,
           !responseFields.isEmpty {
            signals.insert(.catVodInputOutput)
        }
        return signals
    }

    public var admissionDecision: ExternalEvidenceAdmissionDecision {
        ExternalEvidenceAdmissionPolicy.standard.evaluate(
            status: sampleStatus,
            availableSignals: evidenceSignals,
            redactionIssues: ExternalEvidenceRedactionAudit.issues(in: [
                requestShape,
                responseFields,
                httpTraceShape,
                ["redactedURL": redactedURL, "candidateSummary": candidateSummary]
            ])
        )
    }

    public init(
        id: String = UUID().uuidString,
        provider: String,
        scenario: String,
        route: String = "",
        qualityRank: Int? = nil,
        selectedReason: String = "",
        candidateSummary: String = "",
        sampleStatus: ExternalCaptureStatus = .pendingCapture,
        requestShape: [String: String] = [:],
        responseFields: [String: String] = [:],
        httpTraceShape: [String: String] = [:],
        errorCategory: AppFailureCategory? = nil,
        url: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.scenario = scenario
        self.route = route
        self.qualityRank = qualityRank
        self.selectedReason = selectedReason
        self.candidateSummary = Self.redactedURL(candidateSummary)
        self.sampleStatus = sampleStatus
        self.requestShape = Self.redactedDictionary(requestShape)
        self.responseFields = Self.redactedDictionary(responseFields)
        self.httpTraceShape = Self.redactedDictionary(httpTraceShape)
        self.errorCategory = errorCategory
        self.redactedURL = Self.redactedURL(url)
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        self.scenario = try container.decodeIfPresent(String.self, forKey: .scenario) ?? ""
        self.route = try container.decodeIfPresent(String.self, forKey: .route) ?? ""
        self.qualityRank = try container.decodeIfPresent(Int.self, forKey: .qualityRank)
        self.selectedReason = try container.decodeIfPresent(String.self, forKey: .selectedReason) ?? ""
        self.candidateSummary = Self.redactedURL(try container.decodeIfPresent(String.self, forKey: .candidateSummary) ?? "")
        self.sampleStatus = try container.decodeIfPresent(ExternalCaptureStatus.self, forKey: .sampleStatus)
            ?? container.decodeIfPresent(ExternalCaptureStatus.self, forKey: .captureStatus)
            ?? .pendingCapture
        self.requestShape = Self.redactedDictionary(try container.decodeIfPresent([String: String].self, forKey: .requestShape) ?? [:])
        self.responseFields = Self.redactedDictionary(try container.decodeIfPresent([String: String].self, forKey: .responseFields) ?? [:])
        self.httpTraceShape = Self.redactedDictionary(try container.decodeIfPresent([String: String].self, forKey: .httpTraceShape) ?? [:])
        self.errorCategory = try container.decodeIfPresent(AppFailureCategory.self, forKey: .errorCategory)
        let rawURL = try container.decodeIfPresent(String.self, forKey: .redactedURL) ?? ""
        self.redactedURL = Self.redactedURL(rawURL)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(scenario, forKey: .scenario)
        try container.encode(route, forKey: .route)
        try container.encodeIfPresent(qualityRank, forKey: .qualityRank)
        try container.encode(selectedReason, forKey: .selectedReason)
        try container.encode(candidateSummary, forKey: .candidateSummary)
        try container.encode(sampleStatus, forKey: .sampleStatus)
        try container.encode(requestShape, forKey: .requestShape)
        try container.encode(responseFields, forKey: .responseFields)
        try container.encode(httpTraceShape, forKey: .httpTraceShape)
        try container.encodeIfPresent(errorCategory, forKey: .errorCategory)
        try container.encode(redactedURL, forKey: .redactedURL)
        try container.encode(createdAt, forKey: .createdAt)
    }

    public static func redactedDictionary(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [:]) { result, entry in
            result[entry.key] = isSensitiveKey(entry.key) ? "<redacted>" : redactedURL(entry.value)
        }
    }

    public static func redactedURL(_ rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("file://"), !trimmed.hasPrefix("/") else { return "<redacted-path>" }
        guard let queryStart = trimmed.firstIndex(of: "?") else { return trimmed }
        let fragmentStart = trimmed[queryStart...].firstIndex(of: "#")
        let queryEnd = fragmentStart ?? trimmed.endIndex
        let prefix = trimmed[..<trimmed.index(after: queryStart)]
        let query = trimmed[trimmed.index(after: queryStart)..<queryEnd]
        let suffix = fragmentStart.map { trimmed[$0...] } ?? ""
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            let separator = pair.firstIndex(of: "=")
            let encodedName = separator.map { pair[..<$0] } ?? pair[...]
            let decodedName = String(encodedName).removingPercentEncoding ?? String(encodedName)
            guard isSensitiveKey(decodedName) else { return String(pair) }
            return "\(encodedName)=<redacted>"
        }
        return String(prefix) + pairs.joined(separator: "&") + String(suffix)
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower == "ut"
            || lower.contains("cookie")
            || lower.contains("token")
            || lower.contains("authorization")
            || lower.contains("auth_key")
            || lower.contains("signature")
            || lower.contains("callback")
            || lower.contains("ossaccesskeyid")
    }

    private var hasHostPathShape: Bool {
        let combined = requestShape
            .merging(responseFields) { current, _ in current }
            .merging(httpTraceShape) { current, _ in current }
        let keys = Set(combined.keys.map { $0.lowercased() })
        let values = Set(combined.values.map { $0.lowercased() })
        let hasHost = keys.contains { $0.contains("host") } || values.contains { $0.contains("host") }
        let hasPath = keys.contains { $0.contains("path") } || values.contains { $0.contains("path") }
        return hasHost && hasPath
    }
}
