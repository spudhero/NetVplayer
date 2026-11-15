import Foundation
import Models
import Storage
import FileTransferShim

private final class TransferCancellation: @unchecked Sendable {
    let pointer = nvp_remote_cancel_create()!
    func cancel() { nvp_remote_cancel_set(pointer) }
    deinit { nvp_remote_cancel_destroy(pointer) }
}

private struct TransferResponse: Sendable {
    var data: Data
    var entries: [FileEntry]
    var mlsd: Bool
}

/// Blocking C I/O runs only on this connection's serial queue, never a Swift executor.
private final class TransferConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "netvplayer.file-transfer", qos: .userInitiated)
    private var pointer: OpaquePointer?
    init(configuration: FileServiceConfiguration, credentials: FileServiceCredentials) throws {
        let url = URLComponents(string: configuration.address)!
        let pin = configuration.sshHostKeySHA256.flatMap { value -> Data? in
            guard value.hasPrefix("SHA256:") else { return nil }
            let raw = String(value.dropFirst(7))
            guard let digest = Data(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)), digest.count == 32 else { return nil }
            return digest
        }
        pointer = (pin ?? Data()).withUnsafeBytes { digest in
            nvp_remote_create(configuration.kind == .sftp ? 1 : 0, configuration.address,
                url.host!, url.port.map(Int32.init) ?? Int32(configuration.kind.defaultPort), configuration.rootPath,
                credentials.username, credentials.password, pin == nil ? nil : digest.bindMemory(to: UInt8.self).baseAddress)
        }
        guard pointer != nil else { throw FileServiceError.unavailable }
    }
    deinit { if let pointer { nvp_remote_destroy(pointer) } }
    func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let pointer = self.pointer { nvp_remote_destroy(pointer); self.pointer = nil }
                continuation.resume()
            }
        }
    }
    func execute(operation: Int32, path: String, relative: String, url: String, range: Range<Int64> = 0..<0) async throws -> TransferResponse {
        let cancellation = TransferCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response: TransferResponse = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard let pointer = self.pointer else { throw FileServiceError.unavailable }
                        var output = nvp_remote_result()
                        defer { nvp_remote_result_free(&output) }
                        let status = nvp_remote_execute(pointer, operation, path, url, range.lowerBound,
                            Int(range.upperBound - range.lowerBound), cancellation.pointer, &output)
                        switch status {
                        case 0: break
                        case 2: throw FileServiceError.authentication
                        case 3:
                            let fingerprint = withUnsafeBytes(of: output.host_sha256) { Data($0).base64EncodedString().replacingOccurrences(of: "=", with: "") }
                            throw FileServiceError.protocolFailure("SSH 主机指纹未确认或已更改。请向服务器管理员核对后填写：SHA256:" + fingerprint)
                        case 4: throw FileServiceError.path(relative)
                        case 5: throw FileServiceError.permission(relative)
                        case 6: throw FileServiceError.protocolFailure("文件服务器响应无效或超出读取上限")
                        case 7: throw CancellationError()
                        default: throw FileServiceError.network("无法完成文件传输，请检查地址、端口和服务器状态")
                        }
                        let entries = try (0..<output.count).map { index -> FileEntry in
                            let entry = output.entries![index]
                            guard let namePointer = entry.name, let name = String(validatingCString: namePointer) else {
                                throw FileServiceError.protocolFailure("文件名不是有效的 UTF-8")
                            }
                            return .init(path: operation == 1 ? relative : try FileServicePath.join(relative, name),
                                name: operation == 1 ? (relative as NSString).lastPathComponent : name,
                                isDirectory: entry.directory != 0, isSymbolicLink: entry.symlink != 0,
                                size: entry.size, modifiedAt: entry.modified > 0 ? Date(timeIntervalSince1970: Double(entry.modified)) : nil)
                        }
                        continuation.resume(returning: .init(data: output.data.map { Data(bytes: $0, count: output.size) } ?? Data(),
                            entries: entries, mlsd: output.listing_is_mlsd != 0))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return response
        } onCancel: { cancellation.cancel() }
    }
}

public actor RemoteTransferClient: FileServiceClient {
    private let configuration: FileServiceConfiguration
    private let connection: TransferConnection
    public init(configuration: FileServiceConfiguration, credentials: FileServiceCredentials) throws {
        self.configuration = try configuration.validated()
        guard [.ftp, .sftp].contains(configuration.kind),
              credentials.username.rangeOfCharacter(from: CharacterSet(charactersIn: "\0\r\n")) == nil,
              credentials.password.rangeOfCharacter(from: CharacterSet(charactersIn: "\0\r\n")) == nil else {
            throw FileServiceError.invalidConfiguration("无效的 FTP / SFTP 配置")
        }
        if configuration.kind == .sftp && credentials.username.isEmpty { throw FileServiceError.authentication }
        connection = try TransferConnection(configuration: self.configuration, credentials: credentials)
    }
    public func connect() async throws { _ = try await list(path: "/", cursor: nil) }
    public func disconnect() async { await connection.close() }
    private func request(_ operation: Int32, path: String, range: Range<Int64> = 0..<0) async throws -> TransferResponse {
        let relative = try FileServicePath.normalize(path)
        let full = try FileServicePath.join(configuration.rootPath, relative)
        var url = URLComponents(string: configuration.address)!
        // FTP's double slash addresses the server's absolute root rather than the login directory.
        url.path = "/" + full + (operation == 0 && !full.hasSuffix("/") ? "/" : "")
        guard let address = url.url?.absoluteString else { throw FileServiceError.path(path) }
        return try await connection.execute(operation: operation, path: full, relative: relative, url: address, range: range)
    }
    public func list(path: String, cursor: String?) async throws -> FileEntryPage {
        guard cursor == nil else { throw FileServiceError.protocolFailure("无效的目录分页") }
        let result = try await request(0, path: path)
        if configuration.kind == .sftp { return .init(entries: result.entries) }
        return .init(entries: try FTPDirectoryListing.parse(result.data, path: path, mlsd: result.mlsd))
    }
    public func stat(path: String) async throws -> FileEntry {
        let normalized = try FileServicePath.normalize(path)
        if configuration.kind == .sftp {
            guard let entry = try await request(1, path: normalized).entries.first else { throw FileServiceError.path(path) }
            return entry
        }
        if normalized == "/" { _ = try await list(path: "/", cursor: nil); return .init(path: "/", name: "/", isDirectory: true) }
        guard let entry = try await list(path: FileServicePath.parent(normalized), cursor: nil).entries.first(where: { $0.path == normalized }) else {
            throw FileServiceError.path(path)
        }
        return entry
    }
    public func read(path: String, range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound - range.lowerBound <= 4 * 1024 * 1024 else {
            throw FileServiceError.protocolFailure("单次文件读取不能超过 4 MiB")
        }
        if range.isEmpty { return Data() }
        return try await request(2, path: path, range: range).data
    }
    public func resolve(path: String) async throws -> ResolvedFileResource {
        throw FileServiceError.protocolFailure("FTP / SFTP 通过本机范围读取代理播放")
    }
}

enum FTPDirectoryListing {
    static func parse(_ data: Data, path: String, mlsd: Bool) throws -> [FileEntry] {
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw FileServiceError.protocolFailure("目录列表过大或文件名不是 UTF-8")
        }
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "yyyyMMddHHmmss"
        var entries: [FileEntry] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            if line.isEmpty || (!mlsd && line.hasPrefix("total ")) { continue }
            let entry: FileEntry?
            if mlsd {
                guard let separator = line.firstIndex(of: " ") else { throw invalidListing }
                let facts = line[..<separator].split(separator: ";").reduce(into: [String: String]()) { result, fact in
                    let parts = fact.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 { result[String(parts[0]).lowercased()] = String(parts[1]) }
                }
                let type = facts["type"]?.lowercased() ?? ""
                if type == "cdir" || type == "pdir" { continue }
                let name = String(line[line.index(after: separator)...])
                guard validName(name), !type.isEmpty else { throw invalidListing }
                entry = .init(path: try FileServicePath.join(path, name), name: name,
                    isDirectory: type == "dir", isSymbolicLink: type.contains("slink") || facts["unix.slink"] != nil,
                    size: try size(facts["size"]), modifiedAt: facts["modify"].flatMap { date.date(from: String($0.prefix(14))) })
            } else {
                entry = try parseLegacy(line, path: path)
            }
            if let entry { entries.append(entry) }
            guard entries.count <= 20_000 else { throw invalidListing }
        }
        return entries
    }
    private static var invalidListing: FileServiceError { .protocolFailure("无法识别 FTP 目录列表；服务器需支持 MLSD 或标准 UNIX / DOS LIST") }
    private static func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0") }
    private static func size(_ value: String?) throws -> Int64 {
        guard let value else { return 0 }
        guard let count = Int64(value), count >= 0 else { throw invalidListing }
        return count
    }
    private static func parseLegacy(_ line: String, path: String) throws -> FileEntry? {
        let unix = try NSRegularExpression(pattern: #"^([bcdlps-][^\s]*)\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\d+\s+\S+\s+(.+)$"#)
        let dos = try NSRegularExpression(pattern: #"^\d{2}-\d{2}-\d{2,4}\s+\d{2}:\d{2}(?:AM|PM)\s+(<DIR>|\d+)\s+(.+)$"#, options: .caseInsensitive)
        let full = NSRange(line.startIndex..., in: line)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String { String(line[Range(match.range(at: index), in: line)!]) }
        var name: String, directory: Bool, link = false, length: Int64
        if let match = unix.firstMatch(in: line, range: full) {
            let mode = group(match, 1); directory = mode.hasPrefix("d"); link = mode.hasPrefix("l")
            name = group(match, 3); if link, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            length = try size(group(match, 2))
        } else if let match = dos.firstMatch(in: line, range: full) {
            directory = group(match, 1).uppercased() == "<DIR>"; length = directory ? 0 : try size(group(match, 1)); name = group(match, 2)
        } else { throw invalidListing }
        if name == "." || name == ".." { return nil }
        guard validName(name) else { throw invalidListing }
        return .init(path: try FileServicePath.join(path, name), name: name, isDirectory: directory, isSymbolicLink: link, size: length)
    }
}
