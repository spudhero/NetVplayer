import Foundation
import Testing
import Models
import Storage
import ApplicationCore
@testable import SpiderEngine
@testable import NetVplayerApp

private let hostHash = "0123456789abcdef0123456789abcdef01234567"
private let hostURI = "magnet:?xt=urn:btih:" + hostHash + "&dn=Original&tr=https%3A%2F%2Ftracker.invalid%2Fannounce"

@Suite(.serialized)
struct HostMagnetContractTests {
    @Test func originalAuditNeverExpandsSDKBusinessEpisodes() {
        let site = Site(key: "fixture-sixv", type: 3, api: "csp_SixVGuard")
        let episode = Episode(name: "Original", url: hostURI)
        #expect(!DevelopmentAndroidMagnetAudit.requiresNativeExpansion(episode, site: site, backend: .androidOriginal))
        #expect(DevelopmentAndroidMagnetAudit.requiresNativeExpansion(episode, site: site, backend: nil))
    }

    @Test func canonicalHashAndInvalidTopics() throws {
        #expect(MagnetURI.infoHash(in: hostURI) == hostHash)
        #expect(MagnetURI.infoHash(in: "MAGNET:?XT=URN:BTIH:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") == String(repeating: "0", count: 40))
        #expect(MagnetURI.infoHash(in: "magnet:?xt=urn:btih:77777777777777777777777777777777") == String(repeating: "f", count: 40))
        for invalid in ["magnet:?xt=not-btih:" + hostHash, hostURI + "&xt=urn:btih:bad", hostURI + "&xt=urn:btih:" + String(repeating: "f", count: 40), hostURI + "#fragment", "magnet:path?xt=urn:btih:" + hostHash] {
            #expect(MagnetURI.infoHash(in: invalid) == nil)
        }
    }

    @Test func fileIdentityIsStableAndCannotEnterThroughProviderJSON() throws {
        let files = try hostFiles()
        let result = try HostMagnetPlaybackResolver.prepared(Result(url: hostURI), leaseID: UUID(), files: files, resumeFile: nil)
        let otherPort = try hostFiles(port: 32124)
        let reloaded = try HostMagnetPlaybackResolver.prepared(Result(url: hostURI), leaseID: UUID(), files: otherPort, resumeFile: nil)
        #expect(result.playbackCandidates.map(\.id) == reloaded.playbackCandidates.map(\.id))
        #expect(Set(result.playbackCandidates.map(\.id)).count == 2)
        #expect(files[0].identity.mediaIdentity != files[1].identity.mediaIdentity)
        let wire = try JSONEncoder().encode(result)
        #expect(!String(decoding: wire, as: UTF8.self).contains("hostMagnet"))
        var injected = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        injected["hostMagnet"] = ["leaseID": UUID().uuidString, "selectedFile": ["infoHash": hostHash]]
        let decoded = try JSONDecoder().decode(Result.self, from: JSONSerialization.data(withJSONObject: injected))
        #expect(decoded.hostMagnet == nil)
        var forged = result.playbackCandidates[0]
        forged.url = "http://127.0.0.1:9999/forged"
        #expect(result.hostMagnet?.selecting(forged) == nil)
    }

    @Test func historyExactFileChangedFileAndLegacyCompatibility() throws {
        let files = try hostFiles()
        let exact = try HostMagnetPlaybackResolver.prepared(Result(url: hostURI), leaseID: UUID(), files: files, resumeFile: files[1].identity)
        #expect(exact.playbackCandidates.map(\.id) == [files[1].identity.candidateID])
        #expect(exact.hostMagnet?.selecting(exact.playbackCandidates[0])?.canResumeSelectedFile == true)
        let missing = try #require(MagnetFileIdentity(infoHash: hostHash, fileIndex: 2, length: 999))
        #expect(throws: (any Error).self) {
            try HostMagnetPlaybackResolver.prepared(Result(url: hostURI), leaseID: UUID(), files: files, resumeFile: missing)
        }
        let saved = History(key: "fixture", episodeUrl: hostURI, position: 88000, duration: 120000, magnet: files[1].identity)
        let bytes = try JSONEncoder().encode(HistoryPersistencePolicy.sanitized(saved))
        let decoded = try JSONDecoder().decode(History.self, from: bytes)
        #expect(decoded.magnet == files[1].identity)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("tracker.invalid"))
        #expect(try JSONDecoder().decode(History.self, from: Data("{}".utf8)).magnet == nil)
        #expect(try JSONDecoder().decode(History.self, from: Data("{\"magnet\":{\"infoHash\":\"bad\",\"fileIndex\":-1,\"length\":0}}".utf8)).magnet == nil)
        var changed = saved
        changed.magnet = files[0].identity
        changed.position = 0; changed.duration = 0
        let state = ApplicationLibraryState(history: [saved])
        let new = ApplicationLibraryCore.recordHistory(state, record: changed, preservingPlaybackPreferences: true).state.history[0]
        #expect(new.position == 0 && new.duration == 0)
    }

    @Test func rejectsInvalidBridgeFiles() throws {
        let valid = SixVMagnetPlaybackFile(index: 7, name: "same.mp4", length: 100,
            url: URL(string: "http://127.0.0.1:32123/stream/7/same.mp4")!)
        for invalid in [
            SixVMagnetPlaybackFile(index: 7, name: valid.name, length: 0, url: valid.url),
            SixVMagnetPlaybackFile(index: -1, name: valid.name, length: 100, url: valid.url),
            SixVMagnetPlaybackFile(index: 1, name: valid.name, length: 100, url: valid.url),
            SixVMagnetPlaybackFile(index: 7, name: valid.name, length: 100, url: URL(string: "http://remote.invalid:32123/stream/7/same.mp4")!),
            SixVMagnetPlaybackFile(index: 7, name: valid.name, length: 100, url: URL(string: "http://127.0.0.1:32123/stream/7/same.mp4?token=secret")!)
        ] { #expect(throws: (any Error).self) { try HostMagnetPlaybackResolver.files([invalid], infoHash: hostHash) } }
        #expect(throws: (any Error).self) { try HostMagnetPlaybackResolver.files([valid, valid], infoHash: hostHash) }
    }

    @MainActor @Test func selectionCallsProviderOnceAndKeepsOriginalEpisodeHistory() async throws {
        let fixture = try await HostAppFixture()
        let state = fixture.state
        var submissions: [PlaySpec] = []
        state.playSpecHandler = { spec in
            try? await Task.sleep(for: .milliseconds(20))
            state.playerState.currentSpec = spec; submissions.append(spec)
        }
        await state.playEpisode(fixture.episode, resumePosition: 88000, resumeDuration: 120000)
        let selection = try #require(state.pendingPlaybackSelection)
        #expect(selection.episode.url == fixture.episode.url)
        #expect(selection.candidates.count == 2 && submissions.isEmpty)
        await state.selectPlaybackCandidate(selection.candidates[1])
        #expect(await fixture.provider.calls() == ["original-line\u{0}original-opaque-episode"])
        let spec = try #require(submissions.first)
        #expect(spec.hostMagnet?.selectedFile?.identity.fileIndex == 7)
        #expect(spec.mediaIdentity == spec.hostMagnet?.selectedFile?.identity.mediaIdentity)
        #expect(spec.initialStartPositionSeconds == nil || spec.initialStartPositionSeconds == 0)
        #expect(spec.metadata["vod.episodeURL"] == fixture.episode.url)
        #expect(state.episodes.map(\.url) == [fixture.episode.url])
        #expect(state.historyItems.first?.magnet?.fileIndex == 7)
        #expect(state.historyItems.first?.position == 0)
        state.playerState.position = 19; state.playerState.duration = 120
        state.saveCurrentPlaybackProgress()
        #expect(state.historyItems.first?.magnet?.fileIndex == 7)
        #expect(state.historyItems.first?.position == 19000)
        state.handleMPVPlaybackFailure(spec: spec, message: "Synthetic decode failure")
        await fixture.resolver.waitForReleases(1)
        state.isPlayerPresented = false
        await fixture.resolver.waitForReleases(1)
        #expect(await fixture.resolver.releaseCount() >= 1)
    }

    @MainActor @Test func exactResumeAndManualChangeResetProgress() async throws {
        let fixture = try await HostAppFixture()
        let files = try hostFiles()
        var submitted: PlaySpec?
        fixture.state.playSpecHandler = { spec in
            try? await Task.sleep(for: .milliseconds(20))
            fixture.state.playerState.currentSpec = spec; submitted = spec
        }
        await fixture.state.playEpisode(fixture.episode, resumePosition: 88000, resumeDuration: 120000,
                                        resumeMagnetFile: files[1].identity)
        #expect(fixture.state.pendingPlaybackSelection == nil)
        #expect(submitted?.hostMagnet?.selectedFile?.identity == files[1].identity)
        #expect(submitted?.initialStartPositionSeconds == 88)
        await fixture.state.playEpisode(fixture.episode, resumePosition: 88000, resumeDuration: 120000, restartFromBeginning: true)
        let selection = try #require(fixture.state.pendingPlaybackSelection)
        await fixture.state.selectPlaybackCandidate(selection.candidates[0])
        #expect(submitted?.hostMagnet?.selectedFile?.identity == files[0].identity)
        #expect(submitted?.initialStartPositionSeconds == nil || submitted?.initialStartPositionSeconds == 0)
        #expect(fixture.state.historyItems.first?.position == 0)
        fixture.state.isPlayerPresented = false
    }

    @MainActor @Test(arguments: ["dismiss", "cancel", "replace", "close"])
    func pendingSelectionReleasesWithoutStoppingCurrentFile(action: String) async throws {
        let fixture = try await HostAppFixture()
        let old = PlaySpec(url: "http://127.0.0.1:31111/old.mp4")
        fixture.state.playerState.currentSpec = old
        fixture.state.isPlayerPresented = true
        await fixture.state.playEpisode(fixture.episode)
        #expect(fixture.state.pendingPlaybackSelection != nil)
        switch action {
        case "dismiss": fixture.state.pendingPlaybackSelection = nil
        case "cancel": await fixture.state.cancelLoading()
        case "replace": await fixture.state.playEpisode(Episode(name: "other", url: "other"))
        default: fixture.state.isPlayerPresented = false
        }
        await fixture.resolver.waitForReleases(1)
        #expect(await fixture.resolver.releaseCount() >= 1)
        #expect(fixture.state.playerState.currentSpec?.url == old.url)
        if action == "replace" { fixture.state.dismissPlaybackSelection() }
    }

    @MainActor @Test(arguments: ["cancelTask", "cancelLoading", "newEpisode"])
    func lateHostPreparationReleasesStaleLease(action: String) async throws {
        let fixture = try await HostAppFixture(deferred: true)
        let task = Task { await fixture.state.playEpisode(fixture.episode) }
        await fixture.resolver.waitUntilRequested()
        if action == "cancelTask" { task.cancel() }
        if action == "cancelLoading" { await fixture.state.cancelLoading() }
        if action == "newEpisode" {
            await fixture.resolver.setDeferred(false)
            await fixture.state.playEpisode(Episode(name: "new", url: "new"))
        }
        // Deliberately ignores cancellation, exercising the App's stale-result cleanup.
        await fixture.resolver.complete()
        await task.value
        await fixture.resolver.waitForReleases(1)
        #expect(await fixture.resolver.releaseCount() >= 1)
        if action != "newEpisode" { #expect(fixture.state.pendingPlaybackSelection == nil) }
        fixture.state.dismissPlaybackSelection()
    }

    @Test func sharedBridgeLeasesAndNativeSelection() async throws {
        let fixture = try BridgeProcessFixture(delay: 0.25)
        let first = Task { try await fixture.bridge.acquireFiles(for: hostURI) }
        let second = Task { try await fixture.bridge.acquireFiles(for: hostURI) }
        let a = try await first.value; let b = try await second.value
        #expect(a.id != b.id && a.files.map(\.url) == b.files.map(\.url))
        #expect(try fixture.processIDs().count == 1)
        await fixture.bridge.release(a.id)
        #expect(try fixture.isRunning())
        await fixture.bridge.release(b.id)
        try await fixture.waitUntilStopped()
        let native = try BridgeProcessFixture()
        let selected = try await native.bridge.playbackURL(for: hostURI + "&netvplayer_file=7")
        #expect(selected.path == "/stream/7/same.mp4")
        let lease = try await native.bridge.acquireFiles(for: hostURI)
        await native.bridge.release(lease.id)
        #expect(try native.isRunning())
        native.stop()
    }

    @Test(arguments: [false, true]) func cancellationDoesNotCancelOtherWaiters(all: Bool) async throws {
        let fixture = try BridgeProcessFixture(delay: 0.6)
        let first = Task { try await fixture.bridge.acquireFiles(for: hostURI) }
        let second = Task { try await fixture.bridge.acquireFiles(for: hostURI) }
        try await fixture.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(40))
        first.cancel()
        if all { second.cancel() }
        do { _ = try await first.value; Issue.record("Cancelled waiter returned a lease") } catch is CancellationError {} catch { throw error }
        if all {
            do { _ = try await second.value; Issue.record("Cancelled waiter returned a lease") } catch is CancellationError {} catch { throw error }
        } else {
            let lease = try await second.value
            #expect(try fixture.isRunning())
            await fixture.bridge.release(lease.id)
        }
        try await fixture.waitUntilStopped()
        #expect(try fixture.processIDs().count == 1)
    }

    @Test func missingResumeFileReleasesPreparedBridge() async throws {
        let fixture = try BridgeProcessFixture()
        let resolver = HostMagnetPlaybackResolver(bridge: fixture.bridge)
        let missing = try #require(MagnetFileIdentity(infoHash: hostHash, fileIndex: 99, length: 1000))
        do { _ = try await resolver.prepare(Result(url: hostURI), resumeFile: missing); Issue.record("Accepted missing resume file") }
        catch { #expect(error is WebTorrentMagnetPlaybackError) }
        try await fixture.waitUntilStopped()
    }

    @Test func wrongMetadataHashFailsAndReleasesProcess() async throws {
        let fixture = try BridgeProcessFixture(wrongHash: true)
        do { _ = try await fixture.bridge.acquireFiles(for: hostURI); Issue.record("Accepted mismatched metadata") }
        catch let error as WebTorrentMagnetPlaybackError {
            #expect(error == .bridgeFailed("磁力元数据或文件身份不匹配"))
        }
        try await fixture.waitUntilStopped()
    }
}

private func hostFiles(port: Int = 32123) throws -> [HostMagnetFile] {
    try HostMagnetPlaybackResolver.files([0, 7].map { index in
        SixVMagnetPlaybackFile(index: index, name: "same.mp4", length: Int64(1000 + index),
            url: URL(string: "http://127.0.0.1:\(port)/stream/\(index)/same.mp4")!)
    }, infoHash: hostHash)
}

@MainActor private struct HostAppFixture {
    let state: AppState
    let provider: HostProviderFixture
    let resolver: HostResolverFixture
    let episode = Episode(name: "Original episode", url: "original-opaque-episode")
    init(deferred: Bool = false) async throws {
        provider = HostProviderFixture()
        resolver = HostResolverFixture(deferred: deferred)
        let id = UUID().uuidString
        let site = Site(key: id, name: "Host fixture", type: 3, api: "csp_HostFixture_" + id)
        await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-app-" + id)
        let defaults = UserDefaults(suiteName: "host-app-" + id)!
        state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: root), userPreferences: UserPreferences(defaults: defaults),
            hostMagnetResolver: resolver)
        state.sites = [site]; state.activeSite = site; state.selectedPlayFlag = "original-line"
        state.detailVod = Vod(vodId: "original-vod", vodName: "Original", siteKey: site.key)
        state.episodes = [episode]
        state.allowsAutomaticVodPlaybackActions = false
    }
}

private actor HostProviderFixture: SiteContentProvider {
    var inputs: [String] = []
    func calls() -> [String] { inputs }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        inputs.append(flag + "\u{0}" + id)
        return Result(url: hostURI, header: ["Authorization": "never-forward-to-loopback"])
    }
    func homeContent(site: Site) async throws -> Result { .empty }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result { .empty }
    func detailContent(site: Site, id: String) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}

private actor HostResolverFixture: HostMagnetPlaybackResolving {
    var deferred: Bool
    var continuation: CheckedContinuation<Void, Never>?
    var requested = false
    var released: Set<UUID> = []
    init(deferred: Bool) { self.deferred = deferred }
    func setDeferred(_ value: Bool) { deferred = value }
    func prepare(_ result: Result, resumeFile: MagnetFileIdentity?) async throws -> Result {
        requested = true
        if deferred { await withCheckedContinuation { continuation = $0 } }
        return try HostMagnetPlaybackResolver.prepared(result, leaseID: UUID(), files: hostFiles(), resumeFile: resumeFile)
    }
    func complete() { continuation?.resume(); continuation = nil }
    func release(_ leaseID: UUID) { released.insert(leaseID) }
    func releaseCount() -> Int { released.count }
    func waitUntilRequested() async {
        for _ in 0..<400 where !requested { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(requested)
    }
    func waitForReleases(_ count: Int) async {
        for _ in 0..<400 where released.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

private struct BridgeProcessFixture {
    let root: URL
    let bridge: WebTorrentMagnetPlaybackResolver
    init(delay: Double = 0, wrongHash: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("host-bridge-\(UUID())")
        let module = root.appendingPathComponent("node_modules/webtorrent")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        let script = """
        import fs from 'node:fs'
        const [uri, ready] = process.argv.slice(2)
        fs.appendFileSync('\(root.path)/pids', process.pid + '\\n')
        process.on('SIGTERM', () => process.exit(0))
        setTimeout(() => {
          const files = [0, 7].map(index => ({index, name:'same.mp4', length:1000+index, url:`http://127.0.0.1:32123/stream/${index}/same.mp4`}))
          fs.writeFileSync(ready, JSON.stringify({url:files[0].url, files, infoHash:'\(wrongHash ? String(repeating: "f", count: 40) : hostHash)'}))
        }, \(Int(delay * 1000)))
        setInterval(() => {}, 1000)
        """
        try script.write(to: root.appendingPathComponent("torrent-bridge.mjs"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["NETVPLAYER_TORRENT_BRIDGE_PATH"] = root.path
        bridge = WebTorrentMagnetPlaybackResolver(environment: env, cacheRoot: root.appendingPathComponent("cache"))
    }
    func processIDs() throws -> [Int32] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("pids").path) else { return [] }
        return try String(contentsOf: root.appendingPathComponent("pids"), encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
    }
    func isRunning() throws -> Bool { try processIDs().contains { kill($0, 0) == 0 } }
    func waitUntilStarted() async throws {
        for _ in 0..<200 { if try !processIDs().isEmpty { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CocoaError(.executableLoad)
    }
    func waitUntilStopped() async throws {
        for _ in 0..<200 { if try !isRunning() { return }; try await Task.sleep(for: .milliseconds(10)) }
        stop(); Issue.record("Bridge process did not retire")
    }
    func stop() { for pid in (try? processIDs()) ?? [] where kill(pid, 0) == 0 { kill(pid, SIGTERM) } }
}
