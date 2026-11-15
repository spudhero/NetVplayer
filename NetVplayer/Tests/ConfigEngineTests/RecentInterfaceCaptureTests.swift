import AppKit
import SwiftUI
import Testing
import Models
import Storage
@testable import PlayerEngine
@testable import NetVplayerApp

/// Opt-in native renders with isolated storage and synthetic data. These are
/// layout evidence, not proof of device output or live provider acceptance.
@Suite("Recent interface native captures", .serialized)
struct RecentInterfaceCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_RECENT_UI_CAPTURE_DIR"] != nil))
    @MainActor func captureInterfaces() async throws {
        guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_RECENT_UI_CAPTURE_DIR"] else { return }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("recent-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suite = "netvplayer.recent-ui." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = StorageManager(storageDirectory: temporary)
        let scope = DriveTransferTaskScope(provider: .quark, cacheKey: "fixture", sourceKey: "fixture",
            accountReference: "fixture", configurationIdentity: "fixture", target: "fixture",
            shareID: "fixture", sourceFileID: "fixture", name: "合成检查片段.mkv", size: 1)
        var task = DriveTransferTask(scope: scope)
        task.phase = .outcomeUnknown; task.submitted = true
        let journal = DriveTransferTaskStore(storage: storage)
        try journal.insert(task)
        try journal.diagnostics.record(.transfer(task))
        try journal.diagnostics.record(.init(id: UUID(), kind: .mediaScan,
            event: .init(stage: .scanning, state: .needsAttention, issue: .init(.partial))))
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: storage,
            userPreferences: UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore()),
            providerRuntimeBootstrap: nil)
        let startup = StartupCoordinator<Int>(store: nil,
            startDiagnostics: { .init(state: .disabled, crashedLastRun: true) }, factory: { _ in 1 }, cleanup: { _ in })
        startup.prepare()
        let controller = LocalAutomationController(read: { _ in Data("{}".utf8) })
        let programme = EpgItem(title: "山海之间 · 合成节目", start: Date().addingTimeInterval(-7200), end: Date().addingTimeInterval(-3600))
        let catchup = LiveCatchupContext(sourceFingerprint: "fixture", sourceRevision: UUID(),
            channelFingerprint: "fixture", channelName: "示例纪录片频道", programme: programme, supportsRequestSeek: true)
        let reference = try MediaServerReference(accountID: UUID(), itemID: "fixture")
        let files = [MediaServerFileDetail(id: "fixture", episodeURL: reference.locator,
            name: "合成检查片段 · 4K", container: "mkv", width: 3840, height: 2160,
            videoCodec: "hevc", videoRange: "Dolby Vision", audio: ["Dolby TrueHD + Dolby Atmos · 7.1"],
            sourceID: "fixture", supportsOriginalPlayback: true)]
        let player = PlayerState()
        var diagnostics = try PlaybackFormatTestFixtures.diagnostics(hdr: false)
        PlaybackFormatTestFixtures.reconstructDolby(&diagnostics)
        let summary = PlaybackFormatTestFixtures.summary(diagnostics)
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "合成媒体库")
        var checkpoint = MediaScanCheckpoint(library: library, revision: "fixture")
        checkpoint.phase = .partial
        checkpoint.directories = [
            .init(path: "/已完成", state: .completed), .init(path: "/待扫描", state: .pending),
            .init(path: "/示例失败目录", state: .failed)
        ]
        for (theme, suffix) in [(AppAppearanceThemeID.auroraViolet, "dark"), (.greenPeachBlush, "light")] {
            let palette = AppThemeCatalog.palette(for: theme)
            try await capture("startup-" + suffix, width: 720, height: 650, output: output, palette: palette, state: state) {
                StartupRecoveryView(startup: startup, quit: {})
            }
            try await capture("tasks-" + suffix, width: 680, height: 540, output: output, palette: palette, state: state) {
                DriveTaskRecoveryView()
            }
            try await capture("automation-" + suffix, width: 650, height: 640, output: output, palette: palette, state: state) {
                ScrollView { LocalAutomationSettingsView(controller: controller).padding(20) }.themedPresentation()
            }
            try await capture("detail-" + suffix, width: 640, height: 390, output: output, palette: palette, state: state) {
                MediaServerFilesSection(files: files, selectedSourceID: "fixture").padding(24).themedPresentation()
            }
            try await capture("scan-" + suffix, width: 640, height: 330, output: output, palette: palette, state: state) {
                MediaScanRecoveryContent(checkpoint: checkpoint, configurationMatches: true, canContinue: true,
                    issue: .init(.partial), onEditService: {}, onRequest: { _ in }).padding(24).themedPresentation()
            }
            try await capture("scan-narrow-login-" + suffix, width: 340, height: 370, output: output, palette: palette, state: state) {
                MediaScanRecoveryContent(checkpoint: checkpoint, configurationMatches: true, canContinue: true,
                    issue: .init(.credentialExpired), onEditService: {}, onRequest: { _ in }).padding(16).themedPresentation()
            }
        }
        await controller.setEnabled(true)
        #expect(controller.enabled)
        for (theme, suffix) in [(AppAppearanceThemeID.auroraViolet, "dark"), (.greenPeachBlush, "light")] {
            let palette = AppThemeCatalog.palette(for: theme)
            try await capture("automation-enabled-" + suffix, width: 650, height: 640, output: output, palette: palette, state: state) {
                ScrollView { LocalAutomationSettingsView(controller: controller).padding(20) }.themedPresentation()
            }
            var cancelled = checkpoint
            cancelled.phase = .cancelled
            try await capture("scan-cancelled-" + suffix, width: 640, height: 330, output: output, palette: palette, state: state) {
                MediaScanRecoveryContent(checkpoint: cancelled, configurationMatches: true, canContinue: false,
                    issue: nil, onEditService: {}, onRequest: { _ in }).padding(24).themedPresentation()
            }
        }
        await controller.shutdown()
        let hud = AppThemeCatalog.palette(for: .legacyDeepSpace)
        try await capture("catchup", width: 650, height: 190, output: output, palette: hud, state: state) {
            LiveCatchupControls(context: catchup, phase: .playing, position: 840, canSeek: true,
                message: L10n.text("节目回放进度"), onSeek: { _ in }, onRetry: {}, onReplay: {}, onReturnToLive: {})
                .padding(20)
        }
        try await capture("catchup-compact", width: 360, height: 190, output: output, palette: hud, state: state) {
            LiveCatchupControls(context: catchup, phase: .failed, position: 840, canSeek: false,
                message: L10n.text("回放失败，请重试。"), compact: true,
                onSeek: { _ in }, onRetry: {}, onReplay: {}, onReturnToLive: {}).padding(12)
        }
        try await capture("dolby-output", width: 560, height: 120, output: output, palette: hud, state: state) {
            PlaybackFormatStatusBar(summary: summary, playerState: player, selection: .constant(nil)).padding(20)
        }
        diagnostics.audio.mode = .passthrough
        diagnostics.audio.outputDriver = "coreaudio_exclusive"; diagnostics.audio.outputFormat = "spdif-truehd"
        diagnostics.audio.compressedAudio = .init(codec: diagnostics.audio.codec, profile: diagnostics.audio.profile,
            mode: .passthrough, passthroughProperty: nil)
        let bothActive = PlaybackFormatTestFixtures.summary(diagnostics)
        try await capture("dolby-both-active", width: 560, height: 120, output: output, palette: hud, state: state) {
            PlaybackFormatStatusBar(summary: bothActive, playerState: player, selection: .constant(nil)).padding(20)
        }
        let locator = reference.locator
        var vod = Vod(vodId: locator, vodName: "山海之间 · 合成检查片段", vodPlayFrom: "原始文件",
            vodPlayUrl: "正片$" + locator, siteKey: "fixture")
        vod.episodeDetails = [Episode(name: "正片", url: locator)]
        vod.mediaServerDetail = .init(metadata: MediaMetadata(title: vod.vodName, year: 2026, kind: .movies,
            plot: "用于检查详情布局的固定资料，不连接真实媒体服务器。"), files: files)
        state.detailVod = vod
        state.applyPlaybackAvailability(for: vod)
        try await capture("detail-hero", width: 960, height: 720, output: output, palette: hud, state: state) {
            MediaServerDetailView(vod: vod, size: .init(width: 960, height: 720))
        }
        try await state.prepareForApplicationTermination()
    }

    @MainActor private func capture<Content: View>(_ name: String, width: CGFloat, height: CGFloat,
        output: URL, palette: AppThemePalette, state: AppState, @ViewBuilder content: () -> Content) async throws {
        let root = content().environmentObject(state).environment(\.appThemePalette, palette)
            .preferredColorScheme(palette.preferredColorScheme).foregroundStyle(palette.foreground).tint(palette.accent)
            .frame(width: width, height: height).background(palette.background)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: palette.preferredColorScheme == .dark ? .darkAqua : .aqua)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(220))
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bytes.count > 2000)
        try bytes.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
