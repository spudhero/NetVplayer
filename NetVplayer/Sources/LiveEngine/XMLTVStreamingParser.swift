import Foundation
import Models

public struct EPGImportLimits: Sendable {
    public var downloadBytes = 32 * 1_024 * 1_024
    public var expandedBytes = 128 * 1_024 * 1_024
    public var programmeCount = 300_000
    public var channelCount = 4_000
    public var fieldBytes = 4_096
    public var batchCount = 256
    public var batchBytes = 512 * 1_024
    public var indexBytes = 128 * 1_024 * 1_024
    public init() {}
}

public enum EPGImportError: Error, Sendable { case limitExceeded, invalidXML, invalidGzip, invalidIndex }

public struct XMLTVProgramme: Codable, Sendable {
    public var channelID: String
    public var item: EpgItem
    public init(channelID: String, item: EpgItem) { self.channelID = channelID; self.item = item }
}

public enum XMLTVStreamingParser {
    /// Only the current batch and channel names remain resident while the caller stages its index.
    public static func parse(file: URL, limits: EPGImportLimits = .init(), window: DateInterval? = nil,
                             receive: @escaping ([XMLTVProgramme]) throws -> Void) throws -> [String: String] {
        let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limits.expandedBytes, let stream = InputStream(url: file) else { throw EPGImportError.limitExceeded }
        let delegate = BatchingXMLTVDelegate(limits: limits, window: window, receive: receive)
        let parser = XMLParser(stream: stream)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let completed = parser.parse()
        try Task.checkCancellation()
        if let error = delegate.failure { throw error }
        guard completed, delegate.sawTV else { throw EPGImportError.invalidXML }
        try delegate.flush()
        return delegate.channels
    }
}

private final class BatchingXMLTVDelegate: NSObject, XMLParserDelegate {
    let limits: EPGImportLimits
    let window: DateInterval?
    let receive: ([XMLTVProgramme]) throws -> Void
    var channels: [String: String] = [:]
    var failure: Error?
    var sawTV = false
    private var programmeCount = 0
    private var channelID: String?
    private var programme: XMLTVProgramme?
    private var field: String?
    private var text = ""
    private var depth = 0
    private var batch: [XMLTVProgramme] = []
    private var batchCost = 0
    private let dateParsers: [DateFormatter] = ["yyyyMMddHHmmss Z", "yyyyMMddHHmmssZ", "yyyyMMddHHmmss", "yyyyMMddHHmm"].map { format in
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = format
        parser.isLenient = false
        return parser
    }

    init(limits: EPGImportLimits, window: DateInterval?, receive: @escaping ([XMLTVProgramme]) throws -> Void) {
        self.limits = limits; self.window = window; self.receive = receive
    }

    private func fail(_ parser: XMLParser, _ error: Error) { failure = error; parser.abortParsing() }
    private func date(_ value: String?) -> Date? {
        guard let value, value.utf8.count <= 40 else { return nil }
        return dateParsers.lazy.compactMap { $0.date(from: value) }.first
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        do { try Task.checkCancellation() } catch { fail(parser, error); return }
        depth += 1
        guard depth <= 32, attributes.values.allSatisfy({ $0.utf8.count <= limits.fieldBytes }) else { fail(parser, EPGImportError.limitExceeded); return }
        if depth == 1 { sawTV = name == "tv" }
        switch name {
        case "channel":
            channelID = attributes["id"]
            if let id = channelID { register(id, parser: parser) }
        case "programme":
            programmeCount += 1
            guard programmeCount <= limits.programmeCount else { fail(parser, EPGImportError.limitExceeded); return }
            guard let id = attributes["channel"], let start = date(attributes["start"]), let end = date(attributes["stop"]),
                  end > start, end.timeIntervalSince(start) <= 2 * 86_400 else { programme = nil; return }
            register(id, parser: parser)
            if let window, end <= window.start || start >= window.end { programme = nil; return }
            programme = XMLTVProgramme(channelID: id, item: EpgItem(start: start, end: end))
        case "title", "display-name": field = name; text = ""
        default: break
        }
    }

    private func register(_ id: String, parser: XMLParser) {
        guard !id.isEmpty, id.utf8.count <= 512 else { fail(parser, EPGImportError.limitExceeded); return }
        if channels[id] == nil { channels[id] = id }
        if channels.count > limits.channelCount { fail(parser, EPGImportError.limitExceeded) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard field != nil else { return }
        guard text.utf8.count + string.utf8.count <= limits.fieldBytes else { fail(parser, EPGImportError.limitExceeded); return }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let string = String(data: data, encoding: .utf8) else { fail(parser, EPGImportError.invalidXML); return }
        self.parser(parser, foundCharacters: string)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if name == field {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "title", programme?.item.title.isEmpty == true { programme?.item.title = value }
            if name == "display-name", let id = channelID, channels[id] == id, !value.isEmpty { channels[id] = value }
            field = nil; text = ""
        }
        if name == "channel" { channelID = nil }
        if name == "programme" {
            defer { programme = nil }
            guard let programme, !programme.item.title.isEmpty else { return }
            let cost = programme.channelID.utf8.count + programme.item.title.utf8.count + 128
            do {
                guard cost <= limits.batchBytes else { throw EPGImportError.limitExceeded }
                if !batch.isEmpty, batchCost + cost > limits.batchBytes { try flush() }
                batch.append(programme); batchCost += cost
                if batch.count >= limits.batchCount { try flush() }
            } catch { fail(parser, error) }
        }
    }

    func flush() throws {
        try Task.checkCancellation()
        guard !batch.isEmpty else { return }
        try receive(batch)
        batch.removeAll(keepingCapacity: true); batchCost = 0
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { fail(parser, EPGImportError.invalidXML) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(parser, EPGImportError.invalidXML) }
}
