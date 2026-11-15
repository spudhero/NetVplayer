import Foundation
import Models

enum EPGHistoryMerge {
    static let historyDays = 7
    static func window(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-Double(historyDays) * 86_400), end: now.addingTimeInterval(8 * 86_400))
    }

    /// New intervals replace overlapping old programmes as whole records, never clipped fragments.
    static func items(old: [EpgItem], new: [EpgItem], now: Date) -> [EpgItem] {
        let window = window(now: now)
        let fresh = new.filter { $0.end > window.start && $0.start < window.end }.sorted { $0.start < $1.start }
        let history = old.filter { $0.end > window.start && $0.end <= now }.sorted { $0.start < $1.start }
        var merged = fresh, index = 0, seen = Set(fresh.map(\.id))
        for item in history {
            while index < fresh.count, fresh[index].end <= item.start { index += 1 }
            guard index == fresh.count || fresh[index].start >= item.end else { continue }
            if seen.insert(item.id).inserted { merged.append(item) }
        }
        return merged.sorted { $0.start < $1.start }
    }

    /// One channel at a time, at most 18 UTC buckets per generation and 2 × indexBytes read overall.
    static func write(fresh: URL, previous: URL?, channels: [String: String], previousChannels: [String: String],
                      destination: URL, limits: EPGImportLimits, now: Date,
                      freshWriter: XMLTVIndexWriter) throws -> Int {
        let writer = XMLTVIndexWriter(directory: destination, limits: limits)
        let window = window(now: now)
        let days = (XMLTVIndex.day(window.start) - 2)...XMLTVIndex.day(window.end)
        var readBytes = 0
        var remainingItems = max(0, limits.programmeCount - freshWriter.programmeCount)
        var remainingBytes = max(0, limits.indexBytes - freshWriter.byteCount)
        var bucketBytes = freshWriter.fileBytes
        func read(_ directory: URL?, channel: String) throws -> [EpgItem] {
            guard let directory else { return [] }
            var items: [EpgItem] = []
            for day in days {
                try Task.checkCancellation()
                let file = directory.appendingPathComponent(XMLTVIndex.filename(channel: channel, day: day))
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let data = try XMLTVIndex.boundedData(file, maximumBytes: min(512 * 1_024, max(0, limits.indexBytes * 2 - readBytes)))
                readBytes += data.count
                for line in data.split(separator: 10) {
                    guard items.count < limits.programmeCount else { throw EPGImportError.limitExceeded }
                    items.append(try JSONDecoder().decode(EpgItem.self, from: Data(line)))
                }
            }
            return items
        }
        // Only channels present in the new feed survive; a removed channel cannot reappear later.
        for channel in channels.keys.sorted() {
            let new = try read(fresh, channel: channel)
            let old = try read(previousChannels[channel] == nil ? nil : previous, channel: channel)
            let freshIDs = Set(new.map(\.id))
            // Reserve all fresh records first. Under pressure evict retained history, newest first
            // within each channel, with deterministic channel order across the feed.
            let history = items(old: old, new: new, now: now).filter { !freshIDs.contains($0.id) }.reversed()
            var retained: [EpgItem] = []
            for item in history {
                let bytes = try JSONEncoder().encode(item).count + 1
                let bucket = XMLTVIndex.filename(channel: channel, day: XMLTVIndex.day(item.start))
                guard remainingItems > 0, bytes <= remainingBytes, bucketBytes[bucket, default: 0] + bytes <= 512 * 1_024 else { continue }
                remainingItems -= 1; remainingBytes -= bytes; bucketBytes[bucket, default: 0] += bytes
                retained.append(item)
            }
            let merged = new + retained
            for offset in stride(from: 0, to: merged.count, by: max(1, limits.batchCount)) {
                try writer.append(merged[offset..<min(merged.count, offset + max(1, limits.batchCount))].map { XMLTVProgramme(channelID: channel, item: $0) })
            }
        }
        return writer.byteCount
    }
}
