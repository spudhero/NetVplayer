import AppKit
import Foundation
import Models
import Testing
@testable import PlayerEngine

@Test func mpvCENCPlaybackUsesValidatedPerMediaKeyAndKeepsOtherDemuxerOptions() {
    let key = "00112233445566778899AABBCCDDEEFF"
    let encrypted = PlaySpec(url: "https://media.test/video", drm: Drm(key: key, type: "cenc-aes-ctr"))
    let plan = MPVOptionPolicy.resolve(spec: encrypted, user: ["demuxer-lavf-o": "http_persistent=0,decryption_key=old"], session: [:])
    #expect(plan["demuxer-lavf-o"] == .init(value: "http_persistent=0,decryption_key=\(key.lowercased())", origin: .transport))
    for drm in [Drm(key: key, type: "widevine"), Drm(key: "abc", type: "cenc"), Drm(key: String(repeating: "z", count: 32), type: "cenc")] {
        let spec = PlaySpec(url: "https://media.test/video", drm: drm)
        #expect(MPVOptionPolicy.resolve(spec: spec, user: [:], session: [:])["demuxer-lavf-o"] == nil)
    }
    let nextMedia = PlaySpec(url: "https://media.test/plain.mp4")
    #expect(MPVOptionPolicy.resolve(spec: nextMedia, user: [:], session: [:])["demuxer-lavf-o"] == nil)
}

@Test func mpvOptionPolicyExplainsPriorityAndProtectsStructuredTransport() {
    let spec = PlaySpec(url: "file:///tmp/a.mkv", mpvOptions: ["sub-pos": "1", "secondary-sid": "3", "http-proxy": "http://proxy.test:1", "referrer": "private", "brightness": "20"])
    let plan = MPVOptionPolicy.resolve(spec: spec, user: ["sub-pos": "95"], session: ["secondary-sid": "no"])
    #expect(plan["brightness"] == .init(value: "20", origin: .source))
    #expect(plan["sub-pos"] == .init(value: "95", origin: .user))
    #expect(plan["secondary-sid"] == .init(value: "no", origin: .session))
    #expect(plan["http-proxy"] == .init(value: "", origin: .transport))
    #expect(plan["referrer"] == .init(value: "", origin: .transport))
    #expect(plan["stream-lavf-o"]?.value == "http_proxy=")
    #expect(PlaybackTransportOptions.resolved(["http-proxy": "http://proxy.test"], url: "https://127.example.test/a", direct: false)["http-proxy"] == "http://proxy.test")
    #expect(!MPVOptionPolicy.accepts(name: "private?token=secret", value: "yes"))
    #expect(!MPVOptionPolicy.accepts(name: "brightness", value: "\0"))
    #expect(!MPVOptionPolicy.accepts(name: "brightness", value: String(repeating: "x", count: 65 * 1_024)))
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
func mpvOptionNativeDefaultsResetAndInvalidSuggestionsDoNotFailPlayback() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"])
    _ = NSApplication.shared
    let engine = MPVPlayerEngine(videoSurface: .vod)
    let state = PlayerState(); engine.playerState = state
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
    let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
    view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
    engine.attach(to: view, surface: .vod)
    defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
    let url = URL(fileURLWithPath: path).absoluteString
    await engine.play(spec: PlaySpec(url: url, mpvOptions: ["brightness": "45", "vf": "hflip", "sub-pos": "1", "this-option-does-not-exist": "private-token-value"]))
    try #require(await optionWait { !state.isMediaLoading || state.errorMessage != nil })
    #expect(state.errorMessage == nil)
    #expect(engine.nativePropertyJSON("brightness") == "45")
    #expect(engine.nativePropertyJSON("vf")?.contains("hflip") == true)
    #expect(engine.nativePropertyJSON("sub-pos") == "95")
    #expect(state.mpvOptionDiagnostics.contains { $0.name == "this-option-does-not-exist" && $0.status == .rejected })
    #expect(!String(describing: state.mpvOptionDiagnostics).contains("private-token-value"))
    await engine.play(spec: PlaySpec(url: url, mpvOptions: ["brightness": "invalid"]))
    try #require(await optionWait { !state.isMediaLoading || state.errorMessage != nil })
    #expect(state.errorMessage == nil)
    #expect(engine.nativePropertyJSON("brightness") == "0")
    #expect(engine.nativePropertyJSON("vf") == "[]")
    #expect(state.mpvOptionDiagnostics.contains { $0.name == "brightness" && $0.status == .rejected })
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
func mpvLiveCacheDefaultsAndSourceOverridesRestoreBetweenChannels() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"])
    _ = NSApplication.shared
    let engine = MPVPlayerEngine(videoSurface: .live)
    let state = PlayerState(); engine.playerState = state
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
    let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .live))
    view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
    engine.attach(to: view, surface: .live)
    defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
    let url = URL(fileURLWithPath: path).absoluteString
    let live = PlaySpec(url: url, metadata: ["playback.kind": "live"])
    await engine.play(spec: live)
    try #require(await optionWait { !state.isMediaLoading || state.errorMessage != nil })
    #expect(state.errorMessage == nil)
    #expect(engine.nativePropertyJSON("cache-secs").flatMap(Double.init) == 20)
    #expect(engine.nativePropertyJSON("cache-pause-wait").flatMap(Double.init) == 3)
    var overridden = live
    overridden.mpvOptions = ["cache-secs": "30", "cache-pause-wait": "5",
        "stream-lavf-o": "icy=0,multiple_requests=0", "demuxer-lavf-o": "http_persistent=0"]
    await engine.play(spec: overridden)
    try #require(await optionWait { !state.isMediaLoading || state.errorMessage != nil })
    #expect(state.errorMessage == nil)
    #expect(engine.nativePropertyJSON("cache-secs").flatMap(Double.init) == 30)
    #expect(engine.nativePropertyJSON("cache-pause-wait").flatMap(Double.init) == 5)
    #expect(engine.nativePropertyJSON("stream-lavf-o")?.contains("multiple_requests") == true)
    #expect(engine.nativePropertyJSON("demuxer-lavf-o")?.contains("http_persistent") == true)
    await engine.play(spec: live)
    try #require(await optionWait { !state.isMediaLoading || state.errorMessage != nil })
    #expect(state.errorMessage == nil)
    #expect(engine.nativePropertyJSON("cache-secs").flatMap(Double.init) == 20)
    #expect(engine.nativePropertyJSON("cache-pause-wait").flatMap(Double.init) == 3)
    #expect(engine.nativePropertyJSON("stream-lavf-o")?.contains("multiple_requests") == false)
    #expect(engine.nativePropertyJSON("demuxer-lavf-o")?.contains("http_persistent") == false)
}

@MainActor
private func optionWait(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
    return predicate()
}
