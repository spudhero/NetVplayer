import SwiftUI
import Models

/// A saved preference changes the next session; the active backend remains a fact
/// reported by AppState, independent of the selection shown in the picker.
struct ProviderExecutionSettingsView: View {
    @ObservedObject var appState: AppState
    var loadComponentOnAppear = true
    @State private var restartError: String?
    @Environment(\.appThemePalette) private var palette

    private var requiresRestart: Bool {
        appState.providerExecutionRequiresRestart || appState.androidRuntimeComponentRequiresRestart
    }

    var body: some View {
        GroupBox(label: SettingsPanelLabel(
            title: L10n.text("来源解析方式"),
            subtitle: L10n.text("选择内容来源的解析方式，更改后重启应用。"),
            systemImage: "arrow.triangle.branch"
        )) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    summaryRow(L10n.text("本次启动"), value: preferenceTitle(appState.activeProviderExecutionPreference))
                    if let site = appState.activeSite,
                       let backend = appState.providerExecutionBackends[site.key] {
                        summaryRow(L10n.text("当前来源"), value: site.name)
                        summaryRow(L10n.text("实际解析方式"), value: backendTitle(backend))
                    } else {
                        Text(L10n.text("选择来源后，可在这里查看实际使用的解析方式。"))
                            .font(.caption).foregroundStyle(palette.muted)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("下次启动优先使用"))
                        .font(.system(size: 12, weight: .semibold))
                    Picker(L10n.text("下次启动优先使用"), selection: $appState.preferredProviderExecution) {
                        ForEach(ProviderExecutionPreference.allCases, id: \.self) { preference in
                            Text(preferenceTitle(preference)).tag(preference)
                                .disabled(preference == .androidPreferred && !appState.hasBundledAndroidProviderRuntime)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings.provider-execution.preference")
                    Text(preferenceDescription)
                        .font(.caption).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !appState.hasBundledAndroidProviderRuntime {
                        Text(L10n.text("安装下方的运行组件后，才能选择 Android 原版优先。"))
                            .font(.caption).foregroundStyle(palette.color(for: .warning))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()
                AndroidRuntimeComponentSettingsView(appState: appState, loadOnAppear: loadComponentOnAppear)

                if requiresRestart {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L10n.text("更改已保存，重启后应用"), systemImage: "arrow.clockwise.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.color(for: .warning))
                        Text(L10n.text("本次运行仍使用启动时的设置。重启后请重新选择影片；历史与收藏会保留。"))
                            .font(.caption).foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.text("立即重启并应用")) {
                            do { try AppRelaunchCoordinator.shared.relaunch() }
                            catch { restartError = error.localizedDescription }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.androidRuntimeComponentBusy)
                        .accessibilityIdentifier("settings.provider-execution.restart")
                        if let restartError { SettingsInlineMessage(message: restartError) }
                    }
                }

                DisclosureGroup(L10n.text("兼容性说明")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Android 原版按配置运行原始 JAR；缺少组件或运行能力时会显示错误，不会在失败后自动改用 Mac 适配。"))
                        if let site = appState.activeSite,
                           let backend = appState.providerExecutionBackends[site.key] {
                            if appState.activeProviderExecutionPreference == .macPreferred && backend == .androidOriginal {
                                Text(L10n.text("此入口没有精确匹配的 Mac 适配，使用 Android 原版。"))
                            } else if appState.activeProviderExecutionPreference == .androidPreferred
                                        && (backend == .macNative || backend == .macExtension) {
                                Text(L10n.text("此来源使用独立的本地或媒体服务接口。"))
                            }
                        }
                    }
                    .font(.caption).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).foregroundStyle(palette.muted)
                Spacer(minLength: 8)
                Text(value).fontWeight(.medium)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(palette.muted)
                Text(value).fontWeight(.medium)
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func preferenceTitle(_ preference: ProviderExecutionPreference) -> String {
        switch preference {
        case .automatic: L10n.text("自动选择（推荐）")
        case .macPreferred: L10n.text("Mac 适配优先")
        case .androidPreferred: L10n.text("Android 原版优先（实验）")
        }
    }

    private var preferenceDescription: String {
        switch appState.preferredProviderExecution {
        case .automatic: L10n.text("根据来源选择兼容的解析方式。")
        case .macPreferred: L10n.text("优先使用 Mac 适配；没有匹配适配时使用 Android 原版。")
        case .androidPreferred: L10n.text("使用来源提供的原版解析组件，兼容性与速度因来源而异。")
        }
    }

    private func backendTitle(_ backend: ProviderExecutionBackend) -> String {
        switch backend {
        case .macNative: L10n.text("Mac 原生适配")
        case .macExtension: L10n.text("Mac 扩展适配")
        case .androidOriginal: L10n.text("Android 原版（模拟执行）")
        case .androidUnavailable: L10n.text("Android 原版不可用")
        case .standard: L10n.text("标准内容接口")
        }
    }
}
