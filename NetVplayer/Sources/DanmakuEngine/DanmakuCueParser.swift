// DanmakuEngine/DanmakuCueParser.swift
// Parses cached danmaku payloads into bounded SwiftUI-renderable cues.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum DanmakuCueMode: String, Codable, Sendable, Equatable {
    case scroll
    case top
    case bottom
}

public struct DanmakuCue: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var timeMs: Int
    public var text: String
    public var mode: DanmakuCueMode
    public var color: String

    public init(
        id: String = UUID().uuidString,
        timeMs: Int,
        text: String,
        mode: DanmakuCueMode = .scroll,
        color: String = "#FFFFFF"
    ) {
        self.id = id
        self.timeMs = max(0, timeMs)
        self.text = Self.truncated(text)
        self.mode = mode
        self.color = color.isEmpty ? "#FFFFFF" : color
    }

    private static func truncated(_ value: String, limit: Int = 100) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }
}

public enum DanmakuPayloadFailureCategory: String, Codable, Sendable, Equatable {
    case emptyPayload
    case invalidEncoding
    case invalidXML
    case invalidJSON
    case payloadTooLarge
}

public struct DanmakuPayloadParseDiagnostic: Codable, Sendable, Equatable {
    public var format: DanmakuTrackFormat
    public var rawSizeBytes: Int
    public var parsedCount: Int
    public var returnedCount: Int
    public var truncatedCount: Int
    public var failureCategory: DanmakuPayloadFailureCategory?

    public init(
        format: DanmakuTrackFormat,
        rawSizeBytes: Int,
        parsedCount: Int,
        returnedCount: Int,
        truncatedCount: Int,
        failureCategory: DanmakuPayloadFailureCategory? = nil
    ) {
        self.format = format
        self.rawSizeBytes = max(0, rawSizeBytes)
        self.parsedCount = max(0, parsedCount)
        self.returnedCount = max(0, returnedCount)
        self.truncatedCount = max(0, truncatedCount)
        self.failureCategory = failureCategory
    }
}

public struct DanmakuPayloadParseResult: Sendable, Equatable {
    public var cues: [DanmakuCue]
    public var diagnostic: DanmakuPayloadParseDiagnostic

    public init(cues: [DanmakuCue], diagnostic: DanmakuPayloadParseDiagnostic) {
        self.cues = cues
        self.diagnostic = diagnostic
    }
}

public enum DanmakuPayloadParser {
    public static let maxCueCount = 5_000
    public static let maximumPayloadBytes = 4 * 1_024 * 1_024

    public static func parse(payload: String, format: DanmakuTrackFormat, limit: Int = maxCueCount) -> [DanmakuCue] {
        parseWithDiagnostic(payload: payload, format: format, limit: limit).cues
    }

    public static func parseWithDiagnostic(
        payload: String,
        format: DanmakuTrackFormat,
        limit: Int = maxCueCount
    ) -> DanmakuPayloadParseResult {
        let cappedLimit = max(0, min(maxCueCount, limit))
        let rawSize = payload.utf8.count
        guard rawSize <= maximumPayloadBytes else {
            return emptyResult(format: format, rawSize: rawSize, failure: .payloadTooLarge)
        }
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return emptyResult(format: format, rawSize: rawSize, failure: .emptyPayload)
        }
        guard cappedLimit > 0 else {
            return emptyResult(format: format, rawSize: rawSize, failure: nil)
        }
        let cues: [DanmakuCue]
        let failureCategory: DanmakuPayloadFailureCategory?
        let parsedCount: Int
        switch format {
        case .xml:
            let result = parseXML(payload)
            cues = result.cues
            failureCategory = result.failureCategory
            parsedCount = result.parsedCount
        case .json:
            let result = parseJSON(payload)
            cues = result.cues
            failureCategory = result.failureCategory
            parsedCount = result.parsedCount
        case .text:
            let result = parseText(payload)
            cues = result.cues
            parsedCount = result.total
            failureCategory = nil
        }
        let sorted = cues.sorted { $0.timeMs < $1.timeMs }
        let returned = Array(sorted.prefix(cappedLimit))
        let diagnostic = DanmakuPayloadParseDiagnostic(
            format: format,
            rawSizeBytes: rawSize,
            parsedCount: parsedCount,
            returnedCount: returned.count,
            truncatedCount: max(0, parsedCount - returned.count),
            failureCategory: failureCategory
        )
        return DanmakuPayloadParseResult(cues: returned, diagnostic: diagnostic)
    }

    private static func parseXML(_ payload: String) -> (cues: [DanmakuCue], failureCategory: DanmakuPayloadFailureCategory?, parsedCount: Int) {
        guard let data = payload.data(using: .utf8) else { return ([], .invalidEncoding, 0) }
        let delegate = XMLDanmakuDelegate()
        guard !payload.localizedCaseInsensitiveContains("<!ENTITY"), !payload.localizedCaseInsensitiveContains("<!DOCTYPE") else { return ([], .invalidXML, 0) }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return ([], .invalidXML, 0) }
        return (delegate.accumulator.cues, nil, delegate.accumulator.total)
    }

    private static func parseJSON(_ payload: String) -> (cues: [DanmakuCue], failureCategory: DanmakuPayloadFailureCategory?, parsedCount: Int) {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return ([], .invalidJSON, 0)
        }
        var accumulator = DanmakuCueAccumulator()
        for object in cueObjects(in: root) {
            if let cue = cueFromJSONObject(object) { accumulator.append(cue) }
        }
        return (accumulator.cues, nil, accumulator.total)
    }

    private static func cueObjects(in root: Any) -> [Any] {
        if let array = root as? [Any] { return array }
        guard let object = root as? [String: Any] else { return [] }
        for key in ["comments", "data", "items", "danmaku", "list"] {
            if let array = object[key] as? [Any] { return array }
        }
        return [object]
    }

    private static func cueFromJSONObject(_ item: Any) -> DanmakuCue? {
        guard let object = item as? [String: Any] else { return nil }
        let text = stringValue(object["text"])
            ?? stringValue(object["content"])
            ?? stringValue(object["m"])
            ?? stringValue(object["message"])
            ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let seconds = doubleValue(object["time"])
            ?? doubleValue(object["timeSec"])
            ?? doubleValue(object["at"])
        let millis = intValue(object["timeMs"])
            ?? intValue(object["progress"])
            ?? seconds.map { milliseconds($0) }
            ?? 0
        let mode = modeValue(object["mode"])
        let color = colorValue(object["color"])
        return DanmakuCue(timeMs: millis, text: text, mode: mode, color: color)
    }

    private static func parseText(_ payload: String) -> DanmakuCueAccumulator {
        var accumulator = DanmakuCueAccumulator()
        payload.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            for separator: Character in ["|", ",", "\t"] {
                if let index = trimmed.firstIndex(of: separator) {
                    let text = String(trimmed[trimmed.index(after: index)...])
                    accumulator.append(DanmakuCue(timeMs: parseTimeMillis(String(trimmed[..<index])), text: text))
                    return
                }
            }
            accumulator.append(DanmakuCue(timeMs: 0, text: trimmed))
        }
        return accumulator
    }

    fileprivate static func cueFromBilibili(attributes: [String: String], text: String) -> DanmakuCue? {
        let values = (attributes["p"] ?? "").split(separator: ",").map(String.init)
        let timeMs = values.first.flatMap { Double($0) }.map { milliseconds($0) } ?? 0
        let mode = values.count > 1 ? modeValue(values[1]) : .scroll
        let color = values.count > 3 ? colorValue(values[3]) : "#FFFFFF"
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return DanmakuCue(timeMs: timeMs, text: text, mode: mode, color: color)
    }

    fileprivate static func parseTimeMillis(_ value: String) -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed) {
            return milliseconds(seconds)
        }
        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return 0 }
        let seconds: Double
        if parts.count == 3 {
            seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        } else if parts.count == 2 {
            seconds = parts[0] * 60 + parts[1]
        } else {
            seconds = parts[0]
        }
        return milliseconds(seconds)
    }

    private static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(86_400_000, max(0, seconds * 1_000)).rounded())
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func modeValue(_ value: Any?) -> DanmakuCueMode {
        let raw = stringValue(value)?.lowercased() ?? ""
        switch raw {
        case "5", "top":
            return .top
        case "4", "bottom":
            return .bottom
        default:
            return .scroll
        }
    }

    private static func colorValue(_ value: Any?) -> String {
        guard let text = stringValue(value), !text.isEmpty else { return "#FFFFFF" }
        if text.hasPrefix("#") { return text }
        if let number = Int(text) {
            return String(format: "#%06X", min(max(number, 0), 0xFFFFFF))
        }
        return text
    }

    private static func emptyResult(
        format: DanmakuTrackFormat,
        rawSize: Int,
        failure: DanmakuPayloadFailureCategory?
    ) -> DanmakuPayloadParseResult {
        DanmakuPayloadParseResult(
            cues: [],
            diagnostic: DanmakuPayloadParseDiagnostic(
                format: format,
                rawSizeBytes: rawSize,
                parsedCount: 0,
                returnedCount: 0,
                truncatedCount: 0,
                failureCategory: failure
            )
        )
    }
}

private final class XMLDanmakuDelegate: NSObject, XMLParserDelegate {
    private(set) var accumulator = DanmakuCueAccumulator()
    private var currentAttributes: [String: String]?
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "d" else { return }
        currentAttributes = attributeDict
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentAttributes != nil {
            currentText += string.prefix(max(0, 1_024 - currentText.count))
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "d", let attributes = currentAttributes else { return }
        if let cue = DanmakuPayloadParser.cueFromBilibili(attributes: attributes, text: currentText) {
            accumulator.append(cue)
        }
        currentAttributes = nil
        currentText = ""
    }
}

// Keep the earliest cues with a bounded max-heap, even when the payload is unsorted.
private struct DanmakuCueAccumulator {
    var cues: [DanmakuCue] = []
    var total = 0
    mutating func append(_ cue: DanmakuCue) {
        total += 1
        if cues.count < DanmakuPayloadParser.maxCueCount {
            cues.append(cue)
            var child = cues.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard cues[child].timeMs > cues[parent].timeMs else { break }
                cues.swapAt(child, parent)
                child = parent
            }
        } else if let latest = cues.first, cue.timeMs < latest.timeMs {
            cues[0] = cue
            var parent = 0
            while parent * 2 + 1 < cues.count {
                var child = parent * 2 + 1
                if child + 1 < cues.count, cues[child + 1].timeMs > cues[child].timeMs { child += 1 }
                guard cues[child].timeMs > cues[parent].timeMs else { break }
                cues.swapAt(parent, child)
                parent = child
            }
        }
    }
}
