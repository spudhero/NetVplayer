import Models
import Foundation
import Darwin

public enum ProviderMaintenanceMode: String, Codable, Sendable { case obsoleteVersions, uninstall }
public struct ProviderMaintenancePlan: Codable, Sendable, Identifiable {
    public let id: UUID
    public let mode: ProviderMaintenanceMode
    public let bytes: Int64
    public let paths: [String]
    let snapshots: [String: [ProviderFileIdentity]]
    let rootIdentity: ProviderFileIdentity
}
public struct ProviderStorageUsage: Sendable {
    public let componentBytes: Int64
    public let stateBytes: Int64
    public let obsoleteBytes: Int64
    public let pendingRecovery: Bool
}
public enum ProviderMaintenanceError: Error, LocalizedError {
    case busy, changed, expired, unsafe, pending, processRunning
    public var errorDescription: String? {
        switch self {
        case .busy: L10n.text("播放扩展正在使用或更新，请稍后重试。")
        case .changed: L10n.text("组件文件已改变，请重新生成清理计划。")
        case .expired: L10n.text("清理计划已过期，请重新确认。")
        case .unsafe: L10n.text("无法确认组件目录归属，已保留文件。")
        case .pending: L10n.text("有未完成的组件维护，请先恢复。")
        case .processRunning: L10n.text("播放扩展尚未退出，未删除任何组件。")
        }
    }
}

struct ProviderFileIdentity: Codable, Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modified: Int64
    let nanos: Int64
    let mode: UInt16
    let blocks: Int64
}

/// Synchronous under the package-store actor. Journals and quarantine are app-owned.
final class ProviderMaintenance {
    private let root: URL
    private let planLifetime: Duration
    private let fm = FileManager.default
    private var prepared: (ProviderMaintenancePlan, ContinuousClock.Instant)?
    var checkpoint: (String) throws -> Void = { _ in }
    init(root: URL, planLifetime: Duration = .seconds(120)) {
        self.root = root.standardizedFileURL
        self.planLifetime = planLifetime
    }
    private var journalRoot: URL { root.appendingPathComponent(".maintenance", isDirectory: true) }
    struct Journal: Codable {
        var plan: ProviderMaintenancePlan
        var committed: Bool
    }

    static func validComponent(_ part: String) -> Bool {
        !part.isEmpty && !part.hasPrefix(".") && part.utf8.count < 200
            && part.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }

    private func identity(_ url: URL, relative: String) throws -> ProviderFileIdentity {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFDIR || (value.st_mode & S_IFMT) == S_IFREG,
              (value.st_mode & S_IFMT) == S_IFDIR || value.st_nlink == 1 else { throw ProviderMaintenanceError.unsafe }
        return ProviderFileIdentity(path: relative, device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
            size: value.st_size, modified: Int64(value.st_mtimespec.tv_sec), nanos: Int64(value.st_mtimespec.tv_nsec),
            mode: value.st_mode, blocks: Int64(value.st_blocks))
    }

    private func validateRoot() throws -> ProviderFileIdentity {
        guard root.resolvingSymlinksInPath().path == root.path else { throw ProviderMaintenanceError.unsafe }
        let record = try identity(root, relative: ".")
        guard record.mode & S_IFMT == S_IFDIR else { throw ProviderMaintenanceError.unsafe }
        return record
    }

    private func target(_ path: String, under parent: URL? = nil) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy(Self.validComponent) else { throw ProviderMaintenanceError.unsafe }
        let base = parent ?? root
        let folder = base.appendingPathComponent(parts[0])
        if fm.fileExists(atPath: folder.path) { _ = try identity(folder, relative: parts[0]) }
        return folder.appendingPathComponent(parts[1])
    }

    func snapshot(_ path: String, under parent: URL? = nil) throws -> [ProviderFileIdentity] {
        let url = try target(path, under: parent)
        var result: [ProviderFileIdentity] = []
        func visit(_ item: URL, _ relative: String) throws {
            let record = try identity(item, relative: relative)
            result.append(record)
            if record.mode & S_IFMT == S_IFDIR {
                for name in try fm.contentsOfDirectory(atPath: item.path).sorted() {
                    guard name != ".", name != "..", !name.contains("/") else { throw ProviderMaintenanceError.unsafe }
                    try visit(item.appendingPathComponent(name), relative + "/" + name)
                }
            }
        }
        try visit(url, path)
        return result
    }

    func hasPending() -> Bool { (try? fm.contentsOfDirectory(atPath: journalRoot.path).isEmpty) == false }
    func requireReady() throws { if hasPending() { throw ProviderMaintenanceError.pending } }

    func prepare(paths: [String], mode: ProviderMaintenanceMode, guards: [String] = [], remember: Bool = true) throws -> ProviderMaintenancePlan {
        try requireReady()
        let identity = try validateRoot()
        var snapshots = try Dictionary(uniqueKeysWithValues: paths.sorted().map { ($0, try snapshot($0)) })
        for path in guards where snapshots[path] == nil {
            snapshots[path] = fm.fileExists(atPath: try target(path).path) ? try snapshot(path) : []
        }
        var bytes: Int64 = 0
        for path in paths {
            for file in snapshots[path] ?? [] where file.mode & UInt16(S_IFMT) == UInt16(S_IFREG) {
                bytes += file.blocks * 512
            }
        }
        let plan = ProviderMaintenancePlan(id: UUID(), mode: mode, bytes: bytes, paths: paths.sorted(), snapshots: snapshots, rootIdentity: identity)
        if remember { prepared = (plan, ContinuousClock.now) }
        return plan
    }

    func execute(id: UUID) throws -> Bool {
        guard let (plan, instant) = prepared, id == plan.id,
              instant.duration(to: .now) < planLifetime else { throw ProviderMaintenanceError.expired }
        prepared = nil
        try requireReady()
        let current = try validateRoot()
        guard current.device == plan.rootIdentity.device, current.inode == plan.rootIdentity.inode else { throw ProviderMaintenanceError.changed }
        for (path, expected) in plan.snapshots {
            if expected.isEmpty {
                guard !fm.fileExists(atPath: try target(path).path) else { throw ProviderMaintenanceError.changed }
            } else { guard try snapshot(path) == expected else { throw ProviderMaintenanceError.changed } }
        }
        guard !plan.paths.isEmpty else {
            if plan.mode == .uninstall {
                try Data("disabled-by-user".utf8).write(
                    to: root.appendingPathComponent(".disabled"),
                    options: .atomic
                )
            }
            return false
        }
        if fm.fileExists(atPath: journalRoot.path) { _ = try identity(journalRoot, relative: ".maintenance") }
        let transaction = journalRoot.appendingPathComponent(plan.id.uuidString)
        try fm.createDirectory(at: transaction, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let quarantine = transaction.appendingPathComponent("files")
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: false)
        var journal = Journal(plan: plan, committed: false)
        try write(journal, at: transaction)
        do {
            // Active markers are withdrawn before their packages.
            for path in ordered(plan.paths) {
                try checkpoint("move")
                let destination = try target(path, under: quarantine)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: target(path), to: destination)
            }
            try checkpoint("commit")
            journal.committed = true
            try write(journal, at: transaction)
        } catch {
            try? restore(journal, transaction: transaction)
            throw error
        }
        if plan.mode == .uninstall { try Data("disabled-by-user".utf8).write(to: root.appendingPathComponent(".disabled"), options: .atomic) }
        return !finish(journal, transaction: transaction)
    }

    func recover() throws {
        prepared = nil
        _ = try validateRoot()
        guard fm.fileExists(atPath: journalRoot.path) else { return }
        _ = try identity(journalRoot, relative: ".maintenance")
        for name in try fm.contentsOfDirectory(atPath: journalRoot.path).sorted() {
            guard UUID(uuidString: name) != nil else { throw ProviderMaintenanceError.unsafe }
            let transaction = journalRoot.appendingPathComponent(name)
            _ = try identity(transaction, relative: name)
            let journalURL = transaction.appendingPathComponent("journal.json")
            if !fm.fileExists(atPath: journalURL.path) {
                let contents = try fm.contentsOfDirectory(atPath: transaction.path)
                if contents == ["files"] {
                    let files = transaction.appendingPathComponent("files")
                    try validateEmptyDirectoryTree(files)
                    try removeEmptyDirectoryTree(files)
                } else if !contents.isEmpty { throw ProviderMaintenanceError.unsafe }
                guard rmdir(transaction.path) == 0 else { throw ProviderMaintenanceError.unsafe }
                continue
            }
            _ = try identity(journalURL, relative: "journal.json")
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            guard journal.plan.id.uuidString == name,
                  Set(journal.plan.paths).isSubset(of: Set(journal.plan.snapshots.keys)) else { throw ProviderMaintenanceError.unsafe }
            let identity = try validateRoot()
            guard identity.device == journal.plan.rootIdentity.device, identity.inode == journal.plan.rootIdentity.inode else { throw ProviderMaintenanceError.changed }
            for path in journal.plan.paths { _ = try target(path) }
            if journal.committed {
                if journal.plan.mode == .uninstall { try Data("disabled-by-user".utf8).write(to: root.appendingPathComponent(".disabled"), options: .atomic) }
                if !finish(journal, transaction: transaction) { throw ProviderMaintenanceError.pending }
            } else { try restore(journal, transaction: transaction) }
        }
    }

    private func ordered(_ paths: [String]) -> [String] {
        paths.sorted { ($0.hasSuffix("active-version") ? "0" : "1") + $0 < ($1.hasSuffix("active-version") ? "0" : "1") + $1 }
    }
    private func write(_ journal: Journal, at transaction: URL) throws {
        try JSONEncoder().encode(journal).write(to: transaction.appendingPathComponent("journal.json"), options: .atomic)
    }
    private func restore(_ journal: Journal, transaction: URL) throws {
        let quarantine = transaction.appendingPathComponent("files")
        _ = try identity(quarantine, relative: "files")
        for path in ordered(journal.plan.paths).reversed() {
            let source = try target(path, under: quarantine)
            if fm.fileExists(atPath: source.path) {
                guard try snapshot(path, under: quarantine) == journal.plan.snapshots[path] else { throw ProviderMaintenanceError.changed }
                try checkpoint("restore")
                try fm.moveItem(at: source, to: target(path))
            } else {
                guard try snapshot(path) == journal.plan.snapshots[path] else { throw ProviderMaintenanceError.changed }
            }
        }
        try removeTransactionScaffolding(transaction)
    }
    private func finish(_ journal: Journal, transaction: URL) -> Bool {
        do {
            let quarantine = transaction.appendingPathComponent("files")
            _ = try identity(quarantine, relative: "files")
            for path in journal.plan.paths {
                guard let records = journal.plan.snapshots[path], !records.isEmpty else { throw ProviderMaintenanceError.unsafe }
                for expected in records.reversed() {
                    guard expected.path == path || expected.path.hasPrefix(path + "/"),
                          !expected.path.split(separator: "/").contains("..") else { throw ProviderMaintenanceError.unsafe }
                    let url = quarantine.appendingPathComponent(expected.path)
                    var parent = url.deletingLastPathComponent()
                    while parent.path != quarantine.path {
                        if fm.fileExists(atPath: parent.path) { _ = try identity(parent, relative: "parent") }
                        parent.deleteLastPathComponent()
                    }
                    var state = stat()
                    if lstat(url.path, &state) != 0 {
                        guard errno == ENOENT else { throw ProviderMaintenanceError.unsafe }
                        continue
                    }
                    let current = try identity(url, relative: expected.path)
                    guard current.device == expected.device, current.inode == expected.inode, current.mode == expected.mode else { throw ProviderMaintenanceError.changed }
                    let directory = current.mode & S_IFMT == S_IFDIR
                    if !directory, current != expected { throw ProviderMaintenanceError.changed }
                    try checkpoint("delete")
                    // Never recursively remove a directory: unknown new contents block cleanup.
                    let status = directory ? rmdir(url.path) : unlink(url.path)
                    guard status == 0 else { throw ProviderMaintenanceError.pending }
                }
            }
            try removeTransactionScaffolding(transaction)
            return true
        } catch { return false }
    }

    private func removeTransactionScaffolding(_ transaction: URL) throws {
        let contents = Set(try fm.contentsOfDirectory(atPath: transaction.path))
        guard contents == ["files", "journal.json"] else {
            throw ProviderMaintenanceError.pending
        }
        let files = transaction.appendingPathComponent("files")
        try validateEmptyDirectoryTree(files)
        let journal = transaction.appendingPathComponent("journal.json")
        let record = try identity(journal, relative: "journal.json")
        guard record.mode & S_IFMT == S_IFREG, unlink(journal.path) == 0 else {
            throw ProviderMaintenanceError.pending
        }
        try removeEmptyDirectoryTree(files)
        guard rmdir(transaction.path) == 0 else { throw ProviderMaintenanceError.pending }
    }

    private func validateEmptyDirectoryTree(_ directory: URL) throws {
        let record = try identity(directory, relative: directory.lastPathComponent)
        guard record.mode & S_IFMT == S_IFDIR else { throw ProviderMaintenanceError.unsafe }
        for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
            guard ProviderMaintenance.validComponent(name) else { throw ProviderMaintenanceError.unsafe }
            let child = directory.appendingPathComponent(name)
            let childRecord = try identity(child, relative: name)
            guard childRecord.mode & S_IFMT == S_IFDIR else {
                throw ProviderMaintenanceError.pending
            }
            try validateEmptyDirectoryTree(child)
        }
    }

    private func removeEmptyDirectoryTree(_ directory: URL) throws {
        let record = try identity(directory, relative: directory.lastPathComponent)
        guard record.mode & S_IFMT == S_IFDIR else { throw ProviderMaintenanceError.unsafe }
        for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
            guard ProviderMaintenance.validComponent(name) else { throw ProviderMaintenanceError.unsafe }
            let child = directory.appendingPathComponent(name)
            let childRecord = try identity(child, relative: name)
            guard childRecord.mode & S_IFMT == S_IFDIR else {
                throw ProviderMaintenanceError.pending
            }
            try removeEmptyDirectoryTree(child)
        }
        guard rmdir(directory.path) == 0 else { throw ProviderMaintenanceError.pending }
    }
}
