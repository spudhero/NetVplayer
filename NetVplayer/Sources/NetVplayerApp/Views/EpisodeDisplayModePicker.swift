import Models
import SwiftUI

enum EpisodeDisplayMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: Self { self }

    var title: String {
        switch self {
        case .grid: return L10n.text("宫格")
        case .list: return L10n.text("列表")
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
        case .ascending: return L10n.text("正序")
        case .descending: return L10n.text("倒序")
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
        Picker(L10n.text("剧集显示模式"), selection: $selection) {
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
        .help(L10n.text("切换剧集的宫格或列表显示"))
        .accessibilityLabel(L10n.text("剧集显示模式"))
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
        .help(L10n.text("当前{0}，点击切换为{1}", ["\(selection.title)", "\(selection.next.title)"]))
        .accessibilityLabel(L10n.text("剧集排序"))
        .accessibilityValue(selection.title)
        .accessibilityHint(L10n.text("切换为{0}", ["\(selection.next.title)"]))
    }
}
