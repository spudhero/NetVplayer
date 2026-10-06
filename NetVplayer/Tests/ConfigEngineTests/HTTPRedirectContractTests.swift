import Foundation
import Testing
@testable import Networking

@Test func redirectContractChecksEveryOriginComponentAndPreservesMediaHeaders() throws {
    var previous = URLRequest(url: try #require(URL(string: "https://origin.test/start")))
    previous.httpMethod = "POST"
    previous.httpBody = Data("payload".utf8)
    for (key, value) in ["Authorization": "Bearer fixture", "Cookie": "session=fixture", "Proxy-Authorization": "fixture",
                         "Range": "bytes=10-20", "User-Agent": "fixture-agent", "Content-Type": "application/json"] {
        previous.setValue(value, forHTTPHeaderField: key)
    }
    for target in ["https://other.test/end", "https://origin.test:444/end", "http://origin.test/end"] {
        let result = try #require(HTTPRedirectPolicy.redirected(previous, proposed: URLRequest(url: URL(string: target)!), status: 307, hop: 1))
        #expect(result.httpBody == previous.httpBody)
        #expect(result.httpMethod == "POST")
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(result.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "Range") == "bytes=10-20")
        #expect(result.value(forHTTPHeaderField: "User-Agent") == "fixture-agent")
    }
    let same = try #require(HTTPRedirectPolicy.redirected(previous, proposed: URLRequest(url: URL(string: "https://origin.test:443/end")!), status: 308, hop: 20))
    #expect(same.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    #expect(HTTPRedirectPolicy.redirected(previous, proposed: same, status: 308, hop: 21) == nil)
    #expect(HTTPRedirectPolicy.redirected(previous, proposed: URLRequest(url: URL(string: "https://other.test/end")!), status: 302,
                                        allowedOrigin: previous.url, hop: 1) == nil)
}

@Test func redirectContractConvertsPostButRetainsHeadAndPut() throws {
    var previous = URLRequest(url: URL(string: "https://origin.test/start")!)
    previous.httpMethod = "POST"
    previous.httpBody = Data("payload".utf8)
    previous.setValue("application/json", forHTTPHeaderField: "Content-Type")
    previous.setValue("7", forHTTPHeaderField: "Content-Length")
    let proposed = URLRequest(url: URL(string: "https://origin.test/end")!)
    for status in [301, 302, 303] {
        let result = try #require(HTTPRedirectPolicy.redirected(previous, proposed: proposed, status: status, hop: 1))
        #expect(result.httpMethod == "GET")
        #expect(result.httpBody == nil)
        #expect(result.value(forHTTPHeaderField: "Content-Length") == nil)
        #expect(result.value(forHTTPHeaderField: "Content-Type") == nil)
    }
    previous.httpMethod = "HEAD"
    #expect(HTTPRedirectPolicy.redirected(previous, proposed: proposed, status: 303, hop: 1)?.httpMethod == "HEAD")
    previous.httpMethod = "PUT"
    #expect(HTTPRedirectPolicy.redirected(previous, proposed: proposed, status: 302, hop: 1)?.httpMethod == "PUT")
    #expect(HTTPRedirectPolicy.isLoopback(URL(string: "http://[::1]/")!))
    #expect(HTTPRedirectPolicy.isLoopback(URL(string: "http://127.0.0.2/")!))
    #expect(!HTTPRedirectPolicy.isLoopback(URL(string: "https://127.example.test/")!))
}

@Test func redirectContractWorksForRealRequestsStreamsAndDownloads() async throws {
    let fixture = try RedirectSocketFixture()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.httpCookieStorage = nil
    let client = HTTPClient(session: URLSession(configuration: configuration))
    let headers = ["Authorization": "Bearer fixture", "Cookie": "session=fixture", "X-Api-Key": "fixture"]
    let same = try await client.get(url: fixture.base + "/same", headers: headers, allowsProxyFallback: false)
    #expect(same.text.contains("Bearer fixture"))
    let cross = try await client.get(url: fixture.base + "/cross", headers: headers, allowsProxyFallback: false)
    #expect(!cross.text.contains("fixture"))
    let bounded = try await client.getBounded(url: fixture.base + "/cross", headers: headers, maximumBytes: 4096, allowsProxyFallback: false)
    #expect(!bounded.text.contains("fixture"))
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    _ = try await client.downloadFile(url: fixture.base + "/cross", headers: headers, to: destination, allowsProxyFallback: false)
    #expect(!String(decoding: try Data(contentsOf: destination), as: UTF8.self).contains("fixture"))
    let keep = try await client.request(url: fixture.base + "/307", method: .post, body: Data("body".utf8), allowsProxyFallback: false)
    #expect(keep.text.contains("POST"))
    #expect(keep.text.contains("body"))
    let change = try await client.request(url: fixture.base + "/302", method: .post, body: Data("body".utf8), allowsProxyFallback: false)
    #expect(change.text.contains("GET"))
    #expect(!change.text.contains("body"))
}

private final class RedirectSocketFixture {
    let process: Process
    let base: String
    init() throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", #"""
import http.server, json, threading
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.handle_request()
    def do_POST(self): self.handle_request()
    def handle_request(self):
        data = self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode()
        target = None
        if self.path == '/same': target = '/echo'
        if self.path == '/cross': target = 'http://127.0.0.1:%d/echo' % other.server_port
        if self.path in ['/302', '/307']: target = '/echo'
        if target:
            self.send_response(307 if self.path == '/307' else 302)
            self.send_header('Location', target)
            self.send_header('Content-Length', '0')
            self.end_headers()
        else:
            payload = json.dumps([self.command, data, self.headers.get('Authorization'), self.headers.get('Cookie'), self.headers.get('X-Api-Key')]).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
other = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=other.serve_forever, daemon=True).start()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
            if line.count > 16 { break }
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else {
            process.terminate()
            throw URLError(.cannotConnectToHost)
        }
        base = "http://127.0.0.1:\(port)"
    }
    deinit { if process.isRunning { process.terminate() } }
}
