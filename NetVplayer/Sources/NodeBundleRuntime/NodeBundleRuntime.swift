// NodeBundleRuntime/NodeBundleRuntime.swift
// Host-side runtime for OKVideoMac-compatible remote Node .js.md5 bundles.

import CryptoKit
import Foundation
import Models
import Networking

public struct NodeBundleResolution: Sendable {
    public let sourceURL: String
    public let providerID: String
    public let configurationData: Data

    public init(sourceURL: String, providerID: String, configurationData: Data) {
        self.sourceURL = sourceURL
        self.providerID = providerID
        self.configurationData = configurationData
    }
}

public enum NodeBundleRuntimeError: Error, LocalizedError, Sendable {
    case invalidURL
    case unsupportedScheme
    case invalidEntry(String)
    case checksumUnavailable
    case checksumMismatch(expected: String, actual: String)
    case sha256Mismatch(expected: String, actual: String)
    case bundleTooLarge
    case nodeUnavailable
    case processLaunch(String)
    case processExited(Int32, String)
    case healthTimeout
    case configurationInvalid
    case sessionUnavailable(String)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Node .js.md5 Provider 地址无效"
        case .unsupportedScheme:
            return "Node .js.md5 Provider 只允许 HTTPS；本机 HTTP 仅用于回环测试"
        case .invalidEntry(let value):
            return "Node Provider 入口无效：\(value)"
        case .checksumUnavailable:
            return "Node .js.md5 Provider 未返回有效 MD5 校验值"
        case .checksumMismatch(let expected, let actual):
            return "Node Provider MD5 校验失败（期望 \(expected)，实际 \(actual)）"
        case .sha256Mismatch(let expected, let actual):
            return "Node Provider SHA-256 校验失败（期望 \(expected)，实际 \(actual)）"
        case .bundleTooLarge:
            return "Node Provider 脚本超过 16 MiB 限制"
        case .nodeUnavailable:
            return "应用未包含可用的 Node.js 运行时；开发环境可设置 NETVPLAYER_NODE_PATH"
        case .processLaunch(let message):
            return "Node Provider 进程启动失败：\(message)"
        case .processExited(let status, let detail):
            if detail.isEmpty {
                return "Node Provider 进程已退出（状态码 \(status)）"
            }
            return "Node Provider 进程已退出（状态码 \(status)）：\(detail)"
        case .healthTimeout:
            return "Node Provider 启动超时，/health 未就绪"
        case .configurationInvalid:
            return "Node Provider /config 返回了无法识别的配置"
        case .sessionUnavailable(let value):
            return "Node Provider 会话不可用：\(value)"
        case .requestFailed(let value):
            return "Node Provider 请求失败：\(value)"
        }
    }
}

/// Owns one downloaded bundle and its long-lived Node HTTP process.
private actor NodeBundleSession {
    private static let maxBundleBytes = 16 * 1024 * 1024
    private static let bootstrapScript = #"""
    import { pathToFileURL } from "node:url";
    const bundlePath = process.argv[1];
    const port = Number(process.argv[2]);
    process.env.PORT = String(port);
    process.env.DEV_HTTP_PORT = String(port);
    process.env.HOST = "127.0.0.1";
    // OKVideoMac bundles auto-start when argv[1] ends in index.js. The host
    // owns the lifecycle, so disable that side effect before importing.
    process.env.CATVOD_DISABLE_AUTOSTART = "1";
    const bundle = await import(pathToFileURL(bundlePath).href);
    if (typeof bundle.start !== "function") {
      throw new Error("Node bundle must export start()");
    }
    await bundle.start({ port, host: "127.0.0.1" });
    process.stdin.resume();
    const stop = async () => {
      try { if (typeof bundle.stop === "function") await bundle.stop(); }
      finally { process.exit(0); }
    };
    process.once("SIGTERM", stop);
    process.once("SIGINT", stop);
    """#

    let sourceURL: URL
    let checksumURL: URL
    let scriptURL: URL
    var expectedMD5: String
    let expectedSHA256: String?
    let httpClient: HTTPClient

    var process: Process?
    var temporaryDirectory: URL?
    var baseURL: URL?
    var cachedConfiguration: Data?

    init(sourceURL: URL, httpClient: HTTPClient) throws {
        guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.path.lowercased().hasSuffix(".js.md5") else {
            throw NodeBundleRuntimeError.invalidEntry(sourceURL.absoluteString)
        }
        if scheme == "http" {
            let host = components.host?.lowercased() ?? ""
            guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
                throw NodeBundleRuntimeError.unsupportedScheme
            }
        }
        self.sourceURL = sourceURL
        self.httpClient = httpClient

        var checksumComponents = components
        checksumComponents.fragment = nil
        self.checksumURL = checksumComponents.url ?? sourceURL

        var scriptComponents = checksumComponents
        scriptComponents.path = String(scriptComponents.path.dropLast(4))
        guard let scriptURL = scriptComponents.url,
              scriptURL.path.lowercased().hasSuffix(".js") else {
            throw NodeBundleRuntimeError.invalidEntry(sourceURL.absoluteString)
        }
        self.scriptURL = scriptURL

        let fragment = components.fragment?.split(separator: "&").first {
            $0.lowercased().hasPrefix("sha256=")
        }
        self.expectedSHA256 = fragment.map {
            String($0.dropFirst("sha256=".count)).lowercased()
        }
        self.expectedMD5 = ""
    }

    func configuration() async throws -> Data {
        try await ensureStarted()
        if let cachedConfiguration { return cachedConfiguration }
        guard let baseURL else { throw NodeBundleRuntimeError.sessionUnavailable(sourceURL.absoluteString) }
        let response = try await httpClient.get(
            url: baseURL.appendingPathComponent("config").absoluteString,
            timeout: 15,
            allowsProxyFallback: false
        )
        guard (200...299).contains(response.statusCode) else {
            throw NodeBundleRuntimeError.requestFailed("/config HTTP \(response.statusCode)")
        }
        guard JSONSerialization.isValidJSONObject(try JSONSerialization.jsonObject(with: response.data)) else {
            throw NodeBundleRuntimeError.configurationInvalid
        }
        cachedConfiguration = response.data
        return response.data
    }

    func request(
        api: String,
        method: String,
        body: Data,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        try await ensureStarted()
        guard let baseURL else { throw NodeBundleRuntimeError.sessionUnavailable(sourceURL.absoluteString) }
        let normalizedAPI = api.hasPrefix("/") ? String(api.dropFirst()) : api
        let endpoint = baseURL.appendingPathComponent(normalizedAPI).appendingPathComponent(method)
        var requestHeaders = headers
        requestHeaders["Content-Type"] = "application/json; charset=utf-8"
        for attempt in 0..<2 {
            do {
                let response = try await httpClient.request(
                    url: endpoint.absoluteString,
                    method: .post,
                    headers: requestHeaders,
                    body: body,
                    timeout: timeout,
                    allowsProxyFallback: false
                )
                guard (200...299).contains(response.statusCode) else {
                    let message = String(data: response.data.prefix(512), encoding: .utf8) ?? "HTTP \(response.statusCode)"
                    if attempt == 0, Self.isTransientUpstreamFailure(message) {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        continue
                    }
                    throw NodeBundleRuntimeError.requestFailed("\(method)：\(message)")
                }
                return response.data
            } catch let error as NodeBundleRuntimeError {
                throw error
            } catch {
                guard attempt == 0, Self.isTransientUpstreamFailure(error.localizedDescription) else {
                    throw error
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        throw NodeBundleRuntimeError.requestFailed("\(method)：上游请求连续失败")
    }

    func stop() async {
        process?.terminate()
        process = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        baseURL = nil
        cachedConfiguration = nil
    }

    private func ensureStarted() async throws {
        if let process, process.isRunning, baseURL != nil { return }
        if let process, process.isRunning == false {
            self.process = nil
        }
        try await downloadAndLaunch()
    }

    private func downloadAndLaunch() async throws {
        let checksumResponse = try await httpClient.get(
            url: checksumURL.absoluteString,
            timeout: 20,
            allowsProxyFallback: false
        )
        guard (200...299).contains(checksumResponse.statusCode),
              let checksumText = String(data: checksumResponse.data, encoding: .utf8),
              let expectedMD5 = Self.extractMD5(checksumText) else {
            throw NodeBundleRuntimeError.checksumUnavailable
        }
        self.expectedMD5 = expectedMD5

        let scriptResponse = try await httpClient.get(
            url: scriptURL.absoluteString,
            timeout: 60,
            allowsProxyFallback: false
        )
        guard (200...299).contains(scriptResponse.statusCode) else {
            throw NodeBundleRuntimeError.requestFailed("脚本 HTTP \(scriptResponse.statusCode)")
        }
        guard !scriptResponse.data.isEmpty,
              scriptResponse.data.count <= Self.maxBundleBytes else {
            throw NodeBundleRuntimeError.bundleTooLarge
        }

        let actualMD5 = Insecure.MD5.hash(data: scriptResponse.data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualMD5.caseInsensitiveCompare(expectedMD5) == .orderedSame else {
            throw NodeBundleRuntimeError.checksumMismatch(expected: expectedMD5, actual: actualMD5)
        }
        if let expectedSHA256 {
            let actualSHA256 = SHA256.hash(data: scriptResponse.data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualSHA256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw NodeBundleRuntimeError.sha256Mismatch(expected: expectedSHA256, actual: actualSHA256)
            }
        }

        guard let node = NodeRuntimeLocator.locate() else {
            throw NodeBundleRuntimeError.nodeUnavailable
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetVplayer-NodeBundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundleURL = directory.appendingPathComponent("index.js")
        try scriptResponse.data.write(to: bundleURL, options: [.atomic])
        let stdoutURL = directory.appendingPathComponent("stdout.log")
        let stderrURL = directory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        var launchedProcess: Process?
        var selectedPort: Int?
        for _ in 0..<3 {
            let port = Int.random(in: 20_000...45_000)
            let candidate = Process()
            candidate.executableURL = node.executableURL
            candidate.arguments = ["--input-type=module", "-e", Self.bootstrapScript, bundleURL.path, String(port)]
            var environment = ProcessInfo.processInfo.environment
            environment["PORT"] = String(port)
            environment["DEV_HTTP_PORT"] = String(port)
            // Several OKVideoMac providers persist profile/cache files under
            // NODE_PATH || process.cwd(). A GUI app may start in / or inside
            // the app bundle, neither of which is a writable provider root.
            environment["NODE_PATH"] = directory.path
            environment["CATVOD_DISABLE_AUTOSTART"] = "1"
            candidate.environment = environment
            candidate.currentDirectoryURL = directory
            candidate.standardOutput = try FileHandle(forWritingTo: stdoutURL)
            candidate.standardError = try FileHandle(forWritingTo: stderrURL)
            do {
                try candidate.run()
            } catch {
                throw NodeBundleRuntimeError.processLaunch(error.localizedDescription)
            }
            switch await waitForHealth(process: candidate, port: port, stderrURL: stderrURL) {
            case .ready:
                launchedProcess = candidate
                selectedPort = port
            case .exited(let status, let detail):
                try? FileHandle(forReadingFrom: stdoutURL).close()
                throw NodeBundleRuntimeError.processExited(status, detail)
            case .timedOut:
                candidate.terminate()
            }
            if launchedProcess != nil { break }
        }
        guard let launchedProcess, let selectedPort else {
            try? FileManager.default.removeItem(at: directory)
            throw NodeBundleRuntimeError.healthTimeout
        }
        self.process = launchedProcess
        self.temporaryDirectory = directory
        self.baseURL = URL(string: "http://127.0.0.1:\(selectedPort)")
    }

    private enum HealthResult {
        case ready
        case exited(Int32, String)
        case timedOut
    }

    private func waitForHealth(process: Process, port: Int, stderrURL: URL) async -> HealthResult {
        let url = "http://127.0.0.1:\(port)/health"
        for _ in 0..<40 {
            if !process.isRunning {
                let detail = Self.readDiagnostic(from: stderrURL)
                return .exited(process.terminationStatus, detail)
            }
            if let response = try? await httpClient.get(
                url: url,
                timeout: 1,
                allowsProxyFallback: false
            ), (200...299).contains(response.statusCode) {
                return .ready
            }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return .timedOut
            }
        }
        return .timedOut
    }

    private static func readDiagnostic(from url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        let text = String(decoding: data.suffix(4 * 1024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.replacingOccurrences(of: "\n", with: " | ")
    }

    private static func isTransientUpstreamFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("econnreset")
            || lower.contains("socket hang up")
            || lower.contains("etimedout")
            || lower.contains("eai_again")
            || lower.contains("fetch failed")
    }

    private static func extractMD5(_ text: String) -> String? {
        text.split { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
            .map(String.init)
            .first { $0.count == 32 && $0.allSatisfy(\.isHexDigit) }?
            .lowercased()
    }

}

public actor NodeBundleRuntimeRegistry {
    public static let shared = NodeBundleRuntimeRegistry()

    private let httpClient: HTTPClient
    private var sessions: [String: NodeBundleSession] = [:]

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    public func resolve(url: String) async throws -> NodeBundleResolution {
        guard let sourceURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NodeBundleRuntimeError.invalidURL
        }
        let providerID = Self.providerID(for: sourceURL.absoluteString)
        let session: NodeBundleSession
        if let existing = sessions[providerID] {
            session = existing
        } else {
            let created = try NodeBundleSession(sourceURL: sourceURL, httpClient: httpClient)
            sessions[providerID] = created
            session = created
        }
        let configurationData = try await session.configuration()
        return NodeBundleResolution(
            sourceURL: sourceURL.absoluteString,
            providerID: providerID,
            configurationData: configurationData
        )
    }

    public func request(
        providerID: String,
        api: String,
        method: String,
        body: Data,
        headers: [String: String] = [:],
        timeout: TimeInterval
    ) async throws -> Data {
        guard let session = sessions[providerID] else {
            throw NodeBundleRuntimeError.sessionUnavailable(providerID)
        }
        return try await session.request(
            api: api,
            method: method,
            body: body,
            headers: headers,
            timeout: timeout
        )
    }

    public func shutdown() async {
        for session in sessions.values { await session.stop() }
        sessions.removeAll()
    }

    private static func providerID(for sourceURL: String) -> String {
        let digest = SHA256.hash(data: Data(sourceURL.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "nodejs_\(digest)"
    }
}
