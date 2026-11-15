import Foundation
import Models

/// Date endpoints use source-local calendar dates; UI dates remain device-local.
public struct TVBoxEPGRequest: Sendable {
    public let date: String
    public let timeZone: TimeZone
    public let channelID: String
    public let channelName: String

    public init(date: String, timeZone: TimeZone, channelID: String, channelName: String) {
        self.date = date; self.timeZone = timeZone; self.channelID = channelID; self.channelName = channelName
    }

    public static func dates(window: DateInterval, timeZone: TimeZone) throws -> [String] {
        guard window.duration > 0, window.duration <= 86_400,
              window.start.timeIntervalSince1970.isFinite, abs(window.start.timeIntervalSince1970) < 1e12 else {
            throw EPGImportError.limitExceeded
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        // A programme returned for yesterday can extend into the selected day.
        guard var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: window.start)) else {
            throw EPGImportError.invalidDate
        }
        let formatter = formatter(timeZone)
        var result: [String] = []
        while day < window.end {
            guard result.count < 4, let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else {
                throw EPGImportError.limitExceeded
            }
            result.append(formatter.string(from: day)); day = next
        }
        return result
    }

    static func formatter(_ zone: TimeZone) -> DateFormatter {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian); value.timeZone = zone
        value.dateFormat = "yyyy-MM-dd"; value.isLenient = false
        return value
    }
}

public enum TVBoxEPGParser {
    public static let maximumBytes = 2 * 1_024 * 1_024
    public static let maximumItems = 2_048
    private struct Response: Decodable { let date: String; let epg_data: [Row] }
    private struct Row: Decodable { let start: String; let end: String; let title: String }

    /// A malformed/date-mismatched response never replaces an earlier successful date.
    public static func parse(data: Data, request: TVBoxEPGRequest) throws -> EpgData {
        guard data.count <= maximumBytes else { throw EPGImportError.limitExceeded }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw EPGImportError.invalidJSON }
        guard response.date == request.date, response.epg_data.count <= maximumItems else { throw EPGImportError.invalidDate }
        let formatter = TVBoxEPGRequest.formatter(request.timeZone)
        guard request.date.count == 10, let day = formatter.date(from: request.date), formatter.string(from: day) == request.date else {
            throw EPGImportError.invalidDate
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = request.timeZone
        var items: [EpgItem] = []
        for row in response.epg_data {
            try Task.checkCancellation()
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.utf8.count <= 4_096,
                  let startClock = clock(row.start, allow24: false), let endClock = clock(row.end, allow24: true) else {
                throw EPGImportError.invalidDate
            }
            let endDay = endClock == 86_400 || endClock < startClock
                ? calendar.date(byAdding: .day, value: 1, to: day) : day
            guard let endDay, let start = instant(day: day, seconds: startClock, calendar: calendar),
                  let end = instant(day: endDay, seconds: endClock % 86_400, calendar: calendar), end > start else {
                throw EPGImportError.invalidDate
            }
            items.append(EpgItem(title: title, start: start, end: end))
        }
        return EpgData(channelName: request.channelName, items: items.sorted { $0.start < $1.start })
    }

    private static func clock(_ text: String, allow24: Bool) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.count == 2 && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), let second = parts.count == 3 ? Int(parts[2]) : 0,
              minute < 60, second < 60 else { return nil }
        if hour == 24 { return allow24 && minute == 0 && second == 0 ? 86_400 : nil }
        return hour < 24 ? hour * 3_600 + minute * 60 + second : nil
    }

    private static func instant(day: Date, seconds: Int, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = seconds / 3_600; components.minute = seconds / 60 % 60; components.second = seconds % 60
        let before = day.addingTimeInterval(-1)
        let first = calendar.nextDate(after: before, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.nextDate(after: before, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last)
        // Do not invent a location for nonexistent or repeated local wall times.
        guard let first, first == last, calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: first) == components else { return nil }
        return first
    }
}
