import AppKit
import Foundation
import Testing
import Models
import Storage
import ApplicationCore
import MediaServerEngine
@testable import NetVplayerApp

@Suite(.serialized)
struct MediaServerBrowsingTests {
    @MainActor
    @Test func folderCardsNavigateAndReturnWithoutOpeningDetails() async throws {
        let account = MediaServerConfiguration(name: "Navigation fixture", server: "https://server.invalid")
        let site = account.site()
        let app = AppState(loadDefaultConfig: false, startProxyServer: false)
        app.activeSite = site
        let root = VodClass(typeId: "movies", typeName: "Movies")
        app.categories = [root]
        app.selectedCategory = root
        let folder = Vod(vodId: try MediaServerReference(accountID: account.id, itemID: "00s").locator,
                         vodName: "00s", siteKey: site.key, isFolder: true)
        // The absent test account makes catalog reads fail immediately, while routing must remain usable.
        await app.openVodCard(folder)
        #expect(app.selectedCategory?.typeId == "00s")
        #expect(app.mediaServerFolderPath.map(\.typeId) == ["movies", "00s"])
        #expect(!app.isDetailPresented && !app.isDetailLoading && app.detailVod == nil)
        await app.refreshCurrentCatalog()
        #expect(app.mediaServerFolderPath.map(\.typeId) == ["movies", "00s"])
        let nested = Vod(vodId: try MediaServerReference(accountID: account.id, itemID: "nested").locator,
                         vodName: "Nested", siteKey: site.key, isFolder: true)
        await app.selectVod(nested)
        #expect(app.mediaServerFolderPath.map(\.typeId) == ["movies", "00s", "nested"])
        #expect(!app.isDetailPresented)
        await app.openMediaServerAncestor(at: 0)
        #expect(app.selectedCategory?.typeId == "movies")
        #expect(app.mediaServerFolderPath.map(\.typeId) == ["movies"])
        await app.openVodCard(folder)
        await app.selectCategory(VodClass(typeId: "tv", typeName: "TV"))
        #expect(app.mediaServerFolderPath.map(\.typeId) == ["tv"])
        await app.loadHomeContent()
        #expect(app.mediaServerFolderPath.isEmpty)
    }

    @Test func folderRoutingKeepsSeriesPlayableAndRejectsAnotherAccount() throws {
        let account = MediaServerConfiguration()
        let locator = try MediaServerReference(accountID: account.id, itemID: "item").locator
        let legacy = Vod(vodId: locator, vodName: "Folder", vodRemarks: "Folder", siteKey: account.siteKey)
        #expect(VodCardRoutingPolicy.mediaServerFolderCategory(site: account.site(), vod: legacy)?.typeId == "item")
        for type in ["Series", "Season", "Movie", "Episode"] {
            let playable = Vod(vodId: locator, vodRemarks: type, siteKey: account.siteKey)
            #expect(VodCardRoutingPolicy.mediaServerFolderCategory(site: account.site(), vod: playable) == nil)
        }
        #expect(VodCardRoutingPolicy.mediaServerFolderCategory(site: MediaServerConfiguration().site(), vod: legacy) == nil)
    }

    @MainActor
    @Test func nativeArtworkPassesThroughImageLoaderAndSharedCacheWithoutExposingCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-poster-" + UUID().uuidString)
        let domain = "NativePosterTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory); ImageLoader.clearMemoryCache() }
        let store = MediaServerStore(storage: StorageManager(storageDirectory: directory.appendingPathComponent("storage")),
            preferences: UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore()))
        let account = MediaServerConfiguration(name: "Poster fixture", kind: .emby, server: "https://poster.invalid/nested", serverID: "server", userID: "user")
        try store.save([account]); try store.saveToken("poster-fixture-token", for: account)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 120,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<120 { for x in 0..<80 { bitmap.setColor(NSColor(deviceRed: x.isMultiple(of: 2) ? 1 : 0, green: 0, blue: x.isMultiple(of: 2) ? 0 : 1, alpha: 1), atX: x, y: y) } }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let fixture = NativePosterFixture(image: png)
        let runtime = MediaServerRuntime(store: store, transport: .init(handler: { request, _ in try await fixture.request(request) }))
        let pipeline = PosterImagePipeline(cacheDirectory: directory.appendingPathComponent("posters"), mediaServerRuntime: runtime)
        let reference = try MediaServerArtworkReference(item: .init(accountID: account.id, itemID: "film"), tag: "tag")
        let parsed = try #require(EmbeddedImageSource.parse(reference.locator))
        #expect(EmbeddedImageSource.parse(reference.locator + "@Cookie=secret") == nil)
        let request = ImageLoader.makeRequest(url: parsed.url, headers: ["Cookie": "unrelated-site-cookie"], timeout: 15)
        #expect(request.allHTTPHeaderFields?.isEmpty != false)
        let key = ImageLoader.cacheKey(url: parsed.url, headers: nil)
        let decoded = try await pipeline.image(request: request, key: key, maxPixelSize: 96)
        #expect(decoded.cgImage.width == 64 && decoded.cgImage.height == 96)
        let enlarged = try await pipeline.image(request: request, key: key, maxPixelSize: 120)
        #expect(enlarged.cgImage.width == 80 && enlarged.cgImage.height == 120)
        #expect(await fixture.imageRequests == 1)
        let loader = ImageLoader(pipeline: pipeline)
        loader.load(from: reference.locator, maxPixelSize: 96)
        let deadline = ContinuousClock.now + .seconds(2)
        while loader.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(loader.image != nil && !loader.isLoading)
        let other = try MediaServerArtworkReference(item: .init(accountID: UUID(), itemID: "film"), tag: "tag")
        #expect(key != ImageLoader.cacheKey(url: URL(string: other.locator)!, headers: nil))
    }
}

private actor NativePosterFixture {
    let image: Data
    var imageRequests = 0
    init(image: Data) { self.image = image }
    func request(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        #expect(!url.absoluteString.contains("poster-fixture-token"))
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        if url.path.hasSuffix("/Images/Primary") {
            imageRequests += 1
            #expect(url.path == "/nested/emby/Items/film/Images/Primary")
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "poster-fixture-token")
            return (image, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
        }
        let json: String
        if url.path.hasSuffix("/System/Info/Public") {
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
            json = #"{"Id":"server"}"#
        } else {
            #expect(url.path.hasSuffix("/Users/user"))
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "poster-fixture-token")
            json = #"{"Id":"user"}"#
        }
        return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
