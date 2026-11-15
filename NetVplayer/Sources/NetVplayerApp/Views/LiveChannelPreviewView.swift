import SwiftUI
import Models

struct LivePreviewRefreshControls: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var store: LiveChannelPreviewStore
    let refresh: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    cacheNotice.fixedSize()
                    Spacer(minLength: 8)
                    actions.fixedSize()
                }
                .frame(minWidth: 320)
                VStack(alignment: .leading, spacing: 8) {
                    cacheNotice
                    actions
                }
            }
            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cacheNotice: some View {
        Label(L10n.text("缓存画面，非实时"), systemImage: "photo")
            .font(.caption).foregroundStyle(palette.muted)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if store.isRefreshing {
                ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在刷新可见画面…"))
                Text(L10n.text("正在刷新可见画面…")).font(.caption).foregroundStyle(palette.muted)
                Button(L10n.text("取消")) { store.cancelRefresh() }
                    .accessibilityIdentifier("live-preview-cancel")
            } else {
                Button(L10n.text("刷新可见画面"), action: refresh)
                    .accessibilityIdentifier("live-preview-refresh")
            }
        }.buttonStyle(.bordered).controlSize(.regular)
    }
}

/// Shares clipped visibility and window hiding semantics with the poster pipeline.
struct LiveChannelPreviewView: View {
    @ObservedObject var store: LiveChannelPreviewStore
    let channel: Channel
    @State private var owner = UUID()
    var body: some View {
        let frame = store.frame(for: channel)
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let frame { Image(nsImage: frame.image).resizable().scaledToFit() }
                else if !channel.logo.isEmpty {
                    WebImage(urlString: channel.logo, showsLoadingIndicator: false, fallbackSystemImage: "tv", maxPixelSize: 160)
                        .scaledToFit()
                } else {
                    Rectangle().fill(.white.opacity(0.06))
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 80, height: 45).clipped().cornerRadius(4)
            if let frame {
                VStack(alignment: .leading, spacing: 1) {
                    Text(frame.capturedAt, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                    Text(frame.capturedAt, format: .dateTime.hour().minute().second())
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else { Text(L10n.text("尚无缓存画面")).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(width: 80)
        .background(PosterDemandVisibility { priority in
            store.setDemand(channel: channel, owner: owner, priority: priority)
        })
        .onDisappear { store.setDemand(channel: channel, owner: owner, priority: .inactive) }
        .help([store.error(for: channel), frame.map { L10n.text("缓存画面拍摄于 {0}", [$0.capturedAt.formatted()]) },
               L10n.text("缓存画面，非实时")].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channel.name + " · " + (frame.map {
            L10n.text("缓存画面拍摄于 {0}", [$0.capturedAt.formatted()]) + " · " + L10n.text("缓存画面，非实时")
        } ?? L10n.text("尚无缓存画面")))
    }
}
