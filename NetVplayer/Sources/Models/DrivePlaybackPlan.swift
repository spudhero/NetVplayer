import Foundation

public enum DrivePlaybackMetadataKey {
    public static let provider = "drive.provider"
    public static let cacheKey = "drive.cacheKey"
    public static let driveID = "drive.driveID"
    public static let fid = "drive.fid"
    public static let personalFileID = "drive.personalFileID"
    public static let pickCode = "drive.pickCode"
    public static let fileName = "drive.fileName"
    public static let size = "drive.size"
    public static let temporarySavedFile = "drive.temporarySavedFile"
    public static let route = "drive.route"
    public static let quality = "drive.quality"
    public static let qualityLabel = "drive.qualityLabel"
    public static let width = "drive.width"
    public static let height = "drive.height"
    public static let canUpdateProgress = "drive.canUpdateProgress"
    public static let selectedReason = "drive.selectedReason"
    public static let candidateSummary = "drive.candidateSummary"
    public static let fixtureStatus = "drive.fixtureStatus"
}

public enum DrivePlaybackCandidateKind: String, Equatable, Sendable {
    case original
    case streaming
    case transcode
    case shareFallback

}

public enum DrivePlaybackTransport: String, Equatable, Sendable {
    case localRangeProxy
    case direct
    case hlsRelay
}

public enum DrivePlaybackRefreshPolicy: String, Equatable, Sendable {
    case none
    case refreshURLOnce
    case refreshCredentialAndURLOnce
}

public struct DrivePlaybackQuality: Equatable, Sendable {
    public let value: String
    public let label: String
    public let width: Int
    public let height: Int

    public init(value: String = "", label: String = "", width: Int = 0, height: Int = 0) {
        self.value = value
        self.label = label
        self.width = width
        self.height = height
    }
}

public struct DrivePlaybackAssetIdentity: Equatable, Sendable {
    public let provider: DriveProvider
    public let shareID: String
    public let sourceFileID: String
    public let size: Int64

    public init(provider: DriveProvider, shareID: String = "", sourceFileID: String, size: Int64 = 0) {
        self.provider = provider
        self.shareID = shareID
        self.sourceFileID = sourceFileID
        self.size = max(0, size)
    }

    public var cacheKey: String {
        [provider.rawValue, shareID, sourceFileID, String(size)].joined(separator: ":")
    }
}

public struct DrivePlaybackCleanupDescriptor: Equatable, Sendable {
    public let provider: DriveProvider
    public let driveID: String
    public let fileID: String
    public let cacheKey: String
    public let isTemporary: Bool

    public init(
        provider: DriveProvider,
        driveID: String = "",
        fileID: String,
        cacheKey: String = "",
        isTemporary: Bool
    ) {
        self.provider = provider
        self.driveID = driveID
        self.fileID = fileID
        self.cacheKey = cacheKey
        self.isTemporary = isTemporary
    }
}

public struct DrivePlaybackCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let providerRoute: String
    public let kind: DrivePlaybackCandidateKind
    public let transport: DrivePlaybackTransport
    public let url: String
    public let headers: [String: String]
    public let mpvOptions: [String: String]
    public let quality: DrivePlaybackQuality
    public let refreshPolicy: DrivePlaybackRefreshPolicy
    public let canUpdateProgress: Bool
    public let expectedSize: Int64

    public init(
        id: String,
        providerRoute: String,
        kind: DrivePlaybackCandidateKind,
        transport: DrivePlaybackTransport,
        url: String,
        headers: [String: String] = [:],
        mpvOptions: [String: String] = [:],
        quality: DrivePlaybackQuality = DrivePlaybackQuality(),
        refreshPolicy: DrivePlaybackRefreshPolicy = .none,
        canUpdateProgress: Bool = false,
        expectedSize: Int64 = 0
    ) {
        self.id = id
        self.providerRoute = providerRoute
        self.kind = kind
        self.transport = transport
        self.url = url
        self.headers = headers
        self.mpvOptions = mpvOptions
        self.quality = quality
        self.refreshPolicy = refreshPolicy
        self.canUpdateProgress = canUpdateProgress
        self.expectedSize = max(0, expectedSize)
    }
}

public struct DrivePlaybackPlan: Equatable, Sendable {
    public let provider: DriveProvider
    public let asset: DrivePlaybackAssetIdentity
    public let candidates: [DrivePlaybackCandidate]
    public let cleanup: DrivePlaybackCleanupDescriptor?
    public let reauthenticationRequired: Bool
    public let unavailableReason: String?

    public init(
        provider: DriveProvider,
        asset: DrivePlaybackAssetIdentity,
        candidates: [DrivePlaybackCandidate],
        cleanup: DrivePlaybackCleanupDescriptor? = nil,
        reauthenticationRequired: Bool = false,
        unavailableReason: String? = nil
    ) {
        self.provider = provider
        self.asset = asset
        var seen = Set<String>()
        self.candidates = candidates.filter {
            !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted
        }
        self.cleanup = cleanup
        self.reauthenticationRequired = reauthenticationRequired
        self.unavailableReason = unavailableReason
    }

    public var primaryCandidate: DrivePlaybackCandidate? { candidates.first }

    public func candidate(after id: String) -> DrivePlaybackCandidate? {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return nil }
        let next = candidates.index(after: index)
        return next < candidates.endIndex ? candidates[next] : nil
    }
}
