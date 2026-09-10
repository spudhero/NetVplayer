import Foundation
import ProviderSDK

public final class ProviderDiagnosticJSONLWriter: @unchecked Sendable {
    public let fileURL: URL
    public let maximumBytes: Int
    public let archiveCount: Int

    private let lock = NSLock()

    public init(
        stateDirectoryURL: URL,
        maximumBytes: Int = 1_048_576,
        archiveCount: Int = 2
    ) {
        fileURL = stateDirectoryURL
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("provider-events.jsonl")
        self.maximumBytes = max(1, maximumBytes)
        self.archiveCount = max(0, archiveCount)
    }

    public func record(_ event: ProviderDiagnosticEvent) throws {
        let line = try ProviderDiagnostics.jsonLine(for: event)
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let existingBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if existingBytes > 0, existingBytes + line.count > maximumBytes {
            try rotate(fileManager: fileManager)
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func recordSafely(_ event: ProviderDiagnosticEvent) {
        do {
            try record(event)
        } catch {
            let message = "[ProviderDiagnostics] unable to record event: \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        }
    }

    private func rotate(fileManager: FileManager) throws {
        guard archiveCount > 0 else {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        for index in stride(from: archiveCount, through: 1, by: -1) {
            let destination = archiveURL(index: index)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            let source = index == 1 ? fileURL : archiveURL(index: index - 1)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    private func archiveURL(index: Int) -> URL {
        URL(fileURLWithPath: fileURL.path + ".\(index)")
    }
}
