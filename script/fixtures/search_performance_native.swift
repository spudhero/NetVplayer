import AppKit
import SwiftUI
import Combine
import Vision
import ObjectiveC
import Foundation
import Storage
import Models
@testable import SearchEngine
@testable import NetVplayerApp

// Every session created inside this isolated host receives the fixture protocol.
private final class FixtureHTTP: URLProtocol, @unchecked Sendable {
    static let traffic = Traffic()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.traffic.record(request.url?.host ?? "unknown")
        let data = Data(#"{"data":[{"title":"Synthetic fixture"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class Traffic: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String: Int] = [:]
    func record(_ host: String) { lock.lock(); defer { lock.unlock() }; hosts[host, default: 0] += 1 }
    func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return hosts }
}

private actor Calls {
    var keys: [String] = []
    func add(_ key: String) { keys.append(key) }
}

@main private struct Main {
    @MainActor static func main() {
        try? Data("main entered\n".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("stages.log"))
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
    var labels: [[String: Any]] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        stage("applicationDidFinishLaunching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [self] in finish("failed", error: "watchdog expired") }
        Task { @MainActor in
            do {
                for sorted in [false, true] { try await exercise(sorted: sorted) }
                finish("passed")
            } catch { finish("failed", error: String(describing: error)) }
        }
    }

    private func exercise(sorted: Bool) async throws {
        stage("exercise sorted=\(sorted)")
        let suite = "search-performance-native-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = StorageManager(storageDirectory: output.appendingPathComponent(sorted ? "sorted-storage" : "baseline-storage"))
        let store = SearchPerformanceStore(storage: storage)
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        preferences.siteHealthSortingEnabled = sorted
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: storage, userPreferences: preferences, providerRuntimeBootstrap: nil)
        state.sites = (0..<12).map { Site(key: "s\($0)", name: "Fixture \($0)", type: 1, api: "https://fixture.invalid/\($0)") }
        stage("state initialized")
        let calls = Calls()
        state.searchEngine = SearchEngine(performanceStore: store) { site, _, _, _ in
            await calls.add(site.key)
            let slow = Int(site.key.dropFirst())! < 6
            try await Task.sleep(for: .milliseconds(slow ? 250 : 25))
            return Result(list: slow ? [] : (1...12).map {
                Vod(vodId: "\(site.key)-\($0)", vodName: String(format: "Film fixture %02d", $0), siteKey: site.key)
            }, page: 1, pagecount: 1)
        }
        for (index, site) in state.sites.enumerated() {
            let identity = SearchPerformanceIdentity.fingerprint(site: site, configuration: state.libraryConfigurationURL)
            for _ in 0..<8 {
                store.record(store.beginAttempt(identity: identity), success: true, durationMs: index < 6 ? 250 : 25)
            }
        }
        state.searchKeyword = "Film"
        let host = NSHostingView(rootView: SearchView().environmentObject(state))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 180, width: 1200, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "OV91-06 isolated SearchView · \(sorted ? "sorted" : "baseline")"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        stage("window shown")
        NSApp.activate(ignoringOtherApps: true)
        defer { state.resetSearchState(); store.flushPendingWrites(); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        var firstUseful: Double?, allSourcesTime: Double?
        let observer = state.$contentSearchState.sink { snapshot in
            if firstUseful == nil && snapshot.results.contains(where: { !$0.vods.isEmpty }) {
                firstUseful = self.ms(start.duration(to: .now))
            }
            if !snapshot.isLoading, snapshot.cursors.count == 12 { allSourcesTime = self.ms(start.duration(to: .now)) }
        }
        defer { observer.cancel() }
        let search = Task { await state.search(keyword: "Film") }
        stage("search started")
        let deadline = start.advanced(by: .seconds(10))
        var screenTime: Double?
        while .now < deadline {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds), let png = capture(host, bitmap: bitmap) {
                let renderedAt = ms(start.duration(to: .now))
                let rows = try await Task.detached { try Self.recognizedRows(png) }.value
                labels = rows.map { ["label": $0.text, "normalizedFrame": $0.frame] }
                if rows.count >= 4 {
                    screenTime = renderedAt
                    try png.write(to: output.appendingPathComponent(sorted ? "sorted-first-screen.png" : "baseline-first-screen.png"))
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await search.value
        stage("search finished labels=\(labels.count)")
        guard let firstUseful, let screenTime else { throw failure("visible SearchView rows did not complete") }
        let keys = await calls.keys
        guard Set(keys).count == 12 else { throw failure("source coverage lost") }
        let allSources = allSourcesTime ?? ms(start.duration(to: .now))
        records.append(["sorted": sorted, "firstUsefulMs": firstUseful, "completeVisibleFirstScreenMs": screenTime,
                        "allSourcesMs": allSources, "coverage": Set(keys).count, "siteOrder": state.contentSearchState.siteOrder,
                        "windowPoints": [1200, 700], "firstScreenRows": labels, "providerDelaysMs": [250, 25],
                        "sample": "synthetic providers, empty poster placeholders; real production SearchView"])
    }

    private struct VisibleRow: Sendable { let text: String; let frame: [Double] }
    private nonisolated static func recognizedRows(_ png: Data) throws -> [VisibleRow] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(data: png).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string,
                  text.lowercased().contains("film fixture") else { return nil }
            let rect = observation.boundingBox
            guard rect.minY > 0.08 else { return nil } // Exclude the partially clipped fifth row.
            return VisibleRow(text: text, frame: [rect.minX, rect.minY, rect.width, rect.height])
        }
    }

    private func capture(_ host: NSView, bitmap: NSBitmapImageRep) -> Data? {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    private func failure(_ text: String) -> Error { NSError(domain: "SearchPerformanceProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func stage(_ text: String) {
        if let handle = try? FileHandle(forWritingTo: output.appendingPathComponent("stages.log")) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((text + "\n").utf8))
            try? handle.close()
        }
    }
    private func finish(_ status: String, error: String = "") {
        let record: [String: Any] = ["status": status, "error": error, "runs": records, "lastLabels": labels,
            "isolatedStorageDefaultsAndMemoryCredentials": true, "httpSessionsUseFixtureProtocol": true,
            "interceptedHTTPHosts": FixtureHTTP.traffic.snapshot(), "realServiceVerified": false]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-validation.json"))
        NSApp.terminate(nil)
    }
}

private extension URLSessionConfiguration {
    @objc class func ov91_fixtureDefault() -> URLSessionConfiguration {
        let config = ov91_fixtureDefault()
        config.protocolClasses = [FixtureHTTP.self]
        config.connectionProxyDictionary = [:]
        return config
    }
    @objc class func ov91_fixtureEphemeral() -> URLSessionConfiguration {
        let config = ov91_fixtureEphemeral()
        config.protocolClasses = [FixtureHTTP.self]
        config.connectionProxyDictionary = [:]
        return config
    }
}

@MainActor private func installFixtureHTTP() {
    for (original, replacement) in [("defaultSessionConfiguration", "ov91_fixtureDefault"),
                                     ("ephemeralSessionConfiguration", "ov91_fixtureEphemeral")] {
        guard let a = class_getClassMethod(URLSessionConfiguration.self, NSSelectorFromString(original)),
              let b = class_getClassMethod(URLSessionConfiguration.self, NSSelectorFromString(replacement)) else {
            fatalError("fixture configuration factory missing")
        }
        method_exchangeImplementations(a, b)
    }
}
