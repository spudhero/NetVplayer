import Foundation
import SwiftSoup
import Models

/// Reads ordinary public movie pages; no private client API key or captcha automation.
public actor DoubanMetadataProvider: MetadataProvider {
    public nonisolated let source = MetadataSource.douban
    public static let shared = DoubanMetadataProvider()
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private let transport: MetadataTransport
    private let publicPageRequest: MetadataRequest?
    private let cookieStorage: HTTPCookieStorage?
    private var lastRequest = Date.distantPast
    private var recoveredPage: (key: String, data: Data)?
    public init(request: MetadataRequest? = nil, publicPageRequest: MetadataRequest? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        self.cookieStorage = configuration.httpCookieStorage
        self.transport = MetadataTransport(session: URLSession(configuration: configuration), request: request)
        if let publicPageRequest { self.publicPageRequest = publicPageRequest }
        else if request == nil {
            let storage = configuration.httpCookieStorage
            self.publicPageRequest = { url, _ in try await DoubanPublicPageLoader.load(url, cookieStorage: storage) }
        } else { self.publicPageRequest = nil }
    }
    public func setCookies(_ cookies: [HTTPCookie]) {
        for cookie in cookies where cookie.domain == "douban.com" || cookie.domain.hasSuffix(".douban.com") { cookieStorage?.setCookie(cookie) }
    }
    public static func subjectID(_ value: String) -> String? {
        if !value.isEmpty, value.count <= 12, value.allSatisfy(\.isNumber) { return value }
        guard let url = URL(string: value), url.scheme == "https", url.host == "movie.douban.com",
              url.path.hasPrefix("/subject/") else { return nil }
        return subjectID(String(url.path.dropFirst(9).split(separator: "/").first ?? ""))
    }
    public static func verificationURL(response: HTTPURLResponse, data: Data) -> URL? {
        if let url = response.url, url.host == "sec.douban.com" { return url }
        if requiresUserVerification(data) { return response.url ?? URL(string: "https://movie.douban.com/")! }
        return nil
    }
    static func requiresUserVerification(_ data: Data) -> Bool {
        guard let document = try? SwiftSoup.parse(String(decoding: data, as: UTF8.self)) else { return false }
        let title = (try? document.title()) ?? ""
        return title.hasPrefix("豆瓣 - 验证") || title.hasPrefix("验证") ||
            (try? document.select("input[id^=captcha], input[name*=captcha], img[id^=captcha], form[action*=sec.douban.com]").isEmpty()) == false
    }
    /// Reuse a public page already loaded in the verification browser instead of repeating the blocked HTTP request.
    public func acceptPublicPage(html: String, text: String, at url: URL) -> Bool {
        guard let key = Self.publicPageKey(url), let data = Self.publicPageData(html: html, text: text, at: url) else { return false }
        recoveredPage = (key, data)
        return true
    }
    static func publicPageKey(_ url: URL) -> String? {
        guard url.scheme == "https", url.host == "movie.douban.com", url.user == nil, url.password == nil else { return nil }
        if url.path == "/j/subject_suggest", let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value {
            return "search:" + query
        }
        if let id = subjectID(url.absoluteString), url.path == "/subject/" + id || url.path == "/subject/" + id + "/" { return "subject:" + id }
        return nil
    }
    static func publicPageData(html: String, text: String, at url: URL) -> Data? {
        guard let key = publicPageKey(url), html.utf8.count <= 2 * 1024 * 1024, text.utf8.count <= 2 * 1024 * 1024 else { return nil }
        if key.hasPrefix("search:") {
            let data = Data(text.utf8)
            guard (try? JSONSerialization.jsonObject(with: data)) is [[String: Any]] else { return nil }
            return data
        }
        let data = Data(html.utf8)
        guard !requiresUserVerification(data), let id = subjectID(url.absoluteString),
              (try? parseSubject(data, id: id, fallbackKind: .movies)) != nil else { return nil }
        return data
    }
    private func get(_ url: URL) async throws -> Data {
        if let page = recoveredPage, page.key == Self.publicPageKey(url) { recoveredPage = nil; return page.data }
        let delay = 1.0 - Date().timeIntervalSince(lastRequest)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        lastRequest = Date()
        let headers = ["User-Agent": Self.userAgent, "Accept-Language": "zh-CN,zh;q=0.9"]
        var (data, response) = try await transport.data(url: url, headers: headers)
        if let verification = Self.verificationURL(response: response, data: data) {
            guard let publicPageRequest else { throw MetadataProviderError.verification(verification) }
            (data, response) = try await publicPageRequest(url, headers)
            if let verification = Self.verificationURL(response: response, data: data) { throw MetadataProviderError.verification(verification) }
            guard response.url.flatMap(Self.publicPageKey) == Self.publicPageKey(url) else { throw MetadataProviderError.invalidResponse }
        }
        guard response.statusCode == 200, response.url?.host == "movie.douban.com" else { throw MetadataProviderError.invalidResponse }
        return data
    }
    public func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        var url = URLComponents(string: "https://movie.douban.com/j/subject_suggest")!
        url.queryItems = [URLQueryItem(name: "q", value: title)]
        let data = try await get(url.url!)
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MetadataProviderError.invalidResponse }
        return items.prefix(20).compactMap { object in
            guard let id = object["id"] as? String, Self.subjectID(id) != nil, let title = object["title"] as? String else { return nil }
            let episodes = object["episode"] as? String ?? ""
            let type: MediaLibraryKind = episodes.isEmpty ? .movies : .television
            return .init(source: .douban, metadata: .init(title: title, originalTitle: object["sub_title"] as? String,
                         year: (object["year"] as? String).flatMap(Int.init), kind: type,
                         showTitle: type == .television ? title : nil, poster: Self.validImage(object["img"] as? String), doubanID: id))
        }
    }
    public func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        guard let id = Self.subjectID(id) else { throw MetadataProviderError.invalidResponse }
        let data = try await get(URL(string: "https://movie.douban.com/subject/" + id + "/")!)
        return try Self.parseSubject(data, id: id, fallbackKind: kind)
    }
    public static func parseSubject(_ data: Data, id: String, fallbackKind: MediaLibraryKind) throws -> MediaMetadata {
        let document = try SwiftSoup.parse(String(decoding: data, as: UTF8.self))
        var metadata = MediaMetadata(doubanID: id)
        if let script = try document.select("script[type=application/ld+json]").first(),
           let jsonData = try script.data().data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            metadata.title = json["name"] as? String; metadata.plot = json["description"] as? String
            metadata.poster = validImage(json["image"] as? String)
            metadata.kind = (json["@type"] as? String)?.contains("TV") == true ? .television : .movies
            if let rating = (json["aggregateRating"] as? [String: Any])?["ratingValue"] { metadata.doubanRating = Double(String(describing: rating)) }
            metadata.year = (json["datePublished"] as? String).flatMap { Int($0.prefix(4)) }
        }
        if metadata.title == nil { metadata.title = try document.select("h1 span[property=v\u{3a}itemreviewed]").first()?.text() }
        if metadata.poster == nil { metadata.poster = validImage(try document.select("#mainpic img").first()?.attr("src")) }
        if metadata.plot == nil { metadata.plot = try document.select("[property=v\u{3a}summary]").first()?.text() }
        if metadata.doubanRating == nil {
            let value = try document.select(".rating_num").first()?.text()
            metadata.doubanRating = value.flatMap { Double($0) }
        }
        if metadata.year == nil {
            let value = try document.select("h1 .year").first()?.text()
            metadata.year = value.flatMap { Int($0.filter(\.isNumber)) }
        }
        metadata.kind = metadata.kind ?? fallbackKind
        if metadata.kind == .television { metadata.showTitle = metadata.title }
        guard metadata.title?.isEmpty == false else { throw MetadataProviderError.invalidResponse }
        return metadata
    }
    private static func validImage(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        return value
    }
}
