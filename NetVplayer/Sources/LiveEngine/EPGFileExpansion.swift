import Foundation
import zlib

enum EPGFileExpansion {
    static func expandIfNeeded(input: URL, output: URL, maximumBytes: Int) throws -> URL {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        let header = try reader.read(upToCount: 2) ?? Data()
        guard header == Data([0x1f, 0x8b]) else {
            let size = (try input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maximumBytes else { throw EPGImportError.limitExceeded }
            return input
        }
        try reader.seek(toOffset: 0)
        try Data().write(to: output, options: .withoutOverwriting)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var inflater = z_stream()
        guard inflateInit2_(&inflater, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw EPGImportError.invalidGzip }
        defer { inflateEnd(&inflater) }
        var expanded = 0
        var ended = false
        let chunkSize = 64 * 1_024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while let inputChunk = try reader.read(upToCount: 64 * 1_024), !inputChunk.isEmpty {
            try Task.checkCancellation()
            guard !ended else { throw EPGImportError.invalidGzip }
            try inputChunk.withUnsafeBytes { bytes in
                inflater.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
                inflater.avail_in = uInt(inputChunk.count)
                repeat {
                    try Task.checkCancellation()
                    let status = buffer.withUnsafeMutableBytes { bytes -> Int32 in
                        inflater.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                        inflater.avail_out = uInt(chunkSize)
                        return inflate(&inflater, Z_NO_FLUSH)
                    }
                    let count = buffer.count - Int(inflater.avail_out)
                    guard count <= maximumBytes - expanded else { throw EPGImportError.limitExceeded }
                    if count > 0 { try writer.write(contentsOf: Data(buffer.prefix(count))); expanded += count }
                    if status == Z_STREAM_END {
                        guard inflater.avail_in == 0 else { throw EPGImportError.invalidGzip }
                        ended = true
                        break
                    }
                    if status == Z_BUF_ERROR, inflater.avail_in == 0, count == 0 { break }
                    guard status == Z_OK else { throw EPGImportError.invalidGzip }
                } while inflater.avail_in > 0 || inflater.avail_out == 0
            }
        }
        guard ended else { throw EPGImportError.invalidGzip }
        try writer.synchronize()
        return output
    }
}
