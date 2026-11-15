import Foundation

/// A process-wide source routing preference. A restart keeps opaque category,
/// detail and episode IDs on the implementation that created them.
public enum ProviderExecutionPreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case macPreferred
    case androidPreferred

    public static let storageKey = "providerExecutionPreference.v1"
}

public enum ProviderExecutionBackend: String, Codable, Sendable {
    case macNative
    case macExtension
    case androidOriginal
    case androidUnavailable
    case standard
}
