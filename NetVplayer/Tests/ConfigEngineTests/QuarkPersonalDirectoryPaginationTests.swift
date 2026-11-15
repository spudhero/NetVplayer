import Foundation
import Models
import Networking
import Testing
@testable import DriveEngine

private final class QuarkPaginationProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: QuarkPaginationFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.fixture!.reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: reply.body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private final class QuarkPaginationFixture: @unchecked Sendable {
    let scenario: String
    let lock = NSLock()
    private var pages: [Int] = []
    private var mutations = 0
    var requestedPages: [Int] { lock.withLock { pages } }
    var remoteMutations: Int { lock.withLock { mutations } }
    init(_ scenario: String) { self.scenario = scenario }

    func row(_ id: String, name: String? = nil, parent: String = "app-folder", directory: Bool = true) -> [String: Any] {
        ["fid": id, "file_name": name ?? id, "pdir_fid": parent, "dir": directory,
         "file": !directory, "file_type": directory ? 0 : 1, "category": directory ? 0 : 1,
         "size": directory ? 0 : 1234, "format_type": directory ? "" : "video/mp4"]
    }

    func reply(_ request: URLRequest) throws -> (status: Int, body: [String: Any]) {
        if request.httpMethod == "POST", request.url?.path == "/1/clouddrive/file/v2/play" {
            return (200, ["code": 0, "data": ["video_list": [["resolution": "super", "trans_status": "success",
                "video_info": ["url": "https://media.example.test/sample.m3u8"]]]]])
        }
        if request.httpMethod == "POST", request.url?.path == "/1/clouddrive/file/download" {
            return (200, ["code": 0, "data": [["download_url": "https://media.example.test/sample.mp4"]]])
        }
        guard request.httpMethod == "GET" else {
            lock.withLock { mutations += 1 }
            throw URLError(.unsupportedURL)
        }
        guard request.url?.path == "/1/clouddrive/file/sort" else { throw URLError(.unsupportedURL) }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let parent = query.first { $0.name == "pdir_fid" }!.value!
        if parent == "0" {
            return (200, ["code": 0, "metadata": ["_total": 1], "data": ["list": [row("app-folder", name: "NetVplayer", parent: "0")]]])
        }
        if parent == "target-folder" {
            return (200, ["code": 0, "metadata": ["_total": 1], "data": ["list": [row("exact-saved-file", name: "same.mp4", parent: parent, directory: false)]]])
        }
        let page = Int(query.first { $0.name == "_page" }!.value!)!
        lock.withLock { pages.append(page) }
        let firstPage = (0..<100).map { row("item-\($0)") }
        var rows = firstPage
        var total: Int? = scenario == "unknown-total" ? nil : 101
        if scenario == "bound" {
            rows = (0..<100).map { row("item-\((page - 1) * 100 + $0)") }
            total = 3201
        } else if scenario == "short-page" {
            rows = Array(firstPage.dropLast())
        } else if page == 2 {
            switch scenario {
            case "later-folder": rows = [row("target-folder", name: "Film__share-id")]
            case "later-file", "unknown-total": rows = [row("exact-saved-file", name: "same.mp4", directory: false)]
            case "changed-total": rows = [row("last")]; total = 102
            case "repeated-page": rows = firstPage
            case "malformed-row": rows = [["unexpected": "value"]]
            case "wrong-parent": rows = [row("last", parent: "unrelated-folder")]
            case "page-error": return (403, ["code": 403, "message": "fixture rejection"])
            default: throw URLError(.unsupportedURL)
            }
        } else if page != 1 { throw URLError(.unsupportedURL) }
        var result: [String: Any] = ["code": 0, "data": ["list": rows]]
        if let total { result["metadata"] = ["_total": total] }
        return (200, result)
    }
}

@Suite(.serialized)
struct QuarkPersonalDirectoryPaginationTests {
    private func withFixture(_ fixture: QuarkPaginationFixture,
        operation: (QuarkDriveClient, QuarkPlayableFile, QuarkShareRequest, DriveSavedFileRecord) async throws -> Void) async throws {
        await sharedSavedFileStoreTestLock.acquire()
        let cookie = "__uid=quark-pagination-fixture"
        let sourceID = "source-" + UUID().uuidString
        let shareID = fixture.scenario == "later-folder" ? "share-id" : "share-" + UUID().uuidString
        let file = QuarkShareFile(fid: sourceID, name: "same.mp4", pdirFID: "0", category: 1,
            fileType: 1, size: 1234, formatType: "video/mp4", isDirectory: false, isFile: true, shareFIDToken: "fixture")
        let base = DriveSavedFileNaming.identity(provider: .quark, pwdID: shareID, file: file)
        let target = fixture.scenario == "later-folder" ? "target-folder" : "app-folder"
        let identity = base.scoped(account: DriveTransferContext.account(provider: .quark, cookie: cookie), target: target)
        let record = DriveSavedFileRecord(provider: .quark, cacheKey: identity.cacheKey, pwdID: shareID,
            shareFID: sourceID, fidToken: "fixture", size: 1234, originalName: "same.mp4", savedFID: "exact-saved-file",
            savedFileName: "same.mp4", parentFID: target, targetRootFID: target)
        do {
            // TestRuntime directs this shared store to /tmp, never the user's mappings.
            try await DriveSavedFileStore.shared.save(record)
            QuarkPaginationProtocol.fixture = fixture
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [QuarkPaginationProtocol.self]
            configuration.httpCookieStorage = nil
            let client = QuarkDriveClient(httpClient: HTTPClient(session: URLSession(configuration: configuration)).withExplicitProxy(nil))
            let share = QuarkShareRequest(originalURL: "https://pan.quark.cn/s/" + shareID,
                pwdID: shareID, collectionName: fixture.scenario == "later-folder" ? "Film" : "")
            try await operation(client, QuarkPlayableFile(file: file, stoken: "fixture"), share, record)
            #expect(await DriveSavedFileStore.shared.record(for: record.cacheKey) == record)
            try await DriveSavedFileStore.shared.remove(cacheKey: record.cacheKey)
            await sharedSavedFileStoreTestLock.release()
        } catch {
            try? await DriveSavedFileStore.shared.remove(cacheKey: record.cacheKey)
            await sharedSavedFileStoreTestLock.release()
            throw error
        }
    }

    @Test func existingCollectionAfterFirstHundredIsReusedWithoutCreation() async throws {
        let fixture = QuarkPaginationFixture("later-folder")
        try await withFixture(fixture) { client, playable, share, _ in
            let result = try await client.fetchSavedDownloadURLResult(for: playable, share: share, cookie: "__uid=quark-pagination-fixture")
            #expect(result.url == "https://media.example.test/sample.mp4")
            #expect(result.savedFile?.parentFID == "target-folder")
            #expect(result.savedFile?.savedFID == "exact-saved-file")
        }
        #expect(fixture.requestedPages == [1, 2])
        #expect(fixture.remoteMutations == 0)
    }

    @Test(arguments: ["later-file", "unknown-total"])
    func laterFileKeepsExactIDAndSize(scenario: String) async throws {
        let fixture = QuarkPaginationFixture(scenario)
        try await withFixture(fixture) { client, playable, share, _ in
            let result = try await client.fetchSavedDownloadURLResult(for: playable, share: share, cookie: "__uid=quark-pagination-fixture")
            #expect(result.url == "https://media.example.test/sample.mp4")
            #expect(result.savedFile?.savedFID == "exact-saved-file")
            #expect(result.savedFile?.size == 1234)
            #expect(result.savedFile?.parentFID == "app-folder")
        }
        #expect(fixture.requestedPages == [1, 2])
        #expect(fixture.remoteMutations == 0)
    }

    @Test(arguments: ["changed-total", "repeated-page", "malformed-row", "short-page", "wrong-parent"])
    func incompletePagesCannotInvalidateOrReplaceMapping(scenario: String) async throws {
        let fixture = QuarkPaginationFixture(scenario)
        try await withFixture(fixture) { client, playable, share, _ in
            do {
                _ = try await client.fetchSavedDownloadURLResult(for: playable, share: share, cookie: "__uid=quark-pagination-fixture")
                Issue.record("incomplete listing was accepted as file-identity evidence")
            } catch let failure as DriveServiceFailure {
                #expect(failure.reason == .mappingUnconfirmed)
            }
        }
        #expect(fixture.remoteMutations == 0)
        #expect(fixture.requestedPages == (scenario == "short-page" ? [1] : [1, 2]))
    }

    @Test func scanBoundRemainsIncomplete() async throws {
        let fixture = QuarkPaginationFixture("bound")
        try await withFixture(fixture) { client, playable, share, _ in
            do {
                _ = try await client.fetchSavedDownloadURLResult(for: playable, share: share, cookie: "__uid=quark-pagination-fixture")
                Issue.record("bounded scan was accepted as complete")
            } catch let failure as DriveServiceFailure {
                #expect(failure.reason == .mappingUnconfirmed)
            }
        }
        #expect(fixture.requestedPages == Array(1...32))
        #expect(fixture.remoteMutations == 0)
    }

    @Test func laterRequestFailureCannotDeleteOrReplaceMapping() async throws {
        let fixture = QuarkPaginationFixture("page-error")
        try await withFixture(fixture) { client, playable, share, _ in
            do {
                _ = try await client.fetchSavedDownloadURLResult(for: playable, share: share, cookie: "__uid=quark-pagination-fixture")
                Issue.record("failed second page was accepted as file-identity evidence")
            } catch is DriveServiceFailure { }
        }
        #expect(fixture.remoteMutations == 0)
        #expect(fixture.requestedPages == [1, 2])
    }
}
