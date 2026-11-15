import SwiftUI
import Models
import Diagnostics

struct StartupRootView: View {
    @ObservedObject var startup: AppStartupCoordinator
    @AppStorage("appearanceThemeID") private var startupTheme = AppAppearanceDefaults.releaseDefaultThemeID.rawValue

    private var palette: AppThemePalette {
        AppThemeCatalog.palette(for: AppAppearanceThemeID(rawValue: startupTheme) ?? AppAppearanceDefaults.releaseDefaultThemeID)
    }

    var body: some View {
        Group {
            if startup.phase == .ready, let state = startup.runtime {
                if let visual = PlayerVisualRegressionConfiguration.current {
                    PlayerView(playerState: state.playerState, windowContext: PlayerWindowContext(),
                               visualRegressionConfiguration: visual).environmentObject(state)
                } else {
                    MainContainerView().environmentObject(state)
                        .safeAreaInset(edge: .top, spacing: 0) { StartupReadyBar(startup: startup, state: state) }
                }
            } else {
                StartupRecoveryView(startup: startup)
                    .environment(\.appThemePalette, palette)
            }
        }
        .modifier(LocalMediaFileDropModifier(startup: startup, palette: palette))
        .task { startup.startIfNeeded() }
        .onOpenURL { startup.enqueue([$0]) }
    }
}

/// Only lightweight diagnostics and startup state are reachable from this view.
struct StartupRecoveryView<Runtime>: View {
    @ObservedObject var startup: StartupCoordinator<Runtime>
    @Environment(\.appThemePalette) private var palette
    var quit: () -> Void = { NSApp.terminate(nil) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(palette.accent)
                Text(title).font(.system(size: 26, weight: .semibold)).accessibilityIdentifier("startup-title")
                Text(message).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                if startup.phase == .starting || startup.phase == .terminating {
                    ProgressView().controlSize(.small)
                }
                if startup.phase == .terminationFailed || startup.phase == .stopped {
                    AppRestartStatusView()
                }
                if startup.phase == .recovery {
                    VStack(alignment: .leading, spacing: 12) {
                        Button(L10n.text("暂缓恢复上次状态")) { startup.start(.deferRestoration) }
                            .controlSize(.large)
                            .buttonStyle(ThemedDialogButtonStyle(isPrimary: true)).keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("startup-defer")
                        Button(L10n.text("继续并恢复上次状态")) { startup.start(.restore) }
                            .buttonStyle(.bordered).controlSize(.large)
                            .accessibilityIdentifier("startup-restore")
                        Text(L10n.text("暂缓仅影响本次启动。配置和历史会保留，可稍后手动恢复。"))
                            .font(.callout).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !startup.pendingFiles.isEmpty || startup.rejectedFileCount > 0 {
                    Text(L10n.text("已暂存 {0} 个文件请求；进入应用后由你选择打开。", [String(startup.pendingFiles.count)]))
                        .font(.callout)
                    if startup.rejectedFileCount > 0 {
                        Text(L10n.text("最多暂存 8 个本地文件；超出或不支持的请求已忽略。"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button(L10n.text("取消待打开的文件")) { startup.discardFiles() }
                }
                Divider()
                DisclosureGroup(L10n.text("诊断与隐私")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(diagnosticsMessage).font(.callout).foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if startup.diagnostics.state == .active {
                            Button(L10n.text("关闭自动诊断共享")) { startup.changeDiagnosticsEnabled(false) }
                                .disabled(startup.phase == .terminating)
                        }
                    }.padding(.top, 8)
                }.font(.callout).disclosureGroupStyle(FullRowDisclosureGroupStyle())
                HStack {
                    Spacer()
                    Button(L10n.text("退出 NetVplayer"), action: quit)
                        .disabled(startup.phase == .terminating)
                        .accessibilityIdentifier("startup-quit")
                }
            }
            .padding(40).frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, minHeight: 500, alignment: .center)
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .themedPresentation()
        .environment(\.locale, L10n.locale)
    }

    private var title: String {
        switch startup.phase {
        case .recovery: L10n.text("恢复启动")
        case .failed, .terminationFailed: L10n.text("启动或清理未完成")
        case .terminating, .stopped: L10n.text("正在退出")
        default: L10n.text("正在启动 NetVplayer")
        }
    }

    private var message: String {
        if let failure = startup.failure { return L10n.text(failure) }
        if startup.phase == .recovery {
            return startup.diagnostics.crashedLastRun
                ? L10n.text("检测到上次运行发生崩溃。请选择本次启动方式。")
                : L10n.text("上次运行未正常结束，可能是崩溃、强制退出或断电。请选择本次启动方式。")
        }
        if startup.phase == .terminating { return L10n.text("正在等待播放、后台任务和诊断服务完成清理。") }
        return L10n.text("正在准备应用，请稍候。")
    }

    private var diagnosticsMessage: String {
        switch startup.diagnostics.state {
        case .disabled: L10n.text("自动诊断共享已关闭。启动恢复仍可使用本地状态。")
        case .unconfigured: L10n.text("当前构建未配置远端诊断。启动恢复使用本地状态。")
        case .inactive: L10n.text("诊断服务未运行；未确认任何报告已上传。")
        case .active: L10n.text("自动诊断共享沿用现有设置。诊断服务已启用，但此处无法确认报告是否已送达。")
        }
    }
}

private struct AppRestartStatusView: View {
    @ObservedObject private var updates = AppUpdateCoordinator.shared
    @ObservedObject private var relaunch = AppRelaunchCoordinator.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = updates.restartFailure {
                Text(message).foregroundStyle(.secondary)
                Button(L10n.text("重试安装并重启")) { updates.installNow() }
                    .disabled(!updates.canRetryInstallation)
            }
            if let message = relaunch.failure {
                Text(message).foregroundStyle(.secondary)
                Button(L10n.text("重试语言重启")) { try? relaunch.relaunch() }
            }
        }
    }
}

private struct StartupReadyBar: View {
    @ObservedObject var startup: AppStartupCoordinator
    @ObservedObject var state: AppState
    var body: some View {
        if state.startupRestorationDeferred || !startup.pendingFiles.isEmpty || startup.rejectedFileCount > 0 {
            HStack(spacing: 12) {
                if state.startupRestorationDeferred {
                    Text(L10n.text("本次启动已暂缓恢复上次状态")).font(.callout)
                    Button(L10n.text("现在恢复")) { state.restoreDeferredStartup() }
                }
                Spacer()
                if !startup.pendingFiles.isEmpty {
                    Menu(L10n.text("待打开的文件（{0}）", [String(startup.pendingFiles.count)])) {
                        ForEach(startup.pendingFiles, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                guard let file = startup.takeFile(url) else { return }
                                Task { await state.openStartupFile(file) }
                            }
                        }
                        Divider()
                        Button(L10n.text("取消待打开的文件")) { startup.discardFiles() }
                    }
                }
                if startup.rejectedFileCount > 0 {
                    Button(L10n.text("部分文件请求已忽略")) { startup.discardFiles() }
                        .help(L10n.text("最多暂存 8 个本地文件；超出或不支持的请求已忽略。"))
                }
            }.padding(12).background(state.appearancePalette.surface.opacity(0.85))
                .foregroundStyle(state.appearancePalette.foreground).tint(state.appearancePalette.accent)
                .preferredColorScheme(state.appearancePalette.preferredColorScheme)
        }
    }
}
