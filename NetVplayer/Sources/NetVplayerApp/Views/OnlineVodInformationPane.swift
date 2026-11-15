import SwiftUI
import Models
import MediaLibraryEngine

struct OnlineVodInformationPane<Original: View>: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var model: OnlineVodDetailModel
    let vod: Vod
    let input: OnlineVodDetailInput?
    let layout: VodDetailLayout
    @ViewBuilder let original: () -> Original
    @State private var editing = false
    @State private var query = ""
    @State private var visibilityOwner = UUID()

    var body: some View {
        VStack(spacing: 0) {
            if input != nil {
                ThemedSegmentedControl {
                    ThemedSegmentButton(title: L10n.text("原详情"), isSelected: !model.wantsEnhanced) { model.showOriginal() }
                        .accessibilityIdentifier("online-detail-original")
                    ThemedSegmentButton(title: L10n.text("TMDB 资料"), isSelected: model.wantsEnhanced) { model.showEnhanced() }
                        .accessibilityIdentifier("online-detail-tmdb")
                }.padding(layout.contentInset)
            }
            ThemedScrollView {
                VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                    if input != nil, hasStatus { controls }
                    if model.input?.identity == input?.identity, let metadata = model.displayedMetadata {
                        Text(L10n.text("TMDB 资料")).font(.caption.weight(.semibold)).foregroundStyle(palette.muted)
                        enhanced(metadata)
                    } else {
                        if input != nil {
                            Text(L10n.text("原详情")).font(.caption.weight(.semibold)).foregroundStyle(palette.muted)
                        }
                        original()
                    }
                    if input != nil, model.wantsEnhanced { correction }
                }.padding(layout.contentInset)
            }
        }
        .onChange(of: input, initial: true) { _, value in model.receive(value) }
        .onAppear { model.receive(input); model.resume(owner: visibilityOwner) }
        .onDisappear { model.suspend(owner: visibilityOwner) }
    }

    private var hasStatus: Bool {
        model.wantsEnhanced && (model.isLoading || model.issue != nil ||
            (model.binding == nil && (model.hasSearched || !model.candidates.isEmpty)))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isLoading {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在补全影片资料…")).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.issue != nil {
                Label(L10n.text("资料暂不可用，仍可使用原片源播放"), systemImage: "exclamationmark.circle")
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("重试")) { model.retry() }.buttonStyle(ThemedDialogButtonStyle())
            }
            if model.wantsEnhanced, model.binding == nil, !model.candidates.isEmpty {
                Label(L10n.text("请选择匹配的作品；确认前保留原详情"), systemImage: "person.crop.rectangle.stack")
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.candidates, id: \.onlineDisplayID) { candidate in
                    Button { model.confirm(candidate) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.metadata.title ?? "TMDB").font(.callout.bold()).foregroundStyle(palette.foreground)
                            Text([L10n.text(candidate.metadata.kind == .television ? "剧集" : "电影"),
                                  candidate.metadata.year.map(String.init) ?? "—"].joined(separator: " · "))
                            Text("TMDB · " + (candidate.metadata.tmdbID ?? ""))
                            HStack {
                                Text(L10n.text("使用此作品"))
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.right").accessibilityHidden(true)
                            }.foregroundStyle(palette.accent)
                        }.fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(palette.foreground.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            } else if model.wantsEnhanced, model.hasSearched, model.binding == nil, model.issue == nil, !model.isLoading {
                Label(L10n.text("未找到匹配资料，可修改名称重试"), systemImage: "magnifyingglass")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.font(.caption).foregroundStyle(palette.muted).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { AppGlassSurface(cornerRadius: 10, role: .control, usesSystemMaterial: false) }
    }

    private var correction: some View {
        DisclosureGroup(L10n.text("修正资料匹配"), isExpanded: $editing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("影片名称")).font(.caption)
                TextField(L10n.text("影片名称"), text: $query)
                    .textFieldStyle(SettingsFieldStyle())
                    .onSubmit { search() }
                Button(L10n.text("搜索资料")) { search() }
                    .buttonStyle(ThemedDialogButtonStyle())
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.utf8.count > 512)
            }.padding(.top, 6)
        }
        .font(.caption).foregroundStyle(palette.muted)
        .padding(.top, 8)
        .onChange(of: input?.identity, initial: true) { _, _ in query = vod.vodName; editing = false }
    }

    private func search() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 512 else { return }
        model.search(title: query)
    }

    private func enhanced(_ metadata: MediaMetadata) -> some View {
        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            // TMDB artwork never receives the original site's authorization headers.
            WebImage(urlString: metadata.poster ?? "", fallbackText: metadata.title ?? vod.vodName,
                     maxPixelSize: layout.posterWidth * 2)
                .aspectRatio(PosterMetrics.aspectRatio, contentMode: .fill)
                .frame(width: layout.posterWidth, height: layout.posterHeight).clipped()
                .clipShape(RoundedRectangle(cornerRadius: HomeVisualPolicy.posterCornerRadius))
            Text(metadata.title ?? vod.vodName)
                .font(.system(size: layout.titleFontSize, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            if let originalTitle = metadata.originalTitle, originalTitle != metadata.title {
                Text(originalTitle).font(.subheadline).foregroundStyle(palette.muted)
            }
            Text(L10n.text("片源：{0}", [vod.vodName])).font(.caption).foregroundStyle(palette.muted)
            Button { appState.toggleKeep(vod: vod) } label: {
                Label(L10n.text(appState.isKept(vodId: vod.vodId) ? "取消收藏" : "加入收藏"), systemImage: "star")
            }.buttonStyle(ThemedDialogButtonStyle())
            if let progress = appState.currentDetailHistoryProgressText() {
                Label(progress, systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(palette.accent)
            }
            Text([metadata.year.map(String.init),
                  L10n.text(metadata.kind == .television ? "剧集" : "电影"),
                  metadata.genres?.joined(separator: " / ")].compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(palette.muted)
            if let rating = metadata.tmdbRating, rating > 0 {
                Text("TMDB · " + rating.formatted(.number.precision(.fractionLength(1))))
                    .font(.headline).foregroundStyle(palette.accent)
            }
            if let directors = metadata.directors, !directors.isEmpty {
                Text(L10n.text("导演：") + directors.joined(separator: " / ")).font(.callout)
            }
            if let plot = metadata.plot, !plot.isEmpty {
                Text(L10n.text("简介")).font(.headline)
                Text(plot).font(.body).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let cast = metadata.cast, !cast.isEmpty {
                Text(L10n.text("演职员")).font(.headline)
                ForEach(Array(cast.prefix(20).enumerated()), id: \.offset) { _, person in
                    if let url = Self.tmdbURL(type: "person", id: person.tmdbID) {
                        Link(destination: url) { personLabel(person) }
                            .help(L10n.text("在 TMDB 查看人物与作品"))
                    } else { personLabel(person) }
                }
            }
            if let collection = metadata.collection, let url = Self.tmdbURL(type: "collection", id: collection.tmdbID) {
                Link(collection.name, destination: url).font(.callout)
            }
            if let url = Self.tmdbURL(type: metadata.kind == .television ? "tv" : "movie", id: metadata.tmdbID) {
                Link(L10n.text("在 TMDB 查看完整资料"), destination: url).font(.caption)
            }
            Text(L10n.text("资料来自 TMDB；播放线路与选集来自原片源"))
                .font(.caption).foregroundStyle(palette.muted)
        }
    }

    private func personLabel(_ person: MediaCastMember) -> some View {
        Text(person.name + (person.role.map { " · " + $0 } ?? ""))
            .font(.callout).fixedSize(horizontal: false, vertical: true)
    }
    static func tmdbURL(type: String, id: String?) -> URL? {
        guard ["person", "collection", "tv", "movie"].contains(type), let id,
              !id.isEmpty, id.utf8.count <= 12, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://www.themoviedb.org/" + type + "/" + id)
    }
}

private extension MetadataCandidate {
    var onlineDisplayID: String { MetadataMatcher.onlineCandidateKey(self) ?? id }
}
