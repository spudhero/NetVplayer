import AppKit
import Models
import MediaServerEngine
import Storage
import SwiftUI
import Testing
@testable import NetVplayerApp

/// Opt-in native layout evidence. All stores and account values are synthetic;
/// this suite never installs a component, connects a source, or starts playback.
@Suite("Runtime UI native captures", .serialized)
@MainActor struct RuntimeInterfaceCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_RUNTIME_UI_CAPTURE_DIR"] != nil))
    func captureInterfaces() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_RUNTIME_UI_CAPTURE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-ui-" + UUID().uuidString)
        let suite = "netvplayer.runtime-ui." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        let storage = StorageManager(storageDirectory: directory)
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: storage, userPreferences: preferences, providerRuntimeBootstrap: nil)
        let files = FileServicesState(catalog: .init(), index: MediaIndex(url: directory.appendingPathComponent("media.sqlite")),
            store: FileServiceStore(storage: storage, preferences: preferences), cloudPreferences: preferences)
        let serverStore = MediaServerStore(storage: storage, preferences: preferences)
        let fnos = MediaServerAccountModel(store: serverStore, invalidate: { _ in })
        fnos.kind = .fnos; fnos.name = "家庭媒体库"; fnos.server = "https://nas.example"
        let zspace = MediaServerAccountModel(store: serverStore, invalidate: { _ in })
        zspace.kind = .zspace; zspace.name = "客厅 NAS"; zspace.server = "https://nas.example"
        for (theme, suffix) in [(AppAppearanceThemeID.auroraViolet, "dark"), (.greenPeachBlush, "light")] {
            let palette = AppThemeCatalog.palette(for: theme)
            for mode in ["missing", "installed", "restart", "error", "busy"] {
                state.preferredProviderExecution = mode == "restart" ? .androidPreferred : .automatic
                state.androidRuntimeComponentVersion = mode == "missing" ? nil : "1.0.8"
                state.androidRuntimePreviousVersion = mode == "missing" ? nil : "1.0.7"
                state.androidRuntimeComponentError = mode == "error" ? "组件签名验证失败，请重新选择完整的签名组件文件夹。" : nil
                state.androidRuntimeComponentRequiresRestart = mode == "restart"
                state.androidRuntimeComponentBusy = mode == "busy"
                try await capture("runtime-" + mode + "-" + suffix, width: 520, height: 720, output: output, palette: palette, state: state) {
                    ScrollView { ProviderExecutionSettingsView(appState: state, loadComponentOnAppear: false).padding(24) }
                }
            }
            state.androidRuntimeComponentBusy = false
            state.androidRuntimeComponentRequiresRestart = true
            state.preferredProviderExecution = .androidPreferred
            try await capture("runtime-narrow-" + suffix, width: 360, height: 820, output: output, palette: palette, state: state) {
                ScrollView { ProviderExecutionSettingsView(appState: state, loadComponentOnAppear: false).padding(20) }
            }
            try await capture("cloud-directory-" + suffix, width: 600, height: 430, output: output, palette: palette, state: state) {
                CloudDirectoryEditor(state: files)
            }
            for (name, model) in [("fnos", fnos), ("zspace", zspace)] {
                try await capture(name + "-" + suffix, width: 520, height: 800, output: output, palette: palette, state: state) {
                    ScrollView { MediaServerAccountSettings(model: model, loadOnAppear: false).padding(24) }
                }
            }
            for (name, enabled, available) in [("on", true, true), ("off", false, true), ("unavailable", false, false)] {
                try await capture("dolby-" + name + "-" + suffix, width: 360, height: 300, output: output, palette: palette, state: state) {
                    PlaybackSystemDolbyVisionSetting(isOn: .constant(enabled), sourceMetadata: .constant(true), available: available).padding(20)
                }
            }
        }
        for enabled in [true, false] {
            try await capture("danmaku-" + (enabled ? "enabled" : "disabled"), width: 360, height: 300,
                output: output, palette: AppThemeCatalog.palette(for: .legacyDeepSpace), state: state) {
                VStack(alignment: .leading, spacing: 12) {
                    ProviderDanmakuTrackPicker(tracks: [
                        .init(name: "原版弹幕 · 中文", url: "https://example.invalid/track-1"),
                        .init(name: "特别放映版 · 导演评论与观众弹幕（完整修复收藏版）", url: "https://example.invalid/track-2"),
                        .init(url: "https://example.invalid/track-3")
                    ], selection: 1, enabled: enabled, onSelect: { _ in })
                }.padding(20)
            }
        }
        try await state.prepareForApplicationTermination()
    }

    private func capture<Content: View>(_ name: String, width: CGFloat, height: CGFloat,
        output: URL, palette: AppThemePalette, state: AppState, @ViewBuilder content: () -> Content) async throws {
        let previous = NSApplication.shared.appearance
        let appearance = NSAppearance(named: palette.preferredColorScheme == .dark ? .darkAqua : .aqua)
        NSApplication.shared.appearance = appearance
        defer { NSApplication.shared.appearance = previous }
        let root = content().themedPresentation().environmentObject(state).environment(\.appThemePalette, palette)
            .preferredColorScheme(palette.preferredColorScheme).foregroundStyle(palette.foreground).tint(palette.accent)
            .frame(width: width, height: height, alignment: .topLeading).background(palette.background)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = appearance; host.appearance = appearance
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bytes.count > 2000)
        try bytes.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
