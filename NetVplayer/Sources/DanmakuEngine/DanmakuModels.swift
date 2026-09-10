// DanmakuEngine/DanmakuModels.swift
// Native danmaku search/cache contracts. Rendering is intentionally out of v1.

import Foundation

public enum DanmakuParserType: String, Codable, Sendable, CaseIterable {
    case xml
    case json
    case text
    case bilibiliXML
}

public enum DanmakuTrackFormat: String, Codable, Sendable {
    case xml
    case json
    case text
}

public struct DanmakuStyle: Codable, Sendable, Equatable {
    public var opacity: Double
    public var fontSize: Int
    public var displayArea: Double
    public var speed: Double

    public static let `default` = DanmakuStyle(opacity: 0.8, fontSize: 36, displayArea: 0.5, speed: 1.0)

    public init(opacity: Double = 0.8, fontSize: Int = 36, displayArea: Double = 0.5, speed: Double = 1.0) {
        self.opacity = min(1, max(0, opacity))
        self.fontSize = min(72, max(18, fontSize))
        self.displayArea = min(1, max(0.25, displayArea))
        self.speed = min(3, max(0.5, speed))
    }
}

public struct DanmakuSource: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var apiURL: String
    public var enabled: Bool
    public var headers: [String: String]
    public var queryTemplate: String
    public var parserType: DanmakuParserType

    public init(
        id: String,
        name: String,
        apiURL: String,
        enabled: Bool = false,
        headers: [String: String] = [:],
        queryTemplate: String = "",
        parserType: DanmakuParserType = .xml
    ) {
        self.id = id
        self.name = name
        self.apiURL = apiURL
        self.enabled = enabled
        self.headers = headers
        self.queryTemplate = queryTemplate
        self.parserType = parserType
    }

    enum CodingKeys: String, CodingKey {
        case id, name, apiURL, apiUrl, enabled, headers, queryTemplate, parserType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        let decodedAPIURL = try container.decodeIfPresent(String.self, forKey: .apiURL)
            ?? container.decodeIfPresent(String.self, forKey: .apiUrl)
            ?? ""
        self.name = decodedName
        self.apiURL = decodedAPIURL
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? Self.defaultID(name: decodedName, apiURL: decodedAPIURL)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.queryTemplate = try container.decodeIfPresent(String.self, forKey: .queryTemplate) ?? ""
        self.parserType = try container.decodeIfPresent(DanmakuParserType.self, forKey: .parserType) ?? .xml
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(apiURL, forKey: .apiURL)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(headers, forKey: .headers)
        try container.encode(queryTemplate, forKey: .queryTemplate)
        try container.encode(parserType, forKey: .parserType)
    }

    private static func defaultID(name: String, apiURL: String) -> String {
        let slug = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        if !slug.isEmpty { return slug }
        return apiURL
    }
}

public struct DanmakuSearchRequest: Codable, Sendable, Equatable {
    public var title: String
    public var season: Int?
    public var episode: Int?
    public var year: Int?
    public var siteKey: String
    public var manualKeyword: String

    public init(
        title: String,
        season: Int? = nil,
        episode: Int? = nil,
        year: Int? = nil,
        siteKey: String = "",
        manualKeyword: String = ""
    ) {
        self.title = title
        self.season = season
        self.episode = episode
        self.year = year
        self.siteKey = siteKey
        self.manualKeyword = manualKeyword
    }

    public var effectiveKeyword: String {
        let manual = manualKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return manual.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : manual
    }

    public func cacheKey(sourceID: String) -> String {
        [
            sourceID,
            effectiveKeyword.lowercased(),
            season.map { "s\($0)" } ?? "s-",
            episode.map { "e\($0)" } ?? "e-",
            year.map { "y\($0)" } ?? "y-",
            siteKey
        ]
        .joined(separator: "|")
    }
}

public struct DanmakuTrack: Codable, Sendable, Equatable {
    public var format: DanmakuTrackFormat
    public var contentURL: String
    public var cacheKey: String
    public var offsetMs: Int
    public var style: DanmakuStyle
    public var sourceName: String

    public init(
        format: DanmakuTrackFormat,
        contentURL: String = "",
        cacheKey: String,
        offsetMs: Int = 0,
        style: DanmakuStyle = .default,
        sourceName: String
    ) {
        self.format = format
        self.contentURL = contentURL
        self.cacheKey = cacheKey
        self.offsetMs = offsetMs
        self.style = style
        self.sourceName = sourceName
    }
}

public struct DanmakuMatch: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var season: Int?
    public var episode: Int?
    public var year: Int?
    public var siteKey: String
    public var confidence: Double
    public var track: DanmakuTrack

    public init(
        id: String = UUID().uuidString,
        title: String,
        season: Int? = nil,
        episode: Int? = nil,
        year: Int? = nil,
        siteKey: String = "",
        confidence: Double = 1.0,
        track: DanmakuTrack
    ) {
        self.id = id
        self.title = title
        self.season = season
        self.episode = episode
        self.year = year
        self.siteKey = siteKey
        self.confidence = min(1, max(0, confidence))
        self.track = track
    }
}

public struct DanmakuFixtureReplaySample: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var sourceID: String
    public var sourceName: String
    public var request: DanmakuSearchRequest
    public var format: DanmakuTrackFormat
    public var payload: String

}

public struct DanmakuFixtureReplayResult: Sendable, Equatable {
    public var match: DanmakuMatch
    public var diagnostic: DanmakuPayloadParseDiagnostic

    public init(match: DanmakuMatch, diagnostic: DanmakuPayloadParseDiagnostic) {
        self.match = match
        self.diagnostic = diagnostic
    }
}

public struct DanmakuCacheEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: String { cacheKey }
    public var cacheKey: String
    public var track: DanmakuTrack
    public var payload: String
    public var createdAt: Date
    public var expiresAt: Date?

    public init(
        cacheKey: String,
        track: DanmakuTrack,
        payload: String,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.cacheKey = cacheKey
        self.track = track
        self.payload = payload
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}
