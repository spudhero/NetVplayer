import AppKit
import Foundation
import Models
import Testing
@testable import PlayerEngine

@Test func chapterMetadataIsBoundedAndKeepsNativeIndicesWhenRejectingInvalidRows() throws {
    let json = #"[{"title":"Start","time":0},{"time":-1},{"title":"Middle","time":5},{"time":5},{"time":true},{"time":100},{"title":"End","time":10}]"#
    let chapters = try PlayerChapterPolicy.chapters(json: json, duration: 35)
    #expect(chapters.map(\.id) == [0, 2, 6])
    #expect(chapters.map(\.seconds) == [0, 5, 10])
    #expect(PlayerChapterPolicy.current(at: 6, in: chapters)?.id == 2)
    #expect(PlayerChapterPolicy.next(at: 6, in: chapters)?.id == 6)
    #expect(PlayerChapterPolicy.previous(at: 6, in: chapters)?.id == 0)
    #expect(PlayerChapterPolicy.previous(at: 9, in: chapters)?.id == 2)
    #expect(PlayerChapterPolicy.previous(at: 0, in: chapters) == nil)
    #expect(PlayerChapterPolicy.next(at: 15, in: chapters) == nil)
    #expect(PlayerChapterPolicy.current(at: .nan, in: chapters) == nil)
    let many = (0..<500).map { ["time": $0, "title": String(repeating: "x", count: 300)] as [String: Any] }
    let text = String(decoding: try JSONSerialization.data(withJSONObject: many), as: UTF8.self)
    let bounded = try PlayerChapterPolicy.chapters(json: text)
    #expect(bounded.count == 256)
    #expect(bounded.allSatisfy { $0.title.count == 256 })
    let editions = try PlayerChapterPolicy.editions(json: #"[{"title":"Theatrical","default":true},{"title":"Director"}]"#)
    #expect(editions.map(\.id) == [0, 1])
    #expect(editions.first?.isDefault == true)
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_CHAPTER_FIXTURE"] != nil))
func chapterNativeReadSeekAndRetiredMenuOwnership() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_CHAPTER_FIXTURE"])
    let plain = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"])
    _ = NSApplication.shared
    let engine = MPVPlayerEngine(videoSurface: .vod)
    let state = PlayerState(); engine.playerState = state
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
    let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
    view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
    engine.attach(to: view, surface: .vod)
    defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
    await engine.play(spec: PlaySpec(url: URL(fileURLWithPath: path).absoluteString))
    try #require(await chapterWait { !state.isMediaLoading && state.chapters.count == 3 })
    #expect(state.chapters.map(\.seconds) == [0, 5, 10])
    #expect(state.chapters.map(\.title) == ["Start", "Middle", "End"])
    let owner = try #require(state.chapterOwnerID)
    engine.pause()
    engine.seekToChapter(id: 1, owner: owner)
    try #require(await chapterWait { abs(state.position - 5) < 0.3 && !state.isSeeking })
    await engine.play(spec: PlaySpec(url: URL(fileURLWithPath: plain).absoluteString))
    try #require(await chapterWait { !state.isMediaLoading && state.chapters.isEmpty })
    #expect(state.chapterOwnerID != owner)
    engine.seekToChapter(id: 2, owner: owner)
    #expect(!state.isSeeking)
    #expect(state.position < 2)
    engine.stop()
    try #require(await chapterWait { state.currentSpec == nil })
    #expect(state.chapters.isEmpty)
    #expect(state.chapterOwnerID == nil)
    #expect(state.containerEditions.isEmpty)
}

@MainActor
private func chapterWait(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
    return predicate()
}
