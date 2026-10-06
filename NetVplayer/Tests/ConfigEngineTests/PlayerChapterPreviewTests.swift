import AppKit
import Models
import PlayerEngine
import Testing
@testable import NetVplayerApp

struct PlayerChapterPreviewTests {
    let chapters = [PlayerChapter(id: 0, title: "Chapter 1", seconds: 0),
                    PlayerChapter(id: 4, title: "The crossing", seconds: 20),
                    PlayerChapter(id: 8, title: "", seconds: 60)]

    @Test func chapterPresentationPreservesTitlesAndUsesVisibleNumbering() {
        #expect(PlayerChapterPresentationPolicy.title(for: chapters[1], in: chapters) == "The crossing")
        #expect(PlayerChapterPresentationPolicy.number(of: chapters[1], in: chapters) == 2)
        #expect(!PlayerChapterPresentationPolicy.title(for: chapters[0], in: chapters).contains("Chapter"))
        #expect(PlayerChapterPresentationPolicy.end(of: chapters[1], in: chapters, duration: 100) == 60)
        #expect(PlayerChapterPresentationPolicy.end(of: chapters[2], in: chapters, duration: 100) == 100)
        #expect(PlayerChapterPresentationPolicy.end(of: chapters[2], in: chapters, duration: .nan) == nil)
        #expect(PlayerChapterPresentationPolicy.range(of: chapters[1], in: chapters, duration: 100) == "00:20 – 01:00")
    }

    @Test func nodeClicksUseExactChapterStartsAndCrowdedNodesUseNearestTarget() {
        #expect(PlayerChapterPresentationPolicy.hit(at: 25, width: 100, chapters: chapters, duration: 100)?.id == 4)
        #expect(PlayerChapterPresentationPolicy.hit(at: 34, width: 100, chapters: chapters, duration: 100) == nil)
        let crowded = [PlayerChapter(id: 11, title: "", seconds: 50), PlayerChapter(id: 23, title: "", seconds: 51)]
        #expect(PlayerChapterPresentationPolicy.hit(at: 50.8, width: 100, chapters: crowded, duration: 100)?.id == 23)
        #expect(PlayerChapterPresentationPolicy.hit(at: 50.2, width: 100, chapters: crowded, duration: 100)?.id == 11)
        #expect(PlayerChapterPresentationPolicy.hit(at: .nan, width: 100, chapters: chapters, duration: 100) == nil)
        #expect(PlayerChapterPresentationPolicy.hit(at: 0, width: 0, chapters: chapters, duration: 100) == nil)
        #expect(PlayerChapterPresentationPolicy.hit(at: 0, width: 100, chapters: chapters, duration: .infinity) == nil)
        #expect(PlayerChapterPresentationPolicy.center(of: chapters[0], width: 100, duration: 100, thumbWidth: 18) == 9)
        #expect(PlayerChapterPresentationPolicy.isClick(translation: CGSize(width: 2, height: 1)))
        #expect(!PlayerChapterPresentationPolicy.isClick(translation: CGSize(width: 5, height: 0)))
        #expect(!PlayerChapterPresentationPolicy.isClick(translation: .zero, hasDragged: true))
    }

    @MainActor
    @Test func previewRequestsShareWorkAndSurviveClosingOneView() async throws {
        let probe = ChapterPreviewDecodeProbe()
        let store = PlayerChapterPreviewStore(decode: probe.decode)
        let spec = PlaySpec(url: "file:///preview-fixture.mp4")
        let first = Task { ChapterPreviewImageResult(await store.image(spec: spec, mediaID: "A", seconds: 4)) }
        try #require(await previewWait { probe.calls == [4] })
        let second = Task { ChapterPreviewImageResult(await store.image(spec: spec, mediaID: "A", seconds: 4)) }
        first.cancel()
        try await Task.sleep(for: .milliseconds(20))
        probe.finish(seconds: 4)
        let image = try #require(await second.value.image)
        #expect(await first.value.image == nil)
        #expect(probe.calls == [4])
        #expect(store.cachedImage(mediaID: "A", seconds: 4) === image)
        #expect(await store.image(spec: spec, mediaID: "A", seconds: 4) === image)
        #expect(probe.calls == [4])
    }

    @MainActor
    @Test func previewResetRejectsLateFramesAndBoundsQueuedReaders() async throws {
        let probe = ChapterPreviewDecodeProbe()
        let store = PlayerChapterPreviewStore(decode: probe.decode)
        let spec = PlaySpec(url: "file:///preview-fixture.mp4")
        let first = Task { ChapterPreviewImageResult(await store.image(spec: spec, mediaID: "A", seconds: 4)) }
        let second = Task { ChapterPreviewImageResult(await store.image(spec: spec, mediaID: "A", seconds: 8)) }
        try #require(await previewWait { probe.calls.count == 2 })
        let waiting = Task { ChapterPreviewImageResult(await store.image(spec: spec, mediaID: "A", seconds: 12)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(probe.calls.count == 2)
        waiting.cancel()
        #expect(await waiting.value.image == nil)
        store.reset(mediaID: "B")
        probe.finish(seconds: 4); probe.finish(seconds: 8)
        #expect(await first.value.image == nil)
        #expect(await second.value.image == nil)
        #expect(store.cachedImage(mediaID: "B", seconds: 4) == nil)
        #expect(store.cachedImage(mediaID: "A", seconds: 4) == nil)
    }

    @MainActor
    @Test func visibleRowsWaitForAFreeReaderAndShareTheNewFrame() async throws {
        let probe = ChapterPreviewDecodeProbe()
        let store = PlayerChapterPreviewStore(decode: probe.decode)
        let spec = PlaySpec(url: "file:///preview-fixture.mp4")
        let first = Task { ChapterPreviewImageResult(await store.image(spec: spec, mediaID: "A", seconds: 4)) }
        let second = Task { ChapterPreviewImageResult(await store.image(spec: spec, mediaID: "A", seconds: 8)) }
        try #require(await previewWait { probe.calls.count == 2 })
        let row = Task { ChapterPreviewImageResult(await store.image(spec: spec, mediaID: "A", seconds: 12)) }
        let hover = Task { ChapterPreviewImageResult(await store.image(spec: spec, mediaID: "A", seconds: 12)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(probe.calls.count == 2)
        probe.finish(seconds: 4)
        try #require(await previewWait { probe.calls.contains(12) })
        probe.finish(seconds: 8); probe.finish(seconds: 12)
        _ = await first.value; _ = await second.value
        let image = try #require(await row.value.image)
        #expect(await hover.value.image === image)
        #expect(probe.calls == [4, 8, 12])
    }

    @MainActor
    @Test func successfulPreviewCacheEvictsLeastRecentlyUsedFrame() async throws {
        let data = try #require(chapterPreviewPNG())
        var calls = 0
        let store = PlayerChapterPreviewStore { _, _ in calls += 1; return data }
        let spec = PlaySpec(url: "file:///preview-fixture.mp4")
        for index in 0..<64 { _ = await store.image(spec: spec, mediaID: "A", seconds: Double(index)) }
        let retained = try #require(store.cachedImage(mediaID: "A", seconds: 0))
        _ = await store.image(spec: spec, mediaID: "A", seconds: 64)
        #expect(store.cachedImage(mediaID: "A", seconds: 1) == nil)
        #expect(store.cachedImage(mediaID: "A", seconds: 0) === retained)
        #expect(calls == 65)
    }

    @Test func timelinePreviewTargetsAreStableAndBoundedWhileSeeksStayExact() {
        let points = PlayerChapterPreviewPolicy.targets(chapters: chapters, duration: 100)
        #expect(points.count <= 64)
        #expect(points.contains(20) && points.contains(60))
        #expect(PlayerChapterPreviewPolicy.timelineSeconds(20.1, chapters: chapters, duration: 100) == 20)
        #expect(PlayerChapterPreviewPolicy.timelineSeconds(20.2, chapters: chapters, duration: 100) == 20)
        #expect(PlayerChapterPresentationPolicy.hit(at: 20, width: 100, chapters: chapters, duration: 100)?.seconds == 20)
        #expect(PlayerChapterPreviewPolicy.targets(chapters: chapters, duration: .nan).isEmpty)
    }

    @Test func crowdedOrRepeatedChaptersStillPreviewTheEndOfTheFilm() {
        let many = (0..<200).map { PlayerChapter(id: $0, title: "", seconds: Double($0)) }
        let points = PlayerChapterPreviewPolicy.targets(chapters: many, duration: 1000)
        #expect(points.count <= PlayerChapterPreviewPolicy.capacity)
        #expect(points.first == 0 && points.last == 999)
        #expect(points.contains(199))
        #expect(PlayerChapterPreviewPolicy.timelineSeconds(995, chapters: many, duration: 1000) >= 990)
        let repeated = (0..<100).map { PlayerChapter(id: $0, title: "", seconds: 20) }
            + [PlayerChapter(id: 100, title: "Last", seconds: 900)]
        let deduplicated = PlayerChapterPreviewPolicy.targets(chapters: repeated, duration: 1000)
        #expect(deduplicated.contains(20) && deduplicated.contains(900))
        #expect(deduplicated.last == 999)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_CHAPTER_PREVIEW_URL"] != nil))
    func backgroundWarmupCachesRealRangeFramesBeforeOpeningPreview() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_CHAPTER_PREVIEW_URL"])
        let spec = PlaySpec(url: url, headers: ["Cookie": "preview-token=fixture", "Referer": "https://fixture.invalid/"])
        let reservation = "chapter-preview-acceptance-\(UUID().uuidString)"
        PlaybackBackgroundBudget.shared.update(session: reservation, bufferedAhead: 0,
            isLoading: false, isSeeking: false, isBuffering: true)
        defer { PlaybackBackgroundBudget.shared.remove(session: reservation) }
        var calls: [Double] = []
        let store = PlayerChapterPreviewStore { spec, seconds in
            calls.append(seconds)
            return await PlayerChapterThumbnailDecoder.shared.imageData(spec: spec, seconds: seconds)
        }
        let warmup = Task { await store.prefetch(spec: spec, mediaID: "range", targets: [0, 4], position: 4) }
        try await Task.sleep(for: .milliseconds(2200))
        #expect(store.cachedImage(mediaID: "range", seconds: 4) == nil)
        PlaybackBackgroundBudget.shared.update(session: reservation, bufferedAhead: 60,
            isLoading: false, isSeeking: false, isBuffering: false)
        await warmup.value
        #expect(calls == [4, 0])
        let image = try #require(store.cachedImage(mediaID: "range", seconds: 4))
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let color = try #require(bitmap.colorAt(x: 160, y: 90)?.usingColorSpace(.deviceRGB))
        #expect(color.blueComponent > 0.8 && color.redComponent < 0.2)
        #expect(await store.image(spec: spec, mediaID: "range", seconds: 4) === image)
        #expect(calls == [4, 0])
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_CHAPTER_PREVIEW_FIXTURE"] != nil))
    func nativePreviewDecodesTheRequestedFrameAndCancellationDoesNotReturnAnImage() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_CHAPTER_PREVIEW_FIXTURE"])
        let spec = PlaySpec(url: URL(fileURLWithPath: path).absoluteString)
        let decoder = PlayerChapterThumbnailDecoder()
        let data = try #require(await decoder.imageData(spec: spec, seconds: 4))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 320)
        let color = try #require(bitmap.colorAt(x: 160, y: 90)?.usingColorSpace(.deviceRGB))
        #expect(color.blueComponent > 0.8)
        #expect(color.redComponent < 0.2)
        let cancelled = Task { await decoder.imageData(spec: spec, seconds: 0) }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(await decoder.imageData(spec: spec, seconds: .nan) == nil)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_CHAPTER_PREVIEW_URL"] != nil))
    func nativePreviewForwardsMediaHeadersToRangeSource() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_CHAPTER_PREVIEW_URL"])
        let spec = PlaySpec(url: url, headers: ["Cookie": "preview-token=fixture", "Referer": "https://fixture.invalid/"])
        let data = try #require(await PlayerChapterThumbnailDecoder().imageData(spec: spec, seconds: 4))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let color = try #require(bitmap.colorAt(x: 160, y: 90)?.usingColorSpace(.deviceRGB))
        #expect(color.blueComponent > 0.8)
        #expect(color.redComponent < 0.2)
    }
}

@MainActor
private final class ChapterPreviewImageResult {
    let image: NSImage?
    init(_ image: NSImage?) { self.image = image }
}

@MainActor
private final class ChapterPreviewDecodeProbe {
    var calls: [Double] = []
    private var waiting: [Double: CheckedContinuation<Data?, Never>] = [:]
    func decode(spec: PlaySpec, seconds: Double) async -> Data? {
        calls.append(seconds)
        return await withCheckedContinuation { waiting[seconds] = $0 }
    }
    func finish(seconds: Double) { waiting.removeValue(forKey: seconds)?.resume(returning: chapterPreviewPNG()) }
}

@MainActor
private func chapterPreviewPNG() -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.setColor(.blue, atX: 0, y: 0)
    return bitmap.representation(using: .png, properties: [:])
}

@MainActor
private func previewWait(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}
