import AppKit
import SwiftUI
import Testing
import Storage
import PlayerEngine
@testable import NetVplayerApp

@Suite("Player presentation native captures", .serialized)
struct PlayerPresentationCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_PLAYER_PRESENTATION_CAPTURE_DIR"] != nil))
    @MainActor func captureLayouts() async throws {
        guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_PLAYER_PRESENTATION_CAPTURE_DIR"] else { return }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("player-presentation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suite = "netvplayer.player-presentation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: temporary),
            userPreferences: UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore()),
            providerRuntimeBootstrap: nil)
        // Original, generated backdrop; no media library or remote artwork.
        let fixture = output.appendingPathComponent("synthetic-backdrop.png")
        let image = NSImage(size: .init(width: 1480, height: 833))
        image.lockFocus()
        NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.16, alpha: 1),
                   ending: NSColor(calibratedRed: 0.22, green: 0.15, blue: 0.10, alpha: 1))!
            .draw(in: NSRect(x: 0, y: 0, width: 1480, height: 833), angle: 30)
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let backdrop = try #require(NSBitmapImageRep(data: tiff))
        try #require(backdrop.representation(using: .png, properties: [:])).write(to: fixture)
        for (name, size, chapters) in [
            ("regular", CGSize(width: 1480, height: 833), false),
            ("chapters", CGSize(width: 1480, height: 833), true),
            ("minimum-regular", CGSize(width: 960, height: 640), true),
            ("compact", CGSize(width: 640, height: 360), true),
        ] {
            let configuration = PlayerVisualRegressionConfiguration(state: .normal, fixtureURL: fixture,
                viewport: size, outputURL: nil)
            configuration.apply(to: state)
            state.playerState.chapters = chapters ? (0..<24).map {
                PlayerChapter(id: $0, title: "Chapter \($0 + 1)", seconds: Double($0 * 300))
            } : []
            let view = NSHostingView(rootView: PlayerView(playerState: state.playerState,
                windowContext: PlayerWindowContext(), visualRegressionConfiguration: configuration)
                .environmentObject(state).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            window.appearance = NSAppearance(named: .darkAqua)
            try await Task.sleep(for: .milliseconds(250))
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(bytes.count > 2000)
            try bytes.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
            window.close()
        }
        try await state.prepareForApplicationTermination()
    }
}
