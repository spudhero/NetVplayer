import SwiftUI

enum EpisodeDisplayMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: Self { self }

    var title: String {
        switch self {
        case .grid: return "宫格"
        case .list: return "列表"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

enum EpisodeSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: Self { self }

    var title: String {
        switch self {
        case .ascending: return "正序"
        case .descending: return "倒序"
        }
    }

    var systemImage: String {
        switch self {
        case .ascending: return "arrow.up.to.line"
        case .descending: return "arrow.down.to.line"
        }
    }

    var next: Self {
        switch self {
        case .ascending: return .descending
        case .descending: return .ascending
        }
    }

    func ordered<Element>(_ values: [Element]) -> [Element] {
        switch self {
        case .ascending: return values
        case .descending: return Array(values.reversed())
        }
    }
}

struct EpisodeDisplayModePicker: View {
    @Binding var selection: EpisodeDisplayMode

    var body: some View {
        Picker("剧集显示模式", selection: $selection) {
            ForEach(EpisodeDisplayMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage)
                    .tag(mode)
                    .help(mode.title)
            }
        }
        .labelsHidden()
        .labelStyle(.iconOnly)
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 76)
        .help("切换剧集的宫格或列表显示")
        .accessibilityLabel("剧集显示模式")
    }
}

struct EpisodeSortOrderButton: View {
    @Binding var selection: EpisodeSortOrder

    var body: some View {
        Button {
            selection = selection.next
        } label: {
            Image(systemName: selection.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("当前\(selection.title)，点击切换为\(selection.next.title)")
        .accessibilityLabel("剧集排序")
        .accessibilityValue(selection.title)
        .accessibilityHint("切换为\(selection.next.title)")
    }
}
