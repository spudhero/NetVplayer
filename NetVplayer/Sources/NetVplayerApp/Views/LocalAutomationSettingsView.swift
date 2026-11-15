import AppKit
import SwiftUI
import Models

struct LocalAutomationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: LocalAutomationController
    @Environment(\.appThemePalette) private var palette
    @State private var addressCopied = false
    var body: some View {
        GroupBox(label: SettingsPanelLabel(title: L10n.text("本地只读接口"),
            subtitle: L10n.text("允许本机工具读取脱敏任务、选定服务的已有连接结果和应用状态。"), systemImage: "terminal")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L10n.text("启用本次运行的只读接口"), isOn: Binding(get: { controller.enabled }, set: { value in
                    Task { await controller.setEnabled(value) }
                }))
                .toggleStyle(.switch).disabled(controller.busy).accessibilityIdentifier("automation-enable")
                HStack(spacing: 6) {
                    if controller.busy { ProgressView().controlSize(.mini) }
                    Label(L10n.text(controller.enabled ? "本次运行已开启" : "默认关闭"),
                          systemImage: controller.enabled ? "checkmark.circle" : "lock")
                }.font(.caption.weight(.medium))
                    .foregroundStyle(controller.enabled ? palette.color(for: .success) : palette.muted)
                Text(L10n.text("默认关闭，退出应用后失效。关闭会撤销令牌，不影响播放。"))
                    .font(.caption).foregroundStyle(palette.muted)
                if controller.failed {
                    Text(L10n.text("本地接口未能启动，请关闭后重试。"))
                        .foregroundStyle(palette.color(for: .danger))
                }
                if let url = controller.baseURL {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(L10n.text("本机地址")).font(.caption).foregroundStyle(palette.muted)
                                Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                    .accessibilityIdentifier("automation-address")
                            }
                            Spacer()
                            Button { copyAddress(url) } label: {
                                Label(L10n.text(addressCopied ? "已复制" : "复制地址"),
                                      systemImage: addressCopied ? "checkmark" : "doc.on.doc")
                            }
                        }
                        Button(L10n.text(controller.copied && !addressCopied ? "已复制" : "复制访问令牌")) {
                            addressCopied = false
                            Task { await controller.copyToken() }
                        }.buttonStyle(.bordered).disabled(controller.busy)
                            .accessibilityIdentifier("automation-copy-token")
                        if controller.copied && !addressCopied {
                            Text(L10n.text("令牌已复制。仅交给可信的本机工具，勿放入网址或日志。"))
                                .font(.caption).foregroundStyle(palette.muted)
                        }
                    }
                    DisclosureGroup(L10n.text("允许读取连接状态的服务（最多 32 个）")) {
                        serviceChoices.padding(.top, 8)
                    }.disclosureGroupStyle(FullRowDisclosureGroupStyle()).font(.callout)
                    DisclosureGroup(L10n.text("最小使用说明")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.text("向上方地址发送 GET /v1/tasks、/v1/services 或 /v1/health。请求头为 Authorization: Bearer <令牌>，不要使用 URL 参数。"))
                            Text(L10n.text("每分钟最多 60 次连接；超限返回 429，等待 60 秒再试。轮换立即撤销旧令牌，关闭后端口不可用。"))
                            Text(L10n.text("任务沿用本地诊断白名单；服务仅返回本次运行的匿名编号、类型、结果和时间，不返回名称、地址或账号。此接口不接受任何写操作。"))
                            Button(L10n.text("轮换并复制令牌")) {
                                addressCopied = false
                                Task { await controller.rotate() }
                            }.disabled(controller.busy).accessibilityIdentifier("automation-rotate-token")
                        }.font(.caption).foregroundStyle(palette.muted).padding(.top, 8)
                    }.disclosureGroupStyle(FullRowDisclosureGroupStyle()).font(.callout)
                }
            }.padding(12)
        }
        .onChange(of: controller.baseURL) { _, _ in addressCopied = false }
    }

    private var serviceChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("仅使用本次运行已有的连接结果，5 分钟后标记过期；未连接为未知，查询不会检查服务。"))
                .font(.caption).foregroundStyle(palette.muted)
            let choices = appState.automationServiceChoices
            if choices.isEmpty {
                Text(L10n.text("尚未配置文件服务或媒体服务器。")).font(.caption).foregroundStyle(palette.muted)
            }
            ForEach(choices) { choice in
                Toggle(choice.name, isOn: Binding(get: { controller.selectedServices[choice.id] != nil },
                    set: { controller.select(choice.id, enabled: $0) }))
                    .disabled(controller.selectedServices.count >= 32 && controller.selectedServices[choice.id] == nil)
            }
        }
    }

    private func copyAddress(_ value: String) {
        NSPasteboard.general.clearContents()
        addressCopied = NSPasteboard.general.setString(value, forType: .string)
    }
}
