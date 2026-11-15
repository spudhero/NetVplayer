import AppKit
import Models
import Storage
import SwiftUI
import Testing
import MediaLibraryEngine
import ApplicationCore
import LiveEngine
import Networking
@testable import NetVplayerApp

/// Opt-in before/after layout evidence using production SwiftUI views and synthetic data.
/// This does not authenticate accounts or validate external media playback.
@Suite("November interface native captures", .serialized, .timeLimit(.minutes(2)))
@MainActor struct NovemberInterfaceCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_NOVEMBER_UI_CAPTURE_DIR"] != nil))
    func captureInterfaces() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_NOVEMBER_UI_CAPTURE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("november-ui-" + UUID().uuidString)
        let suite = "netvplayer.november-ui." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: .init(storageDirectory: directory),
            userPreferences: .init(defaults: defaults, credentialStore: MemoryCredentialStore()), providerRuntimeBootstrap: nil)
        let budget = PlaybackBackgroundBudget()
        let previews = LiveChannelPreviewStore(budget: budget, decode: { _ in nil })
        for (theme, suffix) in [(AppAppearanceThemeID.auroraViolet, "dark"), (.greenPeachBlush, "light")] {
            let palette = AppThemeCatalog.palette(for: theme)
            try await capture("cloud-" + suffix, width: 600, height: 460, output: output, palette: palette, state: state) {
                CloudDirectoryEditor()
            }
            for kind in [MediaServerKind.zspace, .fnos] {
                let model = MediaServerAccountModel(); model.kind = kind
                try await capture("server-" + kind.rawValue + "-" + suffix, width: 480, height: 820,
                    output: output, palette: palette, state: state) {
                    ScrollView { MediaServerAccountSettings(model: model, loadOnAppear: false).padding(20) }
                }
            }
            try await capture("dolby-source-" + suffix, width: 320, height: 360, output: output, palette: palette, state: state) {
                PlaybackSystemDolbyVisionSetting(isOn: .constant(true), sourceMetadata: .constant(true), available: true).padding(16)
            }
            try await capture("settings-search-" + suffix, width: 360, height: 150, output: output, palette: palette, state: state) {
                SettingsSearchBar(navigate: { _ in }, availability: { _ in nil }).padding(20)
            }
            try await capture("settings-results-" + suffix, width: 360, height: 460, output: output, palette: palette, state: state) {
                SettingsSearchBar(navigate: { _ in }, availability: { _ in "当前条件暂不可用，仍可定位查看说明。" }).padding(20)
            }
            for width: CGFloat in [280, 480] {
                try await capture("live-" + String(Int(width)) + "-" + suffix, width: width, height: 140,
                    output: output, palette: palette, state: state) {
                    LivePreviewRefreshControls(store: previews, refresh: {}).padding(16)
                }
            }
            for width: CGFloat in [360, 680] {
                for status in [SearchPageCursor.Status.loading, .retryable, .limited] {
                    let name = status == .loading ? "loading" : status == .retryable ? "retryable" : "limited"
                    try await capture("continuation-\(name)-\(Int(width))-\(suffix)", width: width, height: 190,
                        output: output, palette: palette, state: state) {
                        SearchContinuationStatusRow(siteName: "示例来源 · 较长的频道与影视名称", status: status,
                            message: status == .limited ? "已达到本轮追加上限，已有结果仍可查看。" : "此处展示来源返回的完整状态说明，不截断较长的失败原因。",
                            isSearching: false, cancel: {}, retry: {}).padding(16)
                    }
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NovemberEPGProtocol.self]
            let session = URLSession(configuration: configuration)
            state.liveEpgRepository = XMLTVRepository(directory: directory.appendingPathComponent("epg-" + suffix),
                client: HTTPClient(session: session), budget: budget)
            let guideDate = Date(timeIntervalSince1970: 1793667600)
            let channel = Channel(name: "示例频道 · 文化与纪录", number: "1",
                epg: "https://november-epg.invalid/guide.xml", tvgId: "fixture", urls: ["https://fixture.invalid/live"])
            await state.changeLive(.init(name: "离线节目单示例", url: "https://fixture.invalid/list", timeZone: "Asia/Shanghai"),
                initialGroups: [.init(name: "示例分组", channels: [channel])])
            try await capture("epg-loading-" + suffix, width: 800, height: 440,
                output: output, palette: palette, state: state) { EPGGuideView(initialDate: guideDate) }
            let day = Calendar.current.startOfDay(for: guideDate)
            _ = await state.makeLiveEpgLoader().load(channel: channel,
                window: DateInterval(start: day, duration: 86400), forceRefresh: false)
            try await capture("epg-loaded-" + suffix, width: 800, height: 440,
                output: output, palette: palette, state: state) { EPGGuideView(initialDate: guideDate) }
            session.invalidateAndCancel()
            for mode in ["normal", "ambiguous", "failure"] {
                let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [NovemberMetadata(mode: mode)]))
                let vod = Vod(vodId: "synthetic-film", vodName: "远方的旅程", vodContent: "来自原片源的简介，线路与选集仍由原片源提供。", typeName: "电影", siteKey: "synthetic")
                let input = OnlineVodDetailInput(vod: vod, sourceFingerprint: "synthetic", siteKey: "synthetic")
                let layout = VodDetailLayoutPolicy.layout(in: .init(width: 960, height: 900))
                try await capture("online-" + mode + "-" + suffix, width: 320, height: 740,
                    output: output, palette: palette, state: state) {
                    OnlineVodInformationPane(model: model, vod: vod, input: input, layout: layout) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(vod.vodName).font(.title2.bold())
                            Text(vod.vodContent).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                model.suspend()
            }
        }
        previews.cancelRefresh(); await previews.drain()
        try await state.prepareForApplicationTermination()
    }
    private func capture<Content: View>(_ name: String, width: CGFloat, height: CGFloat,
        output: URL, palette: AppThemePalette, state: AppState, @ViewBuilder content: () -> Content) async throws {
        // AppKit's native controls also consult the test process appearance.
        // Scope it to this capture so earlier suites cannot leak light controls
        // into a dark SwiftUI hosting window (and restore it afterwards).
        let previousAppearance = NSApplication.shared.appearance
        let appearance = NSAppearance(named: palette.preferredColorScheme == .dark ? .darkAqua : .aqua)
        NSApplication.shared.appearance = appearance
        defer { NSApplication.shared.appearance = previousAppearance }
        let root = content().themedPresentation().environmentObject(state).environment(\.appThemePalette, palette)
            .preferredColorScheme(palette.preferredColorScheme).foregroundStyle(palette.foreground).tint(palette.accent)
            .frame(width: width, height: height, alignment: .topLeading).background(palette.background)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = appearance
        host.appearance = appearance
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        if name.hasPrefix("settings-results-") {
            window.makeKeyAndOrderFront(nil)
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            let field = try #require(fields(host).first)
            window.makeFirstResponder(field)
            field.selectText(nil)
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.insertText("HDR", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(200))
        }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bytes.count > 2000)
        try bytes.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        if name.hasPrefix("sftp-"), let scroll = scrollViews(host).first, let document = scroll.documentView {
            scroll.contentView.scroll(to: .init(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            let lower = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: lower)
            try #require(lower.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + "-lower.png"), options: .atomic)
        }
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}

private final class NovemberEPGProtocol: URLProtocol, @unchecked Sendable {
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "november-epg.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = self.request.url else { return }
            let programmes = (0..<23).map { hour in
                "<programme start=\"20261103\(String(format: "%02d", hour))0000 +0800\" stop=\"20261103\(String(format: "%02d", hour + 1))0000 +0800\" channel=\"fixture\"><title>示例纪录片 · 第 \(hour + 1) 集</title></programme>"
            }.joined()
            let data = Data(("<tv><channel id=\"fixture\"><display-name>示例频道</display-name></channel>" + programmes + "</tv>").utf8)
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/xml"])!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    override func stopLoading() { pending?.cancel() }
}

private struct NovemberMetadata: MetadataProvider {
    let mode: String
    let source = MetadataSource.tmdb
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        if mode == "failure" { throw URLError(.timedOut) }
        if kind == .television { return [] }
        let first = MetadataCandidate(source: .tmdb, metadata: .init(title: title, year: 2024, kind: kind, tmdbID: "12"))
        return mode == "ambiguous" ? [first, .init(source: .tmdb, metadata: .init(title: title, year: 1994, kind: kind, tmdbID: "13"))] : [first]
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        .init(title: "远方的旅程", originalTitle: "A Journey Beyond", year: 2024, kind: kind,
              plot: "一段穿越山海的旅程，让平凡生活中的相遇成为新的开始。",
              tmdbID: id, tmdbRating: 8.5, genres: ["剧情", "冒险"], detailVersion: 2)
    }
}
