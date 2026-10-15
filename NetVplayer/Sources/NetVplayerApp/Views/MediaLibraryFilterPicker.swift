import SwiftUI
import Models

struct MediaLibraryFilterPicker: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    let icon: String
    let options: [MediaLibraryFacet]
    let selected: String?
    let onSelect: (String?) -> Void
    @State private var presented = false
    @State private var search = ""

    private var selectionName: String { options.first { $0.id == selected }?.name ?? L10n.text("全部") }
    private var results: [MediaLibraryFacet] {
        options.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        Button { search = ""; presented = true } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title + " · " + selectionName).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }.font(.callout).foregroundStyle(selected == nil ? palette.muted : palette.accent)
        }.buttonStyle(.bordered).accessibilityLabel(title + " · " + selectionName)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                TextField(L10n.text("搜索筛选项"), text: $search).textFieldStyle(.roundedBorder)
                ThemedScrollView(theme: .subtle) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        option(id: nil, name: L10n.text("全部"), count: nil)
                        ForEach(results) { item in option(id: item.id, name: item.name, count: item.count) }
                        if results.isEmpty {
                            Text(L10n.text(options.isEmpty ? "补全资料后可按系列、主演和导演筛选" : "没有符合搜索的筛选项"))
                                .font(.caption).foregroundStyle(palette.muted).padding(.vertical, 16)
                        }
                    }
                }.frame(height: 280)
                Text(L10n.text("仅显示此媒体库中已有的影片")).font(.caption).foregroundStyle(palette.muted)
            }.padding(18).frame(width: 320).foregroundStyle(palette.foreground).tint(palette.accent)
                .background { AppThemeBackdropLayer(palette: palette) }
        }
    }
    private func option(id: String?, name: String, count: Int?) -> some View {
        Button { onSelect(id); presented = false } label: {
            HStack(spacing: 10) {
                Text(name).lineLimit(2)
                Spacer()
                if let count { Text(String(count)).font(.caption).foregroundStyle(palette.muted) }
                if selected == id { Image(systemName: "checkmark").foregroundStyle(palette.accent) }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.foreground.opacity(selected == id ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
