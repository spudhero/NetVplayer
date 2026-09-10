// Storage/CacheManager.swift
// 缓存管理器

import Foundation

/// 缓存管理器
public final class CacheManager: @unchecked Sendable {

    public static let shared = CacheManager()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    public init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("NetVplayer", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// 获取缓存大小（字节）
    public func cacheSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var size: Int64 = 0
        for case let url as URL in enumerator {
            if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }

    /// 清理所有缓存
    public func clearCache() throws {
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
}
