import Testing
@testable import Models

@Test func testSiteCreation() {
    let site = Site(key: "test", name: "测试站", type: 3)
    #expect(site.isSpider == true)
    #expect(site.isSearchable == true)
    #expect(site.isEmpty == false)
}

@Test func testEpisodeParsing() {
    let episodes = Episode.parse(from: "第1集$url1#第2集$url2#第3集$url3")
    #expect(episodes.count == 3)
    #expect(episodes[0].name == "第1集")
    #expect(episodes[1].url == "url2")

    let encoded = Episode.parse(from: "正片$netvplayer-drive://quark/file?share=https%3A%2F%2Fpan.quark.cn%2Fs%2Fabc&fid=file%24fid")
    #expect(encoded.count == 1)
    #expect(encoded[0].name == "正片")
    #expect(encoded[0].url.contains("fid=file%24fid"))
}

@Test func testResultFromJSON() {
    let json = "{\"url\":\"http://test.m3u8\",\"parse\":0,\"flag\":\"hd\"}"
    let result = Result.fromJSON(json)
    #expect(result.url == "http://test.m3u8")
    #expect(result.needParse == false)
}

@Test func testResultFromJSONToleratesOutOfRangeNumbers() {
    let json = "{\"url\":\"http://test.m3u8\",\"page\":1e20,\"pagecount\":-1e20,\"total\":1e20,\"code\":1e20}"
    let result = Result.fromJSON(json)

    #expect(result.url == "http://test.m3u8")
    #expect(result.page == 0)
    #expect(result.pagecount == 0)
    #expect(result.total == 0)
    #expect(result.code == 0)
    #expect(JSONDynamicValue.number(1e20).intValue == 0)
    #expect(JSONDynamicValue.number(1e20).stringValue == "1e+20")
}

@Test func testPlaybackLinkageLocatesHistoryFlagAndEpisode() {
    let vod = Vod(vodId: "v1", vodName: "剧集", siteKey: "site")
    let history = History(
        key: PlaybackLinkage.vodKey(siteKey: "site", vodId: "v1"),
        siteKey: "site",
        vodId: "v1",
        vodFlag: "线路二",
        episodeUrl: "ep2",
        position: 95_000,
        duration: 300_000
    )
    let episodes = [Episode(name: "第1集", url: "ep1"), Episode(name: "第2集", url: "ep2")]

    let matched = PlaybackLinkage.history(for: vod, activeSiteKey: "site", items: [history])

    #expect(matched?.vodFlag == "线路二")
    #expect(PlaybackLinkage.preferredFlag(from: matched, availableFlags: ["线路一", "线路二"]) == "线路二")
    #expect(PlaybackLinkage.preferredEpisode(from: matched, episodes: episodes)?.name == "第2集")
    #expect(PlaybackLinkage.progressText(for: matched) == "上次看到 01:35 / 05:00")
}

@Test func testKeepRemarksUpdateCanBeMarkedAndAcknowledged() {
    let keep = Keep(
        key: "site_v1",
        siteName: "Site",
        vodName: "剧集",
        vodRemarks: "更新至10集",
        type: .vod
    )

    let marked = PlaybackLinkage.updatedKeep(keep, currentRemarks: "更新至11集", acknowledge: false)
    #expect(marked.vodRemarks == "更新至10集")
    #expect(marked.latestRemarks == "更新至11集")
    #expect(marked.hasUpdate == true)

    let acknowledged = PlaybackLinkage.updatedKeep(marked, currentRemarks: "更新至11集", acknowledge: true)
    #expect(acknowledged.vodRemarks == "更新至11集")
    #expect(acknowledged.latestRemarks.isEmpty)
    #expect(acknowledged.hasUpdate == false)
}

@Test func testTrackPreferenceUsesSelectionIDForRestoreLookup() {
    let spec = PlaySpec(url: "https://media.example.test/1.m3u8", title: "剧集 - 第1集", siteKey: "site")
    let key = PlaybackLinkage.trackPreferenceKey(for: spec)
    let tracks = [
        Track(key: key, type: .subtitle, selectionId: "sid-2", name: "简中", format: "srt", isSelected: true)
    ]

    let preference = PlaybackLinkage.trackPreference(type: .subtitle, for: spec, in: tracks)

    #expect(preference?.selectionId == "sid-2")
    #expect(preference?.name == "简中")
}

@Test func testLiveFavoriteCreatesVirtualGuideGroup() {
    let channel = Channel(name: "南京文旅纪录", number: "003", tvgId: "nbs-doc")
    let group = ChannelGroup(name: "江苏地区", channels: [channel])
    let keep = Keep(
        key: PlaybackLinkage.liveKeepKey(liveName: "饭太硬", groupName: group.name, channel: channel),
        siteName: group.name,
        vodName: channel.name,
        type: .live
    )

    let groups = PlaybackLinkage.liveGuideGroups(keeps: [keep], groups: [group], liveName: "饭太硬")

    #expect(groups.first?.name == PlaybackLinkage.liveFavoritesGroupName)
    #expect(groups.first?.channels.first?.name == channel.name)
    #expect(PlaybackLinkage.matchingLiveChannel(for: keep, in: [group], liveName: "饭太硬")?.group.name == group.name)
}

@Test func testExternalCapabilityClosureCatalogHasNoDefaultBuildOpenItems() {
    let closures = ExternalCapabilityClosureCatalog.defaultClosures

    #expect(Set(closures.map(\.area)) == Set(ExternalCapabilityArea.allCases))
    #expect(ExternalCapabilityClosureCatalog.defaultBuildOpenItems(in: closures).isEmpty)
    #expect(ExternalCapabilityClosureCatalog.externalEvidenceItems(in: closures).contains { $0.area == .publicDriveSharePlayback })
    #expect(ExternalCaptureStatus.pendingCapture.canRegisterNativePlaybackCapability == false)
    #expect(ExternalCaptureStatus.captured.canRegisterNativePlaybackCapability == false)
    #expect(ExternalCaptureStatus.nativeRewriteReady.canRegisterNativePlaybackCapability == true)
}

@Test func testExternalEvidenceAdmissionGatesCapturePromotion() {
    let pending = ExternalCaptureFixture(
        provider: "KkSs",
        sourceKey: "csp_KkSsGuard",
        catVodMethod: "searchContent",
        status: .pendingCapture,
        requestShape: ["host": "kk.example.test", "path": "/search"]
    )
    #expect(pending.admissionDecision.canDisplayDiagnostic)
    #expect(pending.admissionDecision.canAnalyze == false)
    #expect(pending.admissionDecision.canRegisterNativeCapability == false)

    let captured = ExternalCaptureFixture(
        provider: "KkSs",
        sourceKey: "csp_KkSsGuard",
        catVodMethod: "searchContent",
        status: .captured,
        requestShape: ["host": "kk.example.test", "path": "/search"],
        responseFields: ["list": "[vod_id,vod_name]"]
    )
    #expect(captured.admissionDecision.canAnalyze)
    #expect(captured.admissionDecision.canRegisterNativeCapability == false)

    let ready = ExternalCaptureFixture(
        provider: "KkSs",
        sourceKey: "csp_KkSsGuard",
        catVodMethod: "playerContent",
        status: .nativeRewriteReady,
        requestShape: ["host": "kk.example.test", "path": "/player/{id}", "id": "vod id"],
        responseFields: ["url": "media url", "header": "map"],
        httpTraceShape: ["host": "api.kk.example.test", "path": "/player/{id}", "status": "200"],
        errorCategory: .spider
    )
    #expect(ready.admissionDecision.canRegisterNativeCapability)
    #expect(ready.admissionDecision.missingSignals.isEmpty)

    let redactionIssues = ExternalEvidenceRedactionAudit.issues(in: [[
        "url": "https://cdn.example.test/video.mp4?auth_key=secret",
        "local": "file:///Users/example/secret.mp4"
    ]])
    #expect(redactionIssues.count == 2)
}

@Test func testAppFailureCategoriesExposeReadablePresentationHints() {
    for category in [
        AppFailureCategory.config,
        .spider,
        .proxy,
        .parse,
        .source,
        .live,
        .player,
        .ui,
        .unknown
    ] {
        let hint = category.presentationHint
        #expect(!hint.title.isEmpty)
        #expect(!hint.suggestedAction.isEmpty)
    }

    let failure = AppFailure(category: .proxy, message: "upstream failed", detail: "HTTP 500")
    #expect(failure.errorDescription?.contains("[Proxy]") == true)
    #expect(AppFailureCategory.spider.presentationHint.title == "视频源错误")
    #expect(AppFailureCategory.proxy.presentationHint.title == "网络代理错误")
    #expect(failure.presentationHint.suggestedAction == "请检查网络和本地代理状态，确认上游服务可访问后重试。")

    let developerTerms = ["WebView", "JSON", "待抓包", "EPG", "mpv", "DRM", "view state", "Config/Spider"]
    for category in AppFailureCategory.allCasesForPresentationTest {
        #expect(!developerTerms.contains { category.presentationHint.suggestedAction.contains($0) })
    }
}

private extension AppFailureCategory {
    static var allCasesForPresentationTest: [Self] {
        [.config, .spider, .proxy, .parse, .source, .live, .player, .ui, .unknown]
    }
}
