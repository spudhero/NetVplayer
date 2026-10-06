import Foundation
import CryptoKit
import Models

struct XMLTVIndexManifest: Codable, Sendable {
    var version = 1
    var generation: String
    var importedAt: Date
    var channels: [String: String]
    var window: DateInterval
    var indexBytes: Int
}

enum XMLTVIndex {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func day(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 86_400)) }
    static func filename(channel: String, day: Int) -> String { "\(digest(channel))-\(day).jsonl" }

    static func read(_ type: XMLTVIndexManifest.Type, from url: URL) throws -> XMLTVIndexManifest {
        let data = try boundedData(url, maximumBytes: 4 * 1_024 * 1_024)
        let manifest = try JSONDecoder().decode(type, from: data)
        guard manifest.version == 1, UUID(uuidString: manifest.generation) != nil, manifest.channels.count <= 4_000 else { throw EPGImportError.invalidIndex }
        return manifest
    }

    static func boundedData(_ url: URL, maximumBytes: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw EPGImportError.limitExceeded }
        return data
    }

    static func query(manifest: XMLTVIndexManifest, directory: URL, channelID: String, channelName: String,
                      window: DateInterval, maximumItems: Int = 128) throws -> EpgData {
        guard window.duration > 0, window.duration <= 2 * 86_400,
              window.start.timeIntervalSince1970.isFinite, abs(window.start.timeIntervalSince1970) < 1e12 else { throw EPGImportError.limitExceeded }
        let key: String?
        if manifest.channels[channelID] != nil { key = channelID }
        else {
            let candidates = manifest.channels.filter {
                $0.key.caseInsensitiveCompare(channelID) == .orderedSame || $0.value.caseInsensitiveCompare(channelName) == .orderedSame
            }
            key = candidates.count == 1 ? candidates.first?.key : nil
        }
        guard let key else { return EpgData(channelName: channelName) }
        var items: [EpgItem] = []
        var seen = Set<String>()
        // Include the preceding UTC day for programmes crossing midnight.
        for day in (day(window.start) - 2)...day(window.end) {
            let file = directory.appendingPathComponent(filename(channel: key, day: day))
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let data = try boundedData(file, maximumBytes: 512 * 1_024)
            for line in data.split(separator: 10) {
                let item = try JSONDecoder().decode(EpgItem.self, from: Data(line))
                guard item.start < window.end, item.end > window.start, seen.insert(item.id).inserted else { continue }
                items.append(item)
            }
        }
        return EpgData(channelName: manifest.channels[key] ?? channelName,
                       items: Array(items.sorted { $0.start < $1.start }.prefix(max(0, min(256, maximumItems)))))
    }
}

final class XMLTVIndexWriter {
    let directory: URL
    let limits: EPGImportLimits
    private(set) var byteCount = 0
    private var fileBytes: [String: Int] = [:]
    init(directory: URL, limits: EPGImportLimits) { self.directory = directory; self.limits = limits }

    func append(_ batch: [XMLTVProgramme]) throws {
        var files: [String: Data] = [:]
        for programme in batch {
            let filename = XMLTVIndex.filename(channel: programme.channelID, day: XMLTVIndex.day(programme.item.start))
            var data = try JSONEncoder().encode(programme.item)
            data.append(10)
            guard data.count <= limits.indexBytes - byteCount,
                  fileBytes[filename, default: 0] + data.count <= 512 * 1_024 else { throw EPGImportError.limitExceeded }
            byteCount += data.count
            fileBytes[filename, default: 0] += data.count
            files[filename, default: Data()].append(data)
        }
        for (name, data) in files {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else { try data.write(to: url, options: .withoutOverwriting) }
        }
    }
}
