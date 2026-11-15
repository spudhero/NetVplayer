import Foundation
import Models
import Testing
import ProxyServer

struct AndroidPlaybackMediaContextTests {
    @Test func originalHostDiscoveryProbeIsExactAndDoesNotEnterThePlaybackProxy() async throws {
        let server = ProxyServer()
        server.proxyHandler = { _ in ProxyResponse(statusCode: 418, contentType: "text/plain", data: Data("delegated".utf8)) }
        try server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(server.port)" + path)))
            request.httpMethod = method
            request.allHTTPHeaderFields = headers
            let (data, response) = try await session.data(for: request)
            return (data, try #require(response as? HTTPURLResponse))
        }
        for path in ["/proxy?do=ck", "/proxy/play?do=ck"] {
            let probe = try await request(path)
            #expect(probe.1.statusCode == 200 && probe.0 == Data("ok".utf8))
            #expect(probe.1.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            let head = try await request(path, method: "HEAD")
            #expect(head.1.statusCode == 200 && head.0.isEmpty)
            #expect(try await request(path, method: "POST").1.statusCode == 405)
        }
        for path in ["/proxy?do=ck&route=fixture", "/proxy?do=ck&do=ck", "/proxy/fixture?do=ck", "/proxy?do=other", "/proxy"] {
            #expect(try await request(path).1.statusCode == 418)
        }
        #expect(try await request("/proxy", headers: ["do": "ck"]).1.statusCode == 418)
    }

    @Test func mediaLeaseUsesActualTitlesAndRejectsDifferentSources() throws {
        let context = AndroidPlaybackMediaContext()
        let source = String(repeating: "a", count: 64)
        #expect(context.snapshot() == nil)
        let owner = try #require(context.begin(sourceIdentity: source, title: "Current film", episode: "Episode 02"))
        let json = try #require(context.snapshot(expectedSource: source))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(object == ["title": "Current film", "artist": "Episode 02", "sourceIdentity": source])
        #expect(context.snapshot(expectedSource: String(repeating: "b", count: 64)) == nil)
        context.end(owner)
        #expect(context.snapshot() == nil)
    }

    @Test func previousRequestCannotClearReplacementMediaAndInvalidInputIsRejected() throws {
        let context = AndroidPlaybackMediaContext()
        let source = String(repeating: "a", count: 64)
        let first = try #require(context.begin(sourceIdentity: source, title: "Film one", episode: "01"))
        let second = try #require(context.begin(sourceIdentity: source, title: "Film two", episode: "02"))
        context.end(first)
        #expect(context.snapshot()?.contains("Film two") == true)
        context.end(second)
        #expect(context.snapshot() == nil)
        #expect(context.begin(sourceIdentity: "invalid", title: "Film", episode: "01") == nil)
        #expect(context.begin(sourceIdentity: source, title: "  ", episode: "01") == nil)
        #expect(context.begin(sourceIdentity: source, title: String(repeating: "x", count: 2049), episode: "01") == nil)
        #expect(context.snapshot() == nil)
    }

    @Test func mediaEndpointReturnsOnlyActiveSourceMetadataWithoutCaching() async throws {
        let server = ProxyServer()
        try server.start()
        defer { server.stop() }
        let source = String(repeating: "a", count: 64)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(server.port)" + path)))
            request.httpMethod = method
            let (data, response) = try await session.data(for: request)
            return (data, try #require(response as? HTTPURLResponse))
        }
        let absent = try await request("/media")
        #expect(absent.1.statusCode == 204 && absent.0.isEmpty)
        let owner = try #require(server.androidPlaybackMedia.begin(sourceIdentity: source, title: "Fixture film", episode: "02"))
        let actual = try await request("/media")
        #expect(actual.1.statusCode == 200)
        #expect(actual.1.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let fields = try #require(JSONSerialization.jsonObject(with: actual.0) as? [String: String])
        #expect(fields["title"] == "Fixture film" && fields["artist"] == "02")
        let head = try await request("/media?source=" + source, method: "HEAD")
        #expect(head.1.statusCode == 200 && head.0.isEmpty)
        let other = try await request("/media?source=" + String(repeating: "b", count: 64))
        #expect(other.1.statusCode == 204 && other.0.isEmpty)
        let rejected = try await request("/media", method: "POST")
        #expect(rejected.1.statusCode == 405)
        server.androidPlaybackMedia.end(owner)
        let ended = try await request("/media")
        #expect(ended.1.statusCode == 204 && ended.0.isEmpty)
    }

}
