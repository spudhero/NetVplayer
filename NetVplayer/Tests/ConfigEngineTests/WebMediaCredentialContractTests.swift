import AppKit
import Foundation
import Models
import Testing
@testable import ParseEngine
@testable import PlayerEngine

/// Only loopback traffic. Server receipts distinguish browser requests from
/// replay/player requests; cookie-store snapshots are never used as wire data.
@Suite(.serialized)
@MainActor
struct WebMediaCredentialContractTests {
    @Test func fetchOmitDoesNotResurrectPageCredentials() async throws {
        let server = try MediaCredentialServer()
        defer { server.stop() }
        let spec = try await resolve(server, scenario: "fetch-omit")
        let browser = try await server.waitForMedia(actor: "browser")
        #expect(browser.headers["cookie"] == nil && browser.headers["authorization"] == nil)
        #expect(browser.headers["x-page-token"] == nil)
        #expect(browser.headers["referer"] != "https://initial.invalid/private")
        expectNoPageCredentials(spec)
        #expect(spec.headers["User-Agent"] == "Original-Web-UA/1")
        let replay = try await server.replay(spec)
        #expect(replay == 200)
        let rows = try await server.requests()
        let page = try #require(rows.first { $0.path == "/scope/fetch-omit" })
        #expect(page.headers["cookie"] == "account=seed; Path=/scope")
        #expect(page.headers["authorization"] == "Bearer page-only")
        #expect(rows.last { $0.actor == "replay" }?.headers["cookie"] == nil)
        #expect(rows.last { $0.actor == "replay" }?.headers["authorization"] == nil)
    }

    @Test func hostAndPathChangesDoNotInheritPageCredentials() async throws {
        for scenario in ["outside-path", "cross-host", "xhr-cross-host"] {
            let server = try MediaCredentialServer()
            defer { server.stop() }
            let spec = try await resolve(server, scenario: scenario)
            let browser = try await server.waitForMedia(actor: "browser")
            #expect(browser.headers["cookie"] == nil && browser.headers["authorization"] == nil, "\(scenario)")
            expectNoPageCredentials(spec)
            #expect(try await server.replay(spec) == 200, "\(scenario)")
        }
    }

    @Test func explicitAuthorizationSurvivesFetchOmitAndXHR() async throws {
        for scenario in ["fetch-explicit", "xhr-explicit"] {
            let server = try MediaCredentialServer()
            defer { server.stop() }
            let spec = try await resolve(server, scenario: scenario)
            let browser = try await server.waitForMedia(actor: "browser")
            #expect(browser.headers["authorization"] == "Bearer media-only")
            expectNoPageCredentials(spec, explicitAuthorization: true)
            #expect(spec.headers.first { $0.key.lowercased() == "authorization" }?.value == "Bearer media-only")
            #expect(try await server.replay(spec) == 200)
        }
    }

    @Test func dynamicHTTPCookieIsNotReplayedAsTheInitialCookie() async throws {
        let server = try MediaCredentialServer()
        defer { server.stop() }
        let spec = try await resolve(server, scenario: "dynamic-cookie")
        let browser = try await server.waitForMedia(actor: "browser")
        #expect(browser.headers["cookie"] == "account=fresh")
        expectNoPageCredentials(spec)
        // This is an intentional capability boundary: without wire interception
        // a fresh HttpOnly cookie cannot safely be reconstructed for playback.
        #expect(try await server.replay(spec) == 403)
        let replay = try #require(try await server.requests().last { $0.actor == "replay" })
        #expect(replay.headers["cookie"] == nil)
    }

    @Test func frameCandidateDoesNotCopyTopLevelCredentials() async throws {
        let server = try MediaCredentialServer()
        defer { server.stop() }
        let spec = try await resolve(server, scenario: "frame")
        let browser = try await server.waitForMedia(actor: "browser")
        #expect(browser.headers["cookie"] == nil && browser.headers["authorization"] == nil)
        expectNoPageCredentials(spec)
        #expect(try await server.replay(spec) == 200)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
    func parsedCredentialRemovalReachesNativePlayerAfterCredentialedReload() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"])
        let server = try MediaCredentialServer()
        defer { server.stop() }
        var spec = try await resolve(server, scenario: "native-omit")
        let browser = try await server.waitForMedia(actor: "browser")
        #expect(browser.headers["cookie"] == nil && browser.headers["authorization"] == nil)
        expectNoPageCredentials(spec)
        // An explicit fixture marker identifies player requests at the server.
        spec.headers["X-Fixture-Actor"] = "player"
        spec.metadata["network.explicitDirect"] = "true"
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod)
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        await engine.play(spec: PlaySpec(url: URL(fileURLWithPath: path).absoluteString,
            headers: ["Cookie": "stale=old", "Authorization": "Bearer stale", "Referer": "https://old.invalid/"],
            mpvOptions: ["http-header-fields": "Cookie: source-old"]))
        try #require(await wait { !state.isMediaLoading || state.errorMessage != nil })
        try #require(state.errorMessage == nil)
        await engine.play(spec: spec)
        try #require(await wait { !state.isMediaLoading || state.errorMessage != nil })
        #expect(state.errorMessage == nil)
        try #require(await wait { engine.nativePropertyJSON("video-format")?.contains("h264") == true })
        let actual = try JSONDecoder().decode([String].self,
            from: Data(try #require(engine.nativePropertyJSON("http-header-fields")).utf8))
        #expect(Set(actual) == Set(spec.headers.map { "\($0.key): \($0.value)" }))
        #expect(engine.nativePropertyJSON("referrer") == "\"\"")
        let received = try await server.waitForMedia(actor: "player")
        #expect(received.headers["cookie"] == nil && received.headers["authorization"] == nil)
        #expect((received.headers["referer"] ?? "").isEmpty && received.headers["x-page-token"] == nil)
        #expect(received.headers["user-agent"] == "Original-Web-UA/1")
    }

    private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return predicate()
    }

    private func expectNoPageCredentials(_ spec: PlaySpec, explicitAuthorization: Bool = false) {
        let names = Set(spec.headers.keys.map { $0.lowercased() })
        #expect(!names.contains("cookie") && !names.contains("cookie2"))
        #expect(!names.contains("proxy-authorization") && !names.contains("x-page-token"))
        #expect(!names.contains("referer") && !names.contains("origin"))
        if !explicitAuthorization { #expect(!names.contains("authorization")) }
    }

    private func resolve(_ server: MediaCredentialServer, scenario: String) async throws -> PlaySpec {
        let root = server.diagnostics
        let engine = ParseEngine(httpClient: .shared, snifferFactory: { WebViewSniffer(diagnosticDirectory: root) })
        let spec = await engine.resolve(result: Result(url: server.url("/scope/" + scenario), header: [
            "cOoKiE": "account=seed; Path=/scope", "Authorization": "Bearer page-only",
            "Proxy-Authorization": "Basic page-only", "X-Page-Token": "page-token",
            "Referer": "https://initial.invalid/private", "Origin": "https://initial.invalid",
            "User-Agent": "Original-Web-UA/1"
        ]), parse: nil)
        try #require(engine.lastFailure == nil)
        return spec
    }
}

private struct MediaCredentialRequest: Decodable {
    let path: String
    let headers: [String: String]
    let actor: String
}

@MainActor
private final class MediaCredentialServer {
    let diagnostics: URL
    private let process: Process
    private let port: Int
    private let temporaryRoot: Bool
    init() throws {
        if let path = ProcessInfo.processInfo.environment["NETVPLAYER_WEB_CREDENTIAL_EVIDENCE_DIR"] {
            diagnostics = URL(fileURLWithPath: path).appendingPathComponent("diagnostics")
            temporaryRoot = false
        } else {
            diagnostics = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            temporaryRoot = true
        }
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
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
    func stop() {
        let stopped = stopOwnedFixtureProcess(process)
        #expect(stopped)
        if stopped && temporaryRoot { try? FileManager.default.removeItem(at: diagnostics) }
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }
    func requests() async throws -> [MediaCredentialRequest] {
        let client = session(); defer { client.invalidateAndCancel() }
        let (data, _) = try await client.data(from: URL(string: url("/records"))!)
        return try JSONDecoder().decode([MediaCredentialRequest].self, from: data)
    }
    func waitForMedia(actor: String) async throws -> MediaCredentialRequest {
        for _ in 0..<100 {
            if let row = try await requests().first(where: { ($0.path.hasSuffix(".m3u8") || $0.path.hasSuffix(".mp4")) && $0.actor == actor }) { return row }
            try await Task.sleep(for: .milliseconds(20))
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
    private static let script = #"""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import os, json, uuid
rows=[]
capture=None
if os.environ.get('NETVPLAYER_WEB_CREDENTIAL_EVIDENCE_DIR'):
    folder=Path(os.environ['NETVPLAYER_WEB_CREDENTIAL_EVIDENCE_DIR'])
    folder.mkdir(parents=True,exist_ok=True)
    dest=folder/('requests-'+str(uuid.uuid4())+'.jsonl')
    capture=dest.open('x');dest.chmod(0o600)
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_OPTIONS(self):
        self.send_response(204)
        self.cors();self.end_headers()
    def cors(self):
        self.send_header('Access-Control-Allow-Origin',self.headers.get('Origin','*'))
        self.send_header('Access-Control-Allow-Credentials','true')
        self.send_header('Access-Control-Allow-Headers','authorization,x-fixture-actor')
    def do_GET(self):
        path=self.path.split('?')[0]
        actor=self.headers.get('X-Fixture-Actor','browser')
        if path=='/records':
            payload=json.dumps(rows).encode();mime='application/json';status=200;extra=[]
        else:
            row={'path':path,'headers':{k.lower():v for k,v in self.headers.items()},'actor':actor}
            rows.append(row)
            if capture: capture.write(json.dumps(row)+'\n');capture.flush()
            status=200;mime='text/html';extra=[]
            media='/scope/'+path.rsplit('/',1)[-1]+'.m3u8'
            cross='http://localhost:'+str(self.server.server_port)+'/outside/media.m3u8'
            scripts={
                '/scope/native-omit': "fetch('/scope/native-omit.mp4',{credentials:'omit'})",
                '/scope/fetch-omit': "fetch('"+media+"',{credentials:'omit'})",
                '/scope/outside-path': "fetch('/outside/media.m3u8',{credentials:'include'})",
                '/scope/cross-host': "fetch('"+cross+"')",
                '/scope/xhr-cross-host': "let x=new XMLHttpRequest();x.open('GET','"+cross+"');x.send()",
                '/scope/fetch-explicit': "fetch(new Request('"+media+"',{credentials:'include',headers:{Authorization:'Bearer old'}}),{credentials:'omit',headers:{Authorization:'Bearer media-only'}})",
                '/scope/xhr-explicit': "let x=new XMLHttpRequest();x.open('GET','"+media+"');x.setRequestHeader('Authorization','Bearer media-only');x.send()",
                '/scope/dynamic-cookie': "fetch('"+media+"',{credentials:'include'})"
            }
            if path in scripts:
                payload=('<script>'+scripts[path]+';</script>').encode()
                if path=='/scope/dynamic-cookie': extra=[('Set-Cookie','account=fresh; Path=/scope; HttpOnly')]
            elif path=='/scope/frame':
                payload=('<iframe src="http://localhost:'+str(self.server.server_port)+'/frame"></iframe>').encode()
            elif path=='/frame':
                payload=b"<script>let x=new XMLHttpRequest();x.open('GET','/outside/media.m3u8',false);x.send();</script>"
            elif path.endswith(('.m3u8','.mp4')):
                mime='application/vnd.apple.mpegurl'
                if actor!='browser' and (self.headers.get('Cookie') or self.headers.get('Authorization')=='Bearer page-only' or self.headers.get('X-Page-Token')):status=403
                if path.endswith('explicit.m3u8') and self.headers.get('Authorization')!='Bearer media-only':status=403
                if path.endswith('dynamic-cookie.m3u8') and self.headers.get('Cookie')!='account=fresh':status=403
                payload=Path(os.environ['NETVPLAYER_FEATURE_FIXTURE']).read_bytes() if path.endswith('.mp4') and status==200 else b'#EXTM3U\n#EXT-X-ENDLIST\n'
                if path.endswith('.mp4'):mime='video/mp4'
            else: payload=b'ok'
        self.send_response(status);self.cors()
        for k,v in extra:self.send_header(k,v)
        self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(payload)));self.end_headers()
        try:self.wfile.write(payload)
        except (BrokenPipeError,ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""#
}
