import Foundation
import Storage
import DriveEngine
import Models
import Networking

public final class BaiduShareExtractor: SourceExtractorProtocol {
    public static let cookieDefaultsKey = "baiduCookie"

    private let client: BaiduDriveClient
    private let savedFileStore: DriveSavedFileStore
    private let cookieProvider: @Sendable () -> String?
    private let cookieUpdateHandler: @Sendable (String) -> Void

    public init(
        httpClient: HTTPClient = .shared,
        cookieProvider: (@Sendable () -> String?)? = nil,
        cookieUpdateHandler: (@Sendable (String) -> Void)? = nil,
        preferences: UserPreferences = .shared,
        savedFileStore: DriveSavedFileStore = .shared
    ) {
        self.client = BaiduDriveClient(httpClient: httpClient, savedFileStore: savedFileStore)
        self.savedFileStore = savedFileStore
        self.cookieProvider = cookieProvider ?? {
            let values = [
                ProcessInfo.processInfo.environment["NETVPLAYER_BAIDU_COOKIE"] ?? "",
                preferences.baiduCookie
            ]
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        self.cookieUpdateHandler = cookieUpdateHandler ?? { preferences.baiduCookie = $0 }
    }

    public func match(url: URL) -> Bool {
        if let reference = DriveFileReference.parse(url.absoluteString) {
            return reference.provider == .baidu
        }
        if url.scheme?.lowercased() == "baidu" { return true }
        return (url.host ?? "").lowercased().contains("pan.baidu.com")
    }

    public func fetch(url: String) async throws -> String {
        try await fetchResult(url: url).url
    }

    public func fetchResult(url: String) async throws -> SourceFetchResult {
        guard let cookie = cookieProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !cookie.isEmpty else {
            throw DriveEngineError.loginRequired(.baidu)
        }
        let reference: DriveFileReference
        if let parsed = DriveFileReference.parse(url), parsed.provider == .baidu {
            let identity = DriveSavedFileNaming.identity(provider: .baidu, pwdID: parsed.pwdID,
                fid: parsed.fid, name: parsed.fileName, size: parsed.size)
            let cached = parsed.fidToken.isEmpty ? await savedFileStore.record(for: identity) : nil
            if let restored = Self.cachedReference(matching: parsed, record: cached) {
                reference = restored
            } else if parsed.pwdID.isEmpty || parsed.fid.isEmpty || parsed.fidToken.isEmpty {
                var share = try client.shareRequest(from: parsed.shareURL)
                if share.passcode.isEmpty, !parsed.passcode.isEmpty,
                   var components = URLComponents(string: share.originalURL) {
                    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "pwd", value: parsed.passcode)]
                    if let value = components.string { share = try client.shareRequest(from: value) }
                }
                let expanded = try await client.expandedFiles(share: share)
                guard let file = Self.legacyFile(matching: parsed, in: expanded.files) else {
                    throw DriveEngineError.noPlayableFile(parsed.shareURL)
                }
                reference = client.fileReference(for: file, share: share,
                    shareID: expanded.shareID, shareUK: expanded.shareUK,
                    collectionName: parsed.collectionName)
            } else {
                reference = parsed
            }
        } else {
            let share = try client.shareRequest(from: url)
            let expanded = try await client.expandedFiles(share: share)
            guard let file = expanded.files.first else {
                throw DriveEngineError.noPlayableFile(url)
            }
            reference = client.fileReference(
                for: file,
                share: share,
                shareID: expanded.shareID,
                shareUK: expanded.shareUK,
                collectionName: file.name
            )
        }

        let link = try await client.link(
            reference: reference,
            credential: .cookie(provider: .baidu, value: cookie)
        )
        if let updated = link.updatedCredential?.secret,
           !updated.isEmpty,
           updated != cookie {
            cookieUpdateHandler(updated)
        }
        var headers = link.headers
        if headers["User-Agent"] == nil && headers["user-agent"] == nil {
            headers["User-Agent"] = BaiduDriveClient.playbackUserAgent
        }
        let adapter = BaiduDrivePlaybackAdapter()
        return SourceFetchResult(
            url: link.url,
            headers: headers,
            isDirectMedia: true,
            metadata: adapter.sanitizedMetadata(link.metadata),
            drivePlaybackPlan: adapter.playbackPlan(
                from: link,
                primaryHeaders: headers,
                primaryMPVOptions: [:]
            )
        )
    }

    static func cachedReference(matching reference: DriveFileReference, record: DriveSavedFileRecord?) -> DriveFileReference? {
        guard reference.provider == .baidu, let record, record.provider == .baidu,
              record.pwdID == reference.pwdID, record.shareFID == reference.fid,
              !record.fidToken.isEmpty, !record.savedFID.isEmpty,
              reference.size <= 0 || reference.size == record.size else { return nil }
        return DriveFileReference(provider: .baidu, shareURL: reference.shareURL,
            pwdID: record.pwdID, passcode: reference.passcode, fid: record.shareFID,
            fidToken: record.fidToken, fileName: reference.fileName,
            collectionName: reference.collectionName, size: reference.size,
            formatType: reference.formatType, filePath: reference.filePath)
    }

    /// Repair missing sharing IDs while preserving the requested file. A
    /// duplicate name must never silently resume another file in the share.
    static func legacyFile(matching reference: DriveFileReference, in files: [BaiduShareFile]) -> BaiduShareFile? {
        let playable = files.filter(\.isPlayableMedia)
        if !reference.fid.isEmpty {
            let exact = playable.filter { $0.fileID == reference.fid }
            if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        }
        if !reference.filePath.isEmpty {
            let exact = playable.filter { $0.path == reference.filePath && (reference.size <= 0 || $0.size == reference.size) }
            if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        }
        guard !reference.fileName.isEmpty else { return nil }
        let named = playable.filter {
            $0.name == reference.fileName && (reference.size <= 0 || $0.size == reference.size)
        }
        return named.count == 1 ? named[0] : nil
    }
}
