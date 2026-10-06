import SwiftUI
import Models
import Storage
import MediaLibraryEngine

struct MetadataSettings: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject private var state = FileServicesState.shared
    @State private var overrideKind = TMDBCredential.Kind.apiKey
    @State private var overrideValue = ""
    @State private var hasApplicationCredential = false
    @State private var error: String?
    var body: some View {
        GroupBox(label: SettingsPanelLabel(
            title: L10n.text("海报与影片资料"),
            subtitle: L10n.text("为媒体库补充海报、简介和评分，优先使用视频旁的本地资料。"),
            systemImage: "photo.on.rectangle.angled"
        )) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsControlRow(title: L10n.text("新建媒体库的资料来源"), caption: L10n.text("已建立的媒体库可在编辑库时单独调整")) {
                    SettingsChoicePicker(title: L10n.text("新建媒体库的资料来源"), selection: Binding(get: { state.catalog.defaultMetadataSource }, set: { source in
                        var catalog = state.catalog; catalog.defaultMetadataSource = source
                        do { try FileServiceStore.shared.save(catalog); state.reload() } catch { self.error = error.localizedDescription }
                    }), choices: MetadataSource.allCases, label: FileConnectionPresentation.metadataTitle)
                }
                Text(L10n.text("自动模式优先使用本地资料，再尝试可用的 TMDB 和豆瓣。选择仅本地，也能整理和播放。"))
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
                DisclosureGroup(L10n.text("高级：自定义 TMDB 访问凭据")) {
                    Text(hasApplicationCredential ? L10n.text("TMDB 已配置应用凭据，无需填写令牌。") : L10n.text("TMDB 暂不可用，可继续使用本地资料和豆瓣。"))
                        .font(.caption).foregroundStyle(palette.muted)
                    SettingsChoicePicker(title: L10n.text("凭据类型"), selection: $overrideKind, choices: [TMDBCredential.Kind.apiKey, .readAccessToken]) { $0 == .apiKey ? "API Key" : "Read Access Token" }
                    FormFieldLabel(title: L10n.text("个人凭据"), requirement: .optional)
                    SettingsPasswordField(L10n.text("留空使用应用默认凭据"), text: $overrideValue)
                    HStack {
                        Button(L10n.text("保存覆盖")) { saveOverride() }
                        Button(L10n.text("使用应用默认")) { overrideValue = ""; saveOverride() }
                    }
                    Text(L10n.text("凭据在本机加密保存，不导出到备份。")) .font(.caption).foregroundStyle(palette.muted)
                }
                if let error { SettingsInlineMessage(message: error) }
            }.padding(.leading, 27)
        }
        .task {
            let personal = await Task.detached { MetadataCredentials.personal() }.value
            overrideValue = personal?.value ?? ""; overrideKind = personal?.kind ?? .apiKey
            hasApplicationCredential = Bundle.main.url(forResource: "TMDB", withExtension: "json") != nil
        }
    }
    private func saveOverride() {
        let credential = overrideValue.isEmpty ? nil : TMDBCredential(kind: overrideKind, value: overrideValue)
        Task {
            do { try await Task.detached { try MetadataCredentials.savePersonal(credential) }.value; error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct MetadataAttributionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image("TMDB", bundle: .module).resizable().scaledToFit().frame(width: 110, height: 18)
                Link("TMDB", destination: URL(string: "https://www.themoviedb.org/")!)
                Link("豆瓣电影", destination: URL(string: "https://movie.douban.com/")!)
            }
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("影视资料与图片来源：本地资料、TMDB 或豆瓣；评分分别标注来源。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
