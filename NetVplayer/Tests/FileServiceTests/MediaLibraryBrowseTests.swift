import Foundation
import Testing
import CSQLite
import Models
import Storage
import MediaLibraryEngine

@Suite("NAS library identity and facets", .serialized)
struct MediaLibraryBrowseTests {
    @Test func stableIdentityCombinesSeasonsAndKeepsRemakesAndMoviesDistinct() throws {
        let service = UUID(), library = UUID()
        var first = try record("one.mkv", metadata: .init(title: "Show Season 1", kind: .television, showTitle: "Show Season 1", season: 1), service: service, library: library)
        var second = try record("two.mkv", metadata: .init(title: "Show 第二季", kind: .television, showTitle: "Show 第二季", season: 2), service: service, library: library)
        first.updateGrouping(); second.updateGrouping()
        #expect(first.groupKey == second.groupKey)
        first.onlineMetadata = .init(title: "中文片名", year: 2011, kind: .television, showTitle: "中文片名", tmdbID: "1399")
        second.onlineMetadata = .init(title: "English alias", year: 2019, kind: .television, showTitle: "English alias", tmdbID: "1399")
        first.updateGrouping(); second.updateGrouping()
        #expect(first.groupKey == second.groupKey)
        second.onlineMetadata.tmdbID = "different"; second.updateGrouping()
        #expect(first.groupKey != second.groupKey)
        first.onlineMetadata = .init(); second.onlineMetadata = .init()
        first.filenameMetadata = .init(title: "Show", year: 2000, kind: .television, showTitle: "Show")
        second.filenameMetadata = .init(title: "Show", year: 2020, kind: .television, showTitle: "Show")
        first.updateGrouping(); second.updateGrouping()
        #expect(first.groupKey != second.groupKey)
        first.filenameMetadata = .init(title: "Film 1", kind: .movies, tmdbID: "1", collection: .init(name: "Family", tmdbID: "100"))
        second.filenameMetadata = .init(title: "Film 2", kind: .movies, tmdbID: "2", collection: .init(name: "Family", tmdbID: "100"))
        first.updateGrouping(); second.updateGrouping()
        #expect(first.groupKey != second.groupKey)
    }

    @Test func wholeLibraryFacetsCountTitlesInsteadOfVersionsAndIntersectFilters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let service = UUID(), library = UUID(), scan = UUID()
        for number in 0..<215 {
            var metadata = MediaMetadata(title: String(format: "Film %04d", number), year: 2024, kind: .movies, tmdbID: String(number + 1))
            if number >= 200 {
                metadata.collection = .init(name: "Family", tmdbID: "1000")
                metadata.cast = [.init(name: "Actor", tmdbID: "20"), .init(name: "Actor", tmdbID: "20")]
                metadata.directors = number == 210 ? ["Other Director"] : ["宫崎骏", "宫崎骏 Hayao Miyazaki"]
                metadata.releaseDate = String(format: "%04d-01-01", 2224 - number)
            }
            if number == 214 { metadata.cast = [.init(name: "Other", tmdbID: "30")] }
            try await index.upsert(try record("\(number).mkv", metadata: metadata, service: service, library: library), scanID: scan)
            if number == 200 {
                try await index.upsert(try record("version.mkv", metadata: metadata, service: service, library: library), scanID: scan)
            }
        }
        #expect(try await index.representatives(libraryID: library).count == 100)
        let facets = try await index.facets(libraryID: library)
        #expect(facets.collections == [.init(id: "tmdb:1000", name: "Family", count: 15)])
        #expect(facets.actors.first { $0.id == "tmdb:20" }?.count == 14)
        #expect(facets.directors.first { $0.id == "name:宫崎骏" } == .init(id: "name:宫崎骏", name: "宫崎骏", count: 14))
        #expect(try await index.representatives(libraryID: library, filter: .init(director: "name:宫崎骏")).count == 14)
        let directed = try await index.representatives(libraryID: library, limit: 5, offset: 5,
            filter: .init(collection: "tmdb:1000", actor: "tmdb:20", director: "name:宫崎骏"))
        #expect(directed.count == 5 && directed.allSatisfy { $0.metadata.directors?.contains("宫崎骏") == true })
        #expect(try await index.representatives(libraryID: library,
            filter: .init(collection: "tmdb:1000", actor: "tmdb:20", director: "name:宫崎骏")).count == 13)
        let filtered = try await index.representatives(libraryID: library, filter: .init(collection: "tmdb:1000", actor: "tmdb:20"))
        #expect(filtered.count == 14)
        #expect(filtered.first?.metadata.title == "Film 0213")
        #expect(filtered.last?.metadata.title == "Film 0200")
        let other = try await index.representatives(libraryID: library, filter: .init(collection: "tmdb:1000", actor: "tmdb:30"))
        #expect(other.count == 1 && other.first?.metadata.title == "Film 0214")
        try await index.removeLibrary(library)
        #expect(try await index.facets(libraryID: library) == .init())
    }

    @Test func confirmedMergeRetainsAllSeasonsFilesAndPerEpisodeCorrections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let service = UUID(), library = UUID()
        var records: [MediaRecord] = []
        for season in 1...8 {
            let count = season <= 6 ? 10 : season == 7 ? 7 : 6
            for episode in 1...count {
                let title = season <= 5 ? "冰与火之歌：权力的游戏 Game of Thrones" : season == 6 ? "B与火之歌：Q力的游戏 第六季" : season == 7 ? "权力D游戏S1-S8" : "权力的游戏"
                var item = try record("S\(season)E\(episode).mkv", metadata: .init(title: title, kind: .television, showTitle: title, season: season, episode: episode), service: service, library: library)
                if season == 8 { item.onlineMetadata = .init(title: "权力的游戏", kind: .television, showTitle: "权力的游戏", tmdbID: "1399") }
                item.updateGrouping(); records.append(item)
                try await index.upsert(item, scanID: UUID())
            }
        }
        #expect(try await index.representatives(libraryID: library).count == 4)
        let target = try #require(records.last)
        let changes = try MediaTelevisionMerge.corrections(records: records, target: target)
        #expect(changes.allSatisfy { $0.fields.season == nil && $0.fields.episode == nil })
        try await index.applyCorrections(changes)
        let merged = try #require(try await index.representatives(libraryID: library).first)
        let files = try await index.group(for: merged)
        #expect(files.count == 73 && Set(files.map(\.id)) == Set(records.map(\.id)))
        let vod = MediaLibraryPresentation.vod(record: merged, group: files, site: .init())
        #expect(vod.parseFlags().map(\.name) == (1...8).map { "第 \($0) 季" })
        #expect(vod.parseFlags().map { $0.episodes.count } == [10,10,10,10,10,10,7,6])
        var corrected = records[0]
        corrected.correction = .init(reference: corrected.reference, fields: .init(season: 0, episode: 9))
        let correctedChange = try #require(MediaTelevisionMerge.corrections(records: [corrected], target: target).first)
        #expect(correctedChange.fields.season == 0 && correctedChange.fields.episode == 9)
        var wrongLibrary = target; wrongLibrary.reference.libraryID = UUID()
        #expect(throws: FileServiceError.self) { try MediaTelevisionMerge.corrections(records: records, target: wrongLibrary) }
        var unresolved = target; unresolved.onlineMetadata = .init()
        #expect(throws: FileServiceError.self) { try MediaTelevisionMerge.corrections(records: records, target: unresolved) }
    }

    @Test func batchCorrectionRollsBackOnMissingFileAndOldIndexRegroupsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let index = MediaIndex(url: url), service = UUID(), library = UUID()
        let first = try record("one.mkv", metadata: .init(title: "Alias 1", kind: .television, tmdbID: "1399"), service: service, library: library)
        let second = try record("two.mkv", metadata: .init(title: "Alias 2", kind: .television, tmdbID: "1399"), service: service, library: library)
        try await index.upsert(first, scanID: UUID()); try await index.upsert(second, scanID: UUID())
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "DELETE FROM media_index_meta; DELETE FROM media_browse; DELETE FROM media_facets; UPDATE media SET group_id=id;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let reopened = MediaIndex(url: url)
        #expect(try await reopened.representatives(libraryID: library).count == 1)
        #expect(try await reopened.group(for: first).count == 2)
        let missing = try FileResourceReference(serviceID: service, libraryID: library, path: "/missing.mkv")
        await #expect(throws: MediaIndexError.self) {
            try await reopened.applyCorrections([.init(reference: first.reference, fields: .init(title: "changed")), .init(reference: missing)])
        }
        #expect(try await reopened.record(reference: first.reference)?.correction == nil)
        #expect(try await reopened.group(for: first).count == 2)
    }

    @Test func collectionAndCastIDsAreOptionalAndNFOSetDoesNotReplaceMovieTitle() async throws {
        let provider = TMDBMetadataProvider(credential: .init(kind: .apiKey, value: "fixture")) { url, _ in
            let body = #"{"id":1,"title":"Film","belongs_to_collection":{"id":1000,"name":"Family"},"credits":{"cast":[{"id":20,"name":"Actor"}]}}"#
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let metadata = try await provider.details(id: "1", kind: .movies)
        #expect(metadata.collection == .init(name: "Family", tmdbID: "1000"))
        #expect(metadata.cast?.first?.tmdbID == "20")
        let nfo = try NFOMetadataParser.parse(Data("<movie><title>Film</title><set><name>Local Family</name><overview>Collection text</overview></set><actor><name>Actor</name><tmdbid>20</tmdbid></actor></movie>".utf8))
        #expect(nfo.title == "Film" && nfo.collection?.name == "Local Family" && nfo.cast?.first?.tmdbID == "20")
        let old = try JSONDecoder().decode(MediaMetadata.self, from: Data(#"{"title":"Film","cast":[{"name":"Actor"}]}"#.utf8))
        #expect(old.collection == nil && old.cast?.first?.tmdbID == nil)
        #expect(nfo.fillingMissing(from: metadata).collection?.name == "Local Family")
    }

    @Test func versionTwoIndexBackfillsDirectorsAndCorrectionsRefreshTheFacet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let index = MediaIndex(url: url), service = UUID(), library = UUID(), scan = UUID()
        let first = try record("one.mkv", metadata: .init(title: "One", kind: .movies, directors: [" 宫崎骏 Hayao Miyazaki ", "", " / "]), service: service, library: library)
        let removed = try record("removed.mkv", metadata: .init(title: "Removed", kind: .movies, directors: ["Unavailable Director"]), service: service, library: library)
        let foreign = try record("foreign.mkv", metadata: .init(title: "Other library", kind: .movies, directors: ["Foreign Director"]), service: service, library: UUID())
        for file in [first, removed, foreign] { try await index.upsert(file, scanID: scan) }
        // Simulate an existing v2 cache, including unavailable files and the old scan receipt.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "INSERT OR REPLACE INTO media_index_meta VALUES('browse_version','2'); DELETE FROM media_facets WHERE kind='director'; UPDATE media SET available=0 WHERE path='/removed.mkv';", nil, nil, nil) == SQLITE_OK)
        let reopened = MediaIndex(url: url)
        let key = MediaLibraryIdentity.directorKey("宫崎骏")
        #expect(!MediaLibraryFilter(director: key).isEmpty)
        #expect(try await reopened.facets(libraryID: library).directors == [.init(id: key, name: "宫崎骏", count: 1)])
        #expect(try await reopened.representatives(libraryID: library, filter: .init(director: key)).map(\.id) == [first.id])
        let again = MediaIndex(url: url)
        #expect(try await again.facets(libraryID: library).directors.count == 1)
        #expect(try await again.record(reference: first.reference)?.reference == first.reference)
        var receipt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT seen,available,(SELECT value FROM media_index_meta WHERE key='browse_version') FROM media WHERE path='/removed.mkv'", -1, &receipt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(receipt) }
        #expect(sqlite3_step(receipt) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(receipt, 0)) == scan.uuidString)
        #expect(sqlite3_column_int(receipt, 1) == 0)
        #expect(String(cString: sqlite3_column_text(receipt, 2)) == "3")
        try await reopened.applyCorrection(.init(reference: first.reference, fields: .init(directors: ["高畑勋"])))
        #expect(try await reopened.representatives(libraryID: library, filter: .init(director: key)).isEmpty)
        #expect(try await reopened.facets(libraryID: library).directors == [.init(id: MediaLibraryIdentity.directorKey("高畑勋"), name: "高畑勋", count: 1)])
    }

    @Test func bilingualActorAliasesJoinOnlyAnUnambiguousPersonID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let service = UUID(), library = UUID()
        let tmdb = try record("one.mkv", metadata: .init(title: "One", kind: .movies, cast: [.init(name: "成龙", tmdbID: "6384")]), service: service, library: library)
        let douban = try record("two.mkv", metadata: .init(title: "Two", kind: .movies, cast: [.init(name: "成龙 Jackie Chan")]), service: service, library: library)
        try await index.upsert(tmdb, scanID: UUID()); try await index.upsert(douban, scanID: UUID())
        #expect(try await index.facets(libraryID: library).actors == [.init(id: "tmdb:6384", name: "成龙", count: 2)])
        #expect(try await index.representatives(libraryID: library, filter: .init(actor: "tmdb:6384")).count == 2)
        let aliasFilter = MediaLibraryFilter(actor: MediaLibraryIdentity.actorKey(douban.metadata.cast![0]))
        #expect(try await index.canonicalFilter(libraryID: library, filter: aliasFilter).actor == "tmdb:6384")
        #expect(try await index.representatives(libraryID: library, filter: aliasFilter).count == 2)
        let other = try record("three.mkv", metadata: .init(title: "Three", kind: .movies, cast: [.init(name: "成龙", tmdbID: "another")]), service: service, library: library)
        try await index.upsert(other, scanID: UUID())
        #expect(try await index.facets(libraryID: library).actors.count == 3)
        #expect(try await index.representatives(libraryID: library, filter: .init(actor: "tmdb:6384")).count == 1)
        #expect(try await index.representatives(libraryID: library, filter: .init(actor: "tmdb:another")).count == 1)
        #expect(try await index.canonicalFilter(libraryID: library, filter: aliasFilter) == aliasFilter)
        #expect(try await index.representatives(libraryID: library, filter: aliasFilter).count == 1)
    }

    @Test func mergedShowFindsNewestHistoryByExactFileAcrossFormerCards() throws {
        let service = UUID(), library = UUID()
        let first = try record("one.mkv", metadata: .init(title: "Show", kind: .television, showTitle: "Show", season: 1, episode: 1), service: service, library: library)
        let second = try record("two.mkv", metadata: .init(title: "Show", kind: .television, showTitle: "Show", season: 2, episode: 1), service: service, library: library)
        let site = Site(key: "nas")
        let vod = MediaLibraryPresentation.vod(record: first, group: [first, second], site: site)
        let old = History(siteKey: site.key, vodId: first.id, episodeUrl: first.id, createTime: Date(timeIntervalSince1970: 1))
        let recent = History(siteKey: site.key, vodId: second.id, episodeUrl: second.id, position: 120_000, createTime: Date(timeIntervalSince1970: 2))
        #expect(PlaybackLinkage.history(for: vod, activeSiteKey: site.key, items: [old, recent])?.episodeUrl == second.id)
        var foreign = recent; foreign.sourceFingerprint = "another-profile"
        #expect(PlaybackLinkage.history(for: vod, activeSiteKey: site.key, items: [foreign, old])?.episodeUrl == first.id)
        var removed = recent; removed.episodeUrl = "absent"
        #expect(PlaybackLinkage.history(for: vod, activeSiteKey: site.key, items: [removed, old])?.episodeUrl == first.id)
    }

    private func record(_ path: String, metadata: MediaMetadata, service: UUID, library: UUID) throws -> MediaRecord {
        let ref = try FileResourceReference(serviceID: service, libraryID: library, path: "/" + path)
        return .init(reference: ref, entry: .init(path: ref.path, name: path, isDirectory: false), groupKey: "old", filenameMetadata: metadata)
    }
}
