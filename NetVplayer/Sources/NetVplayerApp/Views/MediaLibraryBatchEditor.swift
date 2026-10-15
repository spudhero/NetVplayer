import SwiftUI
import Models
import FileServiceEngine

/// Browse once, keep selections across directories, then add all libraries to one connection.
struct MediaLibraryBatchEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var state = FileServicesState.shared
    let service: FileServiceConfiguration
    var newConnection = false
    @State private var path = "/"
    @State private var entries: [FileEntry] = []
    @State private var selections: [MediaLibraryConfiguration] = []
    @State private var loading = false
    @State private var saving = false
    @State private var directoryError: String?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var directoryGeneration = 0

    private var existing: [MediaLibraryConfiguration] {
        state.catalog.libraries.filter { $0.serviceID == service.id }
    }

    var body: some View {
        SettingsEditorContainer(title: L10n.text("添加文件夹"), width: 840) {
            connectionSummary
            HStack(alignment: .top, spacing: 16) {
                folderBrowser.frame(maxWidth: .infinity)
                ThemedScrollView { selectedFolders.padding(12) }
                    .frame(width: 350, height: 320)
                    .background(AppGlassSurface(cornerRadius: 12, role: .control))
            }.padding(.top, 16)
            if let saveError { SettingsInlineMessage(message: saveError).padding(.top, 12) }
        } actions: {
            if saving {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在验证所选文件夹")).font(.caption).foregroundStyle(palette.muted)
            } else {
                Text(L10n.text("已选 {0} 个文件夹", [String(selections.count)]))
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
            }
            Spacer()
            Button(newConnection ? L10n.text("稍后添加") : L10n.text("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction).disabled(saving)
            Button(L10n.text("添加并扫描")) { save() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(saving || selections.isEmpty || selections.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        .task(id: path) { await loadDirectory() }
        .onDisappear { saveTask?.cancel() }
    }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if newConnection {
                HStack(spacing: 8) {
                    Label(L10n.text("连接服务"), systemImage: "checkmark.circle.fill").foregroundStyle(palette.muted)
                    Image(systemName: "chevron.right").font(.system(size: 10))
                    Text(L10n.text("选择文件夹")).foregroundStyle(palette.accent)
                }.font(.system(size: 12, weight: .medium))
            }
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.name).font(.system(size: 14, weight: .semibold))
                    Text(service.kind == .smb ? SMBFolderAddress.formatted(service) : service.kind == .local ? L10n.text("本机文件夹") : service.address)
                        .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
                }
                Spacer()
                Text(service.kind.title).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted)
            }
            Text(L10n.text("勾选多个文件夹，共用此连接。每个文件夹将建立一个媒体库。"))
                .font(.system(size: 12)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            if existing.contains(where: { $0.path == "/" }) {
                Text(L10n.text("此连接的整个目录已在媒体库中，子文件夹会一起扫描。"))
                    .font(.system(size: 12)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var folderBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { path = FileServicePath.parent(path) } label: { Image(systemName: "arrow.up") }
                    .help(L10n.text("返回上级")).accessibilityLabel(L10n.text("返回上级"))
                    .disabled(path == "/" || loading || saving)
                Text(path == "/" ? L10n.text("连接根目录") : path)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(selections.contains(where: { $0.path == path }) ? L10n.text("取消选择当前文件夹") : L10n.text("选择当前文件夹")) {
                    toggle(path: path, name: path == "/" ? service.name : (path as NSString).lastPathComponent)
                }
                .font(.system(size: 11)).disabled(loading || saving || directoryError != nil
                    || (!selections.contains(where: { $0.path == path }) && isBlocked(path)))
            }.padding(12)
            Divider()
            ThemedScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if loading {
                        HStack { ProgressView().controlSize(.small); Text(L10n.text("正在读取文件夹")) }.padding(16)
                    } else if let directoryError {
                        SettingsInlineMessage(message: directoryError).padding(12)
                        Button(L10n.text("重试")) { Task { await loadDirectory() } }.padding(.horizontal, 12)
                    } else {
                        ForEach(entries) { entry in folderRow(entry) }
                        if entries.isEmpty {
                            Text(L10n.text("此处没有子文件夹，可选择当前文件夹。"))
                                .font(.system(size: 12)).foregroundStyle(palette.muted).padding(16)
                        }
                    }
                }.padding(6)
            }.frame(height: 270)
        }
        .background(AppGlassSurface(cornerRadius: 12, role: .control))
    }

    private func folderRow(_ entry: FileEntry) -> some View {
        let selected = selections.contains { $0.path == entry.path }
        let alreadyAdded = existing.contains { MediaLibraryBatch.overlaps($0.path, entry.path) }
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { selected }, set: { _ in toggle(path: entry.path, name: entry.name) })) {
                Label(entry.name, systemImage: "folder").lineLimit(1)
            }
            .toggleStyle(.checkbox).disabled(saving || (!selected && isBlocked(entry.path)))
            Spacer(minLength: 8)
            if alreadyAdded {
                Text(L10n.text("已在媒体库中")).font(.system(size: 11)).foregroundStyle(palette.muted)
            } else if !selected && isBlocked(entry.path) {
                Text(L10n.text("与已选目录重叠")).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            Button { path = entry.path } label: { Image(systemName: "chevron.right").frame(width: 24, height: 28) }
                .buttonStyle(.plain).foregroundStyle(palette.muted).disabled(saving)
                .accessibilityLabel(L10n.text("进入文件夹：{0}", [entry.name]))
        }
        .font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? palette.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private var selectedFolders: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("所选文件夹")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(selections.count)).font(.system(size: 12)).foregroundStyle(palette.muted)
            }
            if selections.isEmpty {
                Text(L10n.text("勾选左侧文件夹，也可以进入子目录后继续选择。"))
                    .font(.system(size: 12)).foregroundStyle(palette.muted).padding(.vertical, 10)
            }
            ForEach($selections) { $library in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(library.path, systemImage: "folder").font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                        Spacer()
                        Button { selections.removeAll { $0.id == library.id } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(palette.muted)
                            .accessibilityLabel(L10n.text("移除文件夹：{0}", [library.name]))
                    }
                    HStack(spacing: 10) {
                        TextField(L10n.text("媒体库名称"), text: $library.name)
                            .accessibilityLabel(L10n.text("媒体库名称") + " " + library.path)
                        Picker(L10n.text("内容类型"), selection: $library.kind) {
                            ForEach(MediaLibraryKind.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                        }.labelsHidden().frame(width: 84)
                    }
                }.padding(10).background(palette.foreground.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)).disabled(saving)
            }
            if !selections.isEmpty {
                Text(L10n.text("保存后开始整理，只读取源目录中的文件。"))
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }
    }

    private func isBlocked(_ path: String) -> Bool {
        (existing + selections).contains { MediaLibraryBatch.overlaps($0.path, path) }
    }

    private func toggle(path: String, name: String) {
        saveError = nil
        if selections.contains(where: { $0.path == path }) {
            selections.removeAll { $0.path == path }; return
        }
        guard !isBlocked(path) else { return }
        let kind: MediaLibraryKind = ["电影", "movies", "movie"].contains(name.lowercased()) ? .movies
            : ["电视剧", "剧集", "tv", "tv shows", "shows"].contains(name.lowercased()) ? .television : .mixed
        selections.append(.init(serviceID: service.id, name: name, path: path, kind: kind, metadataSource: state.catalog.defaultMetadataSource))
    }

    private func loadDirectory() async {
        let requestedPath = path
        directoryGeneration += 1
        let generation = directoryGeneration
        loading = true; directoryError = nil; entries = []
        do {
            let result = try await state.directoryEntries(serviceID: service.id, path: requestedPath)
            try Task.checkCancellation()
            guard requestedPath == path, generation == directoryGeneration else { return }
            entries = result.filter { $0.isDirectory && !$0.isSymbolicLink && !$0.name.hasPrefix(".") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            guard !Task.isCancelled, requestedPath == path, generation == directoryGeneration else { return }
            directoryError = error.localizedDescription
        }
        loading = false
    }

    private func save() {
        saving = true; saveError = nil
        saveTask = Task {
            defer { saving = false }
            do { try await state.addLibraries(selections, to: service.id); dismiss() }
            catch { if !Task.isCancelled { saveError = error.localizedDescription } }
        }
    }
}
