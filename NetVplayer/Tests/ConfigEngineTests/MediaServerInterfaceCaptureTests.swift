import AppKit
import Models
import Storage
import SwiftUI
import Testing

@testable import NetVplayerApp

@Suite("Media server account and shared detail captures", .serialized) @MainActor
struct MediaServerInterfaceCaptureTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_SERVER_UI_CAPTURE_DIR"] != nil))
  func captureSavedLoginAndRichDetails() async throws {
    let output = URL(
      fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["NETVPLAYER_SERVER_UI_CAPTURE_DIR"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let context = try AccountUIContext()
    defer { context.cleanup() }
    let prefs = UserPreferences(
      defaults: context.defaults, credentialStore: MemoryCredentialStore())
    let app = AppState(
      loadDefaultConfig: false, startProxyServer: false,
      storageManager: .init(storageDirectory: context.directory.appendingPathComponent("app")),
      userPreferences: prefs, providerRuntimeBootstrap: nil)
    let dark = AppThemeCatalog.palette(for: .auroraViolet)
    let savedModel = context.model()
    savedModel.load(checkConnection: false)
    try await capture(
      "account-saved", size: .init(width: 820, height: 680), output: output, app: app, palette: dark
    ) {
      MediaServerAccountSettings(model: savedModel, loadOnAppear: false).padding(24)

    }
    let model = context.model()
    model.load()
    try await idle(model)
    #expect(model.state == .signedIn)
    try await capture(
      "account-signed-in", size: .init(width: 820, height: 680), output: output, app: app,
      palette: dark
    ) {
      MediaServerAccountSettings(model: model, loadOnAppear: false).padding(24)
    }
    try await capture(
      "account-signed-in-light", size: .init(width: 820, height: 680), output: output, app: app,
      palette: AppThemeCatalog.palette(for: .seaSalt)
    ) {
      MediaServerAccountSettings(model: model, loadOnAppear: false).padding(24)
    }
    model.reauthenticating = true
    try await capture(
      "account-relogin", size: .init(width: 820, height: 780), output: output, app: app,
      palette: dark
    ) {
      MediaServerAccountSettings(model: model, loadOnAppear: false).padding(24)
    }
    let expired = context.model(failure: .authentication)
    expired.load()
    try await idle(expired)
    try await capture(
      "account-expired", size: .init(width: 820, height: 780), output: output, app: app,
      palette: dark
    ) {
      MediaServerAccountSettings(model: expired, loadOnAppear: false).padding(24)

    }
    let unavailable = context.model(failure: .response)
    unavailable.load()
    try await idle(unavailable)
    try await capture(
      "account-unavailable", size: .init(width: 820, height: 680), output: output, app: app,
      palette: dark
    ) {
      MediaServerAccountSettings(model: unavailable, loadOnAppear: false).padding(24)

    }
    let signedOut = context.model()
    signedOut.load(checkConnection: false)
    signedOut.logout()
    try await idle(signedOut)
    try await capture(
      "account-signed-out", size: .init(width: 820, height: 780), output: output, app: app,
      palette: dark
    ) {
      MediaServerAccountSettings(model: signedOut, loadOnAppear: false).padding(24)

    }
    app.activeSite = context.account.site()
    let artwork = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "docs/design/nas-detail-ui/assets")
    for scenario in ["movie", "series", "missing"] {
      let tv = scenario == "series"
      let missing = scenario == "missing"
      let locator = try MediaServerReference(accountID: context.account.id, itemID: scenario)
        .locator
      var vod = Vod(
        vodId: locator, vodName: missing ? "未提供资料的影片" : tv ? "示例剧集" : "A计划续集",
        vodPlayFrom: tv ? "第 1 季$$$第 2 季" : "原始文件", siteKey: context.account.siteKey)
      let episodes = try (1...(tv ? 8 : 1)).map { index in
        Episode(
          name: tv ? "第 \(index) 集" : "正片",
          url: try MediaServerReference(accountID: context.account.id, itemID: "episode\(index)")
            .locator,
          overview: tv ? "服务器提供的本集简介，用于检查卡片换行和选集布局。" : nil,
          released: tv ? "2024-01-01" : nil, season: tv ? (index > 4 ? 2 : 1) : nil, number: index)
      }
      vod.episodeDetails = episodes
      let urls: ([Episode]) -> String = { $0.map { $0.name + "$" + $0.url }.joined(separator: "#") }
      vod.vodPlayUrl =
        tv
        ? urls(Array(episodes.prefix(4))) + "$$$" + urls(Array(episodes.suffix(4))) : urls(episodes)
      let metadata = MediaMetadata(
        title: vod.vodName, originalTitle: missing ? nil : "Project A Part II",
        year: missing ? nil : 1987, kind: tv ? .television : .movies,
        plot: missing
          ? nil : "本片由成龙自编自导自演。警官马如龙奉命接管西环治安，与地方势力展开一场惊险、幽默的冒险。本次截图使用固定资料和隔离状态，不访问用户媒体库。",
        poster: missing
          ? nil : artwork.appendingPathComponent("project-a-ii-poster.jpg").absoluteString,
        fanart: missing
          ? nil : artwork.appendingPathComponent("project-a-ii-backdrop.jpg").absoluteString,
        genres: missing ? nil : ["动作", "喜剧"], runtimeMinutes: missing ? nil : 106,
        releaseDate: missing ? nil : "1987-08-19", countries: missing ? nil : ["中国香港"],
        languages: missing ? nil : ["粤语"], studios: missing ? nil : ["嘉禾影业"],
        directors: missing ? nil : ["成龙"], writers: missing ? nil : ["成龙", "邓景生"],
        cast: missing
          ? nil
          : ["成龙", "张曼玉", "关之琳", "刘嘉玲"].enumerated().map { index, name in
            .init(
              name: name, role: "角色",
              portrait: artwork.appendingPathComponent(
                ["jackie-chan.jpg", "maggie-cheung.jpg", "rosamund-kwan.png", "carina-lau.jpg"][
                  index]
              ).absoluteString)
          })
      vod.mediaServerDetail = .init(
        metadata: metadata, rating: missing ? nil : 7.1, officialRating: missing ? nil : "PG-13",
        files: missing
          ? []
          : episodes.map {
            .init(
              id: $0.url, episodeURL: $0.url, name: "示例影片.mkv", container: "mkv",
              size: 4_655_999_552, width: 3840, height: 2160, videoCodec: "hevc",
              videoRange: "HDR10",
              audio: ["粤语 · E-AC-3 · 5.1"], subtitles: ["简体中文 · SRT", "English · SRT"], sourceID: "main")
          })
      if scenario == "movie", var alternate = vod.mediaServerDetail?.files.first {
        alternate.id += "-1080p"
        alternate.name = "示例影片 · 1080p H.264.mkv"
        alternate.sourceID = "alternate"
        alternate.width = 1920; alternate.height = 1080; alternate.videoCodec = "h264"
        alternate.videoRange = "SDR"; alternate.size = 2_000_000_000
        vod.mediaServerDetail?.files[0].name = "示例影片 · 2160p HEVC HDR10.mkv"
        vod.mediaServerDetail?.files.insert(alternate, at: 0)
      }
      if scenario == "movie" {
        // The generic branch is unchanged. Render it with the previous provider's sparse mapping
        // to make the layout comparison reproducible without retaining a user's private screenshot.
        var legacy = vod
        legacy.vodId = "generic-layout-fixture"
        legacy.vodPic = metadata.poster ?? ""
        legacy.vodYear = "1987"
        legacy.vodRemarks = "Movie"
        legacy.vodContent = metadata.plot ?? ""
        legacy.mediaServerDetail = nil
        app.detailVod = legacy
        app.applyPlaybackAvailability(for: legacy)
        let layout = VodDetailLayoutPolicy.layout(in: .init(width: 1644.45, height: 1000))
        try await capture(
          "before-generic-movie", size: .init(width: 1480, height: 900), output: output, app: app,
          palette: dark
        ) {
          VodDetailView(vod: legacy, layout: layout)
        }
      }
      app.detailVod = vod
      app.applyPlaybackAvailability(for: vod)
      for width in [960, 1480] {
        let size = CGSize(width: width, height: width == 960 ? 720 : 900)
        try await capture(
          "detail-\(scenario)-\(width)", size: size, output: output, app: app, palette: dark
        ) {
          MediaServerDetailView(vod: vod, size: size)
        }
      }
    }
  }

  private func idle(_ model: MediaServerAccountModel) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while model.busy && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.busy)
  }
  private func capture<V: View>(
    _ name: String, size: CGSize, output: URL, app: AppState,
    palette: AppThemePalette, @ViewBuilder content: () -> V
  ) async throws {
    _ = NSApplication.shared
    let root = content().frame(width: size.width, height: size.height, alignment: .topLeading)
      .themedPresentation()
      .environmentObject(app).environment(\.appThemePalette, palette)
      .preferredColorScheme(palette.preferredColorScheme)
    let host = NSHostingView(rootView: root)
    let rect = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setFrame(rect, display: true)
    window.appearance = NSAppearance(
      named: palette.preferredColorScheme == .light ? .aqua : .darkAqua)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    #expect(abs(host.bounds.width - size.width) < 1 && abs(host.bounds.height - size.height) < 1)
    try snapshot(host, to: output.appendingPathComponent(name + ".png"))
    if name.hasPrefix("detail-"),
      let scroll = scrollViews(host).max(by: {
        ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
      }),
      let document = scroll.documentView, document.bounds.height > size.height
    {
      scroll.contentView.scroll(
        to: .init(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
      scroll.reflectScrolledClipView(scroll.contentView)
      host.layoutSubtreeIfNeeded()
      try snapshot(host, to: output.appendingPathComponent(name + "-lower.png"))
    }
  }
  private func snapshot(_ host: NSView, to url: URL) throws {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    try #require(bitmap.representation(using: .png, properties: [:])).write(
      to: url, options: .atomic)
  }
  private func scrollViews(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
  }
}
