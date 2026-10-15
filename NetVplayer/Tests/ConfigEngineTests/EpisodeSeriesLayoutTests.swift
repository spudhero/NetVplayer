import AppKit
import SwiftUI
import Testing
import Models
import Storage
import DriveEngine
@testable import NetVplayerApp

/// Opt-in snapshots exercise the actual SwiftUI picker at the supported desktop sizes.
@Suite("Episode series layout", .serialized) @MainActor
struct EpisodeSeriesLayoutTests {
    @Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_EPISODE_SERIES_LAYOUT_OUTPUT"] == nil))
    func groupedDetailAtDesktopSizes() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_EPISODE_SERIES_LAYOUT_OUTPUT"])
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore())
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory.appendingPathComponent("storage")),
            userPreferences: preferences, providerRuntimeBootstrap: nil)
        let groups = [
            (DriveEpisodeSeries.source(provider: .quark, shareID: "example-a", directoryID: "sdr", directoryPath: "/M-美-R-余/4K SDR"), (1...10).map { String(format: "%02d", $0) }),
            (DriveEpisodeSeries.source(provider: .quark, shareID: "example-a", directoryID: "root", directoryPath: "/M-美-R-余"), ["S01E11", "S01E12"]),
            (DriveEpisodeSeries.source(provider: .quark, shareID: "example-b", directoryID: "root", directoryPath: "/美人鱼2026"), (1...12).map { String(format: "E%02d", $0) })
        ]
        state.episodes = groups.enumerated().flatMap { groupIndex, group in
            group.1.map { name in
                Episode(name: name, url: DriveFileReference(provider: .quark,
                    shareURL: "https://pan.quark.cn/s/example-\(groupIndex)", pwdID: groupIndex < 2 ? "example-a" : "example-b",
                    fid: "fixture-\(groupIndex)-\(name)", fidToken: "fixture", fileName: "\(name).mkv").encodedURL,
                    series: group.0)
            }
        }
        state.playFlags = ["夸克网盘", "百度网盘"]
        state.selectedPlayFlag = "夸克网盘"
        var vod = Vod(vodId: "fixture", vodName: "美人余（臻彩）", vodYear: "2026",
            vodContent: "根据伊北同名小说改编，以当代都市为背景，探讨真实情感和婚姻现状。",
            vodActor: "李一桐 王佳佳 常华森 曾梦雪 何润东", vodDirector: "王迎 毋辉辉", vodRemarks: "4K HDR 杜比视界")
        vod.episodeDetails = state.episodes
        vod.vodPlayFrom = "夸克网盘"
        vod.vodPlayUrl = state.episodes.map { "\($0.name)$\($0.url)" }.joined(separator: "#")
        state.detailVod = vod
        state.applyPlaybackAvailability(for: vod)
        #expect(state.episodeGroups.count == 3)
        for size in [CGSize(width: 1200, height: 675), CGSize(width: 1480, height: 833)] {
            for mode in [EpisodeDisplayMode.grid, .list] {
                state.episodeDisplayMode = mode
                let root = VodDetailView(vod: vod, layout: VodDetailLayoutPolicy.layout(in: size))
                    .environmentObject(state).environment(\.appThemePalette, state.appearancePalette)
                    .frame(width: size.width, height: size.height)
                    .background(AppThemeRootBackground(palette: state.appearancePalette, forceOpaque: false))
                    .preferredColorScheme(.dark)
                try await capture(root, size: size, to: directory.appendingPathComponent("series-\(Int(size.width))-\(mode.rawValue).png"))
            }
        }
    }

    private func capture<V: View>(_ view: V, size: CGSize, to url: URL) async throws {
        _ = NSApplication.shared
        let content = NSHostingView(rootView: view)
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setFrame(rect, display: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }
}
