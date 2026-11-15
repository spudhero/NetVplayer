import Foundation
import Models
import Networking
@testable import ParseEngine
import Testing

@Suite(.serialized)
@MainActor
struct ParseEngineSniffingTests {
    private let page = "https://video.example.invalid/watch/1"
    private let media = "https://media.example.invalid/one.m3u8"

    @Test func emptyOrUnchangedSniffNeverBecomesSuccess() async {
        for value in ["", " \n ", page] {
            let sniffer = StubSniffer(reply: .success(PlaySpec(url: value, headers: ["X-False": "discard"])))
            let engine = makeEngine(sniffer)
            let spec = await engine.resolve(result: Result(url: page, header: ["X-Original": "keep"]), parse: nil)
            #expect(spec.url == page)
            #expect(spec.headers == ["X-Original": "keep"])
            #expect(engine.lastFailure?.category == .parse)
            #expect(engine.lastFailure?.detail == WebViewSnifferError.noMediaFound.localizedDescription)
        }
    }

    @Test func timeoutIsAnExplicitFailure() async {
        let engine = makeEngine(StubSniffer(reply: .failure(WebViewSnifferError.noMediaFound)))
        let spec = await engine.resolve(result: Result(url: page), parse: nil)
        #expect(spec.url == page)
        #expect(engine.lastFailure?.category == .parse)
        #expect(engine.lastFailure?.message == "WebView 嗅探失败")
    }

    @Test func realMediaPreservesSuccessfulMergeAndClearsPreviousFailure() async {
        let sniffer = StubSniffer(reply: .success(PlaySpec()))
        let engine = makeEngine(sniffer)
        let result = Result(url: page, flag: "line", header: ["Origin": "https://origin.example.invalid"],
                            externalAudioURL: "https://media.example.invalid/audio.m4a", key: "fixture")
        _ = await engine.resolve(result: result, parse: nil)
        #expect(engine.lastFailure != nil)
        sniffer.reply = .success(PlaySpec(url: media, headers: ["Referer": page], format: "m3u8"))
        let spec = await engine.resolve(result: result, parse: nil)
        #expect(spec.url == media)
        #expect(spec.headers["Origin"] == "https://origin.example.invalid")
        #expect(spec.headers["Referer"] == page)
        #expect(spec.externalAudioURL == result.externalAudioURL)
        #expect(spec.flag == "line" && spec.siteKey == "fixture" && spec.format == "m3u8")
        #expect(engine.lastFailure == nil)
    }

    @Test func authoritativeEmptyHeadersSurviveParserAndLaterPlaySpecMerges() async {
        let reply = PlaySpec(url: media, headerPolicy: .replace)
        let engine = makeEngine(StubSniffer(reply: .success(reply)))
        let result = Result(url: page, flag: "line", header: ["cOoKiE": "page-only", "Authorization": "page-only"], key: "fixture")
        let spec = await engine.resolve(result: result, parse: nil)
        #expect(engine.lastFailure == nil)
        #expect(spec.headers.isEmpty && spec.headerPolicy == .replace)
        #expect(spec.flag == "line" && spec.siteKey == "fixture")
        let staleBase = PlaySpec(headers: result.header)
        #expect(staleBase.merging(spec).headers.isEmpty)
        #expect(staleBase.merging(spec.merging(PlaySpec(title: "next"))).headers.isEmpty)
    }

    @Test func authoritativeDeclaredCredentialsReplaceRatherThanReintroducePageFields() async {
        let reply = PlaySpec(url: media, headers: ["authorization": "Bearer media"], headerPolicy: .replace)
        let engine = makeEngine(StubSniffer(reply: .success(reply)))
        let spec = await engine.resolve(result: Result(url: page,
            header: ["Cookie": "page-only", "Authorization": "Bearer page", "Referer": page]), parse: nil)
        #expect(engine.lastFailure == nil)
        #expect(spec.headers == ["authorization": "Bearer media"])
        #expect(PlaySpec(headers: ["Cookie": "stale"]).merging(spec).headers == spec.headers)
    }

    @Test func failedSniffDoesNotBlockValidJSONFallback() async {
        let engine = makeEngine(StubSniffer(reply: .success(PlaySpec(url: page))))
        let spec = await engine.resolve(result: Result(url: page, flag: "line"), parse: parser(type: 4, response: "media"))
        #expect(spec.url == media && spec.flag == "line")
        #expect(spec.headers["X-Parsed"] == "yes")
        #expect(engine.lastFailure == nil)
    }

    @Test func failedJSONDoesNotBlockValidSniffFallback() async {
        let sniffer = StubSniffer(reply: .success(PlaySpec(url: media)), suspended: true)
        let engine = makeEngine(sniffer)
        let task = Task { await engine.resolve(result: Result(url: page), parse: parser(type: 4, response: "invalid")) }
        await sniffer.waitUntilStarted()
        sniffer.complete()
        let spec = await task.value
        #expect(spec.url == media)
        #expect(engine.lastFailure == nil)
    }

    @Test func raceWithNoMediaFailsInsteadOfReturningSuccess() async {
        for response in ["invalid", "empty", "original"] {
            let engine = makeEngine(StubSniffer(reply: .success(PlaySpec())))
            let spec = await engine.resolve(result: Result(url: page), parse: parser(type: 4, response: response))
            #expect(spec.url == page)
            #expect(engine.lastFailure?.category == .parse)
        }
    }

    @Test func JSONWinnerCancelsPendingSnifferWithoutOverwritingSuccess() async {
        let sniffer = StubSniffer(reply: .success(PlaySpec()), suspended: true)
        let engine = makeEngine(sniffer)
        // A held protocol response makes the ordering deterministic without sockets.
        let task = Task { await engine.resolve(result: Result(url: page), parse: parser(type: 4, response: "held")) }
        await sniffer.waitUntilStarted()
        await SniffFixtureURLProtocol.waitUntilHeld()
        SniffFixtureURLProtocol.completeHeld()
        let spec = await task.value
        #expect(spec.url == media)
        #expect(sniffer.cancelCount == 1 && !sniffer.isPending)
        #expect(engine.lastFailure == nil)
    }

    @Test func taskCancellationStopsPendingSnifferAndCannotSucceed() async {
        let sniffer = StubSniffer(reply: .success(PlaySpec(url: media)), suspended: true)
        let engine = makeEngine(sniffer)
        let task = Task { await engine.resolve(result: Result(url: page), parse: nil) }
        await sniffer.waitUntilStarted()
        task.cancel()
        let spec = await task.value
        #expect(spec.url == page)
        #expect(sniffer.cancelCount == 1 && !sniffer.isPending)
        #expect(engine.lastFailure?.message == "解析已取消")
    }

    @Test func explicitCancelStopsPendingSniffer() async {
        let sniffer = StubSniffer(reply: .success(PlaySpec(url: media)), suspended: true)
        let engine = makeEngine(sniffer)
        let task = Task { await engine.resolve(result: Result(url: page), parse: nil) }
        await sniffer.waitUntilStarted()
        engine.cancelCurrentSniff()
        let spec = await task.value
        #expect(spec.url == page)
        #expect(sniffer.cancelCount == 1 && !sniffer.isPending)
        #expect(engine.lastFailure?.message == "解析已取消")
    }

    @Test func alreadyCancelledTaskDoesNotStartSniffer() async {
        let sniffer = StubSniffer(reply: .success(PlaySpec(url: media)))
        let engine = makeEngine(sniffer)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.resolve(result: Result(url: page), parse: nil)
        }
        let spec = await task.value
        #expect(spec.url == page && sniffer.startCount == 0)
        #expect(engine.lastFailure?.message == "解析已取消")
    }

    @Test func realSnifferRejectsInvalidInputAndCancellationBeforeCreatingWebView() async {
        let sniffer = WebViewSniffer()
        do {
            _ = try await sniffer.sniff(url: " \n ")
            Issue.record("Invalid input returned an empty success")
        } catch {
            #expect((error as? URLError)?.code == .badURL)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await sniffer.sniff(url: page)
                Issue.record("Cancelled sniff returned success")
            } catch { #expect(error is CancellationError) }
        }
        await task.value
    }

    @Test func JSONParsingKeepsMetadataAndUnsupportedTypeContract() async {
        let engine = makeEngine(StubSniffer(reply: .success(PlaySpec())))
        let result = Result(url: page, flag: "line", header: ["Origin": "https://origin.example.invalid"], key: "fixture")
        let spec = await engine.resolve(result: result, parse: parser(type: 1, response: "media"))
        #expect(spec.url == media && spec.flag == "line" && spec.siteKey == "fixture")
        #expect(spec.headers["Origin"] == "https://origin.example.invalid")
        #expect(spec.headers["X-Parsed"] == "yes" && spec.format == "m3u8")
        #expect(engine.lastFailure == nil)
        let unsupported = await engine.resolve(result: result, parse: Parse(type: 2))
        #expect(unsupported.url == page && unsupported.headers == result.header)
        #expect(engine.lastFailure?.message.contains("type 2") == true)
    }

    private func parser(type: Int, response: String) -> Parse {
        Parse(type: type, url: "https://parse.example.invalid/\(response)?url=")
    }

    private func makeEngine(_ sniffer: StubSniffer) -> ParseEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SniffFixtureURLProtocol.self]
        let client = HTTPClient(session: URLSession(configuration: configuration)).withExplicitProxy(nil)
        return ParseEngine(httpClient: client, snifferFactory: { sniffer })
    }
}

@MainActor
private final class StubSniffer: WebMediaSniffing {
    var reply: Swift.Result<PlaySpec, Error>
    private let suspended: Bool
    private var continuation: CheckedContinuation<PlaySpec, Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    var isPending: Bool { continuation != nil }

    init(reply: Swift.Result<PlaySpec, Error>, suspended: Bool = false) {
        self.reply = reply
        self.suspended = suspended
    }

    func sniff(url: String, headers: [String: String], clickScript: String, timeout: TimeInterval, policy: WebMediaPolicy?) async throws -> PlaySpec {
        startCount += 1
        if !suspended { return try reply.get() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if startCount > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func complete() {
        let pending = continuation
        continuation = nil
        pending?.resume(with: reply)
    }

    func cancel() {
        cancelCount += 1
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }
}

private final class SniffFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: SniffFixtureURLProtocol?
    nonisolated(unsafe) private static var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private static let media = "{\"url\":\"https://media.example.invalid/one.m3u8\",\"format\":\"m3u8\",\"header\":{\"X-Parsed\":\"yes\"}}"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if request.url?.path == "/held" {
            Self.lock.lock()
            Self.held = self
            let waiters = Self.heldWaiters
            Self.heldWaiters.removeAll()
            Self.lock.unlock()
            waiters.forEach { $0.resume() }
            return
        }
        let body: String
        switch request.url?.path {
        case "/media": body = Self.media
        case "/empty": body = "{}"
        case "/original": body = "{\"url\":\"https://video.example.invalid/watch/1\"}"
        default: body = "invalid-json"
        }
        respond(body)
    }

    static func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let ready = held != nil
            if !ready { heldWaiters.append(continuation) }
            lock.unlock()
            if ready { continuation.resume() }
        }
    }

    static func completeHeld() {
        lock.lock()
        let pending = held
        held = nil
        lock.unlock()
        pending?.respond(media)
    }

    private func respond(_ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
