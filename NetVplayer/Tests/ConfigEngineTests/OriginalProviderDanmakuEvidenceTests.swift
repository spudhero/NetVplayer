import CryptoKit
import DanmakuEngine
import Foundation
import Networking
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_ORIGINAL_DANMAKU_ONCE_DIR"] != nil))
struct OriginalProviderDanmakuEvidenceTests {
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func save(_ object: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: path, options: .withoutOverwriting)
    }
    @Test func freezeExactlySelectedOriginalProviderDanmakuResponseWithoutMediaHeaders() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_ORIGINAL_DANMAKU_ONCE_DIR"]), isDirectory: true)
        let request = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("request.private.json"))) as? [String: Any])
        let input = URL(fileURLWithPath: try #require(request["SDK_result_path"] as? String))
        let bytes = try Data(contentsOf: input)
        try #require(hash(bytes) == request["SDK_result_SHA256"] as? String)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let address = try #require(object["danmaku"] as? String)
        try #require(hash(Data(address.utf8)) == request["attachment_URL_SHA256"] as? String)
        try #require(URL(string: address)?.scheme == "https")
        let started = ProcessInfo.processInfo.systemUptime
        try save(["request_started": true, "monotonic_seconds": started, "HTTP_request_tasks_admitted": 1,
            "media_headers_forwarded": false, "SDK_initializations": 0, "SDK_business_calls": 0],
            to: root.appendingPathComponent("request-started.safe.json"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(session: session)
        do {
            // Matches loadProviderTrack: a fresh ephemeral client, no media header forwarding or proxy fallback.
            let response = try await client.getBounded(url: address, maximumBytes: DanmakuPayloadParser.maximumPayloadBytes,
                timeout: 12, allowsProxyFallback: false)
            try response.data.write(to: root.appendingPathComponent("response.body.private.bin"), options: .withoutOverwriting)
            try save(["status": response.statusCode, "headers": response.headers, "final_URL": response.finalURL?.absoluteString ?? ""],
                to: root.appendingPathComponent("response.private.json"))
            let payload = String(data: response.data, encoding: .utf8)
            let trimmed = payload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parsed = payload.map { DanmakuPayloadParser.parseWithDiagnostic(payload: $0, format: trimmed.hasPrefix("<") ? .xml : .json) }
            let cues = parsed?.cues ?? []
            try JSONEncoder().encode(cues).write(to: root.appendingPathComponent("cues.private.json"), options: .withoutOverwriting)
            let nonempty = parsed?.diagnostic.failureCategory == nil && !cues.isEmpty
            var result: [String: Any] = ["status": nonempty ? "original_provider_danmaku_nonempty" : "original_provider_danmaku_empty_or_unparseable",
                "HTTP_status": response.statusCode, "body_bytes": response.data.count, "body_SHA256": hash(response.data),
                "UTF8_decodable": payload != nil, "cue_count": cues.count,
                "HTTP_request_tasks_admitted": 1, "server_request_count_or_internal_retries_attested": false,
                "media_headers_forwarded": false, "fresh_ephemeral_session": true, "proxy_fallback_allowed": false,
                "maximum_bytes": DanmakuPayloadParser.maximumPayloadBytes, "timeout_seconds": 12,
                "SDK_initializations": 0, "SDK_business_calls": 0, "target_App_starts": 0, "phone_operations": 0,
                "full_loadProviderTrack_method_invoked": false, "renderer_or_phone_parity_proven": false,
                "elapsed_seconds": ProcessInfo.processInfo.systemUptime - started, "whole_plan_complete": false]
            if let parsed {
                result["parse_failure"] = parsed.diagnostic.failureCategory?.rawValue ?? "none"
                result["parsed_count"] = parsed.diagnostic.parsedCount
                result["truncated_count"] = parsed.diagnostic.truncatedCount
            } else { result["parse_failure"] = "invalidEncoding" }
            if let first = cues.first, let last = cues.last {
                result["first_cue_ms"] = first.timeMs; result["last_cue_ms"] = last.timeMs
            }
            try save(result, to: root.appendingPathComponent("outcome.safe.json"))
            #expect(nonempty, "Original selected provider attachment must contain actual parsed cues; empty remains a failure.")
        } catch {
            try save(["status": "original_provider_danmaku_request_failed", "error_type": String(reflecting: type(of: error)),
                "HTTP_request_tasks_admitted": 1, "original_URL_retried_by_driver": false,
                "SDK_business_calls": 0, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - started,
                "whole_plan_complete": false], to: root.appendingPathComponent("request-error.safe.json"))
            throw error
        }
    }
}
