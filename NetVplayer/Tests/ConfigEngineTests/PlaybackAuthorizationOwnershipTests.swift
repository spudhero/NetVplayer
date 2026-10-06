import Foundation
import Testing
import Models
import DriveEngine
import Storage
import SpiderEngine
@testable import NetVplayerApp

@Suite(.serialized)
struct PlaybackAuthorizationOwnershipTests {
    @MainActor
    @Test(arguments: ["source", "film", "line", "close", "cancel", "replacement"])
    func lateAuthorizationNeverResumesChangedContext(change: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = fixture(directory: directory)
        let gate = AuthorizationValidationGate()
        state.cloudAuthCredentialOperation = { _, _, _ in await gate.validate() }
        var starts = 0
        state.playSpecHandler = { _ in starts += 1 }
        let episode = Episode(name: "1", url: "first")
        state.handlePlaybackError(DriveEngineError.loginRequired(.quark), episode: episode)
        let request = try #require(state.cloudAuthRequest)
        let task = Task {
            try? await state.completeCloudAuth(credential: .cookie(provider: .quark, value: "fixture"), requestID: request.id)
        }
        await gate.waitForStart()
        switch change {
        case "source":
            let changed = Site(key: state.activeSite!.key, name: "Changed", type: 3, api: "csp_Changed")
            state.sites = [changed]; state.activeSite = changed
        case "film": state.detailVod = Vod(vodId: "another-film")
        case "line": state.selectedPlayFlag = "other-line"
        case "close": state.isPlayerPresented = false
        case "replacement": state.requestCloudAuthFromSettings(.uc)
        default: state.cloudAuthRequest = nil // Covers interactive sheet dismissal.
        }
        state.playbackErrorMessage = "current operation"
        let newerRequestID = state.cloudAuthRequest?.id
        await gate.finish()
        _ = await task.value
        #expect(starts == 0)
        #expect(state.playbackErrorMessage == "current operation")
        if change == "replacement" { #expect(state.cloudAuthRequest?.id == newerRequestID) }
    }

    @MainActor
    @Test func duplicateSuccessClaimsTheOriginalEpisodeOnlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = fixture(directory: directory)
        let provider = AuthorizationPlaybackProvider()
        await SpiderReplacementRegistry.shared.register(originalAPI: state.activeSite!.api, provider: provider)
        let gate = AuthorizationValidationGate()
        state.cloudAuthCredentialOperation = { _, _, _ in await gate.validate() }
        var starts = 0
        state.playSpecHandler = { _ in starts += 1 }
        state.handlePlaybackError(DriveEngineError.loginRequired(.quark), episode: Episode(name: "1", url: "first"))
        let request = try #require(state.cloudAuthRequest)
        let credential = CloudCredential.cookie(provider: .quark, value: "fixture")
        let first = Task { try await state.completeCloudAuth(credential: credential, requestID: request.id) }
        await gate.waitForStart()
        do {
            _ = try await state.completeCloudAuth(credential: credential, requestID: request.id)
            Issue.record("Duplicate validation must be rejected")
        } catch is CancellationError {} // The original validation remains owned.
        await gate.finish()
        _ = try await first.value
        do {
            _ = try await state.completeCloudAuth(credential: credential, requestID: request.id)
            Issue.record("A retired authorization must not resolve twice")
        } catch is CancellationError {}
        #expect(starts == 1)
        let requests = await provider.requests
        #expect(requests == ["first"])
        #expect(state.cloudAuthRequest == nil)
    }

    @MainActor
    private func fixture(directory: URL) -> AppState {
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
        let site = Site(key: UUID().uuidString, name: "Auth fixture", type: 3, api: "csp_Auth_\(UUID().uuidString)")
        state.sites = [site]; state.activeSite = site
        state.detailVod = Vod(vodId: "film", siteKey: site.key)
        state.selectedPlayFlag = "line"
        state.episodes = [Episode(name: "1", url: "first")]
        state.isPlayerPresented = true
        return state
    }
}

private actor AuthorizationValidationGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<CloudAuthCompletion, Never>?
    func validate() async -> CloudAuthCompletion {
        await withCheckedContinuation {
            result = $0; started = true
            waiter?.resume(); waiter = nil
        }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { result?.resume(returning: .dismiss()); result = nil }
}

private actor AuthorizationPlaybackProvider: SiteContentProvider {
    private(set) var requests: [String] = []
    func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        requests.append(id)
        return Result(url: "https://media.example.test/episode.mp4", format: "mp4")
    }
    func homeContent(site: Site) async throws -> Result { .empty }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result { .empty }
    func detailContent(site: Site, id: String) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}
