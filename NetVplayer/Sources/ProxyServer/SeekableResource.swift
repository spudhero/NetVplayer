import Foundation
import Models

public struct SeekableResource: Sendable {
    public let size: Int64
    public let contentType: String
    public let readChunkSize: Int64
    public let transferProfile: PlaybackTransferProfile?
    public let read: @Sendable (Range<Int64>) async throws -> Data
    public init(size: Int64, contentType: String = "application/octet-stream", readChunkSize: Int64 = 512 * 1024,
                transferProfile: PlaybackTransferProfile? = nil,
                read: @escaping @Sendable (Range<Int64>) async throws -> Data) {
        self.size = size; self.contentType = contentType; self.read = read
        self.readChunkSize = max(1, min(readChunkSize, 4 * 1024 * 1024))
        self.transferProfile = transferProfile
    }
}

public enum SeekableRange {
    public static func parse(_ header: String?, size: Int64) -> Range<Int64>? {
        guard size >= 0 else { return nil }
        guard let header else { return 0..<size }
        guard header.hasPrefix("bytes="), !header.contains(","), size > 0 else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            return max(0, size - min(suffix, size))..<size
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { return nil }
        if parts[1].isEmpty { return start..<size }
        guard let end = Int64(parts[1]), end >= start else { return nil }
        return start..<(min(end, size - 1) + 1)
    }
}
