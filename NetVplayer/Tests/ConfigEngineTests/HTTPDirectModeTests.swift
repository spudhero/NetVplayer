import Foundation
import Testing
@testable import Networking

@Test func httpDirectModeBypassesInheritedProxyAcrossReadMethods() async throws {
    try await withHTTPRouteTestIsolation {
        let fixture = try HTTPRouteProxyFixture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": fixture.port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": fixture.port
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(session: session)
        // The reserved .invalid hostname cannot work directly. A response proves
        // that the request reached the controlled proxy, without changing macOS settings.
        let url = "http://netvplayer-route.invalid/resource"
        let origin = try #require(URL(string: url))
        let savedProvider = ProxyDetector.shared.proxySettingsProvider
        defer { ProxyDetector.shared.proxySettingsProvider = savedProvider }

        ProxyDetector.shared.proxySettingsProvider = { (mode: 0, customPort: 0) }
        let automatic = try await client.get(url: url, timeout: 2, allowsProxyFallback: false)
        #expect(automatic.text == "controlled-proxy")

        ProxyDetector.shared.proxySettingsProvider = { (mode: 1, customPort: 0) }
        for routed in [client, client.constrained(to: origin)] {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let reads: [() async throws -> Void] = [
                { _ = try await routed.get(url: url, timeout: 2, allowsProxyFallback: false) },
                { _ = try await routed.request(url: url, method: .post, body: Data("fixture".utf8), timeout: 2, allowsProxyFallback: false) },
                { _ = try await routed.getBounded(url: url, maximumBytes: 64, timeout: 2, allowsProxyFallback: false) },
                { _ = try await routed.downloadFile(url: url, to: destination, timeout: 2, allowsProxyFallback: false) },
                { _ = try await routed.downloadBounded(url: url, to: destination, maximumBytes: 64, timeout: 2) }
            ]
            for read in reads {
                // A successful read here means the inherited proxy was used.
                defer { try? FileManager.default.removeItem(at: destination) }
                do {
                    try await read()
                    Issue.record("Direct mode sent a request through the inherited proxy")
                } catch {
                    #expect(error is URLError)
                }
            }
        }

        // An explicit per-request route remains authoritative, including when constrained.
        let pinned = client.withExplicitProxy(URL(string: "http://127.0.0.1:\(fixture.port)")!).constrained(to: origin)
        let explicit = try await pinned.get(url: url, timeout: 2, allowsProxyFallback: false)
        #expect(explicit.text == "controlled-proxy")

        // Switching back applies to the same already-created client.
        ProxyDetector.shared.proxySettingsProvider = { (mode: 0, customPort: 0) }
        let restored = try await client.get(url: url, timeout: 2, allowsProxyFallback: false)
        #expect(restored.text == "controlled-proxy")
    }
}

private final class HTTPRouteProxyFixture {
    let process: Process
    let port: Int

    init() throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", #"""
import http.server
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.do_GET()
    def do_GET(self):
        payload = b'controlled-proxy'
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
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
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else {
            if process.isRunning { process.terminate() }
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    deinit {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}
