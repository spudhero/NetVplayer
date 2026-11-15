import CryptoKit
import Foundation
import Models
import ProviderRuntime
import ProviderSDK

/// Opt-in observations of the real UI and audit operations. This observer never
/// issues Provider requests, warms caches, or serializes account/request values.
public enum DevelopmentAndroidLifecycleDiagnostics {
    public static var isEnabled: Bool {
        !(ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_DIAGNOSTIC_CAPTURE_ROOT"] ?? "").isEmpty
    }

    public enum Phase: String, Codable, Sendable {
        case configuration, homeStart, homeCache, homeFinish, categoryStart, categoryCache, categoryFinish, providerSession, providerRequest
    }

    public enum FailureStage: String, Codable, Sendable {
        case session, initialize, operation
    }

    /// Only structured identifiers and a digest leave the private error path.
    /// Provider diagnostics can contain URLs, opaque IDs and account values.
    public struct Failure: Codable, Sendable {
        public var stage: FailureStage
        public var code: String
        public var exceptionClass: String?
        public var messageSHA256: String

        public init(_ error: Error, stage: FailureStage) {
            self.stage = stage
            messageSHA256 = DevelopmentAndroidLifecycleDiagnostics.sha256(Data(String(describing: error).utf8))
            if let payload = error as? ProviderErrorPayload {
                code = Self.identifier(payload.code) ?? "provider_error"
                exceptionClass = payload.diagnostic.flatMap(Self.identifier)
            } else if let process = error as? ProviderProcessError {
                switch process {
                case .notRunning: code = "process_not_running"
                case .launchFailed: code = "process_launch_failed"
                case .writeFailed: code = "process_write_failed"
                case .invalidResponse: code = "process_invalid_response"
                case .duplicateRequest: code = "process_duplicate_request"
                case .timedOut: code = "process_timeout"
                case .canceled: code = "process_canceled"
                case .terminated: code = "process_terminated"
                case .invalidEnvironment: code = "process_invalid_environment"
                case .statePreparationFailed: code = "process_state_preparation_failed"
                }
            } else {
                code = error is CancellationError ? "canceled" : "host_error"
                exceptionClass = Self.identifier(String(reflecting: type(of: error)))
            }
        }

        private static func identifier(_ value: String) -> String? {
            guard value.utf8.count <= 160,
                  value.range(of: "^[A-Za-z_][A-Za-z0-9_.$]*$", options: .regularExpression) != nil else { return nil }
            return value
        }
    }

    public struct Event: Codable, Sendable {
        public var phase: Phase
        public var operation: String?
        public var outcome: String?
        public var siteSHA256: String?
        public var inputSHA256: String?
        public var siteConfigurationSHA256: String?
        public var resultSHA256: String?
        public var categorySHA256: String?
        public var androidCategoryPayload: Result.AndroidCategoryPayload?
        public var configurationGeneration: UInt64?
        public var catalogRevision: UInt64?
        public var contentGeneration: UInt64?
        public var requestSerial: UInt64?
        public var helperGeneration: UInt64?
        public var helperSession: String?
        public var persistentStateSHA256: String?
        public var cacheEpoch: UInt64?
        public var elapsedMS: Double?
        public var queueMS: Double?
        public var sessionMS: Double?
        public var initializeMS: Double?
        public var operationMS: Double?
        public var listItems: Int?
        public var categories: Int?
        public var artifactSHA256: [String: String]?
        public var failure: Failure?
        public var processID: Int32 = ProcessInfo.processInfo.processIdentifier
        public var uptime: Double = ProcessInfo.processInfo.systemUptime

        public init(_ phase: Phase, siteKey: String? = nil) {
            self.phase = phase
            siteSHA256 = siteKey.map { DevelopmentAndroidLifecycleDiagnostics.sha256(Data($0.utf8)) }
        }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whitespace and object-key ordering do not define a different config.
    /// Arrays and every value remain significant. Raw bytes are recorded too.
    public static func canonicalJSONSHA256(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return sha256(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]))
    }

    public static func record(_ event: Event) {
        guard isEnabled else { return }
        var event = event
        event.uptime = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONEncoder().encode(event) else { return }
        DevelopmentAndroidProxyDiagnostics.captureLifecycle(data)
    }
}
