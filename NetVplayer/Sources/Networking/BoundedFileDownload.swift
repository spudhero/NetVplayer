import Foundation

private actor LimitedDownloadFile {
    private let handle: FileHandle
    private let limit: Int
    private var count = 0
    init(url: URL, limit: Int) throws {
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        self.limit = max(0, limit)
    }
    func append(_ data: Data) throws {
        try Task.checkCancellation()
        guard data.count <= limit - count else { throw HTTPBodyLimitError.tooLarge }
        try handle.write(contentsOf: data)
        count += data.count
    }
    func finish() throws { try handle.close() }
    deinit { try? handle.close() }
}

public extension HTTPClient {
    @discardableResult
    func downloadBounded(url: String, to destination: URL, maximumBytes: Int, timeout: TimeInterval = 30) async throws -> HTTPStreamResponse {
        let file = try LimitedDownloadFile(url: destination, limit: maximumBytes)
        do {
            let response = try await stream(url: url, timeout: timeout, allowsProxyFallback: false, redactsURLInLogs: true,
                shouldStream: { response in
                    guard (200..<300).contains(response.statusCode) else { throw HTTPBodyLimitError.rejectedStatus(response.statusCode) }
                    if let length = response.headers.first(where: { $0.key.lowercased() == "content-length" }).flatMap({ Int($0.value) }),
                       length > maximumBytes { throw HTTPBodyLimitError.tooLarge }
                    return true
                }, receive: { try await file.append($0) })
            try Task.checkCancellation()
            try await file.finish()
            return response
        } catch {
            try? await file.finish()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
