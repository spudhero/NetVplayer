import AppKit

struct DanmakuGlyphKey: Hashable, Sendable {
    var text: String
    var color: String
    var fontSize: Int
    var scale: Double
}

struct DanmakuPreparedGlyph: Sendable {
    var image: CGImage?
    var size: CGSize
    var cost: Int { image.map { $0.bytesPerRow * $0.height } ?? 0 }

    /// All drawing state and the bitmap context belong to this worker invocation.
    static func prepare(_ key: DanmakuGlyphKey) -> Self {
        let font = NSFont.systemFont(ofSize: CGFloat(key.fontSize), weight: .semibold)
        let size = CGSize(width: DanmakuTextRasterizer.width(text: key.text, font: font),
                          height: DanmakuTextRasterizer.laneHeight(font: font))
        return Self(image: DanmakuTextRasterizer.image(text: key.text, color: key.color,
                                                      font: font, size: size, scale: key.scale), size: size)
    }
}

/// One physical serial worker, bounded requests, and reservations that survive
/// invalidation until synchronous drawing actually returns. Layers pin entries.
@MainActor
final class DanmakuGlyphPreparation {
    static let byteLimit = 12 * 1_024 * 1_024
    static let entryLimit = 128
    static let batchLimit = 4
    private let queue = DispatchQueue(label: "com.netvplayer.danmaku-glyphs", qos: .utility)
    private let prepare: @Sendable (DanmakuGlyphKey) -> DanmakuPreparedGlyph
    private var entries: [DanmakuGlyphKey: DanmakuPreparedGlyph] = [:]
    private var order: [DanmakuGlyphKey] = []
    private var pending: [DanmakuGlyphKey] = []
    private var protected: Set<DanmakuGlyphKey> = []
    private(set) var generation: UInt64 = 0
    private(set) var cost = 0
    private(set) var reservedCost = 0
    private(set) var isWorking = false
    private(set) var rejectedResults = 0
    private(set) var completedBatches = 0
    var count: Int { entries.count }
    var pendingCount: Int { pending.count }
    var onPrepared: (@MainActor () -> Void)?

    init(prepare: @escaping @Sendable (DanmakuGlyphKey) -> DanmakuPreparedGlyph = DanmakuPreparedGlyph.prepare) {
        self.prepare = prepare
    }

    func glyph(for key: DanmakuGlyphKey) -> DanmakuPreparedGlyph? { entries[key] }

    func invalidate() {
        generation &+= 1
        entries.removeAll(); order.removeAll(); pending.removeAll(); protected.removeAll()
        cost = 0
        // The outstanding batch retains its physical reservation and worker slot.
    }

    func request(_ keys: [DanmakuGlyphKey], protecting active: Set<DanmakuGlyphKey>) {
        protected = active.union(keys.prefix(Self.entryLimit))
        var seen = Set<DanmakuGlyphKey>()
        pending.removeAll(keepingCapacity: true)
        for key in keys where seen.insert(key).inserted && entries[key] == nil {
            pending.append(key)
            if pending.count == Self.entryLimit { break }
        }
        guard !isWorking else { return }
        var batch: [DanmakuGlyphKey] = []
        while let key = pending.first, batch.count < Self.batchLimit {
            let height = DanmakuTextRasterizer.laneHeight(font: NSFont.systemFont(ofSize: CGFloat(key.fontSize), weight: .semibold))
            let pixels = ceil(2_400 * key.scale) * ceil(height * key.scale)
            let reservation = Int(min(Double(2 * 1_024 * 1_024), max(0, pixels * 4)))
            while cost + reservedCost + reservation > Self.byteLimit || entries.count + batch.count >= Self.entryLimit {
                guard let index = order.firstIndex(where: { !protected.contains($0) }) else { break }
                let old = order.remove(at: index)
                cost -= entries.removeValue(forKey: old)?.cost ?? 0
            }
            guard cost + reservedCost + reservation <= Self.byteLimit,
                  entries.count + batch.count < Self.entryLimit else { break }
            pending.removeFirst()
            reservedCost += reservation
            batch.append(key)
        }
        guard !batch.isEmpty else { return }
        isWorking = true
        let revision = generation, work = batch, prepare = prepare
        queue.async { [weak self] in
            let result = work.map { key in autoreleasepool { prepare(key) } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isWorking = false
                self.reservedCost = 0
                self.completedBatches += 1
                if self.generation == revision {
                    for (key, glyph) in zip(work, result) {
                        guard self.cost + glyph.cost <= Self.byteLimit, self.entries.count < Self.entryLimit else { continue }
                        self.entries[key] = glyph
                        self.order.append(key)
                        self.cost += glyph.cost
                    }
                } else {
                    self.rejectedResults += result.count
                }
                // Release a rejected batch before admitting the next allocation.
                DispatchQueue.main.async { [weak self] in self?.onPrepared?() }
            }
        }
    }
}
