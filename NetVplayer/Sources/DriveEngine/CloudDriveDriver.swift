// DriveEngine/CloudDriveDriver.swift
// AList-style cloud drive abstraction: authenticate credentials, list files, and resolve links.

import Foundation
import Models

public enum CloudCredentialKind: String, Codable, Sendable {
    case cookie
    case refreshToken
    case accessToken
    case shareToken
    case qrSession
    case serviceConfig
}

public struct CloudCredential: Codable, Equatable, Sendable {
    public let provider: DriveProvider
    public let kind: CloudCredentialKind
    public var secret: String
    public var refreshToken: String?
    public var accessToken: String?
    public var queryToken: String?
    public var deviceID: String?
    public var metadata: [String: String]
    public var updatedAt: Date

    public init(
        provider: DriveProvider,
        kind: CloudCredentialKind,
        secret: String = "",
        refreshToken: String? = nil,
        accessToken: String? = nil,
        queryToken: String? = nil,
        deviceID: String? = nil,
        metadata: [String: String] = [:],
        updatedAt: Date = Date()
    ) {
        self.provider = provider
        self.kind = kind
        self.secret = secret
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.queryToken = queryToken
        self.deviceID = deviceID
        self.metadata = metadata
        self.updatedAt = updatedAt
    }

    public static func cookie(provider: DriveProvider, value: String) -> CloudCredential {
        CloudCredential(provider: provider, kind: .cookie, secret: value)
    }

    public static func token(
        provider: DriveProvider,
        refreshToken: String,
        accessToken: String,
        deviceID: String,
        queryToken: String? = nil
    ) -> CloudCredential {
        CloudCredential(
            provider: provider,
            kind: .refreshToken,
            refreshToken: refreshToken,
            accessToken: accessToken,
            queryToken: queryToken,
            deviceID: deviceID
        )
    }
}

public struct CloudDriveLink: Equatable, Sendable {
    public let url: String
    public let headers: [String: String]
    public let fallbackHeaders: [String: String]
    public let metadata: [String: String]
    public let updatedCredential: CloudCredential?
    public let playbackPlan: DrivePlaybackPlan?

    public init(
        url: String,
        headers: [String: String] = [:],
        fallbackHeaders: [String: String] = [:],
        metadata: [String: String] = [:],
        updatedCredential: CloudCredential? = nil,
        playbackPlan: DrivePlaybackPlan? = nil
    ) {
        self.url = url
        self.headers = headers
        self.fallbackHeaders = fallbackHeaders
        self.metadata = metadata
        self.updatedCredential = updatedCredential
        self.playbackPlan = playbackPlan
    }
}
