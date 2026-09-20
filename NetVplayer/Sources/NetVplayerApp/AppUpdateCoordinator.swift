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
    case failed(String)

}

private enum AppUpdateError: LocalizedError {
    case versionChanged

    var errorDescription: String? {
        switch self {
        case .versionChanged: "发布版本已变化，请重新检查更新。"
        }
    }
}

@MainActor
final class AppUpdateCoordinator: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdateCoordinator()

    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var isCheckingInformation = false
    @Published private(set) var latestAvailable: AppUpdateInfo?

    var hasNewVersion: Bool { latestAvailable != nil }

    private let lastCheckKey = "appUpdateLastCheck"
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private var controller: SPUStandardUpdaterController?
    private var checkTimer: Timer?
    private var approvedBuildVersion: String?

    private override init() {
        super.init()
    }

    func start() {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        checkTimer = Timer.scheduledTimer(timeInterval: 60 * 60, target: self,
                                          selector: #selector(checkWhenDue), userInfo: nil, repeats: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkWhenDue()
        }
    }

    @objc private func checkWhenDue() {
        if case .ready = phase { return }
        if case .downloading = phase { return }
        let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= checkInterval else { return }
        checkForUpdateInformation()
    }

    func checkForUpdateInformation() {
        guard let updater = controller?.updater, !updater.sessionInProgress else { return }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        isCheckingInformation = true
        phase = .checking
        updater.checkForUpdateInformation()
    }

    func beginUpdate() {
        guard case let .available(info) = phase,
              !info.isInformationalOnly,
              !isCheckingInformation,
              let updater = controller?.updater,
              !updater.sessionInProgress else { return }
        approvedBuildVersion = info.buildVersion
        phase = .downloading(info)
        updater.checkForUpdatesInBackground()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard let approvedBuildVersion else { return }
        guard item.versionString == approvedBuildVersion else {
            self.approvedBuildVersion = nil
            phase = .failed(AppUpdateError.versionChanged.localizedDescription)
            throw AppUpdateError.versionChanged
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let info = AppUpdateInfo(item: item)
        latestAvailable = info
        if approvedBuildVersion == nil {
            phase = .available(info)
        } else {
            phase = .downloading(info)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        approvedBuildVersion = nil
        latestAvailable = nil
        phase = .idle
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        phase = .downloading(AppUpdateInfo(item: item))
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem,
                 error: any Error) {
        approvedBuildVersion = nil
        phase = .failed("下载失败：\(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        phase = .ready(AppUpdateInfo(item: item))
        return false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        isCheckingInformation = false
        guard let error else {
            if phase == .checking { phase = .idle }
            if case .downloading = phase {
                approvedBuildVersion = nil
                phase = .failed("后台更新未完成，请重试。")
            }
            return
        }
        let nsError = error as NSError
        // SUNoUpdateError is 1001 in Sparkle's public SUErrors.h.
        guard !(nsError.domain == SUSparkleErrorDomain && nsError.code == 1001) else {
            if phase == .checking { phase = .idle }
            return
        }
        approvedBuildVersion = nil
        if case .failed = phase { return }
        phase = .failed(failureMessage(for: nsError))
    }

    private func failureMessage(for error: NSError) -> String {
        if error.domain == SUSparkleErrorDomain {
            switch error.code {
            case 1003, 1005:
                return "请先将 NetVplayer 移到“应用程序”文件夹，再检查更新。"
            case 4001, 4007, 4012:
                return "安装需要系统授权。授权未完成，当前版本保持不变，可稍后重试。"
            default:
                break
            }
        }
        return "更新未完成：\(error.localizedDescription)"
    }
}
