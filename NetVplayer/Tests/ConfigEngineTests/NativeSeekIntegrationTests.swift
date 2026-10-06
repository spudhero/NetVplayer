import AppKit
import Foundation
import Models
import DriveEngine
import Testing
@testable import PlayerEngine

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_SEEK_FIXTURE"] != nil))
func nativeSeekRecoversLongGOPAndPreservesPause() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_SEEK_FIXTURE"])
    _ = NSApplication.shared
    let engine = MPVPlayerEngine(videoSurface: .vod)
    let state = PlayerState()
    engine.playerState = state
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0.01
    window.ignoresMouseEvents = true
    let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
    view.frame = window.contentView!.bounds
    window.contentView = view
    window.orderFrontRegardless()
    engine.attach(to: view, surface: .vod)
    defer {
        engine.stop()
        engine.detach(from: view)
        window.orderOut(nil)
    }
    await engine.play(spec: PlaySpec(url: URL(fileURLWithPath: path).absoluteString,
        metadata: [DrivePlaybackMetadataKey.route: DrivePlaybackRoute.personalTranscode]))
    let started = await nativeSeekWait { state.duration > 100 && !state.isMediaLoading }
    try #require(started, "Native fixture did not start: \(state.errorMessage ?? "no error")")
    engine.seek(to: 92_000)
    engine.seek(to: 65_000)
    let recovered = await nativeSeekWait { !state.isSeeking && !state.isMediaLoading }
    #expect(recovered)
    #expect(state.position.isFinite)
    #expect(state.errorMessage == nil)
    engine.pause()
    let paused = await nativeSeekWait { !state.isPlaying }
    try #require(paused)
    engine.seek(to: 17_000)
    let pausedSeekCompleted = await nativeSeekWait { !state.isSeeking }
    #expect(pausedSeekCompleted)
    #expect(!state.isPlaying)
    #expect(state.errorMessage == nil)

    engine.resume()
    engine.seek(to: 120_000)
    let ended = await nativeSeekWait { state.hasEnded }
    #expect(ended)
    #expect(!state.isPlaying)
    await engine.play(spec: PlaySpec(url: URL(fileURLWithPath: path).absoluteString))
    let replayed = await nativeSeekWait { !state.hasEnded && state.isPlaying && !state.isMediaLoading && state.position < 5 }
    #expect(replayed)
}

@MainActor
private func nativeSeekWait(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}
