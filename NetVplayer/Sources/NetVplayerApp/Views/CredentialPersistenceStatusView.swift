import SwiftUI
import Models
import Storage

struct CredentialPersistenceStatusView: View {
    var preferences: UserPreferences = .shared
    @State private var message: String?
    @State private var refreshID = 0
    @State private var retrying = false
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
                            retrying = true
                        }
                        .disabled(retrying)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 27)
                }
            }
        }
        .task(id: refreshID) { await refresh() }
        .task(id: retrying) {
            guard retrying else { return }
            let preferences = preferences
            let result = await Task.detached {
                do { try preferences.retryCredentialPersistence(); return String?.none }
                catch { return error.localizedDescription }
            }.value
            guard !Task.isCancelled else { return }
            message = result
            retrying = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UserPreferences.credentialsDidChange).receive(on: RunLoop.main)) { _ in
            refreshID &+= 1
        }
    }

    private func refresh() async {
        // UserDefaults can synchronously notify SwiftUI while a background
        // credential transaction holds its lock. Never wait for that lock
        // inside a SwiftUI update or on the main thread.
        let preferences = preferences
        let result = await Task.detached {
            do { try preferences.checkCredentialPersistence(); return String?.none }
            catch { return error.localizedDescription }
        }.value
        guard !Task.isCancelled else { return }
        message = result
    }
}
