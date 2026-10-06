import SwiftUI
import Models

struct EPGGuideView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = EPGGuideModel()
    @State private var groupIndex = 0
    @State private var dayOffset = 0
    @State private var block = Calendar.current.component(.hour, from: Date()) / 6
    @State private var anchorDay = Calendar.current.startOfDay(for: Date())
    @State private var rowGeneration = UUID()

    private var groups: [ChannelGroup] { appState.channelGroups.filter { !$0.isHidden } }
    private var channels: [Channel] { groups.indices.contains(groupIndex) ? groups[groupIndex].channels : [] }
    private var window: DateInterval {
        let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: anchorDay) ?? anchorDay
        let start = Calendar.current.date(byAdding: .hour, value: block * 6, to: day) ?? day
        return DateInterval(start: start, duration: 6 * 3_600)
    }
    private var scope: String { "\(appState.activeLive?.url ?? "")|\(groupIndex)|\(window.start.timeIntervalSince1970)|\(channels.map { [$0.id, $0.epg, $0.tvgId] + $0.urls })" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.text("节目单")).font(.title2.bold())
                Picker(L10n.text("分组"), selection: $groupIndex) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in Text(group.name).tag(index) }
                }.labelsHidden().frame(maxWidth: 190)
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .help(L10n.text("前六小时")).disabled(dayOffset == -1 && block == 0)
                Picker(L10n.text("日期"), selection: $dayOffset) {
                    ForEach(-1...6, id: \.self) { offset in
                        Text((Calendar.current.date(byAdding: .day, value: offset, to: anchorDay) ?? anchorDay), format: .dateTime.month().day().weekday()).tag(offset)
                    }
                }.labelsHidden().frame(width: 165)
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .help(L10n.text("后六小时")).disabled(dayOffset == 6 && block == 3)
                Button(L10n.text("现在")) {
                    anchorDay = Calendar.current.startOfDay(for: Date()); dayOffset = 0
                    block = Calendar.current.component(.hour, from: Date()) / 6
                    reload()
                }
                Spacer()
                Text(L10n.text("时间按本机时区显示")).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal).padding(.bottom, 12)
            GeometryReader { geometry in
                let width = max(300, geometry.size.width - 220)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text(L10n.text("频道")).frame(width: 170, alignment: .leading)
                        HStack(spacing: 0) {
                            ForEach(0..<6) { hour in
                                Text(window.start.addingTimeInterval(Double(hour) * 3_600), format: .dateTime.hour().minute())
                                    .font(.caption.monospacedDigit()).frame(width: width / 6, alignment: .leading)
                            }
                        }
                    }.padding(.horizontal, 16).frame(height: 30)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(channels.enumerated()), id: \.offset) { index, channel in
                                guideRow(channel: channel, id: String(index), width: width, generation: rowGeneration)
                            }
                        }.id(rowGeneration)
                    }
                }
            }
        }
        .frame(minWidth: 800, idealWidth: 1000, minHeight: 440, idealHeight: 650)
        .themedPresentation()
        .onAppear { reload() }
        .onChange(of: scope) { _, _ in reload() }
        .onDisappear { model.stop() }
    }

    private func guideRow(channel: Channel, id: String, width: CGFloat, generation: UUID) -> some View {
        HStack(spacing: 0) {
            Button {
                Task { await appState.playChannel(channel) }
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name).lineLimit(2)
                    Text(channel.number).font(.caption).foregroundStyle(.secondary)
                }.frame(width: 155, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.text("播放此频道"))
            Spacer().frame(width: 15)
            if let result = model.rows[id] {
                VStack(alignment: .leading, spacing: 3) {
                    if result.data.items.isEmpty {
                        HStack {
                            Text(status(result)).foregroundStyle(.secondary)
                            if result.availability == .unavailable || result.availability == .stale {
                                Button(L10n.text("重试")) { model.retry(id: id) }.disabled(model.loading.contains(id))
                            }
                        }.font(.caption).frame(maxHeight: .infinity)
                    } else {
                        timeline(result.data.items, width: width)
                        if result.availability == .stale {
                            HStack {
                                Text(L10n.text("显示缓存节目单"))
                                Button(L10n.text("重试")) { model.retry(id: id) }.disabled(model.loading.contains(id))
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.frame(width: width, height: 76, alignment: .leading)
            } else {
                HStack { ProgressView().controlSize(.small); Text(L10n.text("正在加载节目单…")).font(.caption) }
                    .frame(width: width, height: 76, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.primary.opacity(Int(id).map { $0.isMultiple(of: 2) } == true ? 0.025 : 0))
        .onAppear { model.appear(id: id, channel: channel, generation: generation) }
        .onDisappear { model.disappear(id: id, generation: generation) }
    }

    private func timeline(_ items: [EpgItem], width: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ZStack(alignment: .topLeading) {
                ForEach(items) { item in
                    let start = max(0, item.start.timeIntervalSince(window.start))
                    let end = min(window.duration, item.end.timeIntervalSince(window.start))
                    if end > start {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.caption.weight(.medium)).lineLimit(2)
                            Text(item.start, format: .dateTime.hour().minute()).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(6).frame(width: max(1, width * (end - start) / window.duration - 2), height: 54, alignment: .topLeading)
                        .background(item.start <= context.date && item.end > context.date ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .clipped().offset(x: width * start / window.duration)
                        .help("\(item.title)  \(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened))")
                    }
                }
                if context.date >= window.start && context.date < window.end {
                    Rectangle().fill(Color.accentColor).frame(width: 1, height: 58)
                        .offset(x: width * context.date.timeIntervalSince(window.start) / window.duration)
                        .allowsHitTesting(false)
                }
            }.frame(width: width, height: 58, alignment: .topLeading).clipped()
        }
    }

    private func status(_ result: EpgLoadResult) -> String {
        switch result.availability {
        case .unconfigured: L10n.text("此频道未配置节目单")
        case .unavailable: L10n.text("节目单加载失败，请重试。")
        case .stale: L10n.text("刷新失败，正在显示上次的节目单。")
        default: L10n.text("此时段暂无节目")
        }
    }

    private func reload() {
        let loader = appState.makeLiveEpgLoader()
        model.reset(window: window) { channel, window, force in await loader.load(channel: channel, window: window, forceRefresh: force) }
        rowGeneration = model.generation
    }

    private func move(_ step: Int) {
        let total = min(27, max(-4, dayOffset * 4 + block + step))
        dayOffset = Int(floor(Double(total) / 4)); block = total - dayOffset * 4
    }
}
