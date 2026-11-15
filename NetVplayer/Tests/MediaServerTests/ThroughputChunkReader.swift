import Foundation
import Networking
import Models

/// Independent bounded reference reader for the opt-in throughput comparison.
final class ThroughputChunkReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private typealias Response = (Data, HTTPURLResponse)
    private let lock = NSLock()
    private let request: URLRequest
    private let maximumBytes: Int
    private let configuration: URLSessionConfiguration
    private let pool: URLSession?
    private let redirects: HTTPRedirectDelegate
    private var continuation: CheckedContinuation<Response, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var response: HTTPURLResponse?
    private var body = Data()

    init(request: URLRequest, maximumBytes: Int, origin: URL?, configuration: URLSessionConfiguration = .ephemeral, pool: URLSession? = nil) {
        self.pool = pool
        self.request = request
        self.maximumBytes = max(0, maximumBytes)
        self.configuration = configuration
        redirects = HTTPRedirectDelegate(initialRequest: request, allowedOrigin: origin,
            sensitiveURLValues: [request.value(forHTTPHeaderField: "X-Emby-Token") ?? ""])
    }

    func read() async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                configuration.httpShouldSetCookies = false
                configuration.urlCache = nil
                let session = pool ?? URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                task.delegate = self
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Swift.Result<Response, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        let session = self.session
        self.continuation = nil
        self.session = nil
        let task = self.task
        self.task = nil
        body = Data()
        response = nil
        lock.unlock()
        if pool == nil { session?.invalidateAndCancel() } else { task?.cancel() }
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            finish(.failure(MediaServerError.response)); completionHandler(.cancel); return
        }
        guard (200..<300).contains(response.statusCode) else {
            finish(.failure(MediaServerError.http(response.statusCode))); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            finish(.failure(MediaServerError.response)); completionHandler(.cancel); return
        }
        let active = lock.withLock {
            guard continuation != nil else { return false }
            self.response = response
            return true
        }
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock {
            guard continuation != nil else { return false }
            guard data.count <= maximumBytes - body.count else { return true }
            body.append(data)
            return false
        }
        if overflow { finish(.failure(MediaServerError.response)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Swift.Result<Response, Error> = lock.withLock {
            if let error { return .failure(error) }
            guard let response else { return .failure(MediaServerError.response) }
            return .success((body, response))
        }
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        redirects.urlSession(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        redirects.urlSession(session, task: task, didFinishCollecting: metrics)
    }
}
