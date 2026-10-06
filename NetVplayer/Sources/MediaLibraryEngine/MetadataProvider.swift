import Foundation
import Models
import Storage

public protocol MetadataProvider: Sendable {
    var source: MetadataSource { get }
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate]
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata
}

public enum MetadataProviderError: Error, LocalizedError, Sendable {
    case unavailable(String), verification(URL), rateLimited, invalidResponse
    public var errorDescription: String? { switch self {
    case .unavailable(let text): text
    case .verification: "豆瓣需要网页验证，完成验证后可继续匹配"
    case .rateLimited: "信息来源暂时限流，已保留现有资料"
    case .invalidResponse: "信息来源返回了无法识别的数据"
    } }
}

public struct TMDBCredential: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case apiKey, readAccessToken }
    public var kind: Kind
    public var value: String
    public init(kind: Kind, value: String) { self.kind = kind; self.value = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isValid: Bool { !value.isEmpty && value.utf8.count <= 4096 && !value.contains("\n") && !value.contains("\r") }
}

public enum MetadataCredentials {
    private struct StoredCredential: Codable { var kind: TMDBCredential.Kind; var value: String }
    public static func resolve(preferences: UserPreferences = .shared, bundleURL: URL? = Bundle.main.url(forResource: "TMDB", withExtension: "json")) throws -> TMDBCredential? {
        let key = "metadata.tmdb.override"
        let personal = preferences.credential(key)
        do {
            try preferences.checkCredentialPersistence(for: key)
            if let credential = decode(Data(personal.utf8)) { return credential }
        } catch {
            // A temporarily unreadable optional override must not disable the publisher's credential.
            if let credential = try bundled(bundleURL) { return credential }
            throw error
        }
        return try bundled(bundleURL)
    }
    private static func bundled(_ bundleURL: URL?) throws -> TMDBCredential? {
        guard let bundleURL else { return nil }
        let handle = try FileHandle(forReadingFrom: bundleURL); defer { try? handle.close() }
        let data = try handle.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw MetadataProviderError.invalidResponse }
        return decode(data)
    }
    public static func personal(preferences: UserPreferences = .shared) -> TMDBCredential? {
        decode(Data(preferences.credential("metadata.tmdb.override").utf8))
    }
    private static func decode(_ data: Data) -> TMDBCredential? {
        guard let value = try? JSONDecoder().decode(StoredCredential.self, from: data) else { return nil }
        let credential = TMDBCredential(kind: value.kind, value: value.value)
        return credential.isValid ? credential : nil
    }
    public static func savePersonal(_ credential: TMDBCredential?, preferences: UserPreferences = .shared) throws {
        let value: String
        if let credential {
            guard credential.isValid else { throw MetadataProviderError.unavailable("个人凭据格式无效") }
            value = String(decoding: try JSONEncoder().encode(StoredCredential(kind: credential.kind, value: credential.value)), as: UTF8.self)
        } else { value = "" }
        try preferences.saveCredential(value, for: "metadata.tmdb.override")
    }
}

public typealias MetadataRequest = @Sendable (URL, [String: String]) async throws -> (Data, HTTPURLResponse)

struct MetadataTransport: Sendable {
    let request: MetadataRequest
    init(session: URLSession = URLSession(configuration: .ephemeral), request: MetadataRequest? = nil) {
        self.request = request ?? { url, headers in
            var request = URLRequest(url: url); request.timeoutInterval = 20
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 2 * 1024 * 1024 else { throw MetadataProviderError.invalidResponse }
                data.append(byte)
            }
            return (data, response)
        }
    }
    func data(url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let result = try await request(url, headers)
        if result.1.statusCode == 429 { throw MetadataProviderError.rateLimited }
        return result
    }
}
