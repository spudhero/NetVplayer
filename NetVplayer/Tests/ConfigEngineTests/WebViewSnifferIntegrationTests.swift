import Foundation
import Testing
import Models
@testable import ParseEngine

/// A real WKWebView talks only to a loopback server. No provider or remote URL
/// is requested, and a page must actually run before it exposes the media URL.
@Suite(.serialized)
@MainActor
struct WebViewSnifferIntegrationTests {
    @Test func discoversStaticAndDynamicMediaInFrames() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        for scenario in ["static", "source", "attribute", "frame", "fetch", "xhr"] {
            let spec = try await WebViewSniffer().sniff(
                url: server.url("/page/" + scenario),
                headers: ["User-Agent": "Original-Provider-UA/1", "X-Provider": "preserve"], timeout: 5)
            #expect(spec.url == server.url("/media/movie.m3u8?signature=a%2Fb&part=1"), "\(scenario)")
            #expect(spec.headers["User-Agent"] == "Original-Provider-UA/1", "\(scenario)")
            #expect(spec.headers["X-Provider"] == nil, "\(scenario)")
        }
    }

    @Test func providerUserAgentReachesFrameAndScriptRequests() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        let spec = try await WebViewSniffer().sniff(url: server.url("/page/ua"),
            headers: ["user-agent": "Original-Provider-UA/1"], timeout: 5)
        #expect(spec.url == server.url("/media/movie.m3u8?signature=a%2Fb&part=1"))
        #expect(spec.headers["User-Agent"] == "Original-Provider-UA/1")
        #expect(spec.headers.keys.filter { $0.lowercased() == "user-agent" }.count == 1)
    }

    @Test func sharedParserAllowsTheOriginalFifteenSecondWindow() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        let engine = ParseEngine()
        let spec = await engine.resolve(result: Result(url: server.url("/page/delayed")), parse: nil)
        #expect(engine.lastFailure == nil)
        #expect(spec.url == server.url("/media/movie.m3u8?signature=a%2Fb&part=1"))
    }

    @Test func pageAPIHeadersReachTheResolvedMediaRequest() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        for scenario in ["fetch-init", "fetch-request", "fetch-override", "xhr-headers", "xhr-reopen"] {
            let engine = ParseEngine()
            let spec = await engine.resolve(result: Result(url: server.url("/page/" + scenario),
                header: ["X-Access": "stale-page-value", "User-Agent": "Original-Provider-UA/1"]), parse: nil)
            #expect(engine.lastFailure == nil, "\(scenario)")
            #expect(spec.headers.filter { $0.key.lowercased() == "x-access" }.map(\.value) == ["media-secret"], "\(scenario)")
            #expect(spec.headers.filter { $0.key.lowercased() == "x-parts" }.map(\.value) == ["one, two"], "\(scenario)")
            var request = URLRequest(url: try #require(URL(string: spec.url)))
            for (key, value) in spec.headers { request.setValue(value, forHTTPHeaderField: key) }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(scenario)")
            #expect(String(data: data, encoding: .utf8) == "authorized-media", "\(scenario)")
        }
    }

    @Test func unopenedOrUnsentXHRIsNotAMediaRequest() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        let spec = try await WebViewSniffer().sniff(url: server.url("/page/xhr-unsent"), timeout: 5)
        #expect(spec.url == server.url("/media/movie.m3u8?signature=a%2Fb&part=1"))
    }

    @Test func browserControlledAndNoCORSHeadersAreNotPromotedToPlayback() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        for scenario in ["forbidden", "no-cors"] {
            let spec = try await WebViewSniffer().sniff(url: server.url("/page/" + scenario),
                headers: ["User-Agent": "Original-Provider-UA/1"], timeout: 5)
            let names = Set(spec.headers.keys.map { $0.lowercased() })
            #expect(!names.contains("cookie") && !names.contains("referer") && !names.contains("origin"))
            #expect(!names.contains("sec-fixture") && !names.contains("proxy-fixture"))
            #expect(spec.headers["User-Agent"] == "Original-Provider-UA/1")
            if scenario == "no-cors" { #expect(!names.contains("x-access")) }
        }
    }

    @Test func diagnosticsDescribeProvenanceWithoutExposingURLsOrHeaders() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await WebViewSniffer(diagnosticDirectory: directory).sniff(
            url: server.url("/page/xhr-headers"), headers: ["X-Private": "initial-secret"], timeout: 5)
        let path = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: path)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(server.url("")) && !text.contains("media-secret") && !text.contains("initial-secret"))
        #expect(!text.lowercased().contains("x-access") && !text.lowercased().contains("x-private"))
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["schema"] as? Int == 7)
        let events = try #require(report["events"] as? [[String: Any]])
        #expect(events.count <= 128)
        let candidate = try #require(events.first { $0["stage"] as? String == "candidate" })
        #expect(candidate["source"] as? String == "xhr" && candidate["method"] as? String == "GET")
        #expect(candidate["wireHeadersObserved"] as? Bool == false)
        #expect(candidate["initialHeadersInherited"] as? Bool == false)
        #expect(candidate["headerPolicy"] as? String == "replacePageHeaders")
        #expect((candidate["pageSuppliedHeaders"] as? [String: Any])?["count"] as? Int == 2)
        #expect(events.contains { $0["stage"] as? String == "navigationResponse" && $0["status"] as? Int == 200 })
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func noMediaDiagnosticsRetainTheMainPageHTTPFailure() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await WebViewSniffer(diagnosticDirectory: directory).sniff(url: server.url("/page/unavailable"), timeout: 5)
            Issue.record("Unavailable page returned media")
        } catch { #expect(error is WebViewSnifferError) }
        let path = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let events = try #require(report["events"] as? [[String: Any]])
        #expect(events.contains { $0["stage"] as? String == "navigationResponse" && $0["status"] as? Int == 429 })
        #expect(events.last?["stage"] as? String == "failure")
        #expect(!events.contains { $0["stage"] as? String == "candidate" })
    }

    @Test func replacementRequestKeepsItsOwnLifetime() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        let sniffer = WebViewSniffer()
        let old = Task { try await sniffer.sniff(url: server.url("/page/empty"), timeout: 5) }
        try await Task.sleep(for: .milliseconds(150))
        let current = Task { try await sniffer.sniff(url: server.url("/page/attribute"), timeout: 5) }
        old.cancel()
        do { _ = try await old.value; Issue.record("replaced request succeeded") }
        catch { #expect(error is CancellationError) }
        let spec = try await current.value
        #expect(spec.url == server.url("/media/movie.m3u8?signature=a%2Fb&part=1"))
    }

    @Test func pagesAndNonHTTPMediaNeverBecomePlaybackURLs() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        do {
            _ = try await WebViewSniffer().sniff(url: server.url("/page/negative"), timeout: 0.4)
            Issue.record("a page or non-HTTP media was accepted")
        } catch { #expect(error is WebViewSnifferError) }
    }

    @Test func timeoutCancellationAndReuseDoNotAcceptStaleMessages() async throws {
        let server = try SnifferLoopbackServer()
        defer { server.stop() }
        let sniffer = WebViewSniffer()
        let waiting = Task { try await sniffer.sniff(url: server.url("/page/empty"), timeout: 5) }
        try await Task.sleep(for: .milliseconds(150))
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("cancelled sniff returned media") }
        catch { #expect(error is CancellationError) }
        do {
            _ = try await sniffer.sniff(url: server.url("/page/empty"), timeout: 0.15)
            Issue.record("empty page returned media")
        } catch { #expect(error is WebViewSnifferError) }
        let spec = try await sniffer.sniff(url: server.url("/page/static"), timeout: 5)
        #expect(spec.url == server.url("/media/movie.m3u8?signature=a%2Fb&part=1"))
    }
}

private final class SnifferLoopbackServer {
    private let process: Process
    private let port: Int

    init() throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        let data = pipe.fileHandleForReading.availableData
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let port = Int(value) else {
            process.terminate()
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)" + path }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }

    private static let script = #"""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
media = '/media/movie.m3u8?signature=a%2Fb&part=1'
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        path = self.path.split('?')[0]
        body = '<html><body>'
        if path == '/page/static':
            body += '<video preload="auto" src="../media/movie.m3u8?signature=a%2Fb&amp;part=1"></video>'
        elif path == '/page/source':
            body += '<script>let s=document.createElement("source"); s.src="'+media+'"; let v=document.createElement("video"); v.append(s); document.body.append(v);</script>'
        elif path == '/page/attribute':
            body += '<video id="v"></video><script>setTimeout(()=>v.setAttribute("src","'+media+'"),100)</script>'
        elif path == '/page/frame':
            body += '<iframe src="/page/static"></iframe>'
        elif path == '/page/fetch':
            body += '<script>fetch(new Request("'+media+'"))</script>'
        elif path == '/page/xhr':
            body += '<script>let x=new XMLHttpRequest();x.open("GET","'+media+'");x.send()</script>'
        elif path == '/page/fetch-init':
            body += '<script>fetch("/protected/media.m3u8",{headers:{"X-Access":"media-secret","X-Parts":"one, two"}})</script>'
        elif path == '/page/fetch-request':
            body += '<script>fetch(new Request("/protected/media.m3u8",{headers:[["X-Access","media-secret"],["X-Parts","one"],["x-parts","two"]]}))</script>'
        elif path == '/page/fetch-override':
            body += '<script>fetch(new Request("/protected/media.m3u8",{headers:{"X-Access":"wrong"}}),{headers:new Headers({"X-Access":"media-secret","X-Parts":"one, two"})})</script>'
        elif path == '/page/xhr-headers':
            body += '<script>let x=new XMLHttpRequest();x.open("GET","/protected/media.m3u8");x.setRequestHeader("X-Access","media-secret");x.setRequestHeader("X-Parts","one");x.setRequestHeader("x-parts","two");x.send()</script>'
        elif path == '/page/xhr-reopen':
            body += '<script>let x=new XMLHttpRequest();x.open("GET","/media/unused.m3u8");x.setRequestHeader("X-Access","wrong");x.open("GET","/protected/media.m3u8");x.setRequestHeader("X-Access","media-secret");x.setRequestHeader("X-Parts","one, two");x.send()</script>'
        elif path == '/page/forbidden':
            body += '<script>fetch("'+media+'",{headers:{"Cookie":"fake-secret","Referer":"https://fake.invalid/","Origin":"https://fake.invalid","User-Agent":"fake-UA","Sec-Fixture":"bad","Proxy-Fixture":"bad"}})</script>'
        elif path == '/page/no-cors':
            body += '<script>fetch("'+media+'",{mode:"no-cors",headers:{"X-Access":"must-not-forward"}})</script>'
        elif path == '/page/xhr-unsent':
            body += '<script>let x=new XMLHttpRequest();x.open("GET","/media/unsent.m3u8");setTimeout(()=>fetch("'+media+'"),100)</script>'
        elif path == '/protected/media.m3u8':
            allowed = self.headers.get('X-Access') == 'media-secret' and self.headers.get('X-Parts') == 'one, two'
            payload = b'authorized-media' if allowed else b'missing-headers'
            self.send_response(200 if allowed else 403)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            try: self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        elif path == '/page/delayed':
            body += '<script>setTimeout(()=>fetch("'+media+'"),7000)</script>'
        elif path == '/page/negative':
            body += '<picture><source src="/image.png"></picture><video src="blob:fixture"></video><script>fetch("/page/empty?next=movie.mp4");</script>'
        elif path == '/page/ua':
            body += '<iframe src="/ua-frame"></iframe>'
        elif path == '/ua-frame' and self.headers.get('User-Agent') == 'Original-Provider-UA/1':
            body += '<script src="/ua-script"></script>'
        elif path == '/ua-script' and self.headers.get('User-Agent') == 'Original-Provider-UA/1':
            body = 'if(navigator.userAgent==="Original-Provider-UA/1") fetch("'+media+'");'
        elif path.startswith('/media/'):
            body = '#EXTM3U\n#EXT-X-ENDLIST\n'
        body += '' if path.startswith(('/media/', '/ua-script')) else '</body></html>'
        payload = body.encode()
        self.send_response(429 if path == '/page/unavailable' else 200)
        self.send_header('Content-Type', 'application/javascript' if path == '/ua-script' else 'application/vnd.apple.mpegurl' if path.startswith('/media/') else 'text/html')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        try: self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#
}
