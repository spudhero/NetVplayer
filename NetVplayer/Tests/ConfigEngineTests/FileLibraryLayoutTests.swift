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
    func nativeLibraryAndFolderSettingsAtDesktopSizes() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FILE_LIBRARY_LAYOUT_OUTPUT"])
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = MediaIndex(url: directory.appendingPathComponent("preview.sqlite"))
        let service = FileServiceConfiguration(name: "家庭 NAS", kind: .smb, address: "smb://nas.local", rootPath: "/电影", share: "家庭共享")
        let library = MediaLibraryConfiguration(serviceID: service.id, name: "电影与剧集", metadataSource: .douban)
        let catalog = FileServiceCatalog(services: [service], libraries: [library])
        let state = FileServicesState(catalog: catalog, index: index, serviceID: service.id)
        state.selectedLibraryID = library.id; state.mode = .library
        for i in 0..<153 {
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
        let television = MediaLibraryConfiguration(serviceID: service.id, name: "电视剧", path: "/电视剧", kind: .television)
        state.catalog.libraries.append(television)
        for size in [CGSize(width: 960, height: 720), CGSize(width: 1200, height: 675), CGSize(width: 1480, height: 833)] {
            let width = Int(size.width)
            let root = HStack(spacing: 0) {
                SidebarView(selectedTab: .constant(.vodHome)).frame(width: HomeVisualPolicy.primarySidebarPaneIdealWidth)
                VodHomeView(fileServices: state)
            }.environmentObject(appState).frame(width: size.width, height: size.height)
                .background(AppThemeRootBackground(palette: appState.appearancePalette, forceOpaque: false))
                .environment(\.appThemePalette, appState.appearancePalette).preferredColorScheme(.dark)
            try await capture(root, size: size, to: directory.appendingPathComponent("media-library-\(width).png"))
            #expect(state.mediaRecords.count == 100)
            #expect(state.mediaHasMore)
        }
        let settings = FileServiceSettings(state: state).padding(24).frame(width: 900, height: 540, alignment: .topLeading)
            .environment(\.appThemePalette, appState.appearancePalette)
            .background(AppThemeRootBackground(palette: appState.appearancePalette, forceOpaque: false))
        try await capture(settings, size: .init(width: 900, height: 540), to: directory.appendingPathComponent("nas-settings.png"))
        let folders = directory.appendingPathComponent("folders")
        for name in ["电影", "电视剧", "纪录片", "动画", "家庭影像"] {
            try FileManager.default.createDirectory(at: folders.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let store = FileServiceStore(storage: StorageManager(storageDirectory: directory.appendingPathComponent("folder-state")), preferences: preferences)
        let localService = FileServiceConfiguration(name: "家庭 NAS · 文件夹布局", kind: .local)
        try store.save(.init(services: [localService]))
        try store.saveBookmark(folders.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), for: localService.id)
        let folderState = FileServicesState(index: index, store: store)
        try await capture(MediaLibraryBatchEditor(state: folderState, service: localService)
            .environment(\.appThemePalette, appState.appearancePalette),
            size: .init(width: 840, height: 590), to: directory.appendingPathComponent("nas-folders.png"))
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
