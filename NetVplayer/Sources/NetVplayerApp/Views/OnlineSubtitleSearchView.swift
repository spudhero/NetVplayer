import SwiftUI
import Models
import Storage
import PlayerEngine
import SubtitleEngine

struct OnlineSubtitleSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var player: PlayerState
    @StateObject private var model = OnlineSubtitleSearchModel()
    @State private var enabled = UserPreferences.shared.onlineSubtitleSearchEnabled
    @State private var token = ""
    @State private var query = ""
    @State private var slot: SubtitleSlot = .primary
    @State private var credentialMessage: String?
    @State private var serviceSettingsExpanded = false
    let attach: (Sub, SubtitleSlot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("在线字幕")).font(.title2)
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            DisclosureGroup(L10n.text("字幕服务设置"), isExpanded: $serviceSettingsExpanded) {
                serviceSettings.padding(.top, 10)
            }
            FormFieldLabel(title: L10n.text("影片名称"), requirement: .required)
            HStack {
                TextField(L10n.text("字幕搜索词"), text: $query)
                    .textFieldStyle(SettingsFieldStyle())
                    .onSubmit { search() }
                Button(L10n.text("搜索")) { search() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!enabled || model.isLoading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || savedToken.isEmpty)
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("取消")) { model.cancel() }
                }
            }
            Picker(L10n.text("加载到"), selection: $slot) {
                Text(L10n.text("主字幕")).tag(SubtitleSlot.primary)
                Text(L10n.text("副字幕")).tag(SubtitleSlot.secondary)
            }.pickerStyle(.segmented)
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.results) { result in
                        Button { model.details(result, token: savedToken) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).lineLimit(2)
                                Text([result.language, result.format].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).disabled(!enabled || model.isLoading)
                    }
                    if model.hasMore {
                        Button(L10n.text("加载更多字幕")) { model.search(query: query, token: savedToken, more: true) }
                            .disabled(!enabled || model.isLoading)
                    }
                    if !model.files.isEmpty { Divider() }
                    ForEach(model.files) { file in
                        Button(L10n.text("下载字幕：{0}", [file.name])) { model.download(file) }
                            .disabled(!enabled || model.isLoading)
                    }
                    if !model.downloads.isEmpty { Divider() }
                    ForEach(model.downloads) { subtitle in
                        Button(L10n.text("使用字幕：{0}", [subtitle.name])) {
                            guard model.owns(player.currentSpec) else { return }
                            attach(subtitle.attachment(language: model.language), slot)
                            dismiss()
                        }.disabled(!enabled || model.isLoading)
                    }
                    if model.results.isEmpty && !model.isLoading && model.errorMessage == nil {
                        Text(L10n.text("输入影片名称并搜索，再选择匹配的语言或版本。"))
                            .foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L10n.text("支持 SRT、ASS、SSA、VTT 和 ZIP；下载后请选择要加载的文件。"))
                .font(.caption).foregroundStyle(.secondary)
            Link(L10n.text("字幕服务由 assrt.net 提供"), destination: URL(string: "https://assrt.net/api/doc")!)
                .font(.caption)
        }
          .padding(20).frame(width: 560, height: 620)
          .themedPresentation()
          .onAppear {
              token = UserPreferences.shared.credential("subtitle.assrt.token")
              serviceSettingsExpanded = token.isEmpty || !enabled
            query = player.currentSpec?.metadata["vod.name"] ?? player.currentSpec?.title ?? ""
            model.bind(to: player.currentSpec.map(SubtitlePlaybackOwner.init))
        }
        .onChange(of: player.currentSpec.map(SubtitlePlaybackOwner.init)) { _, owner in
            model.bind(to: owner)
            query = player.currentSpec?.metadata["vod.name"] ?? player.currentSpec?.title ?? ""
        }
        .onDisappear { model.cancel() }
    }

    private var serviceSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.text("启用在线字幕搜索"), isOn: $enabled)
                .onChange(of: enabled) { _, value in
                    UserPreferences.shared.onlineSubtitleSearchEnabled = value
                    if !value { model.cancel() }
                }
            FormFieldLabel(title: "ASSRT API Token", requirement: .required)
            Text(L10n.text("在线搜索需要字幕服务令牌，填写并保存一次即可。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SettingsPasswordField("ASSRT API Token", text: $token)
                Button(L10n.text("保存字幕令牌")) {
                    do {
                        try UserPreferences.shared.saveCredential(token.trimmingCharacters(in: .whitespacesAndNewlines), for: "subtitle.assrt.token")
                        credentialMessage = L10n.text("字幕令牌已保存。")
                    } catch { credentialMessage = L10n.text("字幕令牌保存失败，请重试。") }
                }
            }
            if let credentialMessage { Text(credentialMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var savedToken: String { UserPreferences.shared.credential("subtitle.assrt.token") }
    private func search() {
        guard enabled, !savedToken.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.search(query: query, token: savedToken)
    }
}
