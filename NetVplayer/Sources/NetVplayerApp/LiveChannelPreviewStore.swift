import AppKit
import ImageIO
import LiveEngine
import Models
import PlayerEngine

/// Manual rounds only. Native clipped visibility owns demand; one physical
/// operation remains charged until its resolver and decoder have both returned.
@MainActor
final class LiveChannelPreviewStore: ObservableObject {
    struct Frame {
        let image: NSImage
        let capturedAt: Date
        let cost: Int
    }
    typealias Resolve = @MainActor (Channel) async throws -> PlaySpec
    typealias Decode = @MainActor (PlaySpec) async -> Data?
    private struct Demand {
        let channel: Channel
        let priority: PosterDemand
    }
    private struct Flight {
        let id: UUID
        let key: String
        let task: Task<Void, Never>
    }
    static let capacity = 64
    static let byteLimit = 8 * 1_024 * 1_024
    static let roundLimit = 96
    @Published private(set) var revision = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?
    private(set) var source = ""
    private var frames: [String: Frame] = [:]
    private var access: [String: UInt64] = [:]
    private var accessSerial: UInt64 = 0
    private var demands: [String: [UUID: Demand]] = [:]
    private var attempted: Set<String> = []
    private var errors: [String: String] = [:]
    private var flight: Flight?
    private var generation = UUID()
    private var playbackHolds: Set<UUID> = []
    private var resolver: Resolve?
    private let decode: Decode
    private let budget: PlaybackBackgroundBudget
    private var budgetTask: Task<Void, Never>?

    init(budget: PlaybackBackgroundBudget = .shared,
         decode: @escaping Decode = { await PlayerChapterThumbnailDecoder.shared.liveImageData(spec: $0) }) {
        self.budget = budget; self.decode = decode
    }
    deinit { budgetTask?.cancel(); flight?.task.cancel() }
    var activeCount: Int { flight == nil ? 0 : 1 }
    var cachedCount: Int { frames.count }
    var cachedBytes: Int { frames.values.reduce(0) { $0 + $1.cost } }
    var demandCount: Int { demands.count }

    func setSource(_ identity: String) {
        guard source != identity else { return }
        cancelRefresh()
        source = identity
        demands.removeAll(); frames.removeAll(); access.removeAll(); errors.removeAll()
        revision += 1
    }

    func setDemand(channel: Channel, owner: UUID, priority: PosterDemand) {
        let key = LiveCatchupPolicy.channelFingerprint(channel)
        if priority.tier == .visible {
            guard demands[key] != nil || demands.count < Self.roundLimit else { return }
            demands[key, default: [:]][owner] = Demand(channel: channel, priority: priority)
        } else {
            demands[key]?[owner] = nil
            if demands[key]?.isEmpty == true { demands[key] = nil }
        }
        if flight?.key == key, demands[key] == nil { flight?.task.cancel() }
        pump()
    }

    func frame(for channel: Channel) -> Frame? {
        let key = LiveCatchupPolicy.channelFingerprint(channel)
        guard let frame = frames[key] else { return nil }
        accessSerial &+= 1; access[key] = accessSerial
        return frame
    }
    func error(for channel: Channel) -> String? { errors[LiveCatchupPolicy.channelFingerprint(channel)] }

    func refresh(resolve: @escaping Resolve) {
        guard !isRefreshing, flight == nil, playbackHolds.isEmpty else { return }
        guard budget.permitsOptionalWork else {
            message = L10n.text("主播放繁忙或窗口隐藏，请稍后刷新画面。")
            return
        }
        guard !demands.isEmpty else { message = L10n.text("没有可见频道可刷新。"); return }
        generation = UUID(); attempted.removeAll(); errors.removeAll()
        resolver = resolve; message = nil; isRefreshing = true
        let changes = budget.permissionChanges()
        budgetTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { return }
                if !self.budget.permitsOptionalWork {
                    self.message = L10n.text("主播放繁忙或窗口隐藏，请稍后刷新画面。")
                    self.cancelRefresh()
                }
            }
        }
        pump()
    }

    func cancelRefresh() {
        generation = UUID(); resolver = nil; isRefreshing = false
        budgetTask?.cancel(); budgetTask = nil
        flight?.task.cancel()
        // Keep flight (and its physical slot) until completion, including cancellation.
    }

    func beginPlayback() -> UUID {
        let token = UUID(); playbackHolds.insert(token)
        if isRefreshing { message = L10n.text("主播放繁忙或窗口隐藏，请稍后刷新画面。") }
        cancelRefresh()
        return token
    }
    func endPlayback(_ token: UUID) { playbackHolds.remove(token) }
    func drain() async { if let task = flight?.task { await task.value } }

    private func pump() {
        guard isRefreshing, flight == nil, playbackHolds.isEmpty else { return }
        guard budget.permitsOptionalWork else { cancelRefresh(); return }
        let next = demands.compactMap { key, owners -> (String, Demand)? in
            guard !attempted.contains(key), let demand = owners.values.min(by: { $0.priority < $1.priority }) else { return nil }
            return (key, demand)
        }.min { lhs, rhs in
            lhs.1.priority == rhs.1.priority ? lhs.0 < rhs.0 : lhs.1.priority < rhs.1.priority
        }
        guard attempted.count < Self.roundLimit, let (key, demand) = next, let resolver else {
            isRefreshing = false; self.resolver = nil; budgetTask?.cancel(); budgetTask = nil
            return
        }
        attempted.insert(key)
        let id = UUID(), generation = generation, source = source
        let task = Task { [weak self, decode] in
            guard let self else { return }
            defer {
                if self.flight?.id == id { self.flight = nil }
                self.revision += 1
                self.pump()
            }
            do {
                let spec = try await resolver(demand.channel)
                try Task.checkCancellation()
                guard self.generation == generation, self.source == source,
                      self.budget.permitsOptionalWork, self.demands[key] != nil else { return }
                let data = await decode(spec)
                try Task.checkCancellation()
                guard self.generation == generation, self.source == source,
                      self.budget.permitsOptionalWork, self.demands[key] != nil else { return }
                // Fixed decoder output, also validate injected/malformed data before AppKit allocation.
                guard let data, data.count <= 2 * 1_024 * 1_024,
                      let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (1...640).contains(width), (1...640).contains(height),
                      let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0,
                      rep.pixelsWide <= 640, rep.pixelsHigh <= 640 else { throw LivePreviewError.failed }
                let image = NSImage(size: rep.size); image.addRepresentation(rep)
                self.accessSerial &+= 1; self.access[key] = self.accessSerial
                self.frames[key] = Frame(image: image, capturedAt: Date(), cost: data.count + rep.bytesPerRow * rep.pixelsHigh)
                while self.frames.count > Self.capacity || self.cachedBytes > Self.byteLimit {
                    guard let oldest = self.access.min(by: { $0.value < $1.value })?.key else { break }
                    self.frames[oldest] = nil; self.access[oldest] = nil
                }
                self.errors[key] = nil
            } catch {
                guard !Task.isCancelled, self.generation == generation, self.source == source else { return }
                // Never display transport errors containing an authenticated URL.
                let text = (error as? LivePreviewError)?.errorDescription ?? LivePreviewError.failed.errorDescription!
                self.errors[key] = text; self.message = text
            }
        }
        flight = Flight(id: id, key: key, task: task)
    }
}
