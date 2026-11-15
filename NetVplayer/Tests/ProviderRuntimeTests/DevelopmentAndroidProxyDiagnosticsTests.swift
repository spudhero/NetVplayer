#if DEBUG
import CryptoKit
import Foundation
import Models
import ProviderSDK
import Testing
@testable import SpiderEngine

@Test func developmentAndroidProxyShapeCountsPlaylistReferencesWithoutValues() {
    let privateMarker = "SECRET-PLAYLIST-HEADER-MARKER"
    let playlist = """
    #EXTM3U
    # comment \(privateMarker)
    #EXT-X-STREAM-INF:BANDWIDTH=12345
    variant/child.m3u8?token=\(privateMarker)
    #EXT-X-MEDIA:TYPE=AUDIO,URI="http://localhost:9978/proxy?secret=\(privateMarker)"
    #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.test/a,b?token=\(privateMarker)"
    #EXT-X-MAP:URI="//[::1]:-1/proxy?secret=\(privateMarker)"
    #EXTINF:3,
    http://127.0.0.1:-1/proxy?secret=\(privateMarker)
    #EXTINF:3,
    /media/segment.ts
    """
    let response = ProxyResponse(contentType: "application/vnd.apple.mpegURL", data: Data(playlist.utf8),
        headers: ["Content-Encoding": privateMarker, "Location": "https://secret.example.test/" + privateMarker])
    let payload = ProviderProxyPayload(statusCode: 200, bodyBase64: Data(playlist.utf8).base64EncodedString())
    let summary = DevelopmentAndroidProxyDiagnostics.summary(response: response, payload: payload)
    let fields = androidProxyShapeFields(summary)
    #expect(fields["body_kind"] == "base64")
    #expect(fields["mime"] == "hls" && fields["hls"] == "1")
    #expect(fields["master"] == "2" && fields["media"] == "2")
    #expect(fields["uris"] == "6" && fields["uri_lines"] == "3" && fields["uri_attributes"] == "3")
    #expect(fields["key_uri"] == "1" && fields["map_uri"] == "1")
    #expect(fields["relative"] == "2" && fields["absolute"] == "4" && fields["http"] == "4")
    #expect(fields["loopback"] == "3" && fields["knownloopback"] == "1" && fields["negativeport"] == "2")
    #expect(fields["encoding"] == "1" && fields["location"] == "1" && fields["truncated"] == "0")
    for secret in [privateMarker, "example.test", "localhost", "127.0.0.1", "#EXT", "a,b", "token="] {
        #expect(!summary.contains(secret))
    }
    #expect(summary.utf8.count <= 1024 && !summary.contains("\n"))
}

@Test func developmentAndroidProxyShapeDoesNotTrustMIMEOrNonPlaylistBodies() {
    let secret = "PRIVATE-MIME-BODY-COOKIE"
    let response = ProxyResponse(statusCode: 302, contentType: secret + "\nurl=https://secret.example.test/", data: Data(secret.utf8))
    let payload = ProviderProxyPayload(statusCode: 302, body: secret, bodyBase64: "not-logged",
        headers: ["lOcAtIoN": secret, "CONTENT-ENCODING": secret, secret: secret])
    let summary = DevelopmentAndroidProxyDiagnostics.summary(response: response, payload: payload)
    let fields = androidProxyShapeFields(summary)
    #expect(fields["mime"] == "other" && fields["body_kind"] == "both")
    #expect(fields["status"] == "302" && fields["hls"] == "0" && fields["uris"] == "0")
    #expect(fields["encoding"] == "1" && fields["location"] == "1")
    #expect(!summary.contains(secret) && !summary.contains("example.test") && !summary.contains("\n"))
}

@Test func developmentAndroidProxyShapeHandlesEmptyAndCompressedBodies() {
    let empty = DevelopmentAndroidProxyDiagnostics.summary(response: ProxyResponse(data: Data()), payload: ProviderProxyPayload(statusCode: 200))
    let emptyFields = androidProxyShapeFields(empty)
    #expect(emptyFields["empty"] == "1" && emptyFields["bytes"] == "0" && emptyFields["body_kind"] == "absent")
    #expect(emptyFields["utf8"] == "valid" && emptyFields["hls"] == "0")
    let binary = DevelopmentAndroidProxyDiagnostics.summary(
        response: ProxyResponse(data: Data([0x1f, 0x8b, 0xff, 0x00])), payload: ProviderProxyPayload(statusCode: 200, bodyBase64: "unused"))
    let binaryFields = androidProxyShapeFields(binary)
    #expect(binaryFields["gzip"] == "1" && binaryFields["utf8"] == "invalid" && binaryFields["hls"] == "0")
}

@Test func developmentAndroidProxyShapeRejectsLoopbackLookalikesAndCountsOtherSchemes() {
    let playlist = """
    #EXTM3U
    https://127.0.0.1.attacker.example.test:-1/not-loopback
    http://localhost@remote.example.test:-1/not-loopback
    http://[::1]:9979/proxy
    //127.0.0.1:-2/proxy
    data:application/octet-stream;base64,secret
    segments/one.ts
    """
    let fields = androidProxyShapeFields(DevelopmentAndroidProxyDiagnostics.summary(
        response: ProxyResponse(data: Data(playlist.utf8)), payload: ProviderProxyPayload(statusCode: 200, body: playlist)))
    #expect(fields["loopback"] == "2" && fields["knownloopback"] == "1" && fields["negativeport"] == "1")
    #expect(fields["absolute"] == "5" && fields["other_scheme"] == "1" && fields["relative"] == "1")
}

@Test func developmentAndroidProxyShapeHonorsByteLineAndReferenceLimits() {
    let afterLimit = "http://127.0.0.1:-1/DO-NOT-SCAN"
    let large = "#EXTM3U\n" + String(repeating: "# padding\n", count: 110_000) + afterLimit
    let largeFields = androidProxyShapeFields(DevelopmentAndroidProxyDiagnostics.summary(
        response: ProxyResponse(data: Data(large.utf8)), payload: ProviderProxyPayload(statusCode: 200, body: large)))
    #expect(largeFields["sampled"] == String(1024 * 1024) && largeFields["truncated"] == "1")
    #expect(largeFields["negativeport"] == "0")
    let lines = "#EXTM3U\n" + String(repeating: "# padding\n", count: 4096) + afterLimit
    let lineFields = androidProxyShapeFields(DevelopmentAndroidProxyDiagnostics.summary(
        response: ProxyResponse(data: Data(lines.utf8)), payload: ProviderProxyPayload(statusCode: 200, body: lines)))
    #expect(lineFields["truncated"] == "1" && lineFields["negativeport"] == "0")
    let references = "#EXTM3U\n" + String(repeating: "segment.ts\n", count: 1100)
    let referenceFields = androidProxyShapeFields(DevelopmentAndroidProxyDiagnostics.summary(
        response: ProxyResponse(data: Data(references.utf8)), payload: ProviderProxyPayload(statusCode: 200, body: references)))
    #expect(referenceFields["uris"] == "1024" && referenceFields["relative"] == "1024" && referenceFields["truncated"] == "1")
}

@Test func developmentAndroidProxyShapeBoundsIndividualLinesURIsAndAttributes() {
    let longURI = "https://remote.example.test/" + String(repeating: "s", count: 9000)
    let longLine = String(repeating: "x", count: 20_000)
    let attributes = String(repeating: "OTHER=1,", count: 64) + "URI=\"http://127.0.0.1:-1/not-scanned\""
    let playlist = "#EXTM3U\n" + longURI + "\n" + longLine + "\n#EXT-X-KEY:" + attributes
    let fields = androidProxyShapeFields(DevelopmentAndroidProxyDiagnostics.summary(
        response: ProxyResponse(data: Data(playlist.utf8)), payload: ProviderProxyPayload(statusCode: 200, body: playlist)))
    #expect(fields["oversize_uris"] == "1" && fields["oversize_lines"] == "1" && fields["truncated"] == "1")
    #expect(fields["negativeport"] == "0" && fields["key_uri"] == "0")
}

@Test func developmentAndroidProxyShapeAcceptsBOMAndCRLFAndUnquotedURI() {
    let playlist = "\u{feff}\r\n#EXTM3U\r\n#EXT-X-MAP:BYTERANGE=\"20@0\",URI=init.mp4\r\n#EXTINF:1,\r\nclip.ts\r\n"
    let fields = androidProxyShapeFields(DevelopmentAndroidProxyDiagnostics.summary(
        response: ProxyResponse(data: Data(playlist.utf8)), payload: ProviderProxyPayload(statusCode: 200, body: playlist)))
    #expect(fields["hls"] == "1" && fields["map_uri"] == "1" && fields["relative"] == "2")
    #expect(fields["media"] == "1" && fields["truncated"] == "0")
}

@Test func developmentAndroidCaptureRequiresOptInAndNeverSerializesInputConfig() throws {
    let fixture = try AndroidDiagnosticCaptureFixture()
    defer { fixture.remove() }
    let result = ProviderJSONValue.object(["list": .array([]), "response": .string("private-response-fixture")])
    let response = ProviderResponse(requestID: "fixture", ok: true, result: result)
    DevelopmentAndroidProxyDiagnostics.captureResult(response, operation: .detail, site: fixture.site, environment: [:])
    DevelopmentAndroidProxyDiagnostics.captureResult(response, operation: .detail, site: fixture.site,
        environment: [fixture.environmentKey: ""])
    #expect(!FileManager.default.fileExists(atPath: fixture.capture.path))
    for operation: ProviderOperation in [.initialize, .handshake, .action] {
        DevelopmentAndroidProxyDiagnostics.captureResult(response, operation: operation, site: fixture.site, environment: fixture.environment)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.capture.path))
    DevelopmentAndroidProxyDiagnostics.captureResult(response, operation: .detail, site: fixture.site, environment: fixture.environment)
    let files = try fixture.files()
    #expect(files.count == 1)
    let file = try #require(files.first)
    let expected = try JSONEncoder.providerCanonical.encode(result)
    #expect(try Data(contentsOf: file) == expected)
    let siteHash = SHA256.hash(data: Data(fixture.site.key.utf8)).map { String(format: "%02x", $0) }.joined()
    let contentHash = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
    #expect(file.lastPathComponent == "\(siteHash)-detail-\(contentHash).result.json")
    #expect(!file.lastPathComponent.contains("PRIVATE-SITE"))
    #expect(!String(decoding: expected, as: UTF8.self).contains("PRIVATE-INPUT-CONFIG"))
    #expect(try fixture.permissions(fixture.capture) == 0o700)
    #expect(try fixture.permissions(file) == 0o600)
    // A preexisting artifact is never overwritten, even when its content differs.
    let retained = Data("existing-artifact-fixture".utf8)
    try retained.write(to: file)
    DevelopmentAndroidProxyDiagnostics.captureResult(response, operation: .detail, site: fixture.site, environment: fixture.environment)
    #expect(try fixture.files().count == 1)
    #expect(try Data(contentsOf: file) == retained)
}

@Test func developmentAndroidCaptureEnforcesEncodedResultByteLimit() throws {
    let fixture = try AndroidDiagnosticCaptureFixture()
    defer { fixture.remove() }
    let atLimit = ProviderResponse(requestID: "fixture", ok: true, result: .string(String(repeating: "x", count: 1024 * 1024 - 2)))
    DevelopmentAndroidProxyDiagnostics.captureResult(atLimit, operation: .detail, site: fixture.site, environment: fixture.environment)
    let files = try fixture.files()
    #expect(files.count == 1)
    #expect(try Data(contentsOf: #require(files.first)).count == 1024 * 1024)
    let tooLarge = ProviderResponse(requestID: "fixture", ok: true, result: .string(String(repeating: "x", count: 1024 * 1024 - 1)))
    DevelopmentAndroidProxyDiagnostics.captureResult(tooLarge, operation: .detail, site: fixture.site, environment: fixture.environment)
    let failed = ProviderResponse(requestID: "fixture", ok: false, result: .string("failed-response"))
    DevelopmentAndroidProxyDiagnostics.captureResult(failed, operation: .detail, site: fixture.site, environment: fixture.environment)
    #expect(try fixture.files().count == 1)
}

@Test func developmentAndroidCaptureSavesOnlyBoundedManifestBodies() throws {
    let fixture = try AndroidDiagnosticCaptureFixture()
    defer { fixture.remove() }
    let hls = Data("#EXTM3U\n#EXTINF:3,\nhttps://media.example.test/segment.ts?token=fixture\n".utf8)
    let dash = Data(repeating: 0x20, count: 256 * 1024)
    DevelopmentAndroidProxyDiagnostics.captureProxy(ProxyResponse(contentType: "application/vnd.apple.mpegURL", data: hls),
        site: fixture.site, environment: [:])
    #expect(!FileManager.default.fileExists(atPath: fixture.capture.path))
    DevelopmentAndroidProxyDiagnostics.captureProxy(ProxyResponse(contentType: "application/vnd.apple.mpegURL", data: hls,
        headers: ["Cookie": "PRIVATE-HEADER-FIXTURE"]), site: fixture.site, environment: fixture.environment)
    DevelopmentAndroidProxyDiagnostics.captureProxy(ProxyResponse(contentType: "application/dash+xml; charset=utf-8", data: dash),
        site: fixture.site, environment: fixture.environment)
    let files = try fixture.files()
    #expect(files.count == 2)
    let hlsFile = try #require(files.first { $0.pathExtension == "m3u8" })
    let dashFile = try #require(files.first { $0.pathExtension == "mpd" })
    #expect(try Data(contentsOf: hlsFile) == hls)
    #expect(try Data(contentsOf: dashFile) == dash)
    for mime in ["video/mp4", "video/mp2t", "audio/mpeg", "application/octet-stream", "text/plain", "application/dash+xml-invalid"] {
        DevelopmentAndroidProxyDiagnostics.captureProxy(ProxyResponse(contentType: mime, data: Data("media-fixture".utf8)),
            site: fixture.site, environment: fixture.environment)
    }
    DevelopmentAndroidProxyDiagnostics.captureProxy(ProxyResponse(contentType: "application/dash+xml", data: Data(repeating: 0, count: 256 * 1024 + 1)),
        site: fixture.site, environment: fixture.environment)
    #expect(try fixture.files().count == 2)
    #expect(try files.allSatisfy { try fixture.permissions($0) == 0o600 })
}

@Test func developmentAndroidCaptureRejectsRelativeSymlinkAndNonprivateRoots() throws {
    let fixture = try AndroidDiagnosticCaptureFixture()
    defer { fixture.remove() }
    let response = ProxyResponse(contentType: "application/dash+xml", data: Data("<MPD/>".utf8))
    DevelopmentAndroidProxyDiagnostics.captureProxy(response, site: fixture.site,
        environment: [fixture.environmentKey: "relative-private-capture"])
    DevelopmentAndroidProxyDiagnostics.capturePage(response.data, profile: .doubaoPageHTML,
        environment: [fixture.environmentKey: "relative-private-capture"])
    #expect(!FileManager.default.fileExists(atPath: fixture.capture.path))
    let destination = fixture.root.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: fixture.capture, withDestinationURL: destination)
    DevelopmentAndroidProxyDiagnostics.captureProxy(response, site: fixture.site, environment: fixture.environment)
    DevelopmentAndroidProxyDiagnostics.capturePage(response.data, profile: .doubaoPageHTML, environment: fixture.environment)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    try FileManager.default.removeItem(at: fixture.capture)
    try FileManager.default.createDirectory(at: fixture.capture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    DevelopmentAndroidProxyDiagnostics.captureProxy(response, site: fixture.site, environment: fixture.environment)
    DevelopmentAndroidProxyDiagnostics.capturePage(response.data, profile: .doubaoPageHTML, environment: fixture.environment)
    #expect(try fixture.files().isEmpty)
    #expect(try fixture.permissions(fixture.capture) == 0o755)
}

@Test func developmentAndroidPageCaptureUsesExplicitPrivateRootAndFixedHashedName() throws {
    let fixture = try AndroidDiagnosticCaptureFixture()
    defer { fixture.remove() }
    let body = Data("<html>PRIVATE-PAGE-ID https://example.invalid/?token=PRIVATE-BODY</html>".utf8)
    DevelopmentAndroidProxyDiagnostics.capturePage(body, profile: .doubaoPageHTML, environment: [:])
    DevelopmentAndroidProxyDiagnostics.capturePage(body, profile: .doubaoPageHTML, environment: [fixture.environmentKey: ""])
    #expect(!FileManager.default.fileExists(atPath: fixture.capture.path))
    DevelopmentAndroidProxyDiagnostics.capturePage(body, profile: .doubaoPageHTML, environment: fixture.environment)
    let files = try fixture.files()
    #expect(files.count == 1)
    let file = try #require(files.first)
    let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    #expect(file.lastPathComponent == "doubao-native-page-\(digest).html")
    #expect(try Data(contentsOf: file) == body)
    #expect(try fixture.permissions(fixture.capture) == 0o700)
    #expect(try fixture.permissions(file) == 0o600)

    // Repeated captures neither overwrite an artifact nor follow a file symlink.
    let retained = Data("retained-fixture".utf8)
    try retained.write(to: file)
    DevelopmentAndroidProxyDiagnostics.capturePage(body, profile: .doubaoPageHTML, environment: fixture.environment)
    #expect(try Data(contentsOf: file) == retained)
    try FileManager.default.removeItem(at: file)
    let destination = fixture.root.appendingPathComponent("outside-fixture")
    try retained.write(to: destination)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: destination)
    DevelopmentAndroidProxyDiagnostics.capturePage(body, profile: .doubaoPageHTML, environment: fixture.environment)
    #expect(try Data(contentsOf: destination) == retained)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == destination.path)
}

@Test func developmentAndroidPageCaptureRejectsOversizeWithoutTruncating() throws {
    let fixture = try AndroidDiagnosticCaptureFixture()
    defer { fixture.remove() }
    let limit = 2 * 1024 * 1024
    DevelopmentAndroidProxyDiagnostics.capturePage(Data(repeating: 0x78, count: limit + 1), profile: .doubaoPageHTML,
        environment: fixture.environment)
    #expect(!FileManager.default.fileExists(atPath: fixture.capture.path))
    let body = Data(repeating: 0x79, count: limit)
    DevelopmentAndroidProxyDiagnostics.capturePage(body, profile: .doubaoPageHTML, environment: fixture.environment)
    let files = try fixture.files()
    #expect(files.count == 1)
    #expect(try Data(contentsOf: #require(files.first)) == body)
}

@Test func developmentAndroidSignalCaptureUsesFixedJSONProfilesAndSmallerByteLimit() throws {
    let fixture = try AndroidDiagnosticCaptureFixture()
    defer { fixture.remove() }
    let limit = 256 * 1024
    let body = Data(repeating: 0x20, count: limit)
    let oversized = Data(repeating: 0x20, count: limit + 1)
    for profile: DevelopmentAndroidProxyDiagnostics.PageCaptureProfile in [.doubaoSignalMetadata, .doubaoSignalPlay] {
        DevelopmentAndroidProxyDiagnostics.capturePage(oversized, profile: profile, environment: fixture.environment)
        #expect(!FileManager.default.fileExists(atPath: fixture.capture.path))
    }
    for profile: DevelopmentAndroidProxyDiagnostics.PageCaptureProfile in [.doubaoSignalMetadata, .doubaoSignalPlay] {
        DevelopmentAndroidProxyDiagnostics.capturePage(body, profile: profile, environment: fixture.environment)
    }
    let files = try fixture.files()
    #expect(files.count == 2 && files.allSatisfy { $0.pathExtension == "json" })
    #expect(try files.allSatisfy { try Data(contentsOf: $0) == body && fixture.permissions($0) == 0o600 })
}

private struct AndroidDiagnosticCaptureFixture {
    let root: URL
    var capture: URL { root.appendingPathComponent("capture", isDirectory: true) }
    let environmentKey = "NETVPLAYER_ANDROID_DIAGNOSTIC_CAPTURE_ROOT"
    var environment: [String: String] { [environmentKey: capture.path] }
    var site: Site { Site(key: "PRIVATE-SITE/fixture", name: "Fixture", type: 3, api: "csp_FixtureGuard", ext: "PRIVATE-INPUT-CONFIG") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("android-private-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func files() throws -> [URL] { try FileManager.default.contentsOfDirectory(at: capture, includingPropertiesForKeys: nil) }
    func permissions(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
}

private func androidProxyShapeFields(_ summary: String) -> [String: String] {
    Dictionary(uniqueKeysWithValues: summary.split(separator: " ").compactMap { field in
        let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
    })
}
@Test func developmentAndroidProxyExchangeJoinsUniqueRequestsToOneUnmodifiedBody() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("android-exchange-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = "private-signed-reference-fixture"
    let data = Data(("#EXTM3U\nhttps://example.test/" + secret).utf8)
    let response = ProxyResponse(contentType: "application/vnd.apple.mpegurl", data: data)
    let environment = ["NETVPLAYER_ANDROID_DIAGNOSTIC_CAPTURE_ROOT": root.path]
    for id in ["request-one", "request-two"] {
        let context = DevelopmentAndroidProxyDiagnostics.MediaContext(requestID: id, routeID: "route", parentRouteID: nil,
            playerInputSHA256: String(repeating: "a", count: 64), proxyInputSHA256: String(repeating: "b", count: 64),
            originalURLSHA256: String(repeating: "c", count: 64), role: "provider")
        DevelopmentAndroidProxyDiagnostics.captureExchange(response, context: context, environment: environment)
        let bytes = try Data(contentsOf: root.appendingPathComponent("exchange-" + id + ".json"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains(secret))
        let envelope = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let filename = try #require(envelope["bodyFile"] as? String)
        #expect(try Data(contentsOf: root.appendingPathComponent(filename)) == data)
        #expect(envelope["bodySHA256"] as? String == DevelopmentAndroidLifecycleDiagnostics.sha256(data))
        #expect((envelope["context"] as? [String: Any])?["requestID"] as? String == id)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 3)
}

#endif
