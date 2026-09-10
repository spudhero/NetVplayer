// Models/ConfigAggregation.swift
// Diagnostics for multi-config import, URL normalization, and credential requirements.

import Foundation

public enum ConfigEntityType: String, Codable, Sendable {
    case config
    case site
    case parse
    case live
    case rule
    case doh
    case proxy
    case header
}

public enum ConfigNormalizationKind: String, Codable, Sendable {
    case externalArrayFetched
    case externalArrayFailed
    case urlNormalized
    case duplicateRemoved
    case credentialRequired
    case androidRuntimeUnsupported
    case blockedByUser
    case credentialRiskDetected
    case resourceDiagnosticRecorded
}

public struct ConfigFetchedSource: Codable, Sendable, Equatable, Identifiable {
    public var field: String
    public var requestedURL: String
    public var resolvedURL: String
    public var finalURL: String
    public var status: String
    public var itemCount: Int
    public var error: String

    public var id: String {
        [field, requestedURL, resolvedURL, finalURL, status].joined(separator: "::")
    }

    public init(
        field: String,
        requestedURL: String,
        resolvedURL: String,
        finalURL: String = "",
        status: String,
        itemCount: Int = 0,
        error: String = ""
    ) {
        self.field = field
        self.requestedURL = requestedURL
        self.resolvedURL = resolvedURL
        self.finalURL = finalURL
        self.status = status
        self.itemCount = itemCount
        self.error = error
    }
}

public struct ConfigEntityOrigin: Codable, Sendable, Equatable, Identifiable {
    public var entityType: ConfigEntityType
    public var entityKey: String
    public var entityName: String
    public var sourceURL: String
    public var originalKey: String
    public var action: String

    public var id: String {
        [entityType.rawValue, entityKey, entityName, sourceURL, action].joined(separator: "::")
    }

    public init(
        entityType: ConfigEntityType,
        entityKey: String,
        entityName: String = "",
        sourceURL: String,
        originalKey: String = "",
        action: String = "imported"
    ) {
        self.entityType = entityType
        self.entityKey = entityKey
        self.entityName = entityName
        self.sourceURL = sourceURL
        self.originalKey = originalKey
        self.action = action
    }
}

public struct ConfigNormalizationEvent: Codable, Sendable, Equatable, Identifiable {
    public var kind: ConfigNormalizationKind
    public var entityType: ConfigEntityType
    public var entityKey: String
    public var field: String
    public var originalValue: String
    public var normalizedValue: String
    public var reason: String
    public var sourceURL: String

    public var id: String {
        [
            kind.rawValue,
            entityType.rawValue,
            entityKey,
            field,
            originalValue,
            normalizedValue,
            reason
        ].joined(separator: "::")
    }

    public init(
        kind: ConfigNormalizationKind,
        entityType: ConfigEntityType,
        entityKey: String = "",
        field: String = "",
        originalValue: String = "",
        normalizedValue: String = "",
        reason: String = "",
        sourceURL: String = ""
    ) {
        self.kind = kind
        self.entityType = entityType
        self.entityKey = entityKey
        self.field = field
        self.originalValue = originalValue
        self.normalizedValue = normalizedValue
        self.reason = reason
        self.sourceURL = sourceURL
    }
}

public struct ConfigCredentialRequirement: Codable, Sendable, Equatable, Identifiable {
    public var provider: String
    public var siteKey: String
    public var siteName: String
    public var reason: String

    public var id: String {
        [provider, siteKey, siteName, reason].joined(separator: "::")
    }

    public init(
        provider: String,
        siteKey: String,
        siteName: String = "",
        reason: String = ""
    ) {
        self.provider = provider
        self.siteKey = siteKey
        self.siteName = siteName
        self.reason = reason
    }
}

public struct ConfigAggregationSnapshot: Codable, Sendable, Equatable {
    public var rootURL: String
    public var createdAt: Date
    public var fetchedSources: [ConfigFetchedSource]
    public var origins: [ConfigEntityOrigin]
    public var normalizationEvents: [ConfigNormalizationEvent]
    public var credentialRequirements: [ConfigCredentialRequirement]
    public var hygieneDecisions: [SourceHygieneDecision]
    public var credentialRiskAssessments: [CredentialRiskAssessment]
    public var resourceDiagnostics: [ExternalResourceDiagnostic]

    public init(
        rootURL: String = "",
        createdAt: Date = Date(),
        fetchedSources: [ConfigFetchedSource] = [],
        origins: [ConfigEntityOrigin] = [],
        normalizationEvents: [ConfigNormalizationEvent] = [],
        credentialRequirements: [ConfigCredentialRequirement] = [],
        hygieneDecisions: [SourceHygieneDecision] = [],
        credentialRiskAssessments: [CredentialRiskAssessment] = [],
        resourceDiagnostics: [ExternalResourceDiagnostic] = []
    ) {
        self.rootURL = rootURL
        self.createdAt = createdAt
        self.fetchedSources = fetchedSources
        self.origins = origins
        self.normalizationEvents = normalizationEvents
        self.credentialRequirements = credentialRequirements
        self.hygieneDecisions = hygieneDecisions
        self.credentialRiskAssessments = credentialRiskAssessments
        self.resourceDiagnostics = resourceDiagnostics
    }

    public var duplicateCount: Int {
        normalizationEvents.filter { $0.kind == .duplicateRemoved }.count
    }

    public var normalizedURLCount: Int {
        normalizationEvents.filter { $0.kind == .urlNormalized }.count
    }

    public var unsupportedAndroidRuntimeCount: Int {
        normalizationEvents.filter { $0.kind == .androidRuntimeUnsupported }.count
    }

    public var failedExternalSourceCount: Int {
        fetchedSources.filter { !$0.error.isEmpty || $0.status == "failed" }.count
    }

    public var blockedByUserCount: Int {
        hygieneDecisions.count
    }

    public var credentialRiskCount: Int {
        credentialRiskAssessments.filter { $0.riskLevel == .low || $0.riskLevel == .high || $0.riskLevel == .unaudited }.count
    }
}
