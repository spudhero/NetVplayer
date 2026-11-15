import Foundation
import Models

/// One owned byte source behind the existing shared Range cache and read-session budget.
actor MediaServerByteSource {
    private let client: MediaServerClient
    private let fallback: URLRequest
    private let direct: URLRequest?
    let size: Int64
    private var usesFallback = false
    private var closed = false
    private var reads: [UUID: Task<Data, Error>] = [:]
    init(client: MediaServerClient, fallback: URLRequest, direct: URLRequest?, size: Int64) {
        self.client = client; self.fallback = fallback; self.direct = direct; self.size = size
    }
    func read(_ range: Range<Int64>) async throws -> Data {
        guard !closed, range.lowerBound >= 0, range.upperBound <= size, !range.isEmpty,
              range.count <= 4 * 1024 * 1024 else { throw MediaServerError.cancelled }
        try Task.checkCancellation()
        let id = UUID(), client = client, size = size
        let selected = usesFallback ? nil : direct
        let fallback = fallback
        let task = Task<Data, Error> {
            func fetch(_ original: URLRequest) async throws -> Data {
                var request = original
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
                    let (data, response) = try await client.transport.request(client.refreshedMediaRequest(request), maximumBytes: range.count)
                try MediaServerTransport.validateRange(data, response: response, range: range, size: size)
                return data
            }
            return try await fetch(selected ?? fallback)
        }
        reads[id] = task
        defer { reads[id] = nil }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !closed else { throw CancellationError() }
            try Task.checkCancellation(); return value
        } catch {
            guard !closed, !Task.isCancelled, selected != nil, !(error is CancellationError) else { throw error }
            // A failed/expired direct URL is retired for this lease. No second load,
            // Started event or new media identity is created.
            usesFallback = true
            var request = fallback
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            let retryRequest = client.refreshedMediaRequest(request)
            let retry = Task { try await client.transport.request(retryRequest, maximumBytes: range.count) }
            let bridged = Task<Data, Error> {
                let (data, response) = try await withTaskCancellationHandler { try await retry.value } onCancel: { retry.cancel() }
                try MediaServerTransport.validateRange(data, response: response, range: range, size: size)
                return data
            }
            reads[id] = bridged
            let value = try await withTaskCancellationHandler { try await bridged.value } onCancel: { bridged.cancel(); retry.cancel() }
            guard !closed else { throw CancellationError() }
            try Task.checkCancellation(); return value
        }
    }
    func close() { closed = true; reads.values.forEach { $0.cancel() }; reads.removeAll() }
}
