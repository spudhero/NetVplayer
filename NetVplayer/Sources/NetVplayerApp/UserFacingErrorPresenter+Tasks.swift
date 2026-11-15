import Foundation
import Models
import DriveEngine

enum TaskResultAction: Equatable {
    case continueTask, retryLater, login, settings, reviewTasks
    var title: String {
        switch self {
        case .continueTask: L10n.text("继续核对")
        case .retryLater: L10n.text("稍后重试")
        case .login: L10n.text("重新登录")
        case .settings: L10n.text("查看设置")
        case .reviewTasks: L10n.text("查看任务记录")
        }
    }
}

extension UserFacingErrorPresenter {
    static func taskAction(for reason: TaskResultReason?) -> TaskResultAction {
        switch reason {
        case .credentialExpired: .login
        case .permissionDenied, .quotaExceeded, .configurationChanged, .capacity: .settings
        case .temporaryNetwork, .rateLimited, .signedURLExpired, .playbackAddressPending: .retryLater
        default: .continueTask
        }
    }
    static func playbackTaskAction(for error: Error) -> TaskResultAction? {
        guard !TaskDiagnosticIssue.isCancellation(error) else { return nil }
        if case DriveTaskRecoveryError.cancelled = error { return nil }
        if error is DriveTaskRecoveryError { return .reviewTasks }
        guard error is DriveServiceFailure || error is DriveEngineError || error is AppFailure else { return .retryLater }
        let issue = DriveTaskDiagnosticIssue.issue(error)
        if [.outcomeUnknown, .interrupted].contains(issue.reason) { return .reviewTasks }
        if issue.reason == .fileMissing { return .settings }
        return taskAction(for: issue.reason) == .continueTask ? .retryLater : taskAction(for: issue.reason)
    }
    static func taskState(_ event: TaskDiagnosticEvent, isActive: Bool = false) -> String {
        switch event.state {
        case .processing: isActive ? L10n.text("处理中") : L10n.text("等待确认")
        case .waitingConfirmation: L10n.text("等待确认")
        case .needsLogin: L10n.text("需要登录")
        case .needsAttention: L10n.text("需要处理")
        case .cancelled: L10n.text("已取消")
        case .completed: L10n.text("已完成")
        }
    }
    static func taskStage(_ stage: TaskResultStage) -> String {
        switch stage {
        case .queued: L10n.text("准备任务")
        case .submitting: L10n.text("提交转存")
        case .confirming: L10n.text("核对转存结果")
        case .fileConfirmed: L10n.text("文件已确认")
        case .preparingPlayback: L10n.text("准备播放地址")
        case .scanning: L10n.text("扫描媒体库")
        case .finished: L10n.text("任务收尾")
        }
    }
    static func taskMessage(_ event: TaskDiagnosticEvent, isActive: Bool = false) -> String {
        if event.state == .cancelled { return L10n.text("任务已取消，不会恢复执行。") }
        if event.state == .processing {
            return isActive ? L10n.text("任务正在处理中。") : L10n.text("上次操作未完成，请手动继续。")
        }
        if let reason = event.reason?.failureReason {
            return presentation(for: AppFailure(category: .source, reason: reason), context: .playback).combinedMessage
        }
        switch event.reason {
        case .configurationChanged: return message(for: DriveTaskRecoveryError.scopeChanged, context: .playback)
        case .storageUnavailable: return message(for: DriveTaskRecoveryError.storageUnavailable, context: .playback)
        case .capacity: return L10n.text("任务已达到本次上限。请先处理待核对任务，或缩小扫描目录。")
        case .expired: return message(for: MediaScanRecoveryError.expired, context: .storage(operation: L10n.text("扫描媒体库")))
        case .partial: return L10n.text("部分目录读取失败，旧索引已保留")
        case .playbackAddressPending: return L10n.text("文件已确认。请重新打开原文件准备播放。")
        case .reopenOriginal: return L10n.text("上次尚未提交转存。已核对目标，请重新打开原文件再试。")
        case .unavailable: return L10n.text("任务暂时未能完成，请检查服务设置后手动重试。")
        default: return event.state == .completed ? L10n.text("任务已完成。") : L10n.text("上次操作未完成，请手动继续。")
        }
    }
}
