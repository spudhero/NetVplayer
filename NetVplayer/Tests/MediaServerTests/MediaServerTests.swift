import Foundation
import Testing
import Models
import Storage
import Networking
import ProxyServer
import SpiderEngine
@testable import MediaServerEngine

@Suite("Media server contracts (synthetic responses)", .serialized)
struct MediaServerTests {
    @Test(arguments: [MediaServerKind.emby, .jellyfin]) func authenticationAndNestedBase(_ kind: MediaServerKind) async throws {
        let fixture = ServerFixture()
        let account = MediaServerConfiguration(kind: kind, server: "https://server.invalid/nested")
        let client = try MediaServerClient(account: account, transport: .init(handler: { try await fixture.handle($0, limit: $1) }))
        let (connected, token) = try await client.authenticate(username: "same-name", password: "fixture-password")
        #expect(connected.userID == "user1"); #expect(connected.serverID == "server1"); #expect(token == ServerFixture.token)
        try await MediaServerClient(account: connected, token: token, transport: .init(handler: { try await fixture.handle($0, limit: $1) })).validateSession()
        let paths = await fixture.paths
        #expect(paths.allSatisfy { $0.hasPrefix(kind == .emby ? "/nested/emby/" : "/nested/") })
        #expect(await fixture.loginBodyCorrect)
        #expect(await fixture.anonymousCredentialsAbsent)
    }
    @Test func validationAndOpaqueStableIdentity() throws {
        let account = MediaServerConfiguration(name: "Same", server: "https://server.invalid/base", serverID: "s", userID: "u")
        for value in ["https://name:password@server.invalid", "https://server.invalid?api_key=secret", "http://server.invalid", "file:///etc"] {
            var invalid = account; invalid.server = value
            #expect(throws: MediaServerError.self) { try invalid.validated() }
        }
        let ref = try MediaServerReference(accountID: account.id, itemID: "a_b-12")
        #expect(MediaServerReference(locator: ref.locator) == ref)
        #expect(HistoryPersistencePolicy.sanitizedEpisodeLocator(ref.locator) == ref.locator)
        #expect(MediaServerReference(locator: ref.locator + "?token=secret") == nil)
        #expect(throws: MediaServerError.self) { try MediaServerReference(accountID: account.id, itemID: "../escape") }
        var second = account; second.id = UUID()
        #expect(account.identity(itemID: "film").cacheKey != second.identity(itemID: "film").cacheKey)
        second = account; second.userID = "other"
        #expect(account.identity(itemID: "film") != second.identity(itemID: "film"))
    }
    @Test func changedLoginGetsNewAccountNamespace() async throws {
        let fixture = ServerFixture()
        let old = MediaServerConfiguration(server: "https://server.invalid", serverID: "server1", userID: "previous")
        let client = try MediaServerClient(account: old, transport: .init(handler: { try await fixture.handle($0, limit: $1) }))
        let (new, _) = try await client.authenticate(username: "new", password: "fixture-password")
        #expect(new.id != old.id); #expect(new.deviceID == old.deviceID)
    }
    @Test func tokenBindingAndPortableBackupExcludeSecrets() throws {
        let context = try ServerTestContext()
        defer { context.cleanup() }
        let account = context.account
        #expect(try context.store.token(for: account) == ServerFixture.token)
        for mutation in 0..<4 {
            var changed = account
            switch mutation { case 0: changed.server += "/other"; case 1: changed.userID = "other"; case 2: changed.serverID = "other"; default: changed.kind = .emby }
            #expect(throws: MediaServerError.authentication) { try context.store.token(for: changed) }
        }
        let backup = context.storage.makeBackup(includePreferences: false)
        let data = try StorageBackupCodec.encode(backup)
        #expect(!String(decoding: data, as: UTF8.self).contains(ServerFixture.token))
        #expect(try StorageBackupCodec.decode(data).backup.mediaServers == [account])
        let old = try StorageBackupCodec.decode(Data(#"{"schemaVersion":1}"#.utf8)).backup
        #expect(old.mediaServers == nil)
        var changed = account; changed.server = "https://other.invalid"
        try context.storage.restoreBackup(.init(mediaServers: [changed]), restorePreferences: false)
        #expect(context.store.load() == [account])
        #expect(try context.store.token(for: account) == ServerFixture.token)
    }
    @Test func changedServerIdentityNeverReceivesSavedToken() async throws {
        let fixture = ServerFixture(); await fixture.replaceServerIdentity()
        let client = try client(fixture)
        await #expect(throws: MediaServerError.authentication) { try await client.validateSession() }
        #expect(await fixture.paths.count == 1)
        #expect(await fixture.anonymousCredentialsAbsent)
    }
    @Test func sourceURLsNeverCarryServerTokenToCDN() throws {
        let client = try client(ServerFixture())
        let own = try #require(client.mediaRequest("https://server.invalid/media?api_key=" + ServerFixture.token))
        #expect(own.url?.query?.contains(ServerFixture.token) != true)
        #expect(own.value(forHTTPHeaderField: "X-Emby-Token") == ServerFixture.token)
        let cdn = try #require(client.mediaRequest("https://cdn.invalid/nested/%E4%B8%AD%E6%96%87/film.mkv?signature=provider-signature"))
        #expect(cdn.allHTTPHeaderFields?.isEmpty != false)
        #expect(client.mediaRequest("https://cdn.invalid/film?api_key=" + ServerFixture.token) == nil)
        #expect(client.mediaRequest("https://user:password@cdn.invalid/film") == nil)
        #expect(client.mediaRequest("file:///private/film") == nil)
        var proposed = own; proposed.url = cdn.url
        let redirect = try #require(HTTPRedirectPolicy.redirected(own, proposed: proposed, status: 302, hop: 1))
        #expect(redirect.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        #expect(HTTPRedirectPolicy.redirected(own, proposed: proposed, status: 302, allowedOrigin: client.baseURL, hop: 1) == nil)
        let delegate = HTTPRedirectDelegate(initialRequest: own, sensitiveURLValues: [ServerFixture.token])
        proposed.url = URL(string: "https://cdn.invalid/film?api_key=" + ServerFixture.token)
        let task = URLSession.shared.dataTask(with: own)
        let response = try #require(HTTPURLResponse(url: own.url!, statusCode: 302, httpVersion: nil, headerFields: nil))
        #expect(delegate.redirected(task: task, response: response, proposed: proposed) == nil)
        #expect(HTTPRedirectDelegate.url("https://cdn.invalid/?token=synthetic%252Dserver%252Dcredential", contains: ServerFixture.token))
    }
    @Test func directExpiryFallsBackWithoutChangingBytesOrIdentity() async throws {
        let fixture = ServerFixture(), client = try client(fixture)
        let source = MediaServerByteSource(client: client, fallback: client.originalRequest(item: "film", source: "source1", audio: false),
            direct: client.mediaRequest("https://cdn.invalid/nested/film.mkv?signature=expired"), size: Int64(ServerFixture.bytes.count))
        #expect(try await source.read(17..<43) == ServerFixture.bytes.subdata(in: 17..<43))
        #expect(try await source.read(600..<650) == ServerFixture.bytes.subdata(in: 600..<650))
        #expect(await fixture.directRequests == 1); #expect(await fixture.originalRequests == 2)
        #expect(await fixture.cdnCredentialsAbsent)
        await source.close()
        await #expect(throws: MediaServerError.self) { try await source.read(0..<10) }
    }
    @Test(arguments: ["shifted", "short", "ignored", "wrong-size"]) func rejectsMismatchedOriginalRange(_ mode: String) async throws {
        let fixture = ServerFixture(); await fixture.setRangeMode(mode)
        let client = try client(fixture)
        let source = MediaServerByteSource(client: client, fallback: client.originalRequest(item: "film", source: "source1", audio: false), direct: nil, size: Int64(ServerFixture.bytes.count))
        await #expect(throws: MediaServerError.response) { try await source.read(17..<43) }
        await source.close()
    }
    @Test func inFlightReadAndUncooperativeResultAreRetired() async throws {
        let fixture = ServerFixture(); await fixture.delayReads()
        let client = try client(fixture)
        let source = MediaServerByteSource(client: client, fallback: client.originalRequest(item: "film", source: "source1", audio: false), direct: nil, size: Int64(ServerFixture.bytes.count))
        let task = Task { try await source.read(0..<100) }
        try #require(await waitUntil { await fixture.originalRequests > 0 })
        await source.close()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func metadataLibrarySearchAndPagedSeriesKeepItemIDs() async throws {
        let context = try ServerTestContext(); defer { context.cleanup() }
        let fixture = ServerFixture(), runtime = context.runtime(fixture)
        let provider = MediaServerNativeProvider(accountID: context.account.id, runtime: runtime), site = context.account.site()
        #expect(try await provider.homeContent(site: site).types.first?.typeId == "library")
        let list = try await provider.categoryContent(site: site, tid: "library", page: "1", filter: false, extend: [:])
        #expect(list.vod?.vodId == (try MediaServerReference(accountID: context.account.id, itemID: "film")).locator)
        #expect(try await provider.searchContent(site: site, keyword: "中文", quick: false, page: "2").page == 2)
        let series = try MediaServerReference(accountID: context.account.id, itemID: "series")
        let detail = try await provider.detailContent(site: site, id: series.locator)
        #expect(detail.vod?.episodeDetails.count == 53)
        #expect(detail.vod?.episodeDetails.last?.url == (try MediaServerReference(accountID: context.account.id, itemID: "episode52")).locator)
        let other = try MediaServerReference(accountID: UUID(), itemID: "film")
        await #expect(throws: MediaServerError.response) { try await provider.playerContent(site: site, flag: "original", id: other.locator) }
    }
    @Test func foldersStayPagedAndNeverBecomeEpisodeLists() async throws {
        let context = try ServerTestContext(); defer { context.cleanup() }
        let fixture = ServerFixture(), runtime = context.runtime(fixture)
        let provider = MediaServerNativeProvider(accountID: context.account.id, runtime: runtime)
        let site = context.account.site()
        let folders = try await provider.categoryContent(site: site, tid: "folders", page: "1", filter: false, extend: [:])
        let folder = try #require(folders.vod)
        #expect(folder.isFolder)
        #expect(folder.vodPlayUrl.isEmpty && folder.episodeDetails.isEmpty)
        let restored = try JSONDecoder().decode(Vod.self, from: JSONEncoder().encode(folder))
        #expect(restored.isFolder)
        let detail = try await provider.detailContent(site: site, id: folder.vodId)
        #expect(detail.vod?.episodeDetails.isEmpty == true)
        #expect(await fixture.folderPageRequests == 0)
        let page = try await provider.categoryContent(site: site, tid: "folder", page: "2", filter: false, extend: [:])
        #expect(page.list.count == 50 && page.total == 103 && page.pagecount == 3)
        #expect(page.list.first?.vodName == "Film 50")
        #expect(page.list.allSatisfy { !$0.isFolder })
        #expect(await fixture.folderPageRequests == 1)
        let artwork = try #require(MediaServerArtworkReference(locator: page.list[0].vodPic))
        #expect(artwork.item.accountID == context.account.id && artwork.item.itemID == "film50")
        #expect(!page.list[0].vodPic.contains(ServerFixture.token))
    }
    @Test(arguments: [MediaServerKind.emby, .jellyfin]) func artworkUsesBoundedAuthenticatedNativePath(_ kind: MediaServerKind) async throws {
        let context = try ServerTestContext(kind: kind); defer { context.cleanup() }
        let fixture = ServerFixture(), runtime = context.runtime(fixture)
        let reference = try MediaServerArtworkReference(item: .init(accountID: context.account.id, itemID: "film"), tag: "image-tag")
        #expect(try await runtime.artwork(reference) == ServerFixture.bytes)
        #expect(await fixture.imageRequests == 1)
        #expect(await fixture.paths.last == (kind == .emby ? "/emby/Items/film/Images/Primary" : "/Items/film/Images/Primary"))
        let other = try MediaServerArtworkReference(item: .init(accountID: UUID(), itemID: "film"), tag: "image-tag")
        await #expect(throws: MediaServerError.configuration) { try await runtime.artwork(other) }
        #expect(await fixture.imageRequests == 1)
    }
    @Test func artworkRejectsInvalidatedAccountAndChangedServer() async throws {
        let context = try ServerTestContext(); defer { context.cleanup() }
        let fixture = ServerFixture(), runtime = context.runtime(fixture)
        let reference = try MediaServerArtworkReference(item: .init(accountID: context.account.id, itemID: "film"), tag: "image-tag")
        await fixture.delayImages()
        let task = Task { try await runtime.artwork(reference) }
        try #require(await waitUntil { await fixture.imageRequests == 1 })
        await runtime.invalidate(context.account.id)
        await #expect(throws: CancellationError.self) { try await task.value }
        await fixture.replaceServerIdentity()
        await #expect(throws: MediaServerError.authentication) { try await runtime.artwork(reference) }
        #expect(await fixture.imageRequests == 1)
    }
    @Test func artworkLocatorRejectsRemoteURLsAndEmbeddedCredentials() throws {
        let reference = try MediaServerArtworkReference(item: .init(accountID: UUID(), itemID: "film"), tag: "image-tag")
        #expect(MediaServerArtworkReference(locator: reference.locator) == reference)
        for suffix in ["?api_key=secret", "#secret", "/extra", "/", "@Headers=secret"] {
            #expect(MediaServerArtworkReference(locator: reference.locator + suffix) == nil)
        }
        #expect(MediaServerArtworkReference(locator: "https://server.invalid/Items/film/Images/Primary") == nil)
        #expect(throws: MediaServerError.response) { try MediaServerArtworkReference(item: reference.item, tag: "../image") }
    }
    @Test func playerResultOwnsOnlyLocalURLsAndReleasesAllResources() async throws {
        try ProxyServer.shared.start(); defer { ProxyServer.shared.stop() }
        let context = try ServerTestContext(); defer { context.cleanup() }
        let fixture = ServerFixture(), runtime = context.runtime(fixture)
        let result = try await runtime.resolve(.init(accountID: context.account.id, itemID: "film"))
        let server = try #require(result.mediaServer)
        #expect(result.url.contains("127.0.0.1")); #expect(result.header.isEmpty)
        #expect(result.subs.count == 1); #expect(server.resumeSeconds == 12.5)
        #expect(server.chapters.map(\.seconds) == [0, 5])
        #expect(server.identity == context.account.identity(itemID: "film"))
        #expect(server.externalSubtitleIndices[result.subs[0].url] == 3)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!encoded.contains(ServerFixture.token)); #expect(!encoded.contains("PlaySession")); #expect(!encoded.contains("mediaServer"))
        var spec = PlaySpec(url: result.url); spec.mediaServer = server
        #expect(PlaybackMediaIdentity.resolved(for: spec) == server.identity)
        let changed = spec.merging(.init(url: "http://127.0.0.1/new"))
        #expect(changed.mediaServer?.leaseID == server.leaseID)
        await runtime.release(server.leaseID)
        #expect(await runtime.activeLeaseCount == 0)
        await runtime.report(server.leaseID, snapshot: .init(seconds: 40), started: true)
        #expect(await fixture.reports.isEmpty)
        let second = try await runtime.resolve(.init(accountID: context.account.id, itemID: "film"))
        #expect(second.mediaServer?.leaseID != server.leaseID)
        #expect(second.mediaServer?.identity == server.identity)
        await runtime.invalidate(context.account.id)
        #expect(await runtime.activeLeaseCount == 0)
    }
    @Test(arguments: ["RequiresOpening", "IsInfiniteStream", "BluRay", "TranscodeOnly"])
    func unsupportedSourcesNeverBecomeRawFilePlayback(_ mode: String) async throws {
        let context = try ServerTestContext(); defer { context.cleanup() }
        let fixture = ServerFixture(); await fixture.setUnsupportedSource(mode)
        let runtime = context.runtime(fixture)
        await #expect(throws: MediaServerError.originalUnavailable) {
            try await runtime.resolve(.init(accountID: context.account.id, itemID: "film"))
        }
        #expect(await runtime.activeLeaseCount == 0)
        #expect(await fixture.originalRequests == 0)
    }
    @Test(arguments: [true, false]) func invalidatedAccountDuringResolutionLeavesNoLease(_ removeAccount: Bool) async throws {
        try ProxyServer.shared.start(); defer { ProxyServer.shared.stop() }
        let context = try ServerTestContext(); defer { context.cleanup() }
        let fixture = ServerFixture(); await fixture.delayPlaybackInfo()
        let runtime = context.runtime(fixture)
        let reference = try MediaServerReference(accountID: context.account.id, itemID: "film")
        let task = Task { try await runtime.resolve(reference) }
        try #require(await waitUntil { await fixture.playbackRequests > 0 })
        if removeAccount { try context.store.save([]) }
        else { await runtime.invalidate(context.account.id) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await runtime.activeLeaseCount == 0)
    }
    @Test func reporterOrdersStartCoalescedProgressAndTerminalStop() async throws {
        let fixture = ServerFixture(); await fixture.holdReports()
        let reporter = MediaServerPlaybackReporter(client: try client(fixture), itemID: "film", sourceID: "source1", sessionID: "session1")
        await reporter.update(.init(seconds: 12.5), start: true)
        let didStart = await waitUntil { await fixture.reports.count == 1 }
        if !didStart { await fixture.releaseReports() }
        try #require(didStart)
        for value in 1...100 { await reporter.update(.init(seconds: Double(value * 10), paused: value % 2 == 0)) }
        await reporter.stop(.init(seconds: 77, paused: true))
        await reporter.update(.init(seconds: 999), start: true)
        #expect(await fixture.reports.count == 1)
        await fixture.releaseReports()
        try #require(await waitUntil { await reporter.idle })
        let reports = await fixture.reports
        #expect(reports.first?.path.hasSuffix("/Sessions/Playing") == true)
        #expect(reports.last?.path.hasSuffix("/Stopped") == true)
        try #require(reports.count == 3)
        #expect(reports[1].path.hasSuffix("/Progress"))
        #expect(reports[1].ticks == 10_000_000_000)
        #expect(reports.last?.ticks == 770_000_000)
        #expect(reports.allSatisfy { $0.session == "session1" })
        #expect(await reporter.failures == 0)
    }
    @Test func normalTicksAreThrottledAndPauseIsImmediate() async throws {
        let fixture = ServerFixture()
        let reporter = MediaServerPlaybackReporter(client: try client(fixture), itemID: "film", sourceID: "source1", sessionID: "session")
        await reporter.update(.init(), start: true)
        try #require(await waitUntil { await reporter.idle })
        for value in 1...20 { await reporter.update(.init(seconds: Double(value) / 4)) }
        #expect(await fixture.reports.count == 1)
        await reporter.update(.init(seconds: 5, paused: true, audioIndex: 2, subtitleIndex: -1))
        try #require(await waitUntil { await reporter.idle })
        #expect(await fixture.reports.count == 2)
        await reporter.stop(nil)
        try #require(await waitUntil { await reporter.idle })
    }
    @Test func errorsAndResponseLimitsExcludeRemoteBody() async throws {
        let transport = MediaServerTransport(handler: { request, _ in
            (Data("private server body".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        })
        let request = URLRequest(url: URL(string: "https://server.invalid/?private=true")!)
        await #expect(throws: MediaServerError.http(500)) { try await transport.request(request, maximumBytes: 100) }
        #expect(!MediaServerError.http(500).localizedDescription.contains("private"))
        let large = MediaServerTransport(handler: { request, _ in
            (Data(repeating: 1, count: 9), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: MediaServerError.response) { try await large.request(request, maximumBytes: 8) }
    }
    @Test func snapshotRejectsInvalidTimesAndSeparatesSourceIndex() {
        #expect(MediaServerPlaybackSnapshot(seconds: .nan, volume: 999, rate: .infinity).ticks == 0)
        #expect(MediaServerPlaybackSnapshot(seconds: -1).ticks == 0)
        #expect(MediaServerPlaybackSnapshot(seconds: 1.25, audioIndex: 8).ticks == 12_500_000)
    }
    private func client(_ fixture: ServerFixture) throws -> MediaServerClient {
        try MediaServerClient(account: .init(server: "https://server.invalid", serverID: "server1", userID: "user1"),
            token: ServerFixture.token, transport: .init(handler: { try await fixture.handle($0, limit: $1) }))
    }
}

private struct ServerTestContext {
    let directory: URL
    let defaults: UserDefaults
    let domain: String
    let storage: StorageManager
    let store: MediaServerStore
    let account: MediaServerConfiguration
    init(kind: MediaServerKind = .jellyfin) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-server-contract-" + UUID().uuidString)
        domain = "MediaServerTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: domain)!
        storage = StorageManager(storageDirectory: directory)
        store = MediaServerStore(storage: storage, preferences: UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore()))
        account = .init(name: "Same", kind: kind, server: "https://server.invalid", serverID: "server1", userID: "user1")
        try store.save([account]); try store.saveToken(ServerFixture.token, for: account)
    }
    func runtime(_ fixture: ServerFixture) -> MediaServerRuntime {
        MediaServerRuntime(store: store, transport: .init(handler: { try await fixture.handle($0, limit: $1) }))
    }
    func cleanup() { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
}

private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return await predicate()
}

private actor ServerFixture {
    static let token = "synthetic-server-credential"
    static let bytes = Data((0..<4096).map { UInt8($0 % 251) })
    struct Report: Sendable { let path: String; let ticks: Int64; let session: String }
    var paths: [String] = []
    var folderPageRequests = 0, imageRequests = 0
    private var slowImages = false
    func delayImages() { slowImages = true }
    var directRequests = 0, originalRequests = 0, playbackRequests = 0
    var cdnCredentialsAbsent = true, anonymousCredentialsAbsent = true, loginBodyCorrect = false
    var reports: [Report] = []
    private var serverID = "server1", rangeMode = "normal"
    private var slowRead = false, slowPlayback = false
    private var reportGateClosed = false
    private var reportWaiters: [CheckedContinuation<Void, Never>] = []
    private var unsupportedSource: String?
    func setUnsupportedSource(_ value: String) { unsupportedSource = value }
    func replaceServerIdentity() { serverID = "server2" }
    func setRangeMode(_ value: String) { rangeMode = value }
    func delayReads() { slowRead = true }
    func delayPlaybackInfo() { slowPlayback = true }
    func holdReports() { reportGateClosed = true }
    func releaseReports() {
        reportGateClosed = false
        let waiters = reportWaiters
        reportWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func handle(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!, path = url.path
        paths.append(path)
        func response(_ object: Any, status: Int = 200) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        if url.host == "cdn.invalid" {
            directRequests += 1
            cdnCredentialsAbsent = cdnCredentialsAbsent && request.value(forHTTPHeaderField: "X-Emby-Token") == nil
            return try response([:], status: 403)
        }
        if path.hasSuffix("/System/Info/Public") {
            anonymousCredentialsAbsent = anonymousCredentialsAbsent && request.value(forHTTPHeaderField: "X-Emby-Token") == nil
            return try response(["Id": serverID])
        }
        if path.hasSuffix("/AuthenticateByName") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            loginBodyCorrect = body["Pw"] == "fixture-password"
            return try response(["AccessToken": Self.token, "User": ["Id": "user1"], "ServerId": serverID])
        }
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == Self.token)
        #expect(!url.absoluteString.contains(Self.token))
        let userPath = path.contains("/emby/") ? "/Users/user1" : "/Users/Me"
        if path.hasSuffix(userPath) { return try response(["Id": "user1"]) }
        if path.hasSuffix("/Views") { return try response(["Items": [["Id": "library", "Name": "Library", "IsFolder": true]]]) }
        if path.hasSuffix("/Episodes") {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let start = Int(query.first { $0.name == "StartIndex" }!.value!)!
            let items = (start..<min(start + 50, 53)).map { ["Id": "episode\($0)", "Name": "Episode \($0)", "Type": "Episode", "IndexNumber": $0 + 1, "ParentIndexNumber": 1] as [String: Any] }
            return try response(["Items": items, "TotalRecordCount": 53])
        }
        if path.hasSuffix("/Images/Primary") {
            imageRequests += 1
            #expect(limit == 4 * 1024 * 1024)
            #expect(request.value(forHTTPHeaderField: "Accept") == "image/*")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains(.init(name: "Tag", value: "image-tag")))
            #expect(query.contains(.init(name: "MaxWidth", value: "800")))
            if slowImages { try? await Task.sleep(for: .milliseconds(100)) }
            return (Self.bytes, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"])!)
        }
        if path.hasSuffix("/Items/folder") { return try response(["Id": "folder", "Name": "00s", "Type": "Folder", "IsFolder": true]) }
        if path.hasSuffix("/Items") {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let parent = query.first { $0.name == "ParentId" }?.value
            if parent == "folders" { return try response(["Items": [["Id": "folder", "Name": "00s", "Type": "Folder", "IsFolder": true]], "TotalRecordCount": 1]) }
            if parent == "folder" {
                folderPageRequests += 1
                #expect(!query.contains { $0.name == "Recursive" && $0.value == "true" })
                let start = Int(query.first { $0.name == "StartIndex" }!.value!)!
                let items = (start..<min(start + 50, 103)).map { ["Id": "film\($0)", "Name": "Film \($0)", "Type": "Movie", "ImageTags": ["Primary": "image-tag"]] as [String: Any] }
                return try response(["Items": items, "TotalRecordCount": 103])
            }
            return try response(["Items": [["Id": "film", "Name": "Film", "Type": "Movie"]], "TotalRecordCount": 51])
        }
        if path.hasSuffix("/Items/series") { return try response(["Id": "series", "Name": "Series", "Type": "Series", "IsFolder": true]) }
        if path.hasSuffix("/Items/film") { return try response(["Id": "film", "Name": "Film", "MediaType": "Video", "Type": "Movie", "RunTimeTicks": 500_000_000,
            "UserData": ["PlaybackPositionTicks": 125_000_000], "Chapters": [["Name": "Start", "StartPositionTicks": 0], ["Name": "Middle", "StartPositionTicks": 50_000_000]]]) }
        if path.hasSuffix("/PlaybackInfo") {
            playbackRequests += 1
            if slowPlayback { try? await Task.sleep(for: .milliseconds(100)) }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            #expect(body["EnableTranscoding"] as? Bool == false)
            var source: [String: Any] = ["Id": "source1", "Size": Self.bytes.count, "SupportsDirectPlay": true,
                "Protocol": "File", "Path": "/nested/中文/Film.mkv", "MediaStreams": [["Index": 3, "Type": "Subtitle", "Codec": "subrip", "Language": "en", "IsExternal": true]]]
            if let mode = unsupportedSource {
                if mode == "BluRay" { source["VideoType"] = "BluRay" }
                else if mode == "TranscodeOnly" { source["SupportsDirectPlay"] = false }
                else { source[mode] = true }
            }
            return try response(["PlaySessionId": "play-session-1", "MediaSources": [source]])
        }
        if path.contains("/Sessions/Playing") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            reports.append(.init(path: path, ticks: (body["PositionTicks"] as! NSNumber).int64Value, session: body["PlaySessionId"] as! String))
            if reportGateClosed { await withCheckedContinuation { reportWaiters.append($0) } }
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        if path.hasSuffix("/Stream.srt") {
            return (Data("1\n00:00:00,000 --> 00:00:30,000\nSynthetic external subtitle\n".utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if path.hasSuffix("/stream") {
            originalRequests += 1
            if slowRead { try? await Task.sleep(for: .milliseconds(100)) }
            let bounds = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-").map { Int($0)! }
            let lower = bounds[0], upper = bounds[1] + 1
            let data = Self.bytes.subdata(in: lower..<upper)
            let advertisedLower = rangeMode == "shifted" ? lower + 1 : lower
            let size = rangeMode == "wrong-size" ? Self.bytes.count + 1 : Self.bytes.count
            return (rangeMode == "short" ? data.dropLast() : data,
                HTTPURLResponse(url: url, statusCode: rangeMode == "ignored" ? 200 : 206, httpVersion: nil,
                    headerFields: ["Content-Range": "bytes \(advertisedLower)-\(upper - 1)/\(size)"])!)
        }
        throw MediaServerError.response
    }
}
