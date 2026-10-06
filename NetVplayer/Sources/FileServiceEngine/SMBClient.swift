import Foundation
@preconcurrency import AMSMB2
import Models
import Storage

protocol SMBSession: Sendable {
    func connect(share: String) async throws
    func disconnect() async
    func list(remotePath: String, relativePath: String) async throws -> [FileEntry]
    func stat(remotePath: String, relativePath: String) async throws -> FileEntry
    func read(path: String, range: Range<Int64>) async throws -> Data
}

private struct AMSMBSession: SMBSession {
    let manager: SMB2Manager
    func connect(share: String) async throws { try await manager.connectShare(name: share) }
    func disconnect() async { try? await manager.disconnectShare(gracefully: true) }
    func list(remotePath: String, relativePath: String) async throws -> [FileEntry] {
        let values = try await manager.contentsOfDirectory(atPath: remotePath, recursive: false)
        return try values.compactMap { item in
            guard let name = item[.nameKey] as? String, name != ".", name != "..", !name.contains("/") else { return nil }
            return FileEntry(path: try FileServicePath.join(relativePath, name), name: name,
                isDirectory: (item[.isDirectoryKey] as? NSNumber)?.boolValue ?? false,
                isSymbolicLink: (item[.isSymbolicLinkKey] as? NSNumber)?.boolValue ?? false,
                size: (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0, modifiedAt: item[.contentModificationDateKey] as? Date)
        }
    }
    func stat(remotePath: String, relativePath: String) async throws -> FileEntry {
        let item = try await manager.attributesOfItem(atPath: remotePath)
        return .init(path: relativePath, name: (relativePath as NSString).lastPathComponent,
            isDirectory: (item[.isDirectoryKey] as? NSNumber)?.boolValue ?? false,
            isSymbolicLink: (item[.isSymbolicLinkKey] as? NSNumber)?.boolValue ?? false,
            size: (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0, modifiedAt: item[.contentModificationDateKey] as? Date)
    }
    func read(path: String, range: Range<Int64>) async throws -> Data { try await manager.contents(atPath: path, range: range) }
}

public actor SMBClient: FileServiceClient {
    private let configuration: FileServiceConfiguration
    private let session: any SMBSession
    private let guestClient: SMBGuestClient?
    private var connected = false
    public init(configuration: FileServiceConfiguration, credentials: FileServiceCredentials = .init()) throws {
        let configuration = try configuration.validated(); self.configuration = configuration
        self.guestClient = configuration.guest ? try SMBGuestClient(configuration: configuration) : nil
        let login = URLCredential(user: configuration.guest ? "" : credentials.username,
                                  password: configuration.guest ? "" : credentials.password, persistence: .forSession)
        guard configuration.guest || !credentials.username.isEmpty else { throw FileServiceError.authentication }
        guard let manager = SMB2Manager(url: URL(string: configuration.address)!, domain: configuration.domain, credential: login) else {
            throw FileServiceError.invalidConfiguration("SMB 地址无效")
        }
        self.session = AMSMBSession(manager: manager)
    }
    init(configuration: FileServiceConfiguration, session: any SMBSession) throws {
        self.configuration = try configuration.validated(); self.session = session; self.guestClient = nil
    }
    private func fullPath(_ path: String) throws -> String { String(try FileServicePath.join(configuration.rootPath, path).dropFirst()) }
    private func ensureConnected(checkLiveness: Bool = false) async throws {
        if !connected || checkLiveness {
            // connectShare probes a cached session with SMB echo and reconnects after server timeouts.
            do { try await session.connect(share: configuration.share); connected = true }
            catch { connected = false; throw Self.translate(error, path: configuration.share, connecting: true) }
        }
    }
    public func connect() async throws {
        if let guestClient { try await guestClient.connect(); return }
        _ = try await list(path: "/", cursor: nil)
    }
    public func disconnect() async {
        if let guestClient { await guestClient.disconnect(); return }
        connected = false; await session.disconnect()
    }
    public func list(path: String, cursor: String?) async throws -> FileEntryPage {
        if let guestClient { return try await guestClient.list(path: path, cursor: cursor) }
        try Task.checkCancellation(); try await ensureConnected(checkLiveness: true)
        let remotePath = try fullPath(path)
        do {
            let entries = try await session.list(remotePath: remotePath, relativePath: path)
            return .init(entries: entries)
        } catch { throw Self.translate(error, path: "/" + remotePath) }
    }
    public func stat(path: String) async throws -> FileEntry {
        if let guestClient { return try await guestClient.stat(path: path) }
        try Task.checkCancellation(); try await ensureConnected(checkLiveness: true)
        let remotePath = try fullPath(path)
        do {
            return try await session.stat(remotePath: remotePath, relativePath: path)
        } catch { throw Self.translate(error, path: "/" + remotePath) }
    }
    public func read(path: String, range: Range<Int64>) async throws -> Data {
        if let guestClient { return try await guestClient.read(path: path, range: range) }
        guard range.lowerBound >= 0, range.count <= 4 * 1024 * 1024 else { throw FileServiceError.protocolFailure("SMB 单次读取超出上限") }
        try await ensureConnected(); try Task.checkCancellation()
        let remotePath = try fullPath(path)
        do {
            let data: Data
            do { data = try await session.read(path: remotePath, range: range) }
            catch {
                let underlying = error as NSError
                let dropped = [ENOTCONN, ECONNRESET, ECONNABORTED, EPIPE, ETIMEDOUT].map(Int.init)
                guard underlying.domain == NSPOSIXErrorDomain, dropped.contains(underlying.code) else { throw error }
                connected = false; try Task.checkCancellation(); try await ensureConnected()
                // Repeat the same bounded read once; healthy playback chunks do not each send an echo.
                data = try await session.read(path: remotePath, range: range)
            }
            try Task.checkCancellation(); return data
        } catch is CancellationError { throw CancellationError() }
        catch { throw Self.translate(error, path: "/" + remotePath) }
    }
    public func resolve(path: String) async throws -> ResolvedFileResource {
        throw FileServiceError.protocolFailure("SMB 资源需要通过范围读取代理播放")
    }
    static func translate(_ error: Error, path: String, connecting: Bool = false) -> Error {
        if error is CancellationError { return error }
        if let error = error as? FileServiceError { return error }
        let underlying = error as NSError
        guard underlying.domain == NSPOSIXErrorDomain else { return FileServiceError.network(error.localizedDescription) }
        switch underlying.code {
        case Int(EACCES), Int(EPERM):
            // Session login and share access can both fail with EACCES. Do not blame only the password.
            return connecting
                ? FileServiceError.protocolFailure(L10n.text("无法访问共享文件夹，请检查完整地址、账号密码，以及该账号是否有访问权限。"))
                : FileServiceError.permission(path)
        case Int(ENOENT), Int(ENOTDIR): return FileServiceError.path(path)
        default: return FileServiceError.network(error.localizedDescription)
        }
    }
}
