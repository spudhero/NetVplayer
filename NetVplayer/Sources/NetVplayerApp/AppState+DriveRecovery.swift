import Foundation
import DriveEngine
import Models
import Storage
import MediaLibraryEngine

extension AppState {
    /// Stable across launches; use saved configuration content, never the
    /// process-local load/playback generation as a durable identity.
    var driveRecoveryConfigurationIdentity: String {
        let url = userPreferences.currentVodConfigUrl
        let json = storageManager.loadConfigs().first { $0.type == .vod && $0.url == url }?.json ?? ""
        let canonical: String
        if let bytes = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: bytes),
           let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            canonical = String(decoding: sorted, as: UTF8.self)
        } else { canonical = json }
        return DriveTransferContext.digest(["transfer-policy-v1", url, canonical, userPreferences.currentVodSiteKey])
    }

    func refreshDriveTaskSummaries() {
        do {
            driveTaskSummaries = try driveTaskStore.records().sorted { $0.updatedAt > $1.updatedAt }
            driveTaskStorageFailed = false
        } catch { driveTaskStorageFailed = true }
        refreshTaskDiagnostics()
    }

    func refreshTaskDiagnostics() {
        do { recentTaskDiagnostics = try taskDiagnosticStore.records(); taskDiagnosticsUnavailable = false }
        catch { taskDiagnosticsUnavailable = true }
        Task { [weak self] in
            guard let self else { return }
            let drive = await driveTransferCoordinator.activeDiagnosticIDs()
            let scans = await MediaLibraryScanner.shared.activeDiagnosticIDs()
            let matches = await MetadataMatcher.shared.activeDiagnosticIDs()
            activeTaskDiagnosticIDs = drive.union(scans).union(matches)
        }
    }

    func exportTaskDiagnostics(to url: URL) throws {
        // Produce the complete safe projection before opening the output file.
        let data = try taskDiagnosticStore.exportData(activeTaskIDs: activeTaskDiagnosticIDs)
        try data.write(to: url, options: .atomic)
    }

    func finishTaskSheetDismissal() {
        if let provider = pendingTaskLogin {
            pendingTaskLogin = nil; requestCloudAuthFromSettings(provider)
        } else if pendingTaskSettings {
            pendingTaskSettings = false; openTaskSettings()
        }
    }

    func performPlaybackTaskAction(_ action: TaskResultAction) {
        switch action {
        case .login: openCloudAuthFromPlaybackError()
        case .reviewTasks, .continueTask: refreshDriveTaskSummaries(); showsDriveTaskRecovery = true
        case .settings: openTaskSettings()
        case .retryLater: retryTaskPlayback()
        }
    }

    private func recordDriveTaskIssue(_ id: UUID, error: Error) {
        guard let task = try? driveTaskStore.records().first(where: { $0.id == id }), task.canContinue else { return }
        let issue = DriveTaskDiagnosticIssue.issue(error)
        var summary = TaskDiagnosticRecord.transfer(task)
        summary.events = [.init(stage: summary.latest.stage,
            state: issue.reason == .credentialExpired ? .needsLogin : task.protectsUncertainWrite ? .waitingConfirmation : .needsAttention,
            issue: issue, retryCount: summary.latest.retryCount)]
        try? taskDiagnosticStore.record(summary)
    }

    func continueDriveTask(_ task: DriveTransferTask) {
        guard task.canContinue, !driveRecoveryBusy.contains(task.id) else { return }
        guard let credential = recoveryCredential(task.scope.provider) else {
            driveTaskMessage = L10n.text("原网盘账号不可用。请先在设置中登录原账号，再手动继续。")
            recordDriveTaskIssue(task.id, error: DriveEngineError.loginRequired(task.scope.provider))
            refreshTaskDiagnostics()
            return
        }
        let identity = driveRecoveryConfigurationIdentity
        let credentialRevision = userPreferences.searchCredentialRevision
        let baseContext = driveTransferContext()
        let context = DriveTransferContext(revision: baseContext.revision, configurationIdentity: identity) { [weak self] in
            await MainActor.run {
                guard let self else { return false }
                return self.driveRecoveryConfigurationIdentity == identity
                    && self.userPreferences.searchCredentialRevision == credentialRevision
            }
        }
        driveRecoveryBusy.insert(task.id)
        driveTaskMessage = nil
        driveRecoveryOperations[task.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                driveRecoveryBusy.remove(task.id); driveRecoveryOperations[task.id] = nil
                refreshDriveTaskSummaries()
            }
            do {
                let result = try await DriveTransferContext.$current.withValue(context) {
                    try await driveTransferCoordinator.continueRecovery(task.id, credential: credential,
                        configurationIdentity: identity)
                }
                driveTaskMessage = result == .fileConfirmed
                    ? L10n.text("文件已确认。请重新打开原文件准备播放。")
                    : L10n.text("上次尚未提交转存。已核对目标，请重新打开原文件再试。")
            } catch is CancellationError {
                driveTaskMessage = L10n.text("任务已取消，不会恢复执行。")
            } catch {
                if !TaskDiagnosticIssue.isCancellation(error) { recordDriveTaskIssue(task.id, error: error) }
                driveTaskMessage = UserFacingErrorPresenter.message(for: error, context: .playback)
            }
        }
    }

    func cancelDriveTask(_ task: DriveTransferTask) {
        do {
            // Commit cancellation first, so an uncooperative late read cannot
            // publish a result or revive this row after relaunch.
            try driveTaskStore.cancel(task.id)
            driveRecoveryOperations[task.id]?.cancel()
            Task { try? await driveTransferCoordinator.cancelRecovery(task.id) }
            driveTaskMessage = L10n.text("任务已取消。已提交的转存可能仍在服务端完成，记录会保留。")
        } catch {
            driveTaskStorageFailed = true
            driveTaskMessage = UserFacingErrorPresenter.message(for: DriveTaskRecoveryError.storageUnavailable, context: .playback)
        }
        refreshDriveTaskSummaries()
    }

    private func recoveryCredential(_ provider: DriveProvider) -> CloudCredential? {
        let cookie: String
        switch provider {
        case .quark: cookie = userPreferences.quarkCookie
        case .uc: cookie = userPreferences.ucCookie
        case .baidu: cookie = userPreferences.baiduCookie
        case .p115: cookie = userPreferences.p115Cookie
        case .ali:
            let access = userPreferences.aliAccessToken, refresh = userPreferences.aliRefreshToken
            guard !access.isEmpty || !refresh.isEmpty else { return nil }
            return .init(provider: .ali, kind: refresh.isEmpty ? .accessToken : .refreshToken,
                secret: access.isEmpty ? refresh : access, refreshToken: refresh, accessToken: access,
                metadata: ["default_drive_id": userPreferences.aliDefaultDriveID,
                           "ali_auth_domain": userPreferences.aliAuthDomain, "user_id": userPreferences.aliUserID])
        default: return nil
        }
        return cookie.isEmpty ? nil : .cookie(provider: provider, value: cookie)
    }
}
