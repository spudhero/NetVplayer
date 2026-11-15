import AppKit
import FileServiceEngine
import MediaLibraryEngine
import Models
import Networking
import PlayerEngine
import ProxyServer
import SpiderEngine
import Storage
import SwiftUI
import Testing
@testable import NetVplayerApp

/// Opt-in acceptance with isolated credentials, real Quark wire parsing, local HTTP ranges,
/// the persistent media library, and the native decoder. This is not real-drive acceptance.
@Suite("Cloud directory synthetic native acceptance", .serialized) @MainActor
struct CloudDirectoryCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_CLOUD_CAPTURE_DIR"] != nil))
    func foldersPostersDetailsAndPlayback() async throws {
        let env = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: try #require(env["NETVPLAYER_CLOUD_CAPTURE_DIR"]))
        let media = URL(fileURLWithPath: try #require(env["NETVPLAYER_CLOUD_CAPTURE_MEDIA"]))
        let mediaSize = try media.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        CloudCaptureProtocol.mediaURL = try #require(env["NETVPLAYER_CLOUD_CAPTURE_URL"])
        CloudCaptureProtocol.mediaSize = mediaSize
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-ui-" + UUID().uuidString)
        let domain = "cloud-ui-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        try preferences.saveCredential("__uid=synthetic-only; __pus=fixture", for: "quarkCookie")
        let storage = StorageManager(storageDirectory: directory)
        let store = FileServiceStore(storage: storage, preferences: preferences)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CloudCaptureProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration)).withExplicitProxy(nil)
        let runtime = FileServiceRuntime(store: store, cloudPreferences: preferences, cloudHTTPClient: http)
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let scanner = MediaLibraryScanner(index: index, store: store, runtime: runtime)
        let state = FileServicesState(index: index, store: store, runtime: runtime, scanner: scanner, cloudPreferences: preferences)
        let service = try await state.connectCloudDirectory(.quark)
        let library = MediaLibraryConfiguration(serviceID: service.id, name: "网盘样片 · 模拟验收", path: "/电影", metadataSource: .local)
        let app = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: storage, userPreferences: preferences, providerRuntimeBootstrap: nil)
        app.activeSite = service.site(); app.sites = [service.site()]; app.isConfigLoaded = true
        app.currentSiteName = service.name
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        try ProxyServer.shared.start()
        defer { ProxyServer.shared.stop() }
        try await capture("account", app: app, output: output) { CloudDirectoryEditor(state: state) }
        try await capture("folders", app: app, output: output) { MediaLibraryBatchEditor(state: state, service: service) }
        try await state.addLibraries([library], to: service.id)
        try #require(await wait { (try? await index.lastSuccessfulScan(libraryID: library.id)) != nil })
        var record = try #require(try await index.records(libraryID: library.id).first)
        let art = env["NETVPLAYER_CLOUD_CAPTURE_POSTER"].map { URL(fileURLWithPath: $0).absoluteString }
        try await index.applyCorrection(.init(reference: record.reference, fields: .init(title: "云端样片", year: 2026,
            plot: "隔离模拟网盘协议，验证个人目录、持久媒体库、详情和原始文件播放。", poster: art, fanart: art)))
        record = try #require(try await index.record(reference: record.reference))
        state.selectService(service.id); await state.waitForMediaLoad()
        #expect(state.mediaRecords.count == 1)
        try await capture("posters", app: app, output: output) { MediaLibraryWallView(state: state, service: service).padding(24) }
        let provider = FileServiceNativeProvider(serviceID: service.id, runtime: runtime, index: index)
        let vod = try #require(try await provider.detailContent(site: service.site(), id: record.reference.locator).vod)
        app.detailVod = vod; app.applyPlaybackAvailability(for: vod)
        try await capture("detail", app: app, output: output) {
            NASMediaDetailContent(vod: vod, size: .init(width: 1280, height: 820), metadata: record.metadata,
                files: [record], serviceName: service.name, libraryName: library.name)
        }
        let result = try await provider.playerContent(site: service.site(), flag: "文件", id: record.reference.locator)
        #expect(result.url.contains("127.0.0.1"))
        let lease = try #require(result.fileResourceLeaseID.flatMap(UUID.init(uuidString:)))
        let spec = PlaySpec(url: result.url, title: "个人网盘目录 · 模拟服务样片")
        let host = NSHostingView(rootView: PlayerView(playerState: app.playerState, windowContext: PlayerWindowContext())
            .environmentObject(app).environment(\.appThemePalette, AppThemeCatalog.palette(for: .auroraViolet))
            .frame(width: 1280, height: 720))
        let window = NSWindow(contentRect: .init(x: 30, y: 50, width: 1280, height: 720),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await app.play(spec: spec); _ = MPVPlayerEngine.vod.setMuted(true)
        try #require(await wait { app.playerState.errorMessage != nil || app.playerState.position > 1 })
        try #require(app.playerState.errorMessage == nil)
        #expect(!app.playerState.audioTracks.isEmpty)
        MPVPlayerEngine.vod.seek(to: 20_000)
        try #require(await wait { !app.playerState.isSeeking && app.playerState.position >= 20 && app.playerState.position < 24 })
        MPVPlayerEngine.vod.pause()
        try #require(await wait { !app.playerState.isPlaying })
        try await Task.sleep(for: .milliseconds(400))
        try snapshot(host, to: output.appendingPathComponent("playback-view.png"))
        let preview = try #require(await PlayerChapterThumbnailDecoder.shared.imageData(spec: spec, seconds: 20))
        try preview.write(to: output.appendingPathComponent("decoded-preview.png"))
        let evidence: [String: Any] = ["synthetic": true, "provider": "quark", "mediaRecords": state.mediaRecords.count,
            "position": app.playerState.position, "duration": app.playerState.duration, "seekPassed": true,
            "audioTracks": app.playerState.audioTracks.count, "rangeProxy": true,
            "uiScreenshotIncludesVideo": false, "previewDecodedSeparately": true]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native.json"))
        try await app.prepareForApplicationTermination()
        await runtime.releasePlayback(leaseID: lease)
        await runtime.invalidate(serviceID: service.id)
    }
    private func wait(_ predicate: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        return await predicate()
    }
    private func capture<V: View>(_ name: String, app: AppState, output: URL, @ViewBuilder content: () -> V) async throws {
        let host = NSHostingView(rootView: content().frame(width: 1280, height: 820).themedPresentation()
            .environmentObject(app).environment(\.appThemePalette, AppThemeCatalog.palette(for: .auroraViolet)).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(700))
        try snapshot(host, to: output.appendingPathComponent(name + ".png"))
    }
    private func snapshot(_ host: NSView, to url: URL) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

private final class CloudCaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var mediaURL = ""
    nonisolated(unsafe) static var mediaSize = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let object: [String: Any]
        switch url.path {
        case "/1/clouddrive/file/sort":
            let parent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pdir_fid" }?.value
            let items: [[String: Any]] = parent == "0"
                ? [["fid": "movies", "file_name": "电影", "dir": true, "file_type": 0]]
                : [["fid": "movie", "file_name": "云端样片 (2026).mp4", "size": Self.mediaSize, "dir": false, "file": true, "file_type": 1]]
            object = ["code": 0, "status": 200, "data": ["list": items], "metadata": ["_total": items.count]]
        case "/1/clouddrive/file/download":
            object = ["code": 0, "status": 200, "data": [["fid": "movie", "download_url": Self.mediaURL]]]
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
}
