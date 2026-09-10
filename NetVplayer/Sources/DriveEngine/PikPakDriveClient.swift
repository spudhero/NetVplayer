// DriveEngine/PikPakDriveClient.swift
// PikPak native file/share playback extraction.

import Foundation
import Models
import Networking

public struct PikPakShareRequest: Sendable {
    public let originalURL: String
    public let shareID: String
    public let passcode: String
    public let isShareTokenOnly: Bool
    public let requestedFileName: String?
    public let requestedFID: String?
    public let collectionName: String

    public init(
        originalURL: String,
        shareID: String,
        passcode: String = "",
        isShareTokenOnly: Bool = false,
        requestedFileName: String? = nil,
        requestedFID: String? = nil,
        collectionName: String = ""
    ) {
        self.originalURL = originalURL
        self.shareID = shareID
        self.passcode = passcode
        self.isShareTokenOnly = isShareTokenOnly
        self.requestedFileName = requestedFileName
        self.requestedFID = requestedFID
        self.collectionName = collectionName
    }
}

public struct PikPakShareFile: Sendable {
    public let fileID: String
    public let name: String
    public let parentID: String
    public let kind: String
    public let size: Int64
    public let streamVariants: [CloudDrivePlaybackVariant]
    public let downloadURL: String
    public let isDirectory: Bool

    public var isPlayableVideo: Bool {
        DriveMediaClassifier.isPlayableVideo(name: name, formatType: kind, isDirectory: isDirectory, isFile: !isDirectory)
    }

    public var isKnownNonVideoAsset: Bool {
        DriveMediaClassifier.isKnownNonVideoAsset(name: name)
    }
}

public struct PikPakPlayableFile: Sendable {
    public let file: PikPakShareFile

    public init(file: PikPakShareFile) {
        self.file = file
    }
}

public struct PikPakAuthenticatedCredential: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let deviceID: String
    public let updatedCredential: CloudCredential?
}

public final class PikPakDriveClient: @unchecked Sendable {
    private static let apiBase = "https://api-drive.mypikpak.com"
    private static let userBase = "https://user.mypikpak.com"
    private static let pageSize = 100
    private static let maxDirectories = 32
    private static let maxPagesPerDirectory = 8
    private static let clientID = "YNxT9w7GMdWvEOKa"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"

    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    public func shareRequest(from rawURL: String) throws -> PikPakShareRequest {
        if let reference = DriveFileReference.parse(rawURL), reference.provider == .pikpak {
            return PikPakShareRequest(
                originalURL: reference.shareURL,
                shareID: reference.pwdID,
                passcode: reference.passcode,
                isShareTokenOnly: reference.fid.isEmpty || reference.fid == reference.pwdID,
                requestedFileName: reference.fileName,
                requestedFID: reference.fid,
                collectionName: reference.collectionName
            )
        }

        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bare = Self.parseBareShareID(trimmed) {
            return PikPakShareRequest(originalURL: rawURL, shareID: bare.id, passcode: bare.passcode, requestedFID: bare.id)
        }

        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw DriveEngineError.invalidShareURL(rawURL)
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let passcode = Self.value(for: ["pwd", "password", "passcode", "code"], in: queryItems) ?? ""
        let requestedFileName = Self.value(for: ["file", "name", "episode"], in: queryItems)
        let requestedFID = Self.value(for: ["fid", "file_id", "fileId"], in: queryItems)

        let shareID: String?
        if scheme == "pikpak" {
            shareID = Self.parsePikPakScheme(url)
        } else {
            shareID = Self.parseWebShare(url)
        }

        guard let shareID, !shareID.isEmpty else {
            throw DriveEngineError.invalidShareURL(rawURL)
        }

        return PikPakShareRequest(
            originalURL: rawURL,
            shareID: shareID,
            passcode: passcode,
            isShareTokenOnly: scheme != "pikpak" && requestedFID == nil,
            requestedFileName: requestedFileName,
            requestedFID: requestedFID
        )
    }

    public func collectPlayableFiles(share: PikPakShareRequest, credential: CloudCredential? = nil) async throws -> [PikPakPlayableFile] {
        guard let credential else {
            if let fileID = share.requestedFID ?? (share.isShareTokenOnly ? nil : Self.fileIDFromShareID(share.shareID)) {
                let file = PikPakShareFile(
                    fileID: fileID,
                    name: share.requestedFileName ?? fileID,
                    parentID: "",
                    kind: "drive#file",
                    size: 0,
                    streamVariants: [],
                    downloadURL: "",
                    isDirectory: false
                )
                return [PikPakPlayableFile(file: file)]
            }
            throw DriveEngineError.loginRequired(.pikpak)
        }

        let auth = try await authenticate(credential)
        var playableFiles: [PikPakPlayableFile] = []
        var filteredAssetNames: [String] = []
        guard let initialID = share.requestedFID ?? (share.isShareTokenOnly ? nil : Self.fileIDFromShareID(share.shareID)) else {
            throw DriveEngineError.unsupported("PikPak 公开分享读取接口尚未完成验证；请先转存到个人网盘，或使用 pikpak://file/<file_id> / netvplayer-drive://pikpak/file 个人文件入口。")
        }
        var directoryQueue = [initialID]
        var visitedDirectories = Set<String>()

        while !directoryQueue.isEmpty && visitedDirectories.count < Self.maxDirectories {
            let parentID = directoryQueue.removeFirst()
            guard visitedDirectories.insert(parentID).inserted else { continue }

            if parentID != "root",
               let detail = try? await fileDetail(fileID: parentID, auth: auth) {
                if detail.isDirectory {
                    directoryQueue.append(detail.fileID)
                    continue
                }
                if detail.isPlayableVideo {
                    playableFiles.append(PikPakPlayableFile(file: detail))
                } else if detail.isKnownNonVideoAsset {
                    filteredAssetNames.append(detail.name)
                }
                continue
            }

            var pageToken = ""
            for _ in 1...Self.maxPagesPerDirectory {
                let page = try await listFiles(parentID: parentID, pageToken: pageToken, auth: auth)
                for item in page.files {
                    if item.isDirectory {
                        directoryQueue.append(item.fileID)
                    } else if item.isPlayableVideo {
                        playableFiles.append(PikPakPlayableFile(file: item))
                    } else if item.isKnownNonVideoAsset {
                        filteredAssetNames.append(item.name)
                    }
                }
                pageToken = page.nextPageToken
                if pageToken.isEmpty || page.files.count < Self.pageSize {
                    break
                }
            }
        }

        if !filteredAssetNames.isEmpty {
            let sample = filteredAssetNames.prefix(6).joined(separator: ", ")
            DiagnosticLog.write("[PIKPAK_SHARE_FILTER] filtered non-video assets count=\(filteredAssetNames.count) names=\(sample)")
        }

        return playableFiles.sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
    }

    public func selectPlayableFile(from files: [PikPakPlayableFile], share: PikPakShareRequest) -> PikPakPlayableFile? {
        if let requestedFID = share.requestedFID,
           let exact = files.first(where: { $0.file.fileID == requestedFID }) {
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

    public func fileReference(for playable: PikPakPlayableFile, share: PikPakShareRequest, collectionName: String = "") -> DriveFileReference {
        DriveFileReference(
            provider: .pikpak,
            shareURL: share.originalURL,
            pwdID: share.shareID,
            passcode: share.passcode,
            fid: playable.file.fileID,
            fidToken: "",
            fileName: playable.file.name,
            collectionName: collectionName
        )
    }

    public func link(reference: DriveFileReference, credential: CloudCredential) async throws -> CloudDriveLink {
        guard reference.provider == .pikpak else {
            throw DriveEngineError.unsupported("PikPakDriveClient 只能处理 PikPak 文件引用。")
        }
        let auth = try await authenticate(credential)
        let file = try await fileDetail(fileID: reference.fid, auth: auth, fallbackName: reference.fileName)
        return try playbackLink(file: file, auth: auth)
    }

    public func link(file: PikPakShareFile, credential: CloudCredential) async throws -> CloudDriveLink {
        let auth = try await authenticate(credential)
        let detail = file.streamVariants.isEmpty && file.downloadURL.isEmpty
            ? try await fileDetail(fileID: file.fileID, auth: auth, fallbackName: file.name)
            : file
        return try playbackLink(file: detail, auth: auth)
    }

    public func authenticate(_ credential: CloudCredential) async throws -> PikPakAuthenticatedCredential {
        let accessToken = ppFirstNonEmpty([
            credential.accessToken ?? "",
            credential.metadata["access_token"] ?? "",
            credential.secret
        ])
        let refreshToken = ppFirstNonEmpty([
            credential.refreshToken ?? "",
            credential.metadata["refresh_token"] ?? ""
        ])
        let deviceID = ppFirstNonEmpty([
            credential.deviceID ?? "",
            credential.metadata["device_id"] ?? "",
            credential.metadata["deviceID"] ?? ""
        ])

        if !accessToken.isEmpty {
            return PikPakAuthenticatedCredential(
                accessToken: accessToken,
                refreshToken: refreshToken,
                deviceID: deviceID,
                updatedCredential: nil
            )
        }

        guard !refreshToken.isEmpty else {
            throw DriveEngineError.loginRequired(.pikpak)
        }

        let object = try await postJSON(
            url: Self.userURL(path: "/v1/auth/token"),
            headers: requestHeaders(accessToken: nil, deviceID: deviceID),
            body: [
                "client_id": Self.clientID,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token"
            ]
        )
        let newAccessToken = ppFirstString(object, keys: ["access_token", "accessToken"])
        guard !newAccessToken.isEmpty else {
            throw DriveEngineError.loginRequired(.pikpak)
        }
        var updated = credential
        updated.accessToken = newAccessToken
        updated.refreshToken = ppFirstNonEmpty([ppFirstString(object, keys: ["refresh_token", "refreshToken"]), refreshToken])
        updated.secret = newAccessToken
        if !deviceID.isEmpty {
            updated.deviceID = deviceID
            updated.metadata["device_id"] = deviceID
        }
        updated.updatedAt = Date()
        return PikPakAuthenticatedCredential(
            accessToken: newAccessToken,
            refreshToken: updated.refreshToken ?? refreshToken,
            deviceID: deviceID,
            updatedCredential: updated
        )
    }

    private func playbackLink(file: PikPakShareFile, auth: PikPakAuthenticatedCredential) throws -> CloudDriveLink {
        let fallbackVariant = CloudDrivePlaybackVariant.sortedForPlayback(file.streamVariants).first { !$0.isOriginal }
        if !file.downloadURL.isEmpty {
            let original = CloudDrivePlaybackVariant(quality: "Origin", label: "原画", url: file.downloadURL, isOriginal: true)
            let originalMetadata = metadata(file: file, route: DrivePlaybackRoute.originalDownload, variant: original, canUpdateProgress: true)
            let headers = playbackHeaders(accessToken: auth.accessToken)
            let fallbackMetadata = fallbackVariant.map {
                CloudDrivePlaybackMetadata.variantMetadata(
                    $0,
                    route: DrivePlaybackRoute.streamVariant,
                    canUpdateProgress: true
                )
            } ?? [:]
            return CloudDriveLink(
                url: file.downloadURL,
                headers: headers,
                metadata: originalMetadata,
                updatedCredential: auth.updatedCredential,
                playbackPlan: PikPakDrivePlaybackAdapter().playbackPlan(
                    primaryURL: file.downloadURL,
                    primaryHeaders: headers,
                    primaryMetadata: originalMetadata,
                    fallbackURL: fallbackVariant?.url,
                    fallbackHeaders: headers,
                    fallbackMetadata: fallbackMetadata
                )
            )
        }
        if let variant = fallbackVariant {
            let variantMetadata = metadata(file: file, route: DrivePlaybackRoute.streamVariant, variant: variant, canUpdateProgress: true)
            let headers = playbackHeaders(accessToken: auth.accessToken)
            return CloudDriveLink(
                url: variant.url,
                headers: headers,
                metadata: variantMetadata,
                updatedCredential: auth.updatedCredential,
                playbackPlan: PikPakDrivePlaybackAdapter().playbackPlan(
                    primaryURL: variant.url,
                    primaryHeaders: headers,
                    primaryMetadata: variantMetadata
                )
            )
        }
        throw DriveEngineError.noDownloadURL(file.name)
    }

    private func fileDetail(fileID: String, auth: PikPakAuthenticatedCredential, fallbackName: String = "") async throws -> PikPakShareFile {
        let response = try await httpClient.get(
            url: Self.apiURL(path: "/drive/v1/files/\(Self.urlPathEscaped(fileID))?thumbnail_size=SIZE_LARGE"),
            headers: requestHeaders(accessToken: auth.accessToken, deviceID: auth.deviceID),
            timeout: 30
        )
        let object = try Self.parseJSONResponse(data: response.data, statusCode: response.statusCode)
        guard var file = Self.file(from: object) else {
            throw DriveEngineError.noDownloadURL(fallbackName.isEmpty ? fileID : fallbackName)
        }
        if file.name.isEmpty && !fallbackName.isEmpty {
            file = PikPakShareFile(
                fileID: file.fileID,
                name: fallbackName,
                parentID: file.parentID,
                kind: file.kind,
                size: file.size,
                streamVariants: file.streamVariants,
                downloadURL: file.downloadURL,
                isDirectory: file.isDirectory
            )
        }
        return file
    }

    private func listFiles(parentID: String, pageToken: String, auth: PikPakAuthenticatedCredential) async throws -> PikPakFileListPage {
        var components = URLComponents(string: Self.apiURL(path: "/drive/v1/files"))
        var queryItems = [
            URLQueryItem(name: "thumbnail_size", value: "SIZE_MEDIUM"),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
            URLQueryItem(name: "with_audit", value: "true"),
            URLQueryItem(name: "filters", value: #"{"trashed":{"eq":false},"phase":{"eq":"PHASE_TYPE_COMPLETE"}}"#)
        ]
        if parentID != "root" {
            queryItems.append(URLQueryItem(name: "parent_id", value: parentID))
        }
        if !pageToken.isEmpty {
            queryItems.append(URLQueryItem(name: "page_token", value: pageToken))
        }
        components?.queryItems = queryItems

        let response = try await httpClient.get(
            url: components?.url?.absoluteString ?? Self.apiURL(path: "/drive/v1/files"),
            headers: requestHeaders(accessToken: auth.accessToken, deviceID: auth.deviceID),
            timeout: 30
        )
        let object = try Self.parseJSONResponse(data: response.data, statusCode: response.statusCode)
        let rawItems = object["files"] as? [[String: Any]] ?? []
        return PikPakFileListPage(
            files: rawItems.compactMap(Self.file(from:)),
            nextPageToken: ppFirstString(object, keys: ["next_page_token", "nextPageToken"])
        )
    }

    private func postJSON(url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await httpClient.post(url: url, headers: headers, body: data, timeout: 30)
        return try Self.parseJSONResponse(data: response.data, statusCode: response.statusCode)
    }

    private func requestHeaders(accessToken: String?, deviceID: String?) -> [String: String] {
        var headers = [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json; charset=utf-8",
            "User-Agent": Self.userAgent
        ]
        if let deviceID, !deviceID.isEmpty {
            headers["X-Device-Id"] = deviceID
        }
        if let accessToken, !accessToken.isEmpty {
            headers["Authorization"] = accessToken.hasPrefix("Bearer ") ? accessToken : "Bearer \(accessToken)"
        }
        return headers
    }

    private func playbackHeaders(accessToken: String) -> [String: String] {
        var headers = [
            "User-Agent": Self.userAgent,
            "Referer": "https://mypikpak.com/"
        ]
        if !accessToken.isEmpty {
            headers["Authorization"] = accessToken.hasPrefix("Bearer ") ? accessToken : "Bearer \(accessToken)"
        }
        return headers
    }

    private func metadata(
        file: PikPakShareFile,
        route: String,
        variant: CloudDrivePlaybackVariant? = nil,
        canUpdateProgress: Bool = false
    ) -> [String: String] {
        var values = [
            "provider": DriveProvider.pikpak.rawValue,
            "file_id": file.fileID,
            "file_name": file.name,
            "route": route,
            DrivePlaybackMetadataKey.provider: DriveProvider.pikpak.rawValue,
            DrivePlaybackMetadataKey.fid: file.fileID,
            DrivePlaybackMetadataKey.personalFileID: file.fileID,
            DrivePlaybackMetadataKey.fileName: file.name,
            DrivePlaybackMetadataKey.route: route,
            DrivePlaybackMetadataKey.size: String(file.size)
        ]
        if let variant {
            values[DrivePlaybackMetadataKey.quality] = variant.quality
            values[DrivePlaybackMetadataKey.qualityLabel] = variant.label
            values[DrivePlaybackMetadataKey.width] = String(variant.width)
            values[DrivePlaybackMetadataKey.height] = String(variant.height)
        }
        if canUpdateProgress {
            values[DrivePlaybackMetadataKey.canUpdateProgress] = "true"
        }
        return values
    }
}

private struct PikPakFileListPage: Sendable {
    let files: [PikPakShareFile]
    let nextPageToken: String
}

private extension PikPakDriveClient {
    static func apiURL(path: String) -> String {
        Self.apiBase + path
    }

    static func userURL(path: String) -> String {
        Self.userBase + path
    }

    static func parseJSONResponse(data: Data, statusCode: Int) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveEngineError.api(provider: .pikpak, statusCode: statusCode, code: nil, message: "响应不是 JSON")
        }
        let error = ppFirstNonEmpty([
            ppFirstString(object, keys: ["error_description", "message", "error"])
        ])
        if !error.isEmpty {
            throw DriveEngineError.api(provider: .pikpak, statusCode: statusCode, code: nil, message: error)
        }
        if statusCode >= 400 {
            throw DriveEngineError.api(provider: .pikpak, statusCode: statusCode, code: statusCode, message: "PikPak 接口返回 HTTP \(statusCode)")
        }
        return object
    }

    static func file(from item: [String: Any]) -> PikPakShareFile? {
        let fileID = ppFirstString(item, keys: ["id", "file_id", "fileId"])
        let name = ppFirstString(item, keys: ["name", "file_name", "fileName"])
        guard !fileID.isEmpty else { return nil }
        let kind = ppFirstString(item, keys: ["kind", "type", "mime_type", "mimeType"])
        let isDirectory = kind.lowercased().contains("folder")
            || ppBoolValue(item["is_directory"])
            || ppBoolValue(item["isDir"])
        return PikPakShareFile(
            fileID: fileID,
            name: name,
            parentID: ppFirstString(item, keys: ["parent_id", "parentId"]),
            kind: kind,
            size: ppInt64Value(item["size"]),
            streamVariants: streamVariants(from: item),
            downloadURL: ppFirstString(item, keys: ["web_content_link", "webContentLink", "download_url", "downloadUrl"]),
            isDirectory: isDirectory
        )
    }

    static func streamVariants(from item: [String: Any]) -> [CloudDrivePlaybackVariant] {
        let medias = (item["medias"] as? [[String: Any]])
            ?? (item["media"] as? [[String: Any]])
            ?? []
        return CloudDrivePlaybackVariant.sortedForPlayback(medias.compactMap { media in
            let link = media["link"] as? [String: Any] ?? media
            let url = ppFirstString(link, keys: ["url", "play_url", "playUrl"])
            guard !url.isEmpty else { return nil }
            let mediaName = ppFirstString(media, keys: ["media_name", "mediaName", "name", "quality"])
            let width = ppIntValue(media["width"] ?? link["width"])
            let height = ppIntValue(media["height"] ?? link["height"])
            let label = ppFirstNonEmpty([mediaName, height > 0 ? "\(height)p" : "转码"])
            return CloudDrivePlaybackVariant(
                quality: mediaName.isEmpty ? label : mediaName,
                label: label,
                width: width,
                height: height,
                url: url
            )
        })
    }

    static func parseBareShareID(_ value: String) -> (id: String, passcode: String)? {
        guard value.range(of: #"^[A-Za-z0-9_-]{6,}([?&].*)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let parts = value.split(separator: "?", maxSplits: 1).map(String.init)
        let passcode: String
        if parts.count == 2,
           let components = URLComponents(string: "pikpak://share/\(parts[0])?\(parts[1])") {
            passcode = Self.value(for: ["pwd", "password", "passcode", "code"], in: components.queryItems ?? []) ?? ""
        } else {
            passcode = ""
        }
        return (parts[0], passcode)
    }

    static func parsePikPakScheme(_ url: URL) -> String? {
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let components = url.pathComponents.filter { $0 != "/" }
        if !host.isEmpty, !["share", "s", "file"].contains(host.lowercased()) {
            return host
        }
        if let index = components.firstIndex(where: { ["share", "s", "file"].contains($0.lowercased()) }),
           components.indices.contains(index + 1) {
            return components[index + 1]
        }
        return components.first
    }

    static func parseWebShare(_ url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        if let index = components.firstIndex(where: { ["s", "share", "file"].contains($0.lowercased()) }),
           components.indices.contains(index + 1) {
            return components[index + 1]
        }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return value(for: ["share_id", "shareId", "id", "fid", "file_id", "fileId"], in: queryItems)
    }

    static func fileIDFromShareID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func value(for names: [String], in queryItems: [URLQueryItem]) -> String? {
        for name in names {
            if let value = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func urlPathEscaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private func ppFirstString(_ dict: [String: Any], keys: [String]) -> String {
    for key in keys {
        if let value = dict[key] {
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            if let int = value as? Int { return String(int) }
            if let int64 = value as? Int64 { return String(int64) }
        }
    }
    return ""
}

private func ppFirstNonEmpty(_ values: [String]) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func ppBoolValue(_ value: Any?) -> Bool {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? String {
        return ["1", "true", "yes", "folder", "directory"].contains(string.lowercased())
    }
    return false
}

private func ppInt64Value(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber { return number.int64Value }
    if let int = value as? Int { return Int64(int) }
    if let int64 = value as? Int64 { return int64 }
    if let string = value as? String { return Int64(string) ?? 0 }
    return 0
}

private func ppIntValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let int = value as? Int { return int }
    if let string = value as? String { return Int(string) ?? 0 }
    return 0
}
