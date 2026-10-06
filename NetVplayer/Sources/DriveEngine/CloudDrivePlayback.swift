// DriveEngine/CloudDrivePlayback.swift
// Shared contract for share-saved personal cloud-drive playback.

import Foundation
import Models

public struct PersonalDriveFileReference: Equatable, Sendable {
    public let provider: DriveProvider
    public let driveID: String
    public let fileID: String
    public let pickCode: String
    public let fileName: String
    public let size: Int64

    public init(
        provider: DriveProvider,
        driveID: String,
        fileID: String,
        pickCode: String = "",
        fileName: String,
        size: Int64 = 0
    ) {
        self.provider = provider
        self.driveID = driveID
        self.fileID = fileID
        self.pickCode = pickCode
        self.fileName = fileName
        self.size = size
    }
}

public struct CloudDrivePlaybackVariant: Equatable, Sendable {
    public let quality: String
    public let label: String
    public let width: Int
    public let height: Int
    public let url: String
    public let isOriginal: Bool

    public init(
        quality: String,
        label: String,
        width: Int = 0,
        height: Int = 0,
        url: String,
        isOriginal: Bool = false
    ) {
        self.quality = quality
        self.label = label
        self.width = width
        self.height = height
        self.url = url
        self.isOriginal = isOriginal
    }

    public static func sortedForPlayback(_ variants: [CloudDrivePlaybackVariant]) -> [CloudDrivePlaybackVariant] {
        variants
            .filter { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.isOriginal != rhs.isOriginal { return lhs.isOriginal && !rhs.isOriginal }
                let lhsPixels = lhs.width * lhs.height
                let rhsPixels = rhs.width * rhs.height
                if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }
                if lhs.height != rhs.height { return lhs.height > rhs.height }
                return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
    }
}

public struct CloudDrivePersonalPlayback: Equatable, Sendable {
    public let file: PersonalDriveFileReference
    public let variants: [CloudDrivePlaybackVariant]
    public let originalURL: String
    public let subtitles: [String]
    public let canUpdateProgress: Bool

    public init(
        file: PersonalDriveFileReference,
        variants: [CloudDrivePlaybackVariant] = [],
        originalURL: String = "",
        subtitles: [String] = [],
        canUpdateProgress: Bool = false
    ) {
        self.file = file
        self.variants = CloudDrivePlaybackVariant.sortedForPlayback(variants)
        self.originalURL = originalURL
        self.subtitles = subtitles
        self.canUpdateProgress = canUpdateProgress
    }

    public var bestTranscodeVariant: CloudDrivePlaybackVariant? {
        variants.first { !$0.isOriginal }
    }
}

public enum CloudDrivePlaybackMetadata {
    public static func variantMetadata(
        _ variant: CloudDrivePlaybackVariant,
        route: String,
        canUpdateProgress: Bool
    ) -> [String: String] {
        let values = [
            DrivePlaybackMetadataKey.route: route,
            DrivePlaybackMetadataKey.quality: variant.quality,
            DrivePlaybackMetadataKey.qualityLabel: variant.label,
            DrivePlaybackMetadataKey.width: String(variant.width),
            DrivePlaybackMetadataKey.height: String(variant.height),
            DrivePlaybackMetadataKey.canUpdateProgress: canUpdateProgress ? "true" : "false"
        ]
        return values
    }
}
