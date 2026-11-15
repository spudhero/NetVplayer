// DriveEngine/AliDriveClient.swift
// Aliyun Drive public share listing and native playback link extraction.

import CryptoKit
import Foundation
import Models
import Networking
import P256K

public struct AliShareRequest: Sendable {
    public let originalURL: String
    public let shareID: String
    public let passcode: String
    public let requestedFileName: String?
    public let requestedFID: String?
    public let collectionName: String

    public init(
        originalURL: String,
        shareID: String,
        passcode: String = "",
        requestedFileName: String? = nil,
        requestedFID: String? = nil,
        collectionName: String = ""
    ) {
        self.originalURL = originalURL
        self.shareID = shareID
        self.passcode = passcode
        self.requestedFileName = requestedFileName
        self.requestedFID = requestedFID
        self.collectionName = collectionName
    }
}

public struct AliShareFile: Sendable {
    public let fileID: String
    public let name: String
    public let parentFileID: String
    public let driveID: String
    public let type: String
    public let category: String
    public let size: Int64
    public let contentType: String
    public let downloadURL: String
    public let playURL: String
    public let isDirectory: Bool

    public var isPlayableMedia: Bool {
        DriveMediaClassifier.isPlayableMedia(
            name: name,
            formatType: firstNonEmpty([contentType, category, type]),
            isDirectory: isDirectory,
            isFile: !isDirectory
        )
    }

    public var isKnownNonVideoAsset: Bool {
        DriveMediaClassifier.isKnownNonVideoAsset(name: name)
    }
}

public struct AliPlayableFile: Sendable {
    public let file: AliShareFile
    public let shareToken: String

    public init(file: AliShareFile, shareToken: String) {
        self.file = file
        self.shareToken = shareToken
    }
}

public final class AliDriveClient: @unchecked Sendable {
    private static let apiBase = "https://api.aliyundrive.com"
    private static let downloadAPIBase = "https://api.alipan.com"
    private static let authBase = "https://auth.alipan.com"
    private static let authDomainMetadataKey = "ali_auth_domain"
    private static let currentAuthDomain = "auth.alipan.com"
    private static let pageSize = 200
    private static let maxDirectories = 32
    private static let maxPagesPerDirectory = 8
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"

    private let httpClient: DriveHTTPClient
    private let directoryAuthorization = AliDirectoryAuthorization()
    private let originalDownloadPolls: Int
    private let originalDownloadIntervalMilliseconds: Int

    public init(
        httpClient: HTTPClient = .shared,
        originalDownloadPolls: Int = 3,
        originalDownloadIntervalMilliseconds: Int = 400
    ) {
        self.httpClient = DriveHTTPClient(httpClient, provider: .ali)
        self.originalDownloadPolls = max(1, originalDownloadPolls)
        self.originalDownloadIntervalMilliseconds = max(0, originalDownloadIntervalMilliseconds)
    }

    public func shareRequest(from rawURL: String) throws -> AliShareRequest {
        if let reference = DriveFileReference.parse(rawURL), reference.provider == .ali {
            return AliShareRequest(
                originalURL: reference.shareURL,
                shareID: reference.pwdID,
                passcode: reference.passcode,
                requestedFileName: reference.fileName,
                requestedFID: reference.fid,
                collectionName: reference.collectionName
            )
        }

        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bare = Self.parseBareShareID(trimmed) {
            return AliShareRequest(originalURL: rawURL, shareID: bare.id, passcode: bare.passcode)
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
        if scheme == "ali" {
            shareID = Self.parseAliScheme(url)
        } else {
            shareID = Self.parseWebShare(url)
        }

        guard let shareID, !shareID.isEmpty else {
            throw DriveEngineError.invalidShareURL(rawURL)
        }

        return AliShareRequest(
            originalURL: rawURL,
            shareID: shareID,
            passcode: passcode,
            requestedFileName: requestedFileName,
            requestedFID: requestedFID
        )
    }

    public func collectPlayableFiles(share: AliShareRequest) async throws -> [AliPlayableFile] {
        let shareToken = try await fetchShareToken(share: share)
        var playableFiles: [AliPlayableFile] = []
        var filteredAssetNames: [String] = []
        var directoryQueue = ["root"]
        var visitedDirectories = Set<String>()

        while !directoryQueue.isEmpty && visitedDirectories.count < Self.maxDirectories {
            let parentID = directoryQueue.removeFirst()
            guard visitedDirectories.insert(parentID).inserted else { continue }

            var marker = ""
            for _ in 1...Self.maxPagesPerDirectory {
                let page = try await loadShareList(share: share, parentFileID: parentID, marker: marker, shareToken: shareToken)
                for item in page.files {
                    if item.isDirectory {
                        directoryQueue.append(item.fileID)
                    } else if item.isPlayableMedia {
                        playableFiles.append(AliPlayableFile(file: item, shareToken: shareToken))
                    } else if item.isKnownNonVideoAsset {
                        filteredAssetNames.append(item.name)
                    }
                }
                marker = page.nextMarker
                if marker.isEmpty || page.files.count < Self.pageSize {
                    break
                }
            }
        }

        if !filteredAssetNames.isEmpty {
            let sample = filteredAssetNames.prefix(6).joined(separator: ", ")
            DiagnosticLog.write("[ALI_SHARE_FILTER] filtered non-video assets count=\(filteredAssetNames.count) names=\(sample)")
        }

        return playableFiles.sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
    }

    public func selectPlayableFile(from files: [AliPlayableFile], share: AliShareRequest) -> AliPlayableFile? {
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

    public func fileReference(for playable: AliPlayableFile, share: AliShareRequest, collectionName: String = "") -> DriveFileReference {
        DriveFileReference(
            provider: .ali,
            shareURL: share.originalURL,
            pwdID: share.shareID,
            passcode: share.passcode,
            fid: playable.file.fileID,
            fidToken: Self.encodeTokenBundle(shareToken: playable.shareToken, driveID: playable.file.driveID),
            fileName: playable.file.name,
            collectionName: collectionName,
            size: playable.file.size
        )
    }

    public func link(reference: DriveFileReference, credential: CloudCredential) async throws -> CloudDriveLink {
        if DriveRequestRecovery.budget == nil {
            return try await DriveRequestRecovery.withBudget { try await self.link(reference: reference, credential: credential) }
        }
        guard reference.provider == .ali else {
            throw DriveEngineError.unsupported("AliDriveClient 只能处理阿里云盘文件引用。")
        }
        let share = try shareRequest(from: reference.encodedURL)
        let tokenBundle = Self.decodeTokenBundle(reference.fidToken)
        let auth = try await authenticate(credential)
        let file = AliShareFile(
            fileID: reference.fid,
            name: reference.fileName,
            parentFileID: "",
            driveID: tokenBundle.driveID,
            type: "file",
            category: "video",
            size: reference.size,
            contentType: "",
            downloadURL: "",
            playURL: "",
            isDirectory: false
        )
        if !reference.personalFileID.isEmpty, !reference.personalDriveID.isEmpty {
            let personal = PersonalDriveFileReference(
                provider: .ali,
                driveID: reference.personalDriveID,
                fileID: reference.personalFileID,
                pickCode: reference.pickCode,
                fileName: reference.fileName
            )
            guard !DriveRequestRecovery.background else { throw DriveMappingVerification.unconfirmed(.ali) }
            let observed = try await personalFile(driveID: personal.driveID, fileID: personal.fileID, auth: auth)
            guard observed.fileID == personal.fileID,
                  observed.driveID.isEmpty || observed.driveID == personal.driveID else {
                throw DriveMappingVerification.unconfirmed(.ali)
            }
            guard !observed.isDirectory else { throw DriveMappingVerification.changed(.ali) }
            if reference.size > 0 {
                guard observed.size > 0 else { throw DriveMappingVerification.unconfirmed(.ali) }
                guard observed.size == reference.size else { throw DriveMappingVerification.changed(.ali) }
            }
            // A known personal reference never falls through to another share copy.
            return try await personalPlaybackLink(file: file, personal: personal, auth: auth,
                updatedCredential: auth.updatedCredential)
        }
        let refreshedShareToken = try await fetchShareToken(share: share)
        return try await link(file: file, share: share, shareToken: refreshedShareToken, auth: auth)
    }

    public func link(file: AliShareFile, share: AliShareRequest, shareToken: String, credential: CloudCredential) async throws -> CloudDriveLink {
        if DriveRequestRecovery.budget == nil {
            return try await DriveRequestRecovery.withBudget { try await self.link(file: file, share: share, shareToken: shareToken, credential: credential) }
        }
        let auth = try await authenticate(credential)
        return try await link(file: file, share: share, shareToken: shareToken, auth: auth)
    }

    private func link(file: AliShareFile, share: AliShareRequest, shareToken: String, auth: AliAuthenticatedCredential) async throws -> CloudDriveLink {
        if !auth.defaultDriveID.isEmpty {
            do {
                let saved = try await saveShareFile(file: file, share: share, shareToken: shareToken, auth: auth)
                do {
                    return try await personalPlaybackLink(file: file, personal: saved.personal, auth: auth,
                        updatedCredential: auth.updatedCredential, temporarySavedFile: true, savedRecord: saved.record)
                } catch DriveEngineError.noDownloadURL {
                    throw DriveEngineError.officialPlayURLPending(file.name)
                } catch {
                    try await DriveMappingVerification.handle(error, record: saved.record, provider: .ali)
                    throw error
                }
            } catch {
                if Self.isUnauthorized(error) || DriveServiceFailure.stopsRecovery(error) { throw error }
                if case DriveEngineError.transferConfirmationPending = error { throw error }
                if case DriveEngineError.officialPlayURLPending = error { throw error }
                DiagnosticLog.write("[ALI_PLAYBACK_FALLBACK] personal route unavailable; trying share fallback reason=\(error.localizedDescription)")
            }
        }

        return try await shareFallbackLink(file: file, share: share, shareToken: shareToken, auth: auth)
    }

    private func shareFallbackLink(file: AliShareFile, share: AliShareRequest, shareToken: String, auth: AliAuthenticatedCredential) async throws -> CloudDriveLink {
        if !file.playURL.isEmpty {
            return CloudDriveLink(url: file.playURL, headers: playbackHeaders(), metadata: metadata(file: file, route: DrivePlaybackRoute.shareFallback), updatedCredential: auth.updatedCredential)
        }
        if !file.downloadURL.isEmpty {
            return CloudDriveLink(url: file.downloadURL, headers: playbackHeaders(), metadata: metadata(file: file, route: DrivePlaybackRoute.shareFallback), updatedCredential: auth.updatedCredential)
        }

        let body: [String: Any] = [
            "drive_id": file.driveID,
            "file_id": file.fileID,
            "share_id": share.shareID
        ]
        let primary = try await postJSON(
            url: Self.apiURL(path: "/v2/file/get_download_url"),
            headers: requestHeaders(accessToken: auth.accessToken, shareToken: shareToken, deviceAuthorization: auth.deviceAuthorization),
            body: body
        )
        if let url = Self.downloadURL(from: primary) {
            return CloudDriveLink(url: url, headers: playbackHeaders(), metadata: metadata(file: file, route: DrivePlaybackRoute.shareFallback), updatedCredential: auth.updatedCredential)
        }

        let fallback = try await postJSON(
            url: Self.apiURL(path: "/v2/file/get_share_link_download_url"),
            headers: requestHeaders(accessToken: auth.accessToken, shareToken: shareToken, deviceAuthorization: auth.deviceAuthorization),
            body: body
        )
        if let url = Self.downloadURL(from: fallback) {
            return CloudDriveLink(url: url, headers: playbackHeaders(), metadata: metadata(file: file, route: DrivePlaybackRoute.shareFallback), updatedCredential: auth.updatedCredential)
        }

        throw DriveEngineError.noDownloadURL(file.name)
    }

    private func saveShareFile(
        file: AliShareFile,
        share: AliShareRequest,
        shareToken: String,
        auth: AliAuthenticatedCredential
    ) async throws -> AliSavedFileResult {
        let targetDriveID = auth.defaultDriveID
        guard !targetDriveID.isEmpty else {
            throw DriveEngineError.loginRequired(.ali)
        }
        let baseIdentity = DriveSavedFileNaming.identity(provider: .ali, pwdID: share.shareID, file: file)
        try await DriveTransferCoordinator.current.checkRecovery(sourceKey: baseIdentity.cacheKey, account: targetDriveID)
        let cached = try await DriveSavedFileStore.shared.verificationRecord(for: baseIdentity, account: targetDriveID,
            allowUnscopedCandidate: true)
        let legacy = try DriveMappingVerification.legacyCandidate(cached, for: baseIdentity,
            shareID: share.shareID, sourceID: file.fileID, size: file.size)
        let folder = try await DriveMappingVerification.target(record: cached, provider: .ali, legacy: legacy) {
            try await self.ensureTransferFolder(for: share, driveID: targetDriveID, auth: auth)
        }
        let identity = baseIdentity.scoped(account: targetDriveID, target: folder.fileID)
        if let cached {
            do {
                guard cached.driveID == targetDriveID, cached.parentFID == folder.fileID else {
                    try await DriveMappingVerification.invalidate(cached, provider: .ali, legacy: legacy)
                }
                let existing = try await personalFile(driveID: targetDriveID, fileID: cached.savedFID, auth: auth)
                if !existing.driveID.isEmpty && existing.driveID != targetDriveID {
                    throw DriveMappingVerification.unconfirmed(.ali)
                }
                let verified = try await DriveMappingVerification.verified(cached, identity: identity, legacy: legacy,
                    file: .init(id: existing.fileID, parent: existing.parentFileID,
                                size: existing.size, isDirectory: existing.isDirectory))
                return AliSavedFileResult(personal: personalReference(from: verified), record: verified)
            } catch {
                try await DriveMappingVerification.handle(error, record: cached, provider: .ali, legacy: legacy)
                throw error
            }
        }
        let transfer = try await DriveTransferCoordinator.current.confirmedTransfer(cacheKey: identity.cacheKey,
            scope: .make(identity: identity, account: targetDriveID, target: folder.fileID,
                         driveID: targetDriveID, shareID: share.shareID, sourceFileID: file.fileID,
                         name: file.name, size: file.size, collectionName: share.collectionName)) { attempt in
            if await attempt.needsSubmission {
                let before = try await self.listPersonalFiles(parentFileID: folder.fileID, driveID: targetDriveID, auth: auth)
                _ = try await attempt.submit(previousIDs: Set(before.map(\.fileID))) {
                    try await self.copyShareFile(file: file, share: share, shareToken: shareToken,
                        targetDriveID: targetDriveID, targetParentFileID: folder.fileID, auth: auth)
                }
            }
            let personalFile = try await self.confirmTransferredFile(attempt: attempt, source: file,
                parentID: folder.fileID, driveID: targetDriveID, auth: auth)
            try await attempt.confirmed(personalFile.fileID)
            try await DriveTransferContext.current.check()
            let record = self.savedRecord(
                identity: identity,
                pwdID: share.shareID,
                source: file,
                personalFile: personalFile,
                parentFileID: folder.fileID,
                driveID: targetDriveID
            )
            try await DriveSavedFileStore.shared.save(record)
            _ = try? await self.renamePersonalFile(driveID: targetDriveID, fileID: personalFile.fileID,
                name: identity.targetFileName, auth: auth)
            try await DriveTransferContext.current.check()
            DiagnosticLog.write("[ALI_SAVED_CACHE] saved cacheKey=\(identity.cacheKey) fid=\(record.savedFID) file=\(record.savedFileName)")
            return DriveSavedFileTransferResult(record: record, updatedCookie: "")
        }

        return AliSavedFileResult(personal: personalReference(from: transfer.record), record: transfer.record)
    }

    private func copyShareFile(
        file: AliShareFile,
        share: AliShareRequest,
        shareToken: String,
        targetDriveID: String,
        targetParentFileID: String,
        auth: AliAuthenticatedCredential
    ) async throws -> DriveTransferSubmission {
        let copyBody: [String: Any] = [
            "share_id": share.shareID,
            "file_id": file.fileID,
            "to_drive_id": targetDriveID,
            "to_parent_file_id": targetParentFileID,
            "auto_rename": true
        ]
        let body: [String: Any] = [
            "requests": [[
                "body": copyBody,
                "headers": ["Content-Type": "application/json"],
                "id": file.fileID,
                "method": "POST",
                "url": "/file/copy"
            ]],
            "resource": "file"
        ]
        let object = try await postJSON(
            url: Self.apiURL(path: "/adrive/v4/batch"),
            headers: requestHeaders(accessToken: auth.accessToken, shareToken: shareToken, deviceAuthorization: auth.deviceAuthorization),
            body: body,
            allowsProxyFallback: false
        )
        let copyResult = try batchCopyResult(from: object)
        let data = copyResult["data"] as? [String: Any] ?? copyResult
        return DriveTransferSubmission(
            fileID: firstString(data, keys: ["file_id", "fileId", "fid"]),
            taskID: firstString(data, keys: ["async_task_id", "asyncTaskId", "task_id", "taskId"]))
    }

    private func confirmTransferredFile(
        attempt: DriveTransferAttempt, source: AliShareFile, parentID: String,
        driveID: String, auth: AliAuthenticatedCredential
    ) async throws -> AliShareFile {
        let previous = await attempt.previousIDs
        for poll in 0..<6 {
            try await DriveTransferContext.current.check()
            if let taskID = await attempt.taskID, await attempt.fileID == nil {
                do {
                    let task = try await postJSON(url: Self.apiURL(path: "/v2/async_task/get"),
                        headers: requestHeaders(accessToken: auth.accessToken, shareToken: nil, deviceAuthorization: auth.deviceAuthorization),
                        body: ["async_task_id": taskID])
                    let data = task["data"] as? [String: Any] ?? task
                    let result = data["result"] as? [String: Any] ?? data
                    try await attempt.update(fileID: firstString(result, keys: ["file_id", "fileId", "fid"]))
                } catch is CancellationError { throw CancellationError() } catch {
                    // A task read failure still permits directory reconciliation.
                }
            }
            let knownID = await attempt.fileID
            let files = try await listPersonalFiles(parentFileID: parentID, driveID: driveID, auth: auth)
            let matches = files.filter { candidate in
                guard !candidate.isDirectory, candidate.parentFileID.isEmpty || candidate.parentFileID == parentID,
                      source.size <= 0 || candidate.size == source.size else { return false }
                if let knownID { return candidate.fileID == knownID }
                return source.size > 0 && candidate.name == source.name && !previous.contains(candidate.fileID)
            }
            if matches.count == 1 { return matches[0] }
            if poll < 5 { try await Task.sleep(for: .milliseconds(350)) }
        }
        throw DriveEngineError.transferConfirmationPending()
    }

    private func ensureTransferFolder(
        for share: AliShareRequest,
        driveID: String,
        auth: AliAuthenticatedCredential
    ) async throws -> AliPersonalFolder {
        let root = try await ensurePersonalFolder(
            named: DriveTransferDirectoryPolicy.rootFolderName,
            parentFileID: "root",
            driveID: driveID,
            auth: auth
        )
        guard let childName = DriveTransferDirectoryPolicy.collectionFolderName(
            collectionName: share.collectionName,
            shareID: share.shareID
        ) else {
            return root
        }
        return try await ensurePersonalFolder(
            named: childName,
            parentFileID: root.fileID,
            driveID: driveID,
            auth: auth
        )
    }

    private func ensurePersonalFolder(
        named name: String,
        parentFileID: String,
        driveID: String,
        auth: AliAuthenticatedCredential
    ) async throws -> AliPersonalFolder {
        let files = try await listPersonalFiles(parentFileID: parentFileID, driveID: driveID, auth: auth)
        if let existing = files.first(where: { $0.isDirectory && $0.name == name }) {
            return AliPersonalFolder(fileID: existing.fileID)
        }

        if DriveMappingVerification.readOnly { throw DriveMappingVerification.changed(.ali) }

        do {
            let object = try await postJSON(
                url: Self.apiURL(path: "/v2/file/create"),
                headers: requestHeaders(accessToken: auth.accessToken, shareToken: nil, deviceAuthorization: auth.deviceAuthorization),
                body: [
                    "drive_id": driveID,
                    "parent_file_id": parentFileID,
                    "type": "folder",
                    "name": name,
                    "check_name_mode": "refuse"
                ]
            )
            let data = object["data"] as? [String: Any] ?? object
            let fileID = firstString(data, keys: ["file_id", "fileId", "fid"])
            if !fileID.isEmpty {
                return AliPersonalFolder(fileID: fileID)
            }
        } catch {
            let refreshed = try await listPersonalFiles(parentFileID: parentFileID, driveID: driveID, auth: auth)
            if let existing = refreshed.first(where: { $0.isDirectory && $0.name == name }) {
                return AliPersonalFolder(fileID: existing.fileID)
            }
            throw error
        }

        let refreshed = try await listPersonalFiles(parentFileID: parentFileID, driveID: driveID, auth: auth)
        if let existing = refreshed.first(where: { $0.isDirectory && $0.name == name }) {
            return AliPersonalFolder(fileID: existing.fileID)
        }
        throw DriveEngineError.api(provider: .ali, statusCode: 200, code: nil, message: "无法创建或定位 \(name) 转存文件夹")
    }

    private func listPersonalFiles(
        parentFileID: String,
        driveID: String,
        auth: AliAuthenticatedCredential
    ) async throws -> [AliShareFile] {
        var marker = ""
        var files: [AliShareFile] = []
        for _ in 1...Self.maxPagesPerDirectory {
            var body: [String: Any] = [
                "drive_id": driveID,
                "parent_file_id": parentFileID,
                "limit": 100,
                "order_by": "name",
                "order_direction": "ASC"
            ]
            if !marker.isEmpty { body["marker"] = marker }
            let object = try await postJSON(
                url: Self.apiURL(path: "/adrive/v3/file/list"),
                headers: requestHeaders(accessToken: auth.accessToken, shareToken: nil, deviceAuthorization: auth.deviceAuthorization),
                body: body
            )
            let data = object["data"] as? [String: Any] ?? object
            guard let rawItems = (data["items"] as? [[String: Any]])
                ?? (data["file_list"] as? [[String: Any]]) else { throw DriveMappingVerification.unconfirmed(.ali) }
            let parsed = rawItems.compactMap(Self.file(from:))
            guard parsed.count == rawItems.count else { throw DriveMappingVerification.unconfirmed(.ali) }
            files.append(contentsOf: parsed)
            marker = firstString(data, keys: ["next_marker", "nextMarker", "marker"])
            if marker.isEmpty { break }
        }
        guard marker.isEmpty else { throw DriveMappingVerification.unconfirmed(.ali) }
        return files
    }

    private func personalFile(
        driveID: String,
        fileID: String,
        auth: AliAuthenticatedCredential
    ) async throws -> AliShareFile {
        let object = try await postJSON(
            url: Self.apiURL(path: "/v2/file/get"),
            headers: requestHeaders(accessToken: auth.accessToken, shareToken: nil, deviceAuthorization: auth.deviceAuthorization),
            body: ["drive_id": driveID, "file_id": fileID]
        )
        let data = object["data"] as? [String: Any] ?? object
        if Self.isUnavailablePersonalFile(data) {
            throw DriveServiceFailure(provider: .ali, reason: .fileMissing, operation: .fileMetadata)
        }
        guard let file = Self.file(from: data) else {
            throw DriveMappingVerification.unconfirmed(.ali)
        }
        return file
    }

    private func renamePersonalFile(
        driveID: String,
        fileID: String,
        name: String,
        auth: AliAuthenticatedCredential
    ) async throws -> [String: Any] {
        try await postJSON(
            url: Self.apiURL(path: "/v2/file/update"),
            headers: requestHeaders(accessToken: auth.accessToken, shareToken: nil, deviceAuthorization: auth.deviceAuthorization),
            body: [
                "drive_id": driveID,
                "file_id": fileID,
                "name": name,
                "check_name_mode": "refuse"
            ]
        )
    }

    private func savedRecord(
        identity: DriveSavedFileIdentity,
        pwdID: String,
        source: AliShareFile,
        personalFile: AliShareFile,
        parentFileID: String,
        driveID: String
    ) -> DriveSavedFileRecord {
        DriveSavedFileRecord(
            provider: .ali,
            cacheKey: identity.cacheKey,
            pwdID: pwdID,
            shareFID: source.fileID,
            fidToken: "",
            size: personalFile.size > 0 ? personalFile.size : source.size,
            originalName: source.name,
            savedFID: personalFile.fileID,
            savedFileName: personalFile.name,
            parentFID: parentFileID,
            driveID: driveID
        )
    }

    private func personalReference(from record: DriveSavedFileRecord) -> PersonalDriveFileReference {
        PersonalDriveFileReference(
            provider: .ali,
            driveID: record.driveID ?? "",
            fileID: record.savedFID,
            fileName: record.originalName,
            size: record.size
        )
    }

    private func batchCopyResult(from object: [String: Any]) throws -> [String: Any] {
        guard let response = (object["responses"] as? [[String: Any]])?.first else {
            throw DriveEngineError.api(provider: .ali, statusCode: 200, code: nil, message: "批量转存响应结构异常")
        }
        let status = intValue(response["status"])
        let body = response["body"] as? [String: Any] ?? response
        let businessCode = firstString(body, keys: ["code", "Code"])
        if status >= 400 || (!businessCode.isEmpty && businessCode != "0") {
            let message = firstNonEmpty([
                firstString(body, keys: ["message", "msg", "display_message"]),
                "批量转存失败"
            ])
            throw DriveEngineError.api(provider: .ali, statusCode: status,
                                       code: businessCode.isEmpty ? nil : (Int(businessCode) ?? -1), message: message)
        }
        return body
    }

    private func personalPlaybackLink(
        file: AliShareFile,
        personal: PersonalDriveFileReference,
        auth: AliAuthenticatedCredential,
        updatedCredential: CloudCredential?,
        temporarySavedFile: Bool = false,
        savedRecord: DriveSavedFileRecord? = nil
    ) async throws -> CloudDriveLink {
        let originalResult: Swift.Result<CloudDrivePlaybackVariant, any Error>
        do {
            originalResult = .success(try await personalOriginalDownloadWaiting(personal: personal, auth: auth))
        } catch {
            if DriveServiceFailure.stopsRecovery(error) { throw error }
            originalResult = .failure(error)
        }

        let preview = try? await personalVideoPreview(personal: personal, auth: auth)
        let fallbackVariant = preview?.bestTranscodeVariant
        switch originalResult {
        case .success(let original):
            DiagnosticLog.write("[ALI_PLAYBACK_ROUTE] route=original-download fid=\(personal.fileID)")
            let originalMetadata = applyingSavedRecord(savedRecord, to: metadata(
                file: file,
                route: DrivePlaybackRoute.originalDownload,
                personal: personal,
                variant: original,
                canUpdateProgress: preview?.canUpdateProgress ?? false,
                temporarySavedFile: temporarySavedFile
            ))
            let headers = playbackHeaders()
            let fallbackMetadata = fallbackVariant.map {
                CloudDrivePlaybackMetadata.variantMetadata(
                    $0,
                    route: DrivePlaybackRoute.personalTranscode,
                    canUpdateProgress: preview?.canUpdateProgress ?? false
                )
            } ?? [:]
            let plan = AliDrivePlaybackAdapter().playbackPlan(
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
                updatedCredential: updatedCredential,
                playbackPlan: plan
            )
        case .failure(let originalError):
            guard let variant = fallbackVariant else { throw originalError }
            DiagnosticLog.write("[ALI_PLAYBACK_FALLBACK] original-download failed fid=\(personal.fileID) error=\(originalError)")
            DiagnosticLog.write("[ALI_PLAYBACK_ROUTE] route=personal-transcode fid=\(personal.fileID) quality=\(variant.quality)")
            let variantMetadata = applyingSavedRecord(savedRecord, to: metadata(
                file: file,
                route: DrivePlaybackRoute.personalTranscode,
                personal: personal,
                variant: variant,
                canUpdateProgress: preview?.canUpdateProgress ?? false,
                temporarySavedFile: temporarySavedFile
            ))
            let headers = playbackHeaders()
            let plan = AliDrivePlaybackAdapter().playbackPlan(
                primaryURL: variant.url,
                primaryHeaders: headers,
                primaryMetadata: variantMetadata
            )
            return CloudDriveLink(
                url: variant.url,
                headers: headers,
                metadata: variantMetadata,
                updatedCredential: updatedCredential,
                playbackPlan: plan
            )
        }
    }

    public func deleteTemporaryPlaybackFile(
        driveID: String,
        fileID: String,
        cacheKey: String = "",
        credential: CloudCredential
    ) async throws -> CloudCredential? {
        guard credential.provider == .ali else {
            throw DriveEngineError.unsupported("阿里云盘自动清理需要阿里云盘凭证。")
        }
        await DriveTransferCoordinator.current.beginCleanup(cacheKey: cacheKey)
        do {
            let auth = try await authenticate(credential)
            do {
                _ = try await postJSON(
                    url: Self.apiURL(path: "/v2/recyclebin/trash"),
                    headers: requestHeaders(accessToken: auth.accessToken, shareToken: nil, deviceAuthorization: auth.deviceAuthorization),
                    body: ["drive_id": driveID, "file_id": fileID]
                )
            } catch where Self.isMissingPersonalFileError(error) {
                DiagnosticLog.write("[ALI_SAVED_CACHE] cleanup found missing file cacheKey=\(cacheKey) fid=\(fileID)")
            }
            if !cacheKey.isEmpty {
                try? await DriveSavedFileStore.shared.remove(cacheKey: cacheKey)
            }
            await DriveTransferCoordinator.current.finishCleanup(cacheKey: cacheKey)
            return auth.updatedCredential
        } catch {
            await DriveTransferCoordinator.current.finishCleanup(cacheKey: cacheKey)
            throw error
        }
    }

    private func personalVideoPreview(personal: PersonalDriveFileReference, auth: AliAuthenticatedCredential) async throws -> CloudDrivePersonalPlayback {
        let object = try await postJSON(
            url: Self.apiURL(path: "/v2/file/get_video_preview_play_info"),
            headers: requestHeaders(accessToken: auth.accessToken, shareToken: nil, deviceAuthorization: auth.deviceAuthorization),
            body: [
                "drive_id": personal.driveID,
                "file_id": personal.fileID,
                "category": "live_transcoding",
                "template_id": "",
                "get_subtitle_info": true,
                "url_expire_sec": 14400
            ]
        )
        let variants = Self.videoPreviewVariants(from: object)
        return CloudDrivePersonalPlayback(
            file: personal,
            variants: variants,
            subtitles: Self.subtitleURLs(from: object),
            canUpdateProgress: true
        )
    }

    private func personalOriginalDownload(personal: PersonalDriveFileReference, auth: AliAuthenticatedCredential) async throws -> CloudDrivePlaybackVariant {
        let object = try await postJSON(
            url: Self.downloadAPIURL(path: "/v2/file/get_download_url"),
            headers: requestHeaders(accessToken: auth.accessToken, shareToken: nil, deviceAuthorization: auth.deviceAuthorization),
            body: [
                "drive_id": personal.driveID,
                "file_id": personal.fileID,
                "expire_sec": 14400
            ]
        )
        guard let url = Self.downloadURL(from: object) else {
            throw DriveEngineError.noDownloadURL(personal.fileName)
        }
        return CloudDrivePlaybackVariant(quality: "Origin", label: "原画", url: url, isOriginal: true)
    }

    private func personalOriginalDownloadWaiting(
        personal: PersonalDriveFileReference,
        auth: AliAuthenticatedCredential
    ) async throws -> CloudDrivePlaybackVariant {
        var lastError: Error = DriveEngineError.noDownloadURL(personal.fileName)
        for attempt in 0..<originalDownloadPolls {
            do {
                return try await personalOriginalDownload(personal: personal, auth: auth)
            } catch let error as DriveEngineError {
                guard case .noDownloadURL = error else { throw error }
                lastError = error
            } catch {
                throw error
            }

            if attempt + 1 < originalDownloadPolls, originalDownloadIntervalMilliseconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(originalDownloadIntervalMilliseconds) * 1_000_000)
            }
        }
        throw lastError
    }

    public func authenticate(_ credential: CloudCredential) async throws -> AliAuthenticatedCredential {
        let refreshToken = firstNonEmpty([
            credential.refreshToken ?? "",
            credential.metadata["refresh_token"] ?? "",
            credential.kind == .refreshToken ? credential.secret : ""
        ])
        let defaultDriveID = firstNonEmpty([
            credential.metadata["default_drive_id"] ?? "",
            credential.metadata["defaultDriveId"] ?? "",
            credential.metadata["drive_id"] ?? ""
        ])
        let userID = firstNonEmpty([
            credential.metadata["user_id"] ?? "",
            credential.metadata["userId"] ?? ""
        ])
        let accessToken = firstNonEmpty([
            credential.accessToken ?? "",
            credential.metadata["access_token"] ?? "",
            credential.metadata["open_token"] ?? "",
            credential.kind == .accessToken ? credential.secret : ""
        ])
        let usesCurrentAuthDomain = credential.metadata[Self.authDomainMetadataKey] == Self.currentAuthDomain
        if !accessToken.isEmpty, refreshToken.isEmpty || usesCurrentAuthDomain {
            do {
                return try await authenticatedCredential(
                    accessToken: accessToken,
                    defaultDriveID: defaultDriveID,
                    userID: userID,
                    updatedCredential: nil
                )
            } catch {
                guard !refreshToken.isEmpty, Self.isUnauthorized(error) else { throw error }
                DiagnosticLog.write("[ALI_AUTH_REFRESH] saved access token rejected; refreshing credential")
            }
        } else if !accessToken.isEmpty {
            DiagnosticLog.write("[ALI_AUTH_REFRESH] migrating saved credential to auth.alipan.com")
        }

        guard !refreshToken.isEmpty else {
            throw DriveEngineError.loginRequired(.ali)
        }

        return try await refreshCredential(
            credential,
            refreshToken: refreshToken,
            defaultDriveID: defaultDriveID,
            userID: userID
        )
    }

    public func forceRefreshCredential(_ credential: CloudCredential) async throws -> CloudCredential {
        guard credential.provider == .ali,
              let refreshToken = credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            throw DriveEngineError.loginRequired(.ali)
        }
        let auth = try await refreshCredential(
            credential,
            refreshToken: refreshToken,
            defaultDriveID: credential.metadata["default_drive_id"] ?? "",
            userID: credential.metadata["user_id"] ?? ""
        )
        return auth.updatedCredential ?? credential
    }

    private func refreshCredential(
        _ credential: CloudCredential,
        refreshToken: String,
        defaultDriveID: String,
        userID: String
    ) async throws -> AliAuthenticatedCredential {
        if let budget = DriveRequestRecovery.budget, !(await budget.claimCredentialRefresh(.ali)) {
            throw DriveServiceFailure(provider: .ali, reason: .credentialExpired, operation: .authentication)
        }
        let object = try await postJSON(
            url: Self.authURL(path: "/v2/account/token"),
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: ["grant_type": "refresh_token", "refresh_token": refreshToken]
        )
        let newAccessToken = firstString(object, keys: ["access_token", "accessToken"])
        guard !newAccessToken.isEmpty else {
            throw DriveEngineError.loginRequired(.ali)
        }
        var updated = credential
        let newRefreshToken = firstNonEmpty([
            firstString(object, keys: ["refresh_token", "refreshToken"]),
            refreshToken
        ])
        let newDefaultDriveID = firstNonEmpty([
            firstString(object, keys: ["default_drive_id", "defaultDriveId"]),
            defaultDriveID
        ])
        let newUserID = firstNonEmpty([
            firstString(object, keys: ["user_id", "userId"]),
            userID,
            Self.jwtUserID(accessToken: newAccessToken)
        ])
        updated.secret = newAccessToken
        updated.accessToken = newAccessToken
        updated.refreshToken = newRefreshToken
        updated.metadata["access_token"] = newAccessToken
        updated.metadata["refresh_token"] = newRefreshToken
        updated.metadata[Self.authDomainMetadataKey] = Self.currentAuthDomain
        if !newDefaultDriveID.isEmpty {
            updated.metadata["default_drive_id"] = newDefaultDriveID
        }
        if !newUserID.isEmpty {
            updated.metadata["user_id"] = newUserID
        }
        updated.updatedAt = Date()
        return try await authenticatedCredential(
            accessToken: newAccessToken,
            defaultDriveID: newDefaultDriveID,
            userID: newUserID,
            updatedCredential: updated
        )
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        DriveServiceFailure.isCredentialExpired(error, provider: .ali)
    }

    private static func isMissingPersonalFileError(_ error: Error) -> Bool {
        DriveEngineError.invalidatesSavedRecord(error, provider: .ali)
    }

    private func authenticatedCredential(
        accessToken: String,
        defaultDriveID: String,
        userID: String,
        updatedCredential: CloudCredential?
    ) async throws -> AliAuthenticatedCredential {
        let resolvedUserID = firstNonEmpty([userID, Self.jwtUserID(accessToken: accessToken)])
        guard !resolvedUserID.isEmpty else {
            throw DriveEngineError.api(provider: .ali, statusCode: 401, code: nil, message: "登录 Token 缺少用户标识，请重新扫码")
        }
        let deviceAuthorization: AliDeviceAuthorization
        do {
            deviceAuthorization = try AliDeviceAuthorization(userID: resolvedUserID)
        } catch {
            throw DriveEngineError.api(provider: .ali, statusCode: 401, code: nil, message: "无法生成设备会话签名，请重新扫码")
        }
        _ = try await postJSON(
            url: Self.apiURL(path: "/users/v1/users/device/create_session"),
            headers: requestHeaders(accessToken: accessToken, shareToken: nil, deviceAuthorization: deviceAuthorization),
            body: [
                "deviceName": "NetVplayer macOS",
                "modelName": "Mac",
                "pubKey": deviceAuthorization.publicKey
            ]
        )
        return AliAuthenticatedCredential(
            accessToken: accessToken,
            defaultDriveID: defaultDriveID,
            updatedCredential: updatedCredential,
            deviceAuthorization: deviceAuthorization
        )
    }

    private func fetchShareToken(share: AliShareRequest) async throws -> String {
        let object = try await postJSON(
            url: Self.apiURL(path: "/v2/share_link/get_share_token"),
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: ["share_id": share.shareID, "share_pwd": share.passcode]
        )
        let token = firstNonEmpty([
            firstString(object, keys: ["share_token", "shareToken"]),
            firstString(object["data"] as? [String: Any] ?? [:], keys: ["share_token", "shareToken"])
        ])
        guard !token.isEmpty else {
            throw DriveEngineError.api(provider: .ali, statusCode: 200, code: nil, message: "分享 token 响应结构异常")
        }
        return token
    }

    private func loadShareList(share: AliShareRequest, parentFileID: String, marker: String, shareToken: String) async throws -> AliShareListPage {
        var body: [String: Any] = [
            "share_id": share.shareID,
            "parent_file_id": parentFileID,
            "limit": Self.pageSize,
            "order_by": "name",
            "order_direction": "ASC"
        ]
        if !marker.isEmpty { body["marker"] = marker }
        let object = try await postJSON(
            url: Self.apiURL(path: "/adrive/v3/file/list"),
            headers: requestHeaders(accessToken: nil, shareToken: shareToken),
            body: body
        )
        let data = object["data"] as? [String: Any] ?? object
        let rawItems = (data["items"] as? [[String: Any]])
            ?? (data["file_list"] as? [[String: Any]])
            ?? (object["items"] as? [[String: Any]])
            ?? []
        let items = rawItems.compactMap(Self.file(from:))
        let nextMarker = firstString(data, keys: ["next_marker", "nextMarker", "marker"])
        return AliShareListPage(files: items, nextMarker: nextMarker)
    }

    private func postJSON(url: String, headers: [String: String], body: [String: Any], allowsProxyFallback: Bool = true) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        var requestHeaders = headers
        requestHeaders["Content-Type"] = "application/json; charset=utf-8"
        requestHeaders["User-Agent"] = Self.userAgent
        let response = try await httpClient.post(url: url, headers: requestHeaders, body: data, timeout: try DriveTransferContext.readTimeout(30), allowsProxyFallback: allowsProxyFallback && DriveTransferContext.confirmationDeadline == nil, redactsURLInLogs: true)
        if response.statusCode == 204 { return [:] }
        if !(200..<300).contains(response.statusCode) {
            let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let apiMessage = object.map {
                firstString($0, keys: ["message", "msg", "error", "display_message"])
            } ?? ""
            let message: String
            switch response.statusCode {
            case 401:
                message = apiMessage.isEmpty ? "登录凭据失效" : apiMessage
            case 410:
                message = apiMessage.isEmpty ? "播放线路或签名已失效" : apiMessage
            default:
                message = apiMessage.isEmpty ? "接口返回错误" : apiMessage
            }
            throw DriveEngineError.api(
                provider: .ali,
                statusCode: response.statusCode,
                code: object.flatMap(Self.errorCode(from:)),
                message: message
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            let endpoint = URL(string: url)?.path ?? "接口"
            throw DriveEngineError.api(provider: .ali, statusCode: response.statusCode, code: nil, message: "\(endpoint) 响应不是 JSON")
        }
        let stringCode = (object["code"] as? String) ?? (object["Code"] as? String) ?? ""
        if let code = Self.errorCode(from: object) ?? (stringCode.isEmpty || stringCode == "0" ? nil : -1), code != 0 {
            let message = firstString(object, keys: ["message", "msg", "error"])
            throw DriveEngineError.api(provider: .ali, statusCode: response.statusCode, code: code, message: message.isEmpty ? "接口返回错误" : message)
        }
        return object
    }

    private func requestHeaders(
        accessToken: String?,
        shareToken: String?,
        deviceAuthorization: AliDeviceAuthorization? = nil
    ) -> [String: String] {
        var headers = [
            "Accept": "application/json, text/plain, */*",
            "Referer": "https://alipan.com/",
            "Origin": "https://www.alipan.com",
            "User-Agent": Self.userAgent,
            "X-Canary": "client=Android,app=adrive,version=v4.1.0"
        ]
        if let accessToken, !accessToken.isEmpty {
            headers["Authorization"] = accessToken.hasPrefix("Bearer ") ? accessToken : "Bearer \(accessToken)"
        }
        if let shareToken, !shareToken.isEmpty {
            headers["x-share-token"] = shareToken
        }
        if let deviceAuthorization {
            headers["x-device-id"] = deviceAuthorization.deviceID
            headers["x-signature"] = deviceAuthorization.signature
            headers["x-request-id"] = UUID().uuidString.lowercased()
        }
        return headers
    }

    private func playbackHeaders() -> [String: String] {
        [
            "User-Agent": Self.userAgent,
            "Referer": "https://www.aliyundrive.com/"
        ]
    }

    private func metadata(
        file: AliShareFile,
        route: String,
        personal: PersonalDriveFileReference? = nil,
        variant: CloudDrivePlaybackVariant? = nil,
        canUpdateProgress: Bool = false,
        temporarySavedFile: Bool = false
    ) -> [String: String] {
        var values = [
            "provider": DriveProvider.ali.rawValue,
            "file_id": file.fileID,
            "file_name": file.name,
            "route": route,
            DrivePlaybackMetadataKey.provider: DriveProvider.ali.rawValue,
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

    private func applyingSavedRecord(
        _ record: DriveSavedFileRecord?,
        to metadata: [String: String]
    ) -> [String: String] {
        guard let record else { return metadata }
        var values = metadata
        values[DrivePlaybackMetadataKey.cacheKey] = record.cacheKey
        values[DrivePlaybackMetadataKey.driveID] = record.driveID
        values[DrivePlaybackMetadataKey.personalFileID] = record.savedFID
        values[DrivePlaybackMetadataKey.size] = String(record.size)
        values[DrivePlaybackMetadataKey.temporarySavedFile] = "true"
        return values
    }
}

public struct AliAuthenticatedCredential: Sendable {
    public let accessToken: String
    public let defaultDriveID: String
    public let updatedCredential: CloudCredential?
    let deviceAuthorization: AliDeviceAuthorization
}

struct AliDeviceAuthorization: Sendable {
    let deviceID: String
    let signature: String
    let publicKey: String

    init(userID: String) throws {
        let userData = Data(userID.utf8)
        var uuidBytes = Array(Insecure.SHA1.hash(data: userData).prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        let uuidHex = uuidBytes.map { String(format: "%02x", $0) }
        deviceID = [
            uuidHex[0...3].joined(),
            uuidHex[4...5].joined(),
            uuidHex[6...7].joined(),
            uuidHex[8...9].joined(),
            uuidHex[10...15].joined()
        ].joined(separator: "-")

        let privateKey = try P256K.Signing.PrivateKey(
            dataRepresentation: Data(SHA256.hash(data: userData)),
            format: .uncompressed
        )
        publicKey = Self.hex(privateKey.publicKey.dataRepresentation)
        let payload = ":\(deviceID):\(userID):0"
        signature = Self.hex(privateKey.signature(for: Data(payload.utf8)).compactRepresentation) + "01"
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private struct AliShareListPage: Sendable {
    let files: [AliShareFile]
    let nextMarker: String
}

private struct AliPersonalFolder: Sendable {
    let fileID: String
}

private struct AliSavedFileResult: Sendable {
    let personal: PersonalDriveFileReference
    let record: DriveSavedFileRecord
}

private extension AliDriveClient {
    static func jwtUserID(accessToken: String) -> String {
        let rawToken = accessToken.hasPrefix("Bearer ") ? String(accessToken.dropFirst(7)) : accessToken
        let segments = rawToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return "" }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return firstString(object, keys: ["user_id", "userId", "sub"])
    }

    static func apiURL(path: String) -> String {
        Self.apiBase + path
    }

    static func downloadAPIURL(path: String) -> String {
        Self.downloadAPIBase + path
    }

    static func authURL(path: String) -> String {
        Self.authBase + path
    }

    static func file(from item: [String: Any]) -> AliShareFile? {
        guard !isUnavailablePersonalFile(item) else { return nil }
        let fileID = firstString(item, keys: ["file_id", "fileId", "id", "fid"])
        let name = firstString(item, keys: ["name", "file_name", "fileName"])
        guard !fileID.isEmpty, !name.isEmpty else { return nil }
        let type = firstString(item, keys: ["type", "file_type", "fileType"])
        let isDirectory = type.lowercased() == "folder"
            || type.lowercased() == "directory"
            || boolValue(item["is_directory"])
            || boolValue(item["isDir"])
        return AliShareFile(
            fileID: fileID,
            name: name,
            parentFileID: firstString(item, keys: ["parent_file_id", "parentFileId", "parent_id"]),
            driveID: firstString(item, keys: ["drive_id", "driveId"]),
            type: type,
            category: firstString(item, keys: ["category"]),
            size: int64Value(item["size"]),
            contentType: firstString(item, keys: ["content_type", "contentType", "mime_type", "mimeType"]),
            downloadURL: firstString(item, keys: ["download_url", "downloadUrl", "url"]),
            playURL: firstString(item, keys: ["play_url", "playUrl"]),
            isDirectory: isDirectory
        )
    }

    static func isUnavailablePersonalFile(_ item: [String: Any]) -> Bool {
        if boolValue(item["trashed"]) { return true }
        if !firstString(item, keys: ["trashed_at", "trashedAt"]).isEmpty { return true }
        let status = firstString(item, keys: ["status", "phase"]).lowercased()
        return status == "trashed" || status == "deleted"
    }

    static func downloadURL(from object: [String: Any]) -> String? {
        let data = object["data"] as? [String: Any] ?? object
        let direct = firstString(data, keys: [
            "url", "download_url", "downloadUrl", "cdn_url", "cdnUrl", "play_url", "playUrl"
        ])
        if !direct.isEmpty { return direct }
        if let videoPreview = data["video_preview_play_info"] as? [String: Any],
           let liveList = videoPreview["live_transcoding_task_list"] as? [[String: Any]] {
            return liveList.compactMap { item -> String? in
                let url = firstString(item, keys: ["url"])
                return url.isEmpty ? nil : url
            }.first
        }
        return nil
    }

    static func videoPreviewVariants(from object: [String: Any]) -> [CloudDrivePlaybackVariant] {
        let data = object["data"] as? [String: Any] ?? object
        let preview = data["video_preview_play_info"] as? [String: Any] ?? data
        let taskList = (preview["live_transcoding_task_list"] as? [[String: Any]])
            ?? (preview["task_list"] as? [[String: Any]])
            ?? []
        return CloudDrivePlaybackVariant.sortedForPlayback(taskList.compactMap { item in
            let url = firstString(item, keys: ["url", "play_url", "playUrl"])
            guard !url.isEmpty else { return nil }
            let templateID = firstString(item, keys: ["template_id", "templateId", "quality"])
            let width = intValue(item["template_width"] ?? item["width"])
            let height = intValue(item["template_height"] ?? item["height"])
            let label = firstNonEmpty([
                firstString(item, keys: ["label", "title", "name"]),
                qualityLabel(for: templateID, height: height)
            ])
            return CloudDrivePlaybackVariant(
                quality: templateID.isEmpty ? label : templateID,
                label: label,
                width: width,
                height: height,
                url: url
            )
        })
    }

    static func subtitleURLs(from object: [String: Any]) -> [String] {
        let data = object["data"] as? [String: Any] ?? object
        let preview = data["video_preview_play_info"] as? [String: Any] ?? data
        let subtitleList = (preview["live_transcoding_subtitle_task_list"] as? [[String: Any]])
            ?? (preview["subtitle_task_list"] as? [[String: Any]])
            ?? []
        return subtitleList.compactMap { item in
            let status = firstString(item, keys: ["status"])
            guard status.isEmpty || status == "finished" else { return nil }
            let url = firstString(item, keys: ["url"])
            return url.isEmpty ? nil : url
        }
    }

    static func qualityLabel(for templateID: String, height: Int) -> String {
        switch templateID {
        case "LD": return "低清 480p"
        case "SD": return "标清 540p"
        case "HD": return "高清 720p"
        case "FHD": return "全高清 1080p"
        case "QHD": return "超高清 2K"
        case "4K", "UHD": return "4K"
        default:
            if height > 0 { return "\(height)p" }
            return templateID.isEmpty ? "转码" : templateID
        }
    }

    static func parseBareShareID(_ value: String) -> (id: String, passcode: String)? {
        guard value.range(of: #"^[A-Za-z0-9_-]{6,}([?&].*)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let parts = value.split(separator: "?", maxSplits: 1).map(String.init)
        let passcode: String
        if parts.count == 2,
           let components = URLComponents(string: "ali://share/\(parts[0])?\(parts[1])") {
            passcode = Self.value(for: ["pwd", "password", "passcode", "code"], in: components.queryItems ?? []) ?? ""
        } else {
            passcode = ""
        }
        return (parts[0], passcode)
    }

    static func parseAliScheme(_ url: URL) -> String? {
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

    static func encodeTokenBundle(shareToken: String, driveID: String) -> String {
        let object = ["share_token": shareToken, "drive_id": driveID]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return shareToken
        }
        return data.base64EncodedString()
    }

    static func decodeTokenBundle(_ value: String) -> (shareToken: String, driveID: String) {
        guard let data = Data(base64Encoded: value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return (value, "")
        }
        return (object["share_token"] ?? value, object["drive_id"] ?? "")
    }

    static func errorCode(from object: [String: Any]) -> Int? {
        if let code = object["code"] as? Int { return code }
        if let codeText = object["code"] as? String, let code = Int(codeText) { return code }
        if let status = object["status"] as? Int, status >= 400 { return status }
        return nil
    }
}

private func firstString(_ dict: [String: Any], keys: [String]) -> String {
    for key in keys {
        if let value = dict[key] {
            if let text = value as? String, !text.isEmpty { return text }
            if let number = value as? NSNumber { return number.stringValue }
        }
    }
    return ""
}

private func firstNonEmpty(_ values: [String]) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func boolValue(_ value: Any?) -> Bool {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let text = value as? String { return ["1", "true", "yes", "folder"].contains(text.lowercased()) }
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

extension AliDriveClient {
    func recoverTransfer(_ record: DriveTransferTask, attempt: DriveTransferAttempt, credential: CloudCredential) async throws -> DriveRecoveredFile? {
        let scope = record.scope
        let auth = try await authenticate(credential)
        guard auth.defaultDriveID == scope.driveID else { throw DriveTaskRecoveryError.scopeChanged }
        let target = try await ensureTransferFolder(for: .init(originalURL: "", shareID: scope.shareID,
            collectionName: scope.collectionName), driveID: auth.defaultDriveID, auth: auth)
        guard target.fileID == scope.target else { throw DriveTaskRecoveryError.scopeChanged }
        if !record.submitted || record.phase == .failed { return nil }
        let source = AliShareFile(fileID: scope.sourceFileID, name: scope.name, parentFileID: "",
            driveID: "", type: "file", category: "", size: scope.size, contentType: "", downloadURL: "", playURL: "", isDirectory: false)
        let file = try await confirmTransferredFile(attempt: attempt, source: source, parentID: scope.target,
            driveID: auth.defaultDriveID, auth: auth)
        return .init(id: file.fileID, name: file.name, parent: scope.target, size: file.size)
    }
}

extension AliDriveClient {
    func personalDirectory(folderID: String, driveID: String, cursor: String?, credential: CloudCredential) async throws -> CloudDirectoryPage {
        try await withDirectoryAuthorization(credential) { auth in
        let resolvedDrive = driveID.isEmpty ? auth.defaultDriveID : driveID
        guard !resolvedDrive.isEmpty else {
            throw DriveEngineError.unsupported("阿里云盘授权缺少空间标识，请重新登录")
        }
        var body: [String: Any] = ["drive_id": resolvedDrive, "parent_file_id": folderID,
            "limit": 100, "order_by": "name", "order_direction": "ASC"]
        if let cursor, !cursor.isEmpty { body["marker"] = cursor }
        let object = try await postJSON(url: Self.apiURL(path: "/adrive/v3/file/list"),
            headers: requestHeaders(accessToken: auth.accessToken, shareToken: nil, deviceAuthorization: auth.deviceAuthorization), body: body)
        let data = object["data"] as? [String: Any] ?? object
        guard let raw = (data["items"] as? [[String: Any]]) ?? (data["file_list"] as? [[String: Any]]) else {
            throw DriveMappingVerification.unconfirmed(.ali)
        }
        let files = raw.compactMap(Self.file(from:))
        guard files.count == raw.count else { throw DriveMappingVerification.unconfirmed(.ali) }
        let marker = firstString(data, keys: ["next_marker", "nextMarker"])
        guard marker.isEmpty || (marker != cursor && !files.isEmpty) else { throw DriveMappingVerification.unconfirmed(.ali) }
        return CloudDirectoryPage(entries: files.map {
            .init(id: $0.fileID, name: $0.name, parentID: folderID, driveID: resolvedDrive,
                  size: $0.size, isDirectory: $0.isDirectory)
        }, nextCursor: marker.isEmpty ? nil : marker, driveID: resolvedDrive, updatedCredential: auth.updatedCredential)
        }
    }

    func personalDirectoryDownload(entry: CloudDirectoryEntry, credential: CloudCredential) async throws -> CloudDriveLink {
        try await withDirectoryAuthorization(credential) { auth in
        let driveID = entry.driveID.isEmpty ? auth.defaultDriveID : entry.driveID
        guard !driveID.isEmpty else { throw DriveEngineError.noDownloadURL(entry.name) }
        let file = PersonalDriveFileReference(provider: .ali, driveID: driveID, fileID: entry.id, fileName: entry.name, size: entry.size)
        let original = try await personalOriginalDownloadWaiting(personal: file, auth: auth)
        return CloudDriveLink(url: original.url, headers: playbackHeaders(),
            metadata: CloudDirectoryPaging.metadata(entry, provider: .ali), updatedCredential: auth.updatedCredential)
        }
    }

    private func withDirectoryAuthorization<T: Sendable>(
        _ credential: CloudCredential, operation: @Sendable (AliAuthenticatedCredential) async throws -> T
    ) async throws -> T {
        let auth = try await directoryAuthorization.resolve(credential) { try await self.authenticate(credential) }
        do { return try await operation(auth) }
        catch {
            guard Self.isUnauthorized(error) else { throw error }
            await directoryAuthorization.invalidate()
            try Task.checkCancellation()
            let current = auth.updatedCredential ?? credential
            let fresh = try await directoryAuthorization.resolve(current) { try await self.authenticate(current) }
            return try await operation(fresh)
        }
    }
}

/// Reuse a device session while scanning, and merge simultaneous refreshes for the same credential.
/// Account changes have different keys; a completed older refresh cannot replace a newer session.
private actor AliDirectoryAuthorization {
    private var cached: (keys: Set<String>, value: AliAuthenticatedCredential, expires: Date)?
    private var inFlight: [String: (id: UUID, task: Task<AliAuthenticatedCredential, Error>)] = [:]
    private var activeKey: String?
    private var generation = 0

    func resolve(_ credential: CloudCredential,
                 operation: @escaping @Sendable () async throws -> AliAuthenticatedCredential) async throws -> AliAuthenticatedCredential {
        try Task.checkCancellation()
        let key = try Self.key(credential)
        if let cached, cached.keys.contains(key), cached.expires > Date() { return cached.value }
        if activeKey != key { activeKey = key; generation += 1 }
        let request: (id: UUID, task: Task<AliAuthenticatedCredential, Error>)
        if let existing = inFlight[key] { request = existing }
        else { request = (UUID(), Task { try await operation() }); inFlight[key] = request }
        let currentGeneration = generation
        defer { if inFlight[key]?.id == request.id { inFlight.removeValue(forKey: key) } }
        let value = try await request.task.value
        try Task.checkCancellation()
        if currentGeneration == generation {
            var keys: Set<String> = [key]
            if let updated = value.updatedCredential { keys.insert(try Self.key(updated)) }
            cached = (keys, value, Date().addingTimeInterval(300))
        }
        return value
    }

    func invalidate() { generation += 1; cached = nil }

    private static func key(_ credential: CloudCredential) throws -> String {
        var stable = credential
        stable.updatedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(stable)).map { String(format: "%02x", $0) }.joined()
    }
}
