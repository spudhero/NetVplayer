import Foundation
import Testing
import Models
import Networking
@testable import DriveEngine

@Suite(.serialized)
struct BaiduTransferFolderTests {
    @Test func existingDirectoryIsReusedAcrossPreparations() async throws {
        let fixture = FolderFixture([.okList, .okList, .okList, .okList])
        let client = fixture.client()
        try await client.ensureTransferFolder(cookie: "BDUSS=fixture")
        try await client.ensureTransferFolder(cookie: "BDUSS=fixture")
        let anotherClient = fixture.client()
        async let first = client.ensureTransferFolder(cookie: "BDUSS=fixture")
        async let second = anotherClient.ensureTransferFolder(cookie: "BDUSS=fixture")
        _ = try await (first, second)
        #expect(fixture.methods == Array(repeating: "GET", count: 4))
        #expect(fixture.directories == Array(repeating: "/NetVplayer", count: 4))
    }

    @Test func existingLargeDirectoryReturnsCompleteTransferSnapshot() async throws {
        let files: [[String: Any]] = (0..<101).map {
            ["fs_id": "file-\($0)", "server_filename": "\($0).mp4", "path": "/NetVplayer/\($0).mp4", "isdir": 0, "size": 1]
        }
        func page(_ files: ArraySlice<[String: Any]>) throws -> FolderReply {
            .json(String(decoding: try JSONSerialization.data(withJSONObject: ["errno": 0, "list": Array(files)]), as: UTF8.self))
        }
        let fixture = try FolderFixture([page(files.prefix(100)), page(files.suffix(1))])
        let snapshot = try await fixture.client().ensureTransferFolder(cookie: "BDUSS=fixture")
        #expect(snapshot.count == 101)
        #expect(Set(snapshot.map(\.fileID)).count == 101)
        #expect(fixture.methods == ["GET", "GET"])
    }

    @Test(arguments: [0, -8, -6])
    func missingDirectoryIsCreatedWithoutRenamingAndRechecked(createCode: Int) async throws {
        let created = createCode == 0 ? #"{"errno":0,"path":"/NetVplayer","isdir":1}"# : "{\"errno\":\(createCode)}"
        let fixture = FolderFixture([.json(#"{"errno":-9}"#), .json(created), .okList])
        try await fixture.client().ensureTransferFolder(cookie: "BDUSS=fixture")
        #expect(fixture.methods == ["GET", "POST", "GET"])
        #expect(fixture.createForms.count == 1)
        #expect(fixture.createForms.first?["path"] == "/NetVplayer")
        #expect(fixture.createForms.first?["isdir"] == "1")
        #expect(fixture.createForms.first?["rtype"] == "0")
        #expect(fixture.directories == ["/NetVplayer", "/NetVplayer"])
    }

    @Test(arguments: [#"{"errno":-6}"#, #"{"errno":0}"#, #"{"list":[]}"#])
    func uncertainOrUnauthorizedReadNeverCreatesDirectory(body: String) async throws {
        let fixture = FolderFixture([.json(body)])
        await #expect(throws: Error.self) { try await fixture.client().ensureTransferFolder(cookie: "BDUSS=fixture") }
        #expect(fixture.methods == ["GET"])
        #expect(fixture.createForms.isEmpty)
    }

    @Test func successfulAutoRenamedDirectoryIsRejected() async throws {
        let fixture = FolderFixture([.json(#"{"errno":-9}"#),
            .json(#"{"errno":0,"path":"/NetVplayer_2026-11-11_23-59-59","isdir":1}"#)])
        await #expect(throws: Error.self) { try await fixture.client().ensureTransferFolder(cookie: "BDUSS=fixture") }
        #expect(fixture.methods == ["GET", "POST"])
    }

    @Test func conflictWithoutCanonicalDirectoryDoesNotCountAsSuccess() async throws {
        let fixture = FolderFixture([.json(#"{"errno":-9}"#), .json(#"{"errno":-8}"#), .json(#"{"errno":-9}"#)])
        await #expect(throws: Error.self) { try await fixture.client().ensureTransferFolder(cookie: "BDUSS=fixture") }
        #expect(fixture.methods == ["GET", "POST", "GET"])
    }

    @Test func transientReadFailureDoesNotCreateDirectory() async throws {
        let fixture = FolderFixture([FolderReply(status: 503, body: #"{"errno":-9}"#)])
        await #expect(throws: Error.self) { try await fixture.client().ensureTransferFolder(cookie: "BDUSS=fixture") }
        #expect(!fixture.methods.isEmpty && fixture.methods.allSatisfy { $0 == "GET" })
        #expect(fixture.createForms.isEmpty)
    }
}

private struct FolderReply {
    let status: Int
    let body: String
    static let okList = json(#"{"errno":0,"list":[]}"#)
    static func json(_ body: String) -> Self { Self(status: 200, body: body) }
}

private final class FolderFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [FolderReply]
    private var seenMethods: [String] = []
    private var seenDirectories: [String] = []
    private var forms: [[String: String]] = []
    var methods: [String] { lock.withLock { seenMethods } }
    var directories: [String] { lock.withLock { seenDirectories } }
    var createForms: [[String: String]] { lock.withLock { forms } }
    init(_ replies: [FolderReply]) { self.replies = replies }
    func client() -> BaiduDriveClient {
        FolderProtocol.fixture = self
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FolderProtocol.self]
        return BaiduDriveClient(httpClient: HTTPClient(session: URLSession(configuration: configuration)).withExplicitProxy(nil))
    }
    func respond(_ request: URLRequest) throws -> FolderReply {
        try lock.withLock {
            seenMethods.append(request.httpMethod ?? "GET")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let dir = query.first(where: { $0.name == "dir" })?.value { seenDirectories.append(dir) }
            if request.httpMethod == "POST" {
                var bytes = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        bytes.append(contentsOf: buffer.prefix(count))
                    }
                }
                var form = URLComponents()
                form.percentEncodedQuery = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
                forms.append(Dictionary((form.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new }))
            }
            guard !replies.isEmpty else { throw URLError(.badServerResponse) }
            return replies.removeFirst()
        }
    }
}

private final class FolderProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: FolderFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.fixture!.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
