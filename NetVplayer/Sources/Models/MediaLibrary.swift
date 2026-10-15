import Foundation

public struct MediaCastMember: Codable, Equatable, Sendable {
    public var name: String
    public var role: String?
    public var portrait: String?
    public var tmdbID: String?
    public init(name: String, role: String? = nil, portrait: String? = nil, tmdbID: String? = nil) {
        self.name = name; self.role = role; self.portrait = portrait; self.tmdbID = tmdbID
    }
}

public struct MediaCollection: Codable, Equatable, Sendable {
    public var name: String
    public var tmdbID: String?
    public init(name: String, tmdbID: String? = nil) { self.name = name; self.tmdbID = tmdbID }
}

public struct MediaMetadata: Codable, Equatable, Sendable {
    public var title: String?
    public var originalTitle: String?
    public var alternativeTitles: [String]?
    public var year: Int?
    public var kind: MediaLibraryKind?
    public var showTitle: String?
    public var season: Int?
    public var episode: Int?
    public var plot: String?
    public var poster: String?
    public var fanart: String?
    public var tmdbID: String?
    public var doubanID: String?
    public var tmdbRating: Double?
    public var doubanRating: Double?
    public var genres: [String]?
    public var runtimeMinutes: Int?
    public var releaseDate: String?
    public var countries: [String]?
    public var languages: [String]?
    public var studios: [String]?
    public var tagline: String?
    public var directors: [String]?
    public var writers: [String]?
    public var cast: [MediaCastMember]?
    public var collection: MediaCollection?
    /// Marks a completed detail response, including responses with legitimately absent fields.
    public var detailVersion: Int?
    public init(title: String? = nil, originalTitle: String? = nil, alternativeTitles: [String]? = nil, year: Int? = nil, kind: MediaLibraryKind? = nil, showTitle: String? = nil,
                season: Int? = nil, episode: Int? = nil, plot: String? = nil, poster: String? = nil, fanart: String? = nil,
                tmdbID: String? = nil, doubanID: String? = nil, tmdbRating: Double? = nil, doubanRating: Double? = nil,
                genres: [String]? = nil, runtimeMinutes: Int? = nil, releaseDate: String? = nil,
                countries: [String]? = nil, languages: [String]? = nil, studios: [String]? = nil,
                tagline: String? = nil, directors: [String]? = nil, writers: [String]? = nil,
                cast: [MediaCastMember]? = nil, collection: MediaCollection? = nil, detailVersion: Int? = nil) {
        self.title = title; self.originalTitle = originalTitle; self.alternativeTitles = alternativeTitles; self.year = year; self.kind = kind; self.showTitle = showTitle; self.season = season; self.episode = episode
        self.plot = plot; self.poster = poster; self.fanart = fanart; self.tmdbID = tmdbID; self.doubanID = doubanID
        self.tmdbRating = tmdbRating; self.doubanRating = doubanRating
        self.genres = genres; self.runtimeMinutes = runtimeMinutes; self.releaseDate = releaseDate
        self.countries = countries; self.languages = languages; self.studios = studios; self.tagline = tagline
        self.directors = directors; self.writers = writers; self.cast = cast; self.collection = collection; self.detailVersion = detailVersion
    }
    /// The receiver has priority; only missing fields come from the lower-priority source.
    public func fillingMissing(from other: Self) -> Self {
        Self(title: title ?? other.title, originalTitle: originalTitle ?? other.originalTitle, alternativeTitles: alternativeTitles ?? other.alternativeTitles, year: year ?? other.year, kind: kind ?? other.kind,
             showTitle: showTitle ?? other.showTitle, season: season ?? other.season, episode: episode ?? other.episode,
             plot: plot ?? other.plot, poster: poster ?? other.poster, fanart: fanart ?? other.fanart,
             tmdbID: tmdbID ?? other.tmdbID, doubanID: doubanID ?? other.doubanID,
             tmdbRating: tmdbRating ?? other.tmdbRating, doubanRating: doubanRating ?? other.doubanRating,
             genres: genres ?? other.genres, runtimeMinutes: runtimeMinutes ?? other.runtimeMinutes,
             releaseDate: releaseDate ?? other.releaseDate, countries: countries ?? other.countries,
             languages: languages ?? other.languages, studios: studios ?? other.studios, tagline: tagline ?? other.tagline,
             directors: directors ?? other.directors, writers: writers ?? other.writers, cast: cast ?? other.cast,
             collection: collection ?? other.collection,
             detailVersion: detailVersion ?? other.detailVersion)
    }
}

public struct MetadataCandidate: Codable, Identifiable, Equatable, Sendable {
    public var source: MetadataSource
    public var metadata: MediaMetadata
    public var id: String { source.rawValue + ":" + (source == .tmdb ? metadata.tmdbID ?? "" : metadata.doubanID ?? "") }
    public init(source: MetadataSource, metadata: MediaMetadata) { self.source = source; self.metadata = metadata }
}

public struct MediaManualCorrection: Codable, Identifiable, Equatable, Sendable {
    public var reference: FileResourceReference
    public var fields: MediaMetadata
    public var selectedCandidate: MetadataCandidate?
    public var id: String { reference.locator }
    public init(reference: FileResourceReference, fields: MediaMetadata = .init(), selectedCandidate: MetadataCandidate? = nil) {
        self.reference = reference; self.fields = fields; self.selectedCandidate = selectedCandidate
    }
}

public struct MediaRecord: Codable, Identifiable, Equatable, Sendable {
    public var reference: FileResourceReference
    public var entry: FileEntry
    public var groupKey: String
    public var filenameMetadata: MediaMetadata
    public var localMetadata: MediaMetadata
    public var onlineMetadata: MediaMetadata
    public var correction: MediaManualCorrection?
    public var candidates: [MetadataCandidate]
    public var metadataError: String?
    public var metadataSource: MetadataSource?
    public var sidecarVersion: String?
    public var id: String { reference.locator }
    public var metadata: MediaMetadata {
        (correction?.fields ?? .init()).fillingMissing(from: localMetadata)
            .fillingMissing(from: metadataSource == .local ? .init() : onlineMetadata).fillingMissing(from: filenameMetadata)
    }
    public mutating func updateGrouping() {
        let value = metadata
        let title = value.kind == .television ? value.showTitle ?? value.title ?? entry.name : value.title ?? entry.name
        let kind = (value.kind ?? .movies).rawValue
        if let id = value.tmdbID, !id.isEmpty,
           candidates.isEmpty || correction?.fields.tmdbID != nil || localMetadata.tmdbID != nil {
            groupKey = kind + ":tmdb:" + id
        } else if let id = value.doubanID, !id.isEmpty,
                  candidates.isEmpty || correction?.fields.doubanID != nil || localMetadata.doubanID != nil {
            groupKey = kind + ":douban:" + id
        } else {
            let base = value.kind == .television ? MediaLibraryIdentity.showTitle(title) : title
            groupKey = kind + ":" + MediaLibraryIdentity.normalized(base) + ":\(value.year ?? 0)"
        }
    }
    public init(reference: FileResourceReference, entry: FileEntry, groupKey: String, filenameMetadata: MediaMetadata,
                localMetadata: MediaMetadata = .init(), onlineMetadata: MediaMetadata = .init(),
                correction: MediaManualCorrection? = nil, candidates: [MetadataCandidate] = [], metadataError: String? = nil,
                metadataSource: MetadataSource? = nil, sidecarVersion: String? = nil) {
        self.reference = reference; self.entry = entry; self.groupKey = groupKey; self.filenameMetadata = filenameMetadata
        self.localMetadata = localMetadata; self.onlineMetadata = onlineMetadata; self.correction = correction
        self.candidates = candidates; self.metadataError = metadataError; self.metadataSource = metadataSource
        self.sidecarVersion = sidecarVersion
    }
}

public struct MediaScanProgress: Equatable, Sendable {
    public var libraryID: UUID
    public var files: Int
    public var directories: Int
    public var currentPath: String
    public var failedDirectories: [String]
    public var isRunning: Bool
    public var message: String?
    public init(libraryID: UUID, files: Int = 0, directories: Int = 0, currentPath: String = "/", failedDirectories: [String] = [], isRunning: Bool = true, message: String? = nil) {
        self.libraryID = libraryID; self.files = files; self.directories = directories; self.currentPath = currentPath
        self.failedDirectories = failedDirectories; self.isRunning = isRunning; self.message = message
    }
}

public struct MetadataMatchProgress: Equatable, Sendable {
    public var libraryID: UUID
    public var completed: Int
    public var total: Int
    public var matched = 0
    public var needsConfirmation = 0
    public var unmatched = 0
    public var isRunning: Bool
    public var message: String
    public init(libraryID: UUID, completed: Int = 0, total: Int, isRunning: Bool = true, message: String = "正在匹配影视信息") {
        self.libraryID = libraryID; self.completed = completed; self.total = total
        self.isRunning = isRunning; self.message = message
    }
}
