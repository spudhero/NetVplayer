// Models/Drm.swift
// DRM 配置模型

import Foundation

/// DRM 配置
public struct Drm: Codable, Sendable {
    public var key: String
    public var type: String
    public var licenseUrl: String
    public var licenseHeader: [String: String]
    public var forceKey: Bool

    public init(
        key: String = "",
        type: String = "",
        licenseUrl: String = "",
        licenseHeader: [String: String] = [:],
        forceKey: Bool = false
    ) {
        self.key = key
        self.type = type
        self.licenseUrl = licenseUrl
        self.licenseHeader = licenseHeader
        self.forceKey = forceKey
    }
}
