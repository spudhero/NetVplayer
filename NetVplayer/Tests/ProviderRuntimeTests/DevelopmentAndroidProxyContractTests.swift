#if DEBUG
import Foundation
import Models
import ProviderSDK
import Testing
@testable import SpiderEngine

private let androidManifestBase = "http://127.0.0.1:-1/proxy?do=fixture&master=1"
private func mapAndroidManifest(_ body: String, mime: String = "application/vnd.apple.mpegurl") throws -> ProxyResponse {
    try DevelopmentAndroidProxyManifest.map(ProxyResponse(contentType: mime, data: Data(body.utf8), headers: ["ETag": "before", "X-Original": "same"]), originalURL: androidManifestBase) { value in
        let site = Site(key: "fixture", name: "Fixture", type: 3, api: "csp_FixtureGuard")
        return try DevelopmentAndroidCatVodProxyAdapter.localize(Result(url: value), site: site,
            binding: .init(key: site.key, api: site.api, className: "com.github.catvod.spider.FixtureGuard"),
            providerID: "android-runtime-experiment", routeID: "bound", proxyAddress: "http://127.0.0.1:12345/proxy")?.result.url
    }
}

@Test func developmentAndroidAiDjKeepsOriginalSDKMediaServer() throws {
    let site = Site(key: "AiDj", name: "AI drama", type: 3, api: "csp_AiDjGuard")
    let binding = DevelopmentAndroidRuntimeManifest.Binding(key: site.key, api: site.api,
        className: "com.github.catvod.spider.AiDjGuard")
    // Separate helpers choose available ports; media and attachment handling
    // must preserve the SDK's server rather than interpreting its query values.
    for port in [6677, 6678, 18080] {
        let media = Result(url: "http://127.0.0.1:\(port)/proxy?do=hg&vid=1234567890123456789", parse: 0,
            header: ["User-Agent": "SDK fixture"])
        #expect(try DevelopmentAndroidCatVodProxyAdapter.localize(media, site: site, binding: binding,
            providerID: "android-runtime-experiment", routeID: "fixture", permitsDirectLocalServer: true) == nil)
        let direct = try RemoteProviderPlayerResultAdapter.localize(media, site: site, providerID: "android-runtime-experiment")
        #expect(direct.url == media.url && direct.parse == 0 && direct.header == media.header)
    }
    for port in ["-1", "9978", "9979", "9999"] {
        let host = Result(url: "http://127.0.0.1:\(port)/proxy?do=fixture&id=opaque")
        let route = try #require(try DevelopmentAndroidCatVodProxyAdapter.localize(host, site: site, binding: binding,
            providerID: "android-runtime-experiment", routeID: "fixture", permitsDirectLocalServer: true))
        #expect(route.result.url != host.url)
        #expect(route.parameters == ["do": "fixture", "id": "opaque"])
    }
}

@Test func developmentAndroidPlayerUsesItsOwnHelperMediaServerPort() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture(); defer { fixture.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: runtime.manifest.bindings[0], stateDirectory: fixture.state)
    do {
        for port in [6677, 6678] {
            let result = try await provider.playerContent(site: fixture.site, flag: "fixture", id: "sdk-owned-\(port)")
            let address = try #require(URLComponents(string: result.url))
            #expect((6677..<7000).contains(address.port ?? 0))
            #expect(address.path == "/proxy" && address.percentEncodedQuery == "do=hg&vid=fixture")
            #expect(result.parse == 0 && result.header == ["User-Agent": "SDK fixture"])
            let (body, _) = try await URLSession.shared.data(from: #require(address.url))
            #expect(body == Data("SDK media fixture".utf8))
        }
    } catch {
        await provider.shutdown()
        throw error
    }
    await provider.shutdown()
}

@Test func developmentAndroidProxyHLSMapsMasterRenditionsKeysMapsAndSegments() throws {
    let input = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="zh",LANGUAGE="zh",NAME="Chinese",URI="http://127.0.0.1:9978/proxy?do=audio"
    #EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="zh",RESOLUTION=1280x720
    ?do=variant&quality=720
    #EXT-X-KEY:METHOD=AES-128,URI="/proxy?do=key"
    #EXT-X-MAP:URI="proxy?do=init",BYTERANGE="100@0"
    #EXTINF:4,
    http://127.0.0.1:9979/proxy?do=segment&sign=a%2Bb%2F
    #EXT-X-BYTERANGE:120@100
    https://cdn.example.test/a.ts?sign=a%2Bb%2F
    //cdn.example.test/b.ts?sign=a%2Bb%2F
    """
    let response = try mapAndroidManifest(input)
    let text = String(decoding: response.data, as: UTF8.self)
    #expect(text.components(separatedBy: "android_route=bound").count == 6)
    #expect(text.contains("LANGUAGE=\"zh\"") && text.contains("RESOLUTION=1280x720"))
    #expect(text.contains("BYTERANGE=\"100@0\"") && text.contains("#EXT-X-BYTERANGE:120@100"))
    #expect(text.contains("https://cdn.example.test/a.ts?sign=a%2Bb%2F"))
    #expect(text.contains("http://cdn.example.test/b.ts?sign=a%2Bb%2F"))
    #expect(response.headers["ETag"] == nil && response.headers["X-Original"] == "same")
}

@Test func developmentAndroidProxyDASHPreservesRepresentationsLanguagesAndTimeline() throws {
    let input = """
    <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"><Period>
    <BaseURL>https://cdn.example.test/signed/</BaseURL>
    <AdaptationSet contentType="video"><SegmentTemplate media="$RepresentationID$-$Number$.m4s" initialization="$RepresentationID$-init.mp4"><SegmentTimeline><S t="0" d="4000" r="9"/></SegmentTimeline></SegmentTemplate><Representation id="low" bandwidth="100000"/><Representation id="high" bandwidth="400000"/></AdaptationSet>
    <AdaptationSet lang="zh" contentType="audio"><Representation id="zh"/></AdaptationSet>
    <AdaptationSet lang="en" contentType="audio"><Representation id="en"/></AdaptationSet>
    </Period></MPD>
    """
    #expect(try mapAndroidManifest(input, mime: "application/dash+xml").data == Data(input.utf8))
    let ordinaryLoopbackCDN = input.replacingOccurrences(of: "https://cdn.example.test/signed/", with: "http://127.0.0.1:63324/media/")
    #expect(try mapAndroidManifest(ordinaryLoopbackCDN, mime: "application/dash+xml").data == Data(ordinaryLoopbackCDN.utf8))
    let local = input.replacingOccurrences(of: "https://cdn.example.test/signed/", with: "http://127.0.0.1:9978/proxy?do=mp4&amp;id=one")
    #expect(throws: (any Error).self) { try mapAndroidManifest(local, mime: "application/dash+xml") }
    let explicit = "<MPD><Period><AdaptationSet lang=\"zh\"><Representation><BaseURL>http://127.0.0.1:9978/proxy?do=mp4&amp;id=one</BaseURL></Representation></AdaptationSet><AdaptationSet lang=\"en\"/></Period></MPD>"
    let output = String(decoding: try mapAndroidManifest(explicit, mime: "application/dash+xml").data, as: UTF8.self)
    #expect(output.contains("android_route=bound") && output.contains("lang=\"zh\"") && output.contains("lang=\"en\""))
}

@Test func developmentAndroidProxyRejectsUnresolvableRelativeHLSAndXMLExternalEntities() {
    for input in ["#EXTM3U\nsegment.ts\n", "#EXTM3U\nhttp://127.0.0.1:22/proxy?do=segment\n"] {
        #expect(throws: (any Error).self) { try mapAndroidManifest(input) }
    }
    #expect(throws: (any Error).self) {
        try mapAndroidManifest("<!DOCTYPE MPD [<!ENTITY x SYSTEM 'file:///private'>]><MPD>&x;</MPD>", mime: "application/dash+xml")
    }
}

@Test func developmentAndroidProxyPreservesBinaryRangeAndMapsOnlyLocalRedirect() throws {
    let binary = Data([0,255,1,2])
    let input = ProxyResponse(statusCode: 206, contentType: "video/mp4", data: binary,
        headers: ["Content-Range": "bytes 10-13/100", "Accept-Ranges": "bytes"])
    let output = try DevelopmentAndroidProxyManifest.map(input, originalURL: androidManifestBase) { _ in nil }
    #expect(output.data == binary && output.statusCode == 206 && output.headers == input.headers)
    let redirect = ProxyResponse(statusCode: 302, contentType: "text/plain", data: Data(), headers: ["Location": "?do=next"])
    let result = try DevelopmentAndroidProxyManifest.map(redirect, originalURL: androidManifestBase) {
        $0.hasPrefix("http://127.0.0.1:9978/proxy?") ? "http://127.0.0.1:12345/proxy?android_route=bound" : nil
    }
    #expect(result.statusCode == 302 && result.headers["Location"]?.contains("android_route=bound") == true)
}

@Test func developmentAndroidStreamCapabilitiesRejectOtherOriginsAndPaths() throws {
    let token = UUID().uuidString
    #expect(try DevelopmentAndroidStreamTransport.validate("http://127.0.0.1:12345/android-stream/" + token).port == 12345)
    for value in ["http://example.test:12345/android-stream/" + token,
                  "http://127.0.0.1:12345/arbitrary/" + token,
                  "http://127.0.0.1:12345/android-stream/" + token + "?token=x",
                  "http://user@127.0.0.1:12345/android-stream/" + token,
                  "file:///android-stream/" + token] {
        #expect(throws: (any Error).self) { try DevelopmentAndroidStreamTransport.validate(value) }
    }
}

@Test func developmentAndroidProxyMasterSurvivesMoreThan64QualityAndSubtitleRoutes() async throws {
    let f = try DevelopmentAndroidBridgeFixture(); defer { f.remove() }
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: f.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: runtime.manifest.bindings[0], stateDirectory: f.state)
    let first = try await provider.playerContent(site: f.site, flag: "fixture", id: "proxy-fixture")
    for _ in 0..<70 { _ = try await provider.playerContent(site: f.site, flag: "fixture", id: "proxy-fixture") }
    let parameters = Dictionary(uniqueKeysWithValues: (URLComponents(string: first.url)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    let response = try await provider.proxyRoute(site: f.site, parameters: parameters)
    #expect(response.statusCode == 200)
    await provider.cancelPlayback()
    await #expect(throws: (any Error).self) { try await provider.proxyRoute(site: f.site, parameters: parameters) }
    _ = try await provider.playerContent(site: f.site, flag: "fixture", id: "proxy-fixture")
    await provider.shutdown()
    await #expect(throws: (any Error).self) { try await provider.proxyRoute(site: f.site, parameters: parameters) }
}
#endif
