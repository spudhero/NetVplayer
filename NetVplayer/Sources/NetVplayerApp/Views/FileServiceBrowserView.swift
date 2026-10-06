import SwiftUI
import Models
import FileServiceEngine
import SpiderEngine

struct FileServiceBrowserView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var state = FileServicesState.shared
    let service: FileServiceConfiguration
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("浏览方式", selection: $state.mode) {
                ForEach(FileServicesState.FileViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(width: 210)
            if state.mode == .library { MediaLibraryWallView(state: state, service: service) }
            else { directoryContent }
        }
        .task(id: service.id) { state.selectService(service.id) }
        .onChange(of: state.mode) { _, mode in
            if mode == .files { state.load(path: state.path) }
            else { state.cancel(); state.loadMedia() }
        }
        .onDisappear { state.cancel() }
    }
    private var directoryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { state.load(path: FileServicePath.parent(state.path)) } label: { Image(systemName: "arrow.up") }
                    .disabled(state.path == "/" || state.busy).help("返回上级")
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        Button(service.name) { state.load(path: "/") }
                        ForEach(breadcrumbs, id: \.path) { crumb in
                            Image(systemName: "chevron.right").font(.caption)
                            Button(crumb.name) { state.load(path: crumb.path) }
                        }
                    }.buttonStyle(.plain)
                }
                Spacer()
                Picker("排序", selection: $state.sort) { ForEach(FileServicesState.FileSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 140)
                TextField("搜索当前目录", text: $state.search).textFieldStyle(.roundedBorder).frame(maxWidth: 230)
            }
            if state.busy { HStack { ProgressView().controlSize(.small); Text("正在读取目录"); Button("取消") { state.cancel() } } }
            if let error = state.directoryError ?? state.error {
                HStack { Text(error).foregroundStyle(.red); Button("重试") { state.load(path: state.path) }; Button("编辑服务") { appState.selectedTab = .settings } }
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(state.visibleEntries) { entry in
                        Button { open(entry) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : (FileServiceRuntime.isVideo(entry) ? "play.rectangle" : "doc"))
                                    .frame(width: 24).foregroundStyle(entry.isDirectory ? .yellow : .secondary)
                                Text(entry.name).lineLimit(1)
                                Spacer()
                                if !entry.isDirectory { Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).foregroundStyle(.secondary).font(.caption) }
                                if let date = entry.modifiedAt { Text(date, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary).frame(width: 100) }
                                if entry.isDirectory { Image(systemName: "chevron.right") }
                            }.padding(12).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!entry.isDirectory && !FileServiceRuntime.isVideo(entry))
                    }
                }
                if state.entries.isEmpty && !state.busy && state.directoryError == nil && state.error == nil { Text("此目录为空").foregroundStyle(.secondary).padding(30) }
            }
        }
    }
    private var breadcrumbs: [(name: String, path: String)] {
        var path = ""
        return state.path.split(separator: "/").map { name in path += "/" + name; return (String(name), path) }
    }
    private func open(_ entry: FileEntry) {
        if entry.isDirectory { state.load(path: entry.path) }
        else {
            Task {
                do { try await appState.selectVod(FileServiceNativeProvider.vod(entry: entry, serviceID: service.id, site: service.site())) }
                catch { state.error = error.localizedDescription }
            }
        }
    }
}
