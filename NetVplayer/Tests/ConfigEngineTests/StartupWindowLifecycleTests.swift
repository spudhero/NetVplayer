import AppKit
import SwiftUI
import Testing
import Diagnostics
@testable import NetVplayerApp

@Suite(.serialized) @MainActor
struct StartupWindowLifecycleTests {
    @Test func dockReopenUsesSceneWindowAndSuppressesDefaultCreation() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ov87-window-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StartupSessionStore(url: directory.appendingPathComponent("session.json"))
        try store.write(.starting, recoveryPending: false)
        var constructions = 0
        enum Unexpected: Error { case construction }
        let startup = AppStartupCoordinator(store: store, factory: { _ in
            constructions += 1
            throw Unexpected.construction
        }, cleanup: { _ in })
        startup.prepare()
        let windows = NetVplayerWindowCoordinator(startup: startup)
        let delegate = NetVplayerAppDelegate(windows: windows)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sceneIdentifier = NSUserInterfaceItemIdentifier("swiftui-owned-main-\(UUID())")
        window.identifier = sceneIdentifier
        window.contentView = NSHostingView(rootView: StartupRecoveryView(startup: startup, quit: {}))
        var sceneOpenRequests = 0
        windows.registerMainWindow(window) {
            sceneOpenRequests += 1
            window.makeKeyAndOrderFront(nil)
        }
        defer { window.close(); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        #expect(sceneOpenRequests == 0)
        #expect(window.isVisible)
        window.close()
        #expect(!window.isVisible)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(window.isVisible)
        #expect(sceneOpenRequests == 1)
        for flag in [true, false, true, false] {
            #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: flag))
        }
        // Dock minimization is verified in the installed .app; the test runner is not a Dock app.
        #expect(sceneOpenRequests == 1)
        #expect(window.identifier == sceneIdentifier)
        #expect(NSApp.windows.filter { $0.isVisible && $0.identifier == sceneIdentifier }.count == 1)
        await Task.yield()
        #expect(constructions == 0 && startup.phase == .recovery && startup.runtime == nil)
        #expect(await startup.terminate().value)
        #expect(try store.needsRecovery())
    }

    @Test func earlyDockEventsDoNotRaceSceneAttachmentWithFallbackWindow() {
        _ = NSApplication.shared
        let startup = AppStartupCoordinator(store: nil, factory: { _ in
            Issue.record("Showing a window must not construct AppState")
            throw CancellationError()
        }, cleanup: { _ in })
        let windows = NetVplayerWindowCoordinator(startup: startup)
        let delegate = NetVplayerAppDelegate(windows: windows)
        let countBefore = NSApp.windows.count
        for _ in 0..<5 {
            #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        }
        #expect(NSApp.windows.count == countBefore)
        let sceneWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sceneWindow.isReleasedWhenClosed = false
        defer { sceneWindow.close() }
        var sceneOpenRequests = 0
        windows.registerMainWindow(sceneWindow) { sceneOpenRequests += 1 }
        #expect(sceneWindow.isVisible)
        #expect(sceneOpenRequests == 0)
        #expect(startup.runtime == nil && startup.phase == .idle)
    }

    @Test func nativeRecoveryViewRendersWithBoundedRequests() throws {
        _ = NSApplication.shared
        let startup = StartupCoordinator<Int>(store: nil,
            startDiagnostics: { .init(state: .active, crashedLastRun: true) },
            factory: { _ in 1 }, cleanup: { _ in })
        startup.prepare()
        startup.enqueue((0..<10).map { URL(fileURLWithPath: "/tmp/fixture-\($0).mp4") })
        let view = NSHostingView(rootView: StartupRecoveryView(startup: startup, quit: {}))
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 650)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width <= 760)
        #expect(view.fittingSize.height <= 650)
        if let output = ProcessInfo.processInfo.environment["NETVPLAYER_STARTUP_CAPTURE_DIRECTORY"] {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("recovery-native-render.png"))
        }
    }
}
