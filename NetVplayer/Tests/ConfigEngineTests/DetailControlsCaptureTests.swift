import AppKit
import MediaLibraryEngine
import Models
import Storage
import SwiftUI
import Testing
@testable import NetVplayerApp

/// Opt-in renderings of production controls with in-memory accounts and no source traffic.
@Suite(.serialized) @MainActor
struct DetailControlsCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_DETAIL_CONTROLS_CAPTURE_DIR"] != nil))
    func originalAndOptionalMetadata() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_DETAIL_CONTROLS_CAPTURE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for theme in [AppAppearanceThemeID.auroraViolet, .greenPeachBlush] {
            for width in [960, 1280] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let suite = "netvplayer.detail-controls." + UUID().uuidString
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
                let provider = DetailControlMetadata()
                let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
                let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
                let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
                    storageManager: StorageManager(storageDirectory: directory), userPreferences: preferences,
                    onlineDetailMetadata: model, providerRuntimeBootstrap: nil)
                let site = Site(key: "offline-detail", name: "离线示例", type: 3, api: "csp_OfflineDetail")
                state.sites = [site]; state.activeSite = site
                state.libraryConfigurationURL = "https://fixture.invalid/config"
                let vod = Vod(vodId: "offline-film", vodName: "远方的旅程", vodYear: "2024",
                    vodContent: "这是原片源简介。打开详情时直接展示，TMDB 资料由用户按需选择。",
                    typeName: "电影", vodPlayFrom: "原片源线路",
                    vodPlayUrl: "第1集$https://fixture.invalid/1#第2集$https://fixture.invalid/2#第3集$https://fixture.invalid/3", siteKey: site.key)
                state.detailVod = vod; state.applyPlaybackAvailability(for: vod); state.isDetailPresented = true
                let palette = AppThemeCatalog.palette(for: theme)
                let size = CGSize(width: width, height: 740)
                let root = VodDetailView(vod: vod, layout: VodDetailLayoutPolicy.layout(in: size))
                    .environmentObject(state).environment(\.appThemePalette, palette)
                    .frame(width: size.width, height: size.height)
                    .background(AppThemeRootBackground(palette: palette, forceOpaque: false))
                    .preferredColorScheme(palette.preferredColorScheme)
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                window.appearance = NSAppearance(named: palette.preferredColorScheme == .dark ? .darkAqua : .aqua)
                host.appearance = window.appearance
                defer { window.close() }
                let prefix = "\(theme.rawValue)-\(width)"
                try await capture(host, to: output.appendingPathComponent(prefix + "-original-grid.png"))
                #expect(!model.wantsEnhanced && !model.isLoading)
                #expect(await provider.searchCalls == 0)
                state.episodeDisplayMode = .list; state.episodeSortOrder = .descending
                try await capture(host, to: output.appendingPathComponent(prefix + "-original-list.png"))
                model.showEnhanced()
                try await capture(host, to: output.appendingPathComponent(prefix + "-tmdb-loading.png"))
                #expect(model.wantsEnhanced && model.isLoading)
                await provider.fail()
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while model.issue == nil {
                    try #require(ContinuousClock.now < deadline)
                    try await Task.sleep(for: .milliseconds(10))
                }
                try await capture(host, to: output.appendingPathComponent(prefix + "-tmdb-failure.png"))
                #expect(state.episodes.count == 3 && state.selectedPlayFlag == "原片源线路")
                model.suspend(); try await state.prepareForApplicationTermination()
            }
        }
    }

    private func capture<V: View>(_ host: NSHostingView<V>, to url: URL) async throws {
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded(); host.window?.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

private actor DetailControlMetadata: MetadataProvider {
    nonisolated let source = MetadataSource.tmdb
    var searchCalls = 0
    private var pending: CheckedContinuation<[MetadataCandidate], Error>?
    private var failureRequested = false
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        searchCalls += 1
        return try await withCheckedThrowingContinuation { continuation in
            if failureRequested { continuation.resume(throwing: URLError(.timedOut)) }
            else { pending = continuation }
        }
    }
    func fail() {
        failureRequested = true
        pending?.resume(throwing: URLError(.timedOut)); pending = nil
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        throw URLError(.timedOut)
    }
}
