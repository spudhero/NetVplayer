import Foundation
import Testing
import WebKit
@testable import ParseEngine

/// Browser-side results below are checked against headers received by the local
/// HTTP server. They do not turn a WK cookie-store snapshot into a wire capture.
@Suite(.serialized)
@MainActor
struct WebViewCookieContractTests {
    @Test func seedParsingKeepsSetCookieSemanticsAndRejectsUnrelatedDomains() throws {
        let url = try #require(URL(string: "https://video.example.test/scope/start"))
        let seeds = WebViewSniffer.seedCookies(headers: ["cookie": "sid=a=b; second=ignored; HttpOnly; Secure"], url: url)
        let seed = try #require(seeds.first)
        #expect(seeds.count == 1 && seed.name == "sid" && seed.value == "a=b")
        #expect(seed.path == "/scope" && seed.isSecure && seed.isHTTPOnly)
        #expect(WebViewSniffer.seedCookies(headers: ["Cookie": "sid=x; Domain=other.test"], url: url).isEmpty)
        #expect(WebViewSniffer.seedCookies(headers: ["Cookie": "sid=x; Domain=example.test"], url: url).count == 1)
        #expect(WebViewSniffer.seedCookies(headers: ["Cookie": "sid=x\r\nInjected: yes"], url: url).isEmpty)
        #expect(WebViewSniffer.seedCookies(headers: ["Cookie": "sid=x; Secure"],
            url: URL(string: "http://video.example.test/scope/start")!).isEmpty)
        #expect(WebViewSniffer.seedCookies(headers: [:], url: url).isEmpty)
    }

    @Test func httpOnlyExpiryAndPathBoundaryAreEnforcedByTheBrowser() async throws {
        let server = try CookieContractServer()
        defer { server.stop() }
        _ = try await WebViewSniffer().sniff(url: server.url("/attributes/start"), timeout: 5)
        let rows = try await server.requests()
        let probe = try #require(rows.first { $0.path == "/attributes/probe" })
        #expect(Set(probe.cookie.components(separatedBy: "; ")) == ["visible=one", "hidden=two"])
        #expect(probe.query == "js=visible%3Done")
        #expect(rows.first { $0.path == "/attributesevil/probe" }?.cookie == "")
    }

    @Test func localStorageAndAccountStateAreIsolatedEvenDuringConcurrentSniffs() async throws {
        let server = try CookieContractServer()
        defer { server.stop() }
        let first = WebViewSniffer(), second = WebViewSniffer()
        let a = Task { try await first.sniff(url: server.url("/storage/set"),
            headers: ["Cookie": "account=A; Path=/"], timeout: 5) }
        let b = Task { try await second.sniff(url: server.url("/storage/read"),
            headers: ["Cookie": "account=B; Path=/"], timeout: 5) }
        _ = try await a.value
        _ = try await b.value
        _ = try await first.sniff(url: server.url("/storage/read"), timeout: 5)
        let rows = try await server.requests()
        #expect(rows.first { $0.path == "/storage/set-probe" }?.cookie == "account=A")
        #expect(rows.filter { $0.path == "/storage/read-probe" }.map(\.cookie) == ["account=B", ""])
        #expect(rows.filter { $0.path == "/storage/read-probe" }.allSatisfy { $0.query == "value=null" })
    }

    @Test func crossSiteFrameDoesNotReceiveLaxFirstPartyCookie() async throws {
        let server = try CookieContractServer()
        defer { server.stop() }
        _ = try await WebViewSniffer().sniff(url: server.url("/third/set"), timeout: 5)
        let rows = try await server.requests()
        #expect(rows.first { $0.path == "/third/first-party" }?.cookie == "third=lax")
        #expect(rows.first { $0.path == "/third/frame" }?.cookie == "")
        #expect(rows.first { $0.path == "/third/probe" }?.cookie == "")
        // This is a real cross-site HTTP SameSite control, not proof of Android's
        // third-party opt-in or a secure SameSite=None/ITP compatibility claim.
    }

    @Test func diagnosticsSeparateStoreStateFromCredentialOmissionAndWireHeaders() async throws {
        let server = try CookieContractServer()
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = try await WebViewSniffer(diagnosticDirectory: root).sniff(
            url: server.url("/diagnostics/start"), timeout: 5)
        #expect(spec.headers.keys.allSatisfy { $0.lowercased() != "cookie" })
        let path = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: path)
        try saveDiagnostics(data)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(server.url("")) && !text.contains("private-value") && !text.contains("diagnostic-cookie"))
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["schema"] as? Int == 7)
        let events = try #require(report["events"] as? [[String: Any]])
        let candidate = try #require(events.first { $0["stage"] as? String == "candidate" })
        #expect(candidate["credentialsMode"] as? String == "omit")
        #expect(candidate["wireHeadersObserved"] as? Bool == false)
        let snapshot = try #require(candidate["cookieStoreSnapshot"] as? [String: Any])
        #expect(snapshot["count"] as? Int == 1)
        #expect(snapshot["provenance"] as? String == "WKHTTPCookieStore")
        #expect(snapshot["requestEligibilityEvaluated"] as? Bool == false)
        let fields = try #require(snapshot["fields"] as? [[String: Any]])
        #expect(fields.first?["httpOnly"] as? Bool == true)
        #expect(events.contains { $0["stage"] as? String == "cookieSeed" && $0["store"] as? String == "nonPersistentPerSniff" })
        let rows = try await server.requests()
        #expect(rows.first { $0.path == "/diagnostics/omitted" }?.cookie == "")
        #expect(rows.first { $0.path == "/diagnostics/omitted" }?.referer == server.url("/diagnostics/start"))
        #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func cookieDiagnosticsAreBounded() async throws {
        let server = try CookieContractServer()
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await WebViewSniffer(diagnosticDirectory: root).sniff(url: server.url("/diagnostics/many"), timeout: 5)
        let path = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: path)
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(report["events"] as? [[String: Any]])
        #expect(events.count <= 128)
        let snapshot = try #require(events.first { $0["stage"] as? String == "candidate" }?["cookieStoreSnapshot"] as? [String: Any])
        #expect(snapshot["count"] as? Int == 80)
        #expect((snapshot["fields"] as? [[String: Any]])?.count == 64)
        #expect(snapshot["truncated"] as? Bool == true)
        try saveDiagnostics(data)
    }

    private func saveDiagnostics(_ data: Data) throws {
        guard let folder = ProcessInfo.processInfo.environment["NETVPLAYER_WEB_COOKIE_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("diagnostic-" + UUID().uuidString + ".json")
        try data.write(to: path, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    @Test func seededCookieReachesFramesWithDefaultPathAndHostScope() async throws {
        let server = try CookieContractServer()
        defer { server.stop() }
        _ = try await WebViewSniffer().sniff(url: server.url("/scope/start"),
            headers: ["cOoKiE": "seed=alpha; second=not-a-separate-seed"], timeout: 5)
        let rows = try await server.requests()
        #expect(rows.first { $0.path == "/scope/start" }?.cookie == "seed=alpha; second=not-a-separate-seed")
        #expect(rows.first { $0.path == "/scope/frame" }?.cookie == "seed=alpha")
        #expect(rows.first { $0.path == "/scope/probe" }?.cookie == "seed=alpha")
        #expect(rows.first { $0.path == "/outside/probe" }?.cookie == "")
        #expect(rows.first { $0.path == "/scope/other-host" }?.cookie == "")
    }

    @Test func responseCookiesUpdateWithinSessionButDoNotSurviveReuseOrNewInstances() async throws {
        let server = try CookieContractServer()
        defer { server.stop() }
        let sniffer = WebViewSniffer()
        _ = try await sniffer.sniff(url: server.url("/session/set"), timeout: 5)
        _ = try await sniffer.sniff(url: server.url("/session/read"), timeout: 5)
        _ = try await WebViewSniffer().sniff(url: server.url("/session/read"), timeout: 5)
        let rows = try await server.requests()
        #expect(rows.first { $0.path == "/session/probe" }?.cookie == "account=server-updated")
        #expect(rows.filter { $0.path == "/session/read" }.count == 2)
        #expect(rows.filter { $0.path == "/session/read" }.allSatisfy { $0.cookie.isEmpty })
    }

    @Test func credentialsModeControlsActualSameOriginSubrequests() async throws {
        let server = try CookieContractServer()
        defer { server.stop() }
        _ = try await WebViewSniffer().sniff(url: server.url("/credentials/start"),
            headers: ["Cookie": "account=seeded; Path=/"], timeout: 5)
        let rows = try await server.requests()
        #expect(rows.first { $0.path == "/credentials/omit" }?.cookie == "")
        #expect(rows.first { $0.path == "/credentials/include" }?.cookie == "account=seeded")
        #expect(rows.first { $0.path == "/credentials/xhr" }?.cookie == "account=seeded")
    }

    @Test func redirectCookiesAreObservedOnlyAtTheirDestinationScope() async throws {
        let server = try CookieContractServer()
        defer { server.stop() }
        _ = try await WebViewSniffer().sniff(url: server.url("/redirect/start"), timeout: 5)
        let rows = try await server.requests()
        #expect(rows.first { $0.path == "/redirect/landing" }?.cookie == "redirect=accepted")
        #expect(rows.first { $0.path == "/outside/probe" }?.cookie == "")
    }

    @Test func cancelledAndReplacedSessionsCannotCarryCookiesIntoNewAccount() async throws {
        let server = try CookieContractServer()
        defer { server.stop() }
        let sniffer = WebViewSniffer()
        for cancel in [true, false] {
            let old = Task { try await sniffer.sniff(url: server.url("/session/hold"),
                headers: ["Cookie": "account=old; Path=/"], timeout: 5) }
            try await server.waitFor("/session/held", count: cancel ? 1 : 2)
            if cancel { old.cancel() }
            let current = Task { try await sniffer.sniff(url: server.url("/session/read"),
                headers: ["Cookie": "account=new; Path=/"], timeout: 5) }
            do { _ = try await old.value; Issue.record("old session completed") }
            catch { #expect(error is CancellationError) }
            _ = try await current.value
        }
        _ = try await sniffer.sniff(url: server.url("/session/read"), timeout: 5)
        let rows = try await server.requests()
        #expect(rows.filter { $0.path == "/session/read-probe" }.map(\.cookie) == ["account=new", "account=new", ""])
    }
}

private struct CookieRequest: Decodable {
    let path: String
    let cookie: String
    let referer: String
    let origin: String
    let query: String
}

private final class CookieContractServer {
    private let process: Process
    private let port: Int
    init() throws {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-u", "-c", Self.script]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        process = task
        guard let text = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8),
              let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            task.terminate(); throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }
    func url(_ path: String) -> String { "http://127.0.0.1:\(port)" + path }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    func requests() async throws -> [CookieRequest] {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: URL(string: url("/records"))!)
        return try JSONDecoder().decode([CookieRequest].self, from: data)
    }
    func waitFor(_ path: String, count: Int) async throws {
        for _ in 0..<150 {
            if try await requests().filter({ $0.path == path }).count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }
    private static let script = #"""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import json, os, uuid
from pathlib import Path
capture = None
if os.environ.get('NETVPLAYER_WEB_COOKIE_EVIDENCE_DIR'):
    folder = Path(os.environ['NETVPLAYER_WEB_COOKIE_EVIDENCE_DIR'])
    folder.mkdir(parents=True,exist_ok=True)
    capture_path = folder / ('requests-'+str(uuid.uuid4())+'.jsonl')
    capture = capture_path.open('x')
    capture_path.chmod(0o600)
rows = []
finish = "let v=document.createElement('video');v.src='/media/done.m3u8';document.body.append(v);"
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        path = self.path.split('?')[0]
        if path != '/records':
            rows.append(dict(path=path, cookie=self.headers.get('Cookie',''), referer=self.headers.get('Referer',''), origin=self.headers.get('Origin',''), query=self.path.partition('?')[2], headers=dict(self.headers)))
            if capture:
                capture.write(json.dumps(rows[-1])+'\n');capture.flush()
        headers, status, mime = [], 200, 'text/html'
        script = ''
        if path == '/records':
            body, mime = json.dumps(rows), 'application/json'
        elif path == '/attributes/start':
            headers += [('Set-Cookie','visible=one; Path=/attributes'),('Set-Cookie','hidden=two; Path=/attributes; HttpOnly'),('Set-Cookie','expired=three; Path=/attributes; Max-Age=0')]
            script = "await fetch('/attributes/probe?js='+encodeURIComponent(document.cookie));await fetch('/attributesevil/probe');"
        elif path == '/storage/set':
            script = "localStorage.setItem('account','A');await fetch('/storage/set-probe');"
        elif path == '/storage/read':
            script = "await fetch('/storage/read-probe?value='+localStorage.getItem('account'));"
        elif path == '/third/set':
            headers.append(('Set-Cookie','third=lax; Path=/third; SameSite=Lax'))
            body = "<script>fetch('/third/first-party').then(()=>location.href='http://localhost:%d/third/top')</script>" % self.server.server_port
        elif path == '/third/top':
            body = '<iframe src="http://127.0.0.1:%d/third/frame"></iframe>' % self.server.server_port
        elif path == '/third/frame':
            script = "await fetch('/third/probe',{credentials:'include'});"
        elif path == '/diagnostics/many':
            headers += [('Set-Cookie','fixture%02d=bounded; Path=/; HttpOnly' % i) for i in range(80)]
            script = "await fetch('/diagnostics/probe');"
        elif path == '/diagnostics/start':
            headers.append(('Set-Cookie','diagnostic-cookie=private-value; Path=/; HttpOnly'))
            script = "await fetch('/diagnostics/omitted',{credentials:'omit'});fetch('/media/diagnostic.m3u8',{credentials:'omit'});"
        elif path == '/scope/start':
            body = '<iframe src="/scope/frame"></iframe>'
        elif path == '/scope/frame':
            script = "await fetch('/scope/probe'); await fetch('/outside/probe'); await fetch('http://localhost:%d/scope/other-host',{mode:'no-cors',credentials:'include'});" % self.server.server_port
        elif path == '/session/set':
            headers.append(('Set-Cookie','account=server-updated; Path=/; HttpOnly'))
            script = "await fetch('/session/probe');"
        elif path == '/session/hold':
            headers.append(('Set-Cookie','stale=must-not-survive; Path=/; HttpOnly'))
            body = "<script>fetch('/session/held')</script>"
        elif path == '/session/read':
            script = "await fetch('/session/read-probe');"
        elif path == '/credentials/start':
            script = "await fetch('/credentials/omit',{credentials:'omit'});await fetch('/credentials/include',{credentials:'include'});await new Promise(resolve=>{let x=new XMLHttpRequest();x.open('GET','/credentials/xhr');x.onload=resolve;x.send()});"
        elif path == '/redirect/start':
            headers += [('Location','/redirect/landing'),('Set-Cookie','redirect=accepted; Path=/redirect; HttpOnly')]
            body, status = '', 302
        elif path == '/redirect/landing':
            script = "await fetch('/outside/probe');"
        else:
            body = 'ok'
        if script: body = '<script>(async()=>{'+script+finish+'})()</script>'
        payload = body.encode()
        self.send_response(status)
        for k,v in headers: self.send_header(k,v)
        self.send_header('Content-Type',mime)
        self.send_header('Content-Length',str(len(payload)))
        self.end_headers()
        try: self.wfile.write(payload)
        except (BrokenPipeError,ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""#
}
