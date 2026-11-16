import Foundation

/// A process-wide source routing preference. A restart keeps opaque category,
/// detail and episode IDs on the implementation that created them.
public enum ProviderExecutionPreference: String, Codable, CaseIterable, Sendable {
    /// Decode legacy preferences without retaining the mixed execution route.
    case automatic
    case macPreferred
    case androidPreferred

    public static let allCases: [Self] = [.macPreferred, .androidPreferred]
    public var resolved: Self { self == .androidPreferred ? .androidPreferred : .macPreferred }
    public var usesAndroid: Bool { resolved == .androidPreferred }

    public static let storageKey = "providerExecutionPreference.v1"
}

public enum ProviderExecutionBackend: String, Codable, Sendable {
    case macNative
    case macExtension
    case androidOriginal
    case androidUnavailable
    case standard
}
