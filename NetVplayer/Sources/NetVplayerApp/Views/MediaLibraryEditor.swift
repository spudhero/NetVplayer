import SwiftUI
import Models
import FileServiceEngine

struct MediaLibraryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    @State var library: MediaLibraryConfiguration
    @State private var selectingFolder = false
    @State private var busy = false
    @State private var error: String?
    private var isEditing: Bool { FileServicesState.shared.catalog.libraries.contains { $0.id == library.id } }

    var body: some View {
        SettingsEditorContainer(title: isEditing ? L10n.text("编辑媒体库") : L10n.text("建立媒体库")) {
            Text(L10n.text("选择视频文件夹，整理电影和剧集。"))
                .font(.system(size: 12)).foregroundStyle(palette.muted).padding(.bottom, 12)
            VStack(spacing: 0) {
                SettingsControlRow(title: L10n.text("媒体库名称"), labelWidth: 140, requirement: .required) {
                    TextField(L10n.text("例如：电影"), text: $library.name)
                }
                SettingsControlRow(title: L10n.text("视频文件夹"), caption: L10n.text("保留 / 表示整个目录"), labelWidth: 140, requirement: .optional) {
                    HStack(spacing: 8) {
                        TextField("/", text: $library.path).accessibilityLabel(L10n.text("视频文件夹"))
                        Button(L10n.text("浏览…")) { selectingFolder = true }
                    }
                }
                SettingsControlRow(title: L10n.text("内容类型"), labelWidth: 140) {
                    SettingsChoicePicker(title: L10n.text("内容类型"), selection: $library.kind, choices: MediaLibraryKind.allCases) {
                        $0 == .mixed ? L10n.text("电影与剧集") : L10n.text($0.title)
                    }
                }
                SettingsControlRow(title: L10n.text("影片资料来源"), labelWidth: 140) {
                    SettingsChoicePicker(title: L10n.text("影片资料来源"), selection: $library.metadataSource, choices: MetadataSource.allCases, label: FileConnectionPresentation.metadataTitle)
                }
            }.disabled(busy)
            Text(L10n.text("优先使用本地海报与影片资料。保存后开始整理，只读取源目录中的文件。"))
                .font(.system(size: 12)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            if let error { SettingsInlineMessage(message: error).padding(.top, 12) }
            if busy { ProgressView(L10n.text("正在验证目录")).padding(.top, 12) }
        } actions: {
            if isEditing {
                Button(L10n.text("删除媒体库"), role: .destructive) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await FileServicesState.shared.removeLibrary(library); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy)
            }
            Spacer()
            Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            Button(L10n.text("保存并扫描")) {
                busy = true; error = nil
                Task {
                    defer { busy = false }
                    do { try await FileServicesState.shared.saveLibrary(library); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy)
        }
        .sheet(isPresented: $selectingFolder) { ServiceDirectoryPicker(serviceID: library.serviceID, selection: $library.path) }
    }
}

struct ServiceDirectoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    let serviceID: UUID
    @Binding var selection: String
    @State private var path = "/"
    @State private var entries: [FileEntry] = []
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        SettingsEditorContainer(title: L10n.text("选择视频文件夹")) {
            HStack(spacing: 10) {
                Button(L10n.text("返回上级")) { path = FileServicePath.parent(path) }.disabled(path == "/" || busy)
                Text(path).font(.system(size: 12)).foregroundStyle(palette.muted).lineLimit(2).textSelection(.enabled)
            }.padding(.bottom, 12)
            if busy { ProgressView(L10n.text("正在读取文件夹")).padding(.vertical, 12) }
            if let error {
                SettingsInlineMessage(message: error)
                Button(L10n.text("重试")) { Task { await load() } }.disabled(busy).padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries.filter(\.isDirectory)) { entry in
                    Button { path = entry.path } label: {
                        HStack {
                            Label(entry.name, systemImage: "folder").lineLimit(2)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(palette.muted)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(busy)
                }
                if entries.filter(\.isDirectory).isEmpty && !busy && error == nil {
                    Text(L10n.text("此处没有子文件夹，可选择当前文件夹。"))
                        .font(.system(size: 12)).foregroundStyle(palette.muted).padding(.vertical, 20)
                }
            }.frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        } actions: {
            Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(L10n.text("选择此文件夹")) { selection = path; dismiss() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy || error != nil)
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        busy = true; error = nil; entries = []
        do {
            let client = try await FileServiceRuntime.shared.client(for: serviceID)
            let result = try await client.allEntries(path: path)
            try Task.checkCancellation()
            entries = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        if !Task.isCancelled { busy = false }
    }
}
