import SwiftUI
import UniformTypeIdentifiers
import Models

struct AndroidRuntimeComponentSettingsView: View {
    @ObservedObject var appState: AppState
    var loadOnAppear = true
    @State private var selectingDirectory = false
    @Environment(\.appThemePalette) private var palette

    private var installIsPrimary: Bool {
        !appState.providerExecutionRequiresRestart && !appState.androidRuntimeComponentRequiresRestart
            && (!appState.hasBundledAndroidProviderRuntime || appState.androidRuntimeComponentError != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Android 原版运行组件"))
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if let version = appState.androidRuntimeComponentVersion {
                Text(L10n.text("磁盘组件版本：{0}", [version]))
                    .font(.caption).monospacedDigit()
            } else if appState.hasBundledAndroidProviderRuntime {
                Text(L10n.text("运行组件随应用提供"))
                    .font(.caption).foregroundStyle(palette.muted)
            } else {
                Text(L10n.text("尚未安装原版运行组件"))
                    .font(.caption).foregroundStyle(palette.muted)
            }

            if appState.androidRuntimeComponentBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(appState.androidRuntimeComponentProgress ?? L10n.text("正在验证并准备组件…")).font(.caption)
                }
                .accessibilityElement(children: .combine)
            }
            if let error = appState.androidRuntimeComponentError {
                SettingsInlineMessage(message: error)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { automaticButton; installButton; rollbackButton }
                VStack(alignment: .leading, spacing: 8) { automaticButton; installButton; rollbackButton }
            }
            .disabled(appState.androidRuntimeComponentBusy)

            Text(L10n.text("仅在 Android 原版模式下自动下载完整运行环境。也可手动提前安装；安装不会切换当前实现。手动安装或回滚后需重启。"))
                .font(.caption).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $selectingDirectory, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let directory):
                Task {
                    let access = directory.startAccessingSecurityScopedResource()
                    defer { if access { directory.stopAccessingSecurityScopedResource() } }
                    await appState.installAndroidRuntimeComponent(directory: directory)
                }
            case .failure(let error): appState.androidRuntimeComponentError = error.localizedDescription
            }
        }
        .task { if loadOnAppear { await appState.refreshAndroidRuntimeComponent() } }
    }

    @ViewBuilder private var automaticButton: some View {
        if !appState.hasBundledAndroidProviderRuntime {
            Button(L10n.text("自动下载并安装")) {
                Task { await appState.prepareAndroidRuntimeAutomatically() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("settings.android-component.automatic")
        }
    }

    @ViewBuilder private var installButton: some View {
        if installIsPrimary && appState.hasBundledAndroidProviderRuntime {
            installAction.buttonStyle(.borderedProminent)
        } else {
            installAction.buttonStyle(.bordered)
        }
    }

    private var installAction: some View {
        Button(appState.hasBundledAndroidProviderRuntime
            ? L10n.text("安装或更新…") : L10n.text("选择组件文件夹…")) {
            selectingDirectory = true
        }
        .accessibilityIdentifier("settings.android-component.install")
    }

    @ViewBuilder private var rollbackButton: some View {
        if let previous = appState.androidRuntimePreviousVersion {
            Button(L10n.text("回滚到 {0}", [previous])) {
                Task { await appState.rollbackAndroidRuntimeComponent() }
            }
            .buttonStyle(.borderless)
            .help(L10n.text("切回上一组件版本，重启后生效。"))
            .accessibilityIdentifier("settings.android-component.rollback")
        }
    }
}
