import Foundation
import Models

public final class LocalDirectoryClient: FileServiceClient, @unchecked Sendable {
    private let folder: URL
    private let root: URL
    private let hasScope: Bool
    private let lock = NSLock()
    private var closed = false
    public init(bookmark: Data, rootPath: String = "/") throws {
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        guard !stale else { throw FileServiceError.authorizationExpired }
        self.folder = folder
        self.hasScope = folder.startAccessingSecurityScopedResource()
        self.root = folder.appendingPathComponent(String(try FileServicePath.normalize(rootPath).dropFirst()), isDirectory: true)
        // Non-sandboxed builds can already access the URL even when startAccessing returns false.
        guard FileManager.default.isReadableFile(atPath: root.path) else {
            if hasScope { folder.stopAccessingSecurityScopedResource() }
            throw FileServiceError.authorizationExpired
        }
    }
    public init(folder: URL) throws {
        self.folder = folder; self.root = folder
        self.hasScope = folder.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: folder.path) else {
            if hasScope { folder.stopAccessingSecurityScopedResource() }
            throw FileServiceError.authorizationExpired
        }
    }
    deinit { close() }
    private func close() {
        lock.withLock { if !closed { closed = true; if hasScope { folder.stopAccessingSecurityScopedResource() } } }
    }
    public func disconnect() async { close() }
    private func url(_ path: String) throws -> URL {
        guard !lock.withLock({ closed }) else { throw FileServiceError.unavailable }
        let candidate = root.appendingPathComponent(String(try FileServicePath.normalize(path).dropFirst()))
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == base || resolved.hasPrefix(base + "/") else { throw FileServiceError.permission(path) }
        return candidate
    }
    public func connect() async throws { _ = try await list(path: "/", cursor: nil) }
    public func list(path: String, cursor: String?) async throws -> FileEntryPage {
        try Task.checkCancellation()
        let target = try url(path)
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: target,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            return FileEntryPage(entries: try urls.map { child in
                try entry(url: child, path: FileServicePath.join(path, child.lastPathComponent))
            })
        } catch { throw FileServiceError.permission(path) }
    }
    private func entry(url: URL, path: String) throws -> FileEntry {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        return FileEntry(path: path, name: url.lastPathComponent, isDirectory: values.isDirectory ?? false,
                         isSymbolicLink: values.isSymbolicLink ?? false, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate)
    }
    public func stat(path: String) async throws -> FileEntry { try entry(url: url(path), path: path) }
    public func read(path: String, range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.count <= 4 * 1024 * 1024 else { throw FileServiceError.protocolFailure("单次读取超出上限") }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url(path)); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: Int(range.count)) ?? Data()
    }
    public func resolve(path: String) async throws -> ResolvedFileResource { .init(url: try url(path)) }
}
