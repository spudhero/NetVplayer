import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Models
import MPVShim

public enum SubtitleRecognitionError: Error, Sendable {
    case unsupported, modelRequired, invalidInput, limitExceeded, changedInput, invalidResponse, expired
}
public enum SubtitleRecognitionKind: String, Sendable { case pgs, audio }
public struct SubtitleRecognitionUnit: Sendable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let inputStart: Double
    public let inputEnd: Double
}
public enum SubtitleRecognitionPayload: Sendable {
    case bitmap(Data)
    case audio(Data, sampleRate: Int, channels: Int, float: Bool)
}

/// Immutable local input. No media URL, credentials, or filenames enter cache keys.
public final class SubtitleRecognitionSource: Sendable {
    public let kind: SubtitleRecognitionKind
    public let units: [SubtitleRecognitionUnit]
    public let fingerprint: String
    public let name: String
    private let images: [Data]
    private let reader: RecognitionFileReader
    private let wave: RecognitionWave?
    private init(kind: SubtitleRecognitionKind, units: [SubtitleRecognitionUnit], fingerprint: String,
                 images: [Data] = [], reader: RecognitionFileReader, wave: RecognitionWave? = nil, name: String) {
        self.kind = kind; self.units = units; self.fingerprint = fingerprint
        self.images = images; self.reader = reader; self.wave = wave; self.name = name
    }

    public static func load(file: URL, library: String, budget: PlaybackBackgroundBudget = .shared) async throws -> Self {
        guard file.isFileURL, ["sup", "wav"].contains(file.pathExtension.lowercased()) else { throw SubtitleRecognitionError.unsupported }
        let reader = try RecognitionFileReader(file: file, budget: budget)
        if file.pathExtension.lowercased() == "sup", reader.size > 16 * 1024 * 1024 { throw SubtitleRecognitionError.limitExceeded }
        let readSession = PlaybackReadSession()
        let owner = readSession.makeOwner(mediaIdentity: .init(source: "recognition", account: "local", item: UUID().uuidString), purpose: .subtitleExtraction)
        defer { readSession.stop() }
        var hash = SHA256()
        for offset in stride(from: Int64(0), to: reader.size, by: 512 * 1024) {
            let data = try await reader.read(offset..<min(reader.size, offset + 512 * 1024), owner: owner)
            hash.update(data: data)
        }
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if file.pathExtension.lowercased() == "sup" {
            guard reader.size <= 16 * 1024 * 1024 else { throw SubtitleRecognitionError.limitExceeded }
            let data = try await reader.read(0..<reader.size, owner: owner)
            let decoded = try await budget.withRead(purpose: .subtitleExtraction, bytes: Int64(data.count)) {
                let task = Task.detached(priority: .utility) { try decodePGS(data, library: library) }
                return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            }
            return Self(kind: .pgs, units: decoded.0, fingerprint: fingerprint, images: decoded.1, reader: reader, name: file.lastPathComponent)
        }
        guard file.pathExtension.lowercased() == "wav" else { throw SubtitleRecognitionError.unsupported }
        let wave = try await RecognitionWave.read(reader: reader, owner: owner)
        let duration = Double(wave.frames) / Double(wave.rate)
        var units: [SubtitleRecognitionUnit] = []
        // Independent core windows plus one second of acoustic context each side.
        for start in stride(from: 0.0, to: duration, by: 20) {
            units.append(.init(id: units.count, start: start, end: min(duration, start + 20),
                inputStart: max(0, start - 1), inputEnd: min(duration, start + 21)))
        }
        guard !units.isEmpty, units.count <= SubtitleDocument.maximumCues else { throw SubtitleRecognitionError.limitExceeded }
        return Self(kind: .audio, units: units, fingerprint: fingerprint, reader: reader, wave: wave, name: file.lastPathComponent)
    }

    public func payload(for unit: SubtitleRecognitionUnit, owner: PlaybackReadOwner) async throws -> SubtitleRecognitionPayload {
        try owner.check()
        guard units.indices.contains(unit.id) else { throw SubtitleRecognitionError.invalidInput }
        if kind == .pgs { return .bitmap(images[unit.id]) }
        guard let wave else { throw SubtitleRecognitionError.invalidInput }
        let first = Int64((unit.inputStart * Double(wave.rate)).rounded())
        let last = min(wave.frames, Int64((unit.inputEnd * Double(wave.rate)).rounded()))
        let data = try await reader.read((wave.offset + first * wave.frameBytes)..<(wave.offset + last * wave.frameBytes), owner: owner)
        return .audio(data, sampleRate: wave.rate, channels: wave.channels, float: wave.float)
    }

    public func cacheDocument() throws -> SubtitleDocument {
        try SubtitleDocument(cues: units.map { SubtitleCue(id: $0.id, start: $0.start, end: $0.end,
            text: "\(kind.rawValue):\(fingerprint):\($0.id):\($0.inputStart):\($0.inputEnd)") })
    }

    private static func decodePGS(_ data: Data, library: String) throws -> ([SubtitleRecognitionUnit], [Data]) {
        try data.withUnsafeBytes { bytes in
            guard let decoder = nv_subtitle_bitmap_create(library, bytes.bindMemory(to: UInt8.self).baseAddress, data.count) else { throw SubtitleRecognitionError.unsupported }
            defer { nv_subtitle_bitmap_free(decoder) }
            var units: [SubtitleRecognitionUnit] = [], images: [Data] = []
            var pending: (Double, Data)?
            var total = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while true {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SubtitleRecognitionError.expired }
                var bitmap = NVSubtitleBitmap()
                let result = nv_subtitle_bitmap_next(decoder, &bitmap)
                guard result >= 0 else { throw SubtitleRecognitionError.invalidInput }
                if result == 0 { break }
                if let previous = pending {
                    guard bitmap.position > previous.0 else { throw SubtitleRecognitionError.invalidInput }
                    units.append(.init(id: units.count, start: previous.0, end: bitmap.position, inputStart: previous.0, inputEnd: bitmap.position))
                    images.append(previous.1); pending = nil
                }
                if let pixels = bitmap.rgba, bitmap.width > 0, bitmap.height > 0 {
                    let w = Int(bitmap.width), h = Int(bitmap.height)
                    let raw = Data(bytes: pixels, count: w * h * 4)
                    guard let provider = CGDataProvider(data: raw as CFData),
                          let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw SubtitleRecognitionError.invalidInput }
                    let png = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { throw SubtitleRecognitionError.invalidInput }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw SubtitleRecognitionError.invalidInput }
                    total += png.length
                    guard total <= 32 * 1024 * 1024, units.count < SubtitleDocument.maximumCues else { throw SubtitleRecognitionError.limitExceeded }
                    pending = (bitmap.position, png as Data)
                }
            }
            // Do not invent a duration for a display without a closing PGS event.
            guard pending == nil, !units.isEmpty else { throw SubtitleRecognitionError.invalidInput }
            return (units, images)
        }
    }
}

/// A cancelled borrower leaves other borrowers alive. The last one cancels I/O.
/// All actual reads share the existing background queue and byte reservation.
private actor RecognitionFileReader {
    nonisolated let size: Int64
    private let file: URL
    private let stamp: Date
    private let budget: PlaybackBackgroundBudget
    private struct BorrowedRead { let shared: PlaybackSharedRead<Data>; var borrowers: Int }
    private var reads: [Range<Int64>: BorrowedRead] = [:]
    init(file: URL, budget: PlaybackBackgroundBudget) throws {
        guard file.isFileURL else { throw SubtitleRecognitionError.unsupported }
        let file=file.resolvingSymlinksInPath()
        let values = try FileManager.default.attributesOfItem(atPath:file.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = (values[.size] as? NSNumber)?.int64Value, size > 0, size <= 512 * 1024 * 1024,
              let stamp = values[.modificationDate] as? Date else { throw SubtitleRecognitionError.limitExceeded }
        self.file = file; self.size = size; self.stamp = stamp; self.budget = budget
    }
    func read(_ range: Range<Int64>, owner: PlaybackReadOwner) async throws -> Data {
        try owner.check()
        guard range.lowerBound >= 0, range.upperBound <= size, !range.isEmpty,
              range.count <= PlaybackTransferProfile.backgroundByteLimit else { throw SubtitleRecognitionError.limitExceeded }
        let shared: PlaybackSharedRead<Data>
        if var existing = reads[range], !existing.shared.isCancelled {
            shared = existing.shared; existing.borrowers += 1; reads[range] = existing
        }
        else {
            let file = file, size = size, stamp = stamp, budget = budget
            let task = Task.detached(priority: .utility) {
                try await budget.withRead(owner: nil, purpose: .subtitleExtraction, bytes: Int64(range.count)) {
                    try Task.checkCancellation()
                    let values = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard (values[.size] as? NSNumber)?.int64Value == size, values[.modificationDate] as? Date == stamp else { throw SubtitleRecognitionError.changedInput }
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(range.lowerBound))
                    let data = try handle.read(upToCount: range.count) ?? Data()
                    try Task.checkCancellation()
                    let after = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard data.count == range.count, (after[.size] as? NSNumber)?.int64Value == size,
                          after[.modificationDate] as? Date == stamp else { throw SubtitleRecognitionError.changedInput }
                    return data
                }
            }
            shared = PlaybackSharedRead(task: task); reads[range] = BorrowedRead(shared: shared, borrowers: 1)
        }
        defer {
            if var existing = reads[range], existing.shared === shared {
                existing.borrowers -= 1
                if existing.borrowers == 0 { shared.cancel(); reads.removeValue(forKey: range) }
                else { reads[range] = existing }
            }
        }
        return try await owner.perform { try await shared.value(phase: .preload) }
    }
}

private struct RecognitionWave: Sendable {
    let offset: Int64, frames: Int64, frameBytes: Int64
    let rate: Int, channels: Int
    let float: Bool
    static func read(reader: RecognitionFileReader, owner: PlaybackReadOwner) async throws -> Self {
        let header = try await reader.read(0..<min(reader.size, 12), owner: owner)
        guard header.count == 12, String(decoding: header.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: header.suffix(4), as: UTF8.self) == "WAVE" else { throw SubtitleRecognitionError.unsupported }
        func u16(_ d: Data, _ i: Int) -> Int { Int(d[i]) | Int(d[i+1]) << 8 }
        func u32(_ d: Data, _ i: Int) -> Int64 { Int64(d[i]) | Int64(d[i+1]) << 8 | Int64(d[i+2]) << 16 | Int64(d[i+3]) << 24 }
        guard u32(header,4) + 8 == reader.size else { throw SubtitleRecognitionError.invalidInput }
        var offset: Int64 = 12, format: (Int,Int,Int,Bool)?, audio: (Int64,Int64)?
        for _ in 0..<256 {
            guard offset + 8 <= reader.size else { break }
            let chunk = try await reader.read(offset..<(offset+8), owner: owner)
            let length = u32(chunk,4), start = offset+8
            guard length <= reader.size-start else { throw SubtitleRecognitionError.invalidInput }
            switch String(decoding: chunk.prefix(4), as: UTF8.self) {
            case "fmt ":
                guard format == nil, length >= 16 else { throw SubtitleRecognitionError.invalidInput }
                let data = try await reader.read(start..<(start+16), owner: owner)
                let code=u16(data,0), channels=u16(data,2), rate=Int(u32(data,4)), bits=u16(data,14)
                guard (code == 1 && bits == 16) || (code == 3 && bits == 32), (1...2).contains(channels),
                      (8000...48000).contains(rate), u16(data,12) == channels*bits/8,
                      u32(data,8) == Int64(rate*channels*bits/8) else { throw SubtitleRecognitionError.unsupported }
                format = (rate,channels,channels*bits/8,code == 3)
            case "data":
                guard audio == nil, length > 0 else { throw SubtitleRecognitionError.invalidInput }
                audio = (start,length)
            default: break
            }
            offset = start + length + length%2
        }
        guard offset == reader.size, let format, let audio, audio.1 % Int64(format.2) == 0 else { throw SubtitleRecognitionError.invalidInput }
        return Self(offset: audio.0, frames: audio.1/Int64(format.2), frameBytes: Int64(format.2), rate: format.0, channels: format.1, float: format.3)
    }
}
