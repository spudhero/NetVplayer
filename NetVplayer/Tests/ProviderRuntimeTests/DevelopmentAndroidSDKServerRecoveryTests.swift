#if DEBUG
import Darwin
import Foundation
import Models
import ProviderSDK
import Testing
@testable import SpiderEngine

private func sdkRecoverySite() -> Site {
    Site(key: "AiDj", name: "AI", type: 3, api: "csp_AiDjGuard", ext: "original SDK extension")
}

private func sdkRecoveryRuntime(_ fixture: DevelopmentAndroidBridgeFixture) throws -> DevelopmentAndroidRuntimeLayout {
    let site = sdkRecoverySite()
    try fixture.writeManifest(changes: ["bindings": [["key": site.key, "api": site.api,
        "className": "com.github.catvod.spider.AiDjGuard"]]], repairsSDKMedia: true)
    return try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
}

private func sdkRecoveryEvents(_ fixture: DevelopmentAndroidBridgeFixture) throws -> [[String: String]] {
    try String(contentsOf: fixture.state.appendingPathComponent("operations.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
}

@Test func developmentAndroidSDKServerRecoveryConfirmsExitAndKeepsSavedState() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture(); defer { fixture.remove() }
    let runtime = try sdkRecoveryRuntime(fixture), site = sdkRecoverySite()
    let http = try AndroidHLSHTTPFixture(body: Data("SDK media fixture".utf8), contentType: "video/mp4")
    defer { http.stop() }
    let port = try await http.start()
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: runtime.manifest.bindings[0], stateDirectory: fixture.state)
    do {
        do {
            _ = try await provider.playerContent(site: site, flag: "AI", id: "sdk-recover-\(port)")
            Issue.record("A disconnected SDK server must retire its helper before the existing retry")
        } catch let error as ProviderErrorPayload {
            #expect(error.code == "android_sdk_media_disconnected" && error.retryable)
        }
        let before = try sdkRecoveryEvents(fixture)
        let oldPID = try #require(before.first?["pid"].flatMap(Int32.init))
        #expect(kill(oldPID, 0) == -1 && errno == ESRCH)
        // Simulate AppState's existing single retry, with the identical episode.
        let result = try await provider.playerContent(site: site, flag: "AI", id: "sdk-recover-\(port)")
        let media = try #require(URLComponents(string: result.url))
        let ownedPort = try #require(media.port)
        #expect(media.host == "127.0.0.1" && (6677..<7000).contains(ownedPort))
        #expect(media.path == "/proxy" && media.percentEncodedQuery == "do=hg&vid=fixture")
        #expect(result.header == ["User-Agent": "SDK fixture"])
        #expect(ownedPort != Int(port)) // The test process's unrelated HTTP listener must never be selected.
        let (body, _) = try await URLSession.shared.data(from: #require(media.url))
        #expect(body == Data("SDK media fixture".utf8))
        let events = try sdkRecoveryEvents(fixture)
        let players = events.filter { $0["operation"] == "player" }
        #expect(players.count == 2 && Set(players.compactMap { $0["pid"] }).count == 2)
        #expect(Set(players.compactMap { $0["id"] }).count == 1)
        #expect(Set(players.compactMap { $0["state_sha256"] }).count == 1)
        #expect(events.filter { $0["operation"] == "init" }.allSatisfy { $0["extend"] == site.ext })
        let persistent = try runtime.persistentDataDirectory(base: fixture.state.appendingPathComponent("source-sessions-v1"),
            binding: runtime.manifest.bindings[0], site: site)
        #expect(try String(contentsOf: persistent.appendingPathComponent("sdk-server-recovery.fixture"), encoding: .utf8) == "saved SDK session")
    } catch { await provider.shutdown(); throw error }
    await provider.shutdown()
}

@Test(arguments: [false, true])
func developmentAndroidSDKServerRecoveryHandlesHTTP500WithOneForegroundRetry(persistentFailure: Bool) async throws {
    let fixture = try DevelopmentAndroidBridgeFixture(); defer { fixture.remove() }
    let runtime = try sdkRecoveryRuntime(fixture), site = sdkRecoverySite()
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: runtime.manifest.bindings[0], stateDirectory: fixture.state)
    let id = persistentFailure ? "sdk-http-500-always-1" : "sdk-http-500-once-1"
    do {
        do {
            _ = try await provider.playerContent(site: site, flag: "AI", id: id)
            Issue.record("The background request must fail before handing a 500 address to the player")
        } catch let error as ProviderErrorPayload {
            #expect(error.code == "android_sdk_media_http_500" && !error.retryable)
        }
        let backgroundPID = try #require(try sdkRecoveryEvents(fixture).first?["pid"].flatMap(Int32.init))
        #expect(kill(backgroundPID, 0) == 0)

        do {
            _ = try await DevelopmentAndroidSiteProvider.$allowsSDKMediaHTTPRecovery.withValue(true) {
                try await provider.playerContent(site: site, flag: "AI", id: id)
            }
            Issue.record("The first foreground 500 must retire its SDK helper before the retry")
        } catch let error as ProviderErrorPayload {
            #expect(error.code == "android_sdk_media_http_500" && error.retryable)
        }
        #expect(kill(backgroundPID, 0) == -1 && errno == ESRCH)

        // AppState spends its preparation retry on the same episode and stops after that.
        do {
            let result = try await provider.playerContent(site: site, flag: "AI", id: id)
            #expect(!persistentFailure)
            let (body, response) = try await URLSession.shared.data(from: #require(URL(string: result.url)))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(body == Data("SDK media fixture".utf8))
        } catch let error as ProviderErrorPayload {
            #expect(persistentFailure)
            #expect(error.code == "android_sdk_media_http_500" && !error.retryable)
        }

        let players = try sdkRecoveryEvents(fixture).filter { $0["operation"] == "player" }
        try #require(players.count == 3)
        #expect(players[0]["pid"] == players[1]["pid"])
        let retryPID = try #require(players[2]["pid"].flatMap(Int32.init))
        #expect(retryPID != backgroundPID && kill(retryPID, 0) == 0)
        #expect(Set(players.compactMap { $0["id"] }) == [id])
        #expect(Set(players.compactMap { $0["state_sha256"] }).count == 1)
    } catch { await provider.shutdown(); throw error }
    await provider.shutdown()
}

@Test func developmentAndroidSDKServerRecoveryDoesNotRetireForTimeoutOrCancellation() async throws {
    for code in [URLError.timedOut, .cancelled, .networkConnectionLost] {
        let fixture = try DevelopmentAndroidBridgeFixture(); defer { fixture.remove() }
        let runtime = try sdkRecoveryRuntime(fixture), site = sdkRecoverySite()
        let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: runtime.manifest.bindings[0],
            stateDirectory: fixture.state, probeSDKMedia: { _, _ in throw URLError(code) })
        do {
            do { _ = try await provider.playerContent(site: site, flag: "AI", id: "sdk-owned-1"); Issue.record("Expected probe failure") }
            catch let error as URLError { #expect(error.code == code) }
            _ = try await provider.homeContent(site: site)
            #expect(Set(try sdkRecoveryEvents(fixture).compactMap { $0["pid"] }).count == 1)
        } catch { await provider.shutdown(); throw error }
        await provider.shutdown()
    }
}

private actor SDKProbeGate {
    var entered = false
    var released = false
    var continuation: CheckedContinuation<[Int64], Error>?
    func wait() async throws -> [Int64] {
        guard !released else { throw URLError(.cannotConnectToHost) }
        return try await withCheckedThrowingContinuation { continuation = $0; entered = true }
    }
    func refuseConnection() { released = true; continuation?.resume(throwing: URLError(.cannotConnectToHost)); continuation = nil }
}

@Test func developmentAndroidSDKServerRecoveryRejectsLateFailureAfterSourceCancellation() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture(); defer { fixture.remove() }
    let runtime = try sdkRecoveryRuntime(fixture), site = sdkRecoverySite(), gate = SDKProbeGate()
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: runtime.manifest.bindings[0],
        stateDirectory: fixture.state, probeSDKMedia: { _, _ in try await gate.wait() })
    let pending = Task { try await provider.playerContent(site: site, flag: "AI", id: "sdk-owned-1") }
    do {
        for _ in 0..<300 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(await gate.entered)
        let oldPID = try #require(try sdkRecoveryEvents(fixture).first?["pid"].flatMap(Int32.init))
        await provider.cancelPlayback()
        await gate.refuseConnection()
        do { _ = try await pending.value; Issue.record("A canceled source must reject its late failure") }
        catch let error as ProviderErrorPayload { #expect(error.code == "android_content_stale") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while kill(oldPID, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(oldPID, 0) == -1)
        _ = try await provider.homeContent(site: site)
        #expect(Set(try sdkRecoveryEvents(fixture).compactMap { $0["pid"] }).count == 2)
    } catch { await gate.refuseConnection(); pending.cancel(); await provider.shutdown(); throw error }
    await provider.shutdown()
}

@Test func developmentAndroidSDKServerRecoveryRejectsAnotherSourcesLiveServer() async throws {
    let foreign = try DevelopmentAndroidBridgeFixture(); defer { foreign.remove() }
    let fixture = try DevelopmentAndroidBridgeFixture(); defer { fixture.remove() }
    let foreignRuntime = try sdkRecoveryRuntime(foreign)
    let foreignProvider = DevelopmentAndroidSiteProvider(runtime: foreignRuntime,
        binding: foreignRuntime.manifest.bindings[0], stateDirectory: foreign.state)
    // This source has no MP4 repair policy: ownership must be checked for all
    // original Android SDK media, independently of codec compatibility.
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime,
        binding: runtime.manifest.bindings[0], stateDirectory: fixture.state)
    do {
        let foreignResult = try await foreignProvider.playerContent(site: sdkRecoverySite(), flag: "AI", id: "sdk-owned-1")
        let foreignPort = try #require(URLComponents(string: foreignResult.url)?.port)
        let input = "sdk-recover-\(foreignPort)"
        do {
            _ = try await provider.playerContent(site: fixture.site, flag: "fixture", id: input)
            Issue.record("A live foreign source server must not be accepted as this source's media")
        } catch let error as ProviderErrorPayload {
            #expect(error.code == "android_sdk_media_disconnected" && error.retryable)
        }
        let oldPID = try #require(try sdkRecoveryEvents(fixture).first?["pid"].flatMap(Int32.init))
        #expect(kill(oldPID, 0) == -1 && errno == ESRCH)
        let result = try await provider.playerContent(site: fixture.site, flag: "fixture", id: input)
        let address = try #require(URLComponents(string: result.url))
        #expect(address.port != foreignPort && (6677..<7000).contains(address.port ?? 0))
        #expect(address.path == "/proxy" && address.percentEncodedQuery == "do=hg&vid=fixture")
        #expect(result.header == foreignResult.header)
        let (body, _) = try await URLSession.shared.data(from: #require(address.url))
        #expect(body == Data("SDK media fixture".utf8))
        let players = try sdkRecoveryEvents(fixture).filter { $0["operation"] == "player" }
        #expect(players.count == 2 && Set(players.compactMap { $0["pid"] }).count == 2)
        #expect(Set(players.compactMap { $0["id"] }) == [input])
        #expect(Set(players.compactMap { $0["state_sha256"] }).count == 1)
        // Recovery must neither retire nor borrow the other source's helper.
        let foreignPID = try #require(try sdkRecoveryEvents(foreign).first?["pid"].flatMap(Int32.init))
        #expect(kill(foreignPID, 0) == 0)
    } catch { await provider.shutdown(); await foreignProvider.shutdown(); throw error }
    await provider.shutdown()
    await foreignProvider.shutdown()
}
#endif
