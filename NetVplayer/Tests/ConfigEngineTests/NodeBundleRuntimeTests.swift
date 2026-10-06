import Foundation
import Testing
import ConfigEngine
import Models
import DriveEngine
import NodeBundleRuntime
import SpiderEngine

private func makeNodeRuntimeExecutable(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@Test func nodeRuntimeLocatorPrefersExplicitOverrideThenBundledRuntime() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NetVplayer-NodeLocator-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Resources", isDirectory: true)
    let bundled = resources.appendingPathComponent("NodeRuntime/bin/node")
    let configured = root.appendingPathComponent("configured-node")
    try makeNodeRuntimeExecutable(at: bundled)
    try makeNodeRuntimeExecutable(at: configured)

    let overridden = try #require(NodeRuntimeLocator.locate(
        environment: ["NETVPLAYER_NODE_PATH": configured.path],
        bundleResourceURL: resources
    ))
    #expect(overridden == NodeRuntimeLocation(executableURL: configured, source: .configured))

    let packaged = try #require(NodeRuntimeLocator.locate(
        environment: [:],
        bundleResourceURL: resources
    ))
    #expect(packaged == NodeRuntimeLocation(executableURL: bundled, source: .bundled))
}

@Test func nodeRuntimeLocatorUsesPATHOnlyWhenBundleIsUnavailable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NetVplayer-NodePath-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let node = root.appendingPathComponent("bin/node")
    try makeNodeRuntimeExecutable(at: node)

    let location = try #require(NodeRuntimeLocator.locate(
        environment: ["PATH": node.deletingLastPathComponent().path],
        bundleResourceURL: root.appendingPathComponent("MissingResources")
    ))
    #expect(location == NodeRuntimeLocation(executableURL: node, source: .host))
}

@Test func nodeBundleDriveTokenConvertsToNativeReference() throws {
    let playToken = #"{"fid":"file-1","shareFidToken":"fid-token-1","shareId":"share-1","fileName":"episode.mp4"}"#
    let payloadObject: [String: Any] = [
        "providerId": "quark",
        "shareId": "share-1",
        "fileId": "file-1",
        "name": "Episode",
        "playToken": playToken,
        "mode": "original",
        "quality": "original"
    ]
    let payload = try JSONSerialization.data(withJSONObject: payloadObject)
    let token = payload.base64EncodedString()

    let canonical = try #require(NodeBundleDriveToken.canonicalURL(for: token))
    let reference = try #require(DriveFileReference.parse(canonical))
    #expect(reference.provider == .quark)
    #expect(reference.pwdID == "share-1")
    #expect(reference.fid == "file-1")
    #expect(reference.fidToken == "fid-token-1")
    #expect(reference.fileName == "episode.mp4")
}

@Test func nodeBundleDriveTokenRejectsMalformedOrUnknownPayload() {
    #expect(NodeBundleDriveToken.canonicalURL(for: "not-a-node-token") == nil)
    let payload = Data(#"{"providerId":"unknown","shareId":"share","fileId":"file","name":"Episode"}"#.utf8).base64EncodedString()
    #expect(NodeBundleDriveToken.canonicalURL(for: payload) == nil)
}

@Test func nodeBundleLiveContractWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["NETVPLAYER_RUN_LIVE_NODE_BUNDLE"] == "1" else {
        return
    }

    let input = try await ConfigResolver.shared.loadVodInput(
        url: "https://9280.kstore.vip/cat/index.js.md5"
    )
    #expect(input.kind == .nodeJSBundle)
    #expect(input.providerID != nil)
    #expect(input.json.contains("nodejs_douban"))

    guard let providerID = input.providerID,
          let data = input.json.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawSite = (object["sites"] as? [[String: Any]])?.first,
          let siteData = try? JSONSerialization.data(withJSONObject: rawSite),
          let site = try? JSONDecoder().decode(Site.self, from: siteData) else {
        await NodeBundleRuntimeRegistry.shared.shutdown()
        Issue.record("Node bundle configuration did not contain a decodable site")
        return
    }

    do {
        let adapter = NodeBundleSiteContentProvider(providerID: providerID)
        let result = try await adapter.homeContent(site: site)
        let optionalHomeVideo = try await adapter.homeVideoContent(site: site)
        let search = try await adapter.searchContent(site: site, keyword: "测试", quick: true, page: "1")
        await NodeBundleRuntimeRegistry.shared.shutdown()
        #expect(!result.types.isEmpty || !result.list.isEmpty)
        // The first site (Douban) does not expose the optional /homeVod route.
        #expect(optionalHomeVideo == nil)
        #expect(search.list.count >= 0)
    } catch {
        await NodeBundleRuntimeRegistry.shared.shutdown()
        throw error
    }
}
