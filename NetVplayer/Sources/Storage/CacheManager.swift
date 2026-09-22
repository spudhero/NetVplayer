// Storage/CacheManager.swift
// Namespaced, reproducible cache storage.

import Foundation

public enum CacheNamespace: String, CaseIterable, Sendable {
    case posters = "Posters-v2"
}

public struct DiskCacheSnapshot: Sendable, Equatable {
    public var posterBytes: Int64
    public var networkBytes: Int64

    public init(posterBytes: Int64, networkBytes: Int64) {
        self.posterBytes = max(0, posterBytes)
        self.networkBytes = max(0, networkBytes)
    }

    public var totalBytes: Int64 { posterBytes + networkBytes }
}

public final class CacheManager: @unchecked Sendable {

    public static let shared = CacheManager()

    private let fileManager: FileManager
    private let cacheDirectory: URL

    public init(cacheDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.cacheDirectory = caches.appendingPathComponent("NetVplayer", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    public func directory(for namespace: CacheNamespace) -> URL {
        let directory = cacheDirectory.appendingPathComponent(namespace.rawValue, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func size(for namespace: CacheNamespace) -> Int64 {
        directorySize(directory(for: namespace))
    }

    public func diskSnapshot(networkBytes: Int64 = Int64(URLCache.shared.currentDiskUsage)) -> DiskCacheSnapshot {
        DiskCacheSnapshot(posterBytes: size(for: .posters), networkBytes: networkBytes)
    }

    /// Returns managed, reproducible disk caches only. Feedback and user data are excluded.
    public func cacheSize() -> Int64 {
        CacheNamespace.allCases.reduce(0) { $0 + size(for: $1) }
    }

    public func clear(_ namespace: CacheNamespace) throws {
        let directory = cacheDirectory.appendingPathComponent(namespace.rawValue, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func clearCache() throws {
        for namespace in CacheNamespace.allCases {
            try clear(namespace)
        }
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var size: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
            ), values.isRegularFile == true else { continue }
            size += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return size
    }
}

public extension Notification.Name {
    static let netVplayerCacheDidChange = Notification.Name("NetVplayerCacheDidChange")
}
