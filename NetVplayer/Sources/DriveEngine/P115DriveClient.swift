// DriveEngine/P115DriveClient.swift
// 115 public share listing and cookie-backed playback extraction.

import Foundation
import Models
import Networking

public struct P115ShareRequest: Sendable {
    public let originalURL: String
    public let shareCode: String
    public let receiveCode: String
    public let requestedFileName: String?
    public let requestedFID: String?
    public let collectionName: String

    public init(
        originalURL: String,
        shareCode: String,
        receiveCode: String = "",
        requestedFileName: String? = nil,
        requestedFID: String? = nil,
        collectionName: String = ""
    ) {
        self.originalURL = originalURL
        self.shareCode = shareCode
        self.receiveCode = receiveCode
        self.requestedFileName = requestedFileName
        self.requestedFID = requestedFID
        self.collectionName = collectionName
    }
}

public struct P115ShareFile: Sendable {
    public let fileID: String
    public let name: String
    public let parentID: String
    public let pickCode: String
    public let size: Int64
    public let category: String
    public let downloadURL: String
    public let isDirectory: Bool

    public var isPlayableVideo: Bool {
        DriveMediaClassifier.isPlayableVideo(name: name, formatType: category, isDirectory: isDirectory, isFile: !isDirectory)
    }

    public var isKnownNonVideoAsset: Bool {
        DriveMediaClassifier.isKnownNonVideoAsset(name: name)
    }
}

public struct P115PlayableFile: Sendable {
    public let file: P115ShareFile

    public init(file: P115ShareFile) {
        self.file = file
    }
}

public final class P115DriveClient: @unchecked Sendable {
    private static let webAPIBase = "https://webapi.115.com"
    private static let proAPIBase = "https://proapi.115.com"
    private static let pageSize = 200
    private static let maxDirectories = 32
    private static let maxPagesPerDirectory = 8
    private static let currentWebUserAgent: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let safariVersion = "\(version.majorVersion).\(version.minorVersion)"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }()
    private static let userAgent = currentWebUserAgent

    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    public func validate(_ credential: CloudCredential) async throws -> CloudCredential {
        guard credential.provider == .p115, credential.kind == .cookie else {
            throw DriveEngineError.unsupported("115 分享播放需要 115 Cookie 凭证。")
        }

        let cookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            throw DriveEngineError.loginRequired(.p115)
        }

        DiagnosticLog.write("[P115_AUTH] validation_started")
        do {
            _ = try await loadPersonalFilesPage(parentID: "0", offset: 0, limit: 1, cookie: cookie)
            var validated = credential
            validated.secret = cookie
            validated.updatedAt = Date()
            DiagnosticLog.write("[P115_AUTH] validation_succeeded")
            return validated
        } catch {
            DiagnosticLog.write("[P115_AUTH] validation_failed type=\(String(describing: type(of: error)))")
            throw error
        }
    }

    public func shareRequest(from rawURL: String) throws -> P115ShareRequest {
        if let reference = DriveFileReference.parse(rawURL), reference.provider == .p115 {
            return P115ShareRequest(
                originalURL: reference.shareURL,
                shareCode: reference.pwdID,
                receiveCode: reference.passcode,
                requestedFileName: reference.fileName,
                requestedFID: reference.fid,
                collectionName: reference.collectionName
            )
        }

        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bare = Self.parseBareShare(trimmed) {
            return P115ShareRequest(originalURL: rawURL, shareCode: bare.code, receiveCode: bare.receiveCode)
        }

        let normalizedURL = trimmed.hasPrefix("115://") ? "p\(trimmed)" : trimmed
        guard let url = URL(string: normalizedURL), let scheme = url.scheme?.lowercased() else {
            throw DriveEngineError.invalidShareURL(rawURL)
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let receiveCode = Self.value(for: ["password", "pwd", "passcode", "code", "receive_code"], in: queryItems) ?? ""
        let requestedFileName = Self.value(for: ["file", "name", "episode"], in: queryItems)
        let requestedFID = Self.value(for: ["fid", "file_id", "fileId"], in: queryItems)

        let shareCode: String?
        if scheme == "115" || scheme == "p115" {
            shareCode = Self.parse115Scheme(url)
        } else {
            shareCode = Self.parseWebShare(url)
        }

        guard let shareCode, !shareCode.isEmpty else {
            throw DriveEngineError.invalidShareURL(rawURL)
        }

        return P115ShareRequest(
            originalURL: rawURL,
            shareCode: shareCode,
            receiveCode: receiveCode,
            requestedFileName: requestedFileName,
            requestedFID: requestedFID
        )
    }

    public func collectPlayableFiles(share: P115ShareRequest, cookie: String? = nil) async throws -> [P115PlayableFile] {
        var playableFiles: [P115PlayableFile] = []
        var filteredAssetNames: [String] = []
        var directoryQueue = ["0"]
        var visitedDirectories = Set<String>()

        while !directoryQueue.isEmpty && visitedDirectories.count < Self.maxDirectories {
            let parentID = directoryQueue.removeFirst()
            guard visitedDirectories.insert(parentID).inserted else { continue }

            for page in 1...Self.maxPagesPerDirectory {
                let files = try await loadShareList(share: share, parentID: parentID, page: page, cookie: cookie)
                for item in files {
                    if item.isDirectory {
                        directoryQueue.append(item.fileID)
                    } else if item.isPlayableVideo {
                        playableFiles.append(P115PlayableFile(file: item))
                    } else if item.isKnownNonVideoAsset {
                        filteredAssetNames.append(item.name)
                    }
                }
                if files.count < Self.pageSize {
                    break
                }
            }
        }

        if !filteredAssetNames.isEmpty {
            let sample = filteredAssetNames.prefix(6).joined(separator: ", ")
            DiagnosticLog.write("[115_SHARE_FILTER] filtered non-video assets count=\(filteredAssetNames.count) names=\(sample)")
        }

        return playableFiles.sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
    }

    public func selectPlayableFile(from files: [P115PlayableFile], share: P115ShareRequest) -> P115PlayableFile? {
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

    public func fileReference(for playable: P115PlayableFile, share: P115ShareRequest, collectionName: String = "") -> DriveFileReference {
        DriveFileReference(
            provider: .p115,
            shareURL: share.originalURL,
            pwdID: share.shareCode,
            passcode: share.receiveCode,
            fid: playable.file.fileID,
            fidToken: playable.file.pickCode.isEmpty ? playable.file.fileID : playable.file.pickCode,
            fileName: playable.file.name,
            collectionName: collectionName
        )
    }

    public func link(reference: DriveFileReference, cookie: String, accessToken: String? = nil) async throws -> CloudDriveLink {
        guard reference.provider == .p115 else {
            throw DriveEngineError.unsupported("P115DriveClient 只能处理 115 网盘文件引用。")
        }
        let share = try shareRequest(from: reference.encodedURL)
        let file = P115ShareFile(
            fileID: reference.fid,
            name: reference.fileName,
            parentID: "",
            pickCode: reference.fidToken,
            size: 0,
            category: "video",
            downloadURL: "",
            isDirectory: false
        )
        if let token = normalizedAccessToken(accessToken),
           !reference.personalFileID.isEmpty || !reference.pickCode.isEmpty {
            let personal = PersonalDriveFileReference(
                provider: .p115,
                driveID: reference.personalDriveID.isEmpty ? "115" : reference.personalDriveID,
                fileID: reference.personalFileID.isEmpty ? reference.fid : reference.personalFileID,
                pickCode: firstNonEmpty([reference.pickCode, reference.fidToken]),
                fileName: reference.fileName
            )
            if let personalLink = try? await personalPlaybackLink(file: file, personal: personal, cookie: cookie, accessToken: token) {
                return personalLink
            }
        }
        return try await link(file: file, share: share, cookie: cookie, accessToken: accessToken)
    }

    public func link(file: P115ShareFile, share: P115ShareRequest, cookie: String, accessToken: String? = nil) async throws -> CloudDriveLink {
        let normalizedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCookie.isEmpty else {
            throw DriveEngineError.loginRequired(.p115)
        }
        if let token = normalizedAccessToken(accessToken),
           let personal = try? await saveShareFile(file: file, share: share, cookie: normalizedCookie, accessToken: token),
           let personalLink = try? await personalPlaybackLink(
               file: file,
               personal: personal,
               cookie: normalizedCookie,
               accessToken: token,
               temporarySavedFile: true
           ) {
            if let fallbackLink = try? await shareFallbackLink(
                file: file,
                share: share,
                cookie: normalizedCookie
            ) {
                return appendingShareFallback(fallbackLink, to: personalLink)
            }
            return personalLink
        }

        do {
            let personalLink = try await cookiePersonalHLSLink(
                file: file,
                share: share,
                cookie: normalizedCookie
            )
            if let fallbackLink = try? await shareFallbackLink(
                file: file,
                share: share,
                cookie: normalizedCookie
            ) {
                return appendingShareFallback(fallbackLink, to: personalLink)
            }
            return personalLink
        } catch {
            let personalPlaybackError = error
            DiagnosticLog.write(
                "[P115_COOKIE_TRANSFER] failed stage=playback tag=\(Self.diagnosticTag(for: error))"
            )
            do {
                return try await shareFallbackLink(file: file, share: share, cookie: normalizedCookie)
            } catch {
                if let driveError = personalPlaybackError as? DriveEngineError,
                   case .loginRequired = driveError {
                    throw driveError
                }
                throw error
            }
        }
    }

    private func appendingShareFallback(
        _ fallbackLink: CloudDriveLink,
        to personalLink: CloudDriveLink
    ) -> CloudDriveLink {
        let adapter = P115DrivePlaybackAdapter()
        guard let personalPlan = personalLink.playbackPlan,
              let fallbackPlan = adapter.playbackPlan(
                  from: fallbackLink,
                  primaryHeaders: fallbackLink.headers,
                  primaryMPVOptions: [:]
              ) else {
            return personalLink
        }
        let plan = DrivePlaybackPlan(
            provider: .p115,
            asset: personalPlan.asset,
            candidates: personalPlan.candidates + fallbackPlan.candidates,
            cleanup: personalPlan.cleanup,
            reauthenticationRequired: personalPlan.reauthenticationRequired,
            unavailableReason: personalPlan.unavailableReason
        )
        return CloudDriveLink(
            url: personalLink.url,
            headers: personalLink.headers,
            metadata: personalLink.metadata,
            updatedCredential: personalLink.updatedCredential,
            playbackPlan: plan
        )
    }

    private func shareFallbackLink(file: P115ShareFile, share: P115ShareRequest, cookie normalizedCookie: String) async throws -> CloudDriveLink {
        if !file.downloadURL.isEmpty {
            return CloudDriveLink(url: file.downloadURL, headers: playbackHeaders(cookie: normalizedCookie), metadata: metadata(file: file, route: DrivePlaybackRoute.shareFallback))
        }

        guard let userID = Self.userID(fromCookie: normalizedCookie) else {
            throw DriveEngineError.loginRequired(.p115)
        }
        var components = URLComponents(string: Self.webAPIURL(path: "/share/downurl"))
        components?.queryItems = [
            URLQueryItem(name: "dl", value: "1"),
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "share_code", value: share.shareCode),
            URLQueryItem(name: "receive_code", value: share.receiveCode),
            URLQueryItem(name: "file_id", value: file.fileID)
        ]
        var headers = requestHeaders(cookie: normalizedCookie)
        headers["User-Agent"] = Self.currentWebUserAgent
        do {
            let object = try await getJSON(
                url: components?.url?.absoluteString ?? Self.webAPIURL(path: "/share/downurl"),
                headers: headers
            )
            if let url = Self.downloadURL(from: object, fileID: file.fileID) {
                return CloudDriveLink(url: url, headers: playbackHeaders(cookie: normalizedCookie), metadata: metadata(file: file, route: DrivePlaybackRoute.shareFallback))
            }
        } catch {
            if let original = try? await legacyAppShareDownloadLink(
                file: file,
                share: share,
                cookie: normalizedCookie
            ) {
                return original
            }
            if let original = try? await encryptedShareDownloadLink(
                file: file,
                share: share,
                cookie: normalizedCookie
            ) {
                return original
            }
            if let preview = try? await hlsPlaybackLink(file: file, cookie: normalizedCookie) {
                return preview
            }
            throw error
        }
        if let original = try? await legacyAppShareDownloadLink(
            file: file,
            share: share,
            cookie: normalizedCookie
        ) {
            return original
        }
        if let original = try? await encryptedShareDownloadLink(
            file: file,
            share: share,
            cookie: normalizedCookie
        ) {
            return original
        }
        if let preview = try? await hlsPlaybackLink(file: file, cookie: normalizedCookie) {
            return preview
        }
        throw DriveEngineError.noDownloadURL(file.name)
    }

    private func legacyAppShareDownloadLink(
        file: P115ShareFile,
        share: P115ShareRequest,
        cookie: String
    ) async throws -> CloudDriveLink {
        var components = URLComponents(string: Self.proAPIURL(path: "/os_windows/2.0/share/downurl"))
        components?.queryItems = [
            URLQueryItem(name: "file_id", value: file.fileID),
            URLQueryItem(name: "receive_code", value: share.receiveCode),
            URLQueryItem(name: "share_code", value: share.shareCode)
        ]
        let object = try await getJSON(
            url: components?.url?.absoluteString ?? Self.proAPIURL(path: "/os_windows/2.0/share/downurl"),
            headers: requestHeaders(cookie: cookie)
        )
        guard let url = Self.downloadURL(from: object, fileID: file.fileID) else {
            throw DriveEngineError.noDownloadURL(file.name)
        }
        DiagnosticLog.write("[P115_SHARE_ORIGINAL] ready route=os-windows")
        return shareOriginalLink(file: file, url: url, cookie: cookie)
    }

    private func encryptedShareDownloadLink(
        file: P115ShareFile,
        share: P115ShareRequest,
        cookie: String
    ) async throws -> CloudDriveLink {
        var lastError: Error?
        var decrypted: [String: Any]?
        for attempt in 0..<3 {
            do {
                decrypted = try await cookieEncryptedDownloadData(
                    payload: [
                        "file_id": file.fileID,
                        "receive_code": share.receiveCode,
                        "share_code": share.shareCode
                    ],
                    cookie: cookie,
                    endpoint: "/app/share/downurl"
                )
                break
            } catch {
                lastError = error
                DiagnosticLog.write(
                    "[P115_SHARE_ORIGINAL] encrypted_failed attempt=\(attempt + 1) tag=\(Self.diagnosticTag(for: error))"
                )
                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        guard let decrypted else {
            if let lastError { throw lastError }
            throw DriveEngineError.noDownloadURL(file.name)
        }
        guard let url = Self.downloadURL(from: ["data": decrypted], fileID: file.fileID) else {
            throw DriveEngineError.noDownloadURL(file.name)
        }
        DiagnosticLog.write("[P115_SHARE_ORIGINAL] ready route=encrypted")
        return shareOriginalLink(file: file, url: url, cookie: cookie)
    }

    private func shareOriginalLink(
        file: P115ShareFile,
        url: String,
        cookie: String
    ) -> CloudDriveLink {
        let variant = CloudDrivePlaybackVariant(
            quality: "Origin",
            label: "原画",
            url: url,
            isOriginal: true
        )
        let originalMetadata = metadata(
            file: file,
            route: DrivePlaybackRoute.originalDownload,
            variant: variant
        )
        let headers = playbackHeaders(cookie: cookie)
        return CloudDriveLink(
            url: url,
            headers: headers,
            metadata: originalMetadata,
            playbackPlan: P115DrivePlaybackAdapter().playbackPlan(
                primaryURL: url,
                primaryHeaders: headers,
                primaryMetadata: originalMetadata
            )
        )
    }

    private func hlsPlaybackLink(
        file: P115ShareFile,
        cookie: String,
        pickCode: String? = nil,
        personal: PersonalDriveFileReference? = nil,
        temporarySavedFile: Bool = false
    ) async throws -> CloudDriveLink {
        let selectedPickCode = pickCode ?? file.pickCode
        guard !selectedPickCode.isEmpty else {
            throw DriveEngineError.noDownloadURL(file.name)
        }
        let encodedPickCode = selectedPickCode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedPickCode
        let masterURL = "https://115.com/api/video/m3u8/\(encodedPickCode).m3u8"
        let response = try await httpClient.get(
            url: masterURL,
            headers: playbackHeaders(cookie: cookie),
            timeout: 30,
            redactsURLInLogs: true
        )
        let contentType = response.headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value ?? ""
        let master = String(data: response.data, encoding: .utf8) ?? ""
        let responseCode = (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any])
            .flatMap(Self.errorCode(from:))
        guard (200..<300).contains(response.statusCode),
              master.hasPrefix("#EXTM3U") else {
            DiagnosticLog.write(
                "[P115_HLS] rejected status=\(response.statusCode) contentType=\(contentType) bytes=\(response.data.count) code=\(responseCode.map(String.init) ?? "-")"
            )
            throw DriveEngineError.noDownloadURL(file.name)
        }
        let variants = Self.hlsVariants(from: master, masterURL: masterURL)
        guard let variant = variants.max(by: {
                  if $0.height != $1.height { return $0.height < $1.height }
                  return $0.width < $1.width
              }) else {
            DiagnosticLog.write(
                "[P115_HLS] rejected status=\(response.statusCode) contentType=\(contentType) bytes=\(response.data.count) format=playlist variants=0"
            )
            throw DriveEngineError.noDownloadURL(file.name)
        }
        DiagnosticLog.write(
            "[P115_HLS] accepted status=\(response.statusCode) contentType=\(contentType) bytes=\(response.data.count) variants=\(variants.count)"
        )
        let playbackMetadata = metadata(
            file: file,
            route: DrivePlaybackRoute.streamVariant,
            personal: personal,
            variant: variant,
            temporarySavedFile: temporarySavedFile
        )
        let headers = playbackHeaders(cookie: cookie)
        return CloudDriveLink(
            url: variant.url,
            headers: headers,
            metadata: playbackMetadata,
            playbackPlan: P115DrivePlaybackAdapter().playbackPlan(
                primaryURL: variant.url,
                primaryHeaders: headers,
                primaryMetadata: playbackMetadata
            )
        )
    }

    private func cookiePersonalHLSLink(
        file: P115ShareFile,
        share: P115ShareRequest,
        cookie: String
    ) async throws -> CloudDriveLink {
        let savedFile = try await saveShareFileWithCookie(file: file, share: share, cookie: cookie)
        let personal = savedFile.reference
        do {
            let link: CloudDriveLink
            do {
                link = try await hlsPlaybackLink(
                    file: file,
                    cookie: cookie,
                    pickCode: personal.pickCode,
                    personal: personal,
                    temporarySavedFile: savedFile.temporary
                )
            } catch {
                do {
                    link = try await cookieVideoPlaybackLink(
                        file: file,
                        personal: personal,
                        cookie: cookie,
                        temporarySavedFile: savedFile.temporary
                    )
                } catch {
                    DiagnosticLog.write(
                        "[P115_COOKIE_VIDEO] failed tag=\(Self.diagnosticTag(for: error))"
                    )
                    do {
                        link = try await cookieOriginalDownloadLink(
                            file: file,
                            personal: personal,
                            cookie: cookie,
                            temporarySavedFile: savedFile.temporary
                        )
                    } catch {
                        DiagnosticLog.write(
                            "[P115_COOKIE_ORIGINAL] failed tag=\(Self.diagnosticTag(for: error))"
                        )
                        throw error
                    }
                }
            }
            DiagnosticLog.write("[P115_COOKIE_TRANSFER] playback_ready")
            return link
        } catch {
            if savedFile.temporary {
                _ = try? await postForm(
                    url: Self.webAPIURL(path: "/rb/delete"),
                    headers: requestHeaders(cookie: cookie),
                    body: ["fid[0]": personal.fileID]
                )
            }
            throw error
        }
    }

    private func cookieVideoPlaybackLink(
        file: P115ShareFile,
        personal: PersonalDriveFileReference,
        cookie: String,
        temporarySavedFile: Bool
    ) async throws -> CloudDriveLink {
        var components = URLComponents(string: Self.webAPIURL(path: "/files/video"))
        components?.queryItems = [URLQueryItem(name: "pickcode", value: personal.pickCode)]
        let object = try await getJSON(
            url: components?.url?.absoluteString ?? Self.webAPIURL(path: "/files/video"),
            headers: requestHeaders(cookie: cookie)
        )
        let variants = Self.videoVariants(from: object)
        let data = object["data"] as? [String: Any] ?? object
        let queued = !firstString(data, keys: ["queue_url", "queueUrl"]).isEmpty
        DiagnosticLog.write("[P115_COOKIE_VIDEO] variants=\(variants.count) queued=\(queued)")
        guard let variant = CloudDrivePersonalPlayback(
            file: personal,
            variants: variants,
            canUpdateProgress: true
        ).bestTranscodeVariant else {
            throw DriveEngineError.noDownloadURL(file.name)
        }
        let variantMetadata = metadata(
            file: file,
            route: DrivePlaybackRoute.personalTranscode,
            personal: personal,
            variant: variant,
            canUpdateProgress: true,
            temporarySavedFile: temporarySavedFile
        )
        let headers = playbackHeaders(cookie: cookie)
        return CloudDriveLink(
            url: variant.url,
            headers: headers,
            metadata: variantMetadata,
            playbackPlan: P115DrivePlaybackAdapter().playbackPlan(
                primaryURL: variant.url,
                primaryHeaders: headers,
                primaryMetadata: variantMetadata
            )
        )
    }

    private func cookieOriginalDownloadLink(
        file: P115ShareFile,
        personal: PersonalDriveFileReference,
        cookie: String,
        temporarySavedFile: Bool
    ) async throws -> CloudDriveLink {
        guard !personal.pickCode.isEmpty else {
            throw DriveEngineError.noDownloadURL("115 个人文件缺少 pick_code")
        }
        let decrypted: [String: Any]
        do {
            decrypted = try await cookieEncryptedDownloadData(
                payload: try Self.cookieOriginalDownloadPayload(
                    pickCode: personal.pickCode,
                    cookie: cookie,
                    pickCodeField: "pickcode"
                ),
                cookie: cookie,
                endpoint: "/app/chrome/downurl",
                userAgentOverride: ""
            )
        } catch {
            DiagnosticLog.write(
                "[P115_COOKIE_ORIGINAL] chrome_failed tag=\(Self.diagnosticTag(for: error))"
            )
            decrypted = try await cookieEncryptedDownloadData(
                payload: try Self.cookieOriginalDownloadPayload(
                    pickCode: personal.pickCode,
                    cookie: cookie,
                    pickCodeField: "pick_code"
                ),
                cookie: cookie,
                endpoint: "/android/2.0/ufile/download",
                userAgentOverride: ""
            )
        }

        guard let url = Self.downloadURL(from: ["data": decrypted], fileID: personal.fileID) else {
            throw DriveEngineError.noDownloadURL(file.name)
        }
        DiagnosticLog.write("[P115_COOKIE_ORIGINAL] ready")
        let variant = CloudDrivePlaybackVariant(
            quality: "Origin",
            label: "原画",
            url: url,
            isOriginal: true
        )
        let originalMetadata = metadata(
            file: file,
            route: DrivePlaybackRoute.originalDownload,
            personal: personal,
            variant: variant,
            temporarySavedFile: temporarySavedFile
        )
        var headers = playbackHeaders(cookie: cookie)
        headers["User-Agent"] = ""
        return CloudDriveLink(
            url: url,
            headers: headers,
            metadata: originalMetadata,
            playbackPlan: P115DrivePlaybackAdapter().playbackPlan(
                primaryURL: url,
                primaryHeaders: headers,
                primaryMetadata: originalMetadata
            )
        )
    }

    private func cookieEncryptedDownloadData(
        payload: [String: Any],
        cookie: String,
        endpoint: String,
        userAgentOverride: String? = nil
    ) async throws -> [String: Any] {
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let encryptedPayload = try P115RSACipher.encrypt(payloadData)
        var headers = requestHeaders(cookie: cookie)
        if let userAgentOverride {
            headers["User-Agent"] = userAgentOverride
        }
        let object = try await postForm(
            url: Self.proAPIURL(path: endpoint),
            headers: headers,
            body: ["data": encryptedPayload]
        )
        if let plainObject = object["data"] as? [String: Any] {
            return plainObject
        }
        guard let encryptedResponse = object["data"] as? String,
              !encryptedResponse.isEmpty else {
            throw DriveEngineError.noDownloadURL("115 原画响应缺少下载数据")
        }
        let data = try P115RSACipher.decrypt(encryptedResponse)
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveEngineError.noDownloadURL("115 原画响应无法解析")
        }
        return decoded
    }

    static func cookieOriginalDownloadPayload(
        pickCode: String,
        cookie: String,
        pickCodeField: String
    ) throws -> [String: Any] {
        guard let userIDText = userID(fromCookie: cookie),
              let userID = Int64(userIDText) else {
            throw DriveEngineError.loginRequired(.p115)
        }
        return [
            pickCodeField: pickCode,
            "user_id": userID
        ]
    }

    func ensureTransferFolder(share: P115ShareRequest, cookie: String) async throws -> String {
        let rootID = try await ensurePersonalFolder(
            named: DriveTransferDirectoryPolicy.rootFolderName,
            parentID: "0",
            cookie: cookie
        )
        guard let childName = DriveTransferDirectoryPolicy.collectionFolderName(
            collectionName: share.collectionName,
            shareID: share.shareCode
        ) else {
            return rootID
        }
        return try await ensurePersonalFolder(named: childName, parentID: rootID, cookie: cookie)
    }

    private func ensurePersonalFolder(named name: String, parentID: String, cookie: String) async throws -> String {
        let files = try await listPersonalFiles(parentID: parentID, cookie: cookie)
        if let existing = files.first(where: { $0.isDirectory && $0.name == name }) {
            return existing.fileID
        }

        do {
            let object = try await postForm(
                url: Self.webAPIURL(path: "/files/add"),
                headers: requestHeaders(cookie: cookie),
                body: ["pid": parentID, "cname": name]
            )
            let data = object["data"] as? [String: Any] ?? object
            let folderID = firstNonEmpty([
                firstString(data, keys: ["file_id", "fileId", "fid", "cid", "id"]),
                firstString(object, keys: ["file_id", "fileId", "fid", "cid", "id"])
            ])
            if !folderID.isEmpty { return folderID }
        } catch {
            let refreshed = try await listPersonalFiles(parentID: parentID, cookie: cookie)
            if let existing = refreshed.first(where: { $0.isDirectory && $0.name == name }) {
                return existing.fileID
            }
            throw error
        }

        let refreshed = try await listPersonalFiles(parentID: parentID, cookie: cookie)
        if let existing = refreshed.first(where: { $0.isDirectory && $0.name == name }) {
            return existing.fileID
        }
        throw DriveEngineError.api(provider: .p115, statusCode: 200, code: nil, message: "无法创建或定位 \(name) 转存文件夹")
    }

    private func listPersonalFiles(parentID: String, cookie: String) async throws -> [P115ShareFile] {
        var files: [P115ShareFile] = []
        for page in 0..<Self.maxPagesPerDirectory {
            let pageFiles = try await loadPersonalFilesPage(
                parentID: parentID,
                offset: page * Self.pageSize,
                limit: Self.pageSize,
                cookie: cookie
            )
            files.append(contentsOf: pageFiles)
            if pageFiles.count < Self.pageSize { break }
        }
        return files
    }

    private func loadPersonalFilesPage(
        parentID: String,
        offset: Int,
        limit: Int,
        cookie: String
    ) async throws -> [P115ShareFile] {
        var components = URLComponents(string: Self.webAPIURL(path: "/files"))
        components?.queryItems = [
            URLQueryItem(name: "aid", value: "1"),
            URLQueryItem(name: "cid", value: parentID),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "show_dir", value: "1"),
            URLQueryItem(name: "natsort", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]
        let response = try await httpClient.get(
            url: components?.url?.absoluteString ?? Self.webAPIURL(path: "/files"),
            headers: requestHeaders(cookie: cookie),
            timeout: 30
        )
        let object = try Self.parseJSONResponse(
            data: response.data,
            statusCode: response.statusCode,
            fallbackMessage: "个人文件列表失败"
        )
        return Self.files(from: object)
    }

    private func saveShareFile(file: P115ShareFile, share: P115ShareRequest, cookie: String, accessToken: String) async throws -> PersonalDriveFileReference {
        let targetFolderID = try await ensureTransferFolder(share: share, cookie: cookie)
        let object = try await postForm(
            url: Self.webAPIURL(path: "/share/receive"),
            headers: requestHeaders(cookie: cookie),
            body: [
                "share_code": share.shareCode,
                "receive_code": share.receiveCode,
                "cid": targetFolderID,
                "file_id": file.fileID
            ]
        )
        let savedFileID = Self.savedFileID(from: object)
        guard !savedFileID.isEmpty else {
            throw DriveEngineError.noDownloadURL("115 转存结果缺少个人文件 ID")
        }
        return try await personalFileReference(
            fileID: savedFileID,
            fallbackFile: file,
            accessToken: accessToken
        )
    }

    private func saveShareFileWithCookie(
        file: P115ShareFile,
        share: P115ShareRequest,
        cookie: String
    ) async throws -> (reference: PersonalDriveFileReference, temporary: Bool) {
        let targetFolderID: String
        do {
            targetFolderID = try await ensureTransferFolder(share: share, cookie: cookie)
        } catch {
            DiagnosticLog.write(
                "[P115_COOKIE_TRANSFER] failed stage=ensure_folder tag=\(Self.diagnosticTag(for: error))"
            )
            throw error
        }

        let savedFileID: String?
        let temporarySavedFile: Bool
        let wasAlreadyReceived: Bool
        do {
            let object = try await postForm(
                url: Self.webAPIURL(path: "/share/receive"),
                headers: requestHeaders(cookie: cookie),
                body: [
                    "share_code": share.shareCode,
                    "receive_code": share.receiveCode,
                    "cid": targetFolderID,
                    "file_id": file.fileID
                ]
            )
            let receivedFileID = Self.savedFileID(from: object)
            if receivedFileID.isEmpty {
                DiagnosticLog.write("[P115_COOKIE_TRANSFER] receive_accepted_without_id")
                savedFileID = nil
            } else {
                savedFileID = receivedFileID
            }
            temporarySavedFile = true
            wasAlreadyReceived = false
        } catch {
            if Self.isAlreadyReceived(error) {
                DiagnosticLog.write("[P115_COOKIE_TRANSFER] receive_already_completed")
                savedFileID = nil
                temporarySavedFile = false
                wasAlreadyReceived = true
            } else {
                DiagnosticLog.write(
                    "[P115_COOKIE_TRANSFER] failed stage=receive tag=\(Self.diagnosticTag(for: error))"
                )
                throw error
            }
        }

        for attempt in 0..<8 {
            let files: [P115ShareFile]
            do {
                files = try await listPersonalFiles(parentID: targetFolderID, cookie: cookie)
            } catch {
                DiagnosticLog.write(
                    "[P115_COOKIE_TRANSFER] failed stage=lookup tag=\(Self.diagnosticTag(for: error))"
                )
                throw error
            }
            let saved = files.first { candidate in
                guard !candidate.isDirectory, !candidate.pickCode.isEmpty else { return false }
                if let savedFileID { return candidate.fileID == savedFileID }
                guard candidate.name == file.name else { return false }
                return file.size <= 0 || candidate.size == file.size
            }
            if let saved,
               !saved.pickCode.isEmpty {
                DiagnosticLog.write(temporarySavedFile
                    ? "[P115_COOKIE_TRANSFER] saved"
                    : "[P115_COOKIE_TRANSFER] reused")
                return (
                    reference: PersonalDriveFileReference(
                        provider: .p115,
                        driveID: "115",
                        fileID: saved.fileID,
                        pickCode: saved.pickCode,
                        fileName: saved.name,
                        size: saved.size
                    ),
                    temporary: temporarySavedFile
                )
            }
            if attempt == 0,
               wasAlreadyReceived,
               let recovered = try await recoverPreviouslyReceivedFile(
                   file: file,
                   parentID: targetFolderID,
                   cookie: cookie
               ) {
                return recovered
            }
            if attempt < 7 {
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        DiagnosticLog.write("[P115_COOKIE_TRANSFER] failed stage=lookup tag=timeout")
        throw DriveEngineError.noDownloadURL("115 转存文件尚未出现在个人盘")
    }

    private func recoverPreviouslyReceivedFile(
        file: P115ShareFile,
        parentID: String,
        cookie: String
    ) async throws -> (reference: PersonalDriveFileReference, temporary: Bool)? {
        let activeFiles = try await searchPersonalFiles(
            named: file.name,
            areaID: "1",
            cookie: cookie
        )
        let activeMatches = activeFiles.filter { candidate in
            guard !candidate.isDirectory,
                  !candidate.pickCode.isEmpty,
                  candidate.name == file.name else {
                return false
            }
            return file.size <= 0 || candidate.size == file.size
        }
        DiagnosticLog.write(
            "[P115_COOKIE_TRANSFER] active_search candidates=\(activeFiles.count) matches=\(activeMatches.count)"
        )
        if let active = activeMatches.first {
            DiagnosticLog.write("[P115_COOKIE_TRANSFER] reused_from_search")
            return (
                reference: PersonalDriveFileReference(
                    provider: .p115,
                    driveID: "115",
                    fileID: active.fileID,
                    pickCode: active.pickCode,
                    fileName: active.name,
                    size: active.size
                ),
                temporary: false
            )
        }

        let recycledFiles = try await searchPersonalFiles(
            named: file.name,
            areaID: "7",
            cookie: cookie
        )
        let recycledMatches = recycledFiles.filter { candidate in
            guard !candidate.isDirectory,
                  !candidate.pickCode.isEmpty,
                  candidate.name == file.name else {
                return false
            }
            let matchesOriginalParent = candidate.parentID == parentID
            let matchesKnownSize = file.size > 0 && candidate.size == file.size
            return matchesOriginalParent || matchesKnownSize
        }
        DiagnosticLog.write(
            "[P115_COOKIE_TRANSFER] recycle_search candidates=\(recycledFiles.count) matches=\(recycledMatches.count)"
        )
        guard let recycled = recycledMatches.first else { return nil }

        _ = try await postForm(
            url: Self.webAPIURL(path: "/rb/revert"),
            headers: requestHeaders(cookie: cookie),
            body: ["rid[0]": recycled.fileID]
        )

        for attempt in 0..<4 {
            let files = try await listPersonalFiles(parentID: parentID, cookie: cookie)
            if let restored = files.first(where: { $0.fileID == recycled.fileID && !$0.pickCode.isEmpty }) {
                DiagnosticLog.write("[P115_COOKIE_TRANSFER] restored_from_recycle_bin")
                return (
                    reference: PersonalDriveFileReference(
                        provider: .p115,
                        driveID: "115",
                        fileID: restored.fileID,
                        pickCode: restored.pickCode,
                        fileName: restored.name,
                        size: restored.size
                    ),
                    temporary: true
                )
            }
            if attempt < 3 {
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        return nil
    }

    private func searchPersonalFiles(
        named name: String,
        areaID: String,
        cookie: String
    ) async throws -> [P115ShareFile] {
        var components = URLComponents(string: Self.webAPIURL(path: "/files/search"))
        components?.queryItems = [
            URLQueryItem(name: "aid", value: areaID),
            URLQueryItem(name: "cid", value: "0"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "show_dir", value: "0"),
            URLQueryItem(name: "search_value", value: name)
        ]
        let object = try await getJSON(
            url: components?.url?.absoluteString ?? Self.webAPIURL(path: "/files/search"),
            headers: requestHeaders(cookie: cookie)
        )
        return Self.files(from: object)
    }

    private func personalFileReference(fileID: String, fallbackFile: P115ShareFile, accessToken: String) async throws -> PersonalDriveFileReference {
        var components = URLComponents(string: Self.proAPIURL(path: "/open/folder/get_info"))
        components?.queryItems = [URLQueryItem(name: "file_id", value: fileID)]
        let object = try await getJSON(
            url: components?.url?.absoluteString ?? Self.proAPIURL(path: "/open/folder/get_info"),
            headers: openAPIHeaders(accessToken: accessToken)
        )
        let data = object["data"] as? [String: Any] ?? object
        return PersonalDriveFileReference(
            provider: .p115,
            driveID: "115",
            fileID: firstNonEmpty([
                firstString(data, keys: ["file_id", "fileId", "fid", "id"]),
                fileID
            ]),
            pickCode: firstNonEmpty([
                firstString(data, keys: ["pick_code", "pickCode", "pickcode", "pc"]),
                fallbackFile.pickCode
            ]),
            fileName: firstNonEmpty([
                firstString(data, keys: ["file_name", "fileName", "name", "n"]),
                fallbackFile.name
            ]),
            size: firstNonZeroInt64([
                int64Value(data["size_byte"]),
                int64Value(data["size"]),
                fallbackFile.size
            ])
        )
    }

    private func personalPlaybackLink(
        file: P115ShareFile,
        personal: PersonalDriveFileReference,
        cookie: String,
        accessToken: String,
        temporarySavedFile: Bool = false
    ) async throws -> CloudDriveLink {
        let normalizedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = try await personalVideoPlay(personal: personal, accessToken: accessToken)
        let fallbackVariant = preview.bestTranscodeVariant
        do {
            let original = try await personalOriginalDownload(personal: personal, accessToken: accessToken)
            let originalMetadata = metadata(
                file: file,
                route: DrivePlaybackRoute.originalDownload,
                personal: personal,
                variant: original,
                canUpdateProgress: preview.canUpdateProgress,
                temporarySavedFile: temporarySavedFile
            )
            let headers = playbackHeaders(cookie: normalizedCookie)
            let fallbackMetadata = fallbackVariant.map {
                CloudDrivePlaybackMetadata.variantMetadata(
                    $0,
                    route: DrivePlaybackRoute.personalTranscode,
                    canUpdateProgress: preview.canUpdateProgress
                )
            } ?? [:]
            let plan = P115DrivePlaybackAdapter().playbackPlan(
                primaryURL: original.url,
                primaryHeaders: headers,
                primaryMetadata: originalMetadata,
                fallbackURL: fallbackVariant?.url,
                fallbackHeaders: headers,
                fallbackMetadata: fallbackMetadata
            )
            return CloudDriveLink(
                url: original.url,
                headers: headers,
                metadata: originalMetadata,
                playbackPlan: plan
            )
        } catch {
            guard let variant = fallbackVariant else { throw error }
            let variantMetadata = metadata(
                file: file,
                route: DrivePlaybackRoute.personalTranscode,
                personal: personal,
                variant: variant,
                canUpdateProgress: preview.canUpdateProgress,
                temporarySavedFile: temporarySavedFile
            )
            let headers = playbackHeaders(cookie: normalizedCookie)
            return CloudDriveLink(
                url: variant.url,
                headers: headers,
                metadata: variantMetadata,
                playbackPlan: P115DrivePlaybackAdapter().playbackPlan(
                    primaryURL: variant.url,
                    primaryHeaders: headers,
                    primaryMetadata: variantMetadata
                )
            )
        }
    }

    public func deleteTemporaryPlaybackFile(fileID: String, credential: CloudCredential) async throws {
        guard credential.provider == .p115, credential.kind == .cookie else {
            throw DriveEngineError.unsupported("115 自动清理需要 115 Cookie 凭证。")
        }
        let cookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            throw DriveEngineError.loginRequired(.p115)
        }
        _ = try await postForm(
            url: Self.webAPIURL(path: "/rb/delete"),
            headers: requestHeaders(cookie: cookie),
            body: ["fid[0]": fileID]
        )
    }

    private func personalVideoPlay(personal: PersonalDriveFileReference, accessToken: String) async throws -> CloudDrivePersonalPlayback {
        guard !personal.pickCode.isEmpty else {
            throw DriveEngineError.noDownloadURL("115 个人文件缺少 pick_code")
        }
        var components = URLComponents(string: Self.proAPIURL(path: "/open/video/play"))
        components?.queryItems = [URLQueryItem(name: "pick_code", value: personal.pickCode)]
        let object = try await getJSON(
            url: components?.url?.absoluteString ?? Self.proAPIURL(path: "/open/video/play"),
            headers: openAPIHeaders(accessToken: accessToken)
        )
        return CloudDrivePersonalPlayback(
            file: personal,
            variants: Self.videoVariants(from: object),
            canUpdateProgress: true
        )
    }

    private func personalOriginalDownload(personal: PersonalDriveFileReference, accessToken: String) async throws -> CloudDrivePlaybackVariant {
        guard !personal.pickCode.isEmpty else {
            throw DriveEngineError.noDownloadURL("115 个人文件缺少 pick_code")
        }
        let object = try await postForm(
            url: Self.proAPIURL(path: "/open/ufile/downurl"),
            headers: openAPIHeaders(accessToken: accessToken),
            body: ["pick_code": personal.pickCode]
        )
        guard let url = Self.downloadURL(from: object, fileID: personal.fileID) else {
            throw DriveEngineError.noDownloadURL(personal.fileName)
        }
        return CloudDrivePlaybackVariant(quality: "Origin", label: "原画", url: url, isOriginal: true)
    }

    private func loadShareList(share: P115ShareRequest, parentID: String, page: Int, cookie: String?) async throws -> [P115ShareFile] {
        var components = URLComponents(string: Self.webAPIURL(path: "/share/snap"))
        components?.queryItems = [
            URLQueryItem(name: "share_code", value: share.shareCode),
            URLQueryItem(name: "receive_code", value: share.receiveCode),
            URLQueryItem(name: "cid", value: parentID),
            URLQueryItem(name: "offset", value: String((page - 1) * Self.pageSize)),
            URLQueryItem(name: "limit", value: String(Self.pageSize))
        ]
        let response = try await httpClient.get(url: components?.url?.absoluteString ?? Self.webAPIURL(path: "/share/snap"), headers: requestHeaders(cookie: cookie), timeout: 30)
        let object = try Self.parseJSONResponse(data: response.data, statusCode: response.statusCode)
        return Self.files(from: object)
    }

    private func postForm(url: String, headers: [String: String], body: [String: String]) async throws -> [String: Any] {
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        let data = Data((components.percentEncodedQuery ?? "").utf8)
        var requestHeaders = headers
        requestHeaders["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
        let response = try await httpClient.post(url: url, headers: requestHeaders, body: data, timeout: 30)
        return try Self.parseJSONResponse(data: response.data, statusCode: response.statusCode)
    }

    private func getJSON(url: String, headers: [String: String]) async throws -> [String: Any] {
        let response = try await httpClient.get(url: url, headers: headers, timeout: 30)
        return try Self.parseJSONResponse(data: response.data, statusCode: response.statusCode)
    }

    private func requestHeaders(cookie: String?) -> [String: String] {
        var headers = [
            "Accept": "application/json, text/plain, */*",
            "Referer": "https://115.com/",
            "Origin": "https://115.com",
            "User-Agent": Self.userAgent
        ]
        if let cookie = cookie?.trimmingCharacters(in: .whitespacesAndNewlines), !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    private func openAPIHeaders(accessToken: String) -> [String: String] {
        var headers = [
            "Accept": "application/json, text/plain, */*",
            "User-Agent": Self.userAgent
        ]
        headers["Authorization"] = accessToken.hasPrefix("Bearer ") ? accessToken : "Bearer \(accessToken)"
        return headers
    }

    private func playbackHeaders(cookie: String) -> [String: String] {
        var headers = [
            "User-Agent": Self.userAgent,
            "Referer": "https://115.com/"
        ]
        if !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    private func metadata(
        file: P115ShareFile,
        route: String,
        personal: PersonalDriveFileReference? = nil,
        variant: CloudDrivePlaybackVariant? = nil,
        canUpdateProgress: Bool = false,
        temporarySavedFile: Bool = false
    ) -> [String: String] {
        var values = [
            "provider": DriveProvider.p115.rawValue,
            "file_id": file.fileID,
            "file_name": file.name,
            "route": route,
            DrivePlaybackMetadataKey.provider: DriveProvider.p115.rawValue,
            DrivePlaybackMetadataKey.fid: file.fileID,
            DrivePlaybackMetadataKey.fileName: file.name,
            DrivePlaybackMetadataKey.route: route,
            DrivePlaybackMetadataKey.size: String(file.size)
        ]
        if let personal {
            values[DrivePlaybackMetadataKey.driveID] = personal.driveID
            values[DrivePlaybackMetadataKey.personalFileID] = personal.fileID
            values[DrivePlaybackMetadataKey.pickCode] = personal.pickCode
        }
        if let variant {
            values[DrivePlaybackMetadataKey.quality] = variant.quality
            values[DrivePlaybackMetadataKey.qualityLabel] = variant.label
            values[DrivePlaybackMetadataKey.width] = String(variant.width)
            values[DrivePlaybackMetadataKey.height] = String(variant.height)
        }
        if canUpdateProgress {
            values[DrivePlaybackMetadataKey.canUpdateProgress] = "true"
        }
        if temporarySavedFile {
            values[DrivePlaybackMetadataKey.temporarySavedFile] = "true"
        }
        return values
    }
}

private extension P115DriveClient {
    static func webAPIURL(path: String) -> String {
        Self.webAPIBase + path
    }

    static func proAPIURL(path: String) -> String {
        Self.proAPIBase + path
    }

    static func parseJSONResponse(
        data: Data,
        statusCode: Int,
        fallbackMessage: String = "接口返回错误"
    ) throws -> [String: Any] {
        if statusCode == 401 || statusCode == 403 {
            throw DriveEngineError.loginRequired(.p115)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveEngineError.api(provider: .p115, statusCode: statusCode, code: nil, message: "响应不是 JSON")
        }
        let code = Self.errorCode(from: object)
        let message = firstString(object, keys: ["message", "msg", "error", "error_msg"])
        if Self.isAuthenticationFailure(statusCode: statusCode, message: message) {
            throw DriveEngineError.loginRequired(.p115)
        }
        let explicitlyFailed = (object["state"] as? Bool) == false || (object["success"] as? Bool) == false
        guard (200..<300).contains(statusCode) else {
            throw DriveEngineError.api(
                provider: .p115,
                statusCode: statusCode,
                code: code,
                message: message.isEmpty ? fallbackMessage : message
            )
        }
        if let code, code != 0 {
            throw DriveEngineError.api(
                provider: .p115,
                statusCode: statusCode,
                code: code,
                message: message.isEmpty ? fallbackMessage : message
            )
        }
        if explicitlyFailed {
            throw DriveEngineError.api(
                provider: .p115,
                statusCode: statusCode,
                code: code,
                message: message.isEmpty ? fallbackMessage : message
            )
        }
        return object
    }

    static func isAuthenticationFailure(statusCode: Int, message: String) -> Bool {
        if statusCode == 401 || statusCode == 403 { return true }
        let normalized = message.lowercased()
        return [
            "未登录", "请先登录", "请登录", "重新登录", "登录失效", "登录已失效",
            "cookie", "not logged", "login required", "unauthorized"
        ].contains { normalized.contains($0) }
    }

    static func files(from object: [String: Any]) -> [P115ShareFile] {
        let data = object["data"] as? [String: Any] ?? object
        let rawItems = (data["list"] as? [[String: Any]])
            ?? (data["file_list"] as? [[String: Any]])
            ?? (data["items"] as? [[String: Any]])
            ?? (object["data"] as? [[String: Any]])
            ?? []
        return rawItems.compactMap(Self.file(from:))
    }

    static func file(from item: [String: Any]) -> P115ShareFile? {
        let fileID = firstString(item, keys: ["fid", "file_id", "fileId", "id", "cid"])
        let name = firstString(item, keys: ["n", "name", "file_name", "fileName"])
        guard !fileID.isEmpty, !name.isEmpty else { return nil }
        let directoryFlag = firstString(item, keys: ["fc", "is_dir", "is_directory", "type"])
        let isDirectory = boolValue(item["is_directory"])
            || boolValue(item["is_dir"])
            || directoryFlag == "0"
            || directoryFlag.lowercased() == "folder"
            || directoryFlag.lowercased() == "directory"
        return P115ShareFile(
            fileID: fileID,
            name: name,
            parentID: firstString(item, keys: ["cid", "pid", "parent_id", "parentId"]),
            pickCode: firstString(item, keys: ["pc", "pick_code", "pickCode", "pickcode"]),
            size: int64Value(item["s"] ?? item["size"]),
            category: firstString(item, keys: ["ico", "category", "type"]),
            downloadURL: firstString(item, keys: ["url", "download_url", "downloadUrl"]),
            isDirectory: isDirectory
        )
    }

    static func savedFileID(from object: [String: Any]) -> String {
        let data = object["data"] as? [String: Any] ?? object
        let direct = firstNonEmpty([
            firstString(data, keys: ["file_id", "fileId", "fid", "id"]),
            firstString(object, keys: ["file_id", "fileId", "fid", "id"])
        ])
        if !direct.isEmpty { return direct }
        for key in ["file_id_list", "file_ids", "fid_list", "ids"] {
            if let array = data[key] as? [Any],
               let first = array.map(stringValue).first(where: { !$0.isEmpty }) {
                return first
            }
        }
        for key in ["list", "items", "file_list", "receive"] {
            if let dict = data[key] as? [String: Any] {
                let nested = firstString(dict, keys: ["file_id", "fileId", "fid", "id"])
                if !nested.isEmpty { return nested }
            }
            if let array = data[key] as? [[String: Any]] {
                for item in array {
                    let nested = firstString(item, keys: ["file_id", "fileId", "fid", "id"])
                    if !nested.isEmpty { return nested }
                }
            }
        }
        return ""
    }

    static func videoVariants(from object: [String: Any]) -> [CloudDrivePlaybackVariant] {
        let data = object["data"] as? [String: Any] ?? object
        let rawItems: [[String: Any]]
        if let array = data["video_url"] as? [[String: Any]] {
            rawItems = array
        } else if let array = data["video_urls"] as? [[String: Any]] {
            rawItems = array
        } else if let array = data["list"] as? [[String: Any]] {
            rawItems = array
        } else if let dict = data["video_url"] as? [String: Any] {
            rawItems = dict.values.compactMap { $0 as? [String: Any] }
        } else if let dict = data["video_urls"] as? [String: Any] {
            rawItems = dict.values.compactMap { $0 as? [String: Any] }
        } else {
            rawItems = []
        }
        return CloudDrivePlaybackVariant.sortedForPlayback(rawItems.compactMap { item in
            let url = firstNonEmpty([
                firstString(item, keys: ["url", "play_url", "playUrl", "m3u8", "video_url", "videoUrl"]),
                nestedURL(from: item) ?? ""
            ])
            guard !url.isEmpty else { return nil }
            let quality = firstNonEmpty([
                firstString(item, keys: ["definition", "definition_n", "quality", "q", "type"]),
                firstString(item, keys: ["height"])
            ])
            let width = intValue(item["width"] ?? item["template_width"])
            let height = intValue(item["height"] ?? item["template_height"])
            let label = firstNonEmpty([
                firstString(item, keys: ["title", "name", "label", "display_name"]),
                qualityLabel(for: quality, height: height)
            ])
            return CloudDrivePlaybackVariant(
                quality: quality.isEmpty ? label : quality,
                label: label,
                width: width,
                height: height,
                url: url
            )
        })
    }

    static func hlsVariants(from master: String, masterURL: String) -> [CloudDrivePlaybackVariant] {
        let lines = master.components(separatedBy: .newlines)
        guard let baseURL = URL(string: masterURL) else { return [] }
        var variants: [CloudDrivePlaybackVariant] = []
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { continue }
            guard let childLine = lines.dropFirst(index + 1).lazy
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let childURL = URL(string: childLine, relativeTo: baseURL)?.absoluteURL.absoluteString else {
                continue
            }
            let resolution = hlsAttribute("RESOLUTION", in: line).split(separator: "x", maxSplits: 1)
            let width = resolution.first.flatMap { Int($0) } ?? 0
            let height = resolution.count == 2 ? Int(resolution[1]) ?? 0 : 0
            let quality = hlsAttribute("NAME", in: line)
            variants.append(CloudDrivePlaybackVariant(
                quality: quality,
                label: qualityLabel(for: quality, height: height),
                width: width,
                height: height,
                url: childURL
            ))
        }
        return variants
    }

    static func hlsAttribute(_ name: String, in line: String) -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let range = line.range(
            of: "\(escapedName)=(\\\"[^\\\"]*\\\"|[^,]*)",
            options: .regularExpression
        ) else { return "" }
        let assignment = String(line[range])
        let value = assignment.dropFirst(name.count + 1)
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    static func qualityLabel(for quality: String, height: Int) -> String {
        switch quality.uppercased() {
        case "4", "FHD", "1080", "1080P": return "1080P"
        case "3", "HD", "720", "720P": return "720P"
        case "2", "SD", "540", "540P": return "540P"
        case "1", "LD", "480", "480P": return "480P"
        case "UHD", "4K", "2160", "2160P": return "4K"
        default:
            if height > 0 { return "\(height)P" }
            return quality.isEmpty ? "转码" : quality
        }
    }

    static func downloadURL(from object: [String: Any], fileID: String) -> String? {
        let data = object["data"] as? [String: Any] ?? object
        let direct = firstString(data, keys: ["url", "download_url", "downloadUrl"])
        if !direct.isEmpty { return direct }
        if let byID = data[fileID] as? [String: Any] {
            return nestedURL(from: byID)
        }
        if let first = data.values.compactMap({ $0 as? [String: Any] }).first {
            return nestedURL(from: first)
        }
        return nil
    }

    static func nestedURL(from object: [String: Any]) -> String? {
        let direct = firstString(object, keys: ["url", "download_url", "downloadUrl"])
        if !direct.isEmpty { return direct }
        if let urlObject = object["url"] as? [String: Any] {
            let nested = firstString(urlObject, keys: ["url"])
            if !nested.isEmpty { return nested }
        }
        return nil
    }

    static func parseBareShare(_ value: String) -> (code: String, receiveCode: String)? {
        guard value.range(of: #"^sw[A-Za-z0-9]+([?&].*)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let parts = value.split(separator: "?", maxSplits: 1).map(String.init)
        let receiveCode: String
        if parts.count == 2,
           let components = URLComponents(string: "115://share/\(parts[0])?\(parts[1])") {
            receiveCode = Self.value(for: ["password", "pwd", "passcode", "code", "receive_code"], in: components.queryItems ?? []) ?? ""
        } else {
            receiveCode = ""
        }
        return (parts[0], receiveCode)
    }

    static func userID(fromCookie cookie: String) -> String? {
        for field in cookie.split(separator: ";") {
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("UID") == .orderedSame else {
                continue
            }
            let rawUID = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let decodedUID = rawUID.removingPercentEncoding ?? rawUID
            let userID = String(decodedUID.split(separator: "_", maxSplits: 1).first ?? "")
            guard !userID.isEmpty, userID.allSatisfy({ $0.isNumber }) else { return nil }
            return userID
        }
        return nil
    }

    static func parse115Scheme(_ url: URL) -> String? {
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let components = url.pathComponents.filter { $0 != "/" }
        if !host.isEmpty, !["share", "s"].contains(host.lowercased()) {
            return host
        }
        if let index = components.firstIndex(where: { ["share", "s"].contains($0.lowercased()) }),
           components.indices.contains(index + 1) {
            return components[index + 1]
        }
        return components.first
    }

    static func parseWebShare(_ url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        if let index = components.firstIndex(of: "s"),
           components.indices.contains(index + 1) {
            return components[index + 1]
        }
        if let index = components.firstIndex(of: "share"),
           components.indices.contains(index + 1) {
            return components[index + 1]
        }
        return nil
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

    static func errorCode(from object: [String: Any]) -> Int? {
        if let state = object["state"] as? Bool {
            if state { return 0 }
            if let errno = object["errno"] as? Int { return errno }
            if let code = object["code"] as? Int { return code }
            return -1
        }
        if let code = object["code"] as? Int { return code }
        if let codeText = object["code"] as? String, let code = Int(codeText) { return code }
        if let errno = object["errno"] as? Int { return errno }
        if let status = object["status"] as? Int, status >= 400 { return status }
        return nil
    }

    static func diagnosticTag(for error: Error) -> String {
        guard let driveError = error as? DriveEngineError else {
            return String(describing: type(of: error))
        }
        switch driveError {
        case .api(let provider, let statusCode, let code, _):
            return "api-\(provider.rawValue)-\(statusCode)-\(code.map(String.init) ?? "none")"
        case .loginRequired(let provider):
            return "login-required-\(provider.rawValue)"
        case .noDownloadURL:
            return "no-download-url"
        case .invalidShareURL:
            return "invalid-share-url"
        case .unsupported:
            return "unsupported"
        case .noPlayableFile:
            return "no-playable-file"
        case .officialPlayURLPending:
            return "official-play-url-pending"
        }
    }

    static func isAlreadyReceived(_ error: Error) -> Bool {
        guard let driveError = error as? DriveEngineError else { return false }
        if case .api(let provider, _, let code, _) = driveError {
            return provider == .p115 && code == 4_200_045
        }
        return false
    }
}

private func firstString(_ dict: [String: Any], keys: [String]) -> String {
    for key in keys {
        if let value = dict[key] {
            let text = stringValue(value)
            if !text.isEmpty { return text }
        }
    }
    return ""
}

private func firstNonEmpty(_ values: [String]) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func firstNonZeroInt64(_ values: [Int64]) -> Int64 {
    values.first { $0 > 0 } ?? 0
}

private func stringValue(_ value: Any?) -> String {
    if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
    if let number = value as? NSNumber { return number.stringValue }
    if let int = value as? Int { return String(int) }
    return ""
}

private func boolValue(_ value: Any?) -> Bool {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let text = value as? String { return ["1", "true", "yes", "folder", "directory"].contains(text.lowercased()) }
    return false
}

private func int64Value(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber { return number.int64Value }
    if let int = value as? Int { return Int64(int) }
    if let text = value as? String, let parsed = Int64(text) { return parsed }
    return 0
}

private func intValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let int = value as? Int { return int }
    if let text = value as? String, let parsed = Int(text) { return parsed }
    return 0
}

private func normalizedAccessToken(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
