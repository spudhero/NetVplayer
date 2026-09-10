// PlayerEngine/QuarkShareExtractor.swift
// 夸克网盘公开分享转直连。完整播放需要用户登录 Cookie；免登录接口只提供短预览。

import Foundation
import Models
import Networking
import DriveEngine

public enum QuarkShareExtractorError: Error, LocalizedError, Sendable {
    case invalidShareURL(String)
    case loginRequired
    case noPlayableFile(String)
    case noDownloadURL(String)
    case officialPlayURLPending(String)
    case api(statusCode: Int, code: Int?, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidShareURL(let url):
            return "无效的夸克分享链接: \(url)"
        case .loginRequired:
            return "夸克网盘分享完整播放需要 Cookie。扫码 token 可登录个人网盘，但当前 Wogg 分享下载仍需要粘贴夸克 Cookie；公开分享免登录接口只能拿到短预览，不能完整播放。"
        case .noPlayableFile(let share):
            return "夸克分享中没有找到可播放视频文件: \(share)"
        case .noDownloadURL(let fileName):
            return "夸克网盘没有返回完整播放地址: \(fileName)。可能是 Cookie 过期、账号无权限，或该文件只能转存后播放。"
        case .officialPlayURLPending(let fileName):
            return "已转存成功，但夸克只返回下载 CDN，正在等待官方播放地址: \(fileName)。请稍后重试，或先在夸克网盘 App 中打开一次该文件后再试。"
        case .api(let statusCode, let code, let message):
            if let code {
                return "夸克网盘接口错误 HTTP \(statusCode) / \(code): \(message)"
            }
            return "夸克网盘接口错误 HTTP \(statusCode): \(message)"
        }
    }
}

public final class QuarkShareExtractor: SourceExtractorProtocol {
    public static let cookieDefaultsKey = "quarkCookie"

    private let httpClient: HTTPClient
    private let client: QuarkDriveClient
    private let cookieDriver: QuarkCookieDriver
    private let cookieProvider: @Sendable () -> String?
    private let cookieUpdateHandler: @Sendable (String) -> Void
    private let allowPreviewFallback: Bool

    public init(
        httpClient: HTTPClient = .shared,
        cookieProvider: @escaping @Sendable () -> String? = {
            let envCookie = ProcessInfo.processInfo.environment["NETVPLAYER_QUARK_COOKIE"]
            if let envCookie, !envCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return envCookie
            }
            return UserDefaults.standard.string(forKey: QuarkShareExtractor.cookieDefaultsKey)
        },
        cookieUpdateHandler: @escaping @Sendable (String) -> Void = {
            UserDefaults.standard.set($0, forKey: QuarkShareExtractor.cookieDefaultsKey)
        },
        allowPreviewFallback: Bool = false,
        pendingPlayPolls: Int = 15,
        pendingPlayIntervalMilliseconds: Int = 2_000
    ) {
        self.httpClient = httpClient
        self.client = QuarkDriveClient(
            httpClient: httpClient,
            pendingPlayPolls: pendingPlayPolls,
            pendingPlayIntervalMilliseconds: pendingPlayIntervalMilliseconds
        )
        self.cookieDriver = QuarkCookieDriver(
            httpClient: httpClient,
            pendingPlayPolls: pendingPlayPolls,
            pendingPlayIntervalMilliseconds: pendingPlayIntervalMilliseconds
        )
        self.cookieProvider = cookieProvider
        self.cookieUpdateHandler = cookieUpdateHandler
        self.allowPreviewFallback = allowPreviewFallback
    }

    public func match(url: URL) -> Bool {
        if let reference = DriveFileReference.parse(url.absoluteString) {
            return reference.provider == .quark
        }
        if url.scheme?.lowercased() == "quark" { return true }
        let host = (url.host ?? "").lowercased()
        return host.contains("pan.quark.cn") || host.contains("v.quark.cn")
    }

    public func fetch(url: String) async throws -> String {
        try await fetchResult(url: url).url
    }

    public func fetchResult(url: String) async throws -> SourceFetchResult {
        let share: QuarkShareRequest
        do {
            share = try client.shareRequest(from: url)
        } catch {
            throw QuarkShareExtractorError.invalidShareURL(url)
        }

        guard let cookie = Self.normalizedCookie(cookieProvider()) else {
            throw DriveEngineError.loginRequired(.quark)
        }

        do {
            let link = try await cookieDriver.link(
                rawURL: url,
                credential: .cookie(provider: .quark, value: cookie)
            )
            if let updatedCookie = link.updatedCredential?.secret,
               updatedCookie != cookie,
               !updatedCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cookieUpdateHandler(updatedCookie)
            }
            return try await streamFetchResult(for: link)
        } catch {
            let recovered = try await recoverFromShareDownloadLimitIfNeeded(error: error, rawURL: url, cookie: cookie)
            if let recovered {
                return try await streamFetchResult(for: recovered)
            }

            if let driveError = error as? DriveEngineError,
               case .loginRequired = driveError {
                throw driveError
            }
            let converted = Self.convert(error)
            if case .loginRequired = converted { throw converted }
            if allowPreviewFallback {
                let playableFiles = try await client.collectPlayableFiles(share: share, cookie: cookie)
                guard let selected = client.selectPlayableFile(from: playableFiles, share: share) else {
                    throw QuarkShareExtractorError.noPlayableFile(share.originalURL)
                }
                if let previewURL = try await client.fetchPreviewURL(for: selected, share: share, cookie: cookie) {
                    return SourceFetchResult(
                        url: previewURL,
                        headers: playbackHeaders(from: ["Referer": "https://pan.quark.cn/s/\(share.pwdID)", "Cookie": cookie]),
                        isDirectMedia: true
                    )
                }
                throw QuarkShareExtractorError.noDownloadURL(selected.file.name)
            }
            throw converted
        }
    }

    private func recoverFromShareDownloadLimitIfNeeded(error: Error, rawURL: String, cookie: String) async throws -> CloudDriveLink? {
        guard Self.isShareDownloadLimit(error) else {
            return nil
        }
        let link = try await cookieDriver.link(
            rawURL: rawURL,
            credential: .cookie(provider: .quark, value: cookie)
        )
        if let updatedCookie = link.updatedCredential?.secret,
           updatedCookie != cookie,
           !updatedCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cookieUpdateHandler(updatedCookie)
        }
        return link
    }
}

extension QuarkShareExtractor {
    func streamFetchResult(for link: CloudDriveLink) async throws -> SourceFetchResult {
        let headers = playbackHeaders(from: link.headers)
        var mpvOptions = try await detectMPVOptions(for: link.url, headers: headers)
        if let streamLavfOptions = Self.streamLavfOptions(for: link.url, headers: headers) {
            mpvOptions["stream-lavf-o"] = streamLavfOptions
        }
        let adapter = QuarkDrivePlaybackAdapter()
        let playbackPlan = adapter.playbackPlan(
            from: link,
            primaryHeaders: headers,
            primaryMPVOptions: mpvOptions
        )
        return SourceFetchResult(
            url: link.url,
            headers: headers,
            isDirectMedia: true,
            mpvOptions: mpvOptions,
            metadata: adapter.sanitizedMetadata(link.metadata),
            drivePlaybackPlan: playbackPlan
        )
    }

    func playbackHeaders(from headers: [String: String]) -> [String: String] {
        var playbackHeaders = headers
        playbackHeaders["User-Agent"] = QuarkDriveClient.accountPlaybackUserAgent
        if playbackHeaders["Referer"] == nil && playbackHeaders["referer"] == nil {
            playbackHeaders["Referer"] = "https://pan.quark.cn"
        }
        return playbackHeaders
    }

    static func normalizedCookie(_ cookie: String?) -> String? {
        guard let cookie else { return nil }
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func convert(_ error: Error) -> QuarkShareExtractorError {
        if let error = error as? QuarkShareExtractorError {
            return error
        }
        guard let driveError = error as? DriveEngineError else {
            return .api(statusCode: -1, code: nil, message: error.localizedDescription)
        }

        switch driveError {
        case .invalidShareURL(let url):
            return .invalidShareURL(url)
        case .loginRequired:
            return .loginRequired
        case .noPlayableFile(let share):
            return .noPlayableFile(share)
        case .noDownloadURL(let fileName):
            return .noDownloadURL(fileName)
        case .officialPlayURLPending(let fileName):
            return .officialPlayURLPending(fileName)
        case .unsupported(let message):
            return .api(statusCode: -1, code: nil, message: message)
        case .api(_, let statusCode, let code, let message):
            return .api(statusCode: statusCode, code: code, message: message)
        }
    }

    static func isShareDownloadLimit(_ error: Error) -> Bool {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("23018")
            || description.localizedCaseInsensitiveContains("download file size limit") {
            return true
        }
        if case .api(.quark, _, let code, let message) = error as? DriveEngineError {
            return code == 23018 || message.localizedCaseInsensitiveContains("download file size limit")
        }
        if case .api(_, let code, let message) = error as? QuarkShareExtractorError {
            return code == 23018 || message.localizedCaseInsensitiveContains("download file size limit")
        }
        return false
    }

    func detectMPVOptions(for url: String, headers: [String: String]) async throws -> [String: String] {
        guard Self.shouldProbeMediaHeader(url: url) else { return [:] }
        var probeHeaders = headers
        probeHeaders["Range"] = "bytes=0-63"
        do {
            let response = try await httpClient.get(url: url, headers: probeHeaders, timeout: 12)
            guard (200..<300).contains(response.statusCode), response.data.count >= 12 else {
                DiagnosticLog.write("[QUARK_MEDIA_PROBE] 探测未命中 status=\(response.statusCode) bytes=\(response.data.count)")
                return [:]
            }

            return Self.mpvOptions(forProbedMediaHeader: [UInt8](response.data.prefix(16)))
        } catch {
            DiagnosticLog.write("[QUARK_MEDIA_PROBE] 探测失败，继续交给 mpv: \(error.localizedDescription)")
        }

        return [:]
    }

    static func mpvOptions(forProbedMediaHeader bytes: [UInt8]) -> [String: String] {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.starts(with: pngMagic) else { return [:] }

        let demuxer: (format: String, container: String)
        if bytes.count >= 12, bytes[8...11].elementsEqual([0x1A, 0x45, 0xDF, 0xA3]) {
            demuxer = ("matroska", "Matroska")
        } else if bytes.count >= 16, bytes[12...15].elementsEqual([0x66, 0x74, 0x79, 0x70]) {
            demuxer = ("mov", "MP4")
        } else {
            return [:]
        }

        DiagnosticLog.write("[QUARK_MEDIA_PROBE] 检测到夸克 PNG 伪头 + \(demuxer.container)，mpv 将跳过前 8 字节")
        return [
            "demuxer-lavf-format": demuxer.format,
            "demuxer-lavf-o": "skip_initial_bytes=8"
        ]
    }

    static func shouldProbeMediaHeader(url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host.contains("quark.cn") || host.contains("uc.cn")
    }

    static func streamLavfOptions(for url: String, headers: [String: String]) -> String? {
        guard shouldUseStreamLavfHeaders(url: url),
              headerValue(named: "Cookie", in: headers) != nil else {
            return nil
        }

        let orderedHeaderNames = ["Cookie", "Origin", "Referer", "User-Agent"]
        let headerBlock = orderedHeaderNames.compactMap { name -> String? in
            guard let value = headerValue(named: name, in: headers),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return "\(name): \(value)"
        }
        .joined(separator: "\r\n")

        guard !headerBlock.isEmpty else { return nil }
        return "headers=\(headerBlock)\r\n,seekable=1,initial_request_size=64,request_size=4194304"
    }

    static func shouldUseStreamLavfHeaders(url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host.contains("quark.cn") || host.contains("uc.cn")
    }

    static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
