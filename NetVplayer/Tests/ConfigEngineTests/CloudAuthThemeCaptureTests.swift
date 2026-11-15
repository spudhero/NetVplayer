import AppKit
import Models
import SwiftUI
import Testing
@testable import NetVplayerApp

/// Opt-in native renderings with a static demonstration QR, no login or credentials.
@Suite(.serialized) @MainActor
struct CloudAuthThemeCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AUTH_THEME_CAPTURE_DIR"] != nil))
    func signInStates() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AUTH_THEME_CAPTURE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let image = try #require(CloudAuthQRCodeImageFactory.imageData(from: "NETVPLAYER_SYNTHETIC_UI_ONLY").flatMap(NSImage.init(data:)))
        for theme in [AppAppearanceThemeID.auroraViolet, .greenPeachBlush] {
            let palette = AppThemeCatalog.palette(for: theme)
            for state in ["ready", "loading", "unavailable", "manual"] {
                let content = VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.text("登录二维码")).font(.headline)
                    Divider()
                    HStack(alignment: .center, spacing: 24) {
                        CloudAuthQRCodeCard(image: state == "ready" ? image : nil,
                            isLoading: state == "loading", isManual: state == "manual")
                        VStack(alignment: .leading, spacing: 12) {
                            Text(state == "unavailable" ? L10n.text("二维码暂不可用") : L10n.text("登录二维码"))
                                .font(.headline)
                            Text(L10n.text(state == "unavailable" ? "请刷新二维码重试。" :
                                state == "manual" ? "粘贴登录信息" :
                                state == "loading" ? "正在获取二维码" : "等待确认"))
                                .foregroundStyle(palette.muted)
                            Button(L10n.text("刷新二维码")) {}.disabled(state == "loading")
                            if state == "manual" {
                                SettingsPasswordField(L10n.text("粘贴登录信息"), text: .constant(""))
                                Button(L10n.text("验证并保存")) {}
                                    .buttonStyle(ThemedDialogButtonStyle(isPrimary: true)).disabled(true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack { Spacer(); Button(L10n.text("关闭")) {} }
                }
                .padding(24).frame(width: 640, height: 400)
                .themedPresentation().environment(\.appThemePalette, palette)
                .preferredColorScheme(palette.preferredColorScheme)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 400),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: palette.preferredColorScheme == .dark ? .darkAqua : .aqua)
                host.appearance = window.appearance
                window.contentView = host
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 2000)
                try png.write(to: output.appendingPathComponent("\(theme.rawValue)-\(state).png"))
            }
        }
    }
}
