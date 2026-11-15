import Foundation
import Models

enum XtreamEPGParser {
    static func positive(_ value: JSONDynamicValue?) -> Bool { value == .bool(true) || value?.stringValue == "1" }

    static func item(_ value: JSONDynamicValue, timeZone: TimeZone?) throws -> EpgItem {
        guard case .object(let row) = value else { throw XtreamError.malformedResponse }
        func date(_ epoch: JSONDynamicValue?, _ text: JSONDynamicValue?) throws -> Date {
            if let epoch, epoch != .null {
                guard let seconds = Double(epoch.stringValue), seconds.isFinite, seconds > 0, seconds < 1e12 else { throw XtreamError.malformedResponse }
                return Date(timeIntervalSince1970: seconds)
            }
            guard let timeZone else { throw LiveCatchupUnavailableReason.serverTimeZoneUnknown }
            guard let raw = text?.stringValue, let date = XtreamArchivePolicy.instant(raw, timeZone: timeZone) else {
                throw LiveCatchupUnavailableReason.ambiguousArchiveTime
            }
            return date
        }
        let start = try date(row["start_timestamp"], row["start"])
        let end = try date(row["stop_timestamp"] ?? row["end_timestamp"], row["end"] ?? row["stop"])
        let raw = row["title"]?.stringValue ?? ""
        let title = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? raw
        guard end > start, end.timeIntervalSince(start) <= 2 * 86_400,
              !title.isEmpty, title.utf8.count <= 4_096 else { throw XtreamError.malformedResponse }
        return EpgItem(title: title, start: start, end: end)
    }

    static func history(_ response: JSONDynamicValue, timeZone: TimeZone?, resource: String, scope: String, session: UUID) throws -> EpgData {
        guard case .object(let root) = response, case .array(let rows) = root["epg_listings"], rows.count <= 2_048 else {
            throw XtreamError.malformedResponse
        }
        var items: [EpgItem] = [], seen = Set<String>()
        for row in rows {
            try Task.checkCancellation()
            var programme = try item(row, timeZone: timeZone)
            guard case .object(let fields) = row else { throw XtreamError.malformedResponse }
            // Conflicting duplicate times could grant the wrong permission; reject atomically.
            let key = "\(programme.start.timeIntervalSince1970)"
            guard seen.insert(key).inserted else { throw XtreamError.malformedResponse }
            programme.xtreamArchive = .init(resource: resource, scope: scope, session: session, hasArchive: positive(fields["has_archive"]))
            items.append(programme)
        }
        return EpgData(items: items.sorted { $0.start < $1.start })
    }
}
