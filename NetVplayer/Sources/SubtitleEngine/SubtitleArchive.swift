import Foundation
import CoreFoundation
import zlib

/// Reads ZIP entries in memory. No archive path is ever written to disk.
public enum SubtitleArchive {
    public static let maximumDownloadBytes = 8 * 1024 * 1024
    public static let maximumFileBytes = 4 * 1024 * 1024
    public static let maximumExpandedBytes = 16 * 1024 * 1024

    public static func unpack(_ data: Data, filename: String) throws -> [DownloadedSubtitle] {
        guard !data.isEmpty, data.count <= maximumDownloadBytes else { throw OnlineSubtitleError.limitExceeded }
        if data.starts(with: [0x50, 0x4b]) { return try zip(data) }
        guard let subtitle = try text(data, filename: filename) else { throw OnlineSubtitleError.unsupportedArchive }
        return [subtitle]
    }

    private static func text(_ data: Data, filename: String) throws -> DownloadedSubtitle? {
        let format = (filename as NSString).pathExtension.lowercased()
        guard ["srt", "ass", "ssa", "vtt"].contains(format) else { return nil }
        guard !data.isEmpty, data.count <= maximumFileBytes else { throw OnlineSubtitleError.limitExceeded }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let decoded: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { decoded = String(data: data, encoding: .utf16) }
        else { decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb) }
        guard let decoded, !decoded.contains("\0") else { throw OnlineSubtitleError.invalidDownload }
        let value = decoded.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
        let valid: Bool
        switch format {
        case "ass", "ssa": valid = value.contains("[Events]") && value.contains("Dialogue:")
        case "vtt": valid = value.hasPrefix("WEBVTT") && value.contains("-->")
        default: valid = value.range(of: #"\d{1,2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{3}"#, options: .regularExpression) != nil
        }
        guard valid, !value.lowercased().hasPrefix("<!doctype"), !value.lowercased().hasPrefix("<html") else { throw OnlineSubtitleError.invalidDownload }
        let normalized = Data(decoded.utf8)
        guard normalized.count <= maximumFileBytes else { throw OnlineSubtitleError.limitExceeded }
        return DownloadedSubtitle(name: filename, format: format, data: normalized)
    }

    private static func zip(_ data: Data) throws -> [DownloadedSubtitle] {
        guard data.count >= 22 else { throw OnlineSubtitleError.invalidDownload }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else { throw OnlineSubtitleError.invalidDownload }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int { (try u16(offset)) | (try u16(offset + 2)) << 16 }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if (try u32(offset)) == 0x06054b50, offset + 22 + (try u16(offset + 20)) == data.count { end = offset; break }
        }
        guard let end, (try u16(end + 4)) == 0, (try u16(end + 6)) == 0,
              (try u16(end + 8)) == (try u16(end + 10)), (try u16(end + 10)) <= 64 else { throw OnlineSubtitleError.unsupportedArchive }
        let count = (try u16(end + 10)), directorySize = (try u32(end + 12))
        var cursor = (try u32(end + 16))
        let directoryStart = cursor
        let directoryEnd = cursor + directorySize
        guard directoryEnd == end else { throw OnlineSubtitleError.invalidDownload }
        var expanded = 0
        var result: [DownloadedSubtitle] = []
        var names = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor + 46 <= directoryEnd, (try u32(cursor)) == 0x02014b50 else { throw OnlineSubtitleError.invalidDownload }
            let flags = (try u16(cursor + 8)), method = (try u16(cursor + 10))
            let crc = (try u32(cursor + 16)), compressed = (try u32(cursor + 20)), size = (try u32(cursor + 24))
            let nameCount = (try u16(cursor + 28)), extra = (try u16(cursor + 30)), comment = (try u16(cursor + 32))
            let local = (try u32(cursor + 42)), unixMode = (try u32(cursor + 38)) >> 16
            let next = cursor + 46 + nameCount + extra + comment
            guard next <= directoryEnd, size <= maximumFileBytes, size <= maximumExpandedBytes - expanded,
                  compressed <= maximumDownloadBytes else { throw OnlineSubtitleError.limitExceeded }
            expanded += size
            guard flags & 1 == 0, [0, 8].contains(method), unixMode & 0xf000 != 0xa000,
                  let name = String(data: data[(cursor + 46)..<(cursor + 46 + nameCount)], encoding: .utf8),
                  !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.contains(":"),
                  !name.split(separator: "/").contains(".."), names.insert(name).inserted else { throw OnlineSubtitleError.unsupportedArchive }
            guard local + 30 <= directoryStart, (try u32(local)) == 0x04034b50, (try u16(local + 6)) == flags, (try u16(local + 8)) == method,
                  (try u16(local + 26)) == nameCount else { throw OnlineSubtitleError.invalidDownload }
            let start = local + 30 + ((try u16(local + 26))) + ((try u16(local + 28)))
            guard start + compressed <= directoryStart, start >= 0,
                  data[(local + 30)..<(local + 30 + nameCount)] == data[(cursor + 46)..<(cursor + 46 + nameCount)] else { throw OnlineSubtitleError.invalidDownload }
            cursor = next
            guard !name.hasSuffix("/"), ["srt", "ass", "ssa", "vtt"].contains((name as NSString).pathExtension.lowercased()) else { continue }
            let payload = Data(data[start..<(start + compressed)])
            let contents = method == 0 ? payload : try inflateRaw(payload, size: size)
            guard contents.count == size else { throw OnlineSubtitleError.invalidDownload }
            let actualCRC = contents.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(contents.count)) }
            guard actualCRC == UInt(crc) else { throw OnlineSubtitleError.invalidDownload }
            if let subtitle = try text(contents, filename: name) {
                guard subtitle.data.count <= maximumExpandedBytes - result.reduce(0, { $0 + $1.data.count }) else { throw OnlineSubtitleError.limitExceeded }
                result.append(subtitle)
            }
        }
        guard cursor == directoryEnd, !result.isEmpty else { throw OnlineSubtitleError.unsupportedArchive }
        return result
    }

    private static func inflateRaw(_ data: Data, size: Int) throws -> Data {
        guard size > 0, size <= maximumFileBytes else { throw OnlineSubtitleError.invalidDownload }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw OnlineSubtitleError.invalidDownload }
        defer { inflateEnd(&stream) }
        var output = Data(count: size)
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(size)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.avail_in == 0 else { throw OnlineSubtitleError.invalidDownload }
        return output
    }
}
