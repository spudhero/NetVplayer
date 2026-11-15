import AppKit
import SwiftUI
import Models
import PlayerEngine
@testable import NetVplayerApp

@main private struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = Delegate()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); _ = delegate
    }
}
@MainActor private final class Input: ObservableObject {
    @Published var failed = false
    var calls: [String] = []
    var store: LiveChannelPreviewStore!
    let channels = (1...30).map { Channel(name: "示例频道 \($0)", number: "\($0)", urls: ["https://fixture.invalid/\($0)"]) }
    init() {
        store = LiveChannelPreviewStore { [weak self] spec in
            guard let self else { return nil }
            self.calls.append(spec.title)
            if self.failed { return nil }
            return await PlayerChapterThumbnailDecoder.shared.liveImageData(spec: spec)
        }
        store.setSource("isolated-native-fixture")
    }
    func refresh() {
        store.refresh { channel in
            PlaySpec(url: "file:///private/tmp/netvplayer-ov91-long-gop-120.mp4", title: channel.name)
        }
    }
}
private struct Harness: View {
    @ObservedObject var input: Input
    var body: some View {
        VStack(spacing: 8) {
            LivePreviewRefreshControls(store: input.store, refresh: input.refresh)
                .frame(height: 66, alignment: .top)
            ThemedScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(input.channels) { channel in
                        HStack(spacing: 12) {
                            LiveChannelPreviewView(store: input.store, channel: channel)
                            Text(channel.name).foregroundStyle(.white)
                            Spacer()
                        }
                        .frame(minHeight: 80).padding(.horizontal, 8)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12).background(Color(red: 0.08, green: 0.09, blue: 0.12))
        .preferredColorScheme(.dark)
    }
}
@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    var records: [[String: Any]] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 100) { self.finish("failed", "watchdog") }
        Task { @MainActor in
            do { try await exercise(); finish("passed") }
            catch { finish("failed", String(describing: error)) }
        }
    }
    func exercise() async throws {
        guard NSHomeDirectory().hasPrefix(output.path), TestRuntime.isRunning else { throw failure("isolation missing") }
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        for width in [360, 640] {
            let input = Input()
            let host = NSHostingView(rootView: Harness(input: input)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: 460),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait { input.store.demandCount > 0 }
            guard input.store.demandCount < 8, input.calls.isEmpty else { throw failure("offscreen or automatic demand") }
            try save(host, "empty-\(width)")
            try click(host, x: CGFloat(width) - 66, y: 26)
            try await wait { !input.store.isRefreshing && input.store.cachedCount > 0 }
            let before = input.calls.count
            guard before < 8, input.store.activeCount == 0,
                  let frame = input.store.frame(for: input.channels[0]) else { throw failure("native first frames missing") }
            try save(host, "cached-\(width)")
            input.failed = true
            try click(host, x: CGFloat(width) - 66, y: 26)
            try await wait { input.store.message != nil && !input.store.isRefreshing }
            guard input.store.frame(for: input.channels[0])?.capturedAt == frame.capturedAt else { throw failure("failed refresh changed old frame") }
            try save(host, "failure-keeps-cache-\(width)")
            input.failed = false
            guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first else { throw failure("scroll view missing") }
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: 720)); scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(250))
            let newCallStart = input.calls.count
            try click(host, x: CGFloat(width) - 66, y: 26)
            try await wait { !input.store.isRefreshing && input.calls.count > newCallStart }
            guard !input.calls[newCallStart...].contains(input.channels[0].name) else { throw failure("offscreen frame refreshed") }
            try save(host, "scrolled-\(width)")
            let finalCalls = input.calls.count
            window.orderOut(nil)
            try await wait { input.store.demandCount == 0 }
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            guard input.calls.count == finalCalls else { throw failure("window restore opened automatic media") }
            input.store.cancelRefresh(); await input.store.drain(); window.close()
            records.append(["width": width, "initialVisibleFrameCalls": before,
                            "nativeWindowMousePresses": 3, "failedRefreshKeptTimestamp": true,
                            "scrolledOnlyVisibleChannels": true, "hiddenDemandWithdrawn": true,
                            "restoreDidNotRefresh": true, "finalPhysicalReaders": input.store.activeCount])
        }
        // Fixed decoder's real local-media load/cancel/retirement, with no ffmpeg child.
        let spec = PlaySpec(url: "file:///private/tmp/netvplayer-ov91-long-gop-120.mp4")
        for _ in 0..<3 {
            let data = await PlayerChapterThumbnailDecoder.shared.liveImageData(spec: spec)
            guard let data, NSBitmapImageRep(data: data)?.pixelsWide == 320 else { throw failure("real pinned decoder") }
            let cancelled = Task { await PlayerChapterThumbnailDecoder.shared.liveImageData(spec: spec) }
            cancelled.cancel(); guard await cancelled.value == nil else { throw failure("cancelled decoder published") }
        }
        records.append(["pinnedLibmpvLocalFrames": 3, "cancelledFramesDiscarded": 3,
                        "runtimePath": ProcessInfo.processInfo.environment["NETVPLAYER_LIBMPV_PATH"] ?? "",
                        "childProcessesSpawned": 0, "realIPTVVerified": false])
        guard let origin = ProcessInfo.processInfo.environment["NETVPLAYER_PREVIEW_STALL_ORIGIN"] else { throw failure("stall fixture") }
        let remote = PlaySpec(url: origin + "/stall.ts", headers: ["X-Preview-Token": "fixture-only"], format: "ts")
        var retirement: [Double] = []
        for _ in 0..<3 {
            let store = LiveChannelPreviewStore()
            let channel = Channel(name: "stalled", urls: [remote.url])
            store.setSource("stalled"); store.setDemand(channel: channel, owner: UUID(), priority: .visible)
            store.refresh { _ in remote }
            try await waitNetwork(origin, active: 1)
            let start = ContinuousClock.now
            let hold = store.beginPlayback()
            await store.drain()
            try await waitNetwork(origin, active: 0)
            let elapsed = start.duration(to: .now)
            retirement.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            guard store.activeCount == 0, store.cachedCount == 0 else { throw failure("physical decoder not drained") }
            store.endPlayback(hold)
        }
        let timeoutStart = ContinuousClock.now
        let timedOut = await PlayerChapterThumbnailDecoder.shared.liveImageData(spec: remote)
        let timeoutDuration = timeoutStart.duration(to: .now)
        try await waitNetwork(origin, active: 0)
        guard timedOut == nil, timeoutDuration < .seconds(12) else { throw failure("unbounded native timeout") }
        records.append(["activeHTTPPreemptions": 3, "physicalRetirementSeconds": retirement,
                        "stalledNetworkTimeoutSeconds": Double(timeoutDuration.components.seconds) + Double(timeoutDuration.components.attoseconds) / 1e18,
                        "remoteReadersAfterDrain": 0])
    }
    func waitNetwork(_ origin: String, active: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while .now < deadline {
            let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/status")!)
            if let status = try JSONSerialization.jsonObject(with: data) as? [String: Any], status["active"] as? Int == active { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw failure("HTTP retirement timeout")
    }
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    func click(_ host: NSView, x: CGFloat, y: CGFloat) throws {
        guard let window = host.window else { throw failure("window missing") }
        let point = host.convert(NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw failure("event") }
            window.sendEvent(event)
        }
    }
    func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !predicate() {
            guard .now < deadline else { throw failure("state timeout") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func save(_ host: NSView, _ name: String) throws {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    func failure(_ text: String) -> Error { NSError(domain: "LivePreviewProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    func finish(_ status: String, _ error: String = "") {
        let record: [String: Any] = ["status": status, "error": error, "scenarios": records,
            "isolatedHome": NSHomeDirectory(), "memoryCredentials": TestRuntime.isRunning,
            "inputMedia": "/private/tmp/netvplayer-ov91-long-gop-120.mp4", "realServiceVerified": false]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-validation.json"))
        NSApp.terminate(nil)
    }
}
