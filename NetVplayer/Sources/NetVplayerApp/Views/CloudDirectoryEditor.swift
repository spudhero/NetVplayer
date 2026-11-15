import SwiftUI
import Models
import Storage
import DriveEngine

/// Account selection hands off to the existing multiple-folder picker and scan workflow.
struct CloudDirectoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    @EnvironmentObject private var appState: AppState
    @ObservedObject var state = FileServicesState.shared
    @State var provider: DriveProvider = .quark
    @State private var connectedService: FileServiceConfiguration?
    @State private var busy = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Group {
            if let connectedService {
                MediaLibraryBatchEditor(state: state, service: connectedService, newConnection: true)
            } else {
                SettingsEditorContainer(title: L10n.text("添加网盘目录"), width: 600) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.text("选择网盘 → 选择文件夹"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.muted)
                        Text(L10n.text("使用已保存的账号，将一个或多个文件夹加入媒体库。"))
                            .font(.system(size: 13)).foregroundStyle(palette.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        SettingsChoicePicker(title: L10n.text("网盘服务"), selection: $provider,
                                             choices: PersonalCloudDirectoryClient.supportedProviders) {
                            $0.localizedDisplayName
                        }
                        Text(L10n.text("下一步可多选文件夹。尚未登录时，请先登录此网盘。"))
                            .font(.system(size: 12)).foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let message { SettingsInlineMessage(message: message) }
                    }.disabled(busy)
                } actions: {
                    Button(L10n.text("登录网盘")) {
                        dismiss()
                        appState.requestCloudAuthFromSettings(provider)
                    }.buttonStyle(.borderless).disabled(busy)
                    if busy { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在连接网盘")) }
                    Spacer()
                    Button(L10n.text("取消")) { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L10n.text("选择文件夹")) { connect() }
                        .buttonStyle(ThemedDialogButtonStyle(isPrimary: true)).keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        }
        .onChange(of: provider) { _, _ in message = nil }
        .onDisappear { task?.cancel() }
    }

    private func connect() {
        task?.cancel(); busy = true; message = nil
        let requestedProvider = provider
        task = Task {
            defer { busy = false }
            do {
                let service = try await state.connectCloudDirectory(requestedProvider)
                try Task.checkCancellation()
                connectedService = service
            } catch is CancellationError {
            } catch FileServiceError.authorizationExpired {
                message = L10n.text("请先登录此网盘，再重新选择文件夹。")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
