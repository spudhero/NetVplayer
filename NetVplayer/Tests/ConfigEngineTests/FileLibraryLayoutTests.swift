import AppKit
import SwiftUI
import Foundation
import Testing
import Models
import Storage
@testable import NetVplayerApp

@Suite("File library layout", .serialized)
@MainActor
struct FileLibraryLayoutTests {
    @Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FILE_LIBRARY_LAYOUT_OUTPUT"] == nil))
    func nativeLibraryAt960And1200Points() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FILE_LIBRARY_LAYOUT_OUTPUT"])
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = MediaIndex(url: directory.appendingPathComponent("preview.sqlite"))
        let service = FileServiceConfiguration(name: "家庭 NAS", kind: .smb, address: "smb://nas.local", rootPath: "/电影", share: "家庭共享")
        let library = MediaLibraryConfiguration(serviceID: service.id, name: "电影与剧集", metadataSource: .douban)
        let catalog = FileServiceCatalog(services: [service], libraries: [library])
        let state = FileServicesState(catalog: catalog, index: index, serviceID: service.id)
        state.selectedLibraryID = library.id; state.mode = .library
        for i in 0..<20 {
            let ref = try FileResourceReference(serviceID: service.id, libraryID: library.id, path: "/影片\(i).mkv")
            try await index.upsert(.init(reference: ref, entry: .init(path: ref.path, name: "影片\(i).mkv", isDirectory: false), groupKey: "movie",
                filenameMetadata: .init(title: "示例影片 \(i + 1)", year: 2020 + i % 5, kind: .movies), localMetadata: .init(doubanRating: 8.2 + Double(i % 5) / 10)), scanID: UUID())
        }
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore())
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false, userPreferences: preferences)
        appState.activeSite = service.site()
        appState.currentSiteName = service.name
        appState.isConfigLoaded = true
        appState.sites = [service.site()]
        for width in [960, 1200] {
            let root = HStack(spacing: 0) {
                SidebarView(selectedTab: .constant(.vodHome)).frame(width: HomeVisualPolicy.primarySidebarPaneIdealWidth)
                VodHomeView(fileServices: state)
            }.environmentObject(appState).frame(width: CGFloat(width), height: 720)
                .background(AppThemeRootBackground(palette: appState.appearancePalette, forceOpaque: false))
                .environment(\.appThemePalette, appState.appearancePalette).preferredColorScheme(.dark)
            try await capture(root, size: .init(width: width, height: 720), to: directory.appendingPathComponent("media-library-\(width).png"))
            #expect(state.mediaRecords.count == 20)
        }
        try await capture(FileServiceEditor(configuration: service).background(Color(NSColor.windowBackgroundColor)).preferredColorScheme(.dark), size: .init(width: 620, height: 680),
                          to: directory.appendingPathComponent("smb-editor.png"))
        try await capture(MediaLibraryEditor(library: library).background(Color(NSColor.windowBackgroundColor)).preferredColorScheme(.dark), size: .init(width: 550, height: 420),
                          to: directory.appendingPathComponent("library-editor.png"))
    }
    private func capture<V: View>(_ view: V, size: CGSize, to url: URL) async throws {
        _ = NSApplication.shared
        let content = NSHostingView(rootView: view)
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content; window.setFrame(rect, display: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size; content.cacheDisplay(in: content.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }
}
