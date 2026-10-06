import Foundation
import Testing
import Models
import Storage
import FileServiceEngine
import MediaLibraryEngine

@Suite("Media library", .serialized)
struct MediaLibraryTests {
    @Test func filenamesAndSafeNFO() throws {
        let movie = MediaFilenameParser.parse(path: "/Movie.Name.(2024).2160p.BluRay.mkv", libraryKind: .mixed)
        #expect(movie.title == "Movie Name"); #expect(movie.year == 2024); #expect(movie.kind == .movies)
        let show = MediaFilenameParser.parse(path: "/Example.Show.S02E03.1080p.mkv", libraryKind: .mixed)
        #expect(show.title == "Example Show"); #expect(show.season == 2); #expect(show.episode == 3)
        let nfo = Data("<movie><title>本地片名</title><year>2000</year><uniqueid type=\"tmdb\">123</uniqueid><uniqueid type=\"douban\">1292052</uniqueid><ratings><rating name=\"douban\"><value>9.7</value></rating><rating name=\"tmdb\"><value>8.7</value></rating></ratings><plot><![CDATA[简介]]></plot></movie>".utf8)
        let metadata = try NFOMetadataParser.parse(nfo)
        #expect(metadata.title == "本地片名"); #expect(metadata.tmdbID == "123"); #expect(metadata.doubanID == "1292052")
        #expect(metadata.tmdbRating == 8.7); #expect(metadata.doubanRating == 9.7); #expect(metadata.plot == "简介")
        #expect(throws: FileServiceError.self) { try NFOMetadataParser.parse(Data("<!DOCTYPE movie [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><movie><title>&x;</title></movie>".utf8)) }
        #expect(throws: FileServiceError.self) { try NFOMetadataParser.parse(Data(repeating: 32, count: NFOMetadataParser.maximumBytes + 1)) }
    }
    @Test func precedenceSourceIsolationAndMatchingAmbiguity() throws {
        let reference = try FileResourceReference(serviceID: UUID(), libraryID: UUID(), path: "/Movie (2024).mkv")
        var record = MediaRecord(reference: reference, entry: .init(path: reference.path, name: "Movie (2024).mkv", isDirectory: false), groupKey: "movie", filenameMetadata: .init(title: "Movie", year: 2024),
            localMetadata: .init(title: "本地", doubanRating: 9.7), onlineMetadata: .init(title: "线上", tmdbRating: 8.1))
        record.correction = .init(reference: reference, fields: .init(title: "手动"))
        #expect(record.metadata.title == "手动"); #expect(record.metadata.tmdbRating == 8.1); #expect(record.metadata.doubanRating == 9.7)
        record.metadataSource = .local
        #expect(record.metadata.tmdbRating == nil); #expect(record.metadata.doubanRating == 9.7)
        let candidates = [MetadataCandidate(source: .douban, metadata: .init(title: "Movie", year: 2024, kind: .movies, doubanID: "1"))]
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "Movie", year: 2024, kind: .movies) != nil)
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates + candidates, title: "Movie", year: 2024, kind: .movies) == nil)
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "Movie", year: nil, kind: .movies) != nil)
        let remake = MetadataCandidate(source: .douban, metadata: .init(title: "Movie", year: 2000, kind: .movies, doubanID: "2"))
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates + [remake], title: "Movie", year: nil, kind: .movies) == nil)
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "Movie", year: 2000, kind: .movies) == nil)
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "Movie", year: 2024, kind: .television) == nil)
    }
    @Test func originalTitlePreservesOldIndexesAndFieldPrecedence() throws {
        let old = try JSONDecoder().decode(MediaMetadata.self, from: Data(#"{"title":"旧片名","year":2024}"#.utf8))
        #expect(old.originalTitle == nil)
        let online = MediaMetadata(title: "中文片名", originalTitle: "Original Title", year: 2024)
        #expect(try JSONDecoder().decode(MediaMetadata.self, from: JSONEncoder().encode(online)) == online)
        #expect(old.fillingMissing(from: online).title == "旧片名")
        #expect(old.fillingMissing(from: online).originalTitle == "Original Title")
    }
    @Test func mixedLibrarySeasonsVersionsIncrementalFailureAndLocks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = MediaIndex(url: folder.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "混合", metadataSource: .local)
        let fixture = LibraryFixture()
        await fixture.set(path: "/", files: ["Movie (2024).1080p.mkv", "Movie (2024).2160p.mkv"], directories: ["Show", ".hidden"])
        await fixture.set(path: "/Show", files: ["tvshow.nfo", "Show.S01E01.mkv", "Show.S02E01.mkv"])
        await fixture.setData(path: "/Show/tvshow.nfo", data: Data("<tvshow><title>剧名</title><year>2020</year></tvshow>".utf8))
        let scanner = MediaLibraryScanner(index: index)
        await scanner.scan(library, client: fixture)
        let records = try await index.records(libraryID: library.id)
        #expect(records.count == 4)
        let movies = records.filter { $0.metadata.kind == .movies }
        #expect(Set(movies.map(\.groupKey)).count == 1)
        let show = try #require(records.first { $0.metadata.kind == .television })
        let group = try await index.group(for: show)
        let vod = MediaLibraryPresentation.vod(record: show, group: group, site: .init())
        #expect(vod.vodName == "剧名"); #expect(vod.parseFlags().map(\.name) == ["第 1 季", "第 2 季"])
        let original = try #require(movies.first)
        try await index.applyCorrection(.init(reference: original.reference, fields: .init(title: "锁定片名")))
        await fixture.fail(path: "/Show")
        await fixture.set(path: "/", files: ["Movie (2024).2160p.mkv"], directories: ["Show"])
        await scanner.scan(library, client: fixture)
        #expect(try await index.records(libraryID: library.id).count == 4)
        #expect(try await index.record(reference: original.reference)?.metadata.title == "锁定片名")
        await fixture.clearFailures()
        await scanner.scan(library, client: fixture)
        #expect(try await index.records(libraryID: library.id).count == 3)
        #expect(try await index.lastSuccessfulScan(libraryID: library.id) != nil)
        #expect(await scanner.currentProgress(libraryID: library.id)?.isRunning == false)
        var televisionLibrary = library; televisionLibrary.kind = .television
        await scanner.scan(televisionLibrary, client: fixture)
        #expect(try await index.records(libraryID: library.id).allSatisfy { $0.filenameMetadata.kind == .television })
    }
    @Test func sqliteCacheRestoresAndBackupPreservesCorrections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let index = MediaIndex(url: url)
        let ref = try FileResourceReference(serviceID: UUID(), libraryID: UUID(), path: "/Movie.mkv")
        var record = MediaRecord(reference: ref, entry: .init(path: ref.path, name: "Movie.mkv", isDirectory: false), groupKey: "movie", filenameMetadata: .init(title: "Movie"))
        record.onlineMetadata = .init(title: "缓存标题", tmdbRating: 8.3, doubanRating: 9.2)
        try await index.upsert(record, scanID: UUID())
        let reopened = MediaIndex(url: url)
        #expect(try await reopened.record(reference: ref)?.onlineMetadata == record.onlineMetadata)
        let correction = MediaManualCorrection(reference: ref, fields: .init(title: "手动", poster: "https://example.org/poster.jpg"))
        let backup = StorageBackup(mediaCorrections: [correction])
        #expect(try StorageBackupCodec.decode(StorageBackupCodec.encode(backup)).backup.mediaCorrections == [correction])
    }
    @Test func restoredCatalogClearsOldLocksAndPreservesFileIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = MediaIndex(url: folder.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "恢复", metadataSource: .local)
        let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/Movie.mkv")
        var record = MediaRecord(reference: ref, entry: .init(path: ref.path, name: "Movie.mkv", isDirectory: false),
            groupKey: "movie", filenameMetadata: .init(title: "Movie", kind: .movies), onlineMetadata: .init(title: "在线片名"), metadataSource: .tmdb)
        record.correction = .init(reference: ref, fields: .init(title: "恢复前锁定"))
        let scanID = UUID()
        try await index.upsert(record, scanID: scanID)
        try await index.finishScan(libraryID: library.id, scanID: scanID, succeeded: true)
        try await index.restoreCatalogState(libraries: [library], corrections: [])
        let restored = try #require(try await index.record(reference: ref))
        #expect(restored.id == ref.locator); #expect(restored.correction == nil)
        #expect(restored.metadata.title == "Movie"); #expect(restored.metadataSource == .local)
        #expect(try await index.lastSuccessfulScan(libraryID: library.id) == nil)
        let correction = MediaManualCorrection(reference: ref, fields: .init(title: "备份片名"))
        try await index.restoreCatalogState(libraries: [library], corrections: [correction])
        #expect(try await index.record(reference: ref)?.metadata.title == "备份片名")
        try await index.restoreCatalogState(libraries: [], corrections: [])
        #expect(try await index.records(libraryID: library.id).isEmpty)
    }
    @Test func tenThousandVideosStayPaginated() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = MediaIndex(url: folder.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "性能", metadataSource: .local)
        let fixture = LibraryFixture()
        await fixture.set(path: "/", files: (0..<10000).map { "电影\($0).mkv" })
        let scanner = MediaLibraryScanner(index: index)
        let start = Date()
        await scanner.scan(library, client: fixture)
        let elapsed = Date().timeIntervalSince(start)
        #expect(await scanner.currentProgress(libraryID: library.id)?.files == 10000)
        #expect(try await index.representatives(libraryID: library.id, limit: 100).count == 100)
        #expect(elapsed < 30)
        print("[MEDIA_SCAN_BENCHMARK] 10000 videos: \(String(format: "%.2f", elapsed))s")
    }
}

private actor LibraryFixture: FileServiceClient {
    private var directories: [String: [FileEntry]] = [:]
    private var data: [String: Data] = [:]
    private var failures = Set<String>()
    func set(path: String, files: [String], directories: [String] = []) {
        self.directories[path] = files.map { .init(path: path == "/" ? "/" + $0 : path + "/" + $0, name: $0, isDirectory: false, size: 100, modifiedAt: Date(timeIntervalSince1970: 1)) }
            + directories.map { .init(path: path == "/" ? "/" + $0 : path + "/" + $0, name: $0, isDirectory: true) }
    }
    func setData(path: String, data: Data) {
        self.data[path] = data
        let parent = FileServicePath.parent(path)
        if let i = directories[parent]?.firstIndex(where: { $0.path == path }) { directories[parent]?[i].size = Int64(data.count) }
    }
    func fail(path: String) { failures.insert(path) }
    func clearFailures() { failures = [] }
    func connect() async throws {}
    func list(path: String, cursor: String?) async throws -> FileEntryPage {
        if failures.contains(path) { throw FileServiceError.network("fixture offline") }
        return .init(entries: directories[path] ?? [])
    }
    func stat(path: String) async throws -> FileEntry { throw FileServiceError.path(path) }
    func read(path: String, range: Range<Int64>) async throws -> Data { data[path] ?? Data() }
    func resolve(path: String) async throws -> ResolvedFileResource { throw FileServiceError.path(path) }
}
