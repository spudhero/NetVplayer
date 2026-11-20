import Foundation
import Models
import ProxyServer
import Testing
@testable import SpiderEngine

private func mp4Box(_ name: String, _ body: Data) -> Data {
    var length = UInt32(body.count + 8).bigEndian
    return withUnsafeBytes(of: &length) { Data($0) } + Data(name.utf8) + body
}

private func sdkMP4(entry: String = "avc1", config: String = "hvcC", ambiguous: Bool = false) -> Data {
    var configData = Data(repeating: 0, count: 23); configData[0] = 1
    var children = mp4Box(config, configData)
    if ambiguous { children += mp4Box("avcC", configData) }
    let sample = mp4Box(entry, Data(repeating: 0, count: 78) + children)
    let stsd = mp4Box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + sample)
    var movie = stsd
    for name in ["stbl", "minf", "mdia", "trak", "moov"] { movie = mp4Box(name, movie) }
    return mp4Box("ftyp", Data("isom0000".utf8)) + movie + mp4Box("mdat", Data("avc1hvcC untouched media".utf8))
}

@Test func developmentAndroidMP4RepairRequiresContradictorySampleEntry() {
    let input = sdkMP4()
    let offsets = DevelopmentAndroidMP4CodecRepair.offsets(in: input)
    #expect(offsets.count == 1)
    let corrected = DevelopmentAndroidMP4CodecRepair.apply(input, at: 0, offsets: offsets)
    #expect(corrected == sdkMP4(entry: "hvc1"))
    #expect(corrected.count == input.count)
    for body in [sdkMP4(config: "avcC"), sdkMP4(entry: "hvc1"), sdkMP4(entry: "encv"), sdkMP4(ambiguous: true), Data("avc1hvcC".utf8)] {
        #expect(DevelopmentAndroidMP4CodecRepair.offsets(in: body).isEmpty)
    }
    for size in 0..<input.count {
        let prefix = Data(input.prefix(size))
        let found = DevelopmentAndroidMP4CodecRepair.offsets(in: prefix)
        #expect(found.isEmpty || found == offsets)
    }
}

@Test func developmentAndroidMP4RepairPreservesEveryByteRange() async throws {
    let input = sdkMP4(), patches = DevelopmentAndroidMP4CodecRepair.offsets(in: input)
    let expected = sdkMP4(entry: "hvc1")
    // Include requests beginning inside each of the four replacement bytes,
    // and stream chunks which split the sample-entry marker.
    for start in [0] + patches.flatMap({ Array(Int($0) - 1...Int($0) + 4) }) {
        let stream = DevelopmentAndroidMP4CodecRepairStream(offsets: patches)
        let head = try await stream.head(.init(statusCode: start == 0 ? 200 : 206, contentType: "video/mp4",
            contentLength: input.count - start, headers: ["Content-Range": "bytes \(start)-\(input.count - 1)/\(input.count)",
                "ETag": "original", "X-SDK": "same"], closeConnection: true))
        #expect(head.contentLength == input.count - start && head.headers["ETag"] == nil && head.headers["X-SDK"] == "same")
        var output = Data()
        for pos in stride(from: start, to: input.count, by: 2) {
            output += try await stream.body(Data(input[pos..<min(pos + 2, input.count)]))
        }
        #expect(output == Data(expected.dropFirst(start)))
    }
}

@Test func developmentAndroidMP4RepairRequiresComponentPolicy() throws {
    let site = Site(key: "AiDj", name: "AI", type: 3, api: "csp_AiDjGuard")
    let binding = DevelopmentAndroidRuntimeManifest.Binding(key: site.key, api: site.api, className: "com.github.catvod.spider.AiDjGuard")
    let policy = AndroidCompatibilityPolicy(cloud: [], media: [.init(key: site.key, api: site.api,
        className: binding.className, path: "/proxy", queryName: "do", queryValue: "hg")])
    #expect(!DevelopmentAndroidMP4CodecRepair.accepts("http://127.0.0.1:6677/proxy?do=hg", site: site, binding: binding))
    for port in [6677, 6678, 18080] {
        #expect(DevelopmentAndroidMP4CodecRepair.accepts("http://127.0.0.1:\(port)/proxy?do=hg&vid=fixture", site: site, binding: binding, policy: policy))
    }
    for url in ["http://127.0.0.1:9978/proxy?do=hg", "https://cdn.example.test/proxy?do=hg", "http://127.0.0.1:6677/proxy?do=hgdm", "http://127.0.0.1:6677/proxy?do=hg&do=other"] {
        #expect(!DevelopmentAndroidMP4CodecRepair.accepts(url, site: site, binding: binding, policy: policy))
    }
    #expect(!DevelopmentAndroidMP4CodecRepair.accepts("http://127.0.0.1:6677/proxy?do=hg", site: Site(key: "other", name: "Other", type: 3, api: site.api), binding: binding, policy: policy))
}

#if DEBUG
private actor SDKMP4Output {
    var data = Data()
    func append(_ chunk: Data) { data += chunk }
    func value() -> Data { data }
}

@Test func developmentAndroidMP4RepairRunsThroughPlayerAndStreamingRoute() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture(); defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
    try sdkMP4().write(to: fixture.state.appendingPathComponent("sdk-media-body.fixture"))
    let site = Site(key: "AiDj", name: "AI", type: 3, api: "csp_AiDjGuard", ext: "original")
    try fixture.writeManifest(changes: ["bindings": [["key": site.key, "api": site.api, "className": "com.github.catvod.spider.AiDjGuard"]]], repairsSDKMedia: true)
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: runtime.manifest.bindings[0], stateDirectory: fixture.state)
    do {
        let result = try await provider.playerContent(site: site, flag: "AI", id: "sdk-owned-1")
        let url = try #require(URLComponents(string: result.url))
        let parameters = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(parameters["android_route"] != nil && parameters["siteKey"] == "AiDj")
        let output = SDKMP4Output()
        try await provider.streamProxyRoute(site: site, parameters: parameters, sendHead: { head in
            #expect(head.contentLength == sdkMP4().count)
        }, sendBody: { await output.append($0) })
        #expect(await output.value() == sdkMP4(entry: "hvc1"))
        let requests = try String(contentsOf: fixture.state.appendingPathComponent("sdk-http.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0["path"] == "/proxy?do=hg&vid=fixture" && $0["user_agent"] == "SDK fixture" })
        #expect(requests[0]["range"] == "bytes=0-65535")
    } catch { await provider.shutdown(); throw error }
    await provider.shutdown()
}
#endif
