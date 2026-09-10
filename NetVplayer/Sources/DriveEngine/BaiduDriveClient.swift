// DriveEngine/BaiduDriveClient.swift
// 百度网盘公开分享验证、个人盘转存、原画直链与临时文件清理。

import Foundation
import Models
import Networking

public struct BaiduShareRequest: Sendable {
    public let originalURL: String
    public let shareToken: String
    public let shortURLToken: String
    public let passcode: String

    public init(originalURL: String, shareToken: String, shortURLToken: String, passcode: String) {
        self.originalURL = originalURL
        self.shareToken = shareToken
        self.shortURLToken = shortURLToken
        self.passcode = passcode
    }
}

public struct BaiduShareFile: Sendable {
    public let fileID: String
    public let name: String
    public let path: String
    public let size: Int64
    public let category: Int
    public let isDirectory: Bool

    public init(fileID: String, name: String, path: String, size: Int64, category: Int, isDirectory: Bool) {
        self.fileID = fileID
        self.name = name
        self.path = path
        self.size = max(0, size)
        self.category = category
        self.isDirectory = isDirectory
    }

    public var isPlayableVideo: Bool {
        guard !isDirectory else { return false }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return Self.videoExtensions.contains(ext) || (ext.isEmpty && category == 1)
    }

    private static let videoExtensions: Set<String> = [
        "3gp", "avi", "flv", "m2ts", "m3u8", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "rmvb", "ts", "webm", "wmv"
    ]
}

public struct BaiduDriveClient: Sendable {
    private static let pageSize = 100
    private static let maxPagesPerDirectory = 20
    private static let maxDirectories = 64
    private static let maxFiles = 1_000
    private static let appID = "250528"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
    private static let transferUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    public static let playbackUserAgent = "netdisk;12.24.6;HBN-AL00;android-android;12;JSbridge4.4.0;jointBridge;1.1.0"
    private static let transferFolder = "/NetVplayer"

    private let httpClient: HTTPClient
    private let usesCurlShareListTransport: Bool

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
        self.usesCurlShareListTransport = httpClient === HTTPClient.shared
    }

    public func shareRequest(from rawURL: String) throws -> BaiduShareRequest {
        let canonicalURL = Self.canonicalShareURL(from: rawURL)
        guard DriveFileReference.provider(for: rawURL) == .baidu,
              let url = URL(string: canonicalURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DriveEngineError.invalidShareURL(rawURL)
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard let shareIndex = pathComponents.firstIndex(where: { $0.lowercased() == "s" }),
              pathComponents.indices.contains(shareIndex + 1) else {
            throw DriveEngineError.invalidShareURL(rawURL)
        }
        let shareToken = pathComponents[shareIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shareToken.isEmpty else { throw DriveEngineError.invalidShareURL(rawURL) }
        let shortURLToken = shareToken.hasPrefix("1") ? String(shareToken.dropFirst()) : shareToken
        let passcode = components.queryItems?.first {
            ["pwd", "password", "passcode", "code"].contains($0.name.lowercased())
        }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return BaiduShareRequest(
            originalURL: canonicalURL,
            shareToken: shareToken,
            shortURLToken: shortURLToken,
            passcode: passcode
        )
    }

    /// The native source uses `baidu://share/<token>` as a transport-safe
    /// provider URI. Baidu's web APIs expect the equivalent `/s/<token>` URL.
    private static func canonicalShareURL(from rawURL: String) -> String {
        guard let source = URL(string: rawURL),
              source.scheme?.lowercased() == "baidu",
              source.host?.lowercased() == "share" else {
            return rawURL
        }

        let token = source.pathComponents
            .filter { $0 != "/" }
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return rawURL }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "pan.baidu.com"
        components.path = "/s/\(token)"
        components.queryItems = URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems
        return components.string ?? rawURL
    }

    public func fileReference(
        for file: BaiduShareFile,
        share: BaiduShareRequest,
        shareID: String,
        shareUK: String,
        collectionName: String
    ) -> DriveFileReference {
        DriveFileReference(
            provider: .baidu,
            shareURL: share.originalURL,
            pwdID: shareID,
            passcode: share.passcode,
            fid: file.fileID,
            fidToken: shareUK,
            fileName: file.name,
            collectionName: collectionName,
            size: file.size
        )
    }

    public func expandedFiles(share: BaiduShareRequest) async throws -> (files: [BaiduShareFile], shareID: String, shareUK: String) {
        if share.passcode.isEmpty {
            let response = try await loadSharePage(share: share)
            return try await expandedFiles(share: share, pageResponse: response)
        }

        if await BaiduShareSessionStore.shared.key(for: share.shortURLToken) != nil {
            do {
                let root = try await loadShareRoot(share: share)
                return try await expandedFiles(
                    share: share,
                    rootFiles: root.files,
                    shareID: root.shareID,
                    shareUK: root.shareUK
                )
            } catch where Self.isShareSessionError(error) {
                await clearShareSession(for: share.shortURLToken)
            }
        }

        _ = try await loadSharePage(share: share)
        let shareKey = try await verify(share: share)
        let response = try await loadSharePage(share: share, shareKey: shareKey)
        return try await expandedFiles(share: share, pageResponse: response)
    }

    private func expandedFiles(
        share: BaiduShareRequest,
        pageResponse: HTTPResponse
    ) async throws -> (files: [BaiduShareFile], shareID: String, shareUK: String) {
        let page = try Self.parseSharePage(pageResponse.text, statusCode: pageResponse.statusCode)

        do {
            let root = try await loadShareRoot(share: share)
            return try await expandedFiles(
                share: share,
                rootFiles: root.files.isEmpty ? page.files : root.files,
                shareID: root.shareID.isEmpty ? page.shareID : root.shareID,
                shareUK: root.shareUK.isEmpty ? page.shareUK : root.shareUK
            )
        } catch {
            guard !page.files.isEmpty else { throw error }
            return try await expandedFiles(
                share: share,
                rootFiles: page.files,
                shareID: page.shareID,
                shareUK: page.shareUK
            )
        }
    }

    private func expandedFiles(
        share: BaiduShareRequest,
        rootFiles: [BaiduShareFile],
        shareID: String,
        shareUK: String
    ) async throws -> (files: [BaiduShareFile], shareID: String, shareUK: String) {
        guard !shareID.isEmpty, !shareUK.isEmpty else {
            throw DriveEngineError.api(
                provider: .baidu,
                statusCode: 200,
                code: nil,
                message: "分享根目录缺少分享身份"
            )
        }
        var playable = rootFiles.filter(\.isPlayableVideo)
        var directoryQueue = rootFiles.filter(\.isDirectory).map(\.path).filter { !$0.isEmpty }
        var visitedDirectories = Set<String>()
        while !directoryQueue.isEmpty,
              visitedDirectories.count < Self.maxDirectories,
              playable.count < Self.maxFiles {
            let directory = directoryQueue.removeFirst()
            guard visitedDirectories.insert(directory).inserted else { continue }
            for pageNumber in 1...Self.maxPagesPerDirectory {
                let result = try await loadDirectory(
                    share: share,
                    shareID: shareID,
                    shareUK: shareUK,
                    directory: directory,
                    page: pageNumber
                )
                directoryQueue.append(contentsOf: result.files.filter(\.isDirectory).map(\.path).filter { !$0.isEmpty })
                playable.append(contentsOf: result.files.filter(\.isPlayableVideo))
                if playable.count >= Self.maxFiles || result.files.count < Self.pageSize || result.files.count >= result.total {
                    break
                }
            }
        }
        let files = playable.prefix(Self.maxFiles).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return (Array(files), shareID, shareUK)
    }

    public func validate(_ credential: CloudCredential) async throws -> CloudCredential {
        let cookie = try normalizedCookie(credential)
        installCookies(cookie)
        let response = try await httpClient.get(
            url: Self.accountListURL(),
            headers: Self.accountHeaders(cookie: cookie),
            timeout: 20,
            allowsProxyFallback: true,
            redactsURLInLogs: true
        )
        let object = Self.jsonObject(response.data)
        let code = Self.intValue(object?["errno"])
        guard (200..<300).contains(response.statusCode), code == 0 else {
            throw Self.apiError(response: response, object: object, fallback: "百度网盘 Cookie 已失效")
        }
        return .cookie(provider: .baidu, value: mergedCookie(cookie, sessionCookie: httpClient.cookieHeader(for: "https://pan.baidu.com/")))
    }

    public func link(reference: DriveFileReference, credential: CloudCredential) async throws -> CloudDriveLink {
        guard reference.provider == .baidu else {
            throw DriveEngineError.unsupported("BaiduDriveClient 只处理百度网盘文件引用。")
        }
        let share = try shareRequest(from: reference.shareURL)
        guard !reference.pwdID.isEmpty, !reference.fid.isEmpty, !reference.fidToken.isEmpty else {
            throw DriveEngineError.api(
                provider: .baidu,
                statusCode: 422,
                code: nil,
                message: "百度分享文件缺少 shareid/uk/fs_id，请重新展开分享目录"
            )
        }
        var shareKey = await BaiduShareSessionStore.shared.key(for: share.shortURLToken) ?? ""
        if !share.passcode.isEmpty, shareKey.isEmpty {
            // The web flow sets PANPSC on the share page before /share/verify.
            _ = try await loadSharePage(share: share)
            shareKey = try await verify(share: share)
        } else if share.passcode.isEmpty, shareKey.isEmpty {
            _ = try await loadSharePage(share: share)
            shareKey = httpClient.cookieValue(name: "BDCLND", for: "https://pan.baidu.com/") ?? ""
        }
        let validated = try await validate(credential)
        var requestCookie = mergedCookie(validated.secret, sessionCookie: httpClient.cookieHeader(for: "https://pan.baidu.com/"))
        let identity = DriveSavedFileNaming.identity(
            provider: .baidu,
            pwdID: reference.pwdID,
            fid: reference.fid,
            name: reference.fileName,
            size: reference.size
        )

        var retriedMissingFile = false
        var refreshedShareSession = false
        while true {
            do {
                let record = try await savedRecord(
                    reference: reference,
                    identity: identity,
                    shareCookie: shareKey,
                    accountCookie: requestCookie
                )
                let media = try await mediaInfo(path: record.parentFID, fileID: record.savedFID, cookie: requestCookie)
                var metadata = record.playbackMetadata(provider: .baidu)
                metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
                metadata[DrivePlaybackMetadataKey.canUpdateProgress] = "false"
                if !media.resolution.isEmpty {
                    metadata[DrivePlaybackMetadataKey.qualityLabel] = media.resolution
                }
                return CloudDriveLink(
                    url: media.url,
                    headers: ["User-Agent": Self.playbackUserAgent],
                    metadata: metadata,
                    updatedCredential: .cookie(provider: .baidu, value: requestCookie)
                )
            } catch where !retriedMissingFile && Self.isMissingSavedFile(error) {
                retriedMissingFile = true
                try? await DriveSavedFileStore.shared.remove(cacheKey: identity.cacheKey)
            } catch where !refreshedShareSession && !share.passcode.isEmpty && Self.isShareSessionError(error) {
                refreshedShareSession = true
                await clearShareSession(for: share.shortURLToken)
                _ = try await loadSharePage(share: share)
                shareKey = try await verify(share: share)
                requestCookie = mergedCookie(
                    validated.secret,
                    sessionCookie: httpClient.cookieHeader(for: "https://pan.baidu.com/")
                )
            }
        }
    }

    public func deleteTemporaryPlaybackFile(
        cacheKey: String,
        fileID: String,
        credential: CloudCredential
    ) async throws -> CloudCredential? {
        let cookie = try normalizedCookie(credential)
        guard let record = await DriveSavedFileStore.shared.record(for: cacheKey) else {
            return .cookie(provider: .baidu, value: cookie)
        }
        await DriveTransferCoordinator.shared.beginCleanup(cacheKey: cacheKey)
        do {
            let path = record.parentFID.isEmpty
                ? "\(Self.transferFolder)/\(record.savedFileName)"
                : record.parentFID
            try await delete(path: path, cookie: cookie)
            try await DriveSavedFileStore.shared.remove(cacheKey: cacheKey)
            await DriveTransferCoordinator.shared.finishCleanup(cacheKey: cacheKey)
            return .cookie(provider: .baidu, value: cookie)
        } catch {
            await DriveTransferCoordinator.shared.finishCleanup(cacheKey: cacheKey)
            throw error
        }
    }

    private func savedRecord(
        reference: DriveFileReference,
        identity: DriveSavedFileIdentity,
        shareCookie: String,
        accountCookie: String
    ) async throws -> DriveSavedFileRecord {
        if let record = await DriveSavedFileStore.shared.record(for: identity) {
            return record
        }
        let transferred = try await DriveTransferCoordinator.shared.transfer(cacheKey: identity.cacheKey) {
            if let record = await DriveSavedFileStore.shared.record(for: identity) {
                return DriveSavedFileTransferResult(record: record, updatedCookie: accountCookie)
            }
            try await ensureTransferFolder(cookie: accountCookie)
            let saved = try await transfer(
                reference: reference,
                targetName: identity.targetFileName,
                shareCookie: shareCookie,
                accountCookie: accountCookie
            )
            let record = DriveSavedFileRecord(
                provider: .baidu,
                cacheKey: identity.cacheKey,
                pwdID: reference.pwdID,
                shareFID: reference.fid,
                fidToken: reference.fidToken,
                size: saved.size > 0 ? saved.size : reference.size,
                originalName: reference.fileName,
                savedFID: saved.fileID,
                savedFileName: saved.name,
                parentFID: saved.path
            )
            try await DriveSavedFileStore.shared.save(record)
            return DriveSavedFileTransferResult(record: record, updatedCookie: accountCookie)
        }
        return transferred.record
    }

    private func ensureTransferFolder(cookie: String) async throws {
        var components = URLComponents(string: "https://pan.baidu.com/api/create")!
        components.queryItems = Self.accountQueryItems + [
            URLQueryItem(name: "a", value: "commit"),
            URLQueryItem(name: "bdstoken", value: "")
        ]
        let form = Self.formData([
            URLQueryItem(name: "path", value: "/\(Self.transferFolder)"),
            URLQueryItem(name: "block_list", value: "[]"),
            URLQueryItem(name: "isdir", value: "1")
        ])
        let response = try await httpClient.post(
            url: components.url!.absoluteString,
            headers: Self.formHeaders(cookie: cookie, referer: "https://pan.baidu.com/disk/main"),
            body: form,
            timeout: 20
        )
        let object = Self.jsonObject(response.data)
        let code = Self.intValue(object?["errno"])
        // 百度在目录已存在时的返回码会随入口变化；抓包样本见过 -8，网页登录态也会返回 -6。
        // 后续 transfer 才是目录可用性的权威校验，因此两者都按幂等成功处理。
        guard (200..<300).contains(response.statusCode), code == 0 || code == -8 || code == -6 else {
            throw Self.apiError(response: response, object: object, fallback: "创建百度网盘临时目录失败")
        }
    }

    private func transfer(
        reference: DriveFileReference,
        targetName: String,
        shareCookie: String,
        accountCookie: String
    ) async throws -> (fileID: String, name: String, path: String, size: Int64) {
        guard !shareCookie.isEmpty else {
            throw DriveEngineError.api(provider: .baidu, statusCode: 401, code: nil, message: "分享提取码会话已失效，请重试")
        }
        var components = URLComponents(string: "https://pan.baidu.com/share/transfer")!
        components.queryItems = [
            URLQueryItem(name: "shareid", value: reference.pwdID),
            URLQueryItem(name: "from", value: reference.fidToken),
            URLQueryItem(name: "sekey", value: shareCookie.removingPercentEncoding ?? shareCookie),
            URLQueryItem(name: "ondup", value: "newcopy"),
            URLQueryItem(name: "async", value: "1"),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: Self.appID),
            URLQueryItem(name: "bdstoken", value: ""),
            URLQueryItem(name: "logid", value: ""),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "dp-logid", value: "")
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F")
        let form = Self.formData([
            URLQueryItem(name: "path", value: Self.transferFolder),
            URLQueryItem(name: "fsidlist", value: "[\(reference.fid)]")
        ])
        let response = try await httpClient.post(
            url: components.url!.absoluteString,
            headers: [
                "Accept-Encoding": "gzip",
                "Connection": "Keep-Alive",
                "Content-Type": "application/x-www-form-urlencoded",
                "Cookie": accountCookie,
                "Host": "pan.baidu.com",
                "Referer": "https://pan.baidu.com/",
                "User-Agent": Self.transferUserAgent
            ],
            body: form,
            timeout: 30,
            handlesCookies: false
        )
        let object = Self.jsonObject(response.data)
        let code = Self.intValue(object?["errno"])
        guard (200..<300).contains(response.statusCode), code == 0 else {
            throw Self.apiError(response: response, object: object, fallback: "百度网盘转存失败")
        }
        let items = object?["info"] as? [[String: Any]] ?? []
        guard let item = items.first else {
            throw DriveEngineError.api(provider: .baidu, statusCode: response.statusCode, code: code, message: "转存响应缺少文件信息")
        }
        let returnedPath = Self.firstString(item, keys: ["path"])
        let returnedName = Self.firstString(item, keys: ["server_filename", "name"])
        let pathName = returnedPath.isEmpty ? "" : URL(fileURLWithPath: returnedPath).lastPathComponent
        let resolvedName = returnedName.isEmpty ? (pathName.isEmpty ? targetName : pathName) : returnedName
        let savedPath: String
        if returnedPath == Self.transferFolder || returnedPath.hasPrefix("\(Self.transferFolder)/") {
            savedPath = returnedPath
        } else {
            savedPath = "\(Self.transferFolder)/\(resolvedName)"
        }
        let returnedID = Self.firstString(item, keys: ["fs_id", "fsId", "fsid"])
        return (
            returnedID.isEmpty ? reference.fid : returnedID,
            resolvedName,
            savedPath,
            Self.int64Value(item["size"]) ?? reference.size
        )
    }

    private func mediaInfo(path: String, fileID: String, cookie: String) async throws -> (url: String, resolution: String) {
        var components = URLComponents(string: "https://pan.baidu.com/api/mediainfo")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "VideoURL"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "fs_id", value: fileID),
            URLQueryItem(name: "clienttype", value: "1"),
            URLQueryItem(name: "channel", value: "android_15_25010PN30C_bd-netdisk_1523"),
            URLQueryItem(name: "nom3u8", value: "1"),
            URLQueryItem(name: "dlink", value: "1"),
            URLQueryItem(name: "media", value: "1"),
            URLQueryItem(name: "origin", value: "dlna"),
            URLQueryItem(name: "devuid", value: "0%1")
        ]
        let response = try await httpClient.get(
            url: components.url!.absoluteString,
            headers: [
                "Accept": "application/json, text/plain, */*",
                "Cookie": cookie,
                "Referer": "https://pan.baidu.com/",
                "User-Agent": Self.playbackUserAgent
            ],
            timeout: 25,
            allowsProxyFallback: true,
            redactsURLInLogs: true
        )
        let object = Self.jsonObject(response.data)
        let info = object?["info"] as? [String: Any]
        let dlink = Self.firstString(info ?? [:], keys: ["dlink", "url"])
        guard (200..<300).contains(response.statusCode),
              let url = URL(string: dlink),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw Self.apiError(response: response, object: object, fallback: "百度网盘未返回原画直链")
        }
        return (dlink, Self.firstString(info ?? [:], keys: ["resolution", "format_name"]))
    }

    private func delete(path: String, cookie: String) async throws {
        var components = URLComponents(string: "https://pan.baidu.com/api/filemanager")!
        components.queryItems = [
            URLQueryItem(name: "opera", value: "delete"),
            URLQueryItem(name: "async", value: "2"),
            URLQueryItem(name: "onnest", value: "fail"),
            URLQueryItem(name: "bdstoken", value: ""),
            URLQueryItem(name: "app_id", value: Self.appID)
        ]
        let data = try JSONSerialization.data(withJSONObject: [path])
        let list = String(data: data, encoding: .utf8) ?? "[]"
        let response = try await httpClient.post(
            url: components.url!.absoluteString,
            headers: Self.netdiskFormHeaders(cookie: cookie),
            body: Self.formData([URLQueryItem(name: "filelist", value: list)]),
            timeout: 20
        )
        let object = Self.jsonObject(response.data)
        let code = Self.intValue(object?["errno"])
        guard (200..<300).contains(response.statusCode), code == 0 || code == -9 || code == -7 else {
            throw Self.apiError(response: response, object: object, fallback: "删除百度网盘临时文件失败")
        }
    }

    private func loadSharePage(share: BaiduShareRequest, shareKey: String? = nil) async throws -> HTTPResponse {
        var headers = Self.pageHeaders(referer: "https://pan.baidu.com/")
        if let shareKey, !shareKey.isEmpty {
            headers["Cookie"] = "BDCLND=\(shareKey)"
        }
        let response = try await httpClient.request(
            url: share.originalURL,
            method: .get,
            headers: headers,
            timeout: 25,
            allowsProxyFallback: true,
            redactsURLInLogs: true,
            handlesCookies: shareKey == nil
        )
        guard (200..<400).contains(response.statusCode) else {
            throw DriveEngineError.api(provider: .baidu, statusCode: response.statusCode, code: nil, message: "分享页加载失败")
        }
        return response
    }

    private func verify(share: BaiduShareRequest) async throws -> String {
        var components = URLComponents(string: "https://pan.baidu.com/share/verify")!
        components.queryItems = [
            URLQueryItem(name: "bdstoken", value: ""),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "logid", value: ""),
            URLQueryItem(name: "surl", value: share.shortURLToken),
            URLQueryItem(name: "t", value: Self.timestampMilliseconds()),
            URLQueryItem(name: "web", value: "1"),
        ]
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "pwd", value: share.passcode),
            URLQueryItem(name: "vcode", value: ""),
            URLQueryItem(name: "vcode_str", value: "")
        ]
        var headers = [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Origin": "https://pan.baidu.com",
            "Referer": share.originalURL,
            "User-Agent": Self.userAgent
        ]
        if let cookie = httpClient.cookieHeader(for: "https://pan.baidu.com/"), !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        let response = try await httpClient.post(
            url: components.url!.absoluteString,
            headers: headers,
            body: Data((form.percentEncodedQuery ?? "").utf8),
            timeout: 20,
            handlesCookies: true
        )
        let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        let code = Self.intValue(object?["errno"])
        guard (200..<300).contains(response.statusCode), code == 0 else {
            let message = Self.firstString(object ?? [:], keys: ["errmsg", "err_msg", "show_msg", "msg"])
            throw DriveEngineError.api(
                provider: .baidu,
                statusCode: response.statusCode,
                code: code,
                message: message.isEmpty ? "提取码验证失败" : message
            )
        }
        let responseKey = Self.firstString(object ?? [:], keys: ["randsk"])
        let headerKey = Self.responseCookie(named: "BDCLND", headers: response.headers) ?? ""
        let shareKey = responseKey.isEmpty ? headerKey : responseKey
        guard !shareKey.isEmpty else {
            throw DriveEngineError.api(
                provider: .baidu,
                statusCode: response.statusCode,
                code: code,
                message: "提取码验证响应缺少分享会话"
            )
        }
        _ = httpClient.setCookie(name: "BDCLND", value: shareKey, for: "https://pan.baidu.com/")
        try await BaiduShareSessionStore.shared.setKey(shareKey, for: share.shortURLToken)
        return shareKey
    }

    private func loadShareRoot(
        share: BaiduShareRequest
    ) async throws -> (files: [BaiduShareFile], shareID: String, shareUK: String) {
        let shareKey = await BaiduShareSessionStore.shared.key(for: share.shortURLToken)
            ?? httpClient.cookieValue(name: "BDCLND", for: "https://pan.baidu.com/")
            ?? ""
        var components = URLComponents(string: "https://pan.baidu.com/share/list")!
        components.queryItems = [
            URLQueryItem(name: "web", value: "5"),
            URLQueryItem(name: "desc", value: "1"),
            URLQueryItem(name: "showempty", value: "0"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "num", value: "20"),
            URLQueryItem(name: "order", value: "time"),
            URLQueryItem(name: "shorturl", value: share.shortURLToken),
            URLQueryItem(name: "root", value: "1"),
            URLQueryItem(name: "view_mode", value: "1"),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "bdstoken", value: ""),
            URLQueryItem(name: "clienttype", value: "0")
        ]
        let response = try await loadShareListResponse(
            url: components.url!.absoluteString,
            shareKey: shareKey
        )
        let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        let code = Self.intValue(object?["errno"])
        guard (200..<300).contains(response.statusCode), code == 0, let object else {
            let message = Self.firstString(object ?? [:], keys: ["errmsg", "err_msg", "show_msg", "msg"])
            throw DriveEngineError.api(
                provider: .baidu,
                statusCode: response.statusCode,
                code: code,
                message: message.isEmpty ? "分享根目录加载失败" : message
            )
        }
        return (
            Self.parseFiles(object["list"]),
            Self.firstString(object, keys: ["share_id", "shareid"]),
            Self.firstString(object, keys: ["uk", "share_uk"])
        )
    }

    private func loadDirectory(
        share: BaiduShareRequest,
        shareID: String,
        shareUK: String,
        directory: String,
        page: Int
    ) async throws -> (files: [BaiduShareFile], total: Int) {
        let shareKey = await BaiduShareSessionStore.shared.key(for: share.shortURLToken)
            ?? httpClient.cookieValue(name: "BDCLND", for: "https://pan.baidu.com/")
            ?? ""
        var components = URLComponents(string: "https://pan.baidu.com/share/list")!
        components.queryItems = [
            URLQueryItem(name: "is_from_web", value: "true"),
            URLQueryItem(name: "sekey", value: shareKey.removingPercentEncoding ?? shareKey),
            URLQueryItem(name: "uk", value: shareUK),
            URLQueryItem(name: "shareid", value: shareID),
            URLQueryItem(name: "order", value: "name"),
            URLQueryItem(name: "desc", value: "0"),
            URLQueryItem(name: "showempty", value: "0"),
            URLQueryItem(name: "view_mode", value: "1"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "num", value: String(Self.pageSize)),
            URLQueryItem(name: "dir", value: directory),
            URLQueryItem(name: "t", value: ""),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: Self.appID),
            URLQueryItem(name: "bdstoken", value: ""),
            URLQueryItem(name: "logid", value: ""),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "dp-logid", value: "")
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F")
        let response = try await loadShareListResponse(
            url: components.url!.absoluteString,
            shareKey: shareKey
        )
        let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        let code = Self.intValue(object?["errno"])
        guard (200..<300).contains(response.statusCode), code == 0, let object else {
            let message = Self.firstString(object ?? [:], keys: ["errmsg", "err_msg", "show_msg", "msg"])
            throw DriveEngineError.api(
                provider: .baidu,
                statusCode: response.statusCode,
                code: code,
                message: message.isEmpty ? "分享目录加载失败" : message
            )
        }
        let files = Self.parseFiles(object["list"])
        return (files, max(Self.intValue(object["cur_total"]) ?? files.count, files.count))
    }

    private func loadShareListResponse(url: String, shareKey: String) async throws -> HTTPResponse {
        if usesCurlShareListTransport, !shareKey.isEmpty {
            return try await BaiduShareListCurlTransport.get(
                url: url,
                userAgent: Self.userAgent,
                cookie: "BDCLND=\(shareKey)",
                timeout: 25
            )
        }
        var headers = [
            "Accept-Encoding": "gzip",
            "Connection": "Keep-Alive",
            "Host": "pan.baidu.com",
            "User-Agent": Self.userAgent
        ]
        if !shareKey.isEmpty {
            headers["Cookie"] = "BDCLND=\(shareKey)"
        }
        return try await httpClient.request(
            url: url,
            method: .get,
            headers: headers,
            timeout: 25,
            allowsProxyFallback: true,
            redactsURLInLogs: true,
            handlesCookies: false
        )
    }

    private static func parseSharePage(_ html: String, statusCode: Int) throws -> (shareID: String, shareUK: String, files: [BaiduShareFile]) {
        guard let object = jsonObjectArgument(in: html, marker: "locals.mset") else {
            throw DriveEngineError.api(provider: .baidu, statusCode: statusCode, code: nil, message: "分享页缺少目录数据")
        }
        let shareID = firstString(object, keys: ["shareid", "share_id"])
        let shareUK = firstString(object, keys: ["share_uk", "shareUk", "uk"])
        guard !shareID.isEmpty, !shareUK.isEmpty else {
            throw DriveEngineError.api(provider: .baidu, statusCode: statusCode, code: nil, message: "分享页缺少分享身份")
        }
        return (shareID, shareUK, parseFiles(object["file_list"]))
    }

    private static func parseFiles(_ value: Any?) -> [BaiduShareFile] {
        let objects: [[String: Any]]
        if let value = value as? [[String: Any]] {
            objects = value
        } else if let string = value as? String,
                  let data = string.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            objects = value
        } else {
            objects = []
        }
        return objects.compactMap { item in
            let fileID = firstString(item, keys: ["fs_id", "fsId", "id"])
            let name = firstString(item, keys: ["server_filename", "serverFilename", "name"])
            guard !fileID.isEmpty, !name.isEmpty else { return nil }
            return BaiduShareFile(
                fileID: fileID,
                name: name,
                path: firstString(item, keys: ["path"]),
                size: int64Value(item["size"]) ?? 0,
                category: intValue(item["category"]) ?? 0,
                isDirectory: boolValue(item["isdir"] ?? item["is_dir"])
            )
        }
    }

    private static func jsonObjectArgument(in text: String, marker: String) -> [String: Any]? {
        guard let markerRange = text.range(of: marker),
              let start = text[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        var index = start
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: index)
                    let data = Data(text[start..<end].utf8)
                    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func pageHeaders(referer: String) -> [String: String] {
        [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Referer": referer,
            "User-Agent": userAgent
        ]
    }

    private static var accountQueryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "app_id", value: appID),
            URLQueryItem(name: "web", value: "1")
        ]
    }

    private static func timestampMilliseconds() -> String {
        String(Int64(Date().timeIntervalSince1970 * 1_000))
    }

    private static func accountListURL() -> String {
        var components = URLComponents(string: "https://pan.baidu.com/api/list")!
        components.queryItems = accountQueryItems + [
            URLQueryItem(name: "order", value: "name"),
            URLQueryItem(name: "desc", value: "0"),
            URLQueryItem(name: "num", value: "1"),
            URLQueryItem(name: "page", value: "1")
        ]
        return components.url!.absoluteString
    }

    private static func accountHeaders(cookie: String) -> [String: String] {
        [
            "Accept": "application/json, text/plain, */*",
            "Cookie": cookie,
            "Referer": "https://pan.baidu.com/disk/main",
            "User-Agent": userAgent
        ]
    }

    private static func formHeaders(cookie: String, referer: String) -> [String: String] {
        [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Cookie": cookie,
            "Origin": "https://pan.baidu.com",
            "Referer": referer,
            "User-Agent": userAgent
        ]
    }

    private static func netdiskFormHeaders(cookie: String) -> [String: String] {
        [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/x-www-form-urlencoded",
            "Cookie": cookie,
            "Referer": "https://pan.baidu.com/",
            "User-Agent": playbackUserAgent
        ]
    }

    private static func formData(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func normalizedCookie(_ credential: CloudCredential) throws -> String {
        let cookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credential.provider == .baidu, credential.kind == .cookie, !cookie.isEmpty else {
            throw DriveEngineError.loginRequired(.baidu)
        }
        return cookie
    }

    private func installCookies(_ cookie: String) {
        for pair in Self.cookiePairs(cookie) {
            _ = httpClient.setCookie(name: pair.name, value: pair.value, for: "https://pan.baidu.com/")
            _ = httpClient.setCookie(name: pair.name, value: pair.value, for: "https://passport.baidu.com/")
        }
    }

    private func mergedCookie(_ primary: String, sessionCookie: String?) -> String {
        var ordered: [(String, String)] = []
        var indexes: [String: Int] = [:]
        for pair in Self.cookiePairs(primary) + Self.cookiePairs(sessionCookie ?? "") {
            let key = pair.name.lowercased()
            if let index = indexes[key] {
                ordered[index] = (pair.name, pair.value)
            } else {
                indexes[key] = ordered.count
                ordered.append((pair.name, pair.value))
            }
        }
        return ordered.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private static func cookiePairs(_ cookie: String) -> [(name: String, value: String)] {
        cookie.split(separator: ";").compactMap { raw in
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : (name, value)
        }
    }

    private static func responseCookie(named name: String, headers: [String: String]) -> String? {
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame })?.value else {
            return nil
        }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let expression = try? NSRegularExpression(pattern: "(?:^|[,;]\\s*)\(escaped)=([^;,]+)", options: [.caseInsensitive]),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func apiError(response: HTTPResponse, object: [String: Any]?, fallback: String) -> DriveEngineError {
        let message = firstString(object ?? [:], keys: ["errmsg", "err_msg", "show_msg", "msg"])
        return .api(
            provider: .baidu,
            statusCode: response.statusCode,
            code: intValue(object?["errno"]),
            message: message.isEmpty ? fallback : message
        )
    }

    private static func isMissingSavedFile(_ error: Error) -> Bool {
        guard case .api(.baidu, let statusCode, let code, let message) = error as? DriveEngineError else {
            return false
        }
        if statusCode == 404 || [12, -9, -7].contains(code ?? Int.min) { return true }
        let lower = message.lowercased()
        return lower.contains("not found") || lower.contains("不存在") || lower.contains("已删除")
    }

    private static func isShareSessionError(_ error: Error) -> Bool {
        guard case .api(.baidu, _, let code, let message) = error as? DriveEngineError else {
            return false
        }
        if [200025, -9].contains(code ?? Int.min) { return true }
        return message.contains("提取码") ||
            message.contains("分享会话") ||
            message.contains("分享页缺少目录数据") ||
            message.contains("分享页缺少分享身份")
    }

    private func clearShareSession(for shareToken: String) async {
        try? await BaiduShareSessionStore.shared.removeKey(for: shareToken)
        httpClient.removeCookie(name: "BDCLND", for: "https://pan.baidu.com/")
    }

    private static func firstString(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let string = object[key] as? String, !string.isEmpty { return string }
            if let number = object[key] as? NSNumber { return number.stringValue }
            if let integer = object[key] as? Int { return String(integer) }
            if let integer = object[key] as? Int64 { return String(integer) }
        }
        return ""
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? Int { return value != 0 }
        if let value = value as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
        return false
    }
}
