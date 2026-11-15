import Foundation
import Models
import Networking
import Testing
@testable import DriveEngine

private final class PersonalDirectoryProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: PersonalDirectoryFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let fixture = Self.fixture!
            let object = try fixture.reply(request)
            let headers = ["Content-Type": "application/json", "Set-Cookie": "__sdid=directory-ut; Path=/"]
            let response = HTTPURLResponse(url: request.url!, statusCode: fixture.denied ? 403 : 200, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class PersonalDirectoryFixture: @unchecked Sendable {
    let provider: DriveProvider
    let malformed: Bool
    let denied: Bool
    let playlist: Bool
    let cancelledBootstrap: Bool
    let repeatMarker: Bool
    private let lock = NSLock()
    private var observed: [String] = []
    var paths: [String] { lock.withLock { observed } }
    init(_ provider: DriveProvider, malformed: Bool = false, denied: Bool = false, playlist: Bool = false,
         cancelledBootstrap: Bool = false, repeatMarker: Bool = false) {
        self.provider = provider; self.malformed = malformed; self.denied = denied; self.playlist = playlist
        self.cancelledBootstrap = cancelledBootstrap; self.repeatMarker = repeatMarker
    }

    func reply(_ request: URLRequest) throws -> [String: Any] {
        let url = request.url!, path = url.path
        lock.withLock { observed.append(path) }
        if denied { return ["code": 403, "message": "forbidden"] }
        let rawBody: Data
        if let data = request.httpBody { rawBody = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            rawBody = data
        } else { rawBody = Data() }
        let body = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any] ?? [:]
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String { query.first { $0.name == key }?.value ?? "" }
        let downloadURL = playlist ? "https://cdn.example.test/video.m3u8" : "https://cdn.example.test/sample.mp4?sign=fixture"
        if path == "/users/v1/users/device/create_session" { return [:] }
        if path == "/v2/account/token" {
            return ["access_token": "new-access", "refresh_token": "new-refresh", "default_drive_id": "drive", "user_id": "user"]
        }
        if path == "/1/clouddrive/share/sharepage/token" {
            if cancelledBootstrap { throw URLError(.cancelled) }
            return ["code": 0, "status": 200, "data": ["stoken": "bootstrap"]]
        }
        if path == "/1/clouddrive/file/download" {
            #expect((body["fids"] as? [String]) == ["last"])
            return ["code": 0, "status": 200, "data": [["fid": "last", "download_url": downloadURL]]]
        }
        if path == "/v2/file/get_download_url" {
            #expect(body["file_id"] as? String == "last")
            #expect(body["drive_id"] as? String == "drive")
            return ["url": downloadURL]
        }
        if path == "/api/mediainfo" {
            #expect(value("path") == "/last.mp4")
            return ["errno": 0, "info": ["dlink": downloadURL, "size": 100]]
        }
        if path == "/open/ufile/downurl" || path == "/app/chrome/downurl" {
            return ["state": true, "data": ["last": ["url": ["url": downloadURL]]]]
        }
        let page: Int
        let limit = provider == .p115 ? 200 : 100
        if path == "/1/clouddrive/file/sort" { page = Int(value("_page")) ?? 0; #expect(value("pdir_fid") == "0") }
        else if path == "/api/list" { page = Int(value("page")) ?? 0; #expect(value("dir") == "/") }
        else if path == "/files" { page = (Int(value("offset")) ?? 0) / limit + 1; #expect(value("cid") == "0") }
        else if path == "/adrive/v3/file/list" { page = body["marker"] == nil ? 1 : 2; #expect(body["parent_file_id"] as? String == "root") }
        else { Issue.record("Unexpected endpoint: \(path)"); throw URLError(.badURL) }
        let entries: [[String: Any]] = malformed ? [["unexpected": "missing identity"]] :
            page == 1 ? (0..<limit).map { item(id: "file-\($0)", folder: $0 == 0) } : [item(id: "last", folder: false)]
        switch provider {
        case .quark, .uc: return ["code": 0, "status": 200, "metadata": ["_total": limit + 1], "data": ["list": entries]]
        case .baidu: return ["errno": 0, "total": limit + 1, "list": entries]
        case .p115: return ["state": true, "count": limit + 1, "data": entries]
        case .ali: return ["items": entries, "next_marker": page == 1 || repeatMarker ? "page-2" : ""]
        default: throw URLError(.unsupportedURL)
        }
    }

    private func item(id: String, folder: Bool) -> [String: Any] {
        let name = folder ? "Movies" : "\(id).mp4"
        switch provider {
        case .quark, .uc: return ["fid": id, "file_name": name, "pdir_fid": "0", "file_type": folder ? 0 : 1,
                                 "dir": folder, "file": !folder, "size": folder ? 0 : 100]
        case .baidu: return ["fs_id": id, "server_filename": name, "path": "/\(name)", "isdir": folder ? 1 : 0, "size": folder ? 0 : 100]
        case .p115:
            // The real web listing represents a directory with cid/pid and omits fid/fc.
            return folder ? ["cid": id, "pid": "0", "n": name] : ["fid": id, "cid": "0", "n": name, "s": 100, "pc": "pick-\(id)"]
        case .ali: return ["file_id": id, "name": name, "parent_file_id": "root", "type": folder ? "folder" : "file", "size": folder ? 0 : 100]
        default: return [:]
        }
    }
}

@Suite(.serialized)
struct PersonalCloudDirectoryTests {
    private func client(_ fixture: PersonalDirectoryFixture) -> PersonalCloudDirectoryClient {
        PersonalDirectoryProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonalDirectoryProtocol.self]
        configuration.httpCookieStorage = nil
        return .init(httpClient: HTTPClient(session: URLSession(configuration: configuration)).withExplicitProxy(nil))
    }
    private func credential(_ provider: DriveProvider, openToken: Bool = true) -> CloudCredential {
        if provider == .ali {
            return .init(provider: .ali, kind: .accessToken, secret: "access", accessToken: "access",
                metadata: ["default_drive_id": "drive", "user_id": "user", "ali_auth_domain": "auth.alipan.com", "sentinel": "kept"])
        }
        return .init(provider: provider, kind: .cookie, secret: "UID=123_fixture; BDUSS=fixture; __pus=fixture",
            metadata: provider == .p115 && openToken ? ["access_token": "open-token", "sentinel": "kept"] : ["sentinel": "kept"])
    }

    @Test(arguments: PersonalCloudDirectoryClient.supportedProviders)
    func listsAllPagesAndDownloadsWithoutCloudFileMutations(provider: DriveProvider) async throws {
        let fixture = PersonalDirectoryFixture(provider), client = client(fixture), credential = credential(provider)
        let first = try await client.list(folderID: PersonalCloudDirectoryClient.rootID(for: provider), credential: credential)
        #expect(first.entries.count == (provider == .p115 ? 200 : 100))
        #expect(first.entries.first?.isDirectory == true)
        let cursor = try #require(first.nextCursor)
        let last = try await client.list(folderID: PersonalCloudDirectoryClient.rootID(for: provider), driveID: first.driveID,
            cursor: cursor, credential: first.updatedCredential ?? credential)
        #expect(last.nextCursor == nil)
        let file = try #require(last.entries.first)
        #expect(file.id == "last")
        #expect(file.name == "last.mp4")
        #expect(file.size == 100)
        let link = try await client.download(entry: file, credential: last.updatedCredential ?? first.updatedCredential ?? credential)
        #expect(link.url == "https://cdn.example.test/sample.mp4?sign=fixture")
        #expect(link.metadata[DrivePlaybackMetadataKey.temporarySavedFile] == "false")
        if let updated = link.updatedCredential ?? last.updatedCredential { #expect(updated.metadata["sentinel"] == "kept") }
        #expect(!fixture.paths.contains { $0.contains("delete") || $0.contains("/copy") || $0.contains("/receive") || $0.contains("/rename") || $0.contains("/file/update") || $0.contains("/file/create") })
        if provider == .ali { #expect(fixture.paths.filter { $0.hasSuffix("create_session") }.count == 1) }
    }

    @Test(arguments: PersonalCloudDirectoryClient.supportedProviders)
    func malformedListingsDoNotBecomeAnEmptyLibrary(provider: DriveProvider) async throws {
        let fixture = PersonalDirectoryFixture(provider, malformed: true), client = client(fixture)
        await #expect(throws: (any Error).self) {
            _ = try await client.list(folderID: PersonalCloudDirectoryClient.rootID(for: provider), credential: credential(provider))
        }
    }

    @Test(arguments: PersonalCloudDirectoryClient.supportedProviders)
    func permissionErrorsDoNotTriggerFallbacksOrFileWrites(provider: DriveProvider) async throws {
        let fixture = PersonalDirectoryFixture(provider, denied: true), client = client(fixture)
        await #expect(throws: (any Error).self) {
            _ = try await client.list(folderID: PersonalCloudDirectoryClient.rootID(for: provider), credential: credential(provider))
        }
        #expect(fixture.paths.count == 1)
    }

    @Test(arguments: PersonalCloudDirectoryClient.supportedProviders)
    func originalByteStreamRejectsPlaylists(provider: DriveProvider) async throws {
        let fixture = PersonalDirectoryFixture(provider, playlist: true), client = client(fixture)
        let file = CloudDirectoryEntry(id: "last", name: "last.mp4", driveID: "drive", pickCode: "pick-last", path: "/last.mp4", size: 100, isDirectory: false)
        await #expect(throws: (any Error).self) { _ = try await client.download(entry: file, credential: credential(provider)) }
    }

    @Test func p115CookieOnlyUsesOriginalDownload() async throws {
        let fixture = PersonalDirectoryFixture(.p115), client = client(fixture)
        let file = CloudDirectoryEntry(id: "last", name: "last.mp4", pickCode: "pick-last", size: 100, isDirectory: false)
        let link = try await client.download(entry: file, credential: credential(.p115, openToken: false))
        #expect(link.url.hasPrefix("https://cdn.example.test/sample.mp4"))
        #expect(fixture.paths == ["/app/chrome/downurl"])
        #expect(link.metadata[DrivePlaybackMetadataKey.temporarySavedFile] == "false")
    }

    @Test func ucCancelledBootstrapDoesNotContinueToDownload() async throws {
        let fixture = PersonalDirectoryFixture(.uc, cancelledBootstrap: true), client = client(fixture)
        let file = CloudDirectoryEntry(id: "last", name: "last.mp4", isDirectory: false)
        await #expect(throws: CancellationError.self) { _ = try await client.download(entry: file, credential: credential(.uc)) }
        #expect(fixture.paths == ["/1/clouddrive/share/sharepage/token"])
    }

    @Test func aliRepeatedMarkerIsRejected() async throws {
        let fixture = PersonalDirectoryFixture(.ali, repeatMarker: true), client = client(fixture)
        await #expect(throws: (any Error).self) {
            _ = try await client.list(folderID: "root", cursor: "page-2", credential: credential(.ali))
        }
    }

    @Test func aliConcurrentRefreshIsMergedAndMetadataSurvives() async throws {
        let fixture = PersonalDirectoryFixture(.ali), client = client(fixture)
        let credential = CloudCredential(provider: .ali, kind: .refreshToken, secret: "refresh", refreshToken: "refresh", metadata: ["sentinel": "kept"])
        async let one = client.list(folderID: "root", credential: credential)
        async let two = client.list(folderID: "root", credential: credential)
        let (a, b) = try await (one, two)
        #expect(fixture.paths.filter { $0 == "/v2/account/token" }.count == 1)
        #expect(fixture.paths.filter { $0.hasSuffix("create_session") }.count == 1)
        #expect(a.updatedCredential?.refreshToken == "new-refresh")
        #expect(b.updatedCredential?.metadata["sentinel"] == "kept")
        _ = try await client.list(folderID: "root", credential: a.updatedCredential!)
        #expect(fixture.paths.filter { $0.hasSuffix("create_session") }.count == 1)
    }

    @Test func invalidCursorsAndCancelledTasksMakeNoRequests() async throws {
        let fixture = PersonalDirectoryFixture(.quark), client = client(fixture)
        await #expect(throws: (any Error).self) { _ = try await client.list(folderID: "0", cursor: "-1", credential: credential(.quark)) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.list(folderID: "0", credential: credential(.quark))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fixture.paths.isEmpty)
    }
}
