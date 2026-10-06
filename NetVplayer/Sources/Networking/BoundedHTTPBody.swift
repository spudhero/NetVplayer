import Foundation

public enum HTTPBodyLimitError: Error, Sendable { case tooLarge, rejectedStatus(Int) }

private actor BoundedHTTPBody {
    private var data = Data()
    private let limit: Int
    init(limit: Int) { self.limit = max(0, limit) }
    func append(_ chunk: Data) throws {
        guard chunk.count <= limit - data.count else { throw HTTPBodyLimitError.tooLarge }
        data.append(chunk)
    }
    func value() -> Data { data }
}

public extension HTTPClient {
    func getBounded(url: String, headers: [String: String] = [:], maximumBytes: Int, timeout: TimeInterval = 15,
                    allowsProxyFallback: Bool = true) async throws -> HTTPResponse {
        let body = BoundedHTTPBody(limit: maximumBytes)
        let response = try await stream(url: url, headers: headers, timeout: timeout, allowsProxyFallback: allowsProxyFallback, redactsURLInLogs: true,
            shouldStream: { response in
                guard (200..<300).contains(response.statusCode) else { throw HTTPBodyLimitError.rejectedStatus(response.statusCode) }
                if let length = response.headers.first(where: { $0.key.lowercased() == "content-length" }).flatMap({ Int($0.value) }),
                   length > maximumBytes { throw HTTPBodyLimitError.tooLarge }
                return true
            }, receive: { try await body.append($0) })
        return HTTPResponse(data: await body.value(), statusCode: response.statusCode, headers: response.headers, finalURL: response.finalURL)
    }
}
