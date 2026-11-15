import CryptoKit
import Darwin
import Foundation
import Networking
import Models
import ProviderSDK

struct DevelopmentAndroidProviderArtifact: Sendable {
    let original: URL
    let converted: URL
    let sha256: String
    let convertedSHA256: String
}

public enum DevelopmentAndroidArtifactError: String, LocalizedError {
    case invalidReference, downloadFailed, checksumMismatch, invalidArchive, conversionFailed
    public var errorDescription: String? {
        // Fixed local copy: never expose source URLs, headers or converter output.
        switch self {
        case .invalidReference:
            return L10n.text("视频源组件地址或校验信息无效，请更新配置或切换视频源。")
        case .downloadFailed:
            return L10n.text("视频源组件下载失败，请稍后重试或切换视频源。")
        case .checksumMismatch:
            return L10n.text("视频源组件校验失败，请更新配置或切换视频源。")
        case .invalidArchive:
            return L10n.text("视频源组件格式无效，请更新配置或切换视频源。")
        case .conversionFailed:
            return L10n.text("视频源组件准备失败，请稍后重试或切换视频源。")
        }
    }
}

/// Follows the user's current JAR declaration only in the explicitly bundled DEBUG runtime.
/// Source responses and converted bytecode stay outside the application bundle and signed Provider store.
actor DevelopmentAndroidArtifactStore {
    typealias Fetch = @Sendable (URL, Int) async throws -> Data
    typealias Convert = @Sendable (DevelopmentAndroidRuntimeLayout, URL, URL) async throws -> Void
    static let shared = DevelopmentAndroidArtifactStore()
    static let maximumBytes = 32 * 1024 * 1024
    private let root: URL
    private let fetch: Fetch
    private let convert: Convert
    private var pending: [String: Task<DevelopmentAndroidProviderArtifact, Error>] = [:]

    init(root: URL? = nil, fetch: @escaping Fetch = DevelopmentAndroidArtifactStore.fetchArtifact,
         convert: @escaping Convert = DevelopmentAndroidArtifactStore.convertArtifact) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetVplayer/DevelopmentAndroidArtifacts", isDirectory: true)
        self.fetch = fetch
        self.convert = convert
    }

    func resolve(declaration: String, runtime: DevelopmentAndroidRuntimeLayout,
                 bindings: [DevelopmentAndroidRuntimeManifest.Binding]) async throws -> DevelopmentAndroidProviderArtifact {
        let reference = try Reference(declaration)
        let key = Self.hash(Data((declaration + "\n" + (try runtime.conversionIdentity())).utf8))
        let artifact: DevelopmentAndroidProviderArtifact
        if let task = pending[key] { artifact = try await task.value }
        else {
            let root = root, fetch = fetch, convert = convert
            let task = Task { try await Self.prepare(reference: reference, runtime: runtime, root: root, fetch: fetch, convert: convert) }
            pending[key] = task
            do { artifact = try await task.value; pending[key] = nil }
            catch { pending[key] = nil; throw error }
        }
        let entries = try Self.entries(in: artifact.converted)
        guard bindings.allSatisfy({ entries.contains($0.className.replacingOccurrences(of: ".", with: "/") + ".class") }) else {
            throw DevelopmentAndroidArtifactError.invalidArchive
        }
        return artifact
    }

    struct Reference: Sendable {
        let url: URL
        let checksum: String?
        init(_ declaration: String) throws {
            let parts = declaration.components(separatedBy: ";md5;")
            guard (1...2).contains(parts.count),
                  let url = URL(string: parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
                  url.isFileURL || !(url.host ?? "").isEmpty else { throw DevelopmentAndroidArtifactError.invalidReference }
            self.url = url
            checksum = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if let checksum, !Self.validMD5(checksum) {
                guard let checksumURL = URL(string: checksum), ["http", "https"].contains(checksumURL.scheme?.lowercased() ?? ""),
                      !(checksumURL.host ?? "").isEmpty else { throw DevelopmentAndroidArtifactError.invalidReference }
            }
        }
        static func validMD5(_ value: String) -> Bool { value.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil }
    }

    private struct Record: Codable {
        let sha256: String
        let convertedSHA256: String
        let md5: String
        let converter: String
    }

    private static func prepare(reference: Reference, runtime: DevelopmentAndroidRuntimeLayout, root: URL,
                                fetch: Fetch, convert: Convert) async throws -> DevelopmentAndroidProviderArtifact {
        try Task.checkCancellation()
        var expected = reference.checksum?.lowercased()
        if let checksum = reference.checksum, !Reference.validMD5(checksum) {
            let data = try await checkedFetch(URL(string: checksum)!, limit: 1024, fetch: fetch)
            expected = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let expected, Reference.validMD5(expected) else { throw DevelopmentAndroidArtifactError.invalidReference }
        }
        let bundled = runtime.root.appendingPathComponent("inputs/provider.jar")
        if let expected, try md5(bundled) == expected {
            let converted = runtime.root.appendingPathComponent("converted/provider-jvm.jar")
            return .init(original: bundled, converted: converted, sha256: runtime.manifest.providerSHA256,
                         convertedSHA256: try digest(converted))
        }
        // Bind cached conversions to the actual converter/framework/JDK inputs, not only to source bytes.
        let converter = try converterIdentity(runtime)
        let sourceKey = hash(Data((reference.url.absoluteString + "\n" + (expected ?? "unversioned") + "\n" + converter).utf8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let index = root.appendingPathComponent(sourceKey + ".json")
        if let expected, let cached = try? readCached(index: index, root: root, expected: expected, converter: converter) {
            return cached
        }
        let bytes = try await checkedFetch(reference.url, limit: maximumBytes, fetch: fetch)
        let actualMD5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard expected == nil || expected == actualMD5 else { throw DevelopmentAndroidArtifactError.checksumMismatch }
        let originalSHA = hash(bytes)
        let destination = root.appendingPathComponent(originalSHA + "-" + converter, isDirectory: true)
        let recordURL = destination.appendingPathComponent("record.json")
        if let cached = try? readCached(index: recordURL, root: root, expected: actualMD5, converter: converter) {
            let record = Record(sha256: cached.sha256, convertedSHA256: cached.convertedSHA256, md5: actualMD5, converter: converter)
            try writeRecord(record, to: index)
            return cached
        }
        let staging = root.appendingPathComponent(".preparing-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let original = staging.appendingPathComponent("provider.jar")
        let converted = staging.appendingPathComponent("provider-jvm.jar")
        try bytes.write(to: original, options: .withoutOverwriting)
        _ = try entries(in: original)
        do { try await convert(runtime, original, converted) }
        catch is CancellationError { throw CancellationError() }
        catch { throw DevelopmentAndroidArtifactError.conversionFailed }
        try Task.checkCancellation()
        _ = try entries(in: converted)
        let record = Record(sha256: originalSHA, convertedSHA256: try digest(converted), md5: actualMD5, converter: converter)
        try writeRecord(record, to: staging.appendingPathComponent("record.json"))
        for file in [original, converted] { try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path) }
        // A corrupt previous cache is never executed. Preserve it for diagnosis under a different name.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent(".invalid-" + UUID().uuidString))
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        try writeRecord(record, to: index)
        DiagnosticLog.write("[ANDROID_PROVIDER_ARTIFACT] backend=emulated providerSHA256=\(originalSHA) bundledMatch=\(originalSHA == runtime.manifest.providerSHA256)")
        return try readCached(index: recordURL, root: root, expected: actualMD5, converter: converter)
    }

    private static func readCached(index: URL, root: URL, expected: String, converter: String) throws -> DevelopmentAndroidProviderArtifact {
        guard (try index.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4096 else {
            throw DevelopmentAndroidArtifactError.invalidArchive
        }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: index))
        guard validSHA(record.sha256), validSHA(record.convertedSHA256), record.md5 == expected, record.converter == converter else {
            throw DevelopmentAndroidArtifactError.invalidArchive
        }
        let directory = root.appendingPathComponent(record.sha256 + "-" + converter, isDirectory: true)
        let original = directory.appendingPathComponent("provider.jar"), converted = directory.appendingPathComponent("provider-jvm.jar")
        for file in [original, converted] {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maximumBytes,
                  file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw DevelopmentAndroidArtifactError.invalidArchive
            }
        }
        guard try digest(original) == record.sha256, try md5(original) == expected,
              try digest(converted) == record.convertedSHA256 else { throw DevelopmentAndroidArtifactError.invalidArchive }
        _ = try entries(in: converted)
        return .init(original: original, converted: converted, sha256: record.sha256, convertedSHA256: record.convertedSHA256)
    }

    private static func writeRecord(_ record: Record, to url: URL) throws {
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func checkedFetch(_ url: URL, limit: Int, fetch: Fetch) async throws -> Data {
        do {
            let bytes = try await fetch(url, limit)
            guard !bytes.isEmpty && bytes.count <= limit else { throw DevelopmentAndroidArtifactError.downloadFailed }
            return bytes
        } catch is CancellationError { throw CancellationError() }
        catch { throw DevelopmentAndroidArtifactError.downloadFailed }
    }

    static func fetchArtifact(_ url: URL, limit: Int) async throws -> Data {
        if url.isFileURL {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= limit else { throw DevelopmentAndroidArtifactError.downloadFailed }
            return try Data(contentsOf: url)
        }
        return try await HTTPClient.shared.getBounded(url: url.absoluteString, maximumBytes: limit, timeout: 20,
                                                     allowsProxyFallback: false).data
    }

    static func convertArtifact(_ runtime: DevelopmentAndroidRuntimeLayout, _ original: URL, _ converted: URL) async throws {
        try await Task.detached(priority: .utility) { try runConversion(runtime, original, converted) }.value
    }

    private static func runConversion(_ runtime: DevelopmentAndroidRuntimeLayout, _ original: URL, _ converted: URL) throws {
        let process = Process()
        process.executableURL = runtime.root.appendingPathComponent("jdk/bin/java")
        process.arguments = ["-Xmx512m", "-cp", ["macapk-loader.jar", "android-framework.jar"].map {
            runtime.root.appendingPathComponent("lib/" + $0).path
        }.joined(separator: ":"), "com.macapk.dex.Main", original.path, converted.path]
        process.currentDirectoryURL = original.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("MACAPK_") || key.hasPrefix("DEX2JVM_") || key.hasPrefix("NETVPLAYER_")
            || ["JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH"].contains(key) { environment.removeValue(forKey: key) }
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw DevelopmentAndroidArtifactError.conversionFailed }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw DevelopmentAndroidArtifactError.conversionFailed
        }
    }

    private static func converterIdentity(_ runtime: DevelopmentAndroidRuntimeLayout) throws -> String {
        try runtime.conversionIdentity()
    }
    private static func validSHA(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func digest(_ file: URL) throws -> String { try hash(Data(contentsOf: file)) }
    private static func md5(_ file: URL) throws -> String { try Insecure.MD5.hash(data: Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined() }

    /// Read only ZIP directory metadata. Conversion must contain each exact bound Guard class.
    static func entries(in url: URL) throws -> Set<String> {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size >= 22, size <= maximumBytes else { throw DevelopmentAndroidArtifactError.invalidArchive }
        let bytes = [UInt8](try Data(contentsOf: url))
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var end: Int?
        for i in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if u32(i) == 0x06054b50 && i + 22 + u16(i + 20) == bytes.count { end = i; break }
        }
        guard let end, u16(end + 4) == 0, u16(end + 6) == 0,
              u16(end + 8) == u16(end + 10), (1...20000).contains(u16(end + 10)),
              u32(end + 16) + u32(end + 12) == end else { throw DevelopmentAndroidArtifactError.invalidArchive }
        var cursor = u32(end + 16)
        var names = Set<String>()
        for _ in 0..<u16(end + 10) {
            guard cursor + 46 <= end, u32(cursor) == 0x02014b50 else { throw DevelopmentAndroidArtifactError.invalidArchive }
            let length = u16(cursor + 28), next = cursor + 46 + length + u16(cursor + 30) + u16(cursor + 32)
            guard length > 0, next <= end,
                  let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + length)], encoding: .utf8),
                  !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), names.insert(name).inserted else {
                throw DevelopmentAndroidArtifactError.invalidArchive
            }
            cursor = next
        }
        guard cursor == end else { throw DevelopmentAndroidArtifactError.invalidArchive }
        return names
    }
}
/// A failed refresh must not leave an older, restartable helper selected in the registry.
struct DevelopmentAndroidArtifactFailureProvider: SiteContentProvider {
    let error: DevelopmentAndroidArtifactError
    func homeContent(site: Site) async throws -> Result { throw error }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result { throw error }
    func detailContent(site: Site, id: String) async throws -> Result { throw error }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result { throw error }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { throw error }
}
