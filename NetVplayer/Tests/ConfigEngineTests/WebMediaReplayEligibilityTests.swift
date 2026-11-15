import AppKit
import CryptoKit
import Foundation
import Models
import Testing
@testable import ParseEngine
@testable import PlayerEngine

// The collector observes real loopback requests. A candidate or a cookie-store
// snapshot alone is deliberately never used as proof of replay eligibility.
@Suite(.serialized)
@MainActor
struct WebMediaReplayEligibilityTests {
    @Test func freshHttpOnlyCookieRemainsABoundedReplayFailure() async throws {
        for scenario in ["include", "same-origin", "xhr"] {
            let server = try ReplayEligibilityServer(); defer { server.stop() }
            let spec = try await resolve(server, scenario)
            let browser = try #require(try await server.media(actor: "browser").first)
            #expect(browser.headers["cookie"] == "account=fresh" && browser.status == 200)
            #expect(spec.headers.keys.allSatisfy { $0.lowercased() != "cookie" })
            #expect(try await server.replay(spec) == 403)
            let replay = try #require(try await server.media(actor: "replay").first)
            #expect(replay.headers["cookie"] == nil)
        }
    }

    @Test func omittedExpiredAndOutOfScopeCookiesAreNotReconstructed() async throws {
        for scenario in ["omit", "outside-path", "cross-host", "xhr-cross-host", "expired"] {
            let server = try ReplayEligibilityServer(); defer { server.stop() }
            let spec = try await resolve(server, scenario)
            let browser = try #require(try await server.media(actor: "browser").first)
            #expect(browser.headers["cookie"] == nil && browser.status == 200, "\(scenario)")
            #expect(try await server.replay(spec) == 200, "\(scenario)")
            #expect(try await server.media(actor: "replay").allSatisfy { $0.headers["cookie"] == nil })
        }
    }

    @Test func redirectDestinationsHaveTheirOwnCookieScope() async throws {
        for scenario in ["redirect-same", "redirect-path", "redirect-host"] {
            let server = try ReplayEligibilityServer(); defer { server.stop() }
            let spec = try await resolve(server, scenario)
            let browser = try await server.media(actor: "browser")
            #expect(browser.count == 2)
            #expect(browser.first?.headers["cookie"] == "account=fresh" && browser.first?.status == 302)
            #expect(browser.last?.headers["cookie"] == (scenario == "redirect-same" ? "account=redirected" : nil))
            #expect(browser.last?.status == 200)
            // Candidate is the original request intent; its URL is not evidence
            // of the browser's final destination or destination headers.
            #expect(spec.url == server.url("/media/" + scenario + ".m3u8"))
            #expect(try await server.replay(spec) == (scenario == "redirect-same" ? 403 : 200))
            #expect(try await server.media(actor: "replay").allSatisfy { $0.headers["cookie"] == nil })
        }
    }

    @Test func cacheReuseCannotBeRecoveredFromTheLatestCookieSnapshot() async throws {
        let server = try ReplayEligibilityServer(); defer { server.stop() }
        let spec = try await resolve(server, "cache")
        let media = try await server.media(actor: "browser")
        #expect(media.count == 1 && media.first?.headers["cookie"] == "account=fresh")
        let settled = try #require(try await server.requests().first { $0.path == "/settled" })
        let query = URLComponents(string: "http://local/?" + settled.query)?.queryItems
        #expect(query?.first { $0.name == "cache" }?.value == #"["account=fresh","account=fresh"]"#)
        let candidate = try await server.candidate()
        let snapshot = try #require(candidate["cookieStoreSnapshot"] as? [String: Any])
        let fields = try #require(snapshot["fields"] as? [[String: Any]])
        #expect(fields.first?["valueSHA256"] as? String == Self.digest("second"))
        #expect(try await server.replay(spec) == 403)
    }

    @Test func corsPreflightRejectionDoesNotProveAMediaRequestWasSent() async throws {
        let server = try ReplayEligibilityServer(); defer { server.stop() }
        let spec = try await resolve(server, "cors-denied")
        let browser = try await server.media(actor: "browser")
        #expect(browser.count == 1 && browser.first?.method == "OPTIONS" && browser.first?.status == 403)
        #expect(!browser.contains { $0.method == "GET" })
        #expect(spec.headers.first { $0.key.lowercased() == "x-local-token" }?.value == "declared-only")
        // Native replay has no browser CORS gate; this 200 is not browser parity.
        #expect(try await server.replay(spec) == 200)
        let candidate = try await server.candidate()
        #expect(candidate["replayEligibility"] as? String == "unverified")
        #expect(candidate["requestEvidence"] as? String == "pageAPIIntent")
    }

    @Test func completedSniffDoesNotKeepCookiesOrCacheForTheNextSession() async throws {
        let server = try ReplayEligibilityServer(); defer { server.stop() }
        let sniffer = WebViewSniffer(diagnosticDirectory: server.diagnostics)
        let old = try await resolve(server, "include", sniffer: sniffer)
        #expect(try await server.replay(old) == 403)
        let current = try await resolve(server, "no-seed", sniffer: sniffer)
        #expect(try await server.replay(current) == 200)
        let browser = try await server.media(actor: "browser")
        #expect(browser.map { $0.headers["cookie"] ?? "" } == ["account=fresh", ""])
    }

    @Test func cancelledCookieSessionCannotCompleteIntoItsReplacement() async throws {
        let server = try ReplayEligibilityServer(); defer { server.stop() }
        let sniffer = WebViewSniffer(diagnosticDirectory: server.diagnostics)
        let old = Task { try await resolve(server, "hold", sniffer: sniffer, delay: true) }
        try await server.waitForSettled("hold")
        old.cancel()
        let current = try await resolve(server, "no-seed", sniffer: sniffer)
        do { _ = try await old.value; Issue.record("cancelled Cookie session returned a candidate") }
        catch { #expect(error is CancellationError) }
        #expect(try await server.replay(current) == 200)
        let browser = try await server.media(actor: "browser")
        #expect(browser.map { $0.headers["cookie"] ?? "" } == ["account=fresh", ""])
    }

    @Test func diagnosticsStateTheReplayBoundaryWithoutExposingCredentials() async throws {
        let server = try ReplayEligibilityServer(); defer { server.stop() }
        _ = try await resolve(server, "include")
        let candidate = try await server.candidate()
        #expect(candidate["replayEligibility"] as? String == "unverified")
        #expect(candidate["requestEvidence"] as? String == "pageAPIIntent")
        #expect(candidate["browserResponseObserved"] as? Bool == false)
        #expect(candidate["redirectChainObserved"] as? Bool == false)
        #expect(candidate["cacheDispositionObserved"] as? Bool == false)
        #expect(candidate["automaticCookieForwarded"] as? Bool == false)
        #expect(candidate["wireHeadersObserved"] as? Bool == false)
        let snapshot = try #require(candidate["cookieStoreSnapshot"] as? [String: Any])
        #expect(snapshot["requestEligibilityEvaluated"] as? Bool == false)
        for path in try FileManager.default.contentsOfDirectory(at: server.diagnostics, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: path)
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(!text.contains("account") && !text.contains("fresh") && !text.contains(server.url("")))
            let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(report["schema"] as? Int == 7)
            #expect((report["events"] as? [Any])?.count ?? 129 <= 128)
            #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
    func nativeCookieFailureAndCookieFreeRecoveryAreObservedAtTheReceiver() async throws {
        let server = try ReplayEligibilityServer(); defer { server.stop() }
        let denied = try await resolve(server, "native-include")
        let allowed = try await resolve(server, "native-omit")
        let ranged = try await resolve(server, "native-range")
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod)
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        for (original, shouldFail) in [(denied, true), (allowed, false), (ranged, false)] {
            var spec = original
            spec.headers["X-Fixture-Actor"] = "player"
            spec.metadata["network.explicitDirect"] = "true"
            await engine.play(spec: spec)
            try #require(await wait { !state.isMediaLoading || state.errorMessage != nil })
            #expect((state.errorMessage != nil) == shouldFail)
            if !shouldFail {
                try #require(await wait { engine.nativePropertyJSON("video-format")?.contains("h264") == true })
            }
        }
        let player = try await server.media(actor: "player")
        #expect(player.contains { $0.path == "/media/native-include.mp4" && $0.status == 403 })
        #expect(player.contains { $0.path == "/media/native-omit.mp4" && $0.status == 200 })
        #expect(player.allSatisfy { $0.headers["cookie"] == nil })
        let rangeRequest = try #require(player.last { $0.path == "/media/native-range.mp4" })
        #expect(rangeRequest.headers["range"] != "bytes=1-2" && rangeRequest.status == 200)
    }

    private func resolve(_ server: ReplayEligibilityServer, _ scenario: String,
                         sniffer: WebViewSniffer? = nil, delay: Bool = false) async throws -> PlaySpec {
        let policy = WebMediaPolicy(check: { url in
            guard URL(string: url)?.path.contains("/media/") == true else { return false }
            try await server.waitForSettled(scenario)
            if delay { try await Task.sleep(for: .seconds(2)) }
            return true
        })
        return try await (sniffer ?? WebViewSniffer(diagnosticDirectory: server.diagnostics)).sniff(
            url: server.url("/page/" + scenario), headers: ["User-Agent": "Local-Replay-UA/1"], timeout: 6, policy: policy)
    }
    private func wait(_ predicate: () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
        return predicate()
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ReplayEligibilityRequest: Decodable {
    let path: String
    let query: String
    let method: String
    let headers: [String: String]
    let actor: String
    let status: Int
}

@MainActor
private final class ReplayEligibilityServer {
    let root: URL
    let diagnostics: URL
    private let temporary: Bool
    private let process: Process
    private let port: Int
    init() throws {
        let base = ProcessInfo.processInfo.environment["NETVPLAYER_WEB_REPLAY_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }
        temporary = base == nil
        root = (base ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        diagnostics = root.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repo.deleteLastPathComponent() }
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-B", "-u", repo.appendingPathComponent("script/fixtures/web-transport/web_replay_fixture.py").path]
        var env = ProcessInfo.processInfo.environment
        env["NETVPLAYER_WEB_REPLAY_RECORDS"] = root.appendingPathComponent("requests.private.jsonl").path
        task.environment = env; task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        try task.run(); process = task
        guard let data = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8),
              let value = Int(data.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            task.terminate(); throw URLError(.cannotConnectToHost)
        }
        port = value
    }
    func url(_ path: String) -> String { "http://127.0.0.1:\(port)" + path }
    func stop() {
        let stopped = stopOwnedFixtureProcess(process)
        #expect(stopped)
        if stopped && temporary { try? FileManager.default.removeItem(at: root) }
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }
    func requests() async throws -> [ReplayEligibilityRequest] {
        let client = session(); defer { client.invalidateAndCancel() }
        let (data, _) = try await client.data(from: URL(string: url("/records"))!)
        return try JSONDecoder().decode([ReplayEligibilityRequest].self, from: data)
    }
    func media(actor: String) async throws -> [ReplayEligibilityRequest] {
        try await requests().filter { $0.path.contains("/media/") && $0.actor == actor }
    }
    func waitForSettled(_ scenario: String) async throws {
        for _ in 0..<200 {
            try Task.checkCancellation()
            if try await requests().contains(where: { $0.path == "/settled" && $0.query.hasPrefix("scenario=" + scenario) }) { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw URLError(.timedOut)
    }
    func replay(_ spec: PlaySpec) async throws -> Int {
        let client = session(); defer { client.invalidateAndCancel() }
        var request = URLRequest(url: try #require(URL(string: spec.url)))
        for (name, value) in spec.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("replay", forHTTPHeaderField: "X-Fixture-Actor")
        let (_, response) = try await client.data(for: request)
        return try #require(response as? HTTPURLResponse).statusCode
    }
    func candidate() async throws -> [String: Any] {
        let files = try FileManager.default.contentsOfDirectory(at: diagnostics, includingPropertiesForKeys: nil)
        for path in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            let events = try #require(report["events"] as? [[String: Any]])
            if let result = events.first(where: { $0["stage"] as? String == "candidate" }) { return result }
        }
        throw URLError(.cannotParseResponse)
    }
}
