import AppKit
import Foundation
import Testing
import Models
import Storage
import ProxyServer
@testable import PlayerEngine
import MediaServerEngine

/// Explicit loopback acceptance, not an Emby/Jellyfin server test.
@MainActor
@Test(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_MEDIA_SERVER_LOOPBACK"] != nil), arguments: [MediaServerKind.emby, .jellyfin])
func mediaServerLoopbackNativeOriginalTracksChaptersSeekAndRecovery(_ kind: MediaServerKind) async throws {
    let endpoint = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_MEDIA_SERVER_LOOPBACK"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-server-native-" + UUID().uuidString)
    let domain = "MediaServerNative." + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
    let store = MediaServerStore(storage: StorageManager(storageDirectory: directory),
        preferences: UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore()))
    let login = try MediaServerClient(account: .init(name: "Synthetic loopback", kind: kind, server: endpoint, allowsHTTP: true))
    let (account, token) = try await login.authenticate(username: "fixture", password: "fixture-password")
    try store.save([account]); try store.saveToken(token, for: account)
    let runtime = MediaServerRuntime(store: store)
    try ProxyServer.shared.start()
    defer { ProxyServer.shared.stop() }
    _ = NSApplication.shared
    let audioPreferences = PlaybackAudioPreferenceStore(defaults: defaults)
    audioPreferences.setMuted(true)
    let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: .fullDestroy, audioPreferences: audioPreferences)
    let state = PlayerState(); engine.playerState = state
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
    let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
    view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
    engine.attach(to: view, surface: .vod)
    defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
    let reference = try MediaServerReference(accountID: account.id, itemID: "film1")
    let result = try await runtime.resolve(reference), owner = try #require(result.mediaServer)
    let subtitleURL = try #require(URL(string: result.subs.first?.url ?? ""))
    let (subtitleData, subtitleResponse) = try await URLSession.shared.data(from: subtitleURL)
    try #require((subtitleResponse as? HTTPURLResponse)?.statusCode == 200,
        "subtitle status=\((subtitleResponse as? HTTPURLResponse)?.statusCode ?? -1) body=\(String(decoding: subtitleData, as: UTF8.self))")
    #expect(String(decoding: subtitleData, as: UTF8.self).contains("Synthetic external subtitle"))
    var spec = PlaySpec(url: result.url, subs: result.subs, title: "Synthetic loopback")
    spec.mediaServer = owner; spec.initialStartPositionSeconds = owner.resumeSeconds
    await engine.play(spec: spec)
    try #require(await nativeWait { state.errorMessage != nil || (!state.isMediaLoading && state.position > 12) },
        "loading=\(state.isMediaLoading) position=\(state.position) error=\(state.errorMessage ?? "nil") tracks=\(engine.nativePropertyJSON("track-list") ?? "nil")")
    try #require(state.errorMessage == nil, "\(state.errorMessage ?? "")")
    try #require(await nativeWait { state.audioTracks.count == 2 && state.subtitleTracks.count >= 2 },
        "tracks=\(engine.nativePropertyJSON("track-list") ?? "nil")")
    #expect(state.audioTracks.compactMap(\.sourceIndex) == [1, 2])
    #expect(state.chapters.map(\.seconds) == [0, 10, 20])
    #expect(state.subtitleTracks.contains { $0.isExternal && $0.sourceIndex == 4 })
    await runtime.report(owner.leaseID, snapshot: .init(seconds: state.position, audioIndex: 1), started: true)
    let before = state.position
    try #require(await nativeWait { state.position > before + 1 })
    engine.pause()
    try #require(await nativeWait { !state.isPlaying })
    engine.seek(to: 25_000)
    try #require(await nativeWait { abs(state.position - 25) < 0.4 && !state.isSeeking })
    #expect(!state.isPlaying)
    engine.selectAudioTrack(id: "2")
    try #require(await nativeWait { state.selectedAudioTrackID == "2" })
    await runtime.report(owner.leaseID, snapshot: .init(seconds: state.position, paused: true, audioIndex: 2, subtitleIndex: -1))
    let identity = try #require(PlaybackMediaIdentity.resolved(for: spec))
    let seconds = state.position
    await runtime.release(owner.leaseID, snapshot: .init(seconds: seconds, paused: true, audioIndex: 2))
    engine.stop()
    #expect(await runtime.activeLeaseCount == 0)
    let restored = try await runtime.resolve(reference), newOwner = try #require(restored.mediaServer)
    #expect(newOwner.identity == identity); #expect(newOwner.leaseID != owner.leaseID)
    var resumed = PlaySpec(url: restored.url, subs: restored.subs)
    resumed.mediaServer = newOwner; resumed.initialStartPositionSeconds = seconds
    resumed.mpvOptions["aid"] = "2"; resumed.mpvOptions["sid"] = "no"
    await engine.play(spec: resumed)
    try #require(await nativeWait { !state.isMediaLoading && state.position >= seconds && state.selectedAudioTrackID == "2" })
    #expect(state.selectedSubtitleTrackID == nil)
    #expect(state.chapters.map(\.seconds) == [0, 10, 20])
    let third = try await runtime.resolve(.init(accountID: account.id, itemID: "film2"))
    let thirdOwner = try #require(third.mediaServer)
    #expect(thirdOwner.identity != identity)
    await runtime.release(newOwner.leaseID)
    var next = PlaySpec(url: third.url, subs: third.subs); next.mediaServer = thirdOwner
    await engine.play(spec: next)
    try #require(await nativeWait { !state.isMediaLoading && state.position > 0.2 })
    #expect(state.currentSpec?.mediaServer?.leaseID == thirdOwner.leaseID)
    await runtime.report(owner.leaseID, snapshot: .init(seconds: 999), started: true)
    await runtime.release(thirdOwner.leaseID)
    engine.stop()
    print("[MEDIA_SERVER_LOOPBACK] kind=\(kind.rawValue) synthetic=true originalAudio=2 embeddedAndExternalSubtitles=true chapters=3 seek=25 resumed=true switched=true")
}

@MainActor
private func nativeWait(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(15)
    while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
    return predicate()
}
