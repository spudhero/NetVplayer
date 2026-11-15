import Models
import AppKit
import Combine
import Foundation
import Sparkle

struct AppUpdateInfo: Equatable {
    let buildVersion: String
    let displayVersion: String
    let releaseURL: URL?
    let isInformationalOnly: Bool

    init(item: SUAppcastItem) {
        buildVersion = item.versionString
        displayVersion = item.displayVersionString
        isInformationalOnly = item.isInformationOnlyUpdate
        releaseURL = item.infoURL ?? URL(
            string: "https://github.com/spudhero/NetVplayer/releases/tag/\(item.displayVersionString)"
        )
    }
}

enum AppUpdatePhase: Equatable {
    case idle
    case checking
    case available(AppUpdateInfo)
    case downloading(AppUpdateInfo)
    case ready(AppUpdateInfo)
    case preparing(AppUpdateInfo)
    case failed(String)

}

enum AppUpdateError: LocalizedError {
    case versionChanged, restartBusy, unavailable, cleanupIncomplete

    var errorDescription: String? {
        switch self {
        case .versionChanged: L10n.text("发布版本已变化，请重新检查更新。")
        case .restartBusy: L10n.text("更新或语言重启正在进行，请完成或取消当前操作后重试。")
        case .unavailable: L10n.text("应用尚未就绪或正在退出，请稍后检查更新。")
        case .cleanupIncomplete: L10n.text("清理尚未完成，更新仍在等待。请重试更新或退出应用。")
        }
    }
}

@MainActor
// Sparkle 2.10's user-driver header lacks NS_SWIFT_UI_ACTOR; its standard UI calls
// delegates on the main thread. Keep that runtime check at the Swift boundary.
final class AppUpdateCoordinator: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = AppUpdateCoordinator(showFailure: { NetVplayerWindowCoordinator.shared.showMainWindow() })

    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var isCheckingInformation = false
    @Published private(set) var latestAvailable: AppUpdateInfo?
    @Published private(set) var hasNewVersion = false
    @Published private(set) var restartFailure: String?
    var canRetryInstallation: Bool { pendingInstall != nil && restartFailure != nil && installTask == nil }
    var isPreparingInstallation: Bool { installTask != nil }

    private let lastCheckKey = "appUpdateLastCheck"
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private let defaults: UserDefaults
    private let gate: AppRestartGate
    private let context: @MainActor () -> AppUpdatePresentationContext
    private let cleanup: @MainActor () async -> Bool
    private let now: () -> Date
    private let showFailure: () -> Void
    private var startedAt: Date?
    private var updaterStarted = false
    private(set) var controller: SPUStandardUpdaterController?
    private var checkTimer: Timer?
    private var approvedBuildVersion: String?
    private var updateLease: AppRestartGate.Lease?
    private var installerPending = false
    private var scheduledPresentation = false
    private var installTask: Task<Void, Never>?
    private var pendingInstall: (() -> Void)?
    private var pendingInstallInfo: AppUpdateInfo?
    private var pendingInstallID: UUID?
    private var acceptedQuitHandler = false
    private var acceptedRelaunchHandler = false

    init(gate: AppRestartGate = .shared, defaults: UserDefaults = .standard,
         context: @escaping @MainActor () -> AppUpdatePresentationContext = { .current() },
         cleanup: @escaping @MainActor () async -> Bool = { await AppStartup.shared.terminate().value },
         now: @escaping () -> Date = Date.init,
         showFailure: @escaping () -> Void = {}) {
        self.gate = gate
        self.defaults = defaults
        self.context = context
        self.cleanup = cleanup
        self.now = now
        self.showFailure = showFailure
        super.init()
    }

    func start(pollAutomatically: Bool = true) {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        startedAt = now()
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        // The app owns daily information probes. Never allow persisted Sparkle preferences
        // to introduce a second automatic download scheduler or a launch permission dialog.
        controller.updater.automaticallyChecksForUpdates = false
        do { try controller.updater.start(); updaterStarted = true }
        catch { phase = .failed(failureMessage(for: error as NSError)); return }
        if pollAutomatically {
            checkTimer = Timer.scheduledTimer(timeInterval: 5, target: self,
                selector: #selector(checkWhenDue), userInfo: nil, repeats: true)
            checkTimer?.tolerance = 1
        }
    }

    private var automaticPresentationAllowed: Bool {
        guard let startedAt, now().timeIntervalSince(startedAt) >= 30 else { return false }
        return context().permitsAutomaticReminder
    }

    @objc func checkWhenDue() {
        refreshReminder()
        guard automaticPresentationAllowed, gate.lease == nil,
              !installerPending, !isCheckingInformation else { return }
        let lastCheck = defaults.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard now().timeIntervalSince(lastCheck) >= checkInterval else { return }
        checkForUpdateInformation()
    }

    func refreshReminder() {
        let visible = latestAvailable != nil && automaticPresentationAllowed
        if hasNewVersion != visible { hasNewVersion = visible }
    }

    func checkForUpdateInformation() {
        guard updaterStarted, context().startupReady, gate.lease == nil,
              let updater = controller?.updater, !updater.sessionInProgress else { return }
        defaults.set(now(), forKey: lastCheckKey)
        isCheckingInformation = true
        phase = .checking
        updater.checkForUpdateInformation()
    }

    /// User intent bypasses presentation timing, including a deferred Sparkle alert.
    /// checkForUpdates also focuses an existing alert; sessionInProgress must not block that.
    func checkForUpdates() {
        guard updaterStarted, context().startupReady, let updater = controller?.updater else { return }
        if installerPending, pendingInstall != nil {
            // A controlled background install has no Sparkle alert to focus.
            // The in-app update status offers the explicit restart action.
            NetVplayerWindowCoordinator.shared.showMainWindow()
            return
        }
        if updater.sessionInProgress {
            if scheduledPresentation { updater.checkForUpdates() }
            return
        }
        guard reserveUpdate() else { return }
        approvedBuildVersion = nil
        isCheckingInformation = false
        phase = .checking
        updater.checkForUpdates()
    }

    func beginUpdate() {
        guard updaterStarted, context().startupReady, case let .available(info) = phase,
              !info.isInformationalOnly, !isCheckingInformation,
              let updater = controller?.updater else { return }
        if scheduledPresentation { updater.checkForUpdates(); return }
        guard !updater.sessionInProgress, reserveUpdate() else { return }
        approvedBuildVersion = info.buildVersion
        phase = .downloading(info)
        updater.checkForUpdatesInBackground()
    }

    private func reserveUpdate() -> Bool {
        if let updateLease { return gate.owns(updateLease) }
        guard let lease = gate.acquire(.update) else {
            phase = .failed(AppUpdateError.restartBusy.localizedDescription)
            return false
        }
        updateLease = lease
        return true
    }

    private func isCurrent(_ updater: SPUUpdater) -> Bool { controller?.updater === updater }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard isCurrent(updater), context().startupReady else { throw AppUpdateError.unavailable }
        if updateCheck == .updateInformation {
            guard gate.lease == nil else { throw AppUpdateError.restartBusy }
        } else {
            // Internal follow-up cycles after an explicitly requested download keep the lease.
            guard let updateLease, gate.owns(updateLease) else { throw AppUpdateError.restartBusy }
        }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard isCurrent(updater) else { throw AppUpdateError.unavailable }
        if let approvedBuildVersion, item.versionString != approvedBuildVersion {
            throw AppUpdateError.versionChanged
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard isCurrent(updater), isCheckingInformation || updateLease != nil else { return }
        let info = AppUpdateInfo(item: item)
        latestAvailable = info
        phase = approvedBuildVersion == nil ? .available(info) : .downloading(info)
        refreshReminder()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        guard isCurrent(updater) else { return }
        latestAvailable = nil
        hasNewVersion = false
        phase = .idle
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        guard isCurrent(updater), updateLease != nil else { return }
        phase = .downloading(AppUpdateInfo(item: item))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard isCurrent(updater), let updateLease, gate.owns(updateLease) else { return false }
        guard !acceptedQuitHandler else { return true }
        acceptedQuitHandler = true
        installerPending = true
        phase = .ready(AppUpdateInfo(item: item))
        setPendingInstall(info: AppUpdateInfo(item: item), handler: immediateInstallHandler)
        // Stall the cycle. Sparkle still owns installation on ordinary quit; no second helper.
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard isCurrent(updater), let updateLease else { return false }
        return gate.owns(updateLease)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isCurrent(updater), let updateLease, gate.owns(updateLease) else { return true }
        guard !acceptedRelaunchHandler else { return true }
        acceptedRelaunchHandler = true
        // This delegate is not guaranteed on every SDK path. applicationShouldTerminate
        // independently joins the same StartupCoordinator cleanup task.
        installerPending = true
        setPendingInstall(info: AppUpdateInfo(item: item), handler: installHandler)
        installNow()
        return true
    }

    private func setPendingInstall(info: AppUpdateInfo, handler: @escaping () -> Void) {
        pendingInstallID = UUID()
        pendingInstallInfo = info
        pendingInstall = handler
    }

    func installNow() {
        if pendingInstall == nil, installerPending {
            // A dismissed Sparkle "installing" alert retains its own install action.
            // Bring that UI back; only the SDK can supply its continuation.
            checkForUpdates()
            return
        }
        guard installTask == nil, let lease = updateLease, gate.owns(lease),
              let handler = pendingInstall, let id = pendingInstallID,
              let info = pendingInstallInfo else { return }
        phase = .preparing(info)
        restartFailure = nil
        installTask = Task { @MainActor in
            let completed = await self.gate.prepare(lease, cleanup: self.cleanup)
            guard self.gate.owns(lease), self.pendingInstallID == id else { return }
            self.installTask = nil
            guard completed else {
                self.restartFailure = AppUpdateError.cleanupIncomplete.localizedDescription
                self.phase = .failed(AppUpdateError.cleanupIncomplete.localizedDescription)
                self.showFailure()
                return
            }
            // Consume this particular SDK continuation before calling it; it can synchronously
            // supply the next (postpone-relaunch) continuation for the same update lease.
            self.pendingInstall = nil
            self.pendingInstallID = nil
            handler()
        }
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        guard isCurrent(updater) else { return }
        if choice == .skip {
            latestAvailable = nil
            hasNewVersion = false
            phase = .idle
            // Unlike "later", skip at installing stage cancels the staged installer.
            // Invalidate our continuations now, but retain the lease until SDK completion.
            installerPending = false
            pendingInstall = nil
            pendingInstallID = nil
        }
        if state.stage == .installing && choice == .dismiss {
            // Dismissing this stage does NOT cancel install-on-quit (Sparkle 2.10 contract).
            installerPending = true
            _ = reserveUpdate()
            phase = .ready(AppUpdateInfo(item: item))
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        guard isCurrent(updater) else { return }
        isCheckingInformation = false
        scheduledPresentation = false
        if let error {
            let nsError = error as NSError
            // Authorize-later retains the staged installer. Cancellation is a distinct outcome.
            let authorizeLater = nsError.domain == SUSparkleErrorDomain && nsError.code == 4008
            if !authorizeLater { finishSession() }
            if nsError.domain == SUSparkleErrorDomain && nsError.code == 1001 { phase = .idle }
            else { phase = .failed(failureMessage(for: nsError)) }
        } else if !installerPending {
            finishSession()
            if phase == .checking { phase = .idle }
            if case .downloading = phase {
                phase = latestAvailable.map(AppUpdatePhase.available) ?? .idle
            }
        }
        refreshReminder()
    }

    private func finishSession() {
        if let updateLease { gate.release(updateLease) }
        updateLease = nil
        approvedBuildVersion = nil
        installerPending = false
        pendingInstall = nil
        pendingInstallID = nil
        pendingInstallInfo = nil
        acceptedQuitHandler = false
        acceptedRelaunchHandler = false
        installTask = nil
        restartFailure = nil
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                               andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // Even safe automatic reminders use our badge, never a focus-stealing alert.
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        scheduledPresentation = true // Manual checks may bring this same SDK session into focus.
        latestAvailable = AppUpdateInfo(item: update)
        if !handleShowingUpdate { phase = .available(AppUpdateInfo(item: update)) }
        refreshReminder()
    }

    private func failureMessage(for error: NSError) -> String {
        if error.domain == SUSparkleErrorDomain {
            switch error.code {
            case 1003, 1005:
                return L10n.text("请先将 NetVplayer 移到“应用程序”文件夹，再检查更新。")
            case 4001, 4007, 4008, 4012:
                return L10n.text("安装需要系统授权。授权未完成，当前版本保持不变，可稍后重试。")
            default: break
            }
        }
        return UserFacingErrorPresenter.message(for: error, context: .update)
    }
}
