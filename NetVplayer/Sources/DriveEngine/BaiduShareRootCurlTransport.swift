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

enum BaiduShareListCurlTransport {
    static func get(
        url: String,
        userAgent: String,
        cookie: String,
        timeout: TimeInterval
    ) async throws -> HTTPResponse {
        try await Task.detached(priority: .userInitiated) {
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            var statusCode: CLong = 0
            var errorBuffer = [CChar](repeating: 0, count: 256)
            let result = url.withCString { urlPointer in
                userAgent.withCString { userAgentPointer in
                    cookie.withCString { cookiePointer in
                        nvp_curl_baidu_root_get(
                            urlPointer,
                            userAgentPointer,
                            cookiePointer,
                            CLong(max(1, Int(timeout * 1_000))),
                            &bytes,
                            &length,
                            &statusCode,
                            &errorBuffer,
                            errorBuffer.count
                        )
                    }
                }
            }
            guard result == 0 else {
                let message = String(
                    decoding: errorBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
                throw BaiduShareRootCurlError(code: result, message: message)
            }
            defer { nvp_curl_free(bytes) }
            let data = bytes.map { Data(bytes: $0, count: length) } ?? Data()
            return HTTPResponse(
                data: data,
                statusCode: Int(statusCode),
                finalURL: URL(string: url)
            )
        }.value
    }
}
