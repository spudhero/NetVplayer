import Foundation
import Testing
import Models
import Storage
import DriveEngine
import MediaLibraryEngine
@testable import FileServiceEngine

@Suite("Personal cloud directories", .serialized)
struct CloudDirectoryClientTests {
    @Test func accountRefreshPreservesBindingAndRejectsDelayedCrossAccountWrites() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let first = try fixture.preferences.cloudDirectoryAccount(.quark)
        var refreshed = first.values; refreshed["quarkCookie"] = "account-one-refreshed"
        try fixture.preferences.refreshCloudDirectoryAccount(first, values: refreshed)
        let second = try fixture.preferences.cloudDirectoryAccount(.quark)
        #expect(second.binding == first.binding)
        #expect(second.values["quarkCookie"] == "account-one-refreshed")
        try fixture.preferences.refreshCloudDirectoryAccount(first, values: refreshed)
        #expect(try fixture.preferences.cloudDirectoryAccount(.quark) == second)
        try fixture.preferences.saveCredential("account-two", for: "quarkCookie")
        #expect(try fixture.preferences.cloudDirectoryAccount(.quark).binding != first.binding)
        #expect(throws: FileServiceError.self) {
            try fixture.preferences.refreshCloudDirectoryAccount(second, values: refreshed)
        }
        #expect(fixture.preferences.quarkCookie == "account-two")
        try fixture.preferences.saveCredential("", for: "quarkCookie")
        #expect(throws: FileServiceError.self) { try fixture.preferences.cloudDirectoryAccount(.quark) }
        let json = String(decoding: try JSONEncoder().encode(fixture.configuration), as: UTF8.self)
        #expect(!json.contains("account-one") && !json.contains("Cookie"))
        let old = #"{"id":"12345678-1234-1234-1234-123456789012","name":"old","kind":"local","address":"","rootPath":"/","share":"","domain":"","guest":false}"#
        #expect(try JSONDecoder().decode(FileServiceConfiguration.self, from: Data(old.utf8)).cloudDirectory == nil)
    }

    @Test func folderNamesAndPagingReachNestedFilesAndRefreshCredentials() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let calls = Calls()
        let client = try fixture.client(listing: { folder, _, cursor, credential in
            await calls.record("\(folder):\(cursor ?? "first")")
            if folder == "0" {
                return .init(entries: [.init(id: "movies", name: "电影 目录", isDirectory: true)],
                             updatedCredential: .cookie(provider: .quark, value: "refreshed"))
            }
            #expect(credential.secret == "refreshed")
            return cursor == nil
                ? .init(entries: [.init(id: "one", name: "First (2024).mkv", size: 32, isDirectory: false)], nextCursor: "2")
                : .init(entries: [.init(id: "two", name: "Second (2025).mp4", size: 64, isDirectory: false)])
        })
        try await client.connect()
        let entries = try await client.allEntries(path: "/电影 目录")
        #expect(entries.map(\.path) == ["/电影 目录/First (2024).mkv", "/电影 目录/Second (2025).mp4"])
        #expect(try await client.stat(path: entries[1].path).size == 64)
        #expect(try fixture.preferences.cloudDirectoryAccount(.quark).binding == fixture.configuration.cloudDirectory)
        #expect(await calls.values == ["0:first", "movies:first", "movies:2"])
        try fixture.preferences.saveCredential("different-account", for: "quarkCookie")
        await #expect(throws: FileServiceError.self) { try await client.stat(path: entries[1].path) }
    }

    @Test(arguments: ["..", "nested/movie.mkv", "bad\\name", "."])
    func refusesPathsThatCannotBeRepresentedSafely(_ name: String) async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let client = try fixture.client(listing: { _, _, _, _ in
            .init(entries: [.init(id: "unsafe", name: name, isDirectory: true)])
        })
        await #expect(throws: FileServiceError.self) { try await client.connect() }
    }

    @Test func repeatedCursorAndCrossPageNameConflictsFailRatherThanTruncate() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        for conflict in [true, false] {
            let client = try fixture.client(listing: { _, _, cursor, _ in
                .init(entries: [.init(id: conflict && cursor != nil ? "other" : "first", name: "Movie.mkv", isDirectory: false)], nextCursor: "2")
            })
            await #expect(throws: FileServiceError.self) { try await client.allEntries(path: "/") }
        }
    }

    @Test func rescanAcceptsAReplacedFileOnTheSecondPage() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let calls = Calls()
        let client = try fixture.client(listing: { _, _, cursor, _ in
            if cursor == nil {
                _ = await calls.record("scan")
                return .init(entries: [.init(id: "first", name: "First.mkv", isDirectory: false)], nextCursor: "2")
            }
            let round = await calls.values.count
            return .init(entries: [.init(id: "replacement-\(round)", name: "Second.mkv", size: Int64(round), isDirectory: false)])
        })
        #expect(try await client.allEntries(path: "/").last?.size == 1)
        #expect(try await client.allEntries(path: "/").last?.size == 2)
    }

    @Test func multipleConnectionsUseTheLatestAccountCredential() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let calls = Calls()
        let listing: CloudDirectoryClient.Listing = { _, _, _, credential in
            let number = await calls.record(credential.secret)
            try await Task.sleep(for: .milliseconds(20))
            return .init(entries: [], updatedCredential: .cookie(provider: .quark, value: "renewed-\(number)"))
        }
        let first = try fixture.client(listing: listing), second = try fixture.client(listing: listing)
        async let a: Void = first.connect()
        async let b: Void = second.connect()
        _ = try await (a, b)
        #expect(await calls.values == ["account-one", "renewed-1"])
        #expect(fixture.preferences.quarkCookie == "renewed-2")
        #expect(try fixture.preferences.cloudDirectoryAccount(.quark).binding == fixture.configuration.cloudDirectory)
    }

    @Test func expiredDownloadIsResolvedOnceAndByteRangeIsVerified() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let calls = Calls()
        let client = try fixture.client(download: { entry, _ in
            let number = await calls.record("resolve")
            #expect(entry.id == "movie")
            return .init(url: "https://fixture.invalid/\(number).mp4", headers: ["Cookie": "private-cookie"])
        }, transport: .init(requestHandler: { url, method, headers, _ in
            #expect(method == "GET" && headers["Range"] == "bytes=4-7")
            #expect(headers["Cookie"] == "private-cookie")
            if url.lastPathComponent == "1.mp4" { throw FileServiceError.permission("expired") }
            return (Data([4, 5, 6, 7]), HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes 4-7/32"])!)
        }))
        let bytes = try await client.read(path: "/Movie.mkv", range: 4..<8)
        #expect(bytes == Data([4, 5, 6, 7]))
        #expect(await calls.values == ["resolve", "resolve"])
        await client.disconnect()
        await #expect(throws: FileServiceError.self) { try await client.read(path: "/Movie.mkv", range: 4..<8) }
    }

    @Test func accountSwitchDuringDirectoryRequestDiscardsTheResponse() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let preferences = fixture.preferences
        let client = try fixture.client(listing: { _, _, _, _ in
            try preferences.saveCredential("new-account", for: "quarkCookie")
            return .init(entries: [.init(id: "old-file", name: "Old.mkv", isDirectory: false)],
                         updatedCredential: .cookie(provider: .quark, value: "old-refreshed"))
        })
        await #expect(throws: FileServiceError.self) { try await client.allEntries(path: "/") }
        #expect(preferences.quarkCookie == "new-account")
    }

    @Test func originalFileRangesRejectShiftedBytesAndTranscodedPlaylists() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let shifted = try fixture.client(transport: .init(requestHandler: { url, _, _, _ in
            (Data([0, 1, 2, 3]), HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes 0-3/32"])!)
        }))
        await #expect(throws: FileServiceError.self) { try await shifted.read(path: "/Movie.mkv", range: 4..<8) }
        let hls = try fixture.client(download: { _, _ in .init(url: "https://fixture.invalid/video.m3u8") })
        await #expect(throws: FileServiceError.self) { try await hls.resolve(path: "/Movie.mkv") }
    }

    @Test func cloudDirectoryScanProducesPersistentMovieAndEpisodeRecords() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let library = MediaLibraryConfiguration(serviceID: fixture.configuration.id, name: "Cloud library", metadataSource: .local)
        let store = FileServiceStore(storage: StorageManager(storageDirectory: fixture.directory), preferences: fixture.preferences)
        try store.save(.init(services: [fixture.configuration], libraries: [library]))
        let index = MediaIndex(url: fixture.directory.appendingPathComponent("index.sqlite"))
        let client = try fixture.client(listing: { folder, _, _, _ in
            if folder == "0" { return .init(entries: [.init(id: "folder", name: "Shows", isDirectory: true),
                .init(id: "movie", name: "Cloud Movie (2025).mp4", size: 32, isDirectory: false)]) }
            return .init(entries: [.init(id: "ep", name: "Cloud Show.S01E02.mkv", size: 64, isDirectory: false)])
        })
        let scanner = MediaLibraryScanner(index: index, store: store)
        await scanner.scan(library, client: client)
        let records = try await index.records(libraryID: library.id)
        #expect(records.count == 2)
        #expect(records.contains { $0.metadata.title == "Cloud Movie" && $0.metadata.year == 2025 })
        #expect(records.contains { $0.metadata.season == 1 && $0.metadata.episode == 2 })
        #expect(records.allSatisfy { $0.reference.serviceID == fixture.configuration.id && !$0.reference.locator.contains("Cookie") })
        #expect(try await index.lastSuccessfulScan(libraryID: library.id) != nil)
        let reopened = MediaIndex(url: fixture.directory.appendingPathComponent("index.sqlite"))
        #expect(try await reopened.records(libraryID: library.id).count == 2)
    }

    private struct Fixture {
        let domain = "CloudDirectoryTests." + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-directory-" + UUID().uuidString)
        let defaults: UserDefaults
        let preferences: UserPreferences
        let configuration: FileServiceConfiguration
        init() throws {
            defaults = UserDefaults(suiteName: domain)!
            preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
            try preferences.saveCredential("account-one", for: "quarkCookie")
            configuration = .init(name: "Cloud fixture", kind: .cloudDrive,
                cloudDirectory: try preferences.cloudDirectoryAccount(.quark).binding)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func clean() { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        func client(listing: @escaping CloudDirectoryClient.Listing = { _, _, _, _ in
            .init(entries: [.init(id: "movie", name: "Movie.mkv", size: 32, isDirectory: false)])
        }, download: @escaping CloudDirectoryClient.Download = { _, _ in .init(url: "https://fixture.invalid/movie.mp4") },
                    transport: FileHTTPTransport = .init()) throws -> CloudDirectoryClient {
            try .init(configuration: configuration, preferences: preferences, listing: listing, download: download, transport: transport)
        }
    }
    private actor Calls {
        var values: [String] = []
        @discardableResult func record(_ value: String) -> Int { values.append(value); return values.count }
    }
}
