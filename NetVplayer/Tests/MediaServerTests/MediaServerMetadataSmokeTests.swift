import Foundation
import MediaServerEngine
import Models
import SpiderEngine
import Storage
import Testing

/// Opt-in read-only verification against an already configured server. Never starts playback or saves credentials.
@Suite("Configured media server metadata", .serialized)
struct MediaServerMetadataSmokeTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_SERVER_METADATA_SMOKE"] == "1"))
  func readsSessionUserAndRichItemWithoutMutatingAccount() async throws {
    // Shared preferences deliberately use memory credentials under XCTest. Read the existing
    // local vault explicitly, with an isolated preference domain and no legacy import reader.
    let domain = "MetadataReadOnlySmoke." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = MediaServerStore(
      preferences: .init(defaults: defaults, credentialStore: LocalCredentialStore()))
    let before = store.load()
    let account = try #require(before.first { (try? store.token(for: $0)) != nil })
    let token = try store.token(for: account)
    let client = try MediaServerClient(account: account, token: token)
    let user = try await client.sessionUser()
    #expect(user.Id == account.userID)
    let search =
      ProcessInfo.processInfo.environment["NETVPLAYER_SERVER_METADATA_SEARCH"] ?? "The 5th Wave"
    let page = try await client.items(parent: nil, page: 1, search: search)
    let itemID = try #require(page.Items?.first(where: { !$0.isBrowsableFolder })?.Id)
    let item = try await client.item(itemID)
    let reference = try MediaServerReference(accountID: account.id, itemID: itemID)
    let runtime = MediaServerRuntime(store: store)
    let provider = MediaServerNativeProvider(accountID: account.id, runtime: runtime)
    let response = try await provider.detailContent(site: account.site(), id: reference.locator)
    let vod = try #require(response.list.first)
    let detail = try #require(vod.mediaServerDetail)
    #expect(detail.metadata.title == item.Name)
    #expect(detail.metadata.genres == item.Genres)
    #expect(detail.rating == item.CommunityRating)
    #expect(detail.files.count == min(item.MediaSources?.count ?? 0, 32))
    var imageChecks = 0
    for value in [
      detail.metadata.poster, detail.metadata.fanart, detail.metadata.cast?.first?.portrait,
    ].compactMap({ $0 }) {
      let image = try #require(MediaServerArtworkReference(locator: value))
      let data = try await runtime.artwork(image)
      #expect(!data.isEmpty)
      imageChecks += 1
    }
    #expect(store.load() == before)
    #expect(try store.token(for: account) == token)
    let result: [String: Any] = [
      "readOnly": true, "kind": account.kind.rawValue,
      "sessionValidated": true, "usernameReturned": !(user.Name ?? "").isEmpty,
      "overviewReturned": !(item.Overview ?? "").isEmpty,
      "originalTitleReturned": !(item.OriginalTitle ?? "").isEmpty,
      "genreCount": detail.metadata.genres?.count ?? 0,
      "castCount": detail.metadata.cast?.count ?? 0,
      "directorCount": detail.metadata.directors?.count ?? 0,
      "ratingReturned": detail.rating != nil,
      "runtimeReturned": detail.metadata.runtimeMinutes != nil,
      "fileCount": detail.files.count,
      "authenticatedImagesVerified": imageChecks,
      "accountUnchanged": store.load() == before,
      "passwordReadOrSaved": false, "playbackStarted": false,
    ]
    if let path = ProcessInfo.processInfo.environment["NETVPLAYER_SERVER_METADATA_REPORT"] {
      try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    print(
      "[SERVER_METADATA] readOnly=true sessionValidated=true richMapping=true images=\(imageChecks) accountUnchanged=true"
    )
  }
}
