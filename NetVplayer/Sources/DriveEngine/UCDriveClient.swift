// DriveEngine/UCDriveClient.swift
// UC drive share listing and first playable link support.

import Foundation
import Models
import Networking

public struct UCShareRequest: Sendable {
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

public struct UCShareFile: Sendable {
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

    public var isPlayableVideo: Bool {
        UCPlayableFileClassifier.isPlayableVideo(
            name: name,
            formatType: formatType,
            isDirectory: isDirectory,
            isFile: isFile
        )
    }

    public var isKnownNonVideoAsset: Bool {
        UCPlayableFileClassifier.isKnownNonVideoAsset(name: name)
    }
}

public struct UCPlayableFile: Sendable {
    public let file: UCShareFile
    public let stoken: String
}

public struct UCPlayableSelection: Sendable, Equatable {
    public let url: String
    public let selectedReason: String
    public let candidateSummary: String

    public init(url: String, selectedReason: String, candidateSummary: String) {
        self.url = url
        self.selectedReason = selectedReason
        self.candidateSummary = candidateSummary
    }
}

public struct UCDownloadResult: Sendable {
    public let url: String?
    public let updatedCookie: String
    public let savedFile: DriveSavedFileRecord?
    public let playbackUserAgent: String?
    public let playbackRoute: String?
    public let selectedReason: String?
    public let candidateSummary: String?

    public init(
        url: String?,
        updatedCookie: String,
        savedFile: DriveSavedFileRecord? = nil,
        playbackUserAgent: String? = nil,
        playbackRoute: String? = nil,
        selectedReason: String? = nil,
        candidateSummary: String? = nil
    ) {
        self.url = url
        self.updatedCookie = updatedCookie
        self.savedFile = savedFile
        self.playbackUserAgent = playbackUserAgent
        self.playbackRoute = playbackRoute
        self.selectedReason = selectedReason
        self.candidateSummary = candidateSummary
    }
}

public struct UCPlayResult: Sendable {
    public let url: String?
    public let updatedCookie: String
    public let selectedReason: String?
    public let candidateSummary: String?

    public init(url: String?, updatedCookie: String, selection: UCPlayableSelection? = nil) {
        self.url = url
        self.updatedCookie = updatedCookie
        self.selectedReason = selection?.selectedReason
        self.candidateSummary = selection?.candidateSummary
    }
}

public struct UCDownloadProbe: Sendable {
    public let userAgent: String
    public let statusCode: Int
    public let contentLength: Int64?
    public let contentRangeTotal: Int64?
    public let contentType: String

    public var returnedSize: Int64? {
        contentRangeTotal ?? contentLength
    }
}

private enum UCPlayableFileClassifier {
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
        "video", "mpegurl", "m3u8", "mp4", "matroska", "quicktime", "webm", "x-flv", "x-msvideo"
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

public final class UCDriveClient: @unchecked Sendable {
    private static let apiBase = "https://pc-api.uc.cn"
    public static let accountPlaybackUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    public static let mobileBrowserPlaybackUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/100.0.4896.58 UCBrowser/16.5.8.1309 Mobile Safari/537.36"
    private static let userAgent = accountPlaybackUserAgent
    private static let downloadProbeUserAgents = [
        mobileBrowserPlaybackUserAgent,
        accountPlaybackUserAgent
    ]
    private static let pageSize = 200
    private static let maxDirectories = 32
    private static let maxPagesPerDirectory = 8
    private static let maxTaskPolls = 20
    private static let driveReferer = "https://drive.uc.cn/"
    private static let originalProbeRange = "bytes=0-4194303"
    private static let originalPlaybackBootstrapPwdID = "d0d8d587c9e94"

    private let httpClient: HTTPClient
    private let pendingPlayPolls: Int
    private let pendingPlayIntervalMilliseconds: Int
    private let originalPlaybackTokenProvider: @Sendable () -> String?
    private let originalPlaybackTokenUpdateHandler: @Sendable (String) -> Void
    private let originalPlaybackTokenLock = NSLock()
    private var cachedOriginalPlaybackToken: String?

    public init(
        httpClient: HTTPClient = .shared,
        pendingPlayPolls: Int = 15,
        pendingPlayIntervalMilliseconds: Int = 2_000,
        originalPlaybackTokenProvider: @escaping @Sendable () -> String? = { nil },
        originalPlaybackTokenUpdateHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.httpClient = httpClient
        self.pendingPlayPolls = max(1, pendingPlayPolls)
        self.pendingPlayIntervalMilliseconds = max(0, pendingPlayIntervalMilliseconds)
        self.originalPlaybackTokenProvider = originalPlaybackTokenProvider
        self.originalPlaybackTokenUpdateHandler = originalPlaybackTokenUpdateHandler
    }

    public func shareRequest(from rawURL: String) throws -> UCShareRequest {
        if let reference = DriveFileReference.parse(rawURL), reference.provider == .uc {
            return UCShareRequest(
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
        if scheme == "uc" {
            pwdID = Self.parseUCScheme(url)
        } else {
            pwdID = Self.parseWebShare(url)
        }

        guard let pwdID, !pwdID.isEmpty else {
            throw DriveEngineError.invalidShareURL(rawURL)
        }

        return UCShareRequest(
            originalURL: rawURL,
            pwdID: pwdID,
            passcode: passcode,
            requestedFileName: requestedFileName
        )
    }

    public func collectPlayableFiles(share: UCShareRequest, cookie: String? = nil) async throws -> [UCPlayableFile] {
        var playableFiles: [UCPlayableFile] = []
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
                        playableFiles.append(UCPlayableFile(file: item, stoken: result.stoken))
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
            DiagnosticLog.write("[UC_SHARE_FILTER] filtered non-video assets count=\(filteredAssetNames.count) names=\(sample)")
        }

        return playableFiles.sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
    }

    public func selectPlayableFile(from files: [UCPlayableFile], share: UCShareRequest) -> UCPlayableFile? {
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

    public func fileReference(for playable: UCPlayableFile, share: UCShareRequest, collectionName: String = "") -> DriveFileReference {
        DriveFileReference(
            provider: .uc,
            shareURL: share.originalURL,
            pwdID: share.pwdID,
            passcode: share.passcode,
            fid: playable.file.fid,
            fidToken: playable.file.shareFIDToken,
            fileName: playable.file.name,
            collectionName: collectionName
        )
    }

    public func validateAccountCookie(_ cookie: String) async throws -> String {
        let result = try await getJSONResult(
            url: Self.apiURL(path: "/1/clouddrive/config"),
            headers: accountHeaders(cookie: cookie)
        )
        return result.updatedCookie
    }

    public func fetchSavedDownloadURLResult(for playable: UCPlayableFile, share: UCShareRequest, cookie: String) async throws -> UCDownloadResult {
        var activeCookie = cookie
        let identity = DriveSavedFileNaming.identity(provider: .uc, pwdID: share.pwdID, file: playable.file)
        let folder = try await ensureTransferFolder(for: share, cookie: activeCookie)
        activeCookie = folder.updatedCookie

        if let cached = await DriveSavedFileStore.shared.record(for: identity) {
            let matchesTargetFolder = cached.provider == .uc
                && cached.parentFID == folder.fid
            if !matchesTargetFolder {
                try? await DriveSavedFileStore.shared.remove(cacheKey: identity.cacheKey)
                DiagnosticLog.write("[UC_SAVED_CACHE] invalidated cacheKey=\(identity.cacheKey) fid=\(cached.savedFID) reason=transfer-folder-mismatch")
            } else {
                do {
                    return try await personalDownloadResultWaitingIfNeeded(for: cached, cookie: activeCookie)
                } catch {
                    if Self.shouldInvalidateSavedRecord(error) {
                        try? await DriveSavedFileStore.shared.remove(cacheKey: identity.cacheKey)
                        DiagnosticLog.write("[UC_SAVED_CACHE] invalidated cacheKey=\(identity.cacheKey) fid=\(cached.savedFID) reason=\(error.localizedDescription)")
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
                    provider: .uc,
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
                DiagnosticLog.write("[UC_SAVED_CACHE] reused hash-file cacheKey=\(identity.cacheKey) fid=\(file.fid) file=\(file.name)")
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
                provider: .uc,
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
            DiagnosticLog.write("[UC_SAVED_CACHE] saved cacheKey=\(identity.cacheKey) fid=\(savedFile.fid) file=\(identity.targetFileName)")
            return DriveSavedFileTransferResult(record: record, updatedCookie: transferCookie)
        }

        activeCookie = transferResult.updatedCookie
        do {
            return try await personalDownloadResultWaitingIfNeeded(for: transferResult.record, cookie: activeCookie)
        } catch {
            if Self.shouldInvalidateSavedRecord(error) {
                try? await DriveSavedFileStore.shared.remove(cacheKey: identity.cacheKey)
                DiagnosticLog.write("[UC_SAVED_CACHE] invalidated cacheKey=\(identity.cacheKey) fid=\(transferResult.record.savedFID) reason=\(error.localizedDescription)")
            }
            if Self.shouldWaitForPersonalPlayback(error) {
                DiagnosticLog.write("[UC_LINK_SELECT] type=rejected-pds-download context=personal-play-error file=\(playable.file.name), reason=\(error.localizedDescription)")
                throw DriveEngineError.officialPlayURLPending(playable.file.name)
            }
            throw error
        }
    }

    func fetchSavedPersonalPlayURLResult(for playable: UCPlayableFile, share: UCShareRequest, cookie: String) async throws -> UCDownloadResult {
        let savedResult = try await fetchSavedDownloadURLResult(for: playable, share: share, cookie: cookie)
        if savedResult.playbackRoute == DrivePlaybackRoute.ucSmartPlay {
            return savedResult
        }
        guard let savedFile = savedResult.savedFile else {
            throw DriveEngineError.noDownloadURL(playable.file.name)
        }
        let playResult = try await personalPlayResultWaitingIfNeeded(
            for: savedFile,
            cookie: savedResult.updatedCookie
        )
        guard playResult.playbackRoute == DrivePlaybackRoute.ucSmartPlay else {
            throw DriveEngineError.noDownloadURL(playable.file.name)
        }
        return playResult
    }

    private func validateDownloadURL(_ url: String, record: DriveSavedFileRecord, cookie: String, mode: DownloadProbeMode = .strictOriginalSize) async throws -> String? {
        try await validateDownloadURL(
            url,
            expectedSize: record.size,
            fileName: record.originalName,
            cookie: cookie,
            referer: Self.driveReferer,
            stoken: nil,
            mode: mode
        )
    }

    private func validateDownloadURL(
        _ url: String,
        expectedSize: Int64,
        fileName: String,
        cookie: String,
        referer: String,
        stoken: String?,
        mode: DownloadProbeMode
    ) async throws -> String? {
        guard expectedSize >= Self.minDownloadProbeExpectedSize else {
            return nil
        }

        var lastAPIError: DriveEngineError?
        var lastSuspiciousReturnedSize: Int64?

        for userAgent in Self.downloadProbeUserAgents {
            let probe = try await probeDownloadURL(
                url,
                cookie: cookie,
                referer: referer,
                stoken: stoken,
                userAgent: userAgent
            )
            let uaLabel = Self.userAgentLogLabel(userAgent)
            guard (200..<400).contains(probe.statusCode) else {
                lastAPIError = DriveEngineError.api(
                    provider: .uc,
                    statusCode: probe.statusCode,
                    code: nil,
                    message: "UC 下载链接探测失败"
                )
                DiagnosticLog.write("[UC_DOWNLOAD_PROBE] file=\(fileName) status=\(probe.statusCode) ua=\(uaLabel)")
                continue
            }
            guard let returnedSize = probe.returnedSize, returnedSize > 0 else {
                DiagnosticLog.write("[UC_DOWNLOAD_PROBE] size unavailable file=\(fileName) expected=\(expectedSize) contentType=\(probe.contentType) ua=\(uaLabel)")
                return userAgent
            }

            DiagnosticLog.write("[UC_DOWNLOAD_PROBE] file=\(fileName) expected=\(expectedSize) returned=\(returnedSize) contentType=\(probe.contentType) ua=\(uaLabel)")

            guard Self.isSuspiciousInterceptSize(expected: expectedSize, returned: returnedSize, mode: mode) else {
                return userAgent
            }
            lastSuspiciousReturnedSize = returnedSize
        }

        if let returnedSize = lastSuspiciousReturnedSize {
        throw DriveEngineError.unsupported(
            "UC 返回的是会员/UC 浏览器拦截视频，不是目标文件（片源约 \(Self.formatByteCount(expectedSize))，实际返回约 \(Self.formatByteCount(returnedSize))）。请用 UC 浏览器或会员账号打开，或切换夸克/其他线路。"
        )
        }
        if let lastAPIError {
            throw lastAPIError
        }
        throw DriveEngineError.api(provider: .uc, statusCode: 0, code: nil, message: "UC 下载链接探测失败")
    }
}

private extension UCDriveClient {
    static let minDownloadProbeExpectedSize: Int64 = 128 * 1024 * 1024
    static let suspiciousReturnedSizeLimit: Int64 = 64 * 1024 * 1024

    enum DownloadProbeMode {
        case strictOriginalSize
        case allowTranscodedPlay
    }

    struct ShareListResult: Sendable {
        let stoken: String
        let list: [UCShareFile]
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
            UCPlayableFileClassifier.isPlayableVideo(
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

    struct OriginalPlaybackSession {
        let token: String
        let updatedCookie: String
        let reusedToken: Bool
    }

    func loadShareList(share: UCShareRequest, pdirFID: String, page: Int, cookie: String?) async throws -> ShareListResult {
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
            url: Self.apiURL(path: "/1/clouddrive/share/sharepage/v2/detail", queryItems: [
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
            throw DriveEngineError.api(provider: .uc, statusCode: 200, code: nil, message: "UC 分享列表响应结构异常")
        }

        return ShareListResult(stoken: stoken, list: rawList.compactMap(Self.parseShareFile))
    }

    func ensureAppFolder(cookie: String) async throws -> AppFolderResult {
        let root = try await listPersonalFiles(parentFID: "0", cookie: cookie)
        if let existing = root.files.first(where: { $0.isDirectory && $0.name == DriveTransferDirectoryPolicy.rootFolderName }) {
            return AppFolderResult(fid: existing.fid, updatedCookie: root.updatedCookie)
        }

        let result = try await postJSONResult(
            url: Self.apiURL(path: "/1/clouddrive/file"),
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

        throw DriveEngineError.api(provider: .uc, statusCode: 200, code: nil, message: "无法创建或定位 NetVplayer 转存文件夹")
    }

    func ensureTransferFolder(for share: UCShareRequest, cookie: String) async throws -> AppFolderResult {
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
            url: Self.apiURL(path: "/1/clouddrive/file"),
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

        throw DriveEngineError.api(provider: .uc, statusCode: 200, code: nil, message: "无法创建或定位 \(name) 转存文件夹")
    }

    func saveShareFileToPersonalDrive(
        playable: UCPlayableFile,
        share: UCShareRequest,
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
            url: Self.apiURL(path: "/1/clouddrive/share/sharepage/save"),
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
                url: Self.apiURL(path: "/1/clouddrive/task", queryItems: [
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
        throw DriveEngineError.api(provider: .uc, statusCode: 200, code: nil, message: message)
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
            DiagnosticLog.write("[UC_SAVED_CACHE] save candidate fid=\(candidateFID) name=\(candidate.name) dir=\(candidate.isDirectory) fileType=\(candidate.fileType) category=\(candidate.category) size=\(candidate.size)")

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
                    DiagnosticLog.write("[UC_SAVED_CACHE] save task returned \(containerType) fid=\(candidateFID); resolved nested video fid=\(file.fid) file=\(file.name)")
                    return PersonalFileLookupResult(file: file, updatedCookie: activeCookie)
                }
            }

            if candidate.isPlayableVideoObject {
                return PersonalFileLookupResult(file: candidate, updatedCookie: activeCookie)
            }

            DiagnosticLog.write("[UC_SAVED_CACHE] save task returned non-video fid=\(candidateFID); resolving under app folder file=\(originalFileName)")
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
                    DiagnosticLog.write("[UC_SAVED_CACHE] save task returned external container fid=\(candidateFID); resolved nested video fid=\(file.fid) file=\(file.name)")
                    return PersonalFileLookupResult(file: file, updatedCookie: activeCookie)
                }
            }
        }

        return try await findPersonalFileRecursively(
            fileName: originalFileName,
            size: size,
            rootFID: appFolderFID,
            cookie: activeCookie
        )
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

            DiagnosticLog.write("[UC_SAVE_PENDING] file=\(originalFileName) attempt=\(attempt + 1)/\(pendingPlayPolls)")
            if attempt < pendingPlayPolls - 1 {
                try await sleepForPendingPlayback()
            }
        }

        return latest
    }

    func personalPlayResult(for record: DriveSavedFileRecord, cookie: String) async throws -> UCDownloadResult {
        do {
            let playResult = try await fetchPersonalPlayURLResult(fid: record.savedFID, fileName: record.savedFileName, cookie: cookie)
            if let url = playResult.url, !url.isEmpty {
                var playbackUserAgent: String?
                if Self.isCallbackProtectedURL(url) {
                    playbackUserAgent = try await validateDownloadURL(url, record: record, cookie: playResult.updatedCookie, mode: .allowTranscodedPlay)
                }
                return UCDownloadResult(
                    url: url,
                    updatedCookie: playResult.updatedCookie,
                    savedFile: record,
                    playbackUserAgent: playbackUserAgent,
                    playbackRoute: DrivePlaybackRoute.ucSmartPlay,
                    selectedReason: playResult.selectedReason,
                    candidateSummary: playResult.candidateSummary
                )
            }
            DiagnosticLog.write("[UC_LINK_SELECT] type=rejected-pds-download context=personal-play file=\(record.savedFileName)")
            return try await personalDownloadFallbackResult(for: record, cookie: playResult.updatedCookie, reason: "official-play-missing")
        } catch {
            guard Self.shouldFallbackFromPersonalPlayToDownload(error) else {
                throw error
            }
            DiagnosticLog.write("[UC_LINK_SELECT] type=personal-download context=personal-play-error file=\(record.savedFileName), reason=\(error.localizedDescription)")
            return try await personalDownloadFallbackResult(for: record, cookie: cookie, reason: "official-play-error")
        }
    }

    func personalPlayResultWaitingIfNeeded(for record: DriveSavedFileRecord, cookie: String) async throws -> UCDownloadResult {
        var lastError: Error?

        for attempt in 0..<pendingPlayPolls {
            do {
                return try await personalPlayResult(for: record, cookie: cookie)
            } catch {
                if Self.shouldInvalidateSavedRecord(error) || !Self.shouldWaitForPersonalPlayback(error) {
                    throw error
                }
                lastError = error
                DiagnosticLog.write("[UC_PLAY_PENDING] file=\(record.savedFileName) attempt=\(attempt + 1)/\(pendingPlayPolls) reason=\(error.localizedDescription)")
                if attempt < pendingPlayPolls - 1 {
                    try await sleepForPendingPlayback()
                }
            }
        }

        if let lastError {
            DiagnosticLog.write("[UC_PLAY_PENDING_TIMEOUT] file=\(record.savedFileName) reason=\(lastError.localizedDescription)")
        }
        throw DriveEngineError.officialPlayURLPending(record.originalName)
    }

    func personalDownloadResultWaitingIfNeeded(for record: DriveSavedFileRecord, cookie: String) async throws -> UCDownloadResult {
        var lastError: Error?

        for attempt in 0..<pendingPlayPolls {
            do {
                return try await personalDownloadFallbackResult(for: record, cookie: cookie, reason: "personal-original-preferred")
            } catch {
                if Self.shouldInvalidateSavedRecord(error) || !Self.shouldWaitForPersonalPlayback(error) {
                    DiagnosticLog.write("[UC_LINK_SELECT] type=personal-play context=personal-download-error file=\(record.savedFileName), reason=\(error.localizedDescription)")
                    return try await personalPlayResult(for: record, cookie: cookie)
                }
                lastError = error
                DiagnosticLog.write("[UC_DOWNLOAD_PENDING] file=\(record.savedFileName) attempt=\(attempt + 1)/\(pendingPlayPolls) reason=\(error.localizedDescription)")
                if attempt < pendingPlayPolls - 1 {
                    try await sleepForPendingPlayback()
                }
            }
        }

        if let lastError {
            DiagnosticLog.write("[UC_DOWNLOAD_PENDING_TIMEOUT] file=\(record.savedFileName) reason=\(lastError.localizedDescription)")
        }
        return try await personalPlayResultWaitingIfNeeded(for: record, cookie: cookie)
    }

    func personalDownloadFallbackResult(for record: DriveSavedFileRecord, cookie: String, reason: String) async throws -> UCDownloadResult {
        let result = try await fetchPersonalDownloadURLResult(fid: record.savedFID, fileName: record.savedFileName, cookie: cookie)
        do {
            return try await validatedPersonalDownloadResult(result, record: record, reason: reason)
        } catch {
            guard Self.isSuspiciousOriginalInterceptError(error) else { throw error }
            DiagnosticLog.write("[UC_ORIGINAL_AUTH] ut-refresh context=intercept-video file=\(record.savedFileName)")
            invalidateOriginalPlaybackToken()
            let refreshed = try await fetchPersonalDownloadURLResult(
                fid: record.savedFID,
                fileName: record.savedFileName,
                cookie: result.updatedCookie,
                forceRefreshToken: true
            )
            return try await validatedPersonalDownloadResult(refreshed, record: record, reason: "\(reason)-ut-refreshed")
        }
    }

    func validatedPersonalDownloadResult(
        _ result: UCDownloadResult,
        record: DriveSavedFileRecord,
        reason: String
    ) async throws -> UCDownloadResult {
        if let url = result.url, !url.isEmpty {
            let playbackUserAgent = try await validateDownloadURL(url, record: record, cookie: result.updatedCookie)
            DiagnosticLog.write("[UC_LINK_SELECT] type=personal-download context=\(reason) url=\(Self.redactedURL(url))")
            return UCDownloadResult(
                url: url,
                updatedCookie: result.updatedCookie,
                savedFile: record,
                playbackUserAgent: playbackUserAgent,
                playbackRoute: DrivePlaybackRoute.ucOriginalProxy
            )
        }
        throw DriveEngineError.noDownloadURL(record.originalName)
    }

    private func sleepForPendingPlayback() async throws {
        guard pendingPlayIntervalMilliseconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(pendingPlayIntervalMilliseconds) * 1_000_000)
    }

    func renamePersonalFile(fid: String, fileName: String, cookie: String) async throws -> JSONRequestResult {
        try await postJSONResult(
            url: Self.apiURL(path: "/1/clouddrive/file/rename"),
            headers: accountHeaders(cookie: cookie),
            body: [
                "fid": fid,
                "file_name": fileName
            ]
        )
    }
}

extension UCDriveClient {
    func deleteSavedFile(cacheKey: String, fid: String, cookie: String) async throws -> String {
        let result = try await postJSONResult(
            url: Self.apiURL(path: "/1/clouddrive/file/delete"),
            headers: accountHeaders(cookie: cookie),
            body: [
                "action_type": 2,
                "filelist": [fid],
                "exclude_fids": []
            ]
        )
        try? await DriveSavedFileStore.shared.remove(cacheKey: cacheKey)
        DiagnosticLog.write("[UC_SAVED_CACHE] deleted cacheKey=\(cacheKey) fid=\(fid)")
        return result.updatedCookie
    }
}

extension UCDriveClient {
    func fetchPersonalDownloadURLResult(
        fid: String,
        fileName: String,
        cookie: String,
        forceRefreshToken: Bool = false
    ) async throws -> UCDownloadResult {
        let session: OriginalPlaybackSession?
        do {
            session = try await originalPlaybackSession(cookie: cookie, forceRefresh: forceRefreshToken)
        } catch {
            session = nil
            DiagnosticLog.write("[UC_ORIGINAL_AUTH] ut-bootstrap-failed context=legacy-download-fallback reason=\(error.localizedDescription)")
        }

        do {
            let result = try await personalDownloadJSONResult(
                fid: fid,
                cookie: session?.updatedCookie ?? cookie,
                token: session?.token
            )
            if let download = personalDownloadResult(from: result, fileName: fileName) {
                return download
            }
            if session?.reusedToken != true {
                throw DriveEngineError.noDownloadURL(fileName)
            }
        } catch {
            guard session?.reusedToken == true else { throw error }
        }

        invalidateOriginalPlaybackToken()
        let refreshedSession = try await originalPlaybackSession(cookie: session?.updatedCookie ?? cookie, forceRefresh: true)
        let refreshedResult = try await personalDownloadJSONResult(
            fid: fid,
            cookie: refreshedSession.updatedCookie,
            token: refreshedSession.token
        )
        if let download = personalDownloadResult(from: refreshedResult, fileName: fileName) {
            return download
        }
        throw DriveEngineError.noDownloadURL(fileName)
    }
}

private extension UCDriveClient {
    func personalDownloadJSONResult(fid: String, cookie: String, token: String?) async throws -> JSONRequestResult {
        let queryItems = token.map { [URLQueryItem(name: "ut", value: $0)] } ?? []
        return try await postJSONResult(
            url: Self.apiURL(path: "/1/clouddrive/file/download", queryItems: queryItems),
            headers: accountHeaders(cookie: cookie),
            body: ["fids": [fid]]
        )
    }

    func personalDownloadResult(from result: JSONRequestResult, fileName _: String) -> UCDownloadResult? {
        if let data = result.json["data"] as? [[String: Any]],
           let first = data.first,
           let downloadURL = Self.stringValue(first["download_url"]) ?? Self.stringValue(first["url"]),
           !downloadURL.isEmpty {
            return UCDownloadResult(url: downloadURL, updatedCookie: result.updatedCookie)
        }
        return nil
    }

    func originalPlaybackSession(cookie: String, forceRefresh: Bool = false) async throws -> OriginalPlaybackSession {
        if !forceRefresh {
            if let cached = currentOriginalPlaybackToken() {
                return OriginalPlaybackSession(token: cached, updatedCookie: cookie, reusedToken: true)
            }
            if let stored = Self.normalizedOriginalPlaybackToken(originalPlaybackTokenProvider()) {
                cacheOriginalPlaybackToken(stored)
                return OriginalPlaybackSession(token: stored, updatedCookie: cookie, reusedToken: true)
            }
        }

        let result = try await postJSONResult(
            url: Self.apiURL(path: "/1/clouddrive/share/sharepage/token", queryItems: [
                URLQueryItem(name: "uc_param_str", value: ""),
                URLQueryItem(name: "__dt", value: ""),
                URLQueryItem(name: "__t", value: "")
            ]),
            headers: accountHeaders(cookie: cookie),
            body: [
                "pwd_id": Self.originalPlaybackBootstrapPwdID,
                "passcode": ""
            ]
        )
        guard let token = Self.normalizedOriginalPlaybackToken(cookiePairs(from: result.updatedCookie)["__sdid"]) else {
            throw DriveEngineError.unsupported("UC 原片会话未返回 __sdid。")
        }
        cacheOriginalPlaybackToken(token)
        originalPlaybackTokenUpdateHandler(token)
        DiagnosticLog.write("[UC_ORIGINAL_AUTH] ut-ready source=official-share-session")
        return OriginalPlaybackSession(token: token, updatedCookie: result.updatedCookie, reusedToken: false)
    }

    func currentOriginalPlaybackToken() -> String? {
        originalPlaybackTokenLock.lock()
        defer { originalPlaybackTokenLock.unlock() }
        return cachedOriginalPlaybackToken
    }

    func cacheOriginalPlaybackToken(_ token: String) {
        originalPlaybackTokenLock.lock()
        cachedOriginalPlaybackToken = token
        originalPlaybackTokenLock.unlock()
    }

    func invalidateOriginalPlaybackToken() {
        originalPlaybackTokenLock.lock()
        cachedOriginalPlaybackToken = nil
        originalPlaybackTokenLock.unlock()
        originalPlaybackTokenUpdateHandler("")
    }

    func fetchPersonalPlayURLResult(fid: String, fileName _: String, cookie: String) async throws -> UCPlayResult {
        let result = try await postJSONResult(
            url: Self.apiURL(path: "/1/clouddrive/file/v2/play"),
            headers: accountHeaders(cookie: cookie),
            body: [
                "fid": fid,
                "resolutions": "4k,2k,super,high,normal,low",
                "supports": "fmp4,m3u8"
            ]
        )
        guard let data = result.json["data"] as? [String: Any] else {
            return UCPlayResult(url: nil, updatedCookie: result.updatedCookie)
        }
        let selection = Self.bestPlayableSelection(in: data)
        return UCPlayResult(url: selection?.url, updatedCookie: result.updatedCookie, selection: selection)
    }

    func listPersonalFiles(parentFID: String, cookie: String) async throws -> (files: [PersonalFile], updatedCookie: String) {
        let result = try await getJSONResult(
            url: Self.apiURL(path: "/1/clouddrive/file/sort", queryItems: [
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

    func requestHeaders(
        share: UCShareRequest,
        cookie: String?,
        stoken: String? = nil,
        includeContentType: Bool = true
    ) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": Self.userAgent,
            "Referer": "https://drive.uc.cn/s/\(share.pwdID)",
            "Origin": "https://drive.uc.cn",
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
            "User-Agent": Self.accountPlaybackUserAgent,
            "Referer": "https://drive.uc.cn",
            "Origin": "https://drive.uc.cn",
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json;charset=UTF-8",
            "Cookie": cookie
        ]
    }

    func probeDownloadURL(_ url: String, cookie: String, referer: String, stoken: String?, userAgent: String) async throws -> UCDownloadProbe {
        var headers: [String: String] = [
            "User-Agent": userAgent,
            "Referer": referer,
            "Origin": "https://drive.uc.cn",
            "Cookie": cookie
        ]
        if let stoken {
            headers["x-clouddrive-st"] = stoken
        }
        headers["Accept"] = "*/*"
        headers["Range"] = Self.originalProbeRange

        let response = try await httpClient.request(
            url: url,
            method: .get,
            headers: headers,
            timeout: 20,
            allowsProxyFallback: false
        )

        return UCDownloadProbe(
            userAgent: userAgent,
            statusCode: response.statusCode,
            contentLength: Self.int64HeaderValue("Content-Length", in: response.headers),
            contentRangeTotal: Self.contentRangeTotal(in: response.headers),
            contentType: Self.headerValue("Content-Type", in: response.headers) ?? ""
        )
    }

    func postJSON(url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        try await postJSONResult(url: url, headers: headers, body: body).json
    }

    func getJSONResult(url: String, headers: [String: String]) async throws -> JSONRequestResult {
        let response = try await httpClient.get(url: url, headers: headers, timeout: 20)
        return try decodeJSONResponse(response, fallbackCookie: headers["Cookie"] ?? "")
    }

    func postJSONResult(url: String, headers: [String: String], body: [String: Any]) async throws -> JSONRequestResult {
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await httpClient.post(url: url, headers: headers, body: data, timeout: 20)
        return try decodeJSONResponse(response, fallbackCookie: headers["Cookie"] ?? "")
    }

    func decodeJSONResponse(_ response: HTTPResponse, fallbackCookie: String) throws -> JSONRequestResult {
        guard let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] else {
            throw DriveEngineError.api(provider: .uc, statusCode: response.statusCode, code: nil, message: "响应不是 JSON")
        }
        let status = Self.intValue(json["status"]) ?? 0
        let code = Self.intValue(json["code"]) ?? 0
        if !(200..<300).contains(response.statusCode) || status >= 400 || code != 0 {
            let message = Self.stringValue(json["message"]) ?? Self.stringValue(json["error_info"]) ?? response.text
            throw DriveEngineError.api(provider: .uc, statusCode: response.statusCode, code: code, message: message)
        }
        return JSONRequestResult(json: json, updatedCookie: updatedCookie(from: response, fallback: fallbackCookie))
    }

    func updatedCookie(from response: HTTPResponse, fallback: String) -> String {
        let setCookie = response.headers.first { $0.key.lowercased() == "set-cookie" }?.value ?? ""
        guard !setCookie.isEmpty else { return fallback }
        var values = cookiePairs(from: fallback)
        for pair in setCookie.components(separatedBy: ",") {
            let first = pair.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let parts = first.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1]
        }
        return values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    func cookiePairs(from cookie: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in cookie.components(separatedBy: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1]
        }
        return values
    }

    static func parseShareFile(_ raw: [String: Any]) -> UCShareFile? {
        guard let fid = stringValue(raw["fid"]),
              let name = stringValue(raw["file_name"]) else {
            return nil
        }
        return UCShareFile(
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

    static func bestPlayableSelection(in data: [String: Any]) -> UCPlayableSelection? {
        var candidates: [(url: String, reason: String)] = []
        var candidateSummaries: [String] = []
        let defaultResolution = stringValue(data["default_resolution"]) ?? "-"
        func append(_ urls: [String], reason: String) {
            for url in urls where !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append((url, reason))
            }
        }

        if let videoList = data["video_list"] as? [[String: Any]] {
            candidateSummaries = videoList.prefix(12).map(playCandidateSummary)
            let preferredResolutions = preferredVideoResolutions(in: data)
            for resolution in preferredResolutions {
                for item in videoList where stringValue(item["resolution"])?.lowercased() == resolution && isTranscodedM3U8Item(item) {
                    append(playableURLs(fromVideoListItem: item), reason: "resolution:\(resolution):transcoded-m3u8")
                }
            }
            for resolution in preferredResolutions {
                for item in videoList where stringValue(item["resolution"])?.lowercased() == resolution {
                    append(playableURLs(fromVideoListItem: item), reason: "resolution:\(resolution)")
                }
            }
            for item in videoList {
                let resolution = stringValue(item["resolution"])?.lowercased() ?? "unknown"
                append(playableURLs(fromVideoListItem: item), reason: "fallback-video-list:\(resolution)")
            }
        }

        if let playInfo = data["play_info"] as? [String: Any],
           let url = stringValue(playInfo["url"]),
           !url.isEmpty {
            append([url], reason: "play-info")
        }
        if let url = stringValue(data["download_url"]) ?? stringValue(data["url"]),
           !url.isEmpty {
            append([url], reason: "download-url")
        }

        let uniqueCandidates = uniqueURLSelections(candidates)
        guard let selected = uniqueCandidates.first(where: { !isCallbackProtectedURL($0.url) }) ?? uniqueCandidates.first else {
            return nil
        }
        if !candidateSummaries.isEmpty {
            DiagnosticLog.write("[UC_PLAY_CANDIDATES] default=\(defaultResolution) items=\(candidateSummaries.joined(separator: " | ")) selected=\(playableURLSummary(selected.url)) reason=\(selected.reason)")
        }
        DiagnosticLog.write("[UC_LINK_SELECT] url=\(redactedURL(selected.url)) reason=\(selected.reason)")
        let summary = (["default=\(defaultResolution)"] + candidateSummaries.prefix(8) + ["selected \(playableURLSummary(selected.url))"])
            .joined(separator: " | ")
        return UCPlayableSelection(
            url: selected.url,
            selectedReason: selected.reason,
            candidateSummary: String(summary.prefix(900))
        )
    }

    static func uniqueURLSelections(_ selections: [(url: String, reason: String)]) -> [(url: String, reason: String)] {
        var seen = Set<String>()
        var result: [(url: String, reason: String)] = []
        for selection in selections {
            guard seen.insert(selection.url).inserted else { continue }
            result.append(selection)
        }
        return result
    }

    static func preferredVideoResolutions(in data: [String: Any]) -> [String] {
        var ordered = ["4k", "2k", "super", "high", "normal", "low"]
        if let defaultResolution = stringValue(data["default_resolution"])?.lowercased(),
           !defaultResolution.isEmpty,
           !ordered.contains(defaultResolution) {
            ordered.append(defaultResolution)
        }
        return ordered
    }

    static func playCandidateSummary(_ item: [String: Any]) -> String {
        let resolution = stringValue(item["resolution"]) ?? "-"
        let status = stringValue(item["trans_status"]) ?? stringValue(item["status"]) ?? "-"
        let accessable = stringValue(item["accessable"]) ?? stringValue(item["accessible"]) ?? "-"
        let right = stringValue(item["right"]) ?? "-"
        let memberRight = stringValue(item["member_right"]) ?? "-"
        let urls = playableURLs(fromVideoListItem: item)
        let urlSummary = urls.first.map(playableURLSummary) ?? "url=none keys=\(candidateKeySummary(item))"
        return "res=\(resolution) status=\(status) accessable=\(accessable) right=\(right) memberRight=\(memberRight) \(urlSummary)"
    }

    static func playableURLSummary(_ rawURL: String?) -> String {
        guard let rawURL, !rawURL.isEmpty else {
            return "url=none"
        }
        guard let components = URLComponents(string: rawURL) else {
            return "url=invalid"
        }
        let host = components.host ?? "-"
        let path = components.path.lowercased()
        let ext = (path as NSString).pathExtension
        let kind = path.contains(".m3u8") ? "m3u8" : (ext.isEmpty ? "url" : ext)
        let queryItems = components.queryItems ?? []
        func queryValue(_ name: String) -> String {
            queryItems.first { $0.name.lowercased() == name }?.value ?? "-"
        }
        let queryNames = Set(queryItems.map { $0.name.lowercased() })
        let hasCallback = queryNames.contains("callback") || queryNames.contains("callback-var")
        return "host=\(host) kind=\(kind) dfi=\(queryValue("dfi")) mt=\(queryValue("mt")) cb=\(hasCallback)"
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
        let preferredKeys = [
            "url",
            "play_url",
            "playUrl",
            "download_url",
            "downloadUrl",
            "m3u8_url",
            "m3u8Url",
            "mp4_url",
            "mp4Url",
            "transcode_url",
            "transcodeUrl",
            "media_url",
            "mediaUrl"
        ]

        if let videoInfo = item["video_info"] as? [String: Any] {
            urls.append(contentsOf: urlValues(in: videoInfo, preferredKeys: preferredKeys))
        }
        urls.append(contentsOf: urlValues(in: item, preferredKeys: preferredKeys))

        for url in recursiveURLValues(in: item) where isLikelyPlayableMediaURL(url) {
            urls.append(url)
        }
        return uniqueURLs(urls.filter(isLikelyPlayableMediaURL))
    }

    static func urlValues(in dictionary: [String: Any], preferredKeys: [String]) -> [String] {
        var values: [String] = []
        for key in preferredKeys {
            if let string = stringValue(dictionary[key]), !string.isEmpty {
                values.append(string)
            }
            if let array = dictionary[key] as? [Any] {
                values.append(contentsOf: array.compactMap(stringValue).filter { !$0.isEmpty })
            }
        }
        return values
    }

    static func recursiveURLValues(in value: Any) -> [String] {
        if let string = value as? String, URLComponents(string: string)?.scheme?.hasPrefix("http") == true {
            return [string]
        }
        if let array = value as? [Any] {
            return array.flatMap(recursiveURLValues)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap(recursiveURLValues)
        }
        return []
    }

    static func uniqueURLs(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for url in urls where seen.insert(url).inserted {
            result.append(url)
        }
        return result
    }

    static func isLikelyPlayableMediaURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else {
            return false
        }
        let path = components.path.lowercased()
        let ext = (path as NSString).pathExtension
        if ["jpg", "jpeg", "png", "webp", "gif", "bmp", "avif", "heic"].contains(ext) {
            return false
        }
        if ["m3u8", "mp4", "mkv", "mov", "m4v", "flv", "ts", "webm"].contains(ext) {
            return true
        }
        let queryNames = Set((components.queryItems ?? []).map { $0.name.lowercased() })
        if !queryNames.isDisjoint(with: ["auth_key", "token", "dfi", "callback", "callback-var"]) {
            return true
        }
        return host.contains("drive.uc.cn") || host.contains("pds.uc.cn")
    }

    static func candidateKeySummary(_ item: [String: Any]) -> String {
        var parts = ["item:\(item.keys.sorted().prefix(10).joined(separator: ","))"]
        if let videoInfo = item["video_info"] as? [String: Any] {
            parts.append("video_info:\(videoInfo.keys.sorted().prefix(10).joined(separator: ","))")
        }
        return parts.joined(separator: ";")
    }

    static func isCallbackProtectedURL(_ rawURL: String) -> Bool {
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

    static func shouldFallbackFromPersonalPlayToDownload(_ error: Error) -> Bool {
        guard case .api(.uc, _, let code, let message) = error as? DriveEngineError else {
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
        case .officialPlayURLPending:
            return true
        case .noDownloadURL:
            return false
        case .api:
            return shouldFallbackFromPersonalPlayToDownload(error)
        case .invalidShareURL, .unsupported, .loginRequired, .noPlayableFile:
            return false
        }
    }

    static func shouldInvalidateSavedRecord(_ error: Error) -> Bool {
        guard case .api(.uc, let statusCode, let code, let message) = error as? DriveEngineError else {
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

    static func isSuspiciousInterceptSize(expected: Int64, returned: Int64, mode: DownloadProbeMode = .strictOriginalSize) -> Bool {
        guard expected >= minDownloadProbeExpectedSize else { return false }
        if returned <= suspiciousReturnedSizeLimit, returned * 4 < expected {
            return true
        }
        if mode == .allowTranscodedPlay {
            return false
        }
        return returned * 10 < expected
    }

    static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func int64HeaderValue(_ name: String, in headers: [String: String]) -> Int64? {
        guard let value = headerValue(name, in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return Int64(value)
    }

    static func contentRangeTotal(in headers: [String: String]) -> Int64? {
        guard let value = headerValue("Content-Range", in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let slash = value.lastIndex(of: "/") else {
            return nil
        }
        let total = value[value.index(after: slash)...]
        guard total != "*" else { return nil }
        return Int64(total)
    }

    static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func userAgentLogLabel(_ userAgent: String) -> String {
        if userAgent == mobileBrowserPlaybackUserAgent {
            return "mobile-uc"
        }
        if userAgent == accountPlaybackUserAgent {
            return "pc-drive"
        }
        return userAgent.localizedCaseInsensitiveContains("UCBrowser") ? "uc-browser" : "custom"
    }

    static func redactedURL(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else { return rawURL }
        components.queryItems = components.queryItems?.map { item in
            switch item.name.lowercased() {
            case "auth_key", "token", "signature", "ossaccesskeyid", "callback", "callback-var", "ut":
                return URLQueryItem(name: item.name, value: "<redacted>")
            default:
                return item
            }
        }
        return components.string ?? rawURL
    }

    static func parseUCScheme(_ url: URL) -> String? {
        if let host = url.host, !host.isEmpty, host != "s" {
            return host
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path
    }

    static func parseWebShare(_ url: URL) -> String? {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if let index = pathComponents.firstIndex(of: "s"),
           pathComponents.indices.contains(index + 1) {
            return pathComponents[index + 1]
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return value(for: ["pwd_id", "share", "id"], in: components?.queryItems ?? [])
    }

    static func value(for names: [String], in queryItems: [URLQueryItem]) -> String? {
        for name in names {
            if let value = queryItems.first(where: { $0.name.lowercased() == name.lowercased() })?.value,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func apiURL(path: String, queryItems: [URLQueryItem] = []) -> String {
        var components = URLComponents(string: Self.apiBase + path)
        components?.queryItems = [
            URLQueryItem(name: "pr", value: "UCBrowser"),
            URLQueryItem(name: "fr", value: "pc")
        ] + queryItems
        return components?.url?.absoluteString ?? Self.apiBase + path
    }

    static func normalizedOriginalPlaybackToken(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        var token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("ut-") {
            token.removeFirst(3)
        }
        return token.isEmpty ? nil : token
    }

    static func isSuspiciousOriginalInterceptError(_ error: Error) -> Bool {
        guard case DriveEngineError.unsupported(let message) = error else { return false }
        return message.contains("拦截视频") && message.contains("不是目标文件")
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
            if ["true", "1"].contains(string.lowercased()) { return true }
            if ["false", "0"].contains(string.lowercased()) { return false }
        }
        return nil
    }
}
