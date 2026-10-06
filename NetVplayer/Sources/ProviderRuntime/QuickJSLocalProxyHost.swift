import Foundation
import ProviderSDK
import ProxyServer

/// FongMi-compatible local proxy URL bridge.
///
/// The proxy server is intentionally owned and started by the application shell. This
/// host only exposes its stable port and URL contract to a provider process.
struct QuickJSLocalProxyHost: @unchecked Sendable {
    func handle(_ request: QuickJSHostControl) -> QuickJSHostResponse {
        guard request.capability == "local_proxy" else {
            return failure(
                requestID: request.requestID,
                code: "unsupported_host_request",
                message: "Unsupported QuickJS local proxy request"
            )
        }

        do {
            let options = request.options ?? [:]
            switch request.operation {
            case "get_port":
                return success(
                    requestID: request.requestID,
                    result: .object(["port": .number(Double(ProxyServer.shared.port))])
                )
            case "get_proxy":
                let local = bool(options["local"])
                return success(
                    requestID: request.requestID,
                    result: .object(["url": .string(proxyURL(local: local))])
                )
            case "js2_proxy":
                let dynamic = bool(options["dynamic"])
                let siteType = try requiredInteger(options["site_type"], name: "site_type")
                let siteKey = try requiredString(options["site_key"], name: "site_key")
                let url = try requiredString(options["url"], name: "url")
                let headers = try encodedHeaders(options["headers"])
                let base = proxyURL(local: !dynamic)
                let value = base
                    + "&from=catvod"
                    + "&siteType=\(siteType)"
                    + "&siteKey=\(formURLEncode(siteKey))"
                    + "&header=\(formURLEncode(headers))"
                    + "&url=\(formURLEncode(url))"
                return success(requestID: request.requestID, result: .object(["url": .string(value)]))
            default:
                return failure(
                    requestID: request.requestID,
                    code: "unsupported_operation",
                    message: "QuickJS local proxy operation is unsupported"
                )
            }
        } catch let error as QuickJSLocalProxyHostError {
            return failure(requestID: request.requestID, code: error.code, message: error.message)
        } catch {
            return failure(
                requestID: request.requestID,
                code: "local_proxy_failed",
                message: "QuickJS local proxy request failed"
            )
        }
    }

    private func proxyURL(local: Bool) -> String {
        // FongMi advertises a LAN address when `local` is false. NetVplayer's proxy
        // deliberately binds loopback only, so both modes must advertise the only
        // address that is reachable by the colocated provider and player processes.
        _ = local
        return ProxyServer.shared.getAddress("/proxy?do=js")
    }

    private func encodedHeaders(_ value: ProviderJSONValue?) throws -> String {
        guard let value else { return "{}" }
        guard case .object = value else {
            throw QuickJSLocalProxyHostError(code: "invalid_headers", message: "Local proxy headers must be an object")
        }
        let data = try JSONEncoder.providerCanonical.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func requiredString(_ value: ProviderJSONValue?, name: String) throws -> String {
        guard case .string(let value) = value else {
            throw QuickJSLocalProxyHostError(code: "invalid_\(name)", message: "Local proxy \(name) is invalid")
        }
        return value
    }

    private func requiredInteger(_ value: ProviderJSONValue?, name: String) throws -> Int {
        guard case .number(let value) = value, value.isFinite else {
            throw QuickJSLocalProxyHostError(code: "invalid_\(name)", message: "Local proxy \(name) is invalid")
        }
        return Int(value.rounded(.towardZero))
    }

    private func bool(_ value: ProviderJSONValue?) -> Bool {
        guard case .bool(let value) = value else { return false }
        return value
    }

    /// Java's `URLEncoder.encode` uses application/x-www-form-urlencoded escaping.
    private func formURLEncode(_ value: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._*".utf8)
        return Data(value.utf8).map { byte in
            if safe.contains(byte) { return String(UnicodeScalar(byte)) }
            if byte == 0x20 { return "+" }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    private func success(requestID: String, result: ProviderJSONValue) -> QuickJSHostResponse {
        QuickJSHostResponse(requestID: requestID, ok: true, result: result)
    }

    private func failure(requestID: String, code: String, message: String) -> QuickJSHostResponse {
        QuickJSHostResponse(
            requestID: requestID,
            ok: false,
            error: ProviderErrorPayload(code: code, message: message)
        )
    }
}

private struct QuickJSLocalProxyHostError: Error {
    let code: String
    let message: String
}
