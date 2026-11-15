import Foundation
import MediaServerEngine
import Models
import Storage
import Testing

@testable import NetVplayerApp

@Suite("Media server saved-login presentation", .serialized) @MainActor
struct MediaServerAccountModelTests {
  @Test func legacySavedLoginLoadsUserWithoutPasswordOrChangingCredentialBinding() async throws {
    let context = try AccountUIContext()
    defer { context.cleanup() }
    let original = context.account
    let model = context.model()
    model.load(checkConnection: false)
    #expect(model.selectedID == original.id && model.state == .saved)
    #expect(model.hasStoredToken && !model.showsLoginFields && model.password.isEmpty)
    model.check()
    try await idle(model)
    #expect(model.state == .signedIn && model.username == "demo-viewer")
    let saved = try #require(context.store.load().first)
    #expect(saved.username == "demo-viewer" && saved.id == original.id)
    #expect(saved.credentialBinding == original.credentialBinding)
    #expect(try context.store.token(for: saved) == "fixture-token")
    #expect(model.password.isEmpty)
  }

  @Test func missingTokenExpiredSessionAndNetworkFailureRemainDistinct() async throws {
    let context = try AccountUIContext()
    defer { context.cleanup() }
    let expired = context.model(failure: .authentication)
    expired.load()
    try await idle(expired)
    #expect(expired.state == .expired && expired.hasStoredToken && expired.showsLoginFields)
    let offline = context.model(failure: .response)
    offline.load()
    try await idle(offline)
    #expect(offline.state == .unavailable && offline.hasStoredToken && !offline.showsLoginFields)
    try context.store.removeToken(for: context.account)
    let missing = context.model()
    missing.load()
    #expect(missing.state == .signedOut && !missing.hasStoredToken && missing.showsLoginFields)
    missing.select(nil)
    #expect(missing.state == .newAccount && missing.server.isEmpty)
  }

  @Test func signingInAndOutRetainsUserButNeverStoresPassword() async throws {
    let context = try AccountUIContext()
    defer { context.cleanup() }
    try context.store.removeToken(for: context.account)
    let model = context.model()
    model.load()
    model.username = "typed-user"
    model.password = "input-only-password"
    var saved = false
    model.connect { saved = true }
    try await idle(model)
    #expect(saved && model.state == .signedIn && !model.showsLoginFields)
    #expect(model.selected?.username == "demo-viewer" && model.password.isEmpty)
    let data = try Data(contentsOf: context.directory.appendingPathComponent("media-servers.json"))
    #expect(!String(decoding: data, as: UTF8.self).contains("input-only-password"))
    model.logout()
    try await idle(model)
    #expect(model.state == .signedOut && !model.hasStoredToken && model.showsLoginFields)
    #expect(context.store.load().first?.username == "demo-viewer")
    #expect((try? context.store.token(for: context.store.load()[0])) == nil)
  }

  @Test func selectionCancelsStaleUserLookupAndServerEditsRequireLogin() async throws {
    let context = try AccountUIContext()
    defer { context.cleanup() }
    let model = context.model(delay: true)
    model.load()
    #expect(model.state == .checking && model.busy)
    model.select(nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.state == .newAccount && !model.busy && model.selectedID == nil)
    #expect(context.store.load().first?.username == nil)
    model.select(context.account.id, checkConnection: false)
    model.server = "https://other.invalid"
    #expect(model.serverChanged && model.showsLoginFields)
  }

  @Test func renamingDoesNotRequirePasswordOrRebindLogin() throws {
    let context = try AccountUIContext()
    defer { context.cleanup() }
    let model = context.model()
    model.load(checkConnection: false)
    model.name = "Renamed server"
    #expect(model.nameChanged && !model.showsLoginFields)
    var refreshed = false
    model.saveName { refreshed = true }
    #expect(refreshed && !model.nameChanged && model.selected?.name == "Renamed server")
    #expect(try context.store.token(for: context.store.load()[0]) == "fixture-token")
  }

  @Test func failedConfigurationSaveRestoresPreviousCredentialBinding() async throws {
    let context = try AccountUIContext()
    defer { context.cleanup() }
    let model = context.model()
    model.load(checkConnection: false)
    model.server = "https://different.invalid"
    model.username = "demo-viewer"
    model.password = "input-only"
    let path = context.directory.appendingPathComponent("media-servers.json")
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    var saved = false
    model.connect { saved = true }
    try await idle(model)
    #expect(!saved && model.statusRole == .danger && model.password.isEmpty)
    #expect(try context.store.token(for: context.account) == "fixture-token")
  }

  @Test func credentialChangeWhileInvalidatingDoesNotCertifyReplacementToken() async throws {
    let context = try AccountUIContext()
    defer { context.cleanup() }
    let model = context.model(invalidate: { _ in
      await MainActor.run {
        if let account = context.store.load().first {
          try? context.store.saveToken("replacement-not-validated", for: account)
        }
      }
    })
    model.load(checkConnection: false)
    model.username = "demo-viewer"
    model.password = "input-only"
    model.connect {}
    try await idle(model)
    let account = try #require(context.store.load().first)
    #expect(try context.store.token(for: account) == "replacement-not-validated")
    let observation = ServiceConnectionObservations.shared.snapshot(context.store.connectionObservationScope(account))
    #expect(observation.state == .unknown && observation.checkedAt == nil)
  }

  private func idle(_ model: MediaServerAccountModel) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while model.busy && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.busy)
  }
}

@MainActor
struct AccountUIContext {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "account-ui-" + UUID().uuidString)
  let domain = "AccountUITests." + UUID().uuidString
  let defaults: UserDefaults
  let store: MediaServerStore
  let account = MediaServerConfiguration(
    name: "Demo Emby", kind: .emby,
    server: "https://server.invalid", serverID: "fixture-server", userID: "fixture-user")
  init() throws {
    defaults = UserDefaults(suiteName: domain)!
    store = MediaServerStore(
      storage: .init(storageDirectory: directory),
      preferences: .init(defaults: defaults, credentialStore: MemoryCredentialStore()))
    try store.save([account])
    try store.saveToken("fixture-token", for: account)
  }
  func model(
    failure: MediaServerError? = nil, delay: Bool = false,
    invalidate: @escaping @Sendable (UUID) async -> Void = { _ in }
  ) -> MediaServerAccountModel {
    .init(
      store: store,
      transport: .init(handler: { request, _ in
        if delay { try await Task.sleep(for: .seconds(1)) }
        if let failure { throw failure }
        let path = request.url!.path
        let object: [String: Any]
        if path.hasSuffix("/System/Info/Public") {
          object = ["Id": "fixture-server"]
        } else if path.hasSuffix("/AuthenticateByName") {
          object = [
            "AccessToken": "fixture-token", "ServerId": "fixture-server",
            "User": ["Id": "fixture-user", "Name": "demo-viewer"],
          ]
        } else {
          object = ["Id": "fixture-user", "Name": "demo-viewer"]
        }
        return (
          try JSONSerialization.data(withJSONObject: object),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }), invalidate: invalidate)
  }
  func cleanup() {
    defaults.removePersistentDomain(forName: domain)
    try? FileManager.default.removeItem(at: directory)
  }
}
