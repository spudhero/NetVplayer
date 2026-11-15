import SwiftUI
import Models
import ApplicationCore

/// Presentation only; the owning search view keeps cursor and request scope.
struct SearchContinuationStatusRow: View {
    @Environment(\.appThemePalette) private var palette
    let siteName: String
    let status: SearchPageCursor.Status
    let message: String?
    let isSearching: Bool
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                summary.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                summary
                actions.padding(.leading, 28)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background { AppGlassSurface(cornerRadius: 8, role: .control, usesSystemMaterial: false) }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if status == .loading { ProgressView().controlSize(.small) }
                else { Image(systemName: status == .retryable ? "exclamationmark.circle" : "info.circle") }
            }.frame(width: 20).foregroundStyle(palette.muted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(siteName).font(.subheadline.weight(.semibold)).foregroundStyle(palette.foreground)
                Text(message ?? L10n.text(status == .loading ? "正在加载更多结果…" : status == .retryable ? "重试此来源" : "已达到加载上限"))
                    .font(.caption).foregroundStyle(palette.muted)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        if status == .loading {
            Button(L10n.text("取消"), action: cancel).buttonStyle(.bordered)
        } else if status == .retryable {
            Button(L10n.text("重试此来源"), action: retry).buttonStyle(.bordered).disabled(isSearching)
        }
    }
}
