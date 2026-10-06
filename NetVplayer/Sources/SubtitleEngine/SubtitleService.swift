import Foundation
import Models
import Networking

public struct OnlineSubtitleResult: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let language: String
    public let format: String
    public init(id: Int, title: String, language: String = "", format: String = "") {
        self.id = id; self.title = title; self.language = language; self.format = format
    }
}

public struct OnlineSubtitleFile: Identifiable, Equatable, Sendable {
    public var id: String { url.absoluteString }
    public let name: String
    public let url: URL
    public let language: String
    public init(name: String, url: URL, language: String = "") { self.name = name; self.url = url; self.language = language }
}

public struct DownloadedSubtitle: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let name: String
    public let format: String
    public let data: Data
    public init(name: String, format: String, data: Data) { self.name = name; self.format = format; self.data = data }
    public func attachment(language: String = "") -> Sub {
        Sub(name: name, url: "data:text/plain;base64," + data.base64EncodedString(), lang: language, format: format)
    }
}

public struct OnlineSubtitlePage: Sendable {
    public let results: [OnlineSubtitleResult]
    public let hasMore: Bool
    public init(results: [OnlineSubtitleResult], hasMore: Bool) { self.results = results; self.hasMore = hasMore }
}

public protocol OnlineSubtitleService: Sendable {
    func search(query: String, offset: Int, token: String) async throws -> OnlineSubtitlePage
    func files(id: Int, token: String) async throws -> [OnlineSubtitleFile]
    func download(_ file: OnlineSubtitleFile) async throws -> [DownloadedSubtitle]
}

public enum OnlineSubtitleError: Error, LocalizedError, Sendable {
    case invalidToken, invalidQuery, invalidResponse, serviceRejected(Int), invalidDownload, unsupportedArchive, limitExceeded
    public var errorDescription: String? {
        switch self {
        case .invalidToken: return L10n.text("请填写有效的 ASSRT API 令牌。")
        case .invalidQuery: return L10n.text("字幕搜索词需为 3 至 120 个字符。")
        case .invalidResponse: return L10n.text("字幕服务返回了无法识别的数据。")
        case .serviceRejected(let code): return L10n.text("字幕服务请求失败，错误码 {0}。", [String(code)])
        case .invalidDownload: return L10n.text("下载内容不是有效的文字字幕。")
        case .unsupportedArchive: return L10n.text("仅支持 SRT、ASS、SSA、VTT 字幕和未加密的 ZIP。")
        case .limitExceeded: return L10n.text("字幕文件超出下载或解压大小限制。")
        }
    }
}

public struct ASSRTSubtitleService: OnlineSubtitleService {
    public static let pageSize = 15
    private let client: HTTPClient
    private let apiURL: URL
    public init(client: HTTPClient = .shared, apiURL: URL = URL(string: "https://api.assrt.net/v1/sub/")!) {
        self.client = client; self.apiURL = apiURL
    }

    public func search(query: String, offset: Int = 0, token: String) async throws -> OnlineSubtitlePage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...120).contains(query.count), (0...1500).contains(offset) else { throw OnlineSubtitleError.invalidQuery }
        let rows = try await api("search", items: [.init(name: "q", value: query), .init(name: "pos", value: String(offset)),
                                                  .init(name: "cnt", value: String(Self.pageSize))], token: token)
        var seen = Set<Int>()
        let results = rows.prefix(Self.pageSize).compactMap { row -> OnlineSubtitleResult? in
            guard let id = (row["id"] as? NSNumber)?.intValue, id > 0, seen.insert(id).inserted else { return nil }
            let title = (row["native_name"] ?? row["title"] ?? row["videoname"]) as? String ?? ""
            guard !title.isEmpty else { return nil }
            return .init(id: id, title: String(title.prefix(500)), language: Self.language(row), format: String((row["subtype"] as? String ?? "").prefix(80)))
        }
        return OnlineSubtitlePage(results: results, hasMore: rows.count >= Self.pageSize && offset < 1500)
    }

    public func files(id: Int, token: String) async throws -> [OnlineSubtitleFile] {
        guard id > 0 else { throw OnlineSubtitleError.invalidResponse }
        let rows = try await api("detail", items: [.init(name: "id", value: String(id))], token: token)
        var files: [OnlineSubtitleFile] = []
        for row in rows.prefix(15) {
            let language = Self.language(row)
            let entries = row["filelist"] as? [[String: Any]] ?? []
            for entry in entries.prefix(64) {
                if let file = Self.file(entry, nameKeys: ["f", "filename"], language: language) { files.append(file) }
            }
            if files.isEmpty, let file = Self.file(row, nameKeys: ["filename", "native_name", "title"], language: language) { files.append(file) }
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.id).inserted }.prefix(64).map { $0 }
    }

    public func download(_ file: OnlineSubtitleFile) async throws -> [DownloadedSubtitle] {
        guard Self.validDownloadURL(file.url) else { throw OnlineSubtitleError.invalidDownload }
        let response = try await bounded(timeout: .seconds(20)) {
            try await client.getBounded(url: file.url.absoluteString, maximumBytes: SubtitleArchive.maximumDownloadBytes,
                                        timeout: 20, allowsProxyFallback: true)
        }
        try Task.checkCancellation()
        return try SubtitleArchive.unpack(response.data, filename: file.name)
    }

    private func api(_ action: String, items: [URLQueryItem], token: String) async throws -> [[String: Any]] {
        guard token.count == 32, token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else {
            throw OnlineSubtitleError.invalidToken
        }
        var url = URLComponents(url: apiURL.appendingPathComponent(action), resolvingAgainstBaseURL: false)!
        url.queryItems = items
        guard let requestURL = url.url else { throw OnlineSubtitleError.invalidResponse }
        let response = try await bounded(timeout: .seconds(15)) {
            try await client.constrained(to: apiURL).getBounded(url: requestURL.absoluteString,
                headers: ["Authorization": "Bearer " + token, "Accept": "application/json"], maximumBytes: 1024 * 1024, timeout: 15)
        }
        try Task.checkCancellation()
        guard let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let status = root["status"] as? Int else { throw OnlineSubtitleError.invalidResponse }
        guard status == 0 else { throw OnlineSubtitleError.serviceRejected(status) }
        guard let sub = root["sub"] as? [String: Any], let rows = sub["subs"] as? [[String: Any]] else { throw OnlineSubtitleError.invalidResponse }
        return rows
    }

    private static func language(_ row: [String: Any]) -> String { String(((row["lang"] as? [String: Any])?["desc"] as? String ?? "").prefix(120)) }
    private static func file(_ row: [String: Any], nameKeys: [String], language: String) -> OnlineSubtitleFile? {
        guard let value = row["url"] as? String, let url = URL(string: value), validDownloadURL(url) else { return nil }
        let name = nameKeys.compactMap { row[$0] as? String }.first(where: { !$0.isEmpty }) ?? url.lastPathComponent
        guard !name.isEmpty, name.count <= 1024 else { return nil }
        return .init(name: name, url: url, language: language)
    }
    private static func validDownloadURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
    private func bounded<T: Sendable>(timeout: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask { try await Task.sleep(for: timeout); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
