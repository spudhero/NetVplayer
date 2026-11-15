import Foundation
import Models
import ProxyServer

/// Some SDK responses replace an encrypted sample entry with avc1 even when
/// its codec configuration is HEVC. Repair only that structural contradiction.
enum DevelopmentAndroidMP4CodecRepair {
    static func accepts(_ raw: String, site: Site, binding: DevelopmentAndroidRuntimeManifest.Binding,
                        policy: AndroidCompatibilityPolicy? = nil) -> Bool {
        guard binding.key == site.key, binding.api == site.api else { return false }
        return policy?.repairsMedia(raw, key: site.key, api: site.api, className: binding.className) == true
    }

    static func probe(_ raw: String, headers: [String: String]) async throws -> [Int64] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try DevelopmentAndroidHLSRemoteTransport.validate(raw), timeoutInterval: 15)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
                  http.mimeType == "video/mp4",
                  http.statusCode != 206 || http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-") == true else { return [] }
            var prefix = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                prefix.append(byte)
                if prefix.count == 65536 { break }
            }
            return offsets(in: prefix)
        } onCancel: { session.invalidateAndCancel() }
    }

    static func offsets(in prefix: Data) -> [Int64] {
        let bytes = [UInt8](prefix)
        func integer(_ at: Int) -> Int {
            bytes[at..<at + 4].reduce(0) { $0 * 256 + Int($1) }
        }
        func tag(_ at: Int) -> String { String(bytes: bytes[at..<at + 4], encoding: .ascii) ?? "" }
        guard bytes.count >= 12, tag(4) == "ftyp", integer(0) >= 8, integer(0) <= bytes.count else { return [] }
        var patches: [Int64] = []
        func walk(_ start: Int, _ end: Int, _ depth: Int, _ parent: String) {
            guard depth <= 8 else { return }
            var pos = start
            while pos <= end - 8, pos <= bytes.count - 8 {
                let size = integer(pos)
                guard size >= 8, size <= end - pos else { return }
                let type = tag(pos + 4), boxEnd = pos + size
                let parents = ["moov": "root", "trak": "moov", "mdia": "trak", "minf": "mdia", "stbl": "minf"]
                if parents[type] == parent {
                    walk(pos + 8, boxEnd, depth + 1, type)
                } else if type == "stsd", parent == "stbl", size >= 16, pos <= bytes.count - 16 {
                    walk(pos + 16, boxEnd, depth + 1, type)
                } else if type == "avc1", parent == "stsd", size >= 86, boxEnd <= bytes.count {
                    var child = pos + 86, hevc = false, avc = false, valid = true
                    while child < boxEnd {
                        guard child <= boxEnd - 8 else { valid = false; break }
                        let length = integer(child)
                        guard length >= 8, length <= boxEnd - child else { valid = false; break }
                        let kind = tag(child + 4)
                        if kind == "hvcC", length >= 31, bytes[child + 8] == 1 { hevc = true }
                        if kind == "avcC" { avc = true }
                        child += length
                    }
                    if valid && hevc && !avc { patches.append(Int64(pos + 4)) }
                }
                pos = boxEnd
            }
        }
        // Fast-start moov may be larger than the bounded prefix. Descendants
        // still use declared parent bounds, but sample entries must be complete.
        walk(0, Int(UInt32.max), 0, "root")
        return patches
    }

    static func apply(_ data: Data, at start: Int64, offsets: [Int64]) -> Data {
        var output = data
        let replacement = Array("hvc1".utf8)
        for offset in offsets {
            for i in 0..<4 {
                let relative = offset + Int64(i) - start
                if relative >= 0 && relative < Int64(output.count) {
                    output[output.startIndex + Int(relative)] = replacement[i]
                }
            }
        }
        return output
    }
}

actor DevelopmentAndroidMP4CodecRepairStream {
    private let offsets: [Int64]
    private var position: Int64?
    init(offsets: [Int64]) { self.offsets = offsets }

    func head(_ head: ProxyStreamingResponseHead) throws -> ProxyStreamingResponseHead {
        if head.statusCode == 200 { position = 0 }
        else if head.statusCode == 206 {
            let range = head.headers.first { $0.key.lowercased() == "content-range" }?.value ?? ""
            guard range.hasPrefix("bytes "), let start = Int64(range.dropFirst(6).split(separator: "-").first ?? ""), start >= 0 else {
                throw DevelopmentAndroidProxyManifest.unsupported()
            }
            position = start
        }
        return ProxyStreamingResponseHead(statusCode: head.statusCode, contentType: head.contentType,
            contentLength: head.contentLength,
            headers: head.headers.filter { !["etag", "content-md5", "digest"].contains($0.key.lowercased()) },
            closeConnection: head.closeConnection)
    }

    func body(_ data: Data) throws -> Data {
        guard let position else { return data }
        guard position <= Int64.max - Int64(data.count) else { throw DevelopmentAndroidProxyManifest.unsupported() }
        self.position = position + Int64(data.count)
        return DevelopmentAndroidMP4CodecRepair.apply(data, at: position, offsets: offsets)
    }
}
