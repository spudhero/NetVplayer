import AppKit
import MediaServerEngine
import Models
import PlayerEngine
import ProxyServer
import SpiderEngine
import Storage
import SwiftUI
import Testing
@testable import NetVplayerApp

/// Opt-in UI / native-decoder acceptance against the loopback wire fixtures.
/// These screenshots are synthetic service evidence, never vendor-server evidence.
@Suite("NAS synthetic native UI acceptance", .serialized) @MainActor
struct NASMediaCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_NAS_CAPTURE_DIR"] != nil))
    func postersDetailsAndNativePlayback() async throws {
        let env = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: try #require(env["NETVPLAYER_NAS_CAPTURE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        try ProxyServer.shared.start()
        defer { ProxyServer.shared.stop() }
        for kind in [MediaServerKind.fnos, .zspace] {
            let endpoint = try #require(env["NETVPLAYER_NAS_CAPTURE_" + kind.rawValue.uppercased()])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nas-ui-" + UUID().uuidString)
            let domain = "nas-ui-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
            let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
            let storage = StorageManager(storageDirectory: directory)
            let store = MediaServerStore(storage: storage, preferences: preferences)
            let login = try MediaServerClient(account: .init(name: kind.title + "模拟服务", kind: kind, server: endpoint, allowsHTTP: true))
            let (account, token) = try await login.authenticate(username: "fixture", password: "fixture-password")
            try store.save([account]); try store.saveToken(token, for: account)
            let runtime = MediaServerRuntime(store: store)
            let client = try await runtime.client(for: account.id)
            let provider = MediaServerNativeProvider(accountID: account.id, runtime: runtime)
            let app = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
                storageManager: storage, userPreferences: preferences, providerRuntimeBootstrap: nil)
            let palette = AppThemeCatalog.palette(for: .auroraViolet)
            app.activeSite = account.site(); app.sites = [account.site()]; app.isConfigLoaded = true
            app.currentSiteName = account.name
            app.categories = try await provider.homeContent(site: account.site()).types
            app.selectedCategory = app.categories.first
            let listing = try await provider.categoryContent(site: account.site(), tid: "library", page: "1", filter: false, extend: [:])
            // Fetch artwork through the real client before rendering isolated views.
            // The fixture account does not enter the user's global artwork credential store.
            var vods = listing.list
            for index in vods.indices {
                if let reference = MediaServerArtworkReference(locator: vods[index].vodPic) {
                    let bytes = try await client.artwork(reference)
                    let local = output.appendingPathComponent(kind.rawValue + "-art-\(index).jpg")
                    try bytes.write(to: local)
                    vods[index].vodPic = local.absoluteString
                }
            }
            app.vods = vods
            try await capture("\(kind.rawValue)-posters", app: app, palette: palette, output: output) { VodHomeView() }
            let reference = try MediaServerReference(accountID: account.id, itemID: "film1")
            var vod = try #require(try await provider.detailContent(site: account.site(), id: reference.locator).vod)
            vod.vodPic = vods[0].vodPic
            vod.mediaServerDetail?.metadata.poster = vods[0].vodPic
            vod.mediaServerDetail?.metadata.fanart = vods[0].vodPic
            app.detailVod = vod; app.applyPlaybackAvailability(for: vod)
            try await capture("\(kind.rawValue)-detail", app: app, palette: palette, output: output) {
                MediaServerDetailView(vod: vod, size: .init(width: 1280, height: 820))
            }
            let model = MediaServerAccountModel(store: store)
            model.load()
            let deadline = ContinuousClock.now + .seconds(5)
            while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.state == .signedIn)
            try await capture("\(kind.rawValue)-account", app: app, palette: palette, output: output) {
                MediaServerAccountSettings(model: model, loadOnAppear: false).padding(24)
            }
            let result = try await runtime.resolve(reference)
            let owner = try #require(result.mediaServer)
            var spec = PlaySpec(url: result.url, subs: result.subs, title: kind.title + "模拟服务 · 原始样片")
            spec.mediaServer = owner; spec.initialStartPositionSeconds = owner.resumeSeconds
            let root = PlayerView(playerState: app.playerState, windowContext: PlayerWindowContext())
                .environmentObject(app).environment(\.appThemePalette, palette).frame(width: 1280, height: 720)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 30, y: 50, width: 1280, height: 720),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = kind.title + "模拟服务 · NetVplayer 原生播放验收"
            window.isReleasedWhenClosed = false; window.contentView = host
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            await app.play(spec: spec)
            _ = MPVPlayerEngine.vod.setMuted(true)
            try #require(await wait { app.playerState.errorMessage != nil || (!app.playerState.isMediaLoading && app.playerState.position > owner.resumeSeconds + 0.5) })
            try #require(app.playerState.errorMessage == nil, "\(app.playerState.errorMessage ?? "")")
            #expect(!app.playerState.audioTracks.isEmpty)
            await runtime.report(owner.leaseID, snapshot: .init(seconds: app.playerState.position, audioIndex: 1), started: true)
            MPVPlayerEngine.vod.seek(to: 24_000)
            try #require(await wait { !app.playerState.isSeeking && app.playerState.position >= 24 && app.playerState.position < 27 })
            MPVPlayerEngine.vod.pause()
            try #require(await wait { !app.playerState.isPlaying })
            try await Task.sleep(for: .milliseconds(500))
            try snapshot(host, to: output.appendingPathComponent(kind.rawValue + "-playback-view.png"))
            // cacheDisplay cannot include the GPU video layer. Save a separately
            // decoded chapter-preview frame, never composite it into the UI image.
            let preview = try #require(await PlayerChapterThumbnailDecoder.shared.imageData(spec: spec, seconds: 24))
            try preview.write(to: output.appendingPathComponent(kind.rawValue + "-decoded-preview.png"))
            let state: [String: Any] = ["synthetic": true, "kind": kind.rawValue, "position": app.playerState.position,
                "duration": app.playerState.duration, "audioTracks": app.playerState.audioTracks.count,
                "subtitleTracks": app.playerState.subtitleTracks.count, "rangeProxy": result.url.contains("127.0.0.1"), "seekPassed": true,
                "uiScreenshotIncludesVideo": false, "previewDecodedSeparately": true]
            try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(kind.rawValue + "-native.json"))
            if env["NETVPLAYER_NAS_CAPTURE_WAIT"] == "1" {
                let ready = output.appendingPathComponent(kind.rawValue + "-ready")
                try Data().write(to: ready)
                let go = output.appendingPathComponent(kind.rawValue + "-continue")
                let until = ContinuousClock.now + .seconds(90)
                while !FileManager.default.fileExists(atPath: go.path), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(100)) }
            }
            await runtime.release(owner.leaseID, snapshot: .init(seconds: app.playerState.position, paused: true, audioIndex: 1))
            try await app.prepareForApplicationTermination()
            window.close()
        }
    }
    private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        return predicate()
    }
    private func capture<V: View>(_ name: String, app: AppState, palette: AppThemePalette, output: URL, @ViewBuilder content: () -> V) async throws {
        let host = NSHostingView(rootView: content().frame(width: 1280, height: 820).themedPresentation()
            .environmentObject(app).environment(\.appThemePalette, palette).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(800))
        try snapshot(host, to: output.appendingPathComponent(name + ".png"))
    }
    private func snapshot(_ host: NSView, to url: URL) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
