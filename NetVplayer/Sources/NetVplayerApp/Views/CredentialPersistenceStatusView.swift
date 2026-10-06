import SwiftUI
import Models
import Storage

struct CredentialPersistenceStatusView: View {
    @State private var message: String?
    var body: some View {
        Group {
            if let message {
                GroupBox(label: SettingsPanelLabel(
                    title: L10n.text("账号保存需要处理"),
                    subtitle: L10n.text("未保存的授权仅在本次会话有效。请重新登录或重试保存。"),
                    systemImage: "key.horizontal"
                )) {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsInlineMessage(message: message)
                        Button(L10n.text("重试保存账号")) {
                            do { try UserPreferences.shared.retryCredentialPersistence(); self.message = nil }
                            catch { self.message = error.localizedDescription }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 27)
                }
            }
        }.task { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UserPreferences.credentialsDidChange).receive(on: RunLoop.main)) { _ in refresh() }
    }
    private func refresh() {
        do { try UserPreferences.shared.checkCredentialPersistence(); message = nil }
        catch { message = error.localizedDescription }
    }
}
