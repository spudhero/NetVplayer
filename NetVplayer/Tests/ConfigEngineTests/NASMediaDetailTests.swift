import AppKit
import SwiftUI
import Testing
import Models
import Storage
import MediaLibraryEngine
@testable import NetVplayerApp

@Suite("NAS media detail", .serialized) @MainActor
struct NASMediaDetailTests {
    @Test func resumeSelectionStaysWithinVisibleSeasonAndFileSummariesUseOnlyKnownData() throws {
        let first = Episode(name: "第1集", url: "one")
        let second = Episode(name: "第2集", url: "two")
        let history = History(episodeUrl: "two", position: 120_000)
        #expect(NASMediaDetailPresentation.primaryEpisode(episodes: [first, second], history: history)?.url == "two")
        #expect(NASMediaDetailPresentation.primaryEpisode(episodes: [first], history: history)?.url == "one")
        #expect(NASMediaDetailPresentation.primaryEpisode(episodes: [], history: history) == nil)
        #expect(NASMediaDetailPresentation.primaryEpisode(episodes: [first, second], history: history, selectedURL: "one")?.url == "one")
        #expect(NASMediaDetailPresentation.primaryEpisode(episodes: [first], history: history, selectedURL: "two")?.url == "one")
        let ref = try FileResourceReference(serviceID: UUID(), path: "/movie.mkv")
        let record = MediaRecord(reference: ref, entry: .init(path: ref.path, name: "movie.mkv", isDirectory: false, size: 4_655_999_552),
                                 groupKey: "movie", filenameMetadata: .init(title: "影片"))
        let summary = NASMediaDetailPresentation.fileSummary(record)
        #expect(summary.contains("MKV") && !summary.contains("4K") && !summary.contains("HDR"))
        #expect(NASMediaDetailPresentation.fileSummary(nil).isEmpty)
        #expect(NASMediaDetailPresentation.title(metadata: .init(title: "单集名", kind: .television, showTitle: "剧名"), fallback: "文件名") == "剧名")
    }

    @Test func movieVersionsRemainSeparatePlaybackSeries() throws {
        let service = UUID(), library = UUID()
        let records = try ["movie-1080.mkv", "movie-2160.mkv"].map { name in
            let ref = try FileResourceReference(serviceID: service, libraryID: library, path: "/" + name)
            return MediaRecord(reference: ref, entry: .init(path: ref.path, name: name, isDirectory: false), groupKey: "movie",
                               filenameMetadata: .init(title: "影片", kind: .movies))
        }
        let vod = MediaLibraryPresentation.vod(record: records[0], group: records, site: .init())
        let episodes = try #require(vod.parseFlags().first).episodes
        #expect(episodes.count == 2)
        #expect(Set(episodes.compactMap { $0.series?.id }).count == 2)
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_NAS_DETAIL_LAYOUT_OUTPUT"] == nil))
    func nativeMovieTVAndMissingMetadataAtDesktopSizes() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_NAS_DETAIL_LAYOUT_OUTPUT"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore())
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory.appendingPathComponent("storage")),
            userPreferences: preferences, providerRuntimeBootstrap: nil)
        let service = FileServiceConfiguration(name: "家庭 NAS", kind: .smb, address: "smb://nas.local", rootPath: "/", share: "媒体")
        state.activeSite = service.site()
        let artwork = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/design/nas-detail-ui/assets")
        for scenario in ["movie", "tv", "missing"] {
            let television = scenario == "tv", missing = scenario == "missing"
            var metadata = missing ? MediaMetadata(title: "未匹配影片", kind: .movies) : MediaMetadata(
                title: television ? "庆余年" : "A计划续集", originalTitle: television ? "Joy of Life" : "Project A Part II", year: television ? 2024 : 1987,
                kind: television ? .television : .movies, showTitle: television ? "庆余年" : nil,
                plot: "本片由成龙自编自导自演，集结张曼玉、关之琳、刘嘉玲等群星主演。故事背景设定于清末香港，警官马如龙奉命接管西环治安，与地方势力展开一场惊险、幽默的冒险。",
                tmdbID: "21521", tmdbRating: 7.1, genres: ["动作", "喜剧"], runtimeMinutes: 106, releaseDate: "1987-08-19",
                countries: ["中国香港"], languages: ["粤语"], studios: ["嘉禾影业"], directors: ["成龙"], writers: ["成龙", "邓景生"],
                cast: ["成龙", "张曼玉", "关之琳", "刘嘉玲", "董骠", "林威", "吕良伟", "陈惠敏"].map { .init(name: $0, role: "角色") })
            if !missing {
                metadata.poster = artwork.appendingPathComponent(television ? "joy-of-life-s2-poster.jpg" : "project-a-ii-poster.jpg").absoluteString
                metadata.fanart = artwork.appendingPathComponent(television ? "joy-of-life-s2-backdrop.jpg" : "project-a-ii-backdrop.jpg").absoluteString
                for (index, filename) in ["jackie-chan.jpg", "maggie-cheung.jpg", "rosamund-kwan.png", "carina-lau.jpg"].enumerated() {
                    metadata.cast?[index].portrait = artwork.appendingPathComponent(filename).absoluteString
                }
                if television {
                    metadata.plot = "范闲在庆国经历重重考验。本地渲染测试使用示例文件与观看状态，影片资料不写入真实媒体库。"
                    metadata.genres = ["剧情", "古装"]; metadata.runtimeMinutes = 45
                    metadata.tmdbID = nil; metadata.tmdbRating = nil; metadata.releaseDate = "2024-05-16"
                    metadata.directors = nil; metadata.writers = nil; metadata.studios = nil
                    metadata.countries = ["中国"]; metadata.languages = ["普通话"]
                    metadata.cast = [MediaCastMember(name: "张若昀", role: "范闲", portrait: artwork.appendingPathComponent("zhang-ruoyun.png").absoluteString)]
                } else {
                    metadata.cast = (metadata.cast ?? []) + (1...16).map { MediaCastMember(name: "演员样例 \($0)", role: "角色") }
                }
            }
            let library = UUID()
            let records = try (1...(television ? 12 : 1)).map { number in
                let season = number > 8 ? 2 : 1, episode = number > 8 ? number - 8 : number
                let name = television ? "庆余年.S0\(season)E\(episode).mkv" : "\(metadata.title!).mkv"
                let ref = try FileResourceReference(serviceID: service.id, libraryID: library, path: "/电影/" + name)
                var fields = metadata
                if television { fields.season = number > 8 ? 2 : 1; fields.episode = number > 8 ? number - 8 : number }
                return MediaRecord(reference: ref, entry: .init(path: ref.path, name: name, isDirectory: false, size: 4_655_999_552),
                    groupKey: "fixture", filenameMetadata: fields)
            }
            let vod = MediaLibraryPresentation.vod(record: records[0], group: records, site: service.site())
            state.detailVod = vod; state.applyPlaybackAvailability(for: vod)
            for size in [CGSize(width: 960, height: 720), CGSize(width: 1200, height: 675), CGSize(width: 1480, height: 833), CGSize(width: 1600, height: 900)] {
                let content = NASMediaDetailContent(vod: vod, size: size, metadata: metadata, files: records,
                    serviceName: service.name, libraryName: television ? "电视剧" : "电影", canEdit: true)
                    .environmentObject(state).environment(\.appThemePalette, state.appearancePalette).preferredColorScheme(.dark)
                try await capture(content, size: size, to: directory.appendingPathComponent("nas-detail-\(scenario)-\(Int(size.width)).png"))
            }
        }
    }

    private func capture<V: View>(_ view: V, size: CGSize, to url: URL) async throws {
        _ = NSApplication.shared
        let content = NSHostingView(rootView: view)
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content; window.setFrame(rect, display: true)
        window.appearance = NSAppearance(named: .darkAqua); window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let scroll = try #require(scrollViews(in: content).max { $0.frame.width < $1.frame.width })
        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        for (suffix, offset) in [("", 0.0), ("-middle", maximum / 2), ("-bottom", maximum)] {
            if suffix == "-middle" {
                scroll.scrollerStyle = .legacy; scroll.hasVerticalScroller = true
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(80))
            content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            #expect(abs(scroll.contentView.bounds.width - size.width) < 1)
            #expect(!scroll.hasVerticalScroller)
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size; content.cacheDisplay(in: content.bounds, to: bitmap)
            let destination = url.deletingPathExtension().appendingPathExtension("png")
            let named = suffix.isEmpty ? destination : url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix + ".png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: named, options: .atomic)
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
