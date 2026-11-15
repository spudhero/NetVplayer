import CryptoKit
import Foundation
import Models
import ProxyServer

/// The frozen Android HLS factory only considers {8,13,11,2,0,1,7}.
/// In particular WebP (18) cannot win over a successful TsExtractor sniff.
/// This adapter implements that TS input-position contract at the HLS boundary;
/// other media continue through the existing decoder without format forcing.
enum DevelopmentAndroidHLS {
    enum Role: String, Sendable { case playlist, segment, opaque }
    static let candidateTypes = [8, 13, 11, 2, 0, 1, 7]
    static let sniffBytes = 1504
    static let readFallbackBytes = 188 * 50

    // An open range at zero asks for the full representation. Any bounded,
    // suffix or nonzero range must retain its original byte coordinates.
    static func isWholeBodyRequest(_ range: String?) -> Bool {
        range == nil || range?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "bytes=0-"
    }

    static func isEntireResponse(_ head: ProxyStreamingResponseHead) -> Bool {
        let range = head.headers.first { $0.key.lowercased() == "content-range" }?.value
        if head.statusCode == 200 { return range == nil }
        guard head.statusCode == 206, let range else { return false }
        let fields = range.lowercased().split(separator: " ")
        guard fields.count == 2, fields[0] == "bytes" else { return false }
        let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int(parts[1]), total > 0 else { return false }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, bounds[0] == "0", let last = Int(bounds[1]), last == total - 1 else { return false }
        return head.contentLength == nil || head.contentLength == total
    }

    static func candidates(format: Int? = nil, contentType: Int? = nil, uri: Int? = nil) -> [Int] {
        var output: [Int] = []
        for type in [format, contentType, uri].compactMap({ $0 }) + candidateTypes {
            if candidateTypes.contains(type), !output.contains(type) { output.append(type) }
        }
        return output
    }

    /// mu3.c peeks the whole window before v3.N checks candidates 0...751.
    /// Short EOF is a failed sniff even if five sync bytes fit in that input.
    static func transportStreamOffset(_ bytes: Data) -> Int? {
        guard bytes.count >= sniffBytes else { return nil }
        let prefix = Array(bytes.prefix(sniffBytes))
        for offset in 0...751 {
            if (0..<5).allSatisfy({ prefix[offset + $0 * 188] == 0x47 }) { return offset }
        }
        return nil
    }

    struct Sniffer: Sendable {
        private(set) var prefix = Data()
        private(set) var decided = false
        private(set) var offset: Int?

        private var initialSniffDone = false
        private var nextFallbackOffset = 752

        mutating func consume(_ data: Data) -> Data {
            guard !decided else { return data }
            var consumed = min(max(0, sniffBytes - prefix.count), data.count)
            prefix.append(data.prefix(consumed))
            guard prefix.count >= sniffBytes else { return Data() }
            if !initialSniffDone {
                initialSniffDone = true
                offset = transportStreamOffset(prefix)
                // The original HLS factory retains TS when all sniffs fail. Its
                // read loop can skip a longer WebP wrapper. Support this observed
                // case only after verifying five TS sync points, never by URI.
                let webP = prefix.starts(with: Data("RIFF".utf8))
                    && prefix[8..<12] == Data("WEBP".utf8)
                    && [Data("VP8 ".utf8), Data("VP8L".utf8), Data("VP8X".utf8)].contains(Data(prefix[12..<16]))
                decided = offset != nil || !webP
            }
            if !decided {
                let count = min(readFallbackBytes - prefix.count, data.count - consumed)
                prefix.append(data.dropFirst(consumed).prefix(count))
                consumed += count
                let end = prefix.count - 4 * 188
                while nextFallbackOffset < end {
                    let candidate = nextFallbackOffset
                    nextFallbackOffset += 1
                    if (0..<5).allSatisfy({ prefix[candidate + $0 * 188] == 0x47 }) {
                        offset = candidate
                        decided = true
                        break
                    }
                }
                if prefix.count == readFallbackBytes { decided = true }
            }
            guard decided else { return Data() }
            var output = Data(prefix.dropFirst(offset ?? 0))
            output.append(data.dropFirst(consumed))
            return output
        }

        mutating func finish() -> Data {
            guard !decided else { return Data() }
            decided = true
            return prefix
        }
    }
}

/// Holds at most 1504 bytes for the initial sniff, or 9400 bytes for the verified
/// WebP/TS read fallback, before emitting the HTTP head. Keys, init data, encrypted
/// or byte-range segments never enter this bounded, cancellable advance path.
actor DevelopmentAndroidHLSStream {
    struct Observation: Sendable {
        var prefix: Data
        var bytes: Int
        var offset: Int?
        var complete: Bool
        var status: Int?
        var bodySHA256: String?
        var entireResponse = false
        var declaredBodyBytes: Int?
    }
    private let role: DevelopmentAndroidHLS.Role?
    private let headOnly: Bool
    private let rangeRequested: Bool
    private let sendHead: @Sendable (ProxyStreamingResponseHead) async throws -> Void
    private let sendBody: @Sendable (Data) async throws -> Void
    private let observe: @Sendable (Observation) -> Void
    private var pending: ProxyStreamingResponseHead?
    private var sniffer = DevelopmentAndroidHLS.Sniffer()
    private var sniffing = false
    private var prefix = Data()
    private var received = 0
    private var status: Int?
    private var entireResponse = false
    private var declaredBodyBytes: Int?
    private var digest: SHA256? = DevelopmentAndroidLifecycleDiagnostics.isEnabled ? SHA256() : nil

    init(role: DevelopmentAndroidHLS.Role?, headOnly: Bool, rangeRequested: Bool,
         sendHead: @escaping @Sendable (ProxyStreamingResponseHead) async throws -> Void,
         sendBody: @escaping @Sendable (Data) async throws -> Void,
         observe: @escaping @Sendable (Observation) -> Void = { _ in }) {
        self.role = role; self.headOnly = headOnly; self.rangeRequested = rangeRequested
        self.sendHead = sendHead; self.sendBody = sendBody; self.observe = observe
    }

    func head(_ head: ProxyStreamingResponseHead) async throws {
        try Task.checkCancellation()
        status = head.statusCode
        let encoded = head.headers.contains { $0.key.lowercased() == "content-encoding" && $0.value.lowercased() != "identity" }
        entireResponse = DevelopmentAndroidHLS.isEntireResponse(head)
        declaredBodyBytes = head.contentLength
        sniffing = role == .segment && !headOnly && !rangeRequested && entireResponse && !encoded
        if sniffing { pending = head } else { try await sendHead(head) }
    }

    func body(_ data: Data) async throws {
        try Task.checkCancellation()
        received += data.count
        digest?.update(data: data)
        prefix.append(data.prefix(max(0, DevelopmentAndroidHLS.sniffBytes - prefix.count)))
        guard !headOnly else { return }
        let output = sniffing ? sniffer.consume(data) : data
        if sniffing && sniffer.decided { try await emitHead() }
        if !output.isEmpty { try await sendBody(output) }
    }

    private func emitHead() async throws {
        guard var head = pending else { return }
        pending = nil
        if let offset = sniffer.offset {
            head = ProxyStreamingResponseHead(statusCode: 200, contentType: "video/mp2t",
                contentLength: head.contentLength.map { max(0, $0 - offset) },
                headers: head.headers.filter { !["content-length", "content-type", "etag", "content-md5", "digest", "accept-ranges", "content-range"].contains($0.key.lowercased()) },
                closeConnection: true)
            DiagnosticLog.write("[ANDROID_HLS_EXTRACTOR] type=11 peek=\(sniffer.prefix.count) input_advance=\(offset)")
        }
        try await sendHead(head)
    }

    func finish(complete: Bool = true) async throws {
        if sniffing && !sniffer.decided {
            let remaining = sniffer.finish()
            try await emitHead()
            if !remaining.isEmpty { try await sendBody(remaining) }
        }
        record(complete: complete)
    }

    private func record(complete: Bool) {
        let evidencePrefix = (sniffer.offset ?? 0) >= 752 ? sniffer.prefix : prefix
        observe(Observation(prefix: evidencePrefix, bytes: received, offset: sniffer.offset, complete: complete,
            status: status, bodySHA256: digest.map { $0.finalize().map { String(format: "%02x", $0) }.joined() },
            entireResponse: entireResponse, declaredBodyBytes: declaredBodyBytes))
    }

    func failed() { record(complete: false) }
}
