import Foundation
import CryptoKit
import Models
import FileServiceEngine

public enum MediaFilenameParser {
    public static func parse(path: String, libraryKind: MediaLibraryKind) -> MediaMetadata {
        let file = (path as NSString).lastPathComponent
        var stem = (file as NSString).deletingPathExtension
        let episode = captures("(?i)(?:S(\\d{1,2})[ ._-]*E(\\d{1,3})|(\\d{1,2})x(\\d{1,3})|第(\\d{1,2})季[ ._-]*第(\\d{1,3})集)", stem)
        var season: Int?, number: Int?
        if let episode {
            season = episode.values[0].flatMap(Int.init) ?? episode.values[2].flatMap(Int.init) ?? episode.values[4].flatMap(Int.init)
            number = episode.values[1].flatMap(Int.init) ?? episode.values[3].flatMap(Int.init) ?? episode.values[5].flatMap(Int.init)
            stem = String(stem.prefix(episode.offset))
        }
        let yearMatch = captures("(?:[ ._(\\[]|^)((?:19|20)\\d{2})(?:[ ._)\\]]|$)", stem)
        let year = yearMatch?.values.first.flatMap { $0 }.flatMap(Int.init)
        if let yearMatch { stem = String(stem.prefix(yearMatch.offset)) }
        stem = stem.replacingOccurrences(of: "(?i)[ ._-](?:2160p|1080p|720p|bluray|web[ ._-]?dl|remux|h264|h265|x264|x265|hevc|hdr|dv|chs|cht).*$", with: "", options: .regularExpression)
        stem = stem.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var originalTitle: String?
        // A bracketed Chinese title followed by the original title is common in NAS filenames.
        // Release group prefixes such as [BOBO] are not bilingual titles.
        if let bilingual = captures("^\\[([^\\]]+)\\]\\s*(.+)$", stem),
           let localized = bilingual.values[0], let original = bilingual.values[1],
           localized.range(of: "\\p{Han}", options: .regularExpression) != nil,
           original.range(of: "[A-Za-z]", options: .regularExpression) != nil {
            stem = localized; originalTitle = original.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: originalTitle == nil ? " -()[]" : " -"))
        let television = episode != nil || libraryKind == .television
        if television && (stem.isEmpty || Int(stem) != nil) {
            var folder = FileServicePath.parent(path)
            let parent = (folder as NSString).lastPathComponent
            if let match = captures("(?i)(?:season|s|第)[ ._-]*(\\d{1,2})", parent) {
                season = season ?? match.values[0].flatMap(Int.init); folder = FileServicePath.parent(folder)
            }
            stem = (folder as NSString).lastPathComponent
        }
        if stem.isEmpty { stem = (file as NSString).deletingPathExtension }
        return .init(title: stem, originalTitle: originalTitle, year: year, kind: television ? .television : .movies,
                     showTitle: television ? stem : nil, season: television ? (season ?? 1) : nil, episode: number)
    }
    public static func normalizedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "(?<=[A-Za-z0-9])\\s*&\\s*(?=[A-Za-z0-9])", with: " and ", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func captures(_ pattern: String, _ text: String) -> (values: [String?], offset: Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let full = Range(match.range, in: text) else { return nil }
        return ((1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }, text.distance(from: text.startIndex, to: full.lowerBound))
    }
}

public enum NFOMetadataParser {
    public static let maximumBytes = 1024 * 1024
    public static func parse(_ data: Data) throws -> MediaMetadata {
        guard data.count <= maximumBytes else { throw FileServiceError.protocolFailure("NFO 超过 1 MiB 上限") }
        guard let text = String(data: data, encoding: .utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw FileServiceError.protocolFailure("NFO 不允许外部实体或 DTD") }
        let delegate = NFODocument()
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw FileServiceError.protocolFailure("NFO XML 无效") }
        var result = delegate.metadata
        if result.doubanID == nil, let range = text.range(of: "(?:movie\\.)?douban\\.com/subject/(\\d+)", options: .regularExpression) {
            result.doubanID = text[range].split(separator: "/").last.map(String.init)
        }
        return result
    }
}

private final class NFODocument: NSObject, XMLParserDelegate {
    var metadata = MediaMetadata()
    private var stack: [(String, [String: String], String)] = []
    private var ratingSource: String?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append((name, attributes, ""))
        if name == "movie" { metadata.kind = .movies }
        if name == "tvshow" || name == "episodedetails" { metadata.kind = .television }
        if name == "rating" { ratingSource = attributes["name"]?.lowercased() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !stack.isEmpty { stack[stack.count - 1].2 += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if let text = String(data: CDATABlock, encoding: .utf8), !stack.isEmpty { stack[stack.count - 1].2 += text } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { if name == "rating" { ratingSource = nil } }
        guard let element = stack.popLast() else { return }
        let value = element.2.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch name {
        case "title": if metadata.title == nil { metadata.title = value }
        case "showtitle": metadata.showTitle = value
        case "year": metadata.year = Int(value)
        case "season": metadata.season = Int(value)
        case "episode": metadata.episode = Int(value)
        case "plot": metadata.plot = value
        case "tmdbid": metadata.tmdbID = value
        case "doubanid": metadata.doubanID = value
        case "uniqueid":
            if element.1["type"]?.lowercased() == "tmdb" { metadata.tmdbID = value }
            if element.1["type"]?.lowercased() == "douban" { metadata.doubanID = value }
        case "thumb":
            if stack.contains(where: { $0.0 == "fanart" }) { if metadata.fanart == nil { metadata.fanart = Self.imageURL(value) } }
            else if metadata.poster == nil { metadata.poster = Self.imageURL(value) }
        case "value":
            if ratingSource == "tmdb" { metadata.tmdbRating = Double(value) }
            if ratingSource == "douban" { metadata.doubanRating = Double(value) }
        default: break
        }
    }
    private static func imageURL(_ value: String) -> String? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { return nil }
        return value
    }
}

public actor MediaArtworkCache {
    public static let shared = MediaArtworkCache()
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NetVplayer/LibraryArtwork")
    }
    public func importPoster(url: URL) throws -> String {
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw FileServiceError.protocolFailure("海报超过 4 MiB 上限") }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(key).appendingPathExtension(url.pathExtension)
        try data.write(to: target, options: .atomic); return target.absoluteString
    }
    public func cache(entry: FileEntry, reference: FileResourceReference, client: any FileServiceClient) async throws -> String {
        guard entry.size > 0, entry.size <= 4 * 1024 * 1024 else { throw FileServiceError.protocolFailure("图片超过 4 MiB 上限") }
        let material = reference.locator + "|" + String(entry.size) + "|" + String(entry.modifiedAt?.timeIntervalSince1970 ?? 0) + "|" + (entry.version ?? "")
        let key = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent(key).appendingPathExtension((entry.name as NSString).pathExtension)
        if FileManager.default.fileExists(atPath: target.path) { return target.absoluteString }
        let data = try await client.read(path: entry.path, range: 0..<entry.size)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic); return target.absoluteString
    }
}
