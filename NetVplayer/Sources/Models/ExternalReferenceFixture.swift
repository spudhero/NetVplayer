// Models/ExternalReferenceFixture.swift
// Sanitized behavior fixtures derived from external TVBox/FongMi-style references.

import Foundation

public enum ExternalReferenceFixtureKind: String, Codable, Sendable, Equatable {
    case catVodTVBox
    case omniBoxDrive
    case drivePlayback
    case iBoxVideoSource
}

public struct ExternalReferenceFixture: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: ExternalReferenceFixtureKind
    public var provider: String
    public var scenario: String
    public var requestShape: [String: String]
    public var responseFields: [String: String]
    public var errorCategory: AppFailureCategory?
    public var status: String

    enum CodingKeys: String, CodingKey {
        case id, kind, provider, scenario, requestShape, responseFields, errorCategory, status
    }

    public init(
        id: String = UUID().uuidString,
        kind: ExternalReferenceFixtureKind,
        provider: String,
        scenario: String,
        requestShape: [String: String] = [:],
        responseFields: [String: String] = [:],
        errorCategory: AppFailureCategory? = nil,
        status: String = "pending-capture"
    ) {
        self.id = id
        self.kind = kind
        self.provider = provider
        self.scenario = scenario
        self.requestShape = Self.redactedDictionary(requestShape)
        self.responseFields = Self.redactedDictionary(responseFields)
        self.errorCategory = errorCategory
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.kind = try container.decode(ExternalReferenceFixtureKind.self, forKey: .kind)
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        self.scenario = try container.decodeIfPresent(String.self, forKey: .scenario) ?? ""
        let requestShape = try container.decodeIfPresent([String: String].self, forKey: .requestShape) ?? [:]
        let responseFields = try container.decodeIfPresent([String: String].self, forKey: .responseFields) ?? [:]
        self.requestShape = Self.redactedDictionary(requestShape)
        self.responseFields = Self.redactedDictionary(responseFields)
        self.errorCategory = try container.decodeIfPresent(AppFailureCategory.self, forKey: .errorCategory)
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "pending-capture"
    }

    public var diagnosticSummary: String {
        [provider, scenario, status].filter { !$0.isEmpty }.joined(separator: " / ")
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
        return lower.contains("cookie")
            || lower.contains("token")
            || lower.contains("authorization")
            || lower.contains("auth_key")
            || lower.contains("signature")
            || lower.contains("callback")
            || lower.contains("ossaccesskeyid")
            || lower.contains("secret")
    }
}

public struct ExternalReferenceFixtureCorpusReport: Sendable, Equatable {
    public var fixtureCount: Int
    public var statusCounts: [String: Int]
    public var missingRequiredScenarios: [String]

    public init(
        fixtureCount: Int,
        statusCounts: [String: Int],
        missingRequiredScenarios: [String]
    ) {
        self.fixtureCount = fixtureCount
        self.statusCounts = statusCounts
        self.missingRequiredScenarios = missingRequiredScenarios
    }

    public var isCompleteForOfflineReplay: Bool {
        missingRequiredScenarios.isEmpty
    }
}

public enum ExternalReferenceFixtureCorpus {
    public static let requiredScenarios: [ExternalReferenceFixtureKind: Set<String>] = [
        .catVodTVBox: [
            "directory-list",
            "directory-tree",
            "dash-playback",
            "unsupported-binary-boundary",
            "manual-search-cache",
            "live-push-local-contracts"
        ],
        .omniBoxDrive: [
            "share-url",
            "directory-tree",
            "grouped-search",
            "invalid-or-uncaptured-public-share"
        ],
        .drivePlayback: [
            "unsupported-playback-metadata"
        ],
        .iBoxVideoSource: [
            "cms-list-detail-search-player",
            "app-api-filter-detail-source",
            "vip-parse-url-header",
            "unverified-site-diagnostic"
        ]
    ]

    public static func report(for fixtures: [ExternalReferenceFixture]) -> ExternalReferenceFixtureCorpusReport {
        let statusCounts = fixtures.reduce(into: [String: Int]()) { result, fixture in
            result[fixture.status, default: 0] += 1
        }
        let missing = requiredScenarios.flatMap { kind, scenarios -> [String] in
            let present = Set(fixtures.filter { $0.kind == kind }.map(\.scenario))
            return scenarios
                .subtracting(present)
                .sorted()
                .map { "\(kind.rawValue):\($0)" }
        }
        return ExternalReferenceFixtureCorpusReport(
            fixtureCount: fixtures.count,
            statusCounts: statusCounts,
            missingRequiredScenarios: missing.sorted()
        )
    }
}
