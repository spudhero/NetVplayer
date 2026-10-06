import SwiftUI
import AppKit
import Models
import Storage
import FileServiceEngine

struct FileServiceSettings: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject private var state = FileServicesState.shared
    @State private var draft: FileServiceConfiguration?
    @State private var deleting: FileServiceConfiguration?
    @State private var libraryDraft: MediaLibraryConfiguration?
    @State private var error: String?

    var body: some View {
        GroupBox(label: SettingsPanelLabel(
            title: L10n.text("视频文件位置"),
            subtitle: L10n.text("连接 NAS、本机文件夹或自己的文件服务器，浏览和播放其中的视频。"),
            systemImage: "externaldrive"
        )) {
            VStack(alignment: .leading, spacing: 14) {
                if state.catalog.services.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("还没有添加视频文件位置")).font(.system(size: 13, weight: .medium))
                        Text(L10n.text("从 NAS、Mac 文件夹或文件服务器开始。"))
                            .font(.system(size: 12)).foregroundStyle(palette.muted)
                    }
                }
                ForEach(state.catalog.services) { service in
                    VStack(alignment: .leading, spacing: 12) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                serviceLabel(service)
                                Spacer(minLength: 12)
                                serviceActions(service).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                serviceLabel(service)
                                serviceActions(service)
                            }
                        }
                        ForEach(state.catalog.libraries.filter { $0.serviceID == service.id }) { library in
                            HStack(spacing: 10) {
                                Image(systemName: "rectangle.stack").foregroundStyle(palette.muted)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(library.name).font(.system(size: 13, weight: .medium))
                                    Text(library.path).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Button(L10n.text("编辑媒体库")) { libraryDraft = library }
                            }.padding(.leading, 26)
                        }
                        Divider()
                    }
                }
                if let error { SettingsInlineMessage(message: error) }
                Button(L10n.text("添加视频文件位置"), systemImage: "plus") { draft = .init() }
                    .buttonStyle(.borderedProminent)
                Text(L10n.text("连接文件位置后，选择视频文件夹，整理电影和剧集。"))
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 27)
        }
        .sheet(item: $draft) { FileServiceEditor(configuration: $0) }
        .sheet(item: $libraryDraft) { MediaLibraryEditor(library: $0) }
        .themedConfirmation(L10n.text("删除视频文件位置？"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            confirmTitle: L10n.text("删除"), message: L10n.text("历史和收藏会保留，来源将显示为不可用。")
        ) {
            guard let service = deleting else { return }
            Task { do { try await state.remove(service) } catch { self.error = error.localizedDescription } }
        }
    }

    private func serviceLabel(_ service: FileServiceConfiguration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: service.kind == .local ? "folder" : "externaldrive.connected.to.line.below")
                .foregroundStyle(palette.muted).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(service.name).font(.system(size: 13, weight: .semibold))
                Text(FileConnectionPresentation.title(service.kind)).font(.system(size: 11)).foregroundStyle(palette.muted)
                if service.kind != .local {
                    Text(service.kind == .smb ? SMBFolderAddress.formatted(service) : service.address)
                        .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                }
            }
        }.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
    }

    private func serviceActions(_ service: FileServiceConfiguration) -> some View {
        HStack(spacing: 8) {
            Button(L10n.text("编辑")) { draft = service }
            Button(L10n.text("建立媒体库")) {
                libraryDraft = .init(serviceID: service.id, name: "", metadataSource: state.catalog.defaultMetadataSource)
            }
            Button(L10n.text("删除"), role: .destructive) { deleting = service }
        }.buttonStyle(.bordered)
    }
}

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
        SettingsEditorContainer(title: isEditing ? L10n.text("编辑视频文件位置") : L10n.text("添加视频文件位置")) {
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
            Button(L10n.text("保存")) { perform(save: true) }
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
            FormFieldLabel(title: L10n.text("文件夹地址"), requirement: .required)
            TextField(L10n.text("smb://nas.local/家庭共享/电影"), text: $smbFolderAddress)
                .accessibilityLabel(L10n.text("文件夹地址"))
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("整个共享：smb://nas.local/家庭共享"))
                Text(L10n.text("只看电影：smb://nas.local/家庭共享/电影"))
                Text(L10n.text("将 nas.local 换成 NAS 的 IP 或名称，后面填写实际文件夹名称。"))
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
                    try await FileServicesState.shared.save(configuration: candidate, credentials: credentials, bookmark: bookmark)
                    if !Task.isCancelled { dismiss() }
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
