import SwiftUI
import AppKit
import Models
import Storage
import MediaLibraryEngine

struct MediaMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    let record: MediaRecord
    @State private var title = ""
    @State private var year = ""
    @State private var kind = MediaLibraryKind.movies
    @State private var poster = ""
    @State private var query = ""
    @State private var idInput = ""
    @State private var source = MetadataSource.tmdb
    @State private var candidates: [MetadataCandidate] = []
    @State private var selected: MetadataCandidate?
    @State private var busy = false
    @State private var error: String?
    @State private var verifying: URL?
    @State private var retryAfterVerification: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(record.candidates.isEmpty ? "修正影视信息" : "确认影视信息").font(.title2.bold())
            Text(record.entry.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(candidates.isEmpty ? "没有候选时，请输入准确片名搜索；补充年份可以区分同名影片。" : "核对候选的片名和年份，点击“选择”，再点击“保存修正”。")
                .font(.caption).foregroundStyle(palette.muted)
            ThemedScrollView {
                VStack(alignment: .leading, spacing: 12) {
                ForEach(candidates) { candidate in candidateRow(candidate) }
                if let selected {
                    Label("已选择：" + (selected.metadata.title ?? "") + " · " + (selected.metadata.year.map(String.init) ?? "年份未知"), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(palette.accent)
                }
                Form {
                    Picker("候选来源", selection: $source) { Text("TMDB").tag(MetadataSource.tmdb); Text("豆瓣").tag(MetadataSource.douban) }
                    HStack { TextField("搜索片名", text: $query).onSubmit { search() }; Button("搜索") { search() } }
                    HStack { TextField("条目 ID / 豆瓣链接", text: $idInput); Button("读取条目") { lookup() } }
                    TextField("标题", text: $title)
                    TextField("年份", text: $year)
                    Picker("类型", selection: $kind) { Text("电影").tag(MediaLibraryKind.movies); Text("剧集").tag(MediaLibraryKind.television) }
                    TextField("海报地址", text: $poster)
                    Button("从本机选择海报…", action: choosePoster)
                    Text("手动修改的字段会锁定；重新匹配会保留修正。") .font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped)
                }
                .padding(.trailing, 4).disabled(busy)
            }
            if busy { ProgressView().controlSize(.small).tint(palette.accent) }
            if let error { Text(error).font(.caption).foregroundStyle(palette.color(for: .danger)).textSelection(.enabled) }
            HStack {
                Button("解除手动锁定") {
                    Task {
                        do { try await FileServicesState.shared.saveCorrection(.init(reference: record.reference)); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Spacer(); Button("取消") { dismiss() }
                Button("保存修正") { save() }.keyboardShortcut(.defaultAction)
            }.disabled(busy)
        }.padding(24).frame(width: 650, height: 740)
        .foregroundStyle(palette.foreground).tint(palette.accent)
        .background(AppGlassSurface(cornerRadius: 20, role: .panel))
        .onAppear {
            title = record.metadata.kind == .television ? record.metadata.showTitle ?? record.metadata.title ?? "" : record.metadata.title ?? ""
            query = title; year = record.metadata.year.map(String.init) ?? ""; kind = record.metadata.kind ?? .movies
            poster = record.metadata.poster ?? ""; candidates = record.candidates
            selected = record.correction?.selectedCandidate
            source = candidates.first?.source ?? selected?.source ?? (record.metadataSource == .douban ? .douban : .tmdb)
        }
        .sheet(isPresented: Binding(get: { verifying != nil }, set: { if !$0 { verifying = nil } })) {
            if let url = verifying {
                DoubanVerificationView(url: url) {
                    let retry = retryAfterVerification; retryAfterVerification = nil
                    verifying = nil; retry?()
                }
            }
        }
    }

    private func candidateRow(_ candidate: MetadataCandidate) -> some View {
        let year = candidate.metadata.year.map { "\($0)" } ?? "年份未知"
        let kind = candidate.metadata.kind == .television ? "剧集" : "电影"
        let subtitle = "\(candidate.source.title) · \(year) · \(kind)"
        return HStack(spacing: 12) {
            WebImage(urlString: candidate.metadata.poster ?? "", fallbackText: candidate.metadata.title, maxPixelSize: 140)
                .scaledToFill().frame(width: 48, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.metadata.title ?? "").font(.system(size: 14, weight: .semibold))
                if let original = candidate.metadata.originalTitle, original != candidate.metadata.title {
                    Text(original).font(.caption).foregroundStyle(palette.muted)
                }
                Text(subtitle)
                    .font(.caption).foregroundStyle(palette.muted)
            }
            Spacer()
            Button(selected?.id == candidate.id ? "已选择" : "选择") { select(candidate) }
                .disabled(selected?.id == candidate.id)
                .accessibilityLabel("选择：" + (candidate.metadata.title ?? "") + " · " + year)
        }
        .padding(12).background(AppGlassSurface(cornerRadius: 10, role: .control))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected?.id == candidate.id ? palette.accent : palette.foreground.opacity(0.10), lineWidth: 1)
        }
    }
    private func provider() throws -> any MetadataProvider {
        if source == .douban { return DoubanMetadataProvider.shared }
        guard let credential = try MetadataCredentials.resolve() else { throw MetadataProviderError.unavailable("此构建未配置 TMDB 应用凭据") }
        return TMDBMetadataProvider(credential: credential)
    }
    private func search() {
        busy = true; error = nil
        Task {
            do { candidates = try await provider().search(title: query, year: Int(year), kind: kind) }
            catch { handle(error, retry: search) }; busy = false
        }
    }
    private func lookup() {
        busy = true; error = nil
        Task {
            do {
                let id = source == .douban ? DoubanMetadataProvider.subjectID(idInput) : idInput
                guard let id, !id.isEmpty else { throw MetadataProviderError.invalidResponse }
                let metadata = try await provider().details(id: id, kind: kind)
                apply(.init(source: source, metadata: metadata))
            } catch { handle(error, retry: lookup) }; busy = false
        }
    }
    private func select(_ candidate: MetadataCandidate) {
        source = candidate.source; busy = true; error = nil
        Task {
            do {
                let id = source == .douban ? candidate.metadata.doubanID : candidate.metadata.tmdbID
                guard let id else { throw MetadataProviderError.invalidResponse }
                let details = try await provider().details(id: id, kind: candidate.metadata.kind ?? kind)
                apply(.init(source: source, metadata: details))
            } catch { handle(error, retry: { select(candidate) }) }; busy = false
        }
    }
    private func apply(_ candidate: MetadataCandidate) {
        selected = candidate; title = candidate.metadata.title ?? title; year = candidate.metadata.year.map(String.init) ?? year
        poster = candidate.metadata.poster ?? poster; kind = candidate.metadata.kind ?? kind
    }
    private func handle(_ error: Error, retry: @escaping () -> Void) {
        self.error = error.localizedDescription
        if case MetadataProviderError.verification(let url) = error { retryAfterVerification = retry; verifying = url }
    }
    private func choosePoster() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg, .png, .webP]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            do { poster = try await MediaArtworkCache.shared.importPoster(url: url) }
            catch { self.error = error.localizedDescription }; busy = false
        }
    }
    private func save() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, year.isEmpty || Int(year) != nil else { error = "请填写标题和有效年份"; return }
        var fields = selected?.metadata ?? record.correction?.fields ?? .init()
        let originalTitle = record.metadata.kind == .television ? record.metadata.showTitle ?? record.metadata.title : record.metadata.title
        if title != originalTitle { fields.title = title; if kind == .television { fields.showTitle = title } }
        if kind != record.metadata.kind { fields.kind = kind }
        if year != record.metadata.year.map(String.init) { fields.year = Int(year) }
        if poster != record.metadata.poster {
            guard let url = URL(string: poster), ["https", "http", "file"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { error = "海报地址须为图片 URL，或选择本地海报"; return }
            fields.poster = poster
        }
        let correction = MediaManualCorrection(reference: record.reference, fields: fields, selectedCandidate: selected ?? record.correction?.selectedCandidate)
        busy = true
        Task {
            do { try await FileServicesState.shared.saveCorrection(correction); dismiss() }
            catch { self.error = error.localizedDescription }; busy = false
        }
    }
}
