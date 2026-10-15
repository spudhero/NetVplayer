import SwiftUI
import AppKit
import Models
import Storage
import FileServiceEngine

struct FileServiceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    @State var configuration: FileServiceConfiguration
    @State private var credentials = FileServiceCredentials()
    @State private var bookmark: Data?
    @State private var folderName = ""
    @State private var busy = false
    @State private var loading = true
    @State private var message: String?
    @State private var messageIsError = false
    @State private var advancedExpanded = false
    @State private var directoryPath = "/"
    @State private var directoryPassword = ""
    @State private var task: Task<Void, Never>?
    @State private var smbFolderAddress: String
    @State private var connectedService: FileServiceConfiguration?

    init(configuration: FileServiceConfiguration) {
        _configuration = State(initialValue: configuration)
        _smbFolderAddress = State(initialValue: configuration.kind == .smb ? SMBFolderAddress.formatted(configuration) : "")
    }

    private var isEditing: Bool { FileServicesState.shared.catalog.services.contains { $0.id == configuration.id } }
    private var isFileList: Bool { configuration.kind == .alist || configuration.kind == .openList }
    private var missingRequiredField: String? {
        if configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.text("请填写名称") }
        if configuration.kind == .local { return bookmark == nil ? L10n.text("请选择视频文件夹") : nil }
        let address = configuration.kind == .smb ? smbFolderAddress : configuration.address
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.text("请填写地址") }
        if configuration.kind == .smb && !configuration.guest && credentials.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.text("请填写用户名，或启用访客连接")
        }
        return nil
    }

    var body: some View {
        Group {
            if let connectedService {
                MediaLibraryBatchEditor(service: connectedService, newConnection: true)
            } else {
                connectionEditor
            }
        }
    }

    private var connectionEditor: some View {
        SettingsEditorContainer(title: isEditing ? L10n.text("编辑连接") : L10n.text("添加 NAS 或文件位置"), width: 660) {
            if !isEditing {
                HStack(spacing: 8) {
                    Text(L10n.text("1 连接服务")).foregroundStyle(palette.accent)
                    Image(systemName: "chevron.right").font(.system(size: 10))
                    Text(L10n.text("2 选择文件夹")).foregroundStyle(palette.muted)
                }.font(.system(size: 12, weight: .medium)).padding(.bottom, 18)
            }
            fields.disabled(loading || busy)
            if loading { ProgressView(L10n.text("正在读取账号信息")).controlSize(.small).padding(.vertical, 8) }
            if let message {
                SettingsInlineMessage(message: message, role: messageIsError ? .danger : .success).padding(.top, 12)
            }
            if !loading, message == nil, let missingRequiredField {
                Text(missingRequiredField).font(.system(size: 12)).foregroundStyle(palette.muted).padding(.top, 12)
            }
        } actions: {
            if busy { ProgressView().controlSize(.small) }
            Button(L10n.text("测试连接")) { perform(save: false) }.disabled(loading || busy || missingRequiredField != nil)
            Spacer()
            Button(L10n.text("取消")) { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            Button(isEditing ? L10n.text("保存") : L10n.text("连接并选择文件夹")) { perform(save: true) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(loading || busy || missingRequiredField != nil)
        }
        .task {
            advancedExpanded = (configuration.kind != .smb && configuration.port != nil && configuration.port != configuration.kind.defaultPort)
                || !configuration.domain.isEmpty
            defer { loading = false }
            do {
                let original = configuration
                let loaded = try await Task.detached { try FileServiceStore.shared.credentials(for: original) }.value
                try Task.checkCancellation()
                credentials = loaded
                bookmark = FileServiceStore.shared.bookmark(for: original.id)
                folderName = bookmark == nil ? "" : L10n.text("已授权目录（可重新选择）")
                advancedExpanded = advancedExpanded
                    || loaded.directoryPasswords.keys.contains { $0 != original.rootPath }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription; messageIsError = true }
            }
        }
        .onChange(of: configuration) { _, _ in message = nil }
        .onChange(of: smbFolderAddress) { _, _ in message = nil }
        .onChange(of: credentials) { _, _ in message = nil }
        .onDisappear { task?.cancel() }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsControlRow(title: L10n.text("名称"), labelWidth: 140, requirement: .required) {
                TextField(L10n.text("例如：家里的 NAS"), text: $configuration.name)
            }
            SettingsControlRow(title: L10n.text("连接方式"), labelWidth: 140) {
                SettingsChoicePicker(title: L10n.text("连接方式"), selection: $configuration.kind, choices: FileConnectionPresentation.choices, label: FileConnectionPresentation.title)
            }
            Text(FileConnectionPresentation.hint(configuration.kind))
                .font(.system(size: 12)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            if configuration.kind == .local {
                SettingsControlRow(title: L10n.text("视频文件夹"), labelWidth: 140, requirement: .required) {
                    HStack {
                        Text(folderName.isEmpty ? L10n.text("请选择视频文件夹") : folderName).lineLimit(1)
                        Spacer(minLength: 8)
                        Button(L10n.text("选择文件夹…"), action: chooseFolder)
                    }
                }
            } else if configuration.kind == .smb {
                smbAddressField
            } else {
                SettingsControlRow(title: L10n.text("服务器地址"), labelWidth: 140, requirement: .required) {
                    TextField("https://server.example", text: $configuration.address)
                        .accessibilityLabel(L10n.text("服务器地址"))
                }
            }
            if configuration.kind != .smb {
                SettingsControlRow(title: L10n.text("视频根目录"), caption: L10n.text("保留 / 表示整个目录"), labelWidth: 140, requirement: .optional) {
                    TextField("/", text: $configuration.rootPath).accessibilityLabel(L10n.text("视频根目录"))
                }
            }
            if configuration.kind == .smb {
                Toggle(L10n.text("使用访客连接"), isOn: $configuration.guest).padding(.vertical, 10)
                Text(configuration.guest ? L10n.text("访客连接无需用户名和密码，需要 NAS 允许访客访问。") : L10n.text("使用 NAS 上的账号登录；密码按服务器要求填写，空密码账号可留空。"))
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            }
            if configuration.kind != .local && !(configuration.kind == .smb && configuration.guest) {
                SettingsControlRow(title: L10n.text("用户名"), caption: configuration.kind == .smb ? "" : L10n.text("公开目录可留空；需要登录时填写"), labelWidth: 140, requirement: configuration.kind == .smb ? .required : .serverDependent) {
                    TextField(L10n.text("用户名"), text: $credentials.username)
                }
                SettingsControlRow(title: L10n.text("登录密码"), caption: L10n.text("使用服务方提供的密码"), labelWidth: 140, requirement: .serverDependent) {
                    SettingsPasswordField(L10n.text("登录密码"), text: $credentials.password)
                }
            }
            if isFileList {
                SettingsControlRow(title: L10n.text("根目录密码"), caption: L10n.text("仅文件夹设置了访问密码时填写"), labelWidth: 140, requirement: .optional) {
                    SettingsPasswordField(L10n.text("根目录密码"), text: Binding(
                        get: { credentials.directoryPasswords[configuration.rootPath] ?? "" },
                        set: { credentials.directoryPasswords[configuration.rootPath] = $0 }
                    ))
                }
            }
            if configuration.kind != .local {
                DisclosureGroup(L10n.text("高级连接设置"), isExpanded: $advancedExpanded) {
                    advancedSettings.padding(.top, 8)
                }.padding(.vertical, 12)
            }
        }
    }

    private var smbAddressField: some View {
        VStack(alignment: .leading, spacing: 8) {
            FormFieldLabel(title: L10n.text("共享地址"), requirement: .required)
            TextField(L10n.text("smb://nas.local/家庭共享"), text: $smbFolderAddress)
                .accessibilityLabel(L10n.text("共享地址"))
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("连接共享根目录，下一步可同时选择电影、剧集等多个文件夹。"))
                Text(L10n.text("如只开放某个子目录，也可以在地址后继续填写路径。"))
            }
            .font(.system(size: 12)).foregroundStyle(palette.muted)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.padding(.vertical, 8)
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            if configuration.kind != .smb {
                SettingsControlRow(title: L10n.text("端口"), caption: L10n.text("留空使用默认端口"), labelWidth: 140, requirement: .optional) {
                    TextField(L10n.text("默认 {0}", [String(configuration.kind.defaultPort)]), text: Binding(
                        get: { configuration.port.map(String.init) ?? "" },
                        set: { configuration.port = $0.isEmpty ? nil : (Int($0) ?? 0) }
                    ))
                }
            }
            if configuration.kind == .smb {
                Text(L10n.text("如需指定端口，写在地址中，例如 smb://nas.local:1445/家庭共享"))
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                SettingsControlRow(title: L10n.text("域名"), caption: L10n.text("普通家庭 NAS 通常无需填写"), labelWidth: 140, requirement: .optional) {
                    TextField(L10n.text("域名（可选）"), text: $configuration.domain)
                }
            }
            if isFileList {
                Text(L10n.text("受保护子目录")).font(.system(size: 13, weight: .semibold)).padding(.top, 12)
                ForEach(credentials.directoryPasswords.keys.filter { $0 != configuration.rootPath }.sorted(), id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(2)
                        Spacer()
                        Button(L10n.text("移除")) { credentials.directoryPasswords[path] = nil }
                    }.padding(.vertical, 6)
                }
                SettingsControlRow(title: L10n.text("子目录路径"), caption: L10n.text("添加目录密码时填写"), labelWidth: 140, requirement: .serverDependent) {
                    TextField("/", text: $directoryPath).accessibilityLabel(L10n.text("子目录路径"))
                }
                SettingsControlRow(title: L10n.text("子目录密码"), labelWidth: 140, requirement: .serverDependent) {
                    SettingsPasswordField(L10n.text("子目录密码"), text: $directoryPassword)
                }
                Button(L10n.text("添加目录密码")) {
                    do {
                        credentials.directoryPasswords[try FileServicePath.normalize(directoryPath)] = directoryPassword
                        directoryPassword = ""
                        message = nil
                    } catch { message = error.localizedDescription; messageIsError = true }
                }.padding(.top, 8)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            folderName = url.lastPathComponent
            configuration.address = ""; configuration.rootPath = "/"
            if configuration.name.isEmpty { configuration.name = folderName }
        } catch { message = error.localizedDescription; messageIsError = true }
    }

    private func perform(save: Bool) {
        busy = true; message = nil
        task = Task {
            defer { busy = false }
            do {
                let candidate = configuration.kind == .smb
                    ? try SMBFolderAddress(smbFolderAddress).applying(to: configuration)
                    : configuration
                if save {
                    let wasEditing = isEditing
                    try await FileServicesState.shared.save(configuration: candidate, credentials: credentials, bookmark: bookmark)
                    if !Task.isCancelled {
                        if wasEditing { dismiss() }
                        else { connectedService = try candidate.validated() }
                    }
                } else {
                    try await FileServiceRuntime.shared.test(configuration: candidate, credentials: credentials, bookmark: bookmark)
                    try Task.checkCancellation()
                    message = L10n.text("连接成功，已完成认证并读取配置目录。")
                    messageIsError = false
                }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription; messageIsError = true }
            }
        }
    }
}
