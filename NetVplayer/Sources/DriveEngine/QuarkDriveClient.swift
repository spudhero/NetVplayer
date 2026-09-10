// DriveEngine/QuarkDriveClient.swift
// 夸克网盘分享目录和完整播放地址 API。

import Foundation
import Models
import Networking

public enum DriveEngineError: Error, LocalizedError, Sendable {
    case invalidShareURL(String)
    case unsupported(String)
    case loginRequired(DriveProvider)
    case noPlayableFile(String)
    case noDownloadURL(String)
    case officialPlayURLPending(String)
    case api(provider: DriveProvider, statusCode: Int, code: Int?, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidShareURL(let url):
            return "无效的网盘分享链接: \(url)"
        case .unsupported(let message):
            return message
        case .loginRequired(let provider):
            return "\(provider.displayName) 完整播放需要授权。请完成授权后重试。"
        case .noPlayableFile(let share):
            return "网盘分享中没有找到可播放视频文件: \(share)"
        case .noDownloadURL(let fileName):
            return "网盘没有返回完整播放地址: \(fileName)。可能是 Cookie 过期、账号无权限，或该文件只能转存后播放。"
        case .officialPlayURLPending(let fileName):
            return "已转存成功，但夸克只返回下载 CDN，正在等待官方播放地址: \(fileName)。请稍后重试，或先在夸克网盘 App 中打开一次该文件后再试。"
        case .api(let provider, let statusCode, let code, let message):
            if let code {
                return "\(provider.displayName) 接口错误 HTTP \(statusCode) / \(code): \(message)"
            }
            return "\(provider.displayName) 接口错误 HTTP \(statusCode): \(message)"
        }
    }
}

public struct QuarkShareRequest: Sendable {
    public let originalURL: String
    public let pwdID: String
    public let passcode: String
    public let requestedFileName: String?
    public let requestedFID: String?
    public let collectionName: String

    public init(originalURL: String, pwdID: String, passcode: String = "", requestedFileName: String? = nil, requestedFID: String? = nil, collectionName: String = "") {
        self.originalURL = originalURL
        self.pwdID = pwdID
        self.passcode = passcode
        self.requestedFileName = requestedFileName
        self.requestedFID = requestedFID
        self.collectionName = collectionName
    }
}

public struct QuarkShareFile: Sendable {
    public let fid: String
    public let name: String
    public let pdirFID: String
    public let category: Int
    public let fileType: Int
    public let size: Int64
    public let formatType: String
    public let isDirectory: Bool
    public let isFile: Bool
    public let shareFIDToken: String

    public init(
        fid: String,
        name: String,
        pdirFID: String,
        category: Int,
        fileType: Int,
        size: Int64,
        formatType: String,
        isDirectory: Bool,
        isFile: Bool,
        shareFIDToken: String
    ) {
        self.fid = fid
        self.name = name
        self.pdirFID = pdirFID
        self.category = category
        self.fileType = fileType
        self.size = size
        self.formatType = formatType
        self.isDirectory = isDirectory
        self.isFile = isFile
        self.shareFIDToken = shareFIDToken
    }

    public var isPlayableVideo: Bool {
        QuarkPlayableFileClassifier.isPlayableVideo(
            name: name,
            formatType: formatType,
            isDirectory: isDirectory,
            isFile: isFile
        )
    }

    public var isKnownNonVideoAsset: Bool {
        QuarkPlayableFileClassifier.isKnownNonVideoAsset(name: name)
    }
}

private enum QuarkPlayableFileClassifier {
    private static let videoExtensions: Set<String> = [
        ".mp4", ".m4v", ".mov", ".m3u8", ".mkv", ".ts", ".flv", ".webm",
        ".avi", ".wmv", ".mpg", ".mpeg", ".m2ts", ".mts", ".3gp", ".3g2",
        ".rm", ".rmvb", ".vob", ".ogv", ".mxf"
    ]

    private static let nonVideoExtensions: Set<String> = [
        ".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".avif", ".heic", ".heif",
        ".srt", ".ass", ".ssa", ".vtt", ".sub", ".idx",
        ".txt", ".nfo", ".json", ".xml", ".pdf", ".doc", ".docx",
        ".zip", ".rar", ".7z", ".tar", ".gz", ".iso"
    ]

    private static let videoFormatTokens = [
        "video",
        "mpegurl",
        "m3u8",
        "mp4",
        "matroska",
        "quicktime",
        "webm",
        "x-flv",
        "x-msvideo"
    ]

    static func isPlayableVideo(name: String, formatType: String, isDirectory: Bool, isFile: Bool) -> Bool {
        if isDirectory || !isFile { return false }
        if isKnownNonVideoAsset(name: name) { return false }
        if videoExtensions.contains(normalizedExtension(for: name)) { return true }

        let lowerFormat = formatType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowerFormat.isEmpty else { return false }
        return videoFormatTokens.contains { lowerFormat.contains($0) }
    }

    static func isKnownNonVideoAsset(name: String) -> Bool {
        nonVideoExtensions.contains(normalizedExtension(for: name))
    }

    private static func normalizedExtension(for name: String) -> String {
        let ext = (name.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "" : ".\(ext)"
    }
}

public struct QuarkPlayableFile: Sendable {
    public let file: QuarkShareFile
    public let stoken: String

    public init(file: QuarkShareFile, stoken: String) {
        self.file = file
        self.stoken = stoken
    }
}

public struct QuarkDownloadResult: Sendable {
    public let url: String?
    public let updatedCookie: String
    public let savedFile: DriveSavedFileRecord?
    public let fallbackURL: String?

    public init(url: String?, updatedCookie: String, savedFile: DriveSavedFileRecord? = nil, fallbackURL: String? = nil) {
        self.url = url
        self.updatedCookie = updatedCookie
        self.savedFile = savedFile
        self.fallbackURL = fallbackURL
    }
}

public struct QuarkPlayResult: Sendable {
    public let url: String?
    public let updatedCookie: String
    public let isTranscoded: Bool

    public init(url: String?, updatedCookie: String, isTranscoded: Bool = false) {
        self.url = url
        self.updatedCookie = updatedCookie
        self.isTranscoded = isTranscoded
    }

    public var transcodedURL: String? {
        isTranscoded ? url : nil
    }
}

private enum QuarkPlayableURLType: String, Sendable {
    case officialPlay = "official-play"
    case transcodedM3U8 = "transcoded-m3u8"
    case driveMatroska = "drive-matroska"
    case personalDownload = "personal-download"
    case rejectedPDSDownload = "rejected-pds-download"
}

private struct QuarkPlayableURLSelection: Sendable {
    let url: String?
    let type: QuarkPlayableURLType

    init(_ rawURL: String) {
        if Self.isCallbackProtectedURL(rawURL) {
            url = nil
            type = .rejectedPDSDownload
        } else {
            url = rawURL
            if Self.isM3U8(rawURL) {
                type = .transcodedM3U8
            } else if Self.isDrivePlaybackURL(rawURL) {
                type = .driveMatroska
            } else {
                type = .officialPlay
            }
        }
    }

    private static func isM3U8(_ rawURL: String) -> Bool {
        rawURL.lowercased().contains(".m3u8")
    }

    private static func isDrivePlaybackURL(_ rawURL: String) -> Bool {
        guard let host = URL(string: rawURL)?.host?.lowercased() else { return false }
        return host.contains("drive.quark.cn") || host.contains("drive.uc.cn")
    }

    private static func isCallbackProtectedURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let host = components.host?.lowercased() else {
            return false
        }
        if host.contains("pds.quark.cn") || host.contains("pds.uc.cn") {
            return true
        }
        let queryNames = Set((components.queryItems ?? []).map { $0.name.lowercased() })
        return queryNames.contains("callback") || queryNames.contains("callback-var")
    }
}

public final class QuarkDriveClient: @unchecked Sendable {
    private static let apiBase = "https://drive-m.quark.cn"
    private static let accountAPIBase = "https://drive.quark.cn"
    private static let pcAPIBase = "https://drive-pc.quark.cn"
    private static let shareAPIBase = "https://drive-h.quark.cn"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    public static let accountPlaybackUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    private static let accountUserAgent = accountPlaybackUserAgent
    private static let pageSize = 200
    private static let maxDirectories = 32
    private static let maxPagesPerDirectory = 8
    private static let maxTaskPolls = 20

    private let httpClient: HTTPClient
    private let pendingPlayPolls: Int
    private let pendingPlayIntervalMilliseconds: Int

    public init(
        httpClient: HTTPClient = .shared,
        pendingPlayPolls: Int = 15,
        pendingPlayIntervalMilliseconds: Int = 2_000
    ) {
        self.httpClient = httpClient
        self.pendingPlayPolls = max(1, pendingPlayPolls)
        self.pendingPlayIntervalMilliseconds = max(0, pendingPlayIntervalMilliseconds)
    }

    public func shareRequest(from rawURL: String) throws -> QuarkShareRequest {
        if let reference = DriveFileReference.parse(rawURL), reference.provider == .quark {
            return QuarkShareRequest(
                originalURL: reference.shareURL,
                pwdID: reference.pwdID,
                passcode: reference.passcode,
                requestedFileName: reference.fileName,
                requestedFID: reference.fid,
                collectionName: reference.collectionName
            )
        }

        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw DriveEngineError.invalidShareURL(rawURL)
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let passcode = Self.value(for: ["pwd", "passcode", "code"], in: queryItems) ?? ""
        let requestedFileName = Self.value(for: ["file", "name", "episode"], in: queryItems)

        let pwdID: String?
        if scheme == "quark" {
            pwdID = Self.parseQuarkScheme(url)
        } else {
            pwdID = Self.parseWebShare(url)
        }

        guard let pwdID, !pwdID.isEmpty else {
            throw DriveEngineError.invalidShareURL(rawURL)
        }

        return QuarkShareRequest(
            originalURL: rawURL,
            pwdID: pwdID,
            passcode: passcode,
            requestedFileName: requestedFileName
        )
    }

    public func collectPlayableFiles(share: QuarkShareRequest, cookie: String? = nil) async throws -> [QuarkPlayableFile] {
        var playableFiles: [QuarkPlayableFile] = []
        var filteredAssetNames: [String] = []
        var directoryQueue = ["0"]
        var visitedDirectories = Set<String>()

        while !directoryQueue.isEmpty && visitedDirectories.count < Self.maxDirectories {
            let pdirFID = directoryQueue.removeFirst()
            guard visitedDirectories.insert(pdirFID).inserted else { continue }

            for page in 1...Self.maxPagesPerDirectory {
                let result = try await loadShareList(share: share, pdirFID: pdirFID, page: page, cookie: cookie)

                for item in result.list {
                    if item.isDirectory {
                        directoryQueue.append(item.fid)
                    } else if item.isPlayableVideo {
                        playableFiles.append(QuarkPlayableFile(file: item, stoken: result.stoken))
                    } else if item.isKnownNonVideoAsset {
                        filteredAssetNames.append(item.name)
                    }
                }

                if result.list.count < Self.pageSize {
                    break
                }
            }
        }

        if !filteredAssetNames.isEmpty {
            let sample = filteredAssetNames.prefix(6).joined(separator: ", ")
            DiagnosticLog.write("[QUARK_SHARE_FILTER] filtered non-video assets count=\(filteredAssetNames.count) names=\(sample)")
        }

        return playableFiles.sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
    }

    public func selectPlayableFile(from files: [QuarkPlayableFile], share: QuarkShareRequest) -> QuarkPlayableFile? {
        if let requestedFID = share.requestedFID,
           let exact = files.first(where: { $0.file.fid == requestedFID }) {
            return exact
        }
        if let requestedName = share.requestedFileName {
            let lower = requestedName.lowercased()
            if let exact = files.first(where: { $0.file.name.lowercased() == lower }) {
                return exact
            }
            if let partial = files.first(where: { $0.file.name.lowercased().contains(lower) }) {
                return partial
            }
        }
        return files.first
    }

    public func fileReference(for playable: QuarkPlayableFile, share: QuarkShareRequest, collectionName: String = "") -> DriveFileReference {
        DriveFileReference(
            provider: .quark,
            shareURL: share.originalURL,
            pwdID: share.pwdID,
            passcode: share.passcode,
            fid: playable.file.fid,
            fidToken: playable.file.shareFIDToken,
            fileName: playable.file.name,
            collectionName: collectionName
        )
    }

    public func fetchDownloadURLResult(for playable: QuarkPlayableFile, share: QuarkShareRequest, cookie: String) async throws -> QuarkDownloadResult {
        let file = playable.file
        var body: [String: Any] = [
            "fids": [file.fid],
            "pwd_id": share.pwdID,
            "stoken": playable.stoken
        ]
        if !file.shareFIDToken.isEmpty {
            body["fids_token"] = [file.shareFIDToken]
        }

        let result = try await postJSONResult(
            url: Self.apiURL(base: Self.apiBase, path: "/1/clouddrive/file/share/download"),
            headers: requestHeaders(share: share, cookie: cookie),
            body: body
        )

        if let data = result.json["data"] as? [[String: Any]],
           let first = data.first,
           let downloadURL = (Self.stringValue(first["download_url"]) ?? Self.stringValue(first["url"])),
           !downloadURL.isEmpty {
            return QuarkDownloadResult(url: downloadURL, updatedCookie: result.updatedCookie)
        }
        return QuarkDownloadResult(url: nil, updatedCookie: result.updatedCookie)
    }

    public func validateAccountCookie(_ cookie: String) async throws -> String {
        let result = try await getJSONResult(
            url: Self.apiURL(base: Self.accountAPIBase, path: "/1/clouddrive/config"),
            headers: accountHeaders(cookie: cookie)
        )
        return result.updatedCookie
    }

    public func fetchFullPlayURLResult(for playable: QuarkPlayableFile, share: QuarkShareRequest, cookie: String) async throws -> QuarkPlayResult {
        let file = playable.file
        let body: [String: Any] = [
            "fid": file.fid,
            "pwd_id": share.pwdID,
            "stoken": playable.stoken,
            "fid_token": file.shareFIDToken,
            "resolutions": "4k,2k,super,high,normal,low",
            "supports": "fmp4_av,m3u8,dolby_vision"
        ]

        let result = try await postJSONResult(
            url: Self.apiURL(base: Self.apiBase, path: "/1/clouddrive/file/v2/play/project"),
            headers: requestHeaders(share: share, cookie: cookie, stoken: playable.stoken),
            body: body
        )

        guard let data = result.json["data"] as? [String: Any] else {
            return QuarkPlayResult(url: nil, updatedCookie: result.updatedCookie)
        }
        return Self.playResult(in: data, updatedCookie: result.updatedCookie)
    }

    public func fetchSavedDownloadURLResult(for playable: QuarkPlayableFile, share: QuarkShareRequest, cookie: String) async throws -> QuarkDownloadResult {
        var activeCookie = cookie
        let identity = DriveSavedFileNaming.identity(provider: .quark, pwdID: share.pwdID, file: playable.file)
        let folder = try await ensureTransferFolder(for: share, cookie: activeCookie)
        activeCookie = folder.updatedCookie

        if let cached = await DriveSavedFileStore.shared.record(for: identity) {
            let matchesTargetFolder = (cached.provider ?? .quark) == .quark
                && cached.parentFID == folder.fid
            if !matchesTargetFolder {
                try? await DriveSavedFileStore.shared.remove(cacheKey: identity.cacheKey)
                DiagnosticLog.write("[QUARK_SAVED_CACHE] invalidated cacheKey=\(identity.cacheKey) fid=\(cached.savedFID) reason=transfer-folder-mismatch")
            } else {
                do {
                    return try await personalPlayResultWaitingIfNeeded(for: cached, cookie: activeCookie)
                } catch {
                    if Self.shouldInvalidateSavedRecord(error) {
                        try? await DriveSavedFileStore.shared.remove(cacheKey: identity.cacheKey)
                        DiagnosticLog.write("[QUARK_SAVED_CACHE] invalidated cacheKey=\(identity.cacheKey) fid=\(cached.savedFID) reason=\(error.localizedDescription)")
                    } else if Self.shouldWaitForPersonalPlayback(error) {
                        throw DriveEngineError.officialPlayURLPending(cached.originalName)
                    } else {
                        throw error
                    }
                }
            }
        }

        let transferStartCookie = activeCookie
        let transferResult = try await DriveTransferCoordinator.shared.transfer(cacheKey: identity.cacheKey) {
            var transferCookie = transferStartCookie
            let existing = try await self.findPersonalFileRecursively(
                fileName: identity.targetFileName,
                size: playable.file.size,
                rootFID: folder.fid,
                cookie: transferCookie
            )
            transferCookie = existing.updatedCookie
            if let file = existing.file {
                let record = DriveSavedFileRecord(
                    provider: .quark,
                    cacheKey: identity.cacheKey,
                    pwdID: share.pwdID,
                    shareFID: playable.file.fid,
                    fidToken: playable.file.shareFIDToken,
                    size: playable.file.size,
                    originalName: playable.file.name,
                    savedFID: file.fid,
                    savedFileName: file.name,
                    parentFID: file.pdirFID.isEmpty ? folder.fid : file.pdirFID
                )
                try await DriveSavedFileStore.shared.save(record)
                DiagnosticLog.write("[QUARK_SAVED_CACHE] reused hash-file cacheKey=\(identity.cacheKey) fid=\(file.fid) file=\(file.name)")
                return DriveSavedFileTransferResult(record: record, updatedCookie: transferCookie)
            }

            let save = try await self.saveShareFileToPersonalDrive(
                playable: playable,
                share: share,
                targetPdirFID: folder.fid,
                cookie: transferCookie
            )
            transferCookie = save.updatedCookie

            var savedFID = save.savedFID
            if let taskID = save.taskID {
                let task = try await self.waitForSaveTask(
                    taskID: taskID,
                    originalFID: playable.file.fid,
                    fileName: playable.file.name,
                    intervalMilliseconds: save.intervalMilliseconds,
                    cookie: transferCookie
                )
                transferCookie = task.updatedCookie
                savedFID = task.savedFID ?? savedFID
            }

            let resolved = try await self.waitForResolvedSavedPersonalFile(
                candidateFID: savedFID?.isEmpty == false ? savedFID : nil,
                originalFileName: playable.file.name,
                size: playable.file.size,
                appFolderFID: folder.fid,
                cookie: transferCookie
            )
            transferCookie = resolved.updatedCookie
            guard let savedFile = resolved.file else {
                throw DriveEngineError.noDownloadURL(playable.file.name)
            }

            let rename = try await self.renamePersonalFile(fid: savedFile.fid, fileName: identity.targetFileName, cookie: transferCookie)
            transferCookie = rename.updatedCookie
            let record = DriveSavedFileRecord(
                provider: .quark,
                cacheKey: identity.cacheKey,
                pwdID: share.pwdID,
                shareFID: playable.file.fid,
                fidToken: playable.file.shareFIDToken,
                size: playable.file.size,
                originalName: playable.file.name,
                savedFID: savedFile.fid,
                savedFileName: identity.targetFileName,
                parentFID: savedFile.pdirFID.isEmpty ? folder.fid : savedFile.pdirFID
            )
            try await DriveSavedFileStore.shared.save(record)
            DiagnosticLog.write("[QUARK_SAVED_CACHE] saved cacheKey=\(identity.cacheKey) fid=\(savedFile.fid) file=\(identity.targetFileName)")
            return DriveSavedFileTransferResult(record: record, updatedCookie: transferCookie)
        }
        let savedFile = transferResult.record
        activeCookie = transferResult.updatedCookie

        do {
            return try await personalPlayResultWaitingIfNeeded(for: savedFile, cookie: activeCookie)
        } catch {
            if Self.shouldInvalidateSavedRecord(error) {
                try? await DriveSavedFileStore.shared.remove(cacheKey: identity.cacheKey)
                DiagnosticLog.write("[QUARK_SAVED_CACHE] invalidated cacheKey=\(identity.cacheKey) fid=\(savedFile.savedFID) reason=\(error.localizedDescription)")
            }
            if Self.shouldWaitForPersonalPlayback(error) {
                DiagnosticLog.write("[QUARK_LINK_SELECT] type=rejected-pds-download context=personal-play-error file=\(playable.file.name), reason=\(error.localizedDescription)")
                throw DriveEngineError.officialPlayURLPending(playable.file.name)
            }
            throw error
        }
    }

    public func fetchPreviewURL(for playable: QuarkPlayableFile, share: QuarkShareRequest, cookie: String? = nil) async throws -> String? {
        let file = playable.file
        var components = URLComponents(string: "\(Self.apiBase)/1/clouddrive/share/sharepage/video_preview")
        components?.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "pwd_id", value: share.pwdID),
            URLQueryItem(name: "stoken", value: playable.stoken),
            URLQueryItem(name: "fid", value: file.fid),
            URLQueryItem(name: "fid_token", value: file.shareFIDToken),
            URLQueryItem(name: "format", value: "mp4")
        ]

        guard let url = components?.url?.absoluteString else { return nil }
        let json = try await getJSON(
            url: url,
            headers: requestHeaders(share: share, cookie: cookie, stoken: playable.stoken, includeContentType: false)
        )

        guard let data = json["data"] as? [String: Any] else { return nil }
        return Self.bestPlayableURL(in: data)
    }

    public func deleteSavedFile(cacheKey: String, fid: String, cookie: String) async throws -> String {
        let updatedCookie = try await deletePersonalFile(fid: fid, cookie: cookie)
        try? await DriveSavedFileStore.shared.remove(cacheKey: cacheKey)
        DiagnosticLog.write("[QUARK_SAVED_CACHE] deleted cacheKey=\(cacheKey) fid=\(fid)")
        return updatedCookie
    }
}

private extension QuarkDriveClient {
    struct ShareListResult: Sendable {
        let stoken: String
        let list: [QuarkShareFile]
    }

    struct PersonalFile: Sendable {
        let fid: String
        let name: String
        let pdirFID: String
        let size: Int64
        let fileType: Int
        let category: Int
        let isDirectory: Bool
        let isFile: Bool

        var isPlayableVideoObject: Bool {
            QuarkPlayableFileClassifier.isPlayableVideo(
                name: name,
                formatType: "",
                isDirectory: isDirectory,
                isFile: isFile
            )
        }
    }

    struct AppFolderResult: Sendable {
        let fid: String
        let updatedCookie: String
    }

    struct SaveStartResult: Sendable {
        let taskID: String?
        let savedFID: String?
        let intervalMilliseconds: Int
        let updatedCookie: String
    }

    struct SaveTaskResult: Sendable {
        let savedFID: String?
        let updatedCookie: String
    }

    struct PersonalFileLookupResult: Sendable {
        let file: PersonalFile?
        let updatedCookie: String
    }

    struct JSONRequestResult {
        let json: [String: Any]
        let updatedCookie: String
    }

    func loadShareList(share: QuarkShareRequest, pdirFID: String, page: Int, cookie: String?) async throws -> ShareListResult {
        let body: [String: Any] = [
            "pwd_id": share.pwdID,
            "passcode": share.passcode,
            "pdir_fid": pdirFID,
            "force": 0,
            "page": page,
            "size": Self.pageSize,
            "fetch_banner": 1,
            "fetch_share": 1,
            "fetch_relate_conversation": 1,
            "fetch_total": 1,
            "fetch_sub_file_cnt": 1,
            "sort": "file_type:asc,file_name:asc",
            "support_visit_limit_private_share": true
        ]

        let json = try await postJSON(
            url: Self.apiURL(base: Self.apiBase, path: "/1/clouddrive/share/sharepage/v2/detail", queryItems: [
                URLQueryItem(name: "format", value: "png")
            ]),
            headers: requestHeaders(share: share, cookie: cookie),
            body: body
        )

        guard let data = json["data"] as? [String: Any],
              let tokenInfo = data["token_info"] as? [String: Any],
              let stoken = tokenInfo["stoken"] as? String,
              let detailInfo = data["detail_info"] as? [String: Any],
              let rawList = detailInfo["list"] as? [[String: Any]] else {
            throw DriveEngineError.api(provider: .quark, statusCode: 200, code: nil, message: "分享列表响应结构异常")
        }

        return ShareListResult(
            stoken: stoken,
            list: rawList.compactMap(Self.parseShareFile)
        )
    }

    func ensureAppFolder(cookie: String) async throws -> AppFolderResult {
        let root = try await listPersonalFiles(parentFID: "0", cookie: cookie)
        if let existing = root.files.first(where: { $0.isDirectory && $0.name == DriveTransferDirectoryPolicy.rootFolderName }) {
            return AppFolderResult(fid: existing.fid, updatedCookie: root.updatedCookie)
        }

        let result = try await postJSONResult(
            url: Self.apiURL(base: Self.pcAPIBase, path: "/1/clouddrive/file"),
            headers: accountHeaders(cookie: root.updatedCookie),
            body: [
                "pdir_fid": "0",
                "file_name": DriveTransferDirectoryPolicy.rootFolderName,
                "dir_path": "",
                "dir_init_lock": false
            ]
        )
        if let data = result.json["data"] as? [String: Any],
           let fid = Self.firstString(in: data, keys: ["fid", "file_id"]),
           !fid.isEmpty {
            return AppFolderResult(fid: fid, updatedCookie: result.updatedCookie)
        }

        let refreshed = try await listPersonalFiles(parentFID: "0", cookie: result.updatedCookie)
        if let existing = refreshed.files.first(where: { $0.isDirectory && $0.name == DriveTransferDirectoryPolicy.rootFolderName }) {
            return AppFolderResult(fid: existing.fid, updatedCookie: refreshed.updatedCookie)
        }

        throw DriveEngineError.api(provider: .quark, statusCode: 200, code: nil, message: "无法创建或定位 NetVplayer 转存文件夹")
    }

    func ensureTransferFolder(for share: QuarkShareRequest, cookie: String) async throws -> AppFolderResult {
        let root = try await ensureAppFolder(cookie: cookie)
        guard let childName = DriveTransferDirectoryPolicy.collectionFolderName(
            collectionName: share.collectionName,
            shareID: share.pwdID
        ) else {
            return root
        }
        return try await ensureChildFolder(
            named: childName,
            parentFID: root.fid,
            cookie: root.updatedCookie
        )
    }

    func ensureChildFolder(named name: String, parentFID: String, cookie: String) async throws -> AppFolderResult {
        let listed = try await listPersonalFiles(parentFID: parentFID, cookie: cookie)
        if let existing = listed.files.first(where: { $0.isDirectory && $0.name == name }) {
            return AppFolderResult(fid: existing.fid, updatedCookie: listed.updatedCookie)
        }

        let result = try await postJSONResult(
            url: Self.apiURL(base: Self.pcAPIBase, path: "/1/clouddrive/file"),
            headers: accountHeaders(cookie: listed.updatedCookie),
            body: [
                "pdir_fid": parentFID,
                "file_name": name,
                "dir_path": "",
                "dir_init_lock": false
            ]
        )
        if let data = result.json["data"] as? [String: Any],
           let fid = Self.firstString(in: data, keys: ["fid", "file_id"]),
           !fid.isEmpty {
            return AppFolderResult(fid: fid, updatedCookie: result.updatedCookie)
        }

        let refreshed = try await listPersonalFiles(parentFID: parentFID, cookie: result.updatedCookie)
        if let existing = refreshed.files.first(where: { $0.isDirectory && $0.name == name }) {
            return AppFolderResult(fid: existing.fid, updatedCookie: refreshed.updatedCookie)
        }

        throw DriveEngineError.api(provider: .quark, statusCode: 200, code: nil, message: "无法创建或定位 \(name) 转存文件夹")
    }

    func saveShareFileToPersonalDrive(
        playable: QuarkPlayableFile,
        share: QuarkShareRequest,
        targetPdirFID: String,
        cookie: String
    ) async throws -> SaveStartResult {
        let file = playable.file
        var body: [String: Any] = [
            "fid_list": [file.fid],
            "fid_token_list": [file.shareFIDToken],
            "to_pdir_fid": targetPdirFID,
            "pwd_id": share.pwdID,
            "stoken": playable.stoken,
            "pdir_fid": file.pdirFID,
            "scene": "link"
        ]
        if file.shareFIDToken.isEmpty {
            body.removeValue(forKey: "fid_token_list")
        }

        let result = try await postJSONResult(
            url: Self.apiURL(base: Self.shareAPIBase, path: "/1/clouddrive/share/sharepage/save"),
            headers: requestHeaders(share: share, cookie: cookie, stoken: playable.stoken),
            body: body
        )
        let data = result.json["data"] as? [String: Any] ?? result.json
        let metadata = result.json["metadata"] as? [String: Any]
        return SaveStartResult(
            taskID: Self.firstString(in: data, keys: ["task_id", "taskId"]),
            savedFID: Self.savedFID(in: data, excluding: file.fid, matching: file.name),
            intervalMilliseconds: max(300, Self.intValue(metadata?["tq_gap"]) ?? Self.intValue(metadata?["task_gap"]) ?? 500),
            updatedCookie: result.updatedCookie
        )
    }

    func waitForSaveTask(
        taskID: String,
        originalFID: String,
        fileName: String,
        intervalMilliseconds: Int,
        cookie: String
    ) async throws -> SaveTaskResult {
        var activeCookie = cookie
        var lastJSON: [String: Any] = [:]

        for _ in 0..<Self.maxTaskPolls {
            let result = try await getJSONResult(
                url: Self.apiURL(base: Self.pcAPIBase, path: "/1/clouddrive/task", queryItems: [
                    URLQueryItem(name: "task_id", value: taskID)
                ]),
                headers: accountHeaders(cookie: activeCookie)
            )
            activeCookie = result.updatedCookie
            lastJSON = result.json
            let data = result.json["data"] as? [String: Any] ?? result.json
            if let savedFID = Self.savedFID(in: data, excluding: originalFID, matching: fileName) {
                return SaveTaskResult(savedFID: savedFID, updatedCookie: activeCookie)
            }
            if Self.taskDidFinish(data) {
                return SaveTaskResult(savedFID: nil, updatedCookie: activeCookie)
            }

            let nanoseconds = UInt64(max(300, intervalMilliseconds)) * 1_000_000
            try await Task.sleep(nanoseconds: nanoseconds)
        }

        let message = Self.stringValue(lastJSON["message"]) ?? Self.stringValue(lastJSON["msg"]) ?? "转存任务超时"
        throw DriveEngineError.api(provider: .quark, statusCode: 200, code: nil, message: message)
    }

    func findPersonalFileRecursively(fileName: String, size: Int64?, rootFID: String, cookie: String) async throws -> PersonalFileLookupResult {
        var activeCookie = cookie
        var queue = [rootFID]
        var visited = Set<String>()

        while !queue.isEmpty && visited.count < Self.maxDirectories {
            let parentFID = queue.removeFirst()
            guard visited.insert(parentFID).inserted else { continue }

            let listed = try await listPersonalFiles(parentFID: parentFID, cookie: activeCookie)
            activeCookie = listed.updatedCookie

            let exactMatches = listed.files.filter { $0.isPlayableVideoObject && $0.name == fileName }
            if let size,
               let exact = exactMatches.first(where: { $0.size == size }) {
                return PersonalFileLookupResult(file: exact, updatedCookie: activeCookie)
            }
            if let exact = exactMatches.first {
                return PersonalFileLookupResult(file: exact, updatedCookie: activeCookie)
            }
            if let folded = listed.files.first(where: { $0.isPlayableVideoObject && $0.name.localizedStandardCompare(fileName) == .orderedSame }) {
                return PersonalFileLookupResult(file: folded, updatedCookie: activeCookie)
            }

            queue.append(contentsOf: listed.files.filter(\.isDirectory).map(\.fid))
        }

        return PersonalFileLookupResult(file: nil, updatedCookie: activeCookie)
    }

    func resolveSavedPersonalFile(candidateFID: String, originalFileName: String, size: Int64, appFolderFID: String, cookie: String) async throws -> PersonalFileLookupResult {
        var activeCookie = cookie
        let appFolder = try await listPersonalFiles(parentFID: appFolderFID, cookie: activeCookie)
        activeCookie = appFolder.updatedCookie

        if let candidate = appFolder.files.first(where: { $0.fid == candidateFID }) {
            DiagnosticLog.write("[QUARK_SAVED_CACHE] save candidate fid=\(candidateFID) name=\(candidate.name) dir=\(candidate.isDirectory) fileType=\(candidate.fileType) category=\(candidate.category) size=\(candidate.size)")

            let nested = try? await findPersonalFileRecursively(
                fileName: originalFileName,
                size: size,
                rootFID: candidate.fid,
                cookie: activeCookie
            )
            if let nested {
                activeCookie = nested.updatedCookie
                if let file = nested.file {
                    let containerType = candidate.isDirectory ? "folder" : "container"
                    DiagnosticLog.write("[QUARK_SAVED_CACHE] save task returned \(containerType) fid=\(candidateFID); resolved nested video fid=\(file.fid) file=\(file.name)")
                    return PersonalFileLookupResult(file: file, updatedCookie: activeCookie)
                }
            }

            if candidate.isPlayableVideoObject {
                return PersonalFileLookupResult(file: candidate, updatedCookie: activeCookie)
            }

            DiagnosticLog.write("[QUARK_SAVED_CACHE] save task returned non-video fid=\(candidateFID); resolving under app folder file=\(originalFileName)")
        } else {
            let nested = try? await findPersonalFileRecursively(
                fileName: originalFileName,
                size: size,
                rootFID: candidateFID,
                cookie: activeCookie
            )
            if let nested {
                activeCookie = nested.updatedCookie
                if let file = nested.file {
                    DiagnosticLog.write("[QUARK_SAVED_CACHE] save task returned external container fid=\(candidateFID); resolved nested video fid=\(file.fid) file=\(file.name)")
                    return PersonalFileLookupResult(file: file, updatedCookie: activeCookie)
                }
            }
        }

        let fallback = try await findPersonalFileRecursively(
            fileName: originalFileName,
            size: size,
            rootFID: appFolderFID,
            cookie: activeCookie
        )
        return fallback
    }

    func waitForResolvedSavedPersonalFile(candidateFID: String?, originalFileName: String, size: Int64, appFolderFID: String, cookie: String) async throws -> PersonalFileLookupResult {
        var activeCookie = cookie
        var latest = PersonalFileLookupResult(file: nil, updatedCookie: activeCookie)

        for attempt in 0..<pendingPlayPolls {
            if let candidateFID, !candidateFID.isEmpty {
                latest = try await resolveSavedPersonalFile(
                    candidateFID: candidateFID,
                    originalFileName: originalFileName,
                    size: size,
                    appFolderFID: appFolderFID,
                    cookie: activeCookie
                )
            } else {
                latest = try await findPersonalFileRecursively(
                    fileName: originalFileName,
                    size: size,
                    rootFID: appFolderFID,
                    cookie: activeCookie
                )
            }

            activeCookie = latest.updatedCookie
            if latest.file != nil {
                return latest
            }

            DiagnosticLog.write("[QUARK_SAVE_PENDING] file=\(originalFileName) attempt=\(attempt + 1)/\(pendingPlayPolls)")
            if attempt < pendingPlayPolls - 1 {
                try await sleepForPendingPlayback()
            }
        }

        return latest
    }

    func personalPlayResult(for record: DriveSavedFileRecord, cookie: String) async throws -> QuarkDownloadResult {
        var fallbackURL: String?
        var activeCookie = cookie
        do {
            let playResult = try await fetchPersonalPlayURLResult(fid: record.savedFID, fileName: record.savedFileName, cookie: cookie)
            activeCookie = playResult.updatedCookie
            if let url = playResult.transcodedURL, !url.isEmpty {
                fallbackURL = url
            }
        } catch {
            guard Self.shouldFallbackFromPersonalPlayToDownload(error) else {
                throw error
            }
            DiagnosticLog.write("[QUARK_LINK_SELECT] type=\(QuarkPlayableURLType.personalDownload.rawValue) context=personal-play-error file=\(record.savedFileName), reason=\(error.localizedDescription)")
        }

        do {
            return try await personalDownloadFallbackResult(
                for: record,
                cookie: activeCookie,
                reason: fallbackURL == nil ? "official-play-missing" : "personal-original-preferred",
                fallbackURL: fallbackURL
            )
        } catch {
            if let fallbackURL, !fallbackURL.isEmpty {
                DiagnosticLog.write("[QUARK_LINK_SELECT] type=\(QuarkPlayableURLType.transcodedM3U8.rawValue) context=personal-original-error file=\(record.savedFileName), reason=\(error.localizedDescription)")
                return QuarkDownloadResult(url: fallbackURL, updatedCookie: activeCookie, savedFile: record)
            }
            throw error
        }
    }

    func personalPlayResultWaitingIfNeeded(for record: DriveSavedFileRecord, cookie: String) async throws -> QuarkDownloadResult {
        var lastError: Error?

        for attempt in 0..<pendingPlayPolls {
            do {
                return try await personalPlayResult(for: record, cookie: cookie)
            } catch {
                if Self.shouldInvalidateSavedRecord(error) || !Self.shouldWaitForPersonalPlayback(error) {
                    throw error
                }
                lastError = error
                DiagnosticLog.write("[QUARK_PLAY_PENDING] file=\(record.savedFileName) attempt=\(attempt + 1)/\(pendingPlayPolls) reason=\(error.localizedDescription)")
                if attempt < pendingPlayPolls - 1 {
                    try await sleepForPendingPlayback()
                }
            }
        }

        if let lastError {
            DiagnosticLog.write("[QUARK_PLAY_PENDING_TIMEOUT] file=\(record.savedFileName) reason=\(lastError.localizedDescription)")
        }
        throw DriveEngineError.officialPlayURLPending(record.originalName)
    }

    private func sleepForPendingPlayback() async throws {
        guard pendingPlayIntervalMilliseconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(pendingPlayIntervalMilliseconds) * 1_000_000)
    }

    func personalDownloadFallbackResult(for record: DriveSavedFileRecord, cookie: String, reason: String, fallbackURL: String? = nil) async throws -> QuarkDownloadResult {
        let result = try await fetchPersonalDownloadURLResult(fid: record.savedFID, fileName: record.savedFileName, cookie: cookie)
        if let url = result.url, !url.isEmpty {
            DiagnosticLog.write("[QUARK_LINK_SELECT] type=\(QuarkPlayableURLType.personalDownload.rawValue) context=\(reason) url=\(Self.redactedURL(url))")
            return QuarkDownloadResult(url: url, updatedCookie: result.updatedCookie, savedFile: record, fallbackURL: fallbackURL)
        }
        throw DriveEngineError.noDownloadURL(record.originalName)
    }

    func renamePersonalFile(fid: String, fileName: String, cookie: String) async throws -> JSONRequestResult {
        try await postJSONResult(
            url: Self.apiURL(base: Self.accountAPIBase, path: "/1/clouddrive/file/rename"),
            headers: accountHeaders(cookie: cookie),
            body: [
                "fid": fid,
                "file_name": fileName
            ]
        )
    }

    func deletePersonalFile(fid: String, cookie: String) async throws -> String {
        let result = try await postJSONResult(
            url: Self.apiURL(base: Self.accountAPIBase, path: "/1/clouddrive/file/delete"),
            headers: accountHeaders(cookie: cookie),
            body: [
                "action_type": 2,
                "filelist": [fid],
                "exclude_fids": []
            ]
        )
        return result.updatedCookie
    }

    func fetchPersonalDownloadURLResult(fid: String, fileName: String, cookie: String) async throws -> QuarkDownloadResult {
        let result = try await postJSONResult(
            url: Self.apiURL(base: Self.accountAPIBase, path: "/1/clouddrive/file/download"),
            headers: accountHeaders(cookie: cookie),
            body: ["fids": [fid]]
        )
        if let data = result.json["data"] as? [[String: Any]],
           let first = data.first,
           let downloadURL = Self.stringValue(first["download_url"]) ?? Self.stringValue(first["url"]),
           !downloadURL.isEmpty {
            return QuarkDownloadResult(url: downloadURL, updatedCookie: result.updatedCookie)
        }
        throw DriveEngineError.noDownloadURL(fileName)
    }

    func fetchPersonalPlayURLResult(fid: String, fileName _: String, cookie: String) async throws -> QuarkPlayResult {
        let result = try await postJSONResult(
            url: Self.apiURL(base: Self.accountAPIBase, path: "/1/clouddrive/file/v2/play"),
            headers: accountHeaders(cookie: cookie),
            body: [
                "fid": fid,
                "resolutions": "4k,2k,super,high,normal,low",
                "supports": "fmp4,m3u8"
            ]
        )
        guard let data = result.json["data"] as? [String: Any] else {
            return QuarkPlayResult(url: nil, updatedCookie: result.updatedCookie)
        }
        return Self.playResult(in: data, updatedCookie: result.updatedCookie)
    }

    func listPersonalFiles(parentFID: String, cookie: String) async throws -> (files: [PersonalFile], updatedCookie: String) {
        let result = try await getJSONResult(
            url: Self.apiURL(base: Self.pcAPIBase, path: "/1/clouddrive/file/sort", queryItems: [
                URLQueryItem(name: "pdir_fid", value: parentFID),
                URLQueryItem(name: "_page", value: "1"),
                URLQueryItem(name: "_size", value: "100"),
                URLQueryItem(name: "_fetch_total", value: "1"),
                URLQueryItem(name: "fetch_all_file", value: "1"),
                URLQueryItem(name: "fetch_risk_file_name", value: "1"),
                URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc")
            ]),
            headers: accountHeaders(cookie: cookie)
        )
        let data = result.json["data"] as? [String: Any]
        let rawList = data?["list"] as? [[String: Any]]
            ?? data?["file_list"] as? [[String: Any]]
            ?? []
        return (rawList.compactMap(Self.parsePersonalFile), result.updatedCookie)
    }

    static func parseShareFile(_ raw: [String: Any]) -> QuarkShareFile? {
        guard let fid = stringValue(raw["fid"]),
              let name = stringValue(raw["file_name"]) else {
            return nil
        }

        return QuarkShareFile(
            fid: fid,
            name: name,
            pdirFID: stringValue(raw["pdir_fid"]) ?? "",
            category: intValue(raw["category"]) ?? 0,
            fileType: intValue(raw["file_type"]) ?? 0,
            size: int64Value(raw["size"]) ?? 0,
            formatType: stringValue(raw["format_type"]) ?? "",
            isDirectory: boolValue(raw["dir"]) ?? false,
            isFile: boolValue(raw["file"]) ?? false,
            shareFIDToken: stringValue(raw["share_fid_token"]) ?? ""
        )
    }

    static func parsePersonalFile(_ raw: [String: Any]) -> PersonalFile? {
        guard let fid = stringValue(raw["fid"]) ?? stringValue(raw["file_id"]),
              let name = stringValue(raw["file_name"]) ?? stringValue(raw["name"]) else {
            return nil
        }
        let fileType = intValue(raw["file_type"]) ?? 0
        let category = intValue(raw["category"]) ?? 0
        let isDirectory = boolValue(raw["dir"]) ?? (fileType == 0 && category == 0)
        let isFile = boolValue(raw["file"]) ?? !isDirectory
        return PersonalFile(
            fid: fid,
            name: name,
            pdirFID: stringValue(raw["pdir_fid"]) ?? stringValue(raw["parent_fid"]) ?? "",
            size: int64Value(raw["size"]) ?? 0,
            fileType: fileType,
            category: category,
            isDirectory: isDirectory,
            isFile: isFile
        )
    }

    func requestHeaders(
        share: QuarkShareRequest,
        cookie: String?,
        stoken: String? = nil,
        includeContentType: Bool = true
    ) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": Self.userAgent,
            "Referer": "https://pan.quark.cn/s/\(share.pwdID)",
            "Origin": "https://pan.quark.cn",
            "Accept": "application/json, text/plain, */*"
        ]
        if includeContentType {
            headers["Content-Type"] = "application/json;charset=UTF-8"
        }
        if let cookie, !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["Cookie"] = cookie
        }
        if let stoken {
            headers["x-clouddrive-st"] = stoken
        }
        return headers
    }

    func accountHeaders(cookie: String) -> [String: String] {
        [
            "User-Agent": Self.accountUserAgent,
            "Referer": "https://pan.quark.cn",
            "Origin": "https://pan.quark.cn",
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json;charset=UTF-8",
            "Cookie": cookie
        ]
    }

    func postJSON(url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        try await postJSONResult(url: url, headers: headers, body: body).json
    }

    func postJSONResult(url: String, headers: [String: String], body: [String: Any]) async throws -> JSONRequestResult {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response = try await httpClient.post(url: url, headers: headers, body: bodyData, timeout: 30)
        let json = try decodeAPIResponse(response)
        return JSONRequestResult(
            json: json,
            updatedCookie: Self.updatedCookie(from: response, existingCookie: headers["Cookie"] ?? "")
        )
    }

    func getJSON(url: String, headers: [String: String]) async throws -> [String: Any] {
        try await getJSONResult(url: url, headers: headers).json
    }

    func getJSONResult(url: String, headers: [String: String]) async throws -> JSONRequestResult {
        let response = try await httpClient.get(url: url, headers: headers, timeout: 30)
        let json = try decodeAPIResponse(response)
        return JSONRequestResult(
            json: json,
            updatedCookie: Self.updatedCookie(from: response, existingCookie: headers["Cookie"] ?? "")
        )
    }

    func decodeAPIResponse(_ response: HTTPResponse) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        let code = Self.intValue(json?["code"])
        let message = Self.stringValue(json?["message"]) ?? Self.stringValue(json?["msg"]) ?? response.text

        if response.statusCode == 401 || code == 31001 {
            throw DriveEngineError.loginRequired(.quark)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw DriveEngineError.api(provider: .quark, statusCode: response.statusCode, code: code, message: message)
        }
        if let code, code != 0 {
            throw DriveEngineError.api(provider: .quark, statusCode: response.statusCode, code: code, message: message)
        }
        guard let json else {
            throw DriveEngineError.api(provider: .quark, statusCode: response.statusCode, code: nil, message: "响应不是 JSON")
        }
        return json
    }

    static func parseWebShare(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        if let sIndex = parts.firstIndex(of: "s"), parts.indices.contains(sIndex + 1) {
            return parts[sIndex + 1]
        }
        return parts.last
    }

    static func parseQuarkScheme(_ url: URL) -> String? {
        let host = url.host ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "s", let first = parts.first {
            return first
        }
        if !host.isEmpty, host != "pan.quark.cn" {
            return host
        }
        if let sIndex = parts.firstIndex(of: "s"), parts.indices.contains(sIndex + 1) {
            return parts[sIndex + 1]
        }
        return parts.last
    }

    static func value(for names: [String], in queryItems: [URLQueryItem]) -> String? {
        for name in names {
            if let value = queryItems.first(where: { $0.name.lowercased() == name })?.value,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func apiURL(base: String, path: String, queryItems: [URLQueryItem] = []) -> String {
        var components = URLComponents(string: base + path)
        var items = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc")
        ]
        items.append(contentsOf: queryItems)
        components?.queryItems = items
        return components?.url?.absoluteString ?? base + path
    }

    static func updatedCookie(from response: HTTPResponse, existingCookie: String) -> String {
        guard let setCookie = response.headers.first(where: { $0.key.lowercased() == "set-cookie" })?.value,
              !setCookie.isEmpty else {
            return existingCookie
        }

        var cookie = existingCookie
        for name in ["__puus", "__pus"] {
            if let value = cookieValue(named: name, in: setCookie), !value.isEmpty {
                cookie = settingCookie(cookie, name: name, value: value)
            }
        }
        return cookie
    }

    static func cookieValue(named name: String, in setCookie: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:^|[,;]\\s*)\(escaped)=([^;,]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(setCookie.startIndex..<setCookie.endIndex, in: setCookie)
        guard let match = regex.firstMatch(in: setCookie, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: setCookie) else {
            return nil
        }
        return String(setCookie[valueRange])
    }

    static func settingCookie(_ rawCookie: String, name: String, value: String) -> String {
        var pairs = rawCookie
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let prefix = "\(name)="
        if let index = pairs.firstIndex(where: { $0.hasPrefix(prefix) }) {
            pairs[index] = "\(name)=\(value)"
        } else {
            pairs.append("\(name)=\(value)")
        }
        return pairs.joined(separator: "; ")
    }

    static func bestPlayableURL(in data: [String: Any]) -> String? {
        let selection = bestPlayableURLSelection(in: data)
        DiagnosticLog.write("[QUARK_LINK_SELECT] type=\(selection?.type.rawValue ?? "none") url=\(redactedURL(selection?.url ?? ""))")
        return selection?.url
    }

    static func playResult(in data: [String: Any], updatedCookie: String) -> QuarkPlayResult {
        let selection = bestPlayableURLSelection(in: data)
        DiagnosticLog.write("[QUARK_LINK_SELECT] type=\(selection?.type.rawValue ?? "none") url=\(redactedURL(selection?.url ?? ""))")
        return QuarkPlayResult(
            url: selection?.url,
            updatedCookie: updatedCookie,
            isTranscoded: selection?.type == .transcodedM3U8
        )
    }

    static func bestPlayableURLSelection(in data: [String: Any]) -> QuarkPlayableURLSelection? {
        var rejected: QuarkPlayableURLSelection?
        let defaultResolution = stringValue(data["default_resolution"])?.lowercased()
        func accept(
            _ rawURL: String?,
            resolution: String? = nil,
            transcoded: Bool? = nil
        ) -> QuarkPlayableURLSelection? {
            guard let rawURL, !rawURL.isEmpty else { return nil }
            let selection = QuarkPlayableURLSelection(rawURL)
            if selection.url != nil {
                if let resolution {
                    DiagnosticLog.write(
                        "[QUARK_QUALITY_SELECT] default=\(defaultResolution ?? "none") selected=\(resolution) transcoded=\(transcoded == true)"
                    )
                }
                return selection
            }
            rejected = rejected ?? selection
            return nil
        }

        if let videoList = data["video_list"] as? [[String: Any]] {
            let preferredResolutions = preferredVideoResolutions(in: data)
            for resolution in preferredResolutions {
                for item in videoList where stringValue(item["resolution"])?.lowercased() == resolution && isTranscodedM3U8Item(item) {
                    for url in playableURLs(fromVideoListItem: item) {
                        if let selection = accept(url, resolution: resolution, transcoded: true) {
                            return selection
                        }
                    }
                }
            }
            for resolution in preferredResolutions {
                for item in videoList where stringValue(item["resolution"])?.lowercased() == resolution {
                    for url in playableURLs(fromVideoListItem: item) {
                        if let selection = accept(url, resolution: resolution, transcoded: false) {
                            return selection
                        }
                    }
                }
            }
            for item in videoList {
                for url in playableURLs(fromVideoListItem: item) {
                    if let selection = accept(
                        url,
                        resolution: stringValue(item["resolution"])?.lowercased(),
                        transcoded: isTranscodedM3U8Item(item)
                    ) {
                        return selection
                    }
                }
            }
        }

        if let playInfo = data["play_info"] as? [String: Any],
           let selection = accept(stringValue(playInfo["url"])) {
            return selection
        }

        if let selection = accept(stringValue(data["download_url"]) ?? stringValue(data["url"])) {
            return selection
        }
        return rejected
    }

    static func preferredVideoResolutions(in data: [String: Any]) -> [String] {
        var ordered = ["super", "high", "normal", "low", "2k", "4k"]
        if let defaultResolution = stringValue(data["default_resolution"])?.lowercased(),
           !defaultResolution.isEmpty {
            ordered.removeAll { $0 == defaultResolution }
            ordered.insert(defaultResolution, at: 0)
        }
        return ordered
    }

    static func isTranscodedM3U8Item(_ item: [String: Any]) -> Bool {
        let status = (stringValue(item["trans_status"]) ?? "").lowercased()
        let urls = playableURLs(fromVideoListItem: item)
        guard urls.contains(where: { $0.lowercased().contains(".m3u8") }) else {
            return false
        }
        return status.isEmpty || status == "success" || status == "finished"
    }

    static func playableURLs(fromVideoListItem item: [String: Any]) -> [String] {
        var urls: [String] = []
        if let videoInfo = item["video_info"] as? [String: Any],
           let url = stringValue(videoInfo["url"]),
           !url.isEmpty {
            urls.append(url)
        }
        if let url = stringValue(item["url"]), !url.isEmpty {
            urls.append(url)
        }
        return urls
    }

    static func redactedURL(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else { return rawURL }
        components.queryItems = components.queryItems?.map { item in
            switch item.name.lowercased() {
            case "auth_key", "token", "signature", "ossaccesskeyid", "callback", "callback-var":
                return URLQueryItem(name: item.name, value: "<redacted>")
            default:
                return item
            }
        }
        return components.string ?? rawURL
    }

    static func shouldFallbackFromPersonalPlayToDownload(_ error: Error) -> Bool {
        guard case .api(.quark, _, let code, let message) = error as? DriveEngineError else {
            return false
        }
        if code == 14018 || code == 21005 { return true }
        return message.localizedCaseInsensitiveContains("plf_invalid")
            || message.localizedCaseInsensitiveContains("not video")
    }

    static func shouldWaitForPersonalPlayback(_ error: Error) -> Bool {
        guard let driveError = error as? DriveEngineError else {
            return false
        }
        switch driveError {
        case .officialPlayURLPending, .noDownloadURL:
            return true
        case .api:
            return shouldFallbackFromPersonalPlayToDownload(error)
        case .invalidShareURL, .unsupported, .loginRequired, .noPlayableFile:
            return false
        }
    }

    static func shouldInvalidateSavedRecord(_ error: Error) -> Bool {
        guard case .api(.quark, let statusCode, let code, let message) = error as? DriveEngineError else {
            return false
        }
        if statusCode == 404 || statusCode == 410 {
            return true
        }
        if let code, [31005, 32003, 32004, 41017].contains(code) {
            return true
        }
        let lower = message.lowercased()
        return lower.contains("not exist")
            || lower.contains("not found")
            || lower.contains("不存在")
            || lower.contains("文件已删除")
            || lower.contains("无权限")
    }

    static func firstString(in json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(json[key]), !value.isEmpty {
                return value
            }
            if let array = json[key] as? [Any],
               let value = array.compactMap(stringValue).first(where: { !$0.isEmpty }) {
                return value
            }
        }
        return nil
    }

    static func savedFID(in json: Any, excluding originalFID: String?, matching fileName: String?) -> String? {
        if let fileName,
           let fid = fidForFile(named: fileName, in: json, excluding: originalFID) {
            return fid
        }
        let priorityKeys = [
            "save_as_top_fids",
            "save_as_fids",
            "saved_fids",
            "to_fids",
            "target_fids",
            "fid_list"
        ]
        if let fid = firstFID(in: json, keys: priorityKeys, excluding: originalFID) {
            return fid
        }
        return firstFID(in: json, keys: ["save_as_fid", "saved_fid", "target_fid", "to_fid", "fid"], excluding: originalFID)
    }

    static func fidForFile(named fileName: String, in value: Any, excluding originalFID: String?) -> String? {
        if let dictionary = value as? [String: Any] {
            let name = stringValue(dictionary["file_name"]) ?? stringValue(dictionary["name"])
            if name == fileName,
               let fid = stringValue(dictionary["fid"]) ?? stringValue(dictionary["file_id"]),
               fid != originalFID {
                return fid
            }
            for child in dictionary.values {
                if let fid = fidForFile(named: fileName, in: child, excluding: originalFID) {
                    return fid
                }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let fid = fidForFile(named: fileName, in: child, excluding: originalFID) {
                    return fid
                }
            }
        }
        return nil
    }

    static func firstFID(in value: Any, keys: [String], excluding originalFID: String?) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let fid = stringValue(dictionary[key]), !fid.isEmpty, fid != originalFID {
                    return fid
                }
                if let array = dictionary[key] as? [Any],
                   let fid = array.compactMap(stringValue).first(where: { !$0.isEmpty && $0 != originalFID }) {
                    return fid
                }
            }
            for child in dictionary.values {
                if let fid = firstFID(in: child, keys: keys, excluding: originalFID) {
                    return fid
                }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let fid = firstFID(in: child, keys: keys, excluding: originalFID) {
                    return fid
                }
            }
        }
        return nil
    }

    static func taskDidFinish(_ data: [String: Any]) -> Bool {
        if let status = intValue(data["status"]) ?? intValue(data["task_status"]),
           status == 2 || status == 3 {
            return true
        }
        if let status = stringValue(data["status"]) ?? stringValue(data["task_status"]),
           ["finish", "finished", "success", "done"].contains(status.lowercased()) {
            return true
        }
        return boolValue(data["finished"]) == true || boolValue(data["success"]) == true
    }

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func int64Value(_ value: Any?) -> Int64? {
        if let int64 = value as? Int64 { return int64 }
        if let int = value as? Int { return Int64(int) }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
