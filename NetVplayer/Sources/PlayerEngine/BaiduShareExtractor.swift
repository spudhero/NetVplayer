import Foundation
import DriveEngine
import Models
import Networking

public final class BaiduShareExtractor: SourceExtractorProtocol {
    public static let cookieDefaultsKey = "baiduCookie"

    private let client: BaiduDriveClient
    private let cookieProvider: @Sendable () -> String?
    private let cookieUpdateHandler: @Sendable (String) -> Void

    public init(
        httpClient: HTTPClient = .shared,
        cookieProvider: @escaping @Sendable () -> String? = {
            let values = [
                ProcessInfo.processInfo.environment["NETVPLAYER_BAIDU_COOKIE"] ?? "",
                UserDefaults.standard.string(forKey: BaiduShareExtractor.cookieDefaultsKey) ?? ""
            ]
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        },
        cookieUpdateHandler: @escaping @Sendable (String) -> Void = {
            UserDefaults.standard.set($0, forKey: BaiduShareExtractor.cookieDefaultsKey)
        }
    ) {
        self.client = BaiduDriveClient(httpClient: httpClient)
        self.cookieProvider = cookieProvider
        self.cookieUpdateHandler = cookieUpdateHandler
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
            reference = parsed
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
}
