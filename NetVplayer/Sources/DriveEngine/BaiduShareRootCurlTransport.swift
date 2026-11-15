import CurlTransportShim
import Foundation
import Networking

private struct BaiduShareRootCurlError: LocalizedError {
    let code: Int32
    let message: String

    var errorDescription: String? {
        message.isEmpty ? "libcurl 请求失败（\(code)）" : message
    }
}

private final class BaiduCurlCancellation: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Int32>
    init() { pointer = .allocate(capacity: 1); pointer.initialize(to: 0) }
    deinit { pointer.deinitialize(count: 1); pointer.deallocate() }
    func cancel() { nvp_curl_cancel(pointer) }
}

enum BaiduShareListCurlTransport {
    private static let workerQueue = DispatchQueue(label: "com.netvplayer.baidu-list", qos: .userInitiated, attributes: .concurrent)

    static func get(
        url: String,
        userAgent: String,
        cookie: String,
        timeout: TimeInterval
    ) async throws -> HTTPResponse {
        try await DriveHTTPClient(.shared, provider: .baidu).perform(
            url: url, headers: ["Cookie": cookie], timeout: timeout
        ) { remaining in
            let cancellation = BaiduCurlCancellation()
            return try await withTaskCancellationHandler {
                do {
                    let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                        workerQueue.async {
                            do { continuation.resume(returning: try perform(url: url, userAgent: userAgent,
                                cookie: cookie, timeout: remaining, cancellation: cancellation)) }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                    try Task.checkCancellation()
                    return response
                } catch {
                    try Task.checkCancellation()
                    throw error
                }
            } onCancel: { cancellation.cancel() }
        }
    }

    private static func perform(url: String, userAgent: String, cookie: String, timeout: TimeInterval,
                                cancellation: BaiduCurlCancellation) throws -> HTTPResponse {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        var statusCode: CLong = 0
        var errorBuffer = [CChar](repeating: 0, count: 256)
        var retryAfter = [CChar](repeating: 0, count: 128)
        let result = url.withCString { urlPointer in
            userAgent.withCString { userAgentPointer in
                cookie.withCString { cookiePointer in
                    nvp_curl_baidu_root_get(
                        urlPointer,
                        userAgentPointer,
                        cookiePointer,
                        CLong(max(1, Int(timeout * 1_000))),
                        cancellation.pointer,
                        &bytes,
                        &length,
                        &statusCode,
                        &retryAfter,
                        retryAfter.count,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
            }
        }
        guard result == 0 else {
            // Stable libcurl error constants; no server-message guessing.
            switch result {
            case 6: throw URLError(.cannotFindHost)
            case 7: throw URLError(.cannotConnectToHost)
            case 28: throw URLError(.timedOut)
            case 42: throw CancellationError()
            case 55, 56: throw URLError(.networkConnectionLost)
            default: break
            }
            let message = String(
                decoding: errorBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            throw BaiduShareRootCurlError(code: result, message: message)
        }
        defer { nvp_curl_free(bytes) }
        let data = bytes.map { Data(bytes: $0, count: length) } ?? Data()
        let retryAfterValue = String(decoding: retryAfter.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return HTTPResponse(
            data: data,
            statusCode: Int(statusCode),
            headers: retryAfterValue.isEmpty ? [:] : ["Retry-After": retryAfterValue],
            finalURL: URL(string: url)
        )
    }
}
