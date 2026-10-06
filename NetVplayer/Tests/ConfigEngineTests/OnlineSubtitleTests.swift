import Foundation
import Testing
import zlib
import Models
import Networking
import SubtitleEngine
import Storage
@testable import NetVplayerApp

@Test func onlineSubtitleArchivesValidateStoredDeflatedAndMalformedFiles() throws {
    let srt = Data("1\n00:00:00,000 --> 00:00:02,000\nCaption\n".utf8)
    for compressed in [false, true] {
        let zip = try subtitleTestZIP(name: "folder/caption.srt", content: srt, compressed: compressed)
        let files = try SubtitleArchive.unpack(zip, filename: "captions.zip")
        #expect(files.count == 1)
        #expect(files[0].data == srt)
        #expect(files[0].format == "srt")
    }
    #expect(throws: OnlineSubtitleError.self) { try SubtitleArchive.unpack(subtitleTestZIP(name: "../caption.srt", content: srt), filename: "captions.zip") }
    #expect(throws: OnlineSubtitleError.self) { try SubtitleArchive.unpack(subtitleTestZIP(name: "caption.srt", content: srt, declaredSize: SubtitleArchive.maximumFileBytes + 1), filename: "captions.zip") }
    #expect(throws: OnlineSubtitleError.self) { try SubtitleArchive.unpack(subtitleTestZIP(name: "caption.srt", content: srt, corruptCRC: true), filename: "captions.zip") }
    #expect(throws: OnlineSubtitleError.self) { try SubtitleArchive.unpack(subtitleTestZIP(name: "caption.srt", content: srt, symlink: true), filename: "captions.zip") }
    #expect(throws: OnlineSubtitleError.self) { try SubtitleArchive.unpack(Data("<html>Login</html>".utf8), filename: "caption.srt") }
    #expect(throws: OnlineSubtitleError.self) { try SubtitleArchive.unpack(Data([0x50, 0x4b]), filename: "captions.zip") }
    let utf16 = try #require(String(decoding: srt, as: UTF8.self).data(using: .utf16))
    #expect(try SubtitleArchive.unpack(utf16, filename: "caption.srt").first?.data == srt)
}

@Test func onlineSubtitleAPIPaginatesWithoutSendingTokenToDownloads() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SubtitleHTTPProtocol.self]
    let service = ASSRTSubtitleService(client: HTTPClient(session: URLSession(configuration: configuration)), apiURL: URL(string: "https://api.subtitle.test/v1/sub/")!)
    let token = String(repeating: "a", count: 32)
    let page = try await service.search(query: "Film title", offset: 15, token: token)
    #expect(page.results.count == 15)
    #expect(page.hasMore)
    let files = try await service.files(id: page.results[0].id, token: token)
    #expect(files.count == 1)
    let downloaded = try await service.download(files[0])
    #expect(downloaded.count == 1)
    #expect(downloaded[0].format == "srt")
    let requests = SubtitleHTTPProtocol.requests()
    let search = try #require(requests.first { $0.url?.path.hasSuffix("search") == true })
    let components = URLComponents(url: search.url!, resolvingAgainstBaseURL: false)!
    #expect(components.queryItems?.contains(.init(name: "pos", value: "15")) == true)
    #expect(components.queryItems?.contains { $0.name == "token" } == false)
    #expect(search.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
    #expect(requests.last { $0.url?.host == "download.subtitle.test" }?.value(forHTTPHeaderField: "Authorization") == nil)
    await #expect(throws: OnlineSubtitleError.self) { try await service.search(query: "ab", offset: 0, token: token) }
    await #expect(throws: OnlineSubtitleError.self) { try await service.search(query: "Film", offset: 0, token: "invalid") }
}

@MainActor
@Test func onlineSubtitleModelDiscardsLateResultsAfterPlaybackReplacementAndCancellation() async throws {
    for replaces in [true, false] {
        let service = SubtitleServiceGate()
        let model = OnlineSubtitleSearchModel(service: service)
        let first = PlaySpec(url: "https://cdn.test/first", metadata: ["playback.sessionGeneration": "1"])
        let second = PlaySpec(url: "https://cdn.test/second", metadata: ["playback.sessionGeneration": "2"])
        model.bind(to: SubtitlePlaybackOwner(first))
        model.search(query: "Film", token: "fixture")
        await service.waitUntilStarted()
        if replaces { model.bind(to: SubtitlePlaybackOwner(second)) } else { model.cancel() }
        await service.finish()
        for _ in 0..<10 { await Task.yield() }
        #expect(model.results.isEmpty)
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
        #expect(!model.owns(second) || replaces)
    }
}

private actor SubtitleServiceGate: OnlineSubtitleService {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<OnlineSubtitlePage, Never>?
    func search(query: String, offset: Int, token: String) async throws -> OnlineSubtitlePage {
        await withCheckedContinuation {
            resultWaiter = $0; started = true; startWaiter?.resume(); startWaiter = nil
        }
    }
    func files(id: Int, token: String) async throws -> [OnlineSubtitleFile] { [] }
    func download(_ file: OnlineSubtitleFile) async throws -> [DownloadedSubtitle] { [] }
    func waitUntilStarted() async {
        if started { return }; await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() {
        resultWaiter?.resume(returning: .init(results: [.init(id: 1, title: "Old film")], hasMore: false)); resultWaiter = nil
    }
}

@MainActor
@Test func onlineSubtitlePaginationUsesSubmittedQueryAndDeduplicatesPages() async throws {
    let service = SubtitlePaginationService()
    let model = OnlineSubtitleSearchModel(service: service)
    model.bind(to: SubtitlePlaybackOwner(PlaySpec(url: "file:///tmp/fixture.mkv")))
    model.search(query: "Original title", token: "fixture")
    while model.isLoading { await Task.yield() }
    #expect(model.results.count == 15)
    model.search(query: "Edited title", token: "fixture", more: true)
    while model.isLoading { await Task.yield() }
    #expect(model.results.count == 16)
    #expect(!model.hasMore)
    #expect(await service.requests == ["Original title:0", "Original title:15"])
}

@Test func onlineSubtitleTokenIsExcludedFromPreferenceBackup() throws {
    let suite = "subtitle-token-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = UserPreferences(defaults: defaults)
    #expect(!preferences.onlineSubtitleSearchEnabled)
    preferences.onlineSubtitleSearchEnabled = true
    try preferences.saveCredential("private-fixture-token", for: "subtitle.assrt.token")
    let encoded = try JSONEncoder().encode(UserPreferenceSnapshot(preferences: preferences))
    #expect(!String(decoding: encoded, as: UTF8.self).contains("private-fixture-token"))
    #expect(defaults.string(forKey: "subtitle.assrt.token") == nil)
    #expect(try JSONDecoder().decode(UserPreferenceSnapshot.self, from: encoded).onlineSubtitleSearchEnabled == true)
}

private actor SubtitlePaginationService: OnlineSubtitleService {
    var requests: [String] = []
    func search(query: String, offset: Int, token: String) async throws -> OnlineSubtitlePage {
        requests.append("\(query):\(offset)")
        return .init(results: (offset == 0 ? Array(1...15) : [15, 16]).map { .init(id: $0, title: "Film \($0)") }, hasMore: offset == 0)
    }
    func files(id: Int, token: String) async throws -> [OnlineSubtitleFile] { [] }
    func download(_ file: OnlineSubtitleFile) async throws -> [DownloadedSubtitle] { [] }
}

private final class SubtitleHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("subtitle.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.captured.append(request); Self.lock.unlock()
        let data: Data
        if request.url?.path.hasSuffix("search") == true {
            let rows = (1...15).map { ["id": $0, "native_name": "Film \($0)", "subtype": "SRT"] as [String: Any] }
            data = try! JSONSerialization.data(withJSONObject: ["status": 0, "sub": ["subs": rows]])
        } else if request.url?.path.hasSuffix("detail") == true {
            data = Data(#"{"status":0,"sub":{"subs":[{"id":1,"filelist":[{"f":"caption.srt","url":"https://download.subtitle.test/caption.srt"}]}]}}"#.utf8)
        } else { data = Data("1\n00:00:00,000 --> 00:00:02,000\nCaption\n".utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func subtitleTestZIP(name: String, content: Data, compressed: Bool = false, declaredSize: Int? = nil,
                             corruptCRC: Bool = false, symlink: Bool = false) throws -> Data {
    let name = Data(name.utf8)
    let crc = content.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(content.count)) }
    var payload = content
    if compressed {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw OnlineSubtitleError.invalidDownload }
        defer { deflateEnd(&stream) }
        payload = Data(count: content.count * 2 + 100)
        let status = content.withUnsafeBytes { input in
            payload.withUnsafeMutableBytes { output -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(content.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(output.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw OnlineSubtitleError.invalidDownload }
        payload.count = Int(stream.total_out)
    }
    func word(_ value: Int, _ width: Int) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    let crcValue = Int(crc) + (corruptCRC ? 1 : 0), size = declaredSize ?? content.count, method = compressed ? 8 : 0
    var local = word(0x04034b50, 4) + word(20, 2) + word(0, 2) + word(method, 2) + Data(count: 4)
    local += word(crcValue, 4) + word(payload.count, 4) + word(size, 4) + word(name.count, 2) + word(0, 2) + name + payload
    var central = word(0x02014b50, 4) + word(20, 2) + word(20, 2) + word(0, 2) + word(method, 2) + Data(count: 4)
    central += word(crcValue, 4) + word(payload.count, 4) + word(size, 4) + word(name.count, 2) + Data(count: 8)
    central += word(symlink ? 0xa000 << 16 : 0, 4) + word(0, 4) + name
    let end = word(0x06054b50, 4) + Data(count: 4) + word(1, 2) + word(1, 2) + word(central.count, 4) + word(local.count, 4) + word(0, 2)
    return local + central + end
}
