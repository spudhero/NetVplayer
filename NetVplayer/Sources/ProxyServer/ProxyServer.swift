// ProxyServer/ProxyServer.swift
// 本地 HTTP 代理服务器，对应 FongMi: server/Server.java

import Foundation
import Darwin
import Models
import Networking
import NIO
import NIOHTTP1

public enum ProxyURLCodec {
    public static func encode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) -> String? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum ProxyAccessError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case unsupportedScheme(String)
    case blockedHost(String)
    case missingHost

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "代理目标 URL 无效: \(value)"
        case .unsupportedScheme(let scheme):
            return "代理目标协议不允许: \(scheme)"
        case .blockedHost(let host):
            return "代理目标地址不允许访问: \(host)"
        case .missingHost:
            return "代理目标缺少 host"
        }
    }
}

public enum ProxyAccessPolicy {
    public static func validateTargetURL(_ rawValue: String) throws -> URL {
        guard let url = URL(string: rawValue) else {
            throw ProxyAccessError.invalidURL(rawValue)
        }
        try validate(url)
        return url
    }

    public static func validateFinalURL(_ url: URL?) throws {
        guard let url else { return }
        try validate(url)
    }

    private static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ProxyAccessError.unsupportedScheme(url.scheme ?? "")
        }
        guard let host = url.host, !host.isEmpty else {
            throw ProxyAccessError.missingHost
        }
        if isBlockedHost(host) {
            throw ProxyAccessError.blockedHost(host)
        }
    }

    private static func isBlockedHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == "localhost"
            || normalized.hasSuffix(".localhost")
            || normalized.hasSuffix(".local")
            || normalized.hasSuffix(".localdomain")
            || normalized.hasSuffix(".lan") {
            return true
        }
        if normalized == "0" {
            return true
        }
        if isIPv4Literal(normalized) {
            return isBlockedIPv4(normalized)
        }
        if isBlockedIPv6(normalized) || isAmbiguousNumericHost(normalized) {
            return true
        }
        return false
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }

    private static func isBlockedIPv4(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        return isBlockedIPv4Value(value)
    }

    private static func isBlockedIPv4Value(_ value: UInt32) -> Bool {
        let first = (value >> 24) & 0xff
        let second = (value >> 16) & 0xff
        switch first {
        case 0, 10, 127:
            return true
        case 100:
            return (64...127).contains(second)
        case 169:
            return second == 254
        case 172:
            return (16...31).contains(second)
        case 192:
            return second == 168
        case 198:
            return (18...19).contains(second)
        case 224...255:
            return true
        default:
            return false
        }
    }

    private static func isBlockedIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard bytes.count >= 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            let value = (UInt32(bytes[12]) << 24)
                | (UInt32(bytes[13]) << 16)
                | (UInt32(bytes[14]) << 8)
                | UInt32(bytes[15])
            return isBlockedIPv4Value(value)
        }
        let first = bytes[0]
        if first == 0xff { return true }
        if first == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        if (first & 0xfe) == 0xfc { return true }
        return false
    }

    private static func isAmbiguousNumericHost(_ host: String) -> Bool {
        guard host.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEFxX.")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// 本地 HTTP 代理服务器
/// 默认绑定 127.0.0.1，端口 9978-9998
public struct ProxyStreamingResponseHead: Sendable {
    public let statusCode: Int
    public let contentType: String
    public let contentLength: Int?
    public let headers: [String: String]
    public let closeConnection: Bool

    public init(
        statusCode: Int,
        contentType: String,
        contentLength: Int? = nil,
        headers: [String: String] = [:],
        closeConnection: Bool = false
    ) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.contentLength = contentLength
        self.headers = headers
        self.closeConnection = closeConnection
    }
}

public typealias ProxyStreamingHandler = @Sendable (
    [String: String],
    @escaping @Sendable (ProxyStreamingResponseHead) async throws -> Void,
    @escaping @Sendable (Data) async throws -> Void
) async throws -> Bool
public typealias ProxyHandler = @Sendable ([String: String]) async throws -> ProxyResponse?

public final class ProxyServer: @unchecked Sendable {

    public static let shared = ProxyServer()
    public static let multiplexedRangeConnectionLimit = 2

    public init() {}

    private var channel: NIOCore.Channel?
    private var group: MultiThreadedEventLoopGroup?
    public private(set) var port: Int = 9978
    public private(set) var isRunning: Bool = false
    fileprivate static let defaultStreamChunkSize: Int64 = 4 * 1024 * 1024
    fileprivate static let openEndedStreamChunkSize: Int64 = 16 * 1024 * 1024
    fileprivate static let defaultStreamTimeout: TimeInterval = 8
    fileprivate static let continuousStreamTimeout: TimeInterval = 60
    fileprivate static let streamPrefetchWindowSize: Int64 = 96 * 1024 * 1024
    fileprivate static let streamBufferMaxBytes: Int64 = 192 * 1024 * 1024
    fileprivate static let streamPrefetchMaxConcurrent = 2
    fileprivate static let maxRequestBodyBytes = 2 * 1024 * 1024
    fileprivate static let maxCacheEntryBytes = 2 * 1024 * 1024
    // Buffered routes are for playlists and control payloads; media bodies must stream.
    static let maxBufferedResponseBytes = 256 * 1024 * 1024
    fileprivate static let remoteStreamIdleTTL: TimeInterval = 30 * 60
    fileprivate static let remoteStreamMaxActive = 8
    fileprivate static let remoteStreamGlobalBufferMaxBytes: Int64 = 512 * 1024 * 1024

    /// 代理请求处理器（由 SpiderEngine 设置）
    public var proxyHandler: ProxyHandler?
    public var prefetchedProxyHandler: ProxyHandler?
    public var streamingProxyHandler: ProxyStreamingHandler?
    public var rawProxyHandler: (([String: String]) async throws -> Any?)?
    public var remoteStreamHTTPClient: HTTPClient = .shared
    fileprivate let directRemoteStreamHTTPClient = HTTPClient.shared.withExplicitProxy(nil)
    // The measured eight-range route needs eight transport connections too.
    // Keep this pool separate from the shared control/API session and retain
    // automatic routing unless the registration explicitly selects direct.
    fileprivate let parallelRemoteStreamHTTPClient = ProxyServer.makeParallelRangeHTTPClient(direct: false)
    fileprivate let directParallelRemoteStreamHTTPClient = ProxyServer.makeParallelRangeHTTPClient(direct: true)
    private static func makeParallelRangeHTTPClient(direct: Bool) -> HTTPClient {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 8
        let client = HTTPClient(session: URLSession(configuration: configuration))
        return direct ? client.withExplicitProxy(nil) : client
    }
    fileprivate let multiplexedRemoteStreamHTTPClient: HTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = ProxyServer.multiplexedRangeConnectionLimit
        // Cloud Range multiplexing must keep the measured direct CDN route.
        // Inheriting PAC or retrying each segment through a local proxy defeats
        // connection reuse and can stall the next segment awaiting delivery.
        return HTTPClient(session: URLSession(configuration: configuration)).withExplicitProxy(nil)
    }()
    public var webResourceHTTPClient: HTTPClient = .shared

    private let cacheLock = NSLock()
    private var cache: [String: Data] = [:]
    private var recoveryPlaylistKeys: [String] = []
    private let streamLock = NSLock()
    private var streams: [String: RemoteStream] = [:]
    private let localFileLock = NSLock()
    private var localFiles: [String: RegisteredLocalFile] = [:]
    private let seekableLock = NSLock()
    private var seekableResources: [String: SeekableResource] = [:]
    private let seekableBuffer = SeekableResourceBuffer()

    public func registerSeekableResource(_ resource: SeekableResource) throws -> String {
        guard isRunning else { throw ProxyServerError.serverNotRunning }
        let id = UUID().uuidString
        seekableLock.withLock { seekableResources[id] = resource }
        return getAddress("/resource?id=" + id)
    }
    public func unregisterSeekableResource(url: String) {
        guard let id = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "id" })?.value else { return }
        _ = seekableLock.withLock { seekableResources.removeValue(forKey: id) }
        Task { await seekableBuffer.close(id: id) }
    }
    /// Only the current server's live, opaque resource URL is a trusted file playback endpoint.
    public func isRegisteredSeekableResource(url: String) -> Bool {
        guard isRunning, let components = URLComponents(string: url),
              components.scheme == "http", components.host == "127.0.0.1", components.port == port,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.percentEncodedPath == "/resource",
              let items = components.queryItems, items.count == 1,
              items[0].name == "id", let id = items[0].value else { return false }
        return seekableLock.withLock { seekableResources[id] != nil }
    }
    fileprivate func seekableResource(id: String) -> SeekableResource? {
        seekableLock.withLock { seekableResources[id] }
    }
    public func seekableResourceTransferProfile(forLocalURL url: String) -> PlaybackTransferProfile? {
        guard isRegisteredSeekableResource(url: url),
              let id = URLComponents(string: url)?.queryItems?.first?.value else { return nil }
        return seekableResource(id: id)?.transferProfile
    }
    fileprivate func readSeekableResource(id: String, range: Range<Int64>, phase: PlaybackTransferPhase = .playback) async throws -> Data {
        guard let resource = seekableResource(id: id) else { throw CancellationError() }
        let data = try await seekableBuffer.read(id: id, range: range, resource: resource, phase: phase)
        guard seekableResource(id: id) != nil else { throw CancellationError() }
        await enforceRemoteStreamBufferLimit()
        return data
    }
    private let recentErrorLock = NSLock()
    private var recentErrors: [String] = []
    private var cleanupTimer: DispatchSourceTimer?

    /// 启动代理服务器
    public func start() throws {
        guard !isRunning else { return }

        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let bootstrap = ServerBootstrap(group: group!)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ProxyHTTPHandler(server: self))
                }
            }
            .childChannelOption(.maxMessagesPerRead, value: 16)

        // 尝试端口 9978-9998
        for p in 9978...9998 {
            do {
                channel = try bootstrap.bind(host: "127.0.0.1", port: p).wait()
                port = p
                isRunning = true
                startRemoteStreamCleanupTimer()
                print("ProxyServer: 启动成功，端口 \(port)")
                return
            } catch {
                continue
            }
        }
        try? group?.syncShutdownGracefully()
        group = nil
        throw ProxyServerError.noAvailablePort
    }

    /// 停止代理服务器
    public func stop() {
        cleanupTimer?.cancel()
        cleanupTimer = nil
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()
        channel = nil
        group = nil
        isRunning = false
        let removedStreams = removeAllRemoteStreams()
        cancelRemovedStreams(removedStreams)
        localFileLock.lock()
        localFiles.removeAll()
        localFileLock.unlock()
        let resourceIDs = seekableLock.withLock { let ids = Array(seekableResources.keys); seekableResources.removeAll(); return ids }
        Task { for id in resourceIDs { await seekableBuffer.close(id: id) } }
        recentErrorLock.lock()
        recentErrors.removeAll()
        recentErrorLock.unlock()
        print("ProxyServer: 已停止")
    }

    /// 获取代理地址
    public func getAddress(_ path: String = "") -> String {
        "http://127.0.0.1:\(port)\(path)"
    }

    static func canBufferResponse(byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= maxBufferedResponseBytes
    }

    func cacheValue(for key: String) -> Data? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    func setCacheValue(_ value: Data, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = value
    }

    func removeCacheValue(for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: key)
    }

    /// Recovery masters are memory-only, bounded, and addressed by an opaque random key.
    public func registerRecoveryPlaylist(_ playlist: String) -> (url: String, key: String)? {
        let data = Data(playlist.utf8)
        guard data.count < 256 * 1024 else { return nil }
        let key = "hls-recovery-" + UUID().uuidString
        cacheLock.lock()
        recoveryPlaylistKeys.append(key)
        cache[key] = data
        while recoveryPlaylistKeys.count > 4 { cache.removeValue(forKey: recoveryPlaylistKeys.removeFirst()) }
        cacheLock.unlock()
        return (getAddress("/cache?key=" + key), key)
    }

    public func removeRecoveryPlaylist(_ key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        recoveryPlaylistKeys.removeAll { $0 == key }
        cache.removeValue(forKey: key)
    }

    public func registerRemoteStream(
        url: String,
        headers: [String: String],
        contentType: String = "video/mp4",
        contentLength: Int64? = nil,
        sourceByteOffset: Int64 = 0,
        continuousOpenEndedResponses: Bool = false,
        parallelSegmentedOpenEndedUpstream: Bool = false,
        parallelUpstreamUsesCurl: Bool = false,
        parallelUpstreamUsesHTTP2Multiplexing: Bool = false,
        parallelUpstreamSegmentSize: Int64 = 5 * 1024 * 1024,
        parallelUpstreamConcurrency: Int = 3,
        upstreamUsesDirectConnection: Bool = false,
        preloadLayout: RemoteStreamPreloadLayout = .standard,
        bufferConfiguration: RemoteStreamBufferConfiguration = .default,
        relayMode: RemoteStreamRelayMode = .buffered,
        transferProfile: PlaybackTransferProfile? = nil
    ) -> String {
        cleanupExpiredRemoteStreams()
        let id = UUID().uuidString
        let buffer = RemoteStreamBuffer(id: id, configuration: bufferConfiguration)
        let normalizedParallelConcurrency = max(1, parallelUpstreamConcurrency)
        let parallelConcurrencyController = RemoteStreamParallelConcurrencyController(
            maximum: normalizedParallelConcurrency, adaptive: transferProfile?.adaptsConcurrency == true
        )
        let now = Date()
        let normalizedSourceByteOffset = max(0, sourceByteOffset)
        let downstreamContentLength = contentLength.flatMap { length -> Int64? in
            let adjustedLength = length - normalizedSourceByteOffset
            return adjustedLength > 0 ? adjustedLength : nil
        }
        let usesDirectUpstream = upstreamUsesDirectConnection || parallelUpstreamUsesHTTP2Multiplexing
        let upstreamHTTPClient: HTTPClient
        if remoteStreamHTTPClient === HTTPClient.shared {
            if parallelUpstreamUsesHTTP2Multiplexing {
                upstreamHTTPClient = multiplexedRemoteStreamHTTPClient
            } else if parallelSegmentedOpenEndedUpstream && normalizedParallelConcurrency > 6 {
                upstreamHTTPClient = usesDirectUpstream
                    ? directParallelRemoteStreamHTTPClient : parallelRemoteStreamHTTPClient
            } else {
                upstreamHTTPClient = usesDirectUpstream ? directRemoteStreamHTTPClient : remoteStreamHTTPClient
            }
        } else {
            upstreamHTTPClient = usesDirectUpstream
                ? remoteStreamHTTPClient.withExplicitProxy(nil)
                : remoteStreamHTTPClient
        }
        streamLock.lock()
        streams[id] = RemoteStream(
            id: id,
            url: url,
            headers: headers,
            upstreamHTTPClient: upstreamHTTPClient,
            upstreamRequestTimeout: transferProfile?.upstreamRequestTimeout ?? Self.defaultStreamTimeout,
            contentType: contentType,
            buffer: buffer,
            bufferConfiguration: bufferConfiguration,
            relayMode: relayMode,
            sourceByteOffset: normalizedSourceByteOffset,
            continuousOpenEndedResponses: continuousOpenEndedResponses,
            parallelSegmentedOpenEndedUpstream: parallelSegmentedOpenEndedUpstream,
            parallelUpstreamUsesCurl: parallelUpstreamUsesCurl,
            parallelUpstreamUsesHTTP2Multiplexing: parallelUpstreamUsesHTTP2Multiplexing,
            parallelUpstreamSegmentSize: max(1, parallelUpstreamSegmentSize),
            parallelUpstreamConcurrency: normalizedParallelConcurrency,
            parallelConcurrencyController: parallelConcurrencyController,
            preloadLayout: preloadLayout,
            contentLength: downstreamContentLength,
            createdAt: now,
            lastAccessAt: now,
            recentError: nil
        )
        let removed = trimRemoteStreamsLocked()
        streamLock.unlock()
        cancelRemovedStreams(removed)

        var components = URLComponents(string: getAddress("/stream"))!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        DiagnosticLog.write("[REMOTE_STREAM_NETWORK_ROUTE] id=\(id), route=\(usesDirectUpstream ? "direct" : "automatic")")
        if let transferProfile {
            DiagnosticLog.write("[PLAYBACK_TRANSFER_PROFILE] id=\(id) version=\(PlaybackTransferProfile.version) profile=\(transferProfile.diagnosticName) initialBytes=\(transferProfile.initialReadBytes) steadyBytes=\(transferProfile.steadyReadBytes) cacheLimit=\(transferProfile.maximumCachedBytes)")
        }
        DiagnosticLog.write("[REMOTE_STREAM_REGISTER] id=\(id), mode=\(relayMode.rawValue), sourceByteOffset=\(normalizedSourceByteOffset), continuousOpenEndedResponses=\(continuousOpenEndedResponses), parallelSegmentedOpenEndedUpstream=\(parallelSegmentedOpenEndedUpstream), parallelUpstreamUsesCurl=\(parallelUpstreamUsesCurl), parallelUpstreamUsesHTTP2Multiplexing=\(parallelUpstreamUsesHTTP2Multiplexing), parallelUpstreamSegmentSize=\(max(1, parallelUpstreamSegmentSize)), parallelUpstreamConcurrency=\(normalizedParallelConcurrency), url=\(Self.redactedURL(url)), headers=\(Self.redactedHeaders(headers))")
        return components.url?.absoluteString ?? getAddress("/stream?id=\(id)")
    }

    @discardableResult
    public func unregisterRemoteStream(id: String) -> Bool {
        streamLock.lock()
        let removed = streams.removeValue(forKey: id)
        streamLock.unlock()
        if let removed {
            Task { await removed.buffer.cancelAll() }
            DiagnosticLog.write("[REMOTE_STREAM_UNREGISTER] id=\(id)")
            return true
        }
        return false
    }

    @discardableResult
    public func unregisterRemoteStream(forLocalURL localURL: String) -> Bool {
        guard let components = URLComponents(string: localURL),
              components.path == "/stream",
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty else {
            return false
        }
        return unregisterRemoteStream(id: id)
    }

    public func registerLocalFile(url: URL) -> String {
        let id = UUID().uuidString
        localFileLock.lock()
        localFiles[id] = RegisteredLocalFile(id: id, url: url, createdAt: Date())
        localFileLock.unlock()
        var components = URLComponents(string: getAddress("/file"))!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url?.absoluteString ?? getAddress("/file?id=\(id)")
    }

    public func remoteStreamPlaybackInfo(forLocalURL urlString: String) -> RemoteStreamPlaybackInfo? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              (host == "127.0.0.1" || host == "localhost"),
              components.path == "/stream",
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let stream = stream(for: id) else {
            return nil
        }

        return RemoteStreamPlaybackInfo(
            url: stream.url,
            headers: stream.headers,
            contentType: stream.contentType,
            sourceByteOffset: stream.sourceByteOffset
        )
    }

    public func remoteStreamBufferSnapshot(forLocalURL urlString: String) async -> RemoteStreamBufferSnapshot? {
        if isRegisteredSeekableResource(url: urlString),
           let id = URLComponents(string: urlString)?.queryItems?.first?.value {
            return await seekableBuffer.snapshot(id: id)
        }
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              (host == "127.0.0.1" || host == "localhost"),
              components.path == "/stream",
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let stream = stream(for: id) else {
            return nil
        }

        return await stream.buffer.snapshot()
    }

    @discardableResult
    public func setRemoteStreamParallelConcurrencyLimit(
        forLocalURL urlString: String,
        limit: Int
    ) -> Int? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              (host == "127.0.0.1" || host == "localhost"),
              components.port == port,
              components.path == "/stream",
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let stream = stream(for: id),
              stream.parallelSegmentedOpenEndedUpstream else {
            return nil
        }
        let previous = stream.parallelConcurrencyController.setLimit(limit)
        DiagnosticLog.write(
            "[REMOTE_STREAM_CONCURRENCY] id=\(id) previous=\(previous) current=\(stream.parallelConcurrencyController.currentLimit) maximum=\(stream.parallelUpstreamConcurrency)"
        )
        return previous
    }

    public func prefetchRemoteStream(
        forLocalURL urlString: String,
        byteLimit: Int64 = 16 * 1024 * 1024,
        mode: RemoteStreamPreloadMode = .full
    ) async throws -> RemoteStreamBufferSnapshot? {
        if isRegisteredSeekableResource(url: urlString), byteLimit > 0,
           let id = URLComponents(string: urlString)?.queryItems?.first?.value,
           let resource = seekableResource(id: id) {
            let limit = min(resource.size, byteLimit, PlaybackTransferProfile.backgroundByteLimit,
                mode == .essentials ? 512 * 1024 : 2 * 1024 * 1024)
            var start: Int64 = 0
            while start < limit {
                try await PlaybackBackgroundBudget.shared.waitForBackgroundPermission()
                let end = min(limit, start + 512 * 1024)
                _ = try await readSeekableResource(id: id, range: start..<end, phase: .preload)
                start = end
            }
            return await seekableBuffer.snapshot(id: id)
        }
        guard isRunning,
              byteLimit > 0,
              var components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              components.port == port,
              components.path == "/stream",
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let stream = stream(for: id) else {
            return nil
        }

        let cappedLimit = min(byteLimit, PlaybackTransferProfile.backgroundByteLimit)
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "preload" }
        items.append(URLQueryItem(name: "preload", value: "1"))
        components.queryItems = items
        guard let preloadURL = components.url?.absoluteString else { return nil }

        if stream.parallelSegmentedOpenEndedUpstream {
            let usesUCStartupLayout = stream.preloadLayout == .ucOriginal
            let usesQuarkStartupLayout = stream.preloadLayout == .quarkOriginal
            let usesAudioStartupLayout = stream.preloadLayout == .audioOriginal
            let segmentSize = stream.parallelUpstreamUsesHTTP2Multiplexing
                ? 512 * 1024
                : max(1, stream.parallelUpstreamSegmentSize)
            let concurrency = max(1, stream.parallelUpstreamConcurrency)
            let plan = RemoteStreamPreloadPolicy.plan(
                byteLimit: cappedLimit,
                contentLength: stream.contentLength,
                segmentSize: segmentSize,
                concurrency: concurrency,
                usesUCStartupLayout: usesUCStartupLayout,
                usesQuarkStartupLayout: usesQuarkStartupLayout,
                usesAudioStartupLayout: usesAudioStartupLayout,
                essentialsOnly: mode == .essentials
            )
            let ranges = plan.ranges
            let preloadConcurrency = usesAudioStartupLayout ? min(concurrency, 2)
                : usesUCStartupLayout || usesQuarkStartupLayout
                    ? min(concurrency, mode == .essentials ? 4 : 24) : concurrency
            let activeConcurrency = min(ranges.count, preloadConcurrency)
            let preloadClient: HTTPClient
            if stream.parallelUpstreamUsesHTTP2Multiplexing,
               remoteStreamHTTPClient === HTTPClient.shared {
                preloadClient = multiplexedRemoteStreamHTTPClient
            } else {
                let sessionConfiguration = URLSessionConfiguration.ephemeral
                sessionConfiguration.httpMaximumConnectionsPerHost = activeConcurrency
                preloadClient = HTTPClient(session: URLSession(configuration: sessionConfiguration)).withExplicitProxy(nil)
            }
            await withTaskGroup(of: Void.self) { group in
                var remaining = ranges.makeIterator()
                func enqueue(_ range: RemoteStreamRange) {
                    group.addTask {
                        do {
                            try await PlaybackBackgroundBudget.shared.waitForBackgroundPermission()
                            _ = try await preloadClient.request(
                            url: preloadURL,
                            method: .get,
                            headers: ["Range": range.headerValue],
                            timeout: 20,
                            allowsProxyFallback: false,
                            redactsURLInLogs: true
                            )
                        } catch { }
                    }
                }
                for _ in 0..<activeConcurrency {
                    if let range = remaining.next() { enqueue(range) }
                }
                while await group.next() != nil {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    if let range = remaining.next() { enqueue(range) }
                }
            }
            try Task.checkCancellation()
            let snapshot = await stream.buffer.snapshot()
            guard snapshot.covers(ranges) else { throw ProxyServerError.emptyUpstreamResponse("preload-coverage") }
            DiagnosticLog.write(
                "[NEXT_PRELOAD_RANGE] id=\(id) mode=parallel phase=\(mode.rawValue) cachedBytes=\(snapshot.cachedBytes) headerBytes=\(plan.headerBytes) startupStart=\(plan.startupStart) startupBytes=\(plan.startupBytes) tailBytes=\(plan.tailBytes) segments=\(ranges.count) activeConcurrency=\(activeConcurrency)"
            )
            return snapshot
        }

        var start: Int64 = 0
        let sequentialLimit = min(cappedLimit, stream.contentLength ?? cappedLimit, mode == .essentials ? stream.bufferConfiguration.initialChunkSize : cappedLimit)
        while start < sequentialLimit {
            try await PlaybackBackgroundBudget.shared.waitForBackgroundPermission()
            let requestedSize = start == 0
                ? stream.bufferConfiguration.initialChunkSize
                : stream.bufferConfiguration.chunkSize
            let size = max(1, min(requestedSize, sequentialLimit - start))
            let end = start + size - 1
            let response = try await directRemoteStreamHTTPClient.request(
                url: preloadURL,
                method: .get,
                headers: ["Range": "bytes=\(start)-\(end)"],
                timeout: Self.defaultStreamTimeout,
                allowsProxyFallback: false,
                redactsURLInLogs: true
            )
            guard (200..<300).contains(response.statusCode), !response.data.isEmpty else { break }
            let parsedRange = parseRemoteStreamContentRange(response.headers)
            start = parsedRange.map { $0.end + 1 }
                ?? (start + Int64(response.data.count))
            if let totalLength = parsedRange?.total, start >= totalLength {
                break
            }
        }

        try Task.checkCancellation()
        let snapshot = await stream.buffer.snapshot()
        guard sequentialLimit > 0, snapshot.covers([.init(start: 0, end: sequentialLimit - 1)]) else {
            throw ProxyServerError.emptyUpstreamResponse("preload-coverage")
        }
        DiagnosticLog.write(
            "[NEXT_PRELOAD_RANGE] id=\(id) cachedBytes=\(snapshot.cachedBytes) limit=\(cappedLimit)"
        )
        return snapshot
    }

    private func parseRemoteStreamContentRange(
        _ headers: [String: String]
    ) -> (end: Int64, total: Int64?)? {
        guard let contentRange = headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Range") == .orderedSame
        })?.value,
              let slash = contentRange.lastIndex(of: "/"),
              let dash = contentRange[..<slash].lastIndex(of: "-"),
              let end = Int64(contentRange[contentRange.index(after: dash)..<slash]) else {
            return nil
        }
        let totalText = contentRange[contentRange.index(after: slash)...]
        return (end, totalText == "*" ? nil : Int64(totalText))
    }

    func stream(for id: String) -> RemoteStream? {
        cleanupExpiredRemoteStreams()
        streamLock.lock()
        defer { streamLock.unlock() }
        guard var stream = streams[id] else { return nil }
        stream.lastAccessAt = Date()
        streams[id] = stream
        return stream
    }

    func localFile(for id: String) -> RegisteredLocalFile? {
        localFileLock.lock()
        defer { localFileLock.unlock() }
        return localFiles[id]
    }

    func setRemoteStreamError(id: String, message: String) {
        streamLock.lock()
        if var stream = streams[id] {
            stream.recentError = message
            stream.lastAccessAt = Date()
            streams[id] = stream
        }
        streamLock.unlock()
        recordRecentError(message)
    }

    func updateRemoteStreamContentLength(id: String, contentLength: Int64) {
        guard contentLength > 0 else { return }
        streamLock.lock()
        if var stream = streams[id] {
            stream.contentLength = contentLength
            stream.lastAccessAt = Date()
            streams[id] = stream
        }
        streamLock.unlock()
    }

    func recordRecentError(_ message: String) {
        recentErrorLock.lock()
        defer { recentErrorLock.unlock() }
        recentErrors.append(message)
        if recentErrors.count > 20 {
            recentErrors.removeFirst(recentErrors.count - 20)
        }
    }

    public func healthSnapshot() async -> ProxyHealthSnapshot {
        cleanupExpiredRemoteStreams()
        let currentStreams = currentRemoteStreams()
        var streamSnapshots: [ProxyHealthStreamSnapshot] = []
        var totalCachedBytes: Int64 = 0
        for stream in currentStreams.sorted(by: { $0.lastAccessAt > $1.lastAccessAt }) {
            let snapshot = await stream.buffer.snapshot()
            totalCachedBytes += snapshot.cachedBytes
            streamSnapshots.append(
                ProxyHealthStreamSnapshot(
                    id: stream.id,
                    url: Self.redactedURL(stream.url),
                    contentType: stream.contentType,
                    relayMode: stream.relayMode.rawValue,
                    createdAt: stream.createdAt.timeIntervalSince1970,
                    lastAccessAt: stream.lastAccessAt.timeIntervalSince1970,
                    cachedBytes: snapshot.cachedBytes,
                    inFlightRanges: snapshot.inFlightRanges.map(\.headerValue),
                    recentError: stream.recentError
                )
            )
        }

        if totalCachedBytes > Self.remoteStreamGlobalBufferMaxBytes {
            Task { await self.enforceRemoteStreamBufferLimit() }
        }

        let errors = currentRecentErrors()
        return ProxyHealthSnapshot(
            isRunning: isRunning,
            port: port,
            activeStreams: streamSnapshots.count,
            cachedBytes: totalCachedBytes,
            streams: streamSnapshots,
            recentErrors: errors
        )
    }

    public func enforceRemoteStreamBufferLimit() async {
        let entries = currentRemoteStreamBufferEntries()

        var measured: [(id: String, lastAccessAt: Date, cachedBytes: Int64, buffer: RemoteStreamBuffer)] = []
        var total: Int64 = await seekableBuffer.totalCachedBytes
        for entry in entries {
            let snapshot = await entry.buffer.snapshot()
            total += snapshot.cachedBytes
            measured.append((entry.id, entry.lastAccessAt, snapshot.cachedBytes, entry.buffer))
        }
        guard total > Self.remoteStreamGlobalBufferMaxBytes else { return }

        let sorted = measured.sorted { $0.lastAccessAt < $1.lastAccessAt }
        let removedBuffers = removeRemoteStreamsUntilWithinCacheLimit(sorted, totalCachedBytes: total)
        for buffer in removedBuffers {
            await buffer.cancelAll()
        }
    }

    private func currentRemoteStreams() -> [RemoteStream] {
        streamLock.lock()
        defer { streamLock.unlock() }
        return Array(streams.values)
    }

    private func currentRemoteStreamBufferEntries() -> [(id: String, lastAccessAt: Date, cachedBytes: Int64, buffer: RemoteStreamBuffer)] {
        streamLock.lock()
        defer { streamLock.unlock() }
        return streams.values.map { ($0.id, $0.lastAccessAt, 0, $0.buffer) }
    }

    private func removeRemoteStreamsUntilWithinCacheLimit(
        _ entries: [(id: String, lastAccessAt: Date, cachedBytes: Int64, buffer: RemoteStreamBuffer)],
        totalCachedBytes: Int64
    ) -> [RemoteStreamBuffer] {
        var total = totalCachedBytes
        var removedBuffers: [RemoteStreamBuffer] = []
        streamLock.lock()
        for entry in entries where total > Self.remoteStreamGlobalBufferMaxBytes {
            if streams.removeValue(forKey: entry.id) != nil {
                total -= entry.cachedBytes
                removedBuffers.append(entry.buffer)
            }
        }
        streamLock.unlock()
        return removedBuffers
    }

    private func currentRecentErrors() -> [String] {
        recentErrorLock.lock()
        defer { recentErrorLock.unlock() }
        return recentErrors
    }

    private func removeAllRemoteStreams() -> [RemoteStream] {
        streamLock.lock()
        let removed = Array(streams.values)
        streams.removeAll()
        streamLock.unlock()
        return removed
    }

    private func startRemoteStreamCleanupTimer() {
        cleanupTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.netvplayer.proxy.cleanup"))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.cleanupExpiredRemoteStreams()
            Task {
                await self.enforceRemoteStreamBufferLimit()
            }
        }
        cleanupTimer = timer
        timer.resume()
    }

    private func cleanupExpiredRemoteStreams() {
        let now = Date()
        streamLock.lock()
        let expiredIDs = streams.compactMap { id, stream in
            now.timeIntervalSince(stream.lastAccessAt) > Self.remoteStreamIdleTTL ? id : nil
        }
        let removed = expiredIDs.compactMap { streams.removeValue(forKey: $0) }
        streamLock.unlock()
        cancelRemovedStreams(removed)
    }

    private func trimRemoteStreamsLocked() -> [RemoteStream] {
        guard streams.count > Self.remoteStreamMaxActive else { return [] }
        let sorted = streams.values.sorted { $0.lastAccessAt < $1.lastAccessAt }
        let removeCount = streams.count - Self.remoteStreamMaxActive
        let removed = Array(sorted.prefix(removeCount))
        for stream in removed {
            streams.removeValue(forKey: stream.id)
        }
        return removed
    }

    private func cancelRemovedStreams(_ streams: [RemoteStream]) {
        for stream in streams {
            Task { await stream.buffer.cancelAll() }
        }
    }

    private static func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, item in
            if item.key.caseInsensitiveCompare("Cookie") == .orderedSame
                || item.key.caseInsensitiveCompare("Authorization") == .orderedSame {
                result[item.key] = "<redacted>"
            } else {
                result[item.key] = item.value
            }
        }
    }

    static func redactedURL(_ url: String) -> String {
        let url = XtreamLogRedaction.redact(url)
        guard var components = URLComponents(string: url) else { return url }
        components.queryItems = components.queryItems?.map { item in
            switch item.name.lowercased() {
            case "auth_key", "token", "signature", "ossaccesskeyid", "callback", "callback-var", "ut",
                 "x-oss-credential", "x-oss-security-token", "x-oss-signature", "upsig", "sign",
                 "trid", "traceid", "e", "oi", "mid", "buvid", "qn_dyeid":
                return URLQueryItem(name: item.name, value: "<redacted>")
            default:
                return item
            }
        }
        return components.string ?? url
    }
}

public struct RemoteStreamPlaybackInfo: Sendable {
    public let url: String
    public let headers: [String: String]
    public let contentType: String
    public let sourceByteOffset: Int64
}

public enum RemoteStreamRelayMode: String, Codable, Sendable {
    case buffered
    case chunked
}

public enum RemoteStreamPreloadMode: String, Sendable {
    case essentials
    case full
}

public enum RemoteStreamPreloadLayout: Sendable {
    case standard
    case audioOriginal
    case ucOriginal
    case quarkOriginal
}

struct RegisteredLocalFile: Sendable {
    let id: String
    let url: URL
    let createdAt: Date
}

final class RemoteStreamParallelConcurrencyController: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var limit: Int
    private let adaptive: Bool
    private var adaptiveLimit: Int
    private var windowStarted: TimeInterval?
    private var samples = 0
    private var timeouts = 0
    private var healthyWindows = 0

    init(maximum: Int, adaptive: Bool = false) {
        let normalized = max(1, maximum)
        self.maximum = normalized
        self.limit = normalized
        self.adaptiveLimit = normalized
        self.adaptive = adaptive
    }

    var currentLimit: Int {
        lock.lock()
        defer { lock.unlock() }
        return min(limit, adaptiveLimit)
    }

    @discardableResult
    func setLimit(_ requestedLimit: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let previous = limit
        limit = min(maximum, max(1, requestedLimit))
        return previous
    }

    static func isTimeout(_ error: Error) -> Bool {
        // UC/Quark's measured transport reports libcurl errors, while other
        // requests use URLSession. Both must contribute to the same window.
        if let curl = error as? CurlRangeTransportError { return curl.code == 28 } // CURLE_OPERATION_TIMEDOUT
        let failure = error as NSError
        return failure.domain == NSURLErrorDomain && failure.code == NSURLErrorTimedOut
    }

    /// Only UC/Quark video profiles opt in. Auth failures and cancellation never
    /// count as congestion. Changes apply to newly scheduled requests.
    @discardableResult
    func record(timedOut: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                bufferedEnough: Bool = PlaybackBackgroundBudget.shared.permitsBackgroundWork) -> Bool {
        guard adaptive else { return false }
        return lock.withLock {
            if windowStarted == nil { windowStarted = now }
            samples += 1; if timedOut { timeouts += 1 }
            guard now - (windowStarted ?? now) >= 5, samples >= 5 else { return false }
            defer { windowStarted = now; samples = 0; timeouts = 0 }
            if Double(timeouts) / Double(samples) >= 0.2 {
                adaptiveLimit = max(min(2, maximum), adaptiveLimit / 2)
                healthyWindows = 0
                return true
            }
            if timeouts == 0, bufferedEnough {
                healthyWindows += 1
                if healthyWindows >= 3 {
                    adaptiveLimit = min(maximum, adaptiveLimit * 2)
                    healthyWindows = 0
                }
            } else { healthyWindows = 0 }
            return false
        }
    }
}

struct RemoteStream: Sendable {
    let id: String
    let url: String
    let headers: [String: String]
    let upstreamHTTPClient: HTTPClient
    let upstreamRequestTimeout: TimeInterval
    let contentType: String
    let buffer: RemoteStreamBuffer
    let bufferConfiguration: RemoteStreamBufferConfiguration
    let relayMode: RemoteStreamRelayMode
    let sourceByteOffset: Int64
    let continuousOpenEndedResponses: Bool
    let parallelSegmentedOpenEndedUpstream: Bool
    let parallelUpstreamUsesCurl: Bool
    let parallelUpstreamUsesHTTP2Multiplexing: Bool
    let parallelUpstreamSegmentSize: Int64
    let parallelUpstreamConcurrency: Int
    let parallelConcurrencyController: RemoteStreamParallelConcurrencyController
    let preloadLayout: RemoteStreamPreloadLayout
    var contentLength: Int64?
    let createdAt: Date
    var lastAccessAt: Date
    var recentError: String?
}

public struct RemoteStreamRange: Sendable, Hashable {
    public let start: Int64
    public let end: Int64
    private let rawHeaderValue: String?

    init(start: Int64, end: Int64, rawHeaderValue: String? = nil) {
        self.start = start
        self.end = end
        self.rawHeaderValue = rawHeaderValue
    }

    var headerValue: String {
        rawHeaderValue ?? "bytes=\(start)-\(end)"
    }

    var count: Int64 {
        max(0, end - start + 1)
    }

    func contains(_ other: RemoteStreamRange) -> Bool {
        start <= other.start && end >= other.end
    }
}

struct RemoteStreamPreloadPlan: Sendable, Equatable {
    let ranges: [RemoteStreamRange]
    let headerBytes: Int64
    let startupStart: Int64
    let startupBytes: Int64
    let tailBytes: Int64
}

enum RemoteStreamPreloadPolicy {
    static func plan(
        byteLimit: Int64,
        contentLength: Int64?,
        segmentSize: Int64,
        concurrency: Int,
        usesUCStartupLayout: Bool = false,
        usesQuarkStartupLayout: Bool = false,
        usesAudioStartupLayout: Bool = false,
        essentialsOnly: Bool = false
    ) -> RemoteStreamPreloadPlan {
        let safeLimit = max(0, byteLimit)
        let safeSegmentSize = max(1, segmentSize)
        let oneWaveLimit = safeSegmentSize * Int64(max(1, concurrency))
        let knownLength = max(0, contentLength ?? safeLimit)
        let usesCompactUCLayout = usesUCStartupLayout && knownLength > 32 * 1024 * 1024
        let headerBytes: Int64
        let startupStart: Int64
        let startupBytes: Int64
        let tailBytes: Int64
        var ranges: [RemoteStreamRange]

        if usesAudioStartupLayout {
            headerBytes = min(essentialsOnly ? 64 * 1024 : 2 * 1024 * 1024, safeLimit, knownLength)
            startupStart = 0
            startupBytes = 0
            tailBytes = 0
            ranges = makeRanges(start: 0, byteCount: headerBytes, segmentSize: safeSegmentSize)
        } else if usesQuarkStartupLayout {
            // Quark MP4s start at the file head and can carry a multi-MiB moov at EOF.
            let budget = min(safeLimit, knownLength)
            headerBytes = min(essentialsOnly ? 512 * 1024 : 8 * 1024 * 1024, budget)
            startupStart = 0
            startupBytes = 0
            tailBytes = contentLength == nil ? 0 : min(8 * 1024 * 1024, budget - headerBytes)
            ranges = makeRanges(start: 0, byteCount: headerBytes, segmentSize: safeSegmentSize)
            ranges.append(contentsOf: makeRanges(
                start: knownLength - tailBytes,
                byteCount: tailBytes,
                segmentSize: safeSegmentSize
            ))
        } else if usesCompactUCLayout {
            headerBytes = min(512 * 1024, safeLimit, knownLength)
            tailBytes = min(
                2 * 1024 * 1024,
                max(0, safeLimit - headerBytes),
                max(0, knownLength - headerBytes)
            )
            startupStart = essentialsOnly
                ? 0
                : min(5 * 1024 * 1024, max(headerBytes, knownLength - tailBytes))
            startupBytes = essentialsOnly
                ? 0
                : min(
                    19 * 512 * 1024,
                    max(0, safeLimit - headerBytes - tailBytes),
                    max(0, knownLength - tailBytes - startupStart)
                )
            ranges = makeRanges(start: 0, byteCount: headerBytes, segmentSize: safeSegmentSize)
            ranges.append(contentsOf: makeRanges(
                start: knownLength - tailBytes,
                byteCount: tailBytes,
                segmentSize: safeSegmentSize
            ))
            ranges.append(contentsOf: makeRanges(
                start: startupStart,
                byteCount: startupBytes,
                segmentSize: safeSegmentSize
            ))
        } else {
            headerBytes = min(safeLimit, oneWaveLimit, knownLength)
            startupStart = 0
            startupBytes = 0
            let remainingBudget = max(0, safeLimit - headerBytes)
            tailBytes = contentLength.map { totalLength in
                min(3 * 1024 * 1024, remainingBudget, max(0, totalLength - headerBytes))
            } ?? 0
            ranges = makeRanges(start: 0, byteCount: headerBytes, segmentSize: safeSegmentSize)
            if contentLength != nil {
                ranges.append(contentsOf: makeRanges(
                    start: knownLength - tailBytes,
                    byteCount: tailBytes,
                    segmentSize: safeSegmentSize
                ))
            }
        }

        return RemoteStreamPreloadPlan(
            ranges: disjointRanges(ranges),
            headerBytes: headerBytes,
            startupStart: startupStart,
            startupBytes: startupBytes,
            tailBytes: tailBytes
        )
    }

    private static func disjointRanges(_ ranges: [RemoteStreamRange]) -> [RemoteStreamRange] {
        var result: [RemoteStreamRange] = []
        for range in ranges.sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }) {
            let start = max(range.start, result.last.map { $0.end + 1 } ?? range.start)
            if start <= range.end { result.append(.init(start: start, end: range.end)) }
        }
        return result
    }

    private static func makeRanges(
        start: Int64,
        byteCount: Int64,
        segmentSize: Int64
    ) -> [RemoteStreamRange] {
        guard byteCount > 0 else { return [] }
        let end = start + byteCount
        return stride(from: start, to: end, by: Int(segmentSize)).map { rangeStart in
            RemoteStreamRange(
                start: rangeStart,
                end: min(end - 1, rangeStart + segmentSize - 1)
            )
        }
    }
}

struct RemoteStreamChunk: Sendable {
    let range: RemoteStreamRange
    let data: Data
    let headers: [String: String]
    let contentType: String
    let totalLength: Int64?
}

public struct RemoteStreamBufferSnapshot: Sendable {
    public let chunkRanges: [RemoteStreamRange]
    public let inFlightRanges: [RemoteStreamRange]
    public let cachedBytes: Int64
    public let deliveredBytes: Int64
    public let receivedBytes: Int64

    public func covers(_ ranges: [RemoteStreamRange]) -> Bool {
        let sorted = chunkRanges.sorted { $0.start < $1.start }
        return ranges.allSatisfy { target in
            var cursor = target.start
            for range in sorted {
                if range.end < cursor { continue }
                if range.start > cursor { break }
                cursor = max(cursor, range.end + 1)
                if cursor > target.end { return true }
            }
            return false
        }
    }
}

public struct ProxyHealthSnapshot: Codable, Sendable {
    public let isRunning: Bool
    public let port: Int
    public let activeStreams: Int
    public let cachedBytes: Int64
    public let streams: [ProxyHealthStreamSnapshot]
    public let recentErrors: [String]
}

public struct ProxyHealthStreamSnapshot: Codable, Sendable {
    public let id: String
    public let url: String
    public let contentType: String
    public let relayMode: String
    public let createdAt: TimeInterval
    public let lastAccessAt: TimeInterval
    public let cachedBytes: Int64
    public let inFlightRanges: [String]
    public let recentError: String?
}

public struct RemoteStreamBufferConfiguration: Sendable {
    let initialChunkSize: Int64
    let chunkSize: Int64
    let prefetchWindowSize: Int64
    let maxBytes: Int64
    let maxConcurrentPrefetches: Int
    let prefetchableStartLimit: Int64

    public static let `default` = RemoteStreamBufferConfiguration(
        initialChunkSize: ProxyServer.defaultStreamChunkSize,
        chunkSize: ProxyServer.openEndedStreamChunkSize,
        prefetchWindowSize: ProxyServer.streamPrefetchWindowSize,
        maxBytes: ProxyServer.streamBufferMaxBytes,
        maxConcurrentPrefetches: ProxyServer.streamPrefetchMaxConcurrent,
        prefetchableStartLimit: Int64.max
    )

    public init(
        initialChunkSize: Int64? = nil,
        chunkSize: Int64,
        prefetchWindowSize: Int64,
        maxBytes: Int64,
        maxConcurrentPrefetches: Int,
        prefetchableStartLimit: Int64 = Int64.max
    ) {
        self.initialChunkSize = initialChunkSize ?? ProxyServer.defaultStreamChunkSize
        self.chunkSize = chunkSize
        self.prefetchWindowSize = prefetchWindowSize
        self.maxBytes = maxBytes
        self.maxConcurrentPrefetches = maxConcurrentPrefetches
        self.prefetchableStartLimit = prefetchableStartLimit
    }
}

enum RemoteStreamLoadKind: Sendable {
    case demand
    case prefetch
    case prime
}

struct RemoteStreamInFlight: Sendable {
    let id: UUID
    let generation: Int
    let kind: RemoteStreamLoadKind
    let task: Task<RemoteStreamChunk, Error>
    let read: PlaybackSharedRead<RemoteStreamChunk>

    init(id: UUID, generation: Int, kind: RemoteStreamLoadKind, task: Task<RemoteStreamChunk, Error>) {
        self.id = id; self.generation = generation; self.kind = kind; self.task = task
        self.read = PlaybackSharedRead(task: task)
    }
}

actor RemoteStreamBuffer {
    private let id: String
    private let configuration: RemoteStreamBufferConfiguration
    private var chunks: [RemoteStreamChunk] = []
    private var inFlight: [RemoteStreamRange: RemoteStreamInFlight] = [:]
    private var cachedBytes: Int64 = 0
    private var deliveredBytes: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var activeStart: Int64 = 0
    private var generation = 0
    private var closed = false
    private var prefetchTargetEnd: Int64 = -1
    private var nextPrefetchStart: Int64?
    private var pendingEvictionChunks = 0
    private var pendingEvictionBytes: Int64 = 0
    private var lastEvictionLogAt = Date.distantPast

    init(id: String, configuration: RemoteStreamBufferConfiguration = .default) {
        self.id = id
        self.configuration = configuration
    }

    func snapshot() -> RemoteStreamBufferSnapshot {
        RemoteStreamBufferSnapshot(
            chunkRanges: chunks.filter { !$0.data.isEmpty }.map {
                RemoteStreamRange(start: $0.range.start, end: min($0.range.end, $0.range.start + Int64($0.data.count) - 1))
            }.sorted { $0.start < $1.start },
            inFlightRanges: Array(inFlight.keys).sorted { $0.start < $1.start },
            cachedBytes: cachedBytes,
            deliveredBytes: deliveredBytes,
            receivedBytes: receivedBytes
        )
    }

    func recordDeliveredBytes(_ count: Int) {
        guard count > 0 else { return }
        deliveredBytes += Int64(count)
    }

    func recordReceivedBytes(_ count: Int) {
        guard count > 0 else { return }
        receivedBytes += Int64(count)
    }

    func cancelAll() {
        closed = true
        for marker in inFlight.values {
            marker.read.cancel()
        }
        inFlight.removeAll()
        chunks.removeAll()
        cachedBytes = 0
        generation += 1
        prefetchTargetEnd = -1
        nextPrefetchStart = nil
    }

    func response(
        for requestedRange: RemoteStreamRange,
        stream: RemoteStream,
        method: NIOHTTP1.HTTPMethod,
        isPriming: Bool = false,
        fetch: @escaping @Sendable (RemoteStreamRange, RemoteStreamLoadKind) async throws -> RemoteStreamChunk
    ) async throws -> ProxyResponse {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let cached = assembledCachedChunk(containing: requestedRange),
           !isPriming || cached.range.contains(requestedRange) {
            DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_HIT] id=\(id), range=\(requestedRange.headerValue)")
            if !isPriming {
                advancePlaybackStart(to: requestedRange.start)
                schedulePrefetch(after: cached, stream: stream, fetch: fetch)
            }
            return proxyResponse(from: cached, requestedRange: requestedRange, method: method)
        }

        if let marker = inFlightMarker(containing: requestedRange) {
            DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_WAIT] id=\(id), range=\(requestedRange.headerValue)")
            let chunk = try await marker.read.value(phase: isPriming ? .preload : .playback)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            removeCompletedMarker(marker)
            if marker.kind != .prefetch {
                processDemandChunk(
                    chunk,
                    requestedRange: requestedRange,
                    markerGeneration: marker.generation,
                    stream: stream,
                    isPriming: isPriming,
                    fetch: fetch
                )
            } else {
                store(chunk, prefetch: false)
                if !isPriming {
                    advancePlaybackStart(to: requestedRange.start)
                    schedulePrefetch(after: chunk, stream: stream, fetch: fetch)
                }
            }
            return proxyResponse(from: chunk, requestedRange: requestedRange, method: method)
        }

        DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_MISS] id=\(id), range=\(requestedRange.headerValue)")
        let loadKind: RemoteStreamLoadKind = isPriming ? .prime : .demand
        let (chunk, markerGeneration) = try await loadDemand(
            range: requestedRange,
            kind: loadKind,
            fetch: fetch
        )
        processDemandChunk(
            chunk,
            requestedRange: requestedRange,
            markerGeneration: markerGeneration,
            stream: stream,
            isPriming: isPriming,
            fetch: fetch
        )
        return proxyResponse(from: chunk, requestedRange: requestedRange, method: method)
    }

    func continuousResponse(for requestedRange: RemoteStreamRange) -> ProxyResponse? {
        guard !closed else { return nil }
        guard let cached = assembledCachedChunk(containing: requestedRange) else {
            return nil
        }
        DiagnosticLog.write("[REMOTE_STREAM_CONTINUOUS_CACHE_HIT] id=\(id), range=\(requestedRange.headerValue)")
        advancePlaybackStart(to: requestedRange.start)
        return proxyResponse(from: cached, requestedRange: requestedRange, method: .GET)
    }

    func parallelContinuousChunk(
        for requestedRange: RemoteStreamRange,
        fetch: @escaping @Sendable (RemoteStreamRange) async throws -> RemoteStreamChunk
    ) async throws -> RemoteStreamChunk {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let cached = assembledCachedChunk(containing: requestedRange),
           cached.range.contains(requestedRange) {
            DiagnosticLog.write("[REMOTE_STREAM_CONTINUOUS_CACHE_HIT] id=\(id), range=\(requestedRange.headerValue)")
            return cached
        }

        if let marker = inFlightMarker(containing: requestedRange) {
            let chunk = try await marker.read.value()
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            removeCompletedMarker(marker)
            store(chunk, prefetch: false)
            return assembledCachedChunk(containing: requestedRange) ?? chunk
        }

        let task = Task<RemoteStreamChunk, Error> {
            try await fetch(requestedRange)
        }
        let marker = RemoteStreamInFlight(
            id: UUID(),
            generation: generation,
            kind: .demand,
            task: task
        )
        inFlight[requestedRange] = marker

        do {
            let chunk = try await marker.read.value()
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if inFlight[requestedRange]?.id == marker.id {
                inFlight.removeValue(forKey: requestedRange)
            }
            store(chunk, prefetch: false)
            return assembledCachedChunk(containing: requestedRange) ?? chunk
        } catch {
            if inFlight[requestedRange]?.id == marker.id, !marker.read.hasForegroundReaders {
                inFlight.removeValue(forKey: requestedRange)
            }
            throw error
        }
    }

    func storeContinuousChunk(_ chunk: RemoteStreamChunk) {
        guard !closed else { return }
        if isSeek(from: activeStart, to: chunk.range.start) {
            cancelPrefetch(except: [])
            chunks.removeAll()
            cachedBytes = 0
            prefetchTargetEnd = -1
            nextPrefetchStart = nil
            DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_CANCEL] id=\(id), reason=continuous-seek, start=\(chunk.range.start)")
        }
        activeStart = chunk.range.start
        store(chunk, prefetch: false)
    }

    private func processDemandChunk(
        _ chunk: RemoteStreamChunk,
        requestedRange: RemoteStreamRange,
        markerGeneration: Int,
        stream: RemoteStream,
        isPriming: Bool,
        fetch: @escaping @Sendable (RemoteStreamRange, RemoteStreamLoadKind) async throws -> RemoteStreamChunk
    ) {
        guard !closed, markerGeneration == generation || requestedRange.start >= activeStart else {
            DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_CANCEL] id=\(id), range=\(requestedRange.headerValue), reason=stale-demand")
            return
        }

        if !isPriming, isTailMetadataProbe(chunk) {
            DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_CANCEL] id=\(id), range=\(requestedRange.headerValue), reason=tail-metadata")
            return
        }

        if !isPriming, isSeek(from: activeStart, to: requestedRange.start) {
            cancelPrefetch(except: [])
            chunks.removeAll()
            cachedBytes = 0
            prefetchTargetEnd = -1
            nextPrefetchStart = nil
            DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_CANCEL] id=\(id), reason=seek, start=\(requestedRange.start)")
        }
        if !isPriming {
            activeStart = requestedRange.start
        }
        store(chunk, prefetch: false)
        if isPriming {
            DiagnosticLog.write("[REMOTE_STREAM_PRIME_STORE] id=\(id), range=\(chunk.range.headerValue), bytes=\(chunk.data.count)")
        } else if isInitialHeaderProbe(chunk, requestedRange: requestedRange) {
            DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_CANCEL] id=\(id), range=\(requestedRange.headerValue), reason=initial-probe")
        } else {
            schedulePrefetch(after: chunk, stream: stream, fetch: fetch)
        }
    }

    private func advancePlaybackStart(to start: Int64) {
        if start > activeStart {
            activeStart = start
            dropChunksBeforeActiveStart()
        }
    }

    private func cachedChunk(containing range: RemoteStreamRange) -> RemoteStreamChunk? {
        chunks.first { $0.range.contains(range) }
    }

    private func assembledCachedChunk(containing range: RemoteStreamRange) -> RemoteStreamChunk? {
        guard range.count > 0 else { return nil }

        var cursor = range.start
        var data = Data()
        var headers: [String: String]?
        var contentType: String?
        var totalLength: Int64?

        func assembledChunk(through end: Int64) -> RemoteStreamChunk? {
            guard !data.isEmpty else { return nil }
            return RemoteStreamChunk(
                range: RemoteStreamRange(start: range.start, end: end),
                data: data,
                headers: headers ?? [:],
                contentType: contentType ?? "application/octet-stream",
                totalLength: totalLength
            )
        }

        for chunk in chunks.sorted(by: { $0.range.start < $1.range.start }) {
            guard !chunk.data.isEmpty else { continue }
            let availableEnd = min(chunk.range.end, chunk.range.start + Int64(chunk.data.count) - 1)
            guard availableEnd >= cursor else { continue }
            guard chunk.range.start <= cursor else {
                return assembledChunk(through: cursor - 1)
            }

            let segmentEnd = min(availableEnd, range.end)
            let lowerOffset = cursor - chunk.range.start
            let upperOffset = segmentEnd - chunk.range.start + 1
            guard lowerOffset >= 0,
                  upperOffset <= Int64(chunk.data.count),
                  upperOffset > lowerOffset else {
                return nil
            }

            if headers == nil {
                headers = chunk.headers
                contentType = chunk.contentType
                totalLength = chunk.totalLength
            }

            data.append(chunk.data.subdata(in: Int(lowerOffset)..<Int(upperOffset)))
            cursor = segmentEnd + 1
            if cursor > range.end {
                return assembledChunk(through: range.end)
            }
        }

        return assembledChunk(through: cursor - 1)
    }

    private func inFlightMarker(containing range: RemoteStreamRange) -> RemoteStreamInFlight? {
        inFlight.first { item in item.key.contains(range) && !item.value.read.isCancelled }?.value
    }

    private func removeCompletedMarker(_ marker: RemoteStreamInFlight) {
        inFlight = inFlight.filter { $0.value.id != marker.id }
    }

    private func loadDemand(
        range: RemoteStreamRange,
        kind: RemoteStreamLoadKind = .demand,
        fetch: @escaping @Sendable (RemoteStreamRange, RemoteStreamLoadKind) async throws -> RemoteStreamChunk
    ) async throws -> (RemoteStreamChunk, Int) {
        if let existing = inFlight[range], !existing.read.isCancelled {
            return (try await existing.read.value(phase: kind == .prime ? .preload : .playback), existing.generation)
        }

        let task = Task<RemoteStreamChunk, Error> {
            try await fetch(range, kind)
        }
        let marker = RemoteStreamInFlight(id: UUID(), generation: generation, kind: kind, task: task)
        inFlight[range] = marker
        do {
            let chunk = try await marker.read.value(phase: kind == .prime ? .preload : .playback)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if inFlight[range]?.id == marker.id {
                inFlight.removeValue(forKey: range)
            }
            return (chunk, marker.generation)
        } catch {
            if inFlight[range]?.id == marker.id, !marker.read.hasForegroundReaders {
                inFlight.removeValue(forKey: range)
            }
            throw error
        }
    }

    private func store(_ chunk: RemoteStreamChunk, prefetch: Bool) {
        guard !closed, chunk.range.count > 0, !chunk.data.isEmpty else { return }
        let actualCount = min(chunk.range.count, Int64(chunk.data.count))
        let chunk = RemoteStreamChunk(range: .init(start: chunk.range.start, end: chunk.range.start + actualCount - 1),
            data: Data(chunk.data.prefix(Int(actualCount))), headers: chunk.headers, contentType: chunk.contentType, totalLength: chunk.totalLength)
        let replaced = chunks.filter { chunk.range.contains($0.range) }
        cachedBytes -= replaced.reduce(Int64(0)) { $0 + Int64($1.data.count) }
        chunks.removeAll { chunk.range.contains($0.range) }
        chunks.append(chunk)
        chunks.sort { $0.range.start < $1.range.start }
        cachedBytes += Int64(chunk.data.count)
        if prefetch {
            DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_STORE] id=\(id), range=\(chunk.range.headerValue), bytes=\(chunk.data.count)")
        }
        dropChunksBeforeActiveStart()
        evictIfNeeded()
    }

    private func dropChunksBeforeActiveStart() {
        guard activeStart > 0 else { return }
        var removedBytes: Int64 = 0
        let removed = chunks.filter { $0.range.end < activeStart }
        guard !removed.isEmpty else { return }
        chunks.removeAll { chunk in
            if chunk.range.end < activeStart {
                removedBytes += Int64(chunk.data.count)
                return true
            }
            return false
        }
        cachedBytes -= removedBytes
        recordEviction(chunkCount: removed.count, byteCount: removedBytes, reason: "before-active")
    }

    private func schedulePrefetch(
        after chunk: RemoteStreamChunk,
        stream: RemoteStream,
        fetch: @escaping @Sendable (RemoteStreamRange, RemoteStreamLoadKind) async throws -> RemoteStreamChunk
    ) {
        guard shouldPrefetch(after: chunk) else { return }
        let chunkRange = chunk.range
        let targetEnd = chunkRange.end + configuration.prefetchWindowSize
        let cappedTargetEnd = min(targetEnd, chunk.totalLength.map { max(chunkRange.end, $0 - 1) } ?? targetEnd)
        prefetchTargetEnd = max(prefetchTargetEnd, cappedTargetEnd)
        let proposedNextStart = chunkRange.end + 1
        if nextPrefetchStart == nil || (nextPrefetchStart ?? 0) < proposedNextStart {
            nextPrefetchStart = proposedNextStart
        }
        fillPrefetchQueue(stream: stream, fetch: fetch)
    }

    private func fillPrefetchQueue(
        stream: RemoteStream,
        fetch: @escaping @Sendable (RemoteStreamRange, RemoteStreamLoadKind) async throws -> RemoteStreamChunk
    ) {
        guard var nextStart = nextPrefetchStart else { return }

        while nextStart <= prefetchTargetEnd && prefetchInFlightCount < configuration.maxConcurrentPrefetches {
            let nextEnd = min(nextStart + configuration.chunkSize - 1, prefetchTargetEnd)
            let nextRange = RemoteStreamRange(start: nextStart, end: nextEnd)
            nextPrefetchStart = nextEnd + 1
            nextStart = nextEnd + 1
            let isFullyCached = assembledCachedChunk(containing: nextRange)?.range.contains(nextRange) == true
            if !isFullyCached, inFlightMarker(containing: nextRange) == nil {
                let task = Task<RemoteStreamChunk, Error> {
                    try await fetch(nextRange, .prefetch)
                }
                let marker = RemoteStreamInFlight(id: UUID(), generation: generation, kind: .prefetch, task: task)
                inFlight[nextRange] = marker
                DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_START] id=\(id), range=\(nextRange.headerValue)")
                Task {
                    await self.completePrefetch(range: nextRange, marker: marker, stream: stream, fetch: fetch)
                }
            }
        }
    }

    private func completePrefetch(
        range: RemoteStreamRange,
        marker: RemoteStreamInFlight,
        stream: RemoteStream,
        fetch: @escaping @Sendable (RemoteStreamRange, RemoteStreamLoadKind) async throws -> RemoteStreamChunk
    ) async {
        do {
            let chunk = try await marker.read.value(phase: .preload)
            if inFlight[range]?.id == marker.id {
                inFlight.removeValue(forKey: range)
            }
            guard !closed, marker.generation == generation else {
                DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_CANCEL] id=\(id), range=\(range.headerValue), reason=stale")
                return
            }
            store(chunk, prefetch: true)
            fillPrefetchQueue(stream: stream, fetch: fetch)
        } catch {
            if inFlight[range]?.id == marker.id, !marker.read.hasForegroundReaders {
                inFlight.removeValue(forKey: range)
            }
            DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_ERROR] id=\(id), range=\(range.headerValue), error=\(error.localizedDescription)")
        }
    }

    private func shouldPrefetch(after chunk: RemoteStreamChunk) -> Bool {
        guard configuration.maxConcurrentPrefetches > 0,
              configuration.chunkSize > 0,
              configuration.prefetchWindowSize > 0,
              chunk.range.start < configuration.prefetchableStartLimit else {
            return false
        }
        guard let totalLength = chunk.totalLength else { return true }
        return chunk.range.end + 1 < totalLength
            && totalLength - (chunk.range.end + 1) > configuration.chunkSize
    }

    private var prefetchInFlightCount: Int {
        inFlight.values.filter { $0.kind == .prefetch }.count
    }

    private func isTailMetadataProbe(_ chunk: RemoteStreamChunk) -> Bool {
        guard let totalLength = chunk.totalLength,
              chunk.range.start > configuration.prefetchWindowSize else {
            return false
        }
        return chunk.range.end + 1 >= totalLength
            || totalLength - (chunk.range.end + 1) <= configuration.chunkSize
    }

    private func isInitialHeaderProbe(_ chunk: RemoteStreamChunk, requestedRange: RemoteStreamRange) -> Bool {
        requestedRange.start == 0
            && chunk.range.start == 0
            && chunk.range.end + 1 <= ProxyServer.defaultStreamChunkSize
            && Int64(chunk.data.count) >= chunk.range.count
    }

    private func cancelPrefetch(except keep: Set<RemoteStreamRange>) {
        generation += 1
        prefetchTargetEnd = -1
        nextPrefetchStart = nil
        for (range, marker) in inFlight where marker.kind == .prefetch && !keep.contains(range) {
            marker.read.cancelBackgroundReaders()
            DiagnosticLog.write("[REMOTE_STREAM_PREFETCH_CANCEL] id=\(id), range=\(range.headerValue)")
        }
        inFlight = inFlight.filter { range, marker in
            marker.kind == .demand || marker.read.hasForegroundReaders || keep.contains(range)
        }
    }

    private func evictIfNeeded() {
        var removedChunks = 0
        var removedBytes: Int64 = 0
        while cachedBytes > configuration.maxBytes, let first = chunks.first {
            chunks.removeFirst()
            let byteCount = Int64(first.data.count)
            cachedBytes -= byteCount
            removedChunks += 1
            removedBytes += byteCount
        }
        recordEviction(chunkCount: removedChunks, byteCount: removedBytes, reason: "over-budget")
    }

    private func recordEviction(chunkCount: Int, byteCount: Int64, reason: String) {
        guard chunkCount > 0, byteCount > 0 else { return }
        pendingEvictionChunks += chunkCount
        pendingEvictionBytes += byteCount
        let now = Date()
        guard pendingEvictionChunks >= 100
                || now.timeIntervalSince(lastEvictionLogAt) >= 5 else {
            return
        }
        DiagnosticLog.write(
            "[REMOTE_STREAM_PREFETCH_EVICT] id=\(id), chunks=\(pendingEvictionChunks), bytes=\(pendingEvictionBytes), cachedBytes=\(cachedBytes), reason=\(reason)"
        )
        pendingEvictionChunks = 0
        pendingEvictionBytes = 0
        lastEvictionLogAt = now
    }

    private func isSeek(from currentStart: Int64, to nextStart: Int64) -> Bool {
        abs(nextStart - currentStart) > configuration.prefetchWindowSize
    }

    private func proxyResponse(from chunk: RemoteStreamChunk, requestedRange: RemoteStreamRange, method: NIOHTTP1.HTTPMethod) -> ProxyResponse {
        let offset = max(0, requestedRange.start - chunk.range.start)
        let available = max(0, Int64(chunk.data.count) - offset)
        let requestedCount = min(requestedRange.count, available)
        let lower = Int(offset)
        let upper = Int(offset + requestedCount)
        let data = requestedCount > 0 ? chunk.data.subdata(in: lower..<upper) : Data()
        var headers = withoutHeaders(
            chunk.headers,
            names: ["accept-ranges", "content-length", "content-range"]
        )
        let responseEnd = requestedRange.start + requestedCount - 1
        let total = chunk.totalLength.map(String.init) ?? "*"
        headers["Accept-Ranges"] = "bytes"
        headers["Content-Length"] = "\(data.count)"
        headers["Content-Range"] = requestedCount > 0
            ? "bytes \(requestedRange.start)-\(responseEnd)/\(total)"
            : "bytes \(requestedRange.start)-\(requestedRange.start)/\(total)"
        return ProxyResponse(
            statusCode: 206,
            contentType: chunk.contentType,
            data: method == .HEAD ? Data() : data,
            headers: headers,
            closeConnection: true
        )
    }

    private func withoutHeaders(_ headers: [String: String], names: Set<String>) -> [String: String] {
        headers.filter { key, _ in
            !names.contains(key.lowercased())
        }
    }
}

private actor ContinuousRemoteStreamResponseState {
    private let requestedStart: Int64
    private var totalLength: Int64
    private var headSent = false

    init(requestedStart: Int64, registeredContentLength: Int64) {
        self.requestedStart = requestedStart
        self.totalLength = registeredContentLength
    }

    func prepareHead(responseTotalLength: Int64?) -> (shouldSend: Bool, totalLength: Int64) {
        if !headSent, let responseTotalLength, responseTotalLength > requestedStart {
            totalLength = responseTotalLength
        }
        let shouldSend = !headSent
        headSent = true
        return (shouldSend, totalLength)
    }

    func currentTotalLength() -> Int64 {
        totalLength
    }
}

private actor StreamingRemoteStreamChunkAccumulator {
    private let requestedRange: RemoteStreamRange
    private var data: Data
    private var headers: [String: String] = [:]
    private var contentType: String
    private var totalLength: Int64?

    init(requestedRange: RemoteStreamRange, fallbackContentType: String) {
        self.requestedRange = requestedRange
        self.contentType = fallbackContentType
        var data = Data()
        data.reserveCapacity(Int(min(requestedRange.count, Int64(Int.max))))
        self.data = data
    }

    func updateMetadata(headers: [String: String], contentType: String, totalLength: Int64?) {
        if self.headers.isEmpty {
            self.headers = headers
        }
        self.contentType = contentType
        if let totalLength {
            self.totalLength = totalLength
        }
    }

    func append(_ incoming: Data) -> Data {
        let remaining = max(0, requestedRange.count - Int64(data.count))
        guard remaining > 0, !incoming.isEmpty else { return Data() }
        let acceptedCount = min(incoming.count, Int(remaining))
        let accepted = acceptedCount == incoming.count
            ? incoming
            : Data(incoming.prefix(acceptedCount))
        data.append(accepted)
        return accepted
    }

    func nextStart() -> Int64 {
        requestedRange.start + Int64(data.count)
    }

    func makeChunk() -> RemoteStreamChunk? {
        guard !data.isEmpty else { return nil }
        let actualRange = RemoteStreamRange(
            start: requestedRange.start,
            end: requestedRange.start + Int64(data.count) - 1
        )
        var responseHeaders = headers
        responseHeaders["Accept-Ranges"] = headerValue(headers, "Accept-Ranges") ?? "bytes"
        responseHeaders["Content-Length"] = String(data.count)
        let total = totalLength.map(String.init) ?? "*"
        responseHeaders["Content-Range"] = "bytes \(actualRange.start)-\(actualRange.end)/\(total)"
        return RemoteStreamChunk(
            range: actualRange,
            data: data,
            headers: responseHeaders,
            contentType: contentType,
            totalLength: totalLength
        )
    }

    private func headerValue(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// 代理服务器错误
public enum ProxyServerError: Error, Sendable {
    case noAvailablePort
    case serverNotRunning
    case upstreamRangeMismatch(expected: String, actual: String?)
    case upstreamHTTPStatus(Int)
    case emptyUpstreamResponse(String)
}

extension ProxyServerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noAvailablePort:
            return "没有可用端口"
        case .serverNotRunning:
            return "本地代理未运行"
        case let .upstreamRangeMismatch(expected, actual):
            return "远端 Range 不匹配，期望 \(expected)，实际 \(actual ?? "-")"
        case .upstreamHTTPStatus(let statusCode):
            return "远端 HTTP \(statusCode)"
        case .emptyUpstreamResponse(let range):
            return "远端 Range \(range) 返回空数据"
        }
    }
}

// MARK: - NIO HTTP Handler

final class ProxyHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct SendableChannel: @unchecked Sendable {
        let channel: NIOCore.Channel
    }

    private final class ProxyStreamState: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var closeConnection = false

        func markStarted(closeConnection: Bool) {
            lock.lock()
            started = true
            self.closeConnection = closeConnection
            lock.unlock()
        }

        func snapshot() -> (started: Bool, closeConnection: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (started, closeConnection)
        }
    }

    private let server: ProxyServer
    private var requestHead: HTTPRequestHead?
    private var body = Data()
    private var bodyTooLarge = false
    private var remoteStreamTask: Task<Void, Never>?

    init(server: ProxyServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            body = Data()
            bodyTooLarge = false
        case .body(var buffer):
            let readableBytes = buffer.readableBytes
            guard !bodyTooLarge else { return }
            if body.count + readableBytes > ProxyServer.maxRequestBodyBytes {
                bodyTooLarge = true
                body.removeAll(keepingCapacity: false)
                return
            }
            if let bytes = buffer.readBytes(length: readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            handleRequest(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        remoteStreamTask?.cancel()
        remoteStreamTask = nil
        context.fireChannelInactive()
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let head = requestHead else { return }
        let path = head.uri.components(separatedBy: "?").first ?? head.uri
        var params = queryParams(from: head.uri)
        params.removeValue(forKey: "__downstream_range")
        for header in head.headers {
            params[header.name.lowercased()] = header.value
        }
        if let range = head.headers.first(name: "Range"), !range.isEmpty {
            params["__downstream_range"] = range
        }
        guard !bodyTooLarge, body.count <= ProxyServer.maxRequestBodyBytes else {
            sendErrorResponse(context: context, version: head.version, status: HTTPResponseStatus(statusCode: 413), message: "请求 body 过大")
            return
        }

        if path.hasPrefix("/proxy") {
            struct SendableContext: @unchecked Sendable {
                let context: ChannelHandlerContext
            }
            let safeContext = SendableContext(context: context)
            let version = head.version
            let method = head.method
            let body = self.body
            let channel = SendableChannel(channel: context.channel)
            let streamState = ProxyStreamState()

            remoteStreamTask?.cancel()
            remoteStreamTask = Task {
                do {
                    if method == .GET,
                       let prefetchedHandler = self.server.prefetchedProxyHandler,
                       let response = try await prefetchedHandler(params) {
                        safeContext.context.eventLoop.execute {
                            self.sendResponse(context: safeContext.context, version: version, response: response)
                        }
                        return
                    }
                    if method == .GET,
                       params["preload"] != "1",
                       let streamingHandler = self.server.streamingProxyHandler {
                        let didStream = try await streamingHandler(
                            params,
                            { responseHead in
                                try await self.sendProxyStreamHead(
                                    channel: channel,
                                    version: version,
                                    response: responseHead,
                                    state: streamState
                                )
                            },
                            { data in
                                try await self.writeOpenEndedRemoteStreamBody(
                                    channel: channel,
                                    data: data
                                )
                            }
                        )
                        if didStream {
                            try await self.finishProxyStream(channel: channel, state: streamState)
                            return
                        }
                    }

                    if let handler = self.server.proxyHandler,
                       let response = try await handler(params) {
                        safeContext.context.eventLoop.execute {
                            self.sendResponse(context: safeContext.context, version: version, response: response)
                        }
                    } else if let rawHandler = self.server.rawProxyHandler,
                              let raw = try await rawHandler(params),
                              let response = ProxyResponse.fromSpiderValue(raw) {
                        safeContext.context.eventLoop.execute {
                            self.sendResponse(context: safeContext.context, version: version, response: response)
                        }
                    } else if let targetURL = self.targetURL(from: params), !targetURL.isEmpty {
                        let response = try await self.forwardProxyRequest(url: targetURL, params: params, method: method, body: body)
                        safeContext.context.eventLoop.execute {
                            self.sendResponse(context: safeContext.context, version: version, response: response)
                        }
                    } else {
                        safeContext.context.eventLoop.execute {
                            self.sendErrorResponse(context: safeContext.context, version: version, status: .badRequest, message: "缺少代理目标 url")
                        }
                    }
                } catch {
                    guard let measurements = Self.requestFailureDiagnosticMeasurements(
                        for: error,
                        taskIsCancelled: Task.isCancelled,
                        channelIsActive: channel.channel.isActive
                    ) else { return }
                    let targetURL = self.targetURL(from: params) ?? ""
                    let errorValue = error as NSError
                    let fields = measurements.keys.sorted().map {
                        "\($0)=\(measurements[$0]!)"
                    }.joined(separator: " ")
                    let message = "[PROXY_SERVER_ERROR] \(fields) 代理转发发生异常 url=\(ProxyServer.redactedURL(targetURL)) error=\(errorValue.localizedDescription) [\(errorValue.domain):\(errorValue.code)]"
                    print(message)
                    DiagnosticLog.write(message)
                    fflush(stdout)
                    if streamState.snapshot().started {
                        try? await self.finishProxyStream(channel: channel, state: streamState, forceClose: true)
                        return
                    }
                    safeContext.context.eventLoop.execute {
                        let status: HTTPResponseStatus = error is ProxyAccessError ? .badRequest : .internalServerError
                        self.sendErrorResponse(context: safeContext.context, version: version, status: status, message: "本地代理处理发生异常: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        switch true {
        case path == "/resource":
            handleSeekableResource(context: context, head: head, params: params)
        case path.hasPrefix("/parse"):
            sendTextResponse(
                context: context,
                version: head.version,
                status: .ok,
                contentType: "text/html; charset=utf-8",
                text: parseHTML(params: params)
            )
        case path.hasPrefix("/cache"):
            handleCache(context: context, version: head.version, method: head.method, params: params, body: body)
        case path.hasPrefix("/file"):
            handleFile(context: context, version: head.version, head: head, params: params)
        case path.hasPrefix("/stream"):
            handleRemoteStream(context: context, version: head.version, head: head, params: params)
        case path.hasPrefix("/health"):
            handleHealth(context: context, version: head.version)
        case path.hasPrefix("/webResource"):
            handleWebResource(context: context, version: head.version, head: head, params: params)
        default:
            sendErrorResponse(context: context, version: head.version, status: .notFound, message: "路由不存在")
        }
    }

    private func handleSeekableResource(context: ChannelHandlerContext, head: HTTPRequestHead, params: [String: String]) {
        guard head.method == .GET || head.method == .HEAD else {
            sendErrorResponse(context: context, version: head.version, status: .methodNotAllowed, message: "只支持读取")
            return
        }
        guard let id = params["id"], let resource = server.seekableResource(id: id) else {
            sendErrorResponse(context: context, version: head.version, status: .notFound, message: "资源已释放")
            return
        }
        let header = head.headers.first(name: "Range")
        guard let range = SeekableRange.parse(header, size: resource.size) else {
            sendResponse(context: context, version: head.version, response: ProxyResponse(statusCode: 416,
                contentType: resource.contentType, data: Data(), headers: ["Content-Range": "bytes */\(resource.size)"]))
            return
        }
        let channel = SendableChannel(channel: context.channel)
        let state = ProxyStreamState()
        remoteStreamTask?.cancel()
        remoteStreamTask = Task {
            do {
                var headers = ["Accept-Ranges": "bytes"]
                if header != nil { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(resource.size)" }
                try await self.sendProxyStreamHead(channel: channel, version: head.version,
                    response: ProxyStreamingResponseHead(statusCode: header == nil ? 200 : 206,
                        contentType: resource.contentType, contentLength: range.count, headers: headers, closeConnection: true), state: state)
                if head.method == .GET {
                    var offset = range.lowerBound
                    var prefetched: Task<Data, Error>?
                    defer { prefetched?.cancel() }
                    while offset < range.upperBound {
                        try Task.checkCancellation()
                        guard self.server.seekableResource(id: id) != nil else { throw CancellationError() }
                        let chunkSize = offset == range.lowerBound ? min(resource.readChunkSize, 512 * 1024) : resource.readChunkSize
                        let end = min(range.upperBound, offset + chunkSize)
                        let data: Data
                        if let pending = prefetched { data = try await pending.value; prefetched = nil }
                        else { data = try await self.server.readSeekableResource(id: id, range: offset..<end) }
                        guard data.count == Int(end - offset) else { throw ProxyServerError.emptyUpstreamResponse("bytes=\(offset)-\(end - 1)") }
                        try Task.checkCancellation()
                        if end < range.upperBound {
                            let nextRange = end..<min(range.upperBound, end + resource.readChunkSize)
                            // One bounded read overlaps the local socket write, never the whole file.
                            prefetched = Task {
                                try Task.checkCancellation()
                                return try await self.server.readSeekableResource(id: id, range: nextRange)
                            }
                        }
                        try await self.writeOpenEndedRemoteStreamBody(channel: channel, data: data)
                        offset = end
                    }
                }
                try await self.finishProxyStream(channel: channel, state: state)
            } catch { channel.channel.eventLoop.execute { channel.channel.close(promise: nil) } }
        }
    }

    private func forwardProxyRequest(url: String, params: [String: String], method: NIOHTTP1.HTTPMethod, body: Data) async throws -> ProxyResponse {
        _ = try ProxyAccessPolicy.validateTargetURL(url)
        let headers = decodeHeaderParams(params).merging(extractHeaderParams(params)) { _, new in new }
        let outboundMethod: Networking.HTTPMethod
        switch method {
        case .POST:
            outboundMethod = .post
        case .PUT:
            outboundMethod = .put
        case .DELETE:
            outboundMethod = .delete
        default:
            outboundMethod = .get
        }
        let response = try await HTTPClient.shared.request(
            url: url,
            method: outboundMethod,
            headers: headers,
            body: body.isEmpty ? nil : body
        )
        try ProxyAccessPolicy.validateFinalURL(response.finalURL)
        return ProxyResponse(
            statusCode: response.statusCode,
            contentType: response.headers["Content-Type"] ?? response.headers["content-type"] ?? "application/octet-stream",
            data: response.data,
            headers: response.headers
        )
    }

    private func handleCache(context: ChannelHandlerContext, version: HTTPVersion, method: NIOHTTP1.HTTPMethod, params: [String: String], body: Data) {
        guard let key = params["key"], !key.isEmpty else {
            sendErrorResponse(context: context, version: version, status: .badRequest, message: "缺少 cache key")
            return
        }

        switch method {
        case .GET:
            guard let value = server.cacheValue(for: key) else {
                sendErrorResponse(context: context, version: version, status: .notFound, message: "缓存不存在")
                return
            }
            sendResponse(context: context, version: version, response: ProxyResponse(contentType: "application/octet-stream", data: value))
        case .POST, .PUT:
            let value = body.isEmpty ? Data((params["value"] ?? "").utf8) : body
            guard value.count <= ProxyServer.maxCacheEntryBytes else {
                sendErrorResponse(context: context, version: version, status: HTTPResponseStatus(statusCode: 413), message: "缓存内容过大")
                return
            }
            server.setCacheValue(value, for: key)
            sendTextResponse(context: context, version: version, status: .ok, contentType: "application/json", text: "{\"status\":\"ok\"}")
        case .DELETE:
            server.removeCacheValue(for: key)
            sendTextResponse(context: context, version: version, status: .ok, contentType: "application/json", text: "{\"status\":\"deleted\"}")
        default:
            sendErrorResponse(context: context, version: version, status: .methodNotAllowed, message: "不支持的 cache 方法")
        }
    }

    private func handleFile(context: ChannelHandlerContext, version: HTTPVersion, head: HTTPRequestHead, params: [String: String]) {
        if params["path"] != nil || params["url"] != nil {
            sendErrorResponse(context: context, version: version, status: .badRequest, message: "不再支持任意 file path，请使用注册文件 id")
            return
        }

        guard let id = params["id"], let file = server.localFile(for: id) else {
            sendErrorResponse(context: context, version: version, status: .notFound, message: "文件不存在")
            return
        }

        let filePath = file.url.path
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            sendErrorResponse(context: context, version: version, status: .notFound, message: "文件不存在")
            return
        }

        let contentType = contentTypeForPath(filePath)
        let etag = weakETag(for: data)
        if let ifNoneMatch = head.headers.first(name: "If-None-Match"), ifNoneMatch == etag {
            sendResponse(context: context, version: version, response: ProxyResponse(statusCode: 304, contentType: contentType, data: Data(), headers: ["ETag": etag, "Accept-Ranges": "bytes"]))
            return
        }

        if let rangeHeader = head.headers.first(name: "Range"),
           shouldServeRange(ifRange: head.headers.first(name: "If-Range"), etag: etag),
           let range = byteRange(from: rangeHeader, dataCount: data.count) {
            let part = data.subdata(in: range)
            let headers = [
                "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)",
                "Accept-Ranges": "bytes",
                "ETag": etag
            ]
            sendResponse(context: context, version: version, response: ProxyResponse(statusCode: 206, contentType: contentType, data: part, headers: headers))
        } else {
            sendResponse(context: context, version: version, response: ProxyResponse(contentType: contentType, data: data, headers: ["Accept-Ranges": "bytes", "ETag": etag]))
        }
    }

    private func handleRemoteStream(context: ChannelHandlerContext, version: HTTPVersion, head: HTTPRequestHead, params: [String: String]) {
        guard let id = params["id"], let stream = server.stream(for: id) else {
            sendErrorResponse(context: context, version: version, status: .notFound, message: "流不存在")
            return
        }

        struct SendableContext: @unchecked Sendable {
            let context: ChannelHandlerContext
        }
        let safeContext = SendableContext(context: context)
        let safeChannel = SendableChannel(channel: context.channel)
        let range = head.headers.first(name: "Range")
        let ifRange = head.headers.first(name: "If-Range")
        let method = head.method
        DiagnosticLog.write("[REMOTE_STREAM_REQUEST] id=\(id), method=\(method.rawValue), range=\(range ?? "-"), ifRange=\(ifRange ?? "-")")

        remoteStreamTask?.cancel()
        let isPriming = params["preload"] == "1"
        let usesContinuousResponse = !isPriming && shouldStreamOpenEndedRemoteStream(
            stream: stream,
            range: range,
            method: method
        )
        remoteStreamTask = Task {
            do {
                if usesContinuousResponse {
                    try await self.streamOpenEndedRemoteStream(
                        channel: safeChannel,
                        version: version,
                        stream: stream,
                        range: range
                    )
                } else {
                    let response = try await self.forwardRemoteStream(
                        stream: stream,
                        range: range,
                        ifRange: ifRange,
                        method: method,
                        isPriming: isPriming
                    )
                    safeContext.context.eventLoop.execute {
                        self.sendResponse(context: safeContext.context, version: version, response: response)
                    }
                }
            } catch {
                guard let measurements = Self.requestFailureDiagnosticMeasurements(
                    for: error,
                    taskIsCancelled: Task.isCancelled,
                    channelIsActive: safeChannel.channel.isActive
                ) else {
                    DiagnosticLog.write("[REMOTE_STREAM_CONTINUOUS_CANCEL] id=\(id), range=\(range ?? "-")")
                    return
                }
                let fields = measurements.keys.sorted().map {
                    "\($0)=\(measurements[$0]!)"
                }.joined(separator: " ")
                let message = "[REMOTE_STREAM_ERROR] \(fields) id=\(id), range=\(range ?? "-"), error=\(error.localizedDescription)"
                DiagnosticLog.write(message)
                self.server.setRemoteStreamError(id: id, message: message)
                if usesContinuousResponse {
                    safeChannel.channel.eventLoop.execute {
                        safeChannel.channel.close(promise: nil)
                    }
                    return
                }
                safeContext.context.eventLoop.execute {
                    guard safeContext.context.channel.isActive else { return }
                    self.sendErrorResponse(context: safeContext.context, version: version, status: .badGateway, message: "远端流转发失败: \(error.localizedDescription)")
                }
            }
        }
    }

    static func requestFailureDiagnosticMeasurements(
        for error: Error,
        taskIsCancelled: Bool,
        channelIsActive: Bool
    ) -> [String: Int]? {
        // Exiting playback cancels the upstream task and closes its downstream channel.
        guard !taskIsCancelled, channelIsActive else { return nil }
        return remoteDiagnosticMeasurements(for: error)
    }

    static func remoteDiagnosticMeasurements(for error: Error) -> [String: Int] {
        switch error {
        case ProxyServerError.upstreamHTTPStatus(let statusCode):
            return ["errorKind": 1, "status": statusCode]
        case ProxyServerError.upstreamRangeMismatch:
            return ["errorKind": 2]
        case ProxyServerError.emptyUpstreamResponse:
            return ["errorKind": 3]
        case ProxyServerError.noAvailablePort, ProxyServerError.serverNotRunning:
            return ["errorKind": 6]
        case let curlError as CurlRangeTransportError:
            return ["code": Int(curlError.code), "errorKind": 5]
        case let httpError as HTTPError:
            if case .httpError(let statusCode, _) = httpError {
                return ["errorKind": 1, "status": statusCode]
            }
            return ["errorKind": 6]
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return ["code": nsError.code, "errorKind": 4]
            }
            return ["errorKind": 0, "errorCode": nsError.code]
        }
    }

    private func handleHealth(context: ChannelHandlerContext, version: HTTPVersion) {
        struct SendableContext: @unchecked Sendable {
            let context: ChannelHandlerContext
        }
        let safeContext = SendableContext(context: context)
        Task {
            let snapshot = await self.server.healthSnapshot()
            safeContext.context.eventLoop.execute {
                self.sendJSONResponse(context: safeContext.context, version: version, statusCode: 200, value: snapshot)
            }
        }
    }

    private func handleWebResource(context: ChannelHandlerContext, version: HTTPVersion, head: HTTPRequestHead, params: [String: String]) {
        if head.method == .OPTIONS {
            sendResponse(
                context: context,
                version: version,
                response: ProxyResponse(
                    statusCode: 204,
                    contentType: "application/json",
                    data: Data(),
                    headers: corsHeaders()
                )
            )
            return
        }
        guard head.method == .GET || head.method == .HEAD else {
            sendErrorResponse(context: context, version: version, status: .methodNotAllowed, message: "不支持的 webResource 方法")
            return
        }
        guard let targetURL = targetURL(from: params), !targetURL.isEmpty else {
            sendErrorResponse(context: context, version: version, status: .badRequest, message: "缺少 webResource 目标 url")
            return
        }

        struct SendableContext: @unchecked Sendable {
            let context: ChannelHandlerContext
        }
        let safeContext = SendableContext(context: context)
        let headers = webResourceHeaders(from: params, requestHeaders: head.headers)
        let method = head.method
        Task {
            do {
                _ = try ProxyAccessPolicy.validateTargetURL(targetURL)
                let upstreamMethod: Networking.HTTPMethod = method == .HEAD ? .head : .get
                let upstream = try await self.server.webResourceHTTPClient.request(
                    url: targetURL,
                    method: upstreamMethod,
                    headers: headers,
                    timeout: 15,
                    allowsProxyFallback: false
                )
                try ProxyAccessPolicy.validateFinalURL(upstream.finalURL)
                var responseHeaders = upstream.headers
                responseHeaders.merge(self.corsHeaders()) { _, new in new }
                let response = ProxyResponse(
                    statusCode: upstream.statusCode,
                    contentType: self.headerValue(upstream.headers, "Content-Type") ?? "application/octet-stream",
                    data: method == .HEAD ? Data() : upstream.data,
                    headers: responseHeaders
                )
                safeContext.context.eventLoop.execute {
                    self.sendResponse(context: safeContext.context, version: version, response: response)
                }
            } catch {
                let message = "[WEB_RESOURCE_ERROR] url=\(targetURL) error=\(error.localizedDescription)"
                DiagnosticLog.write(message)
                self.server.recordRecentError(message)
                safeContext.context.eventLoop.execute {
                    let status: HTTPResponseStatus = error is ProxyAccessError ? .badRequest : .badGateway
                    self.sendErrorResponse(context: safeContext.context, version: version, status: status, message: "资源代理失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func shouldStreamOpenEndedRemoteStream(
        stream: RemoteStream,
        range: String?,
        method: NIOHTTP1.HTTPMethod
    ) -> Bool {
        guard (stream.relayMode == .buffered && stream.continuousOpenEndedResponses)
                || stream.parallelSegmentedOpenEndedUpstream,
              method == .GET,
              let contentLength = stream.contentLength,
              contentLength > 0,
              let range,
              !range.lowercased().hasPrefix("bytes=-"),
              let parsed = parseByteRange(range),
              parsed.end == nil,
              parsed.start < contentLength else {
            return false
        }
        return true
    }

    private func streamOpenEndedRemoteStream(
        channel: SendableChannel,
        version: HTTPVersion,
        stream: RemoteStream,
        range: String?
    ) async throws {
        guard let registeredContentLength = stream.contentLength,
              let parsed = parseByteRange(range),
              parsed.end == nil else {
            throw ProxyServerError.upstreamRangeMismatch(expected: range ?? "-", actual: nil)
        }

        let responseState = ContinuousRemoteStreamResponseState(
            requestedStart: parsed.start,
            registeredContentLength: registeredContentLength
        )

        if stream.parallelSegmentedOpenEndedUpstream {
            try await streamParallelSegmentedOpenEndedRemoteStream(
                channel: channel,
                version: version,
                stream: stream,
                requestedStart: parsed.start,
                registeredContentLength: registeredContentLength,
                responseState: responseState
            )
            return
        }

        var currentStart = parsed.start

        while currentStart < (await responseState.currentTotalLength()) {
            try Task.checkCancellation()
            let totalLength = await responseState.currentTotalLength()
            let requestedRange = continuousRemoteStreamRange(
                start: currentStart,
                totalLength: totalLength,
                stream: stream
            )

            if let cached = await stream.buffer.continuousResponse(for: requestedRange) {
                let responseTotal = parseContentRange(headerValue(cached.headers, "Content-Range"))?.total
                try await sendOpenEndedRemoteStreamHeadIfNeeded(
                    channel: channel,
                    version: version,
                    stream: stream,
                    response: cached,
                    requestedStart: parsed.start,
                    responseTotalLength: responseTotal,
                    responseState: responseState
                )
                guard !cached.data.isEmpty else {
                    throw ProxyServerError.emptyUpstreamResponse(requestedRange.headerValue)
                }
                try await writeOpenEndedRemoteStreamBody(channel: channel, data: cached.data, stream: stream)
                currentStart += Int64(cached.data.count)
                continue
            }

            let chunk = try await streamRemoteStreamChunk(
                channel: channel,
                version: version,
                stream: stream,
                range: requestedRange,
                requestedStart: parsed.start,
                responseState: responseState
            )
            await stream.buffer.storeContinuousChunk(chunk)
            currentStart = chunk.range.end + 1
        }

        try await finishOpenEndedRemoteStream(channel: channel)
        let totalLength = await responseState.currentTotalLength()
        DiagnosticLog.write("[REMOTE_STREAM_CONTINUOUS_END] id=\(stream.id), range=bytes=\(parsed.start)-\(totalLength - 1)")
    }

    private func streamParallelSegmentedOpenEndedRemoteStream(
        channel: SendableChannel,
        version: HTTPVersion,
        stream: RemoteStream,
        requestedStart: Int64,
        registeredContentLength: Int64,
        responseState: ContinuousRemoteStreamResponseState
    ) async throws {
        let segmentSize = stream.parallelUpstreamSegmentSize
        let startupSegmentSize = min(segmentSize, 64 * 1024)
        let startedAt = Date()
        var deliveredBytes: Int64 = 0
        var completedSegments = 0
        var nextWriteStart = requestedStart
        var nextScheduleStart = requestedStart
        var inFlight: [Int64: Task<RemoteStreamChunk, Error>] = [:]
        defer { for task in inFlight.values { task.cancel() } }

        func scheduleAvailableSegments(totalLength: Int64) {
            // Bound startup to the probe-sized head and its immediate successor.
            // Distant data can use the throughput window once the head is delivered.
            let limit = stream.parallelConcurrencyController.currentLimit
            let concurrency = completedSegments == 0 ? min(2, limit) : limit
            while inFlight.count < concurrency, nextScheduleStart < totalLength {
                let start = nextScheduleStart
                let scheduledSegmentSize = start == requestedStart ? startupSegmentSize : segmentSize
                let end = min(totalLength - 1, start + scheduledSegmentSize - 1)
                let range = RemoteStreamRange(start: start, end: end)
                inFlight[start] = Task {
                    try await stream.buffer.parallelContinuousChunk(for: range) { requestedRange in
                        try await self.fetchRemoteStreamChunkWithRetry(
                            stream: stream,
                            range: requestedRange,
                            ifRange: nil,
                            kind: .demand,
                            useCurl: stream.parallelUpstreamUsesCurl
                        )
                    }
                }
                nextScheduleStart = end + 1
            }
        }

        scheduleAvailableSegments(totalLength: registeredContentLength)
        while nextWriteStart < (await responseState.currentTotalLength()) {
            try Task.checkCancellation()
            guard let task = inFlight[nextWriteStart] else {
                throw ProxyServerError.emptyUpstreamResponse("bytes=\(nextWriteStart)-")
            }
            let chunk = try await task.value
            try Task.checkCancellation()
            inFlight.removeValue(forKey: nextWriteStart)
            guard !chunk.data.isEmpty else {
                throw ProxyServerError.emptyUpstreamResponse(chunk.range.headerValue)
            }

            let headResponse = ProxyResponse(
                statusCode: 206,
                contentType: chunk.contentType,
                data: Data(),
                headers: chunk.headers
            )
            try await sendOpenEndedRemoteStreamHeadIfNeeded(
                channel: channel,
                version: version,
                stream: stream,
                response: headResponse,
                requestedStart: requestedStart,
                responseTotalLength: chunk.totalLength,
                responseState: responseState
            )
            try await writeOpenEndedRemoteStreamBody(channel: channel, data: chunk.data, stream: stream)

            nextWriteStart += Int64(chunk.data.count)
            deliveredBytes += Int64(chunk.data.count)
            completedSegments += 1
            let totalLength = await responseState.currentTotalLength()
            scheduleAvailableSegments(totalLength: totalLength)

            let activeConcurrency = stream.parallelConcurrencyController.currentLimit
            if completedSegments.isMultiple(of: max(1, stream.parallelUpstreamConcurrency))
                || nextWriteStart >= totalLength {
                let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
                let throughput = Double(deliveredBytes) / elapsed / 1_048_576
                DiagnosticLog.write("[REMOTE_STREAM_THROUGHPUT] id=\(stream.id), deliveredBytes=\(deliveredBytes), segments=\(completedSegments), concurrency=\(activeConcurrency), segmentSize=\(segmentSize), MiBps=\(String(format: "%.2f", throughput))")
            }
        }

        try await finishOpenEndedRemoteStream(channel: channel)
        let totalLength = await responseState.currentTotalLength()
        DiagnosticLog.write("[REMOTE_STREAM_CONTINUOUS_END] id=\(stream.id), range=bytes=\(requestedStart)-\(totalLength - 1), upstreamMode=parallel-segmented")
    }

    private func streamRemoteStreamChunk(
        channel: SendableChannel,
        version: HTTPVersion,
        stream: RemoteStream,
        range: RemoteStreamRange,
        requestedStart: Int64,
        responseState: ContinuousRemoteStreamResponseState
    ) async throws -> RemoteStreamChunk {
        let accumulator = StreamingRemoteStreamChunkAccumulator(
            requestedRange: range,
            fallbackContentType: stream.contentType
        )
        var attempt = 0

        while await accumulator.nextStart() <= range.end {
            try Task.checkCancellation()
            let attemptStart = await accumulator.nextStart()
            let attemptRange = RemoteStreamRange(start: attemptStart, end: range.end)
            let upstreamRange = upstreamRangeHeader(for: attemptRange, stream: stream)
            var headers = stream.headers
            headers["Range"] = upstreamRange

            do {
                let response = try await stream.upstreamHTTPClient.stream(
                    url: stream.url,
                    headers: headers,
                    timeout: ProxyServer.continuousStreamTimeout,
                    redactsURLInLogs: true,
                    chunkSize: 64 * 1024,
                    shouldStream: { metadata in
                        try ProxyAccessPolicy.validateFinalURL(metadata.finalURL)
                        try self.validateUpstreamRange(
                            statusCode: metadata.statusCode,
                            headers: metadata.headers,
                            requestedRange: upstreamRange
                        )
                        guard metadata.statusCode < 400 else {
                            DiagnosticLog.write("[REMOTE_STREAM_UPSTREAM_ERROR] status=\(metadata.statusCode), range=\(upstreamRange), contentType=\(self.headerValue(metadata.headers, "Content-Type") ?? "")")
                            throw ProxyServerError.upstreamHTTPStatus(metadata.statusCode)
                        }

                        let upstreamContentRange = self.parseContentRange(
                            self.headerValue(metadata.headers, "Content-Range")
                        )
                        let downstreamTotalLength = upstreamContentRange?.total.map {
                            max(0, $0 - stream.sourceByteOffset)
                        }
                        let contentType = self.headerValue(metadata.headers, "Content-Type") ?? stream.contentType
                        await accumulator.updateMetadata(
                            headers: metadata.headers,
                            contentType: contentType,
                            totalLength: downstreamTotalLength
                        )
                        if let downstreamTotalLength {
                            self.server.updateRemoteStreamContentLength(
                                id: stream.id,
                                contentLength: downstreamTotalLength
                            )
                        }

                        let headResponse = ProxyResponse(
                            statusCode: metadata.statusCode,
                            contentType: contentType,
                            data: Data(),
                            headers: metadata.headers
                        )
                        try await self.sendOpenEndedRemoteStreamHeadIfNeeded(
                            channel: channel,
                            version: version,
                            stream: stream,
                            response: headResponse,
                            requestedStart: requestedStart,
                            responseTotalLength: downstreamTotalLength,
                            responseState: responseState
                        )
                        return true
                    },
                    receive: { data in
                        await stream.buffer.recordReceivedBytes(data.count)
                        let accepted = await accumulator.append(data)
                        if !accepted.isEmpty {
                            try await self.writeOpenEndedRemoteStreamBody(
                                channel: channel,
                                data: accepted,
                                stream: stream
                            )
                        }
                    }
                )

                let nextStart = await accumulator.nextStart()
                guard nextStart > attemptStart else {
                    throw ProxyServerError.emptyUpstreamResponse(attemptRange.headerValue)
                }
                DiagnosticLog.write("[REMOTE_STREAM_RESPONSE] mode=streaming, status=\(response.statusCode), range=\(upstreamRange), sourceByteOffset=\(stream.sourceByteOffset), bytes=\(nextStart - attemptStart), contentLength=\(headerValue(response.headers, "Content-Length") ?? "-"), contentRange=\(headerValue(response.headers, "Content-Range") ?? "-"), contentType=\(headerValue(response.headers, "Content-Type") ?? stream.contentType)")
                break
            } catch {
                if await accumulator.nextStart() > range.end {
                    break
                }
                if Task.isCancelled || attempt >= 2 || !shouldRetryRemoteStreamError(error) {
                    throw error
                }
                attempt += 1
                let resumeStart = await accumulator.nextStart()
                DiagnosticLog.write("[REMOTE_STREAM_RETRY] id=\(stream.id), kind=demand-stream, attempt=\(attempt), range=bytes=\(resumeStart)-\(range.end), deliveredBytes=\(resumeStart - range.start), error=\(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 150_000_000)
            }
        }

        guard let chunk = await accumulator.makeChunk() else {
            throw ProxyServerError.emptyUpstreamResponse(range.headerValue)
        }
        return chunk
    }

    private func sendOpenEndedRemoteStreamHeadIfNeeded(
        channel: SendableChannel,
        version: HTTPVersion,
        stream: RemoteStream,
        response: ProxyResponse,
        requestedStart: Int64,
        responseTotalLength: Int64?,
        responseState: ContinuousRemoteStreamResponseState
    ) async throws {
        let decision = await responseState.prepareHead(responseTotalLength: responseTotalLength)
        guard decision.shouldSend else { return }
        guard decision.totalLength > requestedStart else {
            throw ProxyServerError.upstreamRangeMismatch(
                expected: "bytes=\(requestedStart)-",
                actual: headerValue(response.headers, "Content-Range")
            )
        }
        let upstreamMode = stream.parallelSegmentedOpenEndedUpstream ? "parallel-segmented" : "chunked"
        DiagnosticLog.write("[REMOTE_STREAM_CONTINUOUS_START] id=\(stream.id), range=bytes=\(requestedStart)-\(decision.totalLength - 1), chunkSize=\(stream.bufferConfiguration.chunkSize), upstreamMode=\(upstreamMode)")
        try await sendOpenEndedRemoteStreamHead(
            channel: channel,
            version: version,
            response: response,
            start: requestedStart,
            totalLength: decision.totalLength
        )
    }

    private func continuousRemoteStreamRange(
        start: Int64,
        totalLength: Int64,
        stream: RemoteStream
    ) -> RemoteStreamRange {
        let requestedChunkSize = start == 0
            ? stream.bufferConfiguration.initialChunkSize
            : stream.bufferConfiguration.chunkSize
        let chunkSize = max(1, requestedChunkSize)
        let end = min(totalLength - 1, start + chunkSize - 1)
        return RemoteStreamRange(start: start, end: max(start, end))
    }

    private func bufferedRemoteStreamResponse(
        stream: RemoteStream,
        range: RemoteStreamRange,
        method: NIOHTTP1.HTTPMethod,
        isPriming: Bool = false
    ) async throws -> ProxyResponse {
        try await stream.buffer.response(
            for: range,
            stream: stream,
            method: method,
            isPriming: isPriming
        ) { bufferedRange, kind in
            do {
                return try await self.fetchRemoteStreamChunkWithRetry(
                    stream: stream,
                    range: bufferedRange,
                    ifRange: nil,
                    kind: kind,
                    useCurl: kind == .prime && stream.parallelUpstreamUsesCurl
                )
            } catch {
                if kind == .prefetch {
                    let message = "[REMOTE_STREAM_PREFETCH_ERROR] id=\(stream.id), range=\(bufferedRange.headerValue), error=\(error.localizedDescription)"
                    self.server.setRemoteStreamError(id: stream.id, message: message)
                }
                throw error
            }
        }
    }

    private func forwardRemoteStream(
        stream: RemoteStream,
        range: String?,
        ifRange: String?,
        method: NIOHTTP1.HTTPMethod,
        isPriming: Bool = false
    ) async throws -> ProxyResponse {
        _ = try ProxyAccessPolicy.validateTargetURL(stream.url)
        if let response = rangeNotSatisfiableResponse(range: range, contentLength: stream.contentLength) {
            return response
        }
        let requestedRange = remoteStreamRange(from: boundedRangeHeader(
            from: range,
            configuration: stream.bufferConfiguration,
            contentLength: stream.contentLength,
            useFullChunkSize: isPriming && stream.preloadLayout == .audioOriginal
        ))
        guard isPriming || shouldUseRemoteStreamBuffer(
            range: requestedRange,
            stream: stream,
            originalRange: range,
            method: method
        ) else {
            let upstreamRange = passthroughRemoteStreamRange(from: range, fallback: requestedRange)
            return try await fetchRemoteStreamResponse(stream: stream, range: upstreamRange, ifRange: ifRange, method: method)
        }

        return try await bufferedRemoteStreamResponse(
            stream: stream,
            range: requestedRange,
            method: method,
            isPriming: isPriming
        )
    }

    private func fetchRemoteStreamResponse(stream: RemoteStream, range: RemoteStreamRange, ifRange: String?, method: NIOHTTP1.HTTPMethod) async throws -> ProxyResponse {
        let chunk = try await fetchRemoteStreamChunkWithRetry(stream: stream, range: range, ifRange: ifRange, kind: .demand)
        var headers = chunk.headers
        if let length = headerValue(headers, "Content-Length") {
            headers["Content-Length"] = length
        }
        return ProxyResponse(
            statusCode: 206,
            contentType: chunk.contentType,
            data: method == .HEAD ? Data() : chunk.data,
            headers: headers,
            closeConnection: true
        )
    }

    private func fetchRemoteStreamChunk(
        stream: RemoteStream,
        range: RemoteStreamRange,
        ifRange: String?,
        useCurl: Bool = false
    ) async throws -> RemoteStreamChunk {
        var headers = stream.headers
        let upstreamRange = upstreamRangeHeader(for: range, stream: stream)
        headers["Range"] = upstreamRange
        if let ifRange, !ifRange.isEmpty {
            headers["If-Range"] = ifRange
        }

        let response: HTTPResponse
        if useCurl {
            let result = try await CurlRangeTransport.get(
                url: stream.url,
                headers: headers,
                timeout: 15
            )
            let throughput = Double(result.averageBytesPerSecond) / 1_048_576
            DiagnosticLog.write("[REMOTE_STREAM_CURL] id=\(stream.id), range=\(upstreamRange), protocol=\(result.protocolName), ip=\(result.primaryIP), seconds=\(String(format: "%.3f", result.totalTime)), bytes=\(result.response.data.count), MiBps=\(String(format: "%.2f", throughput))")
            response = result.response
        } else {
            response = try await stream.upstreamHTTPClient.request(
                url: stream.url,
                method: .get,
                headers: headers,
                timeout: stream.upstreamRequestTimeout,
                redactsURLInLogs: true
            )
        }
        try ProxyAccessPolicy.validateFinalURL(response.finalURL)
        try validateUpstreamRange(response: response, requestedRange: upstreamRange)
        if (200..<300).contains(response.statusCode) {
            await stream.buffer.recordReceivedBytes(response.data.count)
        }
        let upstreamContentRange = parseContentRange(headerValue(response.headers, "Content-Range"))
        let leadingByteCount = upstreamContentRange.map {
            max(0, min(stream.sourceByteOffset - $0.start, Int64(response.data.count)))
        } ?? 0
        let downstreamData = leadingByteCount > 0
            ? response.data.dropFirst(Int(leadingByteCount))
            : response.data
        let downstreamTotalLength = upstreamContentRange?.total.map {
            max(0, $0 - stream.sourceByteOffset)
        }

        var responseHeaders = response.headers
        responseHeaders["Accept-Ranges"] = headerValue(response.headers, "Accept-Ranges") ?? "bytes"
        if let upstreamContentRange {
            let downstreamStart = max(0, upstreamContentRange.start - stream.sourceByteOffset)
            let downstreamEnd = max(downstreamStart, upstreamContentRange.end - stream.sourceByteOffset)
            let total = downstreamTotalLength.map(String.init) ?? "*"
            responseHeaders["Content-Range"] = "bytes \(downstreamStart)-\(downstreamEnd)/\(total)"
        }
        responseHeaders["Content-Length"] = String(downstreamData.count)

        if response.statusCode >= 400 {
            let bodyPrefix = String(data: response.data.prefix(256), encoding: .utf8) ?? ""
            DiagnosticLog.write("[REMOTE_STREAM_UPSTREAM_ERROR] status=\(response.statusCode), range=\(upstreamRange), contentType=\(headerValue(response.headers, "Content-Type") ?? ""), bodyPrefix=\(bodyPrefix)")
            throw ProxyServerError.upstreamHTTPStatus(response.statusCode)
        } else if !stream.parallelUpstreamUsesHTTP2Multiplexing || range.start == 0 {
            DiagnosticLog.write("[REMOTE_STREAM_RESPONSE] status=\(response.statusCode), range=\(upstreamRange), sourceByteOffset=\(stream.sourceByteOffset), bytes=\(response.data.count), contentLength=\(headerValue(response.headers, "Content-Length") ?? "-"), contentRange=\(headerValue(response.headers, "Content-Range") ?? "-"), contentType=\(headerValue(response.headers, "Content-Type") ?? stream.contentType)")
        }

        if let downstreamTotalLength {
            server.updateRemoteStreamContentLength(id: stream.id, contentLength: downstreamTotalLength)
        }
        return RemoteStreamChunk(
            range: range,
            data: Data(downstreamData),
            headers: responseHeaders,
            contentType: headerValue(response.headers, "Content-Type") ?? stream.contentType,
            totalLength: downstreamTotalLength
        )
    }

    private func fetchRemoteStreamChunkWithRetry(
        stream: RemoteStream,
        range: RemoteStreamRange,
        ifRange: String?,
        kind: RemoteStreamLoadKind,
        useCurl: Bool = false
    ) async throws -> RemoteStreamChunk {
        let maxRetries: Int
        switch kind {
        case .demand: maxRetries = 2
        case .prefetch: maxRetries = 1
        case .prime: maxRetries = 0
        }
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                let chunk = try await fetchRemoteStreamChunk(
                    stream: stream,
                    range: range,
                    ifRange: ifRange,
                    useCurl: useCurl
                )
                if kind == .demand { stream.parallelConcurrencyController.record(timedOut: false) }
                return chunk
            } catch {
                if kind == .demand, !Task.isCancelled, RemoteStreamParallelConcurrencyController.isTimeout(error) {
                    if stream.parallelConcurrencyController.record(timedOut: true) {
                        PlaybackBackgroundBudget.shared.suspendBackgroundWork(for: 5)
                        DiagnosticLog.write("[PLAYBACK_CONGESTION] id=\(stream.id) concurrency=\(stream.parallelConcurrencyController.currentLimit) backgroundPauseSeconds=5")
                    }
                }
                if Task.isCancelled || attempt >= maxRetries || !shouldRetryRemoteStreamError(error) {
                    throw error
                }
                attempt += 1
                DiagnosticLog.write("[REMOTE_STREAM_RETRY] id=\(stream.id), kind=\(kind), attempt=\(attempt), range=\(range.headerValue), error=\(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 150_000_000)
            }
        }
    }

    private func shouldRetryRemoteStreamError(_ error: Error) -> Bool {
        if case ProxyServerError.upstreamRangeMismatch = error {
            return false
        }
        if case ProxyServerError.upstreamHTTPStatus(let statusCode) = error {
            return statusCode >= 500
        }
        if case ProxyServerError.emptyUpstreamResponse = error {
            return true
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .userCancelledAuthentication:
                return false
            default:
                return true
            }
        }
        if error is CurlRangeTransportError {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == "kCFErrorDomainCFNetwork" {
            return true
        }
        return false
    }

    private func remoteStreamRange(from rangeHeader: String) -> RemoteStreamRange {
        guard let parsed = parseByteRange(rangeHeader) else {
            return RemoteStreamRange(start: 0, end: ProxyServer.defaultStreamChunkSize - 1)
        }
        return RemoteStreamRange(start: parsed.start, end: parsed.end ?? (parsed.start + ProxyServer.defaultStreamChunkSize - 1))
    }

    private func passthroughRemoteStreamRange(from originalRange: String?, fallback: RemoteStreamRange) -> RemoteStreamRange {
        guard let originalRange,
              originalRange.lowercased().hasPrefix("bytes=-") else {
            return fallback
        }
        return RemoteStreamRange(start: 0, end: 0, rawHeaderValue: originalRange)
    }

    private func upstreamRangeHeader(for range: RemoteStreamRange, stream: RemoteStream) -> String {
        guard stream.sourceByteOffset > 0 else { return range.headerValue }

        if let suffixLength = suffixByteCount(from: range.headerValue),
           let contentLength = stream.contentLength,
           contentLength > 0 {
            let downstreamStart = max(0, contentLength - suffixLength)
            let upstreamStart = downstreamStart + stream.sourceByteOffset
            let upstreamEnd = contentLength + stream.sourceByteOffset - 1
            return "bytes=\(upstreamStart)-\(upstreamEnd)"
        }

        guard !range.headerValue.lowercased().hasPrefix("bytes=-") else {
            return range.headerValue
        }
        return "bytes=\(range.start + stream.sourceByteOffset)-\(range.end + stream.sourceByteOffset)"
    }

    private func shouldUseRemoteStreamBuffer(range: RemoteStreamRange, stream: RemoteStream, originalRange: String?, method: NIOHTTP1.HTTPMethod) -> Bool {
        guard stream.relayMode == .buffered else { return false }
        guard method == .GET else { return false }
        guard let originalRange,
              let parsedOriginal = parseByteRange(originalRange),
              parsedOriginal.end == nil,
              !originalRange.lowercased().hasPrefix("bytes=-") else {
            return false
        }
        return range.start < stream.bufferConfiguration.prefetchableStartLimit
    }

    private func boundedRangeHeader(
        from range: String?,
        configuration: RemoteStreamBufferConfiguration = .default,
        contentLength: Int64? = nil,
        useFullChunkSize: Bool = false
    ) -> String {
        if let range,
           range.lowercased().hasPrefix("bytes=-") {
            return range
        }

        guard let parsed = parseByteRange(range) else {
            return "bytes=0-\(configuration.initialChunkSize - 1)"
        }

        let chunkSize = useFullChunkSize || (parsed.end == nil && parsed.start > 0)
            ? configuration.chunkSize
            : configuration.initialChunkSize
        let windowEnd = parsed.start + chunkSize - 1
        var end = min(parsed.end ?? windowEnd, windowEnd)
        if let contentLength, contentLength > 0 {
            end = min(end, contentLength - 1)
        }
        return "bytes=\(parsed.start)-\(max(parsed.start, end))"
    }

    private func rangeNotSatisfiableResponse(range: String?, contentLength: Int64?) -> ProxyResponse? {
        guard let contentLength,
              contentLength > 0,
              let parsed = parseByteRange(range),
              parsed.start >= contentLength else {
            return nil
        }

        return ProxyResponse(
            statusCode: 416,
            contentType: "application/octet-stream",
            data: Data(),
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes */\(contentLength)"
            ],
            closeConnection: true
        )
    }

    private func parseByteRange(_ value: String?) -> (start: Int64, end: Int64?)? {
        guard let value,
              value.lowercased().hasPrefix("bytes=") else {
            return nil
        }

        let range = value.dropFirst("bytes=".count)
        if range.hasPrefix("-") {
            return nil
        }
        let parts = range.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first,
              let start = Int64(first.trimmingCharacters(in: .whitespacesAndNewlines)),
              start >= 0 else {
            return nil
        }

        let end: Int64?
        if parts.count > 1,
           !parts[1].isEmpty {
            end = Int64(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            end = nil
        }
        return (start, end)
    }

    private func suffixByteCount(from value: String) -> Int64? {
        let lower = value.lowercased()
        guard lower.hasPrefix("bytes=-"),
              let count = Int64(value.dropFirst("bytes=-".count)),
              count > 0 else {
            return nil
        }
        return count
    }

    private func validateUpstreamRange(response: HTTPResponse, requestedRange: String) throws {
        try validateUpstreamRange(
            statusCode: response.statusCode,
            headers: response.headers,
            requestedRange: requestedRange
        )
    }

    private func validateUpstreamRange(
        statusCode: Int,
        headers: [String: String],
        requestedRange: String
    ) throws {
        if requestedRange.lowercased().hasPrefix("bytes=-") {
            return
        }
        guard let requested = parseByteRange(requestedRange) else {
            return
        }

        let actualContentRange = headerValue(headers, "Content-Range")
        if statusCode == 206 {
            guard let actual = parseContentRange(actualContentRange),
                  actual.start == requested.start else {
                DiagnosticLog.write("[REMOTE_STREAM_RANGE_MISMATCH] status=\(statusCode), expected=\(requestedRange), actual=\(actualContentRange ?? "-")")
                throw ProxyServerError.upstreamRangeMismatch(expected: requestedRange, actual: actualContentRange)
            }
            return
        }

        if requested.start > 0, (200..<300).contains(statusCode) {
            DiagnosticLog.write("[REMOTE_STREAM_RANGE_MISMATCH] status=\(statusCode), expected=\(requestedRange), actual=\(actualContentRange ?? "-")")
            throw ProxyServerError.upstreamRangeMismatch(expected: requestedRange, actual: actualContentRange)
        }
    }

    private func parseContentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }

        let rangeAndTotal = trimmed
            .dropFirst("bytes".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rangeTotalParts = rangeAndTotal.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let rangePart = rangeTotalParts.first ?? ""
        let parts = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Int64(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Int64(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              start >= 0,
              end >= start else {
            return nil
        }
        let total: Int64?
        if rangeTotalParts.count > 1 {
            let rawTotal = rangeTotalParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            total = rawTotal == "*" ? nil : Int64(rawTotal)
        } else {
            total = nil
        }
        return (start, end, total)
    }

    private func parseHTML(params: [String: String]) -> String {
        let target = escapeHTML(params["url"] ?? "")
        let parses = (params["parses"] ?? "")
            .split(separator: ",")
            .map { escapeHTML(String($0)) }
        let scripts = parses.map { parseURL in
            """
            fetch('\(parseURL)' + encodeURIComponent('\(target)')).catch(function(){});
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>NetVplayer Parse</title></head>
        <body>
        <video id="probe" src="\(target)" autoplay muted playsinline></video>
        <script>
        \(scripts)
        </script>
        </body>
        </html>
        """
    }

    private func queryParams(from uri: String) -> [String: String] {
        guard let components = URLComponents(string: uri), let queryItems = components.queryItems else { return [:] }
        var params: [String: String] = [:]
        for item in queryItems {
            params[item.name] = item.value ?? ""
        }
        return params
    }

    private func targetURL(from params: [String: String]) -> String? {
        if let encoded = params["u64"], let decoded = ProxyURLCodec.decode(encoded), !decoded.isEmpty {
            return decoded
        }
        return params["url"]
    }

    private func decodeHeaderParams(_ params: [String: String]) -> [String: String] {
        let header: String?
        if let encoded = params["h64"], let decoded = ProxyURLCodec.decode(encoded) {
            header = decoded
        } else {
            header = params["header"] ?? params["headers"]
        }
        guard let header, let data = header.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    private func extractHeaderParams(_ params: [String: String]) -> [String: String] {
        params.reduce(into: [:]) { result, item in
            let lower = item.key.lowercased()
            guard lower.hasPrefix("h_") || lower.hasPrefix("header_") else { return }
            let rawKey = lower.hasPrefix("h_") ? String(item.key.dropFirst(2)) : String(item.key.dropFirst("header_".count))
            result[rawKey] = item.value
        }
    }

    private func webResourceHeaders(from params: [String: String], requestHeaders: HTTPHeaders) -> [String: String] {
        var headers = decodeHeaderParams(params).merging(extractHeaderParams(params)) { _, new in new }
        for name in ["Range", "If-Range", "If-None-Match"] {
            if headerValue(headers, name) == nil,
               let value = requestHeaders.first(name: name) {
                headers[name] = value
            }
        }
        return headers
    }

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
            "Access-Control-Allow-Headers": "Range, If-Range, If-None-Match, User-Agent, Referer, Origin, Cookie, Authorization, Content-Type",
            "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges, Content-Type, ETag"
        ]
    }

    private func contentTypeForPath(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mp4": return "video/mp4"
        case "flv": return "video/x-flv"
        case "ts": return "video/mp2t"
        case "json": return "application/json"
        case "html", "htm": return "text/html; charset=utf-8"
        case "txt", "strm": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    private func byteRange(from header: String, dataCount: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let value = String(header.dropFirst("bytes=".count))
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let start = Int(parts[0]) ?? 0
        let end = parts[1].isEmpty ? dataCount - 1 : (Int(parts[1]) ?? dataCount - 1)
        guard start >= 0, end >= start, start < dataCount else { return nil }
        return start..<min(end + 1, dataCount)
    }

    private func weakETag(for data: Data) -> String {
        "W/\"\(data.count)-\(data.hashValue)\""
    }

    private func shouldServeRange(ifRange: String?, etag: String) -> Bool {
        guard let ifRange, !ifRange.isEmpty else { return true }
        return ifRange == etag
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func jsonEscaped(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

    private func sendTextResponse(context: ChannelHandlerContext, version: HTTPVersion, status: HTTPResponseStatus, contentType: String, text: String) {
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)

        let responseHead = HTTPResponseHead(version: version, status: status, headers: [
            "Content-Type": contentType,
            "Content-Length": "\(text.utf8.count)",
        ])

        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendProxyStreamHead(
        channel: SendableChannel,
        version: HTTPVersion,
        response: ProxyStreamingResponseHead,
        state: ProxyStreamState
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.channel.eventLoop.execute {
                guard channel.channel.isActive else {
                    continuation.resume(throwing: ChannelError.ioOnClosedChannel)
                    return
                }

                let shouldClose = response.closeConnection || response.contentLength == nil
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: response.contentType)
                if let contentLength = response.contentLength, contentLength >= 0 {
                    headers.add(name: "Content-Length", value: String(contentLength))
                }
                if shouldClose {
                    headers.add(name: "Connection", value: "close")
                }
                for (name, value) in response.headers {
                    guard self.shouldForwardResponseHeader(name) else { continue }
                    headers.add(name: name, value: value)
                }

                state.markStarted(closeConnection: shouldClose)
                let head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode),
                    headers: headers
                )
                let promise = channel.channel.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                }
                channel.channel.writeAndFlush(
                    HTTPServerResponsePart.head(head),
                    promise: promise
                )
            }
        }
    }

    private func finishProxyStream(
        channel: SendableChannel,
        state: ProxyStreamState,
        forceClose: Bool = false
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.channel.eventLoop.execute {
                guard channel.channel.isActive else {
                    continuation.resume(throwing: ChannelError.ioOnClosedChannel)
                    return
                }

                let shouldClose = forceClose || state.snapshot().closeConnection
                let promise = channel.channel.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                    if shouldClose {
                        channel.channel.close(promise: nil)
                    }
                }
                channel.channel.writeAndFlush(
                    HTTPServerResponsePart.end(nil),
                    promise: promise
                )
            }
        }
    }

    private func sendOpenEndedRemoteStreamHead(
        channel: SendableChannel,
        version: HTTPVersion,
        response: ProxyResponse,
        start: Int64,
        totalLength: Int64
    ) async throws {
        guard channel.channel.isActive else {
            throw ChannelError.ioOnClosedChannel
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.channel.eventLoop.execute {
                guard channel.channel.isActive else {
                    continuation.resume(throwing: ChannelError.ioOnClosedChannel)
                    return
                }

                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: response.contentType)
                headers.add(name: "Content-Length", value: String(totalLength - start))
                headers.add(name: "Content-Range", value: "bytes \(start)-\(totalLength - 1)/\(totalLength)")
                headers.add(name: "Accept-Ranges", value: "bytes")
                headers.add(name: "Connection", value: "close")
                for (name, value) in response.headers {
                    let lowercasedName = name.lowercased()
                    guard lowercasedName != "content-range",
                          lowercasedName != "accept-ranges" else {
                        continue
                    }
                    guard self.shouldForwardResponseHeader(name) else { continue }
                    headers.add(name: name, value: value)
                }

                let head = HTTPResponseHead(version: version, status: .partialContent, headers: headers)
                let promise = channel.channel.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                }
                channel.channel.writeAndFlush(
                    HTTPServerResponsePart.head(head),
                    promise: promise
                )
            }
        }
    }

    private func writeOpenEndedRemoteStreamBody(
        channel: SendableChannel,
        data: Data,
        stream: RemoteStream? = nil
    ) async throws {
        guard channel.channel.isActive else {
            throw ChannelError.ioOnClosedChannel
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.channel.eventLoop.execute {
                guard channel.channel.isActive else {
                    continuation.resume(throwing: ChannelError.ioOnClosedChannel)
                    return
                }

                var buffer = channel.channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                let promise = channel.channel.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                }
                channel.channel.writeAndFlush(
                    HTTPServerResponsePart.body(.byteBuffer(buffer)),
                    promise: promise
                )
            }
        }
        if let stream {
            await stream.buffer.recordDeliveredBytes(data.count)
        }
    }

    private func finishOpenEndedRemoteStream(channel: SendableChannel) async throws {
        guard channel.channel.isActive else {
            throw ChannelError.ioOnClosedChannel
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.channel.eventLoop.execute {
                guard channel.channel.isActive else {
                    continuation.resume(throwing: ChannelError.ioOnClosedChannel)
                    return
                }

                let promise = channel.channel.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { result in
                    continuation.resume(with: result)
                    channel.channel.close(promise: nil)
                }
                channel.channel.writeAndFlush(
                    HTTPServerResponsePart.end(nil),
                    promise: promise
                )
            }
        }
    }

    private func sendResponse(context: ChannelHandlerContext, version: HTTPVersion, response: ProxyResponse) {
        guard ProxyServer.canBufferResponse(byteCount: response.data.count) else {
            DiagnosticLog.write(
                "[PROXY_BUFFERED_RESPONSE_REJECTED] status=\(response.statusCode), bytes=\(response.data.count), limit=\(ProxyServer.maxBufferedResponseBytes)"
            )
            sendErrorResponse(
                context: context,
                version: version,
                status: HTTPResponseStatus(statusCode: 502),
                message: "上游响应过大，必须使用流式代理"
            )
            return
        }

        var buffer = context.channel.allocator.buffer(capacity: response.data.count)
        buffer.writeBytes(response.data)

        var nioHeaders = HTTPHeaders()
        nioHeaders.add(name: "Content-Type", value: response.contentType)
        nioHeaders.add(name: "Content-Length", value: headerValue(response.headers, "Content-Length") ?? "\(response.data.count)")
        if response.closeConnection {
            nioHeaders.add(name: "Connection", value: "close")
        }
        for (k, v) in response.headers {
            guard shouldForwardResponseHeader(k) else { continue }
            nioHeaders.add(name: k, value: v)
        }

        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let responseHead = HTTPResponseHead(version: version, status: status, headers: nioHeaders)

        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let promise = response.closeConnection ? context.eventLoop.makePromise(of: Void.self) : nil
        if response.closeConnection {
            let channel = SendableChannel(channel: context.channel)
            promise?.futureResult.whenComplete { _ in
                channel.channel.close(promise: nil)
            }
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
    }

    private func sendJSONResponse<T: Encodable>(context: ChannelHandlerContext, version: HTTPVersion, statusCode: Int, value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        sendResponse(
            context: context,
            version: version,
            response: ProxyResponse(
                statusCode: statusCode,
                contentType: "application/json",
                data: data
            )
        )
    }

    private func sendErrorResponse(context: ChannelHandlerContext, version: HTTPVersion, status: HTTPResponseStatus, message: String) {
        let responseBody = "{\"error\":\"\(jsonEscaped(message))\"}"
        var buffer = context.channel.allocator.buffer(capacity: responseBody.utf8.count)
        buffer.writeString(responseBody)

        var nioHeaders = HTTPHeaders()
        nioHeaders.add(name: "Content-Type", value: "application/json")
        nioHeaders.add(name: "Content-Length", value: "\(responseBody.utf8.count)")

        let responseHead = HTTPResponseHead(version: version, status: status, headers: nioHeaders)

        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func shouldForwardResponseHeader(_ name: String) -> Bool {
        switch name.lowercased() {
        case "content-length",
             "content-type",
             "transfer-encoding",
             "connection",
             "keep-alive",
             "proxy-authenticate",
             "proxy-authorization",
             "te",
             "trailer",
             "upgrade":
            return false
        default:
            return true
        }
    }

    private func headerValue(_ headers: [String: String], _ name: String) -> String? {
        headers[name] ?? headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
