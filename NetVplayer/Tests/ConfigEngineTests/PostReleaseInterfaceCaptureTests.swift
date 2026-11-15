import AppKit
import Models
import SubtitleEngine
import SwiftUI
import Testing

@testable import NetVplayerApp
@testable import PlayerEngine

/// Opt-in captures render the shipping SwiftUI views, without signing in, playing
/// media, downloading language models, or changing the user's preferences.
@Suite("Post-release interface captures", .serialized)
struct PostReleaseInterfaceCaptureTests {
    /// Synthetic diagnostic fixtures exercise the shipping views. These captures
    /// are UI evidence, never evidence of a physical receiver's capabilities.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FORMAT_CAPTURE_DIR"] != nil)) @MainActor
    func capturePlaybackFormatStatus() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NETVPLAYER_FORMAT_CAPTURE_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
        let palette = AppThemeCatalog.palette(for: .legacyDeepSpace)
        let hdr = try PlaybackFormatTestFixtures.diagnostics()
        var dolby = try PlaybackFormatTestFixtures.diagnostics(mode: .nativeCompressed)
        PlaybackFormatTestFixtures.reconstructDolby(&dolby)
        let cases: [(String, PlaybackFormatSummary)] = [
            ("hdr-pcm", PlaybackFormatTestFixtures.summary(hdr)),
            ("dolby-system", PlaybackFormatTestFixtures.summary(dolby)),
            ("hdr-sdr", PlaybackFormatTestFixtures.summary(try PlaybackFormatTestFixtures.diagnostics(hdr: false))),
            ("preparing", .init(diagnostics: nil, ownerID: nil, hasPlayback: true)),
        ]
        for (name, summary) in cases {
            try await capture("format-" + name, size: CGSize(width: 640, height: 110), output: output,
                              palette: palette, appState: appState) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("模拟诊断状态 · 原生 SwiftUI 界面验证").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        PlaybackFormatStatusBar(summary: summary, playerState: appState.playerState, selection: .constant(nil))
                        Spacer(minLength: 0)
                    }
                }.padding(20)
            }
        }
        for status in PlaybackFormatTestFixtures.summary(hdr).items {
            try await capture("format-detail-" + status.kind.rawValue, size: CGSize(width: 400, height: 400),
                              output: output, palette: palette, appState: appState) {
                PlaybackFormatDetailsView(status: status, playerState: appState.playerState, onClose: {})
            }
        }
        let dolbyStatus = try #require(PlaybackFormatTestFixtures.summary(dolby).video)
        try await capture("format-detail-dolby", size: CGSize(width: 400, height: 400),
                          output: output, palette: palette, appState: appState) {
            PlaybackFormatDetailsView(status: dolbyStatus, playerState: appState.playerState, onClose: {})
        }
        let volumeState = PlayerState()
        volumeState.volume = 0.64
        for control in [PlaybackVolumeControl.receiver, .player] {
            volumeState.volumeControl = control
            try await capture(control == .receiver ? "volume-receiver" : "volume-pcm",
                size: CGSize(width: 360, height: 300), output: output, palette: palette, appState: appState) {
                PlaybackVolumePopover(playerState: volumeState, setVolume: { _ in },
                                      toggleMute: {}, usePlayerVolume: {})
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_INTERFACE_CAPTURE_DIR"] != nil)) @MainActor
    func captureNativeInterfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NETVPLAYER_INTERFACE_CAPTURE_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
        let player = PlayerState()
        player.currentSpec = PlaySpec(title: "界面检查片段", siteKey: "interface-review")
        let values: [String: Any] = [
            "current-tracks/video": ["codec": "h264", "codec-profile": "High", "decoder": "h264"],
            "video-dec-params": [
                "w": 1920, "h": 1080, "pixelformat": "yuv420p", "gamma": "bt.1886", "primaries": "bt.709",
            ],
            "container-fps": 24.0, "hwdec-current": "videotoolbox-copy",
            "current-tracks/audio": ["codec": "aac", "decoder": "aac"],
            "audio-params": ["format": "floatp", "channels": "stereo", "samplerate": 48000],
            "audio-out-params": ["format": "float", "channels": "stereo", "samplerate": 48000],
            "current-ao": "coreaudio",
        ]
        player.playbackDiagnostics = PlaybackDiagnostics(
            mediaID: UUID(),
            properties: try values.mapValues {
                try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])
            }, display: .init(name: "界面检查显示器", targetFormat: "GL_RGBA8", edrEnabled: false))
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "interface-capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = SubtitleTranslationCache(directory: cacheDirectory)
        let translation = SubtitleTranslationModel(session: .init(cache: cache, budget: .init()))
        translation.bind(player.currentSpec)
        let recognition = SubtitleRecognitionModel()
        recognition.update(player)
        let palette = AppThemeCatalog.palette(for: .auroraViolet)

        try await capture(
            "playback-information", size: CGSize(width: 360, height: 760), output: output,
            palette: palette, appState: appState
        ) {
            ScrollView { PlaybackInformationView(playerState: player).padding(16) }.themedPresentation()
        }
        try await capture(
            "playback-information-narrow", size: CGSize(width: 320, height: 580), output: output,
            palette: palette, appState: appState
        ) {
            ScrollView { PlaybackInformationView(playerState: player).padding(16) }.themedPresentation()
        }
        try await capture(
            "playback-details", size: CGSize(width: 360, height: 580), output: output,
            palette: palette, appState: appState
        ) {
            ScrollView { PlaybackInformationView(playerState: player, initialTab: .details).padding(16) }
                .themedPresentation()
        }
        try await capture(
            "playback-settings", size: CGSize(width: 360, height: 580), output: output,
            palette: palette, appState: appState
        ) {
            ScrollView { PlaybackInformationView(playerState: player, initialTab: .settings).padding(16) }
                .themedPresentation()
        }
        let standardDiagnostics = player.playbackDiagnostics
        var hdrValues = values
        hdrValues["video-dec-params"] = [
            "w": 3840, "h": 2160, "pixelformat": "yuv420p10le", "gamma": "pq", "primaries": "bt.2020",
        ]
        player.playbackDiagnostics = PlaybackDiagnostics(mediaID: UUID(), properties: try hdrValues.mapValues {
            try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])
        }, display: .init(targetFormat: "GL_RGBA8", edrEnabled: false))
        player.playbackDiagnostics?.display.videoOutput = PlaybackVideoOutputAssessment(
            requestedMode: .automatic, sourceSignal: .pq, disposition: .hdrMappedToSDR,
            hdrRestrictions: [.headroomUnavailable])
        try await capture("playback-hdr-fallback", size: CGSize(width: 360, height: 580), output: output,
            palette: palette, appState: appState) {
                ScrollView { PlaybackInformationView(playerState: player).padding(16) }.themedPresentation()
            }
        player.playbackDiagnostics = standardDiagnostics
        try await capture("playback-hud-theme", size: CGSize(width: 360, height: 580), output: output,
            palette: AppThemeCatalog.palette(for: .legacyDeepSpace), appState: appState) {
                ScrollView { PlaybackInformationView(playerState: player).padding(16) }.themedPresentation()
            }
        try await capture(
            "color-settings", size: CGSize(width: 360, height: 760), output: output,
            palette: palette, appState: appState
        ) {
            ScrollView { PlaybackColorSettingsView(playerState: player, initiallyExpanded: true).padding(16) }
                .themedPresentation()
        }
        try await capture(
            "audio-settings", size: CGSize(width: 360, height: 760), output: output,
            palette: palette, appState: appState
        ) {
            ScrollView { PlaybackAudioOutputSettingsView(playerState: player, initiallyExpanded: true).padding(16) }
                .themedPresentation()
        }
        try await capture(
            "dialogue-settings", size: CGSize(width: 360, height: 760), output: output,
            palette: palette, appState: appState
        ) {
            ScrollView { PlaybackDialogueSettingsView(playerState: player, initiallyExpanded: true).padding(16) }
                .themedPresentation()
        }

        try await capture(
            "subtitle-translation", size: CGSize(width: 700, height: 690), output: output,
            palette: palette, appState: appState
        ) {
            SubtitleTranslationView(model: translation, player: player, attachOriginal: { _ in })
        }
        try await capture(
            "subtitle-recognition", size: CGSize(width: 700, height: 690), output: output,
            palette: palette, appState: appState
        ) {
            SubtitleRecognitionView(model: recognition, player: player, useDocument: { _, _ in })
        }
        try await capture(
            "media-server", size: CGSize(width: 820, height: 720), output: output,
            palette: palette, appState: appState
        ) {
            MediaServerAccountSettings().padding(24).themedPresentation()
        }
        try await capture(
            "media-server-narrow", size: CGSize(width: 400, height: 900), output: output,
            palette: palette, appState: appState
        ) {
            MediaServerAccountSettings().padding(18).themedPresentation()
        }
        try await capture(
            "media-server-light", size: CGSize(width: 820, height: 720), output: output,
            palette: AppThemeCatalog.palette(for: .seaSalt), appState: appState
        ) {
            MediaServerAccountSettings().padding(24).themedPresentation()
        }
        try await capture(
            "display-inspection", size: CGSize(width: 960, height: 780), output: output,
            palette: palette, appState: appState
        ) {
            DisplayInspectionView()
        }
        try await capture("display-inspection-minimum", size: CGSize(width: 720, height: 650), output: output,
            palette: palette, appState: appState) { DisplayInspectionView() }
        try await capture("display-inspection-light", size: CGSize(width: 960, height: 780), output: output,
            palette: AppThemeCatalog.palette(for: .seaSalt), appState: appState) { DisplayInspectionView() }
        translation.load(
            data: Data(
                "1\n00:00:01,000 --> 00:00:04,000\nA quiet evening.\n\n2\n00:00:05,000 --> 00:00:08,000\nChoose a subtitle to begin.\n"
                    .utf8), filename: "review.srt")
        try await capture(
            "subtitle-translation-ready", size: CGSize(width: 700, height: 690), output: output,
            palette: palette, appState: appState
        ) {
            SubtitleTranslationView(model: translation, player: player, attachOriginal: { _ in })
        }
        try await capture("subtitle-translation-compact", size: CGSize(width: 650, height: 560), output: output,
            palette: palette, appState: appState) {
                SubtitleTranslationView(model: translation, player: player, attachOriginal: { _ in })
            }
        try await capture(
            "subtitle-translation-light", size: CGSize(width: 700, height: 690), output: output,
            palette: AppThemeCatalog.palette(for: .seaSalt), appState: appState
        ) {
            SubtitleTranslationView(model: translation, player: player, attachOriginal: { _ in })
        }

        let owner = try #require(translation.owner)
        let document = try #require(translation.document)
        let key = SubtitleTranslationKey(
            media: "session:" + owner.uuidString, document: document,
            sourceLanguage: translation.sourceLanguage, targetLanguage: translation.targetLanguage,
            translator: SubtitleTranslationModel.appleIdentity)
        _ = try await cache.merge(key: key, total: 2, translations: [0: "界面检查译文一"])
        translation.start(completing: true)
        try await waitForSession(translation)
        #expect(translation.isProcessing)
        try await capture(
            "subtitle-translation-busy", size: CGSize(width: 700, height: 690), output: output,
            palette: palette, appState: appState
        ) {
            SubtitleTranslationView(model: translation, player: player, attachOriginal: { _ in })
        }
        translation.cancel()
        try await capture(
            "subtitle-translation-resume", size: CGSize(width: 700, height: 690), output: output,
            palette: palette, appState: appState
        ) {
            SubtitleTranslationView(model: translation, player: player, attachOriginal: { _ in })
        }
        _ = try await cache.merge(key: key, total: 2, translations: [1: "界面检查译文二"])
        translation.start(completing: true)
        try await waitForSession(translation)
        #expect(translation.coverage?.complete == true && !translation.isProcessing)
        try await capture(
            "subtitle-translation-complete", size: CGSize(width: 700, height: 690), output: output,
            palette: palette, appState: appState
        ) {
            SubtitleTranslationView(model: translation, player: player, attachOriginal: { _ in })
        }
        translation.cancel()
        translation.load(data: Data("invalid subtitle".utf8), filename: "invalid.srt")
        try await capture(
            "subtitle-translation-error", size: CGSize(width: 700, height: 690), output: output,
            palette: palette, appState: appState
        ) {
            SubtitleTranslationView(model: translation, player: player, attachOriginal: { _ in })
        }
    }

    @MainActor
    private func waitForSession(_ model: SubtitleTranslationModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !model.active, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.active)
    }

    @MainActor
    private func capture<Content: View>(
        _ name: String, size: CGSize, output: URL, palette: AppThemePalette,
        appState: AppState, @ViewBuilder content: () -> Content
    ) async throws {
        if let selected = ProcessInfo.processInfo.environment["NETVPLAYER_INTERFACE_CAPTURE_ONLY"], selected != name {
            return
        }
        let root = content()
            .environmentObject(appState)
            .environment(\.appThemePalette, palette)
            .preferredColorScheme(palette.preferredColorScheme)
            .frame(width: size.width, height: size.height)
            .background(palette.background)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(palette.background)
        window.appearance = NSAppearance(named: palette.preferredColorScheme == .dark ? .darkAqua : .aqua)
        window.contentView = view
        defer { window.close() }
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        try await Task.sleep(for: .milliseconds(180))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 5_000, "Native interface must contain rendered content")
        try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
