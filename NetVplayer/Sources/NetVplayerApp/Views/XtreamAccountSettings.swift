import SwiftUI
import Models
import Storage
import SpiderEngine

struct XtreamAccountSettings: View {
    @EnvironmentObject var appState: AppState
    @State private var accounts: [XtreamConfiguration] = []
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var allowsHTTP = false
    @State private var busy = false
    @State private var status: String?
    @State private var statusIsError = false
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        GroupBox(label: SettingsPanelLabel(
            title: L10n.text("影视与直播账号（Xtream）"),
            subtitle: L10n.text("连接支持 Xtream 的影视或电视直播服务，需要服务方提供的地址、用户名和密码。"),
            systemImage: "person.crop.rectangle"
        )) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsControlRow(title: L10n.text("账号"), caption: L10n.text("添加或管理已有账号")) {
                    SettingsChoicePicker(title: L10n.text("账号"), selection: $selectedID, choices: [UUID?.none] + accounts.map { Optional($0.id) }) { id in
                        accounts.first { $0.id == id }?.name ?? L10n.text("添加账号")
                    }
                }
                .onChange(of: selectedID) { _, value in status = nil; populate(value) }
                Divider()
                SettingsControlRow(title: L10n.text("账号名称"), caption: L10n.text("留空使用 Xtream"), requirement: .optional) {
                    TextField(L10n.text("方便识别的名称"), text: $name)
                }
                SettingsControlRow(title: L10n.text("服务地址"), requirement: .required) {
                    TextField("https://server.example", text: $server).accessibilityLabel(L10n.text("服务地址"))
                }
                SettingsControlRow(title: L10n.text("用户名"), requirement: .required) {
                    TextField(L10n.text("用户名"), text: $username)
                }
                SettingsControlRow(title: L10n.text("密码"), requirement: .required) {
                    SettingsPasswordField(L10n.text("密码"), text: $password)
                        .id(selectedID)
                }
                Toggle(L10n.text("此服务器只支持 HTTP"), isOn: $allowsHTTP)
                    .font(.caption)
                    .padding(.top, 12)
                Text(L10n.text("启用后，账号和密码会通过未加密连接发送。账号在本机加密保存，备份只包含服务器配置。"))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                HStack {
                    Button(L10n.text("验证并连接")) { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    if let id = selectedID {
                        Button(L10n.text("退出此账号")) {
                            do {
                                try UserPreferences.shared.saveCredential("", for: "xtream." + id.uuidString.lowercased())
                                username = ""; password = ""; status = L10n.text("账号已退出，服务器配置已保留。")
                                statusIsError = false
                            } catch { status = error.localizedDescription; statusIsError = true }
                        }.disabled(busy)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                .padding(.top, 14)
                if let status {
                    SettingsInlineMessage(message: status, role: statusIsError ? .danger : .success).padding(.top, 10)
                }
            }
            .padding(.leading, 27)
            .textFieldStyle(SettingsFieldStyle())
        }.onAppear { accounts = UserPreferences.shared.xtreamConfigurations }
    }

    private func populate(_ id: UUID?) {
        guard let account = accounts.first(where: { $0.id == id }) else {
            name = ""; server = ""; username = ""; password = ""; allowsHTTP = false; return
        }
        name = account.name; server = account.server; allowsHTTP = account.allowsHTTP
        let credentials = try? UserPreferences.shared.xtreamCredentials(for: account.id)
        username = credentials?.username ?? ""; password = credentials?.password ?? ""
    }

    private func connect() {
        busy = true; status = nil; statusIsError = false
        Task { @MainActor in
            defer { busy = false }
            do {
                let account = try XtreamConfiguration(id: selectedID ?? UUID(), name: name, server: server, allowsHTTP: allowsHTTP)
                let credentials = XtreamCredentials(username: username, password: password)
                let provider = try XtreamSiteProvider(configuration: account, credentials: { credentials })
                try await provider.authenticate()
                try UserPreferences.shared.saveXtreamCredentials(credentials, for: account.id, server: account.server)
                accounts.removeAll { $0.id == account.id }; accounts.append(account)
                UserPreferences.shared.xtreamConfigurations = accounts
                selectedID = account.id
                await appState.loadConfig(url: account.url, waitForProviderRuntime: false)
                status = appState.configError ?? L10n.text("Xtream 已连接。")
                statusIsError = appState.configError != nil
            } catch { status = error.localizedDescription; statusIsError = true }
        }
    }
}
