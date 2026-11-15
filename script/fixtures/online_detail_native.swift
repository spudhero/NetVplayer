import AppKit
import SwiftUI
import Combine
import Foundation
import Models
import MediaLibraryEngine
import Storage
import ObjectiveC
@testable import NetVplayerApp

// No real-service traffic in the diagnostic host.
private final class FixtureHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main private struct Main {
    @MainActor static func main() {
        installFixtureHTTP()
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        _ = delegate
    }
}
@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    var records: [[String: Any]] = []
    var clickInset: CGFloat = 16
    var clickPaneWidth: CGFloat = 320
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 100) { self.finish("failed", error: "watchdog expired") }
        Task { @MainActor in
            do { try await exercise(); finish("passed") }
            catch { finish("failed", error: String(describing: error)) }
        }
    }
    private func exercise() async throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard home.path.hasPrefix(output.path), TestRuntime.isRunning else { throw failure("isolation missing") }
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        let provider = FixtureMetadata()
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: home.appendingPathComponent("state")),
            userPreferences: UserPreferences.shared, onlineDetailMetadata: model, providerRuntimeBootstrap: nil)
        let site = Site(key: "fixture", name: "离线片源", type: 3, api: "csp_OfflineDetail")
        state.sites = [site]; state.activeSite = site; state.libraryConfigurationURL = "https://example.test/config"
        var vod = Vod(vodId: "source-film", vodName: "测试影片", vodYear: "2024", vodContent: "这是原片源简介，播放线路和选集始终属于原片源。",
            vodActor: "原片源演员", typeName: "电影", vodPlayFrom: "原片源线路", vodPlayUrl: "第1集$https://example.test/one.mp4#第2集$https://example.test/two.mp4", siteKey: site.key)
        state.detailVod = vod; state.applyPlaybackAvailability(for: vod); state.isDetailPresented = true
        let initialEpisodes = state.episodes.map(\.url)
        let initialFlag = state.selectedPlayFlag
        for width in [960, 1440] {
            let layout = VodDetailLayoutPolicy.layout(in: CGSize(width: width, height: 900))
            clickInset = layout.contentInset
            clickPaneWidth = layout.informationPaneWidth
            let host = NSHostingView(rootView: VodDetailView(vod: vod, layout: layout).environmentObject(state))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: layout.containerSize),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await pause(600)
            if width == 960 {
                guard !model.wantsEnhanced, model.displayedMetadata == nil,
                      await provider.searchCalls == 0 else { throw failure("default original started metadata request") }
                try save(host, name: "default-original-\(width)")
                try press(host, identifier: "online-detail-tmdb")
                try await waitUntil { model.metadata?.detailVersion == 2 }
            } else {
                try press(host, identifier: "online-detail-tmdb")
                try await waitUntil { model.metadata?.detailVersion == 2 }
            }
            guard model.metadata?.detailVersion == 2 else { throw failure("TMDB metadata not displayed after selection") }
            try save(host, name: "enhanced-\(width)")
            try press(host, identifier: "online-detail-original")
            guard model.displayedMetadata == nil else { throw failure("original action was not synchronous") }
            try await pause(180)
            try save(host, name: "original-\(width)")
            vod.vodActor = "异步补全演员"; vod.vodContent = "这是异步补全后的原片源简介。"
            state.detailVod = vod
            try await pause(120)
            guard model.binding?.metadata.tmdbID == "12", !model.wantsEnhanced else { throw failure("source completion reset binding or selection") }
            try press(host, identifier: "online-detail-tmdb")
            guard model.displayedMetadata?.tmdbID == "12" else { throw failure("enhanced switch failed") }
            guard state.episodes.map(\.url) == initialEpisodes, state.selectedPlayFlag == initialFlag,
                  state.detailVod?.vodId == "source-film" else { throw failure("metadata mutated playback identity") }
            records.append(["width": width, "nativeButtonsPressed": 3, "originalDefaultVerified": width == 960, "immediateOriginal": true,
                "completionPreservedBinding": true, "sourceIdentityAndEpisodesUnchanged": true])
            if width == 1440 {
                await provider.setMode("ambiguous")
                model.search(title: "同名作品")
                try await pause(250)
                guard model.binding == nil, model.candidates.count == 2 else { throw failure("ambiguity auto-bound") }
                try save(host, name: "ambiguous")
                model.confirm(model.candidates[1])
                try await pause(180)
                guard model.metadata?.tmdbID == "13" else { throw failure("manual confirmation failed") }
                await provider.setMode("failure")
                model.retry(); try await waitUntil { model.issue != nil }
                guard model.issue != nil, model.binding?.metadata.tmdbID == "13" else { throw failure("failed refresh: binding=\(String(describing: model.binding?.metadata.tmdbID)), issue=\(String(describing: model.issue)), loading=\(model.isLoading)") }
                try save(host, name: "failure-keeps-metadata")
                try press(host, identifier: "online-detail-original")
                try await pause(120)
                try save(host, name: "failure-original-playable")
            }
            window.orderOut(nil); window.close(); model.suspend()
        }
    }
    private func press(_ host: NSView, identifier: String) throws {
        guard let window = host.window else { throw failure("window unavailable") }
        // Click the centres of the two equal-width controls using the same
        // layout policy as the captured production detail pane.
        let buttonWidth = (clickPaneWidth - 2 * clickInset - 10) / 2
        let x = clickInset + buttonWidth / 2 + (identifier == "online-detail-original" ? 0 : buttonWidth + 10)
        let y = clickInset + 16
        let point = host.convert(NSPoint(x: x,
            y: host.isFlipped ? y : host.bounds.height - y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw failure("mouse event unavailable")
            }
            window.sendEvent(event)
        }
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard .now < deadline else { throw failure("timed out waiting for metadata state") }
            try await pause(20)
        }
    }
    private func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
    private func save(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("bitmap unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    private func failure(_ text: String) -> Error { NSError(domain: "OnlineDetailProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func finish(_ status: String, error: String = "") {
        let record: [String: Any] = ["status": status, "error": error, "scenarios": records,
            "isolatedHome": NSHomeDirectory(), "memoryCredentials": TestRuntime.isRunning,
            "httpSessionsUseFixtureProtocol": true, "realServiceVerified": false]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-validation.json"))
        NSApp.terminate(nil)
    }
}
private actor FixtureMetadata: MetadataProvider {
    nonisolated let source = MetadataSource.tmdb
    var mode = "normal"
    var searchCalls = 0
    func setMode(_ value: String) { mode = value }
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        searchCalls += 1
        let ids = mode == "ambiguous" ? ["12", "13"] : ["12"]
        return ids.map { .init(source: .tmdb, metadata: .init(title: title, year: 2024, kind: kind, tmdbID: $0)) }
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        if mode == "failure" { throw URLError(.timedOut) }
        return .init(title: "测试影片 · TMDB", originalTitle: "Offline Metadata Fixture", year: 2024, kind: kind,
            plot: "这是一份隔离的资料展示样本，用于验证原详情切换、候选确认与补全后的身份保持。演员作品链接只打开 TMDB 人物页，原片源选集仍在右侧。",
            tmdbID: id, tmdbRating: 8.5, genres: ["剧情", "冒险"], directors: ["测试导演"],
            cast: [.init(name: "测试演员", role: "主演", tmdbID: "42")], detailVersion: 2)
    }
}
private extension URLSessionConfiguration {
    @objc class func ov91_onlineDefault() -> URLSessionConfiguration {
        let config = ov91_onlineDefault(); config.protocolClasses = [FixtureHTTP.self]; return config
    }
    @objc class func ov91_onlineEphemeral() -> URLSessionConfiguration {
        let config = ov91_onlineEphemeral(); config.protocolClasses = [FixtureHTTP.self]; return config
    }
}
@MainActor private func installFixtureHTTP() {
    for (original, replacement) in [("defaultSessionConfiguration", "ov91_onlineDefault"),
                                     ("ephemeralSessionConfiguration", "ov91_onlineEphemeral")] {
        let a = class_getClassMethod(URLSessionConfiguration.self, NSSelectorFromString(original))!
        let b = class_getClassMethod(URLSessionConfiguration.self, NSSelectorFromString(replacement))!
        method_exchangeImplementations(a, b)
    }
}
