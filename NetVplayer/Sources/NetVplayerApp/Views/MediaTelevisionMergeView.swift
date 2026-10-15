import SwiftUI
import Models
import MediaLibraryEngine

struct MediaTelevisionMergeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var state: FileServicesState
    let libraryID: UUID
    @State private var records: [MediaRecord] = []
    @State private var selected = Set<String>()
    @State private var targetID = ""
    @State private var search = ""
    @State private var busy = true
    @State private var error: String?
    private var targets: [MediaRecord] {
        records.filter { $0.candidates.isEmpty && ($0.metadata.tmdbID != nil || $0.metadata.doubanID != nil) }
    }
    private var visible: [MediaRecord] {
        records.filter { search.isEmpty || title($0).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("合并为同一剧集")).font(.title2.bold())
            Text(L10n.text("选择同一部电视剧的条目，共用已确认的影视资料；各季、剧集和视频文件都会保留。"))
                .font(.callout).foregroundStyle(palette.muted)
            if targets.isEmpty && !busy {
                Text(L10n.text("请先为其中一个条目修正影视信息，再将其他季合并到它。"))
                    .font(.callout).foregroundStyle(palette.color(for: .warning))
            } else {
                Picker(L10n.text("共用影视资料"), selection: $targetID) {
                    ForEach(targets) { record in Text(title(record)).tag(record.id) }
                }.disabled(busy)
            }
            HStack {
                TextField(L10n.text("筛选剧集条目"), text: $search).textFieldStyle(.roundedBorder)
                Button(L10n.text("全选")) { selected.formUnion(visible.map(\.id)) }
                Button(L10n.text("清除选择")) { selected.removeAll() }
            }.disabled(busy)
            ThemedScrollView(theme: .subtle) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visible) { record in
                        Toggle(isOn: Binding(get: { selected.contains(record.id) }, set: { value in
                            if value { selected.insert(record.id) } else { selected.remove(record.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(title(record)).font(.callout.weight(.medium))
                                Text(record.reference.path).font(.caption).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.toggleStyle(.checkbox).padding(12)
                            .background(palette.foreground.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.disabled(busy)
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(palette.color(for: .danger)) }
            HStack {
                Text(L10n.text("已选择 {0} 个条目", [String(selected.count)])).font(.caption).foregroundStyle(palette.muted)
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.disabled(busy)
                Button(L10n.text("合并剧集"), action: merge).buttonStyle(.borderedProminent)
                    .disabled(busy || selected.count < 2 || !selected.contains(targetID))
            }
        }.padding(24).frame(width: 680, height: 570)
            .foregroundStyle(palette.foreground).tint(palette.accent)
            .background { AppThemeBackdropLayer(palette: palette) }
            .task {
                do {
                    records = try await state.televisionRepresentatives(libraryID: libraryID)
                    targetID = targets.first?.id ?? ""; selected = targetID.isEmpty ? [] : [targetID]
                } catch { self.error = error.localizedDescription }
                busy = false
            }
    }
    private func title(_ record: MediaRecord) -> String { record.metadata.showTitle ?? record.metadata.title ?? record.entry.name }
    private func merge() {
        guard let target = targets.first(where: { $0.id == targetID }) else { return }
        busy = true; error = nil
        Task {
            do { try await state.mergeTelevision(groups: records.filter { selected.contains($0.id) }, target: target); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
