import AppKit
import Models
import PlayerEngine
import SwiftUI
import Testing
@testable import NetVplayerApp

@MainActor
@Suite(.serialized)
struct PlayerChapterThumbnailViewTests {
    @Test func uncachedHoverNeverDisplaysAnotherTimesCachedFrame() async throws {
        let data = try thumbnailPNG(.red)
        let store = PlayerChapterPreviewStore { _, _ in data }
        _ = await store.image(spec: PlaySpec(url: "file:///thumbnail.mp4"), mediaID: "A", seconds: 0)
        let renderer = ImageRenderer(content: PlayerChapterThumbnail(
            chapter: PlayerChapter(id: 0, title: "", seconds: 0), spec: nil,
            mediaID: "A", store: store, previewSeconds: 60).frame(width: 160, height: 90))
        renderer.proposedSize = ProposedViewSize(width: 160, height: 90)
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        #expect(thumbnailColorFraction(bitmap, color: .red) < 0.01)
    }

    @Test func changingHoverClearsOldFrameAndRejectsLateResults() async throws {
        let probe = ThumbnailViewDecodeProbe()
        let store = PlayerChapterPreviewStore(decode: probe.decode)
        let input = ThumbnailViewInput(store: store)
        _ = await store.image(spec: input.spec, mediaID: "A", seconds: 0)
        let fixture = ThumbnailViewFixture(input: input)
        defer { fixture.close(); store.reset(); probe.finishAll() }
        try #require(await thumbnailViewWait { fixture.fraction(.red) > 0.9 })

        input.seconds = 4
        try #require(await thumbnailViewWait { probe.calls.contains(4) })
        #expect(fixture.fraction(.red) < 0.01)
        probe.finish(4, color: .blue)
        try #require(await thumbnailViewWait { fixture.fraction(.blue) > 0.9 })

        input.seconds = 8
        try #require(await thumbnailViewWait { probe.calls.contains(8) })
        #expect(fixture.fraction(.blue) < 0.01)
        input.seconds = 12
        try #require(await thumbnailViewWait { probe.calls.contains(12) })
        probe.finish(8, color: .red)
        try #require(await thumbnailViewWait { store.cachedImage(mediaID: "A", seconds: 8) != nil })
        // The cancelled view request may still finish for the shared cache.
        // Its red frame must never appear under the new 12-second label.
        #expect(fixture.fraction(.red) < 0.01)
        #expect(fixture.fraction(.blue) < 0.01)
        probe.finish(12, color: .blue)
        try #require(await thumbnailViewWait { fixture.fraction(.blue) > 0.9 })

        input.seconds = 8
        try #require(await thumbnailViewWait { fixture.fraction(.red) > 0.9 })
        #expect(probe.calls.filter { $0 == 8 }.count == 1)
        input.seconds = 16
        try #require(await thumbnailViewWait { probe.calls.contains(16) })
        probe.finish(16, color: nil)
        try #require(await thumbnailViewWait { !probe.isWaiting(16) })
        #expect(fixture.fraction(.red) < 0.01)
        #expect(fixture.fraction(.blue) < 0.01)

        input.seconds = 12
        try #require(await thumbnailViewWait { fixture.fraction(.blue) > 0.9 })
        input.mediaID = "B"
        try #require(await thumbnailViewWait { probe.calls.filter { $0 == 12 }.count == 2 })
        #expect(fixture.fraction(.blue) < 0.01)
    }
}

@MainActor
private final class ThumbnailViewInput: ObservableObject {
    @Published var seconds: Double = 0
    @Published var mediaID = "A"
    let spec = PlaySpec(url: "file:///thumbnail.mp4")
    let store: PlayerChapterPreviewStore
    init(store: PlayerChapterPreviewStore) { self.store = store }
}

private struct ThumbnailViewHarness: View {
    @ObservedObject var input: ThumbnailViewInput
    var body: some View {
        PlayerChapterThumbnail(chapter: PlayerChapter(id: 0, title: "", seconds: 0),
            spec: input.spec, mediaID: input.mediaID, store: input.store, previewSeconds: input.seconds)
            .frame(width: 160, height: 90)
    }
}

@MainActor
private final class ThumbnailViewFixture {
    let host: NSHostingView<ThumbnailViewHarness>
    let window: NSWindow
    init(input: ThumbnailViewInput) {
        host = NSHostingView(rootView: ThumbnailViewHarness(input: input))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 90),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        window.contentView = host
        window.orderBack(nil)
    }
    func fraction(_ color: NSColor) -> Double {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return thumbnailColorFraction(bitmap, color: color)
    }
    func close() { window.close() }
}

@MainActor
private final class ThumbnailViewDecodeProbe {
    var calls: [Double] = []
    private var waiting: [Double: CheckedContinuation<Data?, Never>] = [:]
    func decode(spec: PlaySpec, seconds: Double) async -> Data? {
        calls.append(seconds)
        if seconds == 0 { return try? thumbnailPNG(.red) }
        return await withCheckedContinuation { waiting[seconds] = $0 }
    }
    func isWaiting(_ seconds: Double) -> Bool { waiting[seconds] != nil }
    func finish(_ seconds: Double, color: NSColor?) {
        waiting.removeValue(forKey: seconds)?.resume(returning: color.flatMap { try? thumbnailPNG($0) })
    }
    func finishAll() {
        for continuation in waiting.values { continuation.resume(returning: nil) }
        waiting.removeAll()
    }
}

@MainActor
private func thumbnailPNG(_ color: NSColor) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let rgba = try #require(color.usingColorSpace(.deviceRGB))
    let pixels = try #require(bitmap.bitmapData)
    for y in 0..<4 { for x in 0..<4 {
        let offset = y * bitmap.bytesPerRow + x * 4
        pixels[offset] = UInt8(rgba.redComponent * 255)
        pixels[offset + 1] = UInt8(rgba.greenComponent * 255)
        pixels[offset + 2] = UInt8(rgba.blueComponent * 255)
        pixels[offset + 3] = 255
    } }
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor
private func thumbnailColorFraction(_ bitmap: NSBitmapImageRep, color: NSColor) -> Double {
    let expected = color.usingColorSpace(.deviceRGB)!
    var matching = 0, samples = 0
    for x in stride(from: bitmap.pixelsWide / 8, to: bitmap.pixelsWide * 7 / 8, by: 4) {
        for y in stride(from: bitmap.pixelsHigh / 8, to: bitmap.pixelsHigh * 7 / 8, by: 4) {
            samples += 1
            guard let actual = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            // AppKit applies the display profile when hosting the view, so
            // compare strong red/blue dominance rather than exact RGB bytes.
            let dominant = expected.redComponent > expected.blueComponent
                ? actual.redComponent : actual.blueComponent
            let other = expected.redComponent > expected.blueComponent
                ? max(actual.greenComponent, actual.blueComponent) : max(actual.redComponent, actual.greenComponent)
            if dominant > 0.6, dominant > other + 0.4 { matching += 1 }
        }
    }
    return Double(matching) / Double(max(1, samples))
}

@MainActor
private func thumbnailViewWait(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}
