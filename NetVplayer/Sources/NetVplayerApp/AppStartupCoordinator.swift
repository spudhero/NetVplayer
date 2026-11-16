import Foundation
import Diagnostics
import Models

typealias AppStartupCoordinator = StartupCoordinator<AppState>

@MainActor
enum AppStartup {
    static let shared: AppStartupCoordinator = makeApplicationCoordinator()

    private static func makeApplicationCoordinator() -> AppStartupCoordinator {
        let visual = PlayerVisualRegressionConfiguration.current
        let androidAudit = DevelopmentAndroidAppAudit.current
        let isolatedAudit = androidAudit != nil
        #if DEBUG
        if let probe = StartupRecoveryProbe.current { return probe.makeCoordinator() }
        #endif
        return AppStartupCoordinator(
            store: visual == nil && !isolatedAudit ? StartupSessionStore(url: StartupSessionStore.defaultURL) : nil,
            startDiagnostics: {
                guard visual == nil && !isolatedAudit else { return .init(state: .inactive, crashedLastRun: false) }
                DiagnosticLog.beginSession()
                SentryDiagnostics.shared.start()
                return SentryDiagnostics.shared.startupSnapshot
            },
            setDiagnosticsEnabled: {
                SentryDiagnostics.shared.setEnabled($0)
                return SentryDiagnostics.shared.startupSnapshot
            },
            stopDiagnostics: { if visual == nil { SentryDiagnostics.shared.stop() } },
            factory: { choice in
                if let androidAudit { return DevelopmentAndroidAppAudit.makeState(androidAudit) }
                let restore = choice == .restore && visual == nil && !isolatedAudit
                if visual != nil { print("Visual capture: initializing application state") }
                let state = AppState(loadDefaultConfig: restore, startProxyServer: visual == nil,
                                     startProviderRuntime: restore,
                                     deferStartupRestoration: choice == .deferRestoration)
                visual?.apply(to: state)
                return state
            },
            validate: { state in
                if state.startupServiceFailed { throw StartupServiceFailure.unavailable }
            },
            cleanup: { try await $0.prepareForApplicationTermination() },
            onReady: { state in
                if let androidAudit {
                    DevelopmentAndroidAppAudit.start(androidAudit, state: state)
                    return
                }
                if let visual {
                    print("Visual capture: application state ready")
                    PlayerVisualRegressionCaptureController.schedule(configuration: visual)
                } else {
                    FeedbackReportFileStore.cleanupExpiredReports()
                    AppUpdateCoordinator.shared.start()
                }
            },
            onTerminationRequested: { $0.beginApplicationTermination() }
        )
    }
}

private enum StartupServiceFailure: Error { case unavailable }
