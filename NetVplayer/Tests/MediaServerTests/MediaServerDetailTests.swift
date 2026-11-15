import Foundation
import MediaServerEngine
import Models
import SpiderEngine
import Storage
import Testing

@Suite("Media server rich detail contracts", .serialized)
struct MediaServerDetailTests {
  @Test func oldConfigurationsDecodeAndUserDisplayDoesNotRebindToken() throws {
    let account = MediaServerConfiguration(
      server: "https://server.invalid", serverID: "server", userID: "user")
    var old =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as! [String: Any]
    old.removeValue(forKey: "username")
    let decoded = try JSONDecoder().decode(
      MediaServerConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(decoded.username == nil && decoded.id == account.id)
    var named = decoded
    named.username = "demo-viewer"
    #expect(named.credentialBinding == decoded.credentialBinding)
    #expect(named.identity(itemID: "film") == decoded.identity(itemID: "film"))
  }

  @Test(arguments: [MediaServerKind.emby, .jellyfin])
  func providerKeepsRichMetadataAndOpaqueAuthenticatedImages(_ kind: MediaServerKind) async throws {
    let context = try DetailContractContext(kind: kind)
    defer { context.cleanup() }
    let fixture = DetailContractFixture()
    let runtime = MediaServerRuntime(
      store: context.store,
      transport: .init(handler: { request, _ in try await fixture.request(request) }))
    let provider = MediaServerNativeProvider(accountID: context.account.id, runtime: runtime)
    let reference = try MediaServerReference(accountID: context.account.id, itemID: "film")
    let vod = try #require(
      try await provider.detailContent(site: context.account.site(), id: reference.locator).list
        .first)
    let detail = try #require(vod.mediaServerDetail)
    #expect(
      detail.metadata.title == "Example Movie" && detail.metadata.originalTitle == "Original Title")
    #expect(
      detail.metadata.genres == ["Drama", "Adventure"] && detail.metadata.runtimeMinutes == 120)
    #expect(detail.rating == 7.2 && detail.metadata.tmdbRating == nil)
    #expect(
      detail.metadata.directors == ["Demo Director"]
        && detail.metadata.cast?.first?.role == "Cassie")
    #expect(
      detail.metadata.releaseDate == "2016-01-14" && detail.metadata.countries == ["United States"])
    #expect(detail.files.first?.width == 3840 && detail.files.first?.height == 2160)
    #expect(detail.files.first?.audio == ["English · E-AC-3 5.1"])
    #expect(detail.files.first?.subtitles == ["English · SRT"])
    let backdropLocator = try #require(detail.metadata.fanart)
    let backdrop = try #require(MediaServerArtworkReference(locator: backdropLocator))
    #expect(backdrop.kind == .backdrop)
    let portraitLocator = try #require(detail.metadata.cast?.first?.portrait)
    let portrait = try #require(MediaServerArtworkReference(locator: portraitLocator))
    #expect(portrait.item.itemID == "actor" && portrait.kind == .primary)
    _ = try await runtime.artwork(backdrop)
    _ = try await runtime.artwork(portrait)
    #expect(await fixture.imagePaths.contains { $0.hasSuffix("/Images/Backdrop") })
    let encoded = try JSONEncoder().encode(vod)
    let restored = try JSONDecoder().decode(Vod.self, from: encoded)
    #expect(restored.mediaServerDetail?.metadata == detail.metadata)
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(!json.contains("fixture-token") && !json.contains("private-server-path"))
    #expect(vod.parseFlags().first?.episodes.first?.url == reference.locator)
    #expect(await fixture.requestedDetailFields.contains("People"))
  }

  @Test(arguments: [MediaServerKind.emby, .jellyfin])
  func seriesUsesSeasonsAndKeepsEpisodeMetadata(_ kind: MediaServerKind) async throws {
    let context = try DetailContractContext(kind: kind)
    defer { context.cleanup() }
    let fixture = DetailContractFixture()
    let runtime = MediaServerRuntime(
      store: context.store,
      transport: .init(handler: { request, _ in try await fixture.request(request) }))
    let provider = MediaServerNativeProvider(accountID: context.account.id, runtime: runtime)
    let reference = try MediaServerReference(accountID: context.account.id, itemID: "series")
    let vod = try #require(
      try await provider.detailContent(site: context.account.site(), id: reference.locator).list
        .first)
    let flags = vod.parseFlags()
    #expect(flags.count == 2 && flags.map(\.episodes.count) == [1, 1])
    #expect(flags[0].episodes[0].season == 1 && flags[1].episodes[0].season == 2)
    #expect(flags[0].episodes[0].overview == "Episode overview")
    #expect(flags[0].episodes[0].released == "2024-01-01")
    #expect(vod.mediaServerDetail?.metadata.kind == .television)
    #expect(await fixture.requestedSeriesFields.contains("MediaSources"))
  }

  @Test func missingMetadataAndLegacyArtworkStayUsable() throws {
    let legacy = try JSONDecoder().decode(
      Vod.self, from: Data(#"{"vod_id":"legacy","vod_name":"Untitled"}"#.utf8))
    #expect(legacy.mediaServerDetail == nil && legacy.vodName == "Untitled")
    let item = try MediaServerReference(accountID: UUID(), itemID: "film")
    let primary = try MediaServerArtworkReference(item: item, tag: "tag")
    #expect(MediaServerArtworkReference(locator: primary.locator) == primary)
    #expect(MediaServerArtworkReference(locator: primary.locator + "/Backdrop")?.kind == .backdrop)
    #expect(MediaServerArtworkReference(locator: primary.locator + "/Other") == nil)
    #expect(MediaServerArtworkReference(locator: primary.locator + "/Backdrop?token=x") == nil)
  }
}

private struct DetailContractContext {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "server-detail-contract-" + UUID().uuidString)
  let defaults: UserDefaults
  let domain = "ServerDetailTests." + UUID().uuidString
  let store: MediaServerStore
  let account: MediaServerConfiguration
  init(kind: MediaServerKind) throws {
    defaults = UserDefaults(suiteName: domain)!
    store = .init(
      storage: .init(storageDirectory: directory),
      preferences: .init(defaults: defaults, credentialStore: MemoryCredentialStore()))
    account = .init(
      name: "Demo Server", kind: kind, server: "https://server.invalid", serverID: "server",
      userID: "user")
    try store.save([account])
    try store.saveToken("fixture-token", for: account)
  }
  func cleanup() {
    defaults.removePersistentDomain(forName: domain)
    try? FileManager.default.removeItem(at: directory)
  }
}

private actor DetailContractFixture {
  var imagePaths: [String] = []
  var requestedDetailFields = ""
  var requestedSeriesFields = ""
  func request(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let path = url.path
    let payload: String
    var contentType = "application/json"
    if path.hasSuffix("/System/Info/Public") {
      payload = #"{"Id":"server"}"#
    } else {
      #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token")
      #expect(!url.absoluteString.contains("fixture-token"))
      if path.hasSuffix("/Users/user") || path.hasSuffix("/Users/Me") {
        payload = #"{"Id":"user","Name":"demo-viewer"}"#
      } else if path.contains("/Images/") {
        imagePaths.append(path)
        payload = "synthetic image"
        contentType = "image/png"
      } else if path.hasSuffix("/Episodes") {
        requestedSeriesFields =
          URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "Fields"
          }?.value ?? ""
        payload =
          #"{"Items":[{"Id":"one","Name":"First","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1,"Overview":"Episode overview","PremiereDate":"2024-01-01T00:00:00Z"},{"Id":"two","Name":"Second","Type":"Episode","IndexNumber":1,"ParentIndexNumber":2}],"TotalRecordCount":2}"#
      } else if path.hasSuffix("/Items/series") {
        payload = #"{"Id":"series","Name":"Demo Show","Type":"Series"}"#
      } else {
        requestedDetailFields =
          URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "Fields"
          }?.value ?? ""
        payload =
          #"{"Id":"film","Name":"Example Movie","OriginalTitle":"Original Title","Type":"Movie","Overview":"A supplied plot","ProductionYear":2016,"PremiereDate":"2016-01-14T00:00:00Z","RunTimeTicks":72000000000,"Genres":["Drama","Adventure"],"CommunityRating":7.2,"OfficialRating":"PG-13","ProductionLocations":["United States"],"Studios":[{"Name":"Demo Studio"}],"Taglines":["A new beginning"],"ProviderIds":{"Tmdb":"299687"},"People":[{"Id":"actor","Name":"Demo Actor","Type":"Actor","Role":"Cassie","PrimaryImageTag":"portrait"},{"Name":"Demo Director","Type":"Director"}],"ImageTags":{"Primary":"poster"},"BackdropImageTags":["backdrop"],"MediaSources":[{"Id":"source","Name":"Main version","Path":"/private-server-path/film.mkv","Container":"mkv","Size":1000000000,"MediaStreams":[{"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"VideoRangeType":"DOVI"},{"Type":"Audio","Codec":"eac3","Language":"eng","Channels":6,"DisplayTitle":"English · E-AC-3 5.1"},{"Type":"Subtitle","Codec":"srt","Language":"eng","DisplayTitle":"English · SRT"}]}]}"#
      }
    }
    return (
      Data(payload.utf8),
      HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType])!
    )
  }
}
