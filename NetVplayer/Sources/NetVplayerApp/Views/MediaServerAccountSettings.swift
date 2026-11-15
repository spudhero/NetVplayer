import MediaServerEngine
import Models
import Storage
import SwiftUI

struct MediaServerAccountSettings: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.appThemePalette) private var palette
  @StateObject private var model: MediaServerAccountModel
  private let loadOnAppear: Bool

  init(model: MediaServerAccountModel = .init(), loadOnAppear: Bool = true) {
    _model = StateObject(wrappedValue: model)
    self.loadOnAppear = loadOnAppear
  }

  var body: some View {
    GroupBox(
      label: SettingsPanelLabel(
        title: L10n.text("媒体服务器"),
        subtitle: L10n.text("支持 Emby、Jellyfin、Plex、极影视与飞牛影视。"), systemImage: "server.rack")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsControlRow(title: L10n.text("账号"), labelWidth: 120) {
          SettingsChoicePicker(
            title: L10n.text("账号"),
            selection: Binding(get: { model.selectedID }, set: { model.select($0) }),
            choices: [UUID?.none] + model.accounts.map { Optional($0.id) }
          ) { id in
            guard let account = model.accounts.first(where: { $0.id == id }) else {
              return L10n.text("添加账号")
            }
            return account.name + " · "
              + L10n.text(model.storedLogins.contains(account.id) ? "已保存登录" : "未登录")
          }.disabled(model.busy)
        }
        sessionSummary.padding(.vertical, 12)
        VStack(alignment: .leading, spacing: 0) {
          heading(L10n.text("服务器"), icon: "server.rack")
          SettingsControlRow(title: L10n.text("服务器类型"), labelWidth: 120) {
            SettingsChoicePicker(
              title: L10n.text("服务器类型"), selection: $model.kind,
              choices: MediaServerKind.allCases
            ) { $0.title }
          }
          if model.kind == .zspace || model.kind == .fnos {
            VStack(alignment: .leading, spacing: 5) {
              Label(L10n.text("连接前准备"), systemImage: "info.circle")
                .font(.system(size: 12, weight: .semibold))
              Text(L10n.text(model.kind == .zspace
                ? "在极影视中启用 Emby 兼容服务，填写该服务的地址和账号。"
                : "填写飞牛影视网页的服务地址和影视账号，端口以服务端设置为准。支持原始文件播放。"))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
          }
          SettingsControlRow(title: L10n.text("账号名称"), labelWidth: 120, requirement: .optional) {
            TextField(L10n.text("方便识别的名称"), text: $model.name)
          }
          SettingsControlRow(title: L10n.text("服务地址"), labelWidth: 120, requirement: .required) {
              TextField(serverPlaceholder, text: $model.server)
              .accessibilityLabel(L10n.text("媒体服务器地址"))
          }
          Toggle(L10n.text("此服务器只支持 HTTP"), isOn: $model.allowsHTTP)
            .toggleStyle(.checkbox).font(.system(size: 12)).padding(.top, 6)
          if model.allowsHTTP || model.server.lowercased().hasPrefix("http://") {
            FeatureNotice(
              message: model.allowsHTTP
                ? L10n.text("HTTP 会明文传送登录信息，请仅在信任的网络中使用。")
                : L10n.text("此地址使用 HTTP；如需连接，请明确启用上方 HTTP 选项。"),
              role: .warning, systemImage: "exclamationmark.triangle"
            ).padding(.top, 8)
          }
          if model.serverChanged {
            FeatureNotice(
              message: L10n.text("服务地址或类型已更改，请重新登录以保存。"),
              role: .warning, systemImage: "info.circle"
            ).padding(.top, 10)
          }
          if model.showsLoginFields {
            heading(L10n.text(model.hasStoredToken ? "重新登录" : "登录信息"), icon: "person.crop.circle")
            if model.kind == .plex {
              Text(L10n.text("从 Plex Web 获取访问令牌，粘贴后验证连接。"))
                .font(.caption).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
              Link(L10n.text("如何获取 Plex 访问令牌"), destination: URL(string: "https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/")!)
                .font(.caption).padding(.top, 6)
            } else {
              SettingsControlRow(title: L10n.text("用户名"), labelWidth: 120, requirement: .required) {
                TextField(L10n.text("用户名"), text: $model.username)
              }
            }
            SettingsControlRow(title: L10n.text(model.kind == .plex ? "Plex 访问令牌" : "密码"), labelWidth: 120,
              requirement: model.kind == .plex ? .required : nil) {
              SettingsPasswordField(model.kind == .plex ? "X-Plex-Token" : L10n.text("输入密码（不保存）"), text: $model.password).id(
                model.selectedID)
            }
          }
          Text(
            L10n.text(
                model.kind == .plex ? "访问令牌仅保存于本机凭据存储，不进入播放地址或备份。" : model.showsLoginFields
                ? "密码不保存；登录令牌仅存于本机凭据存储，不进入播放地址或备份。"
                : "当前登录已保留，无需再次输入密码。更换登录用户时，请选择“重新登录”。")
          )
          .font(.caption).foregroundStyle(palette.muted).fixedSize(
            horizontal: false, vertical: true
          ).padding(.top, 8)
        }.disabled(model.busy)
        Divider().padding(.vertical, 14)
        HStack(spacing: 12) {
          if model.busy {
            ProgressView().controlSize(.small)
            Text(L10n.text(model.isLoggingOut ? "正在退出…" : "正在验证连接…"))
              .font(.caption).foregroundStyle(palette.muted)
            Spacer(minLength: 0)
            Button(L10n.text(model.isLoggingOut ? "停止等待" : "取消连接")) { model.stop() }
          } else {
            if model.showsLoginFields {
              Button(L10n.text("验证并连接")) { model.connect { appState.reloadFileServiceSites() } }
                .buttonStyle(.borderedProminent).disabled(!model.canConnect)
              if model.hasStoredToken, !model.serverChanged, model.state != .expired {
                Button(L10n.text("取消重新登录")) {
                  model.reauthenticating = false
                  model.password = ""
                }
              }
            } else {
              if model.nameChanged {
                Button(L10n.text("保存名称")) { model.saveName { appState.reloadFileServiceSites() } }
                  .buttonStyle(.borderedProminent)
              } else {
                Button(L10n.text("检查连接")) { model.check() }.buttonStyle(.borderedProminent)
              }
              Button(L10n.text("重新登录")) { model.reauthenticating = true }
            }
            Spacer(minLength: 0)
            if model.hasStoredToken {
              Button(L10n.text("退出此账号"), role: .destructive) { model.logout() }.buttonStyle(
                .borderless)
            }
          }
        }
        if let status = model.status {
          FeatureNotice(
            message: status, role: model.statusRole,
            systemImage: model.statusRole == .success
              ? "checkmark.circle"
              : model.statusRole == .danger ? "exclamationmark.circle" : "info.circle"
          )
          .padding(.top, 10)
        }
      }.textFieldStyle(SettingsFieldStyle())
    }
    .onAppear { if loadOnAppear { model.load() } }
    .onDisappear { model.stop() }
  }

  private var sessionSummary: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Image(systemName: stateIcon).foregroundStyle(palette.color(for: stateRole))
        Text(stateTitle).font(.callout.bold())
        if let user = model.selected?.username, !user.isEmpty {
          Text(user).font(.callout).textSelection(.enabled)
        }
        Spacer(minLength: 0)
      }
      Text(stateDescription).font(.caption).foregroundStyle(palette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.foreground.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
      .accessibilityElement(children: .combine)
  }
  private var stateTitle: String {
    switch model.state {
    case .newAccount: L10n.text("尚未添加账号")
    case .signedOut: L10n.text("未登录")
    case .saved: L10n.text("已保存登录，待验证")
    case .checking: L10n.text(model.kind == .plex ? "正在验证 Plex 访问令牌…" : "正在检查登录…")
    case .signedIn: L10n.text(model.kind == .plex ? "Plex 服务器已连接" : "已登录")
    case .expired: L10n.text(model.kind == .plex ? "Plex 访问令牌已失效" : "登录已失效")
    case .unavailable: L10n.text("暂时无法验证登录")
    }
  }
  private var serverPlaceholder: String {
    switch model.kind {
    case .plex: "http://nas.local:32400"
    case .fnos, .zspace: "https://nas.example"
    case .emby: "https://server.example/emby"
    case .jellyfin: "https://server.example/jellyfin"
    }
  }
  private var stateDescription: String {
    switch model.state {
    case .newAccount: L10n.text(model.kind == .plex
      ? "填写 Plex 服务器地址和访问令牌，验证成功后保存。"
      : "填写服务器与登录信息，验证成功后保存账号。")
    case .signedOut: L10n.text(model.kind == .plex
      ? "本机没有可用 Plex 访问令牌，请填写后验证连接。"
      : "服务器配置已保留，本机没有可用登录。请填写登录信息。")
    case .saved, .checking: L10n.text(model.kind == .plex
      ? "本机已保存访问令牌，验证连接后确认登录状态。"
      : "本机已保存登录令牌；用户名将在连接服务器后确认。密码不保存。")
    case .signedIn: L10n.text("登录验证成功，可浏览媒体库、播放影片并同步观看进度。")
    case .expired: L10n.text(model.kind == .plex
      ? "访问令牌已失效，请重新获取 Plex 访问令牌并验证连接。"
      : "服务器不再接受当前登录，请重新输入用户名和密码。")
    case .unavailable: L10n.text("无法连接或读取服务器，已保留本机登录。请检查网络后重试。")
    }
  }
  private var stateRole: AppSemanticColorRole {
    switch model.state {
    case .signedIn: .success
    case .expired, .unavailable: .warning
    default: .secondaryText
    }
  }
  private var stateIcon: String {
    switch model.state {
    case .signedIn: "checkmark.circle.fill"
    case .expired, .unavailable: "exclamationmark.circle"
    default: "person.crop.circle"
    }
  }
  private func heading(_ title: String, icon: String) -> some View {
    Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(
      palette.muted
    )
    .padding(.top, 12).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
  }
}
