import AppKit
import Foundation
import MediaServerEngine
import Models
import ProxyServer
import SpiderEngine
import Storage
import SwiftUI
import Testing
@testable import NetVplayerApp
@testable import PlayerEngine

/// Explicitly opt in: this signs into the official, public Jellyfin demo and
/// briefly plays its open movie. Ordinary tests never contact a public server.
@Suite("Official Jellyfin demo acceptance", .serialized) @MainActor
struct JellyfinDemoAcceptanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_JELLYFIN_DEMO_TEST"] == "1"))
  func officialDemoConnectionDetailsAndNativePlayback() async throws {
    let output = URL(fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["NETVPLAYER_JELLYFIN_DEMO_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jellyfin-demo-" + UUID().uuidString)
    let domain = "JellyfinDemoAcceptance." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
    let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
    let storage = StorageManager(storageDirectory: directory)
    let store = MediaServerStore(storage: storage, preferences: preferences)
    let recorder = DemoHTTPRecorder()
    let network = MediaServerTransport()
    let base = URL(string: "https://demo.jellyfin.org/stable")!
    let transport = MediaServerTransport(handler: { request, limit in
      let result = try await network.request(request, maximumBytes: limit, origin: base)
      await recorder.record(request, status: result.1.statusCode)
      return result
    })
    let runtime = MediaServerRuntime(store: store, transport: transport)
    let model = MediaServerAccountModel(store: store, transport: transport, invalidate: { await runtime.invalidate($0) })
    defer { model.stop() }
    model.load(checkConnection: false)
    model.kind = .jellyfin; model.name = "Jellyfin 官方演示"; model.server = base.absoluteString
    model.username = "demo"; model.password = ""
    model.connect(onSaved: {})
    try #require(await wait { !model.busy }, "Demo login timed out")
    try #require(model.state == .signedIn, "Demo login failed")
    model.check()
    try #require(await wait { !model.busy }, "Demo session validation timed out")
    try #require(model.state == .signedIn && model.username == "demo")
    let account = try #require(model.selected)
    let client = try MediaServerClient(account: account, token: store.token(for: account), transport: transport)
    let (publicData, _) = try await transport.request(client.request(["System", "Info", "Public"], authenticated: false), maximumBytes: 64 * 1024)
    let publicInfo = try #require(JSONSerialization.jsonObject(with: publicData) as? [String: Any])
    var evidence: [String: Any] = ["server": base.absoluteString, "serverVersion": publicInfo["Version"] ?? "unknown",
      "testedAt": ISO8601DateFormatter().string(from: Date()), "login": true, "validatedSavedSession": true]
    func save() throws {
      try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("acceptance.json"), options: .atomic)
    }
    try save()
    let app = AppState(loadDefaultConfig: false, startProxyServer: false, storageManager: storage,
      userPreferences: preferences, providerRuntimeBootstrap: nil)
    try await capture("account-connected", output: output, app: app, size: .init(width: 920, height: 680)) {
      MediaServerAccountSettings(model: model, loadOnAppear: false).padding(24)
    }
    let provider = MediaServerNativeProvider(accountID: account.id, runtime: runtime)
    let site = account.site()
    let home = try await provider.homeContent(site: site)
    let libraries = home.types
    let movies = try #require(libraries.first { $0.typeName == "Movies" })
    let listing = try await provider.categoryContent(site: site, tid: movies.typeId, page: "1", filter: false, extend: [:])
    #expect(!listing.list.isEmpty)
    let search = try await provider.searchContent(site: site, keyword: "Caminandes", quick: false, page: "1")
    let movie = try #require(search.list.first { $0.vodName == "Caminandes: Llama Drama" })
    var vod = try #require(try await provider.detailContent(site: site, id: movie.vodId).list.first)
    let detail = try #require(vod.mediaServerDetail)
    #expect(detail.metadata.year == 2013 && detail.rating != nil)
    #expect(!(detail.metadata.plot ?? "").isEmpty && !(detail.metadata.directors ?? []).isEmpty)
    let file = try #require(detail.files.first)
    let selectedLocator = try #require(file.playbackLocator)
    #expect(file.videoCodec == "h264" && !file.audio.isEmpty)
    // Exercise authenticated image fetching, then give the isolated native view
    // those exact bytes. Its ordinary artwork loader uses the app's shared store.
    var imageCount = 0
    func cachedArtwork(_ locator: String?, name: String) async throws -> String? {
      guard let locator, let reference = MediaServerArtworkReference(locator: locator) else { return locator }
      let bytes = try await runtime.artwork(reference)
      try #require(NSImage(data: bytes) != nil)
      let path = directory.appendingPathComponent(name + ".jpg")
      try bytes.write(to: path, options: .atomic)
      imageCount += 1
      return path.absoluteString
    }
    vod.mediaServerDetail?.metadata.poster = try await cachedArtwork(detail.metadata.poster, name: "poster")
    vod.mediaServerDetail?.metadata.fanart = try await cachedArtwork(detail.metadata.fanart, name: "backdrop")
    for index in detail.metadata.cast?.indices ?? 0..<0 {
      vod.mediaServerDetail?.metadata.cast?[index].portrait = try await cachedArtwork(detail.metadata.cast?[index].portrait, name: "person-\(index)")
    }
    app.activeSite = site; app.detailVod = vod; app.applyPlaybackAvailability(for: vod)
    try await capture("movie-detail", output: output, app: app, size: .init(width: 1280, height: 820)) {
      MediaServerDetailView(vod: vod, size: .init(width: 1280, height: 820))
    }
    if let shows = libraries.first(where: { $0.typeName == "Shows" }) {
      let showsPage = try await provider.categoryContent(site: site, tid: shows.typeId, page: "1", filter: false, extend: [:])
      let show = try #require(showsPage.list.first)
      let series = try #require(try await provider.detailContent(site: site, id: show.vodId).list.first)
      #expect(!series.episodeDetails.isEmpty)
      evidence["series"] = ["title": series.vodName, "episodes": series.episodeDetails.count]
    }
    evidence["libraries"] = libraries.map(\.typeName)
    evidence["movieCount"] = listing.list.count; evidence["searchResults"] = search.list.count
    let movieYear: Int = detail.metadata.year ?? 0
    let movieRating: Double = detail.rating ?? 0
    let videoCodec: String = file.videoCodec ?? "unknown"
    let videoWidth: Int = file.width ?? 0
    let videoHeight: Int = file.height ?? 0
    evidence["movie"] = ["title": vod.vodName, "year": movieYear,
      "rating": movieRating, "fileCount": detail.files.count, "authenticatedImages": imageCount,
      "codec": videoCodec, "width": videoWidth, "height": videoHeight]
    try save()

    try ProxyServer.shared.start()
    defer { ProxyServer.shared.stop() }
    let result = try await provider.playerContent(site: site, flag: "原始文件", id: selectedLocator)
    let owner = try #require(result.mediaServer)
    var range = URLRequest(url: try #require(URL(string: result.url)))
    range.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
    let (bytes, response) = try await URLSession.shared.data(for: range)
    try #require((response as? HTTPURLResponse)?.statusCode == 206 && bytes.count == 1024)
    try #require(String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp")
    evidence["originalRange"] = ["status": 206, "bytes": bytes.count]
    try save()
    _ = NSApplication.shared
    let audio = PlaybackAudioPreferenceStore(defaults: defaults); audio.setMuted(true)
    let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: .fullDestroy, audioPreferences: audio)
    let state = PlayerState(); engine.playerState = state
    engine.performanceDiagnosticsHandler = { _, _ in }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
    let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
    view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
    engine.attach(to: view, surface: .vod)
    defer { engine.performanceDiagnosticsHandler = nil; engine.stop(); engine.detach(from: view); window.orderOut(nil) }
    var spec = PlaySpec(url: result.url, subs: result.subs, title: vod.vodName)
    spec.mediaServer = owner; spec.initialStartPositionSeconds = 0
    await engine.play(spec: spec)
    try #require(await wait { state.errorMessage != nil || (!state.isMediaLoading && state.position > 1 && engine.performanceFrameSnapshot.freshFrames > 2) }, "Native playback timed out")
    try #require(state.errorMessage == nil, "Native playback reported an error")
    await runtime.report(owner.leaseID, snapshot: .init(seconds: state.position, muted: true), started: true)
    engine.pause()
    try #require(await wait { !state.isPlaying })
    engine.seek(to: 25_000)
    try #require(await wait { abs(state.position - 25) < 0.5 && !state.isSeeking })
    #expect(!state.isPlaying)
    await runtime.report(owner.leaseID, snapshot: .init(seconds: state.position, paused: true, muted: true))
    engine.resume()
    try #require(await wait { state.isPlaying && state.position > 26 })
    let frames = engine.performanceFrameSnapshot
    evidence["nativePlayback"] = ["durationSeconds": state.duration, "finalPositionSeconds": state.position,
      "freshFrames": frames.freshFrames, "renderWidth": frames.width, "renderHeight": frames.height,
      "audioTracks": state.audioTracks.count, "subtitleTracks": state.subtitleTracks.count,
      "pause": true, "seekSeconds": 25, "resume": true,
      "videoCodec": state.playbackDiagnostics?.video.codec ?? "unknown", "audioCodec": state.playbackDiagnostics?.audio.codec ?? "unknown"]
    await runtime.release(owner.leaseID, snapshot: .init(seconds: state.position, paused: true, muted: true))
    engine.stop()
    try #require(await wait { await recorder.stopped })
    #expect(await runtime.activeLeaseCount == 0)
    evidence["reports"] = await recorder.reports
    #expect(Set(await recorder.reports.keys) == Set(["Started", "Progress", "Stopped"]))
    #expect(await recorder.reports.values.allSatisfy { (200..<300).contains($0) })
    model.logout()
    try #require(await wait { !model.busy })
    #expect(model.state == .signedOut && !model.hasStoredToken)
    try #require(await recorder.logoutStatus == 204)
    do {
      _ = try await client.sessionUser()
      Issue.record("The demo still accepts the logged-out session")
    } catch MediaServerError.authentication {
      evidence["loggedOutTokenRejected"] = true
    }
    evidence["logout"] = model.state == .signedOut
    evidence["complete"] = true
    try save()
    print("[JELLYFIN_DEMO] realServer=true login=passed details=passed originalRange=passed nativeFrames=\(frames.freshFrames) pause=passed seek=25 resume=passed logout=passed")
  }

  private func wait(_ predicate: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(45)
    while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    return await predicate()
  }

  private func capture<V: View>(_ name: String, output: URL, app: AppState, size: CGSize, @ViewBuilder content: () -> V) async throws {
    _ = NSApplication.shared
    let palette = AppThemeCatalog.palette(for: .auroraViolet)
    let root = content().frame(width: size.width, height: size.height, alignment: .topLeading)
      .themedPresentation().environmentObject(app).environment(\.appThemePalette, palette)
      .preferredColorScheme(palette.preferredColorScheme)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    window.setFrame(.init(origin: .zero, size: size), display: true)
    window.appearance = NSAppearance(named: .darkAqua)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(350))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
  }
}

private actor DemoHTTPRecorder {
  var reports: [String: Int] = [:]
  var logoutStatus: Int?
  var stopped: Bool { reports["Stopped"] != nil }
  func record(_ request: URLRequest, status: Int) {
    let path = request.url?.path ?? ""
    if path.hasSuffix("/Sessions/Playing") { reports["Started"] = status }
    if path.hasSuffix("/Sessions/Playing/Progress") { reports["Progress"] = status }
    if path.hasSuffix("/Sessions/Playing/Stopped") { reports["Stopped"] = status }
    if path.hasSuffix("/Sessions/Logout") { logoutStatus = status }
  }
}
