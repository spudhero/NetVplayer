import Foundation
import Models
import Storage

public actor WebDAVClient: FileServiceClient {
    private let configuration: FileServiceConfiguration
    private let base: URL
    private let headers: [String: String]
    private let transport: FileHTTPTransport
    public init(configuration: FileServiceConfiguration, credentials: FileServiceCredentials = .init(), session: URLSession? = nil,
                additionalHeaders: [String: String] = [:]) throws {
        self.configuration = try configuration.validated()
        guard let base = URL(string: self.configuration.address) else { throw FileServiceError.invalidConfiguration("WebDAV 地址无效") }
        self.base = base; self.transport = FileHTTPTransport(session: session)
        var headers = additionalHeaders
        if !credentials.username.isEmpty {
            headers["Authorization"] = "Basic " + Data((credentials.username + ":" + credentials.password).utf8).base64EncodedString()
        }
        self.headers = headers
    }
    private func url(_ path: String) throws -> URL {
        let relative = try FileServicePath.join(configuration.rootPath, path)
        return base.appendingPathComponent(String(relative.dropFirst()))
    }
    public func connect() async throws { _ = try await list(path: "/", cursor: nil) }
    public func list(path: String, cursor: String?) async throws -> FileEntryPage {
        let target = try url(path)
        let requestHeaders = headers.merging(["Depth": "1", "Content-Type": "application/xml"]) { _, new in new }
        let body = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>".utf8)
        let (data, _) = try await transport.request(target, method: "PROPFIND", headers: requestHeaders, body: body)
        let parser = DAVDirectoryParser()
        let xml = XMLParser(data: data); xml.shouldProcessNamespaces = true; xml.shouldResolveExternalEntities = false; xml.delegate = parser
        guard xml.parse(), !parser.items.isEmpty else { throw FileServiceError.protocolFailure("WebDAV 返回了无效目录 XML") }
        let rootURL = try url("/")
        let rootPrefix = rootURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetPath = target.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var entries: [FileEntry] = []
        for item in parser.items {
            guard let href = URL(string: item.href, relativeTo: target)?.absoluteURL,
                  FileHTTPRedirectDelegate.sameOrigin(base, href) else { continue }
            let serverPath = href.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if item.denied { throw FileServiceError.permission(path) }
            if serverPath == targetPath {
                guard item.directory else { throw FileServiceError.path(path) }
                continue
            }
            guard rootPrefix.isEmpty || serverPath.hasPrefix(rootPrefix + "/") else { continue }
            let relative = rootPrefix.isEmpty ? serverPath : String(serverPath.dropFirst(rootPrefix.count + 1))
            let name = href.lastPathComponent
            guard !name.isEmpty else { continue }
            entries.append(.init(path: try FileServicePath.normalize(relative), name: name,
                isDirectory: item.directory, size: item.size, modifiedAt: item.modified, version: item.etag))
        }
        return .init(entries: entries)
    }
    public func stat(path: String) async throws -> FileEntry {
        if path == "/" { return .init(path: "/", name: configuration.name, isDirectory: true) }
        guard let item = try await allEntries(path: FileServicePath.parent(path)).first(where: { $0.path == path }) else { throw FileServiceError.path(path) }
        return item
    }
    public func read(path: String, range: Range<Int64>) async throws -> Data {
        guard !range.isEmpty, range.lowerBound >= 0, range.count <= 4 * 1024 * 1024 else { return Data() }
        let headers = headers.merging(["Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)"]) { _, new in new }
        let (data, response) = try await transport.request(url(path), headers: headers, maximumBytes: Int(range.count))
        guard response.statusCode == 206 || range.lowerBound == 0 else { throw FileServiceError.protocolFailure("服务器不支持范围读取") }
        return data
    }
    public func resolve(path: String) async throws -> ResolvedFileResource { .init(url: try url(path), headers: headers) }
}

private final class DAVDirectoryParser: NSObject, XMLParserDelegate {
    struct Item { var href = ""; var directory = false; var size: Int64 = 0; var modified: Date?; var etag: String?; var denied = false }
    var items: [Item] = []
    private var current: Item?; private var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "response" { current = Item() }
        if name == "collection" { current?.directory = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href": current?.href = value
        case "getcontentlength": current?.size = Int64(value) ?? 0
        case "getetag": current?.etag = value
        case "getlastmodified":
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            current?.modified = formatter.date(from: value)
        case "status": if value.contains(" 401 ") || value.contains(" 403 ") { current?.denied = true }
        case "response": if let current { items.append(current) }; current = nil
        default: break
        }
        text = ""
    }
}
