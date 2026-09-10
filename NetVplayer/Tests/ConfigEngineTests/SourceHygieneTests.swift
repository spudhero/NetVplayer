import Testing
import Foundation
import Models
@testable import ConfigEngine
import Storage

@Test func testSourceHygieneFiltersSitesParsesAndLivesWithoutMutatingOriginalConfig() throws {
    let storage = StorageManager(storageDirectory: temporaryStorageDirectory())
    let hygieneStore = SourceHygieneStore(storage: storage)
    try hygieneStore.replaceRules([
        SourceHygieneRule(kind: .siteNameRegex, pattern: "屏蔽"),
        SourceHygieneRule(kind: .parseURL, pattern: "blocked-parse.example"),
        SourceHygieneRule(kind: .liveURL, pattern: "blocked-live.example")
    ])

    let rawJSON = """
    {
      "sites": [
        { "key": "keep", "name": "保留站", "type": 1, "api": "https://cms.example/api.php" },
        { "key": "bad", "name": "屏蔽站", "type": 1, "api": "https://blocked.example/api.php" }
      ],
      "parses": [
        { "name": "保留解析", "type": 1, "url": "https://parse.example/api" },
        { "name": "屏蔽解析", "type": 1, "url": "https://blocked-parse.example/api" }
      ],
      "lives": [
        { "name": "保留直播", "url": "https://live.example/live.txt" },
        { "name": "屏蔽直播", "url": "https://blocked-live.example/live.txt" }
      ]
    }
    """

    let vodConfig = VodConfig(httpClient: .shared, hygieneStore: hygieneStore)
    try vodConfig.parse(json: rawJSON, config: .vod(url: "https://config.example/tv.json"))

    #expect(vodConfig.sites.map(\.key) == ["keep"])
    #expect(vodConfig.parses.map(\.name) == ["聚合", "保留解析"])
    #expect(vodConfig.config?.json.contains("屏蔽站") == true)
    #expect(vodConfig.aggregationSnapshot.blockedByUserCount == 3)
    #expect(vodConfig.aggregationSnapshot.normalizationEvents.contains { $0.kind == .blockedByUser && $0.entityKey == "bad" })

    let liveConfig = LiveConfig(hygieneStore: hygieneStore)
    liveConfig.parse(livesArray: [
        ["name": "保留直播", "url": "https://live.example/live.txt"],
        ["name": "屏蔽直播", "url": "https://blocked-live.example/live.txt"]
    ])
    #expect(liveConfig.lives.map(\.name) == ["保留直播"])
}

@Test func testCredentialRiskAssessmentClassifiesTokenJsonProxyAndRedactsSecrets() {
    let official = Site(
        key: "official",
        name: "官方直连",
        type: 3,
        api: "csp_QuarkShare",
        ext: #"{"quark_cookie":"kps=secret; __puus=secret"}"#
    )
    let risky = Site(
        key: "risk",
        name: "第三方代理",
        type: 3,
        api: "csp_QuarkShare",
        ext: "https://tokens.example/token.json$$$https://third.example/site$$$proxy$$$4$$${\"cookie\":\"secret-value\"}"
    )

    let officialAssessment = CredentialRiskAssessment.assess(site: official)
    let riskyAssessment = CredentialRiskAssessment.assess(site: risky)

    #expect(officialAssessment.riskLevel == .safe)
    #expect(riskyAssessment.riskLevel == .high)
    #expect(riskyAssessment.redactedEvidence.contains("<redacted>"))
    #expect(!riskyAssessment.redactedEvidence.contains("secret-value"))
}

@Test func testExternalResourceDiagnosticsRejectUnsafeURLsAndFlagAndroidJars() throws {
    let rawJSON = """
    {
      "spider": "jar:https://cdn.example.test/spider.jar;md5;abc",
      "sites": [
        { "key": "local-js", "name": "Local JS", "type": 3, "api": "http://127.0.0.1/drpy.js" },
        { "key": "remote-js", "name": "Remote JS", "type": 3, "api": "https://cdn.example.test/drpy.js", "ext": "https://cdn.example.test/ext.json" }
      ],
      "parses": [
        { "name": "File Parse", "type": 1, "url": "file:///tmp/parser.js" },
        { "name": "Remote Parse", "type": 1, "url": "https://cdn.example.test/parser.txt" }
      ]
    }
    """

    let vodConfig = VodConfig(httpClient: .shared, hygieneStore: nil)
    try vodConfig.parse(json: rawJSON, config: .vod(url: "https://config.example/tv.json"))

    let diagnostics = vodConfig.aggregationSnapshot.resourceDiagnostics
    #expect(diagnostics.contains { $0.resourceType == .jar && $0.status == .androidRuntimeOnly })
    #expect(diagnostics.contains { $0.url.contains("127.0.0.1") && $0.status == .blocked })
    #expect(diagnostics.contains { $0.url.hasPrefix("file://") && $0.status == .blocked })
    #expect(diagnostics.contains { $0.url == "https://cdn.example.test/drpy.js" && $0.status == .recorded })
    #expect(vodConfig.aggregationSnapshot.normalizationEvents.contains { $0.kind == .resourceDiagnosticRecorded })
}

@Test func testLiveLineHealthStoreAggregatesAndPrunesByChannelURL() throws {
    let storage = StorageManager(storageDirectory: temporaryStorageDirectory())
    let store = LiveLineHealthStore(storage: storage)
    let fresh = Date()
    let stale = fresh.addingTimeInterval(-(31 * 24 * 60 * 60))

    store.record(LiveLineHealthEvent(
        liveName: "央视频道",
        groupName: "央视",
        channelName: "CCTV-1",
        url: "https://live.example/cctv1.m3u8?token=secret",
        success: true,
        statusCode: 200,
        ttfbMs: 120,
        failureCategory: nil,
        message: "可播放",
        timestamp: fresh
    ))
    store.record(LiveLineHealthEvent(
        liveName: "央视频道",
        groupName: "央视",
        channelName: "CCTV-1",
        url: "https://live.example/cctv1.m3u8?token=old",
        success: false,
        statusCode: 502,
        ttfbMs: 900,
        failureCategory: .live,
        message: "上游 HTTP 502",
        timestamp: stale
    ))

    let summaries = store.summaries(now: fresh)
    let summary = try #require(summaries.first)
    #expect(summaries.count == 1)
    #expect(summary.channelName == "CCTV-1")
    #expect(summary.successCount == 1)
    #expect(summary.failureCount == 0)
    #expect(summary.averageTTFBMs == 120)
    #expect(!summary.redactedURL.contains("secret"))
}

private func temporaryStorageDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("netvplayer-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
