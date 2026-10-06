import Foundation
import CSMBGuestBridge
import Models

private final class GuestSMBContext: @unchecked Sendable {
    var pointer: OpaquePointer?
    deinit { if let pointer { nv_smb_guest_destroy(pointer) } }
}

/// Guest connections use the libsmb2 revision bundled with AMSMB2 4.0.3, with SMB 3.02 / 2.1 negotiation.
actor SMBGuestClient: FileServiceClient {
    private let configuration: FileServiceConfiguration
    private let context = GuestSMBContext()
    init(configuration: FileServiceConfiguration) throws { self.configuration = try configuration.validated() }
    private func fullPath(_ path: String) throws -> String { String(try FileServicePath.join(configuration.rootPath, path).dropFirst()) }
    private func connected() throws -> OpaquePointer {
        if let pointer = context.pointer { return pointer }
        try Task.checkCancellation()
        let url = URL(string: configuration.address)!
        let server = url.host! + (url.port.map { ":\($0)" } ?? "")
        guard let pointer = nv_smb_guest_create() else { throw FileServiceError.network("无法创建 SMB 访客连接") }
        let result = nv_smb_guest_connect(pointer, server, configuration.share, configuration.domain)
        guard result == 0 else {
            let error = failure(pointer, code: result, path: configuration.share, authenticating: true)
            nv_smb_guest_destroy(pointer); throw error
        }
        context.pointer = pointer; return pointer
    }
    func connect() async throws { _ = try await list(path: "/", cursor: nil) }
    func disconnect() async {
        if let pointer = context.pointer { context.pointer = nil; nv_smb_guest_destroy(pointer) }
    }
    func list(path: String, cursor: String?) async throws -> FileEntryPage {
        try Task.checkCancellation()
        let pointer = try connected()
        guard let directory = nv_smb_guest_opendir(pointer, try fullPath(path)) else { throw failure(pointer, path: path) }
        defer { nv_smb_guest_closedir(pointer, directory) }
        var entries: [FileEntry] = []; var info = NVSMBGuestStat()
        while let raw = nv_smb_guest_readdir(pointer, directory, &info) {
            try Task.checkCancellation()
            let name = String(cString: raw)
            if name == "." || name == ".." || name.contains("/") { continue }
            entries.append(entry(path: try FileServicePath.join(path, name), name: name, stat: info))
        }
        return .init(entries: entries)
    }
    func stat(path: String) async throws -> FileEntry {
        try Task.checkCancellation()
        let pointer = try connected(); var info = NVSMBGuestStat()
        let result = nv_smb_guest_stat(pointer, try fullPath(path), &info)
        guard result == 0 else { throw failure(pointer, code: result, path: path) }
        return entry(path: path, name: (path as NSString).lastPathComponent, stat: info)
    }
    func read(path: String, range: Range<Int64>) async throws -> Data {
        guard !range.isEmpty, range.lowerBound >= 0, range.count <= 4 * 1024 * 1024 else { throw FileServiceError.protocolFailure("SMB 单次读取超出上限") }
        try Task.checkCancellation()
        let pointer = try connected()
        let remotePath = try fullPath(path)
        var bytes = Data(count: range.count)
        let result = bytes.withUnsafeMutableBytes { buffer in
            nv_smb_guest_read(pointer, remotePath, buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(range.count), UInt64(range.lowerBound))
        }
        guard result >= 0 else { throw failure(pointer, code: result, path: path) }
        bytes.count = Int(result); try Task.checkCancellation(); return bytes
    }
    func resolve(path: String) async throws -> ResolvedFileResource { throw FileServiceError.protocolFailure("SMB 资源需要通过范围读取代理播放") }
    private func entry(path: String, name: String, stat: NVSMBGuestStat) -> FileEntry {
        .init(path: path, name: name, isDirectory: stat.kind == 1, isSymbolicLink: stat.kind == 2, size: Int64(clamping: stat.size),
              modifiedAt: Date(timeIntervalSince1970: Double(stat.modified_seconds) + Double(stat.modified_nanoseconds) / 1_000_000_000))
    }
    private func failure(_ pointer: OpaquePointer, code: Int32 = -1, path: String, authenticating: Bool = false) -> FileServiceError {
        let message = String(cString: nv_smb_guest_error(pointer))
        let number = abs(code)
        if number == EACCES || number == EPERM {
            return authenticating
                ? .protocolFailure(L10n.text("无法使用访客连接，请检查完整地址，并确认共享文件夹允许访客访问。"))
                : .permission(path)
        }
        if number == ENOENT || number == ENOTDIR || message.localizedCaseInsensitiveContains("STATUS_OBJECT_NAME_NOT_FOUND") { return .path(path) }
        return .network(message)
    }
}
