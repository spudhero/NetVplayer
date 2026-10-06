import AppKit
import Models
import PlayerEngine
import SwiftUI

enum PlayerChapterPresentationPolicy {
    static func number(of chapter: PlayerChapter, in chapters: [PlayerChapter]) -> Int {
        (chapters.firstIndex(where: { $0.id == chapter.id }) ?? 0) + 1
    }

    static func title(for chapter: PlayerChapter, in chapters: [PlayerChapter]) -> String {
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = title.isEmpty || title.range(
            of: #"^(?:chapter|章节|第)\s*\d+\s*(?:章)?$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        return generic ? L10n.text("第 {0} 章", [String(number(of: chapter, in: chapters))]) : title
    }

    static func end(of chapter: PlayerChapter, in chapters: [PlayerChapter], duration: Double) -> Double? {
        if let next = chapters.first(where: { $0.seconds > chapter.seconds }) { return next.seconds }
        return duration.isFinite && duration > chapter.seconds ? duration : nil
    }

    static func range(of chapter: PlayerChapter, in chapters: [PlayerChapter], duration: Double) -> String {
        let start = PlayerTimelineCoordinatePolicy.label(seconds: chapter.seconds)
        guard let end = end(of: chapter, in: chapters, duration: duration) else { return start }
        return start + " – " + PlayerTimelineCoordinatePolicy.label(seconds: end)
    }

    static func center(of chapter: PlayerChapter, width: CGFloat, duration: Double, thumbWidth: CGFloat = 0) -> CGFloat? {
        guard width.isFinite, thumbWidth.isFinite, width > max(0, thumbWidth),
              duration.isFinite, duration > 0, duration < Double(Int64.max) / 1_000, chapter.seconds.isFinite,
              chapter.seconds >= 0, chapter.seconds < duration else { return nil }
        let inset = max(0, thumbWidth) / 2
        return inset + CGFloat(chapter.seconds / duration) * (width - inset * 2)
    }

    /// Nearest-node hit testing avoids overlapping rectangular targets in dense timelines.
    static func hit(at x: CGFloat, width: CGFloat, chapters: [PlayerChapter], duration: Double,
                    thumbWidth: CGFloat = 0, radius: CGFloat = 10) -> PlayerChapter? {
        guard x.isFinite, radius.isFinite, radius >= 0 else { return nil }
        return chapters.compactMap { chapter -> (PlayerChapter, CGFloat)? in
            guard let center = center(of: chapter, width: width, duration: duration, thumbWidth: thumbWidth) else { return nil }
            return (chapter, abs(center - x))
        }.filter { $0.1 <= radius }.min { $0.1 < $1.1 }?.0
    }

    static func isClick(translation: CGSize, hasDragged: Bool = false) -> Bool {
        !hasDragged && translation.width.isFinite && translation.height.isFinite
            && hypot(translation.width, translation.height) <= 3
    }
}

enum PlayerChapterPreviewPolicy {
    static let capacity = 64

    /// Chapter rows and timeline hover share a bounded set of frames. Moving
    /// one pixel must not open another remote media reader.
    static func targets(chapters: [PlayerChapter], duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0, duration < Double(Int64.max) / 1_000 else { return [] }
        let chapterPoints = Set(chapters.map(\.seconds).filter { $0.isFinite && $0 >= 0 && $0 < duration }).sorted()
        // Reserve timeline coverage even when chapter starts cluster near the
        // beginning. Sampling by chapter index also retains the last chapter.
        let chapterSlots = capacity - 16
        var points: Set<Double>
        if chapterPoints.count > chapterSlots {
            points = Set((0..<chapterSlots).map { index in
                chapterPoints[index * (chapterPoints.count - 1) / (chapterSlots - 1)]
            })
        } else {
            points = Set(chapterPoints)
        }
        let remaining = capacity - points.count
        if remaining > 0 {
            for index in 0..<remaining {
                points.insert(floor(Double(index) * max(0, duration - 1) / Double(max(1, remaining - 1))))
            }
        }
        return points.sorted()
    }

    static func timelineSeconds(_ seconds: Double, chapters: [PlayerChapter], duration: Double) -> Double {
        targets(chapters: chapters, duration: duration).min(by: { abs($0 - seconds) < abs($1 - seconds) }) ?? seconds
    }
}

@MainActor
final class PlayerChapterPreviewStore: ObservableObject {
    typealias Decode = @MainActor (PlaySpec, Double) async -> Data?
    private var mediaID = ""
    private var images: [Double: NSImage] = [:]
    private var access: [Double: ContinuousClock.Instant] = [:]
    private var pending: [Double: Task<NSImage?, Never>] = [:]
    private var unavailable: [Double: ContinuousClock.Instant] = [:]
    private var generation = 0
    private let decode: Decode
    @Published private(set) var revision = 0
    var cachedFrameCount: Int { images.count }

    init(decode: @escaping Decode = { spec, seconds in
        await PlayerChapterThumbnailDecoder.shared.imageData(spec: spec, seconds: seconds)
    }) {
        self.decode = decode
    }

    func cachedImage(mediaID: String, seconds: Double) -> NSImage? {
        guard self.mediaID == mediaID, let image = images[seconds] else { return nil }
        access[seconds] = .now
        return image
    }

    func image(spec: PlaySpec?, mediaID: String, seconds: Double) async -> NSImage? {
        guard !Task.isCancelled, seconds.isFinite, seconds >= 0 else { return nil }
        if self.mediaID != mediaID { reset(mediaID: mediaID) }
        if let image = cachedImage(mediaID: mediaID, seconds: seconds) { return image }
        guard let spec else { return nil }
        if let retryAfter = unavailable[seconds], ContinuousClock.now < retryAfter { return nil }
        let generation = generation
        // Visible rows wait for a slot rather than being dropped permanently.
        // A cancelled hover leaves before opening another media reader.
        while pending.count >= 2, pending[seconds] == nil {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
            guard generation == self.generation, mediaID == self.mediaID else { return nil }
            if let image = cachedImage(mediaID: mediaID, seconds: seconds) { return image }
        }
        if let task = pending[seconds] {
            let image = await task.value
            return Task.isCancelled ? nil : image
        }
        let task = Task { @MainActor [weak self, decode] () -> NSImage? in
            let data = await decode(spec, seconds)
            guard let self, !Task.isCancelled, generation == self.generation, mediaID == self.mediaID else { return nil }
            self.pending[seconds] = nil
            guard let data, let image = NSImage(data: data) else {
                if PlaybackBackgroundBudget.shared.permitsBackgroundWork {
                    self.unavailable[seconds] = ContinuousClock.now.advanced(by: .seconds(30))
                }
                return nil
            }
            if self.images.count >= PlayerChapterPreviewPolicy.capacity,
               let oldest = self.access.min(by: { $0.value < $1.value })?.key {
                self.images.removeValue(forKey: oldest); self.access.removeValue(forKey: oldest)
            }
            self.images[seconds] = image
            self.access[seconds] = .now
            self.revision += 1
            return image
        }
        pending[seconds] = task
        let result = await task.value
        return Task.isCancelled ? nil : result
    }

    func prefetch(spec: PlaySpec?, mediaID: String, targets: [Double], position: Double) async {
        guard let spec, !targets.isEmpty else { return }
        if self.mediaID != mediaID { reset(mediaID: mediaID) }
        let generation = generation
        // Allow the primary demuxer to establish its buffer before seeking
        // remote frames. Decoder also observes the global playback budget.
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        for seconds in targets.sorted(by: { abs($0 - position) < abs($1 - position) }) {
            guard !Task.isCancelled, generation == self.generation else { return }
            while pending.count >= 2 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard generation == self.generation else { return }
            }
            _ = await image(spec: spec, mediaID: mediaID, seconds: seconds)
        }
    }

    func reset(mediaID: String = "") {
        self.mediaID = mediaID
        generation += 1
        for task in pending.values { task.cancel() }
        pending.removeAll()
        images.removeAll()
        access.removeAll()
        unavailable.removeAll()
        revision += 1
    }
}

struct PlayerChapterThumbnail: View {
    private struct Target: Hashable {
        let mediaID: String
        let seconds: Double
    }

    let chapter: PlayerChapter
    let spec: PlaySpec?
    let mediaID: String
    @ObservedObject var store: PlayerChapterPreviewStore
    var fixtureURL: URL? = nil
    var previewSeconds: Double? = nil
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var loadedTarget: Target?

    private var target: Target {
        Target(mediaID: mediaID, seconds: previewSeconds ?? chapter.seconds)
    }

    private var displayedImage: NSImage? {
        // SwiftUI can render the new hover position before its task starts.
        // Only a frame for this exact target may accompany its time label.
        store.cachedImage(mediaID: target.mediaID, seconds: target.seconds)
            ?? (loadedTarget == target ? image : nil)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(PlayerHUDPalette.background.opacity(0.80))
                if let image = displayedImage {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                } else if loadedTarget != target || isLoading {
                    ProgressView().controlSize(.small).tint(PlayerHUDPalette.muted)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "film").font(.system(size: 17, weight: .light))
                        Text(L10n.text("暂无预览")).font(.system(size: 10))
                    }.foregroundStyle(PlayerHUDPalette.muted)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.10), lineWidth: 1))
        .task(id: target) {
            loadedTarget = target
            image = store.cachedImage(mediaID: target.mediaID, seconds: target.seconds)
            isLoading = image == nil
            if let fixtureURL {
                image = NSImage(contentsOf: fixtureURL)
            } else if image == nil {
                do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                let fetched = await store.image(spec: spec, mediaID: target.mediaID, seconds: target.seconds)
                guard !Task.isCancelled else { return }
                image = fetched
            }
            if !Task.isCancelled { isLoading = false }
        }
        .accessibilityHidden(true)
    }
}
