import AppKit
import Foundation
import Models
import Storage
import Testing
@testable import PlayerEngine

@MainActor
@Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_RUN_MPV_AUDIO_RENDERING_TEST"] != "1"))
func testAudioPreferenceChangesDuringCoverRenderingDoNotBlockPlayback() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "MPVAudioRenderingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = PlaybackAudioPreferenceStore(defaults: defaults)
    preferences.setMuted(true)

    let audioURL = directory.appendingPathComponent("silent.wav")
    let payloadBytes: UInt32 = 44_100 * 2 * 2 * 15
    var wav = Data("RIFF".utf8)
    func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
    }
    appendInteger(payloadBytes + 36)
    wav.append(Data("WAVEfmt ".utf8))
    appendInteger(UInt32(16))
    for value in [UInt16(1), UInt16(2)] { appendInteger(value) }
    appendInteger(UInt32(44_100))
    appendInteger(UInt32(44_100 * 4))
    for value in [UInt16(4), UInt16(16)] { appendInteger(value) }
    wav.append(Data("data".utf8))
    appendInteger(payloadBytes)
    wav.append(Data(count: Int(payloadBytes)))
    try wav.write(to: audioURL)

    let artworkURL = directory.appendingPathComponent("cover.png")
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 256, bitsPerPixel: 32
    ))
    bitmap.bitmapData?.initialize(repeating: 128, count: 64 * 256)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: artworkURL)

    let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: .fullDestroy, audioPreferences: preferences)
    let state = PlayerState()
    engine.playerState = state
    let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0.01
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    view.frame = window.contentLayoutRect
    window.contentView = view
    window.orderFrontRegardless()
    engine.attach(to: view, surface: .vod)
    defer {
        engine.stop()
        engine.detach(from: view)
        window.orderOut(nil)
    }

    for round in 0..<3 {
        await engine.play(spec: PlaySpec(url: audioURL.absoluteString, audioFallbackArtwork: artworkURL.absoluteString,
                                        title: "Audio render regression"))
        for index in 0..<120 {
            let started = ContinuousClock.now
            engine.setVolume(Float(index % 10) / 10)
            engine.setMuted(index.isMultiple(of: 2))
            #expect(started.duration(to: .now) < .milliseconds(250))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.position > 1, "Playback must advance while applying audio preferences (round \(round))")
        #expect(state.errorMessage == nil)
    }

    // The real incident seeked to a tail shorter than the three-second guard.
    // It must reach natural EOF and keep the timeline for next-song/replay UI.
    var naturalEnds = 0
    engine.playbackEndedHandler = { _ in naturalEnds += 1 }
    let duration = state.duration
    try #require(duration > 10)
    engine.seek(to: Int64((duration - 1.5) * 1_000))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !state.hasEnded, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(state.endDisposition == .natural)
    #expect(naturalEnds == 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(state.duration == duration)
    #expect(state.position > duration - 0.5)
}
