import Testing
import Foundation
import AppKit
import Models
import DriveEngine
import Networking
import PlayerEngine
import ProxyServer
@testable import NetVplayerApp

private enum TestDriveFallbackMetadataKey {
    static let fallbackURL = "drive.fallback.url"
    static let fallbackRoute = "drive.fallback.route"
    static let fallbackQuality = "drive.fallback.quality"
    static let fallbackQualityLabel = "drive.fallback.qualityLabel"
    static let fallbackWidth = "drive.fallback.width"
    static let fallbackHeight = "drive.fallback.height"
    static let fallbackApplied = "drive.fallback.applied"
    static let fallbackAuthRequired = "drive.fallback.authRequired"
    static let fallbackUnavailableReason = "drive.fallback.unavailableReason"
}

private func typedDriveSpec(_ source: PlaySpec) -> PlaySpec {
    guard let provider = DriveProvider(
        rawValue: source.metadata[DrivePlaybackMetadataKey.provider] ?? ""
    ) else {
        return source
    }
    var metadata = source.metadata
    if metadata[DrivePlaybackMetadataKey.personalFileID] == nil,
       metadata[DrivePlaybackMetadataKey.fid] == nil {
        metadata[DrivePlaybackMetadataKey.fid] = source.url
    }
    let link = CloudDriveLink(
        url: source.url,
        headers: source.headers,
        metadata: metadata
    )
    let fallbackURL = metadata[TestDriveFallbackMetadataKey.fallbackURL]
    let fallbackRoute = metadata[TestDriveFallbackMetadataKey.fallbackRoute]
    let fallbackMetadata: [String: String] = [
        DrivePlaybackMetadataKey.route: fallbackRoute,
        DrivePlaybackMetadataKey.quality: metadata[TestDriveFallbackMetadataKey.fallbackQuality],
        DrivePlaybackMetadataKey.qualityLabel: metadata[TestDriveFallbackMetadataKey.fallbackQualityLabel],
        DrivePlaybackMetadataKey.width: metadata[TestDriveFallbackMetadataKey.fallbackWidth],
        DrivePlaybackMetadataKey.height: metadata[TestDriveFallbackMetadataKey.fallbackHeight]
    ].compactMapValues { $0 }
    let adapter = DrivePlaybackProviderAdapters.adapter(for: provider)
    var spec = source
    spec.drivePlaybackPlan = adapter.playbackPlan(
        primaryURL: link.url,
        primaryHeaders: source.headers,
        primaryMPVOptions: source.mpvOptions,
        primaryMetadata: metadata,
        fallbackURL: fallbackURL,
        fallbackHeaders: source.fallbackHeaders,
        fallbackMetadata: fallbackMetadata,
        reauthenticationRequired: metadata[TestDriveFallbackMetadataKey.fallbackAuthRequired] == "true",
        unavailableReason: metadata[TestDriveFallbackMetadataKey.fallbackUnavailableReason]
    )
    return DrivePlaybackRoutePolicy.preparedSpec(spec)
}

@MainActor
private func installDriveSpec(_ source: PlaySpec, in appState: AppState) -> PlaySpec {
    let prepared = appState.configureDrivePlaybackRoutes(for: typedDriveSpec(source))
    appState.playerState.currentSpec = prepared
    return prepared
}

@Test func testNmyswvVodLineFallbackKeepsEpisodeAndRunsOnlyOnce() throws {
    let site = Site(key: "糯米", name: "糯米", type: 3, api: "csp_NmyswvGuard")
    let detail = Vod(
        vodId: "92013",
        vodName: "镖人：风起大漠",
        vodPlayFrom: "直连线路$$$123Pan兼容线路",
        vodPlayUrl: "第01集$https://direct.example/ep1.m3u8#第02集$https://direct.example/ep2.m3u8$$$第01集$/vod-play-id-92013-src-1-num-1.html#第02集$/vod-play-id-92013-src-1-num-2.html"
    )
    var failed = PlaySpec(
        url: "https://direct.example/ep2.m3u8",
        flag: "直连线路",
        siteKey: site.key
    )
    failed.metadata["vod.episodeURL"] = "https://direct.example/ep2.m3u8"
    failed.metadata["vod.episodeName"] = "第02集"

    let target = try #require(VodLineFallbackPolicy.target(site: site, detail: detail, failedSpec: failed))
    #expect(target.flag == "123Pan兼容线路")
    #expect(target.episode.name == "第02集")
    #expect(target.episode.url == "/vod-play-id-92013-src-1-num-2.html")

    failed.metadata[VodLineFallbackPolicy.appliedMetadataKey] = "true"
    #expect(VodLineFallbackPolicy.target(site: site, detail: detail, failedSpec: failed) == nil)

    let unrelatedSite = Site(key: "other", name: "其它", type: 3, api: "csp_Other")
    failed.metadata[VodLineFallbackPolicy.appliedMetadataKey] = nil
    #expect(VodLineFallbackPolicy.target(site: unrelatedSite, detail: detail, failedSpec: failed) == nil)
}

@MainActor
@Test func testWebImageRejectsTinyTransparentPlaceholderImages() {
    let placeholder = NSImage(size: NSSize(width: 4, height: 8))
    #expect(ImageLoader.isPlaceholderImage(placeholder, dataCount: 52))

    let largeGrayPlaceholder = NSImage(size: NSSize(width: 300, height: 420))
    #expect(ImageLoader.isPlaceholderImage(largeGrayPlaceholder, dataCount: 2_395))

    let poster = NSImage(size: NSSize(width: 300, height: 450))
    #expect(!ImageLoader.isPlaceholderImage(poster, dataCount: 4_096))

    let compressedAlbumArtwork = NSImage(size: NSSize(width: 200, height: 200))
    #expect(!ImageLoader.isPlaceholderImage(compressedAlbumArtwork, dataCount: 2_815))
}

@MainActor
@Test func testWebImageUsesWoggFallbackForBrokenPosterCDNs() throws {
    let baiduPlaceholderURL = try #require(URL(string: "https://gimg0.baidu.com/gimg/app=2001&n=0&g=0n&fmt=jpeg&src=img.picbf.com/upload/vod/20260529-1/829d307a2b1775ee0250e9a23f4d4879.png"))
    let baiduFallback = ImageLoader.fallbackURL(
        for: baiduPlaceholderURL,
        headers: nil,
        error: ImageLoader.ImageLoadError.placeholderImage(width: 300, height: 420, bytes: 2_395)
    )
    #expect(baiduFallback?.absoluteString == "https://cos.ffnews.cn/feedback/20251217/6941c9f5c06e2.jpg")

    let doubanMissingURL = try #require(URL(string: "https://img3.doubanio.com/view/photo/s_ratio_poster/public/p2925430983.jpg"))
    let doubanFallback = ImageLoader.fallbackURL(
        for: doubanMissingURL,
        headers: ["Referer": "https://www.wogg.net/"],
        error: ImageLoader.ImageLoadError.httpStatus(404)
    )
    #expect(doubanFallback?.absoluteString == "https://cos.ffnews.cn/feedback/20251217/6941c9f5c06e2.jpg")

    let genericURL = try #require(URL(string: "https://img.example.test/poster.jpg"))
    #expect(ImageLoader.fallbackURL(
        for: genericURL,
        headers: nil,
        error: ImageLoader.ImageLoadError.httpStatus(404)
    ) == nil)
}

@MainActor
@Test func testWebImageReplaysYGPPictureOnErrorFallback() throws {
    let missingPoster = try #require(URL(string: "https://www.6huo.com:443/files/mpic/202401/p43094.jpg?1511"))
    let fallback = ImageLoader.fallbackURL(
        for: missingPoster,
        headers: nil,
        error: ImageLoader.ImageLoadError.httpStatus(404)
    )
    #expect(fallback?.absoluteString == "https://www.6huo.com:443/files/mpic/default.jpg")

    let defaultPoster = try #require(URL(string: "https://www.6huo.com/files/mpic/default.jpg"))
    #expect(ImageLoader.fallbackURL(
        for: defaultPoster,
        headers: nil,
        error: ImageLoader.ImageLoadError.httpStatus(404)
    ) == nil)
}

@MainActor
@Test func testWebImageKeepsImageCDNRefererAheadOfSiteReferer() throws {
    let doubanURL = try #require(URL(string: "https://img1.doubanio.com/view/photo/s_ratio_poster/public/p2930800379.jpg"))
    let doubanRequest = ImageLoader.makeRequest(
        url: doubanURL,
        headers: ["Referer": "https://www.wogg.net/"],
        timeout: 15
    )
    #expect(doubanRequest.value(forHTTPHeaderField: "Referer") == "https://www.douban.com/")

    let siteURL = try #require(URL(string: "https://img.picbf.com/upload/vod/poster.jpg"))
    let siteRequest = ImageLoader.makeRequest(
        url: siteURL,
        headers: ["Referer": "https://www.wogg.net/"],
        timeout: 15
    )
    #expect(siteRequest.value(forHTTPHeaderField: "Referer") == "https://www.wogg.net/")
}

@MainActor
@Test func testDriveDirectMediaSourceResultReplacesInheritedSiteHeaders() {
    var ucStreamingMetadata: [String: String] = [:]
    ucStreamingMetadata[DrivePlaybackMetadataKey.provider] = DriveProvider.uc.rawValue
    ucStreamingMetadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.ucOpenAPIStreaming

    #expect(AppState.sourceResultShouldReplaceInheritedHeaders(
        metadata: ucStreamingMetadata,
        isDirectMedia: true
    ))
    #expect(!AppState.sourceResultShouldReplaceInheritedHeaders(
        metadata: ucStreamingMetadata,
        isDirectMedia: false
    ))
    #expect(!AppState.sourceResultShouldReplaceInheritedHeaders(
        metadata: [:],
        isDirectMedia: true
    ))
}

@Test func testFiveDriveRoutePoliciesBuildSelectableOriginalAndSmartLines() throws {
    let cases: [(provider: DriveProvider, originalRoute: String, smartRoute: String, titlePrefix: String)] = [
        (.quark, DrivePlaybackRoute.originalDownload, DrivePlaybackRoute.personalTranscode, "夸克"),
        (.uc, DrivePlaybackRoute.ucOriginalProxy, DrivePlaybackRoute.ucSmartPlay, "UC"),
        (.ali, DrivePlaybackRoute.originalDownload, DrivePlaybackRoute.personalTranscode, "阿里"),
        (.p115, DrivePlaybackRoute.originalDownload, DrivePlaybackRoute.personalTranscode, "115"),
        (.pikpak, DrivePlaybackRoute.originalDownload, DrivePlaybackRoute.streamVariant, "PikPak")
    ]

    for item in cases {
        var original = PlaySpec(url: "https://media.example.test/\(item.provider.rawValue)/original.mp4")
        original.metadata[DrivePlaybackMetadataKey.provider] = item.provider.rawValue
        original.metadata[DrivePlaybackMetadataKey.route] = item.originalRoute
        original.metadata[TestDriveFallbackMetadataKey.fallbackURL] = "https://media.example.test/\(item.provider.rawValue)/smart.m3u8"
        original.metadata[TestDriveFallbackMetadataKey.fallbackRoute] = item.smartRoute
        original.metadata[TestDriveFallbackMetadataKey.fallbackQualityLabel] = "1080P"

        let options = DrivePlaybackRoutePolicy.options(for: typedDriveSpec(original))
        #expect(options.map(\.title) == ["\(item.titlePrefix)原", "\(item.titlePrefix)智"])
        #expect(options.first?.detail == "原文件 · 本地 Range 代理")
        let smart = try #require(options.last)
        #expect(smart.detail == "智能转码 · 兼容播放")
        let expectedTransport = item.provider == .uc
            ? DrivePlaybackTransport.direct
            : DrivePlaybackTransport.hlsRelay
        #expect(DrivePlaybackRoutePolicy.candidate(for: smart.spec)?.transport == expectedTransport)
        #expect(smart.spec.metadata[DrivePlaybackRoutePolicy.selectionKindMetadataKey] == DrivePlaybackRouteKind.smart.rawValue)
        #expect(PlaybackProxyPolicy.shouldProxyDriveTranscodeHLS(for: smart.spec) == (item.provider != .uc))
    }

    var aliOriginal = PlaySpec(url: "https://cn-beijing-data.aliyundrive.net/original.mp4")
    aliOriginal.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.ali.rawValue
    aliOriginal.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    #expect(PlaybackProxyPolicy.shouldUseRemoteStreamProxy(for: typedDriveSpec(aliOriginal)))
}

@Test func testDriveAdapterDoesNotInheritHeadersIntoFallbackCandidate() throws {
    let primaryMetadata = [
        DrivePlaybackMetadataKey.provider: DriveProvider.ali.rawValue,
        DrivePlaybackMetadataKey.route: DrivePlaybackRoute.originalDownload,
        DrivePlaybackMetadataKey.fid: "ali-file"
    ]
    let fallbackMetadata = [
        DrivePlaybackMetadataKey.route: DrivePlaybackRoute.personalTranscode
    ]
    let plan = try #require(AliDrivePlaybackAdapter().playbackPlan(
        primaryURL: "https://api.aliyundrive.com/original",
        primaryHeaders: ["Authorization": "Bearer secret"],
        primaryMetadata: primaryMetadata,
        fallbackURL: "https://media.aliyundrive.net/transcode.m3u8",
        fallbackHeaders: [:],
        fallbackMetadata: fallbackMetadata
    ))

    #expect(plan.candidates[0].headers["Authorization"] == "Bearer secret")
    #expect(plan.candidates[1].headers.isEmpty)
}

@Test func testQuarkSmartSignedURLUsesLocalHLSRelayWithAccountHeaders() throws {
    let spec = PlaySpec(
        url: "https://video-play-h-zb.drive.quark.cn/qv/hash/media.m3u8?auth_key=signed&token=value",
        headers: [
            "Cookie": "kps=account",
            "Origin": "https://pan.quark.cn",
            "Referer": "https://pan.quark.cn",
            "User-Agent": QuarkDriveClient.accountPlaybackUserAgent
        ],
        metadata: [
            DrivePlaybackMetadataKey.provider: DriveProvider.quark.rawValue,
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.personalTranscode
        ]
    )

    #expect(PlaybackProxyPolicy.bypassReason(for: spec) == .quarkSmartPlaySignedURL)
    let headers = PlaybackProxyPolicy.headersForDirectPlayback(spec.headers, reason: .quarkSmartPlaySignedURL)
    #expect(headers == spec.headers)
    #expect(PlaybackProxyPolicy.shouldUseLocalHLSProxy(for: spec))
    let relay = try #require(LiveHLSRelayPolicy.localRelaySpec(from: spec, proxyPort: 9978))
    #expect(relay.url.hasPrefix("http://127.0.0.1:9978/proxy?"))
    #expect(relay.headers == spec.headers)
    let proxyOptions = PlaybackProxyPolicy.mpvOptionsForDirectPlayback(
        reason: .quarkSmartPlaySignedURL,
        activeProxyPort: 7897
    )
    #expect(proxyOptions.isEmpty)

    var alternateCDN = spec
    alternateCDN.url = "https://video-h-ekwe-zb.drive.quark.cn/qv/hash/media.m3u8?auth_key=abc&token=def"
    #expect(PlaybackProxyPolicy.bypassReason(for: alternateCDN) == .quarkSmartPlaySignedURL)
    #expect(PlaybackProxyPolicy.shouldUseLocalHLSProxy(for: alternateCDN))
}

@Test func testPlaybackActivityLayerStaysAbovePlayerReferenceCanvas() {
    #expect(PlayerOverlayLayerPolicy.playbackActivity > PlayerOverlayLayerPolicy.referenceCanvas)
}

@Test func testQuarkSmartPrefersProviderDefaultTranscode() async throws {
    let superURL = "https://video-play-h-zb.drive.quark.cn/qv/super/media.m3u8?auth_key=super"
    let fourKURL = "https://video-play-h-zb.drive.quark.cn/qv/4k/media.m3u8?auth_key=4k"
    QuarkQualityURLProtocol.configure(superURL: superURL, fourKURL: fourKURL)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QuarkQualityURLProtocol.self]
    let client = QuarkDriveClient(httpClient: HTTPClient(session: URLSession(configuration: configuration)))
    let playable = QuarkPlayableFile(
        file: QuarkShareFile(
            fid: "quality-file",
            name: "quality.mp4",
            pdirFID: "0",
            category: 1,
            fileType: 1,
            size: 1_000_000,
            formatType: "video/mp4",
            isDirectory: false,
            isFile: true,
            shareFIDToken: "quality-token"
        ),
        stoken: "quality-stoken"
    )
    let share = QuarkShareRequest(
        originalURL: "https://pan.quark.cn/s/quality",
        pwdID: "quality"
    )

    let selection = try await client.fetchFullPlayURLResult(for: playable, share: share, cookie: "kps=quality")
    #expect(selection.url == fourKURL)
    #expect(selection.isTranscoded)
    #expect(selection.transcodedURL == fourKURL)
}

@Test func testQuarkNonHLSPlayURLIsNotExposedAsSmartFallback() async throws {
    let driveURL = QuarkNonHLSURLProtocol.driveURL
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QuarkNonHLSURLProtocol.self]
    let client = QuarkDriveClient(httpClient: HTTPClient(session: URLSession(configuration: configuration)))
    let playable = QuarkPlayableFile(
        file: QuarkShareFile(
            fid: "non-hls-file",
            name: "non-hls.mkv",
            pdirFID: "0",
            category: 1,
            fileType: 1,
            size: 1_000_000,
            formatType: "video/x-matroska",
            isDirectory: false,
            isFile: true,
            shareFIDToken: "non-hls-token"
        ),
        stoken: "non-hls-stoken"
    )
    let share = QuarkShareRequest(
        originalURL: "https://pan.quark.cn/s/non-hls",
        pwdID: "non-hls"
    )

    let selection = try await client.fetchFullPlayURLResult(for: playable, share: share, cookie: "kps=non-hls")
    #expect(selection.url == driveURL)
    #expect(!selection.isTranscoded)
    #expect(selection.transcodedURL == nil)
}

@MainActor
@Test func testManualDriveRouteSelectionWaitsForPlaybackStarted() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    let episodeReference = DriveFileReference(
        provider: .quark,
        shareURL: "https://pan.quark.cn/s/test",
        pwdID: "test",
        fid: "file-id",
        fidToken: "file-token",
        fileName: "video.mp4"
    ).encodedURL
    let staleURL = "https://video-play-h-zb.drive.quark.cn/qv/stale/media.m3u8?auth_key=stale"
    var original = PlaySpec(
        url: "https://dl-pc-zb.pds.quark.cn/path/video.mp4",
        headers: [
            "Cookie": "kps=account",
            "Origin": "https://pan.quark.cn",
            "Referer": "https://pan.quark.cn",
            "User-Agent": QuarkDriveClient.accountPlaybackUserAgent
        ]
    )
    original.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.quark.rawValue
    original.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    original.metadata[TestDriveFallbackMetadataKey.fallbackURL] = staleURL
    original.metadata[TestDriveFallbackMetadataKey.fallbackRoute] = DrivePlaybackRoute.personalTranscode
    original.metadata[TestDriveFallbackMetadataKey.fallbackQualityLabel] = "1080P"
    original.metadata["vod.episodeURL"] = episodeReference
    original.fallbackHeaders = original.headers
    let prepared = appState.configureDrivePlaybackRoutes(for: typedDriveSpec(original))
    let originalRelay = try #require(LiveHLSRelayPolicy.localStreamRelaySpec(from: prepared))
    defer { ProxyServer.shared.unregisterRemoteStream(forLocalURL: originalRelay.url) }
    #expect(ProxyServer.shared.remoteStreamPlaybackInfo(forLocalURL: originalRelay.url) != nil)
    appState.playerState.currentSpec = originalRelay
    appState.playerState.position = 48.5

    var capturedSpec: PlaySpec?
    appState.playSpecHandler = { spec in capturedSpec = spec }
    let smart = try #require(appState.drivePlaybackRoutes.last)

    await appState.selectDrivePlaybackRoute(smart)

    let selected = try #require(capturedSpec)
    let selectedComponents = try #require(URLComponents(string: selected.url))
    let selectedQuery = Dictionary(
        uniqueKeysWithValues: (selectedComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    #expect(selectedComponents.host == "127.0.0.1")
    #expect(selectedComponents.path.hasPrefix("/proxy"))
    #expect(ProxyURLCodec.decode(selectedQuery["u64"] ?? "") == staleURL)
    #expect(selected.headers["Cookie"] == "kps=account")
    #expect(selected.headers["Origin"] == "https://pan.quark.cn")
    #expect(selected.headers["Referer"] == "https://pan.quark.cn")
    #expect(selected.headers["User-Agent"] == QuarkDriveClient.accountPlaybackUserAgent)
    #expect(selected.metadata[DrivePlaybackRoutePolicy.manualSelectionMetadataKey] == "true")
    #expect(appState.selectedDrivePlaybackRouteID == "quark:original-download")
    #expect(appState.pendingDrivePlaybackRouteID == "quark:personal-transcode")
    #expect(appState.playbackDowngradeMessage == nil)
    #expect(ProxyServer.shared.remoteStreamPlaybackInfo(forLocalURL: originalRelay.url) == nil)

    appState.handleMPVPlaybackStarted(spec: selected)

    #expect(appState.selectedDrivePlaybackRouteID == "quark:personal-transcode")
    #expect(appState.pendingDrivePlaybackRouteID == nil)
    #expect(appState.playbackDowngradeMessage == "已切换到“夸克智”线路。")
}

@MainActor
@Test func testFailedManualDriveRouteSelectionTerminatesWithoutAutomaticSwitch() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var original = PlaySpec(url: "https://dl-pc-zb.pds.quark.cn/path/video.mp4")
    original.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.quark.rawValue
    original.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    original.metadata[TestDriveFallbackMetadataKey.fallbackURL] = "https://video-h.example.test/quark/1080.m3u8"
    original.metadata[TestDriveFallbackMetadataKey.fallbackRoute] = DrivePlaybackRoute.personalTranscode
    let prepared = appState.configureDrivePlaybackRoutes(for: typedDriveSpec(original))
    appState.playerState.currentSpec = prepared

    var capturedSpecs: [PlaySpec] = []
    appState.playSpecHandler = { spec in capturedSpecs.append(spec) }
    let smart = try #require(appState.drivePlaybackRoutes.last)
    await appState.selectDrivePlaybackRoute(smart)

    let failed = try #require(capturedSpecs.first)
    appState.handleMPVPlaybackFailure(spec: failed, message: "mpv 播放结束但返回错误: loading failed")
    try await Task.sleep(nanoseconds: 20_000_000)

    #expect(capturedSpecs.count == 1)
    #expect(appState.selectedDrivePlaybackRouteID == "quark:original-download")
    #expect(appState.pendingDrivePlaybackRouteID == nil)
    #expect(appState.playbackDowngradeMessage == nil)
    #expect(appState.playerState.errorMessage == "夸克网盘原片和兼容线路均播放失败，请重试或切换来源。")
}

@MainActor
@Test func testFailedManualQuarkSmartRouteDoesNotRefreshOrSwitch() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    let episodeReference = DriveFileReference(
        provider: .quark,
        shareURL: "https://pan.quark.cn/s/recovery",
        pwdID: "recovery",
        fid: "recovery-file-id",
        fidToken: "recovery-file-token",
        fileName: "video.mp4"
    ).encodedURL
    let staleURL = "https://video-play-h-zb.drive.quark.cn/qv/stale/media.m3u8?auth_key=stale"
    var original = PlaySpec(url: "https://dl-pc-zb.pds.quark.cn/path/video.mp4")
    original.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.quark.rawValue
    original.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    original.metadata[TestDriveFallbackMetadataKey.fallbackURL] = staleURL
    original.metadata[TestDriveFallbackMetadataKey.fallbackRoute] = DrivePlaybackRoute.personalTranscode
    original.metadata["vod.episodeURL"] = episodeReference
    let prepared = appState.configureDrivePlaybackRoutes(for: typedDriveSpec(original))
    appState.playerState.currentSpec = prepared

    var refreshCount = 0
    appState.drivePlaybackSourceRefreshHandler = { sourceSpec, sourceURL in
        #expect(sourceURL == episodeReference)
        refreshCount += 1
        return sourceSpec
    }
    var capturedSpecs: [PlaySpec] = []
    appState.playSpecHandler = { spec in capturedSpecs.append(spec) }

    let smart = try #require(appState.drivePlaybackRoutes.last)
    await appState.selectDrivePlaybackRoute(smart)
    let firstAttempt = try #require(capturedSpecs.first)
    appState.handleMPVPlaybackFailure(
        spec: firstAttempt,
        message: "mpv 播放结束但返回错误: loading failed"
    )
    try await Task.sleep(nanoseconds: 20_000_000)

    #expect(capturedSpecs.count == 1)
    #expect(refreshCount == 0)
    #expect(appState.pendingDrivePlaybackRouteID == nil)
    #expect(appState.selectedDrivePlaybackRouteID == "quark:original-download")
    #expect(appState.playerState.errorMessage == "夸克网盘原片和兼容线路均播放失败，请重试或切换来源。")
}

@MainActor
@Test func testDriveLocalStreamFailureFallsBackToTranscode() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var localStream = PlaySpec(url: "http://127.0.0.1:9978/stream?id=quark-original")
    localStream.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.quark.rawValue
    localStream.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    localStream.metadata[TestDriveFallbackMetadataKey.fallbackURL] = "https://video-play-h-zb.drive.quark.cn/qv/hash/media.m3u8?auth_key=signed"
    localStream.metadata[TestDriveFallbackMetadataKey.fallbackRoute] = DrivePlaybackRoute.personalTranscode
    localStream.metadata[TestDriveFallbackMetadataKey.fallbackQualityLabel] = "4K"
    localStream.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.localStreamRelayTransport
    localStream.metadata["vod.episodeURL"] = "netvplayer-drive://quark/file?fid=original"
    localStream.headers = [
        "Cookie": "kps=token",
        "Referer": "https://pan.quark.cn",
        "User-Agent": QuarkDriveClient.accountPlaybackUserAgent
    ]
    localStream.fallbackHeaders = localStream.headers
    localStream.mpvOptions = [
        "demuxer-lavf-format": "mov",
        "demuxer-lavf-o": "skip_initial_bytes=8",
        "stream-lavf-o": "headers=Cookie: kps=token"
    ]
    localStream = installDriveSpec(localStream, in: appState)
    appState.playerState.position = 126.2

    var capturedSpec: PlaySpec?
    appState.playSpecHandler = { spec in
        capturedSpec = spec
    }

    appState.handleMPVPlaybackFailure(
        spec: localStream,
        message: "本地 stream relay 拉流失败：上游连接被中断或不支持分段转发，请切换线路。"
    )
    for _ in 0..<50 where capturedSpec == nil {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    let fallback = try #require(capturedSpec)
    let fallbackComponents = try #require(URLComponents(string: fallback.url))
    let fallbackQuery = Dictionary(
        uniqueKeysWithValues: (fallbackComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    #expect(fallbackComponents.host == "127.0.0.1")
    #expect(fallbackComponents.path.hasPrefix("/proxy"))
    #expect(
        ProxyURLCodec.decode(fallbackQuery["u64"] ?? "")
            == "https://video-play-h-zb.drive.quark.cn/qv/hash/media.m3u8?auth_key=signed"
    )
    #expect(fallback.headers["Cookie"] == "kps=token")
    #expect(fallback.headers["Referer"] == "https://pan.quark.cn")
    #expect(fallback.headers["User-Agent"] == QuarkDriveClient.accountPlaybackUserAgent)
    #expect(fallback.mpvOptions["demuxer-lavf-format"] == nil)
    #expect(fallback.mpvOptions["demuxer-lavf-o"] == nil)
    #expect(fallback.mpvOptions["stream-lavf-o"] == nil)
    #expect(fallback.metadata[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.personalTranscode)
    #expect(DrivePlaybackRoutePolicy.candidate(for: fallback)?.id == "quark:personal-transcode")
    #expect(fallback.drivePlaybackSessionGeneration == localStream.drivePlaybackSessionGeneration)
    #expect(fallback.metadata[DrivePlaybackRoutePolicy.transportMetadataKey] == DrivePlaybackTransport.hlsRelay.rawValue)
    #expect(fallback.metadata[LiveHLSRelayPolicy.transportMetadataKey] == LiveHLSRelayPolicy.localRelayTransport)
    #expect(appState.playerState.drivePlaybackStatus == "正在切换 夸克智")
    #expect(appState.pendingDrivePlaybackRouteID == "quark:personal-transcode")
    #expect(appState.playbackDowngradeMessage == nil)
    #expect(appState.playerState.errorMessage == nil)

    appState.handleMPVPlaybackStarted(spec: fallback)

    #expect(appState.pendingDrivePlaybackRouteID == nil)
    #expect(appState.selectedDrivePlaybackRouteID == "quark:personal-transcode")
    #expect(appState.playbackDowngradeMessage == "已自动降级到“夸克智”线路（4K），以保持播放流畅。")
}

@MainActor
@Test func testDriveDirectOriginalFailureDoesNotSkipLocalServerToTranscode() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var directOriginal = PlaySpec(url: "https://dl-pc-zb.pds.quark.cn/path/video.mp4")
    directOriginal.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.quark.rawValue
    directOriginal.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    directOriginal.metadata[TestDriveFallbackMetadataKey.fallbackURL] = "https://video-h.example.test/quark/4k.m3u8"
    directOriginal.metadata[TestDriveFallbackMetadataKey.fallbackRoute] = DrivePlaybackRoute.personalTranscode
    appState.playerState.currentSpec = directOriginal

    var capturedSpec: PlaySpec?
    appState.playSpecHandler = { spec in
        capturedSpec = spec
    }

    appState.handleMPVPlaybackFailure(
        spec: directOriginal,
        message: "mpv 播放结束但返回错误: unrecognized file format"
    )
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(capturedSpec == nil)
}

@MainActor
@Test func testDriveQuarkOriginalStallFallsBackAndNotifiesUser() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    let episodeReference = DriveFileReference(
        provider: .quark,
        shareURL: "https://pan.quark.cn/s/stall-test",
        pwdID: "stall-test",
        fid: "stall-file-id",
        fidToken: "stall-file-token",
        fileName: "stall-video.mp4"
    ).encodedURL
    let staleURL = "https://video-play-h-zb.drive.quark.cn/qv/stall-old/media.m3u8?auth_key=stale"
    var localStream = PlaySpec(url: "http://127.0.0.1:9978/stream?id=quark-original")
    localStream.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.quark.rawValue
    localStream.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    localStream.metadata[TestDriveFallbackMetadataKey.fallbackURL] = staleURL
    localStream.metadata[TestDriveFallbackMetadataKey.fallbackRoute] = DrivePlaybackRoute.personalTranscode
    localStream.metadata[TestDriveFallbackMetadataKey.fallbackQualityLabel] = "4K"
    localStream.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.localStreamRelayTransport
    localStream.metadata["vod.episodeURL"] = episodeReference
    localStream.headers = [
        "Cookie": "kps=stall-token",
        "Origin": "https://pan.quark.cn",
        "Referer": "https://pan.quark.cn",
        "User-Agent": QuarkDriveClient.accountPlaybackUserAgent
    ]
    localStream.fallbackHeaders = localStream.headers
    localStream = installDriveSpec(localStream, in: appState)
    appState.playerState.position = 126.2
    appState.playerState.isBuffering = true

    var capturedSpec: PlaySpec?
    appState.playSpecHandler = { spec in
        capturedSpec = spec
    }
    appState.handleMPVPlaybackStall(spec: localStream, positionSeconds: 126.2)
    for _ in 0..<50 where capturedSpec == nil {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    let fallback = try #require(capturedSpec)
    #expect(fallback.headers["Cookie"] == "kps=stall-token")
    #expect(fallback.headers["User-Agent"] == QuarkDriveClient.accountPlaybackUserAgent)
    let fallbackComponents = try #require(URLComponents(string: fallback.url))
    let fallbackQuery = Dictionary(
        uniqueKeysWithValues: (fallbackComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    #expect(fallbackComponents.host == "127.0.0.1")
    #expect(fallbackComponents.path.hasPrefix("/proxy"))
    #expect(ProxyURLCodec.decode(fallbackQuery["u64"] ?? "") == staleURL)
    #expect(fallback.mpvOptions["http-proxy"] == nil)
    #expect(fallback.metadata[LiveHLSRelayPolicy.transportMetadataKey] == LiveHLSRelayPolicy.localRelayTransport)
    #expect(DrivePlaybackRoutePolicy.candidate(for: fallback)?.id == "quark:personal-transcode")
    #expect(fallback.drivePlaybackSessionGeneration == localStream.drivePlaybackSessionGeneration)
    #expect(appState.playerState.drivePlaybackStatus == "正在切换 夸克智")
    #expect(appState.playbackDowngradeMessage == nil)
    #expect(appState.playerState.errorMessage == nil)

    appState.handleMPVPlaybackStarted(spec: fallback)
    #expect(appState.playbackDowngradeMessage == "已自动降级到“夸克智”线路（4K），以保持播放流畅。")

    appState.dismissPlaybackDowngradeNotice()
    #expect(appState.playbackDowngradeMessage == nil)
}

@MainActor
@Test func testDriveQuarkRecoveredStallCancelsPendingFallback() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    let episodeReference = DriveFileReference(
        provider: .quark,
        shareURL: "https://pan.quark.cn/s/recovered-stall-test",
        pwdID: "recovered-stall-test",
        fid: "recovered-stall-file-id",
        fidToken: "recovered-stall-file-token",
        fileName: "recovered-stall-video.mp4"
    ).encodedURL
    var localStream = PlaySpec(url: "http://127.0.0.1:9978/stream?id=quark-recovered-stall")
    localStream.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.quark.rawValue
    localStream.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    localStream.metadata[TestDriveFallbackMetadataKey.fallbackURL]
        = "https://video-play-h-zb.drive.quark.cn/qv/recovered-stall/media.m3u8?auth_key=stale"
    localStream.metadata[TestDriveFallbackMetadataKey.fallbackRoute] = DrivePlaybackRoute.personalTranscode
    localStream.metadata[LiveHLSRelayPolicy.transportMetadataKey]
        = LiveHLSRelayPolicy.localStreamRelayTransport
    localStream.metadata["vod.episodeURL"] = episodeReference
    localStream = installDriveSpec(localStream, in: appState)
    appState.playerState.isBuffering = true

    var capturedSpec: PlaySpec?
    appState.playSpecHandler = { capturedSpec = $0 }

    appState.handleMPVPlaybackStall(spec: localStream, positionSeconds: 1_304.639)
    appState.playerState.isBuffering = false
    appState.handleMPVPlaybackStallRecovery(spec: localStream)
    try await Task.sleep(nanoseconds: 500_000_000)

    #expect(capturedSpec == nil)
    #expect(appState.pendingDrivePlaybackRouteID == nil)
    #expect(appState.playerState.currentSpec?.url == localStream.url)
    #expect(appState.playerState.errorMessage == nil)
}

@MainActor
@Test func testDriveUCOriginalFailureFallsBackOnce() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var original = PlaySpec(url: "http://127.0.0.1:9978/stream?id=uc-original")
    original.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.uc.rawValue
    original.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.ucOriginalProxy
    original.metadata[TestDriveFallbackMetadataKey.fallbackURL] = "https://video-play-c-zb.drive.uc.cn/qv/178/media.m3u8?auth_key=smart"
    original.metadata[TestDriveFallbackMetadataKey.fallbackRoute] = DrivePlaybackRoute.ucSmartPlay
    original.metadata[TestDriveFallbackMetadataKey.fallbackQuality] = "low"
    original.metadata[TestDriveFallbackMetadataKey.fallbackQualityLabel] = "流畅"
    original.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.localStreamRelayTransport
    original = installDriveSpec(original, in: appState)

    var capturedSpec: PlaySpec?
    appState.playSpecHandler = { spec in
        capturedSpec = spec
    }

    appState.handleMPVPlaybackFailure(spec: original, message: "本地视频流启动失败，原片尾部定位请求未能完成。")
    for _ in 0..<50 where capturedSpec == nil {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    let fallback = try #require(capturedSpec)
    #expect(fallback.metadata[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.ucSmartPlay)
    #expect(DrivePlaybackRoutePolicy.candidate(for: fallback)?.id == "uc:uc-smart-play")
    #expect(fallback.drivePlaybackSessionGeneration == original.drivePlaybackSessionGeneration)
    #expect(appState.playerState.errorMessage == nil)
}

@MainActor
@Test func testDriveUCFallbackFailureShowsTerminalError() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var fallback = PlaySpec(url: "https://video-play-c-zb.drive.uc.cn/qv/178/media.m3u8?auth_key=smart")
    fallback.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.uc.rawValue
    fallback.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.ucSmartPlay
    fallback.metadata[TestDriveFallbackMetadataKey.fallbackApplied] = "true"
    fallback = installDriveSpec(fallback, in: appState)
    appState.playerState.drivePlaybackStatus = "转码 流畅"
    appState.isPlayerLoading = true

    var capturedSpec: PlaySpec?
    appState.playSpecHandler = { spec in
        capturedSpec = spec
    }

    appState.handleMPVPlaybackFailure(spec: fallback, message: "mpv 播放结束但返回错误: loading failed")
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(capturedSpec == nil)
    #expect(appState.isPlayerLoading == false)
    #expect(appState.playerState.drivePlaybackStatus == nil)
    #expect(appState.playerState.errorMessage == "UC网盘原片和兼容线路均播放失败，请重试或切换来源。")
}

@MainActor
@Test func testDriveUCOriginalWithoutFallbackShowsTerminalError() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var original = PlaySpec(url: "http://localhost:9978/stream?id=uc-no-fallback")
    original.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.uc.rawValue
    original.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.ucOriginalProxy
    original.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.localStreamRelayTransport
    original = installDriveSpec(original, in: appState)
    appState.isPlayerLoading = true

    var capturedSpec: PlaySpec?
    appState.playSpecHandler = { spec in
        capturedSpec = spec
    }

    appState.handleMPVPlaybackFailure(spec: original, message: "本地视频流启动超时，原片在 60 秒内未返回可播放数据。")
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(capturedSpec == nil)
    #expect(appState.isPlayerLoading == false)
    #expect(appState.playerState.errorMessage == "UC网盘原片和兼容线路均播放失败，请重试或切换来源。")
}

@MainActor
@Test func testDriveUCOriginalStallFallsBackOnce() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var original = PlaySpec(url: "http://127.0.0.1:9978/stream?id=uc-stalled-original")
    original.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.uc.rawValue
    original.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.ucOriginalProxy
    original.metadata[TestDriveFallbackMetadataKey.fallbackURL] = "https://video-play-c-zb.drive.uc.cn/qv/178/media.m3u8?auth_key=smart"
    original.metadata[TestDriveFallbackMetadataKey.fallbackRoute] = DrivePlaybackRoute.ucSmartPlay
    original.metadata[TestDriveFallbackMetadataKey.fallbackQualityLabel] = "流畅"
    original.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.localStreamRelayTransport
    original = installDriveSpec(original, in: appState)
    appState.playerState.isBuffering = true

    var capturedSpec: PlaySpec?
    appState.playSpecHandler = { spec in
        capturedSpec = spec
    }

    appState.handleMPVPlaybackStall(spec: original, positionSeconds: 0.6)
    for _ in 0..<50 where capturedSpec == nil {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    let fallback = try #require(capturedSpec)
    #expect(DrivePlaybackRoutePolicy.candidate(for: fallback)?.id == "uc:uc-smart-play")
    #expect(appState.playbackDowngradeMessage == nil)
    #expect(appState.playerState.errorMessage == nil)

    appState.handleMPVPlaybackStarted(spec: fallback)
    #expect(appState.playbackDowngradeMessage == "已自动降级到“UC智”线路（流畅），以保持播放流畅。")
}

@MainActor
@Test func testDriveUCOriginalStallWithoutFallbackShowsTerminalError() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var original = PlaySpec(url: "http://localhost:9978/stream?id=uc-stalled-no-fallback")
    original.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.uc.rawValue
    original.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.ucOriginalProxy
    original.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.localStreamRelayTransport
    original = installDriveSpec(original, in: appState)
    appState.playerState.isBuffering = true
    appState.playerState.drivePlaybackStatus = "原片"
    appState.isPlayerLoading = true

    appState.handleMPVPlaybackStall(spec: original, positionSeconds: 0.6)
    for _ in 0..<30 where appState.playerState.errorMessage == nil {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    #expect(appState.isPlayerLoading == false)
    #expect(appState.playerState.drivePlaybackStatus == nil)
    #expect(appState.playerState.errorMessage == "UC网盘原片和兼容线路均播放失败，请重试或切换来源。")
}

@MainActor
@Test func testDriveUCFallbackAuthFailureOffersReauthorization() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var fallback = PlaySpec(url: "https://video-play-c-zb.drive.uc.cn/qv/178/media.m3u8?auth_key=guest")
    fallback.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.uc.rawValue
    fallback.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.ucSmartPlay
    fallback.metadata[TestDriveFallbackMetadataKey.fallbackApplied] = "true"
    fallback.metadata[TestDriveFallbackMetadataKey.fallbackAuthRequired] = "true"
    fallback = installDriveSpec(fallback, in: appState)

    appState.handleMPVPlaybackFailure(spec: fallback, message: "mpv 播放结束但返回错误: loading failed")
    for _ in 0..<20 where appState.playerState.errorMessage == nil {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    #expect(appState.playerState.errorMessage == "UC网盘登录已失效，请重新授权后重试。")
    #expect(appState.playbackErrorAuthProvider == .uc)
}

@MainActor
@Test func testDriveUCTransferAuthFailureWarnsBeforePlaybackFails() {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    let episode = Episode(name: "178", url: "netvplayer-drive://uc/file?fid=178")
    var original = typedDriveSpec(PlaySpec(
        url: "https://cdn.example.test/uc-original.mp4",
        metadata: [
            DrivePlaybackMetadataKey.provider: DriveProvider.uc.rawValue,
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.ucOriginalProxy,
            DrivePlaybackMetadataKey.fid: "178"
        ]
    ))
    let plan = try! #require(original.drivePlaybackPlan)
    original.drivePlaybackPlan = DrivePlaybackPlan(
        provider: plan.provider,
        asset: plan.asset,
        candidates: plan.candidates,
        cleanup: plan.cleanup,
        reauthenticationRequired: true,
        unavailableReason: "personal-transfer-failed"
    )

    appState.updateDrivePlaybackWarning(for: original, episode: episode)

    #expect(appState.playerState.errorMessage == nil)
    #expect(appState.playbackWarningMessage == "UC网盘备用线路需要重新授权，当前线路仍会继续尝试播放。")
    #expect(appState.playbackErrorAuthProvider == .uc)

    appState.openCloudAuthFromPlaybackError()

    #expect(appState.playbackWarningMessage == nil)
    #expect(appState.cloudAuthRequest == CloudAuthRequest(provider: .uc, pendingEpisodeURL: episode.url))
}

@MainActor
@Test func testDriveUCTransferFailureWarnsWithoutOfferingIrrelevantReauthorization() {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    let episode = Episode(name: "178", url: "netvplayer-drive://uc/file?fid=178")
    var original = typedDriveSpec(PlaySpec(
        url: "https://cdn.example.test/uc-original.mp4",
        metadata: [
            DrivePlaybackMetadataKey.provider: DriveProvider.uc.rawValue,
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.ucOriginalProxy,
            DrivePlaybackMetadataKey.fid: "178"
        ]
    ))
    let plan = try! #require(original.drivePlaybackPlan)
    original.drivePlaybackPlan = DrivePlaybackPlan(
        provider: plan.provider,
        asset: plan.asset,
        candidates: plan.candidates,
        cleanup: plan.cleanup,
        unavailableReason: "personal-transfer-failed"
    )

    appState.updateDrivePlaybackWarning(for: original, episode: episode)

    #expect(appState.playbackWarningMessage == "UC网盘备用线路暂不可用，当前线路仍会继续尝试播放。")
    #expect(appState.playbackErrorAuthProvider == nil)
    #expect(appState.cloudAuthRequest == nil)
}

@MainActor
@Test func testUCLoginRequiredOpensAuthorizationBeforePresentingPlayer() {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    let episode = Episode(name: "178", url: "netvplayer-drive://uc/file?fid=178")

    appState.handlePlaybackError(DriveEngineError.loginRequired(.uc), episode: episode)

    #expect(appState.isPlayerPresented == false)
    #expect(appState.isPlaybackErrorPresented == false)
    #expect(appState.playbackErrorAuthProvider == .uc)
    #expect(appState.cloudAuthRequest == CloudAuthRequest(provider: .uc, pendingEpisodeURL: episode.url))
}

@Test func testQuarkSignedChildStreamsBeforeUpstreamCompletes() async throws {
    let rawURL = "https://video-play-h-zb.drive.quark.cn/qv/progressive/media-0.ts?ct=segment%253D"
    let normalizedURL = "https://video-play-h-zb.drive.quark.cn/qv/progressive/media-0.ts?ct=segment%3D"
    ProgressiveQuarkURLProtocol.configure(rawURL: rawURL, normalizedURL: normalizedURL)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProgressiveQuarkURLProtocol.self]
    let httpClient = HTTPClient(session: URLSession(configuration: configuration))
    let handlers = ProxyPlaybackHandler.makeHandlers(httpClient: httpClient, streamChunkSize: 4)
    let recorder = ProgressiveStreamRecorder()

    let streamTask = Task {
        let handled = try await handlers.streaming(
            [
                "u64": ProxyURLCodec.encode(rawURL),
                "h64": ProxyURLCodec.encode("{}"),
                "hls": "1",
                "qctx": "progressive-test"
            ],
            { head in await recorder.record(head: head) },
            { data in await recorder.append(data) }
        )
        await recorder.markFinished()
        return handled
    }

    var midstream = await recorder.snapshot()
    for _ in 0..<25 where midstream.data.count < 4 {
        try await Task.sleep(nanoseconds: 20_000_000)
        midstream = await recorder.snapshot()
    }
    let deliveredBeforeCompletion = midstream.data == Data("part".utf8) && !midstream.finished

    let handled = try await streamTask.value
    let completed = await recorder.snapshot()
    let requestedURLs = ProgressiveQuarkURLProtocol.requestedURLs()

    #expect(handled)
    #expect(deliveredBeforeCompletion)
    #expect(midstream.head?.statusCode == 200)
    #expect(midstream.head?.closeConnection == true)
    #expect(completed.data == Data("parttail".utf8))
    #expect(completed.finished)
    #expect(requestedURLs.contains(rawURL))
    #expect(requestedURLs.contains(normalizedURL))
}

@Test func testGenericMediaStreamForwardsRangeWithoutCompressedResponseMetadata() async throws {
    let targetURL = "https://media.example.test/video.mp4"
    GenericMediaStreamURLProtocol.reset()

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GenericMediaStreamURLProtocol.self]
    let handlers = ProxyPlaybackHandler.makeHandlers(
        httpClient: HTTPClient(session: URLSession(configuration: configuration)),
        streamChunkSize: 4
    )
    let recorder = ProgressiveStreamRecorder()
    let handled = try await handlers.streaming(
        [
            "u64": ProxyURLCodec.encode(targetURL),
            "h64": ProxyURLCodec.encode("{}"),
            "stream": "1",
            "__downstream_range": "bytes=64-127"
        ],
        { head in await recorder.record(head: head) },
        { data in await recorder.append(data) }
    )
    let head = await recorder.snapshot().head
    let request = try #require(GenericMediaStreamURLProtocol.recordedRequest())

    #expect(handled)
    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=64-127")
    #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    #expect(head?.headers.keys.contains { $0.caseInsensitiveCompare("Content-Encoding") == .orderedSame } == false)
}

@Test func testGenericMediaStreamForwardsHTTP400ResponseHead() async throws {
    let targetURL = "https://media.example.test/expired-video.mp4"
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HTTP400MediaStreamURLProtocol.self]
    let handlers = ProxyPlaybackHandler.makeHandlers(
        httpClient: HTTPClient(session: URLSession(configuration: configuration)),
        streamChunkSize: 4
    )
    let recorder = ProgressiveStreamRecorder()
    let handled = try await handlers.streaming(
        [
            "u64": ProxyURLCodec.encode(targetURL),
            "h64": ProxyURLCodec.encode("{}"),
            "stream": "1"
        ],
        { head in await recorder.record(head: head) },
        { data in await recorder.append(data) }
    )
    let snapshot = await recorder.snapshot()

    #expect(handled)
    #expect(snapshot.head?.statusCode == 400)
    #expect(snapshot.data == Data("parttail".utf8))
}

@Test func testAliSignedHLSChildStreamsBeforeUpstreamCompletes() async throws {
    let segmentURL = "https://cn-beijing-video-preview.aliyundrive.net/qv/progressive/media-0.ts?security-token=test-token&x-oss-signature=test-signature&x-oss-signature-version=OSS2"
    ProgressiveAliURLProtocol.configure(url: segmentURL)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProgressiveAliURLProtocol.self]
    let handlers = ProxyPlaybackHandler.makeHandlers(
        httpClient: HTTPClient(session: URLSession(configuration: configuration)),
        streamChunkSize: 4
    )
    let recorder = ProgressiveStreamRecorder()

    let streamTask = Task {
        let handled = try await handlers.streaming(
            [
                "u64": ProxyURLCodec.encode(segmentURL),
                "h64": ProxyURLCodec.encode(#"{"Referer":"https://www.aliyundrive.com/"}"#),
                "hls": "1",
                "stream": "1"
            ],
            { head in await recorder.record(head: head) },
            { data in await recorder.append(data) }
        )
        await recorder.markFinished()
        return handled
    }

    var midstream = await recorder.snapshot()
    for _ in 0..<25 where midstream.data.count < 4 {
        try await Task.sleep(nanoseconds: 20_000_000)
        midstream = await recorder.snapshot()
    }
    let deliveredBeforeCompletion = midstream.data == Data("part".utf8) && !midstream.finished

    let handled = try await streamTask.value
    let completed = await recorder.snapshot()

    #expect(handled)
    #expect(deliveredBeforeCompletion)
    #expect(midstream.head?.statusCode == 200)
    #expect(midstream.head?.closeConnection == true)
    #expect(completed.data == Data("parttail".utf8))
    #expect(completed.finished)
    #expect(ProgressiveAliURLProtocol.requestedURLs() == [segmentURL])
}

private actor ProgressiveStreamRecorder {
    private var responseHead: ProxyStreamingResponseHead?
    private var body = Data()
    private var didFinish = false

    func record(head: ProxyStreamingResponseHead) {
        responseHead = head
    }

    func append(_ data: Data) {
        body.append(data)
    }

    func markFinished() {
        didFinish = true
    }

    func snapshot() -> (head: ProxyStreamingResponseHead?, data: Data, finished: Bool) {
        (responseHead, body, didFinish)
    }
}

private final class ProgressiveQuarkURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuredRawURL = ""
    nonisolated(unsafe) private static var configuredNormalizedURL = ""
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private var completionWorkItem: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let requestKind = Self.recordRequest(request)
        guard requestKind != .unexpected else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let isRaw = requestKind == .raw
        var headerFields = [
            "Content-Type": isRaw ? "text/plain" : "video/mp2t",
            "Content-Length": isRaw ? "9" : "8"
        ]
        if request.value(forHTTPHeaderField: "Range") != nil {
            headerFields["Content-Encoding"] = "gzip"
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: isRaw ? 400 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if isRaw {
            client?.urlProtocol(self, didLoad: Data("bad query".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        client?.urlProtocol(self, didLoad: Data("part".utf8))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: Data("tail".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        completionWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    override func stopLoading() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
    }

    static func configure(rawURL: String, normalizedURL: String) {
        lock.lock()
        configuredRawURL = rawURL
        configuredNormalizedURL = normalizedURL
        requests = []
        lock.unlock()
    }

    static func requestedURLs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap { $0.url?.absoluteString }
    }

    private enum RequestKind {
        case raw
        case normalized
        case unexpected
    }

    private static func recordRequest(_ request: URLRequest) -> RequestKind {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let url = request.url?.absoluteString ?? ""
        if url == configuredRawURL { return .raw }
        if url == configuredNormalizedURL { return .normalized }
        return .unexpected
    }
}

private final class ProgressiveAliURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuredURL = ""
    nonisolated(unsafe) private static var requests: [String] = []
    private var completionWorkItem: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard Self.recordRequest(url.absoluteString) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "video/mp2t",
                "Content-Length": "8"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("part".utf8))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: Data("tail".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        completionWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    override func stopLoading() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
    }

    static func configure(url: String) {
        lock.lock()
        configuredURL = url
        requests = []
        lock.unlock()
    }

    static func requestedURLs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private static func recordRequest(_ url: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requests.append(url)
        return url == configuredURL
    }
}

private final class GenericMediaStreamURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var capturedRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.capturedRequest = request
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "video/mp4",
                "Content-Length": "8",
                "Content-Encoding": "gzip",
                "Content-Range": "bytes 64-71/128"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("parttail".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        capturedRequest = nil
        lock.unlock()
    }

    static func recordedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }
}

private final class HTTP400MediaStreamURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 400,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/plain",
                "Content-Length": "8"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("parttail".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class QuarkQualityURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody = "{}"

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func configure(superURL: String, fourKURL: String) {
        lock.lock()
        responseBody = """
        {
          "status": 200,
          "code": 0,
          "message": "ok",
          "data": {
            "default_resolution": "4k",
            "video_list": [
              {
                "resolution": "4k",
                "trans_status": "success",
                "video_info": { "url": "\(fourKURL)" }
              },
              {
                "resolution": "super",
                "trans_status": "success",
                "video_info": { "url": "\(superURL)" }
              }
            ]
          }
        }
        """
        lock.unlock()
    }

    private static func body() -> String {
        lock.lock()
        defer { lock.unlock() }
        return responseBody
    }
}

private final class QuarkNonHLSURLProtocol: URLProtocol, @unchecked Sendable {
    static let driveURL = "https://video-play-m4-zb.drive.quark.cn/qv/hash/video?auth_key=signed"

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let responseBody = """
        {
          "status": 200,
          "code": 0,
          "message": "ok",
          "data": {
            "default_resolution": "super",
            "video_list": [
              {
                "resolution": "super",
                "trans_status": "success",
                "video_info": { "url": "\(Self.driveURL)" }
              }
            ]
          }
        }
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
