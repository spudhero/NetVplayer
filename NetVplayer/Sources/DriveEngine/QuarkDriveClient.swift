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
    case transferConfirmationPending(DriveTransferPhase = .outcomeUnknown)
    case api(provider: DriveProvider, statusCode: Int, code: Int?, message: String)

    public var transferPhase: DriveTransferPhase? {
        switch self {
        case .transferConfirmationPending(let phase): return phase
        case .officialPlayURLPending: return .playbackAddressPending
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidShareURL(let url):
            return L10n.text("无效的网盘分享链接: {0}", ["\(url)"])
        case .unsupported(let message):
            return message
        case .loginRequired(let provider):
            return L10n.text("{0} 完整播放需要授权。请完成授权后重试。", ["\(provider.localizedDisplayName)"])
        case .noPlayableFile(let share):
            return L10n.text("网盘分享中没有找到可播放视频文件: {0}", ["\(share)"])
        case .noDownloadURL(let fileName):
            return L10n.text("网盘没有返回完整播放地址: {0}。可能是 Cookie 过期、账号无权限，或该文件只能转存后播放。", ["\(fileName)"])
        case .officialPlayURLPending(let fileName):
            return L10n.text("已转存成功，但夸克只返回下载 CDN，正在等待官方播放地址: {0}。请稍后重试，或先在夸克网盘 App 中打开一次该文件后再试。", ["\(fileName)"])
        case .transferConfirmationPending:
            return L10n.text("转存结果仍待确认。请稍后重试以核对文件，本次不会重复提交转存。")
        case .api(let provider, let statusCode, let code, let message):
            if let code {
                return L10n.text("{0} 接口错误 HTTP {1} / {2}: {3}", ["\(provider.localizedDisplayName)", "\(statusCode)", "\(code)", "\(message)"])
            }
            return L10n.text("{0} 接口错误 HTTP {1}: {2}", ["\(provider.localizedDisplayName)", "\(statusCode)", "\(message)"])
        }
    }

    public static func invalidatesSavedRecord(_ error: Error, provider: DriveProvider? = nil) -> Bool {
        if let failure = error as? DriveServiceFailure {
            return (provider == nil || provider == failure.provider) && failure.reason == .fileMissing
        }
        guard case let DriveEngineError.api(actual, status, code, _) = error,
              provider == nil || provider == actual, status != 403 else { return false }
        // Legacy errors lack endpoint evidence. Only the established personal
        // file business code is sufficient; HTTP 404/410 and text are not.
        return (actual == .quark || actual == .uc) && code == 32003
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

    public var isPlayableMedia: Bool {
        DriveMediaClassifier.isPlayableMedia(
            name: name,
            formatType: formatType,
            isDirectory: isDirectory,
            isFile: isFile
        )
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
    public let directoryPath: String

    public init(file: QuarkShareFile, stoken: String, directoryPath: String = "") {
        self.file = file
        self.stoken = stoken
        self.directoryPath = directoryPath
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

    private let httpClient: DriveHTTPClient
    private let pendingPlayPolls: Int
    private let pendingPlayIntervalMilliseconds: Int

    public init(
        httpClient: HTTPClient = .shared,
        pendingPlayPolls: Int = 15,
        pendingPlayIntervalMilliseconds: Int = 2_000
    ) {
        self.httpClient = DriveHTTPClient(httpClient, provider: .quark)
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
        var directoryPaths: [String: String] = ["0": ""]
        var visitedDirectories = Set<String>()

        while !directoryQueue.isEmpty && visitedDirectories.count < Self.maxDirectories {
            let pdirFID = directoryQueue.removeFirst()
            guard visitedDirectories.insert(pdirFID).inserted else { continue }

            for page in 1...Self.maxPagesPerDirectory {
                let result = try await loadShareList(share: share, pdirFID: pdirFID, page: page, cookie: cookie)

                for item in result.list {
                    if item.isDirectory {
                        directoryQueue.append(item.fid)
                        directoryPaths[item.fid] = (directoryPaths[pdirFID] ?? "") + "/" + item.name
                    } else if item.isPlayableMedia {
                        playableFiles.append(QuarkPlayableFile(
                            file: item,
                            stoken: result.stoken,
                            directoryPath: directoryPaths[pdirFID] ?? ""
                        ))
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
            collectionName: collectionName,
            formatType: playable.file.formatType
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
        if DriveRequestRecovery.budget == nil {
            return try await DriveRequestRecovery.withBudget { try await self.fetchSavedDownloadURLResult(for: playable, share: share, cookie: cookie) }
        }
        var activeCookie = cookie
        // An explicit video type takes precedence over a disguised audio extension.
        let preferAudioOriginal = !playable.file.isPlayableVideo && DriveMediaClassifier.isPlayableAudio(
            name: playable.file.name,
            formatType: playable.file.formatType,
            isDirectory: playable.file.isDirectory,
            isFile: playable.file.isFile
        )
        let baseIdentity = DriveSavedFileNaming.identity(provider: .quark, pwdID: share.pwdID, file: playable.file)
        let account = DriveTransferContext.account(provider: .quark, cookie: cookie)
        try await DriveTransferCoordinator.current.checkRecovery(sourceKey: baseIdentity.cacheKey, account: account)
        let cached = try await DriveSavedFileStore.shared.verificationRecord(for: baseIdentity, account: account,
            allowUnscopedCandidate: true)
        let legacy = try DriveMappingVerification.legacyCandidate(cached, for: baseIdentity,
            shareID: share.pwdID, sourceID: playable.file.fid, size: playable.file.size)
        let folder = try await DriveMappingVerification.target(record: cached, provider: .quark, legacy: legacy) {
            try await ensureTransferFolder(for: share, cookie: cookie)
        }
        activeCookie = folder.updatedCookie
        let identity = baseIdentity.scoped(account: account, target: folder.fid)

        if let cached {
            var verifiedRecord = cached
            do {
                guard (cached.targetRootFID ?? cached.parentFID) == folder.fid else {
                    try await DriveMappingVerification.invalidate(cached, provider: .quark, legacy: legacy)
                }
                // A returned transfer container is allowed only while it still
                // belongs to the configured target. Never search its siblings.
                if cached.parentFID != folder.fid {
                    let parents = try await listPersonalFiles(parentFID: folder.fid, cookie: activeCookie)
                    activeCookie = parents.updatedCookie
                    guard parents.files.contains(where: { $0.fid == cached.parentFID && $0.isDirectory }) else {
                        if parents.complete { try await DriveMappingVerification.invalidate(cached, provider: .quark, legacy: legacy) }
                        throw DriveMappingVerification.unconfirmed(.quark)
                    }
                }
                let listed = try await listPersonalFiles(parentFID: cached.parentFID, cookie: activeCookie)
                activeCookie = listed.updatedCookie
                let matches = listed.files.filter { $0.fid == cached.savedFID }
                guard matches.count <= 1 else { throw DriveMappingVerification.unconfirmed(.quark) }
                verifiedRecord = try await DriveMappingVerification.verified(cached, identity: identity, legacy: legacy,
                    file: matches.first.map { .init(id: $0.fid,
                        parent: $0.pdirFID.isEmpty ? cached.parentFID : $0.pdirFID,
                        size: $0.size, isDirectory: $0.isDirectory) }, listingComplete: listed.complete)
                return try await personalPlayResultWaitingIfNeeded(for: verifiedRecord, cookie: activeCookie, preferAudioOriginal: preferAudioOriginal)
            } catch {
                try await DriveMappingVerification.handle(error, record: verifiedRecord, provider: .quark, legacy: legacy)
                if Self.shouldWaitForPersonalPlayback(error) { throw DriveEngineError.officialPlayURLPending(cached.originalName) }
                throw error
            }
        }

        let transferStartCookie = activeCookie
        let transferResult = try await DriveTransferCoordinator.current.confirmedTransfer(cacheKey: identity.cacheKey,
            scope: .make(identity: identity, account: account, target: folder.fid,
                         shareID: share.pwdID, sourceFileID: playable.file.fid,
                         name: playable.file.name, size: playable.file.size, collectionName: share.collectionName)) { attempt in
            var transferCookie = transferStartCookie
            let rejectedFIDs = await DriveSavedFileStore.shared.rejectedFileIDs(cacheKey: identity.cacheKey)
            // Names (including the historical hash suffix) are not file identity.
            let before = await attempt.needsSubmission
                ? try await self.listPersonalFiles(parentFID: folder.fid, cookie: transferCookie) : nil
            if let before { transferCookie = before.updatedCookie }
            if await attempt.needsSubmission {
                let submitCookie = transferCookie
                let submitted = try await attempt.submit(previousIDs: Set(before?.files.map(\.fid) ?? [])) {
                    let save = try await self.saveShareFileToPersonalDrive(
                        playable: playable, share: share, targetPdirFID: folder.fid, cookie: submitCookie)
                    return DriveTransferSubmission(fileID: save.savedFID, taskID: save.taskID, updatedCookie: save.updatedCookie)
                }
                if let submitted, !submitted.updatedCookie.isEmpty { transferCookie = submitted.updatedCookie }
            }
            if let taskID = await attempt.taskID, await attempt.fileID == nil {
                do {
                    let task = try await self.waitForSaveTask(taskID: taskID, originalFID: playable.file.fid,
                        fileName: playable.file.name, intervalMilliseconds: 500, cookie: transferCookie)
                    transferCookie = task.updatedCookie
                    try await attempt.update(fileID: task.savedFID)
                } catch is CancellationError { throw CancellationError() } catch {
                    // A task read failure says nothing about whether the write ran.
                }
            }
            let resolved = try await self.confirmTransferredFile(
                attempt: attempt, originalFileName: playable.file.name, size: playable.file.size,
                folderFID: folder.fid, cookie: transferCookie, excludingFIDs: rejectedFIDs)
            transferCookie = resolved.updatedCookie
            guard let savedFile = resolved.file else { throw DriveEngineError.transferConfirmationPending() }
            try await attempt.confirmed(savedFile.fid, parent: savedFile.pdirFID.isEmpty ? folder.fid : savedFile.pdirFID)
            try await DriveTransferContext.current.check()
            // Retain the confirmed ID before optional renaming. A rename failure
            // must never cause another copy on the next click.
            var savedName = savedFile.name
            do {
                let renamed = try await self.renamePersonalFile(fid: savedFile.fid, fileName: identity.targetFileName, cookie: transferCookie)
                transferCookie = renamed.updatedCookie
                savedName = identity.targetFileName
            } catch is CancellationError { throw CancellationError() } catch { }
            try await DriveTransferContext.current.check()
            let record = DriveSavedFileRecord(
                provider: .quark,
                cacheKey: identity.cacheKey,
                pwdID: share.pwdID,
                shareFID: playable.file.fid,
                fidToken: playable.file.shareFIDToken,
                size: playable.file.size,
                originalName: playable.file.name,
                savedFID: savedFile.fid,
                savedFileName: savedName,
                parentFID: savedFile.pdirFID.isEmpty ? folder.fid : savedFile.pdirFID,
                targetRootFID: folder.fid
            )
            try await DriveSavedFileStore.shared.save(record)
            DiagnosticLog.write("[QUARK_SAVED_CACHE] saved cacheKey=\(identity.cacheKey) fid=\(savedFile.fid) file=\(identity.targetFileName)")
            return DriveSavedFileTransferResult(record: record, updatedCookie: transferCookie)
        }
        let savedFile = transferResult.record
        activeCookie = transferResult.updatedCookie

        do {
            return try await personalPlayResultWaitingIfNeeded(for: savedFile, cookie: activeCookie, preferAudioOriginal: preferAudioOriginal)
        } catch {
            try await DriveMappingVerification.handle(error, record: savedFile, provider: .quark)
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
        let formatType: String
        let isDirectory: Bool
        let isFile: Bool

        var isPlayableMediaObject: Bool {
            DriveMediaClassifier.isPlayableMedia(
                name: name,
                formatType: formatType,
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

        guard root.complete else { throw DriveMappingVerification.unconfirmed(.quark) }
        if DriveMappingVerification.readOnly { throw DriveMappingVerification.changed(.quark) }

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

        guard listed.complete else { throw DriveMappingVerification.unconfirmed(.quark) }
        if DriveMappingVerification.readOnly { throw DriveMappingVerification.changed(.quark) }

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
            body: body,
            allowsProxyFallback: false
        )
        let data = result.json["data"] as? [String: Any] ?? result.json
        return SaveStartResult(
            taskID: Self.firstString(in: data, keys: ["task_id", "taskId"]),
            savedFID: Self.savedFID(in: data, excluding: file.fid, matching: file.name),
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

        for _ in 0..<min(6, Self.maxTaskPolls) {
            try await DriveTransferContext.current.check()
            _ = try DriveTransferContext.readTimeout(30)
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

    private func confirmTransferredFile(
        attempt: DriveTransferAttempt, originalFileName: String, size: Int64,
        folderFID: String, cookie: String, excludingFIDs: Set<String>
    ) async throws -> PersonalFileLookupResult {
        var activeCookie = cookie
        let previous = await attempt.previousIDs
        let knownID = await attempt.fileID
        for poll in 0..<min(6, max(1, pendingPlayPolls)) {
            try await DriveTransferContext.current.check()
            let listed = try await listPersonalFiles(parentFID: folderFID, cookie: activeCookie)
            activeCookie = listed.updatedCookie
            let matches = listed.files.filter {
                !$0.isDirectory && $0.fileType != 0 && $0.isPlayableMediaObject && !excludingFIDs.contains($0.fid)
                    && (size <= 0 || $0.size == size)
                    && ($0.pdirFID.isEmpty || $0.pdirFID == folderFID)
            }.filter { file in
                if let knownID { return file.fid == knownID }
                return listed.complete && size > 0 && file.name == originalFileName && !previous.contains(file.fid)
            }
            if matches.count == 1 { return PersonalFileLookupResult(file: matches[0], updatedCookie: activeCookie) }
            // Some services return a container ID. Only descend into that exact,
            // observed directory; never fall back to its siblings or another name.
            if let knownID, listed.files.contains(where: { $0.fid == knownID && ($0.isDirectory || $0.fileType == 0) }) {
                let nested = try await listPersonalFiles(parentFID: knownID, cookie: activeCookie)
                activeCookie = nested.updatedCookie
                let children = nested.files.filter {
                    !$0.isDirectory && $0.isPlayableMediaObject && $0.name == originalFileName
                        && size > 0 && $0.size == size && !excludingFIDs.contains($0.fid)
                }
                if nested.complete && children.count == 1 { return PersonalFileLookupResult(file: children[0], updatedCookie: activeCookie) }
            }
            if poll + 1 < min(6, max(1, pendingPlayPolls)) { try await sleepForPendingPlayback() }
        }
        return PersonalFileLookupResult(file: nil, updatedCookie: activeCookie)
    }

    func personalPlayResult(for record: DriveSavedFileRecord, cookie: String, preferAudioOriginal: Bool) async throws -> QuarkDownloadResult {
        if preferAudioOriginal {
            return try await personalDownloadFallbackResult(for: record, cookie: cookie, reason: "audio-original")
        }
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

    func personalPlayResultWaitingIfNeeded(for record: DriveSavedFileRecord, cookie: String, preferAudioOriginal: Bool) async throws -> QuarkDownloadResult {
        var lastError: Error?

        for attempt in 0..<pendingPlayPolls {
            do {
                return try await personalPlayResult(for: record, cookie: cookie, preferAudioOriginal: preferAudioOriginal)
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

    func listPersonalFiles(parentFID: String, cookie: String) async throws -> (files: [PersonalFile], updatedCookie: String, complete: Bool) {
        let pageSize = 100
        let maximumPages = 32
        var files: [PersonalFile] = []
        var seenIDs = Set<String>()
        var activeCookie = cookie
        var expectedTotal: Int?
        // Directory absence is evidence only after every page has been read.
        // Repeated pages, changing totals and bounded scans remain inconclusive.
        for page in 1...maximumPages {
            let result = try await getJSONResult(
                url: Self.apiURL(base: Self.pcAPIBase, path: "/1/clouddrive/file/sort", queryItems: [
                    URLQueryItem(name: "pdir_fid", value: parentFID),
                    URLQueryItem(name: "_page", value: String(page)),
                    URLQueryItem(name: "_size", value: String(pageSize)),
                    URLQueryItem(name: "_fetch_total", value: "1"),
                    URLQueryItem(name: "fetch_all_file", value: "1"),
                    URLQueryItem(name: "fetch_risk_file_name", value: "1"),
                    URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc")
                ]),
                headers: accountHeaders(cookie: activeCookie)
            )
            activeCookie = result.updatedCookie
            let data = result.json["data"] as? [String: Any]
            guard let rawList = data?["list"] as? [[String: Any]]
                ?? data?["file_list"] as? [[String: Any]] else { throw DriveMappingVerification.unconfirmed(.quark) }
            let pageFiles = rawList.compactMap(Self.parsePersonalFile)
            let metadata = result.json["metadata"] as? [String: Any]
            let total = Self.intValue(metadata?["_total"]) ?? Self.intValue(data?["total"])
            guard rawList.count <= pageSize, pageFiles.count == rawList.count,
                  pageFiles.allSatisfy({ !$0.fid.isEmpty && !$0.name.isEmpty }),
                  Set(pageFiles.map(\.fid)).count == pageFiles.count,
                  pageFiles.allSatisfy({ !seenIDs.contains($0.fid) }),
                  total.map({ $0 >= files.count + pageFiles.count }) ?? true,
                  expectedTotal == nil || total == nil || total == expectedTotal else {
                return (files, activeCookie, false)
            }
            files.append(contentsOf: pageFiles)
            seenIDs.formUnion(pageFiles.map(\.fid))
            expectedTotal = total ?? expectedTotal
            // Keep an observed exact ID for the existing moved-file policy,
            // but unrelated parents cannot prove this directory is complete.
            guard pageFiles.allSatisfy({ $0.pdirFID.isEmpty || $0.pdirFID == parentFID }) else {
                return (files, activeCookie, false)
            }
            let hasMore = Self.boolValue(data?["has_more"]) ?? false
            if expectedTotal == files.count {
                return (files, activeCookie, !hasMore)
            }
            if rawList.count < pageSize {
                return (files, activeCookie, expectedTotal == nil && !hasMore)
            }
        }
        return (files, activeCookie, false)
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
            formatType: stringValue(raw["format_type"]) ?? "",
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

    func postJSONResult(url: String, headers: [String: String], body: [String: Any], allowsProxyFallback: Bool = true) async throws -> JSONRequestResult {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response = try await httpClient.post(url: url, headers: headers, body: bodyData, timeout: 30, allowsProxyFallback: allowsProxyFallback && DriveTransferContext.confirmationDeadline == nil, redactsURLInLogs: true)
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
        let response = try await httpClient.get(url: url, headers: headers, timeout: try DriveTransferContext.readTimeout(30), allowsProxyFallback: DriveTransferContext.confirmationDeadline == nil, redactsURLInLogs: true)
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
        case .transferConfirmationPending:
            return false
        case .invalidShareURL, .unsupported, .loginRequired, .noPlayableFile:
            return false
        }
    }

    static func shouldInvalidateSavedRecord(_ error: Error) -> Bool {
        DriveEngineError.invalidatesSavedRecord(error, provider: .quark)
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

extension QuarkDriveClient {
    func recoverTransfer(_ record: DriveTransferTask, attempt: DriveTransferAttempt, cookie: String) async throws -> DriveRecoveredFile? {
        let scope = record.scope
        let target = try await ensureTransferFolder(for: .init(originalURL: "", pwdID: scope.shareID,
            collectionName: scope.collectionName), cookie: cookie)
        guard target.fid == scope.target else { throw DriveTaskRecoveryError.scopeChanged }
        if !record.submitted || record.phase == .failed { return nil }
        var activeCookie = target.updatedCookie
        if let taskID = await attempt.taskID, await attempt.fileID == nil {
            let result = try await waitForSaveTask(taskID: taskID, originalFID: scope.sourceFileID,
                fileName: scope.name, intervalMilliseconds: 500, cookie: activeCookie)
            activeCookie = result.updatedCookie
            try await attempt.update(fileID: result.savedFID)
        }
        let parent = record.confirmedParentID ?? scope.target
        if parent != scope.target {
            let parents = try await listPersonalFiles(parentFID: scope.target, cookie: activeCookie)
            guard parents.files.contains(where: { $0.fid == parent && $0.isDirectory }) else {
                throw DriveTaskRecoveryError.requiresReview
            }
        }
        guard let file = try await confirmTransferredFile(attempt: attempt, originalFileName: scope.name,
            size: scope.size, folderFID: parent, cookie: activeCookie, excludingFIDs: []).file else {
            throw DriveTaskRecoveryError.requiresReview
        }
        return .init(id: file.fid, name: file.name, parent: file.pdirFID.isEmpty ? parent : file.pdirFID, size: file.size)
    }
}


// Personal-directory browsing never invokes the share-save or cleanup paths.
extension QuarkDriveClient {
    func personalDirectory(folderID: String, cursor: String?, credential: CloudCredential) async throws -> CloudDirectoryPage {
        let page = try CloudDirectoryPaging.integer(cursor, first: 1, provider: .quark)
        let result = try await getJSONResult(
            url: Self.apiURL(base: Self.pcAPIBase, path: "/1/clouddrive/file/sort", queryItems: [
                URLQueryItem(name: "pdir_fid", value: folderID),
                URLQueryItem(name: "_page", value: String(page)),
                URLQueryItem(name: "_size", value: "100"),
                URLQueryItem(name: "_fetch_total", value: "1"),
                URLQueryItem(name: "fetch_all_file", value: "1"),
                URLQueryItem(name: "fetch_risk_file_name", value: "1"),
                URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc")
            ]), headers: accountHeaders(cookie: credential.secret))
        guard let data = result.json["data"] as? [String: Any],
              let raw = (data["list"] as? [[String: Any]]) ?? (data["file_list"] as? [[String: Any]]) else {
            throw DriveMappingVerification.unconfirmed(.quark)
        }
        let files = raw.compactMap(Self.parsePersonalFile)
        guard files.count == raw.count else { throw DriveMappingVerification.unconfirmed(.quark) }
        let metadata = result.json["metadata"] as? [String: Any]
        let total = Self.intValue(metadata?["_total"]) ?? Self.intValue(data["total"])
        let more = try CloudDirectoryPaging.hasNext(count: files.count, offset: (page - 1) * 100, limit: 100,
            total: total, hasMore: Self.boolValue(data["has_more"]) ?? false, provider: .quark)
        return CloudDirectoryPage(entries: files.map {
            .init(id: $0.fid, name: $0.name, parentID: folderID, size: $0.size, isDirectory: $0.isDirectory)
        }, nextCursor: more ? String(page + 1) : nil,
           updatedCredential: CloudDirectoryPaging.updatedCookie(result.updatedCookie, credential: credential))
    }

    func personalDirectoryDownload(entry: CloudDirectoryEntry, credential: CloudCredential) async throws -> CloudDriveLink {
        let result = try await fetchPersonalDownloadURLResult(fid: entry.id, fileName: entry.name, cookie: credential.secret)
        guard let url = result.url, !url.isEmpty else { throw DriveEngineError.noDownloadURL(entry.name) }
        let updated = CloudDirectoryPaging.updatedCookie(result.updatedCookie, credential: credential)
        return CloudDriveLink(url: url, headers: ["Referer": "https://pan.quark.cn", "Origin": "https://pan.quark.cn", "Cookie": updated.secret],
            metadata: CloudDirectoryPaging.metadata(entry, provider: .quark), updatedCredential: updated)
    }
}
