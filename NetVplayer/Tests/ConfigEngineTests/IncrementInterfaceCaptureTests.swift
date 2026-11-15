import AppKit
import Models
import MediaServerEngine
import Storage
import SwiftUI
import Testing
@testable import NetVplayerApp
@testable import PlayerEngine

/// Opt-in layout evidence from shipping views, with synthetic inputs. No account
/// connection, media playback, preference writes, or device output acceptance.
@Suite("Increment interface native captures", .serialized)
@MainActor struct IncrementInterfaceCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_INCREMENT_UI_CAPTURE_DIR"] != nil))
    func captureInterfaces() async throws {
        let output = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["NETVPLAYER_INCREMENT_UI_CAPTURE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("increment-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "netvplayer.increment-ui." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: .init(storageDirectory: directory),
            userPreferences: .init(defaults: defaults, credentialStore: MemoryCredentialStore()),
            providerRuntimeBootstrap: nil)
        let player = PlayerState()
        let plex = MediaServerAccountModel()
        plex.kind = .plex
        plex.name = "家庭媒体库"
        plex.server = "https://plex.example"
        let sftp = FileServiceConfiguration(name: "家庭 NAS", kind: .sftp, address: "sftp://nas.example", rootPath: "/media")
        let accountStore = MediaServerStore(storage: .init(storageDirectory: directory.appendingPathComponent("servers")),
            preferences: .init(defaults: defaults, credentialStore: MemoryCredentialStore()))
        let account = MediaServerConfiguration(name: "Plex 示例", kind: .plex,
            server: "https://plex.example", serverID: "fixture-server", userID: "fixture-user")
        try accountStore.save([account])
        try accountStore.saveToken("fixture-token", for: account)
        let savedPlex = MediaServerAccountModel(store: accountStore, invalidate: { _ in })
        savedPlex.load(checkConnection: false)
        let expiredPlex = MediaServerAccountModel(store: accountStore,
            transport: .init(handler: { _, _ in throw MediaServerError.authentication }), invalidate: { _ in })
        expiredPlex.load()
        let deadline = ContinuousClock.now + .seconds(3)
        while expiredPlex.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(expiredPlex.state == .expired)
        for (theme, suffix) in [(AppAppearanceThemeID.auroraViolet, "dark"), (.greenPeachBlush, "light")] {
            let palette = AppThemeCatalog.palette(for: theme)
            try await capture("audio-" + suffix, width: 400, height: 680, output: output, palette: palette, state: state) {
                ScrollView { PlaybackAudioOutputSettingsContent(playerState: player, advancedExpanded: true).padding(20) }
            }
            try await capture("color-" + suffix, width: 400, height: 660, output: output, palette: palette, state: state) {
                ScrollView { PlaybackColorSettingsContent(playerState: player, advancedExpanded: true).padding(20) }
            }
            try await capture("plex-" + suffix, width: 660, height: 780, output: output, palette: palette, state: state) {
                ScrollView { MediaServerAccountSettings(model: plex, loadOnAppear: false).padding(24) }
            }
            try await capture("sftp-" + suffix, width: 660, height: 820, output: output, palette: palette, state: state) {
                FileServiceEditor(configuration: sftp)
            }
            for mode in [PlaybackTrueHDObjectMode.speakers714, .headphones, .trackedHeadphones] {
                try await capture("truehd-" + mode.rawValue + "-" + suffix, width: 320, height: 350,
                    output: output, palette: palette, state: state) {
                    PlaybackTrueHDObjectSettings(selection: .constant(mode), unavailable: mode == .speakers714).padding(20)
                }
            }
            for (name, enabled, available) in [("off", false, true), ("on", true, true), ("unavailable", false, false)] {
                try await capture("dolby-" + name + "-" + suffix, width: 360, height: 260,
                    output: output, palette: palette, state: state) {
                    PlaybackSystemDolbyVisionSetting(isOn: .constant(enabled), available: available).padding(20)
                }
            }
            for waiting in [false, true] {
                try await capture("drop-" + (waiting ? "queued-" : "ready-") + suffix, width: 640, height: 360,
                    output: output, palette: palette, state: state) {
                    LocalMediaFileDropOverlay(awaitingStartup: waiting)
                }
            }
            try await capture("plex-narrow-" + suffix, width: 480, height: 800,
                output: output, palette: palette, state: state) {
                ScrollView { MediaServerAccountSettings(model: plex, loadOnAppear: false).padding(24) }
            }
            for (name, model) in [("saved", savedPlex), ("expired", expiredPlex)] {
                try await capture("plex-" + name + "-" + suffix, width: 660, height: 780,
                    output: output, palette: palette, state: state) {
                    ScrollView { MediaServerAccountSettings(model: model, loadOnAppear: false).padding(24) }
                }
            }
        }
        try await capture("drop-player", width: 640, height: 360, output: output,
            palette: AppThemeCatalog.palette(for: .greenPeachBlush), state: state) {
            ZStack {
                Color.black
                LocalMediaFileDropOverlay(awaitingStartup: false, usesFixedDarkChrome: true)
            }
        }
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
