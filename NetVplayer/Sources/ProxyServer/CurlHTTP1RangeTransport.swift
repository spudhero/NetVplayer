import CurlTransportShim
import Darwin
import Foundation
import Networking

struct CurlRangeTransportError: LocalizedError {
    let code: Int32
    let message: String

    var errorDescription: String? {
        message.isEmpty ? "libcurl range request failed (\(code))" : message
    }
}

private final class CurlCancellationFlag: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Int32>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: 0)
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    func cancel() {
        nvp_curl_cancel(pointer)
    }
}

enum CurlRangeTransport {
    private static let endpointResolver = CurlDirectEndpointResolver()
    private static let workerQueue = DispatchQueue(
        label: "com.netvplayer.curl-range",
        qos: .userInitiated,
        attributes: .concurrent
    )

    struct Result {
        let response: HTTPResponse
        let protocolName: String
        let primaryIP: String
        let totalTime: TimeInterval
        let averageBytesPerSecond: Int64
    }

    static func get(
        url: String,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> Result {
        let endpoint = await endpointResolver.endpoint(for: url)
        let cancellation = CurlCancellationFlag()
        return try await withTaskCancellationHandler {
            do {
                let result = try await dispatchedPerform(
                    url: url,
                    headers: headers,
                    timeout: timeout,
                    endpoint: endpoint,
                    cancellation: cancellation
                )
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    fileprivate static func directData(
        url: String,
        endpoint: CurlDirectEndpoint,
        timeout: TimeInterval
    ) async -> Data? {
        let cancellation = CurlCancellationFlag()
        return try? await dispatchedPerform(
            url: url,
            headers: [:],
            timeout: timeout,
            endpoint: endpoint,
            cancellation: cancellation
        ).response.data
    }

    private static func dispatchedPerform(
        url: String,
        headers: [String: String],
        timeout: TimeInterval,
        endpoint: CurlDirectEndpoint?,
        cancellation: CurlCancellationFlag
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            workerQueue.async {
                do {
                    continuation.resume(returning: try perform(
                        url: url,
                        headers: headers,
                        timeout: timeout,
                        endpoint: endpoint,
                        cancellation: cancellation
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func perform(
        url: String,
        headers: [String: String],
        timeout: TimeInterval,
        endpoint: CurlDirectEndpoint?,
        cancellation: CurlCancellationFlag
    ) throws -> Result {
        let userAgent = header("User-Agent", in: headers)
        let cookie = header("Cookie", in: headers)
        let referer = header("Referer", in: headers)
        let origin = header("Origin", in: headers)
        let range = header("Range", in: headers)
        let resolveEntry = endpoint?.resolveEntry ?? ""
        let interfaceName = endpoint?.interfaceName ?? ""
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        var statusCode: CLong = 0
        var protocolName = [CChar](repeating: 0, count: 32)
        var primaryIP = [CChar](repeating: 0, count: 64)
        var totalTimeMicroseconds: Int64 = 0
        var averageBytesPerSecond: Int64 = 0
        var contentRange = [CChar](repeating: 0, count: 256)
        var contentType = [CChar](repeating: 0, count: 256)
        var acceptRanges = [CChar](repeating: 0, count: 64)
        var finalURL = [CChar](repeating: 0, count: 8_192)
        var errorBuffer = [CChar](repeating: 0, count: 256)

        let result = url.withCString { urlPointer in
            userAgent.withCString { userAgentPointer in
                cookie.withCString { cookiePointer in
                    referer.withCString { refererPointer in
                        origin.withCString { originPointer in
                            range.withCString { rangePointer in
                                resolveEntry.withCString { resolveEntryPointer in
                                    interfaceName.withCString { interfaceNamePointer in
                                        nvp_curl_range_get(
                                            urlPointer,
                                            userAgentPointer,
                                            cookiePointer,
                                            refererPointer,
                                            originPointer,
                                            rangePointer,
                                            resolveEntryPointer,
                                            interfaceNamePointer,
                                            CLong(max(1, Int(timeout * 1_000))),
                                            cancellation.pointer,
                                            &bytes,
                                            &length,
                                            &statusCode,
                                            &protocolName,
                                            protocolName.count,
                                            &primaryIP,
                                            primaryIP.count,
                                            &totalTimeMicroseconds,
                                            &averageBytesPerSecond,
                                            &contentRange,
                                            contentRange.count,
                                            &contentType,
                                            contentType.count,
                                            &acceptRanges,
                                            acceptRanges.count,
                                            &finalURL,
                                            finalURL.count,
                                            &errorBuffer,
                                            errorBuffer.count
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if Task.isCancelled {
            nvp_curl_free(bytes)
            throw CancellationError()
        }
        guard result == 0 else {
            let baseMessage = string(from: errorBuffer)
            let route = endpoint.map { "direct(interface=\($0.interfaceName), resolved=\($0.address))" } ?? "system"
            let message = "\(baseMessage); route=\(route), protocol=\(string(from: protocolName)), primaryIP=\(string(from: primaryIP)), seconds=\(String(format: "%.3f", TimeInterval(totalTimeMicroseconds) / 1_000_000))"
            throw CurlRangeTransportError(code: result, message: message)
        }
        defer { nvp_curl_free(bytes) }

        var responseHeaders: [String: String] = [:]
        let capturedContentRange = string(from: contentRange)
        let capturedContentType = string(from: contentType)
        let capturedAcceptRanges = string(from: acceptRanges)
        if !capturedContentRange.isEmpty {
            responseHeaders["Content-Range"] = capturedContentRange
        }
        if !capturedContentType.isEmpty {
            responseHeaders["Content-Type"] = capturedContentType
        }
        if !capturedAcceptRanges.isEmpty {
            responseHeaders["Accept-Ranges"] = capturedAcceptRanges
        }
        responseHeaders["Content-Length"] = String(length)

        return Result(
            response: HTTPResponse(
                data: bytes.map { Data(bytes: $0, count: length) } ?? Data(),
                statusCode: Int(statusCode),
                headers: responseHeaders,
                finalURL: URL(string: string(from: finalURL)) ?? URL(string: url)
            ),
            protocolName: string(from: protocolName),
            primaryIP: string(from: primaryIP),
            totalTime: TimeInterval(totalTimeMicroseconds) / 1_000_000,
            averageBytesPerSecond: averageBytesPerSecond
        )
    }

    private static func header(_ name: String, in headers: [String: String]) -> String {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    private static func string(from buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

fileprivate struct CurlDirectEndpoint: Sendable {
    let resolveEntry: String
    let interfaceName: String
    let address: String
}

private actor CurlDirectEndpointResolver {
    private struct CachedEndpoints {
        let values: [CurlDirectEndpoint]
        let expiresAt: Date
        var nextIndex: Int
    }

    private struct DNSResponse: Decodable {
        struct Answer: Decodable {
            let type: Int
            let data: String
            let ttl: Int

            enum CodingKeys: String, CodingKey {
                case type
                case data
                case ttl = "TTL"
            }
        }

        let answers: [Answer]?

        enum CodingKeys: String, CodingKey {
            case answers = "Answer"
        }
    }

    private var cache: [String: CachedEndpoints] = [:]
    private var inFlight: [String: Task<([String], TimeInterval)?, Never>] = [:]

    func endpoint(for rawURL: String) async -> CurlDirectEndpoint? {
        guard let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              host.hasSuffix(".drive.uc.cn"),
              let interfaceName = Self.activePhysicalIPv4Interface() else {
            return nil
        }
        if let endpoint = takeCachedEndpoint(for: host) { return endpoint }

        let task: Task<([String], TimeInterval)?, Never>
        if let existing = inFlight[host] {
            task = existing
        } else {
            task = Task { await Self.resolve(host: host, interfaceName: interfaceName) }
            inFlight[host] = task
        }
        let resolved = await task.value
        inFlight[host] = nil
        if let endpoint = takeCachedEndpoint(for: host) { return endpoint }
        guard let (addresses, ttl) = resolved, !addresses.isEmpty else { return nil }

        let port = url.port ?? 443
        let endpoints = addresses.map { address in
            CurlDirectEndpoint(
                resolveEntry: "\(host):\(port):\(address)",
                interfaceName: interfaceName,
                address: address
            )
        }
        cache[host] = CachedEndpoints(
            values: endpoints,
            expiresAt: Date().addingTimeInterval(max(30, min(ttl, 300))),
            nextIndex: endpoints.count > 1 ? 1 : 0
        )
        return endpoints[0]
    }

    private func takeCachedEndpoint(for host: String) -> CurlDirectEndpoint? {
        guard var cached = cache[host], cached.expiresAt > Date(), !cached.values.isEmpty else {
            return nil
        }
        let endpoint = cached.values[cached.nextIndex % cached.values.count]
        cached.nextIndex = (cached.nextIndex + 1) % cached.values.count
        cache[host] = cached
        return endpoint
    }

    private static func resolve(host: String, interfaceName: String) async -> ([String], TimeInterval)? {
        var components = URLComponents(string: "https://dns.alidns.com/resolve")
        components?.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: "A")
        ]
        guard let url = components?.url?.absoluteString else { return nil }
        let resolverEndpoint = CurlDirectEndpoint(
            resolveEntry: "dns.alidns.com:443:223.5.5.5",
            interfaceName: interfaceName,
            address: "223.5.5.5"
        )
        guard let data = await CurlRangeTransport.directData(
            url: url,
            endpoint: resolverEndpoint,
            timeout: 8
        ),
        let decoded = try? JSONDecoder().decode(DNSResponse.self, from: data) else {
            return nil
        }

        var candidates: [(address: String, ttl: Int, prefix: String)] = []
        for answer in decoded.answers ?? [] where answer.type == 1 {
            var address = in_addr()
            guard inet_pton(AF_INET, answer.data, &address) == 1 else { continue }
            guard let candidateURL = URL(string: "https://\(answer.data)"),
                  (try? ProxyAccessPolicy.validateFinalURL(candidateURL)) != nil else {
                continue
            }
            let octets = answer.data.split(separator: ".")
            guard octets.count == 4 else { continue }
            candidates.append((
                address: answer.data,
                ttl: answer.ttl,
                prefix: "\(octets[0]).\(octets[1])"
            ))
        }
        guard !candidates.isEmpty else { return nil }
        let counts = Dictionary(grouping: candidates, by: \.prefix).mapValues(\.count)
        let dominantPrefix = counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
        let regionalCandidates = candidates.filter { $0.prefix == dominantPrefix }
        guard !regionalCandidates.isEmpty else { return nil }
        var seenAddresses = Set<String>()
        let addresses = regionalCandidates.compactMap { candidate in
            seenAddresses.insert(candidate.address).inserted ? candidate.address : nil
        }
        let ttl = regionalCandidates.map(\.ttl).min() ?? 60
        return (addresses, TimeInterval(ttl))
    }

    private static func activePhysicalIPv4Interface() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET else {
                continue
            }
            let name = String(cString: interface.pointee.ifa_name)
            if name.hasPrefix("en") {
                return name
            }
        }
        return nil
    }
}
