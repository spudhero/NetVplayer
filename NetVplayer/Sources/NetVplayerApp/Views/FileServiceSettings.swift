import SwiftUI
import Models

struct FileServiceSettings: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var state = FileServicesState.shared
    @State private var draft: FileServiceConfiguration?
    @State private var deleting: FileServiceConfiguration?
    @State private var folderService: FileServiceConfiguration?
    @State private var libraryDraft: MediaLibraryConfiguration?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { heading; Spacer(); addConnection }
                VStack(alignment: .leading, spacing: 12) { heading; addConnection }
            }
            if state.catalog.services.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text("还没有添加视频文件位置"), systemImage: "externaldrive")
                        .font(.system(size: 14, weight: .medium))
                    Text(L10n.text("连接一次 NAS，再同时添加电影、剧集等多个文件夹。"))
                        .font(.system(size: 12)).foregroundStyle(palette.muted)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppGlassSurface(cornerRadius: 14))
            }
            ForEach(state.catalog.services) { service in serviceCard(service) }
            if let error { SettingsInlineMessage(message: error) }
        }
        .sheet(item: $draft) { FileServiceEditor(configuration: $0) }
        .sheet(item: $folderService) { MediaLibraryBatchEditor(state: state, service: $0) }
        .sheet(item: $libraryDraft) { MediaLibraryEditor(library: $0) }
        .themedConfirmation(L10n.text("删除视频文件位置？"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            confirmTitle: L10n.text("删除"), message: L10n.text("历史和收藏会保留，来源将显示为不可用。")
        ) {
            guard let service = deleting else { return }
            Task { do { try await state.remove(service) } catch { self.error = error.localizedDescription } }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("连接与文件夹")).font(.system(size: 16, weight: .semibold))
            Text(L10n.text("每台服务连接一次，文件夹分别管理。"))
                .font(.system(size: 12)).foregroundStyle(palette.muted)
        }
    }
    private var addConnection: some View {
        Button { draft = .init(kind: .smb) } label: { Label(L10n.text("添加连接"), systemImage: "plus") }
            .buttonStyle(.borderedProminent).fixedSize()
    }

    private func serviceCard(_ service: FileServiceConfiguration) -> some View {
        let libraries = state.catalog.libraries.filter { $0.serviceID == service.id }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: service.kind == .local ? "folder" : "externaldrive.connected.to.line.below")
                    .font(.system(size: 20)).foregroundStyle(palette.accent)
                    .frame(width: 42, height: 42)
                    .background(palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(service.name).font(.system(size: 14, weight: .semibold))
                        Text(service.kind.title).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.muted).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(palette.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(service.kind == .smb ? SMBFolderAddress.formatted(service) : service.kind == .local ? L10n.text("本机文件夹") : service.address)
                        .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button { folderService = service } label: { Label(L10n.text("添加文件夹"), systemImage: "folder.badge.plus") }
                    .buttonStyle(.bordered).fixedSize()
                Menu {
                    Button(L10n.text("编辑连接")) { draft = service }
                    Divider()
                    Button(L10n.text("删除连接"), role: .destructive) { deleting = service }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(L10n.text("连接选项：{0}", [service.name]))
            }.padding(16)
            Divider().padding(.horizontal, 16)
            if libraries.isEmpty {
                Text(L10n.text("尚未添加文件夹，可一次选择多个目录。"))
                    .font(.system(size: 12)).foregroundStyle(palette.muted).padding(16)
            } else {
                VStack(spacing: 0) {
                    ForEach(libraries) { library in
                        HStack(spacing: 12) {
                            Image(systemName: library.kind == .television ? "tv" : library.kind == .movies ? "film" : "rectangle.stack")
                                .foregroundStyle(palette.muted).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(library.name).font(.system(size: 13, weight: .medium))
                                Text(library.path == "/" ? L10n.text("连接根目录") : library.path)
                                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(L10n.text(library.kind.title)).font(.system(size: 11)).foregroundStyle(palette.muted)
                            Button(L10n.text("编辑")) { libraryDraft = library }
                                .buttonStyle(.borderless).font(.system(size: 12))
                                .accessibilityLabel(L10n.text("编辑媒体库") + " " + library.name)
                        }.padding(.horizontal, 18).padding(.vertical, 12)
                        if library.id != libraries.last?.id { Divider().padding(.leading, 54).padding(.trailing, 16) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppGlassSurface(cornerRadius: 14))
    }
}
